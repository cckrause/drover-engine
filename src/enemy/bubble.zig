//! Bubbles underwater: batches of them, rising until they reach a ceiling.
//!
//! A random value is consumed even when the batch is empty, and one value
//! per bubble supplies both of its scales - the random stream is shared, so
//! the number of draws is part of the behaviour.

const std = @import("std");

const level = @import("../assets/level.zig");
const nwx = @import("../assets/nwx.zig");
const Actor = @import("../render/objects.zig").Actor;
const audio_request = @import("../audio/request.zig");
const weapon = @import("../player/weapon.zig");
const blood = @import("blood.zig");
const physics = @import("physics.zig");

pub const costume_name = "BUBBLE1.NWX";

pub fn sound(random: *u32, sector: usize, position: level.Vec3) audio_request.Request {
    const names = [_][]const u8{
        "bubbles1.wav",
        "bubbles2.wav",
        "bubbles3.wav",
        "bubbles4.wav",
        "bubbles5.wav",
    };

    return .{
        .basename = names[weapon.randomNext(random) % 5],
        .priority = 32,
        .volume = 127,
        .flags = 4,
        .sector = sector,
        .position = position,
    };
}

pub fn spawn(
    costume: *const nwx.Costume,
    random: *u32,
    sector: usize,
    position: level.Vec3,
    now: u32,
) Actor {
    const value: u16 = @truncate(weapon.randomNext(random));
    const scale = @as(f32, @floatFromInt(value)) * @as(f32, 0x1p-16);

    return .{
        .logic_name = "fx_BubbleLogic",
        .costume = costume,
        .sector = sector,
        .position = position,
        .yaw = 0,
        .flags = 0x8000014f,
        .secondary_flags = 0x800000,
        .scale_x = scale,
        .scale_y = scale,
        .height = 1,
        .collision_radius = 1,
        .choreography = 0,
        .frame = 0,
        .angle_offset = 0,
        .playback = .{ .last_time = now },
    };
}

pub fn tick(actor: *Actor, state: *blood.State, world: physics.World, dt: f32, now: u32) !bool {
    const full_speed = (2.0 - @as(f64, actor.scale_x)) * 10.0;
    const speed = f(full_speed);
    const amplitude = f(full_speed * @as(f32, 0.1));
    const next_y = f(@as(f64, speed) * dt + actor.position.y);
    if (try physics.height(world, actor.sector, actor.position, true, true) < next_y) return true;

    actor.position.y = next_y;

    const angle: i16 = @truncate(nearest(f(@as(f64, @floatFromInt(now)) * speed)));
    const trig = world.angles.sinCos(angle);

    state.velocity.x = f(@as(f64, amplitude) * trig.sin + state.velocity.x);
    state.velocity.z = f(@as(f64, amplitude) * trig.cos + state.velocity.z);

    try blood.bubblePhysics(actor, state, world, dt);

    return false;
}

fn f(value: f64) f32 {
    return @floatCast(value);
}

fn nearest(value: f32) i32 {
    const lower = @floor(@as(f64, value));
    const fraction = @as(f64, value) - lower;
    const rounded = lower + @as(
        f64,
        if (fraction > 0.5 or (fraction == 0.5 and @mod(lower, 2) != 0)) 1 else 0,
    );

    if (!std.math.isFinite(
        rounded,
    ) or rounded < -2147483648.0 or rounded >= 2147483648.0) return std.math.minInt(i32);

    return @intFromFloat(rounded);
}
