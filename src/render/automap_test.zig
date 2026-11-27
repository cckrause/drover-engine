//! The automap: the integer line raster, the walls and layers it draws, its background, and its controls.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const level_module = @import("../assets/level.zig");
const automap = @import("automap.zig");
const camera = @import("backends/software/camera.zig");
const hud_messages = @import("hud_messages.zig");
const scene_module = @import("scene.zig");

const Raster = struct { rect: [4]i32, first: [2]i32, last: [2]i32, sha256: []const u8 };

const Map = struct {
    oriented: bool,
    reveal: bool,
    all_layers: bool,
    layer: f32,
    zoom: f32,
    yaw: i16,
    position: [2]f32,
    sector_flags: ?u32,
    wall_flags: ?u32,
    seen: ?bool,
    sha256: []const u8,
};

const Message = struct { text: []const u8, category: u32, color: u32, expiry: u32 };

const Control = struct {
    queued: []u7,
    held: []u7,
    layer: f32,
    found: u32,
    words: [16]u32,
    capture: bool,
    entries: [10]Message,
};

const Reference = struct {
    raster: []Raster,
    maps: []Map,
    controls: []Control,
    background: []const u8,
    integrated: ?[]const u8 = null,
};

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn expectPixels(pixels: []const u8, hex: []const u8) !void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pixels, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "automap integer raster matches the reference clipped lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try read(a, "testdata/automap-reference.json");
    const reference = try std.json.parseFromSlice(
        Reference,
        a,
        source,
        .{ .ignore_unknown_fields = true },
    );

    const pixels = try a.alloc(u8, 640 * 480);

    for (reference.value.raster, 0..) |case, index| {
        errdefer std.debug.print("raster case {d}\n", .{index});
        @memset(pixels, 91);

        automap.line(
            .{ .pixels = pixels, .stride = 640 },
            .{
                .left = case.rect[0],
                .top = case.rect[1],
                .width = case.rect[2],
                .height = case.rect[3],
            },
            .{ .x = case.first[0], .y = case.first[1] },
            .{ .x = case.last[0], .y = case.last[1] },
            15,
        );

        try expectPixels(pixels, case.sha256);
    }
}

test "automap Hideout walls, layers, projection and player glyph match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try read(a, "testdata/automap-reference.json");
    const reference = try std.json.parseFromSlice(
        Reference,
        a,
        source,
        .{ .ignore_unknown_fields = true },
    );

    const geo = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    const system = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"));
    const level = try level_module.Level.parse(a, try geo.find("hideout.lvb", 0));
    const angles = camera.Angles.init();
    const scene = try scene_module.Scene.init(a, &level, &angles);
    const pixels = try a.alloc(u8, 640 * 480);
    var messages = try hud_messages.HudMessages.init(system, 640);

    for (reference.value.maps, 0..) |case, index| {
        errdefer std.debug.print("automap frame {d}\n", .{index});

        for (scene.sectors, level.sectors, 0..) |*sector, source_sector, i| {
            sector.flags = case.sector_flags orelse source_sector.flags;

            for (sector.walls, source_sector.walls, 0..) |*wall, source_wall, j| {
                wall.flags = case.wall_flags orelse source_wall.flags;
                wall.runtime_flags = if (case.seen orelse ((i + j) % 3 == 0)) 0x40000000 else 0;
            }
        }

        var state = automap.State{
            .mode = if (case.oriented) 3 else 2,
            .flags = if (case.oriented) 6 else 2,
            .controller = 1,
            .previous_controller = 1,
            .initialized = true,
            .selected_layer = case.layer,
            .zoom = case.zoom,
            .reveal = case.reveal,
            .all_layers = case.all_layers,
        };

        var controls = automap.Input{};

        @memset(pixels, 91);

        try state.draw(
            &level,
            &scene,
            &angles,
            .{
                .position = .{ .x = case.position[0], .z = case.position[1] },
                .yaw = case.yaw,
                .layer = 0,
            },
            &controls,
            0,
            .{ .pixels = pixels, .stride = 640 },
            640,
            480,
            .{ .width = 640, .height = 440 },
            &messages,
            0,
            .{ .found = 0, .total = 0 },
        );

        try expectPixels(pixels, case.sha256);
    }
}

test "automap separate background repeats MAPBACK texture memory rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reference = try std.json.parseFromSlice(
        Reference,
        a,
        try read(a, "testdata/automap-reference.json"),
        .{ .ignore_unknown_fields = true },
    );

    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLTEX.LAB"));
    const texture = try @import("../assets/texture.zig").loadInitial(a, archive, "MAPBACK.PCX");
    const pixels = try a.alloc(u8, 640 * 480);

    automap.background(pixels, 640, 480, texture);
    try expectPixels(pixels, reference.value.background);
}

test "automap live Session combines explored walls weapon HUD and secret text like the reference" {
    const a = std.testing.allocator;
    const fixture = try read(a, "testdata/automap-reference.json");
    defer a.free(fixture);
    const reference = try std.json.parseFromSlice(
        Reference,
        a,
        fixture,
        .{ .ignore_unknown_fields = true },
    );

    defer reference.deinit();
    const expected = reference.value.integrated orelse return error.SkipZigTest;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const source = try read(a, data_path);
    defer a.free(source);
    const system = try lab.Archive.init(source);
    var startup = try @import("../campaign.zig").Startup.prepare(a, system, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    const session = try @import(
        "session.zig",
    ).Session.open(
        a,
        @import("test_workspace.zig").get(),
        std.testing.io,
        data_path,
        system,
        &startup,
    );

    defer session.deinit(a);
    var packet = @import("../player/input.zig").Packet{};

    packet.entries[
        @intFromEnum(
            @import("../player/input.zig").Slot.map,
        )
    ] = .{ .value = 1, .flags = 8 };

    session.automap.packet(&packet);

    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);

    @memset(pixels, 0);
    _ = try session.render(pixels, 0);

    try expectPixels(pixels, expected);
    try session.advance(a, &packet, 16);

    try std.testing.expectEqual(@as(u32, 0), session.automap.mode);
}

test "automap controls preserve frame timing layers pan zoom and secret messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reference = try std.json.parseFromSlice(
        Reference,
        a,
        try read(a, "testdata/automap-reference.json"),
        .{ .ignore_unknown_fields = true },
    );

    const geo = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB"));
    const system = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"));
    const level = try level_module.Level.parse(a, try geo.find("hideout.lvb", 0));
    const angles = camera.Angles.init();
    const scene = try scene_module.Scene.init(a, &level, &angles);

    for (level.sectors, scene.sectors) |*sector, *live| {
        sector.layer = 0;
        live.flags |= 0x20000000;
    }

    level.sectors[0].layer = -2;
    level.sectors[1].layer = 2;

    const pixels = try a.alloc(u8, 640 * 480);
    @memset(pixels, 0);

    var messages = try hud_messages.HudMessages.init(system, 640);
    var state = automap.State{};
    var packet = @import("../player/input.zig").Packet{};

    packet.entries[
        @intFromEnum(
            @import("../player/input.zig").Slot.map,
        )
    ] = .{ .value = 1, .flags = 8 };

    state.packet(&packet);

    for (reference.value.controls, 0..) |case, i| {
        errdefer std.debug.print("automap control frame {d}\n", .{i});
        var raw = automap.Input{};

        for (case.queued) |key| raw.key(key, true);

        raw.down = @splat(false);

        for (case.held) |key| raw.down[key] = true;

        try state.draw(
            &level,
            &scene,
            &angles,
            .{
                .position = .{ .x = 12.25, .z = -31.5 },
                .layer = case.layer,
                .yaw = 1337,
                .head_yaw = -177,
            },
            &raw,
            0.016,
            .{ .pixels = pixels, .stride = 640 },
            640,
            480,
            .{ .width = 640, .height = 480 },
            &messages,
            @intCast(100 + i * 16),
            .{ .found = case.found, .total = 6 },
        );

        const words = [_]u32{
            state.mode,
            state.flags,
            state.controller,
            state.previous_controller,
            @intFromBool(state.initialized),
            @bitCast(state.zoom),
            @bitCast(state.previous_zoom),
            @bitCast(state.selected_layer),
            @bitCast(state.previous_layer),
            @bitCast(state.center.x),
            @bitCast(state.center.z),
            @bitCast(state.previous_player.x),
            @bitCast(state.previous_player.z),
            @intFromBool(state.follow),
            @intFromBool(state.all_layers),
            state.previous_secrets,
        };

        try std.testing.expectEqualSlices(u32, &case.words, &words);
        try std.testing.expectEqual(case.capture, state.capture_arrows);

        for (&messages.entries, case.entries) |*entry, expected| {
            try std.testing.expectEqualStrings(expected.text, entry.string());
            try std.testing.expectEqual(expected.category, entry.category);
            try std.testing.expectEqual(expected.color, entry.color);
            try std.testing.expectEqual(expected.expiry, entry.expiry);
        }
    }
}
