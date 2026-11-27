//! The first-person weapon: where it sits on screen and how it is clipped.
//!
//! Its size comes from the current frame's first cell, not from the
//! costume's initial bounding box, so a sequence that changes cell size
//! changes the weapon's footprint. The slide of the status panel is applied
//! before positioning.

const std = @import("std");

const walls = @import("backends/software/walls.zig");
const hud_module = @import("hud.zig");

pub const scope_size = @divTrunc(640 * 0x35, 0x140);

pub const scope_fov = 0x111;

pub const Options = struct {
    sector_light: i32,
    lighting: walls.Lighting,
    movement_offset: [2]i32 = .{ 0, 0 },
    aim_offset: [2]i32 = .{ 0, 0 },
    aim_weight: i32 = 0,
    scope: bool = false,
    reloading: bool = false,
    three_d: bool = false,
};

pub fn draw(pixels: []u8, hud: *hud_module.Hud, options: Options) !void {
    if (pixels.len != 640 * 480) return error.InvalidWeaponFramebuffer;

    const rect = try position(hud, options) orelse return;
    const node = hud.weapon orelse return;
    const costume = node.costume orelse return error.MissingWeaponCostume;
    const frame = try costume.select(node.playback.choreography, node.playback.frame, 0, 0);
    const light = nearest(@as(f32, @floatFromInt(options.sector_light)) + @as(f32, 0.5));
    const translation = try lightTable(options.lighting, light);

    try hud_module.blitMapped(
        pixels,
        640,
        480,
        costume,
        frame,
        rect,
        .{ .width = 640, .height = 440 },
        translation,
        hud.blend_table,
    );
}

pub fn position(hud: *hud_module.Hud, options: Options) !?hud_module.Rect {
    const node = hud.weapon orelse return null;
    const costume = node.costume orelse return error.MissingWeaponCostume;
    const frame = try costume.select(node.playback.choreography, node.playback.frame, 0, 0);
    if (frame.parts.len == 0) return error.MissingWeaponFramePart;

    const cell = costume.cells[frame.parts[0].cell];
    var x: i32 = 640 / 2;
    var y: i32 = (480 - 440) / 2 + 440;

    if (!options.three_d and hud.panel.slide != hud.panel.maximum) y +%= hud.panel.rect.height +% 1;

    if (node.playback.flags & 2 == 0) {
        const aim = if (options.scope and node.slide == node.maximum and !options.reloading) [2]i32{
            0,
            0,
        } else options.aim_offset;

        x +%= @divTrunc(
            options.aim_weight *% aim[0] +% options.movement_offset[0] *% (100 -% options.aim_weight),
            100,
        );

        y +%= @divTrunc(
            options.aim_weight *% aim[1] +% options.movement_offset[1] *% (100 -% options.aim_weight),
            100,
        );
    }

    y +%= ((0x10000 -% node.slide) *% @as(i32, @intCast(cell.height))) >> 16;
    node.rect = .{ .x = x, .y = y, .width = @intCast(cell.width), .height = @intCast(cell.height) };

    return node.rect;
}

pub fn scopeRect(hud: *hud_module.Hud, options: Options, offset: [2]i32) !?hud_module.Rect {
    if (!options.scope or options.reloading) return null;

    const node = hud.weapon orelse return null;
    if (node.slide != node.maximum) return null;

    const anchor = try position(hud, options) orelse return null;
    const x = @max(0, anchor.x +% offset[0] -% @divTrunc(scope_size, 2));
    const y = @max(0, anchor.y +% offset[1] -% @divTrunc(scope_size, 2));

    return .{
        .x = x,
        .y = y,
        .width = @min(scope_size, 640 -% x),
        .height = @min(scope_size, 440 -% y),
    };
}

pub fn composeScope(pixels: []u8, scope_pixels: []const u8, rect: hud_module.Rect) !void {
    if (pixels.len != 640 * 480 or scope_pixels.len != scope_size * scope_size) return error.InvalidScopeFramebuffer;
    if (rect.width <= 0 or rect.height <= 0) return;
    if (rect.x < 0 or rect.y < 0 or rect.x > 640 - rect.width or rect.y > 440 - rect.height or rect.width > scope_size or rect.height > scope_size) return error.InvalidScopeRectangle;

    for (0..@intCast(rect.height)) |y| {
        const target: usize = @intCast((rect.y + @as(i32, @intCast(y))) * 640 + rect.x);
        @memcpy(
            pixels[target..][0..@intCast(rect.width)],
            scope_pixels[y * scope_size ..][0..@intCast(rect.width)],
        );
    }
}

pub fn lightTable(lighting: walls.Lighting, sector_light: i32) !?[]const u8 {
    const map = lighting.color_map orelse return null;
    if (map.len < 32 * 256) return error.InvalidColorMap;

    const ambient = sector_light +% lighting.ambient_bias;
    if (ambient > 30) return null;

    var depth_light: i32 = 0;

    if (lighting.force_depth != 0 or (lighting.depth_map != null and lighting.depth_strength != 0)) {
        const depth = lighting.depth_map orelse return error.MissingDepthMap;
        const candidate = ((lighting.depth_strength -% @as(
            i32,
            depth[0],
        )) -% lighting.depth_bias) +% 31;

        if (candidate > 0) depth_light = candidate;
    }

    const minimum = (ambient >> 2) +% (ambient >> 3) +% (ambient >> 1);
    const light = @max(0, @max(minimum, @max(depth_light, ambient)));
    if (light > 30) return null;

    const offset: usize = @intCast((31 - light) * 256);

    return map[offset..][0..256];
}

fn nearest(value: f32) i32 {
    const floor = @floor(value);
    var result: i32 = @intFromFloat(floor);
    if (value - floor > 0.5 or (value - floor == 0.5 and result & 1 != 0)) result += 1;

    return result;
}

test {
    _ = @import("weapon_reference_test.zig");
    _ = @import("weapon_pose.zig");
}
