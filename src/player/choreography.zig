//! The player's choreography numbers - which sequence plays for standing,
//! walking, dying and so on - and the choice made at the end of each
//! update.
//!
//! The numbers start as defaults and are then overridden by the character's
//! item definition, stored as 16-bit values. Each new choice goes through
//! the actor's sequence setter, which the caller does.

const std = @import("std");
const item_asset = @import("../assets/item.zig");

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

pub fn select(flags: *u32, table: Table, input: Input) ?i16 {
    if (input.dead) {
        if (flags.* & 0x1000 != 0) return null;
        flags.* |= 0x1000;
        return table.die;
    }
    const still = @as(u32, @bitCast(input.speed)) & 0x7fffffff == 0;
    if (!input.crouch and !input.low_ceiling) {
        flags.* &= ~@as(u32, 0x380);
        if (still) return pick(flags, 0x10, 0x60, table.stand);
        if (input.run) return pick(flags, 0x40, 0x30, table.run);
        return pick(flags, 0x20, 0x50, table.walk);
    }
    flags.* &= ~@as(u32, 0x70);
    if (still) return pick(flags, 0x80, 0x300, table.crouch_stand);
    if (input.run) return pick(flags, 0x200, 0x180, table.crouch_stand);
    return pick(flags, 0x100, 0x280, table.crouch_walk);
}

fn pick(flags: *u32, bit: u32, others: u32, value: i16) ?i16 {
    if (flags.* & bit != 0) return null;
    flags.* = flags.* & ~others | bit;
    return value;
}

test "player choreography choice follows" {
    const table: Table = .{ .stand = 100, .walk = 101, .run = 102, .crouch_stand = 103, .crouch_walk = 104, .crouch_run = 105, .die = 106 };
    const Case = struct {
        flags: u32,
        input: Input,
        flags_after: u32,
        chosen: ?i16,
    };
    const cases = [_]Case{
        .{ .flags = 4 | 0x380, .input = .{ .dead = false, .crouch = false, .low_ceiling = false, .speed = 0, .run = false }, .flags_after = 4 | 0x10, .chosen = 100 },
        .{ .flags = 4 | 0x10 | 0x80, .input = .{ .dead = false, .crouch = false, .low_ceiling = false, .speed = -0.0, .run = true }, .flags_after = 4 | 0x10, .chosen = null },
        .{ .flags = 4 | 0x10 | 0x20, .input = .{ .dead = false, .crouch = false, .low_ceiling = false, .speed = 3, .run = false }, .flags_after = 4 | 0x10 | 0x20, .chosen = null },
        .{ .flags = 4 | 0x10, .input = .{ .dead = false, .crouch = false, .low_ceiling = false, .speed = 3, .run = false }, .flags_after = 4 | 0x20, .chosen = 101 },
        .{ .flags = 4 | 0x20, .input = .{ .dead = false, .crouch = false, .low_ceiling = false, .speed = 3, .run = true }, .flags_after = 4 | 0x40, .chosen = 102 },
        .{ .flags = 4, .input = .{ .dead = false, .crouch = false, .low_ceiling = false, .speed = std.math.nan(f32), .run = false }, .flags_after = 4 | 0x20, .chosen = 101 },
        .{ .flags = 4 | 0x70, .input = .{ .dead = false, .crouch = true, .low_ceiling = false, .speed = 0, .run = false }, .flags_after = 4 | 0x80, .chosen = 103 },
        .{ .flags = 4 | 0x80, .input = .{ .dead = false, .crouch = false, .low_ceiling = true, .speed = 2, .run = false }, .flags_after = 4 | 0x100, .chosen = 104 },
        .{ .flags = 4 | 0x100, .input = .{ .dead = false, .crouch = true, .low_ceiling = false, .speed = 2, .run = true }, .flags_after = 4 | 0x200, .chosen = 103 },
        .{ .flags = 4 | 0x200 | 0x80, .input = .{ .dead = false, .crouch = true, .low_ceiling = false, .speed = 2, .run = true }, .flags_after = 4 | 0x200 | 0x80, .chosen = null },
        .{ .flags = 4 | 0x20, .input = .{ .dead = true, .crouch = true, .low_ceiling = false, .speed = 0, .run = false }, .flags_after = 4 | 0x20 | 0x1000, .chosen = 106 },
        .{ .flags = 4 | 0x1000, .input = .{ .dead = true, .crouch = true, .low_ceiling = false, .speed = 0, .run = false }, .flags_after = 4 | 0x1000, .chosen = null },
    };
    for (cases) |case| {
        var flags = case.flags;
        try std.testing.expectEqual(case.chosen, select(&flags, table, case.input));
        try std.testing.expectEqual(case.flags_after, flags);
    }
}

test "player choreography numbers read from the CID with defaults" {
    const a = std.testing.allocator;
    var item = try item_asset.Item.parse(a, "ITEM 1.0\nDATA 3\nINT WALK_CHOR 7\nINT CROUCHRUN_CHOR 65537\nINT DIE_CHOR -2\n");
    defer item.deinit();
    const table = Table.fromItem(&item);
    try std.testing.expectEqual(@as(i16, 0), table.stand);
    try std.testing.expectEqual(@as(i16, 7), table.walk);
    try std.testing.expectEqual(@as(i16, 1), table.run);
    try std.testing.expectEqual(@as(i16, 1), table.crouch_run);
    try std.testing.expectEqual(@as(i16, -2), table.die);
    try std.testing.expectEqual(@as(i16, 0x14), table.hit);
}
