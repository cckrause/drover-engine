//! Underwater bubbles: batch construction, the random draws it consumes, ceiling flags and scheduling.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const level_module = @import("../assets/level.zig");
const nwx = @import("../assets/nwx.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene_module = @import("../render/scene.zig");
const blood = @import("blood.zig");
const bubble = @import("bubble.zig");
const physics = @import("physics.zig");
const bits = @import("../util/bits.zig");

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

fn check(
    expected: Snapshot,
    actor: @import("../render/objects.zig").Actor,
    state: blood.State,
    random: u32,
) !void {
    const playback = actor.playback.?;
    const actual = Snapshot{
        .position_bits = vectorBits(actor.position),
        .velocity_bits = vectorBits(state.velocity),
        .flags = bits.word(actor.flags),
        .secondary_flags = bits.word(actor.secondary_flags),
        .scale_bits = .{ @bitCast(actor.scale_x), @bitCast(actor.scale_y) },
        .height_bits = @bitCast(actor.height),
        .radius_bits = @bitCast(actor.collision_radius),
        .floor_cache_bits = @bitCast(state.floor_cache),
        .playback = .{
            playback.last_time,
            @bitCast(@as(i32, playback.angle_offset)),
            playback.direction,
            playback.choreography,
            playback.next_frame,
            playback.frame,
            bits.word(playback.flags),
            @intFromBool(playback.terminated),
        },
        .random = random,
        .same_sector = actor.sector == 0,
    };

    try std.testing.expectEqualDeep(expected, actual);
}

fn point(v: [3]f32) level_module.Vec3 {
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

fn vectorBits(v: level_module.Vec3) [3]u32 {
    return .{ @bitCast(v.x), @bitCast(v.y), @bitCast(v.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "bubble batches preserve RNG construction drift and ceiling flags" {
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
        flags: u32,
        count: i32,
        paired: bool,
        clear_flags: u32 = 0,
        ceiling_slope: ?[3]f32 = null,
    };

    const Fixture = struct {
        results_sha256: []const u8,
        cases: []const struct {
            config: Config,
            initial: []const Snapshot,
            random: u32,
            frames: []const struct { now: u32, removed: bool, state: Snapshot },
        },
    };

    const fixture = (try std.json.parseFromSlice(
        Fixture,
        a,
        try read(a, "testdata/bubbles-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "7e4f879396a041db353be216bf351d36e3a767c8edf820572acb147ba6f07cce",
        fixture.results_sha256,
    );

    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var costume = try nwx.Costume.parse(a, try archive.find(bubble.costume_name, 0));
    defer costume.deinit();
    const angles = camera.Angles.init();

    for (fixture.cases, 0..) |case, case_index| {
        errdefer std.debug.print("reference bubble case {d}\n", .{case_index});
        const config = case.config;
        var sectors = [_]level_module.Sector{
            std.mem.zeroes(level_module.Sector),
            std.mem.zeroes(level_module.Sector),
        };

        const sector = &sectors[0];

        sector.vadjoin = -1;
        sector.gravity = config.gravity;
        sector.friction = config.friction;
        sector.elasticity = config.elasticity;
        sector.floor.height = config.floor;
        sector.ceiling.height = config.ceiling;

        var level: level_module.Level = undefined;

        sectors[1].vadjoin = 0;
        sectors[1].ceiling.height = 30;
        sectors[1].floor.height = config.ceiling;

        if (config.paired) sector.vadjoin = 1;

        level.sectors = &sectors;

        var states = [_]scene_module.SectorState{
            std.mem.zeroes(scene_module.SectorState),
            std.mem.zeroes(scene_module.SectorState),
        };

        const state = &states[0];

        bits.setWord(&state.flags, config.flags);

        if (config.ceiling_slope) |slope| {
            state.flags.sloped_ceiling = true;
            state.ceiling_slope = std.mem.zeroInit(
                scene_module.Slope,
                .{ .coeff_x = slope[0], .coeff_z = slope[1], .constant = slope[2] },
            );
        }

        state.flags = bits.without(state.flags, bits.from(scene_module.SectorFlags, config.clear_flags));
        var scene: scene_module.Scene = undefined;
        scene.sectors = &states;
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;

        const world = physics.World{
            .level = &level,
            .scene = &scene,
            .angles = &angles,
            .actors = .{ .entries = &.{} },
        };

        var random = config.seed;

        _ = bubble.sound(&random, 0, point(config.position));
        const actors = try a.alloc(@import("../render/objects.zig").Actor, @intCast(config.count));

        for (actors) |*actor| actor.* = bubble.spawn(
            &costume,
            &random,
            0,
            point(config.position),
            1000,
        );

        try std.testing.expectEqual(case.random, random);
        var movement = blood.State{ .velocity = .{ .x = 0, .y = 0, .z = 0 } };

        for (case.initial, actors) |expected, actor| try check(expected, actor, movement, random);

        for (case.frames, 0..) |frame, frame_index| {
            errdefer std.debug.print("reference bubble frame {d}\n", .{frame_index});
            try std.testing.expectEqual(
                frame.removed,
                try bubble.tick(&actors[0], &movement, world, config.dt, frame.now),
            );

            try check(frame.state, actors[0], movement, random);
        }
    }
}

test "Hideout underwater bubbles grow live actor lists and preserve saved-next scheduling" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = try read(a, path);
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    const session = try @import(
        "../render/session.zig",
    ).Session.open(
        a,
        @import("../render/test_workspace.zig").get(),
        std.testing.io,
        path,
        archive,
        &startup,
    );

    defer session.deinit(a);

    session.player.sector = 66;
    session.player.position = .{ .x = 465.5, .y = -10, .z = 460 };
    session.player.velocity = .{ .x = 0, .y = 0, .z = 0 };
    session.player.flags = .{};
    session.player.yaw = 0;
    session.player.head_yaw = 0;

    session.actor_links.move(@import("../render/actor_links.zig").player_id, 66);
    session.contact_state.random = 0;

    const first = session.actor_slots.len;
    const origin_y: f32 = @floatCast(
        @as(f64, session.player.position.y) + session.player.eye_height,
    );

    try session.advance(a, &.{}, 16);

    try std.testing.expectEqual(first + 2, session.actor_slots.len);
    try std.testing.expectEqual(@as(u32, 0), session.contact_state.random);

    for (session.actor_slots[first..]) |slot| {
        const actor = slot.?;
        try std.testing.expectEqualStrings("fx_BubbleLogic", actor.logic_name);
        try std.testing.expectEqual(origin_y, actor.position.y);
        try std.testing.expectEqual(@as(f32, 0), actor.scale_x);
    }

    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(first + 4, session.actor_slots.len);

    for (session.actor_slots[first .. first + 2]) |slot|
        try std.testing.expect(slot.?.position.y > origin_y);

    for (session.actor_slots[first + 2 ..]) |slot|
        try std.testing.expect(slot.?.flags.updated);

    var sounds: usize = 0;

    for (session.pickup_effects.items) |effect| switch (effect) {
        .sound => |sound| if (std.mem.eql(u8, sound.basename, "bubbles1.wav")) {
            sounds += 1;
        },
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 1), sounds);
}
