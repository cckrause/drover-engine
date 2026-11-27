//! A script consuming the selected inventory item, including a mismatched item id.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const inf = @import("inf.zig");
const inventory = @import("../player/inventory.zig");
const lab = @import("../assets/lab.zig");
const level_module = @import("../assets/level.zig");

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "INF consumes the selected handle including mismatched USE_ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        layout: []struct { slot: usize, name: []const u8, count: i32 },
        cases: []struct {
            selected: usize,
            flags: u32,
            supplied: u32,
            samples: []struct { flags: u32, selected: usize, slots: []usize },
        },
    };
    const fixture = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/inf-inventory-reference.json"), .{})).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.executable_sha256);
    try std.testing.expectEqualStrings("5d4b8f1b92bd634feffe568bd1f008e2c767880fafbc7fb77ea0fbe5d8e31dec", fixture.results_sha256);
    var archives: [3]lab.Archive = undefined;
    for ([_][]const u8{ "OUTLAWS", "OLOBJ", "OLWEAP" }, &archives) |name, *archive| {
        archive.* = try lab.Archive.init(try read(a, try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name})));
    }
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    for (fixture.cases) |case| {
        var owned: inventory.Inventory = .{ .selected = case.selected };
        for (fixture.layout) |value| owned.slots[value.slot] = .{ .definition = try inventory.Definition.load(a, &archives, value.name), .count = value.count };
        var runtime: inf.Runtime = .{ .arena = std.heap.ArenaAllocator.init(a), .elevators = &.{}, .triggers = undefined, .classes = undefined, .inventory = &owned };
        try runtime.reserveLists();
        defer runtime.deinit();
        runtime.triggers = try runtime.arena.allocator().alloc(inf.Trigger, 1);
        runtime.triggers[0] = .{ .target = .{ .sector = 0 }, .flags = case.flags, .object_id = 101 };
        runtime.classes = try runtime.arena.allocator().alloc(inf.Class, 1);
        runtime.classes[0] = .{ .trigger = 0 };
        for (case.samples) |expected| {
            try runtime.event(&level, .{ .sector = 0, .mask = 0x20, .object_id = case.supplied, .now_ms = 0 });
            try runtime.flushQueued(&level, null, 0, &.{}, 0xf00000);
            try std.testing.expectEqual(expected.flags, runtime.triggers[0].flags);
            try std.testing.expectEqual(expected.selected, owned.selected);
            var present: [25]usize = undefined;
            var count: usize = 0;
            for (owned.slots[1..], 1..) |slot, index| if (slot != null) {
                present[count] = index;
                count += 1;
            };
            try std.testing.expectEqualSlices(usize, expected.slots, present[0..count]);
        }
    }
}
