//! The player's flag word: where the body is, which pose sequence is
//! playing, and whether the player is dead or carrying a lit lamp.
//!
//! The movement code and the inventory each keep a copy and hand it back
//! and forth.

const std = @import("std");

const bits = @import("../util/bits.zig");

pub const PlayerFlags = packed struct(u32) {
    unused_0: u2 = 0,
    on_ground: bool = false,
    /// Riding a rail: steering follows the rail guide walls.
    on_rail: bool = false,
    /// Which pose sequence was last chosen, so it isn't restarted each
    /// frame. At most one standing pose and one crouching pose are set.
    pose: Pose = .{},
    unused_10: u2 = 0,
    dying: bool = false,
    /// Left the floor by jumping; lets the body climb higher steps while
    /// still rising.
    jumped: bool = false,
    wading: bool = false,
    /// Head under water: the lamp can't be lit and drowning counts up.
    underwater: bool = false,
    unused_16: u12 = 0,
    dead: bool = false,
    lamp_on: bool = false,
    unused_30: u2 = 0,

    pub const new: PlayerFlags = .{ .on_ground = true };

    pub fn land(self: *PlayerFlags) void {
        self.on_ground = true;
        self.jumped = false;
    }

    pub fn jump(self: *PlayerFlags) void {
        self.on_ground = false;
        self.jumped = true;
    }
};

pub const Pose = packed struct(u6) {
    stand: bool = false,
    walk: bool = false,
    run: bool = false,
    crouch_stand: bool = false,
    crouch_walk: bool = false,
    crouch_run: bool = false,

    pub const standing: Pose = .{ .stand = true, .walk = true, .run = true };

    pub const crouching: Pose = .{
        .crouch_stand = true,
        .crouch_walk = true,
        .crouch_run = true,
    };
};

test "player flag bits keep their saved positions" {
    try std.testing.expectEqual(@as(u32, 4), bits.word(PlayerFlags.new));
    try std.testing.expectEqual(@as(u32, 0x8), bits.word(PlayerFlags{ .on_rail = true }));
    try std.testing.expectEqual(@as(u32, 0x70), bits.word(PlayerFlags{ .pose = Pose.standing }));
    try std.testing.expectEqual(@as(u32, 0x380), bits.word(PlayerFlags{ .pose = Pose.crouching }));
    try std.testing.expectEqual(@as(u32, 0x1000), bits.word(PlayerFlags{ .dying = true }));
    try std.testing.expectEqual(@as(u32, 0x10000000), bits.word(PlayerFlags{ .dead = true }));
    try std.testing.expectEqual(@as(u32, 0x20000000), bits.word(PlayerFlags{ .lamp_on = true }));
}
