//! The level script's flag words: what happened (`Events`), each trigger's
//! and elevator's settings, and an elevator's running state.
//! Who may set off a trigger or elevator is an `ActorKind` mask.

const std = @import("std");

const bits = @import("../util/bits.zig");
const Difficulties = @import("../assets/level.zig").Difficulties;

/// What happened to a sector or wall. Wall events come in pairs: the front
/// side gets one bit, the side behind it the next one up.
pub const Events = packed struct(u32) {
    cross_front: bool = false,
    cross_back: bool = false,
    enter_sector: bool = false,
    leave_sector: bool = false,
    nudge_front: bool = false,
    nudge_back: bool = false,
    /// An explosion close enough to the walls.
    explosion: bool = false,
    unused_7: bool = false,
    shot_front: bool = false,
    shot_back: bool = false,
    unused_10: u3 = 0,
    /// Sent by the level script itself: a switch flipping its own wall or a
    /// wall breaking.
    script: bool = false,
    object_script: bool = false,
    /// Inside an explosion's whole blast.
    blast: bool = false,
    unused_16: u16 = 0,

    pub const all: Events = bits.from(Events, 0xffffffff);

    pub const nudge: Events = .{ .nudge_front = true, .nudge_back = true };

    /// The same events seen from behind the wall: each front bit moves to
    /// its back bit. Wraps like the 32-bit shift it is.
    pub fn back(self: Events) Events {
        return bits.from(Events, bits.word(self) *% 2);
    }
};

/// How a trigger or elevator treats the object it is used with.
pub const ObjectRule = packed struct(u4) {
    required: bool = false,
    /// The requirement drops after the first use.
    required_once: bool = false,
    /// The requirement turns off and on with each use.
    required_toggles: bool = false,
    /// Using it takes the selected item out of the inventory.
    uses_up_item: bool = false,

    pub fn fromScript(value: u32) ObjectRule {
        return bits.from(ObjectRule, @truncate(value >> 16));
    }
};

pub const TriggerFlags = packed struct(u32) {
    enabled: bool = false,
    ends_level: bool = false,
    unused_2: u10 = 0,
    /// The required object also counts when it's in the player's inventory.
    required_in_inventory: bool = false,
    /// The excluded object also blocks when it's in the player's inventory.
    excluded_in_inventory: bool = false,
    unused_14: u2 = 0,
    object: ObjectRule = .{},
    difficulties: Difficulties = .all,
    kind: TriggerKind = .wall,

    pub fn init(kind: TriggerKind) TriggerFlags {
        return .{ .enabled = true, .kind = kind };
    }
};

/// What a trigger does to its own wall when it fires. Saves carry the raw
/// number, so unknown numbers survive.
pub const TriggerKind = enum(u8) {
    /// A wall trigger that leaves its wall alone.
    wall = 0x04,
    sector = 0x08,
    /// Shows its pressed frame and turns itself off until it gets reset.
    switch_once = 0x10,
    /// Flips its frame each time and stays on.
    toggle = 0x20,
    /// Flips its frame once and turns itself off.
    single = 0x40,
    glass = 0x80,
    _,

    /// Switches, toggles and single triggers change their wall's frame.
    /// Compared as numbers, as the saved word is.
    pub fn changesWall(self: TriggerKind) bool {
        const value = @intFromEnum(self);

        return value >= @intFromEnum(
            TriggerKind.switch_once,
        ) and value <= @intFromEnum(TriggerKind.single);
    }
};

pub const ElevatorFlags = packed struct(u32) {
    /// Set by the level script's FLAGS: and by the second kind of morphing
    /// elevator; nothing reads them.
    unused_0: u16 = 0,
    object: ObjectRule = .{},
    difficulties: Difficulties = .all,
    /// The required object also counts when it's in the player's inventory.
    required_in_inventory: bool = false,
    /// The excluded object also blocks when it's in the player's inventory.
    excluded_in_inventory: bool = false,
    unused_26: u6 = 0,
};

pub const ElevatorState = packed struct(u32) {
    moving: bool = false,
    enabled: bool = false,
    /// Waits one second at the next stop instead of the stop's own delay.
    /// Only a saved game sets it.
    short_wait: bool = false,
    unused_3: u29 = 0,
};

test "level script flag bits keep their saved positions" {
    try std.testing.expectEqual(@as(u32, 0x1c30), bits.word(Events{
        .nudge_front = true,
        .nudge_back = true,
        .unused_10 = 7,
    }));

    try std.testing.expectEqual(
        @as(u32, 0x8100),
        bits.word(Events{ .shot_front = true, .blast = true }),
    );

    try std.testing.expectEqual(
        @as(u32, 0x202),
        bits.word(Events.back(.{ .cross_front = true, .shot_front = true })),
    );

    try std.testing.expectEqual(@as(u32, 0x2000), bits.word(Events{ .script = true }));
    try std.testing.expectEqual(@as(u32, 0x4000), bits.word(Events{ .object_script = true }));
    try std.testing.expectEqual(@as(u32, 0x80f00001), bits.word(TriggerFlags.init(.glass)));
    try std.testing.expectEqual(
        @as(u32, 0x1000),
        bits.word(
            TriggerFlags{
                .required_in_inventory = true,
                .difficulties = .{},
                .kind = @enumFromInt(0),
            },
        ),
    );

    try std.testing.expectEqual(
        @as(u32, 0x10000),
        bits.word(ElevatorFlags{ .object = .{ .required = true }, .difficulties = .{} }),
    );

    try std.testing.expectEqual(@as(u32, 0xf00000), bits.word(ElevatorFlags{}));
    try std.testing.expectEqual(
        @as(u32, 0x1000000),
        bits.word(ElevatorFlags{ .required_in_inventory = true, .difficulties = .{} }),
    );

    try std.testing.expectEqual(
        ObjectRule{ .required = true, .uses_up_item = true },
        ObjectRule.fromScript(0x90000),
    );

    try std.testing.expect(TriggerKind.toggle.changesWall());
    try std.testing.expect(!TriggerKind.glass.changesWall());
}
