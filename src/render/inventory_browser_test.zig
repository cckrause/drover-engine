//! The inventory strip: layout, the timeout, the artwork and the counts.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const fixtures = @import("../testing/fixtures.zig");
const read = fixtures.read;
const lab = @import("../assets/lab.zig");
const inventory = @import("../player/inventory.zig");
const hud = @import("hud.zig");

fn rect(value: hud.Rect) [4]i32 {
    return .{ value.x, value.y, value.width, value.height };
}

test "inventory browser layout timeout artwork and count pixels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Frame = struct {
        now: u32,
        before: struct { cursor: usize, opened: bool },
        inventory: []struct { slot: usize, name: []const u8, count: i32, no_show: bool },
        cursor: usize,
        opened: bool,
        initialized: bool,
        restore_frames: u32,
        changed_at: u32,
        was_open: bool,
        selected: i32,
        count: i32,
        rects: [3][4]i32,
        bounds: [4]i32,
        sha256: []const u8,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        blend: []const u8,
        frames: []Frame,
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/inventory-browser-reference.json"),
        .{},
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "0b98e3bd57efd293ac3c206bf85fa4c4984dad1d55ed6767b9a78b507b879200",
        corpus.results_sha256,
    );

    var archives: [3]lab.Archive = undefined;

    for ([_][]const u8{
        "OUTLAWS",
        "OLOBJ",
        "OLWEAP",
    }, &archives) |name, *archive| archive.* = try lab.Archive.init(
        try read(a, try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name})),
    );

    var host = try hud.Hud.init(a, &archives, 0, false);
    host.blend_table = try read(a, corpus.blend);
    const pixels = try a.alloc(u8, 640 * 480);

    for (corpus.frames, 0..) |frame, index| {
        errdefer std.debug.print("inventory browser frame{d} time{d}\n", .{ index, frame.now });
        var items: inventory.Inventory = .{
            .browse_cursor = frame.before.cursor,
            .browsing = frame.before.opened,
        };

        for (frame.inventory) |owned| {
            const definition = try inventory.Definition.load(a, &archives, owned.name);
            try std.testing.expectEqual(owned.no_show, definition.no_show);
            items.slots[owned.slot] = .{ .definition = definition, .count = owned.count };
        }

        host.now = frame.now;
        try host.browser.advance(frame.now);
        @memset(pixels, 91);
        try host.browser.draw(&host, &items, pixels);

        try std.testing.expectEqual(frame.cursor, items.browse_cursor);
        try std.testing.expectEqual(frame.opened, items.browsing);
        try std.testing.expectEqual(frame.initialized, host.browser.initialized);
        try std.testing.expectEqual(frame.restore_frames, host.browser.restore_frames);
        try std.testing.expectEqual(frame.changed_at, host.browser.changed_at);
        try std.testing.expectEqual(frame.was_open, host.browser.was_open);
        try std.testing.expectEqual(frame.selected, host.browser.cursor);
        try std.testing.expectEqual(frame.count, host.browser.count);

        for (frame.rects, host.browser.rects) |expected, actual| try std.testing.expectEqualDeep(
            expected,
            rect(actual),
        );

        try std.testing.expectEqualDeep(frame.bounds, rect(host.browser.bounds));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pixels, &digest, .{});

        if (!std.mem.eql(u8, frame.sha256, &std.fmt.bytesToHex(digest, .lower))) {
            const reference = try read(
                a,
                try std.fmt.allocPrint(a, "testdata/inventory-browser-{d}.bin", .{frame.now}),
            );

            var differences: usize = 0;

            for (pixels, reference, 0..) |actual, expected, pixel| if (actual != expected) {
                if (differences < 20) std.debug.print(
                    "pixel{d},{d} expected{d} actual{d}\n",
                    .{ pixel % 640, pixel / 640, expected, actual },
                );

                differences += 1;
            };

            std.debug.print("different pixels{d}\n", .{differences});
        }

        try std.testing.expectEqualStrings(frame.sha256, &std.fmt.bytesToHex(digest, .lower));
    }
}
