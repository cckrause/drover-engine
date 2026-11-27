//! Fall damage in a live level: health, audio, HUD and what happens when it is lethal.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const Session = @import("../render/session.zig").Session;
const Audio = @import("../audio/runtime.zig").Runtime;
const input = @import("input.zig");

fn playVoices(session: *const Session, audio: *Audio) !void {
    for (session.pickup_effects.items) |effect| switch (effect) {
        .sound => |sound| {
            const id = (try audio.play(
                sound,
                null,
                session.animation_time,
            )) orelse return error.ExpectedDamageSoundPlayback;

            const voice = audio.engine.find(id) orelse return error.MissingDamageSoundInstance;
            const wave = audio.waves.items[voice.asset];

            try std.testing.expect(wave.pcm.len != 0 and wave.sample_rate != 0);
            try std.testing.expect(
                std.ascii.eqlIgnoreCase(sound.basename, audio.names.items[voice.asset]),
            );
        },
        else => {},
    };
}

fn expectVoices(session: *const Session, expected: []const []const u8) !void {
    var index: usize = 0;

    for (session.pickup_effects.items) |effect| switch (effect) {
        .sound => |sound| {
            try std.testing.expect(index < expected.len);
            try std.testing.expect(std.ascii.eqlIgnoreCase(expected[index], sound.basename));
            try std.testing.expectEqual(@as(?i32, 64), sound.priority);
            try std.testing.expectEqual(@as(?i32, 127), sound.volume);
            try std.testing.expectEqual(@as(?u32, 0), sound.flags);

            index += 1;
        },
        else => {},
    };

    try std.testing.expectEqual(expected.len, index);
}

fn expectAbsentVoice(session: *const Session, name: []const u8) !void {
    for (session.pickup_effects.items) |effect| switch (effect) {
        .sound => |sound| try std.testing.expect(!std.ascii.eqlIgnoreCase(name, sound.basename)),
        else => {},
    };
}

test "Hideout fall damage commits health audio HUD and lethal continuation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";

    inline for (.{
        "OUTLAWS.LAB",
        "OLGEO.LAB",
        "OLTEX.LAB",
        "OLOBJ.LAB",
        "OLWEAP.LAB",
        "OLSFX.LAB",
        "OLTAUNT.LAB",
    }) |name| {
        std.Io.Dir.cwd().access(
            io,
            "inputs/OUTLAWS_CD1/OUTLAWS/" ++ name,
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
    }

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, data_path, a, .limited(128 * 1024 * 1024));
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);

    for ([_]bool{ false, true }) |lethal| {
        var startup = try campaign.Startup.prepare(a, system, .good);
        defer startup.deinit(a);

        _ = try startup.levelForDiagnostics();

        const session = try Session.open(
            a,
            @import("../render/test_workspace.zig").get(),
            io,
            data_path,
            system,
            &startup,
        );

        defer session.deinit(a);
        const audio = try Audio.open(a, io, data_path, system);
        defer audio.deinit();
        const original_player = session.player;
        const original_inventory = session.inventory;

        try std.testing.expectEqual(@as(usize, 410), session.player.sector);
        const sector = session.level.sectors[session.player.sector];

        try std.testing.expectEqual(@as(f32, -3), sector.floor.height);
        try std.testing.expectEqual(@as(f32, -60), sector.gravity);
        try std.testing.expect(session.scene.sectors[session.player.sector].floor_slope == null);

        session.player.position.y = sector.floor.height + 0.01;
        session.player.velocity.y = if (lethal) -100 else -70;
        session.player.flags = 0;

        try session.advance(a, &.{}, 16);

        try std.testing.expectEqual(
            @as(u32, if (lethal) 0x42c9eb85 else 0x428deb85),
            @as(u32, @bitCast(session.player.impact)),
        );

        try std.testing.expectEqual(
            @as(u32, if (lethal) 0 else 0x4099db23),
            @as(u32, @bitCast(session.inventory.health)),
        );

        try std.testing.expectEqual(
            @as(i32, if (lethal) 10 else 5),
            session.inventory.statistics.damage,
        );

        try std.testing.expectEqual(
            @as(i32, if (lethal) 382 else 255),
            session.damage_flash.strength,
        );

        try std.testing.expectEqual(@as(u8, if (lethal) 229 else 127), session.damage_flash.alpha);
        try std.testing.expectEqual(@as(f32, -3), session.player.position.y);
        try std.testing.expectEqual(
            @as(u32, if (lethal) 0x407941c8 else 0x408bfd0d),
            @as(u32, @bitCast(session.player.eye_height)),
        );

        try expectVoices(
            session,
            if (lethal) &.{
                "LAND.WAV",
                "CRUNCH.WAV",
                "JADIE.WAV",
            } else &.{ "LAND.WAV", "CRUNCH.WAV" },
        );

        try playVoices(session, audio);

        try std.testing.expectEqualStrings("", session.messages.entries[0].string());
        try std.testing.expectEqualDeep(original_inventory.slots, session.inventory.slots);

        const tinted = try session.render(pixels, 0);

        try std.testing.expect(!std.mem.eql(u32, &session.palette, &tinted));
        try std.testing.expectEqual(
            @as(i32, if (lethal) -1 else 5),
            session.hud.health_group.value,
        );

        const loss = session.inventory.statistics.damage;
        const health = session.inventory.health;
        const energy = session.player.energy;
        const time = session.animation_time;
        const position = session.player.position;

        var packet: input.Packet = .{};

        packet.entries[
            @intFromEnum(
                input.Slot.forward,
            )
        ] = .{ .value = 5120, .flags = input.absolute };

        packet.entries[
            @intFromEnum(
                input.Slot.strafe,
            )
        ] = .{ .value = 5120, .flags = input.absolute };

        packet.entries[@intFromEnum(input.Slot.speed)] = .{ .value = 300, .flags = input.unscaled };

        if (lethal) {
            packet.entries[
                @intFromEnum(
                    input.Slot.jump,
                )
            ] = .{ .value = 5120, .flags = input.absolute };

            packet.entries[@intFromEnum(input.Slot.turn)] = .{ .value = 5120 };
        }

        try session.advance(a, &packet, 16);

        try std.testing.expectEqual(time + 16, session.animation_time);
        try std.testing.expectEqual(health, session.inventory.health);
        try std.testing.expectEqual(loss, session.inventory.statistics.damage);
        try std.testing.expectEqual(
            @as(i32, if (lethal) 378 else 251),
            session.damage_flash.strength,
        );

        if (lethal) {
            try std.testing.expectEqualStrings(
                "You fell to your death!",
                session.messages.entries[0].string(),
            );

            try std.testing.expectEqual(@as(u32, 1), session.messages.entries[0].category);
            try std.testing.expectEqual(@as(u32, 14), session.messages.entries[0].color);
            try std.testing.expectEqual(
                session.animation_time + 5000,
                session.messages.entries[0].expiry,
            );

            try std.testing.expectEqualStrings("", session.messages.entries[1].string());
            try std.testing.expectEqual(@as(usize, 2), session.pickup_effects.items.len);

            const message = session.pickup_effects.items[0].message;

            try std.testing.expectEqual(@as(i32, 45), message.index);
            try std.testing.expect(message.routed);

            const cue = session.pickup_effects.items[1].sound;

            try std.testing.expect(std.ascii.eqlIgnoreCase("RIFLOUT.WAV", cue.basename));
            try std.testing.expectEqual(@as(?i32, 32), cue.priority);
            try std.testing.expectEqual(@as(?i32, 50), cue.volume);
            try std.testing.expectEqual(@as(?u32, 4), cue.flags);

            try playVoices(session, audio);

            try std.testing.expect(session.player.dead);
            try std.testing.expect(session.player.flags & 0x10000000 != 0);

            for (session.inventory.slots) |slot| try std.testing.expect(slot == null);

            try std.testing.expectEqual(@as(usize, 0), session.inventory.selected);
            try std.testing.expectEqual(@as(usize, 0), session.inventory.selected_weapon);
            try std.testing.expectEqual(energy, session.player.energy);
            try std.testing.expectEqual(position.x, session.player.position.x);
            try std.testing.expectEqual(position.z, session.player.position.z);
            try std.testing.expect(session.player.yaw != original_player.yaw);
            try std.testing.expectEqual(
                @as(u32, 0x4013d70a),
                @as(u32, @bitCast(session.player.eye_height)),
            );

            try session.advance(a, &packet, 16);

            try std.testing.expectEqual(@as(f32, 1), session.player.eye_height);
            try std.testing.expectEqual(@as(f32, 1.5), session.player.body_height);
            try std.testing.expectEqual(@as(f32, 0), session.player.velocity.y);
            try std.testing.expectEqual(position.x, session.player.position.x);
            try std.testing.expectEqual(position.z, session.player.position.z);
            try std.testing.expectEqual(loss, session.inventory.statistics.damage);
            try std.testing.expectEqualStrings(
                "You fell to your death!",
                session.messages.entries[0].string(),
            );

            try std.testing.expectEqualStrings("", session.messages.entries[1].string());

            try expectAbsentVoice(session, "RIFLOUT.WAV");
            const dead_palette = try session.render(pixels, 0);

            try std.testing.expectEqualSlices(u32, &tinted, &dead_palette);
            try std.testing.expectEqual(@as(i32, -1), session.hud.health_group.value);
        } else {
            try std.testing.expect(!session.player.dead);
            try std.testing.expect(
                session.player.position.x != position.x or session.player.position.z != position.z,
            );

            try std.testing.expect(session.inventory.selected_weapon != 0);

            _ = try session.render(pixels, 0);
            try std.testing.expectEqual(@as(i32, 5), session.hud.health_group.value);
        }

        try expectAbsentVoice(session, "CRUNCH.WAV");
        try expectAbsentVoice(session, "JADIE.WAV");
    }
}
