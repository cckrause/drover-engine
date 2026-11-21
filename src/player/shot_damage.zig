//! Damage from bullets and projectiles: armour, impulse, blood and the
//! sounds.
//!
//! The character's item definition installs these fields; a string override
//! is truncated to fifteen bytes and owns its own copy. Damage arrives as a
//! message with the hit position, so the same path serves local and remote
//! shooters.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const Vec3 = @import("../assets/level.zig").Vec3;
const Angles = @import("../render/backends/software/camera.zig").Angles;
const Player = @import("movement.zig").Player;
const inventory_module = @import("inventory.zig");
const Inventory = inventory_module.Inventory;
const damage = @import("damage.zig");
const DamageInput = @import("shooting.zig").DamageInput;
const flash_module = @import("../render/damage_flash.zig");
const player_audio = @import("../audio/player.zig");

const Name = struct {
    bytes: [16]u8 = @splat(0),

    fn init(value: []const u8) Name {
        var result: Name = .{};
        const length = @min(value.len, 15);
        @memcpy(result.bytes[0..length], value[0..length]);
        return result;
    }

    fn slice(self: *const Name) []const u8 {
        return self.bytes[0..std.mem.indexOfScalar(u8, &self.bytes, 0).?];
    }
};

pub const Config = struct {
    mass: f32 = 150,
    multiplier: f32 = 1,
    got_shot: Name = Name.init("gotshot.wav"),
    armor: [3]Name = .{ Name.init("armor1.wav"), Name.init("armor2.wav"), Name.init("armor3.wav") },

    pub fn fromItem(item: *const Item) !Config {
        var result: Config = .{
            .mass = item.floatValue("MASS") orelse 150,
            .multiplier = item.floatValue("DAMAGE_MULTIPLIER") orelse 1,
        };
        if (!std.math.isFinite(result.mass) or result.mass <= 0 or !std.math.isFinite(result.multiplier)) return error.InvalidPlayerShotConfig;
        if (try item.stringValue("SND_GOTSHOT")) |value| result.got_shot = Name.init(value);
        inline for (.{ "SND_ARMOR1HIT", "SND_ARMOR2HIT", "SND_ARMOR3HIT" }, 0..) |key, i| {
            if (try item.stringValue(key)) |value| result.armor[i] = Name.init(value);
        }
        return result;
    }
};

pub const NetworkResult = union(enum) {
    none,
    blood: Vec3,
    death: u32,
};

const Strike = struct { lost: f32, blood: Vec3 };

pub fn apply(config: *const Config, angles: *const Angles, player: *Player, inventory: *Inventory, input: DamageInput, flash: *flash_module.State, audio: *player_audio.Context, now: u32) !?Vec3 {
    if (input.kind > 4) return error.UnsupportedPlayerShotKind;
    const done = try strike(config, angles, player, inventory, input, flash, audio, now) orelse return null;
    if (@abs(done.lost) == 0) return null;
    if (input.kind == 2) return null;
    if (inventory.health == 0) {
        try audio.effects.append(.{ .message = .{ .index = if (input.kind >= 3) 58 else 54, .routed = true } });
        try audio.voice(.die);
        return null;
    }
    if (input.kind >= 3) return null;
    try sound(audio.effects, config.got_shot.slice());
    return done.blood;
}

pub fn applyNetwork(config: *const Config, angles: *const Angles, player: *Player, inventory: *Inventory, input: DamageInput, own_shot: bool, flash: *flash_module.State, audio: *player_audio.Context, now: u32) !NetworkResult {
    const code: u32 = switch (input.kind) {
        0, 1 => 0x2a,
        3, 4 => if (own_shot) 0x3b else 0x3d,
        5 => 0x37,
        else => 0,
    };
    const done = try strike(config, angles, player, inventory, input, flash, audio, now) orelse return .none;
    if (code == 0 or @abs(done.lost) == 0) return .none;
    if (inventory.health == 0) return .{ .death = code };
    if (code != 0x2a) return .none;
    try sound(audio.effects, config.got_shot.slice());
    return .{ .blood = done.blood };
}

fn strike(config: *const Config, angles: *const Angles, player: *Player, inventory: *Inventory, input: DamageInput, flash: *flash_module.State, audio: *player_audio.Context, now: u32) !?Strike {
    if (!std.math.isFinite(input.damage) or !std.math.isFinite(input.mass) or !std.math.isFinite(input.speed) or !std.math.isFinite(input.height) or !std.math.isFinite(input.lateral)) return error.InvalidPlayerShot;
    var amount = input.damage;
    if (try absorb(config, inventory, player.yaw, input.yaw, &amount, audio.effects)) return null;
    const third = f(@as(f64, @abs(player.radius)) * @as(f32, 0.33333334));
    if (@abs(input.lateral) < third and @as(f64, player.eye_height) * 0.5 + player.position.y < input.height) {
        amount = f(@as(f64, amount) * 1.5);
    } else if (@as(f64, third) * 2.0 <= @abs(input.lateral)) {
        amount = f(@as(f64, amount) * 0.5);
    }
    const magnitude = f(((@as(f64, input.mass) * input.speed) / config.mass) * 10.0);
    const yaw = angles.sinCos(input.yaw);
    const pitch = angles.sinCos(input.pitch);
    const horizontal = @as(f64, pitch.cos) * magnitude;
    const impulse = Vec3{ .x = f(@as(f64, yaw.sin) * horizontal), .y = f(@as(f64, pitch.sin) * magnitude), .z = f(horizontal * yaw.cos) };
    if (player.flags & 8 == 0) {
        player.velocity.x = f(@as(f64, player.velocity.x) + impulse.x);
        player.velocity.y = f(@as(f64, player.velocity.y) + impulse.y);
        player.velocity.z = f(@as(f64, player.velocity.z) + impulse.z);
    }
    const twist = @as(f64, input.lateral) * 4.0 * 45.5112;
    if (!std.math.isFinite(twist) or twist < -2147483648 or twist >= 2147483648) return error.InvalidPlayerShot;
    player.yaw -%= @as(i16, @truncate(@as(i32, @intFromFloat(twist))));
    const blood = Vec3{ .x = f(@as(f64, player.position.x) - @as(f64, yaw.cos) * 0.25), .y = f(@as(f64, player.position.y) + player.body_height), .z = f(@as(f64, player.position.z) - @as(f64, yaw.sin) * 0.25) };
    const sheriff: f64 = if (inventory.sheriff_active) 0.25 else 1;
    const requested = f(sheriff * amount * config.multiplier);
    const lost = damage.subtractHealth(inventory, requested);
    if (@as(i32, @bitCast(lost)) > 0) try flash.trigger(lost, inventory.health == 0, now);
    return .{ .lost = lost, .blood = blood };
}

fn absorb(config: *const Config, inventory: *Inventory, player_yaw: i16, shot_yaw: i16, amount: *f32, effects: *inventory_module.Effects) !bool {
    for (inventory.slots[1..], 1..) |slot, index| {
        const owned = slot orelse continue;
        if (owned.definition.item_class != 0x41524d52) continue;
        const protection = f(@as(f64, @floatFromInt(@as(u32, @bitCast(owned.count)))) * @as(f32, 0.1));
        const angle = (@as(i32, shot_yaw) - @as(i32, player_yaw)) & 0x3fff;
        if (angle <= 0x1000) return false;
        const category: usize = if (@as(i32, @bitCast(protection)) >= 0x41200000) 2 else if (@as(i32, @bitCast(protection)) >= 0x40a00000) 1 else 0;
        try sound(effects, config.armor[category].slice());
        const before = amount.*;
        var remaining: f32 = 0;
        if (protection < before) {
            amount.* = f(@as(f64, before) - protection);
        } else {
            remaining = f(@as(f64, protection) - before);
            amount.* = 0;
        }
        const blocked = before <= protection;
        if (@as(i32, @bitCast(remaining)) < 1) {
            if (owned.definition.function != .generic_object) return error.UnsupportedArmorRemovalNative;
            try inventory.remove(index);
        } else {
            inventory.slots[index].?.count = nearest(f(@as(f64, remaining) * 10.0));
        }
        return blocked;
    }
    return false;
}

fn sound(effects: *inventory_module.Effects, name: []const u8) !void {
    if (name.len != 0) try effects.append(.{ .sound = .{ .basename = name, .priority = 64, .volume = 127, .flags = 0 } });
}

fn nearest(value: f32) i32 {
    if (!std.math.isFinite(value) or value < -2147483648 or value >= 2147483648) return std.math.minInt(i32);
    const lower = @floor(@as(f64, value));
    const integer: i32 = @intFromFloat(lower);
    const part = @as(f64, value) - lower;
    return integer + @as(i32, if (part > 0.5 or (part == 0.5 and integer & 1 != 0)) 1 else 0);
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
