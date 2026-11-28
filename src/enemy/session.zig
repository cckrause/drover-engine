//! The enemies of a loaded level: construction, the per-frame tick, and
//! removal.
//!
//! Every enemy and every item bound to an actor is constructed before play
//! starts, whether or not it can be seen; only unbound scenery is deferred.
//! Nodes append to the first group, which is what keeps hidden sets in
//! order.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const controller = @import("controller.zig");
const lifecycle = @import("lifecycle.zig");
const Item = @import("../assets/item.zig").Item;
const Actor = @import("../render/objects.zig").Actor;
const Target = @import("../player/target.zig").Target;
const nwx = @import("../assets/nwx.zig");
const audio = @import("../audio/runtime.zig");
const inventory = @import("../player/inventory.zig");
const object_state = @import("../render/object_state.zig");
const object_logic = @import("../script/object.zig");
const script_runtime = @import("../script/runtime.zig");
const blood = @import("blood.zig");
const dynamic = @import("dynamic.zig");
pub const spawnItem = @import("item_spawn.zig").spawn;
pub const model = @import("item_spawn.zig").model;
pub const bareModel = @import("item_spawn.zig").bareModel;
const bits = @import("../util/bits.zig");
const ActorFlags = @import("../actor_flags.zig").ActorFlags;
const ActorKind = @import("../actor_flags.zig").ActorKind;

const Phase = enum { animation, selection, tick };

pub fn preload(session: anytype, allocator: std.mem.Allocator) !void {
    if (session.enemies_loaded) return;

    const a = session.arena.allocator();
    const sectors = try allocator.alloc(bool, session.level.sectors.len);
    defer allocator.free(sectors);

    @memset(sectors, false);
    _ = try session.loadActors(sectors, true);
    var nodes: std.ArrayList(controller.Node) = .empty;

    for (session.objects.entries) |object| {
        if (!bits.any(object.availability.difficulties, session.difficulty.set()) or object.flags.sound_only) continue;

        const sector = session.level.sectorIndex(object.sector_id) orelse continue;
        const name = try std.fmt.allocPrint(a, "{s}.ITM", .{std.fs.path.stem(object.name)});
        const bytes = session.object_archive.find(name, 0) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };

        var item = try Item.parse(a, bytes);
        defer item.deinit();

        if (!std.mem.eql(u8, item.function, "Node_New")) continue;

        const kind = if (try item.stringValue("TYPE")) |value|
            @as(
                u32,
                if (std.ascii.eqlIgnoreCase(
                    value,
                    "HIDE",
                )) 2 else if (std.ascii.eqlIgnoreCase(value, "NAV")) 3 else 0,
            )
        else
            0;

        try nodes.append(a, .{ .kind = kind, .sector = sector, .position = object.position });
    }

    session.enemy_nodes = try nodes.toOwnedSlice(a);

    for (session.enemy_nodes) |*source| {
        var links: std.ArrayList(usize) = .empty;
        var start = source.position;

        start.y = @floatCast(@as(f64, start.y) + 3);

        for (session.enemy_nodes, 0..) |destination, index| {
            var end = destination.position;
            end.y = @floatCast(@as(f64, end.y) + 3);

            if (try session.enemy_visibility.visible(
                &session.level,
                &session.scene,
                &session.angles,
                source.sector,
                source.sector,
                start,
                end,
                0,
            )) try links.append(a, index);
        }

        source.links = try links.toOwnedSlice(a);
    }

    session.enemies_loaded = true;
}

pub fn playerSubject(session: anytype) controller.Subject {
    return .{
        .position = session.player.position,
        .sector = session.player.sector,
        .height = session.player.body_height,
        .radius = session.player.radius,
        .yaw = session.player.yaw,
        .flags = @import(
            "../player/lamp.zig",
        ).actorFlags(
            playerActorFlags(session.player.flags.dead),
            session.player.flags.lamp_on,
        ),
        .secondary_flags = .{ .player = true },
    };
}

/// The player's actor flags before the lamp has its say.
pub fn playerActorFlags(dead: bool) ActorFlags {
    var flags = ActorFlags.new_player;

    if (dead) {
        flags.dead = true;
        flags.not_solid = true;
    }

    return flags;
}

pub fn context(
    session: anytype,
    allocator: std.mem.Allocator,
    sound: ?*audio.Runtime,
    required: ?[]bool,
) controller.Context {
    _ = allocator;
    var actors = session.collisionActors();

    actors.required_sectors = required;
    actors.allow_pickups = false;
    actors.player = playerBody(session);

    return .{
        .allocator = session.arena.allocator(),
        .level = &session.level,
        .scene = &session.scene,
        .angles = &session.angles,
        .actors = actors,
        .actor_slots = session.actor_slots,
        .targets = session.targets,
        .player = playerSubject(session),
        .visibility = &session.enemy_visibility,
        .random = &session.contact_state.random,
        .now = session.animation_time,
        .elapsed_seconds = session.frame_seconds,
        .audio = sound,
        .before_sound = .{ .context = session, .drain = @TypeOf(session.*).drainActiveSounds },
        .shared = &session.enemy_shared,
        .effects = &session.enemy_effects,
        .shot_sink = .{ .context = session, .emit = @TypeOf(session.*).emitEnemyShot },
        .nodes = session.enemy_nodes,
        .sanchez_sites = session.sanchez_sites orelse &.{},
        .difficulty = session.difficulty,
        .complete_level = .{
            .context = session,
            .enqueue = @TypeOf(session.*).enqueueLevelCompletion,
        },
        .reflected_hit = .{ .context = session, .enqueue = @TypeOf(session.*).enqueueReflectedHit },
        .projectile_sink = .{ .context = session, .emit = @TypeOf(session.*).emitEnemyProjectile },
        .statistics = &session.inventory.statistics,
        .hit_result = .{ .context = session, .enqueue = @TypeOf(session.*).enqueueHitResult },
    };
}

pub fn playerBody(session: anytype) @import("../player/collision.zig").Body {
    const subject = playerSubject(session);

    return .{
        .position = subject.position,
        .sector = subject.sector,
        .height = subject.height,
        .radius = subject.radius,
        .flags = subject.flags,
        .secondary_flags = subject.secondary_flags,
        .sector_link_order = session.player_link_order,
    };
}

pub fn run(
    session: anytype,
    allocator: std.mem.Allocator,
    sound: ?*audio.Runtime,
    source: usize,
    phase: Phase,
) !bool {
    var ctx = context(session, allocator, sound, null);

    if (phase == .tick and source >= session.objects.entries.len) {
        ctx.contact_residue = &session.player.contact_residue;
        ctx.contact_successor_present = false;

        ctx.contact_successor_present = dynamic.nextActor(session, session.made_actors.after(source)) != null;
    }

    const target = if (session.targets[source]) |*value| value else return false;
    const actor = if (session.actor_slots[source]) |*value| value else return error.MissingEnemyActor;
    var effects_buffer: inventory.EffectBuffer = undefined;
    var effects = inventory.Effects.init(&effects_buffer);
    var runtime = scriptContext(session, &effects, actor.secondary_flags);

    runtime.linked_actor = source;
    runtime.link_order = &actor.sector_link_order;
    ctx.actors.runtime = &runtime;

    const removed = try execute(phase, target, actor, &ctx);

    if (phase == .tick and !removed) actor.flags = bits.with(actor.flags, .{ .updated = true, .changed = true });

    session.targets[source] = target.*;
    session.actor_slots[source] = actor.*;
    session.actor_next_update[source] = @bitCast(target.next_tick);

    session.syncActor(source);

    return removed;
}

pub fn scriptContext(
    session: anytype,
    effects: *inventory.Effects,
    entity: ActorKind,
) script_runtime.Context {
    return .{
        .sector_messages = if (@hasField(
            @TypeOf(session.*),
            "router",
        )) session.router.own_client == 1 else true,
        .inventory = &session.inventory,
        .pickups = session.pickup_slots,
        .removed = session.removed_actors,
        .now_ms = session.animation_time,
        .effects = effects,
        .contact_state = &session.contact_state,
        .actor_next_update = session.actor_next_update,
        .inf = &session.inf,
        .level = &session.level,
        .collision_diameter = &session.collision_diameter,
        .entity_mask = entity,
        .links = &session.actor_links,
        .link_serial = &session.actor_link_serial,
        .solid_host = .{ .context = session, .touch = @TypeOf(session.*).receiveActorContact },
        .pickup_release = .{ .context = session, .emit = @TypeOf(session.*).releaseTouchedPickup },
    };
}

pub fn syncSchedule(session: anytype) void {
    for (session.targets, session.actor_next_update) |*target, *next| {
        if (target.*) |*value| next.* = @bitCast(value.next_tick);
    }
}

pub fn impactNoise(
    session: anytype,
    allocator: std.mem.Allocator,
    effects: *inventory.Effects,
) !void {
    return playerNoise(session, allocator, effects, 30, 0x83);
}

pub fn playerNoise(
    session: anytype,
    allocator: std.mem.Allocator,
    effects: *inventory.Effects,
    radius: f32,
    code: u32,
) !void {
    try preload(session, allocator);
    try session.drainSounds(effects);

    var ctx = context(session, allocator, session.active_audio, null);
    var runtime = scriptContext(session, effects, .{ .player = true });

    ctx.actors.runtime = &runtime;
    const source = session.player.sector;

    if (ctx.visibility.lists[source] == null and ctx.level.sectors.len > 1)
        _ = try ctx.visibility.connected(
            ctx.level,
            ctx.scene,
            ctx.angles,
            source,
            (source + 1) % ctx.level.sectors.len,
        );

    const single_sector = [_]u16{@intCast(source)};
    const connected = ctx.visibility.lists[source] orelse &single_sector;
    var visit: usize = 0;

    while (visit <= connected.len) : (visit += 1) {
        const sector: usize = if (visit == 0) source else connected[visit - 1];
        var actors = ctx.actors.inLoadedSector(sector);

        while (actors.next()) |entry| {
            if (entry == @import("../player/shooting.zig").local_player) continue;

            const actor = ctx.actors.get(entry);

            if (!actor.secondary_flags.enemy or actor.logic_name.len == 0) continue;

            const perception = @import("perception.zig");

            if (!(perception.distance(
                perception.point(session.player.position),
                perception.point(actor.position),
            ) < radius)) continue;

            const index = actor.source_index orelse return error.MissingEnemyActorId;
            const target = if (session.targets[index]) |*value| value else return error.UnsupportedEnemyImpactRecipient;
            const live_actor = if (session.actor_slots[index]) |*value| value else return error.MissingEnemyActor;

            try controller.message(target, live_actor, code, &.{}, &ctx);
            session.actor_next_update[index] = @bitCast(target.next_tick);
            session.syncActor(index);
        }
    }
}

pub fn animations(
    session: anytype,
    allocator: std.mem.Allocator,
    sound: ?*audio.Runtime,
    effects: *inventory.Effects,
) !void {
    var index = session.objects.entries.len;

    while (index != 0) {
        index -= 1;

        if (session.removed_actors[index]) continue;

        if (session.targets[index] != null) {
            _ = try run(session, allocator, sound, index, .animation);
        } else if (session.actor_slots[index]) |*actor| {
            if (object_logic.bound(actor.*)) {
                try object_logic.advance(session, index, effects);
            } else {
                try actor.advanceUnboundAnimation(session.animation_time);
                session.syncActor(index);
            }
        }

        try session.castEnemyEffects(allocator, effects);
    }
}

pub fn deliverSelections(
    session: anytype,
    allocator: std.mem.Allocator,
    sound: ?*audio.Runtime,
) !void {
    return deliverSelectionsBefore(session, allocator, sound, std.math.maxInt(u64));
}

pub fn deliverSelectionsBefore(
    session: anytype,
    allocator: std.mem.Allocator,
    sound: ?*audio.Runtime,
    before: u64,
) !void {
    while (true) {
        var source: ?usize = null;
        var splash = false;
        var object = false;
        var serial: u64 = std.math.maxInt(u64);

        for (session.targets, session.removed_actors, 0..) |target, removed, index| {
            if (removed) continue;

            const value = target orelse continue;

            if (value.selection_cursor == value.selections.items.len) continue;

            const selection = value.selections.items[value.selection_cursor];

            if (source == null or selection.serial < serial) {
                source = index;
                serial = selection.serial;
            }
        }

        for (session.splash_slots, session.removed_actors, 0..) |slot, removed, index| {
            if (removed) continue;

            if (slot) |value| if (value.selection_serial) |order| {
                if (source == null or order < serial) {
                    source = index;
                    serial = order;
                    splash = true;
                }
            };
        }

        const objects = &session.object_logic;

        if (objects.cursor < objects.selections.items.len) {
            const selection = objects.selections.items[objects.cursor];

            if (source == null or selection.serial < serial) {
                source = selection.source;
                serial = selection.serial;
                object = true;
            }
        }

        const index = source orelse break;

        if (serial >= before) break;

        if (object) {
            var effects_buffer: inventory.EffectBuffer = undefined;
            var effects = inventory.Effects.init(&effects_buffer);
            try object_logic.deliverNext(session, session.active_effects orelse &effects);
            try session.enemy_native_effects.appendSlice(effects.items);
        } else if (splash) {
            session.splash_slots[index].?.selection_serial = null;

            if (try blood.selectSplash(
                &session.actor_slots[index].?,
                session.animation_time,
            )) session.removed_actors[index] = true;

            session.syncActor(index);
        } else _ = try run(session, allocator, sound, index, .selection);
    }

    for (session.targets) |*target| if (target.*) |*value| {
        if (value.selection_cursor == value.selections.items.len) {
            value.selections.clearRetainingCapacity();
            value.selection_cursor = 0;
        }
    };

    if (session.object_logic.cursor == session.object_logic.selections.items.len) {
        session.object_logic.selections.clearRetainingCapacity();
        session.object_logic.cursor = 0;
    }
}

pub fn tick(
    session: anytype,
    allocator: std.mem.Allocator,
    sound: ?*audio.Runtime,
    effects: *inventory.Effects,
) !void {
    var index: usize = 0;
    const count = session.objects.entries.len;

    while (index < count) : (index += 1) {
        if (session.removed_actors[index]) continue;

        if (session.targets[index] == null) {
            if (index < session.objects.entries.len) if (session.actor_slots[index]) |actor| {
                if (object_logic.bound(actor)) object_logic.tick(session, index);

                if (std.mem.eql(u8, actor.logic_name, "shot_ProjectileDispatch")) {
                    try @import("../projectile/session.zig").ensureMap(session, index);
                    try @import(
                        "../projectile/session.zig",
                    ).tick(session, allocator, effects, index);
                } else if (session.pickup_slots[index] != null and actor.flags.logicReady() and !actor.secondary_flags.waiting_for_start and @as(u32, @bitCast(session.actor_next_update[index])) <= session.animation_time) {
                    session.pickup_slots[index].?.tick(
                        &session.actor_slots[index].?,
                        session.player.position,
                    );

                    session.actor_slots[index].?.flags = bits.with(session.actor_slots[index].?.flags, .{ .updated = true, .changed = true });
                    session.syncActor(index);
                }

                if (inRemovalSector(session, actor)) try removeActor(session, index);
            };

            continue;
        }

        const actor = session.actor_slots[index] orelse return error.MissingEnemyActor;

        if (!actor.flags.logicReady() or actor.secondary_flags.waiting_for_start or session.targets[index].?.next_tick > session.animation_time) {
            if (inRemovalSector(session, actor)) try removeActor(session, index);
            continue;
        }

        const remove = try run(session, allocator, sound, index, .tick);
        try session.castEnemyEffects(allocator, effects);

        if (remove) {
            try finishDeath(session, allocator, index);
        } else if (inRemovalSector(session, session.actor_slots[index].?)) {
            try removeActor(session, index);
        }
    }
}

pub fn inRemovalSector(session: anytype, actor: Actor) bool {
    return session.scene.sectors[actor.sector].flags.removes_objects and !actor.secondary_flags.player and !actor.secondary_flags.projectile;
}

pub fn removeActor(session: anytype, source: usize) !void {
    if (session.removed_actors[source]) return;

    session.player.contact_residue.invalidateProjection();

    if (@hasField(
        @TypeOf(session.*),
        "generators",
    )) session.generators.removed(source, session.animation_time, &session.contact_state.random);

    session.releasePickupSound(source);

    if (session.targets[source]) |*target| controller.clearStack(target);

    if (@hasField(
        @TypeOf(session.*),
        "actor_numbers",
    )) try @import("../render/object_numbers.zig").freeActor(session, source);

    session.removed_actors[source] = true;

    for (session.corpse_sources, 0..) |entry, index| {
        if (entry == source) {
            session.corpse_sources[index] = null;
            session.corpse_pool.actors[index] = null;
        }
    }

    session.syncActor(source);
}

pub fn releaseSectorPickupSounds(session: anytype, sector: usize) void {
    var source = session.actor_links.first(sector);

    while (source) |index| {
        source = session.actor_links.next(index);
        if (index != @import(
            "../render/actor_links.zig",
        ).player_id and !session.removed_actors[index]) session.releasePickupSound(index);
    }
}

pub fn finishDeath(session: anytype, allocator: std.mem.Allocator, index: usize) !void {
    const actor = session.actor_slots[index].?;
    const target = session.targets[index].?;
    var drop_position: ?@import("../assets/level.zig").Vec3 = null;

    if (target.drop_item.len != 0) {
        var drop_context = context(session, allocator, null, null);
        const place = try lifecycle.dropPlacement(drop_context.world(), actor);
        drop_position = place.position;
        _ = try spawnItem(session, target.drop_item, place);
    }

    if (actor.secondary_flags.enemy) session.enemy_shared.killed_enemies += 1;

    const resource = actor.logic_resource orelse blk: {
        var entries = session.costumes.iterator();
        while (entries.next()) |entry| if (entry.value_ptr.* == actor.costume) break :blk entry.key_ptr.*;
        return error.MissingNativeCostumeResource;
    };

    var ctx = context(session, allocator, null, null);
    const PoolContext = struct {
        ctx: *controller.Context,

        pub fn visible(self: *@This(), other: Actor) !bool {
            return self.ctx.visible(
                controller.Subject.fromActor(other),
                self.ctx.player orelse return false,
            );
        }
    };

    var pool_context = PoolContext{ .ctx = &ctx };

    if (try session.corpse_pool.reserve(
        &pool_context,
        lifecycle.CorpsePool.slots(session.game_type),
    )) |slot| {
        if (session.corpse_sources[slot]) |old| try removeActor(session, old);

        session.corpse_sources[slot] = null;
        const outer = if (resource.len == 0) null else costume(
            session,
            resource,
        ) catch |err| switch (err) {
            error.ResourceNotFound => null,
            else => return err,
        };

        if (outer) |value| {
            var corpse_actor = actor;

            corpse_actor.costume = value;
            corpse_actor.logic_resource = resource;

            const corpse = try lifecycle.corpse(corpse_actor, session.animation_time);
            const source = try appendActor(session, corpse, null);

            session.corpse_pool.actors[slot] = corpse;
            session.corpse_sources[slot] = source;
        }
    }

    if (index >= session.objects.entries.len) {
        @import(
            "contact_stack.zig",
        ).Enemy.init(
            &session.player.contact_residue,
            target.native,
        ).death(resource, actor.position, drop_position);
    }

    try removeActor(session, index);
}

pub fn restoreCorpse(session: anytype, source: usize) !void {
    var ctx = context(session, session.arena.allocator(), session.active_audio, null);
    const PoolContext = struct {
        ctx: *controller.Context,

        pub fn visible(self: *@This(), other: Actor) !bool {
            return self.ctx.visible(
                controller.Subject.fromActor(other),
                self.ctx.player orelse return false,
            );
        }
    };

    var pool_context = PoolContext{ .ctx = &ctx };

    if (try session.corpse_pool.reserve(
        &pool_context,
        lifecycle.CorpsePool.slots(session.game_type),
    )) |slot| {
        if (session.corpse_sources[slot]) |old| try removeActor(session, old);
        session.corpse_pool.actors[slot] = session.actor_slots[source];
        session.corpse_sources[slot] = source;
    }
}

pub fn networkCorpse(
    session: anytype,
    resource: []const u8,
    choreography: u32,
    sector: usize,
    position: @import("../assets/level.zig").Vec3,
) !void {
    var ctx = context(session, session.arena.allocator(), session.active_audio, null);
    const PoolContext = struct {
        ctx: *controller.Context,

        pub fn visible(self: *@This(), other: Actor) !bool {
            return self.ctx.visible(
                controller.Subject.fromActor(other),
                self.ctx.player orelse return false,
            );
        }
    };

    var pool_context = PoolContext{ .ctx = &ctx };
    const slot = try session.corpse_pool.reserve(
        &pool_context,
        lifecycle.CorpsePool.slots(session.game_type),
    ) orelse return;

    if (session.corpse_sources[slot]) |old| try removeActor(session, old);

    session.corpse_sources[slot] = null;

    const sprite = costume(session, resource) catch |err| switch (err) {
        error.ResourceNotFound => return,
        else => return err,
    };

    const template: Actor = .{
        .costume = sprite,
        .logic_resource = try session.arena.allocator().dupe(u8, resource),
        .sector = sector,
        .position = position,
        .yaw = 0,
        .flags = .{},
        .secondary_flags = .{},
        .scale_x = 1,
        .scale_y = 1,
        .height = 1,
        .choreography = choreography,
        .frame = 0,
        .angle_offset = 0,
    };

    const corpse = try lifecycle.corpse(template, session.animation_time);
    const source = try appendActor(session, corpse, null);

    session.corpse_pool.actors[slot] = corpse;
    session.corpse_sources[slot] = source;
}

pub fn appendActor(session: anytype, actor: Actor, pickup: ?inventory.Pickup) !usize {
    const index = try session.newActorSlot();

    std.debug.assert(session.source_to_entry[index] == null);
    std.debug.assert(session.actor_links.nodes[index].sector == null);

    session.actor_numbers[index] = 0;
    session.source_to_entry[index] = null;
    session.actor_slots[index] = actor;
    session.actor_slots[index].?.logic_id = session.allocateActorId();
    session.actor_slots[index].?.birth_order = session.next_actor_order;
    session.next_actor_order += 1;
    session.actor_slots[index].?.source_index = index;
    session.actor_slots[index].?.sector_link_order = session.actor_link_serial;
    session.actor_link_serial += 1;
    session.targets[index] = null;
    session.pickup_slots[index] = pickup;
    session.removed_actors[index] = false;
    session.actor_next_update[index] = 0;
    session.blood_slots[index] = null;
    session.general_slots[index] = if (actor.flags.physics) .{
        .velocity = .{ .x = 0, .y = 0, .z = 0 },
    } else null;

    session.splash_slots[index] = null;
    session.projectile_slots[index] = null;
    session.syncActor(index);

    return index;
}

pub fn costume(session: anytype, animation: []const u8) !*nwx.Costume {
    const a = session.arena.allocator();
    var key_buffer: lab.NameBuffer = undefined;
    const key = try lab.upperName(&key_buffer, animation);
    if (session.costumes.get(key)) |value| return value;

    const bytes = session.object_archive.find(animation, 0) catch |err| switch (err) {
        error.ResourceNotFound => try session.system_archive.find(animation, 0),
        else => return err,
    };

    const value = try a.create(nwx.Costume);

    value.* = try nwx.Costume.parse(a, bytes);
    try session.costumes.put(try a.dupe(u8, key), value);

    return value;
}

fn execute(phase: Phase, target: *Target, actor: *Actor, ctx: *controller.Context) !bool {
    switch (phase) {
        .animation => try target.advanceAnimation(actor, ctx),
        .selection => try target.deliverNext(actor, ctx),
        .tick => return controller.tick(target, actor, ctx),
    }

    return false;
}
