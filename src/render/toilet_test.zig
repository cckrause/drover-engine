//! One awkward bit of level geometry, jumped across and back, with its audio and rendering. It has caught several regressions.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const campaign = @import("../campaign.zig");
const lab = @import("../assets/lab.zig");
const Session = @import("session.zig").Session;
const input = @import("../player/input.zig");
const audio_runtime = @import("../audio/runtime.zig");
const actor_links = @import("actor_links.zig");

test "Hideout toilet seat jumps cross the dry opening and return with audio and rendering" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    for ([_]bool{ false, true }) |hold_jump| {
        var startup = try campaign.Startup.prepare(a, system, .good);
        defer startup.deinit(a);
        _ = try startup.levelForDiagnostics();
        const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, path, system, &startup);
        defer session.deinit(a);
        const audio = try audio_runtime.Runtime.open(a, std.testing.io, path, system);
        defer audio.deinit();
        try audio.beginLevel(std.testing.io, &session.level, session.geometry_archive, 0);
        session.player.position = .{ .x = 465.5, .y = -3, .z = 451 };
        session.player.sector = 212;
        session.player.yaw = 0;
        session.actor_links.move(actor_links.player_id, 212);
        var keys = input.State{ .previous_time = 1000 };
        keys.key(17, true, 1000);
        keys.key(18, true, 1000);
        var visited_seat = false;
        var visited_opening = false;
        var returned = false;
        for (0..180) |tick| {
            const now: u32 = @intCast(1016 + tick * 16);
            if (tick == 1 and !hold_jump) keys.key(18, false, now - 16);
            if (tick == 60) {
                keys.key(17, false, now - 16);
                keys.key(18, false, now - 16);
            }
            if (tick == 90) keys.key(31, true, now - 16);
            if (tick == 150) keys.key(31, false, now - 16);
            const packet = try keys.sample(now, .{});
            try session.advanceWithAudio(a, &packet, 16, audio);
            visited_seat = visited_seat or session.player.sector == 214;
            visited_opening = visited_opening or session.player.sector == 70;
            returned = returned or (tick >= 90 and session.player.sector == 212);
            try std.testing.expect(session.player.flags & 0x8000 == 0);
            if (session.player.sector == 70) {
                try std.testing.expect(@as(f64, session.player.eye_height) * 0.75 + session.player.position.y >= session.level.sectors[70].floor.height);
            }
            for (session.pickup_effects.items) |effect| switch (effect) {
                .sound => |request| _ = try audio.play(request, session.audioWorld(), now),
                else => {},
            };
            try audio.engine.updateListener(session.audioListener());
            _ = try session.render(a, pixels, now);
            try std.testing.expect(session.rendered_sector_visits > 0);
        }
        try std.testing.expect(visited_seat);
        try std.testing.expect(visited_opening);
        try std.testing.expect(returned);
        try std.testing.expect(audio.waves.items.len > 0);
    }
}
