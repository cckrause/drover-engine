//! Riding a rail: angles, slopes, collision and the sound timing.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const PlayerFlags = @import("flags.zig").PlayerFlags;

const level_asset = @import("../assets/level.zig");
const player_audio = @import("../audio/player.zig");
const rail_audio = @import("../audio/rail.zig");
const camera = @import("../render/backends/software/camera.zig");
const initial = @import("../render/initial_state.zig");
const scene_module = @import("../render/scene.zig");
const input = @import("input.zig");
const movement = @import("movement.zig");
const bits = @import("../util/bits.zig");

const Snapshot = struct {
    sector: usize,
    position: [3]u32,
    velocity: [3]u32,
    angles: [3]i16,
    eye_height: u32,
    body_height: u32,
    floor_cache: u32,
    energy: u32,
    head_bob: u32,
    weapon_offset: [2]i32,
    stride: u32,
    flags: u32,
    pitch_accumulator: i32,

    fn read(player: *const movement.Player, look: *const input.LookState) Snapshot {
        return .{
            .sector = player.sector,
            .position = .{
                @bitCast(player.position.x),
                @bitCast(player.position.y),
                @bitCast(player.position.z),
            },
            .velocity = .{
                @bitCast(player.velocity.x),
                @bitCast(player.velocity.y),
                @bitCast(player.velocity.z),
            },
            .angles = .{ player.pitch, player.yaw, player.head_yaw },
            .eye_height = @bitCast(player.eye_height),
            .body_height = @bitCast(player.body_height),
            .floor_cache = @bitCast(player.floor_cache),
            .energy = @bitCast(player.energy),
            .head_bob = @bitCast(player.head_bob),
            .weapon_offset = player.weapon_offset,
            .stride = @bitCast(player.stride),
            .flags = bits.word(player.flags),
            .pitch_accumulator = look.pitch_accumulator,
        };
    }
};

test "rail mode angles slopes collision and sound timing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/player-rail-reference.json",
        a,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const Fixture = struct {
        cases: []const struct {
            name: []const u8,
            config: struct {
                sector: usize,
                position: [3]f32,
                player_flags: u32,
                velocity: [3]f32 = .{ 0, 0, 0 },
                yaw: i16 = 0,
                head_yaw: i16 = 0,
                guide: usize = 0,
                floor_slope: ?[4]f32 = null,
                pull: bool = false,
                energy: f32 = 100,
                scope_active: bool = false,
                flag_change_at: ?usize = null,
                clear_flags: u32 = 0,
            },
            slots: []const [3]i16,
            frames: []const struct {
                state: Snapshot,
                actions: []const struct {
                    address: []const u8,
                    position: ?[3]u32 = null,
                    distance: ?u32 = null,
                    speed: ?u32 = null,
                },
            },
        },
        toggles: []const struct { allowed: bool, result: u32, flags: u32 },
    };

    const reference = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    var archives: [3]@import("../assets/lab.zig").Archive = undefined;

    for ([_][]const u8{ "OUTLAWS.LAB", "OLOBJ.LAB", "OLGEO.LAB" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}", .{name});
        archive.* = try @import(
            "../assets/lab.zig",
        ).Archive.init(
            try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)),
        );
    }

    var item = try @import(
        "../assets/item.zig",
    ).Item.parse(a, try archives[1].find("CIDJAMES.ITM", 0x4954454d));

    const physics = try movement.Physics.parse(try archives[0].find("AIR.PHY", 0x50485953));
    var level = try level_asset.Level.parse(a, try archives[2].find("HIDEOUT.LVB", 0));
    var startup = try initial.InfStartup.apply(a, &level, try archives[2].find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    const config = try player_audio.Config.fromItem(&item);
    const runtime = try @import(
        "../audio/runtime.zig",
    ).Runtime.open(a, std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", archives[0]);

    defer runtime.deinit();
    var effects_buffer: @import("inventory.zig").EffectBuffer = undefined;
    var effects = @import("inventory.zig").Effects.init(&effects_buffer);

    for (reference.value.cases) |case| {
        var scene = try scene_module.Scene.init(a, &level, &angles);
        defer scene.deinit();

        startup.applyScene(&level, &scene);
        const sector = &scene.sectors[case.config.sector];
        sector.flags.rail = true;

        for (sector.walls, 0..) |*wall, index| wall.runtime_flags.rail_guide = index == case.config.guide;

        const original_plane = level.sectors[case.config.sector].floor;
        defer level.sectors[case.config.sector].floor = original_plane;

        if (case.config.floor_slope) |plane| {
            sector.flags.sloped_floor = true;
            sector.floor_slope = std.mem.zeroInit(
                scene_module.Slope,
                .{ .coeff_x = plane[0], .coeff_z = plane[1], .constant = plane[2] },
            );

            level.sectors[case.config.sector].floor.slope = .{
                .sector = @intCast(case.config.sector),
                .wall = 0,
                .angle = @intFromFloat(plane[3]),
            };
        }

        if (case.config.pull) sector.flags.rail_slope = true;

        var player = try movement.Player.init(
            &item,
            physics,
            .{
                .sector = case.config.sector,
                .position = .{
                    .x = case.config.position[0],
                    .y = case.config.position[1],
                    .z = case.config.position[2],
                },
                .rotation = .{ .x = 0, .y = 0, .z = 0 },
            },
        );

        player.flags = bits.without(bits.from(PlayerFlags, case.config.player_flags), .{ .on_rail = true });
        player.velocity = .{
            .x = case.config.velocity[0],
            .y = case.config.velocity[1],
            .z = case.config.velocity[2],
        };

        player.yaw = case.config.yaw;
        player.head_yaw = case.config.head_yaw;
        player.energy = case.config.energy;
        player.scope_active = case.config.scope_active;

        var look: input.LookState = .{};
        var sound_state: player_audio.State = .{};
        var rail_state: rail_audio.State = .{};
        var rail: rail_audio.Context = .{ .state = &rail_state, .runtime = runtime, .now = 0 };
        defer rail.stop() catch unreachable;
        var audio: player_audio.Context = .{
            .config = &config,
            .state = &sound_state,
            .effects = &effects,
            .rail = &rail,
        };

        try runtime.engine.updateListener(.{
            .position = .{ player.position.x, player.position.y, player.position.z },
        });

        try std.testing.expect(try player.toggleRail(&scene, &audio));

        for (case.frames, 0..) |frame, frame_index| {
            errdefer std.debug.print("rail case {s} frame {d}\n", .{ case.name, frame_index });

            if (case.config.flag_change_at == frame_index)
                sector.flags = bits.without(sector.flags, bits.from(scene_module.SectorFlags, case.config.clear_flags));

            var packet: input.Packet = .{};
            packet.entries[23] = .{ .value = 100, .flags = .{ .unscaled = true } };

            for (case.slots) |slot| packet.entries[
                @intCast(
                    slot[0],
                )
            ] = .{ .value = slot[1], .flags = bits.from(input.EntryFlags, @intCast(slot[2])) };

            effects.clearRetainingCapacity();
            try runtime.engine.updateListener(.{
                .position = .{ player.position.x, player.position.y, player.position.z },
            });

            try player.tickWithAudio(
                &level,
                &scene,
                .{ .entries = &.{} },
                &angles,
                look.control(&packet),
                &look,
                0.016,
                &audio,
            );

            var expected = frame.state;
            expected.flags &= 0x200c;
            try std.testing.expectEqualDeep(expected, Snapshot.read(&player, &look));
            var update_count: usize = 0;

            for (frame.actions) |action| {
                if (std.mem.eql(u8, action.address, "00477720")) {
                    const voice = runtime.engine.find(
                        rail_state.pull_handle,
                    ) orelse return error.MissingRailPullVoice;

                    const expected_position = action.position.?;

                    for (voice.params.position, expected_position) |actual, word| try std.testing.expectEqual(word, @as(u32, @bitCast(actual)));
                } else if (std.mem.eql(u8, action.address, "004777a0")) {
                    try std.testing.expectEqual(@as(u32, 0), rail_state.pull_handle);
                } else if (std.mem.eql(u8, action.address, "00477660")) {
                    update_count += 1;
                    const step = player.rail_step orelse return error.MissingRailUpdate;

                    try std.testing.expectEqual(
                        action.distance.?,
                        @as(u32, @bitCast(step.distance)),
                    );

                    try std.testing.expectEqual(action.speed.?, @as(u32, @bitCast(step.speed)));
                    try std.testing.expectEqual(
                        action.position.?,
                        Snapshot.read(&player, &look).position,
                    );

                    try rail.update(step.distance, step.speed, player.position);
                } else return error.UnexpectedRailAction;
            }

            try std.testing.expectEqual(
                @as(usize, if (player.rail_step != null) 1 else 0),
                update_count,
            );
        }
    }

    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    var player = try movement.Player.init(
        &item,
        physics,
        .{
            .sector = 410,
            .position = .{ .x = 322.36, .y = -3, .z = 271.88 },
            .rotation = .{ .x = 0, .y = 0, .z = 0 },
        },
    );

    var sound_state: player_audio.State = .{};
    var rail_state: rail_audio.State = .{};
    var rail: rail_audio.Context = .{ .state = &rail_state, .runtime = runtime, .now = 0 };
    defer rail.stop() catch unreachable;
    var audio: player_audio.Context = .{
        .config = &config,
        .state = &sound_state,
        .effects = &effects,
        .rail = &rail,
    };

    for (reference.value.toggles) |toggle| {
        scene.sectors[410].flags.rail = toggle.allowed;

        try std.testing.expectEqual(toggle.result != 0, try player.toggleRail(&scene, &audio));
        try std.testing.expectEqual(toggle.flags, bits.word(player.flags));
        try std.testing.expectEqual(player.flags.on_rail, rail_state.rail_resource != null);
    }
}
