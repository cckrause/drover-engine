//! The lamp in a live level: oil, HUD, lighting and the state kept across a restart.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const campaign = @import("../campaign.zig");
const lab = @import("../assets/lab.zig");
const Session = @import("../render/session.zig").Session;
const input = @import("input.zig");
const lamp = @import("lamp.zig");
const enemy_session = @import("../enemy/session.zig");

test "portable lamp commits input oil HUD lighting and restart state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), io, path, archive, &startup);
    defer session.deinit(a);
    const original_player = session.player;
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    _ = try session.render(pixels, 0);
    try std.testing.expect(session.hud.fuel_group == null);
    const fuel = session.inventory.find("IOIL");
    try std.testing.expect(fuel != 0);
    try std.testing.expectEqual(@as(i32, 60), session.inventory.slots[fuel].?.count);
    for (0..5) |_| try session.advance(a, &.{}, 250);

    var keys: input.State = .{};
    keys.key(38, true, session.animation_time + 1);
    const pressed = try keys.sample(session.animation_time + 16, .{});
    try std.testing.expect(pressed.get(.lamp).flags & input.pressed != 0);
    try session.advance(a, &pressed, 16);
    try std.testing.expectEqual(@as(i32, 59), session.inventory.slots[fuel].?.count);
    try std.testing.expect(session.player.flags & lamp.active_flag != 0);
    try std.testing.expectEqual(session.player.flags, session.inventory.player_flags);
    try std.testing.expectEqual(@as(u32, 0x10), enemy_session.playerSubject(session).flags & 0x18);
    var light_sounds: usize = 0;
    for (session.pickup_effects.items) |effect| if (effect == .sound and std.ascii.eqlIgnoreCase(effect.sound.basename, "LIGHT.WAV")) {
        try std.testing.expectEqual(@as(?i32, 64), effect.sound.priority);
        try std.testing.expectEqual(@as(?i32, 127), effect.sound.volume);
        try std.testing.expectEqual(@as(?u32, 0), effect.sound.flags);
        light_sounds += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), light_sounds);
    _ = try session.render(pixels, session.animation_time);
    try std.testing.expect(session.hud.fuel_group != null);
    try std.testing.expect(session.lamp_state.force_depth);
    const held = try keys.sample(session.animation_time + 16, .{});
    try std.testing.expect(held.get(.lamp).flags & input.pressed == 0);
    try session.advance(a, &held, 16);
    try std.testing.expect(session.player.flags & lamp.active_flag != 0);

    for (0..6) |_| {
        try session.advance(a, &.{}, 250);
        _ = try session.render(pixels, session.animation_time);
    }
    try std.testing.expect(session.lamp_state.flicker_time != 0);
    const before = session.lamp_state;
    const random = session.contact_state.random;
    @memset(pixels, 0);
    _ = try session.renderWorld(pixels, session.animation_time);
    var first: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pixels, &first, .{});
    @memset(pixels, 0);
    _ = try session.renderWorld(pixels, session.animation_time);
    var second: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pixels, &second, .{});
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expectEqualDeep(before, session.lamp_state);
    try std.testing.expectEqual(random, session.contact_state.random);

    var selection: input.Packet = .{};
    selection.entries[@intFromEnum(input.Slot.weapon)] = .{ .value = 3, .flags = input.absolute | input.pressed };
    for (0..5) |_| {
        try session.advance(a, &selection, 600);
        _ = try session.render(pixels, session.animation_time);
        selection = .{};
    }
    try std.testing.expectEqual(@as(usize, 3), session.inventory.selected_weapon);
    try std.testing.expect(session.hud.weaponAnimation().?.ready);
    const scope = try @import("inventory.zig").Definition.load(session.arena.allocator(), &.{ session.object_archive, session.weapon_archive, session.system_archive }, "ISCOPE");
    _ = try session.inventory.acquire(scope, 1);
    try session.advance(a, &pressed, 16);
    selection.entries[@intFromEnum(input.Slot.weapon)] = .{ .value = 3, .flags = input.absolute | input.pressed };
    selection.entries[@intFromEnum(input.Slot.lamp)] = pressed.get(.lamp);
    try session.advance(a, &selection, 16);
    var scoped_lamp = session.lamp_state;
    var scoped_random = session.contact_state.random;
    scoped_lamp.advancePresentation(session.frame_seconds, session.animation_time, &scoped_random);
    scoped_lamp.advancePresentation(session.frame_seconds, session.animation_time, &scoped_random);
    _ = try session.render(pixels, session.animation_time);
    try std.testing.expect(session.player.scope_active);
    try std.testing.expectEqualDeep(scoped_lamp, session.lamp_state);
    try std.testing.expectEqual(scoped_random, session.contact_state.random);
    std.crypto.hash.sha2.Sha256.hash(pixels, &first, .{});
    _ = try session.render(pixels, session.animation_time);
    std.crypto.hash.sha2.Sha256.hash(pixels, &second, .{});
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expectEqualDeep(scoped_lamp, session.lamp_state);
    try std.testing.expectEqual(scoped_random, session.contact_state.random);

    const restarted = try session.restart(a, io, path, archive, &startup, session.animation_time);
    defer restarted.deinit(a);
    try std.testing.expectEqual(scoped_lamp.fuel_elapsed, restarted.lamp_state.fuel_elapsed);
    try std.testing.expectEqual(scoped_lamp.flicker_time, restarted.lamp_state.flicker_time);
    try std.testing.expect(!restarted.lamp_state.force_depth);
    try std.testing.expectEqual(@as(i32, 0), restarted.lamp_state.depth_bias);
    try std.testing.expectEqual(@as(u32, 0), restarted.player.flags & lamp.active_flag);
    try std.testing.expectEqual(@as(i32, 60), restarted.inventory.slots[restarted.inventory.find("IOIL")].?.count);

    try restarted.advance(a, &pressed, 16);
    try std.testing.expect(restarted.lamp_state.force_depth);
    restarted.player.sector = 66;
    restarted.player.position = .{ .x = 465.5, .y = -10, .z = 460 };
    restarted.player.velocity = .{ .x = 0, .y = 0, .z = 0 };
    restarted.player.flags = lamp.active_flag;
    restarted.player.floor_cache = -2147483648;
    try restarted.advance(a, &.{}, 16);
    try std.testing.expect(restarted.player.flags & 0x8000 != 0);
    try std.testing.expectEqual(@as(u32, 0), restarted.player.flags & lamp.active_flag);
    try std.testing.expect(!restarted.lamp_state.force_depth);
    try restarted.advance(a, &pressed, 16);
    try std.testing.expectEqual(@as(u32, 0), restarted.player.flags & lamp.active_flag);

    restarted.player = original_player;
    try restarted.advance(a, &pressed, 16);
    try std.testing.expect(restarted.lamp_state.force_depth);
    restarted.player.position.y = restarted.level.sectors[restarted.player.sector].floor.height + 0.01;
    restarted.player.velocity.y = -100;
    restarted.player.flags &= ~@as(u32, 4);
    try restarted.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(f32, 0), restarted.inventory.health);
    try std.testing.expect(restarted.lamp_state.force_depth);
    try std.testing.expect(restarted.player.flags & lamp.active_flag != 0);
    try restarted.advance(a, &.{}, 16);
    try std.testing.expect(!restarted.lamp_state.force_depth);
    try std.testing.expectEqual(@as(u32, 0), restarted.player.flags & lamp.active_flag);
}
