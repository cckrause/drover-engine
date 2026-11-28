//! The in-level popup: keyboard and mouse ordering, and its pixels, palettes and cursor.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const pcx = @import("../assets/pcx.zig");
const menu = @import("mission_menu.zig");

fn hashEquals(bytes: []const u8, expected: []const u8) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(hash, .lower));
}

test "popup keyboard and mouse ordering matches the reference" {
    var control = menu.Control.init(.mission, .{ .x = 100, .y = 165, .buttons = .{ .left = true } });
    control.update(.{ .x = 100, .y = 165, .buttons = .{ .left = true } }, .none, 61, 52);

    try std.testing.expectEqual(@as(?i32, 2), control.result);
    try std.testing.expectEqualStrings("RIFLOUT.WAV", control.takeSound().?);
    try std.testing.expect(control.takeResult(.{}) == null);

    control.presented = true;

    try std.testing.expect(control.takeResult(.{ .left = true }) == null);
    try std.testing.expect(control.takeResult(.{ .right = true }) == null);
    try std.testing.expectEqual(@as(?i32, 2), control.takeResult(.{}));

    control = menu.Control.init(.mission, .{});
    control.update(.{}, .up, 61, 52);

    try std.testing.expectEqual(@as(i32, 6), control.selected);
    try std.testing.expectEqualStrings("CHICKEN1.WAV", control.takeSound().?);

    control.update(.{}, .down, 61, 52);
    try std.testing.expectEqual(@as(i32, 0), control.selected);
    control.update(.{}, .tab, 61, 52);
    try std.testing.expectEqual(@as(i32, 1), control.selected);
    control.update(.{}, .back_tab, 61, 52);
    try std.testing.expectEqual(@as(i32, 0), control.selected);

    control.update(.{ .x = 900, .y = 113 }, .none, 61, 52);
    try std.testing.expectEqual(@as(i32, 1), control.selected);
    control.update(.{ .x = 900, .y = 425 }, .none, 61, 52);
    try std.testing.expectEqual(@as(i32, 1), control.selected);
    control.update(.{ .x = 900, .y = 373 }, .enter, 61, 52);

    try std.testing.expectEqual(@as(i32, 6), control.selected);
    try std.testing.expectEqual(@as(?i32, 1), control.result);

    control = menu.Control.init(.mission, .{});
    control.update(.{ .x = -100, .y = 400, .buttons = .{ .left = true } }, .escape, 61, 52);
    try std.testing.expectEqual(@as(?i32, 6), control.result);
    control = menu.Control.init(.quit, .{});
    control.update(.{}, .escape, 228, 52);
    try std.testing.expectEqual(@as(?i32, -1), control.result);
}

test "CD1 popup pixels palettes and cursor match the reference" {
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
    const archive = try lab.Archive.init(bytes);
    const background = try pcx.decode(a, try archive.find("NMM.PCX", 0x50424d50));
    defer background.deinit(a);
    var screen = try menu.Popup.init(a, archive, background.pixels, background.palette, .{});
    defer screen.deinit(a);
    const pixels = try a.alloc(u8, menu.width * menu.height);
    defer a.free(pixels);

    try std.testing.expectEqualStrings("RESUME", screen.mission_labels[0]);
    try std.testing.expectEqualStrings("EXIT", screen.mission_labels[6]);
    try std.testing.expectEqual(@as(i32, 61), screen.top());
    try std.testing.expectEqual(@as(i32, 52), screen.spacing());

    try hashEquals(
        &menu.backgroundMap(background.palette, screen.palette),
        "3dddf0865d7ab8f8836f416e0c344671b2a237bcd583af6c1b5dcf9dd67badc3",
    );

    const keys = [_]menu.Key{ .none, .up, .down, .tab, .back_tab, .escape };
    const times = [_]u32{ 0, 95, 100, 195, 200, 205 };
    const selected = [_]i32{ 0, 6, 0, 1, 0, 0 };
    const hashes = [_][]const u8{
        "f909607dc8c0b24d2f1148ac102e8199891e9a3e6219d103a04f6dfd9284cd21",
        "f909607dc8c0b24d2f1148ac102e8199891e9a3e6219d103a04f6dfd9284cd21",
        "3ae26716d162ac0e2441f9fcd0098c72db4e2013ad78406242bf8b2a5eb2c396",
        "f909607dc8c0b24d2f1148ac102e8199891e9a3e6219d103a04f6dfd9284cd21",
        "86597cff39110db196d936df3a9dc866961cbe3573139c9251c570955c8d49d3",
        "f909607dc8c0b24d2f1148ac102e8199891e9a3e6219d103a04f6dfd9284cd21",
    };

    const palettes = [_][]const u8{
        "fed43213d2ec1a870065ba23cc9adcb265115349a0451cd686b2732e1b1e960e",
        "ac6cd8d75675788b214fdb8981309ccba416ed5a511cb7ec976e036d7f41b89d",
        "a856c7b01e8a0f53f2a6a24825ed31224ff80fd88a2ba1000129217c3f2ad83f",
        "63a5ceea7508de43c022d4d51c24467496940d70832fd35f6e15c770f29b4875",
        "fed43213d2ec1a870065ba23cc9adcb265115349a0451cd686b2732e1b1e960e",
        "63a5ceea7508de43c022d4d51c24467496940d70832fd35f6e15c770f29b4875",
    };

    for (keys, times, selected, hashes, palettes) |key, time, selection, hash, palette_hash| {
        try screen.frame(pixels, .{}, key);
        try std.testing.expectEqual(selection, screen.control.selected);
        try hashEquals(pixels, hash);
        const palette = screen.paletteAt(time);
        try hashEquals(std.mem.asBytes(&palette), palette_hash);
    }

    screen.open(.quit, .{});

    try std.testing.expectEqual(@as(i32, 150), screen.top());
    try std.testing.expectEqual(@as(i32, 228), screen.firstRow());

    try screen.frame(pixels, .{}, .none);
    try hashEquals(pixels, "6f5878015dcf9e5c78d7d2180de1162790abd999c595e45476ce84c15027e8ff");
    try screen.frame(pixels, .{}, .down);
    try screen.frame(pixels, .{}, .enter);
    try hashEquals(pixels, "5740f488018215173c160f2875531750592881d3105de4556edca9ccf39daa04");

    screen.open(.mission, .{});
    try screen.frame(pixels, .{ .x = 320, .y = 240 }, .none);
    try hashEquals(pixels, "f1c25c3b09339f77ef80b0353025332cf9f1e0fc6cdf0af7cda4c91fb6bb96fa");
    try screen.frame(pixels, .{ .x = 639, .y = 479 }, .none);
    try hashEquals(pixels, "248e89ba43d5869263d493c02b703507c1fad7c0c16c1c37758ad55a0171e590");
    try screen.frame(pixels, .{ .x = 0, .y = 240 }, .escape);
    try hashEquals(pixels, "de972e284501291e9ee9fad0600c0e3cebd8d075b25ff3ad33a81eaa43dc2551");
}
