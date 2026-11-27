//! NWX sprite sets (WAX): the animation banks almost every actor is drawn
//! with, plus the little command interpreter that plays them.
//!
//! Cells are column-major, bottom row first, as world sprites need them;
//! HUD and inventory cells are transposed from that on use. An instance can
//! be created unbound, with no owner and no callback - map decorations stay
//! that way and still animate. Playback callbacks run synchronously and may
//! select another sequence while the interpreter is mid-command, so commands
//! share one budget and a freed instance is only released after it returns.

const std = @import("std");

/// Selections may nest this deep on one instance. Callbacks run game code
/// that selects again in the middle of a command, so nesting stays on the
/// call stack and this bounds it. No shipped sprite set nests at all; a
/// sequence that selects itself is refused instead of overflowing the stack.
pub const max_selection_depth = 32;

pub const Cell = struct {
    width: u32,
    height: u32,
    flags: u32,
    pixels: []const u8,
    encoded: []const u8 = &.{},
};

pub const Part = struct {
    cell: u32,
    raw_x: i32,
    raw_y: i32,
    offset_x: f32,
    offset_y: f32,
    width: f32,
    height: f32,
    flags: u32,
};

pub const Frame = struct { offset_x: f32, offset_y: f32, parts: []const Part };

pub const Choreography = struct {
    values: [4]u32,
    directions: u32,
    frames_per_direction: u32,
    frames: []const i16,
};

pub const Playback = struct {
    last_time: u32 = 0,
    angle_offset: i16 = 0,
    direction: u32 = 0,
    choreography: u32 = 0,
    next_frame: u32 = 0,
    frame: u32 = 0,
    flags: u32 = 1,
    terminated: bool = false,
    command_budget: ?*usize = null,
    /// How many selections are running inside each other on this instance,
    /// through select commands and through callbacks that select again.
    selection_depth: u8 = 0,

    pub fn advance(self: *Playback, costume: *const Costume, count: u32, now: u32) !void {
        var next = self.*;
        var budget: usize = 1_000_000;
        try next.step(costume, count, now, &budget, null);
        self.* = next;
    }

    pub fn advanceWithContext(self: *Playback, costume: *const Costume, count: u32, now: u32, context: anytype) anyerror!void {
        var budget: usize = 1_000_000;
        const previous = self.command_budget;
        const shared = previous orelse &budget;
        self.command_budget = shared;
        defer self.command_budget = previous;
        try self.step(costume, count, now, shared, context);
    }

    pub fn select(self: *Playback, costume: *const Costume, sequence: u32, now: u32, context: anytype) anyerror!void {
        if (sequence >= costume.choreographies.len) return;
        var budget: usize = 1_000_000;
        const previous = self.command_budget;
        const shared = previous orelse &budget;
        if (shared.* == 0) return error.InvalidNwxCommandLoop;
        shared.* -= 1;
        if (self.selection_depth == max_selection_depth) return error.NwxSelectionTooDeep;
        self.selection_depth += 1;
        defer self.selection_depth -= 1;
        self.command_budget = shared;
        defer self.command_budget = previous;
        self.last_time = now;
        self.choreography = sequence;
        self.next_frame = 0;
        self.frame = 0;
        const directions = costume.choreographies[sequence].directions;
        const turns: i32 = @intFromFloat(@as(f64, @floatFromInt(self.angle_offset)) * (1.0 / 65536.0) * @as(f64, @floatFromInt(directions)));
        self.direction = @bitCast(@as(i32, @as(i16, @truncate(@as(i32, @bitCast(directions)) -% turns -% 1))));
        self.flags = (self.flags | 5) & ~@as(u32, 2);
        if (comptime @TypeOf(context) != @TypeOf(null)) try context.event(self, costume, 0x5f, &.{sequence}, now);
        try self.step(costume, 1, now, shared, context);
    }

    fn step(self: *Playback, costume: *const Costume, requested: u32, now: u32, budget: *usize, context: anytype) anyerror!void {
        if (self.terminated) return;
        const old_flags = self.flags;
        if (self.flags & 1 == 0 or self.flags & 2 != 0) {
            self.last_time = now;
        } else {
            var choreography = try self.selected(costume);
            var remaining = requested;
            if (remaining == 0) {
                if (now < self.last_time) self.last_time = now;
                remaining = (choreography.values[2] *% (now -% self.last_time)) / 1000;
            }
            if (remaining != 0) {
                while (remaining != 0 and !self.terminated) {
                    if (budget.* == 0) return error.InvalidNwxCommandLoop;
                    budget.* -= 1;
                    if (self.next_frame >= choreography.frames_per_direction) {
                        if (self.next_frame == 0) return error.InvalidNwxChoreographyFrame;
                        remaining -= 1;
                        self.next_frame -= 1;
                        continue;
                    }
                    const opcode = try self.word(choreography);
                    if (opcode & 0x8000 == 0) {
                        self.frame = self.next_frame - 1;
                        remaining -= 1;
                        continue;
                    }
                    var arguments: i32 = @as(i16, @bitCast(try self.word(choreography)));
                    self.flags &= ~@as(u32, 4);
                    switch (opcode) {
                        0xfff5, 0xfff6 => {
                            if (comptime @TypeOf(context) != @TypeOf(null)) return error.UnsupportedNwxOwnerFlags;
                        },
                        0xfff7 => return error.UnsupportedNwxMessageCommand,
                        0xfff8 => {
                            if (comptime @TypeOf(context) != @TypeOf(null)) {
                                try context.event(self, costume, 0x5e, &.{}, now);
                            }
                        },
                        0xfff9 => {
                            self.flags |= 2;
                            remaining = 0;
                            if (comptime @TypeOf(context) != @TypeOf(null)) try context.event(self, costume, 0x61, &.{}, now);
                        },
                        0xfffa => {
                            arguments = 0;
                            self.next_frame = try self.word(choreography);
                            if (comptime @TypeOf(context) != @TypeOf(null)) try context.event(self, costume, 0x62, &.{self.next_frame}, now);
                        },
                        0xfffb => {
                            var values: [5]u32 = @splat(0);
                            var i: usize = 0;
                            while (arguments != 0 and i < 5) : (i += 1) {
                                arguments -= 1;
                                values[i] = try self.word(choreography);
                            }
                            if (comptime @TypeOf(context) != @TypeOf(null)) {
                                if (i == 0) return error.InvalidNwxCommandArguments;
                                try context.event(self, costume, values[0], values[1..i], now);
                            }
                        },
                        0xfffc => {
                            arguments -= 1;
                            const target = try self.word(choreography);
                            const previous = self.command_budget;
                            self.command_budget = budget;
                            defer self.command_budget = previous;
                            try self.select(costume, target, now, context);
                        },
                        0xfffd => {
                            arguments -= 1;
                            const value = try self.word(choreography);
                            if (comptime @TypeOf(context) != @TypeOf(null)) try context.event(self, costume, 2, &.{value}, now);
                        },
                        0xfffe => {
                            arguments = 0;
                            self.next_frame = 0;
                            if (comptime @TypeOf(context) != @TypeOf(null)) try context.event(self, costume, 0x62, &.{}, now);
                        },
                        0xffff => {
                            remaining = 0;
                            self.flags &= ~@as(u32, 5);
                            if (comptime @TypeOf(context) != @TypeOf(null)) try context.event(self, costume, 0x63, &.{}, now);
                        },
                        else => return error.InvalidNwxCommand,
                    }
                    if (self.flags & 4 != 0) {
                        arguments = 0;
                        remaining = 0;
                        choreography = try self.selected(costume);
                    }
                    if (arguments < 0) return error.InvalidNwxCommandArguments;
                    if (arguments != 0) self.next_frame +%= @intCast(arguments);
                }
                self.last_time = now;
                const index = try self.sequenceIndex(choreography, self.frame);
                if (choreography.frames[index] < 0) return error.NwxChoreographyCommandIsNotFrame;
            }
        }
        self.flags = (self.flags & ~@as(u32, 4)) | (old_flags & 4);
    }

    fn selected(self: Playback, costume: *const Costume) !Choreography {
        if (self.choreography >= costume.choreographies.len) return error.InvalidNwxChoreographyIndex;
        return costume.choreographies[self.choreography];
    }

    fn sequenceIndex(self: Playback, choreography: Choreography, cursor: u32) !usize {
        if (self.direction >= choreography.directions or cursor >= choreography.frames_per_direction) return error.InvalidNwxChoreographyFrame;
        return @as(usize, self.direction) * choreography.frames_per_direction + cursor;
    }

    fn word(self: *Playback, choreography: Choreography) !u16 {
        const result: u16 = @bitCast(choreography.frames[try self.sequenceIndex(choreography, self.next_frame)]);
        self.next_frame += 1;
        return result;
    }
};

pub const Costume = struct {
    arena: std.heap.ArenaAllocator,
    scale: f32,
    secondary_scale: f32,
    cells: []Cell,
    frames: []Frame,
    choreographies: []Choreography,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Costume {
        var r = Reader{ .bytes = bytes };
        try r.tag("WAXF");
        if (try r.word() != 2 or try r.word() != 1) return error.UnsupportedNwxVersion;
        const scale = try r.float();
        const secondary_scale = try r.float();
        if (scale <= 0) return error.InvalidNwxScale;
        const cell_offset = try r.word();
        const frame_offset = try r.word();
        const choreography_offset = try r.word();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        try r.seek(cell_offset);
        try r.tag("CELT");
        const cells = try a.alloc(Cell, try r.checkedCount(20));
        _ = try r.word();
        for (cells, 0..) |*cell, i| {
            if (try r.word() != i) return error.InvalidNwxCellIndex;
            const size = try r.word();
            const width = try r.word();
            const height = try r.word();
            const flags = try r.word();
            if (width > 0x7fff or height > 0x7fff) return error.InvalidNwxCellDimensions;
            const source = try r.take(size);
            const pixels = try a.alloc(u8, @as(usize, width) * height);
            if (flags & 1 != 0) {
                if (width > source.len / 4) return error.TruncatedNwx;
                for (0..width) |x| {
                    const offset = std.mem.readInt(u32, source[x * 4 ..][0..4], .little);
                    if (offset < width * 4 or offset >= source.len) return error.InvalidNwxColumnOffset;
                    try decodeColumn(source[offset..], pixels[x * height ..][0..height]);
                }
            } else {
                if (height > source.len / 4) return error.TruncatedNwx;
                const row = try a.alloc(u8, width);
                defer a.free(row);
                for (0..height) |y| {
                    const offset = std.mem.readInt(u32, source[y * 4 ..][0..4], .little);
                    if (offset < height * 4 or offset >= source.len) return error.InvalidNwxRowOffset;
                    try decodeColumn(source[offset..], row);
                    for (row, 0..) |pixel, x| pixels[x * height + (height - 1 - y)] = pixel;
                }
            }
            cell.* = .{ .width = width, .height = height, .flags = flags, .pixels = pixels, .encoded = try a.dupe(u8, source) };
        }
        try r.seek(frame_offset);
        try r.tag("FRMT");
        const frames = try a.alloc(Frame, try r.checkedCount(24));
        _ = try r.word();
        for (frames, 0..) |*frame, i| {
            if (try r.word() != i) return error.InvalidNwxFrameIndex;
            const x: f32 = @floatFromInt(try r.signed());
            const y: f32 = @floatFromInt(try r.signed());
            _ = try r.word();
            _ = try r.word();
            const count = try r.word();
            if (count > 2) return error.UnsupportedNwxFrameParts;
            const parts = try a.alloc(Part, count);
            for (parts) |*part| {
                const index = try r.word();
                if (index >= cells.len) return error.InvalidNwxCellIndex;
                const raw_x = try r.signed();
                const raw_y = try r.signed();
                const flags = try r.word();
                const cell = cells[index];
                const unit: f64 = @as(f32, @bitCast(@as(u32, 0x3d924925)));
                const denominator = 14.0 / @as(f64, scale);
                part.* = .{
                    .cell = index,
                    .raw_x = raw_x,
                    .raw_y = raw_y,
                    .flags = flags,
                    .offset_x = @floatCast(@as(f64, @floatFromInt(-%raw_x)) * scale * unit),
                    .offset_y = @floatCast((@as(f64, @floatFromInt(cell.height)) * scale + @as(f64, @floatFromInt(raw_y))) * unit),
                    .width = @floatCast(@as(f64, @floatFromInt(cell.width)) / denominator),
                    .height = @floatCast(@as(f64, @floatFromInt(cell.height)) / denominator),
                };
            }
            frame.* = .{ .offset_x = x, .offset_y = y, .parts = parts };
        }
        try r.seek(choreography_offset);
        try r.tag("CHOT");
        const choreographies = try a.alloc(Choreography, try r.checkedCount(32));
        _ = try r.word();
        for (choreographies, 0..) |*choreography, i| {
            if (try r.word() != i) return error.InvalidNwxChoreographyIndex;
            _ = try r.word();
            var values: [4]u32 = undefined;
            for (&values) |*value| value.* = try r.word();
            const directions = try r.word();
            const frames_per_direction = try r.word();
            const count = std.math.mul(usize, directions, frames_per_direction) catch return error.InvalidNwxChoreographySize;
            if (count > r.remaining() / 2) return error.TruncatedNwx;
            const indices = try a.alloc(i16, count);
            for (indices) |*index| index.* = @bitCast(try r.half());
            choreography.* = .{ .values = values, .directions = directions, .frames_per_direction = frames_per_direction, .frames = indices };
        }
        return .{ .arena = arena, .scale = scale, .secondary_scale = secondary_scale, .cells = cells, .frames = frames, .choreographies = choreographies };
    }

    pub fn deinit(self: *Costume) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn select(self: *const Costume, choreography_index: u32, frame: u32, angle: i16, offset: i16) !*const Frame {
        return self.selectFacing(choreography_index, frame, angle, offset, false);
    }

    pub fn selectFacing(self: *const Costume, choreography_index: u32, frame: u32, angle: i16, offset: i16, four_views: bool) !*const Frame {
        if (choreography_index >= self.choreographies.len) return error.InvalidNwxChoreographyIndex;
        const choreography = self.choreographies[choreography_index];
        if (choreography.directions == 0 or frame >= choreography.frames_per_direction) return error.InvalidNwxChoreographyFrame;
        const delta: u32 = @bitCast(@as(i32, angle) - @as(i32, offset));
        const orientation: u32 = @intFromFloat(@as(f64, @floatFromInt(delta)) * (1.0 / 16384.0) * @as(f64, @floatFromInt(choreography.directions)));
        var direction = choreography.directions -% orientation -% 1;
        if (four_views) direction = fourViews(direction, choreography.directions);
        if (direction >= choreography.directions) direction = choreography.directions - 1;
        const index = choreography.frames[@as(usize, direction) * choreography.frames_per_direction + frame];
        if (index < 0) return error.NwxChoreographyCommandIsNotFrame;
        if (@as(u16, @intCast(index)) >= self.frames.len) return error.InvalidNwxFrameIndex;
        return &self.frames[@intCast(index)];
    }
};

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn remaining(self: Reader) usize {
        return self.bytes.len - self.offset;
    }

    fn take(self: *Reader, count: usize) ![]const u8 {
        if (count > self.remaining()) return error.TruncatedNwx;
        const result = self.bytes[self.offset..][0..count];
        self.offset += count;
        return result;
    }

    fn seek(self: *Reader, offset: usize) !void {
        if (offset > self.bytes.len) return error.TruncatedNwx;
        self.offset = offset;
    }

    fn tag(self: *Reader, expected: []const u8) !void {
        if (!std.mem.eql(u8, try self.take(4), expected)) return error.InvalidNwxSection;
    }

    fn word(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn half(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    fn signed(self: *Reader) !i32 {
        return @bitCast(try self.word());
    }

    fn float(self: *Reader) !f32 {
        const value: f32 = @bitCast(try self.word());
        if (!std.math.isFinite(value)) return error.InvalidNwxFloat;
        return value;
    }

    fn checkedCount(self: *Reader, minimum: usize) !usize {
        const value = try self.word();
        if (value > self.remaining() / minimum) return error.TruncatedNwx;
        return value;
    }
};

fn fourViews(direction: u32, directions: u32) u32 {
    const q = directions >> 2;
    const e = q >> 2;
    if (direction < q - e) return 0;
    if (direction < q + e) return q;
    if (direction < 3 *% q -% e) return 2 *% q;
    return if (direction < e +% 3 *% q) 3 *% q else 0;
}

fn decodeColumn(source: []const u8, destination: []u8) !void {
    var input: usize = 0;
    var output: usize = 0;
    while (output < destination.len) {
        if (input >= source.len) return error.TruncatedNwxColumn;
        const control = source[input];
        input += 1;
        const count = @min(@as(usize, control >> 1) + 1, destination.len - output);
        if (control & 1 != 0) {
            if (input >= source.len) return error.TruncatedNwxColumn;
            @memset(destination[output..][0..count], source[input]);
            input += 1;
        } else {
            if (count > source.len - input) return error.TruncatedNwxColumn;
            @memcpy(destination[output..][0..count], source[input..][0..count]);
            input += count;
        }
        output += count;
    }
}

fn hashWords(hash: *std.crypto.hash.sha2.Sha256, words: []const u32) void {
    for (words) |word| {
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, word, .little);
        hash.update(&encoded);
    }
}

test "NWX cells, frames and choreography match the reference loader" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB", a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);
    const cases = .{
        .{ "SHRUB01.NWX", "0704cd6eeed59976df0f9ff4d4d369b21655d622e569ca0b981fbd5902bf3f90" },
        .{ "HOR1.NWX", "441f1c1384b94d0610b36ac906e5f15e54dd8dabcad6233b531d1b0872f909ea" },
        .{ "BGY3.NWX", "66351072fbeac72af3ad5ec88f32a4905d25a99bfd8a5f3c81a76612fe6056da" },
        .{ "COW1.NWX", "da1778bfa097108b8127c86a4b92ae3baaa73959342900cfcfdefe44dc6e83c9" },
    };
    inline for (cases) |case| {
        var costume = try Costume.parse(a, try archive.find(case[0], 0));
        defer costume.deinit();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashWords(&hash, &.{ @bitCast(costume.scale), @bitCast(costume.secondary_scale), @intCast(costume.cells.len), @intCast(costume.frames.len), @intCast(costume.choreographies.len) });
        for (costume.cells) |cell| {
            hashWords(&hash, &.{ cell.width, cell.height, cell.flags });
            hash.update(cell.pixels);
        }
        for (costume.frames) |frame| {
            hashWords(&hash, &.{ @bitCast(frame.offset_x), @bitCast(frame.offset_y), @intCast(frame.parts.len) });
            for (frame.parts) |part| hashWords(&hash, &.{ part.cell, @bitCast(part.raw_x), @bitCast(part.raw_y), @bitCast(part.offset_x), @bitCast(part.offset_y), @bitCast(part.width), @bitCast(part.height), part.flags });
        }
        for (costume.choreographies) |choreography| {
            hashWords(&hash, &choreography.values);
            hashWords(&hash, &.{ choreography.directions, choreography.frames_per_direction });
            for (choreography.frames) |frame| {
                var encoded: [2]u8 = undefined;
                std.mem.writeInt(i16, &encoded, frame, .little);
                hash.update(&encoded);
            }
        }
        var actual: [32]u8 = undefined;
        hash.final(&actual);
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case[1]);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "NWX directional frame boundaries match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB", a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);
    var costume = try Costume.parse(a, try archive.find("BGY3.NWX", 0));
    defer costume.deinit();
    const angles = [_]i16{ 0, 511, 512, 1023, 1024, 2047, 2048, 4095, 4096, 8191, 8192, 12287, 12288, 16383 };
    const expected = [_]usize{ 79, 79, 79, 79, 81, 81, 81, 83, 83, 86, 86, 82, 82, 79 };
    for (angles, expected) |angle, index| try std.testing.expectEqual(&costume.frames[index], try costume.select(0, 0, angle, 0));
}

test "v1.1.1 snaps directions to four views while 3D is open" {
    var table: [40]i16 = undefined;
    for (&table, 0..) |*entry, k| entry.* = @intCast(k);
    var frames: [40]Frame = undefined;
    for (&frames) |*frame| frame.* = .{ .offset_x = 0, .offset_y = 0, .parts = &.{} };
    var choreographies = [_]Choreography{.{ .values = .{ 0, 0, 0, 0 }, .directions = 1, .frames_per_direction = 1, .frames = &table }};
    var costume: Costume = .{ .arena = undefined, .scale = 1, .secondary_scale = 1, .cells = &.{}, .frames = &frames, .choreographies = &choreographies };
    const offsets = [_]i16{ 0, 1000, -3000, 0x2000 };
    const states = [_]bool{ false, false, false, true };
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    for (1..41) |directions| {
        choreographies[0].directions = @intCast(directions);
        choreographies[0].frames = table[0..directions];
        for (states) |four| for (offsets) |offset| {
            var angle: i32 = -0x8000;
            while (angle < 0x8000) : (angle += 61) {
                const frame = try costume.selectFacing(0, 0, @intCast(angle), offset, four);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, @intCast((@intFromPtr(frame) - @intFromPtr(&frames[0])) / @sizeOf(Frame)), .little);
                digest.update(&bytes);
            }
        };
    }
    var hash: [32]u8 = undefined;
    digest.final(&hash);
    try std.testing.expectEqualStrings("cbf16ea63430e4e15ea8c0c5aee283fea650eef0124e4b245c33d4ce1ea90072", &std.fmt.bytesToHex(hash, .lower));
}

test "inventory and weapon NWX rows match pixels" {
    const a = std.testing.allocator;
    const cases = .{
        .{ "OLOBJ.LAB", "IBULLIT.NWX", "e20fb027211d7597213abec02c6abd068aa8fff76eafef7acc9962b641c3cce2" },
        .{ "OLOBJ.LAB", "ICART.NWX", "3bfb303d6a4f40a1ab4be817c09776d3b25a17850d366d8fe477deb62d3b845f" },
        .{ "OLOBJ.LAB", "IBADGE.NWX", "93f204cee668f918ec3748bd1956b7018ed65f9629c6f638294263ade1b94d4f" },
        .{ "OLOBJ.LAB", "IDOCBAG.NWX", "9d99c5463836206de96bb350b7835e85d979321eda4196ecd71b69153d9edf94" },
        .{ "OLOBJ.LAB", "IIRONKEY.NWX", "9e4041ed99f7453bd64b1da5ac5e88f947cb7f26b04cadff2352d26540ba9550" },
        .{ "OLWEAP.LAB", "IJFIST.NWX", "6d033cdb0670f52906eaca96738bd42f68e7bda4a33d7be81fd82686e19f6f15" },
        .{ "OLWEAP.LAB", "IJPISTOL.NWX", "7459dc238dc4aaf0b8f074f3364d98cca3b71535d623e78c5309f14cb9c789cf" },
        .{ "OLWEAP.LAB", "IJRIFLE.NWX", "7aec43dcaf9a8d5b83867dd76bfd2837d9949195b876d76c8e171e41c904fd4e" },
    };
    inline for (cases) |case| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/" ++ case[0], a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer a.free(bytes);
        const archive = try @import("lab.zig").Archive.init(bytes);
        var costume = try Costume.parse(a, try archive.find(case[1], 0));
        defer costume.deinit();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (costume.cells) |cell| {
            hashWords(&hash, &.{ cell.width, cell.height, cell.flags });
            hash.update(cell.pixels);
        }
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case[2]);
        try std.testing.expectEqualSlices(u8, &expected, &hash.finalResult());
    }
}

test "NWX row offsets must address encoded payload" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB", a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);
    const original = try archive.find("IBULLIT.NWX", 0);
    const corrupt = try a.dupe(u8, original);
    defer a.free(corrupt);
    const cell_table = std.mem.readInt(u32, corrupt[20..24], .little);
    const first_row = corrupt[cell_table + 12 + 20 ..][0..4];
    std.mem.writeInt(u32, first_row, 0, .little);
    try std.testing.expectError(error.InvalidNwxRowOffset, Costume.parse(a, corrupt));
    std.mem.writeInt(u32, first_row, std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidNwxRowOffset, Costume.parse(a, corrupt));
}

test "unbound WAX playback matches 768 reference steps" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB", a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);
    const cases = .{ .{ "COW1.NWX", 0 }, .{ "COW1.NWX", 1 }, .{ "HOR1.NWX", 0 }, .{ "SHRUB01.NWX", 0 }, .{ "BGY3.NWX", 0 }, .{ "BGY3.NWX", 1 } };
    const intervals = [_]u32{ 7, 11, 16, 22, 40, 0, 333, 1000 };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (cases) |case| {
        var costume = try Costume.parse(a, try archive.find(case[0], 0));
        defer costume.deinit();
        var playback: Playback = .{ .choreography = case[1] };
        var now: u32 = 0;
        for (0..128) |i| {
            now += intervals[i % intervals.len];
            if (i == 64) now -= 150;
            if (i == 32) playback.flags |= 2;
            if (i == 38) playback.flags &= ~@as(u32, 2);
            try playback.advance(&costume, if (i == 96) 3 else 0, now);
            hashWords(&hash, &.{ playback.last_time, @as(u16, @bitCast(playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags });
        }
        if (comptime std.mem.eql(u8, case[0], "COW1.NWX") and case[1] == 0) {
            try std.testing.expectEqual(@as(u32, 3), playback.frame);
            for (0..32) |direction_index| _ = try costume.select(playback.choreography, playback.frame, @intCast(direction_index * 512), 0);
        }
    }
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "b4dd0d23d5adf8be1d7ae04134f840b62c3f1c7dc21822af91ddf1b3723b76b7");
    try std.testing.expectEqualSlices(u8, &expected, &hash.finalResult());
}

test "bound WAX playback reads on when its logic ignores termination" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB", a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);
    var costume = try Costume.parse(a, try archive.find("CHCKEN.NWX", 0));
    defer costume.deinit();
    const Recorder = struct {
        messages: [8]u32 = undefined,
        count: usize = 0,

        pub fn event(self: *@This(), _: *Playback, _: *const Costume, message: u32, _: []const u32, _: u32) !void {
            self.messages[self.count] = message;
            self.count += 1;
        }
    };
    var recorder: Recorder = .{};
    var playback: Playback = .{};
    try playback.select(&costume, 21, 0, &recorder);
    try playback.advanceWithContext(&costume, 0, 1000, &recorder);
    try std.testing.expectEqualSlices(u32, &.{ 0x5f, 2, 0x5e, 0x63 }, recorder.messages[0..recorder.count]);
    try std.testing.expect(!playback.terminated);
    try std.testing.expectEqual(@as(u32, 9), playback.frame);
    try std.testing.expectEqual(@as(u32, 4), playback.flags);
    try std.testing.expectEqual(@as(i16, 62), costume.choreographies[21].frames[playback.direction * costume.choreographies[21].frames_per_direction + playback.frame]);
}

test "NWX compressed columns retain clipped runs and reject missing payload" {
    var result: [6]u8 = undefined;
    try decodeColumn(&.{ 4, 7, 8, 9, 255, 11 }, &result);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9, 11, 11, 11 }, &result);
    try std.testing.expectError(error.TruncatedNwxColumn, decodeColumn(&.{ 4, 7, 8 }, &result));
    try std.testing.expectError(error.TruncatedNwxColumn, decodeColumn(&.{1}, &result));
    try std.testing.expectError(error.UnsupportedNwxVersion, Costume.parse(std.testing.allocator, "WAXF\x03\x00\x00\x00\x01\x00\x00\x00"));
}

test "a sequence that selects itself is refused before the stack runs out" {
    var frames = [_]i16{ -4, 1, 0, 0 };
    var choreographies = [_]Choreography{.{ .values = .{ 0, 0, 10, 0 }, .directions = 1, .frames_per_direction = frames.len, .frames = &frames }};
    var costume: Costume = .{ .arena = undefined, .scale = 1, .secondary_scale = 1, .cells = &.{}, .frames = &.{}, .choreographies = &choreographies };
    const Counter = struct {
        selections: usize = 0,

        pub fn event(self: *@This(), _: *Playback, _: *const Costume, message: u32, _: []const u32, _: u32) !void {
            if (message == 0x5f) self.selections += 1;
        }
    };
    var counter: Counter = .{};
    var playback: Playback = .{};
    try std.testing.expectError(error.NwxSelectionTooDeep, playback.select(&costume, 0, 0, &counter));
    try std.testing.expectEqual(@as(usize, max_selection_depth), counter.selections);
    try std.testing.expectEqual(@as(u8, 0), playback.selection_depth);
    var unbound: Playback = .{};
    try std.testing.expectError(error.NwxSelectionTooDeep, unbound.advance(&costume, 1, 0));
}
