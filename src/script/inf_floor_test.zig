//! Moving floors and ceilings: the relays, every mover kind, the initial stops and how plane speed is read.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const lab = @import("../assets/lab.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const Actor = @import("../render/objects.zig").Actor;
const actor_links = @import("../render/actor_links.zig");
const geometry = @import("inf_geometry.zig");
const inf = @import("inf.zig");

const State = struct {
    sectors: []const struct {
        index: usize,
        floor_bits: u32,
        ceiling_bits: u32,
        walls: []const struct {
            index: usize,
            offset_bits: [4]u32,
            height_bits: [3]u32,
            render_flags: u32,
            runtime_flags: u32,
        },
    },
    actors: []const struct { index: usize, y_bits: u32 },
};

fn expectState(expected: State, level: *const level_module.Level, scene: *const scene_module.Scene, actors: []const Actor, slots: []const ?Actor) !void {
    for (expected.sectors) |sector| {
        const actual = level.sectors[sector.index];
        try std.testing.expectEqual(sector.floor_bits, @as(u32, @bitCast(actual.floor.height)));
        try std.testing.expectEqual(sector.ceiling_bits, @as(u32, @bitCast(actual.ceiling.height)));
        for (sector.walls) |wall| {
            const raw = actual.walls[wall.index];
            const state = scene.sectors[sector.index].walls[wall.index];
            try std.testing.expectEqual(wall.offset_bits, [_]u32{
                @bitCast(raw.top.offset.z), @bitCast(raw.mid.offset.z), @bitCast(raw.bottom.offset.z), @bitCast(raw.overlay.offset.z),
            });
            try std.testing.expectEqual(wall.height_bits, [_]u32{ @bitCast(state.top_height), @bitCast(state.mid_height), @bitCast(state.bottom_height) });
            try std.testing.expectEqual(wall.render_flags, state.render_flags);
            try std.testing.expectEqual(wall.runtime_flags, state.runtime_flags);
        }
    }
    for (expected.actors) |actor| {
        const entry = actors[actor.index];
        try std.testing.expectEqual(actor.y_bits, @as(u32, @bitCast(entry.position.y)));
        try std.testing.expectEqual(actor.y_bits, @as(u32, @bitCast(slots[entry.source_index.?].?.position.y)));
    }
}

fn verifyVerticalFixture(path: []const u8, digest: []const u8, startup: bool, expected_count: usize) !void {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []const struct {
            name: []const u8,
            kind: u32,
            primary: usize,
            slaves: []const usize,
            wall_flags: []const struct { sector: usize, index: usize, flags: u32 },
            actors: []const struct { sector: usize, flags: u32, y_bits: u32 },
            initial: State,
            samples: []const struct { delta_bits: u32, result_bits: u32, target_bits: u32 = 0, next_time: u32 = 0, speed_bits: u32 = 0, state: State },
        },
    };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.value.executable_sha256);
    try std.testing.expectEqualStrings(digest, fixture.value.results_sha256);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(128 * 1024 * 1024));
    defer a.free(data);
    const archive = try lab.Archive.init(data);
    const angles = camera.Angles.init();
    var case_count: usize = 0;
    for (fixture.value.cases) |case| {
        case_count += 1;
        var level = try level_module.Level.parse(a, try archive.find("TRAIN.LVB", 0));
        defer level.deinit();
        var scene = try scene_module.Scene.init(a, &level, &angles);
        defer scene.deinit();
        for (case.wall_flags) |wall| {
            level.sectors[wall.sector].walls[wall.index].flags = wall.flags;
            scene.sectors[wall.sector].walls[wall.index].flags = wall.flags;
        }
        for (case.initial.sectors) |sector| for (sector.walls) |wall| {
            scene.sectors[sector.index].walls[wall.index].runtime_flags = wall.runtime_flags;
        };
        var actors = try a.alloc(Actor, case.actors.len);
        defer a.free(actors);
        var slots = try a.alloc(?Actor, case.actors.len);
        defer a.free(slots);
        const source_to_entry = try a.alloc(?usize, case.actors.len);
        defer a.free(source_to_entry);
        var links = try actor_links.Links.init(a, level.sectors.len, case.actors.len);
        defer links.deinit();
        for (case.actors, actors, 0..) |definition, *actor, index| {
            const source = case.actors.len - 1 - index;
            actor.* = undefined;
            actor.source_index = source;
            actor.sector = definition.sector;
            actor.flags = definition.flags;
            actor.position = .{ .x = 0, .y = @bitCast(definition.y_bits), .z = 0 };
            slots[source] = actor.*;
            source_to_entry[source] = index;
            links.move(source, definition.sector);
        }
        var world = geometry.World{
            .level = &level,
            .scene = &scene,
            .angles = &angles,
            .actors = actors,
            .links = &links,
            .source_to_entry = source_to_entry,
            .live_entries = &actors,
            .live_slots = &slots,
            .collision_diameter = 0,
        };
        var runtime = inf.Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = undefined, .triggers = &.{}, .classes = &.{} };
        defer runtime.deinit();
        runtime.elevators = try runtime.arena.allocator().dupe(inf.Elevator, &.{.{
            .sector = case.primary,
            .kind = @enumFromInt(case.kind),
            .speed = 0,
            .value = 0,
            .runtime_flags = 3,
        }});
        for (case.slaves) |slave| try runtime.elevators[0].slaves.append(runtime.arena.allocator(), .{ .sector = slave });
        var random: u32 = 0x742389ac;
        expectState(case.initial, &level, &scene, actors, slots) catch |err| {
            std.debug.print("reference floor case {s}, initial state\n", .{case.name});
            return err;
        };
        for (case.samples, 0..) |sample, index| {
            const delta: f32 = @bitCast(sample.delta_bits);
            if (startup) {
                var arena = std.heap.ArenaAllocator.init(a);
                const mem = arena.allocator();
                level.sectors[case.primary].name = "PRIMARY";
                level.sectors[case.slaves[0]].name = "SLAVE";
                const text = try std.fmt.allocPrint(a, "INF 1.0\nITEMS 1\nITEM: SECTOR NAME: PRIMARY\nSEQ\nCLASS: ELEVATOR {s}\nSPEED: 27\nSTOP: {d} 0.25\nSLAVE: SLAVE\nSEQEND\n", .{ if (case.kind == 0) @as([]const u8, "MOVE_CEILING") else if (case.kind == 1) "MOVE_FLOOR" else "MOVE_FC", @as(f32, @bitCast(sample.target_bits)) });
                defer a.free(text);
                const originals = try mem.alloc([]const level_module.Vec2, level.sectors.len);
                for (level.sectors, originals) |sector, *original| original.* = try mem.dupe(level_module.Vec2, sector.vertices);
                var initial = try inf.Runtime.loadPreparedWithWorld(a, &level, text, &scene, &angles, 90000, .{ .arena = arena, .base_vertices = originals, .elevators = .empty, .triggers = .empty, .classes = .empty }, .{ .world = &world });
                defer initial.deinit();
                try std.testing.expectEqual(sample.result_bits, @as(u32, @bitCast(initial.elevators[0].value)));
                try std.testing.expectEqual(sample.speed_bits, @as(u32, @bitCast(initial.elevators[0].speed)));
                try std.testing.expectEqual(sample.next_time, initial.elevators[0].next_time);
                try expectState(sample.state, &level, &scene, actors, slots);
                continue;
            }
            runtime.elevators[0].speed = delta;
            try runtime.advance(&level, @intCast(index + 1), 1, .{ .world = &world, .random = &random });
            const result = if (case.kind == 0) level.sectors[case.primary].ceiling.height else level.sectors[case.primary].floor.height;
            try std.testing.expectEqual(sample.result_bits, @as(u32, @bitCast(result)));
            try std.testing.expectEqual(sample.result_bits, @as(u32, @bitCast(runtime.elevators[0].value)));
            expectState(sample.state, &level, &scene, actors, slots) catch |err| {
                std.debug.print("reference floor case {s}, sample {d}\n", .{ case.name, index });
                return err;
            };
        }
    }
    try std.testing.expectEqual(expected_count, case_count);
}

test "Train floor relays and all vertical mover kinds match the reference" {
    try verifyVerticalFixture("testdata/inf-vertical-reference.json", "a43de6ac2a1a1f6971e74983dd6276fc7f46706e98b5ae1c7e8f2f7aa703cc4b", false, 15);
}

test "initial vertical stops carry actors and update walls before play" {
    try verifyVerticalFixture("testdata/inf-startup-reference.json", "57276b0d924f3fed78a5e8997aa8248a7e96d1ce25371eb3653694ff125704e5", true, 3);
}

test "plane speed reads live heights and newest matching receiver" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/moving-planes-reference.json", a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Definition = struct {
        kind: u32,
        speed: f32,
        value: f32 = 0,
        target: ?f32 = null,
        active: bool = true,
        sector: usize = 0,
        deleted: bool = false,
    };
    const Fixture = struct {
        executable_sha256: []const u8,
        speed_cases: []const struct {
            name: []const u8,
            floor: f32,
            ceiling: f32,
            classes: []const Definition,
            result_bits: [2]u32,
        },
        sha256: []const u8,
    };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.value.executable_sha256);
    try std.testing.expectEqual(@as(usize, 14), fixture.value.speed_cases.len);
    try std.testing.expectEqualStrings("41ccd2a8b653c42c27ffdd6e3dd510f4ca076a9e84bee327fff9fe5a599ae270", fixture.value.sha256);
    for (fixture.value.speed_cases) |case| {
        errdefer std.debug.print("reference plane speed case {s}\n", .{case.name});
        var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)} ** 2;
        sectors[0].floor.height = case.floor;
        sectors[0].ceiling.height = case.ceiling;
        var level: level_module.Level = undefined;
        level.sectors = &sectors;
        var runtime = inf.Runtime{ .arena = std.heap.ArenaAllocator.init(a), .elevators = undefined, .triggers = &.{}, .classes = &.{} };
        defer runtime.deinit();
        const mem = runtime.arena.allocator();
        runtime.elevators = try mem.alloc(inf.Elevator, case.classes.len);
        for (runtime.elevators, case.classes) |*elevator, definition| {
            elevator.* = .{
                .sector = definition.sector,
                .kind = @enumFromInt(definition.kind),
                .speed = definition.speed,
                .value = definition.value,
                .runtime_flags = if (definition.active) 1 else 0,
                .deleted = definition.deleted,
            };
            if (definition.target) |target| {
                try elevator.stops.append(mem, .{ .value = target });
                elevator.target = 0;
            }
        }
        for ([_]bool{ false, true }, case.result_bits) |ceiling, expected|
            try std.testing.expectEqual(expected, @as(u32, @bitCast(runtime.planeSpeed(&level, 0, ceiling))));
    }
}
