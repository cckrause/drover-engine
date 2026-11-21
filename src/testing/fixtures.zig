//! File access for tests that check engine output against generated reference
//! fixtures.
//!
//! Neither the game data nor the fixtures live in this repository: `inputs/`
//! points at an installed copy of the game and `testdata/` at the generated
//! fixtures. A test that cannot find what it needs skips instead of failing,
//! so a fresh clone still runs the tests that stand on their own.

const std = @import("std");

/// Where generated reference fixtures are looked up.
pub const directory = "testdata";

/// Reads a file a test needs, skipping the test when it is not installed.
///
/// A path that already names a directory is used as given. A bare file name,
/// or a path a fixture stored for one of its sibling files, is looked up in
/// `directory`: fixtures record the tree they were generated in, which says
/// nothing about where the files sit here.
pub fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const local = if (isLocal(path)) path else try std.fmt.bufPrint(&buffer, directory ++ "/{s}", .{std.fs.path.basename(path)});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, local, allocator, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn isLocal(path: []const u8) bool {
    for ([_][]const u8{ directory ++ "/", "inputs/", "patches/" }) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

test "a fixture's own sibling path is looked up in the fixture directory" {
    try std.testing.expectError(error.SkipZigTest, read(std.testing.allocator, "somewhere/else/not-installed.bin"));
}
