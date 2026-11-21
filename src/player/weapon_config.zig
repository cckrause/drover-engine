//! Weapon definitions and their firing modes, as the data files describe
//! them.
//!
//! A field the data does not mention stays zero. The recoil pitch is
//! truncated into a signed angle and only its low 16 bits are kept, so large
//! values wrap rather than clamp.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;

pub const Mode = struct {
    range: f32 = 0,
    effective_range: f32 = 0,
    spread: f32 = 0,
    variance: f32 = 0,
    rate: f32 = 0,
    mass: f32 = 0,
    damage: f32 = 0,
};

pub const Config = struct {
    rest: i16 = 0,
    fire: [3]i16 = @splat(0),
    empty: [3]i16 = @splat(0),
    reload: i16 = 0,
    extra: i16 = 0,
    scope_item: ?[]const u8 = null,
    scope_rest: i16 = 0,
    scope_fire: [3]i16 = @splat(0),
    scope_empty: [3]i16 = @splat(0),
    scope_x: i32 = 0,
    scope_y: i32 = 0,
    fire_sound: [3]?[]const u8 = @splat(null),
    empty_sound: [3]?[]const u8 = @splat(null),
    action_sound: [3]?[]const u8 = @splat(null),
    reload_sound: ?[]const u8 = null,
    extra_sound: ?[]const u8 = null,
    modes: [3]Mode = @splat(.{}),
    flash: i32 = 0,
    kick: f32 = 0.2,
    multiples: i32 = 0,
    auto_reload: bool = false,
    projectile: ?[]const u8 = null,

    pub fn clone(self: Config, a: std.mem.Allocator) !Config {
        var result = self;
        inline for (.{ "scope_item", "reload_sound", "extra_sound", "projectile" }) |name| {
            @field(result, name) = if (@field(self, name)) |value| try a.dupe(u8, value) else null;
        }
        inline for (.{ "fire_sound", "empty_sound", "action_sound" }) |name| {
            for (@field(self, name), 0..) |value, i| @field(result, name)[i] = if (value) |text| try a.dupe(u8, text) else null;
        }
        return result;
    }

    pub fn load(a: std.mem.Allocator, item: *const Item) !Config {
        var result: Config = .{};
        result.rest = short(item.intValue("REST_CHOR") orelse 0);
        result.reload = short(item.intValue("RELOAD_CHOR") orelse 0);
        result.extra = short(item.intValue("EXTRA_CHOR") orelse 0);
        result.scope_item = try string(a, item, "SCOPE_ITEM");
        if (result.scope_item != null) {
            result.scope_rest = short(item.intValue("SCOPE_REST_CHOR") orelse 0);
            result.scope_x = item.intValue("SCOPE_X") orelse 0;
            result.scope_y = item.intValue("SCOPE_Y") orelse 0;
        }
        result.flash = item.intValue("FLASH_INTENSITY") orelse 0;
        result.kick = item.floatValue("KICK_AMOUNT") orelse 0.2;
        result.multiples = item.intValue("SHOT_MULTIPLES") orelse 0;
        result.auto_reload = @as(u8, @truncate(@as(u32, @bitCast(item.intValue("AUTO_RELOAD") orelse 0)))) != 0;
        result.projectile = try string(a, item, "PROJECTILE");
        result.reload_sound = try string(a, item, "RELOAD_SOUND");
        result.extra_sound = try string(a, item, "EXTRA_SOUND");
        var buffer: [64]u8 = undefined;
        for (0..3) |i| {
            result.fire[i] = short(item.intValue(try field(&buffer, "FIRE_CHOR", i)) orelse 0);
            result.empty[i] = short(item.intValue(try field(&buffer, "NO_AMMO_CHOR", i)) orelse 0);
            if (result.scope_item != null) {
                result.scope_fire[i] = short(item.intValue(try field(&buffer, "SCOPE_FIRE_CHOR", i)) orelse 0);
                result.scope_empty[i] = short(item.intValue(try field(&buffer, "SCOPE_NO_AMMO_CHOR", i)) orelse 0);
            }
            result.fire_sound[i] = try string(a, item, try field(&buffer, "FIRE_SOUND", i));
            result.empty_sound[i] = try string(a, item, try field(&buffer, "NO_AMMO_SOUND", i));
            result.action_sound[i] = try string(a, item, try field(&buffer, "ACTION_SOUND", i));
            const mode = &result.modes[i];
            mode.range = item.floatValue(try field(&buffer, "RANGE", i)) orelse 0;
            mode.effective_range = item.floatValue(try field(&buffer, "EFFRANGE", i)) orelse 0;
            mode.spread = item.floatValue(try field(&buffer, "SPREAD", i)) orelse 0;
            mode.variance = item.floatValue(try field(&buffer, "VARIANCE", i)) orelse 0;
            mode.rate = item.floatValue(try field(&buffer, "RATE", i)) orelse 0;
            mode.mass = item.floatValue(try field(&buffer, "MASS", i)) orelse 0;
            mode.damage = item.floatValue(try field(&buffer, "DAMAGE", i)) orelse 0;
        }
        if (result.multiples < 0 or result.multiples > 1024) return error.InvalidWeaponShotCount;
        if (!std.math.isFinite(result.kick)) return error.InvalidWeaponFloat;
        const kick_angle = @trunc(@as(f64, result.kick) * @as(f32, 5.0) * @as(f64, 45.5112));
        if (kick_angle < std.math.minInt(i32) or kick_angle > std.math.maxInt(i32)) return error.InvalidWeaponKick;
        for (result.modes) |mode| inline for (std.meta.fields(Mode)) |member| {
            if (!std.math.isFinite(@field(mode, member.name))) return error.InvalidWeaponFloat;
        };
        return result;
    }
};

fn short(value: i32) i16 {
    return @truncate(value);
}

fn field(buffer: []u8, name: []const u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}_{d}", .{ name, index + 1 });
}

fn string(a: std.mem.Allocator, item: *const Item, name: []const u8) !?[]const u8 {
    return if (try item.stringValue(name)) |value| try a.dupe(u8, value) else null;
}

test "weapon metadata rejects invalid floating point conversions" {
    const fields = [_][]const u8{ "KICK_AMOUNT", "RANGE_1", "EFFRANGE_2", "SPREAD_3", "VARIANCE_1", "RATE_2", "MASS_3", "DAMAGE_1" };
    for (fields) |name| {
        var entries = [_]@import("../assets/item.zig").Field{.{ .name = name, .value = .{ .float = std.math.nan(f32) } }};
        var item: Item = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .name = "", .function = "", .animation = "", .fields = &entries, .ignored_directives = &.{} };
        defer item.arena.deinit();
        try std.testing.expectError(error.InvalidWeaponFloat, Config.load(std.testing.allocator, &item));
    }
    var item = try Item.parse(std.testing.allocator, "ITEM 1.0\nDATA 2\nFLOAT KICK_AMOUNT -0.2\nFLOAT MASS_1 -3\n");
    defer item.deinit();
    const config = try Config.load(std.testing.allocator, &item);
    try std.testing.expectEqual(@as(f32, -0.2), config.kick);
    try std.testing.expectEqual(@as(f32, -3), config.modes[0].mass);
    item.fields[0].value = .{ .float = std.math.floatMax(f32) };
    try std.testing.expectError(error.InvalidWeaponKick, Config.load(std.testing.allocator, &item));
}
