//! Enemy movement: velocity, damping and the commit that moves the actor.
//!
//! Goal, trial, cached logic position and the actor's own position are
//! separate on purpose - the commit is what reconciles them, and skipping it
//! leaves an enemy that thinks it moved.

const std = @import("std");

const level = @import("../assets/level.zig");
const collision = @import("../player/collision.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene = @import("../render/scene.zig");
const Actor = @import("../render/objects.zig").Actor;
const Vec3 = level.Vec3;

pub const World = struct {
    level: *const level.Level,
    scene: *const scene.Scene,
    angles: *const camera.Angles,
    actors: collision.Actors,
    contact_stack: ?@import("contact_stack.zig").Tracking = null,
    enemy_stack: ?@import("contact_stack.zig").Enemy = null,
};

pub const Config = struct {
    walk_speed: f32,
    run_speed: f32,
    walk_chor: u32,
    run_chor: u32,
    step_height: f32,
    drop_height: f32,
};

pub const State = struct {
    velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    goal: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    move_speed: f32 = 0,
    move_complete: bool = false,
    movement_disabled: bool = true,
    landed: bool = false,
    movement_mode: u32 = 0,
    floor_cache: f32 = 0,
    trial: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    sampled: bool = false,
    desired_yaw: i16 = 0,
    blocked_until: u32 = 0,
    position: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    sector: usize = 0,
    yaw: i16 = 0,

    pub fn sample(self: *State, actor: Actor, velocity: Vec3) void {
        self.sampled = true;
        self.position = actor.position;
        self.sector = actor.sector;
        self.yaw = actor.yaw;
        self.velocity = velocity;
    }
};

pub fn damp(actor: Actor, state: *State, world: World, dt: f32) !bool {
    const moving = nonzero(state.velocity);
    const floor = try height(world, state.sector, state.position, false, false);
    const ceiling = try height(world, state.sector, state.position, true, false);

    if (world.enemy_stack) |stack| stack.damp(ceiling);

    const grounded = state.position.y <= floor;
    const above_ceiling = ceiling <= f(@as(f64, actor.height) + state.position.y);
    var damping: f32 = undefined;

    if (grounded or above_ceiling) {
        state.velocity.y = @max(state.velocity.y, 0);
        if (above_ceiling) state.velocity.y = f(@as(f64, state.velocity.y) - @as(f64, dt) * 40.0);
        damping = f(@as(f64, dt) * 4.0);
    } else {
        state.velocity.y = f(@as(f64, state.velocity.y) - @as(f64, dt) * 40.0);
        damping = f(@as(f64, dt) * 0.5);
    }

    if (@abs(state.velocity.x) != 0 or @abs(state.velocity.z) != 0) {
        state.velocity.x = f(@as(f64, state.velocity.x) * (1.0 - @as(f64, damping)));
        state.velocity.z = f((1.0 - @as(f64, damping)) * state.velocity.z);
    }

    if (@abs(state.velocity.x) < 0.1) state.velocity.x = 0;

    if (@abs(state.velocity.z) < 0.1) state.velocity.z = 0;

    return moving;
}

pub fn move(
    actor: *Actor,
    state: *State,
    health: *f32,
    previous_mode: u32,
    current_chor: u8,
    config: Config,
    world: World,
    dt: f32,
    now: u32,
    next_tick: *u32,
    context: anytype,
) !u32 {
    var result: u32 = 0;
    var dx: f32 = 0;
    var dz: f32 = 0;
    var dy: f32 = 0;

    if (!state.movement_disabled) {
        if (state.movement_mode == 1) {
            state.move_speed = config.run_speed;
            if (previous_mode & 0x7fffffff != 6 and current_chor != config.run_chor) try context.select(config.run_chor);
        } else if (state.movement_mode == 2) {
            state.move_speed = config.walk_speed;
            if (previous_mode & 0x7fffffff != 6 and current_chor != config.walk_chor) try context.select(config.walk_chor);
        }

        const gx = if (state.goal.x != state.position.x) f(
            @as(f64, state.goal.x) - state.position.x,
        ) else @as(f32, 0);

        const gz = if (state.goal.z != state.position.z) f(
            @as(f64, state.goal.z) - state.position.z,
        ) else @as(f32, 0);

        if (@abs(gx) == 0 and @abs(gz) == 0) {
            result = 2;
        } else {
            state.desired_yaw = angle(gx, gz);

            const difference = angleDifference(state.yaw, state.desired_yaw);
            const max_turn: i16 = @truncate(nearest(f(@as(f64, dt) * 270.0 * 45.5112)));
            const turn: i32 = @as(i16, if (difference < 0) -%max_turn else max_turn);
            const magnitude: i32 = @intCast(@abs(@as(i32, difference)));
            var change = magnitude;

            if (turn <= magnitude) {
                change = -magnitude;
                if (-turn == magnitude or -magnitude < turn) change = turn;
            }

            state.yaw +%= @truncate(change);
            const trig = world.angles.sinCos(state.yaw);

            if (@abs(
                gx,
            ) != 0 and @abs(trig.sin) != 0) dx = f(@as(f64, state.move_speed) * trig.sin);

            if (@abs(
                gz,
            ) != 0 and @abs(trig.cos) != 0) dz = f(@as(f64, state.move_speed) * trig.cos);

            dx = clampDisplacement(f(@as(f64, dx) * dt), @abs(gx));
            dz = clampDisplacement(f(@as(f64, dz) * dt), @abs(gz));
        }
    }

    const floor = @max(world.level.sectors[state.sector].floor.height, state.floor_cache);

    if (1.0 < @as(f64, actor.position.y) - floor) {
        dx = f(@as(f64, dx) * 0.125);
        dz = f(@as(f64, dz) * 0.125);
    }

    if (nonzero(state.velocity)) {
        dy = f(@as(f64, state.velocity.y) * dt);
        dx = f(@as(f64, state.velocity.x) * dt + dx);
        dz = f(@as(f64, state.velocity.z) * dt + dz);
    }

    if (@abs(dx) != 0 or @abs(dy) != 0 or @abs(dz) != 0) {
        var desired = Vec3{
            .x = f(@as(f64, state.position.x) + dx),
            .y = f(@as(f64, state.position.y) + dy),
            .z = f(@as(f64, state.position.z) + dz),
        };

        state.trial = desired;
        const old = state.position;
        result = try resolve(actor, state, config, world, &desired);

        if (state.goal.x == state.position.x and state.goal.z == state.position.z) result = 2;

        const requested_distance = approximateDistance(.{ .x = 0, .z = 0 }, .{ .x = dx, .z = dz });
        const moved_distance = approximateDistance(
            .{ .x = old.x, .z = old.z },
            .{ .x = state.position.x, .z = state.position.z },
        );

        next_tick.* = @min(next_tick.*, state.blocked_until);

        if (state.blocked_until <= now and moved_distance < @as(
            f64,
            requested_distance,
        ) * 0.25 and @abs(dy) == 0) {
            result = 3;
            state.blocked_until = now +% 1000;
            next_tick.* = @min(next_tick.*, state.blocked_until);

            if (@abs(
                f(@as(f64, state.goal.x) - state.position.x),
            ) < 1 and @abs(f(@as(f64, state.goal.z) - state.position.z)) < 1) result = 2;
        }
    }

    if (state.move_complete and result == 2) result = 0;

    if (result == 2) {
        state.move_complete = true;
        state.movement_disabled = true;
    }

    const ceiling = try height(world, state.sector, state.position, true, true);

    if (ceiling < @as(f64, state.position.y) + actor.height) {
        state.position.y = f(@as(f64, ceiling) - actor.height);
        state.velocity.y = 0;
    }

    const lower = try height(world, state.sector, state.position, false, true);

    if (@as(f64, state.position.y) - 2.0 < lower) {
        if (state.position.y < lower) {
            const flags = world.scene.sectors[state.sector].flags;

            if (!flags.damage_high and !flags.floor_damage_high) {
                if (@as(
                    u32,
                    @bitCast(state.velocity.y),
                ) > 0xc247ffff) health.* = f(
                    @as(f64, health.*) - @as(f64, state.velocity.y) * -0.02,
                );
            } else health.* = f(@as(f64, health.*) - 1000.0);

            state.velocity.y = 0;
        }

        state.position.y = @max(state.position.y, lower);

        if (@as(u32, @bitCast(state.velocity.y)) > 0xc1c80000) {
            state.landed = true;
            state.velocity.y = 0;
        }
    }

    state.yaw = state.desired_yaw;

    return result;
}

pub fn commit(actor: *Actor, state: State) void {
    actor.yaw = state.yaw;

    if (actor.position.x != state.position.x or actor.position.y != state.position.y or actor.position.z != state.position.z or actor.sector != state.sector) {
        actor.position = state.position;
        actor.sector = state.sector;
    }
}

pub fn height(world: World, sector: usize, point: Vec3, ceiling: bool, x_first: bool) !f32 {
    if (sector >= world.level.sectors.len) return error.InvalidEnemySector;

    const state = world.scene.sectors[sector];
    if (!state.flags.sloped(ceiling)) return if (ceiling) world.level.sectors[sector].ceiling.height else world.level.sectors[sector].floor.height;

    const slope = (if (ceiling) state.ceiling_slope else state.floor_slope) orelse return error.MissingCollisionSlope;

    return if (x_first) f(
        (@as(
            f64,
            slope.constant,
        ) - @as(f64, slope.coeff_x) * point.x) - @as(f64, slope.coeff_z) * point.z,
    ) else f(
        (@as(
            f64,
            slope.constant,
        ) - @as(f64, slope.coeff_z) * point.z) - @as(f64, slope.coeff_x) * point.x,
    );
}

pub fn nonzero(v: Vec3) bool {
    return @abs(v.x) != 0 or @abs(v.y) != 0 or @abs(v.z) != 0;
}

pub fn approximateDistance(a: level.Vec2, b: level.Vec2) f32 {
    const x = @abs(f(@as(f64, b.x) - a.x));
    const z = @abs(f(@as(f64, b.z) - a.z));

    return f((@as(f64, x) - @as(f64, @min(x, z)) * 0.25 * 2.0) + z);
}

pub fn angle(x: f32, z: f32) i16 {
    const radians = f(std.math.atan2(@as(f64, x), @as(f64, z)));
    const factor: f64 = @bitCast(@as(u64, 0x3fc45f306dcc48b9));
    const result: i64 = @intFromFloat(@as(f64, radians) * factor * 16384.0);

    return @intCast(result & 0x3fff);
}

pub fn angleDifference(from: i16, to: i16) i16 {
    var difference = (@as(i32, to) & 0x3fff) - (@as(i32, from) & 0x3fff);
    if (@abs(difference) > 0x2000) difference += if (difference < 0) @as(i32, 0x4000) else -0x4000;

    return @intCast(difference);
}

fn resolve(actor: *Actor, state: *State, config: Config, world: World, desired: *Vec3) !u32 {
    const old = state.position;
    if (old.x == desired.x and old.y == desired.y and old.z == desired.z) return 0;

    state.position.y = desired.y;

    var velocity = state.velocity;
    var actors = world.actors;

    actors.allow_pickups = false;
    const solved = try collision.resolveWithOptions(world.level, world.scene, actors, state.sector, old, desired, &velocity, actor.height, @abs(actor.collision_radius), config.step_height, &state.floor_cache, .{
        .exclude_source = actor.source_index,
        .drop_height = if (@abs(
            state.velocity.x,
        ) == 0 and @abs(state.velocity.z) == 0) config.drop_height else 0x1p31,
        .wall_block_mask = .{ .blocks_enemies = true },
        .impassable_walls = true,
        .slide_walls = false,
    });

    actor.position.x = solved.position.x;
    actor.position.z = solved.position.z;
    actor.sector = solved.actor_sector;

    if (solved.actor_flags_dirty) actor.flags.changed = true;

    var sector = solved.sector;
    var result: u32 = 0;

    if (solved.contact_kind != .none) {
        result = 15;
        sector = null;
        state.movement_mode = 2;
    }

    const ceiling = try height(world, state.sector, desired.*, true, true);
    const floor = try height(world, state.sector, desired.*, false, true);

    if (@as(f64, ceiling) - floor < actor.height) {
        result = 15;
        sector = null;
        state.movement_mode = 2;
    }

    if (sector) |index| {
        state.sector = index;
        state.position.x = desired.x;
        state.position.z = desired.z;
    }

    const lower = try height(world, state.sector, state.position, false, true);
    state.position.y = @max(@max(state.floor_cache, lower), state.position.y);

    if (state.position.y == state.floor_cache) state.velocity.y = 0;

    return result;
}

fn clampDisplacement(value: f32, magnitude: f32) f32 {
    return if (magnitude < value) magnitude else if (value < -magnitude) -magnitude else value;
}

fn nearest(value: f32) i32 {
    const lower = @floor(value);
    const integer: i32 = @intFromFloat(lower);
    const fraction = value - lower;

    return integer + @as(
        i32,
        if (fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)) 1 else 0,
    );
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
