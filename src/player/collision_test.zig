//! Player collision: walls, portals, double adjoins, actors, and the sliding behaviour without a hinge.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const collision = @import("collision.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const initial_state = @import("../render/initial_state.zig");
const camera = @import("../render/backends/software/camera.zig");
const Actor = @import("../render/objects.zig").Actor;

fn hashSample(hash: *std.crypto.hash.sha2.Sha256, level: *const level_module.Level, scene: *const scene_module.Scene, old: [3]f64, target: [3]f64, speed: [3]f64, step: f32, floor_cache: f32) !void {
    var desired = point64(target);
    var velocity = point64(speed);
    var floor: f32 = floor_cache;
    const result = try collision.resolve(std.testing.allocator, level, scene, .{ .entries = &.{} }, 410, point64(old), &desired, &velocity, 6, 1.5, step, &floor);
    const values = [_]u32{if (result.sector) |sector| @intCast(sector) else 0xffffffff} ++ bitPattern(desired) ++ bitPattern(velocity) ++ [_]u32{ @bitCast(floor), @intCast(result.actor_sector) } ++ bitPattern(result.position);
    for (values) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        hash.update(&bytes);
    }
}

fn checkReference(path: []const u8) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reference = try read(a, path);
    const Body = struct {
        sector: usize,
        position: [3]f32,
        flags: u32,
        secondary_flags: u32,
        height: f32,
        collision_radius: f32,
    };
    const Case = struct {
        name: []const u8,
        sector: usize,
        old: [3]f32,
        desired: [3]f32,
        velocity: [3]f32,
        height: f32,
        radius: f32,
        step: f32,
        floor_cache: f32,
        actors: []Body,
        result_sector: ?usize,
        position_bits: [3]u32,
        actor_position_bits: [3]u32,
        actor_sector: usize,
        velocity_bits: [3]u32,
        floor_bits: u32,
        slope_enabled: ?bool = null,
    };
    const parsed = try std.json.parseFromSlice(struct { executable_sha256: []const u8, cases: []Case }, a, reference, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", parsed.value.executable_sha256);
    const archive = try @import("../assets/lab.zig").Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    var initial = try initial_state.InfStartup.apply(a, &level, try archive.find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    initial.applyScene(&level, &scene);
    for (parsed.value.cases) |case| {
        const original = scene.sectors[case.sector];
        defer scene.sectors[case.sector] = original;
        if (case.slope_enabled) |enabled| {
            var slope = std.mem.zeroes(scene_module.Slope);
            slope.constant = 3;
            scene.sectors[case.sector].ceiling_slope = slope;
            scene.sectors[case.sector].flags &= ~@as(u32, 0x80000000);
            if (enabled) scene.sectors[case.sector].flags |= 0x80000000;
        }
        const actors = try a.alloc(Actor, case.actors.len);
        for (case.actors, actors) |source, *actor| {
            actor.* = undefined;
            actor.sector = source.sector;
            actor.position = point(source.position);
            actor.flags = source.flags;
            actor.secondary_flags = source.secondary_flags;
            actor.height = source.height;
            actor.collision_radius = source.collision_radius;
        }
        var desired = point(case.desired);
        var velocity = point(case.velocity);
        var floor_cache = case.floor_cache;
        const result = try collision.resolve(allocator, &level, &scene, .{ .entries = actors }, case.sector, point(case.old), &desired, &velocity, case.height, case.radius, case.step, &floor_cache);
        const actual_position = bitPattern(desired);
        const actual_velocity = bitPattern(velocity);
        const actor_position = bitPattern(result.position);
        if (case.result_sector != result.sector or
            case.actor_sector != result.actor_sector or
            !std.mem.eql(u32, &case.actor_position_bits, &actor_position) or
            !std.mem.eql(u32, &case.position_bits, &actual_position) or
            !std.mem.eql(u32, &case.velocity_bits, &actual_velocity) or
            @as(u32, @bitCast(floor_cache)) != case.floor_bits)
        {
            std.debug.print("\nOriginal collision case {s}: sector {?d}/{?d}, position {any}/{any}, velocity {any}/{any}, floor {x}/{x}\n", .{
                case.name,          case.result_sector, result.sector,   case.position_bits,              actual_position,
                case.velocity_bits, actual_velocity,    case.floor_bits, @as(u32, @bitCast(floor_cache)),
            });
        }
        try std.testing.expectEqual(case.result_sector, result.sector);
        try std.testing.expectEqual(case.actor_sector, result.actor_sector);
        try std.testing.expectEqualSlices(u32, &case.actor_position_bits, &actor_position);
        try std.testing.expectEqualSlices(u32, &case.position_bits, &actual_position);
        try std.testing.expectEqualSlices(u32, &case.velocity_bits, &actual_velocity);
        try std.testing.expectEqual(case.floor_bits, @as(u32, @bitCast(floor_cache)));
    }
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn point(v: [3]f32) level_module.Vec3 {
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

fn point64(v: [3]f64) level_module.Vec3 {
    return .{ .x = @floatCast(v[0]), .y = @floatCast(v[1]), .z = @floatCast(v[2]) };
}

fn bitPattern(v: level_module.Vec3) [3]u32 {
    return .{ @bitCast(v.x), @bitCast(v.y), @bitCast(v.z) };
}

test "Hideout collision corpus retains the pinned reference hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archive = try @import("../assets/lab.zig").Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    var initial = try initial_state.InfStartup.apply(a, &level, try archive.find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    initial.applyScene(&level, &scene);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const start = [3]f64{ 322.36, -3, 271.88 };
    const deltas = [_][2]f64{
        .{ 0, 0 },    .{ 0.125, 0 }, .{ -0.125, 0 }, .{ 0, 0.125 }, .{ 0, -0.125 },
        .{ -9, 0 },   .{ -10, 0 },   .{ -11, 0 },    .{ -12, 0 },   .{ -30, 0 },
        .{ 50, 0 },   .{ 52, 0 },    .{ 60, 0 },     .{ 70, 0 },    .{ 0, 60 },
        .{ 15, 70 },  .{ -11, 12 },  .{ -11, -12 },  .{ 50, -30 },  .{ 100, 100 },
        .{ 0, -200 },
    };
    for (deltas) |delta| try hashSample(&hash, &level, &scene, start, .{ start[0] + delta[0], start[1], start[2] + delta[1] }, .{ delta[0] * 4, 0, delta[1] * 4 }, 2.5, -0x1p31);
    for ([_]f64{ -3, -2.5, 0, 42, 50 }) |y|
        try hashSample(&hash, &level, &scene, start, .{ start[0], y, start[2] }, .{ 0, 5, 0 }, 2.5, -0x1p31);
    for ([_][2]f64{ .{ -0.2, 0 }, .{ -0.2, 1 }, .{ -1, -1 }, .{ -3, 2 } }) |delta| {
        const old = [3]f64{ 313.6, -3, 271.88 };
        try hashSample(&hash, &level, &scene, old, .{ old[0] + delta[0], old[1], old[2] + delta[1] }, .{ delta[0] * 50, 0, delta[1] * 50 }, 2.5, -0x1p31);
    }
    for ([_][2]f64{ .{ -0.2, 0 }, .{ -0.2, 0.1 }, .{ -0.5, 0 }, .{ -0.5, 0.25 } }) |delta| {
        const old = [3]f64{ 312.1, -3, 271.88 };
        try hashSample(&hash, &level, &scene, old, .{ old[0] + delta[0], old[1], old[2] + delta[1] }, .{ delta[0] * 50, 0, delta[1] * 50 }, 2.5, 7.25);
    }
    const sector = level.sectors[410];
    for (sector.walls, scene.sectors[410].walls) |wall, state| {
        if (wall.adjoin < 0) continue;
        const first = sector.vertices[wall.v1];
        const last = sector.vertices[wall.v2];
        const x = (@as(f64, first.x) + last.x) * 0.5;
        const z = (@as(f64, first.z) + last.z) * 0.5;
        const dx: f64 = state.direction.x;
        const dz: f64 = state.direction.z;
        for ([_]f32{ 2.5, 4 }) |step|
            try hashSample(&hash, &level, &scene, .{ x + dz * 3, -3, z - dx * 3 }, .{ x - dz * 3, -3, z + dx * 3 }, .{ -dz * 20, 0, dx * 20 }, step, -0x1p31);
    }
    try std.testing.expectEqualStrings("7f9a4db24cbfed40fa036ead08201d2020ebe117bd3cea0a55732c666f054a54", &std.fmt.bytesToHex(hash.finalResult(), .lower));
}

test "double adjoin collision revisits the lower sector as the reference does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archive = try @import("../assets/lab.zig").Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    var initial = try initial_state.InfStartup.apply(a, &level, try archive.find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    initial.applyScene(&level, &scene);
    const old = point(.{ 377.39398193359375, -3, 189.515625 });
    var desired = point(.{ 377.6492919921875, -3, 189.133544921875 });
    var velocity = point(.{ 15.955978393554688, 0, -23.879810333251953 });
    var floor: f32 = -3;
    const result = try collision.resolve(std.testing.allocator, &level, &scene, .{ .entries = &.{} }, 405, old, &desired, &velocity, 5.99, 1.5, 3, &floor);
    try std.testing.expectEqual(@as(?usize, 405), result.sector);
    try std.testing.expectEqual(@as(usize, 405), result.actor_sector);
    const expected_position = [_]u32{ 1136448284, 3225419776, 1128079920 };
    try std.testing.expectEqualSlices(u32, &expected_position, &bitPattern(desired));
    try std.testing.expectEqualSlices(u32, &expected_position, &bitPattern(result.position));
    try std.testing.expectEqualSlices(u32, &.{ 1098861488, 0, 3250522586 }, &bitPattern(velocity));
    try std.testing.expectEqual(@as(u32, 3225419776), @as(u32, @bitCast(floor)));
}

test "hinge-less sector contact uses the remembered wall or does not slide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archive = try @import("../assets/lab.zig").Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    var initial = try initial_state.InfStartup.apply(a, &level, try archive.find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    initial.applyScene(&level, &scene);
    try std.testing.expect(scene.sectors[410].ceiling_slope == null);
    const old = point(.{ 322.36, -10, 271.88 });
    const Run = struct {
        fn run(lvl: *const level_module.Level, scn: *const scene_module.Scene, start: level_module.Vec3, memory: ?*collision.WallMemory, desired: *level_module.Vec3) !collision.Result {
            desired.* = .{ .x = start.x + 0.3, .y = start.y, .z = start.z + 0.4 };
            var velocity = point(.{ 9, 0, 12 });
            var floor: f32 = -3;
            return collision.resolveWithOptions(std.testing.allocator, lvl, scn, .{ .entries = &.{} }, 410, start, desired, &velocity, 6, 1.5, 2.5, &floor, .{ .wall_memory = memory });
        }
    };
    var desired: level_module.Vec3 = undefined;
    var result = try Run.run(&level, &scene, old, null, &desired);
    try std.testing.expectEqualSlices(u32, &bitPattern(old), &bitPattern(result.position));
    var empty: collision.WallMemory = .{};
    result = try Run.run(&level, &scene, old, &empty, &desired);
    try std.testing.expectEqualSlices(u32, &bitPattern(old), &bitPattern(result.position));
    var touched: collision.WallMemory = .{};
    const near = point(.{ 313.6, -3, 271.88 });
    var target = point(.{ 313.4, -3, 272.88 });
    var velocity = point(.{ -10, 0, 50 });
    var floor: f32 = -0x1p31;
    _ = try collision.resolveWithOptions(std.testing.allocator, &level, &scene, .{ .entries = &.{} }, 410, near, &target, &velocity, 6, 1.5, 2.5, &floor, .{ .wall_memory = &touched });
    try std.testing.expectEqualDeep(@as(?collision.WallMemory.Line, .{ .direction = .{ .x = 0, .z = 1 }, .origin = .{ .x = 312, .z = 86 } }), touched.last);
    const line = collision.WallMemory.Line{ .direction = .{ .x = 0, .z = 1 }, .origin = .{ .x = old.x - 1, .z = 0 } };
    var remembered: collision.WallMemory = .{ .last = line };
    result = try Run.run(&level, &scene, old, &remembered, &desired);
    try std.testing.expectEqualSlices(u32, &bitPattern(old), &bitPattern(result.position));
    const dx: f32 = (old.x + 0.3) - old.x;
    const dz: f32 = (old.z + 0.4) - old.z;
    const tangent: f32 = @floatCast(@as(f64, line.direction.x) * dx + @as(f64, line.direction.z) * dz);
    const push: f32 = @floatCast((@as(f64, 1.5) + 0.001) - ((@as(f64, old.x) - line.origin.x) * line.direction.z - (@as(f64, old.z) - line.origin.z) * line.direction.x));
    const slid_x: f32 = @floatCast(@as(f64, line.direction.z) * push + @as(f64, line.direction.x) * tangent);
    const slid_z: f32 = @floatCast(@as(f64, tangent) * line.direction.z - @as(f64, line.direction.x) * push);
    try std.testing.expect(push != 0);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, @floatCast(@as(f64, old.x) + slid_x)))), @as(u32, @bitCast(desired.x)));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, @floatCast(@as(f64, old.z) + slid_z)))), @as(u32, @bitCast(desired.z)));
}

test "player collision matches the reference on Hideout walls portals and actors" {
    try checkReference("testdata/player-collision-reference.json");
}

test "hanging actor collision follows the live ceiling slope flag" {
    try checkReference("testdata/actor-slope-flags-reference.json");
}
