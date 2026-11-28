//! Effects and corpses created during play: splashes, dust, blood and the
//! bodies left behind.
//!
//! New sprite instances are prepended in front of the weapon and map
//! instances, while effects and corpses are appended to the actor list.
//! Bound splash and dust playback removes its own actor when it ends.

const std = @import("std");

const inventory = @import("../player/inventory.zig");
const network_actors = @import("../render/network_actors.zig");
const blood = @import("blood.zig");
const bubble = @import("bubble.zig");
const session_module = @import("session.zig");
const bits = @import("../util/bits.zig");

pub const SplashState = struct { selection_serial: ?u64 };

pub fn animations(session: anytype) !void {
    var index = session.actor_slots.len;

    while (index > session.objects.entries.len) {
        index -= 1;

        if (session.removed_actors[index]) continue;

        const actor = if (session.actor_slots[index]) |*value| value else continue;

        if (session.targets[index] != null) {
            _ = try session_module.run(
                session,
                session.arena.allocator(),
                session.active_audio,
                index,
                .animation,
            );
        } else if (session.splash_slots[index] != null) {
            if (try blood.advanceSplash(
                actor,
                session.animation_time,
            )) session.removed_actors[index] = true;
        } else if (@import("../script/object.zig").bound(actor.*)) {
            try @import(
                "../script/object.zig",
            ).advance(
                session,
                index,
                session.active_effects orelse return error.MissingObjectEffects,
            );
        } else if (network_actors.remoteWax(actor.*)) {
            try network_actors.advanceWax(actor, session.animation_time);
        } else try actor.advanceUnboundAnimation(session.animation_time);

        session.syncActor(index);
    }
}

pub fn firstActor(session: anytype) ?usize {
    return nextActor(session, session.objects.entries.len);
}

pub fn tickBeforePlayer(
    session: anytype,
    allocator: std.mem.Allocator,
    effects: *inventory.Effects,
) !void {
    return run(session, allocator, effects, firstActor(session), session.player_actor.birth_order);
}

pub fn firstAfterPlayer(session: anytype) ?usize {
    var next = firstActor(session);

    while (next) |index| : (next = nextActor(session, index + 1)) {
        if (session.actor_slots[index].?.birth_order > session.player_actor.birth_order) return index;
    }

    return null;
}

pub fn tick(
    session: anytype,
    allocator: std.mem.Allocator,
    effects: *inventory.Effects,
    first: ?usize,
) !void {
    return run(session, allocator, effects, first, null);
}

pub fn spawnSplash(session: anytype, effects: *inventory.Effects, request: blood.Splash) !void {
    session.player.contact_residue.invalidateProjection();

    const costume = try session_module.costume(session, blood.splash_costume_name);
    const actor = try blood.spawnSplash(costume, request, session.animation_time);
    const index = try session_module.appendActor(session, actor, null);

    session.splash_slots[index] = .{ .selection_serial = session.enemy_selection_serial };
    session.enemy_selection_serial += 1;

    try effects.append(.{ .sound = blood.splashSound(request) });
}

fn nextActor(session: anytype, start: usize) ?usize {
    for (start..session.actor_slots.len) |index| {
        if (!session.removed_actors[index] and session.actor_slots[index] != null) return index;
    }

    return null;
}

fn run(
    session: anytype,
    allocator: std.mem.Allocator,
    effects: *inventory.Effects,
    first: ?usize,
    before: ?u64,
) !void {
    var next = first;

    while (next) |index| {
        if (before) |order| if (session.actor_slots[index]) |actor| if (actor.birth_order > order) return;

        next = nextActor(session, index + 1);

        if (session.removed_actors[index]) continue;

        const actor = if (session.actor_slots[index]) |*value| value else continue;

        if (session.projectile_slots[index] != null) {
            try @import("../projectile/session.zig").tick(session, allocator, effects, index);
            continue;
        }

        if (network_actors.isRemote(session, index)) {
            try network_actors.schedule(session, allocator, effects, index);
            continue;
        }

        if (session.targets[index] != null) {
            if (actor.flags.logicReady() and !actor.secondary_flags.waiting_for_start and session.targets[index].?.next_tick <= session.animation_time) {
                const removed = try session_module.run(
                    session,
                    allocator,
                    session.active_audio,
                    index,
                    .tick,
                );

                try session.castEnemyEffects(allocator, effects);

                if (removed) try session_module.finishDeath(session, allocator, index);
            }

            if (!session.removed_actors[index] and session_module.inRemovalSector(
                session,
                session.actor_slots[index].?,
            )) try session_module.removeActor(session, index);

            continue;
        }

        if (@import(
            "../script/object.zig",
        ).bound(actor.*)) @import("../script/object.zig").tick(session, index);

        if (session.blood_slots[index] == null and session.general_slots[index] == null and session.pickup_slots[index] != null and actor.flags.logicReady() and !actor.secondary_flags.waiting_for_start and @as(u32, @bitCast(session.actor_next_update[index])) <= session.animation_time) {
            session.pickup_slots[index].?.tick(actor, session.player.position);
            actor.flags = bits.with(actor.flags, .{ .updated = true, .changed = true });
            session.syncActor(index);
        }

        const is_blood = session.blood_slots[index] != null;
        const state = if (session.blood_slots[index]) |*value| value else if (session.general_slots[index]) |*value| value else {
            if (session_module.inRemovalSector(
                session,
                actor.*,
            )) try session_module.removeActor(session, index);

            continue;
        };

        var runtime = session_module.scriptContext(session, effects, actor.secondary_flags);

        runtime.linked_actor = index;
        runtime.link_order = &actor.sector_link_order;

        var context = session_module.context(session, allocator, null, null);
        context.actors.runtime = &runtime;
        var world = context.world();
        world.contact_stack = .{ .residue = &session.player.contact_residue, .caller = .fragment };

        const logic_due = actor.flags.logicReady() and !actor.secondary_flags.waiting_for_start and @as(u32, @bitCast(session.actor_next_update[index])) <= session.animation_time;
        const is_bubble = std.mem.eql(u8, actor.logic_name, "fx_BubbleLogic");
        const is_fragment = std.mem.eql(u8, actor.logic_name, "FX_ExplosionFragment");
        const removed = if (is_bubble)
            (if (logic_due) try bubble.tick(
                actor,
                state,
                world,
                session.frame_seconds,
                session.animation_time,
            ) else false)
        else if (is_fragment) blk: {
            if (logic_due) try blood.generalPhysics(actor, state, world, session.frame_seconds);
            break :blk false;
        } else try step(actor, state, world, session.frame_seconds, is_blood);

        if (logic_due and !removed and (is_blood or is_bubble or is_fragment or std.mem.eql(
            u8,
            actor.logic_name,
            "misc_CorpseDispatch",
        ))) actor.flags = bits.with(actor.flags, .{ .updated = true, .changed = true });

        if (!removed and logic_due and session.pickup_slots[index] != null) {
            session.pickup_slots[index].?.tick(actor, session.player.position);
            actor.flags = bits.with(actor.flags, .{ .updated = true, .changed = true });
        }

        session.removed_actors[index] = removed;

        if (removed) session.player.contact_residue.invalidateProjection();

        for (session.corpse_sources, 0..) |source, slot| {
            if (source == index) session.corpse_pool.actors[slot] = actor.*;
        }

        session.syncActor(index);

        const splash = state.splash;
        const removal_sector = !removed and session_module.inRemovalSector(session, actor.*);

        if (splash) |request| try spawnSplash(session, effects, request);

        if (removal_sector) try session_module.removeActor(session, index);
    }
}

fn step(
    actor: *@import("../render/objects.zig").Actor,
    state: *blood.State,
    world: @import("physics.zig").World,
    dt: f32,
    is_blood: bool,
) !bool {
    _ = try blood.scheduledPhysics(actor, state, world, dt);

    return if (is_blood) blood.tick(actor, state, world, dt) else false;
}
