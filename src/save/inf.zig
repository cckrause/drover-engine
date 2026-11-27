//! Saving the script engine: tasks, their state, and the sectors and walls
//! they are working on.
//!
//! Queued database packets are deliberately not saved. Sectors are visited
//! in file order with their actor chains, so a restore rebuilds the same
//! lists.

const std = @import("std");
const stream = @import("stream.zig");
const sound = @import("sound.zig");
const inf = @import("../script/inf.zig");
const texture = @import("../render/texture_animation.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const audio_module = @import("../audio/runtime.zig");

pub const References = struct {
    actor_ids: []const u32 = &.{},
    actor_map_ids: []const u32 = &.{},
    generator_ids: []const u32 = &.{},
    audio: ?*audio_module.Runtime = null,
};

pub fn writeDbm(w: *stream.Writer) !void {
    try w.marker(0x426d6244, 1, 0);
}

pub fn readDbm(r: *stream.Reader) !void {
    try r.marker(0x426d6244, 1, 0);
}

pub fn writeElevatorModule(w: *stream.Writer, runtime: *const inf.Runtime) !void {
    try w.marker(0x42766c45, 1, 0);
    try w.integer(u32, runtime.elevator_clock);
}

pub fn readElevatorModule(r: *stream.Reader, runtime: *inf.Runtime) !void {
    try r.marker(0x42766c45, 1, 0);
    runtime.elevator_clock = try r.integer(u32);
}

pub fn writeClasses(w: *stream.Writer, runtime: *const inf.Runtime, animations: *const texture.Runtime, level: *const level_module.Level, refs: References) !void {
    try w.marker(0x42206244, 1, 0);
    for (level.sectors, 0..) |sector, si| {
        try writeTargetClasses(w, runtime, animations, level, .{ .sector = si }, refs);
        for (sector.walls, 0..) |_, wi| try writeTargetClasses(w, runtime, animations, level, .{ .sector = si, .wall = wi }, refs);
    }
    try w.integer(u32, 0xffffffff);
}

pub fn writeElevator(w: *stream.Writer, e: inf.Elevator, refs: References) !void {
    try w.integer(u32, @intFromEnum(e.kind));
    try w.integer(i32, e.mode);
    try w.integer(u32, @intCast(e.sector));
    try w.integer(u32, e.object_id);
    try w.integer(u32, e.excluded_object);
    try w.integer(u32, @intFromBool(e.step));
    try w.integer(u32, e.next_time);
    try w.integer(u32, e.blocked_time);
    try w.integer(u32, @intCast(e.stops.items.len));
    for (e.stops.items) |stop| {
        try w.float(stop.value);
        try w.integer(i32, stop.delay);
        try w.integer(u32, @intCast(stop.messages.items.len));
        for (stop.messages.items) |message| try writeClient(w, message, refs);
        try writeSound(w, refs, stop.sound);
    }
    try w.integer(u32, @intCast(e.slaves.items.len));
    for (e.slaves.items) |slave| {
        try w.integer(u32, @intCast(slave.sector));
        try w.integer(i16, slave.angle);
    }
    try w.integer(u32, if (e.target) |index| @intCast(index) else 0xffffffff);
    try w.float(e.speed);
    try w.float(switch (e.kind) {
        .ceiling, .floor, .offset, .floor_ceiling => e.internal_value,
        else => e.value,
    });
    try w.float(e.vector.x);
    try w.float(e.vector.z);
    try w.integer(u32, e.flags);
    for (e.sounds) |name| try writeSound(w, refs, name);
    for ([_]u5{ 0, 1, 2 }) |bit| try w.boolean(e.runtime_flags & (@as(u32, 1) << bit) != 0);
}

pub fn readElevator(r: *stream.Reader, a: std.mem.Allocator, level: *const level_module.Level, refs: References) !inf.Elevator {
    const raw = try r.integer(u32);
    if (raw > 16 or (raw > 9 and raw < 14)) return error.InvalidSavedElevatorKind;
    const kind: inf.Kind = @enumFromInt(raw);
    const mode = try r.integer(i32);
    const sector = try r.integer(u32);
    if (sector >= level.sectors.len) return error.InvalidSavedSector;
    var e: inf.Elevator = .{ .sector = sector, .kind = kind, .mode = mode, .speed = 0, .value = 0, .object_id = try r.integer(u32), .excluded_object = try r.integer(u32), .step = try r.integer(u32) != 0, .next_time = try r.integer(u32), .blocked_time = try r.integer(u32) };
    const stops = try count(r);
    for (0..stops) |_| {
        var stop: inf.Stop = .{ .value = try r.float(), .delay = try r.integer(i32) };
        const messages = try count(r);
        for (0..messages) |_| try stop.messages.append(a, try readClient(r, level, refs));
        stop.sound = try readSound(r, a, refs);
        try e.stops.append(a, stop);
    }
    const slaves = try count(r);
    for (0..slaves) |_| {
        const si = try r.integer(u32);
        if (si >= level.sectors.len) return error.InvalidSavedSector;
        try e.slaves.append(a, .{ .sector = si, .angle = try r.integer(i16) });
    }
    const target = try r.integer(u32);
    if (target != 0xffffffff) {
        if (target >= stops) return error.InvalidSavedInfStop;
        e.target = target;
    }
    e.cursor = e.target orelse if (stops == 0) 0 else stops - 1;
    e.speed = try r.float();
    e.internal_value = try r.float();
    e.value = switch (kind) {
        .ceiling => level.sectors[sector].ceiling.height,
        .floor, .offset, .floor_ceiling => level.sectors[sector].floor.height,
        else => e.internal_value,
    };
    e.vector = .{ .x = try r.float(), .z = try r.float() };
    e.flags = try r.integer(u32);
    for (&e.sounds) |*name| name.* = try readSound(r, a, refs);
    e.runtime_flags = 0;
    for ([_]u5{ 0, 1, 2 }) |bit| if (try r.boolean()) {
        e.runtime_flags |= @as(u32, 1) << bit;
    };
    return e;
}

pub fn writeTrigger(w: *stream.Writer, t: inf.Trigger, refs: References) !void {
    try w.integer(u32, t.flags);
    try w.integer(u32, @intCast(t.clients.items.len));
    for (t.clients.items) |client| try writeClient(w, .{ .target = client.target, .code = client.code, .event_mask = client.mask, .arg1 = client.arg1, .arg2 = client.arg2 }, refs);
    try w.integer(u32, t.message.code);
    try w.integer(u32, t.message.event_mask);
    try w.integer(i32, t.message.arg1);
    try w.integer(i32, t.message.arg2);
    try w.integer(u32, t.time20);
    try w.integer(u32, t.time24);
    try w.integer(u32, t.object_id);
    try w.integer(u32, t.excluded_object);
    try writeSound(w, refs, t.sound);
    try nullableString(w, t.movie);
    try nullableString(w, t.next_level);
    try writeTarget(w, t.spawn orelse .{}, refs);
}

pub fn readTrigger(r: *stream.Reader, a: std.mem.Allocator, target: inf.Target, level: *const level_module.Level, refs: References) !inf.Trigger {
    var t: inf.Trigger = .{ .target = target, .flags = try r.integer(u32) };
    if (t.flags & 0xfc000000 == 0) return error.InvalidSavedTriggerKind;
    const clients = try count(r);
    for (0..clients) |_| {
        const client = try readClient(r, level, refs);
        try t.clients.append(a, .{ .target = client.target, .mask = client.event_mask, .code = client.code, .arg1 = client.arg1, .arg2 = client.arg2 });
    }
    t.message = .{ .code = try r.integer(u32), .event_mask = try r.integer(u32), .arg1 = try r.integer(i32), .arg2 = try r.integer(i32) };
    t.time20 = try r.integer(u32);
    t.time24 = try r.integer(u32);
    t.object_id = try r.integer(u32);
    t.excluded_object = try r.integer(u32);
    t.sound = try readSound(r, a, refs);
    t.movie = try readNullableString(r, a);
    t.next_level = try readNullableString(r, a);
    const spawn = try readTarget(r, level, refs);
    if (spawn.sector != null or spawn.object != null) t.spawn = spawn;
    return t;
}

pub fn readClasses(r: *stream.Reader, runtime: *inf.Runtime, animations: *texture.Runtime, level: *level_module.Level, scene: *scene_module.Scene, refs: References) !void {
    try r.marker(0x42206244, 1, 0);
    const a = runtime.arena.allocator();
    var elevators: std.ArrayList(inf.Elevator) = .empty;
    var triggers: std.ArrayList(inf.Trigger) = .empty;
    var classes: std.ArrayList(inf.Class) = .empty;
    var instances: std.ArrayList(texture.Instance) = .empty;
    var links: std.ArrayList(inf.DbLink) = .empty;
    while (true) {
        const owner_code = try r.integer(u32);
        if (owner_code == 0xffffffff) break;
        if (links.items.len >= 1048576) return error.InvalidSavedInfClassCount;
        const sector = owner_code >> 16;
        if (sector >= level.sectors.len) return error.InvalidSavedSector;
        const wall: ?usize = if (owner_code & 0xffff == 0xffff) null else owner_code & 0xffff;
        if (wall != null and wall.? >= level.sectors[sector].walls.len) return error.InvalidSavedWall;
        const target: inf.Target = .{ .sector = sector, .wall = wall };
        const kind = try r.integer(u32);
        var link: inf.DbLink = .{ .target = target, .kind = undefined, .index = 0, .event_mask = 0, .entity_mask = 0 };
        switch (kind) {
            1 => {
                link.kind = .trigger;
                link.index = triggers.items.len;
                try triggers.append(a, try readTrigger(r, a, target, level, refs));
                try classes.append(a, .{ .trigger = link.index });
            },
            2 => {
                link.kind = .elevator;
                link.index = elevators.items.len;
                try elevators.append(a, try readElevator(r, a, level, refs));
                if (@intFromEnum(elevators.items[link.index].kind) >= 14) scene.sectors[elevators.items[link.index].sector].velocity_present = true;
                try classes.append(a, .{ .elevator = link.index });
            },
            8 => {
                link.kind = .atx;
                link.index = instances.items.len;
                try instances.append(a, try readAtx(r, a, target, animations, level, scene));
            },
            else => return error.InvalidSavedInfClass,
        }
        link.event_mask = try r.integer(u32);
        link.entity_mask = try r.integer(u32);
        switch (link.kind) {
            .trigger => {
                triggers.items[link.index].event_mask = link.event_mask;
                triggers.items[link.index].entity_mask = link.entity_mask;
            },
            .elevator => {
                elevators.items[link.index].event_mask = link.event_mask;
                elevators.items[link.index].entity_mask = link.entity_mask;
            },
            .atx => {},
        }
        try links.append(a, link);
    }
    runtime.elevators = try elevators.toOwnedSlice(a);
    runtime.triggers = try triggers.toOwnedSlice(a);
    runtime.classes = try classes.toOwnedSlice(a);
    runtime.restored_links = try links.toOwnedSlice(a);
    animations.instances = try instances.toOwnedSlice(a);
    runtime.pending.clearRetainingCapacity();
    runtime.effects.clearRetainingCapacity();
}

fn writeTargetClasses(w: *stream.Writer, runtime: *const inf.Runtime, animations: *const texture.Runtime, level: *const level_module.Level, target: inf.Target, refs: References) !void {
    if (runtime.restored_links.len != 0) {
        var i = runtime.restored_links.len;
        while (i != 0) {
            i -= 1;
            const link = runtime.restored_links[i];
            if (same(link.target, target)) try writeLink(w, runtime, animations, level, link, refs);
        }
        return;
    }
    var i = runtime.classes.len;
    while (i != 0) {
        i -= 1;
        const link: inf.DbLink = switch (runtime.classes[i]) {
            .elevator => |index| blk: {
                const e = runtime.elevators[index];
                if (e.deleted) continue;
                break :blk .{ .target = .{ .sector = e.sector }, .kind = .elevator, .index = index, .event_mask = e.event_mask, .entity_mask = e.entity_mask };
            },
            .trigger => |index| blk: {
                const t = runtime.triggers[index];
                if (t.deleted) continue;
                break :blk .{ .target = t.target, .kind = .trigger, .index = index, .event_mask = t.event_mask, .entity_mask = t.entity_mask };
            },
        };
        if (same(link.target, target)) try writeLink(w, runtime, animations, level, link, refs);
    }
    i = animations.instances.len;
    while (i != 0) {
        i -= 1;
        const instance = animations.instances[i];
        if (instance.target.sector != target.sector or instance.target.wall != target.wall) continue;
        try writeLink(w, runtime, animations, level, .{ .target = target, .kind = .atx, .index = i, .event_mask = 0x2000, .entity_mask = 0xffffffff }, refs);
    }
}

fn writeLink(w: *stream.Writer, runtime: *const inf.Runtime, animations: *const texture.Runtime, level: *const level_module.Level, link: inf.DbLink, refs: References) !void {
    const mask_event = switch (link.kind) {
        .elevator => blk: {
            const e = runtime.elevators[link.index];
            if (e.deleted) return;
            break :blk e.event_mask;
        },
        .trigger => blk: {
            const t = runtime.triggers[link.index];
            if (t.deleted) return;
            break :blk t.event_mask;
        },
        .atx => link.event_mask,
    };
    const mask_entity = switch (link.kind) {
        .elevator => runtime.elevators[link.index].entity_mask,
        .trigger => runtime.triggers[link.index].entity_mask,
        .atx => link.entity_mask,
    };
    const sector = link.target.sector orelse return error.InvalidSavedInfOwner;
    if (sector > 0xffff or (link.target.wall != null and link.target.wall.? >= 0xffff)) return error.InvalidSavedInfOwner;
    try w.integer(u32, @as(u32, @intCast(sector)) << 16 | @as(u32, @intCast(link.target.wall orelse 0xffff)));
    switch (link.kind) {
        .elevator => {
            try w.integer(u32, 2);
            try writeElevator(w, runtime.elevators[link.index], refs);
        },
        .trigger => {
            try w.integer(u32, 1);
            try writeTrigger(w, runtime.triggers[link.index], refs);
        },
        .atx => {
            try w.integer(u32, 8);
            try writeAtx(w, animations.instances[link.index], level);
        },
    }
    try w.integer(u32, mask_event);
    try w.integer(u32, mask_entity);
}

fn writeAtx(w: *stream.Writer, instance: texture.Instance, level: *const level_module.Level) !void {
    try w.integer(u16, instance.state.flags);
    try w.integer(u32, instance.slot);
    if (instance.resource >= level.textures.len) return error.InvalidSavedAtxResource;
    try w.string(level.textures[instance.resource]);
    try w.integer(i32, instance.state.rate);
    try w.integer(u32, instance.state.pc);
    try w.integer(u32, instance.state.displayed);
    try w.integer(u32, instance.state.last_tick);
}

fn readAtx(r: *stream.Reader, a: std.mem.Allocator, target: inf.Target, animations: *const texture.Runtime, level: *level_module.Level, scene: *scene_module.Scene) !texture.Instance {
    const flags = try r.integer(u16);
    const slot = try r.integer(u32);
    if (slot > 3 or flags & 3 == 0) return error.InvalidSavedAtxType;
    var buffer: [255]u8 = undefined;
    const name = try r.string(&buffer);
    _ = a;
    const resource = for (level.textures, 0..) |candidate, index| {
        if (std.ascii.eqlIgnoreCase(candidate, name)) break index;
    } else return error.MissingSavedAtxResource;
    if (resource >= animations.programs.len or animations.programs[resource] == null) return error.MissingSavedAtxResource;
    const program = animations.programs[resource].?;
    const rate = try r.integer(i32);
    const pc = try r.integer(u32);
    const displayed = try r.integer(u32);
    if (pc >= program.animation.instructions.len or (displayed != 1000 and displayed >= program.animation.instructions.len)) return error.InvalidSavedAtxInstruction;
    if (displayed != 1000) {
        if (program.animation.instructions[displayed] != .texture) return error.InvalidSavedAtxTexture;
        const sector = &level.sectors[target.sector.?];
        const destination = if (target.wall) |wall| switch (@as(u2, @intCast(slot))) {
            0 => &sector.walls[wall].top.texture,
            1 => &sector.walls[wall].mid.texture,
            2 => &sector.walls[wall].bottom.texture,
            3 => &sector.walls[wall].overlay.texture,
        } else switch (@as(u2, @intCast(slot))) {
            0 => &sector.floor.texture,
            1 => &sector.ceiling.texture,
            2 => &sector.floor_overlay.texture,
            3 => &sector.ceiling_overlay.texture,
        };
        destination.* = program.textures[displayed];
        if (target.wall) |wall| scene.sectors[target.sector.?].walls[wall].runtime_flags |= 1 else scene.sectors[target.sector.?].runtime_flags |= 1;
    }
    return .{ .target = .{ .sector = target.sector.?, .wall = target.wall }, .slot = @intCast(slot), .resource = resource, .state = .{ .flags = flags, .rate = rate, .pc = pc, .displayed = displayed, .last_tick = try r.integer(u32) } };
}

fn writeClient(w: *stream.Writer, m: inf.Message, refs: References) !void {
    try writeTarget(w, m.target, refs);
    try w.integer(u32, m.code);
    try w.integer(u32, m.event_mask);
    try w.integer(i32, m.arg1);
    try w.integer(i32, m.arg2);
}

fn readClient(r: *stream.Reader, level: *const level_module.Level, refs: References) !inf.Message {
    return .{ .target = try readTarget(r, level, refs), .code = try r.integer(u32), .event_mask = try r.integer(u32), .arg1 = try r.integer(i32), .arg2 = try r.integer(i32) };
}

fn writeTarget(w: *stream.Writer, t: inf.Target, refs: References) !void {
    if (t.object) |id| {
        for (refs.actor_map_ids, 0..) |map, index| {
            if (map == id) {
                if (index >= refs.actor_ids.len) return error.InvalidSavedActorReference;
                try w.integer(u32, 0x40000);
                try w.integer(u32, refs.actor_ids[index]);
                return;
            }
        }
        for (refs.generator_ids) |gen| {
            if (gen == id) {
                try w.integer(u32, 0x100000);
                try w.integer(u32, id);
                return;
            }
        }
        return error.InvalidSavedInfObject;
    }
    if (t.sector) |sector| {
        try w.integer(u32, if (t.wall != null) 0x10000 else 0x20000);
        try w.integer(u32, @intCast(sector));
        if (t.wall) |wall| try w.integer(u32, @intCast(wall));
    } else try w.integer(u32, 0);
}

fn readTarget(r: *stream.Reader, level: *const level_module.Level, refs: References) !inf.Target {
    switch (try r.integer(u32)) {
        0 => return .{},
        0x10000 => {
            const sector = try r.integer(u32);
            const wall = try r.integer(u32);
            if (sector >= level.sectors.len or wall >= level.sectors[sector].walls.len) return error.InvalidSavedInfClient;
            return .{ .sector = sector, .wall = wall };
        },
        0x20000 => {
            const sector = try r.integer(u32);
            if (sector >= level.sectors.len) return error.InvalidSavedSector;
            return .{ .sector = sector };
        },
        0x40000 => {
            const id = try r.integer(u32);
            for (refs.actor_ids, 0..) |existing, index| if (existing == id) {
                if (index >= refs.actor_map_ids.len) return error.InvalidSavedActorReference;
                return .{ .object = refs.actor_map_ids[index] };
            };
            return .{};
        },
        0x100000 => {
            const id = try r.integer(u32);
            for (refs.generator_ids) |existing| if (existing == id) return .{ .object = id };
            return .{};
        },
        else => return error.InvalidSavedInfClient,
    }
}

fn writeSound(w: *stream.Writer, refs: References, name: ?[]const u8) !void {
    try sound.write(w, if (refs.audio) |audio| try sound.capture(audio, name) else if (name == null) null else return error.MissingSaveAudio);
}

fn readSound(r: *stream.Reader, a: std.mem.Allocator, refs: References) !?[]const u8 {
    const value = try sound.read(r, a);
    return if (refs.audio) |audio| try sound.restore(audio, value) else if (value == null) null else return error.MissingSaveAudio;
}

fn nullableString(w: *stream.Writer, value: ?[]const u8) !void {
    try w.integer(u32, if (value) |v| @intCast(v.len) else 0);
    if (value) |v| try w.string(v);
}

fn readNullableString(r: *stream.Reader, a: std.mem.Allocator) !?[]const u8 {
    const len = try r.integer(u32);
    if (len == 0) return null;
    if (len > 255) return error.InvalidSavedInfString;
    var buffer: [255]u8 = undefined;
    const value = try r.string(&buffer);
    if (value.len != len) return error.InvalidSavedInfString;
    return try a.dupe(u8, value);
}

fn count(r: *stream.Reader) !u32 {
    const result = try r.integer(u32);
    if (result > 1048576) return error.InvalidSavedInfCount;
    return result;
}

fn same(a: inf.Target, b: inf.Target) bool {
    return a.sector == b.sector and a.wall == b.wall and a.object == b.object;
}

fn readFixture(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn expectHex(a: std.mem.Allocator, hex: []const u8, actual: []const u8) !void {
    const expected = try a.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(expected, hex);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "trigger movie filename preserves save bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try readFixture(a, "testdata/inf-movie-reference.json");
    const corpus = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    var sectors: [22]level_module.Sector = @splat(std.mem.zeroes(level_module.Sector));
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    for (corpus.value.object.get("cases").?.array.items) |case| {
        var trigger: inf.Trigger = .{ .target = .{ .sector = 20 }, .flags = @intCast(case.object.get("flags").?.integer), .message = .{ .code = 0x7da, .event_mask = 0x2000, .arg1 = 7 }, .movie = "RAM.SAN" };
        try trigger.clients.append(a, .{ .target = .{ .sector = 21 }, .mask = 0x30 });
        var writer = stream.Writer{ .allocator = a };
        try writeTrigger(&writer, trigger, .{});
        const saved = try writer.finish();
        try expectHex(a, case.object.get("bytes").?.string, saved);
        var reader = stream.Reader{ .bytes = saved };
        const restored = try readTrigger(&reader, a, trigger.target, &level, .{});
        try reader.end();
        try std.testing.expectEqualStrings("RAM.SAN", restored.movie.?);
        try std.testing.expectEqual(@as(?[]const u8, null), restored.next_level);
    }
}

test "INF and ATX saves match the reference on shipped geometry and scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        elevators: []struct { kind: u32, sector: usize, words: [24]u32, bytes: []const u8 },
        triggers: []struct { kind: u32, words: [16]u32, bytes: []const u8 },
        atx: []struct { name: []const u8, wall: bool, save: []const u8, samples: []struct { rate: u32, pc: u32, displayed: u32, last_tick: u32, flags: u16 } },
    };
    const fixture = (try std.json.parseFromSlice(Corpus, a, try readFixture(a, "testdata/inf-save-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.executable_sha256);
    try std.testing.expectEqualStrings("77a52bfb7f7fe629f564db151f5c81f40e83c8782c861985a96d76424344e1d3", fixture.results_sha256);
    const archive = try @import("../assets/lab.zig").Archive.init(try readFixture(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0x4c565446));
    defer level.deinit();
    const angles = @import("../render/backends/software/camera.zig").Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    for (fixture.elevators) |case| {
        errdefer std.debug.print("reference saved elevator kind{d}\n", .{case.kind});
        const b = case.words;
        var e: inf.Elevator = .{ .kind = @enumFromInt(case.kind), .sector = case.sector, .mode = @bitCast(b[2]), .object_id = b[4], .excluded_object = b[5], .step = b[6] != 0, .next_time = b[7], .blocked_time = b[8], .target = 1, .cursor = 1, .speed = @bitCast(b[12]), .value = @bitCast(b[14]), .internal_value = @bitCast(b[14]), .vector = .{ .x = @bitCast(b[15]), .z = @bitCast(b[16]) }, .flags = b[17], .runtime_flags = b[23] };
        try e.stops.append(a, .{ .value = 3.5, .delay = 0 });
        try e.stops.append(a, .{ .value = 12.25, .delay = -1 });
        var w = stream.Writer{ .allocator = a };
        try writeElevator(&w, e, .{});
        const bytes = try w.finish();
        try expectHex(a, case.bytes, bytes);
        var r = stream.Reader{ .bytes = bytes };
        const restored = try readElevator(&r, a, &level, .{});
        try r.end();
        try std.testing.expectEqual(@as(?usize, 1), restored.target);
        try std.testing.expectEqual(@as(usize, 1), restored.cursor);
        w = .{ .allocator = a };
        try writeElevator(&w, restored, .{});
        try expectHex(a, case.bytes, try w.finish());
    }
    for (fixture.triggers) |case| {
        const b = case.words;
        var t: inf.Trigger = .{ .target = .{ .sector = 20 }, .flags = b[1], .message = .{ .code = b[4], .event_mask = b[5], .arg1 = @bitCast(b[6]), .arg2 = @bitCast(b[7]) }, .time20 = b[8], .time24 = b[9], .object_id = b[10], .excluded_object = b[11] };
        try t.clients.append(a, .{ .target = .{ .sector = 21 }, .mask = 0x30 });
        var w = stream.Writer{ .allocator = a };
        try writeTrigger(&w, t, .{});
        const bytes = try w.finish();
        try expectHex(a, case.bytes, bytes);
        var r = stream.Reader{ .bytes = bytes };
        const restored = try readTrigger(&r, a, t.target, &level, .{});
        try r.end();
        w = .{ .allocator = a };
        try writeTrigger(&w, restored, .{});
        try expectHex(a, case.bytes, try w.finish());
    }
    const textures = try @import("../assets/lab.zig").Archive.init(try readFixture(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLTEX.LAB"));
    for (fixture.atx) |case| {
        const original_names = level.textures;
        defer level.textures = original_names;
        level.textures = try a.dupe([]const u8, &.{case.name});
        const animation = try @import("../assets/atx.zig").Animation.parse(a, try textures.find(case.name, 0));
        const frames = try a.alloc(i32, animation.instructions.len);
        for (frames, 0..) |*value, index| value.* = @intCast(index);
        const programs = try a.alloc(@typeInfo(@FieldType(texture.Runtime, "programs")).pointer.child, 1);
        programs[0] = .{ .animation = animation, .textures = frames };
        var runtime: texture.Runtime = .{ .programs = programs, .instances = &.{} };
        const sample = case.samples[case.samples.len - 1];
        const instance: texture.Instance = .{ .target = .{ .sector = 410, .wall = if (case.wall) 1 else null }, .slot = if (case.wall) 1 else 0, .resource = 0, .state = .{ .rate = @bitCast(sample.rate), .pc = sample.pc, .displayed = sample.displayed, .last_tick = sample.last_tick, .flags = sample.flags } };
        var w = stream.Writer{ .allocator = a };
        try writeAtx(&w, instance, &level);
        const bytes = try w.finish();
        try expectHex(a, case.save, bytes);
        var r = stream.Reader{ .bytes = bytes };
        const restored = try readAtx(&r, a, .{ .sector = 410, .wall = instance.target.wall }, &runtime, &level, &scene);
        try r.end();
        try std.testing.expectEqualDeep(instance, restored);
        var native = inf.Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = &.{}, .triggers = &.{}, .classes = &.{} };
        try native.reserveLists();
        defer native.deinit();
        native.triggers = try a.dupe(inf.Trigger, &.{ .{ .target = .{ .sector = 410 }, .flags = 0x04f00001, .object_id = 1 }, .{ .target = .{ .sector = 410 }, .flags = 0x04f00001, .object_id = 2 } });
        native.classes = try a.dupe(inf.Class, &.{ .{ .trigger = 0 }, .{ .trigger = 1 } });
        runtime.instances = try a.dupe(texture.Instance, &.{instance});
        w = .{ .allocator = a };
        try writeClasses(&w, &native, &runtime, &level, .{});
        const db = try w.finish();
        r = .{ .bytes = db };
        try readClasses(&r, &native, &runtime, &level, &scene, .{});
        try r.end();
        try std.testing.expectEqual(@as(u32, 2), native.triggers[0].object_id);
        try std.testing.expectEqual(@as(u32, 1), native.triggers[1].object_id);
        try std.testing.expectEqual(@as(usize, 1), runtime.instances.len);
        if (!case.wall) {
            native.triggers[0].sound = "second.wav";
            native.triggers[1].sound = "first.wav";
            try native.event(&level, .{ .sector = 410, .mask = 0, .now_ms = 20 });
            try native.flushQueued(&level, &scene, 20, &.{}, 0x100000);
            try std.testing.expectEqual(@as(usize, 3), native.effects.items.len);
            try std.testing.expectEqual(@as(?usize, 0), native.effects.items[0].wall_frame.instance);
            try std.testing.expectEqualStrings("first.wav", native.effects.items[1].sound.name);
            try std.testing.expectEqualStrings("second.wav", native.effects.items[2].sound.name);
        }
    }
}
