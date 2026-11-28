//! The unique enemy: its constructor, the dormant clock, the message gate and its sound branches.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const Difficulty = @import("../difficulty.zig").Difficulty;

const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;
const level_module = @import("../assets/level.zig");
const nwx = @import("../assets/nwx.zig");
const camera = @import("../render/backends/software/camera.zig");
const object_state = @import("../render/object_state.zig");
const scene_module = @import("../render/scene.zig");
const Target = @import("../player/target.zig").Target;
const occlusion = @import("../audio/occlusion.zig");
const controller = @import("controller.zig");
const bits = @import("../util/bits.zig");
const ActorFlags = @import("../actor_flags.zig").ActorFlags;
const ActorKind = @import("../actor_flags.zig").ActorKind;

const ProjectionActor = struct {
    position_bits: [3]u32,
    velocity_bits: [3]u32,
    flags: u32,
    height_bits: u32,
    radius_bits: u32,
    scale_bits: [2]u32,
};

fn floatBits(value: f32) u32 {
    return @bitCast(value);
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => return err,
    };
}

fn projectionPoint(value: [3]u32) level_module.Vec3 {
    return .{ .x = @bitCast(value[0]), .y = @bitCast(value[1]), .z = @bitCast(value[2]) };
}

fn projectionBits(value: level_module.Vec3) [3]u32 {
    return .{ @bitCast(value.x), @bitCast(value.y), @bitCast(value.z) };
}

test "Sanchez constructor template dormant clock and message gate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const objects = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapons = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    const costume = try nwx.Costume.parse(a, try objects.find("SANCHEZ.NWX", 0));
    var sector = std.mem.zeroes(level_module.Sector);

    sector.vadjoin = -1;
    sector.ceiling.height = 64;

    var level: level_module.Level = undefined;
    level.sectors = (&sector)[0..1];

    var sector_state = std.mem.zeroes(scene_module.SectorState);
    var scene: scene_module.Scene = undefined;

    scene.sectors = (&sector_state)[0..1];
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;

    const angles = camera.Angles.init();
    var visibility = try occlusion.Cache.init(a, &level);
    defer visibility.deinit();
    const health = [2][3]u32{
        .{ 0x40e00000, 0x40a80000, 0x40e00000 },
        .{ 0x41600000, 0x41280000, 0x41600000 },
    };

    const damage = [2][3]u32{
        .{ 0x3f4ccccd, 0x40200000, 0x40800000 },
        .{ 0x404ccccd, 0x41200000, 0x41800000 },
    };

    for ([_][]const u8{ "ESANCHEZ", "SANCHEZ" }, 0..) |name, item_index| {
        const definition = try Item.parse(
            a,
            try objects.find(try std.fmt.allocPrint(a, "{s}.ITM", .{name}), 0),
        );

        var object = std.mem.zeroes(level_module.Object);

        object.name = name;
        const state = try object_state.State.init(object, 0, &definition, &costume);

        try std.testing.expectEqual(
            object_state.Kind.sanchez,
            try object_state.classify(&definition),
        );

        try std.testing.expectEqual(@as(u32, 0x8000014b), bits.word(state.flags));
        try std.testing.expectEqual(@as(u32, 0x00200140), bits.word(state.secondary_flags));
        try std.testing.expectEqual(@as(f32, 6), state.height);
        try std.testing.expectEqual(@as(u32, 0x4026db6e), floatBits(state.collision_radius));
        try std.testing.expectEqual(@as(u32, 0), state.choreography | state.frame);

        for ([_]u32{ 0x100000, 0x200000, 0x800000 }, 0..) |difficulty, index| {
            var actor = state.actor(&costume);
            var target = (try Target.load(a, &.{ objects, weapons }, &definition, @as(Difficulty, @enumFromInt(difficulty)))).?;

            try std.testing.expect(target.sanchez);
            try std.testing.expectEqual(health[item_index][index], floatBits(target.damage.health));
            try std.testing.expectEqual(damage[item_index][index], floatBits(target.config.damage));
            try std.testing.expectEqual(
                ([_]u32{ 0x41666667, 0x41900000, 0x41c99999 })[index],
                floatBits(target.config.walk_speed),
            );

            try std.testing.expectEqual(
                ([_]u32{ 0x4199999a, 0x41c00000, 0x42066666 })[index],
                floatBits(target.config.run_speed),
            );

            try std.testing.expectEqual(
                ([_]u32{ 0x41200000, 0x40700000, 0x40a00000 })[index],
                floatBits(target.config.move_inaccuracy),
            );

            try std.testing.expectEqual(
                ([_]u32{ 0x40000000, 0x3f400000, 0x3f800000 })[index],
                floatBits(target.config.weapon_inaccuracy),
            );

            try std.testing.expectEqual(@as(i16, 0x1fd2), target.config.fov);
            try std.testing.expectEqual(@as(f32, 200), target.config.activate_radius);
            try std.testing.expectEqual(@as(u32, 15000), target.config.taunt_timer_time);

            var random: u32 = 0x742389ac;
            var shared: controller.Shared = .{ .now = 1000, .total_enemies = 1 };
            var effects_buffer: [16]controller.Effect = undefined;
            var effects = controller.Effects.init(&effects_buffer);
            var context: controller.Context = .{
                .allocator = a,
                .level = &level,
                .scene = &scene,
                .angles = &angles,
                .actors = .{ .entries = &.{} },
                .player = null,
                .visibility = &visibility,
                .random = &random,
                .now = 9000,
                .elapsed_seconds = 0.016,
                .shared = &shared,
                .effects = &effects,
            };

            try std.testing.expectEqual(false, try controller.tick(&target, &actor, &context));
            try std.testing.expectEqual(@as(u32, 3000), target.next_tick);
            try std.testing.expectEqual(@as(u32, 1000), shared.now);

            const before = target;

            for ([_]u32{
                1,
                0x62,
                0x63,
                0x78,
                0x7d,
                0x7e,
                0x80,
                0x81,
                0x82,
                0x83,
            }) |code| try controller.message(&target, &actor, code, &.{}, &context);

            try controller.hitMessage(
                &target,
                &actor,
                .{
                    .kind = 1,
                    .damage = 1,
                    .mass = 1,
                    .speed = 1000,
                    .pitch = 0,
                    .yaw = 0,
                    .lateral = 0,
                    .height = 3,
                },
                &context,
            );

            controller.impulseMessage(&target, .{ .x = 1, .y = 2, .z = 3 }, &context);
            controller.activationMessage(&target, &context);
            try controller.resultMessage(&target, &actor, true, &context);

            try std.testing.expectEqualDeep(before, target);
            try std.testing.expectEqual(@as(u32, 0x742389ac), random);
            try std.testing.expectEqual(@as(usize, 0), effects.items.len);
        }
    }
}

test "hidden and active Sanchez projection reaches blood without stale operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Before = struct {
        actor: ProjectionActor,
        random: u32,
        projection: [4]u32,
        velocity_bits: [3]u32,
        mode: u32,
        previous_mode: u32,
        sight_at: u32,
        playback: [8]i64,
        player_position_bits: [3]u32,
        player_height_bits: u32,
        player_yaw: i16,
        player_flags: u32,
        player_secondary_flags: u32,
    };

    const Case = struct {
        variant: []const u8,
        player_config: struct { sector: usize },
        enemy_before: Before,
        initial: ProjectionActor,
        before: [4]u32,
        position_bits: [3]u32,
        velocity_bits: [3]u32,
        floor_cache_bits: u32,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []const Case,
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/collision-sanchez-projection.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "ddd7d2b7b64f9e10729a4237b8e71f77977f5db4d06b004616e3e2eb28aa1708",
        corpus.results_sha256,
    );

    const objects = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapons = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    const geometry = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    const definition = try Item.parse(a, try objects.find("SANCHEZ.ITM", 0));
    const costume = try nwx.Costume.parse(a, try objects.find("SANCHEZ.NWX", 0));
    const blood = @import("blood.zig");
    const blood_costume = try nwx.Costume.parse(a, try objects.find(blood.costume_name, 0));
    var level = try level_module.Level.parse(a, try geometry.find("HIDEOUT.LVB", 0));
    var startup = try @import(
        "../render/initial_state.zig",
    ).InfStartup.apply(a, &level, try geometry.find("HIDEOUT.INF", 0));

    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);

    startup.applyScene(&level, &scene);

    for (corpus.cases) |case| {
        errdefer std.debug.print("Sanchez projection {s}\n", .{case.variant});
        const entry = case.enemy_before;
        var object = std.mem.zeroes(level_module.Object);

        object.name = "SANCHEZ";
        var actor = (try object_state.State.init(object, 0, &definition, &costume)).actor(&costume);

        actor.source_index = 0;
        actor.position = projectionPoint(entry.actor.position_bits);
        actor.sector = case.player_config.sector;
        bits.setWord(&actor.flags, entry.actor.flags);
        actor.height = @bitCast(entry.actor.height_bits);
        actor.collision_radius = @bitCast(entry.actor.radius_bits);
        actor.choreography = @intCast(entry.playback[3]);
        actor.frame = @intCast(entry.playback[5]);
        actor.angle_offset = @intCast(entry.playback[1]);

        var target = (try Target.load(a, &.{ objects, weapons }, &definition, .good)).?;

        target.config.no_los_taunts = &.{};
        target.config.los_taunts = &.{};
        target.config.alert_taunts = &.{};
        target.damage.velocity = projectionPoint(entry.velocity_bits);
        target.mode = entry.mode;
        target.previous_mode = entry.previous_mode;
        target.sight_at = entry.sight_at;

        var shared: controller.Shared = .{
            .now = 1000,
            .total_enemies = 10,
            .killed_enemies = if (std.mem.eql(u8, case.variant, "reveal")) 9 else 6,
        };

        if (std.mem.eql(u8, case.variant, "taunt_wait")) target.ai.taunt_at = 9000;

        var random = entry.random;
        var cache = try occlusion.Cache.init(a, &level);
        var effects_buffer: [16]controller.Effect = undefined;
        var effects = controller.Effects.init(&effects_buffer);
        var residue: @import("../projectile/contact.zig").Residue = .{};

        for (entry.projection, 0..) |word, index| residue.projection.words[index] = word;

        const sites = [_]@import(
            "sanchez.zig",
        ).Site{.{ .source = 0, .sector = actor.sector, .position = actor.position }};

        var ctx: controller.Context = .{
            .allocator = a,
            .level = &level,
            .scene = &scene,
            .angles = &angles,
            .actors = .{ .entries = &.{} },
            .player = .{
                .position = projectionPoint(entry.player_position_bits),
                .sector = actor.sector,
                .height = @bitCast(entry.player_height_bits),
                .radius = 1.5,
                .yaw = entry.player_yaw,
                .flags = bits.from(ActorFlags, entry.player_flags),
                .secondary_flags = bits.from(ActorKind, entry.player_secondary_flags),
            },
            .visibility = &cache,
            .random = &random,
            .now = 1000,
            .elapsed_seconds = 0.2,
            .shared = &shared,
            .effects = &effects,
            .contact_residue = &residue,
            .contact_sector_events = false,
            .sanchez_sites = &sites,
        };

        try std.testing.expect(!try controller.tick(&target, &actor, &ctx));
        const reveal = std.mem.eql(u8, case.variant, "reveal");

        for (case.before, 0..) |word, index| try std.testing.expectEqual(
            if (reveal and index < 2) null else @as(?u32, word),
            residue.projection.words[index],
        );

        var sector = std.mem.zeroes(level_module.Sector);

        sector.vadjoin = -1;
        sector.ceiling.height = 10.1;
        sector.gravity = -60;
        sector.friction = 0.3;
        sector.elasticity = 0.5;

        var blood_level: level_module.Level = undefined;
        blood_level.sectors = (&sector)[0..1];

        var state = std.mem.zeroes(scene_module.SectorState);
        var blood_scene: scene_module.Scene = undefined;

        blood_scene.sectors = (&state)[0..1];
        var collision_check: u32 = 0;
        blood_scene.collision_check = &collision_check;

        const initial = case.initial;
        var particle: @import(
            "../render/objects.zig",
        ).Actor = .{
            .costume = &blood_costume,
            .sector = 0,
            .position = projectionPoint(initial.position_bits),
            .yaw = 0,
            .flags = bits.from(ActorFlags, initial.flags),
            .secondary_flags = .{},
            .height = @bitCast(initial.height_bits),
            .collision_radius = @bitCast(initial.radius_bits),
            .scale_x = @bitCast(initial.scale_bits[0]),
            .scale_y = @bitCast(initial.scale_bits[1]),
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };

        var motion: blood.State = .{ .velocity = projectionPoint(initial.velocity_bits) };
        const world = @import(
            "physics.zig",
        ).World{
            .level = &blood_level,
            .scene = &blood_scene,
            .angles = &angles,
            .actors = .{ .entries = &.{} },
            .contact_stack = .{ .residue = &residue, .caller = .blood },
        };

        if (reveal) {
            const start = particle.position;
            _ = try blood.tick(&particle, &motion, world, 0.2);
            try std.testing.expectEqualDeep(
                [2]u32{ @bitCast(start.x), @bitCast(start.z) },
                [2]u32{ @bitCast(particle.position.x), @bitCast(particle.position.z) },
            );
        } else {
            try std.testing.expect(!try blood.tick(&particle, &motion, world, 0.2));
            try std.testing.expectEqualDeep(case.position_bits, projectionBits(particle.position));
            try std.testing.expectEqualDeep(case.velocity_bits, projectionBits(motion.velocity));
            try std.testing.expectEqual(case.floor_cache_bits, floatBits(motion.floor_cache));
        }

        if (std.mem.eql(u8, case.variant, "taunt")) {
            actor.position = projectionPoint(entry.actor.position_bits);
            actor.sector = if (ctx.player.?.sector == 0) 1 else 0;
            bits.setWord(&actor.flags, entry.actor.flags);
            target.ai.taunt_at = 0;
            random = entry.random;
            shared.next_taunt = 0;
            ctx.contact_sector_events = true;
            residue.words = @splat(0x3f800000);

            for (entry.projection, 0..) |word, index| residue.projection.words[index] = word;

            try std.testing.expect(!try @import("sanchez.zig").tick(&target, &actor, &ctx));
            try std.testing.expectEqual([4]?u32{ null, null, null, null }, residue.words);

            for (residue.projection.words[0..3]) |word| try std.testing.expectEqual(
                @as(?u32, null),
                word,
            );

            try std.testing.expectEqual(@as(?u32, case.before[3]), residue.projection.words[3]);
        }
    }
}

test "hidden Sanchez selected taunt sound updates projection by actual admission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Entry = struct {
        random: u32,
        position_bits: [3]u32,
        player_position_bits: [3]u32,
        player_flags: u32,
        has_los: u8,
        projection: [4]u32,
    };

    const Case = struct { mode: []const u8, projection: [4]u32, taunt_entry: Entry };
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []const Case,
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/sanchez-audio-stack-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "834bbb6e30ce5d0038c5a655f8bc40cbbc0622e4f73b6eaef7cffe80945381ba",
        corpus.results_sha256,
    );

    const objects = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapons = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    const system = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"));
    const definition = try Item.parse(a, try objects.find("SANCHEZ.ITM", 0));
    const costume = try nwx.Costume.parse(a, try objects.find("SANCHEZ.NWX", 0));
    const angles = camera.Angles.init();

    for (corpus.cases) |case| {
        const admitted = std.mem.eql(u8, case.mode, "admitted");
        const exhausted = std.mem.eql(u8, case.mode, "exhausted");

        if (!admitted and !exhausted and !std.mem.eql(u8, case.mode, "rejected_volume")) continue;

        errdefer std.debug.print("Sanchez sound projection {s}\n", .{case.mode});

        const entry = case.taunt_entry;
        var object = std.mem.zeroes(level_module.Object);

        object.name = "SANCHEZ";
        var actor = (try object_state.State.init(object, 0, &definition, &costume)).actor(&costume);

        actor.source_index = 0;
        actor.position = projectionPoint(entry.position_bits);

        var target = (try Target.load(a, &.{ objects, weapons }, &definition, .good)).?;
        target.ai.has_los = entry.has_los != 0;
        var sector = std.mem.zeroes(level_module.Sector);
        sector.vadjoin = -1;
        var level: level_module.Level = undefined;
        level.sectors = (&sector)[0..1];

        var state = std.mem.zeroes(scene_module.SectorState);
        var scene: scene_module.Scene = undefined;

        scene.sectors = (&state)[0..1];
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;

        var cache = try occlusion.Cache.init(a, &level);
        var random = entry.random;
        var shared: controller.Shared = .{ .now = 1000 };
        var effects_buffer: [16]controller.Effect = undefined;
        var effects = controller.Effects.init(&effects_buffer);
        var residue: @import("../projectile/contact.zig").Residue = .{};

        for (entry.projection, 0..) |word, index| residue.projection.words[index] = word;

        const runtime = try @import(
            "../audio/runtime.zig",
        ).Runtime.open(a, std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", system);

        defer runtime.deinit();

        if (exhausted) {
            const registration = try runtime.declare("SZ01.WAV", 0x57415644, 1, 1000);
            for (0..199) |_| try std.testing.expect(runtime.allocateInstance(registration) != null);
        } else if (!admitted) runtime.engine.effects_volume = 0;

        var ctx: controller.Context = .{
            .allocator = a,
            .level = &level,
            .scene = &scene,
            .angles = &angles,
            .actors = .{ .entries = &.{} },
            .player = .{
                .position = projectionPoint(entry.player_position_bits),
                .sector = 0,
                .height = 6,
                .radius = 1.5,
                .yaw = 0,
                .flags = bits.from(ActorFlags, entry.player_flags),
                .secondary_flags = .{ .player = true },
            },
            .visibility = &cache,
            .random = &random,
            .now = 1000,
            .elapsed_seconds = 0.2,
            .shared = &shared,
            .effects = &effects,
            .contact_residue = &residue,
            .contact_hidden_taunt = true,
            .audio = runtime,
        };

        try controller.taunt(&target, actor, 1, true, &ctx);

        for (case.projection, 0..) |word, index| try std.testing.expectEqual(
            if (admitted and index == 2) null else @as(?u32, word),
            residue.projection.words[index],
        );
    }
}
