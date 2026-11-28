//! Saving pickups.
//!
//! Whether a pickup is enabled is deliberately not in the record - a
//! restored pickup takes that from the level. The three signed shorts are
//! all restored, so a pickup keeps its exact placement.

const std = @import("std");

const GameType = @import("../game_type.zig").GameType;
const lab = @import("../assets/lab.zig");
const inventory = @import("../player/inventory.zig");
const cmm = @import("../script/cmm.zig");
const sound = @import("sound.zig");
const stream = @import("stream.zig");

pub const Entry = struct { name: []const u8, count: i16, slot: i16, message: i16 };

pub const Record = struct {
    entries: []const Entry,
    sound: ?sound.Record,
    flags: i16,

    pub fn write(self: Record, writer: *stream.Writer) !void {
        if (self.entries.len > std.math.maxInt(i16)) return error.InvalidSavedPickupCount;

        try writer.integer(i16, @intCast(self.entries.len));
        try sound.write(writer, self.sound);
        try writer.integer(i16, self.flags);

        for (self.entries) |entry| {
            try writer.string(entry.name);
            try writer.integer(i16, entry.count);
            try writer.integer(i16, entry.message);
            try writer.integer(i16, entry.slot);
        }
    }

    pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !Record {
        const count = try reader.integer(i16);
        if (count < 0) return error.InvalidSavedPickupCount;

        const entries = try a.alloc(Entry, @intCast(count));
        const resource = try sound.read(reader, a);
        const flags = try reader.integer(i16);
        var buffer: [31]u8 = undefined;

        for (entries) |*entry| {
            entry.* = .{
                .name = try a.dupe(u8, try reader.string(&buffer)),
                .count = try reader.integer(i16),
                .message = try reader.integer(i16),
                .slot = try reader.integer(i16),
            };

            if (entry.slot < 0 or entry.slot >= 26) return error.InvalidInventorySlot;
        }

        return .{ .entries = entries, .sound = resource, .flags = flags };
    }
};

pub const Instant = struct {
    sound: ?sound.Record,
    health_bonus: u8,
    message: i32,

    pub fn write(self: Instant, writer: *stream.Writer) !void {
        try sound.write(writer, self.sound);
        try writer.integer(u8, self.health_bonus);
        try writer.integer(i32, self.message);
    }

    pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !Instant {
        return .{
            .sound = try sound.read(reader, a),
            .health_bonus = try reader.integer(u8),
            .message = try reader.integer(i32),
        };
    }
};

pub fn captureInstant(audio: anytype, pickup: inventory.Pickup) !Instant {
    if (pickup.function != .instant_ground_object) return error.InvalidInstantPickup;

    return .{
        .sound = try sound.capture(audio, pickup.sound),
        .health_bonus = pickup.health_bonus,
        .message = pickup.message,
    };
}

pub fn restoreInstant(audio: anytype, record: Instant) !inventory.Pickup {
    return .{
        .function = .instant_ground_object,
        .health_bonus = record.health_bonus,
        .message = record.message,
        .sound = try sound.restore(audio, record.sound),
        .sound_names_resolved = true,
    };
}

pub fn capture(a: std.mem.Allocator, audio: anytype, pickup: inventory.Pickup) !Record {
    const entries = try a.alloc(Entry, pickup.entries.len);

    for (entries, pickup.entries) |*entry, value| entry.* = .{
        .name = value.name,
        .count = value.count,
        .slot = value.slot,
        .message = value.message,
    };

    return .{
        .entries = entries,
        .sound = try sound.capture(audio, pickup.sound),
        .flags = @bitCast(pickup.flags),
    };
}

pub fn restore(
    a: std.mem.Allocator,
    archives: []const lab.Archive,
    audio: anytype,
    native: cmm.Native,
    game_type: GameType,
    record: Record,
) !inventory.Pickup {
    const entries = try a.alloc(inventory.Entry, record.entries.len);

    for (entries, record.entries) |*entry, value| entry.* = .{
        .name = try a.dupe(u8, value.name),
        .count = value.count,
        .slot = value.slot,
        .message = value.message,
    };

    return .{
        .function = native,
        .entries = entries,
        .allocator = a,
        .archives = try a.dupe(lab.Archive, archives),
        .game_type = game_type,
        .sound = try sound.restore(audio, record.sound),
        .sound_names_resolved = true,
        .flags = @bitCast(record.flags),
        .enabled = true,
    };
}
