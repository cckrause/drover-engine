//! Being carried by moving floors and ceilings, including jumping off one.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;
const nwx = @import("../assets/nwx.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const movement = @import("movement.zig");
const input = @import("input.zig");
const inventory_module = @import("inventory.zig");
const player_audio = @import("../audio/player.zig");
const inf = @import("../script/inf.zig");
const runtime_module = @import("../script/runtime.zig");
const blood = @import("../enemy/blood.zig");
const physics = @import("../enemy/physics.zig");
const ceiling_contact = @import("ceiling_contact.zig");

const Class = struct { kind: u32, speed: f32, value: f32 = 0, target: ?f32 = null, active: bool = true };

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

    fn read(p: movement.Player, look: input.LookState) Motion {
        return .{ .sector = p.sector, .position = bits(p.position), .velocity = bits(p.velocity), .angles = .{ p.pitch, p.yaw, p.head_yaw }, .eye_height = @bitCast(p.eye_height), .body_height = @bitCast(p.body_height), .floor_cache = @bitCast(p.floor_cache), .energy = @bitCast(p.energy), .head_bob = @bitCast(p.head_bob), .weapon_offset = p.weapon_offset, .stride = @bitCast(p.stride), .flags = p.flags & 0x10003004, .pitch_accumulator = look.pitch_accumulator };
    }
};

const Generic = struct {
    position_bits: [3]u32,
    velocity_bits: [3]u32,
    flags: u32,
    floor_cache_bits: u32,
    random: u32,
    same_sector: bool,
};

const Fixture = struct {
    executable_sha256: []const u8,
    sha256: []const u8,
    bounces: []const struct { slope: ?[2]f32, speed: f32, velocity: [3]f32, mode: u32, result_bits: [3]u32, impact_bits: u32 },
    players: []const struct {
        name: []const u8,
        config: struct { position: [3]f32 = .{ 0, 0, 0 }, velocity: [3]f32 = .{ 0, 0, 0 }, flags: u32, gravity: f32, floor: f32, ceiling: f32, seconds: f32, floor_cache: f32 = -2147483648, ceiling_slope: ?[4]f32 = null, cleared_slope_flags: u32 = 0 },
        classes: []const Class,
        frames: []const struct { floor: f32, ceiling: f32, slots: []const [3]i16, movement: Motion, requests: []const [6]u32, events: []const [4]u32 },
    },
    generics: []const struct {
        config: struct { seed: u32, position: [3]f32, velocity: [3]f32 = .{ 0, 0, 0 }, gravity: f32, ceiling: f32, floor: f32, friction: f32, elasticity: f32, ceiling_slope: ?[3]f32 = null, cleared_slope_flags: u32 = 0 },
        classes: []const Class,
        floor_cache: f32,
        frames: []const struct { floor: f32, state: Generic },
    },
};

fn classes(a: std.mem.Allocator, configs: []const Class) !inf.Runtime {
    var result: inf.Runtime = undefined;
    result.elevators = try a.alloc(inf.Elevator, configs.len);
    result.classes = &.{};
    for (configs, result.elevators) |config, *e| {
        e.* = .{ .sector = 0, .kind = @enumFromInt(config.kind), .speed = config.speed, .value = config.value, .runtime_flags = @intFromBool(config.active) };
        if (config.target) |target| {
            try e.stops.append(a, .{ .value = target });
            e.target = 0;
        }
    }
    return result;
}

fn sound(effect: inventory_module.Effect) ![4]u32 {
    const request = switch (effect) {
        .sound => |s| s,
        else => return error.UnexpectedMovingPlaneEffect,
    };
    const id: u32 = for ([_][]const u8{ "JAJUMP.WAV", "LAND.WAV", "LANDLITE.WAV", "HITHEAD.WAV", "TIRED.WAV", "FLOOR.WAV" }, 1..) |name, index| {
        if (std.ascii.eqlIgnoreCase(name, request.basename)) break @intCast(index);
    } else return error.UnexpectedMovingPlaneSound;
    return .{ id, @bitCast(request.priority.?), @bitCast(request.volume.?), request.flags.? };
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

test "moving planes player transport jump and ceiling relative response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/moving-planes-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("41ccd2a8b653c42c27ffdd6e3dd510f4ca076a9e84bee327fff9fe5a599ae270", corpus.sha256);
    for (corpus.bounces, 0..) |case, index| {
        errdefer std.debug.print("reference moving ceiling bounce {d}\n", .{index});
        var velocity = point(case.velocity);
        const slope: ?scene_module.Slope = if (case.slope) |s| std.mem.zeroInit(scene_module.Slope, .{ .coeff_x = s[0], .coeff_z = s[1] }) else null;
        const impact = ceiling_contact.bounce(&velocity, slope, switch (case.mode) {
            1 => 0,
            2 => 0.2,
            else => 0.7,
        }, case.speed);
        try std.testing.expectEqualDeep(case.result_bits, bits(velocity));
        try std.testing.expectEqual(case.impact_bits, @as(u32, @bitCast(impact)));
    }
    const system = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"));
    const objects = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var item = try Item.parse(a, try objects.find("CIDJAMES.ITM", 0));
    defer item.deinit();
    const air = try movement.Physics.parse(try system.find("AIR.PHY", 0));
    const audio_config = try player_audio.Config.fromItem(&item);
    const angles = camera.Angles.init();
    var effects_buffer: inventory_module.EffectBuffer = undefined;
    var effects = inventory_module.Effects.init(&effects_buffer);
    var inventory: inventory_module.Inventory = .{};
    var native: @import("../script/cmm.zig").ContactState = .{};
    for (corpus.players) |case| {
        errdefer std.debug.print("reference moving player case {s}\n", .{case.name});
        const config = case.config;
        var sector = std.mem.zeroes(level_module.Sector);
        sector.friction = 1;
        sector.elasticity = 0.2;
        sector.gravity = config.gravity;
        sector.floor.height = config.floor;
        sector.ceiling.height = config.ceiling;
        sector.floor_sound = "FLOOR.WAV";
        sector.vadjoin = -1;
        var level: level_module.Level = undefined;
        level.sectors = (&sector)[0..1];
        var sector_state = std.mem.zeroes(scene_module.SectorState);
        if (config.ceiling_slope) |s| {
            sector_state.flags = 0x80000000 & ~config.cleared_slope_flags;
            sector_state.ceiling_slope = std.mem.zeroInit(scene_module.Slope, .{ .coeff_x = s[0], .coeff_z = s[1], .constant = s[2] });
        }
        var scene: scene_module.Scene = undefined;
        scene.sectors = (&sector_state)[0..1];
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;
        var elevators = try classes(a, case.classes);
        var runtime: runtime_module.Context = .{ .inventory = &inventory, .pickups = &.{}, .removed = &.{}, .now_ms = 1000, .effects = &effects, .contact_state = &native, .inf = &elevators, .level = &level };
        var player = try movement.Player.init(&item, air, .{ .sector = 0, .position = point(config.position), .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        player.velocity = point(config.velocity);
        player.flags = config.flags;
        player.floor_cache = config.floor_cache;
        var look: input.LookState = .{};
        var audio_state: player_audio.State = .{};
        var audio: player_audio.Context = .{ .config = &audio_config, .state = &audio_state, .effects = &effects };
        for (case.frames, 0..) |frame, index| {
            errdefer std.debug.print("reference moving player frame {d}\n", .{index});
            sector.floor.height = frame.floor;
            sector.ceiling.height = frame.ceiling;
            effects.clearRetainingCapacity();
            var packet: input.Packet = .{};
            packet.entries[23] = .{ .value = 100, .flags = 0x20 };
            for (frame.slots) |slot| packet.entries[@intCast(slot[0])] = .{ .value = slot[1], .flags = @intCast(slot[2]) };
            try player.tickWithAudio(&level, &scene, .{ .entries = &.{}, .runtime = &runtime }, &angles, look.control(&packet), &look, config.seconds, &audio);
            var expected = frame.movement;
            expected.flags &= 0x10003004;
            try std.testing.expectEqualDeep(expected, Motion.read(player, look));
            const has_request = player.impact != 0 or player.sector_damage != 0;
            try std.testing.expectEqual(@as(usize, if (has_request) 1 else 0), frame.requests.len);
            if (has_request) try std.testing.expectEqualDeep(frame.requests[0], [_]u32{ 0, @bitCast(player.impact), player.sector_damage, 0, 0, 0 });
            try std.testing.expectEqual(frame.events.len, effects.items.len);
            for (frame.events, effects.items) |event, effect| try std.testing.expectEqualDeep(event, try sound(effect));
        }
    }
    var costume = try nwx.Costume.parse(a, try objects.find(blood.costume_name, 0));
    defer costume.deinit();
    for (corpus.generics, 0..) |case, index| {
        errdefer std.debug.print("reference moving generic case {d}\n", .{index});
        const config = case.config;
        var sector = std.mem.zeroes(level_module.Sector);
        sector.vadjoin = -1;
        sector.gravity = config.gravity;
        sector.friction = config.friction;
        sector.elasticity = config.elasticity;
        sector.floor.height = config.floor;
        sector.ceiling.height = config.ceiling;
        var level: level_module.Level = undefined;
        level.sectors = (&sector)[0..1];
        var state = std.mem.zeroes(scene_module.SectorState);
        if (config.ceiling_slope) |s| {
            state.flags = 0x80000000 & ~config.cleared_slope_flags;
            state.ceiling_slope = std.mem.zeroInit(scene_module.Slope, .{ .coeff_x = s[0], .coeff_z = s[1], .constant = s[2] });
        }
        var scene: scene_module.Scene = undefined;
        scene.sectors = (&state)[0..1];
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;
        var elevators = try classes(a, case.classes);
        var runtime: runtime_module.Context = .{ .inventory = &inventory, .pickups = &.{}, .removed = &.{}, .now_ms = 1000, .effects = &effects, .contact_state = &native, .inf = &elevators, .level = &level };
        const world = physics.World{ .level = &level, .scene = &scene, .angles = &angles, .actors = .{ .entries = &.{}, .runtime = &runtime } };
        var random = config.seed;
        var particle = try blood.spawn(&costume, &random, 0, point(config.position), 1000);
        particle.state.velocity = point(config.velocity);
        particle.state.floor_cache = case.floor_cache;
        for (case.frames, 0..) |frame, frame_index| {
            errdefer std.debug.print("reference moving generic frame {d}\n", .{frame_index});
            sector.floor.height = frame.floor;
            try blood.generalPhysics(&particle.actor, &particle.state, world, 0.016);
            const actual = Generic{ .position_bits = bits(particle.actor.position), .velocity_bits = bits(particle.state.velocity), .flags = particle.actor.flags, .floor_cache_bits = @bitCast(particle.state.floor_cache), .random = random, .same_sector = particle.actor.sector == 0 };
            try std.testing.expectEqualDeep(frame.state, actual);
        }
    }
    try std.testing.expectEqual(@as(usize, 108), corpus.bounces.len);
    try std.testing.expectEqual(@as(usize, 17), corpus.players.len);
    try std.testing.expectEqual(@as(usize, 14), corpus.generics.len);
}
