//! What an enemy drops when it dies, and the unbound playback of the dropped object.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;
const nwx = @import("../assets/nwx.zig");
const objects = @import("../render/objects.zig");
const object_state = @import("../render/object_state.zig");

const Snapshot = struct {
    position_bits: [3]u32,
    flags: u32,
    secondary_flags: u32,
    scale_bits: [2]u32,
    height_bits: u32,
    radius_bits: u32,
    playback: [8]u32,
    bound: bool,
};

fn check(expected: Snapshot, actor: objects.Actor) !void {
    try std.testing.expectEqual(expected.position_bits, [3]u32{ @bitCast(actor.position.x), @bitCast(actor.position.y), @bitCast(actor.position.z) });
    try std.testing.expectEqual(expected.flags, actor.flags);
    try std.testing.expectEqual(expected.secondary_flags, actor.secondary_flags);
    try std.testing.expectEqual(expected.scale_bits, [2]u32{ @bitCast(actor.scale_x), @bitCast(actor.scale_y) });
    try std.testing.expectEqual(expected.height_bits, @as(u32, @bitCast(actor.height)));
    try std.testing.expectEqual(expected.radius_bits, @as(u32, @bitCast(actor.collision_radius)));
    const playback = actor.playback.?;
    try std.testing.expectEqual(expected.playback[0..7].*, [7]u32{ playback.last_time, @as(u16, @bitCast(playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags });
    try std.testing.expect(!expected.bound);
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "enemy drop constructors and unbound playback match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { name: []const u8, animation: []const u8, now: u32, initial: Snapshot, frames: []struct { now: u32, state: Snapshot } },
    };
    const corpus = (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/enemy-drop-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("77e24e7974bbc4c304c74cac8a76622a7b2d0713f74c57ffcbf5874632e99e81", corpus.results_sha256);
    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    for (corpus.cases) |case| {
        errdefer std.debug.print("reference enemy drop {s}\n", .{case.name});
        var item = try Item.parse(a, try archive.find(case.name, 0));
        defer item.deinit();
        var costume = try nwx.Costume.parse(a, try archive.find(case.animation, 0));
        defer costume.deinit();
        const state = try object_state.State.init(.{ .name = case.name, .id = 0, .sector_id = 1, .position = .{ .x = 1.5, .y = 0, .z = 1.5 }, .rotation = .{ .x = 0, .y = 0, .z = 0 }, .angles = .{ 0, 0, 0 }, .flags = .{ 0, 0 } }, 0, &item, &costume);
        var actor = state.actor(&costume);
        try std.testing.expect(actor.playback != null);
        actor.playback.?.last_time = case.now;
        try check(case.initial, actor);
        for (case.frames) |frame| {
            try actor.advanceUnboundAnimation(frame.now);
            try check(frame.state, actor);
        }
    }
}
