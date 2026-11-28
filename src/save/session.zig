//! Saving and restoring a level: the registered module callbacks, run in
//! registration order.
//!
//! The resources belong to the level that was opened; what the stream holds
//! is each module's own records, not a memory image of the session.

const std = @import("std");

const enemy_save = @import("../enemy/save.zig");
const enemy_session = @import("../enemy/session.zig");
const cmm = @import("../script/cmm.zig");
const actor_save = @import("actor.zig");
const inf_save = @import("inf.zig");
const level_save = @import("level.zig");
const modules = @import("modules.zig");
const pickup_save = @import("pickup.zig");
const player_save = @import("player.zig");
const player_module = @import("player_module.zig");
const projectile_save = @import("projectile.zig");
const stream = @import("stream.zig");
const Actor = @import("../render/objects.zig").Actor;
const player_source = @import("../player/shooting.zig").local_player;
const object_numbers = @import("../render/object_numbers.zig");
const bits = @import("../util/bits.zig");

/// Writes every module. Lists and records that exist only while writing come
/// from a scratch arena freed before returning, also on failure, so saving
/// adds nothing to the level's storage.
// TODO: Reserve this scratch at startup once actor slots have a fixed capacity.
pub fn write(session: anytype, writer: *stream.Writer, audio: anytype) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(session.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    try hydrateMap(session, scratch);
    try session.bindAudio(audio);

    const previous_audio = session.active_audio;

    session.active_audio = audio;
    defer session.active_audio = previous_audio;

    const ids = try actorIds(session, scratch);

    for (modules.order) |entry| switch (entry.module) {
        .player => try player_module.writeInventory(&session.inventory, writer),
        .server => {
            try entry.writeMarker(writer);
            try writer.boolean(session.server_enabled);
        },
        .level => try level_save.write(session, writer, audio),
        .gen => try enemy_save.writeGenWithAudio(writer, &session.generators, ids, audio),
        .db => {
            try writer.marker(0x426c6157, 1, 0);
            try writer.marker(0x42636553, 1, 0);
            try writeActors(session, scratch, writer, audio);
            try inf_save.writeDbm(writer);
            try inf_save.writeClasses(
                writer,
                &session.inf,
                &session.texture_animations,
                &session.level,
                try infReferences(session, scratch, audio),
            );
        },
        .elevator => try inf_save.writeElevatorModule(writer, &session.inf),
        .logic => try enemy_save.writeLogic(
            writer,
            session.enemy_shared,
            session.sanchez_sites orelse &.{},
        ),
        else => try entry.writeMarker(writer),
    };
}

pub fn read(session: anytype, reader: *stream.Reader, audio: anytype) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(session.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    try session.bindAudio(audio);
    const previous_audio = session.active_audio;

    session.active_audio = audio;
    defer session.active_audio = previous_audio;

    for (modules.order) |entry| switch (entry.module) {
        .player => player_module.apply(&session.inventory, try player_module.State.read(reader)),
        .server => {
            try entry.readMarker(reader);
            session.server_enabled = try reader.boolean();
        },
        .level => session.saved_music = try level_save.read(session, reader, audio),
        .gen => {
            session.generators = try enemy_save.readGenWithAudio(
                reader,
                session.arena.allocator(),
                session.level.sectors.len,
                try actorIds(session, scratch),
                audio,
            );

            if (@hasField(
                @TypeOf(session.*),
                "actor_numbers",
            )) try object_numbers.restoreGenerators(session);
        },
        .db => {
            try reader.marker(0x426c6157, 1, 0);
            try reader.marker(0x42636553, 1, 0);
            try readActors(session, scratch, reader, audio);
            try inf_save.readDbm(reader);
            try inf_save.readClasses(
                reader,
                &session.inf,
                &session.texture_animations,
                &session.level,
                &session.scene,
                try infReferences(session, scratch, audio),
            );

            if (@hasField(
                @TypeOf(session.*),
                "actor_numbers",
            )) try object_numbers.restoreLinks(session);
        },
        .elevator => try inf_save.readElevatorModule(reader, &session.inf),
        .logic => session.sanchez_sites = try enemy_save.readLogic(
            reader,
            session.arena.allocator(),
            &session.enemy_shared,
            session.level.sectors.len,
        ),
        else => try entry.readMarker(reader),
    };

    session.main_presented = null;
    session.scope_presented = null;
    session.framebuffer_initialized = false;
}

fn hydrateMap(session: anytype, scratch: std.mem.Allocator) !void {
    const visible = try scratch.alloc(bool, session.level.sectors.len);
    @memset(visible, true);
    _ = try session.loadActors(visible, true);
}

fn actorIds(session: anytype, scratch: std.mem.Allocator) ![]u32 {
    const ids = try scratch.alloc(u32, session.actor_slots.len);
    for (ids, 0..) |*id, source| id.* = try session.savedActorId(source);

    return ids;
}

fn infReferences(
    session: anytype,
    scratch: std.mem.Allocator,
    audio: anytype,
) !inf_save.References {
    const a = scratch;
    const map = try a.alloc(u32, session.actor_slots.len);

    for (session.actor_slots, map) |slot, *id| id.* = if (slot) |actor| actor.object_id else 0xffffffff;

    const generators = try a.alloc(u32, session.generators.records.items.len);

    for (session.generators.records.items, generators) |record, *id| id.* = record.id;

    return .{
        .actor_ids = try actorIds(session, scratch),
        .actor_map_ids = map,
        .generator_ids = generators,
        .audio = audio,
    };
}

fn enemyReferences(
    session: anytype,
    scratch: std.mem.Allocator,
    audio: anytype,
) !enemy_save.References {
    return .{
        .actor_ids = try actorIds(session, scratch),
        .player_id = session.player_actor.logic_id,
        .sector_count = session.level.sectors.len,
        .node_count = session.enemy_nodes.len,
        .audio = audio,
        .sound_ledger = &session.sound_ledger,
        .now = session.animation_time,
    };
}

fn orderedActors(session: anytype, scratch: std.mem.Allocator, include_ephemeral: bool) ![]usize {
    var sources: std.ArrayList(usize) = .empty;
    const a = scratch;

    if (session.player_actor.logic_id != 0) try sources.append(a, player_source);

    for (session.actor_slots, session.removed_actors, 0..) |slot, removed, source| {
        if (removed) continue;

        if (slot) |actor| {
            if (!include_ephemeral and actor.secondary_flags.effect) continue;
            try sources.append(a, source);
        }
    }

    const Context = struct {
        session: @TypeOf(session),

        pub fn less(ctx: @This(), left: usize, right: usize) bool {
            return getActor(
                ctx.session,
                left,
            ).birth_order < getActor(ctx.session, right).birth_order;
        }
    };

    std.mem.sort(usize, sources.items, Context{ .session = session }, Context.less);

    return sources.toOwnedSlice(a);
}

fn getActor(session: anytype, source: usize) Actor {
    return if (source == player_source) session.player_actor else session.actor_slots[source].?;
}

fn captureActor(
    session: anytype,
    scratch: std.mem.Allocator,
    source: usize,
) anyerror!actor_save.Record {
    var actor = getActor(session, source);
    var due: u32 = 0;

    if (source == player_source) {
        actor.position = session.player.position;
        actor.sector = session.player.sector;
        actor.yaw = session.player.yaw;
        actor.pitch = session.player.pitch;
        actor.height = session.player.body_height;
        actor.eye_height = session.player.eye_height;
        actor.head_angles[1] = session.player.head_yaw;
        actor.velocity = session.player.velocity;
        actor.collision_radius = session.player.radius;
        actor.flags = enemy_session.playerSubject(session).flags;
    } else {
        due = @bitCast(session.actor_next_update[source]);

        if (session.projectile_slots[source]) |state| {
            actor.velocity = state.velocity;
            actor.model_rotation = state.rotation;
        } else if (session.general_slots[source]) |state| actor.velocity = state.velocity;
    }

    var record = try actor_save.capture(session, actor, due);

    if (actor.child_source) |child| {
        const nested = try scratch.create(actor_save.Record);
        nested.* = try captureActor(session, scratch, child);
        record.child = nested;
    }

    return record;
}

fn writeActors(
    session: anytype,
    scratch: std.mem.Allocator,
    writer: *stream.Writer,
    audio: anytype,
) !void {
    try writer.marker(0x42746341, 1, 0);
    const order = try orderedActors(session, scratch, false);
    try writer.integer(u32, @intCast(order.len));

    for (order) |source| {
        try (try captureActor(session, scratch, source)).write(writer);
        if (source == player_source) try (try player_save.capture(session, audio)).write(writer);
    }

    try writer.integer(u32, session.next_actor_id);
    const refs = try enemyReferences(session, scratch, audio);

    for (order) |source| {
        if (source == player_source) continue;

        const actor = session.actor_slots[source].?;

        if (actor.logic_name.len == 0 or std.mem.eql(
            u8,
            actor.logic_name,
            "Inv_Object",
        ) or std.mem.eql(u8, actor.logic_name, "misc_CorpseDispatch")) continue;

        if (session.targets[source]) |*target| {
            try enemy_save.writeEnemy(writer, target, actor.logic_id, refs);
        } else if (session.projectile_slots[source]) |state| {
            try (try projectile_save.capture(
                session,
                scratch,
                state,
                session.pickup_slots[source],
            )).write(writer);
        } else if (session.pickup_slots[source]) |pickup| {
            if (pickup.function == .instant_ground_object) {
                try (try pickup_save.captureInstant(audio, pickup)).write(writer);
            } else try (try pickup_save.capture(scratch, audio, pickup)).write(writer);
        } else return error.UnsupportedSavedActorNative;
    }
}

fn readActors(
    session: anytype,
    scratch: std.mem.Allocator,
    reader: *stream.Reader,
    audio: anytype,
) !void {
    try reader.marker(0x42746341, 1, 0);

    const a = session.arena.allocator();
    const old_order = try orderedActors(session, scratch, true);

    for (old_order) |source| {
        if (source != player_source) try enemy_session.removeActor(session, source);
    }

    @memset(session.actor_slots, null);
    @memset(session.targets, null);
    @memset(session.pickup_slots, null);
    @memset(session.projectile_slots, null);
    @memset(session.blood_slots, null);
    @memset(session.general_slots, null);
    @memset(session.splash_slots, null);
    @memset(session.source_to_entry, null);
    @memset(session.actor_links.heads, null);
    @memset(session.actor_links.nodes.items, .{});

    session.actor_links.player = .{};
    session.actors = session.actor_storage[0..0];
    session.next_actor_id = 0;
    session.next_actor_order = 1;
    session.actor_link_serial = 1;
    session.corpse_pool = .{};
    session.corpse_sources = @splat(null);
    session.player_actor.logic_id = 0;

    const count = try reader.integer(u32);
    if (count == 0 or count > 1048576) return error.InvalidSavedActorCount;

    var loaded: std.ArrayList(usize) = .empty;
    var has_player = false;

    for (0..count) |_| {
        const record = try actor_save.Record.read(reader, a);
        const source = try restoreActor(session, scratch, record, &loaded, &has_player);

        if (@hasField(
            @TypeOf(session.*),
            "actor_numbers",
        )) try object_numbers.restoreActor(session, source);

        if (source == player_source) try player_save.apply(
            session,
            audio,
            try player_save.State.read(reader, a),
        );
    }

    if (!has_player) return error.MissingSavedPlayer;

    _ = try reader.integer(u32);
    const refs = try enemyReferences(session, scratch, audio);

    for (loaded.items) |source| {
        if (source == player_source) continue;

        const actor = &session.actor_slots[source].?;

        if (actor.logic_name.len == 0 or std.mem.eql(u8, actor.logic_name, "Inv_Object")) continue;

        if (std.mem.eql(u8, actor.logic_name, "misc_CorpseDispatch")) {
            try enemy_session.restoreCorpse(session, source);
            continue;
        }

        const native = try cmm.resolve(actor.logic_name);

        switch (native) {
            .enemy, .chicken, .civilian, .marshal, .slim, .sanchez, .farmer, .bob, .dynamite => {
                const restored = try enemy_save.readEnemy(
                    reader,
                    a,
                    &.{ session.object_archive, session.weapon_archive, session.system_archive },
                    session.difficulty,
                    &session.enemy_shared,
                    refs,
                );

                if (restored.owner_id == null or restored.owner_id.? != actor.logic_id) return error.InvalidSavedEnemyOwner;

                session.targets[source] = enemy_save.applyEnemy(
                    restored,
                    actor,
                    &session.enemy_shared,
                    &session.enemy_selection_serial,
                );

                session.targets[source].?.next_tick = @bitCast(session.actor_next_update[source]);
            },
            .projectile_dispatch, .explosive_projectile_dispatch => {
                var restored = try projectile_save.restore(
                    session,
                    try projectile_save.Record.read(reader, a),
                    actor,
                );

                restored.state.velocity = actor.velocity;
                restored.state.rotation = actor.model_rotation;
                restored.state.floor_cache = -0x1p31;
                session.projectile_slots[source] = restored.state;
                session.pickup_slots[source] = restored.pickup;
                actor.projectile_explodes = restored.state.config.explosion != null;
            },
            .instant_ground_object => session.pickup_slots[source] = try pickup_save.restoreInstant(
                audio,
                try pickup_save.Instant.read(reader, a),
            ),
            .ground_object, .ground_sheriff_star, .ground_vanishing_cream => session.pickup_slots[source] = try pickup_save.restore(a, &.{ session.object_archive, session.weapon_archive, session.system_archive }, audio, native, session.game_type, try pickup_save.Record.read(reader, a)),
            else => return error.UnsupportedSavedActorNative,
        }

        session.syncActor(source);
    }
}

fn restoreActor(
    session: anytype,
    scratch: std.mem.Allocator,
    record: actor_save.Record,
    loaded: *std.ArrayList(usize),
    has_player: *bool,
) anyerror!usize {
    var actor = try actor_save.hydrate(session, record);
    var source: usize = undefined;

    if (actor.secondary_flags.player) {
        if (has_player.*) return error.UnsupportedSavedMultiplePlayers;

        has_player.* = true;
        _ = session.allocateActorId();
        actor.birth_order = session.next_actor_order;
        session.next_actor_order += 1;
        actor.secondary_flags = bits.with(actor.secondary_flags, .{ .player = true, .takes_hits = true });
        session.player_actor = actor;
        source = player_source;
        session.player.position = actor.position;
        session.player.sector = actor.sector;
        session.player.velocity = actor.velocity;
        session.player.yaw = actor.yaw;
        session.player.pitch = actor.pitch;
        session.player.head_yaw = actor.head_angles[1];
        session.player.body_height = actor.height;
        session.player.eye_height = actor.eye_height;
        session.player.radius = actor.collision_radius;
        session.player.floor_cache = -0x1p31;
        session.player_link_order = session.actor_link_serial;
        session.actor_link_serial += 1;

        session.actor_links.move(player_source, actor.sector);
    } else {
        var map_source: ?usize = null;

        for (session.objects.entries, 0..) |object, index| {
            if (object.id == actor.object_id and session.actor_slots[index] == null) {
                map_source = index;
                break;
            }
        }

        if (map_source) |index| {
            source = index;
            _ = session.allocateActorId();
            actor.birth_order = session.next_actor_order;
            session.next_actor_order += 1;
            actor.source_index = source;
            actor.sector_link_order = session.actor_link_serial;
            session.actor_link_serial += 1;
            session.actor_slots[source] = actor;
            session.removed_actors[source] = false;
        } else {
            source = try enemy_session.appendActor(session, actor, null);
            session.actor_slots[source].?.logic_id = record.id;
        }

        session.actor_next_update[source] = @bitCast(record.next_update);

        if (actor.flags.physics) session.general_slots[source] = .{
            .velocity = actor.velocity,
        };

        session.syncActor(source);
    }

    try loaded.append(scratch, source);

    if (record.child) |child| {
        const child_source = try restoreActor(session, scratch, child.*, loaded, has_player);
        if (source == player_source) session.player_actor.child_source = child_source else session.actor_slots[source].?.child_source = child_source;
    }

    return source;
}
