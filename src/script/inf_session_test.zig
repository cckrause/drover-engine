//! Scripts in a live level: activation rays, nudging a switch, and an automatic door through queued messages.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const Session = @import("../render/session.zig").Session;
const interaction = @import("interaction.zig");
const input = @import("../player/input.zig");

fn placeAtTrainDoor(session: *Session) !void {
    for (session.targets, 0..) |target, source| if (target != null) try @import("../enemy/session.zig").removeActor(session, source);
    session.player.sector = 635;
    session.player.position = .{ .x = 231.1, .y = 0, .z = 67.3 };
    session.player.yaw = 0;
    session.player.floor_cache = 0;
}

test "Hideout activation ray matches 320 reference traces" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-interaction-reference.json", a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        cases: []const struct { sector: usize, position_bits: [3]u32, yaw: i16, height_bits: u32, object_id: u32, events: []const interaction.Event },
    };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    const system_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(128 * 1024 * 1024));
    defer a.free(system_bytes);
    const archive = try lab.Archive.init(system_bytes);
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", archive, &startup);
    defer session.deinit(a);
    for (fixture.value.cases, 0..) |case, index| {
        var player = session.player;
        player.sector = case.sector;
        player.position = .{ .x = @bitCast(case.position_bits[0]), .y = @bitCast(case.position_bits[1]), .z = @bitCast(case.position_bits[2]) };
        player.yaw = case.yaw;
        player.body_height = @bitCast(case.height_bits);
        const actual = try interaction.activate(a, &session.level, &session.scene, &session.angles, session.textures, &player, .{ .entries = &.{} }, case.object_id);
        defer a.free(actual);
        std.testing.expectEqualDeep(case.events, actual) catch |err| {
            std.debug.print("reference activation ray case{d}, sector{d}, yaw{d}\n", .{ index, case.sector, case.yaw });
            return err;
        };
    }
}

test "Hideout nudge opens TOOLSEC through the live INF task" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    session.player.sector = 337;
    session.player.position = .{ .x = 429.5, .y = 0, .z = 211.5 };
    session.player.yaw = 0;
    session.player.floor_cache = 0;
    const elevator = for (session.inf.elevators) |*entry| {
        if (entry.sector == 20) break entry;
    } else return error.MissingToolsecElevator;
    try std.testing.expectEqualStrings("TOOLSEC", session.level.sectors[20].name);
    try std.testing.expectEqual(@as(f32, 0.125), session.level.sectors[20].ceiling.height);
    var packet: input.Packet = .{};
    packet.entries[@intFromEnum(input.Slot.nudge)].flags = input.pressed;
    try session.advance(a, &packet, 16);
    try std.testing.expectEqual(@as(f32, 0.125), session.level.sectors[20].ceiling.height);
    try std.testing.expectEqual(@as(u32, 0xffffffff), elevator.next_time);
    try std.testing.expect(elevator.runtime_flags & 1 == 0);
    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(u32, 32), elevator.next_time);
    try std.testing.expectEqual(@as(f32, 0.125), session.level.sectors[20].ceiling.height);
    try std.testing.expect(elevator.runtime_flags & 1 != 0);
    try session.advance(a, &.{}, 16);
    try std.testing.expect(session.level.sectors[20].ceiling.height > 0.125);
    for (0..20) |_| try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(f32, 4), session.level.sectors[20].ceiling.height);
    try std.testing.expectEqual(@as(u32, 0xffffffff), elevator.next_time);
    try std.testing.expect(elevator.runtime_flags & 1 == 0);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    _ = try session.render(a, pixels, session.animation_time);
    try std.testing.expect(session.rendered_sector_visits > 0);
}

test "Hideout automatic swinging door opens and closes through queued messages" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    try std.testing.expectEqual(@as(usize, 32), session.inf.elevators.len);
    try std.testing.expectEqual(@as(u32, 0xf03a2f29), session.contact_state.random);
    const elevator = for (session.inf.elevators) |*entry| {
        if (entry.sector == 32) break entry;
    } else return error.MissingAutomaticDoor;
    try std.testing.expect(elevator.automatic_door);
    const original = try a.dupe(@import("../assets/level.zig").Vec2, session.level.sectors[32].vertices);
    defer a.free(original);
    try session.inf.event(&session.level, .{ .sector = 32, .mask = 0x20, .now_ms = session.animation_time });
    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(f32, 0), elevator.value);
    for (0..85) |_| try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(f32, 3868), elevator.value);
    try std.testing.expectEqual(@as(u32, 0xffffffff), elevator.next_time);
    try std.testing.expect(session.loaded_actor_sectors[32]);
    try session.inf.event(&session.level, .{ .sector = 32, .mask = 0x20, .now_ms = session.animation_time });
    try session.advance(a, &.{}, 16);
    for (0..85) |_| try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(f32, 0), elevator.value);
    try std.testing.expectEqualDeep(original, session.level.sectors[32].vertices);
}

test "Hideout INF selected keys retain success and failure sound requests" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    const brass = for (session.level.sectors, 0..) |sector, i| {
        if (std.mem.eql(u8, sector.name, "MHBRASS")) break i;
    } else return error.MissingBrassDoor;
    const Definition = @import("../player/inventory.zig").Definition;
    const archives = [_]lab.Archive{ session.object_archive, session.weapon_archive, system };
    for ([_][]const u8{ "IIRONKEY", "IBRSSKEY" }, [_]u32{ 100, 101 }, [_][]const u8{ "LOCKED", "UNLOCK" }) |name, id, expected| {
        _ = try session.inventory.acquire(try Definition.load(session.arena.allocator(), &archives, name), 1);
        try session.inf.event(&session.level, .{ .sector = brass, .mask = 0x10, .object_id = id, .now_ms = session.animation_time });
        try session.advance(a, &.{}, 16);
        const sound = for (session.pickup_effects.items) |effect| {
            if (effect == .sound and std.mem.eql(u8, effect.sound.basename, expected)) break effect.sound;
        } else return error.MissingInventoryUseSound;
        try std.testing.expectEqualStrings(expected, sound.basename);
        try std.testing.expectEqual(@as(?i32, 0x40), sound.priority);
        try std.testing.expectEqual(@as(?i32, 0x7f), sound.volume);
        try std.testing.expectEqual(@as(?u32, 4), sound.flags);
    }
}

test "Train starting room door and first moving-ground gap work with audio" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    try @import("../platform/mission.zig").select(&startup, "train");
    try startup.finishMovie(true);
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    try placeAtTrainDoor(session);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    _ = try session.render(a, pixels, 0);
    const audio = try @import("../audio/runtime.zig").Runtime.open(a, std.testing.io, path, system);
    defer audio.deinit();
    try audio.engine.updateListener(session.audioListener());
    try audio.beginLevel(std.testing.io, &session.level, session.geometry_archive, 0);
    try audio.beginAmbient(&session.level, &session.objects, startup.difficulty);

    var controls: input.State = .{ .previous_time = 1000 };
    var now: u32 = 1000;
    var crossed_moving_ground = false;
    for (0..125) |tick| {
        switch (tick) {
            0 => {
                controls.key(17, true, now);
                controls.key(57, true, now);
            },
            1 => controls.key(57, false, now),
            else => {},
        }
        now += 16;
        const packet = try controls.sample(now, .{});
        try session.advanceWithAudio(a, &packet, 16, audio);
        if (std.ascii.eqlIgnoreCase(session.level.sectors[session.player.sector].name, "WEDGE02")) {
            crossed_moving_ground = true;
            try std.testing.expectEqual(@as(u32, 0), session.player.sector_damage);
        }
        for (session.pickup_effects.items) |effect| switch (effect) {
            .sound => |request| {
                _ = try audio.play(request, session.audioWorld(), now);
            },
            else => {},
        };
        try audio.engine.updateListener(session.audioListener());
        _ = try session.render(a, pixels, now);
        try audio.advanceMusic(std.testing.io, now);
        try audio.advanceAmbient(now, session.level.sectors[session.player.sector].layer);
    }

    var panels: usize = 0;
    var controllers: usize = 0;
    for (session.inf.elevators) |elevator| {
        const sector = session.level.sectors[elevator.sector];
        if (std.ascii.eqlIgnoreCase(sector.name, "LOADED03") or std.ascii.eqlIgnoreCase(sector.name, "LOADED04")) {
            panels += 1;
            try std.testing.expectEqual(@as(f32, 4.5), elevator.value);
        } else if (std.ascii.eqlIgnoreCase(sector.name, "LOADED0304DUMMY")) {
            controllers += 1;
            try std.testing.expectEqual(@as(f32, 0), elevator.value);
            try std.testing.expectEqual(@as(f32, 0), sector.floor.height);
            try std.testing.expectEqual(@as(u32, 0xffffffff), elevator.next_time);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), panels);
    try std.testing.expectEqual(@as(usize, 1), controllers);
    try std.testing.expect(crossed_moving_ground);
    try std.testing.expect(session.player.position.z > 76);
    try std.testing.expectEqual(@as(f32, 10), session.inventory.health);
}

test "Train lethal ground delivers death text and cleanup on the next frame" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    try @import("../platform/mission.zig").select(&startup, "train");
    try startup.finishMovie(true);
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    try placeAtTrainDoor(session);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    _ = try session.render(a, pixels, 0);
    const audio = try @import("../audio/runtime.zig").Runtime.open(a, std.testing.io, path, system);
    defer audio.deinit();
    try audio.engine.updateListener(session.audioListener());
    try audio.beginLevel(std.testing.io, &session.level, session.geometry_archive, 0);
    try audio.beginAmbient(&session.level, &session.objects, startup.difficulty);

    var controls: input.State = .{ .previous_time = 1000 };
    var now: u32 = 1000;
    var death_tick: ?usize = null;
    var delivered = false;
    for (0..720) |tick| {
        switch (tick) {
            0 => {
                controls.key(17, true, now);
                controls.key(57, true, now);
            },
            1 => controls.key(57, false, now),
            64 => {
                controls.key(17, false, now);
                controls.key(30, true, now);
            },
            else => {},
        }
        now += 16;
        const packet = try controls.sample(now, .{});
        try session.advanceWithAudio(a, &packet, 16, audio);
        var death_message = false;
        var death_voice = false;
        var chat_cue = false;
        for (session.pickup_effects.items) |effect| switch (effect) {
            .message => |message| {
                if (message.index == 47) {
                    try std.testing.expect(message.routed);
                    death_message = true;
                }
            },
            .sound => |request| {
                if (std.ascii.eqlIgnoreCase(request.basename, "JADIE.WAV")) death_voice = true;
                if (std.ascii.eqlIgnoreCase(request.basename, "RIFLOUT.WAV")) chat_cue = true;
                _ = try audio.play(request, session.audioWorld(), now);
            },
        };
        try audio.engine.updateListener(session.audioListener());
        _ = try session.render(a, pixels, now);
        try audio.advanceMusic(std.testing.io, now);
        try audio.advanceAmbient(now, session.level.sectors[session.player.sector].layer);

        if (death_tick == null and session.inventory.health == 0) {
            death_tick = tick;
            try std.testing.expectEqualStrings("OUTVIEW04", session.level.sectors[session.player.sector].name);
            try std.testing.expectEqual(@as(u32, 4), session.player.sector_damage);
            try std.testing.expectEqual(@as(?i32, 47), session.pending_player_death);
            try std.testing.expect(death_voice and !death_message and !chat_cue);
            try std.testing.expect(session.inventory.selected_weapon != 0);
        } else if (death_tick) |died_at| {
            try std.testing.expectEqual(@as(f32, 0), session.inventory.health);
            try std.testing.expect(session.player.dead);
            try std.testing.expect(session.player.flags & 0x10000000 != 0);
            for (session.inventory.slots) |slot| try std.testing.expect(slot == null);
            try std.testing.expectEqual(@as(usize, 0), session.inventory.selected);
            try std.testing.expectEqual(@as(usize, 0), session.inventory.selected_weapon);
            try std.testing.expectEqual(@as(?i32, null), session.pending_player_death);
            if (tick == died_at + 1) {
                try std.testing.expect(death_message and chat_cue and !death_voice);
                try std.testing.expectEqualStrings("You died!", session.messages.entries[0].string());
                try std.testing.expectEqual(@as(u32, 1), session.messages.entries[0].category);
                try std.testing.expectEqual(@as(u32, 14), session.messages.entries[0].color);
                try std.testing.expectEqual(session.animation_time + 5000, session.messages.entries[0].expiry);
                delivered = true;
            } else {
                try std.testing.expect(!death_message and !death_voice and !chat_cue);
            }
        }
    }
    try std.testing.expect(death_tick != null and delivered);
}
