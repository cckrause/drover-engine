//! Enemy templates: the static definition, what it inherits, and the
//! difficulty adjustments applied on top.
//!
//! A template is copied before it is modified, inheritance is resolved
//! recursively, and the difficulty descriptors are applied last.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const WeaponMode = @import("../player/weapon_config.zig").Mode;

pub const Config = struct {
    los_timer_time: u32 = 250,
    watch_timer_time: u32 = 300000,
    reaquire_timer_time: u32 = 5000,
    min_follow_dist: f32 = 20,
    max_follow_dist: f32 = 60,
    radial_variance: i16 = 2048,
    walk_speed: f32 = 8,
    run_speed: f32 = 12,
    fov_dist: f32 = 300,
    fov: i16 = 6599,
    shoot_timer_time: u32 = 2000,
    shoot_chor: u32 = 10,
    walk_chor: u32 = 1,
    chest_die_chor: u32 = 21,
    hit_chor: u32 = 20,
    watch_chor: u32 = 0,
    duck_chor: u32 = 3,
    health: f32 = 2,
    duck_timer_time: u32 = 10000,
    move_inaccuracy: f32 = 20,
    weapon_inaccuracy: f32 = 4,
    shoot_sound: []const u8 = "enmyshot.wav",
    drop_item: []const u8 = "gdrop1.itm",
    activate_radius: f32 = 0,
    leg_die_chor: u32 = 22,
    left_die_chor: u32 = 23,
    right_die_chor: u32 = 23,
    taunt_timer_time: u32 = 25000,
    confidence: f32 = 0.75,
    run_chor: u32 = 2,
    walk_shoot_chor: u32 = 31,
    run_shoot_chor: u32 = 32,
    aggressiveness: i32 = 4,
    max_step: f32 = 3,
    max_drop: f32 = 15,
    base_mode: u32 = 0,
    weapon: Weapon = .pistol,
    weapon_mode: WeaponMode = .{},
    kill_dist: f32 = 0,
    damage: f32 = 1,
    throw_item: []const u8 = "",
    throw_max: f32 = 0,
    throw_min: f32 = 0,
    throw_velocity: f32 = 0,
    hit_sound: []const u8 = "bgy1hit.wav",
    die_sound: []const u8 = "bgy1die.wav",
    panic_rate: f32 = 2,
    panic_inaccuracy: f32 = 7,
    shot_multiples: i32 = 1,
    los_taunts: []const []const u8 = &.{},
    no_los_taunts: []const []const u8 = &.{},
    alert_taunts: []const []const u8 = &.{},
    hitscan: bool = true,
    radius: ?f32 = null,
    height: ?f32 = null,

    pub const Weapon = enum(u32) {
        pistol = 0x005b30c0,
        shotgun = 0x005b3080,
        fist = 0x005b3140,
        weapon0 = 0x005b30a0,
        weapon1 = 0x005b3120,
        weapon2 = 0x005b31a0,
        weapon3 = 0x005b30e0,
        weapon4 = 0x005b3180,
        weapon5 = 0x005b31c0,
        weapon6 = 0x005b3020,
        weapon7 = 0x005b3160,
        weapon8 = 0x005b31e0,
        weapon9 = 0x005b3060,
    };

    pub fn load(
        a: std.mem.Allocator,
        archives: []const lab.Archive,
        item: *const Item,
        difficulty: u32,
    ) !Config {
        var self: Config = .{};

        if (std.ascii.eqlIgnoreCase(
            item.function,
            "Chicken_New",
        ) or std.ascii.eqlIgnoreCase(item.function, "Civilian_New")) {
            self.shoot_chor = 0xffffffff;
            self.drop_item = "";
        } else if (std.ascii.eqlIgnoreCase(
            item.function,
            "Slim_New",
        ) or std.ascii.eqlIgnoreCase(
            item.function,
            "DrDeath_New",
        ) or std.ascii.eqlIgnoreCase(
            item.function,
            "Sanchez_New",
        ) or std.ascii.eqlIgnoreCase(item.function, "TwoFeathers_New")) {
            self.fov = 8146;
            self.health = 6;
            self.move_inaccuracy = 5;
            self.weapon_inaccuracy = 1;
            self.activate_radius = 200;
            self.taunt_timer_time = 15000;
        } else if (std.ascii.eqlIgnoreCase(item.function, "Marshal_New")) {
            self.health = 5;
            self.move_inaccuracy = 10;
            self.weapon_inaccuracy = 2;
            self.activate_radius = 100;
        } else if (std.ascii.eqlIgnoreCase(item.function, "Bob_New")) {
            self.fov = 8146;
            self.shoot_chor = 34;
            self.health = 6;
            self.move_inaccuracy = 0;
            self.weapon_inaccuracy = 0;
            self.taunt_timer_time = 15000;
        }

        try self.fields(a, archives, item, 0);
        self.weapon_mode = try loadWeapon(a, archives, self.weapon);
        self.scaleDifficulty(difficulty);

        return self;
    }

    fn fields(
        self: *Config,
        a: std.mem.Allocator,
        archives: []const lab.Archive,
        item: *const Item,
        depth: usize,
    ) !void {
        if (depth >= 32) return error.InvalidEnemyInheritance;

        if (try item.stringValue("INHERIT")) |name| {
            if (try find(archives, name)) |bytes| {
                var parent = try Item.parse(a, bytes);
                defer parent.deinit();
                try self.fields(a, archives, &parent, depth + 1);
            }
        }

        if (try item.stringValue("WEAPON")) |name| {
            inline for (std.meta.fields(Weapon)) |field| {
                if (std.ascii.eqlIgnoreCase(name, field.name)) {
                    self.weapon = @enumFromInt(field.value);
                    self.hitscan = self.weapon != .fist;
                }
            }
        }

        self.radius = item.floatValue("RADIUS") orelse self.radius;
        self.height = item.floatValue("HEIGHT") orelse self.height;

        inline for (.{
            "min_follow_dist",
            "max_follow_dist",
            "walk_speed",
            "run_speed",
            "fov_dist",
            "health",
            "move_inaccuracy",
            "weapon_inaccuracy",
            "panic_inaccuracy",
            "activate_radius",
            "confidence",
            "panic_rate",
            "max_step",
            "max_drop",
            "kill_dist",
            "damage",
            "throw_max",
            "throw_min",
            "throw_velocity",
        }) |name| {
            if (item.floatValue(name)) |value| {
                if (!std.math.isFinite(value)) return error.InvalidEnemyConfig;
                @field(self, name) = value;
            }
        }

        inline for (.{
            "shoot_chor",
            "walk_chor",
            "chest_die_chor",
            "hit_chor",
            "watch_chor",
            "duck_chor",
            "leg_die_chor",
            "left_die_chor",
            "right_die_chor",
            "run_chor",
            "walk_shoot_chor",
            "run_shoot_chor",
            "base_mode",
        }) |name| {
            if (item.intValue(name)) |value| @field(self, name) = @bitCast(value);
        }

        if (item.intValue("AGGRESSIVENESS")) |value| self.aggressiveness = value;

        if (item.intValue("AGRESSIVENESS")) |value| self.aggressiveness = value;

        if (item.intValue("SHOT_MULTIPLES")) |value| self.shot_multiples = value;

        inline for (.{
            "los_timer_time",
            "watch_timer_time",
            "reaquire_timer_time",
            "shoot_timer_time",
            "taunt_timer_time",
            "duck_timer_time",
        }) |name| {
            if (item.floatValue(
                name,
            )) |value| @field(self, name) = @bitCast(try truncI32(@as(f64, value) * 1000));
        }

        inline for (.{ "radial_variance", "fov" }) |name| {
            if (item.floatValue(
                name,
            )) |value| @field(self, name) = @truncate(try truncI32(@as(f64, value) * 45.5112));
        }

        inline for (.{
            "shoot_sound",
            "drop_item",
            "throw_item",
            "hit_sound",
            "die_sound",
        }) |name| {
            if (try item.stringValue(name)) |value| {
                if (value.len >= 32) return error.InvalidEnemyResourceName;

                @field(
                    self,
                    name,
                ) = if (std.ascii.eqlIgnoreCase(value, "NULL")) "" else try a.dupe(u8, value);
            }
        }

        inline for (.{ "los_taunts", "no_los_taunts", "alert_taunts" }) |name| {
            if (try item.stringValue(name)) |value| {
                if (@field(self, name).len != 0) return error.DuplicateEnemyTaunts;

                var list: std.ArrayList([]const u8) = .empty;
                var tokens = std.mem.tokenizeAny(u8, value, ", ");

                while (tokens.next()) |sound| {
                    if (sound.len >= 32) return error.InvalidEnemyResourceName;
                    try list.append(a, try a.dupe(u8, sound));
                }

                @field(self, name) = try list.toOwnedSlice(a);
            }
        }
    }

    fn scaleDifficulty(self: *Config, difficulty: u32) void {
        const Factors = struct {
            speed: f32,
            shoot: f32,
            health: f32,
            move: f32,
            weapon: f32,
            confidence: f32,
            aggression: f32,
            damage: f32,
        };

        const factors: Factors = switch (difficulty) {
            0x100000 => .{
                .speed = 0.8,
                .shoot = 2,
                .health = 1,
                .move = 2,
                .weapon = 2,
                .confidence = 0.3,
                .aggression = 0.3,
                .damage = 0.8,
            },
            0x400000 => .{
                .speed = 1.2,
                .shoot = 0.5,
                .health = 1,
                .move = 0.75,
                .weapon = 0.75,
                .confidence = 1.7,
                .aggression = 1,
                .damage = 2.8,
            },
            0x800000 => .{
                .speed = 1.4,
                .shoot = 1.5,
                .health = 1,
                .move = 1,
                .weapon = 1,
                .confidence = 1.6,
                .aggression = 1.3,
                .damage = 4,
            },
            else => .{
                .speed = 1,
                .shoot = 2,
                .health = 0.75,
                .move = 0.75,
                .weapon = 0.75,
                .confidence = 1,
                .aggression = 0.75,
                .damage = 2.5,
            },
        };

        self.walk_speed = f(@as(f64, self.walk_speed) * factors.speed);
        self.run_speed = f(@as(f64, self.run_speed) * factors.speed);
        self.shoot_timer_time = @truncate(
            @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.shoot_timer_time)) * factors.shoot)),
        );

        self.health = f(@as(f64, self.health) * factors.health);
        self.move_inaccuracy = f(@as(f64, self.move_inaccuracy) * factors.move);
        self.weapon_inaccuracy = f(@as(f64, self.weapon_inaccuracy) * factors.weapon);
        self.confidence = f(@as(f64, self.confidence) * factors.confidence);
        self.aggressiveness = std.math.clamp(
            @as(
                i32,
                @truncate(
                    @as(
                        i64,
                        @intFromFloat(
                            @as(f64, @floatFromInt(self.aggressiveness)) * factors.aggression,
                        ),
                    ),
                ),
            ),
            0,
            8,
        );

        self.damage = f(@as(f64, self.damage) * factors.damage);
    }
};

pub fn loadWeapon(
    a: std.mem.Allocator,
    archives: []const lab.Archive,
    selected: Config.Weapon,
) !WeaponMode {
    var result: WeaponMode = .{};

    if (try find(archives, "ipistol.itm")) |bytes| result = try weaponFields(a, bytes);

    const override: ?[]const u8 = switch (selected) {
        .pistol => null,
        .shotgun => "bgsgun.itm",
        .fist => "bgfist.itm",
        .weapon0 => "weapon0.itm",
        .weapon1 => "weapon1.itm",
        .weapon2 => "weapon2.itm",
        .weapon3 => "weapon3.itm",
        .weapon4 => "weapon4.itm",
        .weapon5 => "weapon5.itm",
        .weapon6 => "weapon6.itm",
        .weapon7 => "weapon7.itm",
        .weapon8 => "weapon8.itm",
        .weapon9 => "weapon9.itm",
    };

    if (override) |name| {
        if (try find(archives, name)) |bytes| result = try weaponFields(a, bytes);
    }

    return result;
}

fn weaponFields(a: std.mem.Allocator, bytes: []const u8) !WeaponMode {
    var item = try Item.parse(a, bytes);
    defer item.deinit();
    var result: WeaponMode = .{};

    inline for (.{
        .{ "RANGE_1", "range" },
        .{ "EFFRANGE_1", "effective_range" },
        .{ "SPREAD_1", "spread" },
        .{ "VARIANCE_1", "variance" },
        .{ "RATE_1", "rate" },
        .{ "MASS_1", "mass" },
        .{ "DAMAGE_1", "damage" },
    }) |field| {
        if (item.floatValue(field[0])) |value| {
            if (!std.math.isFinite(value)) return error.InvalidEnemyWeapon;
            @field(result, field[1]) = value;
        }
    }

    return result;
}

fn find(archives: []const lab.Archive, name: []const u8) !?[]const u8 {
    for (archives) |archive| return archive.find(name, 0) catch |err| switch (err) {
        error.ResourceNotFound => continue,
        else => return err,
    };

    return null;
}

fn truncI32(value: f64) !i32 {
    if (!std.math.isFinite(
        value,
    ) or value < -2147483648 or value >= 2147483648) return error.InvalidEnemyConfig;

    return @intFromFloat(value);
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
