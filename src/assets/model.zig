//! 3DO text models: vertices, normals and polygons for the few objects
//! drawn as geometry rather than sprites.
//!
//! Stored normals are endpoints, not directions. Loaded counts are tracked
//! separately from the capacities in the header, which are larger. Triangles
//! take their texture coordinates from the texture width for both axes,
//! quads from width and height. A model whose texture is missing is an
//! error here - there is no substitute texture.

const std = @import("std");
const lab = @import("lab.zig");
const texture = @import("texture.zig");
pub const Vec3 = @import("level.zig").Vec3;

const Words = std.mem.TokenIterator(u8, .any);

pub const Vec2 = struct { x: f32, y: f32 };

pub const Polygon = struct {
    indices: [4]u32 = @splat(0),
    count: u32,
    mode: u32 = 0,
    color: u32,
    texture: ?usize,
    uv: [4]Vec2 = @splat(.{ .x = 0, .y = 0 }),
};

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    vertices: []Vec3,
    polygons: []Polygon,
    face_normals: []Vec3,
    vertex_normals: []Vec3,
    textures: []texture.Texture,
    flags: u32,
    radius: f32,
    sort_mode: u32 = 0,

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, archives: []const lab.Archive) !Model {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var lines = Lines{ .bytes = bytes };
        var header = words(try lines.required());
        try expect(&header, "3DO");
        if (!std.mem.eql(u8, try token(&header), "2.0")) return error.UnsupportedModelVersion;
        _ = try lines.value("3DONAME");
        const objects = try lines.count("OBJECTS", 500);
        if (objects != 1) return error.UnsupportedMultiObjectModel;
        const vertex_capacity = try lines.count("VERTICES", 500);
        const polygon_capacity = try lines.count("POLYGONS", 400);
        _ = try lines.value("PALETTE");
        const texture_count = try lines.count("TEXTURES", 500);
        const textures = try a.alloc(texture.Texture, texture_count);
        for (textures) |*destination| {
            const name = try lines.value("TEXTURE:");
            destination.* = try loadTexture(a, archives, name);
        }
        const object_name = try lines.value("OBJECT");
        if (object_name.len < 2 or object_name[0] != '"') return error.InvalidModelObject;
        const texture_index = try integer(try lines.value("TEXTURE"));
        if (texture_index < -1 or texture_index >= @as(i32, @intCast(texture_count))) return error.InvalidModelTexture;
        const selected: ?usize = if (texture_index == -1) null else @intCast(texture_index);
        const vertex_count = try lines.count("VERTICES", vertex_capacity);
        const vertices = try a.alloc(Vec3, vertex_count);
        for (vertices) |*vertex| {
            var row = words(try lines.required());
            try ordinal(&row);
            vertex.* = .{ .x = try number(try token(&row)), .y = try number(try token(&row)), .z = try number(try token(&row)) };
        }
        var polygon_header = words(try lines.required());
        const shape = try token(&polygon_header);
        const arity: u32 = if (std.mem.eql(u8, shape, "TRIANGLES")) 3 else if (std.mem.eql(u8, shape, "QUADS")) 4 else return error.InvalidModelPolygons;
        const polygon_count = try bounded(try token(&polygon_header), polygon_capacity);
        const polygons = try a.alloc(Polygon, polygon_count);
        var flags: u32 = 1;
        for (polygons) |*polygon| {
            var row = words(try lines.required());
            try ordinal(&row);
            polygon.* = .{ .count = arity, .color = 0, .texture = selected };
            for (polygon.indices[0..arity]) |*index| {
                index.* = try bounded(try token(&row), vertex_count);
                if (index.* >= vertex_count) return error.InvalidModelVertexIndex;
            }
            const raw_color = try integer(try token(&row));
            if (raw_color < 0 or raw_color > 255) return error.InvalidModelColor;
            const mode = try token(&row);
            const material = try token(&row);
            polygon.color = if (std.ascii.eqlIgnoreCase(material, "BLACK")) 0x27 else if (std.ascii.eqlIgnoreCase(material, "DYNBROWN")) 0xd8 else if (std.ascii.eqlIgnoreCase(material, "KNIFEBROWN")) 0x99 else if (std.ascii.eqlIgnoreCase(material, "GREY")) 0x20 else @intCast(raw_color);
            if (std.ascii.eqlIgnoreCase(mode, "FLAT")) {
                polygon.mode = 0;
            } else if (std.ascii.eqlIgnoreCase(mode, "VERTEX")) {
                flags = 4;
            } else if (std.ascii.eqlIgnoreCase(mode, "TEXTURE")) {
                polygon.mode = 2;
            } else if (std.ascii.eqlIgnoreCase(mode, "GOURAUD")) {
                polygon.mode = 1;
                flags |= 2;
            } else if (std.ascii.eqlIgnoreCase(mode, "GOURTEX")) {
                polygon.mode = 3;
                flags |= 2;
            } else if (std.ascii.eqlIgnoreCase(mode, "PLANE")) {
                polygon.mode = 4;
            } else return error.UnsupportedModelShading;
            if ((polygon.mode == 2 or polygon.mode == 3 or polygon.mode == 4) and selected == null) return error.MissingModelTexture;
        }
        if (selected) |texture_slot| {
            var uv_header = words(try lines.required());
            try expect(&uv_header, "TEXTURE");
            try expect(&uv_header, "VERTICES");
            const uv_count = try bounded(try token(&uv_header), 500);
            const coords = try a.alloc(Vec2, uv_count);
            for (coords) |*coordinate| {
                var row = words(try lines.required());
                try ordinal(&row);
                coordinate.* = .{ .x = clampUv(try number(try token(&row))), .y = clampUv(try number(try token(&row))) };
            }
            var uv_polygons = words(try lines.required());
            try expect(&uv_polygons, "TEXTURE");
            try expect(&uv_polygons, shape);
            const uv_polygon_count = try bounded(try token(&uv_polygons), polygon_count);
            if (uv_polygon_count != polygon_count) return error.InvalidModelTexturePolygons;
            const width: f64 = @floatFromInt(textures[texture_slot].width);
            const height: f64 = if (arity == 3) width else @floatFromInt(textures[texture_slot].height);
            for (polygons) |*polygon| {
                var row = words(try lines.required());
                try ordinal(&row);
                for (polygon.uv[0..arity]) |*coordinate| {
                    const index = try bounded(try token(&row), uv_count);
                    if (index >= uv_count) return error.InvalidModelTextureVertex;
                    coordinate.* = .{ .x = f(width * coords[index].x), .y = f(height * coords[index].y) };
                }
            }
        }
        if (try lines.next() != null) return error.UnexpectedModelData;
        const normals = try a.alloc(Vec3, polygons.len);
        for (polygons, normals) |polygon, *normal| normal.* = faceNormal(vertices[polygon.indices[1]], vertices[polygon.indices[2]], vertices[polygon.indices[0]]);
        const vertex_normals = try a.alloc(Vec3, if (flags & 2 != 0) vertices.len else 0);
        for (vertex_normals, 0..) |*normal, index| normal.* = vertexNormal(vertices, polygons, normals, index);
        return .{ .arena = arena, .vertices = vertices, .polygons = polygons, .face_normals = normals, .vertex_normals = vertex_normals, .textures = textures, .flags = flags, .radius = boundingRadius(vertices) };
    }
};

const Lines = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn next(self: *Lines) !?[]const u8 {
        while (self.cursor < self.bytes.len) {
            const begin = self.cursor;
            const end = if (std.mem.indexOfScalarPos(u8, self.bytes, begin, '\n')) |index| index else self.bytes.len;
            self.cursor = @min(end + 1, self.bytes.len);
            const line = std.mem.trim(u8, self.bytes[begin..end], " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (end - begin >= 127 or std.mem.indexOfScalar(u8, line, 0) != null) return error.InvalidModelLine;
            return line;
        }
        return null;
    }

    fn required(self: *Lines) ![]const u8 {
        return try self.next() orelse error.TruncatedModel;
    }

    fn value(self: *Lines, name: []const u8) ![]const u8 {
        var row = words(try self.required());
        try expect(&row, name);
        return token(&row);
    }

    fn count(self: *Lines, name: []const u8, maximum: usize) !u32 {
        return bounded(try self.value(name), maximum);
    }
};

pub fn boundingRadius(vertices: []const Vec3) f32 {
    var radius: f32 = 0;
    for (vertices) |point| {
        const distance = if (@abs(point.x) == 0 and @abs(point.y) == 0) point.z else if (@abs(point.x) == 0 and @abs(point.z) == 0) point.y else if (@abs(point.y) == 0 and @abs(point.z) == 0) point.x else f(@sqrt(@as(f64, f(@as(f64, point.z) * point.z + @as(f64, point.y) * point.y + @as(f64, point.x) * point.x))));
        if (radius < distance) radius = distance;
    }
    return radius;
}

pub fn clampUv(value: f32) f32 {
    var bits: u32 = @bitCast(value);
    if (bits > 0x80000000) bits = 0;
    if (@as(i32, @bitCast(bits)) > 0x3f7fffff) bits = 0x3f7ffffe;
    return @bitCast(bits);
}

fn loadTexture(allocator: std.mem.Allocator, archives: []const lab.Archive, name: []const u8) !texture.Texture {
    for (archives) |archive| {
        const data = archive.find(name, 0) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };
        if (!std.ascii.endsWithIgnoreCase(name, ".PCX")) return error.UnsupportedModelTextureFormat;
        return texture.decode(allocator, data);
    }
    return error.UnsupportedSystemDefaultTexture;
}

fn f(value: f64) f32 {
    return @floatCast(value);
}

fn faceNormal(a: Vec3, b: Vec3, c: Vec3) Vec3 {
    const ux = @as(f64, b.x) - a.x;
    const uy = @as(f64, b.y) - a.y;
    const uz = @as(f64, b.z) - a.z;
    const vx = @as(f64, c.x) - a.x;
    const vy = @as(f64, c.y) - a.y;
    const vz: f64 = f(@as(f64, c.z) - a.z);
    const endpoint: Vec3 = .{ .x = f(uz * vy - vz * uy + a.x), .y = f(vz * ux - uz * vx + a.y), .z = f(uy * vx - ux * vy + a.z) };
    const dx = f(@as(f64, endpoint.x) - a.x);
    const dy = f(@as(f64, endpoint.y) - a.y);
    const dz = f(@as(f64, endpoint.z) - a.z);
    const length = f(@sqrt(@as(f64, f((@as(f64, endpoint.z) - a.z) * dz + @as(f64, dy) * dy + @as(f64, dx) * dx))));
    if (length <= 0) return a;
    return .{ .x = f(@as(f64, dx) / length + a.x), .y = f(@as(f64, dy) / length + a.y), .z = f(@as(f64, dz) / length + a.z) };
}

fn vertexNormal(vertices: []const Vec3, polygons: []const Polygon, normals: []const Vec3, index: usize) Vec3 {
    const point = vertices[index];
    var total: Vec3 = .{ .x = 0, .y = 0, .z = 0 };
    var count: u32 = 0;
    for (polygons, normals) |polygon, normal| {
        for (polygon.indices[0..polygon.count]) |vertex| {
            if (vertex != index) continue;
            total.x = f((@as(f64, normal.x) - point.x) + total.x);
            total.y = f((@as(f64, normal.y) - point.y) + total.y);
            total.z = f((@as(f64, normal.z) - point.z) + total.z);
            count += 1;
            break;
        }
    }
    if (count == 0) return point;
    const divisor: f64 = @floatFromInt(count << 16);
    const dx = f(@as(f64, total.x) / divisor);
    const dy = f(@as(f64, total.y) / divisor);
    const dz = f(@as(f64, total.z) / divisor);
    const length = f(@sqrt(@as(f64, f((@as(f64, total.z) / divisor) * dz + @as(f64, dy) * dy + @as(f64, dx) * dx))));
    if (length <= 0) return point;
    return .{ .x = f(@as(f64, dx) / length + point.x), .y = f(@as(f64, dy) / length + point.y), .z = f(@as(f64, dz) / length + point.z) };
}

fn words(line: []const u8) Words {
    return std.mem.tokenizeAny(u8, line, " \t\r");
}

fn token(row: *Words) ![]const u8 {
    return row.next() orelse error.TruncatedModel;
}

fn expect(row: *Words, value: []const u8) !void {
    if (!std.mem.eql(u8, try token(row), value)) return error.InvalidModel;
}

fn integer(value: []const u8) !i32 {
    return std.fmt.parseInt(i32, value, 10) catch return error.InvalidModelInteger;
}

fn bounded(value: []const u8, maximum: usize) !u32 {
    const parsed = try integer(value);
    if (parsed < 0 or parsed > maximum) return error.InvalidModelCount;
    return @intCast(parsed);
}

fn number(value: []const u8) !f32 {
    const parsed = std.fmt.parseFloat(f32, value) catch return error.InvalidModelFloat;
    if (!std.math.isFinite(parsed)) return error.InvalidModelFloat;
    return parsed;
}

fn ordinal(row: *Words) !void {
    const value = try token(row);
    if (value.len < 2 or value[value.len - 1] != ':') return error.InvalidModelOrdinal;
    _ = try integer(value[0 .. value.len - 1]);
}

fn hashWords(hash: *std.crypto.hash.sha2.Sha256, values: []const u32) void {
    for (values) |value| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        hash.update(&bytes);
    }
}

test "3DO exact UV clamp and signed-axis radius quirks" {
    try std.testing.expectEqual(@as(u32, 0x3f7ffffe), @as(u32, @bitCast(clampUv(1))));
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(clampUv(-0.0))));
    try std.testing.expectEqual(@as(f32, 0), clampUv(-0.1));
    try std.testing.expectEqual(@as(f32, 0), boundingRadius(&.{.{ .x = -4, .y = 0, .z = 0 }}));
    try std.testing.expectEqual(@as(f32, 5), boundingRadius(&.{.{ .x = -3, .y = 4, .z = 0 }}));
}

test "3DO validates capacities indices floats and shading before geometry access" {
    const triangle =
        \\3DO 2.0
        \\3DONAME triangle
        \\OBJECTS 1
        \\VERTICES 3
        \\POLYGONS 1
        \\PALETTE DEFAULT.PAL
        \\TEXTURES 0
        \\OBJECT "triangle"
        \\TEXTURE -1
        \\VERTICES 3
        \\9: 0 0 0
        \\4: 0 1 0
        \\2: 1 0 0
        \\TRIANGLES 1
        \\7: 0 1 2 123 FLAT BLACK
        \\
    ;
    const a = std.testing.allocator;
    var valid = try Model.parse(a, triangle, &.{});
    defer valid.deinit();
    try std.testing.expectEqual(@as(u32, 0x27), valid.polygons[0].color);
    try std.testing.expectEqual(@as(f32, 1), valid.vertices[1].y);
    const Case = struct {
        before: []const u8,
        after: []const u8,
        expected: anyerror,
    };
    for ([_]Case{
        .{ .before = "3DO 2.0", .after = "3DO 1.2", .expected = error.UnsupportedModelVersion },
        .{ .before = "OBJECTS 1", .after = "OBJECTS 2", .expected = error.UnsupportedMultiObjectModel },
        .{ .before = "VERTICES 3", .after = "VERTICES 501", .expected = error.InvalidModelCount },
        .{ .before = "9: 0 0 0", .after = "9: nan 0 0", .expected = error.InvalidModelFloat },
        .{ .before = "7: 0 1 2", .after = "7: 0 1 3", .expected = error.InvalidModelVertexIndex },
        .{ .before = "FLAT BLACK", .after = "INVALID BLACK", .expected = error.UnsupportedModelShading },
    }) |case| {
        const bytes = try std.mem.replaceOwned(u8, a, triangle, case.before, case.after);
        defer a.free(bytes);
        try std.testing.expectError(case.expected, Model.parse(a, bytes, &.{}));
    }
    try std.testing.expectError(error.TruncatedModel, Model.parse(a, triangle[0..8], &.{}));
}

test "3DO CD1 models match the reference loader and normal bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var archives: [2]lab.Archive = undefined;
    for ([_][]const u8{ "OLOBJ", "OLTEX" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        archive.* = try lab.Archive.init(bytes);
    }
    const cases = .{
        .{ "GDYNAM.3DO", "c7b4039bbfeda2a549d17625347fcc85ecba02ad59477df46e17fea628a12159" },
        .{ "GKNIFE.3DO", "abe46a2943531abbe4845de5a52a1fdae9263b2f8e4b75a31c21b0b34d61c071" },
        .{ "GGATGUN.3DO", "9676f300f1cc910b0fd6538f5005498773d6e9005c926c7a671c750b87e61fd0" },
        .{ "MINECAR.3DO", "5be70ff0bba5e55f699ff64ea91a33288f23208e66269b1dff58b74f80fbaf8e" },
        .{ "QUADCUBE.3DO", "6b8a8e7de6ca7c6ff83ad99ced807493d9be1b4241d6a04c983c9b5b0e86e9c0" },
    };
    inline for (cases) |case| {
        var model = try Model.parse(std.testing.allocator, try archives[0].find(case[0], 0), &archives);
        defer model.deinit();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashWords(&hash, &.{ @intCast(model.vertices.len), @intCast(model.polygons.len), model.flags, @bitCast(model.radius) });
        for ([_][]const Vec3{ model.vertices, model.face_normals, model.vertex_normals }) |group| for (group) |value| hashWords(&hash, &.{ @bitCast(value.x), @bitCast(value.y), @bitCast(value.z) });
        for (model.polygons) |polygon| {
            hashWords(&hash, &.{ polygon.count, polygon.mode, polygon.color, if (polygon.texture) |index| @intCast(index) else 0xffffffff });
            hashWords(&hash, polygon.indices[0..polygon.count]);
            if (polygon.texture != null) for (polygon.uv[0..polygon.count]) |uv| hashWords(&hash, &.{ @bitCast(uv.x), @bitCast(uv.y) });
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case[1]);
        if (!std.mem.eql(u8, &expected, &digest)) std.debug.print("{s}: {x}\n", .{ case[0], digest });
        try std.testing.expectEqualSlices(u8, &expected, &digest);
    }
    try std.testing.expectError(error.UnsupportedModelVersion, Model.parse(a, try archives[0].find("THEBOX.3DO", 0), &archives));
    try std.testing.expectError(error.UnsupportedSystemDefaultTexture, Model.parse(a, try archives[0].find("CUBE.3DO", 0), &archives));
}
