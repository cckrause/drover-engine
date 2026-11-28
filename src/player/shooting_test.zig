//! Firing: the hitscan ray, enemy damage, and which actor wins at equal distance.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const level_module = @import("../assets/level.zig");
const camera = @import("../render/backends/software/camera.zig");
const initial_state = @import("../render/initial_state.zig");
const scene_module = @import("../render/scene.zig");
const interaction = @import("../script/interaction.zig");
const shooting = @import("shooting.zig");
const Actor = @import("../render/objects.zig").Actor;
const bits = @import("../util/bits.zig");
const ActorFlags = @import("../actor_flags.zig").ActorFlags;
const ActorKind = @import("../actor_flags.zig").ActorKind;

const ActorInput = struct {
    sector: usize,
    position: [3]f32,
    height: f32,
    collision_radius: f32,
    flags: u32,
    secondary_flags: u32,
};

const Hit = struct {
    wall: ?[2]usize = null,
    position_bits: ?[3]u32 = null,
    along_bits: ?u32 = null,
    actor: ?usize = null,
    lateral_bits: ?u32 = null,
    height_bits: ?u32 = null,
    y_bits: ?u32 = null,
    distance_bits: ?u32 = null,
};

const RaySample = struct {
    sector: usize,
    origin: [3]f32,
    range: f32,
    pitch: i16,
    yaw: i16,
    actors: []ActorInput,
    end_bits: [3]u32,
    hit: ?Hit,
    ceiling_bits: u32,
    floor_bits: u32,
    events: []struct { wall: [2]usize, mask: u32, object_id: u32 },
};

const DamageSample = struct {
    input: struct {
        position: [3]f32,
        body_height: f32,
        radius: f32,
        secondary_flags: u32,
        health: f32,
        armor: bool,
        current_chor: u32,
        crouch_chor: u32,
        death_chor: u32,
        leg_death_chor: u32,
        kind: u32,
        damage: f32,
        mass: f32,
        speed: f32,
        pitch: i16,
        yaw: i16,
        lateral: f32,
        height: f32,
        shooter: ?[3]f32,
    },
    health_bits: u32,
    velocity_bits: [3]u32,
    knockout: bool,
    death_chor: u32,
};

const AggregateSample = struct {
    inputs: []struct {
        target: usize,
        kind: u32,
        damage: f32,
        mass: f32,
        speed: f32,
        pitch: i16,
        yaw: i16,
        lateral: f32,
        height: f32,
        y: f32,
        distance: f32,
    },
    messages: []struct {
        target: usize,
        kind: u32,
        damage_bits: u32,
        mass_bits: u32,
        speed_bits: u32,
        yaw: i16,
        pitch: i16,
        position_bits: [3]u32,
        lateral_bits: u32,
        height_bits: u32,
    },
};

const Corpus = struct {
    executable_sha256: []const u8,
    results_sha256: []const u8,
    rays: []RaySample,
    damage: []DamageSample,
    aggregation: []AggregateSample,
};

fn makeActor(source: ActorInput) Actor {
    return .{
        .costume = undefined,
        .sector = source.sector,
        .position = point(source.position),
        .yaw = 0,
        .flags = bits.from(ActorFlags, source.flags),
        .secondary_flags = bits.from(ActorKind, source.secondary_flags),
        .scale_x = 1,
        .scale_y = 1,
        .height = source.height,
        .collision_radius = source.collision_radius,
        .choreography = 0,
        .frame = 0,
        .angle_offset = 0,
    };
}

fn point(value: [3]f32) level_module.Vec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

fn bitPattern(value: level_module.Vec3) [3]u32 {
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

test "Hideout hitscan and enemy damage match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try read(a, "testdata/shooting-reference.json");
    const parsed = try std.json.parseFromSlice(
        Corpus,
        a,
        fixture,
        .{ .ignore_unknown_fields = true },
    );

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "3644889462dc7e3f83930d4c5f00eedb91d6179b6469f44c6e249be6d6c5b7cb",
        parsed.value.results_sha256,
    );

    const archive = try @import(
        "../assets/lab.zig",
    ).Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));

    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    var initial = try initial_state.InfStartup.apply(a, &level, try archive.find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);

    initial.applyScene(&level, &scene);

    for (parsed.value.rays, 0..) |sample, sample_index| {
        const actors = try a.alloc(Actor, sample.actors.len);

        for (sample.actors, actors) |source, *actor| actor.* = makeActor(source);

        const ray = shooting.Ray{
            .sector = sample.sector,
            .origin = point(sample.origin),
            .range = sample.range,
            .pitch = sample.pitch,
            .yaw = sample.yaw,
        };

        var events_buffer: interaction.RayEventBuffer = undefined;
        var events = interaction.RayEvents.init(&events_buffer);
        const result = try shooting.trace(
            &events,
            &level,
            &scene,
            &angles,
            .{ .entries = actors },
            &.{},
            ray,
        );

        errdefer std.debug.print(
            "reference shot ray sample {d}, yaw {d}, pitch {d}\n",
            .{ sample_index, sample.yaw, sample.pitch },
        );

        try std.testing.expectEqual(sample.end_bits, bitPattern(ray.end(&angles)));
        try std.testing.expectEqual(sample.ceiling_bits, @as(u32, @bitCast(result.ceiling)));
        try std.testing.expectEqual(sample.floor_bits, @as(u32, @bitCast(result.floor)));

        if (sample.hit) |expected| {
            try std.testing.expect(result.hit != null);

            if (expected.wall) |wall| {
                const hit = result.hit.?.wall;

                try std.testing.expectEqual(wall[0], hit.sector);
                try std.testing.expectEqual(wall[1], hit.index);
                try std.testing.expectEqual(expected.position_bits.?, bitPattern(hit.position));
                try std.testing.expectEqual(expected.along_bits.?, @as(u32, @bitCast(hit.along)));
            } else {
                const hit = result.hit.?.actor;

                try std.testing.expectEqual(expected.actor.?, hit.index);
                try std.testing.expectEqual(
                    expected.lateral_bits.?,
                    @as(u32, @bitCast(hit.lateral)),
                );

                try std.testing.expectEqual(expected.height_bits.?, @as(u32, @bitCast(hit.height)));
                try std.testing.expectEqual(expected.y_bits.?, @as(u32, @bitCast(hit.position.y)));
                try std.testing.expectEqual(
                    expected.distance_bits.?,
                    @as(u32, @bitCast(hit.distance)),
                );
            }
        } else try std.testing.expect(result.hit == null);

        try std.testing.expect(result.events.len >= sample.events.len);

        for (sample.events, result.events[0..sample.events.len]) |expected, actual| {
            try std.testing.expectEqual(expected.wall[0], actual.sector);
            try std.testing.expectEqual(expected.wall[1], actual.wall.?);
            try std.testing.expectEqual(expected.mask, bits.word(actual.mask));
            try std.testing.expectEqual(expected.object_id, actual.object_id);
        }
    }

    for (parsed.value.damage, 0..) |sample, index| {
        const input = sample.input;
        const actor = makeActor(.{
            .sector = 0,
            .position = input.position,
            .height = input.body_height,
            .collision_radius = input.radius,
            .flags = 0x8000004f,
            .secondary_flags = input.secondary_flags,
        });

        var state = shooting.EnemyState{
            .health = input.health,
            .armor = input.armor,
            .current_chor = input.current_chor,
            .crouch_chor = input.crouch_chor,
            .death_chor = input.death_chor,
            .leg_death_chor = input.leg_death_chor,
            .left_death_chor = 0x31,
            .right_death_chor = 0x32,
        };

        const death = try shooting.damageEnemy(
            &angles,
            actor,
            &state,
            .{
                .kind = input.kind,
                .damage = input.damage,
                .mass = input.mass,
                .speed = input.speed,
                .pitch = input.pitch,
                .yaw = input.yaw,
                .lateral = input.lateral,
                .height = input.height,
                .shooter_position = if (input.shooter) |source| .{
                    .x = source[0],
                    .z = source[2],
                } else null,
            },
        );

        errdefer std.debug.print("reference damage sample {d}\n", .{index});

        try std.testing.expectEqual(sample.health_bits, @as(u32, @bitCast(state.health)));
        try std.testing.expectEqual(sample.velocity_bits, bitPattern(state.velocity));
        try std.testing.expectEqual(sample.knockout, state.knockout);
        try std.testing.expectEqual(sample.death_chor, death orelse 0);
    }

    for (parsed.value.aggregation, 0..) |sample, index| {
        var groups = std.array_list.Managed(shooting.PendingHit).init(a);

        for (sample.inputs) |source| {
            const input = shooting.DamageInput{
                .kind = source.kind,
                .damage = source.damage,
                .mass = source.mass,
                .speed = source.speed,
                .pitch = source.pitch,
                .yaw = source.yaw,
                .lateral = source.lateral,
                .height = source.height,
            };

            const hit = shooting.ActorHit{
                .index = source.target,
                .position = .{ .x = 0, .y = source.y, .z = source.distance },
                .lateral = source.lateral,
                .height = source.height,
                .distance = source.distance,
            };

            for (groups.items) |*group| {
                if (group.matches(source.target, source.kind)) {
                    group.add(&angles, input, hit);
                    break;
                }
            } else try groups.append(shooting.PendingHit.init(source.target, &angles, input, hit));
        }

        errdefer std.debug.print("reference aggregation sample {d}\n", .{index});

        try std.testing.expectEqual(sample.messages.len, groups.items.len);

        for (sample.messages, groups.items) |expected, group| {
            const input = group.damageInput();

            try std.testing.expectEqual(expected.target, group.target);
            try std.testing.expectEqual(expected.kind, input.kind);
            try std.testing.expectEqual(expected.damage_bits, @as(u32, @bitCast(input.damage)));
            try std.testing.expectEqual(expected.mass_bits, @as(u32, @bitCast(input.mass)));
            try std.testing.expectEqual(expected.speed_bits, @as(u32, @bitCast(input.speed)));
            try std.testing.expectEqual(expected.pitch, input.pitch);
            try std.testing.expectEqual(expected.yaw, input.yaw);
            try std.testing.expectEqual(
                expected.position_bits,
                bitPattern(group.messagePosition()),
            );

            try std.testing.expectEqual(expected.lateral_bits, @as(u32, @bitCast(input.lateral)));
            try std.testing.expectEqual(expected.height_bits, @as(u32, @bitCast(input.height)));
        }
    }
}

test "sector relinks and player insertion retain equal-distance ray winner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const OrderCorpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct {
            sector: usize,
            origin: [3]f32,
            range: f32,
            pitch: i16,
            yaw: i16,
            actors: []ActorInput,
            relinks: []usize,
            hit: Hit,
        },
    };

    const corpus = (try std.json.parseFromSlice(
        OrderCorpus,
        a,
        try read(a, "testdata/actor-order-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "29cbfffe17e1d44d366eac794025ed75afc3e5e42f523e5b93b504fbb10dd655",
        corpus.results_sha256,
    );

    const archive = try @import(
        "../assets/lab.zig",
    ).Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));

    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    var initial = try initial_state.InfStartup.apply(a, &level, try archive.find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);

    initial.applyScene(&level, &scene);

    for (corpus.cases) |case| {
        for (0..case.actors.len) |player_source| {
            const actors = try a.alloc(Actor, case.actors.len - 1);
            const orders = try a.alloc(u64, case.actors.len);

            for (orders, 0..) |*order, index| order.* = index + 1;

            for (case.relinks, 0..) |source, index| orders[source] = case.actors.len + index + 1;

            var count: usize = 0;

            for (case.actors, 0..) |source, index| {
                if (index == player_source) continue;

                actors[count] = makeActor(source);
                actors[count].source_index = index;
                actors[count].sector_link_order = orders[index];
                count += 1;
            }

            std.mem.sort(Actor, actors, {}, struct {
                fn before(_: void, first: Actor, second: Actor) bool {
                    return first.sector_link_order < second.sector_link_order;
                }
            }.before);

            const player = case.actors[player_source];
            var events_buffer: interaction.RayEventBuffer = undefined;
            var events = interaction.RayEvents.init(&events_buffer);
            const result = try shooting.trace(
                &events,
                &level,
                &scene,
                &angles,
                .{
                    .entries = actors,
                    .player = .{
                        .position = point(player.position),
                        .sector = player.sector,
                        .height = player.height,
                        .radius = player.collision_radius,
                        .flags = bits.from(ActorFlags, player.flags),
                        .secondary_flags = bits.from(ActorKind, player.secondary_flags),
                        .sector_link_order = orders[player_source],
                    },
                },
                &.{},
                .{
                    .sector = case.sector,
                    .origin = point(case.origin),
                    .range = case.range,
                    .pitch = case.pitch,
                    .yaw = case.yaw,
                },
            );

            const hit = result.hit.?.actor;
            const source = if (hit.index == shooting.local_player) player_source else actors[hit.index].source_index.?;

            try std.testing.expectEqual(case.hit.actor.?, source);
            try std.testing.expectEqual(case.hit.distance_bits.?, @as(u32, @bitCast(hit.distance)));
            try std.testing.expectEqual(case.hit.height_bits.?, @as(u32, @bitCast(hit.height)));
            try std.testing.expectEqual(case.hit.lateral_bits.?, @as(u32, @bitCast(hit.lateral)));

            const actor_links = @import("../render/actor_links.zig");
            var links = try actor_links.Links.init(a, level.sectors.len, case.actors.len);

            defer links.deinit();

            for (case.actors, 0..) |body, index| links.move(
                if (index == player_source) actor_links.player_id else index,
                body.sector,
            );

            for (case.relinks) |index| {
                const id = if (index == player_source) actor_links.player_id else index;
                links.move(id, (case.actors[index].sector + 1) % level.sectors.len);
                links.move(id, case.actors[index].sector);
            }

            std.mem.reverse(Actor, actors);
            const indices = try a.alloc(?usize, case.actors.len);
            @memset(indices, null);

            for (actors, 0..) |actor, index| indices[actor.source_index.?] = index;

            events = interaction.RayEvents.init(&events_buffer);

            const linked = try shooting.trace(&events, &level, &scene, &angles, .{
                .entries = actors,
                .links = &links,
                .source_to_entry = indices,
                .player = .{
                    .position = point(player.position),
                    .sector = player.sector,
                    .height = player.height,
                    .radius = player.collision_radius,
                    .flags = bits.from(ActorFlags, player.flags),
                    .secondary_flags = bits.from(ActorKind, player.secondary_flags),
                },
            }, &.{}, .{
                .sector = case.sector,
                .origin = point(case.origin),
                .range = case.range,
                .pitch = case.pitch,
                .yaw = case.yaw,
            });

            const linked_hit = linked.hit.?.actor;
            const linked_source = if (linked_hit.index == shooting.local_player) player_source else actors[linked_hit.index].source_index.?;

            try std.testing.expectEqual(case.hit.actor.?, linked_source);
            try std.testing.expectEqual(
                case.hit.distance_bits.?,
                @as(u32, @bitCast(linked_hit.distance)),
            );

            try std.testing.expectEqual(
                case.hit.height_bits.?,
                @as(u32, @bitCast(linked_hit.height)),
            );

            try std.testing.expectEqual(
                case.hit.lateral_bits.?,
                @as(u32, @bitCast(linked_hit.lateral)),
            );
        }
    }
}
