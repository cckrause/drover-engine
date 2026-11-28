//! Enemy movement and the commit that applies it, plus the corpse constructor.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const level_module = @import("../assets/level.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene_module = @import("../render/scene.zig");
const lifecycle = @import("lifecycle.zig");
const physics = @import("physics.zig");
const Actor = @import("../render/objects.zig").Actor;
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const bits = @import("../util/bits.zig");
const ActorFlags = @import("../actor_flags.zig").ActorFlags;
const ActorKind = @import("../actor_flags.zig").ActorKind;

const Snapshot = struct {
    position_bits: [3]u32,
    velocity_bits: [3]u32,
    health_bits: u32,
    speed_bits: u32,
    floor_bits: u32,
    complete: u8,
    disabled: u8,
    landed: u8,
    movement_mode: u32,
    desired_yaw: i16,
    yaw: i16,
    blocked_until: u32,
    next_tick: u32,
    actor_position_bits: [3]u32,
    actor_yaw: i16,
    flags: u32,
};

fn expectSnapshot(
    expected: Snapshot,
    actor: Actor,
    state: physics.State,
    health: f32,
    next_tick: u32,
) !void {
    try std.testing.expectEqual(expected.position_bits, vectorBits(state.position));
    try std.testing.expectEqual(expected.velocity_bits, vectorBits(state.velocity));
    try std.testing.expectEqual(expected.health_bits, @as(u32, @bitCast(health)));
    try std.testing.expectEqual(expected.speed_bits, @as(u32, @bitCast(state.move_speed)));
    try std.testing.expectEqual(expected.floor_bits, @as(u32, @bitCast(state.floor_cache)));
    try std.testing.expectEqual(expected.complete != 0, state.move_complete);
    try std.testing.expectEqual(expected.disabled != 0, state.movement_disabled);
    try std.testing.expectEqual(expected.landed != 0, state.landed);
    try std.testing.expectEqual(expected.movement_mode, state.movement_mode);
    try std.testing.expectEqual(expected.desired_yaw, state.desired_yaw);
    try std.testing.expectEqual(expected.yaw, state.yaw);
    try std.testing.expectEqual(expected.blocked_until, state.blocked_until);
    try std.testing.expectEqual(expected.next_tick, next_tick);
    try std.testing.expectEqual(expected.actor_position_bits, vectorBits(actor.position));
    try std.testing.expectEqual(expected.actor_yaw, actor.yaw);
    try std.testing.expectEqual(expected.flags, bits.word(actor.flags));
}

fn point(value: [3]f32) level_module.Vec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

fn pointBits(value: [3]u32) level_module.Vec3 {
    return .{ .x = @bitCast(value[0]), .y = @bitCast(value[1]), .z = @bitCast(value[2]) };
}

fn vectorBits(value: level_module.Vec3) [3]u32 {
    return .{ @bitCast(value.x), @bitCast(value.y), @bitCast(value.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "enemy damping movement and commit match the reference bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct {
        dt: f32,
        position: [3]f32,
        goal: [3]f32,
        velocity: [3]f32,
        movement_mode: u32,
        player: ?struct { position: [3]f32, flags: u32, secondary_flags: u32 } = null,
        initial: Snapshot,
        moving: bool,
        damped: Snapshot,
        returned: u32,
        moved: Snapshot,
        committed: Snapshot,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        config: struct { walk_speed_bits: u32, run_speed_bits: u32 },
        cases: []Case,
        player_cases: []Case,
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/enemy-physics-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "184bc75864cb9f7ad3cac0726b6017f89c32194bc61acd7a688c0031b330c831",
        corpus.results_sha256,
    );

    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var costume = try nwx.Costume.parse(a, try archive.find("BGY4.NWX", 0));
    defer costume.deinit();
    const radius = (try costume.select(0, 0, 0, 0)).parts[0].width * 0.5;
    var sector = std.mem.zeroes(level_module.Sector);

    sector.vadjoin = -1;
    sector.ceiling.height = 64;

    var level: level_module.Level = undefined;
    level.sectors = (&sector)[0..1];

    var state = std.mem.zeroes(scene_module.SectorState);
    var scene: scene_module.Scene = undefined;

    scene.sectors = (&state)[0..1];
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;

    const angles = camera.Angles.init();
    const world = physics.World{
        .level = &level,
        .scene = &scene,
        .angles = &angles,
        .actors = .{ .entries = &.{} },
    };

    const config = physics.Config{
        .walk_speed = @bitCast(corpus.config.walk_speed_bits),
        .run_speed = @bitCast(corpus.config.run_speed_bits),
        .walk_chor = 1,
        .run_chor = 2,
        .step_height = 3,
        .drop_height = 15,
    };

    const Selection = struct {
        pub fn select(_: *@This(), _: u32) !void {
            return error.UnexpectedOriginalPhysicsSelection;
        }
    };

    var selection: Selection = .{};
    const cases = try std.mem.concat(a, Case, &.{ corpus.cases, corpus.player_cases });

    for (cases, 0..) |case, index| {
        errdefer std.debug.print(
            "reference enemy physics case {d}, dt={d}, mode={d}, pos={any}, velocity={any}\n",
            .{ index, case.dt, case.movement_mode, case.position, case.velocity },
        );

        var actor = Actor{
            .costume = &costume,
            .sector = 0,
            .position = point(case.position),
            .yaw = -345,
            .flags = .{ .active = true, .unused_1 = true, .visible = true, .shaded = true, .has_logic = true, .not_solid = true, .physics = true, .dead = true },
            .secondary_flags = .{ .ai_controlled = true, .enemy = true },
            .scale_x = 1,
            .scale_y = 1,
            .height = 6,
            .collision_radius = radius,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };

        var body = physics.State{
            .velocity = point(case.velocity),
            .goal = point(case.goal),
            .position = point(case.position),
            .yaw = -345,
            .desired_yaw = 273,
            .move_speed = 12,
            .movement_disabled = case.movement_mode == 0,
            .movement_mode = case.movement_mode,
        };

        var health: f32 = 2;
        var next_tick: u32 = 11000;
        var case_world = world;

        if (case.player) |player| case_world.actors.player = .{
            .position = point(player.position),
            .sector = 0,
            .height = 6,
            .radius = 1.5,
            .flags = bits.from(ActorFlags, player.flags),
            .secondary_flags = bits.from(ActorKind, player.secondary_flags),
        };

        try expectSnapshot(case.initial, actor, body, health, next_tick);
        try std.testing.expectEqual(
            case.moving,
            try physics.damp(actor, &body, case_world, case.dt),
        );

        try expectSnapshot(case.damped, actor, body, health, next_tick);
        const event = try physics.move(
            &actor,
            &body,
            &health,
            0,
            if (case.movement_mode == 1) 2 else 1,
            config,
            case_world,
            case.dt,
            1000,
            &next_tick,
            &selection,
        );

        try std.testing.expectEqual(case.returned, event);

        try expectSnapshot(case.moved, actor, body, health, next_tick);
        physics.commit(&actor, body);
        try expectSnapshot(case.committed, actor, body, health, next_tick);
    }
}

test "corpse constructor matches asset playback and collision state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Effect = struct {
        kind: []const u8,
        position_bits: ?[3]u32 = null,
        choreography: ?u32 = null,
        flags: ?std.json.Value = null,
        secondary_flags: ?u32 = null,
        height_bits: ?u32 = null,
        radius_bits: ?u32 = null,
        yaw: ?i16 = null,
        playback: ?[8]u32 = null,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        cases: []struct { name: []const u8, frames: []struct { now: u32, effects: []Effect } },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/enemy-runtime-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var count: usize = 0;

    for (corpus.cases) |case| {
        const filename = if (std.mem.startsWith(u8, case.name, "BGY3")) "BGY3.NWX" else "BGY4.NWX";
        var costume = try nwx.Costume.parse(a, try archive.find(filename, 0));
        defer costume.deinit();

        for (case.frames) |frame| for (frame.effects) |effect| {
            if (!std.mem.eql(u8, effect.kind, "corpse")) continue;

            var actor: Actor = undefined;

            actor.costume = &costume;
            actor.sector = 0;
            actor.position = pointBits(effect.position_bits.?);
            actor.choreography = effect.choreography.?;

            const actual = try lifecycle.corpse(actor, frame.now);

            try std.testing.expectEqual(@as(u32, @intCast(effect.flags.?.integer)), bits.word(actual.flags));
            try std.testing.expectEqual(effect.secondary_flags.?, bits.word(actual.secondary_flags));
            try std.testing.expectEqual(effect.height_bits.?, @as(u32, @bitCast(actual.height)));
            try std.testing.expectEqual(
                effect.radius_bits.?,
                @as(u32, @bitCast(actual.collision_radius)),
            );

            try std.testing.expectEqual(effect.yaw.?, actual.yaw);

            const playback = actual.playback.?;
            try std.testing.expectEqual(
                effect.playback.?[0..7].*,
                [7]u32{
                    playback.last_time,
                    @as(u16, @bitCast(playback.angle_offset)),
                    playback.direction,
                    playback.choreography,
                    playback.next_frame,
                    playback.frame,
                    bits.word(playback.flags),
                },
            );

            count += 1;
        };
    }

    try std.testing.expect(count >= 24);
}
