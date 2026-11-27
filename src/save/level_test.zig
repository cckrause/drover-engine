//! The geometry records in a saved game, including their field order.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const level_module = @import("../assets/level.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene_module = @import("../render/scene.zig");
const saved = @import("level.zig");
const stream = @import("stream.zig");

test "geometry save records restore field order and offset quirk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/save-geometry-reference.json",
        a,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const Case = struct {
        kind: []const u8,
        level: []const u8,
        index: usize,
        wall: usize = 0,
        flags: u32 = 0,
        runtime: u32 = 0,
        bytes: []const u8,
        offsets: [8]u32 = @splat(0),
        original: [2]u32 = @splat(0),
    };

    const Fixture = struct { results_sha256: []const u8, cases: []Case };
    const parsed = try std.json.parseFromSlice(
        Fixture,
        a,
        fixture,
        .{ .ignore_unknown_fields = true },
    );

    try std.testing.expectEqualStrings(
        "51a4746b82b440644c395e5b016abd0fe751663be65447caaf5e7d7ddcb0f2ef",
        parsed.value.results_sha256,
    );

    const archive = try lab.Archive.init(
        try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
            a,
            .limited(128 * 1024 * 1024),
        ),
    );

    const angles = camera.Angles.init();

    for (parsed.value.cases) |case| {
        const path = try std.fmt.allocPrint(a, "{s}.LVB", .{case.level});
        var level = try level_module.Level.parse(a, try archive.find(path, 0));
        var scene = try scene_module.Scene.init(a, &level, &angles);
        const bytes = try a.alloc(u8, case.bytes.len / 2);

        _ = try std.fmt.hexToBytes(bytes, case.bytes);

        var reader: stream.Reader = .{ .bytes = bytes };
        var writer: stream.Writer = .{ .allocator = a };
        const sector = &level.sectors[case.index];
        const state = &scene.sectors[case.index];

        if (std.mem.eql(u8, case.kind, "sector")) {
            state.flags = case.flags;
            state.runtime_flags = case.runtime;

            inline for (.{
                "floor",
                "ceiling",
                "floor_overlay",
                "ceiling_overlay",
            }, 0..) |field, index| @field(sector, field).offset.z = @floatFromInt(101 + index);

            const restored = try saved.readSector(&reader, a, sector, state, level.sectors.len);

            try std.testing.expectEqual(
                @as(u32, 0x11220000) + @as(u32, @intCast(case.index)),
                sector.id,
            );

            try std.testing.expectEqual(@as(f32, -1.25), sector.layer);
            try std.testing.expectEqual(@as(u8, 2), sector.palette);
            try std.testing.expectEqual(@as(u8, 3), sector.cmap);
            try std.testing.expectEqualDeep(
                level_module.Vec3{ .x = 1, .y = 2, .z = 3 },
                state.original_velocity,
            );

            try std.testing.expectEqualDeep(
                level_module.Vec3{ .x = 4, .y = 5, .z = 6 },
                sector.velocity,
            );

            inline for (.{
                "floor",
                "ceiling",
                "floor_overlay",
                "ceiling_overlay",
            }, 0..) |field, index| {
                try std.testing.expectEqual(
                    case.offsets[index],
                    @as(u32, @bitCast(@field(sector, field).offset.x)),
                );

                try std.testing.expectEqual(
                    case.offsets[4 + index],
                    @as(u32, @bitCast(@field(sector, field).offset.z)),
                );
            }

            try saved.writeSector(
                &writer,
                sector,
                state,
                restored.base_vertices,
                restored.visible_sectors,
                restored.floor_sound,
            );
        } else {
            const wall = &sector.walls[case.wall];
            const wall_state = &state.walls[case.wall];

            try saved.readWall(&reader, wall, wall_state, @intCast(case.index), &level);

            try std.testing.expectEqual(
                case.original,
                [2]u32{
                    @bitCast(wall_state.original_start.x),
                    @bitCast(wall_state.original_start.z),
                },
            );

            try std.testing.expectEqual(@as(i32, -7), wall_state.light);
            try std.testing.expectEqual(@as(i16, -123), wall_state.angle);

            try saved.writeWall(&writer, wall, wall_state, @intCast(case.index));

            if (std.mem.eql(u8, case.level, "HIDEOUT") and case.index == 369 and case.wall == 0) {
                try std.testing.expect(wall.adjoin == -1);
                wall.mirror = 3;
                var from_asset: stream.Writer = .{ .allocator = a };
                try saved.writeWall(&from_asset, wall, wall_state, @intCast(case.index));
                try std.testing.expectEqualSlices(u8, bytes, try from_asset.finish());
            }
        }

        try reader.end();
        try std.testing.expectEqualSlices(u8, bytes, try writer.finish());
    }
}
