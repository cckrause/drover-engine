//! Finding a secret: the one-shot ordering and the HUD update that goes with it.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const secrets = @import("secrets.zig");
const scene_module = @import("../render/scene.zig");
const Session = @import("../render/session.zig").Session;
const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");

test "secret discovery matches player ticks and one-shot ordering" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/player-secrets-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Frame = struct {
        flags: u32,
        found: u32,
        messages: []const struct { message: u32, flags: u32, found: u32 },
    };
    const Fixture = struct { results_sha256: []const u8, samples: []const struct { initial: [2]u32, frames: []const Frame } };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("c5c7fb2c3b6574ce3d11242c34e468f5e57dc3d1696adbf49d5ec97de1b3b5b3", parsed.value.results_sha256);
    var sectors = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
    var scene: scene_module.Scene = undefined;
    scene.sectors = &sectors;
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;
    for (parsed.value.samples) |sample| {
        sectors[0].runtime_flags = sample.initial[0];
        var state = secrets.State{ .found = sample.initial[1] };
        for (sample.frames) |expected| {
            const discovered = state.discover(&scene, 0);
            try std.testing.expectEqual(expected.flags, sectors[0].runtime_flags);
            try std.testing.expectEqual(expected.found, state.found);
            try std.testing.expectEqual(expected.messages.len, @as(usize, @intFromBool(discovered)));
            if (discovered) {
                try std.testing.expectEqual(@as(u32, 0x13), expected.messages[0].message);
                try std.testing.expectEqual(expected.messages[0].flags, sectors[0].runtime_flags);
                try std.testing.expectEqual(expected.messages[0].found, state.found);
            }
        }
    }
}

test "Hideout secret discovery updates the live HUD once and retains primary flags" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, std.testing.io, path, archive, &startup);
    defer session.deinit(a);
    try std.testing.expectEqual(@as(u32, 4), session.secrets.total);
    const sector = session.player.sector;
    const original = session.scene.sectors[sector].flags;
    session.scene.sectors[sector].runtime_flags |= 0x10000000;
    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(u32, 1), session.secrets.found);
    try std.testing.expectEqual(original, session.scene.sectors[sector].flags);
    try std.testing.expectEqual(@as(u32, 0), session.scene.sectors[sector].runtime_flags & 0x10000000);
    const entries = session.messages.entries;
    try std.testing.expect(entries[0].string().len != 0);
    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(u32, 1), session.secrets.found);
    try std.testing.expectEqualDeep(entries, session.messages.entries);
}
