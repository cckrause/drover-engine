//! Blood: the drops a hit throws, their fall and their removal.
//!
//! Creation is suppressed entirely by one game option, which the caller
//! owns.

const std = @import("std");
const nwx = @import("../assets/nwx.zig");
const level = @import("../assets/level.zig");
const ceiling_contact = @import("../player/ceiling_contact.zig");
const Actor = @import("../render/objects.zig").Actor;
const collision = @import("../player/collision.zig");
const weapon = @import("../player/weapon.zig");
const physics = @import("physics.zig");
const Vec3 = level.Vec3;

pub const costume_name = "BLOOD.NWX";

pub const splash_costume_name = "SPLASH4.NWX";

pub const Splash = struct { sector: usize, position: Vec3 };

pub const State = struct {
    velocity: Vec3,
    floor_cache: f32 = -0x1p31,
    splash: ?Splash = null,
    wall_memory: collision.WallMemory = .{},
    walked: ?f32 = null,
    step_sound: ?Step = null,
};

pub const Step = struct { floor: usize, sector: usize, position: Vec3 };

pub const Spawn = struct { actor: Actor, state: State };

const Mask = struct { gravity: bool, no_slowing: bool = false };

const SplashAnimation = struct {
    removed: bool = false,

    pub fn event(self: *@This(), playback: *nwx.Playback, _: *const nwx.Costume, message: u32, _: []const u32, _: u32) !void {
        if (message == 0x5e) {
            self.removed = true;
            playback.terminated = true;
        }
    }
};

pub fn spawn(costume: *const nwx.Costume, random: *u32, sector: usize, position: Vec3, now: u32) !Spawn {
    const vx = @as(f32, @floatFromInt(weapon.randomNext(random) & 3)) - 1.5;
    const vy: f32 = @floatFromInt(weapon.randomNext(random) & 7);
    const vz = @as(f32, @floatFromInt(weapon.randomNext(random) & 3)) - 1.5;
    const scale = @as(f32, @floatFromInt(@as(u16, @truncate(weapon.randomNext(random))))) * 0x1p-16;
    return .{
        .actor = .{ .logic_name = "fx_BloodLogic", .costume = costume, .sector = sector, .position = position, .yaw = 0, .flags = 0x8000014f, .secondary_flags = 0x800000, .scale_x = scale, .scale_y = scale, .height = 1, .collision_radius = 1, .choreography = 0, .frame = 0, .angle_offset = 0, .playback = .{ .last_time = now } },
        .state = .{ .velocity = .{ .x = vx, .y = vy, .z = vz } },
    };
}

pub fn tick(actor: *Actor, state: *State, world: physics.World, dt: f32) !bool {
    state.splash = null;
    if (!(actor.position.y > try physics.height(world, actor.sector, actor.position, false, true))) {
        if (world.contact_stack) |stack| stack.residue.invalidateProjection();
        return true;
    }
    var callback_world = world;
    if (callback_world.contact_stack) |*stack| stack.caller = .blood;
    try generalPhysics(actor, state, callback_world, dt);
    return false;
}

pub fn scheduledPhysics(actor: *Actor, state: *State, world: physics.World, dt: f32) !bool {
    state.splash = null;
    if (actor.flags & 0x401 != 0x401) return false;
    const floor = try physics.height(world, actor.sector, actor.position, false, false);
    const source = world.level.sectors[actor.sector];
    if (world.scene.sectors[actor.sector].velocity_present and (world.scene.sectors[actor.sector].flags & 0x40 == 0 or actor.position.y <= floor)) {
        state.velocity = source.velocity;
    } else if (actor.position.y <= floor) return false;
    var callback_world = world;
    if (callback_world.contact_stack) |*stack| stack.caller = .scheduler;
    try generalPhysics(actor, state, callback_world, dt);
    return true;
}

pub fn generalPhysics(actor: *Actor, state: *State, world: physics.World, dt: f32) !void {
    return integrate(actor, state, world, dt, .{ .gravity = true }, .{});
}

pub fn bubblePhysics(actor: *Actor, state: *State, world: physics.World, dt: f32) !void {
    var callback_world = world;
    if (callback_world.contact_stack) |*stack| stack.caller = .bubble;
    return integrate(actor, state, callback_world, dt, .{ .gravity = false }, .{});
}

pub fn projectilePhysics(actor: *Actor, state: *State, world: physics.World, dt: f32, owner: ?usize, sink: ?collision.ContactSink) !void {
    return integrate(actor, state, world, dt, .{ .gravity = true }, .{ .exclude_owner = owner, .contact_sink = sink });
}

pub fn remotePlayerPhysics(actor: *Actor, state: *State, world: physics.World, dt: f32) !void {
    return integrate(actor, state, world, dt, .{ .gravity = true, .no_slowing = true }, .{});
}

pub fn planeSpeed(world: physics.World, sector: usize, ceiling: bool) f32 {
    const runtime = world.actors.runtime orelse return 0;
    const inf = runtime.inf orelse return 0;
    return inf.planeSpeed(world.level, sector, ceiling);
}

pub fn spawnSplash(costume: *const nwx.Costume, request: Splash, now: u32) !Actor {
    if (costume.frames.len == 0 or costume.frames[0].parts.len == 0) return error.InvalidSplashCostume;
    const first = costume.frames[0].parts[0];
    return .{ .costume = costume, .sector = request.sector, .position = request.position, .yaw = 0, .flags = 0x8000010f, .secondary_flags = 0x800000, .scale_x = 1, .scale_y = 1, .height = first.height, .collision_radius = f(@as(f64, first.width) * 0.5), .choreography = 0, .frame = 0, .angle_offset = 0, .playback = .{ .last_time = now } };
}

pub fn splashSound(request: Splash) @import("../audio/request.zig").Request {
    return .{ .basename = "smsplash.wav", .priority = 64, .volume = 127, .flags = 4, .sector = request.sector, .position = request.position };
}

pub fn selectSplash(actor: *Actor, now: u32) !bool {
    var context: SplashAnimation = .{};
    try actor.playback.?.select(try actor.sprite(), 0, now, &context);
    syncPlayback(actor);
    return context.removed;
}

pub fn advanceSplash(actor: *Actor, now: u32) !bool {
    var context: SplashAnimation = .{};
    try actor.playback.?.advanceWithContext(try actor.sprite(), 0, now, &context);
    syncPlayback(actor);
    return context.removed;
}

fn integrate(actor: *Actor, state: *State, world: physics.World, dt: f32, mask: Mask, options: collision.Options) !void {
    const gravity = mask.gravity;
    state.splash = null;
    state.step_sound = null;
    const old = actor.position;
    const source = world.level.sectors[actor.sector];
    const flags = world.scene.sectors[actor.sector].flags;
    var lower = actor.sector;
    var upper = actor.sector;
    const submerged = flags & 0x80 != 0;
    const has_surface = submerged or source.vadjoin >= 0;
    var surface: f32 = 0;
    if (source.vadjoin >= 0) {
        if (submerged) upper = @intCast(source.vadjoin) else lower = @intCast(source.vadjoin);
        surface = try physics.height(world, actor.sector, old, submerged, true);
    } else if (submerged) surface = try physics.height(world, actor.sector, old, true, true);
    const floor = try physics.height(world, lower, old, false, true);
    const ceiling = try physics.height(world, upper, old, true, true);
    const floor_limit = if (planeSpeed(world, lower, false) == 0 and floor <= state.floor_cache) state.floor_cache else floor;
    var stack = world.contact_stack;
    if (stack) |tracking| tracking.begin(state.velocity, floor_limit);
    const horizontal: f32 = if (mask.no_slowing) 0 else if (submerged) 20 else f(@as(f64, world.level.sectors[lower].friction) * 80.0);
    const vertical: f32 = if (mask.no_slowing) 0 else 120;
    if (stack) |tracking| if (tracking.caller == .scheduler) {
        tracking.residue.projection.words[0] = 0;
        tracking.residue.projection.words[1] = @bitCast(horizontal);
        tracking.residue.projection.words[2] = @bitCast(@as(f32, 120));
    };
    var next = old;
    var velocity = state.velocity;
    const gravity_bits: u32 = @bitCast(source.gravity);
    if (gravity and (((floor_limit < old.y or (old.y <= floor_limit and @as(i32, @bitCast(velocity.y)) > 0)) and gravity_bits > 0x80000000) or (old.y < ceiling and @as(i32, @bitCast(gravity_bits)) > 0))) {
        const full = @as(f64, dt) * source.gravity + velocity.y;
        velocity.y = f(full);
        next.y = f(full * dt + old.y);
    }
    if (next.y <= floor_limit or (world.scene.sectors[actor.sector].velocity_present and flags & 0x40 == 0)) {
        damp(&velocity, source.velocity, .{ .x = horizontal, .y = vertical, .z = horizontal }, submerged, dt);
    }
    if (world.scene.sectors[upper].flags & 1 == 0 and ceiling < @as(f64, actor.height) + next.y) {
        _ = ceiling_contact.bounce(&velocity, world.scene.sectors[upper].ceiling_slope, world.level.sectors[upper].elasticity, planeSpeed(world, upper, true));
        next.y = f(@as(f64, ceiling) - actor.height);
    }
    if (next.y < floor_limit) {
        if (@as(i32, @bitCast(velocity.y)) > 0) velocity.y = 0;
        next.y = floor_limit;
    }
    if (next.y <= floor_limit and world.scene.sectors[lower].flags & 0x20 == 0) {
        if (world.scene.sectors[lower].floor_slope) |slope| {
            const ground = world.level.sectors[lower];
            velocity.x = f(-@as(f64, ground.gravity) * slope.coeff_x * (1.0 - @as(f64, ground.friction)) * dt + velocity.x);
            velocity.z = f(@as(f64, slope.coeff_z) * -@as(f64, ground.gravity) * (1.0 - @as(f64, ground.friction)) * dt + velocity.z);
        }
    }
    next.x = f(@as(f64, dt) * velocity.x + old.x);
    next.z = f(@as(f64, dt) * velocity.z + old.z);
    var actors = world.actors;
    actors.allow_pickups = false;
    var collision_options = options;
    if (stack) |*tracking| {
        collision_options.query_observer = tracking.observer();
        switch (tracking.caller) {
            .blood => collision_options.projection = &tracking.residue.projection,
            .scheduler => {},
            .knife, .explosive => {},
            .bubble => {
                tracking.residue.projection.words = .{ 0, 0, 0x004c13a0, 0 };
            },
            .fragment => {
                tracking.residue.invalidateProjection();
            },
        }
    }
    collision_options.exclude_source = actor.source_index;
    collision_options.wall_memory = &state.wall_memory;
    const solved = try collision.resolveWithOptions(world.level, world.scene, actors, actor.sector, old, &next, &velocity, actor.height, @abs(actor.collision_radius), actor.height, &state.floor_cache, collision_options);
    if (stack) |tracking| if (tracking.caller == .bubble and solved.actor_flags_dirty) {
        tracking.residue.projection.words[2] = 0x004c1370;
    };
    actor.position.x = solved.position.x;
    actor.position.z = solved.position.z;
    actor.sector = solved.actor_sector;
    if (solved.actor_flags_dirty) actor.flags |= 0x80000000;
    if (has_surface and solved.sector != null) {
        if (surface == next.y) next.y = f(@as(f64, next.y) - 0.001);
        if (submerged) {
            if (surface < next.y) {
                if (actors.runtime) |runtime| try runtime.changeSector(actor.sector, upper);
                actor.sector = upper;
            }
        } else if (next.y < surface) {
            if (stack) |tracking| tracking.residue.invalidateProjection();
            state.splash = .{ .sector = upper, .position = .{ .x = actor.position.x, .y = surface, .z = actor.position.z } };
            if (actors.runtime) |runtime| try runtime.changeSector(actor.sector, lower);
            actor.sector = lower;
            if (stack) |tracking| switch (tracking.caller) {
                .blood => tracking.residue.words = .{ 0x40, null, null, null },
                .fragment => tracking.residue.words = .{ null, null, null, 0x40 },
                .scheduler => {
                    tracking.residue.words[2] = null;
                    tracking.residue.words[3] = null;
                },
                else => {},
            };
        }
    }
    if (state.walked) |*walked| if (!(floor_limit < next.y)) {
        const sum = @as(f64, collision.length(velocity.x, velocity.z)) * dt + walked.*;
        var stored = f(sum);
        if (sum > 15.0) {
            stored = f(@as(f64, stored) - 15.0);
            state.step_sound = .{ .floor = lower, .sector = actor.sector, .position = actor.position };
        }
        walked.* = stored;
    };
    actor.position.y = next.y;
    state.velocity = velocity;
}

fn damp(velocity: *Vec3, conveyor: Vec3, rates: Vec3, submerged: bool, dt: f32) void {
    const multiplier = if (submerged) @exp(-4.0 * @as(f64, dt)) else 1;
    inline for (.{ "x", "y", "z" }) |axis| {
        var delta = @as(f64, @field(velocity, axis)) - @field(conveyor, axis);
        if (submerged) delta *= multiplier else if (delta <= 0) {
            delta += @as(f64, @field(rates, axis)) * dt;
            if (delta >= 0) delta = 0;
        } else {
            delta -= @as(f64, @field(rates, axis)) * dt;
            if (delta <= 0) delta = 0;
        }
        @field(velocity, axis) = f(@as(f64, @field(conveyor, axis)) + delta);
        if (@abs(@field(velocity, axis)) < 0.0001) @field(velocity, axis) = 0;
    }
}

fn f(value: f64) f32 {
    return @floatCast(value);
}

fn syncPlayback(actor: *Actor) void {
    actor.choreography = actor.playback.?.choreography;
    actor.frame = actor.playback.?.frame;
    actor.angle_offset = actor.playback.?.angle_offset;
}
