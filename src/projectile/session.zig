//! The projectile pools of a loaded level: the templates and the live
//! projectiles.
//!
//! A template keeps its sound references until the level's pools are closed.
//! Fuse and explosion sounds are registered in that order, both at the
//! lowest priority.

const std = @import("std");
const runtime = @import("runtime.zig");
const Item = @import("../assets/item.zig").Item;
const Actor = @import("../render/objects.zig").Actor;
const Vec3 = @import("../assets/level.zig").Vec3;
const inventory = @import("../player/inventory.zig");
const shooting = @import("../player/shooting.zig");
const collision = @import("../player/collision.zig");
const weapon = @import("../player/weapon.zig");
const enemy_session = @import("../enemy/session.zig");
const factory = @import("../enemy/item_spawn.zig");
const blood = @import("../enemy/blood.zig");

fn Contact(comptime Session: type) type {
    return struct {
        session: Session,
        state: *runtime.State,
        removed: bool = false,
        hit: ?usize = null,
        damage: f32 = 0,
        lateral: f32 = 0,
        residue: @import("contact.zig").Residue = .{},

        fn emit(raw: *anyopaque, event: collision.ContactEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.removed) return;
            if (event.kind == .actor) {
                const index = event.actor.?;
                const body = if (index == shooting.local_player) enemy_session.playerBody(self.session) else actorBody(self.session.collisionActors().get(index));
                if (body.flags & 0x100 != 0 or body.secondary_flags & 0x4190 == 0 or body.secondary_flags & 0x800c20 != 0) return;
                self.hit = if (index == shooting.local_player) index else self.session.collisionActors().get(index).source_index orelse return error.MissingProjectileContactActor;
                self.damage = self.state.descriptor.damage;
                self.lateral = event.origin.x;
                self.residue = self.session.player.contact_residue;
                self.removed = @as(i32, @bitCast(self.damage)) > 0 or self.state.config.allow_bounce == 0;
                self.state.descriptor.damage = 0;
            } else if (event.kind == .wall) {
                const wall = event.wall.?;
                const interaction = @import("../script/interaction.zig");
                const x = if (event.crossed) @as(f32, 0) else event.origin.x;
                const y = if (event.crossed) @as(f32, 0) else try self.session.player.contact_residue.height();
                for (interaction.wallEvents(&self.session.level, wall.sector, wall.index, 0x100, 2, y)) |maybe| if (maybe) |entry| {
                    if (!try interaction.overlayAccepts(&self.session.level, &self.session.scene, self.session.textures, entry.sector, entry.wall.?, x, y)) continue;
                    try self.session.inf.event(&self.session.level, .{ .sector = entry.sector, .wall = entry.wall, .mask = entry.mask, .object_id = entry.object_id, .now_ms = self.session.animation_time });
                };
                self.removed = self.state.config.allow_bounce == 0;
                self.state.descriptor.damage = 0;
            }
        }
    };
}

pub fn configuration(session: anytype, name: []const u8) !*const runtime.Config {
    const a = session.arena.allocator();
    const path = try runtime.configName(a, name);
    if (session.projectile_configs.get(path)) |existing| return existing;
    var item = try Item.parse(a, try factory.resource(session, path));
    defer item.deinit();
    const config = try a.create(runtime.Config);
    config.* = try runtime.Config.load(a, &item, name);
    try @import("../audio/registration.zig").projectileTemplate(&session.sound_ledger, a, &item, name, session.animation_time);
    try session.projectile_configs.put(config.name, config);
    return config;
}

pub fn create(session: anytype, descriptor: runtime.Descriptor, effects: *inventory.Effects) !usize {
    const config = try configuration(session, descriptor.item);
    const model = try enemy_session.model(session, config.model);
    const source = try enemy_session.bareModel(session, model, .{ .position = descriptor.origin, .sector = descriptor.sector });
    const actor = &session.actor_slots[source].?;
    session.projectile_slots[source] = runtime.initialize(actor, config, descriptor, session.animation_time);
    session.syncActor(source);
    if (descriptor.kind == .explosive) if (config.fuse_sound) |name| {
        var request: @import("../audio/request.zig").Request = .{ .basename = name, .priority = 64, .volume = 64, .flags = 1, .sector = actor.sector, .position = actor.position, .source = source, .mode = .loop };
        try session.drainSounds(effects);
        if (session.active_audio) |sound| {
            session.projectile_slots[source].?.fuse_handle = try sound.play(request, session.audioWorld(), session.animation_time);
            request.delivered = true;
        }
        try effects.append(.{ .sound = request });
    };
    return source;
}

pub fn launch(session: anytype, source: usize, owner: runtime.Owner, fraction: f32) !void {
    if (source >= session.projectile_slots.len or session.removed_actors[source]) return error.MissingProjectileActor;
    const state = if (session.projectile_slots[source]) |*value| value else return error.MissingProjectileActor;
    try runtime.launch(&session.actor_slots[source].?, state, owner, fraction, &session.angles, &session.contact_state.random);
    session.syncActor(source);
}

pub fn ensureMap(session: anytype, source: usize) !void {
    if (session.projectile_slots[source] != null) return;
    if (source >= session.objects.entries.len) return error.MissingProjectileConfiguration;
    const path = try std.fmt.allocPrint(session.arena.allocator(), "{s}.ITM", .{std.fs.path.stem(session.objects.entries[source].name)});
    var item = try Item.parse(session.arena.allocator(), try factory.resource(session, path));
    defer item.deinit();
    try initializeMap(session, source, &item);
}

pub fn initializeMap(session: anytype, source: usize, item: *const Item) !void {
    if (session.projectile_slots[source] != null) return;
    const name = try item.stringValue("PROJECTILE") orelse return error.MissingProjectileConfiguration;
    const config = try configuration(session, name);
    const actor = session.actor_slots[source].?;
    session.projectile_slots[source] = .{ .config = config, .held = false, .deadline = 0xffffffff, .pickup = true, .descriptor = .{ .kind = .knife, .item = config.name, .owner = null, .origin = .{ .x = 0, .y = 0, .z = 0 }, .sector = actor.sector, .pitch = 0, .yaw = 0, .damage = 0, .mass = 0, .rate = 0, .range = 0 } };
}

pub fn ignite(session: anytype, source: usize, damage: f32, sender: ?usize) !void {
    if (@as(u32, @bitCast(damage)) & 0x7fffffff == 0) return;
    try ensureMap(session, source);
    if (session.projectile_slots[source].?.config.explosion == null) return;
    session.projectile_blast_sender = sender;
    session.projectile_slots[source].?.explode = true;
}

pub fn tick(session: anytype, allocator: std.mem.Allocator, effects: *inventory.Effects, source: usize) !void {
    var actor = session.actor_slots[source].?;
    var state = session.projectile_slots[source].?;
    if (state.pickup) return @import("../render/model_state.zig").tick(session, source);
    var native = enemy_session.scriptContext(session, effects, actor.secondary_flags);
    native.linked_actor = source;
    native.link_order = &actor.sector_link_order;
    var ctx = enemy_session.context(session, allocator, session.active_audio, null);
    ctx.actors.runtime = &native;
    var world = ctx.world();
    world.contact_stack = .{ .residue = &session.player.contact_residue, .caller = if (state.descriptor.kind == .knife) .knife else .explosive };
    var motion: blood.State = .{ .velocity = state.velocity, .floor_cache = state.floor_cache, .wall_memory = state.wall_memory };
    _ = try blood.scheduledPhysics(&actor, &motion, world, session.frame_seconds);
    state.velocity = motion.velocity;
    state.floor_cache = motion.floor_cache;
    state.wall_memory = motion.wall_memory;
    const logic_due = actor.flags & 0x41 == 0x41 and actor.secondary_flags & 0x01000000 == 0 and @as(u32, @bitCast(session.actor_next_update[source])) <= session.animation_time;
    var removed = false;
    var contact = Contact(@TypeOf(session)){ .session = session, .state = &state };
    if (logic_due) {
        if (state.descriptor.kind == .explosive and session.animation_time >= state.deadline) {
            session.projectile_blast_sender = shooting.local_player;
            state.explode = true;
        } else {
            if (state.descriptor.kind == .explosive and !state.held and runtime.speed(state) < 0.1) {
                state.rotation = .{ .x = 0, .y = 0, .z = 0 };
                actor.flags |= 0x80000400;
            } else if (state.held and state.descriptor.owner != null and ownerOf(session, state.descriptor.owner.?) != null) {
                const owner = ownerOf(session, state.descriptor.owner.?).?;
                try native.changeSector(actor.sector, owner.sector);
                runtime.follow(&actor, owner);
            } else {
                const previous = state.velocity;
                motion = .{ .velocity = state.velocity, .floor_cache = state.floor_cache, .wall_memory = state.wall_memory };
                if (state.descriptor.owner) |owner| if (owner != shooting.local_player and owner < session.actor_slots.len and session.actor_slots[owner] != null) {
                    session.actor_slots[owner].?.flags |= 0x80000000;
                    session.syncActor(owner);
                };
                try blood.projectilePhysics(&actor, &motion, world, session.frame_seconds, state.descriptor.owner, if (state.descriptor.kind == .knife) .{ .context = &contact, .emit = Contact(@TypeOf(session)).emit } else null);
                state.velocity = motion.velocity;
                state.floor_cache = motion.floor_cache;
                state.wall_memory = motion.wall_memory;
                try runtime.alignFloor(&actor, &state.rotation, ctx.world());
                runtime.rotate(&actor, state.rotation, session.frame_seconds);
                runtime.afterMove(&state, previous);
            }
            if (state.descriptor.kind == .knife) {
                if (contact.hit != null and @as(i32, @bitCast(contact.damage)) > 0) {
                    const point = try contact.residue.position();
                    try aggregate(session, contact.hit.?, .{ .kind = 2, .damage = contact.damage, .mass = state.descriptor.mass, .speed = f(runtime.speed(state)), .pitch = actor.pitch, .yaw = actor.yaw, .lateral = contact.lateral, .height = try contact.residue.height() }, point, shooting.local_player);
                    if (@as(i32, @bitCast(contact.damage)) > 0x40000000) {
                        const body = if (contact.hit.? == shooting.local_player) enemy_session.playerBody(session) else actorBody(session.actor_slots[contact.hit.?].?);
                        if (body.secondary_flags & 0x10 == 0) {
                            for (session.pending_hits.items) |*pending| if (pending.target == contact.hit.? and pending.input.kind == 2) {
                                if (body.secondary_flags & 0x4180 != 0) pending.blood.add(&session.angles, state.descriptor.origin, point, actor.yaw, body.sector, 3, false) else pending.dust.add(&session.angles, state.descriptor.origin, point, actor.yaw, body.sector, 3, true);
                                break;
                            };
                        }
                    }
                }
                if (!state.held and runtime.speed(state) < 0.1) {
                    if (state.config.dead_item) |name| if (try enemy_session.spawnItem(session, name, .{ .position = actor.position, .sector = actor.sector })) |created| {
                        var dropped = session.actor_slots[created].?;
                        dropped.yaw = actor.yaw;
                        var rotation: Vec3 = .{ .x = 0, .y = 0, .z = 0 };
                        try runtime.alignFloor(&dropped, &rotation, ctx.world());
                        session.actor_slots[created] = dropped;
                        if (session.pickup_slots[created]) |*pickup| pickup.enabled = false;
                        if (std.mem.eql(u8, dropped.logic_name, "shot_ProjectileDispatch")) {
                            var ground = state;
                            ground.held = false;
                            ground.pickup = true;
                            ground.explode = false;
                            ground.deadline = 0xffffffff;
                            ground.descriptor.owner = null;
                            ground.descriptor.damage = 0;
                            ground.velocity = .{ .x = 0, .y = 0, .z = 0 };
                            ground.rotation = ground.velocity;
                            session.projectile_slots[created] = ground;
                        }
                        session.syncActor(created);
                    };
                    removed = true;
                }
                removed = removed or contact.removed;
            } else if (session.scene.sectors[actor.sector].flags & 0x80 != 0 and state.fuse_handle != null) {
                if (session.active_audio) |sound| sound.engine.stop(state.fuse_handle.?);
                state.fuse_handle = null;
            }
            removed = removed or session.scene.sectors[actor.sector].flags & 0x01000000 != 0;
        }
        if (!removed) actor.flags |= 0x80000080;
    }
    session.actor_slots[source] = actor;
    session.projectile_slots[source] = state;
    session.syncActor(source);
    if (motion.splash) |splash| {
        const costume = try enemy_session.costume(session, blood.splash_costume_name);
        const created = try enemy_session.appendActor(session, try blood.spawnSplash(costume, splash, session.animation_time), null);
        session.splash_slots[created] = .{ .selection_serial = session.enemy_selection_serial };
        session.enemy_selection_serial += 1;
        try effects.append(.{ .sound = blood.splashSound(splash) });
    }
    if (removed) try enemy_session.removeActor(session, source);
}

pub fn flushExplosions(session: anytype, allocator: std.mem.Allocator, effects: *inventory.Effects) !void {
    session.impact_state.count = 0;
    for (session.projectile_slots, 0..) |optional, source| {
        const state = optional orelse continue;
        if (!state.explode or session.removed_actors[source]) continue;
        const actor = session.actor_slots[source].?;
        try enemy_session.playerNoise(session, allocator, effects, 200, 0x82);
        session.actor_slots[source].?.flags |= 0x80000100;
        session.syncActor(source);
        if (session.enemy_visibility.lists[actor.sector] == null and session.level.sectors.len > 1)
            _ = try session.enemy_visibility.connected(&session.level, &session.scene, &session.angles, actor.sector, (actor.sector + 1) % session.level.sectors.len);
        const single = [_]u16{@intCast(actor.sector)};
        const connected = session.enemy_visibility.lists[actor.sector] orelse &single;
        var visit: usize = 0;
        while (visit <= connected.len) : (visit += 1) {
            const sector: usize = if (visit == 0) actor.sector else connected[visit - 1];
            var actors = session.collisionActors();
            actors.player = enemy_session.playerBody(session);
            var iterator = actors.inLoadedSector(sector);
            while (iterator.next()) |index| {
                const body = if (index == shooting.local_player) actors.player.? else actorBody(actors.get(index));
                const target = if (index == shooting.local_player) index else actors.get(index).source_index.?;
                if (!(@import("../enemy/perception.zig").distance(.{ .x = actor.position.x, .z = actor.position.z }, .{ .x = body.position.x, .z = body.position.z }) < state.config.radius)) continue;
                if ((body.secondary_flags & 0x10 == 0 and state.descriptor.owner == target) or body.flags & 0x100 != 0) continue;
                if (!try session.enemy_visibility.actorsVisible(&session.level, &session.scene, &session.angles, .{ .position = actor.position, .sector = actor.sector, .height = actor.height, .radius = actor.collision_radius }, .{ .position = body.position, .sector = body.sector, .height = body.height, .radius = body.radius }, &session.contact_state.random, session.animation_time)) continue;
                const blast = runtime.blast(state.config, actor.position, body);
                try aggregate(session, target, blast.damage, blast.impact, session.projectile_blast_sender);
            }
        }
        session.actor_slots[source].?.flags = actor.flags | 0x80000000;
        session.syncActor(source);
        if (state.held and state.descriptor.owner == shooting.local_player and session.weapon_state.held_projectile != null) {
            session.weapon_state.held_projectile = null;
            if (gameFlags(session, effects) & 8 == 0) {
                if (session.inventory.slots[session.inventory.selected_weapon]) |*item| item.count -%= 1;
            }
        }
        try @import("visual.zig").explode(session, allocator, effects, state.config, actor);
        try enemy_session.removeActor(session, source);
        return;
    }
}

pub fn flushContacts(session: anytype, effects: *inventory.Effects) !void {
    var index: usize = 0;
    while (index < session.pending_hits.items.len) {
        const pending = session.pending_hits.items[index];
        const sent = try @import("../render/network_combat.zig").postDamage(session, pending);
        if (!sent) {
            session.pending_hits.items[index].queue_serial = session.enemy_selection_serial;
            session.enemy_selection_serial += 1;
        }
        if (pending.blood.count != 0 and gameFlags(session, effects) & 2 == 0) {
            const costume = try enemy_session.costume(session, blood.costume_name);
            for (0..@intCast(pending.blood.count)) |_| {
                const spawned = try blood.spawn(costume, &session.contact_state.random, pending.blood.sector, pending.blood.average(), session.animation_time);
                const source = try enemy_session.appendActor(session, spawned.actor, null);
                session.blood_slots[source] = spawned.state;
            }
        }
        if (pending.dust.count != 0) {
            for (0..@abs(pending.dust.count)) |_| {
                _ = weapon.randomNext(&session.contact_state.random);
                try @import("../enemy/impact.zig").spawnBound(session, "DUST.NWX", pending.dust.sector, pending.dust.average());
            }
        }
        if (sent) _ = session.pending_hits.orderedRemove(index) else index += 1;
    }
}

pub fn enemyThrow(session: anytype, target: *@import("../player/target.zig").Target, actor: *Actor, ctx: *@import("../enemy/controller.zig").Context, effects: *inventory.Effects) !void {
    const name = target.config.throw_item;
    if (name.len == 0) return;
    const source = actor.source_index orelse return error.MissingEnemyActorId;
    const projectile = std.ascii.eqlIgnoreCase(name, "pdynam.itm") or std.ascii.eqlIgnoreCase(name, "pknife.itm") or std.mem.indexOf(u8, name, "PROJ") != null or std.mem.indexOf(u8, name, "proj") != null;
    var created: ?usize = null;
    if (projectile) {
        const kind: runtime.Kind = if (std.ascii.eqlIgnoreCase(name, "pknife.itm")) .knife else .explosive;
        var mode = try @import("../enemy/config.zig").loadWeapon(session.arena.allocator(), &.{ session.object_archive, session.weapon_archive, session.system_archive }, .pistol);
        const path = if (kind == .knife) "BGKNIFE.ITM" else "BGDYNAM.ITM";
        const bytes = factory.resource(session, path) catch |err| switch (err) {
            error.ResourceNotFound => null,
            else => return err,
        };
        if (bytes) |data| {
            var item = try Item.parse(session.arena.allocator(), data);
            defer item.deinit();
            mode = (try weapon.Config.load(session.arena.allocator(), &item)).modes[0];
        }
        const descriptor: runtime.Descriptor = .{ .kind = kind, .item = name, .owner = source, .origin = .{ .x = actor.position.x, .y = f(@as(f64, actor.height) * @as(f32, 0.92) + actor.position.y), .z = actor.position.z }, .sector = actor.sector, .pitch = actor.pitch, .yaw = actor.yaw +% actor.head_angles[1], .damage = f((weapon.randomFloat(ctx.random, 0.2) + @as(f64, @as(f32, 0.9))) * mode.damage), .mass = mode.mass, .rate = mode.rate, .range = mode.effective_range };
        created = try create(session, descriptor, effects);
        actor.flags |= 0x80000000;
        try launch(session, created.?, .{ .source = source, .position = actor.position, .sector = actor.sector, .height = actor.height, .velocity = actor.velocity, .pitch = actor.pitch, .yaw = actor.yaw }, 1);
    } else created = try enemy_session.spawnItem(session, name, .{ .position = actor.position, .sector = actor.sector });
    const index = created orelse return;
    session.actor_slots[index].?.position.y = f(@as(f64, actor.height) * @as(f32, 0.8) + session.actor_slots[index].?.position.y);
    const velocity = runtime.vector(ctx.angles, target.ai.throw_yaw, target.ai.throw_pitch, target.config.throw_velocity);
    if (session.actor_slots[index].?.secondary_flags & 0x40 != 0) {
        const thrown = if (session.targets[index]) |*value| value else return error.MissingThrownActorLogic;
        thrown.ai.physics.velocity = velocity;
    } else if (session.actor_slots[index].?.secondary_flags & 0x20 != 0) {
        const state = if (session.projectile_slots[index]) |*value| value else return error.MissingProjectileActor;
        state.velocity = velocity;
        const subject: ?Vec3 = if (target.ai.target) |id| switch (id) {
            .player => if (ctx.player) |player| player.position else null,
            .actor => |other| if (other < session.actor_slots.len and session.actor_slots[other] != null) session.actor_slots[other].?.position else null,
        } else null;
        if (subject) |position| {
            const distance = @import("../enemy/perception.zig").distance(.{ .x = target.ai.physics.position.x, .z = target.ai.physics.position.z }, .{ .x = position.x, .z = position.z });
            const elapsed = distance / target.config.throw_velocity * @as(f32, 1000);
            if (!std.math.isFinite(elapsed) or elapsed < -2147483648 or elapsed >= 2147483648) return error.InvalidProjectileFuse;
            var timer: i32 = @intFromFloat(elapsed);
            if (@as(i32, @intCast(weapon.randomNext(ctx.random) & 0xfff)) - 0x418 >= 0) timer +%= @as(i32, @intCast(weapon.randomNext(ctx.random) & 0xfff)) - 0x418;
            state.deadline = session.animation_time +% @as(u32, @bitCast(timer));
        }
    } else if (session.actor_slots[index].?.logic_name.len == 0) {
        session.actor_slots[index].?.logic_name = "Physics_Dispatch";
        session.actor_slots[index].?.flags |= 0x80000040;
        session.general_slots[index] = .{ .velocity = velocity };
    }
    session.syncActor(index);
    try session.drainSounds(effects);
    try ctx.sound(session.actor_slots[index].?, target.config.shoot_sound, 0, 1, 0, false);
}

pub fn emitEnemyProjectile(session: anytype, target: *@import("../player/target.zig").Target, actor: *Actor, ctx: *@import("../enemy/controller.zig").Context) !void {
    const source = actor.source_index orelse return error.MissingEnemyActorId;
    session.actor_slots[source] = actor.*;
    session.targets[source] = target.*;
    session.syncActor(source);
    var local = inventory.Effects.init(session.allocator);
    defer local.deinit();
    const effects = session.active_effects orelse &local;
    if (ctx.actors.runtime) |native| if (native.effects != effects) {
        try effects.appendSlice(native.effects.items);
        native.effects.clearRetainingCapacity();
    };
    try enemyThrow(session, target, actor, ctx, effects);
    if (session.active_effects == null) try session.enemy_native_effects.appendSlice(session.arena.allocator(), local.items);
    session.actor_slots[source] = actor.*;
    session.targets[source] = target.*;
    session.syncActor(source);
    const native_context = ctx.actors.runtime;
    const required = ctx.actors.required_sectors;
    ctx.* = enemy_session.context(session, ctx.allocator, ctx.audio, required);
    if (native_context) |native| {
        const script_effects = native.effects;
        const entity_mask = native.entity_mask;
        native.* = enemy_session.scriptContext(session, script_effects, entity_mask);
        native.linked_actor = source;
        native.link_order = &actor.sector_link_order;
        ctx.actors.runtime = native;
    }
}

fn ownerOf(session: anytype, source: usize) ?runtime.Owner {
    if (source == shooting.local_player) return .{ .source = source, .position = session.player.position, .sector = session.player.sector, .height = session.player.body_height, .velocity = session.player.velocity, .pitch = session.player.pitch, .yaw = session.player.yaw };
    if (source >= session.actor_slots.len or session.removed_actors[source]) return null;
    const actor = session.actor_slots[source] orelse return null;
    const velocity = if (session.targets[source]) |target| target.ai.physics.velocity else if (session.general_slots[source]) |state| state.velocity else Vec3{ .x = 0, .y = 0, .z = 0 };
    return .{ .source = source, .position = actor.position, .sector = actor.sector, .height = actor.height, .velocity = velocity, .pitch = actor.pitch, .yaw = actor.yaw };
}

fn actorBody(actor: Actor) collision.Body {
    return .{ .position = actor.position, .sector = actor.sector, .height = actor.height, .radius = actor.collision_radius, .flags = actor.flags, .secondary_flags = actor.secondary_flags };
}

fn aggregate(session: anytype, target: usize, damage: shooting.DamageInput, position: Vec3, sender: ?usize) !void {
    const hit: shooting.ActorHit = .{ .index = target, .position = position, .lateral = damage.lateral, .height = damage.height, .distance = position.z };
    for (session.pending_hits.items) |*pending| if (pending.matchesFrom(target, damage.kind, sender)) {
        pending.add(&session.angles, damage, hit);
        pending.position.x = f(@as(f64, pending.position.x) + position.x);
        return;
    };
    var pending = shooting.PendingHit.initFrom(target, sender, &session.angles, damage, hit);
    pending.position.x = position.x;
    try session.pending_hits.append(session.arena.allocator(), pending);
}

fn f(value: f64) f32 {
    return @floatCast(value);
}

fn gameFlags(session: anytype, effects: *inventory.Effects) u32 {
    var shots = weapon.Shots.init(session.arena.allocator());
    defer shots.deinit();
    return session.weaponContext(effects, &shots, false).game_flags;
}
