//! Damage to the player: impact, crushing and the feedback that goes with
//! it.
//!
//! The character's item definition supplies the damage multiplier; the
//! impact threshold and rate have no override and are fixed here. Impact
//! damage combines the vertical component with the horizontal one rather
//! than taking the larger.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const Inventory = @import("inventory.zig").Inventory;
const player_audio = @import("../audio/player.zig");
const damage_flash = @import("../render/damage_flash.zig");

pub const Config = struct {
    multiplier: f32 = 1,

    pub fn fromItem(item: *const Item) !Config {
        const multiplier = item.floatValue("DAMAGE_MULTIPLIER") orelse 1;
        if (!std.math.isFinite(multiplier)) return error.InvalidPlayerDamageMultiplier;
        return .{ .multiplier = multiplier };
    }
};

pub const Environment = struct {
    elapsed: f32 = 0,
    crush_required: f32 = 0,
    crush_body: f32 = 0,
    runtime: ?*@import("../script/runtime.zig").Context = null,
    player: ?*const @import("movement.zig").Player = null,
    angles: ?*const @import("../render/backends/software/camera.zig").Angles = null,
};

pub fn applyMovement(config: Config, inventory: *Inventory, velocity: f32, sector_damage: u32, seconds: f32, flash: *damage_flash.State, audio: *player_audio.Context, now_ms: u32) !?i32 {
    return applyMovementWithEnvironment(config, inventory, velocity, sector_damage, seconds, flash, audio, now_ms, .{});
}

pub fn applyMovementWithEnvironment(config: Config, inventory: *Inventory, velocity: f32, sector_damage: u32, seconds: f32, flash: *damage_flash.State, audio: *player_audio.Context, now_ms: u32, environment: Environment) !?i32 {
    const drowning = environment.elapsed > 30;
    const crushing = environment.crush_body < environment.crush_required;
    if (!(velocity > 45) and sector_damage == 0 and !drowning and !crushing) return null;
    var amount: f32 = if (velocity > 45) @floatCast((@as(f64, velocity) - 45) * @as(f32, 0.2)) else 0;
    const surface: f32 = if (sector_damage & 4 != 0) 500 else if (sector_damage & 2 != 0) @floatCast(@as(f64, seconds) * 2) else if (sector_damage & 1 != 0) seconds else 0;
    if (sector_damage != 0) amount = @floatCast(@as(f64, amount) + surface);
    const drowned: f32 = if (drowning) @floatCast(@as(f64, @as(f32, 0.22)) * seconds) else 0;
    if (drowning) amount = @floatCast(@as(f64, @as(f32, 0.22)) * seconds + amount);
    const crush_full = if (crushing) @max(0, ((@as(f64, seconds) * 5) / environment.crush_required) * environment.crush_body * 10) else 0;
    const crushed: f32 = @floatCast(crush_full);
    if (crushing) amount = @floatCast(crush_full + amount);
    const old_health = inventory.health;
    const sheriff: f64 = if (inventory.sheriff_active) 0.25 else 1;
    const requested: f32 = @floatCast(sheriff * amount * config.multiplier);
    const lost = subtractHealth(inventory, requested);
    if (@as(i32, @bitCast(lost)) > 0) try flash.trigger(lost, inventory.health == 0, now_ms);
    if (@abs(lost) == 0) return null;
    if (inventory.health == 0) {
        if (crushing) try audio.voice(.splat) else if (drowning) try audio.voice(.water_die) else if (sector_damage == 0) try audio.voice(.crunch);
        try audio.voice(.die);
        return if (crushing) 51 else if (drowning) 49 else if (sector_damage != 0) 47 else 45;
    }
    if (crushing) {
        const after_crush: f32 = @floatCast(@as(f64, old_health) - crushed);
        if (@as(i32, @bitCast(old_health)) > 0 and nearest(old_health) != nearest(after_crush)) try audio.voice(.crush);
    } else if (drowning) {
        const after_drowning: f32 = @floatCast(@as(f64, old_health) - drowned);
        if (@as(i32, @bitCast(old_health)) > 0 and nearest(old_health) != nearest(after_drowning)) {
            try audio.voice(.choke);
            const runtime = environment.runtime orelse return error.MissingBubbleRuntime;
            const player = environment.player orelse return error.MissingDrowningPlayer;
            const angles = environment.angles orelse return error.MissingDrowningAngles;
            const basis = angles.sinCos(player.viewYaw());
            const count: i32 = @intCast((@import("weapon.zig").randomNext(&runtime.contact_state.random) & 7) + 1);
            try runtime.spawnBubbles(player.sector, .{
                .x = @floatCast(@as(f64, basis.sin) * 2 + player.position.x),
                .y = @floatCast(@as(f64, player.eye_height) + player.position.y),
                .z = @floatCast(@as(f64, basis.cos) * 2 + player.position.z),
            }, count);
        }
    } else if (sector_damage != 0) {
        const after_surface: f32 = @floatCast(@as(f64, old_health) - surface);
        if (@as(i32, @bitCast(old_health)) > 0 and nearest(old_health) != nearest(after_surface)) try audio.voice(.shriek);
    } else try audio.voice(.crunch);
    return null;
}

pub fn subtractHealth(inventory: *Inventory, amount: f32) f32 {
    if (inventory.player_flags & 0x10000000 != 0) return 0;
    const remaining = @max(0, @as(f64, inventory.health) - amount);
    const lost: f32 = @floatCast(@as(f64, inventory.health) - remaining);
    inventory.statistics.damage +%= nearest(lost);
    inventory.health = @floatCast(remaining);
    return lost;
}

fn nearest(value: f32) i32 {
    if (!std.math.isFinite(value) or value < -2147483648.0 or value >= 2147483648.0) return std.math.minInt(i32);
    const lower = @floor(@as(f64, value));
    const fraction = @as(f64, value) - lower;
    const integer: i32 = @intFromFloat(lower);
    return if (fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)) integer + 1 else integer;
}
