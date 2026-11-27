//! The weapon in hand: input, shots, reloading, and what a menu reset cancels.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const weapon = @import("weapon.zig");
const inventory_module = @import("inventory.zig");
const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;
const nwx = @import("../assets/nwx.zig");
const movement = @import("movement.zig");
const input = @import("input.zig");
const camera = @import("../render/backends/software/camera.zig");
const runtime_module = @import("../script/runtime.zig");

const Bubble = struct { sector: usize, position: [3]u32, count: i32 };

const BubbleCapture = struct {
    value: ?Bubble = null,

    fn spawn(raw: *anyopaque, _: *runtime_module.Context, sector: usize, position: @import("../assets/level.zig").Vec3, count: i32) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try std.testing.expect(self.value == null);
        self.value = .{ .sector = sector, .position = .{ @bitCast(position.x), @bitCast(position.y), @bitCast(position.z) }, .count = count };
    }
};

fn shotWords(shot: weapon.Shot) [11]u32 {
    return .{ @intFromEnum(shot.kind), @intFromBool(shot.impact_effect), @bitCast(shot.damage), @bitCast(shot.mass), @bitCast(shot.rate), @bitCast(shot.range), @bitCast(shot.origin.x), @bitCast(shot.origin.y), @bitCast(shot.origin.z), @as(u32, @as(u16, @bitCast(shot.pitch))) | (@as(u32, @as(u16, @bitCast(shot.yaw))) << 16), @intFromBool(shot.impact_sound) };
}

fn prepareInventory(a: std.mem.Allocator, archives: []const lab.Archive, cid: *const Item, slot: usize) !inventory_module.Inventory {
    var inventory = try inventory_module.Inventory.init(a, archives, cid);
    inventory.selected_weapon = slot;
    if (slot > 3) {
        const name: []const u8 = switch (slot) {
            4 => "ISGUN",
            5 => "IDBSGUN",
            6 => "ISAWGUN",
            9 => "IGATGUN",
            else => unreachable,
        };
        _ = try inventory.acquire(try inventory_module.Definition.load(a, archives, name), 0);
        const ammo_name: []const u8 = if (slot == 9) "ICLIP" else "ISHELLS";
        const ammo_slot = try inventory.acquire(try inventory_module.Definition.load(a, archives, ammo_name), 0);
        inventory.slots[ammo_slot].?.count = if (slot == 9) 30 else 20;
        try inventory.reload(slot);
    }
    return inventory;
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024));
}

test {
    _ = @import("weapon_config.zig");
}

test "bound weapon input, shots and reload match the reference and assets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = read(a, "testdata/weapons-reference.json") catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Frame = struct {
        now: u32,
        messages: []u32,
        state: [7]i32,
        playback: [7]u32,
        loaded: i32,
        random: u32,
        crt_random: u32,
        shots: [][11]u32,
        sounds: [][]const u8,
    };
    const ShotCase = struct { slot: usize, action: i32, energy: f32, seed: u32, scope: bool, sheriff: bool, underwater: bool, initial_loaded: i32, loaded: i32, random: u32, crt_random: u32, shots: [][11]u32, bubbles: []const Bubble };
    const AimCase = struct { candidates: []weapon.AutoAimCandidate, random: u32, crt_random: u32, shots: [][11]u32, aim: [2]i32 };
    const WaterReload = struct { state: [7]i32, loaded: i32, random: u32, crt_random: u32, playback: [7]u32, bubbles: []const Bubble };
    const Selection = struct { slot: usize, held: bool, bound: bool, state: [7]i32 };
    const Reference = struct { cases: []struct { slot: usize, frames: []Frame }, shot_cases: []ShotCase, aiming: []AimCase = &.{}, water_reload: ?WaterReload = null, selection: []Selection = &.{} };
    const reference = try std.json.parseFromSlice(Reference, a, json, .{ .ignore_unknown_fields = true });
    var archives: [3]lab.Archive = undefined;
    for ([_][]const u8{ "OUTLAWS", "OLOBJ", "OLWEAP" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        archive.* = try lab.Archive.init(try read(a, path));
    }
    var cid = try Item.parse(a, try archives[1].find("CIDJAMES.ITM", 0));
    const physics = try movement.Physics.parse(try archives[0].find("AIR.PHY", 0));
    var player = try movement.Player.init(&cid, physics, .{ .sector = 0, .position = .{ .x = 322.36, .y = 0, .z = 271.88 }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
    player.yaw = 8035;
    const angles = camera.Angles.init();
    for (reference.value.cases) |case| {
        var inventory = try prepareInventory(a, &archives, &cid, case.slot);
        const owned = inventory.slots[case.slot].?;
        var costume = try nwx.Costume.parse(a, try archives[2].find(owned.definition.costume, 0));
        defer costume.deinit();
        var state: weapon.State = .{};
        var random: u32 = 0x742389ac;
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        var shots_buffer: weapon.ShotBuffer = undefined;
        var shots = weapon.Shots.init(&shots_buffer);
        var context: weapon.Context = .{ .state = &state, .inventory = &inventory, .player = &player, .random = &random, .effects = &effects, .shots = &shots, .now = 0, .ready = true, .angles = &angles };
        var playback: nwx.Playback = .{};
        try playback.select(&costume, 0, 0, &context);
        try context.tick(&playback, &costume);
        for (case.frames) |frame| {
            effects.clearRetainingCapacity();
            shots.clearRetainingCapacity();
            context.now = frame.now;
            try playback.advanceWithContext(&costume, 0, frame.now, &context);
            var packet: input.Packet = .{};
            for (frame.messages) |message| {
                const slot: input.Slot = switch (message) {
                    0x69, 0x6a => .fire,
                    0x6b, 0x6c => .fire_big,
                    0x6d, 0x6e => .fire_other,
                    0x6f, 0x70 => .reload,
                    else => unreachable,
                };
                packet.entries[@intFromEnum(slot)].flags = if (message & 1 != 0) input.pressed else input.released;
            }
            try state.inputPacket(&inventory, &packet, frame.now);
            try context.tick(&playback, &costume);
            const actual_state = [_]i32{ state.action, state.pending, @intFromBool(state.ended), @intFromBool(state.released), @intFromBool(state.did_fire), @intFromBool(state.did_finish), @intFromBool(state.scope) };
            if (!std.mem.eql(i32, &frame.state, &actual_state)) std.debug.print("weapon slot{} time{}\n", .{ case.slot, frame.now });
            try std.testing.expectEqualSlices(i32, &frame.state, &actual_state);
            const actual_playback = [_]u32{ playback.last_time, @bitCast(@as(i32, playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags };
            try std.testing.expectEqualSlices(u32, &frame.playback, &actual_playback);
            try std.testing.expectEqual(frame.loaded, inventory.slots[case.slot].?.loaded);
            try std.testing.expectEqual(frame.random, random);
            try std.testing.expectEqual(frame.crt_random, state.crt_random);
            try std.testing.expectEqual(frame.shots.len, shots.items.len);
            for (frame.shots, shots.items) |expected, shot| {
                const actual = shotWords(shot);
                if (!std.mem.eql(u32, &expected, &actual)) std.debug.print("weapon shot slot{} time{}\n", .{ case.slot, frame.now });
                try std.testing.expectEqualSlices(u32, &expected, &actual);
            }
            var inserted: usize = 0;
            for (shots.items) |shot| if (shot.hit_sound) |sound| {
                try effects.insert(sound.effect_index + inserted, .{ .sound = sound.request });
                inserted += 1;
            };
            var sound_index: usize = 0;
            for (frame.sounds) |sound| {
                try std.testing.expect(sound_index < effects.items.len);
                const request = effects.items[sound_index].sound;
                const actual = request.basename;
                try std.testing.expect(std.ascii.eqlIgnoreCase(actual, std.fs.path.stem(sound)));
                try std.testing.expectEqual(@as(?@import("../assets/level.zig").Vec3, null), request.position);
                try std.testing.expectEqual(@as(?usize, null), request.sector);
                sound_index += 1;
            }
            try std.testing.expectEqual(sound_index, effects.items.len);
        }
    }
    for (reference.value.shot_cases) |case| {
        var inventory = try prepareInventory(a, &archives, &cid, case.slot);
        inventory.sheriff_active = case.sheriff;
        inventory.slots[case.slot].?.loaded = case.initial_loaded;
        player.energy = case.energy;
        var costume = try nwx.Costume.parse(a, try archives[2].find(inventory.slots[case.slot].?.definition.costume, 0));
        defer costume.deinit();
        var state: weapon.State = .{ .action = case.action, .scope = case.scope };
        var random = case.seed;
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        var shots_buffer: weapon.ShotBuffer = undefined;
        var shots = weapon.Shots.init(&shots_buffer);
        var captured: BubbleCapture = .{};
        var native: @import("../script/cmm.zig").ContactState = .{};
        const runtime: runtime_module.Context = .{ .inventory = &inventory, .pickups = &.{}, .removed = &.{}, .effects = &effects, .now_ms = 1000, .contact_state = &native, .bubble_host = .{ .context = &captured, .spawn = BubbleCapture.spawn } };
        var context: weapon.Context = .{ .state = &state, .inventory = &inventory, .player = &player, .random = &random, .effects = &effects, .shots = &shots, .now = 1000, .ready = true, .angles = &angles, .underwater = case.underwater, .bubble_context = runtime };
        var playback: nwx.Playback = .{};
        try context.event(&playback, &costume, 1, &.{}, 1000);
        try std.testing.expectEqual(case.loaded, inventory.slots[case.slot].?.loaded);
        try std.testing.expectEqual(case.random, random);
        try std.testing.expectEqual(case.crt_random, state.crt_random);
        try std.testing.expectEqual(case.shots.len, shots.items.len);
        try std.testing.expectEqual(@as(usize, if (captured.value != null) 1 else 0), case.bubbles.len);
        if (captured.value) |bubble| try std.testing.expectEqualDeep(case.bubbles[0], bubble);
        for (case.shots, shots.items) |expected, shot| {
            const actual = shotWords(shot);
            if (!std.mem.eql(u32, &expected, &actual)) std.debug.print("weapon shot slot{} energy{} scope{} water{}\n", .{ case.slot, case.energy, case.scope, case.underwater });
            try std.testing.expectEqualSlices(u32, &expected, &actual);
        }
    }
    player.energy = 100;
    for (reference.value.aiming) |case| {
        var inventory = try prepareInventory(a, &archives, &cid, 2);
        var costume = try nwx.Costume.parse(a, try archives[2].find(inventory.slots[2].?.definition.costume, 0));
        defer costume.deinit();
        var state: weapon.State = .{ .action = 0 };
        var random: u32 = 0x742389ac;
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        var shots_buffer: weapon.ShotBuffer = undefined;
        var shots = weapon.Shots.init(&shots_buffer);
        var context: weapon.Context = .{ .state = &state, .inventory = &inventory, .player = &player, .random = &random, .effects = &effects, .shots = &shots, .now = 1000, .ready = true, .angles = &angles, .candidates = case.candidates };
        var playback: nwx.Playback = .{};
        try context.event(&playback, &costume, 1, &.{}, 1000);
        try std.testing.expectEqual(case.random, random);
        try std.testing.expectEqual(case.crt_random, state.crt_random);
        try std.testing.expectEqualSlices(i32, &case.aim, &.{ state.aim_x, state.aim_y });
        try std.testing.expectEqual(case.shots.len, shots.items.len);
        for (case.shots, shots.items) |expected, shot| try std.testing.expectEqualSlices(u32, &expected, &shotWords(shot));
    }
    if (reference.value.water_reload) |case| {
        var inventory = try prepareInventory(a, &archives, &cid, 2);
        inventory.slots[2].?.loaded = 1;
        var costume = try nwx.Costume.parse(a, try archives[2].find(inventory.slots[2].?.definition.costume, 0));
        defer costume.deinit();
        var state: weapon.State = .{ .bound_slot = 2 };
        var random: u32 = 0x742389ac;
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        var shots_buffer: weapon.ShotBuffer = undefined;
        var shots = weapon.Shots.init(&shots_buffer);
        var captured: BubbleCapture = .{};
        var native: @import("../script/cmm.zig").ContactState = .{};
        const runtime: runtime_module.Context = .{ .inventory = &inventory, .pickups = &.{}, .removed = &.{}, .effects = &effects, .now_ms = 1000, .contact_state = &native, .bubble_host = .{ .context = &captured, .spawn = BubbleCapture.spawn } };
        var context: weapon.Context = .{ .state = &state, .inventory = &inventory, .player = &player, .random = &random, .effects = &effects, .shots = &shots, .now = 0, .ready = true, .angles = &angles, .underwater = true, .bubble_context = runtime };
        var playback: nwx.Playback = .{};
        try playback.select(&costume, 0, 0, &context);
        var packet: input.Packet = .{};
        packet.entries[@intFromEnum(input.Slot.reload)].flags = input.pressed;
        try state.inputPacket(&inventory, &packet, 1000);
        context.now = 1000;
        try context.tick(&playback, &costume);
        try std.testing.expectEqualSlices(i32, &case.state, &.{ state.action, state.pending, @intFromBool(state.ended), @intFromBool(state.released), @intFromBool(state.did_fire), @intFromBool(state.did_finish), @intFromBool(state.scope) });
        try std.testing.expectEqual(case.loaded, inventory.slots[2].?.loaded);
        try std.testing.expectEqual(case.random, random);
        try std.testing.expectEqual(case.crt_random, state.crt_random);
        const actual_playback = [_]u32{ playback.last_time, @bitCast(@as(i32, playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags };
        try std.testing.expectEqualSlices(u32, &case.playback, &actual_playback);
        try std.testing.expectEqual(@as(usize, 1), case.bubbles.len);
        try std.testing.expectEqualDeep(case.bubbles[0], captured.value.?);
    }
    var inventory = try prepareInventory(a, &archives, &cid, 3);
    var state: weapon.State = .{ .bound_slot = 3 };
    for (reference.value.selection) |case| {
        state.action = 1;
        state.pending = 0;
        state.ended = true;
        state.released = false;
        state.did_fire = true;
        state.did_finish = true;
        state.scope = true;
        state.held[0] = case.held;
        inventory.selected_weapon = case.slot;
        state.reconcileSelection(&inventory);
        try std.testing.expectEqualSlices(i32, &case.state, &.{ state.action, state.pending, @intFromBool(state.ended), @intFromBool(state.released), @intFromBool(state.did_fire), @intFromBool(state.did_finish), @intFromBool(state.scope) });
        try std.testing.expectEqual(case.bound, state.bound_slot != 0);
    }
}

test "menu reset cancels shot and reload WAX while retaining the reference scope and input gates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var archives: [3]lab.Archive = undefined;
    for ([_][]const u8{ "OUTLAWS", "OLOBJ", "OLWEAP" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        const bytes = read(a, path) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        archive.* = try lab.Archive.init(bytes);
    }
    var cid = try Item.parse(a, try archives[1].find("CIDJAMES.ITM", 0));
    const physics = try movement.Physics.parse(try archives[0].find("AIR.PHY", 0));
    var player = try movement.Player.init(&cid, physics, .{ .sector = 0, .position = .{ .x = 322.36, .y = 0, .z = 271.88 }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
    const angles = camera.Angles.init();
    const Case = struct {
        slot: usize,
        reload: bool,
        scope: bool,
        before: u32,
        after: u32,
        loaded: i32,
    };
    for ([_]Case{
        .{ .slot = 2, .reload = false, .scope = false, .before = 5, .after = 0, .loaded = 6 },
        .{ .slot = 2, .reload = true, .scope = false, .before = 8, .after = 0, .loaded = 5 },
        .{ .slot = 3, .reload = false, .scope = true, .before = 21, .after = 20, .loaded = 12 },
    }) |case| {
        var inventory = try prepareInventory(a, &archives, &cid, case.slot);
        inventory.slots[case.slot].?.loaded = case.loaded;
        var costume = try nwx.Costume.parse(a, try archives[2].find(inventory.slots[case.slot].?.definition.costume, 0));
        defer costume.deinit();
        var state: weapon.State = .{};
        var random: u32 = 0x742389ac;
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        var shots_buffer: weapon.ShotBuffer = undefined;
        var shots = weapon.Shots.init(&shots_buffer);
        var context: weapon.Context = .{ .state = &state, .inventory = &inventory, .player = &player, .random = &random, .effects = &effects, .shots = &shots, .now = 0, .ready = true, .angles = &angles };
        var playback: nwx.Playback = .{};
        try playback.select(&costume, 0, 0, &context);
        try context.tick(&playback, &costume);
        state.scope = case.scope;
        context.now = 1000;
        var packet: input.Packet = .{};
        packet.entries[@intFromEnum(if (case.reload) input.Slot.reload else input.Slot.fire)].flags = input.pressed;
        try state.inputPacket(&inventory, &packet, context.now);
        try context.tick(&playback, &costume);
        try std.testing.expectEqual(case.before, playback.choreography);
        try context.reset(&playback, &costume);
        const expected_state = [_]i32{ -1, -1, 0, 0, 0, 0, @intFromBool(case.scope) };
        try std.testing.expectEqualSlices(i32, &expected_state, &.{ state.action, state.pending, @intFromBool(state.ended), @intFromBool(state.released), @intFromBool(state.did_fire), @intFromBool(state.did_finish), @intFromBool(state.scope) });
        const expected_playback = [_]u32{ 1000, 0, 31, case.after, 1, 0, 5 };
        const actual_playback = [_]u32{ playback.last_time, @bitCast(@as(i32, playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags };
        try std.testing.expectEqualSlices(u32, &expected_playback, &actual_playback);
        try std.testing.expectEqual([4]bool{ !case.reload, false, false, case.reload }, state.held);
        try std.testing.expectEqual(@as(u32, 1000), state.last_press);
        try std.testing.expectEqual(case.loaded, inventory.slots[case.slot].?.loaded);
        try std.testing.expectEqual(@as(u32, 0x742389ac), random);
        try std.testing.expectEqual(@as(u32, 1), state.crt_random);
        try std.testing.expectEqual(@as(usize, 0), shots.items.len);
        context.now = 1100;
        try context.reset(&playback, &costume);
        try std.testing.expectEqual(@as(u32, 1000), playback.last_time);
    }
}
