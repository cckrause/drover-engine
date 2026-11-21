//! What an enemy can see: field of view, sampled rays and the navigation
//! points it picks.
//!
//! Each actor's head and collision disc are sampled. All random draws are
//! made whether or not they are needed - two actors in the same sector still
//! consume them - because the random stream is shared and its position
//! matters.

const std = @import("std");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const random = @import("../player/weapon.zig");
const visibility = @import("../audio/occlusion.zig");
const Vec2 = level_module.Vec2;
const Vec3 = level_module.Vec3;

pub const Subject = struct {
    position: Vec3,
    sector: usize,
    height: f32,
    radius: f32,
    yaw: i16,
    flags: u32,
    secondary_flags: u32,

    pub fn fromActor(actor: @import("../render/objects.zig").Actor) Subject {
        return .{ .position = actor.position, .sector = actor.sector, .height = actor.height, .radius = actor.collision_radius, .yaw = actor.yaw, .flags = actor.flags, .secondary_flags = actor.secondary_flags };
    }
};

pub const World = struct {
    allocator: std.mem.Allocator,
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    angles: *const camera.Angles,
    visibility: *visibility.Cache,
    random: *u32,
    now: u32,
};

pub const RandomPoint = struct { point: Vec2, yaw: i16 };

pub fn visible(world: World, from: Subject, to: Subject) !bool {
    return world.visibility.actorsVisible(world.level, world.scene, world.angles, .{ .position = from.position, .sector = from.sector, .height = from.height, .radius = from.radius }, .{ .position = to.position, .sector = to.sector, .height = to.height, .radius = to.radius }, world.random, world.now);
}

pub fn visibleAtHeight(world: World, from: Subject, to: Subject, height: f32) !bool {
    const from_y = if (@as(u32, @bitCast(from.height)) < 0x80000001)
        f(@as(f64, from.position.y) + height)
    else
        try world.scene.ceilingHeight(world.level, from.sector, point(from.position));
    const to_y = if (@as(u32, @bitCast(to.height)) < 0x80000001)
        f((@as(f64, to.position.y) + to.height) - 1)
    else
        try world.scene.ceilingHeight(world.level, to.sector, point(to.position));
    return world.visibility.visible(world.level, world.scene, world.angles, from.sector, to.sector, .{ .x = from.position.x, .y = from_y, .z = from.position.z }, .{ .x = to.position.x, .y = to_y, .z = to.position.z }, world.now);
}

pub fn fieldOfView(from: Subject, to: Subject, source_light: i32, target_light: i32, fov_dist: f32, fov: i16, kill_dist: f32, last_seen: u32, now: u32, player_visible: bool, kill: *bool) i16 {
    const dist = f(distance(point(from.position), point(to.position)));
    if (from.secondary_flags & 0x200000 != 0 and to.secondary_flags & 0x10 != 0 and dist < kill_dist) kill.* = true;
    if (!(dist < fov_dist)) return 0;
    const yaw = angle(f(@as(f64, to.position.x) - from.position.x), f(@as(f64, to.position.z) - from.position.z));
    const difference: i32 = @intCast(@abs(@as(i32, angleDifference(from.yaw, yaw))));
    const elapsed = now -% last_seen;
    if (!(difference < fov or elapsed < 10000)) return 0;
    var range = fov_dist;
    if (elapsed > 10000) range = f(((@as(f64, @floatFromInt(@as(i32, fov) - difference)) * @as(f64, @as(f32, 0.021972613))) / (@as(f64, @floatFromInt(fov)) * @as(f64, @as(f32, 0.021972613)))) * range);
    if (!(dist < range)) return 0;
    range = f(@as(f64, to.height) * @as(f64, @as(f32, 0.15384616)) * range);
    if (!(dist < range)) return 0;
    const light = if (to.flags & 0x10 != 0) 31 else target_light;
    var intensity = f(@as(f64, @floatFromInt(light)) * @as(f64, @as(f32, 0.04347826)));
    if (light < 10) intensity = f(@as(f64, intensity) * @as(f64, @as(f32, 0.8)));
    if (light < source_light and source_light - light > 4) intensity = f(@as(f64, intensity) * 0.5);
    intensity = std.math.clamp(intensity, 0.03, 1);
    range = f(@as(f64, intensity) * range);
    if (player_visible) range = f(@as(f64, range) * 10);
    return if (dist < range) (if (yaw == 0) 1 else yaw) else 0;
}

pub fn randomPoint(angles: *const camera.Angles, state: *u32, origin: Vec2, first: i16, last: i16, minimum: f32, maximum: f32) RandomPoint {
    const a: i16 = @intCast(@as(u16, @bitCast(first)) & 0x3fff);
    const b: i16 = @intCast(@as(u16, @bitCast(last)) & 0x3fff);
    const low = @min(a, b);
    const high = @max(a, b);
    const span = f(@as(f64, @floatFromInt(angleDifference(low, high))) * @as(f64, @as(f32, 0.021972613)));
    const offset_angle: i16 = @truncate(nearest(f(random.randomFloat(state, span) * @as(f64, @as(f32, 45.5112)))));
    const yaw = low +% offset_angle;
    const radius = f(random.randomFloat(state, f(@as(f64, maximum) - minimum)) + minimum);
    return .{ .point = offset(angles, origin, radius, yaw), .yaw = yaw };
}

pub fn navigate(world: World, start_sector: usize, start: Vec3, end: Vec3, maximum_step: f32, maximum_drop: f32) !?usize {
    var ray = world.visibility.ray(world.level, world.scene, point(start), point(end));
    var sector = start_sector;
    const y = f((@as(f64, start.y) + end.y) * 0.5);
    while (ray.next(sector)) |hit| {
        const wall = world.level.sectors[hit.sector].walls[hit.index];
        if (wall.adjoin < 0) return null;
        const main: usize = @intCast(wall.adjoin);
        const next: usize = if (wall.dadjoin >= 0 and y < world.level.sectors[main].floor.height) @intCast(wall.dadjoin) else main;
        const difference = @as(f64, world.level.sectors[next].floor.height) - world.level.sectors[start_sector].floor.height;
        if (maximum_step < difference or difference < maximum_drop) return null;
        sector = next;
    }
    return sector;
}

pub fn distance(a: Vec2, b: Vec2) f64 {
    const dx = @abs(f(@as(f64, b.x) - a.x));
    const dz = @abs(f(@as(f64, b.z) - a.z));
    return (@as(f64, dx) - @as(f64, @min(dx, dz)) * 0.25 * 2) + dz;
}

pub fn point(value: Vec3) Vec2 {
    return .{ .x = value.x, .z = value.z };
}

pub fn offset(angles: *const camera.Angles, value: Vec2, radius: f32, yaw: i16) Vec2 {
    const trig = angles.sinCos(yaw);
    return .{ .x = f(@as(f64, radius) * trig.sin + value.x), .z = f(@as(f64, radius) * trig.cos + value.z) };
}

pub fn angle(x: f32, z: f32) i16 {
    const radians = f(std.math.atan2(@as(f64, x), @as(f64, z)));
    const result: i32 = @intFromFloat(@as(f64, radians) * @as(f64, @bitCast(@as(u64, 0x3fc45f306dcc48b9))) * 16384);
    return @intCast(@as(u32, @bitCast(result)) & 0x3fff);
}

pub fn angleDifference(first: i16, second: i16) i16 {
    const delta = (second & 0x3fff) - (first & 0x3fff);
    return if (@abs(@as(i32, delta)) <= 0x2000) delta else if (delta < 0) delta + 0x4000 else delta - 0x4000;
}

pub fn nearest(value: f64) i32 {
    if (!std.math.isFinite(value) or value >= 2147483647.5 or value < -2147483648.5) return std.math.minInt(i32);
    const lower = @floor(value);
    const fraction = value - lower;
    const base: i64 = @intFromFloat(lower);
    return @intCast(base + @as(i64, if (fraction > 0.5 or (fraction == 0.5 and base & 1 != 0)) 1 else 0));
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
