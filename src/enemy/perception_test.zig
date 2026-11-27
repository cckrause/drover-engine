//! Enemy senses: field of view, sampled rays, navigation points and the crouch probe.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const perception = @import("perception.zig");
const occlusion = @import("../audio/occlusion.zig");
const level = @import("../assets/level.zig");
const scene = @import("../render/scene.zig");
const Angles = @import("../render/backends/software/camera.zig").Angles;

const FovCase = struct {
    from: [3]f32,
    to: [3]f32,
    yaw: i16,
    source_secondary: u32,
    target_secondary: u32,
    target_flags: u32,
    height: f32,
    source_light: i32,
    target_light: i32,
    fov_dist: f32,
    fov: i16,
    kill_dist: f32,
    now: u32,
    last_seen: u32,
    player_visible: bool,
    expected: struct { heading: i16, kill: bool },
};

const RayCase = struct {
    seed: u32,
    positions: [2][3]f32,
    heights: [2]f32,
    radii: [2]f32,
    slopes: [2]?[3]f32 = .{ null, null },
    expected: struct { endpoints_bits: [6]u32, random: u32 },
};

const PointCase = struct {
    seed: u32,
    origin: [2]f32,
    angles: [2]i16,
    radii: [2]f32,
    expected: struct { position_bits: [2]u32, yaw: i16, random: u32 },
};

fn vec(value: [3]f32) level.Vec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

test "enemy FOV, sampled actor rays and navigation points match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/enemy-perception-reference.json", a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        fov: []FovCase,
        rays: []RayCase,
        points: []PointCase,
    };
    const parsed = try std.json.parseFromSlice(Corpus, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", parsed.value.executable_sha256);
    try std.testing.expectEqualStrings("b53986ad9608d5b2e8b84e7c3f27ed0b015e7a17d629f3efe6c7054fbd5ad145", parsed.value.results_sha256);
    const angles = Angles.init();
    for (parsed.value.fov, 0..) |sample, index| {
        errdefer std.debug.print("original FOV sample {d}\n", .{index});
        const from = perception.Subject{ .position = vec(sample.from), .sector = 0, .height = 6, .radius = 1.5, .yaw = sample.yaw, .flags = 1, .secondary_flags = sample.source_secondary };
        const to = perception.Subject{ .position = vec(sample.to), .sector = 1, .height = sample.height, .radius = 1.5, .yaw = 0, .flags = sample.target_flags, .secondary_flags = sample.target_secondary };
        var kill = false;
        const heading = perception.fieldOfView(from, to, sample.source_light, sample.target_light, sample.fov_dist, sample.fov, sample.kill_dist, sample.last_seen, sample.now, sample.player_visible, &kill);
        try std.testing.expectEqual(sample.expected.heading, heading);
        try std.testing.expectEqual(sample.expected.kill, kill);
    }
    var sectors: [2]level.Sector = undefined;
    for (&sectors) |*sector| sector.ceiling.height = 64;
    var geometry: level.Level = undefined;
    geometry.sectors = &sectors;
    var states = [_]scene.SectorState{.{ .flags = 0, .runtime_flags = 0, .floor_slope = null, .ceiling_slope = null, .walls = &.{} }} ** 2;
    var state: scene.Scene = undefined;
    state.sectors = &states;
    var collision_check: u32 = 0;
    state.collision_check = &collision_check;
    for (parsed.value.rays, 0..) |sample, index| {
        errdefer std.debug.print("reference actor ray sample {d}\n", .{index});
        var random = sample.seed;
        for (&states, sample.slopes) |*sector, parameters| {
            sector.flags = 0;
            sector.ceiling_slope = null;
            if (parameters) |values| {
                var slope: scene.Slope = undefined;
                slope.coeff_x = values[0];
                slope.coeff_z = values[1];
                slope.constant = values[2];
                sector.ceiling_slope = slope;
                sector.flags = 0x80000000;
            }
        }
        const result = try occlusion.sampleActorRay(&geometry, &state, &angles, .{ .position = vec(sample.positions[0]), .sector = 0, .height = sample.heights[0], .radius = sample.radii[0] }, .{ .position = vec(sample.positions[1]), .sector = 1, .height = sample.heights[1], .radius = sample.radii[1] }, &random);
        try std.testing.expectEqual(sample.expected.endpoints_bits, [6]u32{ @bitCast(result.start.x), @bitCast(result.start.y), @bitCast(result.start.z), @bitCast(result.end.x), @bitCast(result.end.y), @bitCast(result.end.z) });
        try std.testing.expectEqual(sample.expected.random, random);
    }
    for (parsed.value.points, 0..) |sample, index| {
        errdefer std.debug.print("reference random point sample {d}\n", .{index});
        var random = sample.seed;
        const result = perception.randomPoint(&angles, &random, .{ .x = sample.origin[0], .z = sample.origin[1] }, sample.angles[0], sample.angles[1], sample.radii[0], sample.radii[1]);
        try std.testing.expectEqual(sample.expected.position_bits, [2]u32{ @bitCast(result.point.x), @bitCast(result.point.z) });
        try std.testing.expectEqual(sample.expected.yaw, result.yaw);
        try std.testing.expectEqual(sample.expected.random, random);
    }
}
