//! Actors that belong to another machine: the answer to an object request,
//! the copies made for actors created elsewhere, deletions, and the dead
//! reckoning that moves another machine's player.
//!
//! A copy is driven by the owner's updates, never by local logic, and the
//! remote player gets its own logic function so it animates like a player
//! instead of standing still.

const std = @import("std");
const message = @import("../network/message.zig");
const dead_reckoning = @import("../network/dead_reckoning.zig");
const cmm = @import("../script/cmm.zig");
const save_actor = @import("../save/actor.zig");
const nwx = @import("../assets/nwx.zig");
const level_module = @import("../assets/level.zig");
const enemy_session = @import("../enemy/session.zig");
const item_spawn = @import("../enemy/item_spawn.zig");
const network_level = @import("network_level.zig");
const Actor = @import("objects.zig").Actor;
const local_player = @import("../player/shooting.zig").local_player;
const collision = @import("../player/collision.zig");
const blood = @import("../enemy/blood.zig");
const enemy_dynamic = @import("../enemy/dynamic.zig");
const inventory = @import("../player/inventory.zig");
const network_combat = @import("network_combat.zig");

pub const remote_logic = "DRECK_PEX";

pub const RemotePlayer = struct {
    source: usize,
    record: ?dead_reckoning.Record = null,
    floor_cache: f32 = -0x1p31,
    wall_memory: collision.WallMemory = .{},
    tint_flags: u8 = 0,
    tint_due: u32 = 0,
};

const Listed = union(enum) { player, actor: usize };

pub const RemoteWax = struct {
    pub fn event(_: *RemoteWax, _: *nwx.Playback, _: *const nwx.Costume, _: u32, _: []const u32, _: u32) !void {}
};

pub fn answerObjectRequest(session: anytype, sender: u32) !void {
    const router = session.router;
    const client: u16 = @truncate(message.client(sender));
    const order = try globalOrder(session);
    defer session.allocator.free(order);
    const table = try router.newMultiplex(client);
    const previous = router.multiplex;
    router.multiplex = table;
    {
        errdefer {
            router.multiplex = previous;
            table.destroy(router.allocator);
        }
        for (order) |listed| {
            const number = switch (listed) {
                .player => session.player_number,
                .actor => |source| session.actor_numbers[source],
            };
            if (message.client(number) != router.own_client) continue;
            try answer(session, listed, sender);
            switch (listed) {
                .player => {},
                .actor => |source| try logicMessage(session, source, 0x402, null),
            }
        }
    }
    router.multiplex = previous;
    router.queueMultiplex(table);
    try network_level.sendArchitecture(session, client);
}

pub fn sendActor(session: anytype, source: usize, destination: u32) !void {
    const actor = session.actor_slots[source] orelse return error.MissingNetworkActor;
    const number = session.actor_numbers[source];
    if (message.client(number) != session.router.own_client or actor.flags & 0x8000 != 0) return;
    const record = try save_actor.capture(session, actor, 0);
    var animation: i32 = 0;
    if (record.kind == 1) animation = if (record.wax) |instance| @intCast(instance.playback.choreography) else -1;
    if (animation == -1 or actor.secondary_flags & 0x10 != 0) {
        if (actor.flags & 0x20 != 0) return error.NetworkActorPlayerRecordNotPorted;
    }
    if (animation == -1) animation = 0;
    if (actor.secondary_flags & 0x30 != 0) return error.NetworkPlayerActorNotPorted;
    var costume_buffer: [0x100]u8 = undefined;
    if (record.resource.len >= costume_buffer.len) return error.MalformedNetworkMessage;
    const costume = std.ascii.upperString(costume_buffer[0..record.resource.len], record.resource);
    if (costume.len == 0) return;
    var buffer: [message.actor_create_capacity]u8 = undefined;
    const bytes = try message.actorCreate(&buffer, session.router.own_client, .{
        .sector = @intCast(actor.sector),
        .animation = @truncate(@as(u32, @bitCast(animation))),
        .number = number,
        .flags = record.flags,
        .position = .{ @bitCast(record.position.x), @bitCast(record.position.y), @bitCast(record.position.z) },
        .angles = record.angles,
        .kind = @truncate(record.kind),
        .short_70 = @bitCast(record.angle_70),
        .short_72 = @bitCast(record.head_yaw),
        .word_74 = @bitCast(record.eye_height),
        .words_7c = .{
            @bitCast(record.vector_7c.x), @bitCast(record.vector_7c.y), @bitCast(record.vector_7c.z),
            @bitCast(record.vector_88.x), @bitCast(record.vector_88.y), @bitCast(record.vector_88.z),
        },
        .word_3c = @bitCast(record.height),
        .word_94 = @bitCast(record.radius),
        .words_40 = .{ @bitCast(record.velocity.x), @bitCast(record.velocity.y), @bitCast(record.velocity.z) },
        .entity = record.secondary_flags,
        .costume = costume,
        .logic = "",
        .item = actor.network_item,
    });
    _ = try session.router.post(destination, 0x3fd | 0x40000000, bytes);
}

pub fn actorMessage(session: anytype, index: usize, bytes: []u8) !void {
    const number = message.get(bytes, message.number_offset);
    const code = number & 0xffff7fff;
    message.set(bytes, message.number_offset, code);
    const previous = if (number & 0x8000 != 0) session.database.swapRepeat(1) else null;
    defer if (previous) |value| {
        session.database.repeating = value;
    };
    const listed: Listed = if (index == local_player) .player else .{ .actor = index };
    switch (code) {
        0x402 => try answer(session, listed, message.get(bytes, message.sender_offset)),
        0x3ff => {
            if (index == local_player) return error.NetworkDeleteOfOwnPlayerNotPorted;
            if (session.game_type == 5 and (session.mode == 1 or session.mode == 3) and remoteOf(session, index) != null)
                return error.HolderDropNotPorted;
            try deleteActor(session, index);
            return;
        },
        0x403 => if (listed != .player) return error.DatabaseObjectMessageNotPorted,
        0x3fc, 0x40c, 0x411, 0x412, 0x41c => return error.DatabaseObjectMessageNotPorted,
        else => {},
    }
    switch (listed) {
        .player => try network_combat.playerMessage(session, bytes),
        .actor => |source| try logicMessage(session, source, code, bytes),
    }
}

pub fn deleteActor(session: anytype, index: usize) !void {
    if (index >= session.actor_slots.len or session.removed_actors[index] or session.actor_slots[index] == null) return error.MissingNetworkActor;
    const number = session.actor_numbers[index];
    if (number != 0) {
        session.database.free(number, session.animation_time);
        session.actor_numbers[index] = 0;
    }
    const logic = session.actor_slots[index].?.logic_name;
    if (session.targets[index] != null) return error.NetworkActorDeleteNotPorted;
    if (logic.len != 0 and !std.mem.eql(u8, logic, remote_logic)) switch (cmm.resolve(logic) catch return error.NetworkActorDeleteNotPorted) {
        .object, .ground_object, .instant_ground_object, .ground_sheriff_star, .ground_vanishing_cream, .projectile_dispatch, .explosive_projectile_dispatch => {},
        else => return error.NetworkActorDeleteNotPorted,
    };
    try enemy_session.removeActor(session, index);
    for (session.remote_players.items, 0..) |entry, position| if (entry.source == index) {
        _ = session.remote_players.orderedRemove(position);
        break;
    };
}

pub fn createItem(session: anytype, name: []const u8, place: @import("../enemy/lifecycle.zig").Placement) !?usize {
    if (session.game_type != 4 and session.game_type != 5) return enemy_session.spawnItem(session, name, place);
    if (std.ascii.eqlIgnoreCase(name, "NULL")) return null;
    const router = session.router;
    if (router.own_client != 1 and router.clientCount() > 1) {
        try @import("../network/database.zig").requestServerCreate(router, .{
            .sector = @intCast(place.sector),
            .position = .{ @bitCast(place.position.x), @bitCast(place.position.y), @bitCast(place.position.z) },
            .kind = 0,
            .name = name,
        });
        return null;
    }
    const source = try enemy_session.spawnItem(session, name, place) orelse return null;
    if (router.clientCount() > 1) try sendActor(session, source, 0);
    return source;
}

pub fn createRequested(session: anytype, value: message.HaveServerCreate) !void {
    const position: level_module.Vec3 = .{ .x = @bitCast(value.position[0]), .y = @bitCast(value.position[1]), .z = @bitCast(value.position[2]) };
    for ([_]f32{ position.x, position.y, position.z }) |coordinate| if (!std.math.isFinite(coordinate)) return error.MalformedNetworkMessage;
    const created = try createItem(session, value.name, .{ .position = position, .sector = value.sector });
    if (created != null and value.kind == 1) return error.ServerCreateKindNotPorted;
}

pub fn createCorpse(session: anytype, value: message.Corpse) !void {
    if (value.sector >= session.level.sectors.len) return error.MalformedNetworkMessage;
    const position: level_module.Vec3 = .{ .x = @bitCast(value.position[0]), .y = @bitCast(value.position[1]), .z = @bitCast(value.position[2]) };
    for ([_]f32{ position.x, position.y, position.z }) |coordinate| if (!std.math.isFinite(coordinate)) return error.MalformedNetworkMessage;
    try enemy_session.networkCorpse(session, value.costume, value.choreography, value.sector, position);
}

pub fn postDelete(router: anytype, number: u32) !void {
    var bytes = message.request(0x3ff, router.own_client);
    message.set(&bytes, message.sender_offset, (router.own_client & 0xff) << 11);
    message.set(&bytes, message.reply_offset, number);
    _ = try router.post(0, 0x3ff | 0x80000000, &bytes);
}

pub fn isRemote(session: anytype, index: usize) bool {
    return remoteOf(session, index) != null;
}

pub fn remoteWax(actor: Actor) bool {
    const binding = actor.wax_binding orelse return false;
    return std.mem.eql(u8, binding, remote_logic);
}

pub fn receiveActorCreate(session: anytype, value: message.ActorCreate) !void {
    if (value.sector >= session.level.sectors.len) return error.MalformedNetworkMessage;
    if (session.database.find(value.number)) |object| switch (object) {
        .actor => |index| try deleteActor(session, index),
        else => return error.NetworkActorOverOtherObject,
    };
    if (value.entity & 0x10 != 0) return createPlayer(session, value);
    if (value.entity & 0x20 != 0) return error.NetworkModelActorNotPorted;
    const position: level_module.Vec3 = .{ .x = @bitCast(value.position[0]), .y = @bitCast(value.position[1]), .z = @bitCast(value.position[2]) };
    for ([_]f32{ position.x, position.y, position.z }) |coordinate| if (!std.math.isFinite(coordinate)) return error.MalformedNetworkMessage;
    if (value.item.len == 0) return;
    const source = try item_spawn.spawnNumbered(session, value.item, .{ .position = position, .sector = value.sector }, value.number) orelse return;
    const actor = &session.actor_slots[source].?;
    actor.pitch = value.angles[0];
    actor.yaw = value.angles[1];
    actor.roll = value.angles[2];
    session.syncActor(source);
}

pub fn advanceWax(actor: *Actor, now: u32) !void {
    const sprite = actor.costume orelse return;
    if (actor.playback) |*playback| {
        var context: RemoteWax = .{};
        try playback.advanceWithContext(sprite, 0, now, &context);
        actor.choreography = playback.choreography;
        actor.frame = playback.frame;
        actor.angle_offset = playback.angle_offset;
    }
}

pub fn schedule(session: anytype, allocator: std.mem.Allocator, effects: *inventory.Effects, index: usize) !void {
    const actor = session.actor_slots[index].?;
    if (actor.flags & 1 == 0) return;
    try tint(session, remoteOf(session, index) orelse return error.NetworkActorRecordNotPorted);
    if (actor.flags & 0x40 == 0 or actor.secondary_flags & 0x01000000 != 0 or @as(u32, @bitCast(session.actor_next_update[index])) > session.animation_time or actor.logic_name.len == 0) return;
    try reckon(session, allocator, effects, index);
    session.actor_slots[index].?.flags |= 0x80000080;
    session.syncActor(index);
}

pub fn updateRemote(session: anytype, index: usize, sender: u32, bytes: []const u8, now: u32) !void {
    if (index >= session.actor_slots.len or session.removed_actors[index] or session.actor_slots[index] == null) return error.MissingNetworkActor;
    const actor = &session.actor_slots[index].?;
    if (actor.secondary_flags & 0x30 == 0) return;
    const value = try dead_reckoning.readUpdate(bytes);
    const entry = remoteOf(session, index) orelse return error.NetworkActorRecordNotPorted;
    if (entry.record == null) entry.record = dead_reckoning.Record.init(.{ actor.position.x, actor.position.y, actor.position.z }, now);
    const record = &entry.record.?;
    record.take(&value, now);
    if (message.client(sender) == session.router.own_client) return;
    actor.velocity.y = @bitCast(record.velocity[1]);
    actor.pitch = record.angles[0];
    actor.yaw = record.angles[1];
    actor.roll = record.angles[2];
    actor.flags = ((record.actor_flags ^ actor.flags) & 0x491c ^ actor.flags) | 0x80000000;
    actor.secondary_flags = (record.entity ^ actor.secondary_flags) & 0x2000000 ^ actor.secondary_flags;
    if (actor.logic_kind == @as(?u32, 1)) if (actor.costume) |sprite| if (actor.playback) |*playback| {
        if (playback.choreography != value.animation) {
            var context: RemoteWax = .{};
            try playback.select(sprite, value.animation, now, &context);
            actor.choreography = playback.choreography;
            actor.frame = playback.frame;
            actor.angle_offset = playback.angle_offset;
        }
    };
    const across_x: f32 = @floatCast(@as(f64, actor.position.x) - @as(f64, record.position[0]));
    const across_z: f32 = @floatCast(@as(f64, actor.position.z) - @as(f64, record.position[2]));
    const height = @abs(@as(f64, actor.position.y) - @as(f64, record.position[1]));
    const distance = @as(f64, across_x) * @as(f64, across_x) + @as(f64, across_z) * @as(f64, across_z);
    const effects = session.active_effects orelse return error.MissingObjectEffects;
    if (2.5 < height or 100.0 < distance or !try wayClear(session, effects, index, &record.position)) {
        if (record.sector >= session.level.sectors.len) return error.MalformedNetworkMessage;
        const moved = &session.actor_slots[index].?;
        moved.position = .{ .x = record.position[0], .y = record.position[1], .z = record.position[2] };
        try toSector(session, effects, index, record.sector);
    }
    session.syncActor(index);
}

fn globalOrder(session: anytype) ![]Listed {
    var entries: std.ArrayList(struct { order: u64, listed: Listed }) = .empty;
    defer entries.deinit(session.allocator);
    try entries.append(session.allocator, .{ .order = session.player_actor.birth_order, .listed = .player });
    for (session.actor_slots, session.removed_actors, 0..) |slot, removed, source| {
        if (removed) continue;
        const actor = slot orelse continue;
        try entries.append(session.allocator, .{ .order = actor.birth_order, .listed = .{ .actor = source } });
    }
    const Entry = @TypeOf(entries.items[0]);
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.order < b.order;
        }
    }.less);
    const order = try session.allocator.alloc(Listed, entries.items.len);
    for (entries.items, order) |entry, *listed| listed.* = entry.listed;
    return order;
}

fn answer(session: anytype, listed: Listed, destination: u32) !void {
    switch (listed) {
        .player => {
            const flags = network_level.actorFlags(session);
            if (message.client(session.player_number) == session.router.own_client and flags & 0x8000 == 0)
                try network_level.announcePlayer(session, destination);
        },
        .actor => |source| try sendActor(session, source, destination),
    }
}

fn logicMessage(session: anytype, index: usize, code: u32, bytes: ?[]const u8) !void {
    const actor = session.actor_slots[index] orelse return error.MissingNetworkActor;
    if (actor.flags & 0x40 == 0 or actor.logic_name.len == 0) return;
    if (std.mem.eql(u8, actor.logic_name, remote_logic)) return;
    switch (cmm.resolve(actor.logic_name) catch return error.NetworkActorLogicNotPorted) {
        .ground_object, .instant_ground_object, .ground_sheriff_star, .ground_vanishing_cream => {},
        .projectile_dispatch => if (code == 0x7d1) {
            const value = try message.readDamage(bytes orelse return error.MalformedNetworkMessage);
            const sender = message.get(bytes.?, message.sender_offset);
            const from: ?usize = if (sender == 0) null else if (session.database.find(sender)) |object| switch (object) {
                .actor => |source| source,
                else => return error.NetworkBlastSenderNotPorted,
            } else return error.NetworkBlastSenderNotPorted;
            try @import("../projectile/session.zig").ignite(session, index, value.damage, from);
        },
        else => return error.NetworkActorLogicNotPorted,
    }
}

fn remoteOf(session: anytype, index: usize) ?*RemotePlayer {
    for (session.remote_players.items) |*entry| if (entry.source == index) return entry;
    return null;
}

fn createPlayer(session: anytype, value: message.ActorCreate) !void {
    const router = session.router;
    const client = message.client(value.number);
    var position: usize = 0;
    while (position < session.remote_players.items.len) {
        const entry = session.remote_players.items[position];
        if (message.client(session.actor_numbers[entry.source]) == client) {
            try deleteActor(session, entry.source);
            continue;
        }
        position += 1;
    }
    router.clients[client].player = null;
    var flags: u32 = 0x8000000f;
    for ([_]u32{ 1, 4, 8, 0x40 }) |bit| flags = if (value.flags & bit != 0) flags | bit else flags & ~bit;
    flags &= ~@as(u32, 0x80);
    flags = if (value.flags & 0x10 != 0) flags | 0x10 else flags & ~@as(u32, 0x10);
    const position_value: level_module.Vec3 = .{ .x = @bitCast(value.position[0]), .y = @bitCast(value.position[1]), .z = @bitCast(value.position[2]) };
    for ([_]f32{ position_value.x, position_value.y, position_value.z }) |coordinate| if (!std.math.isFinite(coordinate)) return error.MalformedNetworkMessage;
    if (value.costume.len == 0) return error.MalformedNetworkMessage;
    var actor: Actor = .{
        .sector = value.sector,
        .position = position_value,
        .pitch = value.angles[0],
        .yaw = value.angles[1],
        .roll = value.angles[2],
        .flags = flags,
        .secondary_flags = value.entity,
        .scale_x = 1,
        .scale_y = 1,
        .height = @bitCast(value.word_3c),
        .collision_radius = @abs(@as(f32, @bitCast(value.word_94))),
        .eye_height = @bitCast(value.word_74),
        .head_angles = .{ @bitCast(value.short_70), @bitCast(value.short_72) },
        .velocity = .{ .x = @bitCast(value.words_7c[0]), .y = @bitCast(value.words_7c[1]), .z = @bitCast(value.words_7c[2]) },
        .angular_velocity = .{ .x = @bitCast(value.words_7c[3]), .y = @bitCast(value.words_7c[4]), .z = @bitCast(value.words_7c[5]) },
        .transformed = .{ .x = @bitCast(value.words_40[0]), .y = @bitCast(value.words_40[1]), .z = @bitCast(value.words_40[2]) },
        .logic_kind = 1,
        .choreography = 0,
        .frame = 0,
        .angle_offset = 0,
    };
    var record: ?dead_reckoning.Record = null;
    if (flags & 0x40 != 0) {
        actor.logic_name = remote_logic;
        record = dead_reckoning.Record.init(.{ position_value.x, position_value.y, position_value.z }, session.animation_time);
    }
    const costume: ?*nwx.Costume = enemy_session.costume(session, value.costume) catch |err| switch (err) {
        error.ResourceNotFound => null,
        else => return err,
    };
    if (costume) |sprite| {
        actor.costume = sprite;
        actor.logic_resource = try session.arena.allocator().dupe(u8, value.costume);
        var playback: nwx.Playback = .{ .last_time = session.animation_time };
        if (value.entity & 0x10 != 0) actor.wax_binding = remote_logic;
        var context: RemoteWax = .{};
        try playback.select(sprite, value.animation, session.animation_time, &context);
        actor.playback = playback;
        actor.choreography = playback.choreography;
        actor.frame = playback.frame;
        actor.angle_offset = playback.angle_offset;
    }
    actor.secondary_flags |= 0x90;
    const source = try enemy_session.appendActor(session, actor, null);
    session.actor_numbers[source] = value.number;
    session.database.set(value.number, .{ .actor = source }, session.animation_time);
    session.syncActor(source);
    try session.remote_players.append(session.arena.allocator(), .{ .source = source, .record = record });
    router.clients[client].player = .{ .code = std.ascii.toUpper(value.costume[0]), .flags = actor.secondary_flags };
    router.clients[client].in_level = true;
    try session.database.rebuildPlayers(router, session.mode, session.game_type, session.animation_time);
}

fn tint(session: anytype, entry: *RemotePlayer) !void {
    const actor = session.actor_slots[entry.source].?;
    if (actor.secondary_flags & 0x10 == 0 or actor.playback == null or actor.logic_kind != @as(?u32, 1) or !(entry.tint_due < session.animation_time)) return;
    if (actor.secondary_flags & 0x180000 != 0) return error.PlayerTintTableNotPorted;
    switch (session.mode) {
        1, 4, 5 => if (entry.tint_flags & 1 == 0 or actor.secondary_flags & 0x70000 == 0) {
            if (entry.tint_flags & 2 == 0 and actor.flags & 0x800 != 0) return error.PlayerTintTableNotPorted;
            if (actor.secondary_flags & 0xf == 1 or actor.secondary_flags & 0xf == 2) return error.PlayerTintTableNotPorted;
            entry.tint_flags = entry.tint_flags & ~@as(u8, 2) | 1;
        } else {
            entry.tint_flags &= ~@as(u8, 1);
        },
        2, 3, 6 => {
            if (entry.tint_flags & 2 == 0 and actor.flags & 0x800 != 0) return error.PlayerTintTableNotPorted;
            entry.tint_flags &= ~@as(u8, 2);
        },
        else => {},
    }
    entry.tint_due = session.animation_time +% 500;
}

fn reckon(session: anytype, allocator: std.mem.Allocator, effects: *inventory.Effects, index: usize) !void {
    const now = session.animation_time;
    const entry = remoteOf(session, index) orelse return error.NetworkActorRecordNotPorted;
    const record = if (entry.record) |*value| value else return;
    record.reckon(now);
    record.made = now;
    if (session.frame_seconds == 0) return error.RemotePlayerWithoutFrameTime;
    const inverse = 1.0 / @as(f64, session.frame_seconds);
    const actor = &session.actor_slots[index].?;
    actor.velocity.x = @floatCast((@as(f64, record.origin[0]) - actor.position.x) * inverse);
    actor.velocity.z = @floatCast((@as(f64, record.origin[2]) - actor.position.z) * inverse);
    const old_position = actor.position;
    const old_sector = actor.sector;
    const moved = try move(session, allocator, effects, index);
    const after = &session.actor_slots[index].?;
    if (outside(after.position.x) or outside(after.position.z)) {
        after.position = old_position;
        try toSector(session, effects, index, old_sector);
    }
    after.pitch = moved.angles[0];
    after.yaw = moved.angles[1];
    after.roll = moved.angles[2];
}

fn outside(value: f32) bool {
    return @as(u32, @bitCast(value)) > 0xc9742400 or value > 1000000.0;
}

fn move(session: anytype, allocator: std.mem.Allocator, effects: *inventory.Effects, index: usize) !struct { angles: [3]i16 } {
    const actor = &session.actor_slots[index].?;
    const entry = remoteOf(session, index).?;
    const record = &entry.record.?;
    var runtime = enemy_session.scriptContext(session, effects, actor.secondary_flags);
    runtime.linked_actor = index;
    runtime.link_order = &actor.sector_link_order;
    var context = enemy_session.context(session, allocator, null, null);
    context.actors.runtime = &runtime;
    var state: blood.State = .{ .velocity = actor.velocity, .floor_cache = entry.floor_cache, .wall_memory = entry.wall_memory, .walked = record.distance };
    try blood.remotePlayerPhysics(actor, &state, context.world(), session.frame_seconds);
    session.player.contact_residue.invalidate();
    actor.velocity = state.velocity;
    entry.floor_cache = state.floor_cache;
    entry.wall_memory = state.wall_memory;
    record.distance = state.walked.?;
    const angles = record.angles;
    session.syncActor(index);
    if (state.splash) |request| try enemy_dynamic.spawnSplash(session, effects, request);
    if (state.step_sound) |step| {
        const name = session.level.sectors[step.floor].floor_sound;
        if (name.len != 0 and !std.mem.eql(u8, name, "NULL"))
            try effects.append(.{ .sound = .{ .basename = name, .priority = 0x20, .volume = 0x19, .flags = 4, .sector = step.sector, .position = step.position } });
    }
    return .{ .angles = angles };
}

fn toSector(session: anytype, effects: *inventory.Effects, index: usize, sector: usize) !void {
    const actor = &session.actor_slots[index].?;
    if (actor.sector == sector) return;
    var runtime = enemy_session.scriptContext(session, effects, actor.secondary_flags);
    runtime.linked_actor = index;
    runtime.link_order = &actor.sector_link_order;
    try runtime.changeSector(actor.sector, sector);
    actor.sector = sector;
    session.syncActor(index);
}

fn wayClear(session: anytype, effects: *inventory.Effects, index: usize, to: *[3]f32) !bool {
    const actor = session.actor_slots[index].?;
    var runtime = enemy_session.scriptContext(session, effects, actor.secondary_flags);
    var context = enemy_session.context(session, session.allocator, null, null);
    context.actors.runtime = &runtime;
    var target: level_module.Vec3 = .{ .x = to[0], .y = to[1], .z = to[2] };
    const clear = try collision.pathClear(session.allocator, &session.level, &session.scene, context.actors, actor.sector, actor.height, actor.collision_radius, actor.position, &target);
    session.player.contact_residue.invalidate();
    to.* = .{ target.x, target.y, target.z };
    return clear;
}
