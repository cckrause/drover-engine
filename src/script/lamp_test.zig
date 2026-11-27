//! Shooting out a lamp: callback order, playback and the fragments it grows.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const Session = @import("../render/session.zig").Session;
const inventory = @import("../player/inventory.zig");
const level = @import("../assets/level.zig");
const lab = @import("../assets/lab.zig");
const object = @import("object.zig");
const enemy_session = @import("../enemy/session.zig");

fn bits(v: level.Vec3) [3]u32 {
    return .{ @bitCast(v.x), @bitCast(v.y), @bitCast(v.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "shootable lamps retain callback order playback and synchronous fragment growth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Snapshot = struct {
        flags: u32,
        secondary_flags: u32,
        height_bits: u32,
        radius_bits: u32,
        removed: bool,
        playback: [8]u32,
        pending: []i16,
    };
    const Fragment = struct { position_bits: [3]u32, velocity_bits: [3]u32, scale_bits: [2]u32 };
    const Event = struct { kind: []const u8, name: []const u8 = "", position_bits: [3]u32 = @splat(0), options: [3]u32 = @splat(0), mask: u32 = 0, arguments: [2]i32 = @splat(0) };
    const Step = struct { operation: []const u8, now: u32, random: u32, state: Snapshot, events: []Event, fragments: []Fragment };
    const Fixture = struct { executable_sha256: []const u8, results_sha256: []const u8, lamps: []struct { name: []const u8, initial: Snapshot, steps: []Step } };
    const fixture = (try std.json.parseFromSlice(Fixture, a, try read(a, "testdata/lamp-fragments-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.executable_sha256);
    try std.testing.expectEqualStrings("696ef7c3582e27afdf22573122e0be43a856f6d0cef317050968350ec7d05e3b", fixture.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const system = try lab.Archive.init(try read(a, path));
    for (fixture.lamps) |case| {
        var startup = try @import("../campaign.zig").Startup.prepare(a, system, .good);
        defer startup.deinit(a);
        _ = try startup.levelForDiagnostics();
        const session = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, path, system, &startup);
        defer session.deinit(a);
        const source: usize = for (session.actor_slots, 0..) |slot, index| {
            if (slot != null) break index;
        } else return error.MissingTestActor;
        const sector = session.actor_slots[source].?.sector;
        @memset(session.removed_actors, true);
        for (session.actor_slots, 0..) |_, index| session.syncActor(index);
        const name = try std.fmt.allocPrint(a, "{s}.ITM", .{case.name});
        var definition = try @import("../assets/item.zig").Item.parse(a, try session.object_archive.find(name, 0));
        defer definition.deinit();
        const costume = try enemy_session.costume(session, definition.animation);
        const entry = std.mem.zeroInit(level.Object, .{ .name = case.name, .position = .{ .x = 1.25, .y = 3, .z = -3.75 } });
        const state = try @import("../render/object_state.zig").State.init(entry, sector, &definition, costume);
        session.actor_slots[source] = state.actor(costume);
        session.actor_slots[source].?.source_index = source;
        session.actor_slots[source].?.logic_name = "Inv_Object";
        session.actor_slots[source].?.playback.?.last_time = 1000;
        session.targets[source] = null;
        session.removed_actors[source] = false;
        session.contact_state.random = 0x742389ac;
        session.syncActor(source);
        const slots_before = session.actor_slots.ptr;
        const initial_count = session.actor_slots.len;
        var effects = inventory.Effects.init(a);
        defer effects.deinit();
        for (case.steps) |step| {
            errdefer std.debug.print("lamp {s} {s} at{d}\n", .{ case.name, step.operation, step.now });
            effects.clearRetainingCapacity();
            session.animation_time = step.now;
            const pending_before = session.inf.pending.items.len;
            if (std.mem.eql(u8, step.operation, "hit")) {
                try object.hit(session, source);
            } else if (std.mem.eql(u8, step.operation, "drain")) {
                while (session.object_logic.cursor < session.object_logic.selections.items.len) try object.deliverNext(session, &effects);
            } else if (std.mem.eql(u8, step.operation, "tick")) {
                try @import("../enemy/dynamic.zig").animations(session);
                try object.advance(session, source, &effects);
            } else return error.UnknownReferenceOperation;
            const actor = session.actor_slots[source].?;
            const playback = actor.playback.?;
            try std.testing.expectEqualDeep(step.state.playback, [8]u32{ playback.last_time, @bitCast(@as(i32, playback.angle_offset)), playback.direction, playback.choreography, playback.next_frame, playback.frame, playback.flags, @intFromBool(playback.terminated) });
            try std.testing.expectEqual(step.state.flags, actor.flags);
            try std.testing.expectEqual(step.state.secondary_flags, actor.secondary_flags);
            try std.testing.expectEqual(step.state.height_bits, @as(u32, @bitCast(actor.height)));
            try std.testing.expectEqual(step.state.radius_bits, @as(u32, @bitCast(actor.collision_radius)));
            try std.testing.expectEqual(step.state.removed, session.removed_actors[source]);
            try std.testing.expectEqual(step.random, session.contact_state.random);
            try std.testing.expectEqual(step.fragments.len, session.actor_slots.len - initial_count);
            for (step.fragments, initial_count..) |expected, index| {
                const particle = session.actor_slots[index].?;
                try std.testing.expectEqualStrings("FX_ExplosionFragment", particle.logic_name);
                try std.testing.expectEqualDeep(expected.position_bits, bits(particle.position));
                try std.testing.expectEqualDeep(expected.velocity_bits, bits(session.general_slots[index].?.velocity));
                try std.testing.expectEqualDeep(expected.scale_bits, [2]u32{ @bitCast(particle.scale_x), @bitCast(particle.scale_y) });
                try std.testing.expect(session.source_to_entry[index] != null);
            }
            var sound_index: usize = 0;
            var sector_events: usize = 0;
            for (step.events) |event| {
                if (std.mem.eql(u8, event.kind, "sector_event")) {
                    const index = pending_before + sector_events;
                    try std.testing.expect(index < session.inf.pending.items.len);
                    const pending = session.inf.pending.items[index].message;
                    try std.testing.expectEqual(@as(u32, 0xffffffff), pending.entity_mask);
                    try std.testing.expectEqual(@as(?usize, sector), pending.value.target.sector);
                    try std.testing.expectEqual(@as(?usize, null), pending.value.target.wall);
                    try std.testing.expectEqual(@as(u32, 0x7d6), pending.value.code);
                    try std.testing.expectEqual(event.mask, pending.value.event_mask);
                    try std.testing.expectEqualDeep(event.arguments, [2]i32{ pending.value.arg1, pending.value.arg2 });
                    sector_events += 1;
                    continue;
                }
                if (!std.mem.eql(u8, event.kind, "sound")) continue;
                try std.testing.expect(sound_index < effects.items.len);
                const request = effects.items[sound_index].sound;
                try std.testing.expectEqualStrings(event.name, request.basename);
                try std.testing.expectEqualDeep(event.position_bits, bits(request.position.?));
                try std.testing.expectEqualDeep(event.options, [3]u32{ @bitCast(request.priority.?), @bitCast(request.volume.?), request.flags.? });
                sound_index += 1;
            }
            try std.testing.expectEqual(sound_index, effects.items.len);
            try std.testing.expectEqual(sector_events, session.inf.pending.items.len - pending_before);
        }
        try std.testing.expect(session.actor_slots.ptr != slots_before);
    }
}
