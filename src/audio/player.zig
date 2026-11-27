//! The player's own sounds - footsteps, pain, death - as named resources
//! with handles.
//!
//! Names come from the character definition, truncated to fifteen bytes, and
//! are copied so that requests stay valid after the parsed definition is
//! freed.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const inventory = @import("../player/inventory.zig");

const Name = struct {
    bytes: [16]u8 = @splat(0),

    fn init(value: []const u8) Name {
        var result: Name = .{};
        const count = @min(value.len, 15);
        @memcpy(result.bytes[0..count], value[0..count]);

        return result;
    }

    fn slice(self: *const Name) []const u8 {
        return self.bytes[0..std.mem.indexOfScalar(u8, &self.bytes, 0).?];
    }
};

pub const Voice = enum {
    jump,
    land,
    land_light,
    hit_head,
    tired,
    crunch,
    die,
    shriek,
    splash,
    gasp,
    choke,
    water_die,
    crush,
    splat,
};

pub const Config = struct {
    names: [14]Name,
    foot_volume: i32,

    pub fn fromItem(item: *const Item) !Config {
        var result: Config = .{
            .names = undefined,
            .foot_volume = item.intValue("VOL_FEET") orelse 127,
        };

        for ([_][]const u8{
            "SND_JUMP",
            "SND_LAND",
            "SND_LANDLT",
            "SND_HITHEAD",
            "SND_TIRED",
            "SND_CRUNCH",
            "SND_DIE",
            "SND_SHRIEK",
            "SND_SPLASH",
            "SND_GASP",
            "SND_CHOKE",
            "SND_WATERDIE",
            "SND_CRUSH",
            "SND_SPLAT",
        }, [_][]const u8{
            "jajump.wav",
            "land.wav",
            "landlite.wav",
            "hithead.wav",
            "tired.wav",
            "crunch.wav",
            "jadie.wav",
            "shriek.wav",
            "smsplash.wav",
            "gasp.wav",
            "choke.wav",
            "waterdie.wav",
            "crush.wav",
            "splat.wav",
        }, &result.names) |field, fallback, *name| {
            name.* = Name.init((try item.stringValue(field)) orelse fallback);
        }

        return result;
    }
};

pub const State = struct { tired_elapsed: f32 = 0 };

pub const Context = struct {
    config: *const Config,
    state: *State,
    effects: *inventory.Effects,
    rail: ?*@import("rail.zig").Context = null,

    pub fn voice(self: *Context, which: Voice) !void {
        const name = self.config.names[@intFromEnum(which)].slice();
        if (name.len == 0) return;

        try self.effects.append(.{
            .sound = .{ .basename = name, .priority = 64, .volume = 127, .flags = 0 },
        });
    }

    pub fn landing(self: *Context, impact_y: f32, local_y: f32, jump_velocity: f32) !void {
        if (@abs(@as(f64, impact_y)) > @as(f64, jump_velocity) * @as(f32, 1.8)) {
            try self.voice(.land);
        } else if (@abs(@as(f64, local_y)) > @as(f64, jump_velocity) * @as(f32, 0.2)) {
            try self.voice(.land_light);
        }
    }

    pub fn headHit(self: *Context, local_y: f32, jump_velocity: f32) !void {
        if (@as(f64, jump_velocity) * @as(f32, 1.8) < @abs(@as(f64, local_y)))
            try self.voice(.hit_head);
    }

    pub fn footstep(self: *Context, floor_sound: []const u8) !void {
        if (floor_sound.len == 0) return;

        try self.effects.append(.{
            .sound = .{
                .basename = floor_sound,
                .priority = 32,
                .volume = self.config.foot_volume,
                .flags = 4,
            },
        });
    }

    pub fn tired(self: *Context, energy: f32, seconds: f32) !void {
        if (@as(i32, @bitCast(energy)) < 0x42480000) {
            const elapsed = @as(f64, self.state.tired_elapsed) + seconds;
            self.state.tired_elapsed = @floatCast(elapsed);
            if (elapsed <= 1.5) return;
            try self.voice(.tired);
        }

        self.state.tired_elapsed = 0;
    }
};

test "player audio constructor retains defaults and owns truncated CID names" {
    var defaults = try Item.parse(std.testing.allocator, "ITEM 1.0\n");
    defer defaults.deinit();
    const fallback = try Config.fromItem(&defaults);

    try std.testing.expectEqual(@as(i32, 127), fallback.foot_volume);

    for (fallback.names, [_][]const u8{
        "jajump.wav",
        "land.wav",
        "landlite.wav",
        "hithead.wav",
        "tired.wav",
        "crunch.wav",
        "jadie.wav",
        "shriek.wav",
        "smsplash.wav",
        "gasp.wav",
        "choke.wav",
        "waterdie.wav",
        "crush.wav",
        "splat.wav",
    }) |name, expected|
        try std.testing.expectEqualStrings(expected, name.slice());

    var item = try Item.parse(std.testing.allocator,
        \\ITEM 1.0
        \\DATA 6
        \\STR SND_JUMP long_jump_sound_name.wav
        \\STR SND_LAND hard.wav
        \\STR SND_LANDLT soft.wav
        \\STR SND_HITHEAD head.wav
        \\STR SND_TIRED breath.wav
        \\INT VOL_FEET 50
    );

    const config = try Config.fromItem(&item);

    item.deinit();
    try std.testing.expectEqual(@as(i32, 50), config.foot_volume);

    for (config.names, [_][]const u8{
        "LONG_JUMP_SOUND",
        "HARD.WAV",
        "SOFT.WAV",
        "HEAD.WAV",
        "BREATH.WAV",
        "crunch.wav",
        "jadie.wav",
        "shriek.wav",
        "smsplash.wav",
        "gasp.wav",
        "choke.wav",
        "waterdie.wav",
        "crush.wav",
        "splat.wav",
    }) |name, expected|
        try std.testing.expectEqualStrings(expected, name.slice());
}
