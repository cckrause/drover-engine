//! The player's choreography numbers - which sequence plays for standing,
//! walking, dying and so on - and the choice made at the end of each
//! update.
//!
//! The numbers start as defaults and are then overridden by the character's
//! item definition, stored as 16-bit values. Each new choice goes through
//! the actor's sequence setter, which the caller does.

const std = @import("std");

const item_asset = @import("../assets/item.zig");
const bits = @import("../util/bits.zig");
const player_flags = @import("flags.zig");
const PlayerFlags = player_flags.PlayerFlags;
const Pose = player_flags.Pose;

pub const Table = struct {
    stand: i16 = 0,
    walk: i16 = 1,
    run: i16 = 1,
    shoot: i16 = 10,
    punch: i16 = 0xf,
    crouch_stand: i16 = 3,
    crouch_walk: i16 = 3,
    crouch_run: i16 = 3,
    hit: i16 = 0x14,
    die: i16 = 0x15,

    const keys = [_]struct { []const u8, []const u8 }{
        .{ "stand", "STAND_CHOR" },
        .{ "walk", "WALK_CHOR" },
        .{ "run", "RUN_CHOR" },
        .{ "shoot", "SHOOT_CHOR" },
        .{ "punch", "PUNCH_CHOR" },
        .{ "crouch_stand", "CROUCHSTAND_CHOR" },
        .{ "crouch_walk", "CROUCHWALK_CHOR" },
        .{ "crouch_run", "CROUCHRUN_CHOR" },
        .{ "hit", "HIT_CHOR" },
        .{ "die", "DIE_CHOR" },
    };

    pub fn fromItem(item: *const item_asset.Item) Table {
        var table: Table = .{};

        inline for (keys) |key| if (item.intValue(key[1])) |value| {
            @field(table, key[0]) = @bitCast(@as(u16, @truncate(@as(u32, @bitCast(value)))));
        };

        return table;
    }
};

pub const Input = struct {
    dead: bool,
    crouch: bool,
    low_ceiling: bool,
    speed: f32,
    run: bool,
};

/// Picks the pose sequence for this update, or null when the one already
/// playing stays. Each pose plays once until another replaces it, so the
/// flags remember which one was chosen last.
pub fn select(flags: *PlayerFlags, table: Table, input: Input) ?i16 {
    if (input.dead) {
        if (flags.dying) return null;
        flags.dying = true;
        return table.die;
    }

    const still = @as(u32, @bitCast(input.speed)) & 0x7fffffff == 0;
    if (!input.crouch and !input.low_ceiling) {
        flags.pose = bits.without(flags.pose, Pose.crouching);
        if (still) return pick(flags, .{ .stand = true }, table.stand);
        if (input.run) return pick(flags, .{ .run = true }, table.run);
        return pick(flags, .{ .walk = true }, table.walk);
    }

    flags.pose = bits.without(flags.pose, Pose.standing);
    if (still) return pick(flags, .{ .crouch_stand = true }, table.crouch_stand);
    // Crouch-running replays the crouch-stand sequence.
    if (input.run) return pick(flags, .{ .crouch_run = true }, table.crouch_stand);

    return pick(flags, .{ .crouch_walk = true }, table.crouch_walk);
}

/// Sets `pose` in place of the other poses of the same group, unless it is
/// already set.
fn pick(flags: *PlayerFlags, pose: Pose, value: i16) ?i16 {
    if (bits.any(flags.pose, pose)) return null;

    const group = if (bits.any(pose, Pose.standing)) Pose.standing else Pose.crouching;

    flags.pose = bits.with(bits.without(flags.pose, group), pose);

    return value;
}

test "player choreography choice follows" {
    const table: Table = .{
        .stand = 100,
        .walk = 101,
        .run = 102,
        .crouch_stand = 103,
        .crouch_walk = 104,
        .crouch_run = 105,
        .die = 106,
    };

    const Case = struct {
        flags: PlayerFlags,
        input: Input,
        flags_after: PlayerFlags,
        chosen: ?i16,
    };

    const cases = [_]Case{
        .{
            .flags = .{ .on_ground = true, .pose = .{ .crouch_stand = true, .crouch_walk = true, .crouch_run = true } },
            .input = .{
                .dead = false,
                .crouch = false,
                .low_ceiling = false,
                .speed = 0,
                .run = false,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .stand = true } },
            .chosen = 100,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .stand = true, .crouch_stand = true } },
            .input = .{
                .dead = false,
                .crouch = false,
                .low_ceiling = false,
                .speed = -0.0,
                .run = true,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .stand = true } },
            .chosen = null,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .stand = true, .walk = true } },
            .input = .{
                .dead = false,
                .crouch = false,
                .low_ceiling = false,
                .speed = 3,
                .run = false,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .stand = true, .walk = true } },
            .chosen = null,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .stand = true } },
            .input = .{
                .dead = false,
                .crouch = false,
                .low_ceiling = false,
                .speed = 3,
                .run = false,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .walk = true } },
            .chosen = 101,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .walk = true } },
            .input = .{
                .dead = false,
                .crouch = false,
                .low_ceiling = false,
                .speed = 3,
                .run = true,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .run = true } },
            .chosen = 102,
        },
        .{
            .flags = .{ .on_ground = true },
            .input = .{
                .dead = false,
                .crouch = false,
                .low_ceiling = false,
                .speed = std.math.nan(f32),
                .run = false,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .walk = true } },
            .chosen = 101,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .stand = true, .walk = true, .run = true } },
            .input = .{
                .dead = false,
                .crouch = true,
                .low_ceiling = false,
                .speed = 0,
                .run = false,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .crouch_stand = true } },
            .chosen = 103,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .crouch_stand = true } },
            .input = .{
                .dead = false,
                .crouch = false,
                .low_ceiling = true,
                .speed = 2,
                .run = false,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .crouch_walk = true } },
            .chosen = 104,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .crouch_walk = true } },
            .input = .{
                .dead = false,
                .crouch = true,
                .low_ceiling = false,
                .speed = 2,
                .run = true,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .crouch_run = true } },
            .chosen = 103,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .crouch_stand = true, .crouch_run = true } },
            .input = .{
                .dead = false,
                .crouch = true,
                .low_ceiling = false,
                .speed = 2,
                .run = true,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .crouch_stand = true, .crouch_run = true } },
            .chosen = null,
        },
        .{
            .flags = .{ .on_ground = true, .pose = .{ .walk = true } },
            .input = .{
                .dead = true,
                .crouch = true,
                .low_ceiling = false,
                .speed = 0,
                .run = false,
            },
            .flags_after = .{ .on_ground = true, .pose = .{ .walk = true }, .dying = true },
            .chosen = 106,
        },
        .{
            .flags = .{ .on_ground = true, .dying = true },
            .input = .{
                .dead = true,
                .crouch = true,
                .low_ceiling = false,
                .speed = 0,
                .run = false,
            },
            .flags_after = .{ .on_ground = true, .dying = true },
            .chosen = null,
        },
    };

    for (cases) |case| {
        var flags = case.flags;
        try std.testing.expectEqual(case.chosen, select(&flags, table, case.input));
        try std.testing.expectEqual(case.flags_after, flags);
    }
}

test "player choreography numbers read from the CID with defaults" {
    const a = std.testing.allocator;
    var item = try item_asset.Item.parse(
        a,
        "ITEM 1.0\nDATA 3\nINT WALK_CHOR 7\nINT CROUCHRUN_CHOR 65537\nINT DIE_CHOR -2\n",
    );

    defer item.deinit();
    const table = Table.fromItem(&item);

    try std.testing.expectEqual(@as(i16, 0), table.stand);
    try std.testing.expectEqual(@as(i16, 7), table.walk);
    try std.testing.expectEqual(@as(i16, 1), table.run);
    try std.testing.expectEqual(@as(i16, 1), table.crouch_run);
    try std.testing.expectEqual(@as(i16, -2), table.die);
    try std.testing.expectEqual(@as(i16, 0x14), table.hit);
}
