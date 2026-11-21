//! Enemy logic: ticks, combat decisions, movement, hit impulses, throws, death sequences and the special enemies.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const controller = @import("controller.zig");
const Target = @import("../player/target.zig").Target;
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const occlusion = @import("../audio/occlusion.zig");
const Actor = @import("../render/objects.zig").Actor;
const object_state = @import("../render/object_state.zig");
const audio = @import("../audio/runtime.zig");

const Snapshot = struct {
    health_bits: u32,
    velocity_bits: [3]u32,
    mode: u32,
    previous_mode: u32,
    anger_bits: u32,
    fear_bits: u32,
    attack_at: u32,
    sight_at: u32,
    next_tick: u32,
    current_chor: u32,
    animation_ended: bool,
    saved_mode: ?u32,
    saved_health_bits: ?u32,
    flags: u32,
    height_bits: u32,
    playback: [8]u32,
    random: u32,
    position_bits: [3]u32,
    yaw: i16,
    timer: u32,
    destroy: u8,
    stopped: u8,
    last_tick: u32,
    removed: bool,
    logic_words: ?[]u32 = null,
    target_is_player: bool = false,
};

const Effect = struct {
    kind: []const u8,
    words: ?[10]u32 = null,
    same_sector: bool = false,
    sender_is_actor: bool = false,
    name: ?[]const u8 = null,
    frequency_bits: ?u32 = null,
};

const Frame = struct { now: u32, before_tick: Snapshot, after_tick: Snapshot, effects: []Effect };

const Case = struct {
    name: []const u8,
    difficulty: u32,
    damage: ?f32 = null,
    height_ratio: f32 = 0,
    mass: f32 = 0,
    audio_active: bool = false,
    initial: Snapshot,
    hit: ?Snapshot = null,
    delivered: ?Snapshot = null,
    frames: []Frame,
};

const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []Case };

const SpecialSnapshot = struct {
    secondary_flags: u32,
    special: u8,
    taunt_at: u32,
    sub_timer: u32,
    aim_yaw: i16,
    schedule: u32,
    common_enabled: u32,
    completed: u32,
    reflected: [][]u32,
};

fn compare(path: []const u8, expected_hash: []const u8, living: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = (try std.json.parseFromSlice(Corpus, a, try read(a, path), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings(expected_hash, corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapon = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    var sector = std.mem.zeroes(level_module.Sector);
    sector.vadjoin = -1;
    sector.ceiling.height = 64;
    sector.ambient = 31;
    var level: level_module.Level = undefined;
    level.sectors = (&sector)[0..1];
    var state = std.mem.zeroes(scene_module.SectorState);
    var scene: scene_module.Scene = undefined;
    scene.sectors = (&state)[0..1];
    const angles = camera.Angles.init();
    for (corpus.cases, 0..) |case, index| {
        errdefer std.debug.print("reference controller {s} case {d}: {s}/{x}\n", .{ path, index, case.name, case.difficulty });
        var item = try Item.parse(a, try archive.find(try std.fmt.allocPrint(a, "{s}.ITM", .{case.name}), 0));
        defer item.deinit();
        var costume = try nwx.Costume.parse(a, try archive.find(item.animation, 0));
        defer costume.deinit();
        var object = std.mem.zeroes(level_module.Object);
        object.name = case.name;
        var actor = (try object_state.State.init(object, 0, &item, &costume)).actor(&costume);
        actor.source_index = 0;
        actor.logic_name = item.function;
        var target = (try Target.load(a, &.{ archive, weapon }, &item, case.difficulty)).?;
        target.playback.last_time = 1000;
        var cache = try occlusion.Cache.init(a, &level);
        defer cache.deinit();
        var random = case.initial.random;
        var shared: controller.Shared = .{ .now = 1000 };
        var effects: std.ArrayList(controller.Effect) = .empty;
        const sound = if (case.audio_active) try audio.Runtime.open(a, std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"))) else null;
        defer if (sound) |runtime| runtime.deinit();
        var ctx = controller.Context{ .allocator = a, .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} }, .player = if (living) .{ .position = .{ .x = 20, .y = 0, .z = 0 }, .sector = 0, .height = 6, .radius = 1.5, .yaw = 0, .flags = 1, .secondary_flags = 0x10 } else null, .visibility = &cache, .random = &random, .now = 1000, .elapsed_seconds = 0.016, .shared = &shared, .effects = &effects, .difficulty = case.difficulty, .audio = sound };
        try expectSnapshot(case.initial, target, actor, random);
        if (case.damage) |damage| {
            try controller.hitMessage(&target, &actor, .{ .kind = 1, .damage = damage, .mass = case.mass, .speed = 1000, .pitch = 0, .yaw = 4096, .lateral = 0, .height = actor.height * case.height_ratio, .shooter_position = .{ .x = 20, .z = 0 } }, &ctx);
            try expectSnapshot(case.hit.?, target, actor, random);
            try target.deliverWithContext(&actor, &ctx);
            try expectSnapshot(case.delivered.?, target, actor, random);
        }
        for (case.frames) |frame| {
            errdefer std.debug.print("reference frame {d}\n", .{frame.now});
            ctx.now = frame.now;
            ctx.elapsed_seconds = 0.05;
            effects.clearRetainingCapacity();
            try target.deliverWithContext(&actor, &ctx);
            try target.advanceAnimation(&actor, &ctx);
            try expectSnapshot(frame.before_tick, target, actor, random);
            const remove = try controller.tick(&target, &actor, &ctx);
            try std.testing.expectEqual(frame.after_tick.removed, remove);
            try expectSnapshot(frame.after_tick, target, actor, random);
            var shot_index: usize = 0;
            for (frame.effects) |effect| {
                if (effect.frequency_bits) |frequency| {
                    const runtime = sound orelse return error.MissingReferenceAudioRuntime;
                    const voice = runtime.engine.find(runtime.engine.next_id) orelse return error.MissingReferenceEnemyVoice;
                    try std.testing.expectEqual(frequency, @as(u32, @bitCast(voice.params.frequency_factor)));
                    try std.testing.expect(std.ascii.eqlIgnoreCase(effect.name.?, runtime.names.items[voice.asset]));
                }
                if (!std.mem.eql(u8, effect.kind, "shot")) continue;
                const actual = effects.items[shot_index].fire;
                const shot = actual.shot;
                const words = [10]u32{ if (shot.kind == .bullet) 1 else 0, @intFromBool(shot.impact_effect), @bitCast(shot.damage), @bitCast(shot.mass), @bitCast(shot.rate), @bitCast(shot.range), @bitCast(shot.origin.x), @bitCast(shot.origin.y), @bitCast(shot.origin.z), @as(u16, @bitCast(shot.pitch)) | (@as(u32, @as(u16, @bitCast(shot.yaw))) << 16) };
                try std.testing.expectEqual(effect.words.?, words);
                try std.testing.expectEqual(effect.same_sector, shot.sector == 0);
                try std.testing.expectEqual(effect.sender_is_actor, actual.source == 0);
                shot_index += 1;
            }
            try std.testing.expectEqual(shot_index, effects.items.len);
        }
    }
}

fn expectSnapshot(expected: Snapshot, target: Target, actor: Actor, random: u32) !void {
    try std.testing.expectEqual(expected.health_bits, @as(u32, @bitCast(target.damage.health)));
    try std.testing.expectEqual(expected.velocity_bits, bits(target.damage.velocity));
    try std.testing.expectEqual(expected.mode, target.mode);
    try std.testing.expectEqual(expected.previous_mode, target.previous_mode);
    try std.testing.expectEqual(expected.anger_bits, @as(u32, @bitCast(target.anger)));
    try std.testing.expectEqual(expected.fear_bits, @as(u32, @bitCast(target.fear)));
    try std.testing.expectEqual(expected.attack_at, target.attack_at);
    try std.testing.expectEqual(expected.sight_at, target.sight_at);
    try std.testing.expectEqual(expected.next_tick, target.next_tick);
    try std.testing.expectEqual(expected.current_chor, target.damage.current_chor);
    try std.testing.expectEqual(expected.animation_ended, target.animation_ended);
    try std.testing.expectEqual(expected.saved_mode, if (target.ai.stack) |saved| saved.mode else null);
    try std.testing.expectEqual(expected.saved_health_bits, if (target.ai.stack) |saved| @as(u32, @bitCast(saved.damage.health)) else null);
    try std.testing.expectEqual(expected.flags, actor.flags);
    try std.testing.expectEqual(expected.height_bits, @as(u32, @bitCast(actor.height)));
    const p = target.playback;
    try std.testing.expectEqual(expected.playback[0..7].*, [7]u32{ p.last_time, @as(u16, @bitCast(p.angle_offset)), p.direction, p.choreography, p.next_frame, p.frame, p.flags });
    try std.testing.expectEqual(expected.random, random);
    try std.testing.expectEqual(expected.position_bits, bits(actor.position));
    try std.testing.expectEqual(expected.yaw, actor.yaw);
    try std.testing.expectEqual(expected.timer, target.ai.deadline);
    try std.testing.expectEqual(expected.destroy != 0, target.ai.remove);
    try std.testing.expectEqual(expected.stopped != 0, target.ai.physics.movement_disabled);
    try std.testing.expectEqual(expected.last_tick, target.ai.updated_at);
    if (expected.logic_words) |words| {
        try std.testing.expectEqual(words[0x34 / 4], target.ai.watch_at);
        try std.testing.expectEqual(words[0x28 / 4], target.ai.sub_timer);
        try std.testing.expectEqual(words[0x40 / 4], target.ai.taunt_at);
        try std.testing.expectEqual(words[0x6c / 4], @as(u32, @bitCast(target.ai.physics.move_speed)));
        try std.testing.expectEqual(words[0x74 / 4], target.ai.physics.movement_mode);
        try std.testing.expectEqual(words[0x60 / 4 ..][0..3].*, bits(target.ai.physics.goal));
        try std.testing.expectEqual(words[0x118 / 4 ..][0..3].*, bits(target.ai.last_seen));
        try std.testing.expectEqual(words[0x10c / 4], target.ai.previous_seen_at);
        try std.testing.expectEqual(words[0x110 / 4], target.ai.last_seen_at);
        try std.testing.expectEqual(words[0x134 / 4], target.ai.visible_until);
        try std.testing.expectEqual(expected.target_is_player, if (target.ai.target) |id| id == .player else false);
    }
}

fn bits(v: level_module.Vec3) [3]u32 {
    return .{ @bitCast(v.x), @bitCast(v.y), @bitCast(v.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn compareStack(path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Before = struct {
        residue: [4]u32,
        position_bits: [3]u32,
        flags: u32,
        height_bits: u32,
        playback: [8]i64,
        velocity_bits: [3]u32,
        mode: u32,
        previous_mode: u32,
        sight_at: u32,
        random: u32,
        player_position_bits: [3]u32,
        player_height_bits: u32,
        player_yaw: i16,
        player_flags: u32,
        player_secondary_flags: u32,
        difficulty: u32 = 0x100000,
        physics_goal_bits: [3]u32 = .{ 0, 0, 0 },
        movement_disabled: u8 = 1,
        movement_mode: u32 = 0,
        current_chor: u8 = 0,
    };
    const StackCase = struct { name: []const u8, variant: []const u8, follower: ?[]const u8, before: Before, raw_query: [30]u32, unknown_words: [4]bool };
    const StackCorpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const StackCase };
    const corpus = (try std.json.parseFromSlice(StackCorpus, a, try read(a, path), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("8b63348b1b564cbce2eb699b8e0fb37f4bf0566ed8f444721ec9dfea29e792fe", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapons = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    const angles = camera.Angles.init();
    for (corpus.cases, 0..) |case, index| {
        errdefer std.debug.print("enemy stack case{d} {s} {s}\n", .{ index, case.name, case.variant });
        var item = try Item.parse(a, try archive.find(try std.fmt.allocPrint(a, "{s}.ITM", .{case.name}), 0));
        var costume = try nwx.Costume.parse(a, try archive.find(item.animation, 0));
        var object = std.mem.zeroes(level_module.Object);
        object.name = case.name;
        var actor = (try object_state.State.init(object, 0, &item, &costume)).actor(&costume);
        actor.source_index = 0;
        actor.position = stackPoint(case.before.position_bits);
        actor.flags = case.before.flags;
        actor.height = @bitCast(case.before.height_bits);
        actor.choreography = @intCast(case.before.playback[3]);
        actor.frame = @intCast(case.before.playback[5]);
        actor.angle_offset = @intCast(case.before.playback[1]);
        var target = (try Target.load(a, &.{ archive, weapons }, &item, case.before.difficulty)).?;
        target.damage.velocity = stackPoint(case.before.velocity_bits);
        target.mode = case.before.mode;
        if (std.mem.endsWith(u8, case.variant, "death_empty")) target.drop_item = "";
        target.previous_mode = case.before.previous_mode;
        target.sight_at = case.before.sight_at;
        target.ai.physics.goal = stackPoint(case.before.physics_goal_bits);
        target.ai.physics.movement_disabled = case.before.movement_disabled != 0;
        target.ai.physics.movement_mode = case.before.movement_mode;
        target.damage.current_chor = case.before.current_chor;
        if (std.mem.eql(u8, case.variant, "missing_sequence") or std.mem.eql(u8, case.variant, "visible_missing")) target.config.watch_chor = 255;
        var sector = std.mem.zeroes(level_module.Sector);
        sector.vadjoin = -1;
        sector.ceiling.height = 30;
        sector.friction = 1;
        sector.gravity = -50;
        var level: level_module.Level = undefined;
        level.sectors = (&sector)[0..1];
        var sector_state = std.mem.zeroes(scene_module.SectorState);
        var scene: scene_module.Scene = undefined;
        scene.sectors = (&sector_state)[0..1];
        var cache = try occlusion.Cache.init(a, &level);
        var random = case.before.random;
        var shared: controller.Shared = .{ .now = 1000 };
        var effects: std.ArrayList(controller.Effect) = .empty;
        var residue = @import("../projectile/contact.zig").Residue{};
        for (case.before.residue, 0..) |word, i| residue.words[i] = word;
        const projection_words = [4]?u32{ 0, 0x3f800000, 0x439c0000, 0x42ac0000 };
        residue.projection.words = projection_words;
        const sites = [_]@import("sanchez.zig").Site{.{ .source = 0, .sector = 0, .position = actor.position }};
        if (std.mem.eql(u8, case.variant, "taunt") or std.mem.eql(u8, case.variant, "reveal") or std.mem.eql(u8, case.variant, "taunt_wait")) {
            shared.total_enemies = 10;
            shared.killed_enemies = if (std.mem.eql(u8, case.variant, "reveal")) 9 else 6;
            if (std.mem.eql(u8, case.variant, "taunt_wait")) target.ai.taunt_at = 9000;
        }
        var ctx = controller.Context{ .allocator = a, .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} }, .player = .{ .position = stackPoint(case.before.player_position_bits), .sector = 0, .height = @bitCast(case.before.player_height_bits), .radius = 1.5, .yaw = case.before.player_yaw, .flags = case.before.player_flags, .secondary_flags = case.before.player_secondary_flags }, .visibility = &cache, .random = &random, .now = 1000, .elapsed_seconds = 0.2, .shared = &shared, .effects = &effects, .difficulty = case.before.difficulty, .contact_residue = &residue, .contact_sector_events = false, .sanchez_sites = &sites };
        if (try controller.tick(&target, &actor, &ctx)) {
            const resource = try std.ascii.allocUpperString(a, item.animation);
            @import("contact_stack.zig").Enemy.init(&residue, target.native).death(resource, actor.position, null);
        }
        if (std.mem.eql(u8, case.variant, "initial")) try std.testing.expectEqualDeep(projection_words, residue.projection.words);
        if (case.follower) |kind| {
            try std.testing.expectEqualStrings("corpse", kind);
            try std.testing.expectEqual(@as(?u32, 1), residue.words[2]);
            var corpse_costume = try nwx.Costume.parse(a, try archive.find("ADICK.NWX", 0));
            var corpse = try @import("lifecycle.zig").corpse(.{ .costume = &corpse_costume, .sector = 0, .position = .{ .x = 2, .y = 10, .z = 5 }, .yaw = 0, .flags = 0, .secondary_flags = 0, .scale_x = 1, .scale_y = 1, .height = 1, .choreography = 0, .frame = 0, .angle_offset = 0 }, 1000);
            var movement = @import("blood.zig").State{ .velocity = .{ .x = 3, .y = 2, .z = -4 } };
            sector.ceiling.height = 60;
            sector.friction = 0.3;
            sector.gravity = -60;
            sector.elasticity = 0.5;
            var world = ctx.world();
            world.contact_stack = .{ .residue = &residue, .caller = .scheduler };
            _ = try @import("blood.zig").scheduledPhysics(&corpse, &movement, world, 0.2);
        }
        for ([_]usize{ 7, 10, 11, 12 }, 0..) |word, i| {
            const missing_sound_state = std.mem.eql(u8, case.variant, "taunt");
            const expected: ?u32 = if (case.unknown_words[i] or missing_sound_state) null else case.raw_query[word];
            try std.testing.expectEqual(expected, residue.words[i]);
        }
        if (!@reduce(.Or, @as(@Vector(4, bool), case.unknown_words)) and !std.mem.eql(u8, case.variant, "taunt")) {
            _ = try residue.height();
            _ = try residue.position();
        }
    }
}

fn stackPoint(values: [3]u32) level_module.Vec3 {
    return .{ .x = @bitCast(values[0]), .y = @bitCast(values[1]), .z = @bitCast(values[2]) };
}

test "enemy tick and bound WAX match hit and death sequences" {
    try compare("testdata/enemy-runtime-reference.json", "cb0bdf393f7363ab1073d9cf199f34948d62f7eef89a75b8d0b4ac627c970916", false);
}

test "enemy combat decisions movement and bound WAX match living sequences" {
    try compare("testdata/enemy-living-reference.json", "612cde924c487daf9a3d7798fbb1a9a05a9a03f2cc74246bf035d05a223d164d", true);
}

test "enemy hit impulse and admitted voice pitch match the reference" {
    try compare("testdata/enemy-effects-reference.json", "9b1ea68546c0a3ee500a0ef6aa353f565266a56e2fe98c176168d44d5a03abf7", false);
}

test "enemy throw targeting matches the reference range perturbation and angles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ThrowCorpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { item: []const u8, position: [3]f32, seed: u32, success: bool, pitch: i16, yaw: i16, random: u32 },
    };
    const corpus = (try std.json.parseFromSlice(ThrowCorpus, a, try read(a, "testdata/enemy-throw-reference.json"), .{})).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("cda16ad625bbba4e3b5338e6bc616c6e22d6b6b138216ae822dff32f8948aaa8", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapon = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    var sector = std.mem.zeroes(level_module.Sector);
    sector.vadjoin = -1;
    sector.ceiling.height = 64;
    var level: level_module.Level = undefined;
    level.sectors = (&sector)[0..1];
    var state = std.mem.zeroes(scene_module.SectorState);
    var scene: scene_module.Scene = undefined;
    scene.sectors = (&state)[0..1];
    const angles = camera.Angles.init();
    var item = try Item.parse(a, try archive.find("BGY2BOOM.ITM", 0));
    defer item.deinit();
    var costume = try nwx.Costume.parse(a, try archive.find(item.animation, 0));
    defer costume.deinit();
    var object = std.mem.zeroes(level_module.Object);
    object.name = "BGY2BOOM";
    const actor = (try object_state.State.init(object, 0, &item, &costume)).actor(&costume);
    for (corpus.cases, 0..) |case, index| {
        errdefer std.debug.print("reference throw aim {d}: {any}\n", .{ index, case });
        var target = (try Target.load(a, &.{ archive, weapon }, &item, 0x100000)).?;
        target.ai.target = .player;
        target.config.throw_item = case.item;
        var cache = try occlusion.Cache.init(a, &level);
        defer cache.deinit();
        var random = case.seed;
        var shared: controller.Shared = .{ .now = 1000 };
        var effects: std.ArrayList(controller.Effect) = .empty;
        var ctx = controller.Context{ .allocator = a, .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} }, .player = .{ .position = .{ .x = case.position[0], .y = case.position[1], .z = case.position[2] }, .sector = 0, .height = 6, .radius = 1.5, .yaw = 0, .flags = 1, .secondary_flags = 0x10 }, .visibility = &cache, .random = &random, .now = 1000, .elapsed_seconds = 0.016, .shared = &shared, .effects = &effects };
        try std.testing.expectEqual(case.success, try controller.aimThrow(&target, actor, &ctx));
        try std.testing.expectEqual(case.pitch, target.ai.throw_pitch);
        try std.testing.expectEqual(case.yaw, target.ai.throw_yaw);
        try std.testing.expectEqual(case.random, random);
    }
}

test "enemy impulses activation and hit results retain cached AI clock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const EventCorpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { name: []const u8, difficulty: u32, initial: Snapshot, ready: Snapshot, events: []struct { code: u32, vector: [3]f32, state: Snapshot }, hit: Snapshot },
    };
    const corpus = (try std.json.parseFromSlice(EventCorpus, a, try read(a, "testdata/enemy-native-events-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("b8bde8bd7be33c83ad561fe8fa59aa8bd29405f746496fc31d1143f97bdbfeeb", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapon = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    var sector = std.mem.zeroes(level_module.Sector);
    sector.vadjoin = -1;
    sector.ceiling.height = 64;
    var level: level_module.Level = undefined;
    level.sectors = (&sector)[0..1];
    var state = std.mem.zeroes(scene_module.SectorState);
    var scene: scene_module.Scene = undefined;
    scene.sectors = (&state)[0..1];
    const angles = camera.Angles.init();
    for (corpus.cases) |case| {
        var item = try Item.parse(a, try archive.find(try std.fmt.allocPrint(a, "{s}.ITM", .{case.name}), 0));
        defer item.deinit();
        var costume = try nwx.Costume.parse(a, try archive.find(item.animation, 0));
        defer costume.deinit();
        var object = std.mem.zeroes(level_module.Object);
        object.name = case.name;
        var actor = (try object_state.State.init(object, 0, &item, &costume)).actor(&costume);
        var target = (try Target.load(a, &.{ archive, weapon }, &item, case.difficulty)).?;
        target.playback.last_time = 1000;
        var cache = try occlusion.Cache.init(a, &level);
        defer cache.deinit();
        var random = case.initial.random;
        var shared: controller.Shared = .{ .now = 1000 };
        var effects: std.ArrayList(controller.Effect) = .empty;
        var ctx = controller.Context{ .allocator = a, .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{} }, .player = null, .visibility = &cache, .random = &random, .now = 1050, .elapsed_seconds = 0.05, .shared = &shared, .effects = &effects };
        try expectSnapshot(case.initial, target, actor, random);
        try target.advanceAnimation(&actor, &ctx);
        _ = try controller.tick(&target, &actor, &ctx);
        try expectSnapshot(case.ready, target, actor, random);
        ctx.now = 5000;
        for (case.events) |entry| {
            switch (entry.code) {
                0x7d2 => controller.impulseMessage(&target, .{ .x = entry.vector[0], .y = entry.vector[1], .z = entry.vector[2] }, &ctx),
                0x7d3 => controller.activationMessage(&target, &ctx),
                0x7e3, 0x7e4 => try controller.resultMessage(&target, &actor, entry.code == 0x7e3, &ctx),
                else => return error.InvalidReferenceEnemyMessage,
            }
            try expectSnapshot(entry.state, target, actor, random);
            try std.testing.expectEqual(entry.state.logic_words.?[0x174 / 4] >> 16, target.ai.activated);
        }
        try controller.hitMessage(&target, &actor, .{ .kind = 1, .damage = 0.1, .mass = 0, .speed = 1000, .pitch = 0, .yaw = 4096, .lateral = 0, .height = actor.height * 0.75, .shooter_position = .{ .x = 20, .z = 0 } }, &ctx);
        try expectSnapshot(case.hit, target, actor, random);
        try std.testing.expectEqual(@as(u32, 1050), target.attack_at);
        try std.testing.expectEqual(@as(u32, 1050), shared.now);
    }
}

test "special enemy factories boss callbacks civilian reflection and Sanchez match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const CaseSpecial = struct {
        kind: []const u8,
        name: []const u8,
        difficulty: u32,
        state: ?Snapshot = null,
        before: ?Snapshot = null,
        after: ?Snapshot = null,
        damage: f32 = 0,
        sender: u32 = 0,
        dead_player: bool = false,
        code: u32 = 0,
        killed: f32 = 0,
    };
    const raw = try read(a, "testdata/enemy-special-reference.json");
    const cases = (try std.json.parseFromSlice(struct { cases: []CaseSpecial }, a, raw, .{ .ignore_unknown_fields = true })).value.cases;
    const extras = (try std.json.parseFromSlice(struct { cases: []struct { state: ?SpecialSnapshot = null, after: ?SpecialSnapshot = null } }, a, raw, .{ .ignore_unknown_fields = true })).value.cases;
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapon = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    var sector = std.mem.zeroes(level_module.Sector);
    sector.vadjoin = -1;
    sector.ceiling.height = 64;
    sector.ambient = 31;
    var level: level_module.Level = undefined;
    level.sectors = (&sector)[0..1];
    var state = std.mem.zeroes(scene_module.SectorState);
    var scene: scene_module.Scene = undefined;
    scene.sectors = (&state)[0..1];
    const angles = camera.Angles.init();
    const Sink = struct {
        completed: u32 = 0,
        reflected: std.ArrayList(@import("../player/shooting.zig").DamageInput) = .empty,
        allocator: std.mem.Allocator,

        fn complete(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.completed += 1;
        }

        fn reflect(ptr: *anyopaque, _: ?usize, hit: @import("../player/shooting.zig").DamageInput) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.reflected.append(self.allocator, hit);
        }
    };
    for (cases, extras, 0..) |case, extra, index| {
        errdefer std.debug.print("special original case {d} {s}/{s}\n", .{ index, case.kind, case.name });
        const item = try Item.parse(a, try archive.find(try std.fmt.allocPrint(a, "{s}.ITM", .{case.name}), 0));
        const costume = try nwx.Costume.parse(a, try archive.find(item.animation, 0));
        var object = std.mem.zeroes(level_module.Object);
        object.name = case.name;
        var actor = (try object_state.State.init(object, 0, &item, &costume)).actor(&costume);
        actor.source_index = 0;
        actor.logic_name = item.function;
        var target = (try Target.load(a, &.{ archive, weapon }, &item, case.difficulty)).?;
        target.playback.last_time = 1000;
        var cache = try occlusion.Cache.init(a, &level);
        var random: u32 = 1948486060;
        var shared: controller.Shared = .{ .now = 1000, .total_enemies = 10, .killed_enemies = case.killed };
        var effects: std.ArrayList(controller.Effect) = .empty;
        var sink: Sink = .{ .allocator = a };
        const player: controller.Subject = .{ .position = .{ .x = 20, .y = 0, .z = 0 }, .sector = 0, .height = 6, .radius = 1.5, .yaw = 0, .flags = if (case.dead_player) 0x4001 else 1, .secondary_flags = case.sender };
        var ctx = controller.Context{
            .allocator = a,
            .level = &level,
            .scene = &scene,
            .angles = &angles,
            .actors = .{ .entries = &.{} },
            .player = player,
            .visibility = &cache,
            .random = &random,
            .now = 1000,
            .elapsed_seconds = 0.016,
            .shared = &shared,
            .effects = &effects,
            .difficulty = case.difficulty,
            .hit_sender = player,
            .complete_level = .{ .context = &sink, .enqueue = Sink.complete },
            .reflected_hit = .{ .context = &sink, .enqueue = Sink.reflect },
            .sanchez_sites = &.{ .{ .source = 0, .sector = 0, .position = .{ .x = 0, .y = 0, .z = 0 } }, .{ .source = 1, .sector = 0, .position = .{ .x = 10, .y = 2, .z = 30 } } },
        };
        if (std.mem.eql(u8, case.kind, "hit")) {
            try controller.hitMessage(&target, &actor, .{ .kind = 1, .damage = case.damage, .mass = 0.03, .speed = 1000, .pitch = 0, .yaw = 4096, .lateral = 0.1, .height = 3.25, .shooter_position = .{ .x = 20, .z = 0 } }, &ctx);
        } else if (std.mem.eql(u8, case.kind, "bob")) {
            target.mode = case.before.?.mode;
            target.previous_mode = case.before.?.previous_mode;
            target.ai.target = .player;
            target.ai.has_los = true;
            target.attack_at = 9000;
            target.ai.sub_timer = 1;
            shared.next_tick = 11000;
            shared.animation_message = 99;
            _ = try controller.bobCombat(&target, &actor, case.code, &ctx);
        } else if (std.mem.eql(u8, case.kind, "sanchez")) {
            _ = try controller.tick(&target, &actor, &ctx);
        }
        try expectSnapshot(case.state orelse case.after.?, target, actor, random);
        const wanted = extra.state orelse extra.after.?;
        try std.testing.expectEqual(wanted.secondary_flags, actor.secondary_flags);
        try std.testing.expectEqual(wanted.special != 0, target.ai.special);
        try std.testing.expectEqual(wanted.taunt_at, target.ai.taunt_at);
        try std.testing.expectEqual(wanted.sub_timer, target.ai.sub_timer);
        try std.testing.expectEqual(wanted.aim_yaw, target.ai.aim_yaw);
        try std.testing.expectEqual(wanted.schedule, shared.next_tick);
        try std.testing.expectEqual(wanted.common_enabled != 0, shared.sanchez_enabled);
        try std.testing.expectEqual(wanted.completed, sink.completed);
        try std.testing.expectEqual(wanted.reflected.len, sink.reflected.items.len);
        for (wanted.reflected, sink.reflected.items) |packet, hit| {
            try std.testing.expectEqual(packet[1], @as(u32, @bitCast(hit.damage)));
            try std.testing.expectEqual(packet[2], @as(u32, @bitCast(hit.mass)));
            try std.testing.expectEqual(packet[3], @as(u32, @bitCast(hit.speed)));
            try std.testing.expectEqual(@as(f32, 0), hit.lateral);
            try std.testing.expectEqual(@as(f32, 0), hit.height);
        }
    }
}

test {
    _ = @import("save.zig");
}

test "dynamic enemy wrappers retain defined contact residue and later physics overwrites pointers" {
    try compareStack("testdata/projectile-enemy-stack.json");
}

test "civilian NaN residue survives knife damage packing and visual accumulation" {
    const shooting = @import("../player/shooting.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Message = struct {
        target: u32,
        kind: u32,
        damage_bits: u32,
        mass_bits: u32,
        speed_bits: u32,
        yaw: i16,
        pitch: i16,
        position_bits: [3]u32,
        lateral_bits: u32,
        height_bits: u32,
    };
    const Visual = struct { kind: []const u8, sector: usize, count: u32, position_bits: [3]u32 };
    const Native = struct { flags: u32, aggregate: struct { damage_bits: [3]u32, origin_bits: [3]u32, angles: [2]i16, contact_bits: [2]u32, position_bits: [3]u32 }, messages: []const Message, visuals: []const Visual };
    const Data = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const Native };
    const data = (try std.json.parseFromSlice(Data, a, try read(a, "testdata/projectile-enemy-consumption.json"), .{})).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", data.executable_sha256);
    try std.testing.expectEqualStrings("3c4cad8b634baa24688af7a0697e3b0147722f124eb27bd12bea71cd8d50da26", data.results_sha256);
    const angles = camera.Angles.init();
    for (data.cases) |case| {
        const original = case.aggregate;
        try std.testing.expectEqual(@as(u32, 0xffffffe4), original.position_bits[1]);
        try std.testing.expectEqual(@as(u32, 0xffffff9d), original.position_bits[2]);
        const input: shooting.DamageInput = .{ .kind = 2, .damage = @bitCast(original.damage_bits[0]), .mass = @bitCast(original.damage_bits[1]), .speed = @bitCast(original.damage_bits[2]), .pitch = original.angles[0], .yaw = original.angles[1], .lateral = @bitCast(original.contact_bits[0]), .height = @bitCast(original.contact_bits[1]) };
        const point = stackPoint(original.position_bits);
        const hit: shooting.ActorHit = .{ .index = 20, .position = point, .lateral = input.lateral, .height = input.height, .distance = point.z };
        var pending = shooting.PendingHit.init(20, &angles, input, hit);
        pending.position.x = point.x;
        if (case.flags & 0x10 == 0) pending.blood.add(&angles, stackPoint(original.origin_bits), point, input.yaw, 0, 3, false);
        const damage = pending.damageInput();
        try std.testing.expectEqualDeep(case.messages[0], Message{ .target = 20, .kind = damage.kind, .damage_bits = @bitCast(damage.damage), .mass_bits = @bitCast(damage.mass), .speed_bits = @bitCast(damage.speed), .yaw = damage.yaw, .pitch = damage.pitch, .position_bits = bits(pending.messagePosition()), .lateral_bits = @bitCast(damage.lateral), .height_bits = @bitCast(damage.height) });
        for (case.visuals) |visual| {
            try std.testing.expectEqualStrings("blood", visual.kind);
            try std.testing.expectEqual(visual.count, @as(u32, @bitCast(pending.blood.count)));
            try std.testing.expectEqualDeep(visual.position_bits, bits(pending.blood.average()));
        }
    }
}

test "hidden Sanchez sound branches preserve numeric contact words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Native = struct {
        mode: []const u8,
        before: [4]u32,
        words: [4]u32,
    };
    const StackData = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const Native };
    const corpus = (try std.json.parseFromSlice(StackData, a, try read(a, "testdata/sanchez-audio-stack-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("834bbb6e30ce5d0038c5a655f8bc40cbbc0622e4f73b6eaef7cffe80945381ba", corpus.results_sha256);
    const Stack = @import("contact_stack.zig").Enemy;
    for (corpus.cases) |case| {
        var residue = @import("../projectile/contact.zig").Residue{};
        for (case.before, 0..) |word, i| residue.words[i] = word;
        const outcome: Stack.HiddenSound = if (std.mem.eql(u8, case.mode, "null_handle")) .null_handle else if (std.mem.eql(u8, case.mode, "exhausted")) .exhausted else if (std.mem.eql(u8, case.mode, "disabled") or std.mem.eql(u8, case.mode, "null_driver")) .driver_disabled else .driver_enabled;
        Stack.hiddenSound(&residue, outcome);
        const unknown: [4]bool = switch (outcome) {
            .null_handle => .{ false, false, false, false },
            .exhausted => .{ true, false, false, false },
            .driver_disabled => .{ true, false, true, false },
            .driver_enabled => .{ true, false, false, true },
            .unknown_runtime => unreachable,
        };
        for (case.words, unknown, 0..) |word, is_pointer, i| try std.testing.expectEqual(if (is_pointer) @as(?u32, null) else word, residue.words[i]);
    }
}

test "hidden Sanchez connectivity writes only inserted halfwords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Native = struct {
        count: usize,
        pattern: u32,
        sectors: []const u16,
        words: [4]u32,
    };
    const StackData = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const Native };
    const corpus = (try std.json.parseFromSlice(StackData, a, try read(a, "testdata/projectile-enemy-connectivity.json"), .{})).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("820d556b804b655ac3733d066068e58404fbac95adbd245250da310188fefe05", corpus.results_sha256);
    for (corpus.cases) |case| {
        var residue = @import("../projectile/contact.zig").Residue{ .words = @splat(case.pattern) };
        @import("contact_stack.zig").Enemy.hiddenConnectivity(&residue, case.sectors);
        for (case.words, 0..) |word, i| try std.testing.expectEqual(@as(?u32, word), residue.words[i]);
        residue.words = @splat(null);
        @import("contact_stack.zig").Enemy.hiddenConnectivity(&residue, case.sectors);
        for ([_]usize{ 428, 434, 436, 438 }, 0..) |first, i| try std.testing.expectEqual(if (case.count > first + 1) @as(?u32, case.words[i]) else null, residue.words[i]);
    }
}
