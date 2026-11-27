//! The official patches, as a real installation had them: each level
//! includes the ones before it, so 2.0 implies 1.1.
//!
//! Patch archives go in front of the base archive, highest number first.
//! Asking for a patch whose archive is missing is an error - the flag asked
//! for it. Only the archives matter; the patches' loose files change nothing
//! the engine reads.

const std = @import("std");

const lab = @import("../assets/lab.zig");

const archives = [_]struct { level: Level, path: []const u8 }{
    .{ .level = .@"2.0", .path = "patches/2.0/OLPATCH2.LAB" },
    .{ .level = .@"1.1", .path = "patches/1.1/OLPATCH1.LAB" },
};

pub const Level = enum {
    none,

    @"1.1",

    @"2.0",

    pub const latest: Level = .@"2.0";

    pub fn parse(text: []const u8) !Level {
        return std.meta.stringToEnum(Level, text) orelse error.InvalidPatch;
    }
};

pub const Patches = struct {
    bytes: [archives.len][]u8 = undefined,
    list: [archives.len]lab.Archive = undefined,
    count: usize = 0,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, level: Level) !Patches {
        var self: Patches = .{};
        errdefer self.deinit(allocator);

        for (archives) |entry| {
            if (@intFromEnum(entry.level) > @intFromEnum(level)) continue;

            const bytes = std.Io.Dir.cwd().readFileAlloc(
                io,
                entry.path,
                allocator,
                .limited(64 * 1024 * 1024),
            ) catch |err| {
                std.log.err(
                    "cannot read {s}: {s}; install the patch archive there, or start with --patch none",
                    .{ entry.path, @errorName(err) },
                );

                return err;
            };

            self.bytes[self.count] = bytes;
            self.count += 1;
            self.list[self.count - 1] = try lab.Archive.init(bytes);
        }

        return self;
    }

    pub fn front(self: *const Patches) []const lab.Archive {
        return self.list[0..self.count];
    }

    pub fn deinit(self: *Patches, allocator: std.mem.Allocator) void {
        for (self.bytes[0..self.count]) |bytes| allocator.free(bytes);
        self.count = 0;
    }
};

fn within(part: []const u8, whole: []const u8) bool {
    return @intFromPtr(
        part.ptr,
    ) >= @intFromPtr(
        whole.ptr,
    ) and @intFromPtr(part.ptr) + part.len <= @intFromPtr(whole.ptr) + whole.len;
}

test "patch levels include the ones before them" {
    try std.testing.expectEqual(Level.@"2.0", Level.latest);
    try std.testing.expectEqual(Level.@"1.1", try Level.parse("1.1"));
    try std.testing.expectError(error.InvalidPatch, Level.parse("1.2"));

    const allocator = std.testing.allocator;
    var none = try Patches.load(allocator, std.testing.io, .none);
    defer none.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), none.front().len);

    var all = Patches.load(allocator, std.testing.io, .@"2.0") catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer all.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), all.front().len);

    const cd = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB",
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(cd);
    var system = try lab.Archive.init(cd);

    system.front = all.front();

    try std.testing.expect(within(try system.find("LOCAL.MSG", 0), all.bytes[0]));
    try std.testing.expect(within(try system.find("THERMOM.NWX", 0), all.bytes[1]));
    try std.testing.expect(within(try system.find("SYSPAL.PCX", 0), cd));
}
