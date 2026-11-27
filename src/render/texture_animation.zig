//! Animated level textures: one script instance per animated surface.
//!
//! Instances are linked as they are created and traversed backwards for both
//! scheduling and message delivery, so creation order is part of the
//! behaviour. A missing animation script falls back exactly like a missing
//! level texture does.

const std = @import("std");
const atx = @import("../assets/atx.zig");
const texture = @import("../assets/texture.zig");
const lab = @import("../assets/lab.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("scene.zig");
const inventory = @import("../player/inventory.zig");

pub const Target = struct { sector: usize, wall: ?usize = null };

pub const Instance = struct { target: Target, slot: u2, resource: usize, state: atx.State };

const Program = struct { animation: atx.Animation, textures: []i32 };

pub const Runtime = struct {
    programs: []?Program,
    instances: []Instance,

    pub fn init(a: std.mem.Allocator, level: *const level_module.Level, textures: *[]texture.Texture, archive: lab.Archive, now: u32) !Runtime {
        const programs = try a.alloc(?Program, textures.len);
        @memset(programs, null);
        var loaded: std.ArrayList(texture.Texture) = .empty;
        try loaded.appendSlice(a, textures.*);
        for (textures.*, 0..) |source, index| if (source.animation) |animation| {
            const frames = try a.alloc(i32, animation.instructions.len);
            @memset(frames, -1);
            const first = animation.initialTexture() orelse return error.AtXHasNoTexture;
            for (animation.instructions, 0..) |instruction, pc| if (instruction == .texture) {
                const name = instruction.texture;
                if (!std.ascii.endsWithIgnoreCase(name, ".pcx")) return error.UnsupportedTextureFormat;
                if (std.ascii.eqlIgnoreCase(first, name)) {
                    frames[pc] = @intCast(index);
                } else {
                    for (animation.instructions[0..pc], frames[0..pc]) |previous, previous_frame| {
                        if (previous == .texture and std.ascii.eqlIgnoreCase(previous.texture, name)) {
                            frames[pc] = previous_frame;
                            break;
                        }
                    }
                    if (frames[pc] < 0) {
                        frames[pc] = @intCast(loaded.items.len);
                        try loaded.append(a, try texture.loadLevelInitial(a, archive, name));
                    }
                }
            };
            programs[index] = .{ .animation = animation, .textures = frames };
        };
        textures.* = try loaded.toOwnedSlice(a);
        var instances: std.ArrayList(Instance) = .empty;
        for (level.sectors, 0..) |sector, sector_index| {
            for ([_]i32{ sector.floor.texture, sector.ceiling.texture, sector.floor_overlay.texture, sector.ceiling_overlay.texture }, 0..) |index, slot| {
                if (index >= 0 and programs[@intCast(index)] != null)
                    try instances.append(a, .{ .target = .{ .sector = sector_index }, .slot = @intCast(slot), .resource = @intCast(index), .state = .{ .flags = 1, .last_tick = now } });
            }
            for (sector.walls, 0..) |wall, wall_index| {
                for ([_]u2{ 1, 0, 2, 3 }) |slot| {
                    const index = switch (slot) {
                        0 => wall.top.texture,
                        1 => wall.mid.texture,
                        2 => wall.bottom.texture,
                        3 => wall.overlay.texture,
                    };
                    if (index >= 0 and programs[@intCast(index)] != null)
                        try instances.append(a, .{ .target = .{ .sector = sector_index, .wall = wall_index }, .slot = slot, .resource = @intCast(index), .state = .{ .flags = 2, .last_tick = now } });
                }
            }
        }
        return .{ .programs = programs, .instances = try instances.toOwnedSlice(a) };
    }

    pub fn message(self: *Runtime, level: *level_module.Level, scene: *scene_module.Scene, target: Target, code: u32, arg1: i32, now: u32, effects: *inventory.Effects) !void {
        var events_buffer: atx.EventBuffer = undefined;
        var events = atx.Events.init(&events_buffer);
        var index = self.instances.len;
        while (index != 0) {
            index -= 1;
            const instance = &self.instances[index];
            if (instance.target.sector != target.sector or instance.target.wall != target.wall) continue;
            events.clearRetainingCapacity();
            try instance.state.message(self.programs[instance.resource].?.animation, code, arg1, now, &events);
            try self.apply(level, scene, instance, events.items, effects);
        }
    }

    pub fn messageInstance(self: *Runtime, level: *level_module.Level, scene: *scene_module.Scene, index: usize, code: u32, arg1: i32, now: u32, effects: *inventory.Effects) !void {
        if (index >= self.instances.len) return error.InvalidAtxInstance;
        const instance = &self.instances[index];
        var events_buffer: atx.EventBuffer = undefined;
        var events = atx.Events.init(&events_buffer);
        try instance.state.message(self.programs[instance.resource].?.animation, code, arg1, now, &events);
        try self.apply(level, scene, instance, events.items, effects);
    }

    pub fn tick(self: *Runtime, level: *level_module.Level, scene: *scene_module.Scene, now: u32, effects: *inventory.Effects) !void {
        var events_buffer: atx.EventBuffer = undefined;
        var events = atx.Events.init(&events_buffer);
        var index = self.instances.len;
        while (index != 0) {
            index -= 1;
            const instance = &self.instances[index];
            events.clearRetainingCapacity();
            try instance.state.tick(self.programs[instance.resource].?.animation, now, &events);
            try self.apply(level, scene, instance, events.items, effects);
        }
    }

    fn apply(self: *const Runtime, level: *level_module.Level, scene: *scene_module.Scene, instance: *const Instance, events: []const atx.Event, effects: *inventory.Effects) !void {
        const program = self.programs[instance.resource].?;
        const sector = &level.sectors[instance.target.sector];
        for (events) |event| switch (event) {
            .texture => |pc| {
                const destination = if (instance.target.wall) |index| switch (instance.slot) {
                    0 => &sector.walls[index].top.texture,
                    1 => &sector.walls[index].mid.texture,
                    2 => &sector.walls[index].bottom.texture,
                    3 => &sector.walls[index].overlay.texture,
                } else switch (instance.slot) {
                    0 => &sector.floor.texture,
                    1 => &sector.ceiling.texture,
                    2 => &sector.floor_overlay.texture,
                    3 => &sector.ceiling_overlay.texture,
                };
                destination.* = program.textures[pc];
                if (instance.target.wall) |index|
                    scene.sectors[instance.target.sector].walls[index].runtime_flags |= 1
                else
                    scene.sectors[instance.target.sector].runtime_flags |= 1;
            },
            .sound => |pc| {
                const position: level_module.Vec3 = if (instance.target.wall) |index| blk: {
                    const vertex = sector.vertices[sector.walls[index].v1];
                    break :blk .{ .x = vertex.x, .y = sector.floor.height, .z = vertex.z };
                } else blk: {
                    if (sector.vertices.len == 0) return error.InvalidAtxSoundSector;
                    var minimum = sector.vertices[0];
                    var maximum = minimum;
                    for (sector.vertices[1..]) |vertex| {
                        minimum.x = @min(minimum.x, vertex.x);
                        minimum.z = @min(minimum.z, vertex.z);
                        maximum.x = @max(maximum.x, vertex.x);
                        maximum.z = @max(maximum.z, vertex.z);
                    }
                    break :blk .{ .x = @floatCast((@as(f64, minimum.x) + maximum.x) * 0.5), .y = sector.floor.height, .z = @floatCast((@as(f64, minimum.z) + maximum.z) * 0.5) };
                };
                try effects.append(.{ .sound = .{ .basename = program.animation.instructions[pc].start_sound.name, .sector = instance.target.sector, .position = position, .priority = 64, .volume = 127, .flags = 4 } });
            },
        };
    }
};

test "ATX states and spatial requests match shipped script execution" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/atx-reference.json", a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        cases: []struct {
            name: []const u8,
            wall: bool,
            samples: []struct {
                action: struct { now: u32, message: ?u32 = null, arg1: i32 = 0 },
                rate: u32,
                pc: u32,
                displayed: u32,
                last_tick: u32,
                flags: u16,
                texture_pc: i32,
                runtime_flags: u32,
                events: []struct { texture: ?usize = null, sound: ?usize = null },
                sounds: []struct { position_bits: [3]u32, priority: i32, volume: i32, flags: u32, owner_sector: bool },
            },
        },
    };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    const texture_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLTEX.LAB", a, .limited(64 * 1024 * 1024));
    defer a.free(texture_bytes);
    const archive = try lab.Archive.init(texture_bytes);
    const geometry_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(32 * 1024 * 1024));
    defer a.free(geometry_bytes);
    const geometry_archive = try lab.Archive.init(geometry_bytes);
    var level = try level_module.Level.parse(a, try geometry_archive.find("hideout.lvb", 0x4c565446));
    defer level.deinit();
    const angles = @import("backends/software/camera.zig").Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    var events_buffer: atx.EventBuffer = undefined;
    var events = atx.Events.init(&events_buffer);
    var effects_buffer: inventory.EffectBuffer = undefined;
    var effects = inventory.Effects.init(&effects_buffer);
    for (fixture.value.cases) |case| {
        const animation = try atx.Animation.parse(a, try archive.find(case.name, 0));
        defer animation.deinit(a);
        const frames = try a.alloc(i32, animation.instructions.len);
        defer a.free(frames);
        var first: ?i32 = null;
        for (animation.instructions, frames, 0..) |instruction, *frame, pc| {
            frame.* = @intCast(pc);
            if (instruction == .texture and first == null) first = @intCast(pc);
        }
        var programs = [_]?Program{.{ .animation = animation, .textures = frames }};
        var instances = [_]Instance{.{ .target = .{ .sector = 410, .wall = if (case.wall) 1 else null }, .slot = if (case.wall) 1 else 0, .resource = 0, .state = .{ .flags = if (case.wall) 2 else 1 } }};
        const runtime = Runtime{ .programs = &programs, .instances = &instances };
        const instance = &instances[0];
        const destination = if (case.wall) &level.sectors[410].walls[1].mid.texture else &level.sectors[410].floor.texture;
        destination.* = first.?;
        const dirty = if (case.wall) &scene.sectors[410].walls[1].runtime_flags else &scene.sectors[410].runtime_flags;
        for (case.samples) |sample| {
            events.clearRetainingCapacity();
            effects.clearRetainingCapacity();
            dirty.* = 0x80000004;
            if (sample.action.message) |code|
                try instance.state.message(animation, code, sample.action.arg1, sample.action.now, &events)
            else
                try instance.state.tick(animation, sample.action.now, &events);
            try runtime.apply(&level, &scene, instance, events.items, &effects);
            try std.testing.expectEqual(sample.rate, @as(u32, @bitCast(instance.state.rate)));
            try std.testing.expectEqual(sample.pc, instance.state.pc);
            try std.testing.expectEqual(sample.displayed, instance.state.displayed);
            try std.testing.expectEqual(sample.last_tick, instance.state.last_tick);
            try std.testing.expectEqual(sample.flags, instance.state.flags);
            try std.testing.expectEqual(sample.texture_pc, destination.*);
            try std.testing.expectEqual(sample.runtime_flags, dirty.*);
            try std.testing.expectEqual(sample.events.len, events.items.len);
            for (sample.events, events.items) |expected, actual| {
                if (expected.texture) |pc| try std.testing.expectEqual(atx.Event{ .texture = pc }, actual) else try std.testing.expectEqual(atx.Event{ .sound = expected.sound.? }, actual);
            }
            try std.testing.expectEqual(sample.sounds.len, effects.items.len);
            for (sample.sounds, effects.items) |expected, effect| {
                const request = effect.sound;
                const position = request.position.?;
                try std.testing.expectEqual(expected.position_bits, [_]u32{ @bitCast(position.x), @bitCast(position.y), @bitCast(position.z) });
                try std.testing.expectEqual(expected.priority, request.priority.?);
                try std.testing.expectEqual(expected.volume, request.volume.?);
                try std.testing.expectEqual(expected.flags, request.flags.?);
                try std.testing.expect(expected.owner_sector and request.sector == 410);
            }
        }
    }
}
