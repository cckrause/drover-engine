//! Which mouse buttons are down. The platform layer fills it from the
//! host's own button word; menus and player input only read the names.

const std = @import("std");

const bits = @import("util/bits.zig");

pub const MouseButtons = packed struct(u5) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    /// The side buttons some mice have.
    back: bool = false,
    forward: bool = false,

    pub fn any(self: MouseButtons) bool {
        return bits.word(self) != 0;
    }
};

test "no buttons is not any" {
    try std.testing.expect(!(MouseButtons{}).any());
    try std.testing.expect((MouseButtons{ .back = true }).any());
}
