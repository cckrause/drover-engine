//! Saving the level: only the sectors and walls that changed, plus the
//! script engine's state.
//!
//! Geometry is reopened from its own resource first and the save only
//! carries the dirty records on top. Texture handles are not stored - they
//! are resolved again on load.

const std = @import("std");

const asset = @import("../assets/level.zig");
const object_numbers = @import("../render/object_numbers.zig");
const scene = @import("../render/scene.zig");
const sound = @import("sound.zig");
const stream = @import("stream.zig");
const bits = @import("../util/bits.zig");
const Vec2 = asset.Vec2;
const Vec3 = asset.Vec3;

pub const Music = struct { name: []const u8, cue: i32 };

pub const RestoredSector = struct {
    base_vertices: []const Vec2,
    visible_sectors: ?[]const u16,
    floor_sound: ?sound.Record,
};

pub fn write(session: anytype, writer: *stream.Writer, audio: anytype) !void {
    try writer.marker(0x4276654c, 1, 0);
    try writer.string(session.level_name);

    for (session.level.sectors, session.scene.sectors, 0..) |*sector, *state, index| {
        try writer.integer(u32, bits.word(state.flags));
        try writer.integer(u32, bits.word(state.runtime_flags));

        if (state.runtime_flags.changed) try writeSector(
            writer,
            sector,
            state,
            session.inf.base_vertices[index],
            session.enemy_visibility.lists[index],
            try sound.capture(audio, nonempty(sector.floor_sound)),
        );

        for (sector.walls, state.walls) |*wall, *wall_state| {
            try writer.integer(u32, bits.word(wall_state.flags));
            try writer.integer(u32, bits.word(wall_state.runtime_flags));

            if (wall_state.runtime_flags.changed) try writeWall(
                writer,
                wall,
                wall_state,
                @intCast(index),
            );
        }
    }

    try writer.boolean(audio.player != null);

    if (audio.player) |player| {
        try writer.string(audio.music_name);
        try writer.integer(i32, @intCast(player.cue));
    }
}

pub fn read(session: anytype, reader: *stream.Reader, audio: anytype) !?Music {
    try reader.marker(0x4276654c, 1, 0);

    var name: [255]u8 = undefined;
    if (!std.ascii.eqlIgnoreCase(
        try reader.string(&name),
        session.level_name,
    )) return error.SaveLevelMismatch;

    const a = session.arena.allocator();
    const numbered = @hasField(@TypeOf(session.*), "actor_numbers");

    for (session.level.sectors, session.scene.sectors, 0..) |*sector, *state, index| {
        state.flags = bits.from(scene.SectorFlags, try reader.integer(u32));
        sector.flags = state.flags;
        state.runtime_flags = bits.from(scene.SectorRuntimeFlags, try reader.integer(u32));

        if (state.runtime_flags.changed) {
            const restored = try readSector(reader, a, sector, state, session.level.sectors.len);
            @constCast(session.inf.base_vertices)[index] = restored.base_vertices;

            if (session.enemy_visibility.lists[index]) |old| session.enemy_visibility.allocator.free(old);

            session.enemy_visibility.lists[index] = restored.visible_sectors;
            sector.floor_sound = (try sound.restore(audio, restored.floor_sound)) orelse "";
            session.level_sound_ownership.floor_sounds[index] = if (sector.floor_sound.len == 0) null else sector.floor_sound;
        }

        if (numbered) try object_numbers.restoreSector(session, index);

        for (sector.walls, state.walls, 0..) |*wall, *wall_state, wall_index| {
            wall_state.flags = bits.from(scene.WallFlags, try reader.integer(u32));
            wall.flags = wall_state.flags;
            wall_state.runtime_flags = bits.from(scene.WallRuntimeFlags, try reader.integer(u32));

            if (wall_state.runtime_flags.changed) try readWall(
                reader,
                wall,
                wall_state,
                @intCast(index),
                &session.level,
            );

            if (numbered) try object_numbers.restoreWall(session, index, wall_index);
        }
    }

    if (!try reader.boolean()) return null;

    return .{ .name = try a.dupe(u8, try reader.string(&name)), .cue = try reader.integer(i32) };
}

pub fn writeSector(
    writer: *stream.Writer,
    sector: *const asset.Sector,
    state: *const scene.SectorState,
    base_vertices: []const Vec2,
    visible_sectors: ?[]const u16,
    floor_sound: ?sound.Record,
) !void {
    if (base_vertices.len != sector.vertices.len) return error.InvalidSaveVertexCount;

    try writer.integer(u32, sector.id);
    try writer.float(sector.layer);
    try writer.integer(u8, sector.palette);
    try writer.integer(u8, sector.cmap);
    try writer.integer(i32, sector.ambient);

    for (sector.vertices) |vertex| try writeVec2(writer, vertex);

    for (state.bounds) |value| try writer.float(value);

    try writer.float(sector.friction);
    try writer.float(sector.gravity);

    if (state.runtime_flags.has_base_velocity) try writeVec3(writer, state.original_velocity);

    if (state.runtime_flags.has_velocity) try writeVec3(writer, sector.velocity);

    try writer.float(sector.elasticity);
    try sound.write(writer, floor_sound);

    inline for (.{ "floor", "ceiling", "floor_overlay", "ceiling_overlay" }) |field| {
        const plane = @field(sector, field);
        try writer.float(plane.offset.x);
        try writer.float(plane.offset.x);
        try writer.integer(i16, plane.angle);
    }

    try writer.float(sector.ceiling.height);
    try writer.float(sector.floor.height);

    if (state.flags.sloped_ceiling) try writeSlope(
        writer,
        state.ceiling_slope orelse return error.MissingSceneSlope,
    );

    if (state.flags.sloped_floor) try writeSlope(
        writer,
        state.floor_slope orelse return error.MissingSceneSlope,
    );

    if (state.runtime_flags.has_vertical_adjoin) {
        if (sector.vadjoin < 0) return error.InvalidSaveVerticalAdjoin;
        try writer.integer(i32, sector.vadjoin);
    }

    const visible = visible_sectors orelse &.{};
    if (visible.len > 32767) return error.InvalidSaveVisibleSectors;

    try writer.integer(i16, @intCast(visible.len));

    for (visible) |ordinal| try writer.integer(u16, ordinal);

    try writer.integer(u32, @intCast(base_vertices.len));

    for (base_vertices) |vertex| try writeVec2(writer, vertex);
}

pub fn readSector(
    reader: *stream.Reader,
    a: std.mem.Allocator,
    sector: *asset.Sector,
    state: *scene.SectorState,
    sector_count: usize,
) !RestoredSector {
    sector.id = try reader.integer(u32);
    sector.layer = try finite(reader);
    sector.palette = try reader.integer(u8);
    sector.cmap = try reader.integer(u8);
    sector.ambient = try reader.integer(i32);

    for (sector.vertices) |*vertex| vertex.* = try readVec2(reader);

    for (&state.bounds) |*value| value.* = try finite(reader);

    sector.friction = try finite(reader);
    sector.gravity = try finite(reader);

    if (state.runtime_flags.has_base_velocity) state.original_velocity = try readVec3(reader);

    if (state.runtime_flags.has_velocity) {
        sector.velocity = try readVec3(reader);
        state.velocity_present = true;
    }

    sector.elasticity = try finite(reader);
    const floor_sound = try sound.read(reader, a);

    inline for (.{ "floor", "ceiling", "floor_overlay", "ceiling_overlay" }) |field| {
        const plane = &@field(sector, field);
        plane.offset.x = try finite(reader);
        plane.offset.x = try finite(reader);
        plane.angle = try reader.integer(i16);
    }

    sector.ceiling.height = try finite(reader);
    sector.floor.height = try finite(reader);

    if (state.flags.sloped_ceiling) state.ceiling_slope = try readSlope(reader);

    if (state.flags.sloped_floor) state.floor_slope = try readSlope(reader);

    if (state.runtime_flags.has_vertical_adjoin) {
        const ordinal = try reader.integer(u32);
        if (ordinal >= sector_count) return error.InvalidSaveVerticalAdjoin;
        sector.vadjoin = @intCast(ordinal);
    }

    const visible_count = try reader.integer(i16);
    if (visible_count < 0 or visible_count > sector_count) return error.InvalidSaveVisibleSectors;

    const visible: ?[]u16 = if (visible_count == 0) null else try a.alloc(
        u16,
        @intCast(visible_count),
    );

    if (visible) |entries| for (entries) |*ordinal| {
        ordinal.* = try reader.integer(u16);
        if (ordinal.* >= sector_count) return error.InvalidSaveVisibleSectors;
    };

    if (try reader.integer(u32) != sector.vertices.len) return error.InvalidSaveVertexCount;

    const base_vertices = try a.alloc(Vec2, sector.vertices.len);

    for (base_vertices) |*vertex| vertex.* = try readVec2(reader);

    state.runtime_flags.changed = true;

    return .{
        .base_vertices = base_vertices,
        .visible_sectors = visible,
        .floor_sound = floor_sound,
    };
}

pub fn writeWall(
    writer: *stream.Writer,
    wall: *const asset.Wall,
    state: *const scene.WallState,
    own_sector: u32,
) !void {
    inline for (.{
        "top",
        "mid",
        "bottom",
        "overlay",
    }) |field| try writeVec2(writer, @field(wall, field).offset);

    for ([_]f32{
        state.top_height,
        state.mid_height,
        state.bottom_height,
        state.direction.x,
        state.direction.z,
    }) |value| try writer.float(value);

    try writer.integer(i16, state.angle);
    try writer.float(state.length);
    try writer.integer(u32, wall.flags2);

    for ([_]i32{
        wall.adjoin,
        if (wall.adjoin >= 0) wall.mirror else -1,
        wall.dadjoin,
        if (wall.dadjoin >= 0) wall.dmirror else -1,
    }) |ordinal| {
        try writer.boolean(ordinal >= 0);
        if (ordinal >= 0) try writer.integer(i32, ordinal);
    }

    try writer.integer(u32, bits.word(state.render_flags));
    try writer.integer(u32, wall.v1);
    try writer.integer(u32, wall.v2);
    try writer.boolean(true);
    try writer.integer(u32, own_sector);
    try writer.integer(i32, state.light);
    try writeVec2(writer, state.original_start);

    for (state.base_vertices) |ordinal| try writer.integer(u32, ordinal);
}

pub fn readWall(
    reader: *stream.Reader,
    wall: *asset.Wall,
    state: *scene.WallState,
    own_sector: u32,
    level: *const asset.Level,
) !void {
    inline for (.{
        "top",
        "mid",
        "bottom",
        "overlay",
    }) |field| @field(wall, field).offset = try readVec2(reader);

    state.top_height = try finite(reader);
    state.mid_height = try finite(reader);
    state.bottom_height = try finite(reader);
    state.direction = try readVec2(reader);
    state.angle = try reader.integer(i16);
    state.length = try finite(reader);
    wall.flags2 = try reader.integer(u32);

    inline for (.{
        "adjoin",
        "mirror",
        "dadjoin",
        "dmirror",
    }) |field| @field(wall, field) = if (try reader.boolean()) try reader.integer(i32) else -1;

    for ([_]i32{
        wall.adjoin,
        wall.dadjoin,
    }, [_]i32{ wall.mirror, wall.dmirror }) |adjoin, mirror| {
        if (adjoin < -1 or mirror < -1) return error.InvalidSaveWallAdjoin;

        if (adjoin >= 0) {
            if (adjoin >= level.sectors.len) return error.InvalidSaveWallAdjoin;
            if (mirror >= level.sectors[
                @intCast(
                    adjoin,
                )
            ].walls.len) return error.InvalidSaveWallMirror;
        } else if (mirror != -1) return error.InvalidSaveWallMirror;
    }

    state.render_flags = bits.from(scene.WallParts, try reader.integer(u32));
    wall.v1 = try reader.integer(u32);
    wall.v2 = try reader.integer(u32);
    if (!try reader.boolean() or try reader.integer(
        u32,
    ) != own_sector) return error.InvalidSaveWallOwner;

    state.light = try reader.integer(i32);
    state.original_start = try readVec2(reader);

    for (&state.base_vertices) |*ordinal| ordinal.* = try reader.integer(u32);

    for ([_]u32{
        wall.v1,
        wall.v2,
        state.base_vertices[0],
        state.base_vertices[1],
    }) |ordinal| if (ordinal >= level.sectors[own_sector].vertices.len) return error.InvalidSaveWallVertex;

    state.runtime_flags.changed = true;
}

pub fn writeSlope(writer: *stream.Writer, slope: scene.Slope) !void {
    try writer.integer(i16, slope.angle);

    for ([_]f32{
        slope.min_y,
        slope.max_y,
        slope.coeff_x,
        slope.coeff_z,
    }) |value| try writer.float(value);

    try writeVec3(writer, slope.hinge_first);
    try writeVec3(writer, slope.origin);
    try writer.float(slope.constant);
    try writeVec3(writer, slope.u_axis);
    try writeVec3(writer, slope.v_axis);
    try writer.float(slope.u_offset);
    try writer.float(slope.v_offset);
}

pub fn readSlope(reader: *stream.Reader) !scene.Slope {
    return .{
        .angle = try reader.integer(i16),
        .min_y = try finite(reader),
        .max_y = try finite(reader),
        .coeff_x = try finite(reader),
        .coeff_z = try finite(reader),
        .hinge_first = try readVec3(reader),
        .origin = try readVec3(reader),
        .constant = try finite(reader),
        .u_axis = try readVec3(reader),
        .v_axis = try readVec3(reader),
        .u_offset = try finite(reader),
        .v_offset = try finite(reader),
    };
}

pub fn writeVec2(writer: *stream.Writer, value: Vec2) !void {
    try writer.float(value.x);
    try writer.float(value.z);
}

pub fn readVec2(reader: *stream.Reader) !Vec2 {
    return .{ .x = try finite(reader), .z = try finite(reader) };
}

pub fn writeVec3(writer: *stream.Writer, value: Vec3) !void {
    try writer.float(value.x);
    try writer.float(value.y);
    try writer.float(value.z);
}

pub fn readVec3(reader: *stream.Reader) !Vec3 {
    return .{ .x = try finite(reader), .y = try finite(reader), .z = try finite(reader) };
}

fn nonempty(value: []const u8) ?[]const u8 {
    return if (value.len == 0 or std.mem.eql(u8, value, "NULL")) null else value;
}

fn finite(reader: *stream.Reader) !f32 {
    const value = try reader.float();
    if (!std.math.isFinite(value)) return error.InvalidSaveGeometry;

    return value;
}
