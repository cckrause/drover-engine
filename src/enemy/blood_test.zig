//! Blood and splashes: spawning, gravity, contacts, removal, and the actor scheduler around them.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
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

fn dynamicStackTick(kind: []const u8, actor: *@import("../render/objects.zig").Actor, movement: *blood.State, world: physics.World) !void {
    if (std.mem.eql(u8, kind, "blood")) {
        _ = try blood.tick(actor, movement, world, 0.2);
    } else if (std.mem.eql(u8, kind, "bubble")) {
        _ = try @import("bubble.zig").tick(actor, movement, world, 0.2, 1000);
    } else if (std.mem.eql(u8, kind, "fragment")) {
        try blood.generalPhysics(actor, movement, world, 0.2);
    } else {
        _ = try blood.scheduledPhysics(actor, movement, world, 0.2);
    }
}

fn fromBits(values: [3]u32) level_module.Vec3 {
    return .{ .x = @bitCast(values[0]), .y = @bitCast(values[1]), .z = @bitCast(values[2]) };
}

fn projectionActor(costume: *const nwx.Costume, initial: anytype) @import("../render/objects.zig").Actor {
    return .{ .costume = costume, .sector = 0, .position = fromBits(initial.position_bits), .flags = initial.flags, .secondary_flags = 0x800000, .height = @bitCast(initial.height_bits), .collision_radius = @bitCast(initial.radius_bits), .scale_x = @bitCast(initial.scale_bits[0]), .scale_y = @bitCast(initial.scale_bits[1]), .yaw = 0, .choreography = 0, .frame = 0, .angle_offset = 0 };
}

test "blood spawn gravity contacts and removal" {
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
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const struct { config: Config, initial: Snapshot, frames: []const struct { removed: bool, state: Snapshot } } };
    const corpus = (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/blood-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("7223e8a316c0ee8d06b638649909c90e3c5605a6911e5f8c915f32b7a5d8f54b", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var costume = try nwx.Costume.parse(a, try archive.find(blood.costume_name, 0));
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
        const world = physics.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} } };
        var random = config.seed;
        var particle = try blood.spawn(&costume, &random, 0, point(config.position), 1000);
        try check(case.initial, particle, random);
        for (case.frames, 0..) |frame, frame_index| {
            errdefer std.debug.print("reference blood frame{d}\n", .{frame_index});
            try std.testing.expectEqual(frame.removed, try blood.tick(&particle.actor, &particle.state, world, config.dt));
            try check(frame.state, particle, random);
        }
    }
}

test "splash construction selection sound and bound termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        initial: Snapshot,
        selected: Snapshot,
        sounds: []const struct { position_bits: [3]u32, options: [3]u32 },
        frames: []const struct { now: u32, removed: bool, state: Snapshot },
    };
    const corpus = (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/blood-splash-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("1697b9fe204c0c337091664c3e196b5c53efed6001afbc338ad2efec640ad676", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var costume = try nwx.Costume.parse(a, try archive.find(blood.splash_costume_name, 0));
    defer costume.deinit();
    const request = blood.Splash{ .sector = 0, .position = .{ .x = 1.25, .y = 0, .z = -3.75 } };
    var particle = blood.Spawn{ .actor = try blood.spawnSplash(&costume, request, 1000), .state = .{ .velocity = .{ .x = 0, .y = 0, .z = 0 } } };
    try check(corpus.initial, particle, corpus.initial.random);
    const sound = blood.splashSound(request);
    try std.testing.expectEqualStrings("smsplash.wav", sound.basename);
    try std.testing.expectEqual(@as(usize, 1), corpus.sounds.len);
    try std.testing.expectEqualDeep(corpus.sounds[0].position_bits, bits(sound.position.?));
    try std.testing.expectEqualDeep(corpus.sounds[0].options, [3]u32{ @bitCast(sound.priority.?), @bitCast(sound.volume.?), sound.flags.? });
    try std.testing.expect(!try blood.selectSplash(&particle.actor, 1000));
    try check(corpus.selected, particle, corpus.selected.random);
    for (corpus.frames) |frame| {
        try std.testing.expectEqual(frame.removed, try blood.advanceSplash(&particle.actor, frame.now));
        try check(frame.state, particle, frame.state.random);
    }
    try std.testing.expect(corpus.frames[corpus.frames.len - 1].removed);
}

test "general actor scheduler gravity and conveyors" {
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
        conveyor: ?[3]f32 = null,
    };
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const struct { config: Config, flags: u32, initial: Snapshot, stepped: bool, result: Snapshot } };
    const corpus = (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/actor-general-physics-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("cb55018d7b5a7a5c2ddd13db0ea46a238348822e887f37a9f2a0213dcf0613ef", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var costume = try nwx.Costume.parse(a, try archive.find(blood.costume_name, 0));
    defer costume.deinit();
    const angles = camera.Angles.init();
    for (corpus.cases, 0..) |case, index| {
        errdefer std.debug.print("reference general actor physics case{d}\n", .{index});
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
        var scene: scene_module.Scene = undefined;
        scene.sectors = (&sector_state)[0..1];
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;
        const world = physics.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} } };
        var random = config.seed;
        var particle = try blood.spawn(&costume, &random, 0, point(config.position), 1000);
        particle.actor.flags = case.flags;
        try check(case.initial, particle, random);
        try std.testing.expectEqual(case.stepped, try blood.scheduledPhysics(&particle.actor, &particle.state, world, 0.05));
        try check(case.result, particle, random);
    }
}

test "dynamic callbacks retain exact projectile contact stack residue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Config = struct {
        position: [3]f32,
        velocity: [3]f32 = .{ 3, 2, -4 },
        friction: f32 = 0.3,
        gravity: f32 = -60,
        ceiling: f32 = 60,
        floor: f32 = 0,
        conveyor: ?[3]f32 = null,
        water: bool = false,
    };
    const Initial = struct { position_bits: [3]u32, velocity_bits: [3]u32, flags: u32, height_bits: u32, radius_bits: u32, scale_bits: [2]u32 };
    const Case = struct { kind: []const u8, config: Config, initial: Initial, residue_before: [4]u32, raw_query: [30]u32, dynamic_position_bits: [3]u32, dynamic_velocity_bits: [3]u32 };
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const Case };
    const corpus = (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/projectile-dynamic-stack.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("d402d78958dbcd331b52d487a40150a60142f378dc6ad0b493d38e7b7bf2b92c", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var costume = try nwx.Costume.parse(a, try archive.find(blood.costume_name, 0));
    defer costume.deinit();
    const angles = camera.Angles.init();
    for (corpus.cases, 0..) |case, case_index| {
        errdefer std.debug.print("dynamic contact stack case{d} {s}\n", .{ case_index, case.kind });
        const config = case.config;
        const is_blood = std.mem.eql(u8, case.kind, "blood");
        const is_bubble = std.mem.eql(u8, case.kind, "bubble");
        const is_fragment = std.mem.eql(u8, case.kind, "fragment");
        var sectors = [_]level_module.Sector{ std.mem.zeroes(level_module.Sector), std.mem.zeroes(level_module.Sector) };
        sectors[0].vadjoin = if (config.water) 1 else -1;
        sectors[0].gravity = config.gravity;
        sectors[0].friction = config.friction;
        sectors[0].elasticity = 0.5;
        sectors[0].floor.height = config.floor;
        sectors[0].ceiling.height = config.ceiling;
        if (config.conveyor) |value| sectors[0].velocity = point(value);
        sectors[1].vadjoin = 0;
        sectors[1].friction = 0.5;
        sectors[1].gravity = -50;
        sectors[1].elasticity = 0.5;
        sectors[1].floor.height = -100;
        sectors[1].ceiling.height = 0;
        var level: level_module.Level = undefined;
        level.sectors = &sectors;
        var states = [_]scene_module.SectorState{ std.mem.zeroes(scene_module.SectorState), std.mem.zeroes(scene_module.SectorState) };
        states[0].velocity_present = config.conveyor != null;
        states[1].flags = 0x80;
        var scene: scene_module.Scene = undefined;
        scene.sectors = &states;
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;
        var residue = @import("../projectile/contact.zig").Residue{};
        for (case.residue_before, 0..) |value, index| residue.words[index] = value;
        const world = physics.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} }, .contact_stack = .{ .residue = &residue, .caller = .fragment } };
        var actor = @import("../render/objects.zig").Actor{
            .costume = &costume,
            .sector = 0,
            .position = fromBits(case.initial.position_bits),
            .flags = case.initial.flags,
            .secondary_flags = 0x800000,
            .scale_x = @bitCast(case.initial.scale_bits[0]),
            .scale_y = @bitCast(case.initial.scale_bits[1]),
            .height = @bitCast(case.initial.height_bits),
            .collision_radius = @bitCast(case.initial.radius_bits),
            .yaw = 0,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };
        var movement = blood.State{ .velocity = fromBits(case.initial.velocity_bits) };
        const unresolved_projection = config.ceiling == 10.1 and !is_bubble;
        const start = actor.position;
        try dynamicStackTick(case.kind, &actor, &movement, world);
        if (unresolved_projection) try std.testing.expectEqualDeep([2]u32{ @bitCast(start.x), @bitCast(start.z) }, [2]u32{ @bitCast(actor.position.x), @bitCast(actor.position.z) });
        for ([_]usize{ 7, 10, 11, 12 }, 0..) |word, index| {
            if (config.water and !is_bubble and (if (is_blood) index != 0 else if (is_fragment) index != 3 else index >= 2)) {
                try std.testing.expectEqual(@as(?u32, null), residue.words[index]);
            } else try std.testing.expectEqual(@as(?u32, case.raw_query[word]), residue.words[index]);
        }
        if (!unresolved_projection) {
            try std.testing.expectEqualDeep(case.dynamic_position_bits, bits(actor.position));
            try std.testing.expectEqualDeep(case.dynamic_velocity_bits, bits(movement.velocity));
        }
    }
}

test "player blood projection preserves proven scheduler stack words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Initial = struct {
        position_bits: [3]u32,
        velocity_bits: [3]u32,
        flags: u32,
        height_bits: u32,
        radius_bits: u32,
        scale_bits: [2]u32,
    };
    const PlayerConfig = struct { original_scene: bool = false, sector: usize = 0, position: [3]f32, velocity: [3]f32 = .{ 0, 0, 0 }, yaw: i16 = 0 };
    const Case = struct {
        player_config: PlayerConfig,
        player_slots: []const [3]i32,
        previous: ?[]const u8,
        prior_ceiling: f32,
        held: bool = false,
        initial: Initial,
        prior_initial: ?Initial,
        before: [4]u32,
        projections: []const struct { query_from_frame: i32, words: [4]u32 },
        position_bits: [3]u32,
        velocity_bits: [3]u32,
        floor_cache_bits: u32,
    };
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const Case };
    const corpora = [_]Corpus{
        (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/collision-projection-stack.json"), .{ .ignore_unknown_fields = true })).value,
        (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/collision-projectile-projection.json"), .{ .ignore_unknown_fields = true })).value,
    };
    for (corpora) |corpus| try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("6c191effb86ea6241a676d186b3365a4c4a6acb89961dff4f2ec13cad732dc34", corpora[0].results_sha256);
    try std.testing.expectEqualStrings("4a59c059fe16b945ada8856d278c0c79747bea49036f8bd9eb3b11990d24e29f", corpora[1].results_sha256);
    const movement_module = @import("../player/movement.zig");
    const input = @import("../player/input.zig");
    const object_archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const system_archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"));
    const geometry_archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    var item = try @import("../assets/item.zig").Item.parse(a, try object_archive.find("CIDJAMES.ITM", 0));
    defer item.deinit();
    const air = try movement_module.Physics.parse(try system_archive.find("AIR.PHY", 0));
    var costume = try nwx.Costume.parse(a, try object_archive.find(blood.costume_name, 0));
    defer costume.deinit();
    var hideout = try level_module.Level.parse(a, try geometry_archive.find("HIDEOUT.LVB", 0));
    defer hideout.deinit();
    var startup = try @import("../render/initial_state.zig").InfStartup.apply(a, &hideout, try geometry_archive.find("HIDEOUT.INF", 0));
    defer startup.deinit();
    const angles = camera.Angles.init();
    var hideout_scene = try scene_module.Scene.init(a, &hideout, &angles);
    defer hideout_scene.deinit();
    startup.applyScene(&hideout, &hideout_scene);
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};
    sectors[0].vadjoin = -1;
    sectors[0].gravity = -60;
    sectors[0].friction = 0.3;
    sectors[0].elasticity = 0.5;
    sectors[0].ceiling.height = 10.1;
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    var states = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
    var scene: scene_module.Scene = undefined;
    scene.sectors = &states;
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;
    for (corpora) |corpus| for (corpus.cases, 0..) |case, index| {
        errdefer std.debug.print("reference projection stack case{d}\n", .{index});
        const config = case.player_config;
        var player = try movement_module.Player.init(&item, air, .{ .sector = config.sector, .position = point(config.position), .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        player.yaw = config.yaw;
        player.velocity = point(config.velocity);
        var packet: input.Packet = .{};
        packet.entries[23] = .{ .value = 100, .flags = 0x20 };
        for (case.player_slots) |slot| packet.entries[@intCast(slot[0])] = .{ .value = @intCast(slot[1]), .flags = @intCast(slot[2]) };
        var look: input.LookState = .{};
        const control = look.control(&packet);
        if (config.original_scene) {
            try player.tick(&hideout, &hideout_scene, .{ .entries = &.{} }, &angles, control, &look, 0.2);
        } else {
            sectors[0].gravity = -50;
            sectors[0].friction = 1;
            sectors[0].ceiling.height = 30;
            try player.tick(&level, &scene, .{ .entries = &.{} }, &angles, control, &look, 0.2);
            sectors[0].gravity = -60;
            sectors[0].friction = 0.3;
        }
        const world = physics.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} }, .contact_stack = .{ .residue = &player.contact_residue, .caller = .fragment } };
        var actor = projectionActor(&costume, case.initial);
        var motion = blood.State{ .velocity = fromBits(case.initial.velocity_bits) };
        if (case.previous) |kind| {
            const prior = case.prior_initial.?;
            var previous_actor = projectionActor(&costume, prior);
            var previous_motion = blood.State{ .velocity = fromBits(prior.velocity_bits) };
            sectors[0].ceiling.height = case.prior_ceiling;
            if (std.mem.eql(u8, kind, "knife") or std.mem.eql(u8, kind, "explosive")) {
                if (!case.held) {
                    var callback_world = world;
                    callback_world.contact_stack.?.caller = if (std.mem.eql(u8, kind, "knife")) .knife else .explosive;
                    try blood.projectilePhysics(&previous_actor, &previous_motion, callback_world, 0.2, null, null);
                }
            } else if (std.mem.eql(u8, kind, "bubble") and case.prior_ceiling == 10.1) {
                try std.testing.expect(try @import("bubble.zig").tick(&previous_actor, &previous_motion, world, 0.2, 1000));
                player.contact_residue.invalidateProjection();
            } else try dynamicStackTick(kind, &previous_actor, &previous_motion, world);
        }
        sectors[0].ceiling.height = 10.1;
        const unknown = !config.original_scene or (if (case.previous) |kind| std.mem.eql(u8, kind, "fragment") or (std.mem.eql(u8, kind, "bubble") and case.prior_ceiling == 10.1) else false);
        if (unknown) {
            const start = actor.position;
            _ = try blood.tick(&actor, &motion, world, 0.2);
            try std.testing.expectEqualDeep([2]u32{ @bitCast(start.x), @bitCast(start.z) }, [2]u32{ @bitCast(actor.position.x), @bitCast(actor.position.z) });
            continue;
        }
        for (case.before, player.contact_residue.projection.words) |expected, actual| try std.testing.expectEqual(@as(?u32, expected), actual);
        try std.testing.expect(!try blood.tick(&actor, &motion, world, 0.2));
        for (case.projections) |projection| {
            try std.testing.expectEqual(@as(i32, -0x138), projection.query_from_frame);
            for (projection.words, player.contact_residue.projection.words) |expected, actual| try std.testing.expectEqual(@as(?u32, expected), actual);
        }
        try std.testing.expectEqualDeep(case.position_bits, bits(actor.position));
        try std.testing.expectEqualDeep(case.velocity_bits, bits(motion.velocity));
        try std.testing.expectEqual(case.floor_cache_bits, @as(u32, @bitCast(motion.floor_cache)));
    };
}
