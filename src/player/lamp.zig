//! The portable lamp: input, fuel, and the light it adds to the view.
//!
//! The sound name has a default and an override from the character
//! definition, copied as at most fifteen bytes so the terminator survives.
//! Lamp state outlives a level rebind, which is why it is kept here rather
//! than on the level.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const inventory_module = @import("inventory.zig");
const Inventory = inventory_module.Inventory;
const weapon = @import("weapon.zig");

pub const active_flag: u32 = 0x20000000;

pub const Config = struct {
    sound: [16]u8 = @splat(0),

    pub fn fromItem(item: *const Item) !Config {
        var result: Config = .{};
        const name = (try item.stringValue("SND_LIGHTLAMP")) orelse "light.wav";
        const count = @min(name.len, 15);

        @memcpy(result.sound[0..count], name[0..count]);

        return result;
    }

    pub fn soundName(self: *const Config) []const u8 {
        return self.sound[0..std.mem.indexOfScalar(u8, &self.sound, 0).?];
    }
};

pub const State = struct {
    fuel_elapsed: f32 = 0,
    flicker_time: u32 = 0,
    fade: f32 = 0,
    fading_in: bool = false,
    fading_out: bool = false,
    force_depth: bool = false,
    depth_bias: i32 = 0,

    pub fn toggle(
        self: *State,
        inventory: *Inventory,
        config: *const Config,
        effects: *inventory_module.Effects,
    ) !void {
        if (inventory.player_flags & active_flag == 0) {
            if (fuelSlot(inventory) == null or inventory.player_flags & 0x8000 != 0) return;

            const name = config.soundName();

            if (name.len != 0) try effects.append(.{
                .sound = .{ .basename = name, .priority = 64, .volume = 127, .flags = 0 },
            });

            self.fade = 0;
            self.fading_in = true;
            self.fading_out = false;
            self.force_depth = true;
            self.depth_bias = 0;
            inventory.player_flags |= active_flag;
        } else self.turnOff(inventory);
    }

    pub fn consume(self: *State, inventory: *Inventory, seconds: f32) !void {
        const elapsed = @as(f64, self.fuel_elapsed) + seconds;

        self.fuel_elapsed = @floatCast(elapsed);
        if (elapsed < 1 or inventory.player_flags & active_flag == 0) return;

        if (fuelSlot(inventory)) |slot| {
            const remaining = inventory.slots[slot].?.count -% 1;

            if (remaining == 0) {
                if (inventory.slots[slot].?.definition.function != .generic_object) return error.UnsupportedLampFuelNative;
                try inventory.remove(slot);
                self.turnOff(inventory);
            } else inventory.slots[slot].?.count = remaining;
        } else self.turnOff(inventory);

        self.fuel_elapsed = 0;
    }

    pub fn hardOff(self: *State) void {
        self.fade = 0;
        self.fading_in = false;
        self.fading_out = false;
        self.force_depth = false;
        self.depth_bias = 0;
    }

    pub fn advancePresentation(self: *State, seconds: f32, now: u32, random: *u32) void {
        if (!self.force_depth) return;

        if (!self.fading_in and !self.fading_out) {
            self.flicker(now, random);
        } else if (!self.fading_in) {
            self.fade = @floatCast(@as(f64, seconds) * 10 + self.fade);

            if (nearest(self.fade) > 0) {
                self.fade = 0;
                self.fading_in = false;
                self.fading_out = false;
            }

            self.depth_bias = nearest(self.fade);

            if (self.depth_bias == 0) self.force_depth = false;
        } else {
            self.fade = @floatCast(@as(f64, self.fade) - @as(f64, seconds) * 10);
            self.depth_bias = nearest(self.fade);
            if (nearest(self.fade) < -10) self.fading_in = false;
            self.fading_out = false;
        }
    }

    fn turnOff(self: *State, inventory: *Inventory) void {
        self.fading_in = false;
        self.fading_out = true;
        inventory.player_flags &= ~active_flag;
    }

    fn flicker(self: *State, now: u32, random: *u32) void {
        if (@as(f64, @floatFromInt(now -% self.flicker_time)) / 1000 > 0.02) {
            self.flicker_time = now;
            const amount = if (weapon.randomFloat(random, 4) >= 1)
                weapon.randomFloat(random, 29) * 0.125 + 1
            else
                std.math.clamp(
                    (weapon.randomFloat(
                        random,
                        2,
                    ) - 1) * 0.125 - @as(f64, @floatFromInt(self.depth_bias)),
                    1,
                    31,
                );

            self.depth_bias = -%nearest(@floatCast(amount));
        }

        self.fading_in = false;
        self.fading_out = false;
    }
};

pub fn actorFlags(flags: u32, active: bool) u32 {
    return if (active) (flags | 0x80000010) & ~@as(
        u32,
        8,
    ) else (flags & ~@as(u32, 0x10)) | 0x80000008;
}

fn fuelSlot(inventory: *const Inventory) ?usize {
    for (inventory.slots[1..], 1..) |slot, i| if (slot) |owned| {
        if (owned.definition.item_class == 0x4655454c) return i;
    };

    return null;
}

fn nearest(value: f32) i32 {
    if (!std.math.isFinite(
        value,
    ) or value < -2147483648.0 or value >= 2147483648.0) return std.math.minInt(i32);

    const lower = @floor(@as(f64, value));
    const fraction = @as(f64, value) - lower;
    const integer: i32 = @intFromFloat(lower);

    return if (fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)) integer + 1 else integer;
}

test {
    _ = @import("lamp_test.zig");
}
