//! Enemy broadcasts: who hears them and in what order, without loading scenery.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const controller = @import("controller.zig");
const Target = @import("../player/target.zig").Target;
const Actor = @import("../render/objects.zig").Actor;
const level_module = @import("../assets/level.zig");
const occlusion = @import("../audio/occlusion.zig");
const actor_links = @import("../render/actor_links.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene_module = @import("../render/scene.zig");
const bits = @import("../util/bits.zig");
const ActorKind = @import("../actor_flags.zig").ActorKind;

const Case = struct {
    layers: []f32,
    connected: []u16,
    bodies: []struct { sector: usize, position: [3]f32, flags: u32, logic: bool },
    relinks: []usize,
    recipients: []usize,
};

fn compare(case: Case, unsupported: ?usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sectors = try a.alloc(level_module.Sector, case.layers.len);

    for (sectors, case.layers) |*sector, layer| {
        sector.* = std.mem.zeroes(level_module.Sector);
        sector.layer = layer;
    }

    var level: level_module.Level = undefined;
    level.sectors = sectors;

    var scene: scene_module.Scene = undefined;
    const angles = camera.Angles.init();
    var visibility = try occlusion.Cache.init(a, &level);
    defer visibility.deinit();

    visibility.lists[0] = try a.dupe(u16, case.connected);

    var links = try actor_links.Links.init(a, sectors.len, case.bodies.len);
    defer links.deinit();
    const slots = try a.alloc(?Actor, case.bodies.len);
    const targets = try a.alloc(?Target, case.bodies.len);
    const entries = try a.alloc(Actor, case.bodies.len);
    const indices = try a.alloc(?usize, case.bodies.len);

    for (case.bodies, 0..) |body, source| {
        slots[source] = .{
            .source_index = source,
            .logic_name = if (body.logic) "BGY_New" else "",
            .costume = undefined,
            .sector = body.sector,
            .position = .{ .x = body.position[0], .y = body.position[1], .z = body.position[2] },
            .yaw = 0,
            .flags = .{ .active = true, .unused_1 = true, .visible = true, .shaded = true, .has_logic = true, .changed = true },
            .secondary_flags = bits.from(ActorKind, body.flags),
            .scale_x = 1,
            .scale_y = 1,
            .height = 6,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };

        targets[source] = if (unsupported == source) null else .{
            .allocator = a,
            .damage = undefined,
            .mode = 1,
            .next_tick = 777,
        };

        const entry = entries.len - source - 1;

        entries[entry] = slots[source].?;
        indices[source] = entry;

        links.move(source, body.sector);
    }

    for (case.relinks) |source| {
        const sector = case.bodies[source].sector;
        links.move(source, (sector + 1) % sectors.len);
        links.move(source, sector);
    }

    const loaded = try a.alloc(bool, sectors.len);
    @memset(loaded, false);

    var loads: usize = 0;
    var random: u32 = 1;
    var shared: controller.Shared = .{ .now = 1000 };
    var effects_buffer: [16]controller.Effect = undefined;
    var effects = controller.Effects.init(&effects_buffer);
    var ctx: controller.Context = .{
        .allocator = a,
        .level = &level,
        .scene = &scene,
        .angles = &angles,
        .actors = .{
            .entries = entries,
            .links = &links,
            .source_to_entry = indices,
            .loaded_sectors = loaded,
            .loader = .{ .context = &loads, .load = unexpectedLoad },
        },
        .targets = targets,
        .actor_slots = slots,
        .player = null,
        .visibility = &visibility,
        .random = &random,
        .now = 1000,
        .elapsed_seconds = 0,
        .shared = &shared,
        .effects = &effects,
    };

    const result = controller.event(&targets[0].?, &slots[0].?, 9, &ctx);

    if (unsupported != null) try std.testing.expectError(
        error.UnsupportedEnemyBroadcastRecipient,
        result,
    ) else try std.testing.expectEqual(false, try result);

    try std.testing.expectEqual(@as(usize, 0), loads);
    const prefix = if (unsupported) |source| case.recipients[0..std.mem.indexOfScalar(
        usize,
        case.recipients,
        source,
    ).?] else case.recipients;

    for (targets[1..], 1..) |slot, source| {
        const target = slot orelse continue;
        var count: usize = 0;

        for (prefix) |recipient| if (recipient == source) {
            count += 1;
        };

        try std.testing.expectEqual(@as(f32, @floatFromInt(count * 2)), target.anger);
        try std.testing.expectEqual(@as(f32, @floatFromInt(count * 2)), target.fear);
        try std.testing.expectEqual(@as(u32, if (count == 0) 0 else 3000), target.sight_at);
        try std.testing.expectEqual(@as(u32, if (count == 0) 777 else 0), target.next_tick);
    }
}

fn unexpectedLoad(raw: *anyopaque, sector: usize) anyerror!void {
    _ = sector;
    const count: *usize = @ptrCast(@alignCast(raw));
    count.* += 1;

    return error.UnexpectedBroadcastResourceLoad;
}

test "enemy broadcasts preserve recipients and order without loading scenery" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/enemy-broadcast-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []Case,
    };

    const parsed = try std.json.parseFromSlice(Corpus, a, bytes, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "157f928a5bf2a3a95732e81ab149dd90e92421abbb1ce2f9ddc8ac100c6dc5e6",
        parsed.value.results_sha256,
    );

    for (parsed.value.cases) |case| {
        try compare(case, null);

        for (case.recipients, 0..) |source, index| {
            if (std.mem.indexOfScalar(
                usize,
                case.recipients[0..index],
                source,
            ) == null) try compare(case, source);
        }
    }
}
