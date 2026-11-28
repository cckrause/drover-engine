//! A level script event as reference fixtures record it: the same fields as
//! `interaction.Event`, but the event bits as a plain number, since JSON
//! can't fill a packed struct.

const std = @import("std");

const bits = @import("../util/bits.zig");
const Event = @import("../script/interaction.zig").Event;

pub const RecordedEvent = struct {
    sector: usize,
    wall: ?usize = null,
    mask: u32,
    object_id: u32 = 0,
    actor: ?usize = null,

    pub fn of(event: Event) RecordedEvent {
        return .{
            .sector = event.sector,
            .wall = event.wall,
            .mask = bits.word(event.mask),
            .object_id = event.object_id,
            .actor = event.actor,
        };
    }
};

/// Fails unless `actual` records as `expected`, event by event.
pub fn expectEvents(expected: []const RecordedEvent, actual: []const Event) !void {
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected, actual) |want, got| try std.testing.expectEqualDeep(want, RecordedEvent.of(got));
}
