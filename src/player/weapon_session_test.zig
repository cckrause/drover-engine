//! Firing and reloading in a live level, through the real frame phases.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const Session = @import("../render/session.zig").Session;
const input = @import("input.zig");

test "Hideout fires and reloads the installed pistol through the production frame phases" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    const session = try Session.open(
        a,
        @import("../render/test_workspace.zig").get(),
        std.testing.io,
        path,
        archive,
        &startup,
    );

    defer session.deinit(a);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);

    try std.testing.expectEqual(@as(usize, 2), session.inventory.selected_weapon);
    try std.testing.expectEqual(@as(i32, 6), session.inventory.slots[2].?.loaded);

    _ = try session.render(pixels, 0);
    try session.advance(a, &.{}, 600);
    _ = try session.render(pixels, 600);
    try std.testing.expect(session.hud.weaponAnimation().?.ready);

    var packet: input.Packet = .{};
    packet.entries[
        @intFromEnum(
            input.Slot.fire,
        )
    ] = .{ .value = 1, .flags = .{ .absolute = true, .pressed = true } };

    var sound_count: usize = 0;
    var checked_repeated_presentation = false;

    for (0..50) |frame| {
        if (frame == 1) packet.entries[
            @intFromEnum(
                input.Slot.fire,
            )
        ] = .{ .flags = .{ .released = true } };

        if (frame == 2) packet = .{};

        try session.advance(a, &packet, 16);

        for (session.pickup_effects.items) |effect| if (effect == .sound) {
            sound_count += 1;
        };

        _ = try session.render(pixels, session.animation_time);

        if (!checked_repeated_presentation and session.weapon_state.shot_count != 0) {
            const kick = session.weapon_state.kick;
            @memset(pixels, 0);
            _ = try session.renderWorld(pixels, session.animation_time);
            var first: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(pixels, &first, .{});
            @memset(pixels, 0);
            _ = try session.renderWorld(pixels, session.animation_time);
            var second: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(pixels, &second, .{});

            try std.testing.expectEqualSlices(u8, &first, &second);
            try std.testing.expectEqual(kick, session.weapon_state.kick);

            checked_repeated_presentation = true;
        }
    }

    try std.testing.expect(checked_repeated_presentation);
    try std.testing.expectEqual(@as(u32, 1), session.weapon_state.shot_count);
    try std.testing.expectEqual(@as(i32, 5), session.inventory.slots[2].?.loaded);
    try std.testing.expect(sound_count != 0);

    const ammo = session.inventory.find(session.inventory.slots[2].?.definition.ammo);
    const reserve = session.inventory.slots[ammo].?.count;

    packet.entries[
        @intFromEnum(
            input.Slot.reload,
        )
    ] = .{ .value = 1, .flags = .{ .absolute = true, .pressed = true } };

    for (0..60) |frame| {
        if (frame == 1) packet.entries[
            @intFromEnum(
                input.Slot.reload,
            )
        ] = .{ .flags = .{ .released = true } };

        if (frame == 2) packet = .{};

        try session.advance(a, &packet, 16);
        _ = try session.render(pixels, session.animation_time);
    }

    try std.testing.expectEqual(@as(i32, 6), session.inventory.slots[2].?.loaded);
    try std.testing.expectEqual(reserve - 1, session.inventory.slots[ammo].?.count);
    try std.testing.expectEqual(@as(u32, 1), session.weapon_state.shot_count);

    packet.entries[
        @intFromEnum(
            input.Slot.weapon,
        )
    ] = .{ .value = 3, .flags = .{ .absolute = true, .pressed = true } };

    for (0..80) |frame| {
        if (frame == 1) packet = .{};
        try session.advance(a, &packet, 16);
        _ = try session.render(pixels, session.animation_time);
    }

    try std.testing.expectEqual(@as(usize, 3), session.inventory.selected_weapon);
    try std.testing.expectEqual(@as(usize, 3), session.hud.weaponAnimation().?.slot);
    try std.testing.expect(session.hud.weaponAnimation().?.ready);

    const definition = try @import(
        "inventory.zig",
    ).Definition.load(
        session.arena.allocator(),
        &.{ session.object_archive, session.weapon_archive, session.system_archive },
        "ISCOPE",
    );

    _ = try session.inventory.acquire(definition, 1);
    packet.entries[
        @intFromEnum(
            input.Slot.weapon,
        )
    ] = .{ .value = 3, .flags = .{ .absolute = true, .pressed = true } };

    try session.advance(a, &packet, 16);
    _ = try session.render(pixels, session.animation_time);

    try std.testing.expect(session.weapon_state.scope);
    try std.testing.expect(session.player.scope_active);
    try std.testing.expectEqual(@as(i32, 106), session.scope_view.width);

    packet.entries[@intFromEnum(input.Slot.weapon)].value = 0;
    try session.advance(a, &packet, 16);
    _ = try session.render(pixels, session.animation_time);

    try std.testing.expectEqual(@as(usize, 0), session.weapon_state.bound_slot);
    try std.testing.expect(!session.weapon_state.scope);

    packet.entries[@intFromEnum(input.Slot.weapon)].value = 3;
    try session.advance(a, &packet, 16);
    _ = try session.render(pixels, session.animation_time);

    try std.testing.expectEqual(@as(usize, 3), session.weapon_state.bound_slot);
    try std.testing.expect(!session.weapon_state.scope);
}
