//! Saving projectiles in flight: their state and their absolute deadline.
//!
//! Fuse handles, the descriptor's rate and range, and the global explosion
//! sender are not stored - they come back from the definitions.

const std = @import("std");
const stream = @import("stream.zig");
const pickup = @import("pickup.zig");
const runtime = @import("../projectile/runtime.zig");
const inventory = @import("../player/inventory.zig");
const Actor = @import("../render/objects.zig").Actor;

pub const Record = struct {
    kind: runtime.Kind,
    held: bool,
    explode: bool,
    deadline: u32,
    owner_id: u32,
    damage: f32,
    mass: f32,
    bounced: bool,
    pickup: ?pickup.Record,
    configuration: []const u8,

    pub fn write(self: Record, writer: *stream.Writer) !void {
        try writer.integer(u32, @intFromEnum(self.kind));
        try writer.boolean(self.held);
        try writer.boolean(self.explode);
        try writer.integer(u32, self.deadline);
        try writer.integer(u32, self.owner_id);
        try writer.float(self.damage);
        try writer.float(self.mass);
        try writer.boolean(self.bounced);
        try writer.boolean(self.pickup != null);
        if (self.pickup) |value| try value.write(writer);
        try writer.string(self.configuration);
    }

    pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !Record {
        var value: Record = undefined;
        value.kind = switch (try reader.integer(u32)) {
            2 => .knife,
            3 => .explosive,
            else => return error.InvalidSavedProjectileKind,
        };
        value.held = try reader.boolean();
        value.explode = try reader.boolean();
        value.deadline = try reader.integer(u32);
        value.owner_id = try reader.integer(u32);
        value.damage = try reader.float();
        value.mass = try reader.float();
        value.bounced = try reader.boolean();
        value.pickup = if (try reader.boolean()) try pickup.Record.read(reader, a) else null;
        var buffer: [127]u8 = undefined;
        value.configuration = try a.dupe(u8, try reader.string(&buffer));
        return value;
    }
};

pub const Restored = struct { state: runtime.State, pickup: ?inventory.Pickup };

pub fn capture(session: anytype, scratch: std.mem.Allocator, state: runtime.State, ground: ?inventory.Pickup) !Record {
    return .{ .kind = state.descriptor.kind, .held = state.held, .explode = state.explode, .deadline = state.deadline, .owner_id = try session.savedActorId(state.descriptor.owner), .damage = state.descriptor.damage, .mass = state.descriptor.mass, .bounced = state.bounced, .pickup = if (ground) |value| try pickup.capture(scratch, session.active_audio orelse return error.MissingSaveAudio, value) else null, .configuration = state.config.name };
}

pub fn restore(session: anytype, record: Record, actor: *const Actor) !Restored {
    const config = try @import("../projectile/session.zig").configuration(session, record.configuration);
    const state: runtime.State = .{ .config = config, .held = record.held, .explode = record.explode, .deadline = record.deadline, .bounced = record.bounced, .pickup = record.pickup != null, .floor_cache = 0, .descriptor = .{ .kind = record.kind, .item = config.name, .owner = try session.sourceForSavedActorId(record.owner_id), .origin = .{ .x = 0, .y = 0, .z = 0 }, .sector = actor.sector, .pitch = 0, .yaw = 0, .damage = record.damage, .mass = record.mass, .rate = 0, .range = 0 } };
    return .{ .state = state, .pickup = if (record.pickup) |value| try pickup.restore(session.arena.allocator(), &.{ session.object_archive, session.weapon_archive, session.system_archive }, session.active_audio orelse return error.MissingSaveAudio, .projectile_dispatch, session.game_type, value) else null };
}
