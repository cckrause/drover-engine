//! The shade tables: for each light level, the palette entry nearest to a
//! darkened colour.
//!
//! Nearest means unweighted squared RGB distance plus the squared difference
//! of separately truncated brightness values. The comparison is strict, so
//! the first matching entry wins and an exact match stops the search. Row 0
//! is zero and the rest start as identity.

const std = @import("std");

const level = @import("../../../assets/level.zig");

pub fn build(palette: [256]u32, definitions: [16]?level.Shade) [4096]u8 {
    var result: [4096]u8 = undefined;
    @memset(result[0..256], 0);

    for (1..16) |row| {
        const output = result[row * 256 ..][0..256];

        for (output, 0..) |*value, i| value.* = @intCast(i);

        const shade = definitions[row] orelse continue;

        for (16..256) |i| {
            var color: u32 = 0;

            for (0..3) |channel| {
                const shift: u5 = @intCast(channel * 8);
                const base: i32 = @intCast((palette[i] >> shift) & 255);
                const target: i32 = shade.color[channel];
                const value = switch (shade.mode) {
                    .grayscale => @divTrunc(base *% shade.amount, 100),
                    .tint => base +% @divTrunc(shade.amount *% target, 100),
                    .light => base +% @divTrunc((target -% base) *% shade.amount, 100),
                };

                color |= @as(u32, @intCast(std.math.clamp(value, 0, 255))) << shift;
            }

            output[i] = nearest(&palette, color);
        }
    }

    return result;
}

fn nearest(palette: *const [256]u32, color: u32) u8 {
    const r: i32 = @intCast(color & 255);
    const g: i32 = @intCast((color >> 8) & 255);
    const b: i32 = @intCast((color >> 16) & 255);
    const brightness = @divTrunc(3 * r + 5 * g + 2 * b, 10);
    var best_distance: i32 = std.math.maxInt(i32);
    var best: u8 = 16;

    for (16..256) |i| {
        if (best_distance < 1) break;

        const p = palette[i];
        const pr: i32 = @intCast(p & 255);
        const pg: i32 = @intCast((p >> 8) & 255);
        const pb: i32 = @intCast((p >> 16) & 255);
        const dr = r - pr;
        const dg = g - pg;
        const db = b - pb;
        const dl = brightness - @divTrunc(3 * pr + 5 * pg + 2 * pb, 10);
        const distance = dl * dl + db * db + dg * dg + dr * dr;

        if (distance < best_distance) {
            best = @intCast(i);
            best_distance = distance;
        }
    }

    return best;
}

test "shade tables match allocation, modes and nearest-color routines" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/shades-reference.json",
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(bytes);
    const Case = struct {
        name: []const u8,
        palette: [256]u32,
        shades: [16]?level.Shade,
        sha256: []const u8,
    };

    const parsed = try std.json.parseFromSlice(
        struct { executable_sha256: []const u8, cases: []Case },
        allocator,
        bytes,
        .{},
    );

    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.executable_sha256,
    );

    for (parsed.value.cases) |case| {
        const table = build(case.palette, case.shades);
        var digest: [32]u8 = undefined;

        std.crypto.hash.sha2.Sha256.hash(&table, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);

        if (!std.mem.eql(
            u8,
            case.sha256,
            &hex,
        )) std.debug.print("\n{s}: got{s} expected{s}\n", .{ case.name, hex, case.sha256 });

        try std.testing.expectEqualStrings(case.sha256, &hex);
    }
}
