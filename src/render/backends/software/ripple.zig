//! The ripple distortion for water surfaces: a 64x64 texture resampled by a
//! moving offset.
//!
//! Source and destination both use the renderer's rotated texture layout.
//! The offset arithmetic is allowed to overflow - that wrap is what makes
//! the ripple repeat.

const camera = @import("camera.zig");
const m = @import("math.zig");
const std = @import("std");

pub fn warp64(angles: *const camera.Angles, source: []const u8, output: *[4096]u8, ticks: u32) !void {
    if (source.len < 4096) return error.UnsupportedRippleTexture;
    const phase: i16 = @truncate(m.integer(m.mul(m.towardZero(@floatFromInt(ticks)), 4)));
    var row_offset: [64]i32 = undefined;
    var column_offset: [64]i32 = undefined;
    for (0..64) |index| {
        const angle = @as(i16, @intCast(index << 8)) +% phase;
        const value = angles.sinCos(angle);
        row_offset[index] = m.integer(m.mul(value.sin, 4));
        column_offset[index] = m.integer(m.mul(value.cos, 4));
    }
    for (0..64) |x| {
        for (0..64) |y| {
            const sx: u32 = @bitCast(column_offset[y] +% @as(i32, @intCast(x)));
            const sy: u32 = @bitCast(@as(i32, @intCast(y)) +% row_offset[x]);
            output[x * 64 + y] = source[((sx & 63) << 6) | (sy & 63)];
        }
    }
}

test "ripple pixels match the reference across timer phase and integer overflow" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/ripple-reference.json", allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);
    const Case = struct {
        ticks: u32,
        sha256: []const u8,
    };
    const parsed = try std.json.parseFromSlice(struct { executable_sha256: []const u8, cases: []Case }, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", parsed.value.executable_sha256);
    const angles = camera.Angles.init();
    var source: [4096]u8 = undefined;
    for (&source, 0..) |*value, i| value.* = @intCast((i % 64) * 3 + i / 64);
    for (parsed.value.cases) |case| {
        var output: [4096]u8 = undefined;
        try warp64(&angles, &source, &output, case.ticks);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&output, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, case.sha256, &hex)) std.debug.print("\nripple ticks{}: got{s} expected{s}\n", .{ case.ticks, hex, case.sha256 });
        try std.testing.expectEqualStrings(case.sha256, &hex);
    }
}
