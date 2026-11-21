//! Enemies appearing and disappearing: where a spawned actor ends up, and
//! the sprite instance it starts with.
//!
//! The spawn point is nudged along primary adjoins; a solid wall anywhere
//! along that segment puts both the point and the sector back. New instances
//! start unbound.

const std = @import("std");
const level = @import("../assets/level.zig");
const nwx = @import("../assets/nwx.zig");
const collision = @import("../player/collision.zig");
const weapon = @import("../player/weapon.zig");
const physics = @import("physics.zig");
const Actor = @import("../render/objects.zig").Actor;

pub const Placement = struct { position: level.Vec3, sector: usize };

pub const CorpsePool = struct {
    actors: [30]?Actor = @splat(null),
    cursor: usize = 0,

    pub fn slots(game_type: u32) usize {
        return if (game_type == 4 or game_type == 5) 15 else 30;
    }

    pub fn reserve(self: *CorpsePool, context: anytype, count: usize) !?usize {
        for (0..count) |i| {
            const index = (self.cursor + i) % count;
            if (self.actors[index] == null) {
                self.cursor = index;
                return index;
            }
        }
        for (1..count) |i| {
            const index = (self.cursor + i) % count;
            if (!try context.visible(self.actors[index].?)) {
                self.actors[index] = null;
                self.cursor = index;
                return index;
            }
        }
        return null;
    }
};

const Crossing = enum { primary, height };

const WallRef = struct { sector: usize, wall: usize };

pub fn dropPlacement(world: physics.World, actor: Actor) !Placement {
    const desired = level.Vec3{ .x = f(@as(f64, actor.position.x) + 1.5), .y = actor.position.y, .z = f(@as(f64, actor.position.z) + 1.5) };
    const target_sector = try traverse(world, actor.sector, actor.position, desired, .primary, 0, 0);
    return if (target_sector) |sector| .{ .position = desired, .sector = sector } else .{ .position = actor.position, .sector = actor.sector };
}

pub fn corpse(actor: Actor, now: u32) !Actor {
    var playback: nwx.Playback = .{};
    try playback.select(try actor.sprite(), actor.choreography, now, null);
    try playback.advance(try actor.sprite(), 20, now);
    return .{
        .logic_name = "misc_CorpseDispatch",
        .costume = actor.costume,
        .logic_resource = actor.logic_resource,
        .sector = actor.sector,
        .position = actor.position,
        .yaw = 0,
        .flags = 0x8000454f,
        .secondary_flags = 0x800,
        .scale_x = 1,
        .scale_y = 1,
        .height = 1,
        .collision_radius = 1,
        .choreography = playback.choreography,
        .frame = playback.frame,
        .angle_offset = playback.angle_offset,
        .playback = playback,
    };
}

pub fn deathImpulse(world: physics.World, actor: Actor, state: *physics.State, random: *u32) !?i16 {
    var direction: i16 = 45;
    for (0..8) |_| {
        const radians = weapon.randomFloat(random, 0);
        const offset: i16 = @truncate(nearest(f(radians * 45.5112)));
        const sampled_angle = direction +% offset;
        const radius = f(weapon.randomFloat(random, 0) + 8.0);
        const trig = world.angles.sinCos(sampled_angle);
        const point = level.Vec3{
            .x = f(@as(f64, radius) * trig.sin + actor.position.x),
            .y = state.position.y,
            .z = f(@as(f64, radius) * trig.cos + actor.position.z),
        };
        const destination = try traverse(world, state.sector, state.position, point, .height, 1, -0x1p31);
        if (destination) |sector| {
            if (17.0 < @as(f64, world.level.sectors[actor.sector].floor.height) - world.level.sectors[sector].floor.height) {
                state.velocity.x = f(@as(f64, state.velocity.x) * 0.5);
                state.velocity.z = f(@as(f64, state.velocity.z) * 0.5);
                state.velocity.y = f(@as(f64, state.velocity.y) * 2.0);
                const push = world.angles.sinCos(direction);
                state.velocity.x = f(@as(f64, push.sin) * 30.0 + state.velocity.x);
                state.velocity.z = f(@as(f64, push.cos) * 30.0 + state.velocity.z);
                return direction;
            }
        }
        direction +%= 0x800;
    }
    return null;
}

fn traverse(world: physics.World, start: usize, from: level.Vec3, to: level.Vec3, mode: Crossing, up: f32, down: f32) !?usize {
    if (start >= world.level.sectors.len) return error.InvalidEnemySector;
    if (to.x - from.x == 0 and to.z - from.z == 0) return start;
    var arena = std.heap.ArenaAllocator.init(world.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const offsets = try a.alloc(usize, world.level.sectors.len + 1);
    offsets[0] = 0;
    for (world.level.sectors, 0..) |sector, i| offsets[i + 1] = offsets[i] + sector.walls.len;
    const seen = try a.alloc(bool, offsets[world.level.sectors.len]);
    @memset(seen, false);
    var current = start;
    var previous: f32 = -0x1p31;
    while (true) {
        var selected: ?WallRef = null;
        var distance: f32 = 0x1p31;
        const sector = world.level.sectors[current];
        for (sector.walls, world.scene.sectors[current].walls, 0..) |wall, state, index| {
            if (seen[offsets[current] + index]) continue;
            const hit = collision.intersection(.{ .x = from.x, .z = from.z }, .{ .x = to.x, .z = to.z }, sector.vertices[wall.v1], sector.vertices[wall.v2]) orelse continue;
            if (from.x == hit.x and from.z == hit.z and 0 <= (@as(f64, to.x) - from.x) * state.direction.z - (@as(f64, to.z) - from.z) * state.direction.x) continue;
            const dx = @abs(f(@as(f64, hit.x) - from.x));
            const dz = @abs(f(@as(f64, hit.z) - from.z));
            const full = (@as(f64, dx) - @as(f64, @min(dx, dz)) * 0.25 * 2.0) + dz;
            const stored = f(full);
            if (full < distance and previous < stored) {
                distance = stored;
                selected = .{ .sector = current, .wall = index };
            }
        }
        const selected_wall = selected orelse return current;
        mark(world, offsets, seen, selected_wall);
        const wall = sector.walls[selected_wall.wall];
        for (mirrors(wall)) |mirror| if (mirror) |first| {
            mark(world, offsets, seen, first);
            for (mirrors(world.level.sectors[first.sector].walls[first.wall])) |second| if (second) |value| mark(world, offsets, seen, value);
        };
        previous = distance;
        var next = wall.adjoin;
        if (mode == .height and wall.dadjoin >= 0) {
            if (next < 0) return error.InvalidEnemyPortal;
            if ((@as(f64, from.y) + to.y) * 0.5 < world.level.sectors[@intCast(next)].floor.height) next = wall.dadjoin;
        }
        if (next < 0) return null;
        current = @intCast(next);
        if (mode == .height) {
            const difference = @as(f64, world.level.sectors[current].floor.height) - world.level.sectors[start].floor.height;
            if (up < difference or difference < down) return null;
        }
    }
}

fn mirrors(wall: level.Wall) [2]?WallRef {
    return .{ if (wall.adjoin < 0) null else .{ .sector = @intCast(wall.adjoin), .wall = @intCast(wall.mirror) }, if (wall.dadjoin < 0) null else .{ .sector = @intCast(wall.dadjoin), .wall = @intCast(wall.dmirror) } };
}

fn mark(world: physics.World, offsets: []const usize, seen: []bool, wall: WallRef) void {
    _ = world;
    seen[offsets[wall.sector] + wall.wall] = true;
}

fn nearest(value: f32) i32 {
    const lower = @floor(value);
    const integer: i32 = @intFromFloat(lower);
    const fraction = value - lower;
    return integer + @as(i32, if (fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)) 1 else 0);
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
