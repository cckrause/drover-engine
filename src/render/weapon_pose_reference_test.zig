//! Weapon recoil poses and the sector probe behind them.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const pose_module = @import("weapon_pose.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("scene.zig");
const initial_state = @import("initial_state.zig");
const camera = @import("backends/software/camera.zig");
const movement = @import("../player/movement.zig");
const lab = @import("../assets/lab.zig");

fn vector(words: [3]u32) level_module.Vec3 {
    return .{ .x = @bitCast(words[0]), .y = @bitCast(words[1]), .z = @bitCast(words[2]) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
}

test "weapon recoil poses and sector probes match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Result = struct {
        eye: [3]u32,
        pitch: i16,
        sector: usize,
    };
    const Point = struct { sector: usize, point: [3]u32, result: ?usize };
    const Case = struct { sector: usize, position: [3]u32, yaw: i16, pitch: i16, head_yaw: i16, eye_height: u32, head_bob: u32, kick: u32, result: Result };
    const fixture = (try std.json.parseFromSlice(struct { executable_sha256: []const u8, points: []const Point, poses: []const Case }, a, try read(a, "testdata/weapon-pose-reference.json"), .{})).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.executable_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    var initial = try initial_state.InfStartup.apply(a, &level, try archive.find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    initial.applyScene(&level, &scene);
    for (fixture.points, 0..) |point, i| {
        errdefer std.debug.print("View sector probe{d}: {any}\n", .{ i, point });
        try std.testing.expectEqual(point.result, try pose_module.locate(&level, &scene, point.sector, vector(point.point)));
    }
    var player = std.mem.zeroes(movement.Player);
    for (fixture.poses, 0..) |case, i| {
        errdefer std.debug.print("View recoil case{d}: {any}\n", .{ i, case });
        player.position = vector(case.position);
        player.sector = case.sector;
        player.yaw = case.yaw;
        player.pitch = case.pitch;
        player.head_yaw = case.head_yaw;
        player.eye_height = @bitCast(case.eye_height);
        player.head_bob = @bitCast(case.head_bob);
        const actual = try pose_module.pose(&level, &scene, &angles, &player, @bitCast(case.kick));
        try std.testing.expectEqualDeep(case.result, Result{ .eye = .{ @bitCast(actual.eye.x), @bitCast(actual.eye.y), @bitCast(actual.eye.z) }, .pitch = actual.pitch, .sector = actual.sector });
    }
}
