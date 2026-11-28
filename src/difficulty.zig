//! The picked difficulty is one bit of `Difficulties`, shifted up 20 places.

const std = @import("std");

const bits = @import("util/bits.zig");

pub const Difficulty = enum(u32) {
    good = 0x100000,
    bad = 0x200000,
    /// Enemies are tuned for it, but no menu or save picks it, maybe was intended but never implemented?
    /// The engine never reads this bit, but it is preserved in saves and network packets.
    unpicked = 0x400000,
    ugly = 0x800000,

    pub fn fromSelection(index: i32) !Difficulty {
        return switch (index) {
            0 => .good,
            1 => .bad,
            2 => .ugly,
            else => error.InvalidDifficulty,
        };
    }

    /// Only the menu's choices are accepted.
    pub fn fromWord(value: u32) !Difficulty {
        return switch (value) {
            0x100000 => .good,
            0x200000 => .bad,
            0x800000 => .ugly,
            else => error.InvalidDifficulty,
        };
    }

    pub fn set(self: Difficulty) Difficulties {
        return bits.from(Difficulties, @intCast(@intFromEnum(self) >> 20));
    }
};

pub const Difficulties = packed struct(u4) {
    good: bool = false,
    bad: bool = false,
    unpicked: bool = false,
    ugly: bool = false,

    pub const all: Difficulties = .{ .good = true, .bad = true, .unpicked = true, .ugly = true };
};

test "a difficulty is its bit in the set" {
    try std.testing.expectEqual(Difficulties{ .good = true }, Difficulty.good.set());
    try std.testing.expectEqual(Difficulties{ .unpicked = true }, Difficulty.unpicked.set());
    try std.testing.expectEqual(Difficulties{ .ugly = true }, Difficulty.ugly.set());
    try std.testing.expectEqual(Difficulty.ugly, try Difficulty.fromWord(0x800000));
    try std.testing.expectError(error.InvalidDifficulty, Difficulty.fromWord(0x400000));
}
