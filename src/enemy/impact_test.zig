//! Where shots land: impact flags, positions, created actors, the mark rate and mark replacement.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const impact = @import("impact.zig");
const Session = @import("../render/session.zig").Session;
const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const level = @import("../assets/level.zig");
const scene = @import("../render/scene.zig");
const inf = @import("../script/inf.zig");
const weapon = @import("../player/weapon.zig");
const inventory = @import("../player/inventory.zig");

const Config = struct {
    pitch: i16 = 0,
    yaw: i16 = 0,
    origin: [3]f32 = .{ 1.25, 5, -3.75 },
    flags: u32 = 0,
    wall_flags: u32 = 0,
    wall_runtime: u32 = 1,
    velocity: [3]f32 = .{ 0, 0, 0 },
    floor_slope: ?[3]f32 = null,
    ceiling_slope: ?[3]f32 = null,
    vadjoin: bool = false,
    moving: ?u32 = null,
    enabled: u32 = 1,
    sound: u32 = 1,
    count: u32 = 0,
    noise_due: u32 = 0,
    now: u32 = 1000,
    seed: u32 = 0x742389ac,
};

const Actor = struct {
    name: []const u8,
    position_bits: [3]u32,
    flags: u32,
    secondary_flags: u32,
    height_bits: u32,
    radius_bits: u32,
    playback: [8]u32,
};

const Sound = struct { name: []const u8, position_bits: [3]u32, options: [3]u32 };

const Case = struct {
    config: Config,
    hit: struct { index: usize, angle: i16, position_bits: [3]u32 },
    actors: []const Actor,
    sounds: []const Sound,
    packets: usize,
    removed: usize,
    random: u32,
    count: u32,
    noise_due: u32,
    next_mark: usize,
};

const ShotCapture = struct {
    original: weapon.ShotSink,
    packets: *weapon.Shots,

    fn emit(context: *anyopaque, shot: weapon.Shot, effects: *inventory.Effects) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.packets.append(shot);
        try self.original.emit(self.original.context, shot, effects);
    }
};

const NoiseCapture = struct {
    original: weapon.NoiseSink,
    reports: *std.array_list.Managed(Report),

    const Report = struct { radius_bits: u32, code: u32 };

    fn emit(context: *anyopaque, radius: f32, code: u32, effects: *inventory.Effects) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.reports.append(.{ .radius_bits = @bitCast(radius), .code = code });
        try self.original.emit(self.original.context, radius, code, effects);
    }
};

fn check(session: *Session, a: std.mem.Allocator, expected: Case) !void {
    const config = expected.config;
    const sector: usize = 410;
    const old_source = session.level.sectors[sector];
    const old_state = session.scene.sectors[sector];
    const old_wall = session.scene.sectors[sector].walls[expected.hit.index];
    const old_elevators = session.inf.elevators;
    defer {
        session.level.sectors[sector] = old_source;
        session.scene.sectors[sector] = old_state;
        session.scene.sectors[sector].walls[expected.hit.index] = old_wall;
        session.inf.elevators = old_elevators;
    }
    const source = &session.level.sectors[sector];
    const state = &session.scene.sectors[sector];
    source.floor.height = 0;
    source.ceiling.height = 10;
    source.vadjoin = if (config.vadjoin) 0 else -1;
    source.velocity = point(config.velocity);
    state.flags = config.flags;
    state.floor_slope = slope(config.floor_slope);
    state.ceiling_slope = slope(config.ceiling_slope);
    state.walls[expected.hit.index].flags = config.wall_flags;
    state.walls[expected.hit.index].runtime_flags = config.wall_runtime;
    state.walls[expected.hit.index].angle = expected.hit.angle;
    var elevator = [_]inf.Elevator{.{ .sector = sector, .kind = if (config.moving) |kind| @enumFromInt(kind) else .floor, .value = 0, .speed = 2, .runtime_flags = 1 }};
    session.inf.elevators = if (config.moving != null) &elevator else &.{};
    session.animation_time = config.now;
    const first = session.actor_slots.len;
    const selection = session.enemy_selection_serial;
    const old_removed = removedCount(session);
    var effects = inventory.Effects.init(a);
    defer effects.deinit();
    const shot = weapon.Shot{ .kind = .bullet, .sector = sector, .origin = point(config.origin), .yaw = config.yaw, .pitch = config.pitch, .range = 100, .damage = 0, .mass = 0, .rate = 0, .impact_effect = config.enabled != 0, .impact_sound = config.sound != 0 };
    try impact.apply(session, a, shot, .{ .sector = sector, .index = expected.hit.index, .position = fromBits(expected.hit.position_bits), .along = 0 }, &effects);
    try std.testing.expectEqual(expected.random, session.contact_state.random);
    try std.testing.expectEqual(expected.count, session.impact_state.count);
    try std.testing.expectEqual(expected.noise_due, session.impact_state.noise_due);
    try std.testing.expectEqual(expected.next_mark, session.impact_state.next_mark);
    try std.testing.expectEqual(expected.packets, session.enemy_selection_serial - selection);
    try std.testing.expectEqual(expected.removed, removedCount(session) - old_removed);
    try std.testing.expectEqual(expected.actors.len, session.actor_slots.len - first);
    for (expected.actors, session.actor_slots[first..]) |native, optional| {
        const actor = optional.?;
        try std.testing.expect(actor.costume == session.costumes.get(native.name).?);
        try std.testing.expectEqualDeep(native.position_bits, bits(actor.position));
        try std.testing.expectEqual(native.flags, actor.flags);
        try std.testing.expectEqual(native.secondary_flags, actor.secondary_flags);
        try std.testing.expectEqual(native.height_bits, @as(u32, @bitCast(actor.height)));
        try std.testing.expectEqual(native.radius_bits, @as(u32, @bitCast(actor.collision_radius)));
        try std.testing.expectEqualDeep(native.playback, playbackWords(actor.playback.?));
    }
    try std.testing.expectEqual(expected.sounds.len, effects.items.len);
    for (expected.sounds, effects.items) |native, effect| {
        const sound = effect.sound;
        try std.testing.expectEqualStrings(native.name, sound.basename);
        try std.testing.expectEqualDeep(native.position_bits, bits(sound.position.?));
        try std.testing.expectEqualDeep(native.options, [3]u32{ @intCast(sound.priority.?), @intCast(sound.volume.?), sound.flags.? });
    }
}

fn playbackWords(p: @import("../assets/nwx.zig").Playback) [8]u32 {
    return .{ p.last_time, @bitCast(@as(i32, p.angle_offset)), p.direction, p.choreography, p.next_frame, p.frame, p.flags, @intFromBool(p.terminated) };
}

fn removedCount(session: *Session) usize {
    var count: usize = 0;
    for (session.removed_actors) |removed| count += @intFromBool(removed);
    return count;
}

fn slope(value: ?[3]f32) ?scene.Slope {
    const v = value orelse return null;
    return std.mem.zeroInit(scene.Slope, .{ .coeff_x = v[0], .coeff_z = v[1], .constant = v[2] });
}

fn point(v: [3]f32) level.Vec3 {
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

fn fromBits(v: [3]u32) level.Vec3 {
    return .{ .x = @bitCast(v[0]), .y = @bitCast(v[1]), .z = @bitCast(v[2]) };
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

test "wall impact flags positions actors RNG rate and mark replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        results_sha256: []const u8,
        cases: []const Case,
        sequence: []const Case,
        dust_animation: struct { selected: [8]u32, frames: []const struct { now: u32, playback: [8]u32, removed: bool } },
    };
    const fixture = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/impacts-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d646844636cad960ff6caef1efdb1a3de4f691f1942aef95d8e82fc3bb8246e7", fixture.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, archive, &startup);
    defer session.deinit(a);
    session.player.position = .{ .x = 10000, .y = 0, .z = 10000 };
    for (fixture.cases, 0..) |case, index| {
        errdefer std.debug.print("reference impact case {d}\n", .{index});
        session.impact_state = .{ .count = case.config.count, .noise_due = case.config.noise_due };
        session.contact_state.random = case.config.seed;
        try check(session, a, case);
    }
    session.impact_state = .{};
    session.contact_state.random = 0x742389ac;
    for (fixture.sequence, 0..) |case, index| {
        errdefer std.debug.print("reference impact ring step {d}\n", .{index});
        try check(session, a, case);
    }
    const blood = @import("blood.zig");
    var dust = try blood.spawnSplash(session.costumes.get(impact.dust_costume).?, .{ .sector = 410, .position = .{ .x = 0, .y = 0, .z = 0 } }, 1000);
    try std.testing.expect(!try blood.selectSplash(&dust, 1000));
    try std.testing.expectEqualDeep(fixture.dust_animation.selected, playbackWords(dust.playback.?));
    for (fixture.dust_animation.frames) |frame| {
        try std.testing.expectEqual(frame.removed, try blood.advanceSplash(&dust, frame.now));
        try std.testing.expectEqualDeep(frame.playback, playbackWords(dust.playback.?));
    }
}

test "weapon pellets interleave actual impact RNG and actor creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const FireConfig = struct {
        slot: usize,
        seed: u32,
        scope: bool = false,
        now: u32 = 1000,
        due: u32 = 0,
        loaded: i32 = 2,
        fire_sound: bool = true,
        empty_sound: bool = true,
        position: [3]f32 = .{ 1.25, 0, -3.75 },
        reload: bool = false,
    };
    const Fixture = struct { results_sha256: []const u8, cases: []const struct { config: FireConfig, shots: []const [11]u32, actors: []const struct { name: []const u8, position_bits: [3]u32 }, sounds: []const Sound, local_sounds: []const []const u8, reports: []const NoiseCapture.Report, loaded: i32, random: u32, crt_random: u32, count: u32, noise_due: u32, next_mark: usize, fire_noise_due: u32 } };
    const fixture = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/weapon-impacts-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("1f3382decbcbb25a0150bc069702c058dcf8cc6f0f829bb2d3c7721b98600454", fixture.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, archive, &startup);
    defer session.deinit(a);
    const old_sectors = session.level.sectors;
    const old_states = session.scene.sectors;
    var vertices = [_]level.Vec2{ .{ .x = -10, .z = -10 }, .{ .x = -10, .z = 10 }, .{ .x = 10, .z = 10 }, .{ .x = 10, .z = -10 } };
    var wall_array: [4]level.Wall = undefined;
    for (&wall_array, 0..) |*wall, i| wall.* = std.mem.zeroInit(level.Wall, .{ .v1 = @as(u32, @intCast(i)), .v2 = @as(u32, @intCast((i + 1) % 4)), .adjoin = -1, .dadjoin = -1, .mirror = -1, .dmirror = -1 });
    var sectors = [_]level.Sector{std.mem.zeroInit(level.Sector, .{ .vertices = &vertices, .walls = &wall_array, .vadjoin = -1 })};
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
    session.enemy_visibility.lists[0] = try a.dupe(u16, &.{0});
    session.player.sector = 0;
    session.player.position = .{ .x = 1.25, .y = 0, .z = -3.75 };
    session.player.yaw = 0;
    session.player.head_yaw = 0;
    session.player.pitch = 0;
    session.player.energy = 100;
    session.actor_links.move(@import("../render/actor_links.zig").player_id, 0);
    const archives = [_]lab.Archive{ session.system_archive, session.object_archive, session.weapon_archive };
    for (fixture.cases, 0..) |case, case_index| {
        errdefer std.debug.print("reference weapon-impact batch {d}\n", .{case_index});
        const config = case.config;
        if (session.inventory.slots[config.slot] == null) {
            const name: []const u8 = switch (config.slot) {
                4 => "ISGUN",
                5 => "IDBSGUN",
                6 => "ISAWGUN",
                9 => "IGATGUN",
                else => return error.MissingImpactWeapon,
            };
            _ = try session.inventory.acquire(try inventory.Definition.load(a, &archives, name), 0);
        }
        session.inventory.selected_weapon = config.slot;
        session.inventory.slots[config.slot].?.loaded = config.loaded;
        const original = session.inventory.slots[config.slot].?.definition.weapon.?;
        defer session.inventory.slots[config.slot].?.definition.weapon = original;
        if (!config.fire_sound) session.inventory.slots[config.slot].?.definition.weapon.?.fire_sound[0] = null;
        if (!config.empty_sound) session.inventory.slots[config.slot].?.definition.weapon.?.empty_sound[0] = null;
        session.weapon_state = .{ .action = if (config.reload) -1 else 0, .bound_slot = config.slot, .scope = config.scope, .fire_noise_due = config.due };
        session.contact_state.random = config.seed;
        session.player.position = point(config.position);
        session.enemy_shared.crt_random = 1;
        session.impact_state = .{};
        session.animation_time = config.now;
        var effects = inventory.Effects.init(a);
        defer effects.deinit();
        var queued = weapon.Shots.init(a);
        defer queued.deinit();
        var packets = weapon.Shots.init(a);
        defer packets.deinit();
        var context = session.weaponContext(&effects, &queued, true);
        var capture = ShotCapture{ .original = context.shot_sink.?, .packets = &packets };
        context.shot_sink = .{ .context = &capture, .emit = ShotCapture.emit };
        var reports: std.array_list.Managed(NoiseCapture.Report) = .init(a);
        defer reports.deinit();
        var noise_capture = NoiseCapture{ .original = context.noise_sink.?, .reports = &reports };
        context.noise_sink = .{ .context = &noise_capture, .emit = NoiseCapture.emit };
        var costume = try @import("../assets/nwx.zig").Costume.parse(a, try session.weapon_archive.find(session.inventory.slots[config.slot].?.definition.costume, 0));
        defer costume.deinit();
        var playback: @import("../assets/nwx.zig").Playback = .{};
        const first = session.actor_slots.len;
        if (config.reload) {
            const input = @import("../player/input.zig");
            var packet: input.Packet = .{};
            packet.entries[@intFromEnum(input.Slot.reload)] = .{ .flags = input.absolute | input.pressed, .value = 1 };
            try session.weapon_state.inputPacket(&session.inventory, &packet, config.now);
            try context.tick(&playback, &costume);
        } else try context.event(&playback, &costume, 1, &.{}, config.now);
        try std.testing.expectEqual(@as(usize, 0), queued.items.len);
        try std.testing.expectEqual(case.shots.len, packets.items.len);
        for (case.shots, packets.items) |expected, shot| try std.testing.expectEqualDeep(expected, [11]u32{ @intFromEnum(shot.kind), @intFromBool(shot.impact_effect), @bitCast(shot.damage), @bitCast(shot.mass), @bitCast(shot.rate), @bitCast(shot.range), @bitCast(shot.origin.x), @bitCast(shot.origin.y), @bitCast(shot.origin.z), @as(u32, @as(u16, @bitCast(shot.pitch))) | (@as(u32, @as(u16, @bitCast(shot.yaw))) << 16), @intFromBool(shot.impact_sound) });
        try std.testing.expectEqual(case.loaded, session.inventory.slots[config.slot].?.loaded);
        try std.testing.expectEqual(case.random, session.contact_state.random);
        try std.testing.expectEqual(case.crt_random, session.enemy_shared.crt_random);
        try std.testing.expectEqual(case.count, session.impact_state.count);
        try std.testing.expectEqual(case.noise_due, session.impact_state.noise_due);
        try std.testing.expectEqual(case.next_mark, session.impact_state.next_mark);
        try std.testing.expectEqual(case.fire_noise_due, session.weapon_state.fire_noise_due);
        var report_index: usize = 0;
        for (case.reports) |report| {
            if (report.radius_bits == @as(u32, @bitCast(@as(f32, 100)))) continue;
            try std.testing.expect(report_index < reports.items.len);
            try std.testing.expectEqualDeep(report, reports.items[report_index]);
            report_index += 1;
        }
        try std.testing.expectEqual(report_index, reports.items.len);
        try std.testing.expectEqual(case.actors.len, session.actor_slots.len - first);
        for (case.actors, session.actor_slots[first..]) |expected, actor| {
            try std.testing.expect(actor.?.costume == session.costumes.get(expected.name).?);
            try std.testing.expectEqualDeep(expected.position_bits, bits(actor.?.position));
        }
        var sound_index: usize = 0;
        for (effects.items) |effect| if (effect == .sound and effect.sound.position != null) {
            try std.testing.expect(sound_index < case.sounds.len);
            try std.testing.expectEqualStrings(case.sounds[sound_index].name, effect.sound.basename);
            try std.testing.expectEqualDeep(case.sounds[sound_index].position_bits, bits(effect.sound.position.?));
            sound_index += 1;
        };
        try std.testing.expectEqual(case.sounds.len, sound_index);
        sound_index = 0;
        for (effects.items) |effect| if (effect == .sound and effect.sound.position == null) {
            try std.testing.expect(sound_index < case.local_sounds.len);
            try std.testing.expect(std.ascii.eqlIgnoreCase(std.fs.path.stem(case.local_sounds[sound_index]), effect.sound.basename));
            sound_index += 1;
        };
        try std.testing.expectEqual(case.local_sounds.len, sound_index);
    }
}
