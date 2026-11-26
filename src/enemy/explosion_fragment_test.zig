//! Exploding objects: the fragments they throw, their random draws, animation and physics.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const fragment = @import("explosion_fragment.zig");
const blood = @import("blood.zig");
const physics = @import("physics.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const nwx = @import("../assets/nwx.zig");
const lab = @import("../assets/lab.zig");

const Snapshot = struct {
    position_bits: [3]u32,
    velocity_bits: [3]u32,
    flags: u32,
    secondary_flags: u32,
    scale_bits: [2]u32,
    height_bits: u32,
    radius_bits: u32,
    floor_cache_bits: u32,
    playback: [8]u32,
    random: u32,
    same_sector: bool,
};

fn check(expected: Snapshot, particle: blood.Spawn, random: u32) !void {
    const actor = particle.actor;
    const playback = actor.playback.?;
    const actual = Snapshot{ .position_bits = bits(actor.position), .velocity_bits = bits(particle.state.velocity), .flags = actor.flags, .secondary_flags = actor.secondary_flags, .scale_bits = .{ @bitCast(actor.scale_x), @bitCast(actor.scale_y) }, .height_bits = @bitCast(actor.height), .radius_bits = @bitCast(actor.collision_radius), .floor_cache_bits = @bitCast(particle.state.floor_cache), .playback = .{ playback.last_time, @bitCast(@as(i32, playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags, @intFromBool(playback.terminated) }, .random = random, .same_sector = actor.sector == 0 };
    try std.testing.expectEqualDeep(expected, actual);
}

fn point(value: [3]f32) level_module.Vec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

fn bits(value: level_module.Vec3) [3]u32 {
    return .{ @bitCast(value.x), @bitCast(value.y), @bitCast(value.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "lamp fragment bursts RNG animation and physics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Config = struct {
        seed: u32,
        position: [3]f32,
        gravity: f32,
        ceiling: f32,
        floor: f32,
        friction: f32,
        elasticity: f32,
        dt: f32,
        conveyor: ?[3]f32 = null,
        floor_slope: ?[3]f32 = null,
    };
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const struct { config: Config, initial: []const Snapshot, frames: []const []const Snapshot } };
    const corpus = (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/lamp-fragments-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("696ef7c3582e27afdf22573122e0be43a856f6d0cef317050968350ec7d05e3b", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var costume = try nwx.Costume.parse(a, try archive.find(fragment.costume_name, 0));
    defer costume.deinit();
    const angles = camera.Angles.init();
    for (corpus.cases, 0..) |case, case_index| {
        errdefer std.debug.print("reference blood case{d}\n", .{case_index});
        const config = case.config;
        var sector = std.mem.zeroes(level_module.Sector);
        sector.vadjoin = -1;
        sector.gravity = config.gravity;
        sector.friction = config.friction;
        sector.elasticity = config.elasticity;
        sector.floor.height = config.floor;
        sector.ceiling.height = config.ceiling;
        if (config.conveyor) |conveyor| sector.velocity = point(conveyor);
        var level: level_module.Level = undefined;
        level.sectors = (&sector)[0..1];
        var sector_state = std.mem.zeroes(scene_module.SectorState);
        sector_state.velocity_present = config.conveyor != null;
        if (config.floor_slope) |slope| {
            sector_state.flags |= 0x40000000;
            sector_state.floor_slope = std.mem.zeroInit(scene_module.Slope, .{ .coeff_x = slope[0], .coeff_z = slope[1], .constant = slope[2] });
        }
        var scene: scene_module.Scene = undefined;
        scene.sectors = (&sector_state)[0..1];
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;
        const world = physics.World{ .allocator = a, .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} } };
        var random = config.seed;
        const count = (@import("../player/weapon.zig").randomNext(&random) & 3) * 2 + 2;
        try std.testing.expectEqual(case.initial.len, count);
        const particles = try a.alloc(blood.Spawn, count);
        for (particles) |*particle| particle.* = fragment.spawn(&costume, &random, 0, point(config.position), 1000);
        for (case.initial, particles) |expected, particle| try check(expected, particle, random);
        var now: u32 = 1000;
        for (case.frames, 0..) |frame, frame_index| {
            errdefer std.debug.print("reference fragment frame{d}\n", .{frame_index});
            now += 50;
            for (particles) |*particle| {
                try particle.actor.advanceUnboundAnimation(now);
                try blood.generalPhysics(&particle.actor, &particle.state, world, config.dt);
            }
            for (frame, particles) |expected, particle| try check(expected, particle, random);
        }
    }
}
