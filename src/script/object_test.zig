//! Shooting a breakable object: the queued selections, the sound frames and its removal.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const Session = @import("../render/session.zig").Session;
const Actor = @import("../render/objects.zig").Actor;
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const Item = @import("../assets/item.zig").Item;
const inventory = @import("../player/inventory.zig");
const enemy_session = @import("../enemy/session.zig");
const object_logic = @import("object.zig");

const Snapshot = struct {
    flags: u32,
    secondary_flags: u32,
    height_bits: u32,
    radius_bits: u32,
    next_tick: u32,
    removed: bool,
    playback: [8]u32,
    pending: []const i16,
};

const Event = struct {
    kind: []const u8,
    index: u32 = 0,
    name: []const u8 = "",
    position_bits: [3]u32 = @splat(0),
    options: [3]u32 = @splat(0),
};

const Step = struct { operation: []const u8, now: u32, state: Snapshot, events: []const Event };

const Case = struct {
    name: []const u8,
    animation: []const u8,
    town_id: ?u32,
    town_sector_id: ?u32,
    position_bits: [3]u32,
    initial: Snapshot,
    steps: []const Step,
};

fn queueHit(session: *Session, source: usize, serial: ?u64) !void {
    try session.queued_hits.append(.{
        .target = source,
        .queue_serial = serial,
        .count = 1,
        .input = .{ .kind = 1, .damage = 0, .mass = 0.03, .speed = 1000, .pitch = 0, .yaw = 4096, .lateral = 0, .height = 0 },
    });
}

fn expectState(expected: Snapshot, session: *Session, source: usize) !void {
    const actor = session.actor_slots[source].?;
    try std.testing.expectEqual(expected.flags, actor.flags);
    try std.testing.expectEqual(expected.secondary_flags, actor.secondary_flags);
    try std.testing.expectEqual(expected.height_bits, @as(u32, @bitCast(actor.height)));
    try std.testing.expectEqual(expected.radius_bits, @as(u32, @bitCast(actor.collision_radius)));
    try std.testing.expectEqual(expected.next_tick, @as(u32, @bitCast(session.actor_next_update[source])));
    try std.testing.expectEqual(expected.removed, session.removed_actors[source]);
    const playback: nwx.Playback = actor.playback.?;
    try std.testing.expectEqualDeep(expected.playback, [8]u32{ playback.last_time, @bitCast(@as(i32, playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags, @intFromBool(playback.terminated) });
    try std.testing.expectEqual(playback.choreography, actor.choreography);
    try std.testing.expectEqual(playback.frame, actor.frame);
    try std.testing.expectEqual(playback.angle_offset, actor.angle_offset);
    const pending = session.object_logic.selections.items[session.object_logic.cursor..];
    try std.testing.expectEqual(expected.pending.len, pending.len);
    for (expected.pending, pending) |native, actual| {
        try std.testing.expectEqual(source, actual.source);
        try std.testing.expectEqual(@as(u16, @bitCast(native)), actual.choreography);
    }
    if (expected.removed) {
        try std.testing.expectEqual(@as(?usize, null), session.source_to_entry[source]);
        try std.testing.expectEqual(@as(?usize, null), session.actor_links.nodes.items[source].sector);
    } else {
        try std.testing.expect(session.source_to_entry[source] != null);
        try std.testing.expectEqual(@as(?usize, actor.sector), session.actor_links.nodes.items[source].sector);
    }
}

fn bits(v: @import("../assets/level.zig").Vec3) [3]u32 {
    return .{ @bitCast(v.x), @bitCast(v.y), @bitCast(v.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "Town bottle hits retain queued selections sound frames and removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []const Case,
    };
    const fixture = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/shootable-objects-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.executable_sha256);
    try std.testing.expectEqualStrings("7d99b4f506cfa487f476b9b30c7fa9bd1b1743501c448a34ff15d8808d51d9fb", fixture.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    try @import("../platform/mission.zig").select(&startup, "town");
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, archive, &startup);
    defer session.deinit(a);
    const visible = try a.alloc(bool, session.level.sectors.len);
    @memset(visible, false);
    var town_bottles: std.ArrayList(usize) = .empty;
    for (session.objects.entries, 0..) |entry, source| {
        if (!std.mem.startsWith(u8, entry.name, "BOTTLE")) continue;
        visible[session.level.sectorIndex(entry.sector_id).?] = true;
        try town_bottles.append(a, source);
    }
    try std.testing.expectEqual(@as(usize, 11), town_bottles.items.len);
    _ = try session.loadActorsInSectors(visible);
    for (town_bottles.items) |source| {
        const actor = session.actor_slots[source].?;
        try std.testing.expectEqualStrings("Inv_Object", actor.logic_name);
        try std.testing.expectEqual(@as(u32, 0x2000), actor.secondary_flags);
        try std.testing.expect(actor.playback != null);
    }
    const original_slots = try a.dupe(?Actor, session.actor_slots);
    @memset(session.removed_actors, true);
    for (session.actor_slots, 0..) |_, source| session.syncActor(source);
    var effects_buffer: inventory.EffectBuffer = undefined;
    var effects = inventory.Effects.init(&effects_buffer);
    session.active_effects = &effects;
    defer session.active_effects = null;

    for (fixture.cases) |case| {
        errdefer std.debug.print("reference shootable object {s}\n", .{case.name});
        const source = if (case.town_id) |id| for (session.objects.entries, 0..) |entry, index| {
            if (entry.id == id) break index;
        } else return error.MissingOriginalBottlePlacement else town_bottles.items[0];
        if (case.town_id != null) {
            session.actor_slots[source] = original_slots[source];
            try std.testing.expectEqual(case.town_sector_id.?, session.level.sectors[session.actor_slots[source].?.sector].id);
        } else {
            const item_name = try std.fmt.allocPrint(a, "{s}.ITM", .{case.name});
            var definition = try Item.parse(a, try session.object_archive.find(item_name, 0));
            defer definition.deinit();
            const costume = try enemy_session.costume(session, case.animation);
            const entry = std.mem.zeroInit(@import("../assets/level.zig").Object, .{ .name = case.name });
            const state = try @import("../render/object_state.zig").State.init(entry, original_slots[source].?.sector, &definition, costume);
            session.actor_slots[source] = state.actor(costume);
            session.actor_slots[source].?.source_index = source;
            session.actor_slots[source].?.sector_link_order = source + 1;
            session.actor_slots[source].?.logic_name = "Inv_Object";
        }
        session.targets[source] = null;
        session.removed_actors[source] = false;
        session.actor_next_update[source] = 0;
        session.actor_slots[source].?.playback.?.last_time = 1000;
        session.animation_time = 1000;
        session.enemy_selection_serial = 0;
        session.object_logic.selections.clearRetainingCapacity();
        session.object_logic.cursor = 0;
        session.syncActor(source);
        try std.testing.expectEqualDeep(case.position_bits, bits(session.actor_slots[source].?.position));
        try expectState(case.initial, session, source);

        var step_index: usize = 0;
        while (step_index < case.steps.len) : (step_index += 1) {
            var step = case.steps[step_index];
            errdefer std.debug.print("original {s} at {d}\n", .{ step.operation, step.now });
            effects.clearRetainingCapacity();
            session.animation_time = step.now;
            if (std.mem.eql(u8, step.operation, "hit")) {
                while (true) {
                    try queueHit(session, source, null);
                    if (step_index + 1 == case.steps.len or !std.mem.eql(u8, case.steps[step_index + 1].operation, "hit") or case.steps[step_index + 1].now != step.now) break;
                    step_index += 1;
                    step = case.steps[step_index];
                }
                try session.deliverHits(a, null, &effects);
            } else if (std.mem.eql(u8, step.operation, "activate")) {
                try object_logic.receive(session, source, 0x7d3);
            } else if (std.mem.eql(u8, step.operation, "drain")) {
                try enemy_session.deliverSelections(session, a, null);
            } else if (std.mem.eql(u8, step.operation, "tick")) {
                try enemy_session.animations(session, a, null, &effects);
            } else if (std.mem.eql(u8, step.operation, "schedule")) {
                object_logic.schedule(session, source);
            } else return error.InvalidOriginalObjectOperation;
            try expectState(step.state, session, source);
            var sound_index: usize = 0;
            for (step.events) |event| {
                if (!std.mem.eql(u8, event.kind, "sound")) continue;
                try std.testing.expect(sound_index < effects.items.len);
                const sound = effects.items[sound_index].sound;
                try std.testing.expectEqualStrings(event.name, sound.basename);
                try std.testing.expectEqualDeep(event.options, [3]u32{ @intCast(sound.priority.?), @intCast(sound.volume.?), sound.flags.? });
                try std.testing.expectEqualDeep(event.position_bits, bits(sound.position.?));
                try std.testing.expectEqual(session.actor_slots[source].?.sector, sound.sector.?);
                sound_index += 1;
            }
            try std.testing.expectEqual(sound_index, effects.items.len);
        }
    }

    const first = town_bottles.items[0];
    const second = town_bottles.items[1];
    for ([_]bool{ false, true }) |hit_first| {
        for ([_]usize{ first, second }) |source| {
            session.actor_slots[source] = original_slots[source];
            session.actor_slots[source].?.playback.?.last_time = 1000;
            session.removed_actors[source] = false;
            session.targets[source] = null;
            session.syncActor(source);
        }
        session.animation_time = 2000;
        session.enemy_selection_serial = 0;
        effects.clearRetainingCapacity();
        if (hit_first) {
            try queueHit(session, first, session.enemy_selection_serial);
            session.enemy_selection_serial += 1;
            try object_logic.hit(session, second);
            try session.deliverHits(a, null, &effects);
            try std.testing.expectEqual(@as(usize, 0), effects.items.len);
        } else {
            try object_logic.hit(session, first);
            try queueHit(session, second, null);
            try session.deliverHits(a, null, &effects);
            try std.testing.expectEqual(@as(usize, 1), effects.items.len);
            try std.testing.expectEqual(@as(u32, 1), session.actor_slots[first].?.choreography);
            try std.testing.expectEqual(@as(u32, 0), session.actor_slots[second].?.choreography);
        }
        try enemy_session.deliverSelections(session, a, null);
        try std.testing.expectEqual(@as(usize, 2), effects.items.len);
        const order: [2]usize = if (hit_first) .{ second, first } else .{ first, second };
        for (order, effects.items) |source, effect| {
            try std.testing.expectEqualStrings("BOTTLE.WAV", effect.sound.basename);
            try std.testing.expectEqualDeep(bits(original_slots[source].?.position), bits(effect.sound.position.?));
            try std.testing.expectEqual(@as(u32, 1), session.actor_slots[source].?.choreography);
        }
    }
}
