//! What the game expects of a network driver, in one place: the session
//! tag, the buffer sizes, must-arrive messages with their counter and
//! resends, and the timeout after which a silent client is dropped.
//!
//! These are the promises any driver has to keep. The driver this build uses
//! is platform/enet_driver.zig; nothing here talks to a socket.

const std = @import("std");

const message = @import("message.zig");

pub const application = "LEC-OL-B22";

/// The value written to the "Network Driver" setting. The data expects a
/// driver file name here, so it keeps the name the game shipped with.
pub const settings_name = "LECWSOCK.DLL";

pub const port: u16 = 5310;

pub const max_data = 0x800 - 0x10;

pub const waiting_messages = 0x80 - 1;

pub const max_players = 0x40;

pub const silence_ms = 150000;

pub const goodbye_ms = 5000;

pub const must_arrive: u8 = 1;

pub const player_gone = "SD";

pub const session_ended = "SE";

pub fn isEveryone(address: ?*const message.Address) bool {
    const to = address orelse return true;

    return std.mem.readInt(u32, to[0..4], .little) == 0;
}

test "an address with a zero first word means everyone" {
    try std.testing.expect(isEveryone(null));
    var address: message.Address = @splat(0);
    address[5] = 1;
    try std.testing.expect(isEveryone(&address));
    address[0] = 1;

    try std.testing.expect(!isEveryone(&address));
    try std.testing.expect(!isEveryone(&message.no_address));
}
