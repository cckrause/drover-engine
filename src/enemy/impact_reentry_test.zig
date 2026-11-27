//! Impacts that happen while impacts are being processed: nested state and the shared random stream survive the actor array growing.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const Session = @import("../render/session.zig").Session;
const enemy_session = @import("session.zig");
const controller = @import("controller.zig");
const Target = @import("../player/target.zig").Target;
const Actor = @import("../render/objects.zig").Actor;
const weapon = @import("../player/weapon.zig");
const inventory = @import("../player/inventory.zig");
const lab = @import("../assets/lab.zig");
const level = @import("../assets/level.zig");
const scene = @import("../render/scene.zig");
const nwx = @import("../assets/nwx.zig");

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
    entry_random: u32,
    next_shot: u32,
    aim_yaw: i16,
    crt_random: u32,
};

const EffectActor = struct {
    name: []const u8,
    position_bits: [3]u32,
    flags: u32,
    secondary_flags: u32,
    height_bits: u32,
    radius_bits: u32,
    playback: [8]u32,
};

const Sound = struct { name: []const u8, position_bits: [3]u32, options: [3]u32 };

const Frame = struct {
    now: u32,
    before: Snapshot,
    after: Snapshot,
    shots: []const [11]u32,
    recipients: []const struct { code: u32, anger_bits: u32, fear_bits: u32 },
    actors: []const EffectActor,
    sounds: []const Sound,
    packets: usize,
    count: u32,
    noise_due: u32,
    next_mark: usize,
};

const Case = struct { name: []const u8, seed: u32, noise_due: u32, frames: []const Frame };

const Capture = struct {
    session: *Session,
    allocator: std.mem.Allocator,
    shots: std.ArrayList([11]u32) = .empty,

    fn emit(raw: *anyopaque, target: *Target, actor: *Actor, ctx: *controller.Context, shot: weapon.Shot) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try std.testing.expect(actor.flags & 0x80000100 == 0x80000100);
        try self.shots.append(self.allocator, .{ @intFromEnum(shot.kind), @intFromBool(shot.impact_effect), @bitCast(shot.damage), @bitCast(shot.mass), @bitCast(shot.rate), @bitCast(shot.range), @bitCast(shot.origin.x), @bitCast(shot.origin.y), @bitCast(shot.origin.z), @as(u32, @as(u16, @bitCast(shot.pitch))) | (@as(u32, @as(u16, @bitCast(shot.yaw))) << 16), @intFromBool(shot.impact_sound) });
        try Session.emitEnemyShot(self.session, target, actor, ctx, shot);
        try std.testing.expectEqual(self.session.actor_slots.ptr, ctx.actor_slots.ptr);
        try std.testing.expectEqual(self.session.targets.ptr, ctx.targets.ptr);
        try std.testing.expectEqual(self.session.removed_actors.ptr, ctx.actors.runtime.?.removed.ptr);
        try std.testing.expectEqual(self.session.actor_next_update.ptr, ctx.actors.runtime.?.actor_next_update.ptr);
        ctx.shot_sink = .{ .context = self, .emit = emit };
    }
};

const PacketCapture = struct {
    allocator: std.mem.Allocator,
    shots: std.ArrayList([11]u32) = .empty,
    reports: std.ArrayList([2]u32) = .empty,

    fn player(raw: *anyopaque, shot: weapon.Shot, _: *inventory.Effects) !void {
        try append(raw, shot);
    }

    fn enemy(raw: *anyopaque, _: *Target, _: *Actor, _: *controller.Context, shot: weapon.Shot) !void {
        try append(raw, shot);
    }

    fn report(raw: *anyopaque, radius: f32, code: u32, _: *inventory.Effects) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.reports.append(self.allocator, .{ @bitCast(radius), code });
    }

    fn append(raw: *anyopaque, shot: weapon.Shot) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.shots.append(self.allocator, .{ @intFromEnum(shot.kind), @intFromBool(shot.impact_effect), @bitCast(shot.damage), @bitCast(shot.mass), @bitCast(shot.rate), @bitCast(shot.range), @bitCast(shot.origin.x), @bitCast(shot.origin.y), @bitCast(shot.origin.z), @as(u32, @as(u16, @bitCast(shot.pitch))) | (@as(u32, @as(u16, @bitCast(shot.yaw))) << 16), @intFromBool(shot.impact_sound) });
    }
};

fn expectState(expected: Snapshot, target: Target, actor: Actor, session: *Session) !void {
    try std.testing.expectEqual(expected.health_bits, @as(u32, @bitCast(target.damage.health)));
    try std.testing.expectEqualDeep(expected.velocity_bits, bits(target.damage.velocity));
    try std.testing.expectEqual(expected.mode, target.mode);
    try std.testing.expectEqual(expected.previous_mode, target.previous_mode);
    try std.testing.expectEqual(expected.anger_bits, @as(u32, @bitCast(target.anger)));
    try std.testing.expectEqual(expected.fear_bits, @as(u32, @bitCast(target.fear)));
    try std.testing.expectEqual(expected.attack_at, target.attack_at);
    try std.testing.expectEqual(expected.sight_at, target.sight_at);
    try std.testing.expectEqual(expected.next_tick, target.next_tick);
    try std.testing.expectEqual(expected.flags, actor.flags);
    try std.testing.expectEqual(expected.height_bits, @as(u32, @bitCast(actor.height)));
    try std.testing.expectEqualDeep(expected.playback, playbackWords(target.playback));
    try std.testing.expectEqual(expected.random, session.contact_state.random);
    try std.testing.expectEqualDeep(expected.position_bits, bits(actor.position));
    try std.testing.expectEqual(expected.yaw, actor.yaw);
    try std.testing.expectEqual(expected.timer, target.ai.deadline);
    try std.testing.expectEqual(expected.destroy != 0, target.ai.remove);
    try std.testing.expectEqual(expected.stopped != 0, target.ai.physics.movement_disabled);
    try std.testing.expectEqual(expected.last_tick, target.ai.updated_at);
    try std.testing.expectEqual(expected.entry_random, session.enemy_shared.entry_random);
    try std.testing.expectEqual(expected.next_shot, session.enemy_shared.next_shot);
    try std.testing.expectEqual(expected.aim_yaw, target.ai.physics.yaw);
    try std.testing.expectEqual(expected.crt_random, session.enemy_shared.crt_random);
}

fn playbackWords(p: nwx.Playback) [8]u32 {
    return .{ p.last_time, @bitCast(@as(i32, p.angle_offset)), p.direction, p.choreography, p.next_frame, p.frame, p.flags, @intFromBool(p.terminated) };
}

fn bits(v: level.Vec3) [3]u32 {
    return .{ @bitCast(v.x), @bitCast(v.y), @bitCast(v.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "enemy rays preserve nested noise83 state and RNG through actor array growth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []const Case,
    };
    const fixture = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/enemy-impacts-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.executable_sha256);
    try std.testing.expectEqualStrings("b36f214d651d908fa06099ed64c212efa527cf4a6a79996b9759ce228b26d6a0", fixture.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, archive, &startup);
    defer session.deinit(a);
    const old_sectors = session.level.sectors;
    const old_states = session.scene.sectors;
    var vertices = [_]level.Vec2{ .{ .x = -10, .z = -10 }, .{ .x = -10, .z = 10 }, .{ .x = 10, .z = 10 }, .{ .x = 10, .z = -10 } };
    var walls: [4]level.Wall = undefined;
    for (&walls, 0..) |*wall, i| wall.* = std.mem.zeroInit(level.Wall, .{ .v1 = @as(u32, @intCast(i)), .v2 = @as(u32, @intCast((i + 1) % 4)), .adjoin = -1, .dadjoin = -1, .mirror = -1, .dmirror = -1 });
    var sectors = [_]level.Sector{std.mem.zeroInit(level.Sector, .{ .vertices = &vertices, .walls = &walls, .vadjoin = -1 })};
    sectors[0].ceiling.height = 10;
    session.level.sectors = &sectors;
    var geometry = try scene.Scene.init(a, &session.level, &session.angles);
    defer geometry.deinit();
    session.scene.sectors = geometry.sectors;
    defer {
        session.level.sectors = old_sectors;
        session.scene.sectors = old_states;
    }
    session.enemies_loaded = true;
    session.loaded_actor_sectors[0] = true;
    session.enemy_visibility.lists[0] = try session.arena.allocator().dupe(u16, &.{0});
    session.player.sector = 0;
    session.player.position = .{ .x = 6, .y = 0, .z = -3 };
    session.player.body_height = 6;
    session.player.radius = 1.5;
    session.actor_links.move(@import("../render/actor_links.zig").player_id, 0);
    const archives = [_]lab.Archive{ session.object_archive, session.weapon_archive, session.system_archive };
    for (fixture.cases, 0..) |case, case_index| {
        errdefer std.debug.print("reference enemy impact case {d} {s}\n", .{ case_index, case.name });
        @memset(session.removed_actors, true);
        for (session.actor_slots, 0..) |_, source| session.syncActor(source);
        var item = try @import("../assets/item.zig").Item.parse(a, try session.object_archive.find(try std.fmt.allocPrint(a, "{s}.ITM", .{case.name}), 0));
        defer item.deinit();
        const costume = try enemy_session.costume(session, item.animation);
        const object = std.mem.zeroInit(level.Object, .{ .name = case.name });
        var actor = (try @import("../render/object_state.zig").State.init(object, 0, &item, costume)).actor(costume);
        actor.logic_name = item.function;
        const source: usize = 0;
        actor.source_index = source;
        actor.sector_link_order = session.actor_link_serial;
        session.actor_link_serial += 1;
        session.actor_slots[source] = actor;
        session.removed_actors[source] = false;
        session.syncActor(source);
        session.targets[source] = (try Target.load(session.arena.allocator(), &archives, &item, 0x100000)).?;
        session.targets[source].?.playback.last_time = 1000;
        session.targets[source].?.mode = 1;
        session.targets[source].?.anger = 7;
        session.targets[source].?.fear = 0;
        session.targets[source].?.next_tick = 777;
        session.targets[source].?.ai.target = .player;
        session.targets[source].?.ai.last_seen = .{ .x = 0, .y = 0, .z = 30 };
        session.actor_next_update[source] = 777;
        session.contact_state.random = case.seed;
        session.enemy_shared = .{ .crt_random = 0 };
        session.impact_state = .{ .noise_due = case.noise_due };
        for (case.frames, 0..) |frame, frame_index| {
            errdefer std.debug.print("reference enemy impact event at {d}\n", .{frame.now});
            session.animation_time = frame.now;
            session.enemy_shared.now = frame.now;
            const target = &session.targets[source].?;
            const live_actor = &session.actor_slots[source].?;
            try expectState(frame.before, target.*, live_actor.*, session);
            const old_actor_array = session.actor_slots.ptr;
            const old_target_array = session.targets.ptr;
            const first = session.actor_slots.len;
            const selection = session.enemy_selection_serial;
            var effects = inventory.Effects.init(a);
            defer effects.deinit();
            session.active_effects = &effects;
            defer session.active_effects = null;
            var ctx = enemy_session.context(session, a, null, null);
            var runtime = enemy_session.scriptContext(session, &effects, live_actor.secondary_flags);
            runtime.linked_actor = source;
            runtime.link_order = &live_actor.sector_link_order;
            ctx.actors.runtime = &runtime;
            var capture = Capture{ .session = session, .allocator = a };
            ctx.shot_sink = .{ .context = &capture, .emit = Capture.emit };
            try controller.message(target, live_actor, 1, &.{}, &ctx);
            session.targets[source] = target.*;
            session.actor_slots[source] = live_actor.*;
            session.actor_next_update[source] = @bitCast(target.next_tick);
            session.syncActor(source);
            if (case_index == 0 and frame_index == 0) {
                try std.testing.expect(old_actor_array != session.actor_slots.ptr);
                try std.testing.expect(old_target_array != session.targets.ptr);
            }
            try expectState(frame.after, session.targets[source].?, session.actor_slots[source].?, session);
            try std.testing.expectEqualDeep(frame.shots, capture.shots.items);
            try std.testing.expectEqual(frame.count, session.impact_state.count);
            try std.testing.expectEqual(frame.noise_due, session.impact_state.noise_due);
            try std.testing.expectEqual(frame.next_mark, session.impact_state.next_mark);
            try std.testing.expectEqual(frame.packets, session.enemy_selection_serial - selection);
            try std.testing.expectEqual(frame.actors.len, session.actor_slots.len - first);
            for (frame.actors, session.actor_slots[first..]) |native, slot| {
                const actual = slot.?;
                try std.testing.expect(actual.costume == session.costumes.get(native.name).?);
                try std.testing.expectEqualDeep(native.position_bits, bits(actual.position));
                try std.testing.expectEqual(native.flags, actual.flags);
                try std.testing.expectEqual(native.secondary_flags, actual.secondary_flags);
                try std.testing.expectEqual(native.height_bits, @as(u32, @bitCast(actual.height)));
                try std.testing.expectEqual(native.radius_bits, @as(u32, @bitCast(actual.collision_radius)));
                try std.testing.expectEqualDeep(native.playback, playbackWords(actual.playback.?));
            }
            try std.testing.expectEqual(frame.sounds.len, effects.items.len);
            for (frame.sounds, effects.items) |native, effect| {
                const sound = effect.sound;
                try std.testing.expectEqualStrings(native.name, sound.basename);
                try std.testing.expectEqualDeep(native.position_bits, bits(sound.position.?));
                try std.testing.expectEqualDeep(native.options, [3]u32{ @intCast(sound.priority.?), @intCast(sound.volume.?), sound.flags.? });
            }
        }
    }
}

test "alternating player and enemy pellets share the shared random stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        results_sha256: []const u8,
        cases: []const struct { seed: u32, crt_seed: u32, frames: []const struct { kind: []const u8, now: u32, shots: []const [11]u32, reports: []const [2]u32, random: u32, crt_random: u32 } },
    };
    const fixture = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/shared-shot-random-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("e37a1dd11cbc8a89dd10ec60b5128e99b90c4e38643602bb7bf6bb81113ffe86", fixture.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, archive, &startup);
    defer session.deinit(a);
    const old_sectors = session.level.sectors;
    const old_states = session.scene.sectors;
    var sectors = [_]level.Sector{std.mem.zeroInit(level.Sector, .{ .vadjoin = -1 })};
    sectors[0].ceiling.height = 64;
    var states = [_]scene.SectorState{std.mem.zeroes(scene.SectorState)};
    session.level.sectors = &sectors;
    session.scene.sectors = &states;
    defer {
        session.level.sectors = old_sectors;
        session.scene.sectors = old_states;
    }
    session.enemy_visibility.lists[0] = try session.arena.allocator().dupe(u16, &.{0});
    session.player.sector = 0;
    session.player.position = .{ .x = 6, .y = 0, .z = -3 };
    session.player.body_height = 6;
    session.player.radius = 1.5;
    session.player.yaw = 0;
    session.player.head_yaw = 0;
    session.player.pitch = 0;
    session.player.energy = 100;
    session.aim_count = 0;
    const archives = [_]lab.Archive{ session.object_archive, session.weapon_archive, session.system_archive };
    _ = try session.inventory.acquire(try inventory.Definition.load(a, &archives, "ISGUN"), 0);
    session.inventory.selected_weapon = 4;
    var item = try @import("../assets/item.zig").Item.parse(a, try session.object_archive.find("BGY9.ITM", 0));
    defer item.deinit();
    const costume = try enemy_session.costume(session, item.animation);
    var weapon_costume = try nwx.Costume.parse(a, try session.weapon_archive.find(session.inventory.slots[4].?.definition.costume, 0));
    defer weapon_costume.deinit();
    for (fixture.cases, 0..) |case, case_index| {
        var actor = (try @import("../render/object_state.zig").State.init(std.mem.zeroInit(level.Object, .{ .name = "BGY9" }), 0, &item, costume)).actor(costume);
        var target = (try Target.load(a, &archives, &item, 0x100000)).?;
        target.mode = 1;
        target.anger = 7;
        target.fear = 0;
        target.ai.target = .player;
        target.ai.last_seen = .{ .x = 0, .y = 0, .z = 30 };
        session.contact_state.random = case.seed;
        session.enemy_shared = .{ .crt_random = case.crt_seed };
        session.weapon_state = .{ .action = 0 };
        session.inventory.slots[4].?.loaded = 30;
        var playback: nwx.Playback = .{};
        for (case.frames) |frame| {
            errdefer std.debug.print("shared native RNG case {d}, {s} at {d}\n", .{ case_index, frame.kind, frame.now });
            session.animation_time = frame.now;
            session.enemy_shared.now = frame.now;
            var effects = inventory.Effects.init(a);
            defer effects.deinit();
            var shots = weapon.Shots.init(a);
            defer shots.deinit();
            var capture = PacketCapture{ .allocator = a };
            if (std.mem.eql(u8, frame.kind, "enemy")) {
                var context = enemy_session.context(session, a, null, null);
                context.shot_sink = .{ .context = &capture, .emit = PacketCapture.enemy };
                try controller.message(&target, &actor, 1, &.{}, &context);
            } else {
                var context = session.weaponContext(&effects, &shots, true);
                context.shot_sink = .{ .context = &capture, .emit = PacketCapture.player };
                context.noise_sink = .{ .context = &capture, .emit = PacketCapture.report };
                try context.event(&playback, &weapon_costume, 1, &.{}, frame.now);
            }
            try std.testing.expectEqualDeep(frame.shots, capture.shots.items);
            try std.testing.expectEqualDeep(frame.reports, capture.reports.items);
            try std.testing.expectEqual(frame.random, session.contact_state.random);
            try std.testing.expectEqual(frame.crt_random, session.enemy_shared.crt_random);
        }
    }
}
