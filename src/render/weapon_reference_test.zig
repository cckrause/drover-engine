//! First-person weapon views, pixel for pixel.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const fixtures = @import("../testing/fixtures.zig");
const read = fixtures.read;
const lab = @import("../assets/lab.zig");
const inventory_module = @import("../player/inventory.zig");
const hud_module = @import("hud.zig");
const weapon = @import("weapon.zig");
const camera = @import("backends/software/camera.zig");

const Case = struct {
    name: []const u8,
    slot: usize,
    sequence: u32,
    cursor: u32,
    paused: bool,
    slide: i32,
    light: i32,
    move: [2]i32,
    aim: [2]i32,
    weight: i32,
    rect: [4]i32,
    pixels_file: []const u8,
    pixels_sha256: []const u8,
};

const ScopeCase = struct {
    offset: [2]i32,
    center: [2]i32,
    pixels_file: []const u8,
    pixels_sha256: []const u8,
};

test "first-person weapon views match the reference pixels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const document = try std.json.parseFromSlice(struct {
        executable_sha256: []const u8,
        blend_file: []const u8,
        color_map_file: []const u8,
        cases: []const Case,
        scope_projection: [8]u32,
        scope_cases: []const ScopeCase,
    }, a, try read(a, "testdata/weapon-view-reference.json"), .{});
    const fixture = document.value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.executable_sha256);
    var archives: [3]lab.Archive = undefined;
    inline for (.{ "OUTLAWS.LAB", "OLOBJ.LAB", "OLWEAP.LAB" }, 0..) |name, i|
        archives[i] = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/" ++ name));
    const blend = try read(a, fixture.blend_file);
    const color_map = try read(a, fixture.color_map_file);
    const pixels = try a.alloc(u8, 640 * 480);
    for (fixture.cases) |case| {
        errdefer std.debug.print("Weapon view {s} sequence{d} cursor{d}\n", .{ case.name, case.sequence, case.cursor });
        var hud = try hud_module.Hud.init(a, &archives, 0, false);
        defer hud.deinit();
        var inventory: inventory_module.Inventory = .{};
        inventory.slots[case.slot] = .{ .definition = try inventory_module.Definition.load(a, &archives, case.name), .count = 1 };
        inventory.selected_weapon = case.slot;
        try hud.update(&inventory, 100, 0, 0);
        const node = hud.weapon orelse return error.MissingWeaponCostume;
        node.slide = case.slide;
        node.playback.choreography = case.sequence;
        node.playback.frame = case.cursor;
        node.playback.flags = if (case.paused) 2 else 1;
        hud.blend_table = blend;
        for (pixels, 0..) |*pixel, i| pixel.* = @truncate((i % 640) * 3 + (i / 640) * 5);
        try weapon.draw(pixels, &hud, .{
            .sector_light = case.light,
            .lighting = .{ .force_depth = 0, .depth_bias = 0, .depth_strength = 0, .ambient_bias = 0, .ambient = 0, .ambient_min = 0, .color_map = color_map, .depth_map = null },
            .movement_offset = case.move,
            .aim_offset = case.aim,
            .aim_weight = case.weight,
        });
        try std.testing.expectEqual(case.rect, [4]i32{ node.rect.x, node.rect.y, node.rect.width, node.rect.height });
        const expected = try read(a, case.pixels_file);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(expected, &digest, .{});
        try std.testing.expectEqualStrings(case.pixels_sha256, &std.fmt.bytesToHex(digest, .lower));
        try std.testing.expectEqualSlices(u8, expected, pixels);
    }
    const angles = camera.Angles.init();
    var view = try camera.View.initFov(a, &angles, weapon.scope_size, weapon.scope_size, weapon.scope_fov);
    defer view.deinit(a);
    const projection = [_]u32{ @bitCast(view.focal), @bitCast(view.inv_focal), @bitCast(view.center_x), @bitCast(view.horizon), @bitCast(view.center_x_f), @bitCast(view.horizon_f), @bitCast(view.center_y), @bitCast(@as(f32, @floatFromInt(view.center_y))) };
    try std.testing.expectEqual(fixture.scope_projection, projection);
    var hud = try hud_module.Hud.init(a, &archives, 0, false);
    defer hud.deinit();
    var inventory: inventory_module.Inventory = .{};
    inventory.slots[3] = .{ .definition = try inventory_module.Definition.load(a, &archives, "IRIFLE"), .count = 1 };
    inventory.selected_weapon = 3;
    try hud.update(&inventory, 100, 0, 0);
    const node = hud.weapon orelse return error.MissingWeaponCostume;
    node.slide = 0x10000;
    node.playback.choreography = 20;
    node.playback.frame = 0;
    node.playback.flags = 1;
    const scope_pixels = try a.alloc(u8, weapon.scope_size * weapon.scope_size);
    for (scope_pixels, 0..) |*pixel, i| pixel.* = @truncate((i % weapon.scope_size) * 13 + (i / weapon.scope_size) * 7);
    for (fixture.scope_cases) |case| {
        errdefer std.debug.print("Scope offset {any}\n", .{case.offset});
        for (pixels, 0..) |*pixel, i| pixel.* = @truncate((i % 640) * 3 + (i / 640) * 5);
        const options: weapon.Options = .{
            .sector_light = 0,
            .lighting = .{ .force_depth = 0, .depth_bias = 0, .depth_strength = 0, .ambient_bias = 0, .ambient = 0, .ambient_min = 0, .color_map = color_map, .depth_map = null },
            .movement_offset = .{ 7, 3 },
            .aim_offset = .{ 11, -5 },
            .aim_weight = 100,
            .scope = true,
        };
        const rect = try weapon.scopeRect(&hud, options, case.offset) orelse return error.MissingScopeRectangle;
        try std.testing.expectEqual(case.center, [2]i32{ node.rect.x + case.offset[0], node.rect.y + case.offset[1] });
        try weapon.composeScope(pixels, scope_pixels, rect);
        const expected = try read(a, case.pixels_file);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(expected, &digest, .{});
        try std.testing.expectEqualStrings(case.pixels_sha256, &std.fmt.bytesToHex(digest, .lower));
        if (!std.mem.eql(u8, expected, pixels)) {
            for (pixels, expected, 0..) |actual, wanted, i| if (actual != wanted) {
                std.debug.print("Scope pixel ({d},{d}): expected{d}, actual{d}\n", .{ i % 640, i / 640, wanted, actual });
                break;
            };
            return error.ScopePixelMismatch;
        }
    }
}
