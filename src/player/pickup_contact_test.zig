//! Touching a pickup: the ordering, the bounds and the slide filter it changes.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const level_module = @import("../assets/level.zig");
const camera = @import("../render/backends/software/camera.zig");
const initial_state = @import("../render/initial_state.zig");
const scene_module = @import("../render/scene.zig");
const cmm = @import("../script/cmm.zig");
const runtime = @import("../script/runtime.zig");
const collision = @import("collision.zig");
const inventory_module = @import("inventory.zig");
const Actor = @import("../render/objects.zig").Actor;
const bits = @import("../util/bits.zig");

fn point(value: [3]f32) level_module.Vec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

fn vectorBits(value: level_module.Vec3) [3]u32 {
    return .{ @bitCast(value.x), @bitCast(value.y), @bitCast(value.z) };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "pickup contacts retain reference ordering bounds and slide filter changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Body = struct {
        sector: usize,
        position: [3]f32,
        flags: u32,
        secondary_flags: u32,
        height: f32,
        collision_radius: f32,
        logic: []const u8 = "Inv_GroundObject",
    };

    const Dispatch = struct { index: usize, count: u32, message: u32, argument: u32, player: u32 };
    const Case = struct {
        name: []const u8,
        sector: usize,
        old: [3]f32,
        desired: [3]f32,
        velocity: [3]f32,
        height: f32,
        radius: f32,
        step: f32,
        floor_cache: f32,
        actors: []Body,
        enabled: bool,
        player_flags: u32,
        dispatches: []Dispatch,
        result_sector: ?usize,
        position_bits: [3]u32,
        actor_position_bits: [3]u32,
        actor_sector: usize,
        velocity_bits: [3]u32,
        floor_bits: u32,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        dispatch_sha256: []const u8,
        cases: []Case,
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/pickup-contacts-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "67523c175bc7a3ee452fd212188b0604662f6c94aa57f0d56931c37e76968e13",
        corpus.dispatch_sha256,
    );

    const archive = try @import(
        "../assets/lab.zig",
    ).Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));

    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    var initial = try initial_state.InfStartup.apply(a, &level, try archive.find("HIDEOUT.INF", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);

    initial.applyScene(&level, &scene);

    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var total: usize = 0;

    for (corpus.cases) |case| {
        const actors = try a.alloc(Actor, case.actors.len);

        for (actors, case.actors, 0..) |*actor, source, index| {
            actor.* = undefined;
            actor.sector = source.sector;
            actor.position = point(source.position);
            bits.setWord(&actor.flags, source.flags);
            bits.setWord(&actor.secondary_flags, source.secondary_flags);
            actor.height = source.height;
            actor.collision_radius = source.collision_radius;
            actor.source_index = index;
            actor.logic_name = if (source.logic.len == 0) "" else "Inv_Object";
        }

        var inventory = inventory_module.Inventory{};
        const pickups = try a.alloc(?inventory_module.Pickup, actors.len);

        @memset(pickups, null);
        const removed = try a.alloc(bool, actors.len);
        @memset(removed, false);

        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        var contacts = std.array_list.Managed(usize).init(a);
        var contact_state: cmm.ContactState = .{};
        var context: runtime.Context = .{
            .inventory = &inventory,
            .pickups = pickups,
            .removed = removed,
            .now_ms = 0,
            .effects = &effects,
            .contact_log = &contacts,
            .contact_state = &contact_state,
        };

        var desired = point(case.desired);
        var velocity = point(case.velocity);
        var floor_cache = case.floor_cache;
        var links = try @import(
            "../render/actor_links.zig",
        ).Links.init(a, level.sectors.len, actors.len);

        defer links.deinit();
        const indices = try a.alloc(?usize, actors.len);

        for (actors, 0..) |actor, index| {
            links.move(index, actor.sector);
            indices[index] = index;
        }

        const result = try collision.resolve(&level, &scene, .{
            .entries = actors,
            .links = &links,
            .source_to_entry = indices,
            .runtime = if (case.enabled and case.player_flags & 0x10 != 0) &context else null,
        }, case.sector, point(
            case.old,
        ), &desired, &velocity, case.height, case.radius, case.step, &floor_cache);

        const expected = try a.alloc(usize, case.dispatches.len);

        for (case.dispatches, expected) |dispatch, *index| {
            index.* = dispatch.index;

            try std.testing.expectEqual(@as(u32, 4), dispatch.count);
            try std.testing.expectEqual(@as(u32, 0x74), dispatch.message);
            try std.testing.expectEqual(@as(u32, 0), dispatch.argument);
            try std.testing.expectEqual(@as(u32, 0x11223344), dispatch.player);
        }

        if (!std.mem.eql(usize, expected, contacts.items))
            std.debug.print(
                "\nOriginal pickup contact case {s}: expected {any}, actual {any}\n",
                .{ case.name, expected, contacts.items },
            );

        try std.testing.expectEqualSlices(usize, expected, contacts.items);

        for (contacts.items) |index| {
            for ([_]u32{ @intCast(index), 4, 0x74, 0 }) |value| {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, value, .little);
                digest.update(&bytes);
            }
        }

        total += contacts.items.len;

        try std.testing.expectEqual(case.result_sector, result.sector);
        try std.testing.expectEqual(case.actor_sector, result.actor_sector);
        try std.testing.expectEqualSlices(u32, &case.position_bits, &vectorBits(desired));
        try std.testing.expectEqualSlices(u32, &case.actor_position_bits, &vectorBits(result.position));
        try std.testing.expectEqualSlices(u32, &case.velocity_bits, &vectorBits(velocity));
        try std.testing.expectEqual(case.floor_bits, @as(u32, @bitCast(floor_cache)));
        try std.testing.expectEqual(@as(usize, 0), effects.items.len);

        for (removed) |value| try std.testing.expect(!value);
    }

    try std.testing.expectEqual(@as(usize, 29), corpus.cases.len);
    try std.testing.expectEqual(@as(usize, 80), total);
    try std.testing.expectEqualStrings(
        corpus.dispatch_sha256,
        &std.fmt.bytesToHex(digest.finalResult(), .lower),
    );
}
