//! ATX animation scripts: the texture animation programs the level data
//! carries, as a list of instructions with a per-script timer.
//!
//! Scripts are read line by line and each line is matched against the known
//! directive formats. A line that matches none is reported and skipped
//! without producing an instruction, because shipped data contains such
//! lines. Once a script's texture counter runs out the remaining lines are
//! ignored too. STOP is matched as a prefix, so a longer word starting with
//! STOP still stops the script.

const std = @import("std");
const MessageCode = @import("../message_code.zig").MessageCode;
const FixedList = @import("../util/fixed_list.zig").FixedList;

/// Textures and sounds one advance may report: more than ten seconds of
/// catching up at the fastest shipped rate (24 frames a second).
pub const max_events = 256;
pub const Events = FixedList(Event, error{TooManyAtxEvents});
pub const EventBuffer = [max_events]Event;

/// Steps an advance may take between two textures before it must have
/// repeated itself. No script in the test suite needed more than one.
const max_control_steps = 256;

pub const Instruction = union(enum) {
    go_to: i32,
    stop,
    rate: i32,
    texture: []const u8,
    start_sound: struct { priority: u8, name: []const u8 },
};

pub const Animation = struct {
    instructions: []Instruction,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Animation {
        var lines = Lines{ .source = source };
        const header = try lines.next() orelse return error.MissingAtxHeader;
        var scan = Scan{ .source = header };
        if (!scan.literal("ATX")) return error.InvalidAtxHeader;

        const major = scan.integer() orelse return error.InvalidAtxHeader;
        if (!scan.literal(".")) return error.InvalidAtxHeader;

        const minor = scan.integer() orelse return error.InvalidAtxHeader;
        if (major != 1 or minor != 0) return error.UnsupportedAtxVersion;

        const declaration = try lines.next() orelse return error.MissingAtxInstructions;

        scan = .{ .source = declaration };
        if (!scan.literal("INST")) return error.InvalidAtxInstructions;

        const declared = scan.integer() orelse return error.InvalidAtxInstructions;
        if (declared <= 0 or declared >= 32767) return error.InvalidAtxInstructions;

        var result: std.ArrayList(Instruction) = .empty;
        errdefer result.deinit(allocator);
        var remaining_textures = declared;

        while (try lines.next()) |line| {
            const instruction = if (remaining_textures != 0) parseInstruction(line) else null;

            if (instruction == null) {
                std.log.debug("atx_LoadAtxFile: Unknown directive in atx file: <{s}>", .{line});
                continue;
            }

            if (result.items.len >= @as(usize, @intCast(declared)) + 1)
                return error.AtXInstructionCountOverflow;

            if (instruction.? == .texture) remaining_textures -= 1;

            try result.append(allocator, instruction.?);
        }

        if (result.items.len == 0) return error.MissingAtxInstructions;

        return .{ .instructions = try result.toOwnedSlice(allocator) };
    }

    pub fn initialTexture(self: Animation) ?[]const u8 {
        for (self.instructions) |instruction| switch (instruction) {
            .texture => |name| return name,
            else => {},
        };

        return null;
    }

    pub fn deinit(self: Animation, allocator: std.mem.Allocator) void {
        allocator.free(self.instructions);
    }
};

pub const Event = union(enum) { texture: usize, sound: usize };

pub const StateFlags = packed struct(u16) {
    on_sector: bool = false,
    on_wall: bool = false,
    unused_2: u6 = 0,
    /// Waiting at a stop instruction for a message.
    stopped: bool = false,
    unused_9: u7 = 0,
};

pub const State = struct {
    rate: i32 = 12,
    pc: u32 = 0,
    displayed: u32 = 1000,
    last_tick: u32 = 0,
    flags: StateFlags,

    pub fn tick(self: *State, program: Animation, now: u32, events: *Events) !void {
        if (now < self.last_tick) return error.AtxClockMovedBackwards;

        const count = ((now - self.last_tick) *% @as(u32, @bitCast(self.rate))) / 1000;

        if (count != 0) {
            try self.advance(program, @bitCast(count), now, events);
            self.last_tick = now;
        }
    }

    pub fn message(
        self: *State,
        program: Animation,
        code: MessageCode,
        arg1: i32,
        now: u32,
        events: *Events,
    ) !void {
        const destination: i32 = switch (code) {
            .next_stop, .next_frame, .switch_frame => -1,
            .previous_stop, .previous_frame => -2,
            .goto_stop, .goto_frame => arg1,
            else => return,
        };

        if (!self.flags.stopped) return;

        self.flags.stopped = false;

        if (destination == -2) {
            self.pc -%= 1;
        } else if (destination == -1) {
            self.pc +%= 1;
            if (self.pc >= program.instructions.len) self.pc = 0;
        } else {
            if (destination >= program.instructions.len) return;
            if (destination < 0) return error.InvalidAtxInstructionIndex;
            self.pc = @intCast(destination);
        }

        try self.advance(program, -1, now, events);
    }

    pub fn advance(self: *State, program: Animation, amount: i32, now: u32, events: *Events) !void {
        const sign: u32 = @bitCast(amount >> 31);
        const requested = (@as(u32, @bitCast(amount)) ^ sign) -% sign;
        var remaining = requested;
        const last: u32 = @intCast(program.instructions.len - 1);
        var controls: ControlSteps = .{};

        while (remaining != 0 and (amount < 0 or !self.flags.stopped)) {
            if (self.pc >= program.instructions.len) return error.InvalidAtxInstructionIndex;

            if (program.instructions[self.pc] == .texture) {
                controls.count = 0;
            } else if (program.instructions[self.pc] != .stop) {
                try controls.visit(.{
                    .pc = self.pc,
                    .rate = self.rate,
                    .last_tick = self.last_tick,
                    .remaining = remaining,
                });
            }

            switch (program.instructions[self.pc]) {
                .go_to => |destination| {
                    const raw: u32 = @bitCast(destination);
                    const chosen = if (raw -% 1 >= program.instructions.len) last else raw;
                    self.pc = chosen -% 1;
                },
                .stop => {
                    self.flags.stopped = true;
                    remaining = 0;
                    self.pc -%= 1;
                },
                .rate => |rate| {
                    self.last_tick +%= (requested -% remaining) *% 1000;
                    self.rate = rate;
                    remaining = ((now -% self.last_tick) *% @as(u32, @bitCast(rate))) / 1000;
                },
                .texture => {
                    try events.append(.{ .texture = self.pc });
                    remaining -= 1;
                    self.displayed = self.pc;
                },
                .start_sound => try events.append(.{ .sound = self.pc }),
            }

            self.pc = if (self.pc < last) self.pc + 1 else last;
        }
    }
};

/// The steps since the last texture. Reaching one of them again with the same
/// timing means the script loops without showing anything.
const ControlSteps = struct {
    const Step = struct {
        pc: u32,
        rate: i32,
        last_tick: u32,
        remaining: u32,
    };

    steps: [max_control_steps]Step = undefined,
    count: usize = 0,

    fn visit(self: *ControlSteps, step: Step) !void {
        std.debug.assert(self.count <= self.steps.len);

        for (self.steps[0..self.count]) |seen| {
            if (std.meta.eql(seen, step)) return error.InvalidAtxControlFlow;
        }

        if (self.count == self.steps.len) return error.AtxControlFlowTooLong;

        self.steps[self.count] = step;
        self.count += 1;
    }
};

const Lines = struct {
    source: []const u8,
    position: usize = 0,

    fn next(self: *Lines) !?[]const u8 {
        while (self.position < self.source.len) {
            const start = self.position;

            while (self.position < self.source.len and self.source[self.position] != '\r' and self.source[self.position] != '\n') self.position += 1;

            const raw = self.source[start..self.position];
            if (raw.len > 126) return error.UnsupportedAtxLineLength;

            if (self.position < self.source.len) {
                const end = self.source[self.position];
                self.position += 1;
                if (end == '\r' and self.position < self.source.len and self.source[self.position] == '\n') self.position += 1;
            }

            const line = std.mem.trimStart(
                u8,
                raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len],
                " \t",
            );

            if (line.len == 0 or line[0] == '#') continue;
            return line;
        }

        return null;
    }
};

const Scan = struct {
    source: []const u8,

    fn literal(self: *Scan, value: []const u8) bool {
        if (!std.mem.startsWith(u8, self.source, value)) return false;
        self.source = self.source[value.len..];

        return true;
    }

    fn integer(self: *Scan) ?i32 {
        self.source = std.mem.trimStart(u8, self.source, " \t");
        var end: usize = 0;

        if (end < self.source.len and (self.source[end] == '+' or self.source[end] == '-')) end += 1;

        const start = end;

        while (end < self.source.len and std.ascii.isDigit(self.source[end])) end += 1;

        if (end == start) return null;

        const result = std.fmt.parseInt(i32, self.source[0..end], 10) catch return null;
        self.source = self.source[end..];

        return result;
    }

    fn word(self: *Scan) ?[]const u8 {
        self.source = std.mem.trimStart(u8, self.source, " \t");
        var end: usize = 0;

        while (end < self.source.len and !std.ascii.isWhitespace(self.source[end])) end += 1;

        if (end == 0) return null;

        const result = self.source[0..end];
        self.source = self.source[end..];

        return result;
    }
};

fn parseInstruction(line: []const u8) ?Instruction {
    var scan = Scan{ .source = line };

    if (scan.literal("TEXTURE")) if (scan.word()) |name| return .{ .texture = name };

    scan = .{ .source = line };

    if (scan.literal("RATE")) if (scan.integer()) |rate| return .{ .rate = rate };

    scan = .{ .source = line };

    if (scan.literal("START_SOUND")) if (scan.integer()) |priority| {
        if (scan.word()) |name| return .{
            .start_sound = .{ .priority = @truncate(@as(u32, @bitCast(priority))), .name = name },
        };
    };

    scan = .{ .source = line };

    if (scan.literal("GOTO")) if (scan.integer()) |destination| return .{ .go_to = destination };

    if (std.mem.startsWith(u8, line, "STOP")) return .stop;

    return null;
}

test "ATX initial texture follows load order rather than execution branches" {
    const source = "ATX 1.0\r\nINST 6\r\n RATE 12\r\n GOTO 4\r\n TEXTURE FIRST.PCX\r\n STOP\r\n START_SOUND 320 SHATTER\r\n TEXTURE SECOND.PCX\r\n";
    const animation = try Animation.parse(std.testing.allocator, source);
    defer animation.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("FIRST.PCX", animation.initialTexture().?);
    try std.testing.expectEqual(@as(usize, 6), animation.instructions.len);
    try std.testing.expectEqual(@as(u8, 64), animation.instructions[4].start_sound.priority);
    try std.testing.expectError(
        error.UnsupportedAtxVersion,
        Animation.parse(std.testing.allocator, "ATX 2.0\n"),
    );

    try std.testing.expectError(
        error.MissingAtxInstructions,
        Animation.parse(std.testing.allocator, "ATX 1.0\nINST 1\nUNKNOWN\n"),
    );
}

test "ATX loader skips shipped unmatched directives without creating instructions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fixture = std.Io.Dir.cwd().readFileAlloc(
        io,
        "testdata/atx-loader-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(fixture);
    const json = try std.json.parseFromSlice(std.json.Value, a, fixture, .{});
    defer json.deinit();
    const archive_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "inputs/OUTLAWS_CD2/OUTLAWS/OLTEX.LAB",
        a,
        .limited(32 * 1024 * 1024),
    );

    defer a.free(archive_bytes);
    const archive = try @import("lab.zig").Archive.init(archive_bytes);

    for (json.value.object.get("cases").?.array.items) |case| {
        const animation = try Animation.parse(
            a,
            try archive.find(case.object.get("name").?.string, 0),
        );

        defer animation.deinit(a);
        const expected = case.object.get("instructions").?.array.items;

        try std.testing.expectEqual(expected.len, animation.instructions.len);

        for (expected, animation.instructions) |reference, actual| {
            const opcode = reference.object.get("opcode").?.integer;

            switch (actual) {
                .go_to => |value| {
                    try std.testing.expectEqual(@as(i64, 0), opcode);
                    try std.testing.expectEqual(reference.object.get("value").?.integer, value);
                },
                .stop => try std.testing.expectEqual(@as(i64, 1), opcode),
                .rate => |value| {
                    try std.testing.expectEqual(@as(i64, 2), opcode);
                    try std.testing.expectEqual(reference.object.get("value").?.integer, value);
                },
                .texture => |name| {
                    try std.testing.expectEqual(@as(i64, 3), opcode);
                    try std.testing.expectEqualStrings(reference.object.get("name").?.string, name);
                },
                .start_sound => |sound| {
                    try std.testing.expectEqual(@as(i64, 4), opcode);
                    try std.testing.expectEqual(
                        reference.object.get("priority").?.integer,
                        sound.priority,
                    );

                    const native_name = reference.object.get("name").?.string;

                    try std.testing.expectEqualStrings(".wav", native_name[native_name.len - 4 ..]);
                    try std.testing.expectEqualStrings(
                        native_name[0 .. native_name.len - 4],
                        sound.name,
                    );
                },
            }
        }
    }
}
