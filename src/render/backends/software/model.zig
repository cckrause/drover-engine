//! Drawing geometry models in the software renderer: clipping, projection
//! and the triangle and quad fills.
//!
//! Unlike a sprite, a model's radius can cross the near plane while its
//! centre is behind it, so the clip tests are per vertex. The order of the
//! arithmetic is deliberate - including an approximate sine of zero - and
//! changing it moves vertices by a pixel.

const std = @import("std");

const asset = @import("../../../assets/model.zig");
const texture = @import("../../../assets/texture.zig");
const camera = @import("camera.zig");
const m = @import("math.zig");
const planes = @import("planes.zig");
const walls = @import("walls.zig");
const Vec3 = @import("../../../assets/level.zig").Vec3;

pub const Pose = struct { position: Vec3, yaw: i16, pitch: i16 = 0, roll: i16 = 0 };

pub const Context = struct {
    view: *const camera.View,
    angles: *const camera.Angles,
    pixels: []u8,
    window: planes.ClipWindow,
    depth: []const i16,
    lighting: walls.Lighting,
};

pub const Vertex = struct { position: Vec3, uv: asset.Vec2 = .{ .x = 0, .y = 0 }, shade: f32 = 0 };

pub const Projected = struct {
    x: i32,
    y: i32,
    z: f32,
    uv: asset.Vec2 = .{ .x = 0, .y = 0 },
    shade: f32 = 0,
};

const Edge = struct {
    next: usize = 0,
    remaining: i32 = 0,
    y: f32 = 0,
    row: i32 = 0,
    dy: f32 = 0,
    z: f32 = 0,
    dz: f32 = 0,
    u: f32 = 0,
    v: f32 = 0,
    du: f32 = 0,
    dv: f32 = 0,
    shade: f32 = 0,
    ds: f32 = 0,

    fn start(
        self: *Edge,
        vertices: []const Projected,
        from: usize,
        last: usize,
        forward: bool,
        right: i32,
        mode: u32,
    ) bool {
        var index = from;
        var next: usize = undefined;

        while (true) {
            if (index == last) return false;

            next = if (forward) (index + 1) % vertices.len else (index + vertices.len - 1) % vertices.len;
            self.remaining = vertices[next].x - vertices[index].x;

            if (vertices[next].x == right) self.remaining += 1;

            if (self.remaining > 0) break;

            index = next;
        }

        const a = vertices[index];
        const b = vertices[next];

        self.next = next;
        self.row = a.y;
        self.y = @floatFromInt(a.y);
        self.z = a.z;

        const length: f32 = @floatFromInt(self.remaining);
        const inverse = m.div(1, length);

        self.dy = if (mode == 0) m.div(
            @floatFromInt(b.y - a.y),
            length,
        ) else m.mul(@floatFromInt(b.y - a.y), inverse);

        self.dz = if (mode == 0 or !forward) m.div(
            m.sub(b.z, a.z),
            length,
        ) else m.mul(m.sub(b.z, a.z), inverse);

        self.u = a.uv.x;
        self.v = a.uv.y;
        self.du = m.mul(m.sub(b.uv.x, self.u), inverse);
        self.dv = m.mul(m.sub(b.uv.y, self.v), inverse);
        self.shade = @max(@min(a.shade, 31), 0);
        self.ds = m.mul(m.sub(b.shade, self.shade), inverse);

        return true;
    }

    fn advance(self: *Edge, mode: u32) void {
        self.y = m.add(self.dy, self.y);
        self.row = m.integer(m.add(self.y, 0.5));

        if (mode & 2 != 0) {
            self.u = m.add(self.du, self.u);
            self.v = m.add(self.dv, self.v);
        }

        if (mode & 1 != 0) self.shade = @max(@min(m.add(self.ds, self.shade), 31), 0);
    }
};

pub fn eligible(view: *const camera.View, point: Vec3, radius: f32, left: i32, right: i32) bool {
    const far = m.add(point.z, radius);
    if (far < 1 or m.add(radius, point.x) < -far or far < m.sub(point.x, radius)) return false;

    if (m.sub(point.z, radius) > 0) {
        const lo = view.center_x +% m.integer(
            m.add(m.mul(m.div(view.focal, point.z), m.sub(point.x, radius)), 0.5),
        );

        const hi = view.center_x +% m.integer(
            m.add(m.mul(m.div(m.add(radius, point.x), point.z), view.focal), 0.5),
        );

        if (right < lo or hi < left or view.right < lo or hi < view.left) return false;
    }

    return true;
}

pub fn rotation(angles: *const camera.Angles, pose: Pose) [9]f32 {
    const p = angles.sinCos(pose.pitch);
    const y = angles.sinCos(pose.yaw);
    const r = angles.sinCos(pose.roll);
    const a = m.mul(r.sin, p.sin);
    const b = m.mul(r.cos, p.sin);

    return .{
        m.add(m.mul(y.sin, a), m.mul(r.cos, y.cos)),
        m.add(m.mul(-r.sin, y.cos), m.mul(y.sin, b)),
        m.mul(p.cos, y.sin),
        m.mul(p.cos, r.sin),
        m.mul(r.cos, p.cos),
        -p.sin,
        m.add(m.mul(y.cos, a), m.mul(-r.cos, y.sin)),
        m.add(m.mul(r.sin, y.sin), m.mul(y.cos, b)),
        m.mul(y.cos, p.cos),
    };
}

pub fn multiply(a: [9]f32, b: [9]f32) [9]f32 {
    return .{
        m.add(m.add(m.mul(b[6], a[6]), m.mul(b[3], a[3])), m.mul(b[0], a[0])),
        m.add(m.add(m.mul(b[3], a[4]), m.mul(b[6], a[7])), m.mul(b[0], a[1])),
        m.add(m.add(m.mul(a[5], b[3]), m.mul(b[6], a[8])), m.mul(b[0], a[2])),
        m.add(m.add(m.mul(b[1], a[0]), m.mul(a[3], b[4])), m.mul(a[6], b[7])),
        m.add(m.add(m.mul(b[4], a[4]), m.mul(b[7], a[7])), m.mul(b[1], a[1])),
        m.add(m.add(m.mul(a[5], b[4]), m.mul(b[1], a[2])), m.mul(b[7], a[8])),
        m.add(m.add(m.mul(b[2], a[0]), m.mul(b[5], a[3])), m.mul(a[6], b[8])),
        m.add(m.add(m.mul(b[5], a[4]), m.mul(a[1], b[2])), m.mul(a[7], b[8])),
        m.add(m.add(m.mul(b[8], a[8]), m.mul(b[2], a[2])), m.mul(b[5], a[5])),
    };
}

pub fn transform(v: Vec3, matrix: [9]f32, offset: Vec3) Vec3 {
    return .{
        .x = m.add(
            m.add(m.add(m.mul(v.y, matrix[3]), m.mul(v.z, matrix[6])), m.mul(matrix[0], v.x)),
            offset.x,
        ),
        .y = m.add(
            m.add(m.add(m.mul(matrix[1], v.x), m.mul(v.y, matrix[4])), m.mul(v.z, matrix[7])),
            offset.y,
        ),
        .z = m.add(
            m.add(m.add(m.mul(matrix[2], v.x), m.mul(v.z, matrix[8])), m.mul(v.y, matrix[5])),
            offset.z,
        ),
    };
}

pub fn clip(view: *const camera.View, vertices: []const Vertex, output: *[32]Vertex) !usize {
    if (vertices.len > 32) return error.ModelPolygonTooLarge;

    var buffers: [2][32]Vertex = undefined;

    @memcpy(buffers[0][0..vertices.len], vertices);

    var count = vertices.len;
    var current: usize = 0;
    const limits = [_]f32{ 1, -1, 1, view.model_clip_top, view.model_clip_bottom };

    for (0..5) |pass| {
        if (count < 3) return 0;

        const src = buffers[current][0..count];

        current ^= 1;

        var n: usize = 0;
        var previous = src[src.len - 1];

        for (src) |next| {
            const a = previous.position;
            const b = next.position;
            const av = if (pass == 0) a.z else if (pass < 3) a.x else a.y;
            const bv = if (pass == 0) b.z else if (pass < 3) b.x else b.y;
            const ab = if (pass == 0) @as(f32, 1) else m.mul(a.z, limits[pass]);
            const bb = if (pass == 0) @as(f32, 1) else m.mul(b.z, limits[pass]);
            const lower = pass == 0 or pass == 1 or pass == 3;
            const ai = if (lower) av >= ab else av <= ab;
            const bi = if (lower) bv >= bb else bv <= bb;

            if (ai or bi) {
                if (ai) {
                    if (n == 32) return error.ModelPolygonTooLarge;
                    buffers[current][n] = previous;
                    n += 1;
                }

                if (av != ab and bv != bb and (!ai or !bi)) {
                    var v: Vertex = undefined;
                    var t: f32 = undefined;

                    if (pass == 0) {
                        t = m.div(m.sub(1, a.z), m.sub(b.z, a.z));
                        v.position = .{
                            .x = m.add(m.mul(m.sub(b.x, a.x), t), a.x),
                            .y = m.add(m.mul(m.sub(b.y, a.y), t), a.y),
                            .z = 1,
                        };
                    } else {
                        const numerator = m.sub(m.mul(b.z, av), m.mul(a.z, bv));
                        const denominator = if (pass == 1) -m.add(
                            m.sub(b.z, a.z),
                            m.sub(bv, av),
                        ) else m.sub(m.mul(m.sub(b.z, a.z), limits[pass]), m.sub(bv, av));

                        const z = if (denominator != 0) m.div(
                            numerator,
                            denominator,
                        ) else numerator;

                        const coordinate = m.mul(limits[pass], z);

                        t = if (@abs(
                            m.sub(b.z, a.z),
                        ) <= @abs(
                            m.sub(bv, av),
                        )) m.div(
                            m.sub(coordinate, av),
                            m.sub(bv, av),
                        ) else m.div(m.sub(z, a.z), m.sub(b.z, a.z));

                        v.position = if (pass < 3) .{
                            .x = coordinate,
                            .y = m.add(m.mul(m.sub(b.y, a.y), t), a.y),
                            .z = z,
                        } else .{
                            .x = m.add(m.mul(m.sub(b.x, a.x), t), a.x),
                            .y = coordinate,
                            .z = z,
                        };
                    }

                    v.uv = .{
                        .x = m.add(m.mul(m.sub(next.uv.x, previous.uv.x), t), previous.uv.x),
                        .y = m.add(m.mul(m.sub(next.uv.y, previous.uv.y), t), previous.uv.y),
                    };

                    v.shade = m.add(m.mul(m.sub(next.shade, previous.shade), t), previous.shade);
                    if (n == 32) return error.ModelPolygonTooLarge;

                    buffers[current][n] = v;
                    n += 1;
                }
            }

            previous = next;
        }

        count = n;
    }

    @memcpy(output[0..count], buffers[current][0..count]);

    return count;
}

pub fn project(view: *const camera.View, vertex: Vertex) Projected {
    const scale = m.div(view.focal, vertex.position.z);

    return .{
        .x = view.center_x +% m.integer(m.add(m.mul(scale, vertex.position.x), 0.5)),
        .y = view.horizon +% m.integer(m.add(m.mul(vertex.position.y, scale), 0.5)),
        .z = vertex.position.z,
        .uv = vertex.uv,
        .shade = vertex.shade,
    };
}

pub fn raster(
    ctx: Context,
    vertices: []const Projected,
    mode: u32,
    color: u8,
    tex: ?*const texture.Texture,
    table: ?*const [256]u8,
) !void {
    if (mode > 3) return error.UnsupportedModelShading;
    if (vertices.len < 3) return;

    var first: usize = 0;
    var last: usize = 0;
    var min_y = vertices[0].y;
    var max_y = min_y;

    for (vertices, 0..) |v, i| {
        if (v.x < vertices[first].x) first = i;
        if (v.x > vertices[last].x) last = i;
        min_y = @min(min_y, v.y);
        max_y = @max(max_y, v.y);
    }

    const w = ctx.window;
    if (vertices[first].x >= vertices[last].x or min_y > w.bottom or max_y < w.top) return;

    var top: Edge = .{};
    var bottom: Edge = .{};
    if (!top.start(
        vertices,
        first,
        last,
        true,
        w.right,
        mode,
    ) or !bottom.start(vertices, first, last, false, w.right, mode)) return;

    var x = vertices[first].x;

    while (true) {
        if (x >= w.left and x <= w.right) {
            const column: usize = @intCast(x);
            const z = m.mul(m.mul(m.add(top.z, bottom.z), 0.25), 2);

            if (z < m.mul(
                @floatFromInt(@as(i32, ctx.depth[column]) << 12),
                0x1p-16,
            ) and top.row <= w.bottom and bottom.row >= w.top) {
                const y1 = @max(top.row, w.top_clip[column]);
                const y2 = @min(bottom.row, w.bottom_clip[column]);

                if (y1 <= y2) {
                    const count: f32 = @floatFromInt(bottom.row - top.row + 1);
                    const inverse = m.div(1, count);
                    const skip: f32 = @floatFromInt(bottom.row - y2);
                    var du: i32 = 0;
                    var dv: i32 = 0;
                    var u: i32 = 0;
                    var v: i32 = 0;

                    if (mode & 2 != 0) {
                        const t = tex orelse return error.MissingModelTexture;

                        top.u = clampUv(top.u, t.width);
                        bottom.u = clampUv(bottom.u, t.width);
                        top.v = clampUv(top.v, t.height);
                        bottom.v = clampUv(bottom.v, t.height);
                        du = m.fixed(m.mul(m.sub(top.u, bottom.u), inverse));
                        dv = m.fixed(m.mul(m.sub(top.v, bottom.v), inverse));
                        u = m.fixed(
                            m.add(m.mul(m.mul(@floatFromInt(du), 0x1p-16), skip), bottom.u),
                        );

                        v = m.fixed(
                            m.add(m.mul(m.mul(@floatFromInt(dv), 0x1p-16), skip), bottom.v),
                        );
                    }

                    const ds = if (mode == 1) m.fixed(
                        m.div(m.sub(top.shade, bottom.shade), count),
                    ) else m.fixed(m.mul(m.sub(top.shade, bottom.shade), inverse));

                    var shade = m.fixed(
                        m.add(m.mul(m.mul(@floatFromInt(ds), 0x1p-16), skip), bottom.shade),
                    );

                    var dither = ((x ^ y2) & 1) - 1;
                    var y = y2;

                    while (y >= y1) : (y -= 1) {
                        var pixel = color;

                        if (mode & 2 != 0) {
                            const t = tex.?;
                            const offset = (u >> 16) * (@as(i32, 1) << t.height_shift) + (v >> 16);
                            if (offset < 0 or offset >= t.pixels.len) return error.InvalidModelTexel;

                            pixel = t.pixels[@intCast(offset)];
                            u +%= du;
                            v +%= dv;
                        }

                        if (mode & 1 != 0) {
                            const cmap = ctx.lighting.color_map orelse return error.MissingColorMap;
                            const adjusted = if (dither != 0 and shade -% 0x8000 >= 0) shade -% 0x8000 else shade;
                            const offset = (adjusted >> 16) * 256 + pixel;
                            if (offset < 0 or offset >= cmap.len) return error.InvalidModelShade;

                            pixel = cmap[@intCast(offset)];
                            shade +%= ds;
                            dither = ~dither;
                        } else if (table) |map| pixel = map[pixel];

                        ctx.pixels[@as(usize, @intCast(y * ctx.view.width + x))] = pixel;
                    }
                }
            }
        }

        top.remaining -= 1;

        if (top.remaining < 1) {
            if (!top.start(vertices, top.next, last, true, w.right, mode)) return;
        } else {
            top.advance(mode);
            top.z = m.add(top.dz, top.z);
            bottom.z = m.add(bottom.dz, bottom.z);
        }

        bottom.remaining -= 1;

        if (bottom.remaining < 1) {
            if (!bottom.start(vertices, bottom.next, last, false, w.right, mode)) return;
        } else bottom.advance(mode);

        x += 1;
        if (x > w.right) return;
    }
}

pub fn draw(ctx: Context, model: *const asset.Model, pose: Pose) !void {
    if (model.vertices.len > 500 or model.polygons.len > 400) return error.ModelLimitsExceeded;
    if (model.flags == 4) return error.UnsupportedModelVertexMode;

    const view = ctx.view;
    const camera_matrix = [9]f32{
        view.cos_yaw,
        0,
        view.negative_sin_yaw,
        0,
        1,
        0,
        view.sin_yaw,
        0,
        view.cos_yaw,
    };

    const local = Vec3{
        .x = m.sub(pose.position.x, view.x),
        .y = -m.sub(pose.position.y, view.y),
        .z = m.sub(pose.position.z, view.z),
    };

    const offset = Vec3{
        .x = m.add(
            m.add(m.mul(camera_matrix[0], local.x), m.mul(camera_matrix[6], local.z)),
            m.mul(camera_matrix[3], local.y),
        ),
        .y = m.add(
            m.add(m.mul(camera_matrix[4], local.y), m.mul(camera_matrix[7], local.z)),
            m.mul(camera_matrix[1], local.x),
        ),
        .z = m.add(
            m.add(m.mul(camera_matrix[2], local.x), m.mul(camera_matrix[5], local.y)),
            m.mul(camera_matrix[8], local.z),
        ),
    };

    const matrix = multiply(camera_matrix, rotation(ctx.angles, pose));
    var points: [500]Vec3 = undefined;

    for (model.vertices, points[0..model.vertices.len]) |vertex, *point| point.* = transform(
        vertex,
        matrix,
        offset,
    );

    var normals: [400]Vec3 = undefined;
    var depths: [400]f32 = undefined;
    var order: [400]usize = undefined;
    var count: usize = 0;

    for (model.polygons, model.face_normals, 0..) |polygon, endpoint, i| {
        const point = points[polygon.indices[1]];
        normals[i] = subtract(transform(endpoint, matrix, offset), point);

        if (dot(normals[i], .{ .x = -point.x, .y = -point.y, .z = -point.z }) < 0) continue;

        var sum: f32 = 0;

        for (polygon.indices[0..polygon.count]) |index| sum = m.add(points[index].z, sum);

        depths[i] = m.div(sum, @floatFromInt(polygon.count));
        order[count] = i;
        count += 1;
    }

    sort(order[0..count], &depths);

    const directions = lights(view);
    var shades: [500]f32 = undefined;

    if (model.flags & 2 != 0) {
        if (model.vertex_normals.len != model.vertices.len) return error.MissingModelVertexNormals;

        for (model.vertex_normals, 0..) |normal, i| shades[i] = try vertexShade(
            ctx,
            points[i],
            transform(normal, matrix, offset),
            directions,
        );
    }

    for (order[0..count]) |index| {
        const polygon = model.polygons[index];
        if (polygon.mode > 3) return error.UnsupportedModelShading;

        var vertices: [4]Vertex = undefined;

        for (polygon.indices[0..polygon.count], 0..) |vertex_index, corner| vertices[corner] = .{
            .position = points[vertex_index],
            .uv = polygon.uv[corner],
            .shade = if (polygon.mode & 1 != 0) shades[vertex_index] else 0,
        };

        var clipped: [32]Vertex = undefined;
        const n = try clip(view, vertices[0..polygon.count], &clipped);

        if (n < 3) continue;

        var projected: [32]Projected = undefined;

        for (clipped[0..n], projected[0..n]) |vertex, *out| out.* = project(view, vertex);

        const table = if (polygon.mode & 1 == 0) try faceTable(
            ctx,
            normals[index],
            depths[index],
            polygon.mode == 2,
            directions,
        ) else null;

        try raster(
            ctx,
            projected[0..n],
            polygon.mode,
            @truncate(polygon.color),
            if (polygon.texture) |t| &model.textures[t] else null,
            table,
        );
    }
}

fn subtract(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = m.sub(a.x, b.x), .y = m.sub(a.y, b.y), .z = m.sub(a.z, b.z) };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return m.add(m.add(m.mul(b.x, a.x), m.mul(b.y, a.y)), m.mul(b.z, a.z));
}

fn lights(view: *const camera.View) [6]Vec3 {
    const origin = [_]f32{ view.translation_x, -view.y, view.translation_z };
    const bases = [_]Vec3{
        .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 1, .y = 0, .z = 0 },
    };

    var result: [6]Vec3 = undefined;

    for (&result, 0..) |*out, index| {
        const v = bases[index % bases.len];
        const x: f32 = @floatCast(
            @as(f64, v.z) * view.sin_yaw + @as(f64, v.x) * view.cos_yaw + view.translation_x,
        );

        const y: f32 = @floatCast(@as(f64, v.y) - view.y);
        const z: f32 = @floatCast(
            @as(f64, v.z) * view.cos_yaw - @as(f64, v.x) * view.sin_yaw + view.translation_z,
        );

        const dx: f32 = @floatCast(-(@as(f64, x) - origin[0]));
        const dy: f32 = @floatCast(-(@as(f64, y) - origin[1]));
        const dz: f32 = @floatCast(-(@as(f64, z) - origin[2]));
        var length: f32 = 0;

        if (@abs(dx) != 0) length = @floatCast(@as(f64, dx) * dx);

        if (@abs(dy) != 0) length = @floatCast(@as(f64, dy) * dy + length);

        if (@abs(dz) != 0) length = @floatCast(@as(f64, dz) * dz + length);

        const root: f32 = @floatCast(@sqrt(@as(f64, length)));
        const inverse: f32 = if (root > 0) @floatCast(1.0 / @as(f64, root)) else 0;

        out.* = .{
            .x = @floatCast(@as(f64, dx) * inverse),
            .y = @floatCast(@as(f64, dy) * inverse),
            .z = @floatCast(@as(f64, dz) * inverse),
        };
    }

    return result;
}

fn faceTable(
    ctx: Context,
    normal: Vec3,
    distance_in: f32,
    textured: bool,
    directions: [6]Vec3,
) !?*const [256]u8 {
    const l = ctx.lighting;
    const cmap = l.color_map orelse return null;
    if (cmap.len < 8192) return error.InvalidColorMap;

    const ambient = l.ambient +% (if (textured) l.ambient_bias else @as(i32, 0));
    if (ambient > 30) return null;

    const distance: f32 = if (distance_in <= 0) 0 else distance_in;
    var sum: f32 = 0;

    for (directions) |direction| {
        const cosine = dot(normal, direction);
        if (cosine > 0) sum = m.add(m.mul(31, cosine), sum);
    }

    var light = m.integer(m.mul(m.mul(@floatFromInt(l.ambient << 11), 0x1p-16), sum));
    if (light > 30) return if (textured) null else cmap[0..256];

    if (l.force_depth != 0 or (!textured and l.depth_bias < 31) or (l.depth_map != null and l.depth_strength != 0)) {
        const dmap = l.depth_map orelse return error.MissingDepthMap;
        const index: usize = @intCast(@min(m.fixed(distance) >> 14, 127));
        const candidate = ((l.depth_strength -% @as(i32, dmap[index])) -% l.depth_bias) +% 31;
        if (candidate > 0) light +%= candidate;
    }

    light = @max(light, ambient);
    const fixed = m.fixed(distance);

    light -%= (fixed >> 20) +% (fixed >> 21);
    light = @max(light, l.ambient_min);
    if (light > 30) return if (textured) null else cmap[0..256];

    light = @max(light, 0);

    return cmap[@as(usize, @intCast(31 - light)) * 256 ..][0..256];
}

fn vertexShade(ctx: Context, point: Vec3, normal_endpoint: Vec3, directions: [6]Vec3) !f32 {
    const l = ctx.lighting;
    if (l.ambient >= 31) return 0;

    var sum: i32 = 0;

    for (directions) |direction| {
        const end = Vec3{
            .x = m.add(direction.x, point.x),
            .y = m.add(direction.y, point.y),
            .z = m.add(direction.z, point.z),
        };

        const cosine = dot(subtract(normal_endpoint, point), subtract(end, point));

        if (cosine > 0) sum +%= m.integer(m.mul(31, cosine));
    }

    var light: f32 = @floatFromInt(
        m.integer(m.mul(m.mul(@floatFromInt(l.ambient << 11), 0x1p-16), @floatFromInt(sum))),
    );

    const distance: f32 = if (m.unsignedBits(point.z) > 0x80000000) 0 else point.z;

    if (l.force_depth != 0) {
        const dmap = l.depth_map orelse return error.MissingDepthMap;
        const index: usize = @intCast(@min(m.fixed(distance) >> 14, 127));
        const candidate = ((31 -% @as(i32, dmap[index])) -% l.depth_bias) *% 65536;
        if (candidate > 0) light = m.add(m.mul(@floatFromInt(candidate), 0x1p-16), light);
    }

    light = @max(light, @as(f32, @floatFromInt(l.ambient)));
    light = m.sub(
        m.sub(light, m.mul(m.mul(distance, 0x1p-21), 2)),
        m.mul(m.mul(distance, 0x1p-22), 2),
    );

    light = @max(light, @as(f32, @floatFromInt(l.ambient_min)));
    light = @max(@min(light, 31), 0);

    return m.sub(31, light);
}

fn clampUv(value: f32, size: usize) f32 {
    if (m.unsignedBits(value) > 0x80000000) return 0;
    if (value >= @as(f32, @floatFromInt(size))) return @floatFromInt(size - 1);

    return value;
}

fn sort(entries: []usize, depths: []const f32) void {
    if (entries.len < 2) return;
    if (entries.len <= 8) {
        var last = entries.len - 1;

        while (last != 0) : (last -= 1) {
            var greatest: usize = 0;

            for (1..last + 1) |i| if (m.integer(
                m.sub(depths[entries[greatest]], depths[entries[i]]),
            ) > 0) {
                greatest = i;
            };

            std.mem.swap(usize, &entries[greatest], &entries[last]);
        }

        return;
    }

    std.mem.swap(usize, &entries[entries.len / 2], &entries[0]);

    var lo: usize = 0;
    var hi = entries.len;

    while (true) {
        lo += 1;

        while (lo < entries.len and m.integer(
            m.sub(depths[entries[0]], depths[entries[lo]]),
        ) <= 0) lo += 1;

        hi -= 1;

        while (hi > 0 and m.integer(m.sub(depths[entries[0]], depths[entries[hi]])) >= 0) hi -= 1;

        if (lo > hi) break;

        std.mem.swap(usize, &entries[lo], &entries[hi]);
    }

    std.mem.swap(usize, &entries[0], &entries[hi]);
    sort(entries[0..hi], depths);
    sort(entries[lo..], depths);
}

test {
    _ = @import("model_test.zig");
}
