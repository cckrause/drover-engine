//! Projecting walls into screen space: rejection, clipping and the record
//! the rasteriser reads.
//!
//! Backface and frustum rejection come first, then right then left
//! clipping, and screen bounds are inclusive. X and Z products are cached
//! per vertex pair; the first-vertex branch and the order of the arithmetic
//! matter because the renderer runs in 24-bit precision.

const std = @import("std");

const camera = @import("camera.zig");
const m = @import("math.zig");
pub const Vec2 = camera.Vec2;

pub const ProjectedWall = struct {
    wall_index: usize,
    left: i32,
    right: i32,
    z1: f32,
    z2: f32,
    u1: f32,
    x1: f32,
    x2: f32,
    visible_left: i32,
    visible_right: i32,
    axis: i32,
    slope: f32,
    u_scale: f32,
    world_x1: f32,
    world_z1: f32,
    world_x2: f32,
    world_z2: f32,
};

pub fn transform(view: *const camera.View, vertices: anytype, output: []Vec2) !void {
    if (vertices.len == 0 or vertices.len != output.len) return error.InvalidSectorVertices;

    var xc = m.mul(vertices[0].x, view.cos_yaw);
    var xs = m.mul(vertices[0].x, view.negative_sin_yaw);
    var zs = m.mul(vertices[0].z, view.sin_yaw);
    var zc = m.mul(vertices[0].z, view.cos_yaw);

    output[0] = .{
        .x = m.add(m.add(zs, xc), view.translation_x),
        .z = m.add(m.add(zc, xs), view.translation_z),
    };

    for (vertices[1..], 1..) |vertex, i| {
        if (vertex.x != vertices[i - 1].x) {
            xc = m.mul(vertex.x, view.cos_yaw);
            xs = m.mul(vertex.x, view.negative_sin_yaw);
        }

        if (vertex.z != vertices[i - 1].z) {
            zs = m.mul(vertex.z, view.sin_yaw);
            zc = m.mul(vertex.z, view.cos_yaw);
        }

        output[i] = .{
            .x = m.add(m.add(xc, zs), view.translation_x),
            .z = m.add(m.add(xs, zc), view.translation_z),
        };
    }
}

pub fn project(
    view: *const camera.View,
    first: Vec2,
    second: Vec2,
    wall_length: f32,
    wall_index: usize,
    slopes: bool,
) !?ProjectedWall {
    var x1 = first.x;
    var z1 = first.z;
    var x2 = second.x;
    var z2 = second.z;
    const scaled1 = m.mul(x1, view.cot_half_fov);
    var scaled2 = m.mul(x2, view.cot_half_fov);
    if (m.unsignedBits(z1) > 0x80000000 and m.unsignedBits(z2) > 0x80000000) return null;

    const negative_z1 = -z1;
    if (scaled1 < negative_z1 and scaled2 < -z2) return null;
    if (z1 < scaled1 and z2 < scaled2) return null;

    var dx = m.sub(x2, x1);
    var dz = m.sub(z2, z1);
    if (m.add(m.mul(-x1, dz), m.mul(-dx, negative_z1)) < 0) return null;

    var scaled_delta = m.sub(scaled2, scaled1);
    var texture_length = m.mul(wall_length, 8.0);
    var texture_start: f32 = 0;
    var right_f: f32 = undefined;

    if (scaled2 <= z2) {
        right_f = m.add(m.mul(m.div(view.focal, z2), x2), view.center_x_f);
    } else {
        var intersection = m.sub(m.mul(scaled1, z2), m.mul(scaled2, z1));

        if (m.sub(
            dz,
            scaled_delta,
        ) != 0) intersection = m.div(intersection, m.sub(dz, scaled_delta));

        const fraction = if (@abs(dz) <= @abs(dx))
            (if (@abs(dx) == 0) @as(f32, 0) else m.div(m.sub(intersection, scaled2), scaled_delta))
        else
            m.div(m.sub(intersection, z2), dz);

        x2 = m.mul(intersection, view.tan_half_fov);
        scaled2 = intersection;
        z2 = intersection;

        if (@abs(
            fraction,
        ) != 0) texture_length = m.add(m.mul(fraction, texture_length), texture_length);

        dx = m.sub(x2, x1);
        scaled_delta = m.sub(intersection, scaled1);
        dz = m.sub(intersection, z1);
        right_f = m.add(m.mul(view.focal, view.tan_half_fov), view.center_x_f);
    }

    if (!std.math.isFinite(right_f)) return error.InvalidWallProjection;

    const right = m.integer(m.add(right_f, 0.5)) -% 1;
    var left_f: f32 = undefined;

    if (negative_z1 <= scaled1) {
        left_f = m.add(m.mul(m.div(view.focal, z1), x1), view.center_x_f);
    } else {
        var intersection = m.sub(m.mul(scaled2, z1), m.mul(scaled1, z2));

        if (m.add(
            dz,
            scaled_delta,
        ) != 0) intersection = m.div(intersection, m.add(dz, scaled_delta));

        const fraction = if (@abs(dz) <= @abs(dx))
            (if (@abs(dx) == 0) @as(f32, 0) else m.div(-m.add(scaled1, intersection), scaled_delta))
        else
            m.div(m.sub(intersection, z1), dz);

        z1 = intersection;
        x1 = -m.mul(intersection, view.tan_half_fov);

        if (@abs(fraction) != 0) {
            texture_start = m.mul(texture_length, fraction);
            texture_length = m.sub(texture_length, texture_start);
        }

        dx = m.sub(x2, x1);
        dz = m.sub(z2, intersection);
        left_f = m.sub(view.center_x_f, m.mul(view.focal, view.tan_half_fov));
    }

    if (!std.math.isFinite(left_f)) return error.InvalidWallProjection;

    const left = m.integer(m.add(left_f, 0.5));
    if (right < left) return null;

    var projected = ProjectedWall{
        .wall_index = wall_index,
        .left = left,
        .right = right,
        .z1 = z1,
        .z2 = z2,
        .u1 = texture_start,
        .x1 = x1,
        .x2 = x2,
        .visible_left = left,
        .visible_right = right,
        .axis = 0,
        .slope = undefined,
        .u_scale = undefined,
        .world_x1 = undefined,
        .world_z1 = undefined,
        .world_x2 = undefined,
        .world_z2 = undefined,
    };

    if (slopes) {
        projected.world_x1 = m.add(m.sub(m.mul(x1, view.cos_yaw), m.mul(z1, view.sin_yaw)), view.x);
        projected.world_z1 = m.add(m.add(m.mul(x1, view.sin_yaw), m.mul(z1, view.cos_yaw)), view.z);
        projected.world_x2 = m.add(m.sub(m.mul(x2, view.cos_yaw), m.mul(z2, view.sin_yaw)), view.x);
        projected.world_z2 = m.add(m.add(m.mul(view.cos_yaw, z2), m.mul(view.sin_yaw, x2)), view.z);
    }

    var numerator = dz;

    if (@abs(dx) <= @abs(dz)) {
        projected.axis = 1;
        numerator = dx;
        dx = dz;
    }

    if (dx == 0) return error.DegenerateProjectedWall;

    projected.slope = m.mul(numerator, m.div(1, dx));
    projected.u_scale = m.mul(m.div(1, dx), texture_length);

    return projected;
}

pub fn sameSide(a: Vec2, b: Vec2, c: Vec2, d: Vec2) u2 {
    const cross_c = m.sub(
        m.mul(m.sub(c.x, a.x), m.sub(b.z, a.z)),
        m.mul(m.sub(c.z, a.z), m.sub(b.x, a.x)),
    );

    const cross_d = m.sub(
        m.mul(m.sub(d.x, a.x), m.sub(b.z, a.z)),
        m.mul(m.sub(b.x, a.x), m.sub(d.z, a.z)),
    );

    if (m.unsignedBits(cross_c) < 0xba83126f and m.unsignedBits(cross_d) < 0xba83126f) return 1;
    if (m.signedBits(cross_c) < 0x3a83126f and m.signedBits(cross_d) < 0x3a83126f) return 2;

    return 0;
}

test "wall projection clips a crossing wall to inclusive viewport edges" {
    const angles = camera.Angles.init();
    var view = try camera.View.init(std.testing.allocator, &angles, 640, 480);
    defer view.deinit(std.testing.allocator);
    const projected = (try project(
        &view,
        .{ .x = -20, .z = 10 },
        .{ .x = 20, .z = 10 },
        40,
        7,
        false,
    )).?;

    try std.testing.expectEqual(@as(i32, 0), projected.left);
    try std.testing.expectEqual(@as(i32, 639), projected.right);
    try std.testing.expectEqual(@as(i32, 0), projected.axis);
    try std.testing.expectEqual(
        @as(?ProjectedWall, null),
        try project(&view, .{ .x = 20, .z = 10 }, .{ .x = -20, .z = 10 }, 40, 7, false),
    );
}

test "projection records match the reference execution with render control word" {
    const angles = camera.Angles.init();
    var view = try camera.View.init(std.testing.allocator, &angles, 640, 480);
    defer view.deinit(std.testing.allocator);

    view.setPose(&angles, 322.36, 2.5, 271.88, 8035, 0);

    const inputs = [_]struct { first: Vec2, second: Vec2, length: f32 }{
        .{ .first = .{ .x = -20, .z = 10 }, .second = .{ .x = 20, .z = 10 }, .length = 40 },
        .{
            .first = .{ .x = -4.25, .z = 4.75 },
            .second = .{ .x = 20.125, .z = 30.5 },
            .length = 35.5,
        },
        .{ .first = .{ .x = -20, .z = -1 }, .second = .{ .x = 10, .z = 15 }, .length = 34 },
    };

    const expected = [_][16]u32{
        .{
            0,
            639,
            1092616191,
            1092616191,
            1117782017,
            3240099838,
            1092616190,
            0,
            639,
            0,
            0,
            1090519039,
            1134983367,
            1132675067,
            1134329195,
            1132635632,
        },
        .{
            34,
            530,
            1083703296,
            1106509824,
            0,
            3230138368,
            1101070336,
            34,
            530,
            1,
            1064457343,
            1093695308,
            1134784941,
            1132835449,
            1134038440,
            1131428203,
        },
        .{
            0,
            532,
            1086962998,
            1097859072,
            1123571980,
            3234446645,
            1092616192,
            0,
            532,
            0,
            1057523850,
            1091637521,
            1134855200,
            1132788659,
            1134339053,
            1132472089,
        },
    };

    for (inputs, expected) |input, want| {
        const p = (try project(&view, input.first, input.second, input.length, 0, true)).?;
        const actual = [_]u32{
            @bitCast(
                p.left,
            ),
            @bitCast(p.right),
            @bitCast(p.z1),
            @bitCast(p.z2),
            @bitCast(p.u1),
            @bitCast(p.x1),
            @bitCast(p.x2),
            @bitCast(
                p.visible_left,
            ),
            @bitCast(p.visible_right),
            @bitCast(p.axis),
            @bitCast(p.slope),
            @bitCast(p.u_scale),
            @bitCast(p.world_x1),
            @bitCast(p.world_z1),
            @bitCast(p.world_x2),
            @bitCast(p.world_z2),
        };

        try std.testing.expectEqualSlices(u32, &want, &actual);
    }
}
