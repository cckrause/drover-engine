//! Ordering between sprite selections and queued enemy damage in one frame.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const Session = @import("../render/session.zig").Session;
const enemy_session = @import("session.zig");
const Target = @import("../player/target.zig").Target;
const Actor = @import("../render/objects.zig").Actor;
const inventory = @import("../player/inventory.zig");

const Snapshot = struct {
    health_bits: u32,
    velocity_bits: [3]u32,
    mode: u32,
    previous_mode: u32,
    anger_bits: u32,
    fear_bits: u32,
    attack_at: u32,
    sight_at: u32,
    next_tick: u32,
    current_chor: u32,
    animation_ended: bool,
    saved_mode: ?u32,
    saved_health_bits: ?u32,
    flags: u32,
    height_bits: u32,
    playback: [8]u32,
    random: u32,
    position_bits: [3]u32,
    yaw: i16,
};

const Corpus = struct {
    executable_sha256: []const u8,
    results_sha256: []const u8,
    victim_id: u32,
    sector: usize,
    player_position: [3]f32,
    cases: []struct {
        choreography: u32,
        damage: f32,
        initial: Snapshot,
        queued: Snapshot,
        damage_input: struct { kind: u32, damage_bits: u32, height_bits: u32 },
        delivered_codes: []u32,
        after_damage: Snapshot,
        after_drain: Snapshot,
    },
};

fn expectSnapshot(expected: Snapshot, target: Target, actor: Actor, random: u32) !void {
    try std.testing.expectEqual(expected.health_bits, @as(u32, @bitCast(target.damage.health)));
    try std.testing.expectEqual(expected.velocity_bits, [3]u32{ @bitCast(target.damage.velocity.x), @bitCast(target.damage.velocity.y), @bitCast(target.damage.velocity.z) });
    try std.testing.expectEqual(expected.mode, target.mode);
    try std.testing.expectEqual(expected.previous_mode, target.previous_mode);
    try std.testing.expectEqual(expected.anger_bits, @as(u32, @bitCast(target.anger)));
    try std.testing.expectEqual(expected.fear_bits, @as(u32, @bitCast(target.fear)));
    try std.testing.expectEqual(expected.attack_at, target.attack_at);
    try std.testing.expectEqual(expected.sight_at, target.sight_at);
    try std.testing.expectEqual(expected.next_tick, target.next_tick);
    try std.testing.expectEqual(expected.current_chor, target.damage.current_chor);
    try std.testing.expectEqual(expected.animation_ended, target.animation_ended);
    try std.testing.expectEqual(expected.saved_mode, if (target.ai.stack) |saved| saved.mode else null);
    try std.testing.expectEqual(expected.saved_health_bits, if (target.ai.stack) |saved| @as(u32, @bitCast(saved.damage.health)) else null);
    try std.testing.expectEqual(expected.flags, actor.flags);
    try std.testing.expectEqual(expected.height_bits, @as(u32, @bitCast(actor.height)));
    const playback = target.playback;
    try std.testing.expectEqual(expected.playback[0..7].*, [7]u32{ playback.last_time, @as(u16, @bitCast(playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags });
    try std.testing.expectEqual(expected.random, random);
    try std.testing.expectEqual(expected.position_bits, [3]u32{ @bitCast(actor.position.x), @bitCast(actor.position.y), @bitCast(actor.position.z) });
    try std.testing.expectEqual(expected.yaw, actor.yaw);
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "session drains older WAX selections before queued enemy damage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected = (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/enemy-fifo-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", expected.executable_sha256);
    try std.testing.expectEqualStrings("9507b1979f8823b1f41c9c4715de26efc0fb243c14285d2494e8d1003be05633", expected.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, std.testing.io, path, archive, &startup);
    defer session.deinit(a);
    const sectors = try a.alloc(bool, session.level.sectors.len);
    @memset(sectors, false);
    sectors[expected.sector] = true;
    _ = try session.loadActorsInSectors(a, sectors);
    const source = for (session.objects.entries, 0..) |object, index| {
        if (object.id == expected.victim_id) break index;
    } else return error.MissingReferenceFifoTarget;
    session.player.position = .{ .x = expected.player_position[0], .y = expected.player_position[1], .z = expected.player_position[2] };
    session.player.sector = expected.sector;
    const original_target = session.targets[source].?;
    const original_actor = session.actor_slots[source].?;
    var effects = inventory.Effects.init(a);
    defer effects.deinit();
    for (expected.cases) |case| {
        errdefer std.debug.print("original FIFO choreography {d}, damage {d}\n", .{ case.choreography, case.damage });
        session.targets[source] = original_target;
        session.actor_slots[source] = original_actor;
        const target = &session.targets[source].?;
        const actor = &session.actor_slots[source].?;
        target.playback.last_time = 1000;
        session.animation_time = 1000;
        session.enemy_shared = .{ .now = 1000 };
        session.enemy_selection_serial = 0;
        session.contact_state.random = case.initial.random;
        try expectSnapshot(case.initial, target.*, actor.*, session.contact_state.random);
        try std.testing.expect(try target.select(actor, case.choreography));
        try expectSnapshot(case.queued, target.*, actor.*, session.contact_state.random);
        try session.queued_hits.append(session.arena.allocator(), .{
            .target = source,
            .count = 1,
            .input = .{ .kind = case.damage_input.kind, .damage = @bitCast(case.damage_input.damage_bits), .mass = 0, .speed = 1000, .pitch = 0, .yaw = 4096, .lateral = 0, .height = @bitCast(case.damage_input.height_bits) },
        });
        session.animation_time = 1050;
        try session.deliverHits(a, null, &effects);
        try expectSnapshot(case.after_damage, target.*, actor.*, session.contact_state.random);
        try std.testing.expectEqual(@as(usize, 0), session.queued_hits.items.len);
        try enemy_session.deliverSelections(session, a, null);
        try expectSnapshot(case.after_drain, target.*, actor.*, session.contact_state.random);
        try std.testing.expectEqual(@as(usize, 0), target.selections.items.len);
        try std.testing.expectEqual(@as(u32, 0x403), case.delivered_codes[0]);
        try std.testing.expectEqual(@as(u32, 0x7d1), case.delivered_codes[1]);
        if (case.delivered_codes.len == 3) try std.testing.expectEqual(@as(u32, 0x403), case.delivered_codes[2]);
    }
}
