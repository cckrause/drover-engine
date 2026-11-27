//! The first rendered view of a level, at every difficulty: world pixels, HUD, weapon and the prepared wall caches.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const campaign = @import("../campaign.zig");
const lab = @import("../assets/lab.zig");
const Session = @import("session.zig").Session;

fn expectFrameHash(pixels: []const u8, hex: []const u8) !void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pixels, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "all three campaign difficulties retain the full-viewport world rendering reference" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    inline for (.{ "OUTLAWS.LAB", "OLGEO.LAB", "OLTEX.LAB", "OLOBJ.LAB", "OLWEAP.LAB" }) |name| {
        std.Io.Dir.cwd().access(io, "inputs/OUTLAWS_CD1/OUTLAWS/" ++ name, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
    }
    const system_bytes = try std.Io.Dir.cwd().readFileAlloc(io, data_path, a, .limited(128 * 1024 * 1024));
    defer a.free(system_bytes);
    const system = try lab.Archive.init(system_bytes);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    const cases = .{
        .{ campaign.Difficulty.good, 36, "97ddf4f894de4f96909ab47f331bfdf281fc209604a1a3bc1124db7773b0867f" },
        .{ campaign.Difficulty.bad, 34, "b26396221c65ec422cce3590c878383683baff26c34e4c6be45a1fdc4b64d995" },
        .{ campaign.Difficulty.ugly, 30, "c6d9ef175f265b27cc926f1fe3a18bcda3a3037a77926b5838b4d595225969fa" },
    };
    inline for (cases) |case| {
        var startup = try campaign.Startup.prepare(a, system, case[0]);
        defer startup.deinit(a);
        _ = try startup.levelForDiagnostics();
        const session = try Session.open(a, @import("test_workspace.zig").get(), io, data_path, system, &startup);
        defer session.deinit(a);
        session.view.bottom = 479;
        try std.testing.expect(session.actors.len >= case[1]);
        try std.testing.expectEqual(@as(usize, 1), startup.skipped_movies);
        try std.testing.expectEqual(@as(i16, 8034), session.view.yaw);
        @memset(pixels, 0);
        _ = try session.renderWorld(pixels, 0);
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pixels, &actual, .{});
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case[2]);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectEqual(@as(usize, 65), session.rendered_sector_visits);
        @memset(pixels, 17);
        // A frame that reveals nothing new allocates nothing at all.
        const level_storage = session.arena.queryCapacity();
        _ = try session.renderWorld(pixels, 0);
        try std.testing.expectEqual(level_storage, session.arena.queryCapacity());
        std.crypto.hash.sha2.Sha256.hash(pixels, &actual, .{});
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        const yaw = session.player.yaw;
        session.player.yaw +%= 0x2000;
        _ = try session.renderWorld(pixels, 0);
        try std.testing.expect(session.actors.len > case[1]);
        const loaded_count = session.actors.len;
        session.player.yaw = yaw;
        _ = try session.renderWorld(pixels, 0);
        try std.testing.expectEqual(loaded_count, session.actors.len);
        std.crypto.hash.sha2.Sha256.hash(pixels, &actual, .{});
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "campaign HUD and weapon use the reference viewport and independently rendered pixels" {
    const a = std.testing.allocator;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, data_path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    const cases = .{
        .{ campaign.Difficulty.good, "139c9eee058dce7a09fc2e209220009e8ab5f4f865d5e3a9f0c30c46356a3565", "da9b3646842f9763d4b925e9ad0c4188fe6c8892d96265339fd4dfa6aca3aa13", "6def40c6f740be48772f33642da8b55516f924a157549cfb368f707e96a7c5d2" },
        .{ campaign.Difficulty.bad, "0ce9ff3f1fac997d5ca9c39331a3906da802a446d0851f4a45ff609cab5197d6", "7517fa1ecaf2f78a03aff57208c14605a3a1c06c6be09d37f321613ef87e9d6f", "645387be5f8b7e57444fc938e8788fedfa89b6bbaec78ba6f2ccbeb02614f2f9" },
        .{ campaign.Difficulty.ugly, "db93565223645826219520e0a041f40da564ac7033a6fa6c71ca8885c9e299f5", "5e3b7fd1b78c93efe9729dca4cea2736933c92ab9809290759e7a73ddb00c904", "b831285dee0e641cf09f8fa9a84fec35770544fc5ca4940dde78cab2ae0911bf" },
    };
    inline for (cases) |case| {
        var startup = try campaign.Startup.prepare(a, system, case[0]);
        defer startup.deinit(a);
        _ = try startup.levelForDiagnostics();
        const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, data_path, system, &startup);
        defer session.deinit(a);
        try std.testing.expectEqual(@as(i32, 439), session.view.bottom);
        try std.testing.expectEqual(@as(i32, 240), session.view.center_y);
        @memset(pixels, 0);
        _ = try session.renderWorld(pixels, 0);
        try expectFrameHash(pixels, case[1]);
        @memset(pixels, 0);
        _ = try session.render(pixels, 0);
        try expectFrameHash(pixels, case[2]);
        session.animation_time = 500;
        @memset(pixels, 0);
        _ = try session.render(pixels, 0);
        try expectFrameHash(pixels, case[3]);
    }
}

test "cleared slope flags retain renderer pointers and prepared wall caches" {
    const a = std.testing.allocator;
    const reference_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/frame-cleared-slopes-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(reference_bytes);
    const reference = try std.json.parseFromSlice(struct { sha256: []const u8, visits: []usize, seen_walls: [][2]usize }, a, reference_bytes, .{ .ignore_unknown_fields = true });
    defer reference.deinit();
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, data_path, a, .limited(128 * 1024 * 1024));
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, data_path, system, &startup);
    defer session.deinit(a);
    session.view.bottom = 479;
    for (session.scene.sectors) |*sector| {
        sector.flags &= 0x3fffffff;
        for (sector.walls) |*wall| wall.runtime_flags &= ~@as(u32, 0x40000000);
    }
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    @memset(pixels, 0);
    var frame = try @import("backends/software/world.zig").Frame.init(session.render_workspace, &session.view, &session.angles, &session.level, &session.scene, session.textures, pixels, .{
        .force_depth = 0,
        .depth_bias = 0,
        .depth_strength = 0,
        .ambient_bias = 0,
        .ambient = 0,
        .ambient_min = 0,
        .color_map = session.color_map,
        .depth_map = &session.depth_map,
    }, .scalar, 0);
    defer frame.deinit();
    try frame.draw(session.player.sector);
    try expectFrameHash(pixels, reference.value.sha256);
    try std.testing.expectEqual(reference.value.visits.len, frame.sector_visits);
    var seen: usize = 0;
    for (session.scene.sectors, 0..) |sector, i| for (sector.walls, 0..) |wall, j| {
        if (wall.runtime_flags & 0x40000000 == 0) continue;
        try std.testing.expect(seen < reference.value.seen_walls.len);
        try std.testing.expectEqual([2]usize{ i, j }, reference.value.seen_walls[seen]);
        seen += 1;
    };
    try std.testing.expectEqual(reference.value.seen_walls.len, seen);
    const state = &session.scene.sectors[session.player.sector];
    state.floor_slope = null;
    state.flags |= 0x40000000;
    try std.testing.expectError(error.MissingSceneSlope, frame.draw(session.player.sector));
}

test "Hideout wall texture messages execute independent ATX instances" {
    const a = std.testing.allocator;
    const reference_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/atx-reference.json", a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(reference_bytes);
    const Sample = struct {
        action: struct { now: u32, message: ?u32 = null, arg1: i32 = 0 },
        rate: u32,
        pc: u32,
        displayed: u32,
        last_tick: u32,
        flags: u16,
        texture_pc: usize,
        sounds: []const std.json.Value,
    };
    const Fixture = struct { cases: []const struct { name: []const u8, wall: bool, samples: []const Sample } };
    const reference = try std.json.parseFromSlice(Fixture, a, reference_bytes, .{ .ignore_unknown_fields = true });
    defer reference.deinit();
    const samples = for (reference.value.cases) |case| {
        if (case.wall and std.ascii.eqlIgnoreCase(case.name, "HAWIN2.ATX")) break case.samples;
    } else return error.MissingAtxWindowReference;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, data_path, a, .limited(128 * 1024 * 1024));
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, data_path, system, &startup);
    defer session.deinit(a);
    const instance = for (session.texture_animations.instances) |*instance| {
        if (instance.target.wall != null and instance.slot == 1 and std.ascii.eqlIgnoreCase(session.level.textures[instance.resource], "HAWIN2.ATX")) break instance;
    } else return error.MissingAtxWindow;
    const sibling = for (session.texture_animations.instances) |*other| {
        if (other != instance and other.target.wall != null and other.slot == 1 and other.resource == instance.resource) break other;
    } else return error.MissingAtxWindowSibling;
    const untouched = session.level.sectors[sibling.target.sector].walls[sibling.target.wall.?].mid.texture;
    const animation = session.textures[instance.resource].animation.?;
    for (samples[0..7]) |sample| {
        if (sample.action.message) |code| try session.inf.pending.append(.{ .message = .{
            .value = .{ .target = .{ .sector = instance.target.sector, .wall = instance.target.wall }, .code = code, .event_mask = 0x2000, .arg1 = sample.action.arg1 },
            .entity_mask = 0xffffffff,
        } });
        try session.advance(a, &.{}, sample.action.now - session.animation_time);
        try std.testing.expectEqual(sample.rate, @as(u32, @bitCast(instance.state.rate)));
        try std.testing.expectEqual(sample.pc, instance.state.pc);
        try std.testing.expectEqual(sample.displayed, instance.state.displayed);
        try std.testing.expectEqual(sample.last_tick, instance.state.last_tick);
        try std.testing.expectEqual(sample.flags, instance.state.flags);
        const actual = session.textures[@intCast(session.level.sectors[instance.target.sector].walls[instance.target.wall.?].mid.texture)];
        const expected = try @import("../assets/texture.zig").loadInitial(a, session.texture_archive, animation.instructions[sample.texture_pc].texture);
        defer expected.deinit(a);
        try std.testing.expectEqual(expected.width, actual.width);
        try std.testing.expectEqual(expected.height, actual.height);
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
        try std.testing.expectEqual(untouched, session.level.sectors[sibling.target.sector].walls[sibling.target.wall.?].mid.texture);
        var shatters: usize = 0;
        for (session.pickup_effects.items) |effect| if (effect == .sound and std.ascii.eqlIgnoreCase(effect.sound.basename, "SHATTR2")) {
            shatters += 1;
            try std.testing.expectEqual(instance.target.sector, effect.sound.sector.?);
            try std.testing.expectEqual(@as(?i32, 64), effect.sound.priority);
            try std.testing.expectEqual(@as(?u32, 4), effect.sound.flags);
        };
        try std.testing.expectEqual(sample.sounds.len, shatters);
    }
}

test "player input advances the loaded level and updates the software camera" {
    const a = std.testing.allocator;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, data_path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, data_path, system, &startup);
    defer session.deinit(a);
    const before = session.player.position;
    var input: @import("../player/input.zig").State = .{ .previous_time = 1000 };
    input.key(17, true, 1001);
    input.key(77, true, 1001);
    var now: u32 = 1016;
    for (0..6) |_| {
        const packet = try input.sample(now, .{});
        try session.advance(a, &packet, 16);
        now += 16;
    }
    try std.testing.expect(session.player.position.x != before.x or session.player.position.z != before.z);
    try std.testing.expect(session.view.yaw != 8034);
    try std.testing.expectEqual(session.player.position.x, session.view.x);
    try std.testing.expectEqual(session.player.position.z, session.view.z);
    try std.testing.expectEqual(session.player.eyePosition().y, session.view.y);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    _ = try session.render(pixels, now);
    try std.testing.expect(session.rendered_sector_visits > 0);
    const player_before = session.player;
    try session.advance(a, &.{}, 0);
    try std.testing.expectEqualDeep(player_before, session.player);
}

test "walking past adjoining Hideout sectors keeps collision and rendering active" {
    const a = std.testing.allocator;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, data_path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .bad);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, data_path, system, &startup);
    defer session.deinit(a);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    session.player.yaw = 6656;
    var packet: @import("../player/input.zig").Packet = .{};
    packet.entries[0] = .{ .value = 5120, .flags = 2 };
    packet.entries[23] = .{ .value = 100, .flags = 0x20 };
    for (0..240) |tick| {
        try session.advance(a, &packet, 16);
        if (tick == 218) try std.testing.expectEqual(@as(usize, 405), session.player.sector);
        if (tick >= 215 and tick <= 220) _ = try session.render(pixels, @intCast(tick * 16));
    }
    try std.testing.expect(session.player.position.z < 189);
    try std.testing.expectEqual(session.player.position.x, session.view.x);
    try std.testing.expectEqual(session.player.position.z, session.view.z);
    _ = try session.render(pixels, 240 * 16);
}

test "backward walking and left strafing reveal animated decorations after turning" {
    const a = std.testing.allocator;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, data_path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    for ([_]bool{ false, true }) |turn_first| {
        var startup = try campaign.Startup.prepare(a, system, .good);
        defer startup.deinit(a);
        _ = try startup.levelForDiagnostics();
        const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, data_path, system, &startup);
        defer session.deinit(a);
        const pixels = try a.alloc(u8, 640 * 480);
        defer a.free(pixels);
        var input: @import("../player/input.zig").State = .{ .previous_time = 1000 };
        input.key(if (turn_first) 75 else 31, true, 1000);
        var now: u32 = 1016;
        var strafing = false;
        for (0..110) |tick| {
            if (turn_first and !strafing and session.player.yaw <= 8034 - 0x1000) {
                input.key(75, false, now - 16);
                input.key(30, true, now - 16);
                strafing = true;
            } else if (!turn_first and tick == 63) {
                input.key(31, false, now - 16);
                input.key(75, true, now - 16);
            }
            const packet = try input.sample(now, .{});
            try session.advance(a, &packet, 16);
            _ = try session.render(pixels, now);
            now += 16;
        }
        try std.testing.expectEqual(@as(usize, 410), session.player.sector);
        try std.testing.expect(session.player.position.z > session.spawn.position.z);
        try std.testing.expect(session.player.yaw < 8034 - 0x1000);
        if (turn_first) try std.testing.expect(strafing);
        const cow = session.costumes.get("COW1.NWX") orelse return error.TestExpectedCow;
        var cow_loaded = false;
        for (session.actors) |actor| {
            if (actor.costume != cow) continue;
            cow_loaded = true;
            try std.testing.expectEqual(@as(u32, 3), actor.frame);
        }
        try std.testing.expect(cow_loaded);
    }
}
