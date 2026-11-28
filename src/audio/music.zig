//! Music: the cue list and the ordered command records that drive it.
//!
//! Strings point into the loaded file; the arrays are owned. A malformed
//! file is rejected here, because the layers above take the arrays at face
//! value.

const std = @import("std");

pub const default_volume: u7 = 28;

pub const Track = struct { disc: []const u8, number: u8 };

pub const Command = union(enum) { track: Track, goto: u8 };

pub const ScriptFlags = packed struct(u32) {
    unused_0: u18 = 0,
    /// Starting again carries on from the current cue, not the start cue.
    keeps_cue: bool = false,
    unused_19: u13 = 0,
};

pub const Script = struct {
    flags: ScriptFlags,
    start_cue: usize,
    cues: [][]Command,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Script {
        var lines = Lines{ .bytes = bytes };
        var header = Scanner{ .bytes = try lines.required() };
        if (!header.literal("MSC")) return error.InvalidMusicHeader;

        const major = try header.integer();
        if (!header.literal(".")) return error.InvalidMusicHeader;

        const minor = try header.integer();
        if (major != 1 or minor != 0) return error.UnsupportedMusicVersion;

        const flags: ScriptFlags = @bitCast(try directiveInteger(try lines.required(), "FLAGS:"));
        const first = try directiveInteger(try lines.required(), "START_CUE:");
        const count = try directiveInteger(try lines.required(), "CUES:");
        if (count <= 0 or count > bytes.len or first < 1 or first > count) return error.InvalidMusicCue;

        const cues = try allocator.alloc([]Command, @intCast(count));

        @memset(cues, &.{});
        errdefer {
            for (cues) |cue| allocator.free(cue);
            allocator.free(cues);
        }

        while (try lines.next()) |line| {
            const number = try directiveInteger(std.mem.trimStart(u8, line, " \t"), "CUE");
            if (number < 1 or number > count) return error.InvalidMusicCue;

            const index: usize = @intCast(number - 1);
            if (!prefix(try lines.required(), "BEGIN")) return error.MissingMusicCueBegin;

            var commands: std.ArrayList(Command) = .empty;
            defer commands.deinit(allocator);

            while (true) {
                const command_line = try lines.required();

                if (prefix(command_line, "END")) break;

                var scan = Scanner{ .bytes = std.mem.trimStart(u8, command_line, " \t") };

                if (scan.literal("CD_TRACK")) {
                    const disc = scan.word16() orelse return error.InvalidMusicTrack;
                    const track_text = scan.word16() orelse return error.InvalidMusicTrack;
                    const track: u8 = @truncate(@as(u32, @bitCast(atoi(track_text))));
                    if (track == 0 or track > 99) return error.InvalidMusicTrack;

                    try commands.append(
                        allocator,
                        .{ .track = .{ .disc = disc, .number = track } },
                    );
                } else if (scan.literal("GOTO_CUE")) {
                    const target_text = scan.word16() orelse return error.InvalidMusicCue;
                    const target: u8 = @truncate(@as(u32, @bitCast(atoi(target_text) -% 1)));
                    if (target >= cues.len) return error.InvalidMusicCue;
                    try commands.append(allocator, .{ .goto = target });
                } else return error.UnsupportedMusicCommand;
            }

            try commands.appendSlice(allocator, cues[index]);
            allocator.free(cues[index]);

            cues[index] = &.{};
            cues[index] = try commands.toOwnedSlice(allocator);
        }

        for (cues) |cue| if (cue.len == 0) return error.EmptyMusicCue;

        return .{ .flags = flags, .start_cue = @intCast(first - 1), .cues = cues };
    }

    pub fn deinit(self: Script, allocator: std.mem.Allocator) void {
        for (self.cues) |cue| allocator.free(cue);
        allocator.free(self.cues);
    }
};

pub const Player = struct {
    script: *const Script,
    cue: usize = 0,
    command: usize = 0,
    active: bool = false,
    restored: bool = false,

    pub fn start(self: *Player) !?Track {
        if (!self.restored and !self.script.flags.keeps_cue) {
            self.cue = self.script.start_cue;
            self.command = 0;
        }

        self.restored = false;
        self.active = true;

        return self.current();
    }

    pub fn restore(self: *Player, cue: i32) !?Track {
        if (cue < 0 or cue >= self.script.cues.len) return error.InvalidMusicCue;

        self.cue = @intCast(cue);
        self.command = 0;
        self.restored = true;

        return self.start();
    }

    pub fn finished(self: *Player) !?Track {
        if (!self.active) return null;

        if (self.command + 1 == self.script.cues[self.cue].len) {
            if (self.cue + 1 == self.script.cues.len) {
                self.active = false;
                return null;
            }

            self.cue += 1;
            self.command = 0;
        } else self.command += 1;

        return self.current();
    }

    pub fn stop(self: *Player) void {
        self.active = false;
    }

    fn current(self: *Player) !?Track {
        var jumps: usize = 0;

        while (self.active) {
            switch (self.script.cues[self.cue][self.command]) {
                .track => |track| return track,
                .goto => |target| {
                    self.cue = target;
                    self.command = 0;
                    jumps += 1;
                    if (jumps > self.script.cues.len) return error.CyclicMusicJump;
                },
            }
        }

        return null;
    }
};

const Scanner = struct {
    bytes: []const u8,

    fn literal(self: *Scanner, value: []const u8) bool {
        if (!std.mem.startsWith(u8, self.bytes, value)) return false;
        self.bytes = self.bytes[value.len..];

        return true;
    }

    fn integer(self: *Scanner) !i32 {
        self.bytes = std.mem.trimStart(u8, self.bytes, " \t\r\n\x0b\x0c");
        var end: usize = 0;

        if (self.bytes.len != 0 and (self.bytes[0] == '-' or self.bytes[0] == '+')) end = 1;

        const digits = end;

        while (end < self.bytes.len and std.ascii.isDigit(self.bytes[end])) : (end += 1) {}

        if (end == digits) return error.InvalidMusicInteger;

        const result = std.fmt.parseInt(
            i32,
            self.bytes[0..end],
            10,
        ) catch return error.InvalidMusicInteger;

        self.bytes = self.bytes[end..];

        return result;
    }

    fn word16(self: *Scanner) ?[]const u8 {
        self.bytes = std.mem.trimStart(u8, self.bytes, " \t\r\n\x0b\x0c");
        var end: usize = 0;

        while (end < @min(
            16,
            self.bytes.len,
        ) and !std.ascii.isWhitespace(self.bytes[end])) : (end += 1) {}

        if (end == 0) return null;

        const word = self.bytes[0..end];
        self.bytes = self.bytes[end..];

        return word;
    }
};

const Lines = struct {
    bytes: []const u8,

    fn next(self: *Lines) !?[]const u8 {
        while (self.bytes.len != 0) {
            const end = std.mem.indexOfAny(u8, self.bytes, "\r\n") orelse self.bytes.len;
            const line = self.bytes[0..end];
            if (line.len > 254) return error.UnsupportedMusicLineLength;

            var next_offset = end;

            if (next_offset < self.bytes.len) {
                const delimiter = self.bytes[next_offset];
                next_offset += 1;
                if (delimiter == '\r' and next_offset < self.bytes.len and self.bytes[next_offset] == '\n') next_offset += 1;
            }

            self.bytes = self.bytes[next_offset..];

            const visible = line[0 .. std.mem.indexOfScalar(u8, line, 0) orelse line.len];
            const trim = std.mem.trimStart(u8, visible, " \t");

            if (trim.len == 0 or trim[0] == '#') continue;
            return visible;
        }

        return null;
    }

    fn required(self: *Lines) ![]const u8 {
        return try self.next() orelse error.TruncatedMusicScript;
    }
};

pub fn completionDelay(sectors: u32) u32 {
    return (sectors / 75) *% 1000 +% (sectors % 75) * 14 +% 1000;
}

pub fn due(deadline: u32, now: u32) bool {
    return @as(i32, @bitCast(deadline)) < @as(i32, @bitCast(now));
}

pub fn channelVolume(volume: u7) u16 {
    const value: u16 = volume;

    return (value | value << 8) * 2;
}

fn prefix(line: []const u8, value: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), value);
}

fn directiveInteger(line: []const u8, name: []const u8) !i32 {
    var scan = Scanner{ .bytes = line };
    if (!scan.literal(name)) return error.InvalidMusicDirective;

    return scan.integer();
}

fn atoi(bytes: []const u8) i32 {
    var scan = Scanner{ .bytes = bytes };

    return scan.integer() catch 0;
}

test "music rejects malformed scripts and command-only loops" {
    const a = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidMusicCue,
        Script.parse(a, "MSC 1.0\nFLAGS: 0\nSTART_CUE: 0\nCUES: 1\n"),
    );

    try std.testing.expectError(
        error.UnsupportedMusicCommand,
        Script.parse(a, "MSC 1.0\nFLAGS: 0\nSTART_CUE: 1\nCUES: 1\nCUE 1\nBEGIN\nMIDI X\nEND\n"),
    );

    try std.testing.expectError(
        error.TruncatedMusicScript,
        Script.parse(
            a,
            "MSC 1.0\nFLAGS: 0\nSTART_CUE: 1\nCUES: 1\nCUE 1\nBEGIN\nCD_TRACK OUTLAWS_1 2\n",
        ),
    );

    var script = try Script.parse(
        a,
        "MSC 1.0\nFLAGS: 0\nSTART_CUE: 1\nCUES: 1\nCUE 1\nBEGIN\nGOTO_CUE 1\nEND\n",
    );

    defer script.deinit(a);
    var player = Player{ .script = &script };

    try std.testing.expectError(error.CyclicMusicJump, player.start());
}

test "CD music completion timer retains frame rounding and strict comparison" {
    try std.testing.expectEqual(@as(u32, 200882), completionDelay(14988));
    try std.testing.expect(!due(200882, 200882));
    try std.testing.expect(due(200882, 200883));
    try std.testing.expect(!due(0x7fffffff, 0x80000000));
}

test "Hideout MSC plays CD1 tracks2 4 3 and jumps back to cue1" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(bytes);
    var script = try Script.parse(a, try archive.find("HIDEOUT.MSC", 0x4d534342));
    defer script.deinit(a);
    var player = Player{ .script = &script };
    var track = (try player.start()).?;

    for ([_]u8{ 2, 4, 3, 2, 4, 3, 2 }) |number| {
        try std.testing.expect(std.ascii.eqlIgnoreCase("OUTLAWS_1", track.disc));
        try std.testing.expectEqual(number, track.number);
        track = (try player.finished()).?;
    }
}

test "all six CD1 MSC loaders and playback sequences match the reference" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const reference = std.Io.Dir.cwd().readFileAlloc(
        io,
        "testdata/music-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(reference);
    const Sample = struct {
        name: []const u8,
        sha256: []const u8,
        flags: u32,
        start_cue: usize,
        cues: [][]struct { kind: u32, disc: []const u8, number: u8 },
        plays: []struct { disc: []const u8, track: u8, flags: u32, kind: u32 },
        states: []struct { active: bool, cue: usize, plays: usize },
    };

    const Timer = struct {
        sectors: u32,
        start: u32,
        deadline: u32,
        polls: []struct { now: u32, status: u32, message: u32 },
    };

    const parsed = try std.json.parseFromSlice(
        struct {
            exe_sha256: []const u8,
            samples: []Sample,
            dll_sha256: []const u8,
            timers: []Timer,
        },
        a,
        reference,
        .{},
    );

    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.exe_sha256,
    );

    try std.testing.expectEqualStrings(
        "9f902a68970f9f15be6d5f8667d31e602cd66c0d434f13021259cb71359b4a9c",
        parsed.value.dll_sha256,
    );

    for (parsed.value.timers) |timer| {
        try std.testing.expectEqual(timer.deadline, timer.start +% completionDelay(timer.sectors));

        for (timer.polls) |poll| {
            try std.testing.expectEqual(poll.status == 0, due(timer.deadline, poll.now));
            try std.testing.expectEqual(
                @as(u32, @intFromBool(due(timer.deadline, poll.now))),
                poll.message,
            );
        }
    }

    var archive_bytes: [2][]u8 = undefined;
    var archives: [2]@import("../assets/lab.zig").Archive = undefined;

    for ([_][]const u8{
        "OUTLAWS.LAB",
        "OLGEO.LAB",
    }, &archive_bytes, &archives) |name, *bytes, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}", .{name});
        defer a.free(path);
        bytes.* = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128 * 1024 * 1024));
        archive.* = try @import("../assets/lab.zig").Archive.init(bytes.*);
    }

    defer for (archive_bytes) |bytes| a.free(bytes);

    for (parsed.value.samples) |expected| {
        const data = archives[0].find(
            expected.name,
            0x4d534342,
        ) catch try archives[1].find(expected.name, 0x4d534342);

        var digest: [32]u8 = undefined;

        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        var expected_hash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected_hash, expected.sha256);
        try std.testing.expectEqualSlices(u8, &expected_hash, &digest);

        var script = try Script.parse(a, data);
        defer script.deinit(a);

        try std.testing.expectEqual(expected.flags, @as(u32, @bitCast(script.flags)));
        try std.testing.expectEqual(expected.start_cue, script.start_cue);
        try std.testing.expectEqual(expected.cues.len, script.cues.len);

        for (expected.cues, script.cues) |wanted, found| {
            try std.testing.expectEqual(wanted.len, found.len);

            for (wanted, found) |command, actual| switch (actual) {
                .track => |track| {
                    try std.testing.expectEqual(@as(u32, 1), command.kind);
                    try std.testing.expectEqualStrings(command.disc, track.disc);
                    try std.testing.expectEqual(command.number, track.number);
                },
                .goto => |target| {
                    try std.testing.expectEqual(@as(u32, 3), command.kind);
                    try std.testing.expectEqual(command.number, target);
                },
            };
        }

        var player = Player{ .script = &script };
        var track = try player.start();
        var played: usize = 0;

        for (expected.states) |state| {
            if (track) |actual| {
                const wanted = expected.plays[played];

                try std.testing.expectEqualStrings(wanted.disc, actual.disc);
                try std.testing.expectEqual(wanted.track, actual.number);
                try std.testing.expectEqual(@as(u32, 0), wanted.flags);
                try std.testing.expectEqual(@as(u32, 0), wanted.kind);

                played += 1;
            }

            try std.testing.expectEqual(state.active, player.active);
            try std.testing.expectEqual(state.cue, player.cue);
            try std.testing.expectEqual(state.plays, played);

            track = try player.finished();
        }
    }

    try std.testing.expectEqual(@as(u16, 0x3838), channelVolume(default_volume));
}

test "restored music restarts the saved cue head" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/music-restore-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Fixture = struct {
        executable_sha256: []const u8,
        script: []const u8,
        cases: []struct {
            cue: i32,
            before_flags: u32,
            after_flags: u32,
            actual_cue: usize,
            plays: []struct { disc: []const u8, track: u8, flags: u32, kind: u32 },
        },
    };

    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{});
    defer fixture.deinit();
    var script = try Script.parse(a, fixture.value.script);
    defer script.deinit(a);

    for (fixture.value.cases) |case| {
        var player: Player = .{ .script = &script };

        if (case.cue < 0 or case.cue >= script.cues.len) {
            try std.testing.expectError(error.InvalidMusicCue, player.restore(case.cue));
        } else {
            _ = try player.start();
            _ = try player.finished();

            const track = (try player.restore(case.cue)).?;

            try std.testing.expectEqual(case.actual_cue, player.cue);
            try std.testing.expectEqual(case.plays[0].track, track.number);
            try std.testing.expectEqualStrings(case.plays[0].disc, track.disc);
            try std.testing.expect(player.active);
            try std.testing.expectEqual(@as(usize, 0), player.command);
        }
    }
}
