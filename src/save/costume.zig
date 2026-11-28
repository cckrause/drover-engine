//! Saving a sprite instance: its playback state and the name it is bound
//! to.
//!
//! The binding pointer and the global instance links are not on disk - a
//! restore creates a fresh instance and links it as the newest.

const std = @import("std");

const bits = @import("../util/bits.zig");
const nwx = @import("../assets/nwx.zig");
const stream = @import("stream.zig");

pub const Instance = struct {
    resource: []const u8,
    playback: nwx.Playback,
    native: []const u8 = "",
};

pub fn write(writer: *stream.Writer, instance: ?Instance) !void {
    try writer.boolean(instance != null);
    const value = instance orelse return;

    try writer.string(value.resource);
    try writer.integer(u32, value.playback.last_time);
    try writer.integer(i16, value.playback.angle_offset);
    try writer.integer(u32, value.playback.direction);
    try writer.integer(u32, value.playback.choreography);
    try writer.integer(u32, value.playback.next_frame);
    try writer.integer(u32, value.playback.frame);
    try writer.integer(u32, bits.word(value.playback.flags));
    try writer.boolean(value.playback.terminated);
    try writer.string(value.native);
}

pub fn read(reader: *stream.Reader, allocator: std.mem.Allocator) !?Instance {
    if (!try reader.boolean()) return null;

    var buffer: [255]u8 = undefined;
    const resource = try allocator.dupe(u8, try reader.string(&buffer));
    errdefer allocator.free(resource);
    const playback: nwx.Playback = .{
        .last_time = try reader.integer(u32),
        .angle_offset = try reader.integer(i16),
        .direction = try reader.integer(u32),
        .choreography = try reader.integer(u32),
        .next_frame = try reader.integer(u32),
        .frame = try reader.integer(u32),
        .flags = bits.from(nwx.PlaybackFlags, try reader.integer(u32)),
        .terminated = try reader.boolean(),
    };

    const binding = try reader.string(&buffer);
    if (binding.len > 32) return error.InvalidSavedWaxBinding;

    const native = try allocator.dupe(u8, binding);

    return .{ .resource = resource, .playback = playback, .native = native };
}
