//! The level script engine: triggers, tasks, doors, moving floors, lights
//! and the messages between them.
//!
//! This is an event engine over the level's own script text, not a bytecode
//! VM. List order is part of the behaviour: tasks run in the order they were
//! queued, and a trigger's callback runs synchronously between enqueueing a
//! client and switching it.

const std = @import("std");
const level_module = @import("../assets/level.zig");
const item = @import("../assets/item.zig");
const texture = @import("../assets/texture.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const geometry = @import("inf_geometry.zig");
const audio_engine = @import("../audio/engine.zig");
const audio_occlusion = @import("../audio/occlusion.zig");
const network_message = @import("../network/message.zig");
const network_server = @import("../network/server.zig");
const Router = @import("../network/router.zig").Router;

pub const Kind = enum(u32) {
    ceiling = 0,
    floor = 1,
    offset = 2,
    morph_move = 3,
    morph_spin = 4,
    scroll_wall = 5,
    scroll_floor = 6,
    scroll_ceiling = 7,
    light = 8,
    floor_ceiling = 9,
    velocity_x = 14,
    velocity_y = 15,
    velocity_z = 16,
};

pub const Target = struct { sector: ?usize = null, wall: ?usize = null, object: ?u32 = null };

pub const Message = struct {
    target: Target = .{},
    code: u32 = 0x7d6,
    event_mask: u32 = 0,
    arg1: i32 = 0,
    arg2: i32 = 0,
};

pub const Stop = struct {
    value: f32,
    delay: i32 = 4000,
    messages: std.ArrayList(Message) = .empty,
    sound: ?[]const u8 = null,
};

pub const Slave = struct { sector: usize, angle: i16 = 0 };

pub const Elevator = struct {
    sector: usize,
    kind: Kind,
    mode: i32 = -1,
    object_id: u32 = 0,
    excluded_object: u32 = 0,
    step: bool = false,
    next_time: u32 = 0,
    blocked_time: u32 = 0xffffffff,
    stops: std.ArrayList(Stop) = .empty,
    slaves: std.ArrayList(Slave) = .empty,
    target: ?usize = null,
    cursor: usize = 0,
    speed: f32,
    value: f32,
    internal_value: f32 = 0,
    vector: level_module.Vec2 = .{ .x = 0, .z = 0 },
    flags: u32 = 0xf00000,
    sounds: [3]?[]const u8 = .{ null, null, null },
    loop_sound: bool = false,
    event_mask: u32 = 0,
    entity_mask: u32 = 0x10,
    runtime_flags: u32 = 2,
    deleted: bool = false,
    start: usize = 0,
    automatic_door: bool = false,
};

pub const Client = struct { target: Target, mask: u32, code: u32 = 0, arg1: i32 = 0, arg2: i32 = 0 };

pub const Trigger = struct {
    target: Target,
    flags: u32,
    clients: std.ArrayList(Client) = .empty,
    message: Message = .{},
    object_id: u32 = 0,
    excluded_object: u32 = 0,
    sound: ?[]const u8 = null,
    time20: u32 = 0xffffffff,
    time24: u32 = 0,
    movie: ?[]const u8 = null,
    next_level: ?[]const u8 = null,
    spawn: ?Target = null,
    event_mask: u32 = 0xffffffff,
    entity_mask: u32 = 0x10,
    deleted: bool = false,
};

pub const Event = struct {
    sector: usize,
    wall: ?usize = null,
    mask: u32,
    entity_mask: u32 = 0x10,
    from_player: bool = true,
    object_id: u32 = 0,
    inventory_ids: []const u32 = &.{},
    game_mode_mask: u32 = 0x200000,
    now_ms: u32,
};

pub const Effect = union(enum) {
    sound: struct {
        name: []const u8,
        sector: ?usize = null,
        position: ?level_module.Vec3 = null,
        mode: enum { once, loop, stop, update },
        priority: u8 = 64,
        source: ?usize = null,
        volume: u8 = 127,
        flags: u32 = 0,
        occlusion_applied: bool = false,
        listener: ?audio_engine.Listener = null,
        delivered: bool = false,
    },
    inventory_use: struct { object_id: u32, success: bool },
    wall_frame: struct { sector: usize, wall: ?usize, code: u32, arg1: i32 = 0, instance: ?usize = null },
    actor_impulse: struct { contact: geometry.Contact, velocity: level_module.Vec3 },
};

pub const Pending = union(enum) {
    message: struct { value: Message, entity_mask: u32 },
    actor_impulse: @FieldType(Effect, "actor_impulse"),
};

pub const TickContext = struct {
    random: *u32,
    textures: []const texture.Texture = &.{},
    world: ?*geometry.World = null,
    now_ms: u32 = 0,
    inventory_ids: []const u32 = &.{},
    game_mode_mask: u32 = 0x200000,
};

pub const StartupContext = struct {
    world: ?*geometry.World = null,
    textures: []const texture.Texture = &.{},
    seconds: f32 = 1,
};

pub const Class = union(enum) { elevator: usize, trigger: usize };

pub const AudioContext = struct {
    cache: *audio_occlusion.Cache,
    scene: *const scene_module.Scene,
    angles: *const camera.Angles,
    listener_eye: level_module.Vec3,
    listener_sector: usize,
    listener: audio_engine.Listener,
    now_ms: u32,
};

pub const Snapshot = struct {
    elevators: []Elevator,
    triggers: []Trigger,
    effects_len: usize,
    task_time: u32,
    geometry_dirty: bool,
    pending: []Pending,

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.elevators);
        allocator.free(self.triggers);
        allocator.free(self.pending);
    }
};

pub const DbLink = struct {
    target: Target,
    kind: enum { elevator, trigger, atx },
    index: usize,
    event_mask: u32,
    entity_mask: u32,
};

pub const MovieHost = struct {
    context: *anyopaque,
    play: *const fn (*anyopaque, []const u8, u32) anyerror!u32,
};

pub const Runtime = struct {
    arena: std.heap.ArenaAllocator,
    elevators: []Elevator,
    triggers: []Trigger,
    classes: []Class,
    restored_links: []const DbLink = &.{},
    elevator_clock: u32 = 0,
    base_vertices: []const []const level_module.Vec2 = &.{},
    effects: std.ArrayList(Effect) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    router: ?*Router = null,
    marks: ?geometry.Marks = null,
    task_time: u32 = 0,
    geometry_dirty: bool = false,
    movie_host: ?MovieHost = null,
    movie_elapsed: u32 = 0,
    message_log: ?*std.array_list.Managed(Message) = null,
    audio: ?AudioContext = null,
    inventory: ?*@import("../player/inventory.zig").Inventory = null,
    object_host: ?struct {
        context: *anyopaque,
        send: *const fn (*anyopaque, u32, u32) anyerror!void,
    } = null,
    unlink_host: ?struct {
        context: *anyopaque,
        unlinked: *const fn (*anyopaque, Target) void,
    } = null,

    pub const GeometryClasses = struct {
        arena: std.heap.ArenaAllocator,
        base_vertices: []const []const level_module.Vec2,
        elevators: std.ArrayList(Elevator),
        triggers: std.ArrayList(Trigger),
        classes: std.ArrayList(Class),
    };

    pub fn planeSpeed(self: *const Runtime, level: *const level_module.Level, sector: usize, ceiling: bool) f32 {
        var index = self.elevators.len;
        while (index > 0) {
            index -= 1;
            const elevator = self.elevators[index];
            const kind: Kind = if (ceiling) .ceiling else .floor;
            if (elevator.deleted or elevator.sector != sector or (elevator.kind != .floor_ceiling and elevator.kind != kind)) continue;
            if (elevator.runtime_flags & 1 == 0) return 0;
            const current = if (elevator.kind == .ceiling) level.sectors[sector].ceiling.height else level.sectors[sector].floor.height;
            const difference: f32 = if (elevator.target) |target| @floatCast(@as(f64, elevator.stops.items[target].value) - current) else 1;
            if (@abs(difference) == 0) return difference;
            return if (@as(u32, @bitCast(difference)) < 0x80000001) elevator.speed else -elevator.speed;
        }
        return 0;
    }

    pub fn load(allocator: std.mem.Allocator, level: *level_module.Level, bytes: []const u8) !Runtime {
        var random: u32 = 0x742389ac;
        return loadWithRandom(allocator, level, bytes, &random);
    }

    pub fn loadWithRandom(allocator: std.mem.Allocator, level: *level_module.Level, bytes: []const u8, random: *u32) !Runtime {
        const angles = camera.Angles.init();
        return loadImpl(allocator, level, bytes, random, null, &angles, 0);
    }

    pub fn loadWithScene(allocator: std.mem.Allocator, level: *level_module.Level, bytes: []const u8, random: *u32, scene: *scene_module.Scene, angles: *const camera.Angles) !Runtime {
        return loadWithSceneAt(allocator, level, bytes, random, scene, angles, 0);
    }

    pub fn loadWithSceneAt(allocator: std.mem.Allocator, level: *level_module.Level, bytes: []const u8, random: *u32, scene: *scene_module.Scene, angles: *const camera.Angles, now: u32) !Runtime {
        return loadImpl(allocator, level, bytes, random, scene, angles, now);
    }

    pub fn fromGeometry(now: u32, prepared: GeometryClasses) !Runtime {
        var arena = prepared.arena;
        errdefer arena.deinit();
        const a = arena.allocator();
        var elevators = prepared.elevators;
        var triggers = prepared.triggers;
        var classes = prepared.classes;
        return .{ .arena = arena, .elevators = try elevators.toOwnedSlice(a), .triggers = try triggers.toOwnedSlice(a), .classes = try classes.toOwnedSlice(a), .base_vertices = prepared.base_vertices, .task_time = now };
    }

    pub fn prepareGeometry(allocator: std.mem.Allocator, level: *level_module.Level, random: *u32, scene: ?*scene_module.Scene, angles: *const camera.Angles, now: u32) !GeometryClasses {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const base_vertices = try a.alloc([]const level_module.Vec2, level.sectors.len);
        for (level.sectors, base_vertices) |sector, *original| original.* = try a.dupe(level_module.Vec2, sector.vertices);
        var elevators: std.ArrayList(Elevator) = .empty;
        var triggers: std.ArrayList(Trigger) = .empty;
        var classes: std.ArrayList(Class) = .empty;
        for (level.sectors, 0..) |sector, index| {
            if (sector.flags & 0x100 == 0) continue;
            if (sector.walls.len == 0) return error.InvalidInfAutomaticDoor;
            var elevator = Elevator{
                .sector = index,
                .kind = .morph_spin,
                .mode = 2,
                .speed = @bitCast(@as(u32, 0x45471000)),
                .value = 0,
                .vector = sector.vertices[sector.walls[0].v1],
                .event_mask = 0x1c30,
                .entity_mask = 0x210,
                .automatic_door = true,
            };
            try elevator.stops.append(a, .{ .value = 0, .delay = -1 });
            const angle: f32 = @bitCast(@as(u32, 0x4571c000));
            try elevator.stops.append(a, .{ .value = if (sector.flags & 0x200 == 0) angle else -angle, .delay = -1 });
            const choice = nearest(randomFloat(random, 4.9));
            const sounds = [_][]const u8{ "DOOR1.WAV", "DOOR2.WAV", "DOOR3.WAV", "DOOR4.WAV", "DOOR5.WAV" };
            if (choice >= 0 and choice < sounds.len) elevator.sounds[0] = sounds[@intCast(choice)];
            elevator.sounds[2] = "DOORCLS.WAV";
            for (sector.walls) |*wall| {
                wall.flags |= 0x40;
                if (wall.adjoin >= 0) level.sectors[@intCast(wall.adjoin)].walls[@intCast(wall.mirror)].flags |= 0x40;
            }
            try finishStartup(allocator, level, &elevator, scene, angles, base_vertices, now);
            try classes.append(a, .{ .elevator = elevators.items.len });
            try elevators.append(a, elevator);
        }
        for (level.sectors, 0..) |sector, sector_index| {
            for (sector.walls, 0..) |wall, wall_index| {
                if (wall.flags & 0x4000 == 0) continue;
                if (wall.adjoin < 0 or wall.mirror < 0) return error.DoorWallMissingMirror;
                for ([_]Target{ .{ .sector = sector_index, .wall = wall_index }, .{ .sector = @intCast(wall.adjoin), .wall = @intCast(wall.mirror) } }) |owner| {
                    const exists = for (triggers.items) |trigger| {
                        if (trigger.target.sector == owner.sector and trigger.target.wall == owner.wall) break true;
                    } else false;
                    if (exists) continue;
                    level.sectors[owner.sector.?].walls[owner.wall.?].flags |= 0x8800;
                    try classes.append(a, .{ .trigger = triggers.items.len });
                    try triggers.append(a, .{ .target = owner, .flags = 0x80f00001, .event_mask = 0x8100, .entity_mask = 0x30 });
                }
            }
        }
        return .{ .arena = arena, .base_vertices = base_vertices, .elevators = elevators, .triggers = triggers, .classes = classes };
    }

    pub fn loadPrepared(allocator: std.mem.Allocator, level: *level_module.Level, bytes: []const u8, scene: ?*scene_module.Scene, angles: *const camera.Angles, now: u32, prepared: GeometryClasses) !Runtime {
        return loadPreparedWithWorld(allocator, level, bytes, scene, angles, now, prepared, .{});
    }

    pub fn loadPreparedWithWorld(allocator: std.mem.Allocator, level: *level_module.Level, bytes: []const u8, scene: ?*scene_module.Scene, angles: *const camera.Angles, now: u32, prepared: GeometryClasses, context: StartupContext) !Runtime {
        _ = allocator;
        var arena = prepared.arena;
        errdefer arena.deinit();
        const a = arena.allocator();
        const base_vertices = prepared.base_vertices;
        var elevators = prepared.elevators;
        var triggers = prepared.triggers;
        var classes = prepared.classes;
        var pending: std.ArrayList(Pending) = .empty;
        var lines = item.Lines{ .bytes = bytes };
        if (!infVersionOne(try lines.next() orelse return error.MissingInfHeader)) return error.UnsupportedInfVersion;
        var count: ?usize = null;
        var seen: usize = 0;
        var target: ?Target = null;
        var active: ?Class = null;
        var in_sequence = false;
        var abandoned_sequence = false;
        if (scene) |existing| for (level.sectors, existing.sectors) |sector, *state| {
            for (sector.walls, state.walls) |wall, *found| found.flags |= wall.flags & 0x40;
        };
        while (try lines.next()) |line| {
            var words = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = words.next().?;
            if (abandoned_sequence) {
                if (!eq(key, "ITEM:")) continue;
                abandoned_sequence = false;
            }
            if (eq(key, "LEVELNAME:") or eq(key, "LEVELNAME")) continue;
            if (eq(key, "ITEMS")) {
                if (count != null) return error.DuplicateInfCount;
                count = try unsigned(words.next());
                if (count.? > 512) return error.TooManyInfItems;
            } else if (eq(key, "ITEM:")) {
                if (in_sequence or count == null) return error.InvalidInfItemOrder;
                const kind = words.next() orelse return error.MissingInfItemKind;
                if (!eq(kind, "LINE") and !eq(kind, "SECTOR")) return error.UnsupportedInfItemKind;
                if (!eq(words.next() orelse return error.MissingInfName, "NAME:")) return error.MissingInfName;
                const sector = try findSector(level, words.next() orelse return error.MissingInfName);
                target = .{ .sector = sector };
                if (words.next()) |num| {
                    if (!eq(num, "NUM:")) return error.InvalidInfWallIndex;
                    const wall = try findWall(level, sector, words.next() orelse return error.MissingInfWallIndex);
                    if (eq(kind, "LINE")) target.?.wall = wall;
                } else if (eq(kind, "LINE")) return error.MissingInfWallIndex;
                seen += 1;
                if (seen > count.?) return error.TooManyInfItems;
            } else if (eq(key, "SEQ")) {
                if (target == null or in_sequence) return error.InvalidInfSequence;
                in_sequence = true;
            } else if (eq(key, "CLASS:")) {
                if (!in_sequence) return error.InvalidInfSequence;
                if (active) |old| if (old == .elevator) try finishStartupWithWorld(a, level, &elevators.items[old.elevator], scene, angles, base_vertices, now, context, &pending);
                const class = words.next() orelse return error.MissingInfClass;
                const subtype = words.next() orelse return error.MissingInfClassSubtype;
                if (eq(class, "ELEVATOR")) {
                    if (target.?.wall != null) return error.UnsupportedLineElevator;
                    var elevator = try construct(level, target.?.sector.?, subtype);
                    if (elevator.kind == .velocity_x or elevator.kind == .velocity_y or elevator.kind == .velocity_z) {
                        if (scene orelse if (context.world) |world| world.scene else null) |state| {
                            state.sectors[elevator.sector].velocity_present = true;
                            state.sectors[elevator.sector].runtime_flags |= 1;
                        }
                    }
                    if (eq(subtype, "EXPLODE")) {
                        try elevator.stops.append(a, .{ .value = level.sectors[elevator.sector].floor.height, .delay = -1 });
                        try elevator.stops.append(a, .{ .value = level.sectors[elevator.sector].ceiling.height, .delay = -2 });
                        try finishStartupWithWorld(a, level, &elevator, scene, angles, base_vertices, now, context, &pending);
                    }
                    active = .{ .elevator = elevators.items.len };
                    try elevators.append(a, elevator);
                } else if (eq(class, "TRIGGER")) {
                    const trigger_type: u32 = if (target.?.wall == null) blk: {
                        if (!eq(subtype, "STANDARD")) return error.UnsupportedSectorTrigger;
                        break :blk 0x08000000;
                    } else if (eq(subtype, "STANDARD")) 0x04000000 else if (eq(subtype, "SINGLE")) 0x40000000 else if (eq(subtype, "SWITCH1")) 0x10000000 else if (eq(subtype, "TOGGLE")) 0x20000000 else return error.UnsupportedInfTrigger;
                    active = .{ .trigger = triggers.items.len };
                    try triggers.append(a, .{ .target = target.?, .flags = trigger_type | 0xf00001, .event_mask = if (trigger_type >= 0x10000000) 0x30 else 0xffffffff, .entity_mask = if (trigger_type >= 0x10000000) 0x30 else 0x10 });
                } else {
                    abandoned_sequence = true;
                    active = null;
                    target = null;
                    in_sequence = false;
                    continue;
                }
                try classes.append(a, active.?);
            } else if (eq(key, "SEQEND")) {
                if (!in_sequence) return error.InvalidInfSequence;
                if (active) |old| if (old == .elevator) try finishStartupWithWorld(a, level, &elevators.items[old.elevator], scene, angles, base_vertices, now, context, &pending);
                active = null;
                target = null;
                in_sequence = false;
            } else if (active) |class| switch (class) {
                .elevator => |index| try parseElevator(a, level, angles, &elevators.items[index], key, &words),
                .trigger => |index| try parseTrigger(a, level, &triggers.items[index], key, &words),
            } else return error.InvalidInfDirectiveOrder;
        }
        if (count == null or in_sequence) return error.TruncatedInf;
        return .{ .arena = arena, .elevators = try elevators.toOwnedSlice(a), .triggers = try triggers.toOwnedSlice(a), .classes = try classes.toOwnedSlice(a), .base_vertices = base_vertices, .task_time = now, .pending = pending };
    }

    pub fn deinit(self: *Runtime) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn checkpoint(self: *const Runtime, a: std.mem.Allocator) !Snapshot {
        const elevators = try a.dupe(Elevator, self.elevators);
        errdefer a.free(elevators);
        const triggers = try a.dupe(Trigger, self.triggers);
        errdefer a.free(triggers);
        const pending = try a.dupe(Pending, self.pending.items);
        errdefer a.free(pending);
        return .{ .elevators = elevators, .triggers = triggers, .effects_len = self.effects.items.len, .task_time = self.task_time, .geometry_dirty = self.geometry_dirty, .pending = pending };
    }

    pub fn restore(self: *Runtime, snapshot: Snapshot) void {
        @memcpy(self.elevators, snapshot.elevators);
        @memcpy(self.triggers, snapshot.triggers);
        self.effects.shrinkRetainingCapacity(snapshot.effects_len);
        self.task_time = snapshot.task_time;
        self.geometry_dirty = snapshot.geometry_dirty;
        self.pending.clearRetainingCapacity();
        self.pending.appendSliceAssumeCapacity(snapshot.pending);
    }

    pub fn applyScene(self: *const Runtime, level: *const level_module.Level, scene: *scene_module.Scene) void {
        for (self.elevators) |elevator| {
            scene.sectors[elevator.sector].runtime_flags |= 1;
            for (elevator.slaves.items) |slave| scene.sectors[slave.sector].runtime_flags |= 1;
            if (elevator.kind == .velocity_x or elevator.kind == .velocity_y or elevator.kind == .velocity_z) scene.sectors[elevator.sector].velocity_present = true;
            if (@intFromEnum(elevator.kind) <= 5 or elevator.kind == .floor_ceiling) {
                for (level.sectors[elevator.sector].walls, scene.sectors[elevator.sector].walls) |wall, *state| {
                    state.runtime_flags |= 0x04000000;
                    if (elevator.automatic_door) state.runtime_flags |= 4;
                    if (wall.adjoin >= 0) {
                        const mirror = &scene.sectors[@intCast(wall.adjoin)].walls[@intCast(wall.mirror)];
                        mirror.runtime_flags |= 0x04000000;
                        if (elevator.automatic_door) mirror.runtime_flags |= 4;
                    }
                }
            }
        }
        for (self.triggers) |trigger| if (trigger.target.sector) |sector| {
            if (trigger.target.wall) |wall|
                scene.sectors[sector].walls[wall].runtime_flags |= 1
            else
                scene.sectors[sector].runtime_flags |= 1;
        };
    }

    pub fn event(self: *Runtime, level: *level_module.Level, ev: Event) anyerror!void {
        if (ev.sector >= level.sectors.len) return error.InvalidInfSector;
        if (ev.wall) |wall| if (wall >= level.sectors[ev.sector].walls.len) return error.InvalidInfWallIndex;
        try self.enqueue(.{ .target = .{ .sector = ev.sector, .wall = ev.wall }, .event_mask = ev.mask, .arg1 = if (ev.from_player) 1 else 0, .arg2 = @bitCast(ev.object_id) }, ev.entity_mask);
    }

    pub fn postSystem(self: *Runtime, message: Message) !void {
        const router = self.router orelse return error.MissingNetworkRouter;
        var bytes = network_message.words(message.code, router.own_client, .{ 0, @bitCast(message.arg1), @bitCast(message.arg2) });
        network_message.set(&bytes, network_message.reply_offset, 0x100800);
        network_message.set(&bytes, network_message.sender_offset, network_message.addressWord(1, @truncate(router.own_client)));
        try router.postHereAndEveryone(0x100800, message.code, &bytes);
    }

    pub fn flushQueued(self: *Runtime, level: *level_module.Level, scene: ?*scene_module.Scene, now_ms: u32, inventory_ids: []const u32, game_mode_mask: u32) anyerror!void {
        self.movie_elapsed = 0;
        var index: usize = 0;
        while (index < self.pending.items.len) : (index += 1) {
            if (index >= 65536) return error.InfMessageRecursion;
            const pending = self.pending.items[index];
            switch (pending) {
                .actor_impulse => |impulse| try self.effects.append(self.arena.allocator(), .{ .actor_impulse = impulse }),
                .message => |delivery| {
                    const message = delivery.value;
                    if (message.target.object) |id| {
                        const host = self.object_host orelse return error.MissingInfObjectRuntime;
                        try host.send(host.context, id, message.code);
                        continue;
                    }
                    if (message.code == 0x7df or message.code == 0x7e0) {
                        try changeBits(level, scene orelse return error.MissingInfScene, message, self.marks);
                        continue;
                    }
                    try self.dispatch(level, scene, message, .{ .sector = message.target.sector.?, .mask = message.event_mask, .entity_mask = delivery.entity_mask, .from_player = false, .now_ms = now_ms +% self.movie_elapsed, .inventory_ids = inventory_ids, .game_mode_mask = game_mode_mask }, 0);
                    if (self.restored_links.len == 0 and delivery.entity_mask != 0 and (message.event_mask == 0 or message.event_mask & 0x2000 != 0) and
                        (message.code == 0x7d7 or message.code == 0x7d8 or message.code == 0x7da or (message.code >= 0x7e7 and message.code <= 0x7ea)))
                        try self.effects.append(self.arena.allocator(), .{ .wall_frame = .{ .sector = message.target.sector.?, .wall = message.target.wall, .code = message.code, .arg1 = message.arg1 } });
                },
            }
        }
        self.pending.clearRetainingCapacity();
    }

    pub fn shatterWall(self: *Runtime, level: *level_module.Level, scene: *scene_module.Scene, sector: usize, wall: usize) !void {
        try self.breakWall(level, scene, .{ .sector = @intCast(sector), .wall = @intCast(wall) }, false);
    }

    pub fn advance(self: *Runtime, level: *level_module.Level, now_ms: u32, seconds: f32, context: TickContext) anyerror!void {
        if (now_ms <= self.task_time) return;
        try self.runTask(level, now_ms, seconds, context);
    }

    fn loadImpl(allocator: std.mem.Allocator, level: *level_module.Level, bytes: []const u8, random: *u32, scene: ?*scene_module.Scene, angles: *const camera.Angles, now: u32) !Runtime {
        if (scene == null) {
            var initial_scene = try scene_module.Scene.init(allocator, level, angles);
            defer initial_scene.deinit();
            return loadPrepared(allocator, level, bytes, &initial_scene, angles, now, try prepareGeometry(allocator, level, random, &initial_scene, angles, now));
        }
        return loadPrepared(allocator, level, bytes, scene, angles, now, try prepareGeometry(allocator, level, random, scene, angles, now));
    }

    fn enqueue(self: *Runtime, message: Message, entity_mask: u32) !void {
        if (self.message_log) |log| try log.append(message);
        if (message.target.sector == null and message.target.object == null) {
            try self.postSystem(message);
        } else try self.pending.append(self.arena.allocator(), .{ .message = .{ .value = message, .entity_mask = entity_mask } });
    }

    fn changeBits(level: *level_module.Level, scene: *scene_module.Scene, message: Message, marks: ?geometry.Marks) !void {
        const index = message.target.sector orelse return error.InvalidInfClient;
        if (index >= level.sectors.len) return error.InvalidInfClient;
        const sector = &level.sectors[index];
        const state = &scene.sectors[index];
        var primary: *u32 = undefined;
        var runtime: *u32 = undefined;
        var source: *u32 = undefined;
        const dirty: u32 = if (message.target.wall) |wall_index| blk: {
            if (wall_index >= sector.walls.len) return error.InvalidInfWallIndex;
            primary = &state.walls[wall_index].flags;
            runtime = &state.walls[wall_index].runtime_flags;
            source = &sector.walls[wall_index].flags;
            break :blk 4;
        } else blk: {
            primary = &state.flags;
            runtime = &state.runtime_flags;
            source = &sector.flags;
            break :blk 8;
        };
        const bits: u32 = @bitCast(message.arg2);
        if (marks) |hook| try hook.call(if (message.target.wall) |wall| .{ .wall_flags = .{ .sector = index, .index = wall } } else .{ .sector_flags = index });
        runtime.* |= dirty;
        const destination = if (message.arg1 == 1) primary else runtime;
        if (message.code == 0x7df) destination.* |= bits else destination.* &= ~bits;
        source.* = primary.*;
    }

    fn dispatch(self: *Runtime, level: *level_module.Level, scene: ?*scene_module.Scene, message: Message, ev: Event, depth: usize) anyerror!void {
        if (depth > 256) return error.InfMessageRecursion;
        if (message.target.sector == null) return error.MissingInfTargetSector;
        if (self.restored_links.len != 0) {
            var link_index = self.restored_links.len;
            while (link_index != 0) {
                link_index -= 1;
                const link = self.restored_links[link_index];
                if (link.target.sector != message.target.sector or link.target.wall != message.target.wall) continue;
                switch (link.kind) {
                    .elevator => try self.dispatchClass(level, scene, .{ .elevator = link.index }, message, ev, depth),
                    .trigger => try self.dispatchClass(level, scene, .{ .trigger = link.index }, message, ev, depth),
                    .atx => {
                        if (message.event_mask != 0 and message.event_mask & link.event_mask == 0) continue;
                        if (ev.entity_mask & link.entity_mask == 0) continue;
                        try self.effects.append(self.arena.allocator(), .{ .wall_frame = .{ .sector = link.target.sector.?, .wall = link.target.wall, .code = message.code, .arg1 = message.arg1, .instance = link.index } });
                    },
                }
            }
            return;
        }
        var i = self.classes.len;
        while (i != 0) {
            i -= 1;
            try self.dispatchClass(level, scene, self.classes[i], message, ev, depth);
        }
    }

    fn dispatchClass(self: *Runtime, level: *level_module.Level, scene: ?*scene_module.Scene, class: Class, message: Message, ev: Event, depth: usize) anyerror!void {
        switch (class) {
            .elevator => |index| {
                const elevator = &self.elevators[index];
                if (elevator.deleted or message.target.wall != null or elevator.sector != message.target.sector.?) return;
                if (message.event_mask != 0 and message.event_mask & elevator.event_mask == 0) return;
                if (ev.entity_mask & elevator.entity_mask == 0) return;
                refreshValue(level, elevator);
                try self.elevatorMessage(level, elevator, message, ev);
            },
            .trigger => |index| {
                const trigger = &self.triggers[index];
                if (trigger.deleted or trigger.target.sector != message.target.sector or trigger.target.wall != message.target.wall) return;
                if (message.event_mask != 0 and message.event_mask & trigger.event_mask == 0) return;
                if (ev.entity_mask & trigger.entity_mask == 0) return;
                try self.triggerMessage(level, scene, trigger, message, ev, depth);
            },
        }
    }

    fn elevatorMessage(self: *Runtime, level: *const level_module.Level, elevator: *Elevator, message: Message, ev: Event) !void {
        self.task_time = ev.now_ms;
        if (message.code == 0x66) {
            elevator.deleted = true;
            if (self.unlink_host) |host| host.unlinked(host.context, .{ .sector = elevator.sector });
            return;
        }
        if (message.code == 0x7dd) {
            elevator.runtime_flags |= 2;
            return;
        }
        if (elevator.runtime_flags & 2 == 0) return;
        switch (message.code) {
            0x7d6 => {
                if (ev.game_mode_mask & elevator.flags & 0xf00000 == 0) return;
                const object: u32 = @bitCast(message.arg2);
                var owned_ids: [25]u32 = undefined;
                const inventory_ids = self.inventoryIds(&owned_ids, ev.inventory_ids);
                if (!passesObject(elevator.flags, elevator.object_id, elevator.excluded_object, object, message.arg1 != 0, inventory_ids, 0x1000000, 0x2000000)) {
                    try self.inventoryUseSound(object, message.arg1 != 0, ev.inventory_ids, false);
                    return;
                }
                if (elevator.stops.items.len == 0 and elevator.mode != 0) return error.InvalidInfStop;
                if (elevator.mode == 1) {
                    elevator.target = elevator.stops.items.len - 1;
                    if (elevator.value != elevator.stops.items[elevator.target.?].value) try self.start(level, elevator, ev.now_ms);
                } else {
                    if (elevator.mode == 3) {
                        if (elevator.next_time < ev.now_ms) self.selectRelative(elevator, -1);
                        self.selectRelative(elevator, -1);
                    } else if (elevator.mode != 0 and ev.now_ms > elevator.next_time) self.selectRelative(elevator, 1);
                    try self.start(level, elevator, ev.now_ms);
                }
                try self.inventoryUseSound(object, message.arg1 != 0, ev.inventory_ids, true);
                try self.toggleObject(&elevator.flags, elevator.object_id, object);
            },
            0x7d7 => {
                if (elevator.next_time < ev.now_ms) self.selectRelative(elevator, 1);
                try self.start(level, elevator, ev.now_ms);
            },
            0x7d8 => {
                if (ev.now_ms < elevator.next_time) self.selectRelative(elevator, -1);
                self.selectRelative(elevator, -1);
                try self.start(level, elevator, ev.now_ms);
            },
            0x7da => {
                if (elevator.stops.items.len == 0) return error.InvalidInfStop;
                const selected = if (message.arg1 < 0) elevator.stops.items.len - 1 else @as(usize, @intCast(message.arg1)) % elevator.stops.items.len;
                if (message.arg1 >= 0) elevator.cursor = selected;
                if (elevator.value != elevator.stops.items[selected].value) {
                    elevator.target = selected;
                    try self.start(level, elevator, ev.now_ms);
                    if (elevator.runtime_flags & 1 != 0) {
                        try self.stopSounds(level, elevator);
                        elevator.runtime_flags &= ~@as(u32, 1);
                    }
                }
            },
            0x7de => elevator.runtime_flags &= ~@as(u32, 2),
            else => {},
        }
    }

    fn inventoryUseSound(self: *Runtime, object: u32, from_player: bool, inventory: []const u32, success: bool) !void {
        if (self.inventory) |owned_inventory| {
            if (object == 0 or !from_player) return;
            for (owned_inventory.slots[1..]) |slot| if (slot) |owned| {
                if (@as(u32, @bitCast(owned.definition.use_id)) != object) continue;
                const name = if (success) owned.definition.use_success_sound else owned.definition.use_failure_sound;
                if (name) |sound_name| try self.effects.append(self.arena.allocator(), .{ .sound = .{ .name = sound_name, .mode = .once, .priority = 64, .volume = 127, .flags = 4 } });
                return;
            };
            return;
        }
        if (object != 0 and from_player and std.mem.indexOfScalar(u32, inventory, object) != null)
            try self.effects.append(self.arena.allocator(), .{ .inventory_use = .{ .object_id = object, .success = success } });
    }

    fn inventoryIds(self: *const Runtime, buffer: *[25]u32, fallback: []const u32) []const u32 {
        const inventory = self.inventory orelse return fallback;
        var count: usize = 0;
        for (inventory.slots[1..]) |slot| if (slot) |owned| {
            buffer[count] = @bitCast(owned.definition.use_id);
            count += 1;
        };
        return buffer[0..count];
    }

    fn toggleObject(self: *Runtime, flags: *u32, required: u32, object: u32) !void {
        if (required == 0 or required != object) return;
        if (flags.* & 0x20000 != 0) {
            flags.* ^= 0x10000;
            flags.* &= ~@as(u32, 0x20000);
        }
        if (flags.* & 0x40000 != 0) flags.* ^= 0x10000;
        if (flags.* & 0x80000 != 0) {
            const inventory = self.inventory orelse return error.MissingInfInventory;
            const selected = inventory.selected;
            if (selected != 0 and inventory.slots[selected] != null) try inventory.remove(selected);
        }
    }

    fn triggerMessage(self: *Runtime, level: *level_module.Level, scene: ?*scene_module.Scene, trigger: *Trigger, message: Message, ev: Event, depth: usize) anyerror!void {
        switch (message.code) {
            0x66 => {
                trigger.deleted = true;
                if (self.unlink_host) |host| host.unlinked(host.context, trigger.target);
            },
            0x7a => if (trigger.flags & 0xff000000 == 0x10000000) {
                try self.triggerWallMessage(level, trigger, 0x7ea, ev, depth);
                trigger.flags |= 1;
            },
            0x7dd => trigger.flags |= 1,
            0x7de => trigger.flags &= ~@as(u32, 1),
            0x7d6 => {
                if (trigger.flags & 1 == 0 or ev.game_mode_mask & trigger.flags & 0xf00000 == 0) return;
                const object: u32 = @bitCast(message.arg2);
                var owned_ids: [25]u32 = undefined;
                if (!passesObject(trigger.flags, trigger.object_id, trigger.excluded_object, object, true, self.inventoryIds(&owned_ids, ev.inventory_ids), 0x1000, 0x2000)) return;
                if (trigger.sound) |name| try self.effects.append(self.arena.allocator(), .{ .sound = .{ .name = name, .mode = .once } });
                for (trigger.clients.items) |client| if (message.event_mask & client.mask != 0) {
                    var outgoing = trigger.message;
                    outgoing.target = client.target;
                    try self.enqueue(outgoing, 0xffffffff);
                };
                if (trigger.movie) |name| {
                    const host = self.movie_host orelse return error.MissingInfMovieHost;
                    self.movie_elapsed +%= try host.play(host.context, name, 1);
                }
                const subtype = trigger.flags & 0xff000000;
                if (subtype >= 0x10000000 and subtype <= 0x40000000) {
                    try self.triggerWallMessage(level, trigger, if (subtype == 0x10000000) 0x7ea else 0x7e7, ev, depth);
                    if (subtype != 0x20000000) trigger.flags &= ~@as(u32, 1);
                } else if (subtype == 0x80000000) {
                    try self.breakWall(level, scene orelse return error.MissingInfScene, trigger.target, true);
                    trigger.entity_mask = 0;
                }
                try self.toggleObject(&trigger.flags, trigger.object_id, object);
                if (trigger.flags & 2 != 0) try network_server.requestEndLevel(self.router orelse return error.MissingNetworkRouter);
            },
            else => {},
        }
    }

    fn breakWall(self: *Runtime, level: *level_module.Level, scene: *scene_module.Scene, target: Target, send: bool) !void {
        const sector = target.sector orelse return error.InvalidInfClient;
        const index = target.wall orelse return error.InvalidInfWallIndex;
        const wall = level.sectors[sector].walls[index];
        if (scene.sectors[sector].walls[index].flags & 0x4000 == 0) return;
        if (wall.adjoin < 0 or wall.mirror < 0) return error.DoorWallMissingMirror;
        const other: Target = .{ .sector = @intCast(wall.adjoin), .wall = @intCast(wall.mirror) };
        for ([_]Target{ target, other }) |owner|
            try self.enqueue(.{ .target = owner, .code = 0x7e7, .event_mask = 0x2000 }, 0xffffffff);
        for ([_]Target{ target, other }) |owner| {
            const state = &scene.sectors[owner.sector.?].walls[owner.wall.?];
            state.flags &= ~@as(u32, 0x4800);
            state.runtime_flags |= 4;
            level.sectors[owner.sector.?].walls[owner.wall.?].flags = state.flags;
        }
        if (send) {
            const router = self.router orelse return error.MissingNetworkRouter;
            var bytes = network_message.shatterWall(router.own_client, @intCast(sector), @intCast(index));
            _ = try router.post(0, 0x422 | 0x80000000, &bytes);
        }
    }

    fn triggerWallMessage(self: *Runtime, level: *level_module.Level, trigger: *Trigger, code: u32, ev: Event, depth: usize) anyerror!void {
        _ = level;
        _ = ev;
        _ = depth;
        const outgoing = Message{ .target = trigger.target, .code = code, .event_mask = 0x2000 };
        try self.enqueue(outgoing, 0xffffffff);
    }

    fn selectRelative(_: *Runtime, elevator: *Elevator, delta: i32) void {
        if (elevator.stops.items.len == 0) return;
        elevator.cursor = @intCast(@mod(@as(i64, @intCast(elevator.cursor)) + delta, @as(i64, @intCast(elevator.stops.items.len))));
        elevator.target = elevator.cursor;
    }

    fn start(self: *Runtime, level: *const level_module.Level, elevator: *Elevator, now: u32) !void {
        if (elevator.runtime_flags & 1 != 0) return;
        if (elevator.target) |target| if (elevator.value != elevator.stops.items[target].value) {
            try self.sound(level, elevator, 0, .once);
            try self.sound(level, elevator, 1, .loop);
        };
        self.elevator_clock = 0;
        elevator.next_time = now;
        elevator.runtime_flags |= 1;
    }

    fn sound(self: *Runtime, level: *const level_module.Level, elevator: *Elevator, slot: usize, mode: @FieldType(@FieldType(Effect, "sound"), "mode")) !void {
        if (elevator.sounds[slot]) |name| {
            const sector = level.sectors[elevator.sector];
            if (elevator.kind != .morph_spin and sector.vertices.len == 0) return error.InvalidInfSoundPosition;
            const point = if (elevator.kind == .morph_spin) elevator.vector else sector.vertices[0];
            const position: level_module.Vec3 = .{ .x = point.x, .y = sector.floor.height, .z = point.z };
            const flags: u32 = if (mode == .loop or mode == .update) 1 else 0;
            var volume: u8 = 127;
            const context = self.audio;
            if (context) |audio| if (mode != .stop) {
                volume = @intCast(try audio.cache.volume(level, audio.scene, audio.angles, elevator.sector, audio.listener_sector, position, audio.listener_eye, 127, flags, audio.now_ms));
            };
            try self.effects.append(self.arena.allocator(), .{
                .sound = .{
                    .name = name,
                    .source = (@intFromPtr(elevator) - @intFromPtr(self.elevators.ptr)) / @sizeOf(Elevator),
                    .sector = elevator.sector,
                    .position = position,
                    .mode = mode,
                    .flags = flags,
                    .volume = volume,
                    .occlusion_applied = context != null and mode != .stop,
                    .listener = if (context) |audio| audio.listener else null,
                },
            });
            if (slot == 1 and mode != .update) elevator.loop_sound = mode == .loop;
        }
    }

    fn stopSounds(self: *Runtime, level: *const level_module.Level, elevator: *Elevator) !void {
        if (elevator.loop_sound) try self.sound(level, elevator, 1, .stop);
        try self.sound(level, elevator, 2, .once);
        elevator.loop_sound = false;
    }

    fn runTask(self: *Runtime, level: *level_module.Level, now_ms: u32, seconds: f32, context: TickContext) anyerror!void {
        if (context.world) |world| for (self.elevators) |elevator| {
            if (elevator.deleted or elevator.runtime_flags & 2 == 0 or elevator.next_time >= now_ms) continue;
            if (elevator.kind != .morph_move and elevator.kind != .morph_spin) continue;
            if (elevator.target) |index| if (elevator.value == elevator.stops.items[index].value) continue;
            try geometry.ensureLoaded(world, elevator.sector);
            for (elevator.slaves.items) |slave| try geometry.ensureLoaded(world, slave.sector);
        };
        var tick = context;
        tick.now_ms = now_ms;
        var delay: u32 = 2000;
        for (self.elevators) |*elevator| {
            if (elevator.deleted or elevator.runtime_flags & 2 == 0) continue;
            refreshValue(level, elevator);
            if (elevator.next_time >= now_ms) {
                delay = @min(delay, elevator.next_time - now_ms);
                continue;
            }
            if (elevator.runtime_flags & 1 == 0) try self.start(level, elevator, now_ms);
            if (elevator.runtime_flags & 1 != 0) {
                if (!elevator.loop_sound) try self.sound(level, elevator, 1, .loop);
                if (elevator.loop_sound) try self.sound(level, elevator, 1, .update);
            }
            const reached = try self.stepElevator(level, elevator, seconds, tick);
            if (!reached) {
                elevator.next_time = 0;
                delay = 0;
                continue;
            }
            const stop_index = elevator.target orelse return error.InvalidInfStop;
            const stop = elevator.stops.items[stop_index];
            if (elevator.runtime_flags & 1 != 0 and stop.delay != 0) try self.stopSounds(level, elevator);
            if (stop.delay == 0) elevator.runtime_flags |= 1 else elevator.runtime_flags &= ~@as(u32, 1);
            if (elevator.runtime_flags & 4 != 0) {
                elevator.next_time = now_ms +% 1000;
                elevator.runtime_flags &= ~@as(u32, 4);
            } else if (stop.delay == -2) {
                elevator.deleted = true;
                continue;
            } else if (stop.delay == -1) elevator.next_time = 0xffffffff else {
                elevator.next_time = now_ms +% @as(u32, @bitCast(stop.delay));
                delay = @min(delay, @as(u32, @bitCast(stop.delay)));
            }
            for (stop.messages.items) |message| {
                delay = 0;
                try self.enqueue(message, 0xffffffff);
            }
            self.selectRelative(elevator, 1);
        }
        self.task_time = now_ms +% @min(delay, 2000);
    }

    fn stepElevator(self: *Runtime, level: *level_module.Level, elevator: *Elevator, seconds: f32, context: TickContext) !bool {
        refreshValue(level, elevator);
        const previous = elevator.value;
        const target = if (elevator.target) |index| elevator.stops.items[index].value else previous;
        if (elevator.target != null and target == previous) return true;
        const delta = try stepDelta(previous, if (elevator.target == null) null else target, elevator.speed, elevator.step, seconds, elevator.vector, context.random);
        switch (elevator.kind) {
            .ceiling, .floor, .floor_ceiling => {
                const world = context.world orelse return error.MissingInfGeometryWorld;
                const floor_delta: f32 = if (elevator.kind == .ceiling) 0 else delta;
                const ceiling_delta: f32 = if (elevator.kind == .floor) 0 else delta;
                try geometry.moveVertical(world, elevator.sector, floor_delta, ceiling_delta);
                for (elevator.slaves.items) |slave| try geometry.moveVertical(world, slave.sector, floor_delta, ceiling_delta);
                refreshValue(level, elevator);
            },
            .light => {
                elevator.value += delta;
                const sector = &level.sectors[elevator.sector];
                const change = nearest(elevator.value - @as(f32, @floatFromInt(sector.ambient)));
                sector.ambient = nearest(elevator.value);
                if (context.world) |world| {
                    world.scene.sectors[elevator.sector].runtime_flags |= 1;
                    if (world.marks) |marks| try marks.call(.{ .light = elevator.sector });
                }
                for (elevator.slaves.items) |slave| {
                    level.sectors[slave.sector].ambient +%= change;
                    if (context.world) |world| {
                        world.scene.sectors[slave.sector].runtime_flags |= 1;
                        if (world.marks) |marks| try marks.call(.{ .light = slave.sector });
                    }
                }
            },
            .scroll_wall => {
                const dx = elevator.vector.x * delta;
                const dz = elevator.vector.z * delta;
                try scrollWalls(level, elevator.sector, dx, dz, context.textures);
                for (elevator.slaves.items) |slave| try scrollWalls(level, slave.sector, dx, dz, context.textures);
                if (context.world) |world| {
                    markScrollWalls(level, world.scene, elevator.sector);
                    for (elevator.slaves.items) |slave| markScrollWalls(level, world.scene, slave.sector);
                }
                elevator.value += delta;
            },
            .scroll_floor, .scroll_ceiling => {
                elevator.value += delta;
                const dx: f32 = @floatCast(@as(f64, elevator.vector.x) * delta * 0.125);
                const dz: f32 = @floatCast(-(@as(f64, elevator.vector.z) * delta * 0.125));
                const ceiling = elevator.kind == .scroll_ceiling;
                try scrollPlane(level, elevator.sector, ceiling, dx, dz, context.textures);
                if (context.world) |world| world.scene.sectors[elevator.sector].runtime_flags |= 1;
                for (elevator.slaves.items) |slave| {
                    try scrollPlane(level, slave.sector, ceiling, dx, dz, context.textures);
                    if (context.world) |world| world.scene.sectors[slave.sector].runtime_flags |= 1;
                }
            },
            .morph_move, .morph_spin => try self.morph(elevator, delta, seconds, context),
            .velocity_x, .velocity_y, .velocity_z => {
                const change = level_module.Vec3{ .x = if (elevator.kind == .velocity_x) delta else 0, .y = if (elevator.kind == .velocity_y) delta else 0, .z = if (elevator.kind == .velocity_z) delta else 0 };
                try changeVelocity(level, context.world, elevator.sector, change);
                for (elevator.slaves.items) |slave| try changeVelocity(level, context.world, slave.sector, change);
                elevator.value += delta;
            },
            else => return error.UnsupportedInfDynamicElevator,
        }
        self.geometry_dirty = true;
        return elevator.target != null and target == elevator.value;
    }

    fn morph(self: *Runtime, elevator: *Elevator, delta: f32, seconds: f32, context: TickContext) !void {
        const world = context.world orelse return error.MissingInfGeometryWorld;
        const spinning = elevator.kind == .morph_spin;
        const integer_delta: f32 = if (spinning) @floatFromInt(if (@as(i32, @bitCast(delta)) > 0) @as(i32, @intFromFloat(@as(f64, delta) + 0.5)) else -@as(i32, @intFromFloat(0.5 - @as(f64, delta)))) else delta;
        const next = elevator.value + integer_delta;
        const next_angle = if (spinning) try shortAngle(@as(f64, elevator.value) + integer_delta) else 0;
        const contact = if (spinning) try geometry.spin(world, elevator.sector, next_angle, elevator.vector, self.base_vertices) else try geometry.move(world, elevator.sector, delta, elevator.vector.x, elevator.vector.z);
        var blocked = contact != null;
        for (elevator.slaves.items) |slave| {
            const hit = if (spinning) try geometry.spin(world, slave.sector, next_angle +% slave.angle, elevator.vector, self.base_vertices) else try geometry.move(world, slave.sector, delta, elevator.vector.x, elevator.vector.z);
            blocked = blocked or hit != null;
        }
        if (!blocked) {
            elevator.value = next;
            elevator.blocked_time = 0xffffffff;
            return;
        }
        if (spinning) {
            const previous_angle = try shortAngle(@as(f64, elevator.value) - integer_delta);
            _ = try geometry.spin(world, elevator.sector, previous_angle, elevator.vector, self.base_vertices);
            for (elevator.slaves.items) |slave| _ = try geometry.spin(world, slave.sector, previous_angle +% slave.angle, elevator.vector, self.base_vertices);
        } else {
            _ = try geometry.move(world, elevator.sector, -delta, elevator.vector.x, elevator.vector.z);
            for (elevator.slaves.items) |slave| _ = try geometry.move(world, slave.sector, -delta, elevator.vector.x, elevator.vector.z);
        }
        if (elevator.blocked_time == 0xffffffff) elevator.blocked_time = context.now_ms +% 2000 else if (elevator.blocked_time < context.now_ms) {
            self.selectRelative(elevator, -1);
            elevator.blocked_time = 0xffffffff;
        }
        if (contact) |hit| {
            if (!spinning and seconds == 0) return error.InvalidInfElapsed;
            const magnitude: f32 = if (spinning) 10 else @abs(delta / seconds);
            const angle = world.scene.sectors[hit.wall.sector].walls[hit.wall.index].angle +% 0x1000;
            const trig = world.angles.sinCos(angle);
            try self.pending.append(self.arena.allocator(), .{ .actor_impulse = .{ .contact = hit, .velocity = .{ .x = magnitude * trig.sin, .y = 0, .z = magnitude * trig.cos } } });
        }
    }
};

pub fn stepDelta(current: f32, target: ?f32, speed: f32, step: bool, seconds: f32, bounds: level_module.Vec2, random: *u32) !f32 {
    if (!std.math.isFinite(current) or !std.math.isFinite(speed) or !std.math.isFinite(seconds)) return error.InvalidInfFloat;
    if (target == null) return speed * seconds;
    var delta = target.? - current;
    if (@as(u32, @bitCast(speed)) <= 0x80000000) {
        if (speed == 0) return delta;
        if (step) return speed;
        const amount = speed * seconds;
        return if (delta > amount) amount else if (delta < -amount) -amount else delta;
    }
    var amount = (randomFloat(random, @abs(speed)) - @abs(speed * 0.5)) * seconds;
    if (delta > amount) {
        amount = (randomFloat(random, @abs(speed)) - @abs(speed * 0.5)) * seconds;
        delta = amount;
    } else {
        amount = (randomFloat(random, @abs(speed)) - @abs(speed * 0.5)) * seconds;
        if (delta < -amount) {
            amount = (randomFloat(random, @abs(speed)) - @abs(speed * 0.5)) * seconds;
            delta = -amount;
        }
    }
    return @min(@max(bounds.x - current, delta), bounds.z - current);
}

fn changeVelocity(level: *level_module.Level, world: ?*geometry.World, sector: usize, change: level_module.Vec3) !void {
    if (world) |context| if (!context.scene.sectors[sector].velocity_present) return error.MissingInfSectorVelocity;
    const velocity = &level.sectors[sector].velocity;
    velocity.x += change.x;
    velocity.y += change.y;
    velocity.z += change.z;
    if (world) |context| context.scene.sectors[sector].runtime_flags |= 1;
}

fn shortAngle(value: f64) !i16 {
    if (!std.math.isFinite(value) or value < -2147483648.0 or value >= 2147483648.0) return error.InvalidInfAngle;
    return @truncate(@as(i32, @intFromFloat(value)));
}

fn refreshValue(level: *const level_module.Level, elevator: *Elevator) void {
    switch (elevator.kind) {
        .ceiling => elevator.value = level.sectors[elevator.sector].ceiling.height,
        .floor, .floor_ceiling => elevator.value = level.sectors[elevator.sector].floor.height,
        else => {},
    }
}

fn randomFloat(state: *u32, maximum: f32) f32 {
    state.* = if (state.* & 1 != 0) ~((state.* ^ 0xb9ffffff) >> 1) else state.* >> 1;
    const limit = nearest(maximum * 65536.0);
    var value: i32 = @bitCast(state.*);
    if (value < 0 or value >= limit) value = @intCast((@as(i64, @intCast(state.* & 0xffff)) * limit) >> 16);
    return @as(f32, @floatFromInt(value)) * 0.0000152587890625;
}

fn construct(level: *level_module.Level, sector: usize, subtype: []const u8) !Elevator {
    const kind: Kind = if (eq(subtype, "MOVE_CEILING") or eq(subtype, "EXPLODE")) .ceiling else if (eq(subtype, "MOVE_FLOOR")) .floor else if (eq(subtype, "MOVE_FC")) .floor_ceiling else if (eq(subtype, "MORPH_MOVE1") or eq(subtype, "MORPH_MOVE2")) .morph_move else if (eq(subtype, "MORPH_SPIN1") or eq(subtype, "MORPH_SPIN2")) .morph_spin else if (eq(subtype, "SCROLL_WALL")) .scroll_wall else if (eq(subtype, "SCROLL_FLOOR")) .scroll_floor else if (eq(subtype, "SCROLL_CEILING")) .scroll_ceiling else if (eq(subtype, "CHANGE_LIGHT")) .light else if (eq(subtype, "VELOCITY_X")) .velocity_x else if (eq(subtype, "VELOCITY_Y")) .velocity_y else if (eq(subtype, "VELOCITY_Z")) .velocity_z else return error.UnsupportedInfElevator;
    var result = Elevator{ .sector = sector, .kind = kind, .speed = switch (kind) {
        .ceiling, .floor, .floor_ceiling, .velocity_x, .velocity_y, .velocity_z => 8,
        .morph_move => 15,
        .morph_spin => 1024,
        .scroll_wall, .scroll_floor, .scroll_ceiling => 4,
        .light => 32,
        else => 0,
    }, .value = switch (kind) {
        .ceiling => level.sectors[sector].ceiling.height,
        .floor, .floor_ceiling => level.sectors[sector].floor.height,
        .light => @floatFromInt(level.sectors[sector].ambient),
        .velocity_x => level.sectors[sector].velocity.x,
        .velocity_y => level.sectors[sector].velocity.y,
        .velocity_z => level.sectors[sector].velocity.z,
        else => 0,
    } };
    if (kind == .ceiling) result.mode = 1;
    if (kind == .floor or kind == .floor_ceiling or kind == .morph_move or kind == .morph_spin or kind == .scroll_wall) result.mode = 0;
    if (kind == .morph_move or kind == .morph_spin) {
        result.entity_mask = 0x210;
        result.event_mask = 0xffffffff;
    }
    if (eq(subtype, "MORPH_MOVE2") or eq(subtype, "MORPH_SPIN2")) result.flags |= 7;
    if (eq(subtype, "EXPLODE")) {
        result.speed = 0;
        result.entity_mask = 0xffffffff;
        result.event_mask = 0x40;
    }
    return result;
}

fn finishStartup(allocator: std.mem.Allocator, level: *level_module.Level, elevator: *Elevator, scene: ?*scene_module.Scene, angles: *const camera.Angles, base_vertices: []const []const level_module.Vec2, now: u32) !void {
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(allocator);
    try finishStartupWithWorld(allocator, level, elevator, scene, angles, base_vertices, now, .{}, &pending);
}

fn finishStartupWithWorld(allocator: std.mem.Allocator, level: *level_module.Level, elevator: *Elevator, scene: ?*scene_module.Scene, angles: *const camera.Angles, base_vertices: []const []const level_module.Vec2, now: u32, context: StartupContext, pending: *std.ArrayList(Pending)) !void {
    if (elevator.stops.items.len == 0) return;
    if (elevator.start >= elevator.stops.items.len) return error.InvalidInfStart;
    refreshValue(level, elevator);
    const stop = elevator.stops.items[elevator.start];
    elevator.target = elevator.start;
    if (stop.value != elevator.value) {
        var temporary: ?scene_module.Scene = if (scene == null and context.world == null) try scene_module.Scene.init(allocator, level, angles) else null;
        defer if (temporary) |*value| value.deinit();
        var empty_world = geometry.World{ .level = level, .scene = scene orelse if (context.world) |world| world.scene else &temporary.?, .angles = angles, .actors = &.{}, .collision_diameter = 0 };
        var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(allocator), .elevators = &.{}, .triggers = &.{}, .classes = &.{}, .base_vertices = base_vertices };
        defer runtime.deinit();
        const speed = elevator.speed;
        const step = elevator.step;
        elevator.speed = 0;
        elevator.step = false;
        defer {
            elevator.speed = speed;
            elevator.step = step;
        }
        var random: u32 = 0;
        const seconds = if (context.seconds == 0) 1 else context.seconds;
        _ = try runtime.stepElevator(level, elevator, seconds, .{ .random = &random, .world = context.world orelse &empty_world, .textures = context.textures, .now_ms = now });
        try pending.appendSlice(allocator, runtime.pending.items);
    }
    elevator.next_time = if (stop.delay == -1) 0xffffffff else now +% @as(u32, @bitCast(stop.delay));
    elevator.deleted = stop.delay == -2;
    elevator.cursor = (elevator.start + 1) % elevator.stops.items.len;
    elevator.target = elevator.cursor;
}

fn parseElevator(a: std.mem.Allocator, level: *level_module.Level, angles: *const camera.Angles, e: *Elevator, key: []const u8, words: *std.mem.TokenIterator(u8, .any)) !void {
    if (eq(key, "START:")) e.start = try unsigned(words.next()) else if (eq(key, "STOP:")) {
        const raw = words.next() orelse return error.MissingInfStop;
        var value: f32 = if (raw[0] == '@') try number(raw[1..]) else if (std.ascii.isAlphabetic(raw[0])) level.sectors[try findSector(level, raw)].floor.height else try number(raw);
        if (raw[0] == '@' and (e.kind == .ceiling or e.kind == .floor or e.kind == .floor_ceiling)) value += level.sectors[e.sector].floor.height;
        if (e.kind == .morph_spin) value = @floatFromInt(try level_module.angleFromDegrees(value));
        var stop = Stop{ .value = value };
        if (words.next()) |wait| {
            stop.delay = if (eq(wait, "HOLD")) -1 else if (eq(wait, "TERMINATE")) -2 else if (eq(wait, "COMPLETE")) -3 else try milliseconds(wait);
        }
        if (e.kind == .light) {
            if (e.stops.items.len == 0) e.vector.x = value else e.vector.z = value;
        }
        try e.stops.append(a, stop);
    } else if (eq(key, "SPEED:")) {
        e.speed = try number(words.next() orelse return error.MissingInfSpeed);
        if (e.kind == .morph_spin) e.speed = @floatFromInt(try level_module.angleFromDegrees(e.speed));
    } else if (eq(key, "ANGLE:")) {
        const angle = try level_module.angleFromDegrees(try number(words.next() orelse return error.MissingInfAngle));
        const trig = angles.sinCos(angle);
        e.vector = .{ .x = trig.sin, .z = trig.cos };
    } else if (eq(key, "CENTER:")) {
        e.vector = .{ .x = try number(words.next() orelse return error.MissingInfCenter), .z = try number(words.next() orelse return error.MissingInfCenter) };
    } else if (eq(key, "SLAVE:")) {
        const sector = try findSector(level, words.next() orelse return error.MissingInfSlave);
        const angle = if (words.next()) |raw| try level_module.angleFromDegrees(try number(raw)) else 0;
        try e.slaves.append(a, .{ .sector = sector, .angle = angle });
    } else if (eq(key, "EVENT_MASK:")) e.event_mask = try mask(words.next()) else if (eq(key, "ENTITY_MASK:") or eq(key, "OBJECT_MASK:")) e.entity_mask = try mask(words.next()) else if (eq(key, "FLAGS:")) e.flags |= try mask(words.next()) else if (eq(key, "MASTER:")) e.runtime_flags &= ~@as(u32, 2) else if (eq(key, "OBJECT:") or eq(key, "OBJECT_EXCLUDE:")) {
        const excluded = eq(key, "OBJECT_EXCLUDE:");
        const id = try unsigned(words.next());
        if (excluded) e.excluded_object = id else e.object_id = id;
        try objectFlags(&e.flags, words, if (excluded) 0x2000000 else 0x1000000);
    } else if (eq(key, "SOUND:")) {
        const slot = try unsigned(words.next());
        if (slot < 1 or slot > 3) return error.InvalidInfSoundSlot;
        const name = words.next() orelse return error.MissingInfSound;
        e.sounds[slot - 1] = if (std.ascii.isDigit(name[0])) null else try a.dupe(u8, name);
    } else if (eq(key, "MESSAGE:")) {
        const index = try unsigned(words.next());
        if (index >= e.stops.items.len) return error.InvalidInfStop;
        const target = try parseTarget(level, words.next() orelse return error.MissingInfClient);
        var message = try parseMessage(words);
        message.target = target;
        try e.stops.items[index].messages.append(a, message);
    } else return error.UnsupportedInfElevatorDirective;
}

fn parseTrigger(a: std.mem.Allocator, level: *level_module.Level, t: *Trigger, key: []const u8, words: *std.mem.TokenIterator(u8, .any)) !void {
    if (eq(key, "CLIENT:")) {
        const target = try parseTarget(level, words.next() orelse return error.MissingInfClient);
        const event_mask = if (words.next()) |raw| try mask(raw) else 0xffffffff;
        try t.clients.append(a, .{ .target = target, .mask = event_mask });
    } else if (eq(key, "MESSAGE:")) {
        const saved = words.*;
        if (words.next()) |name| {
            if (eq(name, "END_LEVEL")) {
                t.flags |= 2;
                return;
            }
            if (eq(name, "TRIGGER_MOVIE")) {
                const movie = try a.dupe(u8, words.next() orelse return error.MissingInfMovie);
                for (movie) |*byte| byte.* = std.ascii.toUpper(byte.*);
                t.movie = movie;
                return;
            }
        }
        words.* = saved;
        t.message = try parseMessage(words);
    } else if (eq(key, "EVENT:")) t.message.event_mask = try mask(words.next()) else if (eq(key, "EVENT_MASK:")) t.event_mask = try mask(words.next()) else if (eq(key, "ENTITY_MASK:") or eq(key, "OBJECT_MASK:")) t.entity_mask = try mask(words.next()) else if (eq(key, "MASTER:")) t.flags &= ~@as(u32, 1) else if (eq(key, "OBJECT:") or eq(key, "OBJECT_EXCLUDE:")) {
        const excluded = eq(key, "OBJECT_EXCLUDE:");
        const id = try unsigned(words.next());
        if (excluded) t.excluded_object = id else t.object_id = id;
        try objectFlags(&t.flags, words, if (excluded) 0x2000 else 0x1000);
        if (t.target.wall == null and t.flags & 0x80000 != 0) {
            t.flags &= ~@as(u32, 0x80000);
            t.flags |= 0x10000;
        }
    } else if (eq(key, "SOUND:")) {
        const name = words.next() orelse return error.MissingInfSound;
        t.sound = if (std.ascii.isDigit(name[0])) null else try a.dupe(u8, name);
    } else return error.UnsupportedInfTriggerDirective;
}

fn parseMessage(words: *std.mem.TokenIterator(u8, .any)) !Message {
    const name = words.next() orelse return .{};
    var message = Message{};
    if (eq(name, "TRIGGER")) message.code = 0x7d6 else if (eq(name, "NEXT_STOP")) message.code = 0x7d7 else if (eq(name, "PREV_STOP")) message.code = 0x7d8 else if (eq(name, "GOTO_STOP")) message.code = 0x7da else if (eq(name, "MASTER_ON")) message.code = 0x7dd else if (eq(name, "MASTER_OFF")) message.code = 0x7de else if (eq(name, "SET_BITS")) message.code = 0x7df else if (eq(name, "CLEAR_BITS")) message.code = 0x7e0 else if (eq(name, "USER_MSG")) message.code = 0x7e5 else return error.UnsupportedInfMessage;
    if (message.code == 0x7df or message.code == 0x7e0) {
        message.arg1 = atoi(words.next() orelse return error.MissingInfMessageArgument);
        message.arg2 = atoi(words.next() orelse return error.MissingInfMessageArgument);
    } else if (message.code == 0x7da or message.code == 0x7e5) {
        message.arg1 = atoi(words.next() orelse return error.MissingInfMessageArgument);
    } else if (words.next()) |raw| message.event_mask = try mask(raw);
    return message;
}

fn parseTarget(level: *const level_module.Level, raw: []const u8) !Target {
    if (eq(raw, "SYSTEM")) return .{};
    if (raw.len == 0) return error.InvalidInfClient;
    if (raw[0] == '!') {
        if (!std.mem.startsWith(u8, raw, "!#")) return error.InvalidInfClient;
        return .{ .object = std.fmt.parseInt(u32, raw[2..], 16) catch return error.InvalidInfClient };
    }
    if (std.mem.indexOfScalar(u8, raw, '(')) |open| {
        if (raw[raw.len - 1] != ')') return error.InvalidInfClient;
        const sector = try findSector(level, raw[0..open]);
        return .{ .sector = sector, .wall = try findWall(level, sector, raw[open + 1 .. raw.len - 1]) };
    }
    return .{ .sector = try findSector(level, raw) };
}

fn objectFlags(flags: *u32, words: *std.mem.TokenIterator(u8, .any), auto: u32) !void {
    if (words.next()) |raw| {
        if (eq(raw, "AUTO")) flags.* |= auto else {
            const bits = try mask(raw);
            flags.* |= bits & 0x90000;
            if (bits & 0x40000 != 0) flags.* |= 0x40000 else flags.* |= bits & 0x20000;
            if (words.next()) |mode| {
                if (!eq(mode, "AUTO")) return error.InvalidInfObjectMode;
                flags.* |= auto;
            }
        }
    } else flags.* |= 0x10000;
}

fn passesObject(flags: u32, required: u32, excluded: u32, object: u32, from_player: bool, inventory: []const u32, require_auto: u32, exclude_auto: u32) bool {
    if (required != 0 and flags & 0x10000 != 0 and object != required and !(from_player and flags & require_auto != 0 and std.mem.indexOfScalar(u32, inventory, required) != null)) return false;
    if (excluded != 0 and (object == excluded or (from_player and flags & exclude_auto != 0 and std.mem.indexOfScalar(u32, inventory, excluded) != null))) return false;
    return true;
}

fn scrollPlane(level: *level_module.Level, sector: usize, ceiling: bool, dx: f32, dz: f32, textures: []const texture.Texture) !void {
    const plane = if (ceiling) &level.sectors[sector].ceiling else &level.sectors[sector].floor;
    if (plane.texture < 0 or plane.texture >= textures.len) return error.InvalidInfScrollTexture;
    const tex = textures[@intCast(plane.texture)];
    if (tex.width == 0 or tex.height == 0) return error.InvalidInfScrollTexture;
    const width: f32 = @floatFromInt(tex.width);
    const height: f32 = @floatFromInt(tex.height);
    const x = plane.offset.x + dx;
    const z = plane.offset.z + dz;
    if (!std.math.isFinite(x) or !std.math.isFinite(z)) return error.InvalidInfTransform;
    plane.offset.x = if (x > width) x - width else if (x < -width) x + width else x;
    plane.offset.z = if (z > height) z - height else if (z < -height) z + height else z;
}

fn scrollWalls(level: *level_module.Level, sector: usize, dx: f32, dz: f32, textures: []const texture.Texture) !void {
    for (level.sectors[sector].walls) |*wall| {
        const surfaces = [_]*level_module.TextureRef{ &wall.top, &wall.mid, &wall.bottom, &wall.overlay };
        for (surfaces, 0..) |surface, i| {
            if (wall.flags & (@as(u32, 0x80) << @as(u5, @intCast(i))) == 0) continue;
            if (surface.texture < 0 or surface.texture >= textures.len) return error.MissingInfScrollTexture;
            const tex = textures[@intCast(surface.texture)];
            const width: f32 = @floatFromInt(tex.width);
            const height: f32 = @floatFromInt(tex.height);
            const x = surface.offset.x + dx;
            const z = surface.offset.z + dz;
            surface.offset.x = if (x > width) x - width else if (x < -width) x + width else x;
            surface.offset.z = if (z > height) z - height else if (z < -height) z + height else z;
        }
    }
}

fn markScrollWalls(level: *const level_module.Level, scene: *scene_module.Scene, sector: usize) void {
    for (level.sectors[sector].walls, scene.sectors[sector].walls) |wall, *state| if (wall.flags & 0x780 != 0) {
        state.runtime_flags |= 1;
    };
}

fn infVersionOne(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "INF") or line.len == 3 or !std.ascii.isWhitespace(line[3])) return false;
    const value = std.mem.trimStart(u8, line[3..], " \t\r\n");
    var end: usize = 0;
    while (end < value.len and (std.ascii.isDigit(value[end]) or std.mem.indexOfScalar(u8, "+-.eE", value[end]) != null)) : (end += 1) {}
    if (end == 0) return false;
    const parsed = std.fmt.parseFloat(f32, value[0..end]) catch return false;
    return @as(u32, @bitCast(parsed)) == 0x3f800000;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn findSector(level: *const level_module.Level, name: []const u8) !usize {
    for (level.sectors, 0..) |sector, i| if (eq(sector.name, name)) return i;
    return error.UnknownInfSector;
}

fn findWall(level: *const level_module.Level, sector: usize, raw: []const u8) !usize {
    if (raw.len == 0) return error.MissingInfWallIndex;
    if (raw[0] == '#') {
        const id = try std.fmt.parseInt(u32, raw[1..], 16);
        for (level.sectors[sector].walls, 0..) |wall, i| if (wall.id == id) return i;
        return error.InvalidInfWallIndex;
    }
    const index = try unsigned(raw);
    if (index >= level.sectors[sector].walls.len) return error.InvalidInfWallIndex;
    return index;
}

fn unsigned(raw: ?[]const u8) !u32 {
    return std.fmt.parseInt(u32, raw orelse return error.MissingInfInteger, 10);
}

fn mask(raw: ?[]const u8) !u32 {
    const value = raw orelse return error.MissingInfMask;
    if (eq(value, "*")) return 0xffffffff;
    return @bitCast(try std.fmt.parseInt(i32, value, 10));
}

fn number(raw: []const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, raw);
    if (!std.math.isFinite(value)) return error.InvalidInfFloat;
    return value;
}

fn milliseconds(raw: []const u8) !i32 {
    const value = try std.fmt.parseFloat(f64, raw);
    if (!std.math.isFinite(value) or value * 1000 >= 2147483648.0 or value * 1000 < -2147483648.0) return error.InvalidInfDelay;
    return @intFromFloat(value * 1000);
}

fn atoi(raw: []const u8) i32 {
    var cursor: usize = 0;
    while (cursor < raw.len and std.ascii.isWhitespace(raw[cursor])) : (cursor += 1) {}
    const negative = cursor < raw.len and raw[cursor] == '-';
    if (cursor < raw.len and (raw[cursor] == '-' or raw[cursor] == '+')) cursor += 1;
    var result: u32 = 0;
    while (cursor < raw.len and std.ascii.isDigit(raw[cursor])) : (cursor += 1)
        result = result *% 10 +% (raw[cursor] - '0');
    return @bitCast(if (negative) 0 -% result else result);
}

fn nearest(value: f32) i32 {
    const lower = @floor(@as(f64, value));
    const fraction = @as(f64, value) - lower;
    const rounded = lower + @as(f64, if (fraction > 0.5 or (fraction == 0.5 and @mod(lower, 2) != 0)) 1 else 0);
    if (!std.math.isFinite(rounded) or rounded < -2147483648.0 or rounded >= 2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(rounded);
}

test "movie trigger blocks before switch and completion mutations" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-movie-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const corpus = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer corpus.deinit();
    var sectors: [22]level_module.Sector = @splat(std.mem.zeroes(level_module.Sector));
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    for (corpus.value.object.get("cases").?.array.items) |case| {
        const flags: u32 = @intCast(case.object.get("flags").?.integer);
        var triggers = [_]Trigger{.{ .target = .{ .sector = 20 }, .flags = flags, .message = .{ .code = 0x7da, .event_mask = 0x2000, .arg1 = 7 }, .movie = "RAM.SAN" }};
        var classes = [_]Class{.{ .trigger = 0 }};
        var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = &.{}, .triggers = &triggers, .classes = &classes };
        defer runtime.deinit();
        var router = Router.init(a);
        defer router.deinit();
        runtime.router = &router;
        try triggers[0].clients.append(runtime.arena.allocator(), .{ .target = .{ .sector = 21 }, .mask = 0x30 });
        var messages = std.array_list.Managed(Message).init(a);
        defer messages.deinit();
        const Capture = struct {
            runtime: *Runtime,
            flags: u32,
            called: usize = 0,

            fn play(raw: *anyopaque, name: []const u8, movie_flags: u32) anyerror!u32 {
                const self: *@This() = @ptrCast(@alignCast(raw));
                try std.testing.expectEqualStrings("RAM.SAN", name);
                try std.testing.expectEqual(@as(u32, 1), movie_flags);
                try std.testing.expectEqual(self.flags, self.runtime.triggers[0].flags);
                try std.testing.expectEqual(@as(usize, 0), self.runtime.router.?.queues[network_message.Queue.server].items.len);
                try std.testing.expectEqual(@as(usize, 1), self.runtime.message_log.?.items.len);
                try std.testing.expectEqual(@as(?usize, 21), self.runtime.message_log.?.items[0].target.sector);
                self.called += 1;
                return 250;
            }
        };
        var capture = Capture{ .runtime = &runtime, .flags = flags };
        runtime.movie_host = .{ .context = &capture, .play = Capture.play };
        try runtime.event(&level, .{ .sector = 20, .mask = 0x20, .now_ms = 100 });
        runtime.message_log = &messages;
        try runtime.flushQueued(&level, null, 101, &.{}, 0xf00000);
        const events = case.object.get("events").?.array.items;
        var movie_count: usize = 0;
        var message_index: usize = 0;
        var complete_count: usize = 0;
        for (events) |expected| {
            const call = expected.object.get("call").?.string;
            if (std.mem.eql(u8, call, "movie")) movie_count += 1 else if (std.mem.eql(u8, call, "complete")) complete_count += 1 else if (std.mem.eql(u8, call, "message")) {
                const actual = messages.items[message_index];
                message_index += 1;
                try std.testing.expectEqual(@as(?usize, if (std.mem.eql(u8, expected.object.get("target").?.string, "owner")) 20 else 21), actual.target.sector);
                try std.testing.expectEqual(@as(u32, @intCast(expected.object.get("code").?.integer)), actual.code);
                try std.testing.expectEqual(@as(u32, @intCast(expected.object.get("event").?.integer)), actual.event_mask);
                try std.testing.expectEqual(@as(i32, @intCast(expected.object.get("arg1").?.integer)), actual.arg1);
            }
        }
        try std.testing.expectEqual(movie_count, capture.called);
        try std.testing.expectEqual(movie_count * 250, runtime.movie_elapsed);
        try std.testing.expectEqual(message_index, messages.items.len);
        try std.testing.expectEqual(complete_count, router.queues[network_message.Queue.server].items.len);
        try std.testing.expectEqual(@as(u32, @intCast(case.object.get("result_flags").?.integer)), triggers[0].flags);
    }
    var trigger: Trigger = .{ .target = .{ .sector = 20 }, .flags = 0x08f00001, .message = .{ .code = 0x7da, .arg1 = 7 } };
    var words = std.mem.tokenizeAny(u8, "TRIGGER_MOVIE ram.san", " \t\r");
    try parseTrigger(a, &level, &trigger, "MESSAGE:", &words);
    defer a.free(trigger.movie.?);
    try std.testing.expectEqualStrings("RAM.SAN", trigger.movie.?);
    try std.testing.expectEqual(@as(u32, 0x7da), trigger.message.code);
    try std.testing.expectEqual(@as(i32, 7), trigger.message.arg1);
}

test "velocity controllers preserve constructor and primary slave arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-velocity-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Fixture = struct {
        results_sha256: []const u8,
        cases: []const struct {
            kind: u32,
            initial_bits: [2][3]u32,
            mode: u32,
            speed_bits: u32,
            value_bits: u32,
            samples: []const struct { delta_bits: u32, result_bits: u32, velocity_bits: [2][3]u32, flags: [2]u32 },
        },
    };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("4f0ff6d01dcc142b2847c6964032cbcbef72efdb4a9048fcc34e027b160a98b8", parsed.value.results_sha256);
    const angles = camera.Angles.init();
    for (parsed.value.cases) |sample| {
        var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)} ** 2;
        sectors[0].name = "PRIMARY";
        sectors[1].name = "SLAVE";
        for (&sectors, sample.initial_bits) |*sector, values| sector.velocity = .{ .x = @bitCast(values[0]), .y = @bitCast(values[1]), .z = @bitCast(values[2]) };
        var level: level_module.Level = undefined;
        level.sectors = &sectors;
        var scene = try scene_module.Scene.init(a, &level, &angles);
        var random: u32 = 0x742389ac;
        const text = try std.fmt.allocPrint(a, "INF 1.0\nITEMS 1\nITEM: SECTOR NAME: PRIMARY\nSEQ\nCLASS: ELEVATOR VELOCITY_{s}\nSLAVE: SLAVE\nSEQEND\n", .{switch (sample.kind) {
            14 => @as([]const u8, "X"),
            15 => "Y",
            16 => "Z",
            else => unreachable,
        }});
        var runtime = try Runtime.loadWithScene(a, &level, text, &random, &scene, &angles);
        const elevator = &runtime.elevators[0];
        try std.testing.expect(scene.sectors[0].velocity_present);
        try std.testing.expectEqual(sample.mode, @as(u32, @bitCast(elevator.mode)));
        try std.testing.expectEqual(sample.speed_bits, @as(u32, @bitCast(elevator.speed)));
        try std.testing.expectEqual(sample.value_bits, @as(u32, @bitCast(elevator.value)));
        for (scene.sectors) |*state| state.runtime_flags = 0;
        var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 0 };
        for (sample.samples) |expected| {
            elevator.speed = @bitCast(expected.delta_bits);
            _ = try runtime.stepElevator(&level, elevator, 1, .{ .world = &world, .random = &random });
            try std.testing.expectEqual(expected.result_bits, @as(u32, @bitCast(elevator.value)));
            for (level.sectors, scene.sectors, expected.velocity_bits, expected.flags) |sector, state, values, flags| {
                try std.testing.expectEqual(values, [3]u32{ @bitCast(sector.velocity.x), @bitCast(sector.velocity.y), @bitCast(sector.velocity.z) });
                try std.testing.expectEqual(flags, state.runtime_flags);
            }
        }
    }
}

test "INF first stops retain the reference absolute restart clock and wrapping deadlines" {
    const a = std.testing.allocator;
    const angles = camera.Angles.init();
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    const cases = .{
        .{ @as(u32, 90000), @as(i32, 250), @as(u32, 90250) },
        .{ @as(u32, 90000), @as(i32, -1), @as(u32, 0xffffffff) },
        .{ @as(u32, 90000), @as(i32, -3), @as(u32, 89997) },
        .{ @as(u32, 0xffffff00), @as(i32, 500), @as(u32, 244) },
    };
    inline for (cases) |sample| {
        var elevator = Elevator{ .sector = 0, .kind = .light, .speed = 1, .value = 0 };
        defer elevator.stops.deinit(a);
        try elevator.stops.append(a, .{ .value = 0, .delay = sample[1] });
        try elevator.stops.append(a, .{ .value = 10, .delay = -1 });
        try finishStartup(a, &level, &elevator, null, &angles, &.{}, sample[0]);
        try std.testing.expectEqual(sample[2], elevator.next_time);
        try std.testing.expectEqual(@as(?usize, 1), elevator.target);
    }
}

test "INF version scanner accepts the reference Dry Gulch typo" {
    try std.testing.expect(infVersionOne("INF 1.0"));
    try std.testing.expect(infVersionOne("INF 1.O"));
    try std.testing.expect(!infVersionOne("INF 1.1"));
    try std.testing.expect(!infVersionOne("INF 2.0"));
}

test "breakable wall triggers and both-sided destruction match sequences" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/breakable-walls-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const TriggerState = struct {
        flags: u32,
        masks: [2]u32,
    };
    const SnapshotState = struct { walls: [2][2]u32, triggers: [2]TriggerState };
    const Frame = struct { target: usize, walls: [2][2]u32, triggers: [2]TriggerState, messages: []const struct { target: []const u8, message: u32, event: u32, arg1: i32, arg2: i32 } };
    const Fixture = struct { results_sha256: []const u8, cases: []const struct { event: u32, entity: u32, initial: SnapshotState, frames: []const Frame } };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("06b98e74dd06fc6c73a6a0066021f39661ba56fdf1ee3dc24d7d570745b236b5", fixture.value.results_sha256);
    for (fixture.value.cases) |sample| {
        var walls = [_]level_module.Wall{std.mem.zeroes(level_module.Wall)} ** 2;
        walls[0].adjoin = 1;
        walls[1].adjoin = 0;
        walls[0].flags = 0x4001;
        walls[1].flags = 0x4001;
        var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)} ** 2;
        var states = [_]scene_module.WallState{std.mem.zeroes(scene_module.WallState)} ** 2;
        var sector_states = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)} ** 2;
        for (0..2) |i| {
            sectors[i].walls = walls[i .. i + 1];
            sector_states[i].walls = states[i .. i + 1];
        }
        var level: level_module.Level = undefined;
        level.sectors = &sectors;
        var scene: scene_module.Scene = undefined;
        scene.sectors = &sector_states;
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;
        var random: u32 = 0x742389ac;
        const angles = camera.Angles.init();
        var runtime = try Runtime.loadWithScene(a, &level, "INF 1.0\nITEMS 0\n", &random, &scene, &angles);
        defer runtime.deinit();
        var router = Router.init(a);
        defer router.deinit();
        runtime.router = &router;
        try std.testing.expectEqual(@as(usize, 2), runtime.triggers.len);
        for (0..2) |i| {
            states[i].flags = sample.initial.walls[i][0];
            states[i].runtime_flags = sample.initial.walls[i][1];
            walls[i].flags = states[i].flags;
            try std.testing.expectEqual(sample.initial.triggers[i].flags, runtime.triggers[i].flags);
            try std.testing.expectEqual(sample.initial.triggers[i].masks, [2]u32{ runtime.triggers[i].event_mask, runtime.triggers[i].entity_mask });
        }
        var log = std.array_list.Managed(Message).init(a);
        defer log.deinit();
        runtime.message_log = &log;
        for (sample.frames) |frame| {
            log.clearRetainingCapacity();
            try runtime.dispatch(&level, &scene, .{ .target = .{ .sector = frame.target, .wall = 0 }, .event_mask = sample.event }, .{ .sector = frame.target, .wall = 0, .mask = sample.event, .entity_mask = sample.entity, .now_ms = 16 }, 0);
            try runtime.flushQueued(&level, &scene, 16, &.{}, 0x200000);
            for (0..2) |i| {
                try std.testing.expectEqual(frame.walls[i], [2]u32{ states[i].flags, states[i].runtime_flags });
                try std.testing.expectEqual(frame.triggers[i].flags, runtime.triggers[i].flags);
                try std.testing.expectEqual(frame.triggers[i].masks, [2]u32{ runtime.triggers[i].event_mask, runtime.triggers[i].entity_mask });
            }
            try std.testing.expectEqual(frame.messages.len, log.items.len);
            for (frame.messages, log.items) |expected, actual| {
                try std.testing.expectEqual(@as(?usize, if (std.mem.eql(u8, expected.target, "wall")) 0 else 1), actual.target.sector);
                try std.testing.expectEqual(expected.message, actual.code);
                try std.testing.expectEqual(expected.event, actual.event_mask);
                try std.testing.expectEqual(expected.arg1, actual.arg1);
                try std.testing.expectEqual(expected.arg2, actual.arg2);
            }
        }
    }
}

test "INF wall and sector bit messages match every flag bit" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/map-flags-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        results_sha256: []const u8,
        cases: []const struct { wall: bool, selector: i32, code: u32, mask: u32, initial: [2]u32, queued: [2]u32, result: [2]u32 },
        integers: []const struct { text: []const u8, result: u32 },
    };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("4bd5a3bf5a8c122be10af39bd3206a9cb7d666edb0d4b566426f14174f24f9c0", parsed.value.results_sha256);
    var walls = [_]level_module.Wall{std.mem.zeroes(level_module.Wall)};
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};
    sectors[0].walls = &walls;
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    var states = [_]scene_module.WallState{std.mem.zeroes(scene_module.WallState)};
    var sector_states = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
    sector_states[0].walls = &states;
    var scene: scene_module.Scene = undefined;
    scene.sectors = &sector_states;
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;
    var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = &.{}, .triggers = &.{}, .classes = &.{} };
    defer runtime.deinit();
    for (parsed.value.cases) |sample| {
        const primary = if (sample.wall) &states[0].flags else &sector_states[0].flags;
        const secondary = if (sample.wall) &states[0].runtime_flags else &sector_states[0].runtime_flags;
        primary.* = sample.initial[0];
        secondary.* = sample.initial[1];
        const text = try std.fmt.allocPrint(a, "{s} {d} {d}", .{ if (sample.code == 0x7df) "SET_BITS" else "CLEAR_BITS", sample.selector, sample.mask });
        defer a.free(text);
        var words = std.mem.tokenizeAny(u8, text, " ");
        var message = try parseMessage(&words);
        message.target = .{ .sector = 0, .wall = if (sample.wall) @as(usize, 0) else null };
        message.event_mask = 0x40000000;
        try runtime.enqueue(message, 0);
        try std.testing.expectEqual(sample.queued, [2]u32{ primary.*, secondary.* });
        try runtime.flushQueued(&level, &scene, 16, &.{}, 0);
        try std.testing.expectEqual(sample.result, [2]u32{ primary.*, secondary.* });
        try std.testing.expectEqual(primary.*, if (sample.wall) walls[0].flags else sectors[0].flags);
    }
    for (parsed.value.integers) |sample| try std.testing.expectEqual(sample.result, @as(u32, @bitCast(atoi(sample.text))));
}

test "INF trigger flag messages join the current FIFO without link filtering" {
    const a = std.testing.allocator;
    var walls = [_]level_module.Wall{std.mem.zeroes(level_module.Wall)};
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};
    sectors[0].name = "FLAGS";
    sectors[0].walls = &walls;
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    var states = [_]scene_module.WallState{std.mem.zeroes(scene_module.WallState)};
    var sector_states = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
    sector_states[0].walls = &states;
    var scene: scene_module.Scene = undefined;
    scene.sectors = &sector_states;
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;
    var random: u32 = 0x742389ac;
    const angles = camera.Angles.init();
    var runtime = try Runtime.loadWithScene(a, &level,
        \\INF 1.0
        \\ITEMS 1
        \\ITEM: SECTOR NAME: FLAGS
        \\SEQ
        \\CLASS: TRIGGER STANDARD
        \\CLIENT: FLAGS(0)
        \\MESSAGE: SET_BITS 1 32768
        \\SEQEND
    , &random, &scene, &angles);
    defer runtime.deinit();
    try runtime.event(&level, .{ .sector = 0, .mask = 0x10, .now_ms = 10 });
    try std.testing.expectEqual(@as(u32, 0), states[0].flags);
    try runtime.flushQueued(&level, &scene, 11, &.{}, 0x200000);
    try std.testing.expectEqual(@as(u32, 0x8000), states[0].flags);
    try std.testing.expectEqual(@as(u32, 4), states[0].runtime_flags);
    try std.testing.expectEqual(@as(usize, 0), runtime.pending.items.len);
}

test "INF reference FIFO drain and shared task wake phases" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-routing-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const State = struct {
        value_bits: u32,
        next_time: u32,
        target: usize,
        flags: u32,
    };
    const Fixture = struct { samples: []struct { now: u32, phase: []const u8, task_time: u32, queued: usize, trigger_flags: u32, elevators: struct { TOOLSEC: State, AWINDOW: State, AHEAD: State }, messages: []struct { target: []const u8, message: u32, event: u32, arg1: i32, arg2: i32 } } };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const names = [_][]const u8{ "TOOLSEC", "AWINDOW", "AHEAD", "AWINTRIG" };
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)} ** 4;
    for (&sectors, names, [_]f32{ 0.125, -38.6, 0, 0 }) |*sector, name, ceiling| {
        sector.name = name;
        sector.ceiling.height = ceiling;
    }
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = undefined, .triggers = undefined, .classes = undefined };
    defer runtime.deinit();
    const mem = runtime.arena.allocator();
    runtime.elevators = try mem.alloc(Elevator, 3);
    const stops = [_][]const Stop{
        &.{ .{ .value = 0.125, .delay = -1 }, .{ .value = 4, .delay = -1 } },
        &.{ .{ .value = -38.6, .delay = -1 }, .{ .value = -35, .delay = 1000 }, .{ .value = -35, .delay = -1 } },
        &.{ .{ .value = 0, .delay = -1 }, .{ .value = 1, .delay = 5000 }, .{ .value = 32, .delay = 1000 }, .{ .value = 32, .delay = 0 }, .{ .value = 33, .delay = -1 } },
    };
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 0 };
    for (runtime.elevators, 0..) |*elevator, i| {
        elevator.* = try construct(&level, i, if (i == 2) "SCROLL_WALL" else "MOVE_CEILING");
        elevator.speed = if (i == 0) 20 else 60;
        elevator.event_mask = if (i == 0) 0x30 else 0;
        try elevator.stops.appendSlice(mem, stops[i]);
        try finishStartup(a, &level, elevator, null, &angles, &.{}, 0);
    }
    try runtime.elevators[1].stops.items[1].messages.append(mem, .{ .target = .{ .sector = 2 }, .code = 0x7d7 });
    try runtime.elevators[2].stops.items[3].messages.append(mem, .{ .target = .{ .sector = 1 }, .code = 0x7da });
    const direction = angles.sinCos(4096);
    runtime.elevators[2].vector = .{ .x = direction.sin, .z = direction.cos };
    runtime.triggers = try mem.dupe(Trigger, &.{.{ .target = .{ .sector = 3 }, .flags = 0x40f00001, .event_mask = 0x30, .entity_mask = 0x10, .message = .{ .code = 0x7da, .arg1 = 1 } }});
    try runtime.triggers[0].clients.append(mem, .{ .target = .{ .sector = 1 }, .mask = 0xffffffff });
    runtime.classes = try mem.dupe(Class, &.{ .{ .elevator = 0 }, .{ .elevator = 1 }, .{ .elevator = 2 }, .{ .trigger = 0 } });
    var log = std.array_list.Managed(Message).init(a);
    defer log.deinit();
    runtime.message_log = &log;
    var previous: u32 = 0;
    var random: u32 = 0x742389ac;
    for (parsed.value.samples) |sample| {
        if (eq(sample.phase, "drain")) {
            log.clearRetainingCapacity();
            try runtime.flushQueued(&level, null, sample.now, &.{}, 0x200000);
        } else if (eq(sample.phase, "activate")) {
            try runtime.event(&level, .{ .sector = 0, .mask = 0x10, .from_player = false, .now_ms = sample.now });
            try runtime.event(&level, .{ .sector = 3, .mask = 0x10, .from_player = false, .now_ms = sample.now });
        } else if (eq(sample.phase, "task")) {
            const seconds: f32 = @floatCast(@min(@as(f64, @floatFromInt(sample.now - previous)) * 0.001, 0.25));
            try runtime.advance(&level, sample.now, seconds, .{ .random = &random, .world = &world });
            previous = sample.now;
        } else try std.testing.expect(eq(sample.phase, "initial"));
        errdefer std.debug.print("INF router phase {s} time {d}\n", .{ sample.phase, sample.now });
        try std.testing.expectEqual(sample.task_time, runtime.task_time);
        try std.testing.expectEqual(sample.queued, runtime.pending.items.len);
        try std.testing.expectEqual(sample.trigger_flags, runtime.triggers[0].flags);
        for ([_]State{ sample.elevators.TOOLSEC, sample.elevators.AWINDOW, sample.elevators.AHEAD }, runtime.elevators) |expected, actual| {
            try std.testing.expectEqual(expected.value_bits, @as(u32, @bitCast(actual.value)));
            try std.testing.expectEqual(expected.next_time, actual.next_time);
            try std.testing.expectEqual(expected.target, actual.target.?);
            try std.testing.expectEqual(expected.flags, actual.runtime_flags);
        }
        try std.testing.expectEqual(sample.messages.len, log.items.len);
        for (sample.messages, log.items) |expected, actual| {
            try std.testing.expectEqualStrings(expected.target, names[actual.target.sector.?]);
            try std.testing.expectEqual(expected.message, actual.code);
            try std.testing.expectEqual(expected.event, actual.event_mask);
            try std.testing.expectEqual(expected.arg1, actual.arg1);
            try std.testing.expectEqual(expected.arg2, actual.arg2);
        }
    }
}

test "INF reference selected item success and failure requests" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-inventory-use-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Owned = struct {
        slot: usize,
        use_id: u32,
        success_sound: ?[]const u8,
        failure_sound: ?[]const u8,
    };
    const Fixture = struct { cases: []struct {
        inventory: []Owned,
        required: u32,
        excluded: u32,
        extra_flags: u32,
        arg1_nonzero: bool,
        object_id: u32,
        next_time: u32,
        runtime_flags: u32,
        flags: u32,
        audio: []struct { sound: []const u8, actor: u32, arg3: u8, arg4: u8, flags: u32 },
    } };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    for (parsed.value.cases) |sample| {
        var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = undefined, .triggers = &.{}, .classes = &.{} };
        defer runtime.deinit();
        const mem = runtime.arena.allocator();
        runtime.elevators = try mem.dupe(Elevator, &.{.{ .sector = 0, .kind = .light, .mode = 0, .object_id = sample.required, .excluded_object = sample.excluded, .speed = 1, .value = 0, .target = 0, .next_time = 0xffffffff, .flags = 0xf00000 | sample.extra_flags }});
        const elevator = &runtime.elevators[0];
        try elevator.stops.append(mem, .{ .value = 10, .delay = -1 });
        var inventory: [25]u32 = undefined;
        var count: usize = 0;
        for (1..26) |slot| for (sample.inventory) |owned| if (owned.slot == slot) {
            inventory[count] = owned.use_id;
            count += 1;
        };
        try runtime.elevatorMessage(&level, elevator, .{ .code = 0x7d6, .arg1 = if (sample.arg1_nonzero) 1 else 0, .arg2 = @bitCast(sample.object_id) }, .{ .sector = 0, .mask = 0x10, .now_ms = 1000, .inventory_ids = inventory[0..count] });
        try std.testing.expectEqual(sample.next_time, elevator.next_time);
        try std.testing.expectEqual(sample.runtime_flags, elevator.runtime_flags);
        try std.testing.expectEqual(sample.flags, elevator.flags);
        var observed: usize = 0;
        for (runtime.effects.items) |effect| {
            const request = effect.inventory_use;
            try std.testing.expectEqual(sample.object_id, request.object_id);
            try std.testing.expect(sample.arg1_nonzero);
            const owned = found: for (1..26) |slot| {
                for (sample.inventory) |entry| if (entry.slot == slot and entry.use_id == request.object_id) break :found entry;
            } else return error.MissingInfUseInventory;
            const name = (if (request.success) owned.success_sound else owned.failure_sound) orelse continue;
            try std.testing.expect(observed < sample.audio.len);
            const expected = sample.audio[observed];
            observed += 1;
            try std.testing.expectEqualStrings(expected.sound, name);
            try std.testing.expectEqual(@as(u32, 0), expected.actor);
            try std.testing.expectEqual(@as(u8, 64), expected.arg3);
            try std.testing.expectEqual(@as(u8, 127), expected.arg4);
            try std.testing.expectEqual(@as(u32, 4), expected.flags);
        }
        try std.testing.expectEqual(sample.audio.len, observed);
    }
}

test "INF reference scalar stepping and ordered scheduler states" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-reference.json", a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Input = struct {
        kind: u32 = 8,
        current: f32 = 0,
        stops: [][2]f64,
        speed: f32,
        step: u32 = 0,
        seed: u32 = 0x742389ac,
        minimum: f32 = 0,
        maximum: f32 = 31,
        slave_value: f32 = 5,
        next_time: u32 = 0,
        flags: u32 = 2,
        mode: i32 = 0,
    };
    const State = struct { value_bits: u32, next_time: u32, flags: u32, target: ?usize, random: u32, ambient: [2]i32, ceiling_bits: [2]u32, sector_flags: [2]u32 };
    const Fixture = struct {
        stepping: []struct { input: Input, seconds_bits: u32, control: u32, result: u32, value_bits: u32, next_time: u32, flags: u32, target: ?usize, random: u32, ambient: [2]i32, ceiling_bits: [2]u32, sector_flags: [2]u32 },
        sequences: []struct { input: Input, control: u32, samples: []struct { event: struct { now: u32, seconds: ?f32 = null, message: ?u32 = null, arg1: i32 = 0, arg2: i32 = 0 }, result: ?u32, value_bits: u32, next_time: u32, flags: u32, target: ?usize, random: u32, ambient: [2]i32, ceiling_bits: [2]u32, sector_flags: [2]u32 } },
    };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const Helpers = struct {
        fn make(level: *level_module.Level, input: Input) !Runtime {
            var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .elevators = undefined, .triggers = &.{}, .classes = undefined };
            errdefer runtime.deinit();
            const mem = runtime.arena.allocator();
            runtime.elevators = try mem.alloc(Elevator, 1);
            runtime.classes = try mem.dupe(Class, &.{.{ .elevator = 0 }});
            const e = &runtime.elevators[0];
            e.* = .{ .sector = 0, .kind = @enumFromInt(input.kind), .mode = input.mode, .speed = input.speed, .value = input.current, .step = input.step != 0, .next_time = input.next_time, .runtime_flags = input.flags, .vector = .{ .x = input.minimum, .z = input.maximum }, .target = if (input.stops.len == 0) null else 0 };
            for (input.stops) |stop| try e.stops.append(mem, .{ .value = @floatCast(stop[0]), .delay = @intFromFloat(stop[1]) });
            try e.slaves.append(mem, .{ .sector = 1 });
            for (level.sectors, [_]f32{ input.current, input.slave_value }) |*sector, value| {
                sector.* = std.mem.zeroes(level_module.Sector);
                sector.ambient = if (input.kind == 8) nearest(value) else 0;
                sector.ceiling.height = if (input.kind == 0) value else -40;
            }
            return runtime;
        }

        fn check(level: *level_module.Level, runtime: *Runtime, random: u32, expected: State) !void {
            const e = runtime.elevators[0];
            try std.testing.expectEqual(expected.value_bits, @as(u32, @bitCast(e.value)));
            try std.testing.expectEqual(expected.next_time, e.next_time);
            try std.testing.expectEqual(expected.flags, e.runtime_flags);
            try std.testing.expectEqual(expected.target, e.target);
            try std.testing.expectEqual(expected.random, random);
            for (level.sectors, 0..) |sector, i| {
                try std.testing.expectEqual(expected.ambient[i], sector.ambient);
                try std.testing.expectEqual(expected.ceiling_bits[i], @as(u32, @bitCast(sector.ceiling.height)));
            }
        }
    };
    var sectors: [2]level_module.Sector = undefined;
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    const angles = camera.Angles.init();
    for (parsed.value.stepping) |sample| {
        if (sample.control != 0x027f) continue;
        var runtime = try Helpers.make(&level, sample.input);
        defer runtime.deinit();
        var scene = try scene_module.Scene.init(a, &level, &angles);
        defer scene.deinit();
        var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 0 };
        var random = sample.input.seed;
        const reached = try runtime.stepElevator(&level, &runtime.elevators[0], @bitCast(sample.seconds_bits), .{ .random = &random, .world = &world });
        try std.testing.expectEqual(sample.result != 0, reached);
        try Helpers.check(&level, &runtime, random, .{ .value_bits = sample.value_bits, .next_time = sample.next_time, .flags = sample.flags, .target = sample.target, .random = sample.random, .ambient = sample.ambient, .ceiling_bits = sample.ceiling_bits, .sector_flags = sample.sector_flags });
    }
    for (parsed.value.sequences) |sequence| {
        if (sequence.control != 0x027f) continue;
        var runtime = try Helpers.make(&level, sequence.input);
        defer runtime.deinit();
        var scene = try scene_module.Scene.init(a, &level, &angles);
        defer scene.deinit();
        var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 0 };
        var random = sequence.input.seed;
        for (sequence.samples) |sample| {
            if (sample.event.message) |code| {
                try runtime.elevatorMessage(&level, &runtime.elevators[0], .{ .code = code, .arg1 = sample.event.arg1, .arg2 = sample.event.arg2 }, .{ .sector = 0, .mask = 0, .now_ms = sample.event.now });
            } else {
                try runtime.runTask(&level, sample.event.now, sample.event.seconds.?, .{ .random = &random, .world = &world });
                try std.testing.expectEqual(sample.result.?, runtime.task_time -% sample.event.now);
            }
            try Helpers.check(&level, &runtime, random, .{ .value_bits = sample.value_bits, .next_time = sample.next_time, .flags = sample.flags, .target = sample.target, .random = sample.random, .ambient = sample.ambient, .ceiling_bits = sample.ceiling_bits, .sector_flags = sample.sector_flags });
        }
    }
}

test "INF reference trigger filtering and one-shot state" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-reference.json", a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        triggers: []struct {
            flags: u32,
            required: u32,
            excluded: u32,
            samples: []struct { event: struct { message: u32, mask: u32 = 0, object_id: u32 = 0 }, flags: u32, messages: []struct { target: []const u8, message: u32, event: u32, arg1: i32, arg2: i32 } },
        },
    };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)} ** 4;
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    var log = std.array_list.Managed(Message).init(a);
    defer log.deinit();
    for (parsed.value.triggers) |sequence| {
        var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = &.{}, .triggers = &.{}, .classes = &.{}, .message_log = &log };
        defer runtime.deinit();
        var trigger = Trigger{ .target = .{ .sector = 3, .wall = 0 }, .flags = sequence.flags, .object_id = sequence.required, .excluded_object = sequence.excluded, .message = .{ .code = 0x7da, .event_mask = 0x2000, .arg1 = 1 } };
        for ([_]u32{ 0x10, 0x20, 0xffffffff }, 0..) |client_mask, i| try trigger.clients.append(runtime.arena.allocator(), .{ .target = .{ .sector = i }, .mask = client_mask });
        for (sequence.samples) |sample| {
            log.clearRetainingCapacity();
            try runtime.triggerMessage(&level, null, &trigger, .{ .code = sample.event.message, .event_mask = sample.event.mask, .arg2 = @bitCast(sample.event.object_id) }, .{ .sector = 3, .wall = 0, .mask = sample.event.mask, .now_ms = 1 }, 0);
            try std.testing.expectEqual(sample.flags, trigger.flags);
            try std.testing.expectEqual(sample.messages.len, log.items.len);
            for (sample.messages, log.items) |expected, actual| {
                const expected_target: usize = if (std.mem.eql(u8, expected.target, "owner")) 3 else try std.fmt.parseInt(usize, expected.target[6..], 10);
                try std.testing.expectEqual(expected_target, actual.target.sector.?);
                try std.testing.expectEqual(expected.message, actual.code);
                try std.testing.expectEqual(expected.event, actual.event_mask);
                try std.testing.expectEqual(expected.arg1, actual.arg1);
                try std.testing.expectEqual(expected.arg2, actual.arg2);
            }
        }
    }
}

test "Hideout INF constructors, filtered activation and held ceiling movement" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(bytes);
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    defer level.deinit();
    var runtime = try Runtime.load(a, &level, try archive.find("HIDEOUT.INF", 0));
    defer runtime.deinit();
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 0 };
    try std.testing.expectEqual(@as(usize, 32), runtime.elevators.len);
    try std.testing.expectEqual(@as(usize, 5), runtime.triggers.len);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (level.sectors) |sector| {
        var values: [12]u8 = undefined;
        std.mem.writeInt(u32, values[0..4], @bitCast(sector.ceiling.height), .little);
        std.mem.writeInt(u32, values[4..8], @bitCast(sector.floor.height), .little);
        std.mem.writeInt(i32, values[8..12], sector.ambient, .little);
        hash.update(&values);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqualStrings("c3b3e0cdc4fa5483b6d354243df149d2565e3afe98ecba792006daf13d3459c3", &std.fmt.bytesToHex(digest, .lower));
    const sector = try findSector(&level, "C1");
    try runtime.event(&level, .{ .sector = sector, .mask = 0x10, .now_ms = 10 });
    try runtime.flushQueued(&level, null, 10, &.{}, 0x200000);
    try std.testing.expectEqual(@as(usize, 0), runtime.effects.items.len);
    try runtime.event(&level, .{ .sector = sector, .mask = 0x20, .now_ms = 10 });
    var random: u32 = 0x742389ac;
    try runtime.advance(&level, 10, 0.25, .{ .random = &random, .world = &world });
    try std.testing.expectEqual(@as(f32, 17.1), level.sectors[sector].ceiling.height);
    try runtime.flushQueued(&level, null, 11, &.{}, 0x200000);
    try runtime.advance(&level, 11, 0.25, .{ .random = &random, .world = &world });
    try std.testing.expectEqual(@as(f32, 17.1), level.sectors[sector].ceiling.height);
    try runtime.advance(&level, 12, 0.25, .{ .random = &random, .world = &world });
    try std.testing.expectEqual(@as(f32, 18.85), level.sectors[sector].ceiling.height);
    try runtime.advance(&level, 13, 0.25, .{ .random = &random, .world = &world });
    try std.testing.expectEqual(@as(f32, 20), level.sectors[sector].ceiling.height);
    try std.testing.expectEqual(@as(u32, 0x742389ac), random);
}

test "INF reference automatic door constructors" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-constructors-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        doors: []struct { sector: usize, kind: u32, mode: i32, speed_bits: u32, value_bits: u32, center_bits: [2]u32, flags: u32, runtime_flags: u32, next_time: u32, stops: []struct { value_bits: u32, delay: i32 }, sounds: [3]?[]const u8, event_mask: u32, entity_mask: u32, random: u32 },
        walls: []struct { sector: usize, wall: usize, flags: u32, runtime_flags: u32 },
    };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(32 * 1024 * 1024));
    defer a.free(data);
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    defer level.deinit();
    var random: u32 = 0x742389ac;
    var runtime = try Runtime.loadWithRandom(a, &level, "INF 1.0\nITEMS 0\n", &random);
    defer runtime.deinit();
    try std.testing.expectEqual(parsed.value.doors.len, runtime.elevators.len);
    try std.testing.expectEqual(parsed.value.doors[parsed.value.doors.len - 1].random, random);
    for (parsed.value.doors, runtime.elevators) |expected, actual| {
        try std.testing.expectEqual(expected.sector, actual.sector);
        try std.testing.expectEqual(expected.kind, @intFromEnum(actual.kind));
        try std.testing.expectEqual(expected.mode, actual.mode);
        try std.testing.expectEqual(expected.speed_bits, @as(u32, @bitCast(actual.speed)));
        try std.testing.expectEqual(expected.value_bits, @as(u32, @bitCast(actual.value)));
        try std.testing.expectEqual(expected.center_bits, [2]u32{ @bitCast(actual.vector.x), @bitCast(actual.vector.z) });
        try std.testing.expectEqual(expected.flags, actual.flags);
        try std.testing.expectEqual(expected.runtime_flags, actual.runtime_flags);
        try std.testing.expectEqual(expected.next_time, actual.next_time);
        try std.testing.expectEqual(expected.event_mask, actual.event_mask);
        try std.testing.expectEqual(expected.entity_mask, actual.entity_mask);
        try std.testing.expectEqual(expected.stops.len, actual.stops.items.len);
        for (expected.stops, actual.stops.items) |stop, found| {
            try std.testing.expectEqual(stop.value_bits, @as(u32, @bitCast(found.value)));
            try std.testing.expectEqual(stop.delay, found.delay);
        }
        for (expected.sounds, actual.sounds) |sound, found| {
            if (sound) |name| try std.testing.expect(found != null and eq(name, found.?)) else try std.testing.expect(found == null);
        }
    }
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    runtime.applyScene(&level, &scene);
    for (parsed.value.walls) |expected| {
        try std.testing.expectEqual(expected.flags, level.sectors[expected.sector].walls[expected.wall].flags);
        try std.testing.expectEqual(expected.runtime_flags, scene.sectors[expected.sector].walls[expected.wall].runtime_flags & 0x04000004);
    }
}

test "INF reference AHEAD pixel scrolling and single wrap" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-scroll-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Wall = struct {
        index: usize,
        flags: u32,
        runtime_flags: u32,
        surfaces: []struct { dimensions: ?[2]usize, offset_bits: [2]u32 },
    };
    const Fixture = struct { sector: usize, direction_bits: [2]u32, initial: struct { value_bits: u32, walls: []Wall }, samples: []struct { delta_bits: u32, result_bits: u32, value_bits: u32, walls: []Wall } };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(32 * 1024 * 1024));
    defer a.free(data);
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    defer level.deinit();
    var runtime = try Runtime.load(a, &level, try archive.find("HIDEOUT.INF", 0));
    defer runtime.deinit();
    const index = for (runtime.elevators, 0..) |elevator, i| {
        if (elevator.kind == .scroll_wall and elevator.sector == parsed.value.sector) break i;
    } else return error.MissingInfScrollElevator;
    const elevator = &runtime.elevators[index];
    try std.testing.expectEqual(parsed.value.direction_bits, [2]u32{ @bitCast(elevator.vector.x), @bitCast(elevator.vector.z) });
    const texture_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLTEX.LAB", a, .limited(64 * 1024 * 1024));
    defer a.free(texture_data);
    const texture_archive = try @import("../assets/lab.zig").Archive.init(texture_data);
    const textures = try a.alloc(texture.Texture, level.textures.len);
    defer a.free(textures);
    const loaded = try a.alloc(bool, textures.len);
    defer a.free(loaded);
    @memset(loaded, false);
    defer for (loaded, textures) |present, tex| if (present) tex.deinit(a);
    for (level.sectors[elevator.sector].walls) |wall| {
        for ([_]level_module.TextureRef{ wall.top, wall.mid, wall.bottom, wall.overlay }) |surface| {
            if (surface.texture < 0) continue;
            const texture_index: usize = @intCast(surface.texture);
            if (loaded[texture_index]) continue;
            textures[texture_index] = try texture.loadInitial(a, texture_archive, level.textures[texture_index]);
            loaded[texture_index] = true;
        }
    }
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 0 };
    const Check = struct {
        fn walls(l: *const level_module.Level, sc: *const scene_module.Scene, tex: []const texture.Texture, sector: usize, expected: []const Wall) !void {
            for (expected) |wall| {
                const actual = l.sectors[sector].walls[wall.index];
                try std.testing.expectEqual(wall.flags, actual.flags);
                try std.testing.expectEqual(wall.runtime_flags, sc.sectors[sector].walls[wall.index].runtime_flags);
                for (wall.surfaces, [_]level_module.TextureRef{ actual.top, actual.mid, actual.bottom, actual.overlay }) |surface, found| {
                    try std.testing.expectEqual(surface.offset_bits, [2]u32{ @bitCast(found.offset.x), @bitCast(found.offset.z) });
                    if (surface.dimensions) |dimensions| {
                        const texture_index: usize = @intCast(found.texture);
                        try std.testing.expectEqual(dimensions, [2]usize{ tex[texture_index].width, tex[texture_index].height });
                    } else try std.testing.expect(found.texture < 0);
                }
            }
        }
    };
    for (parsed.value.initial.walls) |wall| scene.sectors[elevator.sector].walls[wall.index].runtime_flags = wall.runtime_flags;
    try Check.walls(&level, &scene, textures, elevator.sector, parsed.value.initial.walls);
    try std.testing.expectEqual(parsed.value.initial.value_bits, @as(u32, @bitCast(elevator.value)));
    elevator.target = null;
    elevator.speed = 1;
    var random: u32 = 0x742389ac;
    for (parsed.value.samples) |sample| {
        _ = try runtime.stepElevator(&level, elevator, @bitCast(sample.delta_bits), .{ .random = &random, .textures = textures, .world = &world });
        try std.testing.expectEqual(sample.result_bits, @as(u32, @bitCast(elevator.value)));
        try std.testing.expectEqual(sample.value_bits, @as(u32, @bitCast(elevator.value)));
        try Check.walls(&level, &scene, textures, elevator.sector, sample.walls);
    }
}

test "INF reference Train floor and ceiling scrolling" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-scroll-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Sector = struct {
        dimensions: [2]usize,
        offset_bits: [2]u32,
        runtime_flags: u32,
    };
    const Sample = struct { delta_bits: u32, result_bits: u32, value_bits: u32, sectors: []Sector };
    const Fixture = struct { planes: []struct { kind: u32, angle: i16, direction_bits: [2]u32, initial: struct { value_bits: u32, sectors: []Sector }, samples: []Sample } };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const angles = camera.Angles.init();
    for (parsed.value.planes) |sample_case| {
        var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)} ** 2;
        var states = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)} ** 2;
        var textures: [2]texture.Texture = undefined;
        const ceiling = sample_case.kind == 7;
        for (sample_case.initial.sectors, 0..) |initial, i| {
            const plane = if (ceiling) &sectors[i].ceiling else &sectors[i].floor;
            plane.texture = @intCast(i);
            plane.offset = .{ .x = @bitCast(initial.offset_bits[0]), .z = @bitCast(initial.offset_bits[1]) };
            states[i].runtime_flags = initial.runtime_flags;
            textures[i] = .{ .width = initial.dimensions[0], .height = initial.dimensions[1], .pixels = &.{}, .height_shift = 0, .flags = 0 };
        }
        var level: level_module.Level = undefined;
        level.sectors = &sectors;
        var scene: scene_module.Scene = undefined;
        scene.sectors = &states;
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;
        var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 0 };
        var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = &.{}, .triggers = &.{}, .classes = &.{} };
        defer runtime.deinit();
        var elevator = try construct(&level, 0, if (ceiling) "SCROLL_CEILING" else "SCROLL_FLOOR");
        const direction = angles.sinCos(sample_case.angle);
        try std.testing.expectEqual(sample_case.direction_bits, [2]u32{ @bitCast(direction.sin), @bitCast(direction.cos) });
        elevator.vector = .{ .x = direction.sin, .z = direction.cos };
        elevator.speed = 1;
        try elevator.slaves.append(runtime.arena.allocator(), .{ .sector = 1 });
        var random: u32 = 0x742389ac;
        for (sample_case.samples) |sample| {
            _ = try runtime.stepElevator(&level, &elevator, @bitCast(sample.delta_bits), .{ .random = &random, .textures = &textures, .world = &world });
            try std.testing.expectEqual(sample.result_bits, @as(u32, @bitCast(elevator.value)));
            try std.testing.expectEqual(sample.value_bits, @as(u32, @bitCast(elevator.value)));
            for (sample.sectors, 0..) |expected, i| {
                const plane = if (ceiling) sectors[i].ceiling else sectors[i].floor;
                try std.testing.expectEqual(expected.offset_bits, [2]u32{ @bitCast(plane.offset.x), @bitCast(plane.offset.z) });
                try std.testing.expectEqual(expected.runtime_flags, states[i].runtime_flags);
                const untouched = if (ceiling) sectors[i].floor else sectors[i].ceiling;
                try std.testing.expectEqual(@as(f32, 0), untouched.offset.x);
                try std.testing.expectEqual(@as(f32, 0), untouched.offset.z);
            }
        }
    }
}

test "INF local router phases preserve Hideout chains and delivery inventory" {
    const a = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(data);
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    defer level.deinit();
    var runtime = try Runtime.load(a, &level, try archive.find("HIDEOUT.INF", 0));
    defer runtime.deinit();
    var router = Router.init(a);
    defer router.deinit();
    router.reset();
    runtime.router = &router;
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 0 };
    const window = try findSector(&level, "AWINDOW");
    const ahead = try findSector(&level, "AHEAD");
    const trigger = try findSector(&level, "AWINTRIG");
    const wall = try findWall(&level, trigger, "#31815");
    const window_index = for (runtime.elevators, 0..) |elevator, i| {
        if (elevator.sector == window) break i;
    } else unreachable;
    const ahead_index = for (runtime.elevators, 0..) |elevator, i| {
        if (elevator.sector == ahead) break i;
    } else unreachable;
    const initial = try runtime.checkpoint(a);
    defer initial.deinit(a);
    try runtime.event(&level, .{ .sector = trigger, .wall = wall, .mask = 0x10, .now_ms = 10 });
    try runtime.enqueue(.{ .target = .{ .sector = window }, .code = 0x7de }, 0xffffffff);
    try runtime.flushQueued(&level, null, 11, &.{}, 0x200000);
    try std.testing.expectEqual(@as(u32, 0), runtime.elevators[window_index].runtime_flags);
    try std.testing.expectEqual(@as(u32, 0xffffffff), runtime.elevators[window_index].next_time);
    try std.testing.expectEqual(@as(usize, 0), runtime.pending.items.len);
    runtime.restore(initial);
    try runtime.event(&level, .{ .sector = trigger, .wall = wall, .mask = 0x10, .now_ms = 20 });
    try runtime.flushQueued(&level, null, 21, &.{}, 0x200000);
    try std.testing.expectEqual(@as(u32, 21), runtime.elevators[window_index].next_time);
    try std.testing.expectEqual(@as(u32, 21), runtime.task_time);
    var random: u32 = 0x742389ac;
    try runtime.advance(&level, 21, 0.1, .{ .random = &random, .world = &world });
    try std.testing.expectEqual(@as(f32, -38.6), level.sectors[window].ceiling.height);
    try runtime.advance(&level, 22, 0.1, .{ .random = &random, .world = &world });
    try std.testing.expectEqual(@as(f32, -35), level.sectors[window].ceiling.height);
    try std.testing.expectEqual(@as(u32, 0xffffffff), runtime.elevators[ahead_index].next_time);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending.items.len);
    try std.testing.expectEqual(ahead, runtime.pending.items[0].message.value.target.sector.?);
    try runtime.flushQueued(&level, null, 23, &.{}, 0x200000);
    try std.testing.expectEqual(@as(u32, 23), runtime.elevators[ahead_index].next_time);
    try runtime.advance(&level, 23, 0.1, .{ .random = &random, .world = &world });
    try std.testing.expectEqual(@as(f32, 0), runtime.elevators[ahead_index].value);
    runtime.restore(initial);
    const brass = try findSector(&level, "MHBRASS");
    try runtime.event(&level, .{ .sector = brass, .mask = 0x10, .now_ms = 30, .inventory_ids = &.{101} });
    const queued = try runtime.checkpoint(a);
    defer queued.deinit(a);
    try runtime.flushQueued(&level, null, 31, &.{}, 0x200000);
    try std.testing.expectEqual(@as(usize, 0), runtime.effects.items.len);
    const system = (try router.read(network_message.Queue.server)).?;
    try std.testing.expectEqual(@as(usize, network_message.words_size), system.len);
    try std.testing.expectEqual(@as(u32, 0x100800), network_message.get(system, network_message.destination_offset));
    try std.testing.expectEqual(@as(u32, 0x80800), network_message.get(system, network_message.sender_offset));
    try std.testing.expectEqual(@as(u32, 0x100800), network_message.get(system, network_message.reply_offset));
    try std.testing.expectEqual(@as(u32, 801), network_message.get(system, network_message.word_offsets[1]));
    router.release(system);
    try std.testing.expectEqual(@as(?[]u8, null), try router.read(network_message.Queue.server));
    runtime.restore(queued);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending.items.len);
    try runtime.flushQueued(&level, null, 33, &.{101}, 0x200000);
    try std.testing.expectEqual(@as(?[]u8, null), try router.read(network_message.Queue.server));
    runtime.effects.clearRetainingCapacity();
    try runtime.pending.append(runtime.arena.allocator(), .{ .actor_impulse = .{ .contact = .{ .wall = .{ .sector = brass, .index = 0 }, .actor = null }, .velocity = .{ .x = 1, .y = 0, .z = -1 } } });
    const impulse = try runtime.checkpoint(a);
    defer impulse.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), runtime.effects.items.len);
    try runtime.flushQueued(&level, null, 34, &.{}, 0x200000);
    try std.testing.expectEqual(@as(usize, 1), runtime.effects.items.len);
    try std.testing.expect(runtime.effects.items[0] == .actor_impulse);
    runtime.restore(impulse);
    try std.testing.expectEqual(@as(usize, 1), runtime.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.effects.items.len);
}

test "Train initial sliding doors and queued END_LEVEL match startup" {
    const a = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(data);
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_module.Level.parse(a, try archive.find("TRAIN.LVB", 0));
    defer level.deinit();
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    var random: u32 = 0x742389ac;
    var runtime = try Runtime.loadWithScene(a, &level, try archive.find("TRAIN.INF", 0), &random, &scene, &angles);
    defer runtime.deinit();
    runtime.applyScene(&level, &scene);
    var router = Router.init(a);
    defer router.deinit();
    router.reset();
    runtime.router = &router;

    const names = [_][]const u8{ "SDOOR01", "SDOOR05", "SDOOR06", "SDOOR11", "SDOOR17" };
    for (names) |name| {
        const index = try findSector(&level, name);
        const elevator = for (runtime.elevators) |e| {
            if (e.sector == index and e.kind == .morph_move) break e;
        } else return error.MissingTrainSlidingDoor;
        try std.testing.expectEqual(@as(f32, 6.25), elevator.value);
        try std.testing.expectEqual(@as(u32, 0xffffffff), elevator.next_time);
        try std.testing.expectEqual(@as(?usize, 1), elevator.target);
    }

    const finish = for (runtime.triggers) |*trigger| {
        if (trigger.flags & 2 != 0) break trigger;
    } else return error.MissingTrainEndTrigger;
    try std.testing.expectEqual(@as(u32, 0x7d6), finish.message.code);
    const event_value = Event{ .sector = finish.target.sector.?, .wall = finish.target.wall, .mask = finish.event_mask, .now_ms = 10 };
    finish.flags &= ~@as(u32, 1);
    try runtime.event(&level, event_value);
    try runtime.flushQueued(&level, null, 10, &.{}, 0x200000);
    finish.flags |= 1;
    try runtime.event(&level, event_value);
    try runtime.flushQueued(&level, null, 11, &.{}, 0x200000);
    const trigger = (try router.read(network_message.Queue.server)).?;
    try std.testing.expectEqual(@as(u32, 0x7d6), network_message.get(trigger, network_message.number_offset));
    try std.testing.expectEqual(@as(usize, network_message.words_size), trigger.len);
    router.release(trigger);
    const end_level = (try router.read(network_message.Queue.server)).?;
    try std.testing.expectEqual(@as(u32, 0x3ef), network_message.get(end_level, network_message.number_offset));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x08, 0x10, 0x00, 0x00, 0x08, 0x10, 0x00, 0x00, 0x08, 0x00, 0x00, 0xef, 0x03, 0x00, 0x00 }, end_level);
    router.release(end_level);
    try std.testing.expectEqual(@as(?[]u8, null), try router.read(network_message.Queue.server));

    const reference = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/train-start-reference.json", a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(reference);
    const Fixture = struct {
        changes: []struct { sector: usize, vertices: []struct { index: usize, bits: [2]u32 }, walls: []struct { index: usize, direction_bits: [2]u32, angle: u16, length_bits: u32 } },
    };
    const parsed = try std.json.parseFromSlice(Fixture, a, reference, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.changes) |change| {
        for (change.vertices) |expected| {
            const actual = level.sectors[change.sector].vertices[expected.index];
            try std.testing.expectEqual(expected.bits, [2]u32{ @bitCast(actual.x), @bitCast(actual.z) });
        }
        for (change.walls) |expected| {
            const actual = scene.sectors[change.sector].walls[expected.index];
            try std.testing.expectEqual(expected.direction_bits, [2]u32{ @bitCast(actual.direction.x), @bitCast(actual.direction.z) });
            try std.testing.expectEqual(expected.angle, @as(u16, @bitCast(actual.angle)));
            try std.testing.expectEqual(expected.length_bits, @as(u32, @bitCast(actual.length)));
        }
    }
}

test "Town initial rotating doors match first-stop geometry" {
    const a = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(data);
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_module.Level.parse(a, try archive.find("TOWN.LVB", 0));
    defer level.deinit();
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    var random: u32 = 0x742389ac;
    var runtime = try Runtime.loadWithScene(a, &level, try archive.find("TOWN.INF", 0), &random, &scene, &angles);
    defer runtime.deinit();
    const names = [_][]const u8{ "APOTHECARYDOOR01", "APOTHECARYDOOR02", "MEATMARKETDOOR", "SHERIFFSDOOR", "STANSDOOR02" };
    const values = [_]f32{ 3868, -3868, -3868, 3868, -3868 };
    const affected = try a.alloc(bool, level.sectors.len);
    defer a.free(affected);
    @memset(affected, false);
    for (names, values) |name, expected| {
        const index = try findSector(&level, name);
        const elevator = for (runtime.elevators) |e| {
            if (e.sector == index and e.kind == .morph_spin) break e;
        } else return error.MissingTownRotatingDoor;
        try std.testing.expectEqual(expected, elevator.value);
        try std.testing.expectEqual(@as(u32, 0xffffffff), elevator.next_time);
        try std.testing.expectEqual(@as(u32, 0xffffffff), elevator.blocked_time);
        try std.testing.expectEqual(@as(?usize, 1), elevator.target);
        affected[index] = true;
        for (level.sectors[index].walls) |wall| {
            if (wall.adjoin >= 0) affected[@intCast(wall.adjoin)] = true;
            if (wall.dadjoin >= 0) affected[@intCast(wall.dadjoin)] = true;
        }
    }
    const Digest = struct {
        fn add(hash: *std.crypto.hash.sha2.Sha256, words: []const u32) void {
            for (words) |word| {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, word, .little);
                hash.update(&bytes);
            }
        }
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var count: usize = 0;
    for (level.sectors, scene.sectors, affected, 0..) |sector, state, changed, index| {
        if (!changed) continue;
        count += 1;
        Digest.add(&hash, &.{ @intCast(index), @intCast(sector.vertices.len) });
        for (sector.vertices) |vertex| Digest.add(&hash, &.{ @bitCast(vertex.x), @bitCast(vertex.z) });
        Digest.add(&hash, &.{@intCast(sector.walls.len)});
        for (state.walls) |wall| Digest.add(&hash, &.{ @bitCast(wall.direction.x), @bitCast(wall.direction.z), @as(u16, @bitCast(wall.angle)), @bitCast(wall.length) });
    }
    try std.testing.expectEqual(@as(usize, 9), count);
    try std.testing.expectEqualStrings("1381c4cb92d30e19f135d709867f106ffa406beafa619683b57d6f835d71ac7d", &std.fmt.bytesToHex(hash.finalResult(), .lower));
}

test "INF blocked Hideout door matches rollback timeout and queued impulse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-blocked-reference.json", a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Change = struct {
        sector: usize,
        runtime_flags: u32,
        vertices: []const struct { index: usize, bits: [2]u32 },
        walls: []const struct { index: usize, direction_bits: [2]u32, angle: u16, length_bits: u32, runtime_flags: u32 },
    };
    const Fixture = struct {
        sequences: []const struct {
            sector: usize,
            delta_bits: u32,
            actor_position_bits: [3]u32,
            center_bits: [2]u32,
            samples: []const struct {
                now: u32,
                actor_present: bool,
                result_bits: u32,
                value_bits: u32,
                blocked_time: u32,
                target: usize,
                impulses: []const struct { target: u32, code: u32, velocity_bits: [3]u32 },
                changes: []const Change,
            },
        },
    };
    const reference = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(128 * 1024 * 1024));
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    const originals = try a.alloc([]const level_module.Vec2, level.sectors.len);
    const saved_walls = try a.alloc([]scene_module.WallState, level.sectors.len);
    const saved_flags = try a.alloc(u32, level.sectors.len);
    for (level.sectors, scene.sectors, originals, saved_walls, saved_flags) |sector, state, *vertices, *walls, *flags| {
        vertices.* = try a.dupe(level_module.Vec2, sector.vertices);
        walls.* = try a.dupe(scene_module.WallState, state.walls);
        flags.* = state.runtime_flags;
    }
    for (reference.value.sequences) |sequence| {
        for (level.sectors, scene.sectors, originals, saved_walls, saved_flags) |*sector, *state, vertices, walls, flags| {
            @memcpy(sector.vertices, vertices);
            @memcpy(state.walls, walls);
            state.runtime_flags = flags;
        }
        var runtime = Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = &.{}, .triggers = &.{}, .classes = &.{}, .base_vertices = originals };
        defer runtime.deinit();
        var elevator = Elevator{
            .sector = sequence.sector,
            .kind = .morph_spin,
            .speed = 0,
            .value = 0,
            .target = 1,
            .cursor = 1,
            .vector = .{ .x = @bitCast(sequence.center_bits[0]), .z = @bitCast(sequence.center_bits[1]) },
        };
        try elevator.stops.appendSlice(runtime.arena.allocator(), &.{ .{ .value = 0, .delay = -1 }, .{ .value = 3868, .delay = -1 } });
        var player: @import("../player/movement.zig").Player = undefined;
        player.sector = sequence.sector;
        player.position = .{ .x = @bitCast(sequence.actor_position_bits[0]), .y = @bitCast(sequence.actor_position_bits[1]), .z = @bitCast(sequence.actor_position_bits[2]) };
        player.radius = 1.5;
        var world = geometry.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = &.{}, .collision_diameter = 3 };
        var random: u32 = 0;
        for (sequence.samples) |sample| {
            runtime.pending.clearRetainingCapacity();
            world.player = if (sample.actor_present) &player else null;
            try runtime.morph(&elevator, @bitCast(sequence.delta_bits), 1, .{ .random = &random, .now_ms = sample.now, .world = &world });
            try std.testing.expectEqual(sample.result_bits, @as(u32, @bitCast(elevator.value)));
            try std.testing.expectEqual(sample.value_bits, @as(u32, @bitCast(elevator.value)));
            try std.testing.expectEqual(sample.blocked_time, elevator.blocked_time);
            try std.testing.expectEqual(sample.target, elevator.target.?);
            try std.testing.expectEqual(sample.impulses.len, runtime.pending.items.len);
            try std.testing.expectEqual(@as(usize, 0), runtime.effects.items.len);
            for (sample.impulses, runtime.pending.items) |expected, pending| {
                try std.testing.expectEqual(@as(u32, 0x801), expected.target);
                try std.testing.expectEqual(@as(u32, 0x7d2), expected.code);
                const impulse = pending.actor_impulse;
                try std.testing.expectEqual(@as(?usize, null), impulse.contact.actor);
                try std.testing.expectEqual(expected.velocity_bits, .{ @as(u32, @bitCast(impulse.velocity.x)), @as(u32, @bitCast(impulse.velocity.y)), @as(u32, @bitCast(impulse.velocity.z)) });
            }
            for (level.sectors, originals, 0..) |sector, vertices, sector_index| {
                for (sector.vertices, vertices, 0..) |actual, original, index| {
                    var expected = [2]u32{ @bitCast(original.x), @bitCast(original.z) };
                    for (sample.changes) |change| if (change.sector == sector_index) {
                        for (change.vertices) |vertex| if (vertex.index == index) {
                            expected = vertex.bits;
                            break;
                        };
                        break;
                    };
                    try std.testing.expectEqual(expected, .{ @as(u32, @bitCast(actual.x)), @as(u32, @bitCast(actual.z)) });
                }
            }
            for (sample.changes) |change| {
                try std.testing.expectEqual(saved_flags[change.sector] | change.runtime_flags, scene.sectors[change.sector].runtime_flags);
                for (change.walls) |expected| {
                    const actual = scene.sectors[change.sector].walls[expected.index];
                    try std.testing.expectEqual(expected.direction_bits, .{ @as(u32, @bitCast(actual.direction.x)), @as(u32, @bitCast(actual.direction.z)) });
                    try std.testing.expectEqual(expected.angle, @as(u16, @bitCast(actual.angle)));
                    try std.testing.expectEqual(expected.length_bits, @as(u32, @bitCast(actual.length)));
                    try std.testing.expectEqual(expected.runtime_flags, actual.runtime_flags);
                }
            }
        }
    }
}
