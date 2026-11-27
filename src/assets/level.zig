//! Level geometry: sectors, vertices and walls, in both the binary (.lvb)
//! and text (.lvt) forms. The binary form wins when both exist.
//!
//! Quirks worth knowing: packed slope hinges may be out of range here and
//! have their slope removed later when the scene is built; some records are
//! consumed without adding a floor; and a double adjoin is only chosen after
//! the far sector has been resolved, so wall links must be read in order.

const std = @import("std");

pub const Vec2 = struct { x: f32, z: f32 };

pub const Vec3 = struct { x: f32, y: f32, z: f32 };

pub const TextureRef = struct {
    texture: i32,
    offset: Vec2,
};

pub const Slope = struct {
    sector: u16,
    wall: u16,
    angle: i16,
};

pub const Plane = struct {
    height: f32,
    texture: i32,
    offset: Vec2,
    angle: i16,
    slope: ?Slope = null,
};

pub const Overlay = struct { texture: i32, offset: Vec2, angle: i16 };

pub const FloorOffset = struct { height: f32, texture: i32, offset: Vec2, flags: [2]u32 };

pub const Shade = struct {
    color: [3]u8,
    amount: i32,
    mode: enum(u32) { grayscale = 1, tint = 2, light = 3 },
};

pub const Wall = struct {
    id: u32,
    v1: u32,
    v2: u32,
    mid: TextureRef,
    top: TextureRef,
    bottom: TextureRef,
    overlay: TextureRef,
    adjoin: i32,
    mirror: i32,
    dadjoin: i32,
    dmirror: i32,
    flags: u32,
    flags2: u32,
    light: i32,
};

pub const Sector = struct {
    id: u32,
    name: []const u8,
    ambient: i32,
    palette: u8,
    cmap: u8,
    friction: f32,
    gravity: f32,
    elasticity: f32,
    velocity: Vec3,
    vadjoin: i32,
    floor_sound: []const u8,
    floor: Plane,
    ceiling: Plane,
    floor_overlay: Overlay,
    ceiling_overlay: Overlay,
    floor_offsets: []FloorOffset,
    flags: u32,
    flags2: u32,
    layer: f32,
    vertices: []Vec2,
    walls: []Wall,
};

pub const Level = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    version: [2]u32,
    token_checksum: u32,
    palettes: [][]const u8,
    cmaps: [][]const u8,
    music: []const u8,
    parallax: Vec2,
    light_source: [4]f32,
    shades: [16]?Shade,
    textures: [][]const u8,
    sectors: []Sector,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Level {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var reader = try Tokens.init(a, bytes, ".LVT");

        try reader.token(0, 2);
        if (try reader.u32Value() != 1 or try reader.u32Value() != 1)
            return error.UnsupportedLevelVersion;

        try reader.token(1, 1);

        const full_name = try reader.string();
        const name = full_name[0..@min(full_name.len, 32)];
        var version: [2]u32 = .{ 0, 0 };

        if (try reader.optional(2, 2)) version = .{ try reader.u32Value(), try reader.u32Value() };

        try reader.token(3, 1);

        const palettes = try readNames(a, &reader, 4, try reader.count(), true);
        if (palettes.len == 0 or palettes.len > 255) return error.InvalidLevelPaletteCount;

        var cmaps: [][]const u8 = &.{};

        if (try reader.optional(
            5,
            1,
        )) cmaps = try readNames(a, &reader, 6, try reader.count(), true);

        if (cmaps.len > 255) return error.InvalidLevelColormapCount;

        var music: []const u8 = "";

        if (try reader.optional(7, 1)) {
            const full_music = try reader.string();
            music = full_music[0..@min(full_music.len, 32)];
        }

        try reader.token(8, 2);

        const parallax = try reader.vec2();
        var light_source: [4]f32 = .{ 0, 0, 0, 0 };

        if (try reader.optional(9, 4)) {
            for (&light_source) |*value| value.* = try reader.float();
        }

        try reader.token(10, 1);

        const shade_count = try reader.count();
        var shades: [16]?Shade = @splat(null);

        for (0..shade_count) |_| {
            try reader.token(11, 6);

            const index = try reader.u32Value();
            const red: u8 = @truncate(try reader.u32Value());
            const green: u8 = @truncate(try reader.u32Value());
            const blue: u8 = @truncate(try reader.u32Value());
            const amount = try reader.i32Value();
            const mode_string = try reader.string();
            if (index == 0 or index > 15 or mode_string.len != 1) return error.InvalidLevelShade;

            const mode: @FieldType(Shade, "mode") = switch (std.ascii.toUpper(mode_string[0])) {
                'G' => .grayscale,
                'L' => .light,
                'T' => .tint,
                else => return error.InvalidLevelShade,
            };

            shades[index] = .{ .color = .{ red, green, blue }, .amount = amount, .mode = mode };
        }

        try reader.token(12, 1);

        const textures = try readNames(a, &reader, 13, try reader.count(), false);
        if (textures.len == 0) return error.EmptyLevelTextures;

        try reader.token(14, 1);

        const sectors = try a.alloc(Sector, try reader.count());
        if (sectors.len == 0) return error.EmptyLevelSectors;

        for (sectors) |*sector| sector.* = try readSector(a, &reader);

        if (reader.cursor != reader.bytes.len) return error.TrailingLevelData;

        const result: Level = .{
            .arena = arena,
            .name = name,
            .version = version,
            .token_checksum = reader.checksum,
            .palettes = palettes,
            .cmaps = cmaps,
            .music = music,
            .parallax = parallax,
            .light_source = light_source,
            .shades = shades,
            .textures = textures,
            .sectors = sectors,
        };

        try result.validate();

        return result;
    }

    pub fn deinit(self: *Level) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn sectorIndex(self: *const Level, id: u32) ?usize {
        for (self.sectors, 0..) |sector, index| if (sector.id == id) return index;

        return null;
    }

    fn validate(self: *const Level) !void {
        for (self.sectors) |sector| {
            if (sector.palette >= self.palettes.len or sector.cmap >= self.cmaps.len)
                return error.InvalidSectorPalette;

            try validOptionalIndex(sector.vadjoin, self.sectors.len);
            try validIndex(sector.floor.texture, self.textures.len);
            try validIndex(sector.ceiling.texture, self.textures.len);
            try validOptionalIndex(sector.floor_overlay.texture, self.textures.len);
            try validOptionalIndex(sector.ceiling_overlay.texture, self.textures.len);

            for (sector.walls) |wall| {
                if (wall.v1 >= sector.vertices.len or wall.v2 >= sector.vertices.len)
                    return error.InvalidWallVertex;

                try validIndex(wall.mid.texture, self.textures.len);
                try validIndex(wall.top.texture, self.textures.len);
                try validIndex(wall.bottom.texture, self.textures.len);
                try validOptionalIndex(wall.overlay.texture, self.textures.len);
                try self.validateAdjoin(wall.adjoin, wall.mirror);
                try self.validateAdjoin(wall.dadjoin, wall.dmirror);
                if (wall.dadjoin >= 0 and wall.adjoin < 0) return error.InvalidDoubleAdjoin;
            }
        }
    }

    fn validateAdjoin(self: *const Level, adjoin: i32, mirror: i32) !void {
        try validOptionalIndex(adjoin, self.sectors.len);

        if (adjoin != -1) {
            if (mirror < 0 or mirror >= self.sectors[@intCast(adjoin)].walls.len)
                return error.InvalidWallMirror;
        }
    }
};

pub const Object = struct {
    name: []const u8,
    id: u32,
    sector_id: u32,
    position: Vec3,
    rotation: Vec3,
    angles: [3]i16,
    flags: [2]u32,
};

pub const Spawn = struct {
    sector: usize,
    position: Vec3,
    rotation: Vec3,

    pub fn fromStart(level: *const Level, record: [7]u32) !Spawn {
        return .{
            .sector = level.sectorIndex(
                record[0],
            ) orelse return error.StartSectorByPositionNotPorted,
            .position = .{
                .x = @bitCast(record[1]),
                .y = @bitCast(record[2]),
                .z = @bitCast(record[3]),
            },
            .rotation = .{
                .x = @bitCast(record[4]),
                .y = @bitCast(record[5]),
                .z = @bitCast(record[6]),
            },
        };
    }
};

pub const Objects = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    entries: []Object,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Objects {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var reader = try Tokens.init(arena.allocator(), bytes, ".OBT");

        try reader.token(0, 2);
        if (try reader.u32Value() != 1 or try reader.u32Value() != 0)
            return error.UnsupportedObjectsVersion;

        var name: []const u8 = "";

        if (try reader.optional(1, 1)) name = try reader.string();

        try reader.token(2, 1);
        const entries = try arena.allocator().alloc(Object, try reader.count());

        for (entries) |*entry| {
            try reader.token(3, 11);

            const object_name = try reader.string();
            const id = try reader.u32Value();
            const sector_id = try reader.u32Value();
            const position = try reader.vec3();
            const rotation = try reader.vec3();

            entry.* = .{
                .name = object_name,
                .id = id,
                .sector_id = sector_id,
                .position = position,
                .rotation = rotation,
                .angles = .{
                    try angleFromDegrees(rotation.x),
                    try angleFromDegrees(rotation.y),
                    try angleFromDegrees(rotation.z),
                },
                .flags = .{ try reader.u32Value(), try reader.u32Value() },
            };
        }

        if (reader.cursor != reader.bytes.len) return error.TrailingObjectsData;

        return .{ .arena = arena, .name = name, .entries = entries };
    }

    pub fn deinit(self: *Objects) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn playerStarts(
        self: *const Objects,
        allocator: std.mem.Allocator,
        level: *const Level,
        difficulty: u32,
    ) ![][7]u32 {
        const mask: u32 = switch (difficulty) {
            0x100000 => 0x10000000,
            0x200000 => 0x20000000,
            0x400000 => 0x40000000,
            0x800000 => 0x80000000,
            else => return error.InvalidDifficulty,
        };

        var starts: std.ArrayList([7]u32) = .empty;
        errdefer starts.deinit(allocator);

        for (self.entries) |object| {
            if (object.flags[1] & mask == 0 or object.flags[0] & 1 != 0) continue;

            if (level.sectorIndex(object.sector_id) == null) continue;

            if (!std.ascii.eqlIgnoreCase(object.name, "player")) continue;

            var record: [7]u32 = .{
                object.sector_id,
                @bitCast(object.position.x),
                @bitCast(object.position.y),
                @bitCast(object.position.z),
                0,
                0,
                0,
            };

            for (object.angles, 4..) |angle, index| {
                const degrees: f32 = @floatCast(
                    @as(f64, @floatFromInt(angle)) * 0.02197261333473958,
                );

                record[index] = @bitCast(degrees);
            }

            try starts.append(allocator, record);
        }

        return starts.toOwnedSlice(allocator);
    }

    pub fn multiplayerStarts(
        self: *const Objects,
        allocator: std.mem.Allocator,
        level: *const Level,
        mode: u32,
        difficulty: u32,
        option0: bool,
    ) ![][7]u32 {
        const modes = [_]u32{ 0, 0x800000, 0x1000000, 0x2000000, 0x4000000, 0x8000000, 0x400000 };
        if (mode == 0 or mode >= modes.len) return error.InvalidMultiplayerMode;

        const difficulty_mask: u32 = switch (difficulty) {
            0x100000 => 0x10000000,
            0x200000 => 0x20000000,
            0x400000 => 0x40000000,
            0x800000 => 0x80000000,
            else => return error.InvalidDifficulty,
        };

        const name: []const u8 = switch (mode) {
            1 => "FLAGSTAR",
            2, 5, 6 => "STARTPOS",
            3 => "BALLSTAR",
            4 => "DOCSTART",
            else => unreachable,
        };

        var starts: std.ArrayList([7]u32) = .empty;
        errdefer starts.deinit(allocator);

        for (self.entries) |object| {
            if (object.flags[1] & (modes[mode] | difficulty_mask) == 0 or (!option0 and object.flags[1] & 0x200000 != 0)) continue;

            if (level.sectorIndex(object.sector_id) == null) continue;

            if (object.flags[0] & 1 != 0 or !std.ascii.eqlIgnoreCase(
                object.name,
                name,
            ) or object.sector_id == 0) continue;

            var record: [7]u32 = .{
                object.sector_id,
                @bitCast(object.position.x),
                @bitCast(object.position.y),
                @bitCast(object.position.z),
                0,
                0,
                0,
            };

            for (object.angles, 4..) |angle, index| {
                const degrees: f32 = @floatCast(
                    @as(f64, @floatFromInt(angle)) * 0.02197261333473958,
                );

                record[index] = @bitCast(degrees);
            }

            try starts.append(allocator, record);
        }

        return starts.toOwnedSlice(allocator);
    }
};

const Tokens = struct {
    bytes: []const u8,
    cursor: usize = 8,
    checksum: u32,

    fn init(a: std.mem.Allocator, bytes: []const u8, kind: *const [4]u8) !Tokens {
        if (bytes.len < 8) return error.TruncatedLevelData;

        const initial = @byteSwap(std.mem.readInt(u32, kind[0..4], .little));
        if (!std.mem.eql(
            u8,
            bytes[0..4],
            &.{ 0, 0, 0, 0 },
        )) return .{
            .bytes = try @import("level_text.zig").tokenize(a, bytes, kind),
            .checksum = initial,
        };

        if (!std.mem.eql(u8, bytes[4..8], kind)) return error.InvalidLevelTokenFormat;

        return .{ .bytes = bytes, .checksum = initial };
    }

    fn take(self: *Tokens, size: usize) ![]const u8 {
        if (size > self.bytes.len - self.cursor) return error.TruncatedLevelData;
        const result = self.bytes[self.cursor..][0..size];
        self.cursor += size;

        return result;
    }

    fn peek(self: *const Tokens) !?u32 {
        if (self.cursor == self.bytes.len) return null;
        if (self.bytes.len - self.cursor < 5) return error.TruncatedLevelData;

        return std.mem.readInt(u32, self.bytes[self.cursor..][0..4], .little);
    }

    fn header(self: *Tokens, wanted: u32) !u8 {
        const record = try self.take(5);
        if (std.mem.readInt(
            u32,
            record[0..4],
            .little,
        ) != wanted) return error.UnexpectedLevelToken;

        self.checksum +%= wanted;

        return record[4];
    }

    fn token(self: *Tokens, wanted: u32, count_value: u8) !void {
        if (try self.header(wanted) != count_value) return error.InvalidLevelTokenArguments;
    }

    fn optional(self: *Tokens, wanted: u32, count_value: u8) !bool {
        if (try self.peek() != wanted) return false;
        try self.token(wanted, count_value);

        return true;
    }

    fn u32Value(self: *Tokens) !u32 {
        const bytes = try self.take(4);
        const value = std.mem.readInt(u32, bytes[0..4], .little);
        self.checksum +%= value;

        return value;
    }

    fn i32Value(self: *Tokens) !i32 {
        return @bitCast(try self.u32Value());
    }

    fn count(self: *Tokens) !usize {
        const value = try self.u32Value();
        if (value > (self.bytes.len - self.cursor) / 5) return error.InvalidLevelCount;

        return value;
    }

    fn float(self: *Tokens) !f32 {
        const value: f32 = @bitCast(std.mem.readInt(u32, (try self.take(4))[0..4], .little));
        if (!std.math.isFinite(value)) return error.InvalidLevelCoordinate;

        const scaled = @as(f64, value) * 100.0 + 0.5;
        if (scaled < -0x1.0p31 or scaled >= 0x1.0p31) return error.InvalidLevelCoordinate;

        self.checksum +%= @bitCast(@as(i32, @intFromFloat(scaled)));

        return value;
    }

    fn vec2(self: *Tokens) !Vec2 {
        return .{ .x = try self.float(), .z = try self.float() };
    }

    fn vec3(self: *Tokens) !Vec3 {
        return .{ .x = try self.float(), .y = try self.float(), .z = try self.float() };
    }

    fn string(self: *Tokens) ![]const u8 {
        const tail = self.bytes[self.cursor..];
        const length = std.mem.indexOfScalar(u8, tail, 0) orelse return error.TruncatedLevelData;
        if (length > 255) return error.UnsupportedLevelStringLength;

        self.cursor += length + 1;

        for (tail[0 .. length + 1]) |byte| self.checksum +%= byte;

        return tail[0..length];
    }
};

pub fn angleFromDegrees(degrees: f32) !i16 {
    return truncateAngle(@as(f64, degrees) * 45.5112);
}

fn readNames(
    a: std.mem.Allocator,
    reader: *Tokens,
    id: u32,
    count: usize,
    pcx_name: bool,
) ![][]const u8 {
    const names = try a.alloc([]const u8, count);

    for (names) |*name| {
        try reader.token(id, 1);
        const raw = try reader.string();
        name.* = if (pcx_name) try std.fmt.allocPrint(a, "{s}.pcx", .{basename(raw)}) else raw;
        if (pcx_name and name.len > 32) return error.UnsupportedLevelResourceName;
    }

    return names;
}

fn basename(name: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, name, "\\:")) |index| index + 1 else 0;
    const tail = name[start..];

    if (std.mem.indexOfScalar(u8, tail, '.')) |dot| {
        if (dot + 1 < tail.len) return tail[0..dot];
    }

    return tail;
}

fn readSector(a: std.mem.Allocator, reader: *Tokens) !Sector {
    try reader.token(15, 1);

    const id = try reader.u32Value();
    var name: []const u8 = "";

    if (try reader.peek() == 16) {
        const count = try reader.header(16);
        if (count > 1) return error.InvalidLevelTokenArguments;
        if (count == 1) name = try reader.string();
    }

    try reader.token(17, 1);

    const ambient = try reader.i32Value();
    const palette: u8 = if (try reader.optional(18, 1)) @truncate(try reader.u32Value()) else 0;
    const cmap: u8 = if (try reader.optional(19, 1)) @truncate(try reader.u32Value()) else 0;
    const friction: f32 = if (try reader.optional(20, 1)) try reader.float() else 1.0;
    const gravity: f32 = if (try reader.optional(21, 1)) try reader.float() else -60.0;
    const elasticity: f32 = if (try reader.optional(22, 1)) try reader.float() else 0.3;
    const velocity: Vec3 = if (try reader.optional(
        23,
        3,
    )) try reader.vec3() else .{ .x = 0, .y = 0, .z = 0 };

    const vadjoin: i32 = if (try reader.optional(24, 1)) try reader.i32Value() else -1;
    const floor_sound: []const u8 = if (try reader.optional(25, 1)) try reader.string() else "";

    try reader.token(26, 5);
    var floor = try readPlane(reader);
    try reader.token(27, 5);
    var ceiling = try readPlane(reader);
    try reader.token(28, 4);
    const floor_overlay = try readOverlay(reader);
    try reader.token(29, 4);
    const ceiling_overlay = try readOverlay(reader);
    try reader.token(30, 1);
    const offsets = try a.alloc(FloorOffset, try reader.count());

    for (offsets) |*offset| {
        try reader.token(31, 6);
        offset.* = .{
            .height = try reader.float(),
            .texture = try reader.i32Value(),
            .offset = try reader.vec2(),
            .flags = .{ try reader.u32Value(), try reader.u32Value() },
        };
    }

    try reader.token(32, 2);

    const flags = try reader.u32Value();
    const flags2 = try reader.u32Value();

    if (flags & 0x40000000 != 0) {
        try reader.token(33, 3);
        floor.slope = try readSlope(reader);
    }

    if (flags & 0x80000000 != 0) {
        try reader.token(34, 3);
        ceiling.slope = try readSlope(reader);
    }

    try reader.token(35, 1);
    const layer = try reader.float();
    try reader.token(36, 1);

    const vertices = try a.alloc(Vec2, try reader.count());
    if (vertices.len == 0) return error.EmptySectorVertices;

    for (vertices) |*vertex| {
        try reader.token(37, 2);
        vertex.* = try reader.vec2();
    }

    try reader.token(38, 1);

    const walls = try a.alloc(Wall, try reader.count());
    if (walls.len == 0) return error.EmptySectorWalls;

    for (walls) |*wall| {
        try reader.token(39, 22);
        wall.* = .{
            .id = try reader.u32Value(),
            .v1 = try reader.u32Value(),
            .v2 = try reader.u32Value(),
            .mid = try readWallTexture(reader),
            .top = try readWallTexture(reader),
            .bottom = try readWallTexture(reader),
            .overlay = try readWallTexture(reader),
            .adjoin = try reader.i32Value(),
            .mirror = try reader.i32Value(),
            .dadjoin = try reader.i32Value(),
            .dmirror = try reader.i32Value(),
            .flags = try reader.u32Value(),
            .flags2 = try reader.u32Value(),
            .light = try reader.i32Value(),
        };
    }

    return .{
        .id = id,
        .name = name,
        .ambient = ambient,
        .palette = palette,
        .cmap = cmap,
        .friction = friction,
        .gravity = gravity,
        .elasticity = elasticity,
        .velocity = velocity,
        .vadjoin = vadjoin,
        .floor_sound = floor_sound,
        .floor = floor,
        .ceiling = ceiling,
        .floor_overlay = floor_overlay,
        .ceiling_overlay = ceiling_overlay,
        .floor_offsets = offsets,
        .flags = flags,
        .flags2 = flags2,
        .layer = layer,
        .vertices = vertices,
        .walls = walls,
    };
}

fn readPlane(reader: *Tokens) !Plane {
    return .{
        .height = try reader.float(),
        .texture = try reader.i32Value(),
        .offset = try reader.vec2(),
        .angle = try angleFromDegrees(try reader.float()),
    };
}

fn readOverlay(reader: *Tokens) !Overlay {
    return .{
        .texture = try reader.i32Value(),
        .offset = try reader.vec2(),
        .angle = try angleFromDegrees(try reader.float()),
    };
}

fn readSlope(reader: *Tokens) !Slope {
    const sector = try reader.u32Value();
    const wall = try reader.u32Value();
    const hinge = (sector << 16) | wall;

    return .{
        .sector = @truncate(hinge >> 16),
        .wall = @truncate(hinge),
        .angle = try truncateAngle(try reader.float()),
    };
}

fn readWallTexture(reader: *Tokens) !TextureRef {
    const texture = try reader.i32Value();
    const raw = try reader.vec2();

    return .{ .texture = texture, .offset = .{ .x = raw.x * 8.0, .z = raw.z * 8.0 } };
}

fn truncateAngle(value: f64) !i16 {
    if (!std.math.isFinite(value) or value < -2147483648.0 or value >= 2147483648.0)
        return error.InvalidLevelAngle;
    const integer: i32 = @intFromFloat(value);

    return @truncate(integer);
}

fn validIndex(index: i32, count: usize) !void {
    if (index < 0 or index >= count) return error.InvalidLevelIndex;
}

fn validOptionalIndex(index: i32, count: usize) !void {
    if (index != -1) try validIndex(index, count);
}

test "CD1 binary level and object records preserve first-level geometry and spawn" {
    const allocator = std.testing.allocator;
    const lab = @import("lab.zig");
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        allocator,
        .limited(32 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(data);
    const archive = try lab.Archive.init(data);
    var level = try Level.parse(allocator, try archive.find("hideout.lvb", 0x4c565446));
    defer level.deinit();
    var objects = try Objects.parse(allocator, try archive.find("hideout.obb", 0x4f425446));
    defer objects.deinit();

    try std.testing.expectEqual(@as(usize, 416), level.sectors.len);
    try std.testing.expectEqual(@as(usize, 87), level.textures.len);
    try std.testing.expectEqualStrings("hideout.pcx", level.palettes[0]);
    try std.testing.expectEqualStrings("uwhidot.pcx", level.cmaps[1]);
    try std.testing.expectEqualStrings("HAWIN2.ATX", level.textures[54]);

    var vertices: usize = 0;
    var walls: usize = 0;
    var floor_slopes: usize = 0;
    var ceiling_slopes: usize = 0;

    for (level.sectors) |sector| {
        vertices += sector.vertices.len;
        walls += sector.walls.len;
        floor_slopes += @intFromBool(sector.floor.slope != null);
        ceiling_slopes += @intFromBool(sector.ceiling.slope != null);
    }

    try std.testing.expectEqual(@as(usize, 3729), vertices);
    try std.testing.expectEqual(@as(usize, 3729), walls);
    try std.testing.expectEqual(@as(usize, 21), floor_slopes);
    try std.testing.expectEqual(@as(usize, 32), ceiling_slopes);
    try std.testing.expectEqual(@as(usize, 477), objects.entries.len);

    for ([_]u32{ 0x100000, 0x200000, 0x800000 }) |difficulty| {
        const starts = try objects.playerStarts(std.testing.allocator, &level, difficulty);
        defer std.testing.allocator.free(starts);

        try std.testing.expectEqual(@as(usize, 1), starts.len);
        const spawn = try Spawn.fromStart(&level, starts[0]);

        try std.testing.expectEqual(@as(usize, 410), spawn.sector);
        try std.testing.expectEqual(Vec3{ .x = 322.36, .y = -3, .z = 271.88 }, spawn.position);
        try std.testing.expectEqual(
            @as(f32, @floatCast(@as(f64, 8035) * 0.02197261333473958)),
            spawn.rotation.y,
        );

        const sector = level.sectors[spawn.sector];

        try std.testing.expectEqual(@as(u32, 0x36a11), sector.id);
        try std.testing.expectEqual(@as(u32, 0x401), sector.flags);
        try std.testing.expectEqual(@as(f32, -3), sector.floor.height);
        try std.testing.expectEqual(@as(i32, 64), sector.floor.texture);
        try std.testing.expectEqual(@as(f32, 45), sector.ceiling.height);
        try std.testing.expectEqual(@as(i32, 58), sector.ceiling.texture);
        try std.testing.expectEqual(@as(f32, 98), sector.walls[0].mid.offset.x);
    }
}

test "LVT token checksum matches on Dry Gulch" {
    const a = std.testing.allocator;
    const lab = @import("lab.zig");
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD2/OUTLAWS/OLGEO.LAB",
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(data);
    const archive = try lab.Archive.init(data);
    var level = try Level.parse(a, try archive.find("DRYGULCH.LVB", 0x4c565446));
    defer level.deinit();

    try std.testing.expectEqual(@as(u32, 0x0738ace6), level.token_checksum);
}

test "binary level parsing rejects format errors and truncated data" {
    try std.testing.expectError(
        error.TruncatedLevelData,
        Level.parse(std.testing.allocator, "LVT 1.1\n"),
    );

    try std.testing.expectError(
        error.InvalidLevelTokenFormat,
        Level.parse(std.testing.allocator, "\x00\x00\x00\x00.OBT"),
    );

    try std.testing.expectError(
        error.TruncatedLevelData,
        Level.parse(std.testing.allocator, "\x00\x00\x00\x00.LVT"),
    );

    try std.testing.expectEqual(@as(i16, 16384), try angleFromDegrees(360));
    try std.testing.expectEqual(@as(i16, -4096), try angleFromDegrees(-90));
}

test "Miner text resources discard invalid player records before selecting spawn" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD2/OUTLAWS/OLGEO.LAB",
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);
    var level = try Level.parse(a, try archive.find("MINER.LVT", 0));
    defer level.deinit();
    var objects = try Objects.parse(a, try archive.find("MINER.OBT", 0));
    defer objects.deinit();
    const starts = try objects.playerStarts(a, &level, 0x100000);
    defer a.free(starts);
    const spawn = try Spawn.fromStart(&level, starts[starts.len - 1]);

    try std.testing.expectEqual(@as(u32, 0x1ec40), level.sectors[spawn.sector].id);
    try std.testing.expectEqual(Vec3{ .x = 27.66, .y = 0, .z = 65.13 }, spawn.position);
}

test "Dry Gulch network start markers use its mode and sector records" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);
    var level = try Level.parse(a, try archive.find("DRYGULCH.LVB", 0x4c565446));
    defer level.deinit();
    var objects = try Objects.parse(a, try archive.find("DRYGULCH.OBB", 0x4f425446));
    defer objects.deinit();

    for ([_]u32{ 1, 3, 5, 6 }) |mode| {
        const starts = try objects.multiplayerStarts(a, &level, mode, 0x200000, false);
        defer a.free(starts);
        try std.testing.expect(starts.len != 0);
        for (starts) |record| _ = try Spawn.fromStart(&level, record);
    }
}

test "all shipped binary maps preserve both flag words and valid adjoin pairs" {
    const a = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(data);
    const archive = try @import("lab.zig").Archive.init(data);
    var entries = archive.iterator();
    var names = std.StringHashMap(void).init(a);
    defer names.deinit();
    var sectors: usize = 0;
    var walls: usize = 0;
    var primary: [2]u32 = .{ 0, 0 };
    var secondary: [2]u32 = .{ 0, 0 };

    while (try entries.next()) |entry| {
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".lvb")) continue;

        if ((try names.getOrPut(entry.name)).found_existing) continue;

        errdefer std.debug.print("binary map validation failed: {s}\n", .{entry.name});

        var level = try Level.parse(a, entry.bytes);
        defer level.deinit();

        for (level.sectors) |sector| {
            sectors += 1;
            primary[0] |= sector.flags;
            secondary[0] |= sector.flags2;

            for (sector.walls) |wall| {
                walls += 1;
                primary[1] |= wall.flags;
                secondary[1] |= wall.flags2;
            }
        }

        const wall = &level.sectors[0].walls[0];

        wall.adjoin = -1;
        wall.dadjoin = 0;
        wall.dmirror = 0;

        try std.testing.expectError(error.InvalidDoubleAdjoin, level.validate());
    }

    try std.testing.expectEqual(@as(usize, 10), names.count());
    try std.testing.expectEqual(@as(usize, 2978), sectors);
    try std.testing.expectEqual(@as(usize, 27891), walls);
    try std.testing.expectEqual([2]u32{ 0xefb417c5, 0x0016efed }, primary);
    try std.testing.expectEqual([2]u32{ 0x80000000, 0 }, secondary);
}
