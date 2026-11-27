//! Enemy logic: the state an enemy keeps and the decisions it makes each
//! tick - target, mode, movement, attacks and death.
//!
//! One record holds velocity, mode and submode, health, emotion, and the
//! attack, sight and cover timers. Decisions read the cached clock rather
//! than the current one, so a tick is self-consistent.

const std = @import("std");
const level = @import("../assets/level.zig");
const scene = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const Actor = @import("../render/objects.zig").Actor;
const collision = @import("../player/collision.zig");
const weapon = @import("../player/weapon.zig");
const shooting = @import("../player/shooting.zig");
const audio = @import("../audio/runtime.zig");
const occlusion = @import("../audio/occlusion.zig");
const physics = @import("physics.zig");
const lifecycle = @import("lifecycle.zig");
const perception = @import("perception.zig");
const ballistics = @import("ballistics.zig");
pub const Subject = perception.Subject;

pub const TargetId = union(enum) { player, actor: usize };

pub const Node = struct {
    kind: u32,
    sector: usize,
    position: level.Vec3,
    used_at: u32 = 0,
    links: []const usize = &.{},
};

pub const Effect = union(enum) {
    fire: struct { source: ?usize, shot: weapon.Shot },
};
pub const Effects = @import("../util/fixed_list.zig").FixedList(Effect, error{TooManyEnemyShots});

pub const Shared = struct {
    next_shot: u32 = 0,
    next_taunt: u32 = 0,
    crt_random: u32 = 1,
    now: u32 = 0,
    entry_random: u32 = 0,
    next_tick: u32 = 0,
    animation_message: u32 = 0,
    free_snapshots: ?*Snapshot = null,
    total_enemies: f32 = 0,
    killed_enemies: f32 = 0,
    sanchez_enabled: bool = false,
};

pub const State = struct {
    physics: physics.State = .{},
    base_mode: u32 = 0,
    remove: bool = false,
    special: bool = false,
    deadline: u32 = 0,
    timer20: u32 = 0,
    timer24: u32 = 0,
    timer2c: u32 = 0,
    timer30: u32 = 0,
    sub_timer: u32 = 0,
    watch_at: u32 = 0,
    timer3c: u32 = 0,
    taunt_at: u32 = 0,
    aim_yaw: i16 = 0,
    last_taunt: ?[]const u8 = null,
    last_taunt_resource: ?@import("../save/sound.zig").Record = null,
    cover_task: ?usize = null,
    task_nodes: []const TaskNode = &.{},
    cover_node: ?usize = null,
    obstacle_yaw: i16 = 0,
    check_los: bool = true,
    check_fov: bool = true,
    check_cover: bool = true,
    has_los: bool = false,
    in_fov: bool = false,
    covered: bool = false,
    previous_seen_at: u32 = 0,
    last_seen_at: u32 = 0,
    target: ?TargetId = null,
    last_seen: level.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    last_seen_sector_valid: bool = false,
    last_seen_sector: usize = 0,
    target_yaw: i16 = 0,
    timer12c: u32 = 2000,
    visible_until: u32 = 0,
    throw_pitch: i16 = 0,
    throw_yaw: i16 = 0,
    task_active: bool = false,
    task_values: [3]u32 = @splat(0),
    updated_at: u32 = 0,
    stack: ?*Snapshot = null,
    block_count: u8 = 0,
    fall_voice: bool = false,
    activated: u8 = 0,

    pub fn init(config: @import("config.zig").Config) State {
        return .{ .base_mode = config.base_mode, .watch_at = config.watch_timer_time, .physics = .{ .move_speed = config.run_speed } };
    }
};

pub const TaskNode = struct {
    kind: u32,
    sector: usize,
    position: level.Vec3,
    used_at: u32,
    value1c: u32,
    value20: u32,
    time24: u32,
};

pub const Snapshot = struct {
    pool: *?*Snapshot,
    next_free: ?*Snapshot = null,
    ai: State,
    mode: u32,
    previous_mode: u32,
    damage: shooting.EnemyState,
    anger: f32,
    fear: f32,
    animation_ended: bool,
    config_name: []const u8 = "",
    config: @import("config.zig").Config = .{},
    attack_at: u32 = 0,
    sight_at: u32 = 0,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    level: *const level.Level,
    scene: *const scene.Scene,
    angles: *const camera.Angles,
    actors: collision.Actors,
    targets: []?@import("../player/target.zig").Target = &.{},
    actor_slots: []?Actor = &.{},
    player: ?Subject,
    visibility: *occlusion.Cache,
    random: *u32,
    now: u32,
    elapsed_seconds: f32,
    audio: ?*audio.Runtime = null,
    shared: *Shared,
    effects: *Effects,
    shot_sink: ?struct {
        context: *anyopaque,
        emit: *const fn (*anyopaque, *@import("../player/target.zig").Target, *Actor, *Context, weapon.Shot) anyerror!void,
    } = null,
    nodes: []Node = &.{},
    difficulty: u32 = 0x100000,
    before_sound: ?struct { context: *anyopaque, drain: *const fn (*anyopaque) anyerror!void } = null,
    player_visible: bool = false,
    fall_sound: []const u8 = "bgfall.wav",
    sanchez_sites: []const @import("sanchez.zig").Site = &.{},
    hit_sender: ?Subject = null,
    hit_sender_id: ?TargetId = null,
    statistics: ?*@import("../player/inventory.zig").Statistics = null,
    hit_result: ?struct { context: *anyopaque, enqueue: *const fn (*anyopaque, ?TargetId, u32) anyerror!void } = null,
    complete_level: ?struct { context: *anyopaque, enqueue: *const fn (*anyopaque) anyerror!void } = null,
    reflected_hit: ?struct { context: *anyopaque, enqueue: *const fn (*anyopaque, ?usize, shooting.DamageInput) anyerror!void } = null,
    projectile_sink: ?struct { context: *anyopaque, emit: *const fn (*anyopaque, *@import("../player/target.zig").Target, *Actor, *Context) anyerror!void } = null,
    contact_residue: ?*@import("../projectile/contact.zig").Residue = null,
    state_stack: ?@import("contact_stack.zig").Enemy = null,
    contact_successor_present: bool = true,
    contact_sector_events: bool = true,
    contact_hidden_taunt: bool = false,

    pub fn world(self: *Context) physics.World {
        return .{ .level = self.level, .scene = self.scene, .angles = self.angles, .actors = self.actors };
    }

    pub fn visible(self: *Context, first: Subject, second: Subject) !bool {
        return self.visibility.actorsVisible(self.level, self.scene, self.angles, .{ .position = first.position, .sector = first.sector, .height = first.height, .radius = first.radius }, .{ .position = second.position, .sector = second.sector, .height = second.height, .radius = second.radius }, self.random, self.now);
    }

    pub fn sound(self: *Context, actor: Actor, name: []const u8, flags: u32, base: f32, span: f32, speech: bool) !void {
        if (name.len == 0) return;
        if (self.before_sound) |pending| try pending.drain(pending.context);
        var volume: i32 = 127;
        if (flags & 0x10 == 0) if (self.player) |listener| {
            if (!try self.visibility.connected(self.level, self.scene, self.angles, actor.sector, listener.sector) or !try self.visible(listener, Subject.fromActor(actor))) volume >>= 1;
        };
        const runtime = self.audio orelse {
            if (self.contact_hidden_taunt) if (self.contact_residue) |residue| {
                @import("contact_stack.zig").Enemy.hiddenSound(residue, .unknown_runtime);
                residue.invalidateProjection();
            };
            return;
        };
        const previous_id = runtime.engine.next_id;
        const instances_full = for (1..runtime.engine.allocated.len) |id| {
            if (!runtime.engine.allocated[id] and runtime.engine.find(@intCast(id)) == null) break false;
        } else true;
        const handle = try runtime.play(.{ .basename = name, .priority = 64, .volume = volume, .flags = flags, .sector = actor.sector, .position = actor.position, .source = actor.source_index, .occlusion_applied = true }, null, self.now);
        if (self.contact_hidden_taunt) if (self.contact_residue) |residue| {
            @import("contact_stack.zig").Enemy.hiddenSound(residue, if (runtime.engine.next_id != previous_id) .driver_enabled else if (instances_full) .exhausted else .unknown_runtime);
        };
        if (handle) |id| {
            const voice = runtime.engine.find(id) orelse return error.MissingEnemyVoice;
            var params = voice.params;
            if (span != 0) params.frequency_factor = f(weapon.randomFloat(self.random, span) + @as(f64, base));
            if (speech) params.flags = @import("../audio/engine.zig").Flags.speech;
            try runtime.engine.adjust(id, params);
        }
        if (self.contact_hidden_taunt) if (self.contact_residue) |residue| {
            if (handle) |id| residue.projection.words = .{ 0x48000000, 1, null, id } else {
                residue.projection.words[2] = 0;
                residue.projection.words[3] = 0;
            }
        };
    }

    fn enemyStack(self: *Context, native: @import("../script/cmm.zig").Native) ?@import("contact_stack.zig").Enemy {
        var stack = @import("contact_stack.zig").Enemy.init(self.contact_residue orelse return null, native);
        stack.successor_present = self.contact_successor_present;
        stack.now = self.now;
        return stack;
    }

    fn perceptionWorld(self: *Context) perception.World {
        return .{ .allocator = self.allocator, .level = self.level, .scene = self.scene, .angles = self.angles, .visibility = self.visibility, .random = self.random, .now = self.now };
    }

    fn subject(self: *Context, id: ?TargetId) ?Subject {
        const value = id orelse return null;
        return switch (value) {
            .player => self.player,
            .actor => |source| blk: {
                if (self.actor_slots.len != 0) {
                    if (source >= self.actor_slots.len) break :blk null;
                    if (self.actors.source_to_entry) |indices| if (indices[source] == null) break :blk null;
                    break :blk if (self.actor_slots[source]) |actor| Subject.fromActor(actor) else null;
                }
                for (self.actors.all()) |actor| if (actor.source_index == source) break :blk Subject.fromActor(actor);
                break :blk null;
            },
        };
    }

    fn schedule(self: *Context, time: u32) void {
        self.shared.next_tick = @min(self.shared.next_tick, time);
    }
};

pub fn push(target: anytype, ctx: *Context) !void {
    var depth: usize = 0;
    var entry = target.ai.stack;
    while (entry) |value| : (entry = value.ai.stack) depth += 1;
    const snapshot = if (ctx.shared.free_snapshots) |available| blk: {
        ctx.shared.free_snapshots = available.next_free;
        break :blk available;
    } else try ctx.allocator.create(Snapshot);
    snapshot.* = .{ .pool = &ctx.shared.free_snapshots, .ai = target.ai, .mode = target.mode, .previous_mode = target.previous_mode, .damage = target.damage, .anger = target.anger, .fear = target.fear, .animation_ended = target.animation_ended, .config_name = target.config_name, .config = target.config, .attack_at = target.attack_at, .sight_at = target.sight_at };
    target.ai.stack = snapshot;
    target.ai.task_nodes = &.{};
    target.ai.task_active = false;
    target.ai.task_values = @splat(0);
    if (depth > 19) target.previous_mode = 0x80000007;
}

pub fn restore(target: anytype, actor: *Actor) !void {
    const saved = target.ai.stack orelse return;
    const previous = target.ai;
    target.mode = saved.mode;
    target.previous_mode = saved.previous_mode;
    const velocity = target.damage.velocity;
    target.damage = saved.damage;
    target.damage.velocity = velocity;
    target.anger = saved.anger;
    target.fear = saved.fear;
    target.ai.remove = saved.ai.remove;
    target.ai.special = saved.ai.special;
    target.ai.deadline = saved.ai.deadline;
    target.ai.timer20 = saved.ai.timer20;
    target.ai.timer24 = saved.ai.timer24;
    target.ai.timer2c = saved.ai.timer2c;
    target.ai.timer30 = saved.ai.timer30;
    target.ai.sub_timer = saved.ai.sub_timer;
    target.ai.watch_at = saved.ai.watch_at;
    target.ai.timer3c = saved.ai.timer3c;
    target.ai.aim_yaw = saved.ai.aim_yaw;
    target.config = saved.config;
    target.config_name = saved.config_name;
    target.ai.last_taunt = saved.ai.last_taunt;
    target.ai.last_taunt_resource = saved.ai.last_taunt_resource;
    target.ai.cover_task = saved.ai.cover_task;
    target.ai.task_nodes = saved.ai.task_nodes;
    target.ai.cover_node = saved.ai.cover_node;
    target.ai.physics = saved.ai.physics;
    target.ai.physics.velocity = previous.physics.velocity;
    target.ai.physics.position = previous.physics.position;
    target.ai.physics.sector = previous.physics.sector;
    target.ai.physics.sampled = previous.physics.sampled;
    target.ai.physics.yaw = previous.physics.yaw;
    target.ai.obstacle_yaw = saved.ai.obstacle_yaw;
    target.ai.task_active = saved.ai.task_active;
    target.ai.task_values = saved.ai.task_values;
    _ = try target.select(actor, saved.damage.current_chor);
    target.ai.stack = saved.ai.stack;
    saved.next_free = saved.pool.*;
    saved.pool.* = saved;
}

pub fn clearStack(target: anytype) void {
    while (target.ai.stack) |saved| {
        target.ai.stack = saved.ai.stack;
        saved.next_free = saved.pool.*;
        saved.pool.* = saved;
    }
}

pub fn tick(target: anytype, actor: *Actor, ctx: *Context) !bool {
    if (target.sanchez) {
        if (!try @import("sanchez.zig").tick(target, actor, ctx)) return false;
    }
    ctx.shared.entry_random = weapon.randomNext(ctx.random);
    ctx.shared.now = ctx.now;
    ctx.shared.next_tick = ctx.shared.now +% 10000;
    target.ai.physics.sample(actor.*, target.damage.velocity);
    if (target.ai.activated != 0) target.ai.activated = 2;
    target.anger = clamp(f(@as(f64, target.config.confidence) * ctx.elapsed_seconds + target.anger));
    target.fear = clamp(f(@as(f64, target.fear) - @as(f64, target.config.panic_rate) * ctx.elapsed_seconds));
    var tick_world = ctx.world();
    tick_world.enemy_stack = ctx.enemyStack(target.native);
    const moving = try physics.damp(actor.*, &target.ai.physics, tick_world, ctx.elapsed_seconds);
    target.damage.velocity = target.ai.physics.velocity;
    const active = try tickEvent(target, actor, 1, ctx, 0x00422a3b);
    if ((!moving and !active) or target.ai.special) {
        if (target.ai.special and target.damage.current_chor == target.config.walk_chor) {
            const stack = ctx.enemyStack(target.native);
            if (stack) |value| value.specialSelect();
            if (try target.select(actor, target.config.watch_chor)) if (stack) |value| value.frame(try (try actor.sprite()).select(actor.choreography, actor.frame, 0, actor.angle_offset));
        }
    } else {
        const Selection = struct {
            target: @TypeOf(target),
            actor: *Actor,
            stack: ?@import("contact_stack.zig").Enemy,

            pub fn select(self: *@This(), choreography: u32) !void {
                if (try self.target.select(self.actor, choreography)) if (self.stack) |stack| {
                    stack.frameAt(if (self.target.ai.physics.movement_mode == 1) 0x20 else -0x2c, try (try self.actor.sprite()).select(self.actor.choreography, self.actor.frame, 0, self.actor.angle_offset));
                };
            }
        };
        var selection = Selection{ .target = target, .actor = actor, .stack = ctx.enemyStack(target.native) };
        const signal = try physics.move(actor, &target.ai.physics, &target.damage.health, target.previous_mode, @truncate(target.damage.current_chor), .{ .walk_speed = target.config.walk_speed, .run_speed = target.config.run_speed, .walk_chor = target.config.walk_chor, .run_chor = target.config.run_chor, .step_height = target.config.max_step, .drop_height = target.config.max_drop }, ctx.world(), ctx.elapsed_seconds, ctx.shared.now, &ctx.shared.next_tick, &selection);
        target.damage.velocity = target.ai.physics.velocity;
        if (signal != 0) _ = try tickEvent(target, actor, signal, ctx, 0x00422a85);
        if (ctx.enemyStack(target.native)) |stack| stack.commit(actor.position, target.ai.physics.position, actor.sector != target.ai.physics.sector, ctx.contact_sector_events);
        if (ctx.actors.runtime) |runtime| try runtime.changeSector(actor.sector, target.ai.physics.sector);
        physics.commit(actor, target.ai.physics);
        ctx.shared.next_tick = 0;
    }
    target.damage.velocity = target.ai.physics.velocity;
    target.ai.updated_at = ctx.shared.now;
    target.next_tick = ctx.shared.next_tick;
    return target.ai.remove;
}

pub fn message(target: anytype, actor: *Actor, code: u32, arguments: []const u32, ctx: *Context) !void {
    if (target.sanchez and code == 99 and target.mode & 0x3c0 != 0) {
        try completeLevel(ctx);
        return;
    }
    if (target.sanchez and !ctx.shared.sanchez_enabled) return;
    if (target.native == .farmer and code == 0x78) return;
    _ = arguments;
    ctx.shared.entry_random = weapon.randomNext(ctx.random);
    switch (code) {
        1 => {
            try fire(target, actor, ctx);
            _ = try event(target, actor, 4, ctx);
        },
        0x62, 0x63, 3, 0x60 => {
            if (code == 0x62 or code == 0x63) target.animation_ended = true;
            ctx.shared.animation_message = code;
            _ = try event(target, actor, 7, ctx);
        },
        0x7e, 0x80, 0x81 => {
            _ = try event(target, actor, switch (code) {
                0x7e => 10,
                0x80 => 12,
                else => 13,
            }, ctx);
            if (ctx.player) |player| if ((ctx.shared.entry_random & 0xff) <= @as(u32, if (ctx.difficulty == 0x800000) 13 else 25) or try ctx.visible(Subject.fromActor(actor.*), player)) try retarget(target, actor, .player, ctx);
            target.sight_at = ctx.shared.now +% 2000;
        },
        0x7f => {
            _ = try event(target, actor, 11, ctx);
        },
        0x82 => if (target.mode == 1) {
            if (ctx.player) |player| if ((ctx.shared.entry_random & 0xff) <= @as(u32, if (ctx.difficulty == 0x800000) 13 else 25) or try ctx.visible(Subject.fromActor(actor.*), player)) try retarget(target, actor, .player, ctx);
            target.sight_at = ctx.shared.now +% 2000;
            emotion(target, -1, 4);
        },
        0x83 => {
            _ = try event(target, actor, 14, ctx);
        },
        else => {},
    }
    target.next_tick = 0;
}

pub fn hitMessage(target: anytype, actor: *Actor, input: shooting.DamageInput, ctx: *Context) !void {
    if (target.sanchez and !ctx.shared.sanchez_enabled) return;
    if (target.native == .farmer or target.native == .slim or target.native == .bob) {
        if (ctx.hit_sender) |sender| if (sender.secondary_flags & 0x40 != 0) return;
        const death = try shooting.damageEnemy(ctx.angles, actor.*, &target.damage, input);
        target.ai.physics.velocity = target.damage.velocity;
        if (death != null) try completeLevel(ctx) else _ = try event(target, actor, 5, ctx);
        return;
    }
    ctx.shared.entry_random = weapon.randomNext(ctx.random);
    target.next_tick = 0;
    if (target.mode == 0x3c0) return;
    const death = try shooting.damageEnemy(ctx.angles, actor.*, &target.damage, input);
    target.ai.physics.velocity = target.damage.velocity;
    if (death) |choreography| {
        _ = try event(target, actor, 6, ctx);
        if (ctx.hit_result) |sink| try sink.enqueue(sink.context, ctx.hit_sender_id, 0x7e3);
        actor.flags |= 0x80000100;
        target.dead = true;
        if (!try target.select(actor, choreography)) _ = try target.select(actor, target.config.chest_die_chor);
    } else {
        if (ctx.hit_result) |sink| try sink.enqueue(sink.context, ctx.hit_sender_id, 0x7e4);
        _ = try event(target, actor, 5, ctx);
        if (input.shooter_position != null) {
            if (actor.secondary_flags == 0 or (ctx.hit_sender != null and ctx.hit_sender.?.secondary_flags == 0)) try retarget(target, actor, ctx.hit_sender_id orelse .player, ctx);
            target.sight_at = ctx.shared.now +% 2000;
        }
    }
    if (ctx.hit_sender) |sender| if (sender.secondary_flags != 0) if (ctx.statistics) |stats| {
        if (death == null) stats.hits +%= 1 else stats.kills +%= 1;
    };
    if (actor.secondary_flags & 0x04000000 != 0) if (ctx.hit_sender) |sender| {
        if (sender.secondary_flags & 0x10 != 0) {
            var reflected = input;
            reflected.damage = 1;
            reflected.lateral = 0;
            reflected.height = 0;
            const sink = ctx.reflected_hit orelse return error.MissingReflectedDamageSink;
            try sink.enqueue(sink.context, actor.source_index, reflected);
        }
    };
}

pub fn completeLevel(ctx: *Context) !void {
    if (ctx.player) |player| if (player.flags & 0x4000 != 0) return;
    const sink = ctx.complete_level orelse return error.MissingLevelCompletionSink;
    try sink.enqueue(sink.context);
}

pub fn impulseMessage(target: anytype, impulse: level.Vec3, ctx: *Context) void {
    if (target.sanchez and !ctx.shared.sanchez_enabled) return;
    if (target.native == .farmer) return;
    ctx.shared.entry_random = weapon.randomNext(ctx.random);
    target.damage.velocity.x = f(@as(f64, target.damage.velocity.x) + impulse.x);
    target.damage.velocity.y = f(@as(f64, target.damage.velocity.y) + impulse.y);
    target.damage.velocity.z = f(@as(f64, target.damage.velocity.z) + impulse.z);
    target.ai.physics.velocity = target.damage.velocity;
    target.next_tick = 0;
}

pub fn activationMessage(target: anytype, ctx: *Context) void {
    if (target.sanchez and !ctx.shared.sanchez_enabled) return;
    if (target.native == .farmer) return;
    ctx.shared.entry_random = weapon.randomNext(ctx.random);
    target.ai.activated = 1;
    target.next_tick = 0;
}

pub fn resultMessage(target: anytype, actor: *Actor, killed: bool, ctx: *Context) !void {
    if (target.sanchez and !ctx.shared.sanchez_enabled) return;
    if (target.native == .farmer) return;
    ctx.shared.entry_random = weapon.randomNext(ctx.random);
    _ = try event(target, actor, if (killed) 8 else 9, ctx);
    target.next_tick = 0;
}

pub fn retarget(target: anytype, actor: *Actor, id: TargetId, ctx: *Context) !void {
    const subject = ctx.subject(id) orelse return error.MissingEnemyTarget;
    target.ai.target = id;
    if (ctx.shared.now -% target.ai.last_seen_at > 1500) target.attack_at = ctx.shared.now +% randomDelay(ctx.random, 0x3ff, -12);
    target.ai.last_seen = subject.position;
    target.ai.last_seen_sector_valid = true;
    target.ai.last_seen_sector = subject.sector;
    target.ai.previous_seen_at = target.ai.last_seen_at;
    target.ai.last_seen_at = ctx.shared.now;
    target.ai.has_los = true;
    face(actor, &target.ai, subject.position);
}

pub fn taunt(target: anytype, actor: Actor, requested: u32, force: bool, ctx: *Context) !void {
    const player = ctx.player orelse return;
    if (perception.distance(perception.point(actor.position), perception.point(player.position)) > 200 or player.flags & 0x4000 != 0) return;
    const forced = force or actor.secondary_flags & 0x200000 != 0;
    if (ctx.shared.now +% 30000 < ctx.shared.next_taunt) ctx.shared.next_taunt = ctx.shared.now -% 1;
    if (!forced and (ctx.shared.entry_random & 0x100 == 0 or !(ctx.shared.next_taunt < ctx.shared.now))) return;
    _ = weapon.randomNext(ctx.random);
    ctx.shared.next_taunt = ctx.shared.now +% (weapon.randomNext(ctx.random) & 0x1fff) +% 0x770;
    var kind = requested;
    if (kind == 0) kind = if (target.ai.has_los and ctx.shared.entry_random & 0x80 != 0 and ctx.shared.now -% target.ai.previous_seen_at >= 10001) 2 else 1;
    const list = if (kind == 2) target.config.alert_taunts else if (!target.ai.has_los) target.config.no_los_taunts else target.config.los_taunts;
    if (list.len == 0) return;
    var selected: []const u8 = undefined;
    for (0..4) |_| {
        const range: f32 = @floatFromInt(list.len - 1);
        const sampled = weapon.randomFloat(ctx.random, range);
        if (ctx.contact_hidden_taunt) if (ctx.contact_residue) |residue| {
            residue.projection.words[0] = @bitCast(perception.nearest(f(@as(f64, range) * 65536)));
            residue.projection.words[1] = @bitCast(@as(i32, @intFromFloat(sampled * 65536)));
        };
        const index = perception.nearest(f(sampled));
        if (index < 0 or index >= list.len) return error.InvalidEnemyTauntIndex;
        selected = list[@intCast(index)];
        if (list.len >= 2 and (target.ai.last_taunt == null or !std.ascii.eqlIgnoreCase(target.ai.last_taunt.?, selected))) break;
    }
    target.ai.last_taunt = selected;
    try ctx.sound(actor, selected, 0x10, 0.9, 0.2, true);
}

pub fn bobCombat(target: anytype, actor: *Actor, code: u32, ctx: *Context) !bool {
    if (code != 1) {
        if (code == 4 and target.previous_mode == 5) target.previous_mode = 0x40000005;
        if (code == 7 and target.previous_mode == 6) switch (ctx.shared.animation_message) {
            3, 0x60, 0x62, 99 => {
                const sequence = if (target.damage.current_chor == target.config.walk_chor) target.config.walk_shoot_chor else if (target.damage.current_chor == target.config.run_chor) target.config.run_shoot_chor else target.config.shoot_chor;
                _ = try target.select(actor, sequence);
            },
            else => {},
        };
        return false;
    }
    if (target.mode & 0x80000000 != 0) {
        target.mode &= 0x7fffffff;
        target.previous_mode = 0x80000007;
    }
    if (target.ai.taunt_at != 0 and target.ai.taunt_at < ctx.shared.now) {
        try taunt(target, actor.*, 0, true, ctx);
        target.ai.taunt_at = ctx.shared.now +% randomDelay(ctx.random, 0x1fff, @as(i32, @bitCast(target.config.taunt_timer_time)) -% 0x1000);
        ctx.schedule(target.ai.taunt_at);
    }
    ctx.schedule(target.attack_at);
    if (target.attack_at <= ctx.shared.now) {
        target.attack_at = ctx.shared.now +% randomDelay(ctx.random, 0x7ff, @as(i32, @bitCast(target.config.shoot_timer_time)) -% 0x400);
        ctx.schedule(target.attack_at);
        if (target.previous_mode != 3 and target.previous_mode != 5) target.previous_mode = 0x80000003;
    }
    switch (target.previous_mode) {
        0x80000003, 3 => {
            if (target.previous_mode == 0x80000003) {
                target.previous_mode = 3;
                _ = try target.select(actor, 0x21);
            }
            if (target.animation_ended) target.previous_mode = if (target.ai.has_los) 0x80000005 else 0x80000008;
        },
        0x80000005, 0x40000005, 5 => {
            if (target.previous_mode == 0x80000005) {
                target.previous_mode = 5;
                const first = (weapon.randomNext(ctx.random) & 3) + 1;
                target.ai.sub_timer = if (first < 4) (weapon.randomNext(ctx.random) & 3) + 1 else 3;
                try bobBurst(target, actor, ctx);
            } else if (target.previous_mode == 0x40000005) try bobBurst(target, actor, ctx);
            const subject = ctx.subject(target.ai.target) orelse return error.MissingEnemyTarget;
            face(actor, &target.ai, subject.position);
        },
        0x80000007 => {
            clearStack(target);
            target.ai.block_count = 0;
            target.previous_mode = 0x80000008;
        },
        0x80000008 => {
            target.previous_mode = 8;
            _ = try target.select(actor, 0x23);
        },
        else => {},
    }
    return false;
}

pub fn aimThrow(target: anytype, actor: Actor, ctx: *Context) !bool {
    const subject = ctx.subject(target.ai.target) orelse return false;
    if (target.config.throw_item.len == 0) return false;
    var start = actor.position;
    start.y = f(@as(f64, actor.height) * @as(f32, 0.8) + start.y);
    var end = subject.position;
    end.y = f(@as(f64, subject.height) * 0.25 + end.y);
    const distance = perception.distance(perception.point(start), perception.point(end));
    if (!(distance < target.config.throw_max and target.config.throw_min < f(distance))) return false;
    if (std.ascii.eqlIgnoreCase(target.config.throw_item, "pdynam.itm")) {
        const origin = perception.point(end);
        for (0..10) |_| {
            const sample = perception.randomPoint(ctx.angles, ctx.random, origin, 0, 0x3fd2, 3, 8);
            const candidate = level.Vec3{ .x = sample.point.x, .y = end.y, .z = sample.point.z };
            if (try perception.navigate(ctx.perceptionWorld(), subject.sector, end, candidate, 10, 10)) |sector| {
                end = candidate;
                end.y = ctx.level.sectors[sector].floor.height;
                break;
            }
        }
    }
    const arc = (try ballistics.solve(ctx.angles, start, end, target.config.throw_velocity)) orelse return false;
    target.ai.throw_pitch = arc.low_pitch;
    target.ai.throw_yaw = arc.yaw;
    return true;
}

pub fn event(target: anytype, actor: *Actor, code: u32, ctx: *Context) anyerror!bool {
    if (target.mode == 0x3c0 or target.mode == 0x800003c0) {
        if (target.mode == 0x800003c0) {
            target.mode = 0x3c0;
            target.dead = true;
            target.ai.physics.movement_disabled = true;
            actor.flags |= 0x80000100;
            try ctx.sound(actor.*, target.config.die_sound, 0, 0.8, 0.4, false);
            target.ai.physics.sample(actor.*, target.damage.velocity);
            if (try lifecycle.deathImpulse(ctx.world(), actor.*, &target.ai.physics, ctx.random)) |direction| if (ctx.state_stack) |stack| {
                const push_direction = ctx.angles.sinCos(direction);
                stack.write(0x14, @bitCast(push_direction.cos));
                stack.write(0x1c, @bitCast(push_direction.sin));
            };
            target.damage.velocity = target.ai.physics.velocity;
            target.ai.deadline = ctx.shared.now +% 3000;
            ctx.schedule(target.ai.deadline);
        }
        if (!target.animation_ended) {
            ctx.schedule(target.ai.deadline);
            if (ctx.shared.now < target.ai.deadline) {
                if (@as(f64, actor.position.y) - ctx.level.sectors[actor.sector].floor.height > 17 and !target.ai.fall_voice) {
                    target.ai.fall_voice = true;
                    if (ctx.fall_sound.len == 0) return error.MissingEnemyFallSound;
                    try ctx.sound(actor.*, ctx.fall_sound, 0, 0.85, 0.3, false);
                }
                return false;
            }
        }
        if (!physics.nonzero(target.damage.velocity)) target.ai.remove = true;
        return false;
    }
    switch (code) {
        1 => {},
        5 => {
            emotion(target, -3, 3);
            if (ctx.state_stack) |stack| stack.write(0x1c, @bitCast(target.aggressiveness));
            if (target.aggressiveness >= 4) {
                target.attack_at = ctx.shared.now;
                ctx.schedule(ctx.shared.now);
            }
            if (target.mode == 1) {
                target.mode = 0x80000002;
                try broadcast(target, actor.*, 0x7d, ctx);
            }
            if (target.mode & 0xffff != 8) {
                try push(target, ctx);
                target.mode = 0x80000008;
            }
            return false;
        },
        6 => {
            target.mode = 0x800003c0;
            return false;
        },
        8 => {
            emotion(target, 7, -7);
            target.ai.target = null;
            target.mode = 0x80000001;
            try broadcast(target, actor.*, 0x7f, ctx);
            return false;
        },
        9 => {
            emotion(target, 4, -3);
            try broadcast(target, actor.*, 0x7e, ctx);
            return false;
        },
        10 => {
            emotion(target, 2, 2);
            return false;
        },
        11 => {
            emotion(target, 3, 3);
            return false;
        },
        12 => {
            emotion(target, 2, -7);
            return false;
        },
        13 => {
            emotion(target, 1, -7);
            return false;
        },
        14 => {
            emotion(target, -1, 1);
            return false;
        },
        else => {
            _ = try combat(target, actor, code, ctx);
            return false;
        },
    }
    ctx.schedule(target.sight_at);
    if (target.sight_at <= ctx.shared.now) {
        try sense(target, actor, ctx);
        const distance = if (ctx.player) |player| f(perception.distance(perception.point(target.ai.physics.position), perception.point(player.position))) else @as(f32, 0);
        if (ctx.state_stack) |stack| stack.write(0x1c, @bitCast(distance));
        var delay = target.config.los_timer_time;
        if (@as(i32, @bitCast(distance)) > 0x41c80000) delay = @min(5000, @as(u32, @intCast(@divTrunc(@as(i32, @intFromFloat(distance)), 25))) *% delay);
        target.sight_at = ctx.shared.now +% delay;
        ctx.schedule(target.sight_at);
        if (target.ai.has_los) {
            target.ai.watch_at = ctx.shared.now +% (if (@as(i32, @bitCast(distance)) > 0x42c80000) @as(u32, 60000) else target.config.watch_timer_time);
            ctx.schedule(target.ai.watch_at);
            const elapsed = ctx.shared.now -% target.ai.previous_seen_at;
            if (elapsed > 3000) {
                const delta: u16 = @min(@as(u16, @bitCast(perception.angleDifference(actor.yaw, target.ai.target_yaw))) & 0x3fff, 0x2000);
                const amount: f32 = if (elapsed < 5000) 1 else if (elapsed < 10000) 2 else if (elapsed < 20000) 3 else 4;
                target.anger = clamp(f(@as(f64, target.anger) - (@as(f64, amount) * @as(f64, @floatFromInt(delta)) * @as(f32, 0.00012207031) + amount)));
            }
            target.ai.previous_seen_at = target.ai.last_seen_at;
        }
    }
    if (target.ai.target == null and target.mode != 1) target.mode = 0x80000001;
    if (target.ai.physics.landed) {
        target.ai.physics.landed = false;
        if (ctx.state_stack) |stack| {
            var depth: u32 = 0;
            var saved = target.ai.stack;
            while (saved) |value| : (saved = value.ai.stack) depth += 1;
            stack.write(0x1c, depth);
        }
        try push(target, ctx);
        target.mode = 0x80002000;
    }
    switch (target.mode) {
        0x80000000 => target.mode = 0x80000001,
        0x80000001, 1 => {
            if (target.mode == 0x80000001) {
                target.mode = 1;
                target.anger = 7;
                target.fear = 0;
                clearStack(target);
                try stateSelect(target, actor, target.config.watch_chor, ctx);
            }
            if (target.ai.has_los) {
                target.attack_at = ctx.shared.now +% randomDelay(ctx.random, 0x7ff, -0x20c);
                target.mode = 0x80000002;
                try broadcast(target, actor.*, 0x7d, ctx);
            }
        },
        0x80000002, 2 => return combat(target, actor, code, ctx),
        0x80000008, 8 => {
            if (target.mode == 0x80000008) {
                target.mode = 8;
                try stateSelect(target, actor, target.config.hit_chor, ctx);
                try ctx.sound(actor.*, target.config.hit_sound, 0, 0.8, 0.4, false);
            }
            if (target.animation_ended) try restore(target, actor);
        },
        0x80002000, 0x2000 => {
            if (target.mode == 0x80002000) {
                target.mode = 0x2000;
                try stateSelect(target, actor, target.config.duck_chor, ctx);
                target.ai.deadline = ctx.shared.now +% 250;
            }
            ctx.schedule(target.ai.deadline);
            if (target.ai.deadline <= ctx.shared.now) try restore(target, actor);
        },
        else => {},
    }
    return false;
}

pub fn randomDelay(state: *u32, mask: u32, base: i32) u32 {
    if (@as(i32, @bitCast((weapon.randomNext(state) & mask) +% @as(u32, @bitCast(base)))) < 0) return 0;
    return (weapon.randomNext(state) & mask) +% @as(u32, @bitCast(base));
}

pub fn packetMessage(target: anytype, actor: *Actor, code: u32, ctx: *Context) !void {
    switch (code) {
        0x7d3 => activationMessage(target, ctx),
        0x7e3 => try resultMessage(target, actor, true, ctx),
        0x7e4 => try resultMessage(target, actor, false, ctx),
        0x7d1, 0x7d2 => return error.MissingEnemyPacketPayload,
        else => {
            if (target.sanchez and !ctx.shared.sanchez_enabled) return;
            if (target.native == .farmer) return;
            ctx.shared.entry_random = weapon.randomNext(ctx.random);
            target.next_tick = 0;
        },
    }
}

fn tickEvent(target: anytype, actor: *Actor, code: u32, ctx: *Context, return_address: u32) !bool {
    const previous = ctx.state_stack;
    defer ctx.state_stack = previous;
    ctx.state_stack = ctx.enemyStack(target.native);
    if (ctx.state_stack) |stack| stack.enter(return_address);
    return event(target, actor, code, ctx);
}

fn stateSelect(target: anytype, actor: *Actor, choreography: u32, ctx: *Context) !void {
    if (ctx.state_stack) |stack| stack.write(0x1c, choreography);
    if (try target.select(actor, choreography)) if (ctx.state_stack) |stack| {
        stack.frame(try (try actor.sprite()).select(actor.choreography, actor.frame, 0, actor.angle_offset));
    };
}

fn sense(target: anytype, actor: *Actor, ctx: *Context) !void {
    if (ctx.subject(target.ai.target) == null) target.ai.target = null;
    if (target.ai.target == null) {
        if (actor.secondary_flags & 0x4100 != 0) {
            if (ctx.player) |player| if (player.flags & 0x100 == 0 and try ctx.visible(Subject.fromActor(actor.*), player)) {
                target.ai.target = .player;
            };
        } else {
            const count = if (ctx.actor_slots.len != 0) ctx.actor_slots.len else ctx.actors.all().len;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const other = if (ctx.actor_slots.len != 0) blk: {
                    if (ctx.actors.source_to_entry) |indices| if (indices[i] == null) continue;
                    break :blk ctx.actor_slots[i] orelse continue;
                } else ctx.actors.get(i);
                if (other.secondary_flags & 0x100 == 0 or other.flags & 0x100 != 0) continue;
                if (try ctx.visible(Subject.fromActor(actor.*), Subject.fromActor(other))) {
                    target.ai.target = .{ .actor = other.source_index orelse return error.MissingEnemyActorId };
                    break;
                }
            }
        }
    }
    target.ai.has_los = false;
    target.ai.in_fov = false;
    target.ai.covered = false;
    const subject = ctx.subject(target.ai.target) orelse return;
    const from = Subject.fromActor(actor.*);
    if (target.previous_mode == 9) {
        target.ai.in_fov = true;
        target.ai.has_los = try perception.visibleAtHeight(ctx.perceptionWorld(), from, subject, f(@as(f64, actor.height) + 1));
        target.ai.covered = !try perception.visibleAtHeight(ctx.perceptionWorld(), from, subject, f(@as(f64, actor.height) * 0.25));
    } else {
        target.ai.target_yaw = if (target.ai.check_fov)
            perception.fieldOfView(from, subject, ctx.level.sectors[actor.sector].ambient, ctx.level.sectors[subject.sector].ambient, target.config.fov_dist, target.config.fov, target.config.kill_dist, target.ai.last_seen_at, ctx.shared.now, ctx.player_visible, &target.damage.armor)
        else
            perception.angle(f(@as(f64, subject.position.x) - actor.position.x), f(@as(f64, subject.position.z) - actor.position.z));
        if (target.ai.target_yaw != 0) {
            if (target.ai.check_los) target.ai.has_los = try ctx.visible(from, subject);
            target.ai.in_fov = true;
        }
    }
    if (target.ai.in_fov and target.ai.has_los) {
        try retarget(target, actor, target.ai.target.?, ctx);
        target.ai.visible_until = ctx.shared.now +% 15000;
        ctx.schedule(target.ai.visible_until);
        if (target.ai.check_cover and target.previous_mode != 9) target.ai.covered = !try perception.visibleAtHeight(ctx.perceptionWorld(), from, subject, f(@as(f64, actor.height) * @as(f32, 0.3)));
    }
}

fn face(actor: *Actor, state: *State, position: level.Vec3) void {
    const yaw = perception.angle(f(@as(f64, position.x) - actor.position.x), f(@as(f64, position.z) - actor.position.z));
    actor.yaw = yaw;
    state.physics.yaw = yaw;
}

fn broadcast(target: anytype, actor: Actor, code: u32, ctx: *Context) !void {
    if (ctx.state_stack) |stack| stack.broadcast(target.ai.physics.position, actor.height);
    const parent_stack = ctx.state_stack;
    ctx.state_stack = null;
    defer ctx.state_stack = parent_stack;
    const source_sector = target.ai.physics.sector;
    if (ctx.visibility.lists[source_sector] == null and ctx.level.sectors.len > 1) _ = try ctx.visibility.connected(ctx.level, ctx.scene, ctx.angles, source_sector, (source_sector + 1) % ctx.level.sectors.len);
    const single_sector = [_]u16{@intCast(source_sector)};
    const connected = ctx.visibility.lists[source_sector] orelse &single_sector;
    var sector_index: usize = 0;
    while (sector_index <= connected.len) : (sector_index += 1) {
        const sector: usize = if (sector_index == 0) source_sector else connected[sector_index - 1];
        var iterator = ctx.actors.inLoadedSector(sector);
        while (iterator.next()) |i| {
            if (i == shooting.local_player) continue;
            const candidate = ctx.actors.get(i);
            if (candidate.sector != sector or candidate.source_index == actor.source_index or candidate.secondary_flags & 0x40 == 0 or candidate.logic_name.len == 0) continue;
            if (!(perception.distance(perception.point(target.ai.physics.position), perception.point(candidate.position)) < 50)) continue;
            if (perception.nearest(ctx.level.sectors[actor.sector].layer) != perception.nearest(ctx.level.sectors[candidate.sector].layer)) continue;
            const index = candidate.source_index orelse return error.MissingEnemyActorId;
            if (index >= ctx.targets.len or index >= ctx.actor_slots.len) return error.MissingEnemyBroadcastRecipient;
            const other = if (ctx.targets[index]) |*value| value else return error.UnsupportedEnemyBroadcastRecipient;
            const other_actor = if (ctx.actor_slots[index]) |*value| value else return error.MissingEnemyBroadcastActor;
            if (other.sanchez and !ctx.shared.sanchez_enabled) continue;
            if (code == 0x7d) {
                ctx.shared.entry_random = weapon.randomNext(ctx.random);
                if (other.ai.base_mode == 0) {
                    other.ai.target = target.ai.target;
                    other.ai.last_seen = target.ai.last_seen;
                    other.ai.last_seen_sector = target.ai.last_seen_sector;
                    other.ai.last_seen_sector_valid = target.ai.last_seen_sector_valid;
                    other.ai.last_seen_at = target.ai.last_seen_at;
                    other.ai.has_los = target.ai.has_los;
                    other.ai.in_fov = target.ai.in_fov;
                    other.sight_at = ctx.shared.now +% 2000;
                }
                other.next_tick = 0;
            } else try message(other, other_actor, code, &.{}, ctx);
            if (ctx.actors.live_entries) |entries| {
                if (ctx.actors.source_to_entry) |indices| {
                    if (indices[index]) |entry| entries.*[entry] = other_actor.*;
                }
            }
        }
    }
}

fn bobBurst(target: anytype, actor: *Actor, ctx: *Context) !void {
    target.previous_mode &= 0xbfffffff;
    const previous = target.ai.sub_timer;
    target.ai.sub_timer -%= 1;
    if (previous == 0) {
        target.previous_mode = 0x80000008;
    } else {
        _ = try target.select(actor, target.config.shoot_chor);
        if (ctx.subject(target.ai.target)) |subject| {
            target.ai.aim_yaw = perception.angle(f(@as(f64, subject.position.x) - actor.position.x), f(@as(f64, subject.position.z) - actor.position.z));
            actor.yaw = target.ai.aim_yaw & 0x3fff;
            target.ai.physics.yaw = actor.yaw;
        }
    }
}

fn combat(target: anytype, actor: *Actor, code: u32, ctx: *Context) !bool {
    if (target.native == .bob) return bobCombat(target, actor, code, ctx);
    var moving = false;
    if (code == 1) {
        if (target.mode & 0x80000000 != 0) {
            target.mode &= 0x7fffffff;
            target.previous_mode = 0x80000007;
        }
        if (target.ai.has_los and target.previous_mode == 1) target.previous_mode = 0x80000007;
        ctx.schedule(target.attack_at);
        if (target.attack_at <= ctx.shared.now and target.mode & 0x7fffffff != 0x3c0) {
            if (target.ai.base_mode == 1) {
                target.attack_at = ctx.shared.now +% (randomDelay(ctx.random, 0x7ff, @as(i32, @bitCast(target.config.shoot_timer_time)) -% 0x400) *% 4);
            } else {
                target.attack_at = ctx.shared.now +% (if (target.damage.armor) @as(u32, 1000) else randomDelay(ctx.random, 0x7ff, @as(i32, @bitCast(target.config.shoot_timer_time)) -% 0x400));
            }
            ctx.schedule(target.attack_at);
            if (target.ai.base_mode != 1) if (ctx.player) |player| if (player.flags & 0x4000 != 0) {
                target.attack_at = ctx.shared.now +% 120000;
                ctx.schedule(target.attack_at);
            };
            if (ctx.subject(target.ai.target)) |subject| if (try ctx.visible(Subject.fromActor(actor.*), subject)) {
                switch (target.previous_mode & 0x7fffffff) {
                    5, 6 => {},
                    1, 9 => {
                        try push(target, ctx);
                        target.previous_mode = 0x80000005;
                    },
                    else => {
                        try push(target, ctx);
                        target.previous_mode = if (target.ai.physics.movement_disabled or @abs(target.config.throw_max) != 0 or ctx.shared.entry_random & 0x100 != 0) 0x80000005 else 0x80000006;
                    },
                }
            };
        }
        if (target.ai.covered) switch (target.previous_mode & 0x7fffffff) {
            1, 3, 4, 8 => {
                try push(target, ctx);
                target.previous_mode = 0x80000009;
            },
            else => {},
        };
        if (target.ai.taunt_at < ctx.shared.now) {
            try taunt(target, actor.*, 0, false, ctx);
            target.ai.taunt_at = ctx.shared.now +% randomDelay(ctx.random, 0x1fff, @as(i32, @bitCast(target.config.taunt_timer_time)) -% 0x1000);
        }
        switch (target.previous_mode) {
            0x80000001, 1 => {
                if (target.previous_mode == 0x80000001) {
                    target.previous_mode = 1;
                    const subject = ctx.subject(target.ai.target) orelse return error.MissingEnemyTarget;
                    face(actor, &target.ai, subject.position);
                    target.ai.sub_timer = ctx.shared.now +% 1000;
                    ctx.schedule(target.ai.sub_timer);
                    _ = try target.select(actor, 0);
                }
                ctx.schedule(target.ai.sub_timer);
                if (target.ai.sub_timer <= ctx.shared.now) target.previous_mode = 0x80000007;
            },
            0x80000002, 2 => {
                if (target.previous_mode == 0x80000002) {
                    target.previous_mode = 2;
                    const sample = perception.randomPoint(ctx.angles, ctx.random, perception.point(actor.position), target.ai.obstacle_yaw, target.ai.obstacle_yaw +% 0x2000, 5, 15);
                    goal(target, sample.point);
                    actor.yaw = sample.yaw & 0x3fff;
                    target.ai.physics.yaw = actor.yaw;
                }
                if (!target.ai.physics.move_complete) moving = true else try restore(target, actor);
            },
            0x80000003, 3 => {
                try approach(target, actor, ctx);
                moving = true;
            },
            0x80000004, 4 => {
                try retreat(target, actor, ctx);
                moving = true;
            },
            0x80000005, 5 => {
                var ready = true;
                if (target.previous_mode == 0x80000005) {
                    target.previous_mode = 5;
                    if (target.config.shoot_chor == 0xffffffff) {
                        try restore(target, actor);
                        ready = false;
                    } else if (@abs(target.config.throw_max) != 0) {
                        if (!try aimThrow(target, actor.*, ctx)) {
                            try restore(target, actor);
                            ready = false;
                        } else {
                            target.ai.sub_timer = 1;
                            target.animation_ended = true;
                        }
                    } else {
                        target.ai.sub_timer = switch (target.ai.base_mode) {
                            1 => 1,
                            2, 3 => 0,
                            else => if ((weapon.randomNext(ctx.random) & 3) + 1 < 4) (weapon.randomNext(ctx.random) & 3) + 1 else 3,
                        };
                        target.animation_ended = true;
                    }
                }
                if (ready) {
                    if (ctx.subject(target.ai.target)) |subject| face(actor, &target.ai, subject.position);
                    if (target.animation_ended) {
                        const count = target.ai.sub_timer;
                        target.ai.sub_timer -%= 1;
                        if (count == 0) {
                            try restore(target, actor);
                            try sense(target, actor, ctx);
                        } else if (!try target.select(actor, target.config.shoot_chor)) {
                            try restore(target, actor);
                        } else if (ctx.subject(target.ai.target)) |subject| {
                            target.ai.aim_yaw = perception.angle(f(@as(f64, subject.position.x) - actor.position.x), f(@as(f64, subject.position.z) - actor.position.z));
                            face(actor, &target.ai, subject.position);
                        }
                    }
                }
            },
            0x80000006, 6 => {
                var ready = true;
                if (target.previous_mode == 0x80000006) {
                    if (target.config.walk_shoot_chor == 0xffffffff or target.config.run_shoot_chor == 0xffffffff) {
                        try restore(target, actor);
                        ready = false;
                    } else {
                        target.previous_mode = 6;
                        if (ctx.subject(target.ai.target)) |subject| {
                            target.ai.aim_yaw = perception.angle(f(@as(f64, subject.position.x) - actor.position.x), f(@as(f64, subject.position.z) - actor.position.z));
                            face(actor, &target.ai, subject.position);
                        }
                    }
                }
                if (ready) {
                    const chor = target.damage.current_chor;
                    if (target.animation_ended or (chor != target.config.walk_chor and chor != target.config.run_chor and chor != target.config.walk_shoot_chor and chor != target.config.run_shoot_chor)) try restore(target, actor);
                    moving = true;
                }
            },
            0x80000007 => {
                clearStack(target);
                target.ai.block_count = 0;
                target.previous_mode = 0x8000000a;
            },
            0x80000008, 8 => {
                try seekCover(target, actor, ctx);
                moving = true;
            },
            0x80000009, 9 => {
                if (target.previous_mode == 0x80000009) {
                    target.previous_mode = 9;
                    _ = try target.select(actor, target.config.duck_chor);
                    target.ai.physics.movement_disabled = true;
                    if (target.ai.base_mode == 0 or target.ai.base_mode > 3) {
                        target.ai.sub_timer = ctx.shared.now +% randomDelay(ctx.random, 0x1fff, 0x1ee0 -% target.aggressiveness *% 1000);
                        ctx.schedule(target.ai.sub_timer);
                    } else target.ai.sub_timer = 0xffffffff;
                }
                actor.yaw = target.ai.target_yaw & 0x3fff;
                target.ai.physics.yaw = actor.yaw;
                if (target.ai.base_mode == 2 or target.ai.base_mode == 3) {
                    if (target.ai.base_mode == 3) {
                        const subject = ctx.subject(target.ai.target) orelse return error.MissingEnemyTarget;
                        if (perception.distance(perception.point(actor.position), perception.point(subject.position)) < 15) target.ai.covered = false;
                    }
                    if (!target.ai.covered) {
                        target.ai.base_mode = 0;
                        try restore(target, actor);
                    }
                } else {
                    if (target.ai.covered) ctx.schedule(target.ai.sub_timer);
                    if (!target.ai.covered or !(ctx.shared.now < target.ai.sub_timer)) {
                        if (!target.ai.covered and target.ai.base_mode == 1) target.ai.base_mode = 0;
                        try restore(target, actor);
                    }
                }
            },
            0x8000000a => {
                clearStack(target);
                const decisions = [64]u8{ 4, 4, 4, 4, 4, 4, 1, 1, 4, 4, 4, 4, 4, 1, 1, 1, 4, 4, 4, 4, 1, 1, 1, 2, 4, 4, 4, 1, 1, 1, 2, 2, 4, 4, 1, 1, 1, 2, 2, 2, 4, 1, 1, 1, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 1, 1, 2, 2, 2, 2, 2, 2 };
                const index: usize = @intCast((@as(u32, @bitCast(perception.nearest(target.anger))) & 7) * 8 + (@as(u32, @bitCast(target.aggressiveness)) & 7));
                switch (decisions[index]) {
                    1 => target.previous_mode = 0x80000008,
                    2 => target.previous_mode = 0x80000003,
                    4 => target.previous_mode = 0x80000004,
                    else => unreachable,
                }
            },
            else => {},
        }
    } else switch (code) {
        2 => switch (target.previous_mode) {
            2 => {},
            3, 4, 6, 8 => target.ai.block_count = 0,
            else => target.previous_mode = 0x80000007,
        },
        7 => if (target.previous_mode == 6) {
            switch (ctx.shared.animation_message) {
                3, 0x60, 0x62 => {
                    const chor = if (target.damage.current_chor == target.config.walk_chor) target.config.walk_shoot_chor else if (target.damage.current_chor == target.config.run_chor) target.config.run_shoot_chor else target.config.shoot_chor;
                    if (!try target.select(actor, chor)) try restore(target, actor);
                },
                0x63 => try restore(target, actor),
                else => {},
            }
        },
        3, 15 => {
            var handle = true;
            if (code == 15) {
                if (@as(u16, @bitCast(actor.yaw -% target.ai.obstacle_yaw)) & 0x3fff < 0x2000) {
                    handle = false;
                } else {
                    const sample = perception.randomPoint(ctx.angles, ctx.random, perception.point(actor.position), target.ai.obstacle_yaw, target.ai.obstacle_yaw +% 0x2000, 5, 20);
                    goal(target, sample.point);
                }
            }
            if (handle) {
                if (code == 15 and ctx.shared.entry_random & 1 != 0) {
                    var direction = target.ai.obstacle_yaw;
                    if (@abs(@as(i32, perception.angleDifference(direction, actor.yaw))) > 0xfff) direction = (direction +% 0x2000) & 0x3fff;
                    const sample = perception.randomPoint(ctx.angles, ctx.random, perception.point(target.ai.physics.position), direction, direction, 5, 30);
                    goal(target, sample.point);
                } else {
                    target.ai.block_count +%= 1;
                    if (target.ai.block_count < 5) {
                        if (target.previous_mode & 0x7fffffff != 2) try push(target, ctx);
                        target.previous_mode = 0x80000002;
                    } else target.previous_mode = 0x80000007;
                }
            }
        },
        else => {},
    }
    target.ai.physics.movement_disabled = !moving;
    return moving;
}

fn goal(target: anytype, point: level.Vec2) void {
    target.ai.physics.goal.x = point.x;
    target.ai.physics.goal.z = point.z;
    target.ai.physics.movement_disabled = false;
    target.ai.physics.move_complete = false;
    target.ai.physics.movement_mode = if (perception.distance(perception.point(target.ai.physics.position), point) > 10 and target.ai.target != null) 1 else 2;
}

fn chooseToward(target: anytype, actor: Actor, minimum: f32, maximum: f32, ctx: *Context) !bool {
    goal(target, perception.point(target.ai.physics.position));
    const subject = ctx.subject(target.ai.target) orelse return false;
    const heading = perception.angle(f(@as(f64, subject.position.x) - actor.position.x), f(@as(f64, subject.position.z) - actor.position.z));
    var first = heading -% 0x38e;
    var last = heading +% 0x38e;
    for (0..10) |_| {
        const sample = perception.randomPoint(ctx.angles, ctx.random, perception.point(actor.position), first, last, minimum, maximum);
        const start = level.Vec3{ .x = target.ai.physics.position.x, .y = f(@as(f64, target.ai.physics.position.y) + 3), .z = target.ai.physics.position.z };
        const end = level.Vec3{ .x = sample.point.x, .y = target.ai.physics.position.y, .z = sample.point.z };
        if (try perception.navigate(ctx.perceptionWorld(), target.ai.physics.sector, start, end, target.config.max_step, target.config.max_drop) != null) {
            goal(target, sample.point);
            return true;
        }
        first -%= 0x2aa;
        last +%= 0x2aa;
    }
    return false;
}

fn approach(target: anytype, actor: *Actor, ctx: *Context) !void {
    if (target.previous_mode & 0x80000000 == 0) {
        if (target.ai.physics.move_complete) target.previous_mode = 0x8000000a;
        return;
    }
    target.previous_mode &= 0x7fffffff;
    const subject = ctx.subject(target.ai.target) orelse return error.MissingEnemyTarget;
    if (perception.distance(perception.point(target.ai.physics.position), perception.point(subject.position)) <= 20 or !try chooseToward(target, actor.*, 5, 15, ctx)) {
        const sample = perception.randomPoint(ctx.angles, ctx.random, perception.point(subject.position), 0, 0x3f1c, 10, 20);
        goal(target, sample.point);
    }
    if (target.damage.current_chor != target.config.walk_chor or target.damage.current_chor != target.config.run_chor) _ = try target.select(actor, target.config.walk_chor);
}

fn retreat(target: anytype, actor: *Actor, ctx: *Context) !void {
    if (ctx.subject(target.ai.target)) |subject| if (perception.distance(perception.point(actor.position), perception.point(subject.position)) > 50) {
        target.previous_mode = 0x80000008;
        return;
    };
    if (target.previous_mode & 0x80000000 == 0) {
        if (target.ai.physics.move_complete) target.previous_mode = 0x80000008;
        return;
    }
    target.previous_mode &= 0x7fffffff;
    if (!try chooseToward(target, actor.*, -5, -25, ctx)) {
        _ = try target.select(actor, target.config.watch_chor);
    } else if (target.damage.current_chor != target.config.walk_chor or target.damage.current_chor != target.config.run_chor) _ = try target.select(actor, target.config.walk_chor);
}

fn seekCover(target: anytype, actor: *Actor, ctx: *Context) !void {
    if (target.previous_mode & 0x80000000 == 0) {
        if (target.ai.physics.move_complete) target.previous_mode = 0x80000001;
        return;
    }
    target.previous_mode &= 0x7fffffff;
    target.ai.cover_node = null;
    target.ai.physics.movement_disabled = true;
    target.ai.physics.move_complete = true;
    if (!target.ai.has_los) {
        target.previous_mode = 0x80000001;
        return;
    }
    var nearest: f32 = 0x1p31;
    for (ctx.nodes, 0..) |node, index| {
        if (node.kind != 2) continue;
        var stale_distance = f(perception.distance(perception.point(node.position), perception.point(actor.position)));
        if (@as(i32, @bitCast(stale_distance)) >= 0x42c80001 or @as(i32, @bitCast(stale_distance)) <= 0x3f7fffff) continue;
        const age = @as(f64, @floatFromInt(ctx.shared.now -% node.used_at));
        stale_distance = f((@as(f64, stale_distance) - @min(age * @as(f32, 0.001) * 2, 60)) + 60);
        if (!(stale_distance < nearest)) continue;
        target.ai.cover_node = null;
        nearest = stale_distance;
        var start = node.position;
        start.y = f(@as(f64, start.y) + 3);
        var end = actor.position;
        end.y = f(@as(f64, end.y) + 3);
        if (try ctx.visibility.visible(ctx.level, ctx.scene, ctx.angles, node.sector, actor.sector, start, end, ctx.now)) {
            if (ctx.subject(target.ai.target)) |subject| {
                end = subject.position;
                end.y = f(@as(f64, end.y) + 3);
                if (try ctx.visibility.visible(ctx.level, ctx.scene, ctx.angles, node.sector, subject.sector, start, end, ctx.now)) continue;
            }
            target.ai.cover_node = index;
        } else {
            for (node.links) |_| _ = try ctx.visibility.visible(ctx.level, ctx.scene, ctx.angles, node.sector, actor.sector, start, end, ctx.now);
        }
    }
    if (target.ai.cover_node) |index| {
        goal(target, perception.point(ctx.nodes[index].position));
    } else if (try coverPoint(target, actor.*, ctx)) |point| {
        goal(target, point);
    } else {
        _ = try target.select(actor, target.config.watch_chor);
        target.previous_mode = 0x80000004;
    }
    if (target.damage.current_chor != target.config.walk_chor or target.damage.current_chor != target.config.run_chor) _ = try target.select(actor, target.config.walk_chor);
}

fn coverPoint(target: anytype, actor: Actor, ctx: *Context) !?level.Vec2 {
    const subject = ctx.subject(target.ai.target) orelse return null;
    var direction = target.ai.physics.yaw +% @as(i16, if (ctx.shared.entry_random & 0x100 != 0) 0x1000 else -0x1000);
    for (0..36) |_| {
        direction &= 0x3fff;
        const sample = perception.randomPoint(ctx.angles, ctx.random, perception.point(actor.position), direction, direction, 5, 25);
        const end = level.Vec3{ .x = sample.point.x, .y = target.ai.physics.position.y, .z = sample.point.z };
        if (try perception.navigate(ctx.perceptionWorld(), target.ai.physics.sector, target.ai.physics.position, end, target.config.max_step, target.config.max_drop)) |sector| {
            const start = level.Vec3{ .x = end.x, .y = f(@as(f64, ctx.level.sectors[sector].floor.height) + 3), .z = end.z };
            var target_end = subject.position;
            target_end.y = f(@as(f64, target_end.y) + 3);
            if (!try ctx.visibility.visible(ctx.level, ctx.scene, ctx.angles, sector, subject.sector, start, target_end, ctx.now)) return sample.point;
        }
        direction +%= if (ctx.shared.entry_random & 0x80 == 0) @as(i16, -455) else @as(i16, 455);
    }
    return null;
}

fn fire(target: anytype, actor: *Actor, ctx: *Context) !void {
    if (target.config.throw_max != 0) {
        const sink = ctx.projectile_sink orelse return error.MissingEnemyProjectileSink;
        try sink.emit(sink.context, target, actor, ctx);
        return;
    }
    if (ctx.shared.now +% 1000 < ctx.shared.next_shot) ctx.shared.next_shot = ctx.shared.now -% 1;
    if (!(ctx.shared.next_shot < ctx.shared.now)) return;
    ctx.shared.next_shot = ctx.shared.now +% 50;
    const subject = ctx.subject(target.ai.target) orelse return;
    var yaw = perception.angle(f(@as(f64, target.ai.last_seen.x) - actor.position.x), f(@as(f64, target.ai.last_seen.z) - actor.position.z));
    const dx = f(@as(f64, subject.position.x) - actor.position.x);
    const dz = f(@as(f64, subject.position.z) - actor.position.z);
    const distance = f(@sqrt(@as(f64, dx) * dx + @as(f64, dz) * dz));
    const subject_y = @as(f64, subject.height) * 0.25 + @as(f64, subject.height) * 0.5 + subject.position.y;
    const actor_y = @as(f64, actor.height) * 0.25 + @as(f64, actor.height) * 0.5 + actor.position.y;
    var pitch = perception.angle(f(subject_y - actor_y), distance);
    actor.yaw = yaw & 0x3fff;
    target.ai.physics.yaw = actor.yaw;
    if (actor.secondary_flags & 0x200000 != 0 and subject.secondary_flags & 0x10 != 0 and f(perception.distance(perception.point(actor.position), perception.point(target.ai.last_seen))) < target.config.kill_dist) target.damage.armor = true;
    if (!target.damage.armor) {
        const difference = @min(@abs(@as(i32, perception.angleDifference(yaw, target.ai.aim_yaw))), 0x800);
        const amount = f(@as(f64, @floatFromInt(difference)) * @as(f32, 0.021972613) * @as(f32, 0.022222223) * target.config.move_inaccuracy);
        const move_angle: i16 = @truncate(perception.nearest(f((weapon.randomFloat(ctx.random, f(@as(f64, amount) * 2)) - amount) * 45.5112)));
        const weapon_yaw = inaccuracy(ctx.random, target.config.weapon_inaccuracy);
        const weapon_pitch = inaccuracy(ctx.random, target.config.weapon_inaccuracy);
        const panic = std.math.clamp(f(@as(f64, target.fear) * @as(f32, 0.14285715)), 0, 1);
        const panic_yaw = inaccuracy(ctx.random, f(@as(f64, panic) * target.config.panic_inaccuracy));
        yaw +%= move_angle +% weapon_yaw +% panic_yaw;
        const panic_pitch = inaccuracy(ctx.random, f(@as(f64, target.config.panic_inaccuracy) * panic));
        pitch +%= weapon_pitch +% panic_pitch;
    }
    _ = weapon.randomFloat(ctx.random, 0.2);
    actor.yaw = yaw & 0x3fff;
    target.ai.physics.yaw = actor.yaw;
    const mode = target.config.weapon_mode;
    if (target.config.shot_multiples < 0 or target.config.shot_multiples > 1024) return error.InvalidEnemyShotCount;
    for (0..@intCast(target.config.shot_multiples)) |index| {
        var shot_yaw = yaw;
        var shot_pitch = pitch;
        if (index != 0) {
            const spread = f(@as(f64, mode.spread) * 2);
            const pitch_offset: i16 = @truncate(@as(i32, @intFromFloat((variableFloat(ctx, spread) - mode.spread) * (1.0 / 360.0) * 16384)));
            shot_pitch = (pitch +% pitch_offset) & 0x3fff;
            const yaw_offset: i16 = @truncate(@as(i32, @intFromFloat((variableFloat(ctx, spread) - mode.spread) * (1.0 / 360.0) * 16384)));
            shot_yaw = (yaw +% yaw_offset) & 0x3fff;
        }
        const shot = weapon.Shot{
            .origin = .{ .x = actor.position.x, .y = f(@as(f64, actor.height) * 0.75 + actor.position.y), .z = actor.position.z },
            .sector = actor.sector,
            .yaw = shot_yaw,
            .pitch = shot_pitch,
            .range = mode.effective_range,
            .damage = if (target.damage.armor) 1000 else target.config.damage,
            .mass = mode.mass,
            .rate = mode.rate,
            .kind = if (target.config.hitscan) .bullet else .melee,
            .impact_effect = index == 0,
        };
        const no_collide = actor.flags & 0x100;
        actor.flags |= 0x80000100;
        if (ctx.shot_sink) |sink| try sink.emit(sink.context, target, actor, ctx, shot) else try ctx.effects.append(.{ .fire = .{ .source = actor.source_index, .shot = shot } });
        actor.flags = (actor.flags & ~@as(u32, 0x100)) | no_collide | 0x80000000;
    }
    try ctx.sound(actor.*, target.config.shoot_sound, 0, 1, 0, false);
}

fn inaccuracy(random: *u32, amount: f32) i16 {
    var value = f(weapon.randomFloat(random, amount));
    if (weapon.randomNext(random) & 1 != 0) value = -value;
    return @truncate(perception.nearest(f(@as(f64, value) * 45.5112)));
}

fn variableFloat(ctx: *Context, maximum: f32) f64 {
    ctx.shared.crt_random = ctx.shared.crt_random *% 0x343fd +% 0x269ec3;
    var count = (ctx.shared.crt_random >> 16) & 7;
    while (count != 0) : (count -= 1) _ = weapon.randomNext(ctx.random);
    const limit = perception.nearest(@as(f64, maximum) * 65536);
    var value: i32 = @bitCast(ctx.random.*);
    if (value < 0 or value >= limit) value = @truncate((@as(i64, @intCast(ctx.random.* & 0xffff)) * limit) >> 16);
    return @as(f64, @floatFromInt(value)) * 0.0000152587890625;
}

fn emotion(target: anytype, anger: f32, fear: f32) void {
    target.anger = clamp(f(@as(f64, target.anger) + anger));
    target.fear = clamp(f(@as(f64, target.fear) + fear));
}

fn clamp(value: f32) f32 {
    return std.math.clamp(value, 0, 7);
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
