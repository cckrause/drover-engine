//! The numbered sound list scripts use: an index instead of a name.
//!
//! A missing or out-of-range index is rejected rather than played as
//! whatever happens to be in that slot.

const std = @import("std");
const RequestFlags = @import("engine.zig").RequestFlags;

const level = @import("../assets/level.zig");
const Request = @import("request.zig").Request;

pub const Entry = struct { basename: []const u8 = "", priority: u8 = 1 };

pub const Table = struct {
    entries: []Entry,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Table {
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidIndexedSounds;

        var entries: ?[]Entry = null;
        errdefer if (entries) |values| allocator.free(values);
        var lines = std.mem.splitScalar(u8, bytes, '\n');

        while (lines.next()) |raw| {
            if (raw.len >= 0x400) return error.InvalidIndexedSounds;

            var scan = Scanner{ .text = raw };

            if (scan.literal("NUM") and scan.literal("SOUNDS:")) {
                const count = try scan.integer();
                if (count < 0 or count > bytes.len) return error.InvalidIndexedSounds;

                if (entries) |previous| allocator.free(previous);

                entries = null;
                const values = try allocator.alloc(Entry, @intCast(count));
                @memset(values, .{});
                entries = values;
                continue;
            }

            scan = .{ .text = raw };
            scan.whitespace();

            if (scan.text.len == 0 or (!std.ascii.isDigit(
                scan.text[0],
            ) and scan.text[0] != '-' and scan.text[0] != '+')) continue;

            const index = try scan.integer();
            const values = entries orelse return error.InvalidIndexedSounds;
            if (index < 0 or index >= values.len) return error.InvalidIndexedSoundIndex;

            scan.whitespace();
            if (scan.text.len == 0) return error.InvalidIndexedSounds;

            const priority: u8 = switch (scan.text[0]) {
                'H' => 0x6b,
                'M' => 0x40,
                else => 1,
            };

            scan.text = scan.text[1..];
            scan.whitespace();
            var name_end: usize = 0;

            while (name_end < scan.text.len and !std.ascii.isWhitespace(
                scan.text[name_end],
            )) : (name_end += 1) {}

            if (name_end == 0 or name_end >= 0x200) return error.InvalidIndexedSounds;

            values[@intCast(index)] = .{ .basename = scan.text[0..name_end], .priority = priority };
        }

        const values = entries orelse return error.InvalidIndexedSounds;

        for (values) |entry| if (entry.basename.len == 0) return error.MissingIndexedSound;

        return .{ .entries = values };
    }

    pub fn deinit(self: Table, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    pub fn request(self: Table, index: u32, sector: usize, position: level.Vec3) !Request {
        if (index >= self.entries.len) return error.InvalidIndexedSoundIndex;

        return .{
            .basename = self.entries[index].basename,
            .priority = 0x40,
            .volume = 0x7f,
            .flags = .{},
            .sector = sector,
            .position = position,
        };
    }
};

const Scanner = struct {
    text: []const u8,

    fn whitespace(self: *Scanner) void {
        while (self.text.len != 0 and std.ascii.isWhitespace(
            self.text[0],
        )) self.text = self.text[1..];
    }

    fn literal(self: *Scanner, value: []const u8) bool {
        if (!std.mem.startsWith(u8, self.text, value)) return false;
        self.text = self.text[value.len..];
        self.whitespace();

        return true;
    }

    fn integer(self: *Scanner) !i32 {
        self.whitespace();
        var end: usize = 0;

        if (self.text.len != 0 and (self.text[0] == '-' or self.text[0] == '+')) end = 1;

        while (end < self.text.len and std.ascii.isDigit(self.text[end])) : (end += 1) {}

        const value = std.fmt.parseInt(
            i32,
            self.text[0..end],
            10,
        ) catch return error.InvalidIndexedSounds;

        self.text = self.text[end..];

        return value;
    }
};

test "indexed sound list maps bottle WAX sound zero to BOTTLE.WAV" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB",
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(bytes);
    const table = try Table.parse(a, try archive.find("SOUNDS.LST", 0));
    defer table.deinit(a);

    try std.testing.expectEqual(@as(usize, 14), table.entries.len);
    const request = try table.request(0, 7, .{ .x = 132.31, .y = 4.25, .z = 87.37 });

    try std.testing.expectEqualStrings("BOTTLE.WAV", request.basename);
    try std.testing.expectEqual(@as(?i32, 64), request.priority);
    try std.testing.expectEqual(@as(?i32, 127), request.volume);
    try std.testing.expectEqual(@as(?RequestFlags, .{}), request.flags);
    try std.testing.expectEqual(@as(?usize, 7), request.sector);
    try std.testing.expectError(
        error.InvalidIndexedSoundIndex,
        table.request(14, 7, .{ .x = 0, .y = 0, .z = 0 }),
    );
}

test "indexed sound parsing rejects unsafe slots and retains priority mapping" {
    const a = std.testing.allocator;

    try std.testing.expectError(
        error.MissingIndexedSound,
        Table.parse(a, "NUM SOUNDS: 2\n0 M BOTTLE.WAV\n"),
    );

    try std.testing.expectError(
        error.InvalidIndexedSoundIndex,
        Table.parse(a, "NUM SOUNDS: 1\n1 M BOTTLE.WAV\n"),
    );

    try std.testing.expectError(error.InvalidIndexedSounds, Table.parse(a, "NUM SOUNDS: -1\n"));

    const table = try Table.parse(a, "NUM SOUNDS: 4\n3 X a.wav\n2 L b.wav\n1 H c.wav\n0 M d.wav\n");
    defer table.deinit(a);

    for (table.entries, [_]u8{
        64,
        107,
        1,
        1,
    }) |entry, priority| try std.testing.expectEqual(priority, entry.priority);
}
