//! Blood with a non-finite position: the floor branch keeps its payload and the drop is removed before collision runs.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const blood = @import("blood.zig");
const physics = @import("physics.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const shooting = @import("../player/shooting.zig");
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const Vec3 = level_module.Vec3;

const Snapshot = struct {
    position_bits: [3]u32,
    velocity_bits: [3]u32,
    flags: u32,
    floor_cache_bits: u32,
    random: u32,
};

const Impact = struct {
    raw_bits: [3]u32,
    flags: u32,
    messages: []const struct {
        position_bits: [3]u32,
        damage_bits: u32,
        mass_bits: u32,
        speed_bits: u32,
        lateral_bits: u32,
        height_bits: u32,
    },
    visuals: []const struct { kind: []const u8, sector: usize, count: u32, position_bits: [3]u32 },
};

const Fixture = struct {
    executable_sha256: []const u8,
    results_sha256: []const u8,
    impacts: []const Impact,
    cases: []const struct {
        name: []const u8,
        position_bits: [3]u32,
        floor_bits: u32,
        floor_slope: ?[3]f32,
        initial: Snapshot,
        state: Snapshot,
        removed: bool,
        physics_calls: u32,
    },
};

fn pendingHit(angles: *const camera.Angles, impact: Impact, target: usize) shooting.PendingHit {
    const raw = fromBits(impact.raw_bits);
    var pending = shooting.PendingHit.init(target, angles, .{ .kind = 2, .damage = 4, .mass = 0.5, .speed = 100, .yaw = 0, .pitch = 0, .lateral = 1.5, .height = 5 }, .{ .index = target, .position = raw, .lateral = 1.5, .height = 5, .distance = raw.z });
    pending.position.x = raw.x;
    if (impact.flags & 0x10 == 0) {
        const visual = if (impact.flags & 0x4180 != 0) &pending.blood else &pending.dust;
        visual.add(angles, .{ .x = 3.25, .y = 10, .z = -6.75 }, raw, 0, 73, 3, impact.flags & 0x4180 == 0);
    }
    return pending;
}

fn check(expected: Snapshot, particle: blood.Spawn, random: u32) !void {
    try std.testing.expectEqualDeep(expected, Snapshot{
        .position_bits = bits(particle.actor.position),
        .velocity_bits = bits(particle.state.velocity),
        .flags = particle.actor.flags,
        .floor_cache_bits = @bitCast(particle.state.floor_cache),
        .random = random,
    });
}

fn loadFixture(a: std.mem.Allocator) !Fixture {
    const fixture = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/blood-nan-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.executable_sha256);
    try std.testing.expectEqualStrings("3250d406366d1007e7e49d6a05b789cf2b23968b7283cddb17d668b0d411591e", fixture.results_sha256);
    return fixture;
}

fn fromBits(words: [3]u32) Vec3 {
    return .{ .x = @bitCast(words[0]), .y = @bitCast(words[1]), .z = @bitCast(words[2]) };
}

fn bits(value: Vec3) [3]u32 {
    return .{ @bitCast(value.x), @bitCast(value.y), @bitCast(value.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "NaN blood floor branch preserves payloads and removes before collision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try loadFixture(a);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var costume = try nwx.Costume.parse(a, try archive.find(blood.costume_name, 0));
    defer costume.deinit();
    const angles = camera.Angles.init();
    for (fixture.impacts) |impact| {
        const pending = pendingHit(&angles, impact, 20);
        try std.testing.expectEqual(@as(usize, 1), impact.messages.len);
        const expected = impact.messages[0];
        const damage = pending.damageInput();
        try std.testing.expectEqualDeep(expected.position_bits, bits(pending.messagePosition()));
        try std.testing.expectEqualDeep(
            [5]u32{ expected.damage_bits, expected.mass_bits, expected.speed_bits, expected.lateral_bits, expected.height_bits },
            [5]u32{ @bitCast(damage.damage), @bitCast(damage.mass), @bitCast(damage.speed), @bitCast(damage.lateral), @bitCast(damage.height) },
        );
        if (impact.visuals.len == 0) {
            try std.testing.expectEqual(@as(i32, 0), pending.blood.count);
            try std.testing.expectEqual(@as(i32, 0), pending.dust.count);
        } else {
            try std.testing.expectEqual(@as(usize, 1), impact.visuals.len);
            const visual = impact.visuals[0];
            const actual = if (std.mem.eql(u8, visual.kind, "blood")) pending.blood else pending.dust;
            try std.testing.expectEqual(visual.count, @as(u32, @bitCast(actual.count)));
            try std.testing.expectEqual(visual.sector, actual.sector);
            try std.testing.expectEqualDeep(visual.position_bits, bits(actual.average()));
        }
    }
    for (fixture.cases) |case| {
        errdefer std.debug.print("native NaN blood boundary {s}\n", .{case.name});
        var sector = std.mem.zeroInit(level_module.Sector, .{ .vadjoin = -1 });
        sector.floor.height = @bitCast(case.floor_bits);
        sector.ceiling.height = 100;
        var level: level_module.Level = undefined;
        level.sectors = (&sector)[0..1];
        var state = std.mem.zeroes(scene_module.SectorState);
        if (case.floor_slope) |slope| {
            state.flags = 0x40000000;
            state.floor_slope = std.mem.zeroInit(scene_module.Slope, .{ .coeff_x = slope[0], .coeff_z = slope[1], .constant = slope[2] });
        }
        var scene: scene_module.Scene = undefined;
        scene.sectors = (&state)[0..1];
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;
        const world = physics.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} } };
        var random: u32 = 0x742389ac;
        var particle = try blood.spawn(&costume, &random, 0, fromBits(case.position_bits), 1000);
        particle.state.velocity = .{ .x = 0, .y = 0, .z = 0 };
        try check(case.initial, particle, random);
        try std.testing.expectEqual(@as(u32, @intFromBool(!case.removed)), case.physics_calls);
        try std.testing.expectEqual(case.removed, try blood.tick(&particle.actor, &particle.state, world, 0.05));
        try check(case.state, particle, random);
    }
}

test "NaN blood contact survives delivery and is removed on next live frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try loadFixture(a);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try @import("../render/session.zig").Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, archive, &startup);
    defer session.deinit(a);
    const pixels = try a.alloc(u8, 640 * 480);
    _ = try session.render(a, pixels, session.animation_time);
    const victim = for (session.targets, 0..) |optional, index| {
        if (optional) |target| if (!target.dead and target.native == .enemy) break index;
    } else return error.MissingOriginalEnemyPlacement;
    const health = session.targets[victim].?.damage.health;
    var pending = pendingHit(&session.angles, fixture.impacts[0], victim);
    pending.blood.sector = session.player.sector;
    try session.pending_hits.append(session.arena.allocator(), pending);
    const first = session.actor_slots.len;
    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(first + 3, session.actor_slots.len);
    for (first..first + 3) |index| {
        const actor = session.actor_slots[index].?;
        try std.testing.expectEqualStrings("fx_BloodLogic", actor.logic_name);
        try std.testing.expectEqualDeep(fixture.impacts[0].visuals[0].position_bits, bits(actor.position));
        try std.testing.expect(!session.removed_actors[index]);
        try std.testing.expectEqual(@as(u32, 0), actor.flags & 0x400);
    }
    _ = try session.render(a, pixels, session.animation_time);
    try session.advance(a, &.{}, 16);
    try std.testing.expect(session.targets[victim].?.damage.health < health);
    for (first..first + 3) |index| try std.testing.expect(session.removed_actors[index]);
    _ = try session.render(a, pixels, session.animation_time);
    try session.advance(a, &.{}, 16);
    for (first..first + 3) |index| try std.testing.expect(session.removed_actors[index]);
}
