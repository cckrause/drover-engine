//! Standing on a damaging surface: contact damage, its sounds and the death report.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const messages = @import("../assets/messages.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const movement = @import("movement.zig");
const choreography = @import("choreography.zig");
const input = @import("input.zig");
const inventory_module = @import("inventory.zig");
const damage = @import("damage.zig");
const player_audio = @import("../audio/player.zig");
const damage_flash = @import("../render/damage_flash.zig");

const Motion = struct {
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

    fn read(player: *const movement.Player, look: *const input.LookState) Motion {
        return .{
            .sector = player.sector,
            .position = .{ @bitCast(player.position.x), @bitCast(player.position.y), @bitCast(player.position.z) },
            .velocity = .{ @bitCast(player.velocity.x), @bitCast(player.velocity.y), @bitCast(player.velocity.z) },
            .angles = .{ player.pitch, player.yaw, player.head_yaw },
            .eye_height = @bitCast(player.eye_height),
            .body_height = @bitCast(player.body_height),
            .floor_cache = @bitCast(player.floor_cache),
            .energy = @bitCast(player.energy),
            .head_bob = @bitCast(player.head_bob),
            .weapon_offset = player.weapon_offset,
            .stride = @bitCast(player.stride),
            .flags = player.flags & 0x10003004,
            .pitch_accumulator = look.pitch_accumulator,
        };
    }
};

const Frame = struct {
    now: u32,
    movement: Motion,
    state: struct {
        health_bits: u32,
        sheriff: u8,
        damage_stat: i32,
        flash: i32,
        flash_time: u32,
        flash_red: u8,
        flash_task: u32,
        damage_calls: []const [2]u32,
        removed_bits: []const u32,
        requests: []const [6]u32,
        events: []const [4]u32,
        reports: []const []const std.json.Value,
    },
};

fn readFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn compareFrame(frame: Frame, player: *const movement.Player, look: *const input.LookState, inventory: *const inventory_module.Inventory, direct_health: *inventory_module.Inventory, flash: damage_flash.State, effects: []const inventory_module.Effect, death: ?i32, local_messages: []const u8, shriek_name: []const u8) !void {
    var expected_motion = frame.movement;
    try std.testing.expectEqual(expected_motion.flags, player.flags);
    expected_motion.flags &= 0x10003004;
    try std.testing.expectEqualDeep(expected_motion, Motion.read(player, look));
    const state = frame.state;
    try std.testing.expectEqual(state.health_bits, @as(u32, @bitCast(inventory.health)));
    try std.testing.expectEqual(state.sheriff != 0, inventory.sheriff_active);
    try std.testing.expectEqual(state.damage_stat, inventory.statistics.damage);
    try std.testing.expectEqual(state.flash, flash.strength);
    try std.testing.expectEqual(state.flash_time, flash.last_ms);
    try std.testing.expectEqual(state.flash_red, flash.alpha);
    try std.testing.expectEqual(state.flash_task, flash.last_ms);
    const has_request = player.impact != 0 or player.sector_damage != 0;
    try std.testing.expectEqual(@as(usize, if (has_request) 1 else 0), state.requests.len);
    if (has_request) try std.testing.expectEqual(state.requests[0], [_]u32{ 0, @bitCast(player.impact), player.sector_damage, 0, 0, 0 });
    try std.testing.expectEqual(state.damage_calls.len, state.removed_bits.len);
    for (state.damage_calls, state.removed_bits) |call, removed| {
        try std.testing.expectEqual(@as(u32, @intFromBool(player.impact > 45)), call[1]);
        const lost = damage.subtractHealth(direct_health, @bitCast(call[0]));
        try std.testing.expectEqual(removed, @as(u32, @bitCast(lost)));
    }
    try std.testing.expectEqual(state.health_bits, @as(u32, @bitCast(direct_health.health)));
    try std.testing.expectEqual(state.damage_stat, direct_health.statistics.damage);
    try std.testing.expectEqual(state.events.len, effects.len);
    for (state.events, effects) |expected, effect| try std.testing.expectEqual(expected, try soundEvent(effect, shriek_name));
    var local_reports: usize = 0;
    for (state.reports) |report| {
        if (!std.mem.eql(u8, report[0].string, "message") or report[2].integer != 0x800) continue;
        local_reports += 1;
        const id = death orelse return error.MissingSurfaceDeathReport;
        try std.testing.expectEqualStrings(report[1].string, try messages.lookup(local_messages, @intCast(id)));
    }
    try std.testing.expectEqual(@as(usize, if (death != null) 1 else 0), local_reports);
}

fn soundEvent(effect: inventory_module.Effect, shriek_name: []const u8) ![4]u32 {
    const sound = switch (effect) {
        .sound => |value| value,
        else => return error.UnexpectedSurfaceMessage,
    };
    const id: u32 = for ([_][]const u8{ "JAJUMP.WAV", "LAND.WAV", "LANDLITE.WAV", "HITHEAD.WAV", "TIRED.WAV", "FLOOR.WAV", "CRUNCH.WAV", "JADIE.WAV", shriek_name }, 1..) |name, index| {
        if (std.ascii.eqlIgnoreCase(name, sound.basename)) break @intCast(index);
    } else return error.UnexpectedSurfaceSound;
    try std.testing.expect(sound.position == null and sound.sector == null);
    return .{ id, @bitCast(sound.priority.?), @bitCast(sound.volume.?), sound.flags.? };
}

test "dry surface contact damage sounds and death reports" {
    const a = std.testing.allocator;
    const bytes = try readFile("testdata/player-surfaces-reference.json");
    defer a.free(bytes);
    const Fixture = struct {
        executable_sha256: []const u8,
        sha256: []const u8,
        cases: []const struct {
            name: []const u8,
            config: struct {
                sector_flags: u32,
                position: [3]f32 = .{ 0, 0, 0 },
                velocity: [3]f32 = .{ 0, 0, 0 },
                conveyor: [3]f32 = .{ 0, 0, 0 },
                flags: u32 = 4,
                gravity: f32 = 0,
                floor: f32 = 0,
                floor_cache: f32 = -2147483648,
                health: f32 = 10,
                sheriff: u8 = 0,
                damage_multiplier: ?f32 = null,
                seconds: f32 = 0.016,
            },
            frames: []const Frame,
        },
    };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.value.executable_sha256);
    try std.testing.expectEqualStrings("176b3ad1463007c0bd53b6aa1170037d7d80dad20f5e0a6f6887a7339d0b5bbb", fixture.value.sha256);
    const raw_system = try readFile("inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB");
    defer a.free(raw_system);
    const raw_objects = try readFile("inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB");
    defer a.free(raw_objects);
    const system = try lab.Archive.init(raw_system);
    const objects = try lab.Archive.init(raw_objects);
    var item = try Item.parse(a, try objects.find("CIDJAMES.ITM", 0x4954454d));
    defer item.deinit();
    const physics = try movement.Physics.parse(try system.find("AIR.PHY", 0x50485953));
    try std.testing.expectEqual(@as(f32, 3), physics.step_height);
    const audio_config = try player_audio.Config.fromItem(&item);
    const damage_config = try damage.Config.fromItem(&item);
    const chors = choreography.Table.fromItem(&item);
    const shriek_name = (try item.stringValue("SND_SHRIEK")) orelse "shriek.wav";
    const local_messages = try system.find("LOCAL.MSG", 0);
    const angles = camera.Angles.init();
    var effects = inventory_module.Effects.init(a);
    defer effects.deinit();
    var frame_count: usize = 0;
    for (fixture.value.cases) |case| {
        const config = case.config;
        var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};
        sectors[0].friction = 1;
        sectors[0].elasticity = 0.2;
        sectors[0].gravity = config.gravity;
        sectors[0].floor.height = config.floor;
        sectors[0].ceiling.height = 30;
        sectors[0].floor_sound = "FLOOR.WAV";
        sectors[0].vadjoin = -1;
        sectors[0].flags = config.sector_flags;
        sectors[0].velocity = .{ .x = config.conveyor[0], .y = config.conveyor[1], .z = config.conveyor[2] };
        var level: level_module.Level = undefined;
        level.sectors = &sectors;
        var sector_states = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
        sector_states[0].flags = config.sector_flags;
        sector_states[0].velocity_present = config.conveyor[0] != 0 or config.conveyor[1] != 0 or config.conveyor[2] != 0;
        var scene: scene_module.Scene = undefined;
        scene.sectors = &sector_states;
        const spawn = level_module.Spawn{ .sector = 0, .position = .{ .x = config.position[0], .y = config.position[1], .z = config.position[2] }, .rotation = .{ .x = 0, .y = 0, .z = 0 } };
        var player = try movement.Player.init(&item, physics, spawn);
        player.velocity = .{ .x = config.velocity[0], .y = config.velocity[1], .z = config.velocity[2] };
        player.flags = config.flags;
        player.floor_cache = config.floor_cache;
        var inventory = inventory_module.Inventory{ .health = config.health, .sheriff_active = config.sheriff != 0, .player_flags = config.flags };
        var look: input.LookState = .{};
        var audio_state: player_audio.State = .{};
        var audio = player_audio.Context{ .config = &audio_config, .state = &audio_state, .effects = &effects };
        var flash: damage_flash.State = .{};
        for (case.frames, 0..) |frame, index| {
            frame_count += 1;
            effects.clearRetainingCapacity();
            player.dead = inventory.health == 0;
            if (player.dead and player.flags & 4 != 0 and player.flags & 0x10000000 == 0) {
                player.flags = (player.flags | 0x10000000) & ~@as(u32, 0x20000000);
                player.head_bob = 0;
            }
            var packet: input.Packet = .{};
            packet.entries[23] = .{ .value = 100, .flags = 0x20 };
            const control = look.controlForLife(&packet, !player.dead);
            try player.tickWithAudio(a, &level, &scene, .{ .entries = &.{} }, &angles, control, &look, config.seconds, &audio);
            inventory.player_flags = player.flags;
            var direct_health = inventory;
            const death = try damage.applyMovement(.{ .multiplier = config.damage_multiplier orelse damage_config.multiplier }, &inventory, player.impact, player.sector_damage, config.seconds, &flash, &audio, frame.now);
            if (player.choreography_input) |value| _ = choreography.select(&player.flags, chors, value);
            compareFrame(frame, &player, &look, &inventory, &direct_health, flash, effects.items, death, local_messages, shriek_name) catch |err| {
                std.debug.print("reference surface case {s}, frame {d}\n", .{ case.name, index });
                return err;
            };
        }
    }
    try std.testing.expectEqual(@as(usize, 28), fixture.value.cases.len);
    try std.testing.expectEqual(@as(usize, 219), frame_count);
}
