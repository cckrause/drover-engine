//! The inner loops that fill floor and ceiling spans, lit and unlit.
//!
//! Distances arrive fixed-point and negative or indefinite results are
//! clamped before shifting, which is what keeps a span at a grazing angle
//! from wrapping.

const std = @import("std");

const math = @import("math.zig");
const walls = @import("walls.zig");

pub const Perspective = struct {
    numerator: f32,
    derivative: f32,
    u_offset: f32,
    v_offset: f32,
    u_axis: f32,
    v_axis: f32,
    denominator_step: f32,
    u: f32,
    v: f32,
    denominator: f32,
    inverse: f32,
};

pub fn lightTable(lighting: walls.Lighting, fixed_distance: i32) !?*const [256]u8 {
    const color_map = lighting.color_map orelse return null;
    if (color_map.len < 32 * 256) return error.InvalidColorMap;

    var light = lighting.ambient_bias +% lighting.ambient;
    if (light > 30) return null;

    const distance = if (fixed_distance < 1) 0 else fixed_distance;
    var depth_light: i32 = 0;

    if (lighting.force_depth != 0 or (lighting.depth_map != null and lighting.depth_strength != 0)) {
        const depth_map = lighting.depth_map orelse return error.MissingDepthMap;
        var index = distance >> 14;

        if (index > 126) index = 127;

        const candidate = ((lighting.depth_strength -% @as(
            i32,
            depth_map[@intCast(index)],
        )) -% lighting.depth_bias) +% 31;

        if (candidate > 0) depth_light = candidate;
    }

    if (light <= depth_light) light = depth_light;

    light -%= (distance >> 20) +% (distance >> 21);
    var result = lighting.ambient_min;

    if (lighting.ambient_min <= light) result = light;

    if (result > 30) return null;

    if (result < 1) result = 0;

    const offset: usize = @intCast((31 - result) * 256);

    return color_map[offset..][0..256];
}

pub fn perspective(
    destination: []u8,
    texels: []const u8,
    initial: Perspective,
    lighting: ?walls.Lighting,
    light_scale: f32,
) !void {
    if (texels.len < 4096) return error.UnsupportedSlopeTextureSize;

    var state = initial;
    var position: usize = 0;

    while (position < destination.len) {
        const ratio = math.mul(state.numerator, state.inverse);
        const change = math.mul(state.derivative, math.mul(state.inverse, state.inverse));
        const translation = if (lighting) |light| try lightTable(
            light,
            math.fixed(math.mul(light_scale, ratio)),
        ) else null;

        var u: u32 = @bitCast(math.fixed(math.sub(math.mul(state.u, ratio), state.u_offset)));
        const du: u32 = @bitCast(
            math.fixed(
                math.add(
                    math.mul(state.u_axis, ratio),
                    math.mul(math.add(state.u_axis, state.u), change),
                ),
            ),
        );

        state.u = math.add(state.u, math.mul(state.u_axis, 16.0));

        var v: u32 = @bitCast(math.fixed(math.sub(math.mul(state.v, ratio), state.v_offset)));
        const dv: u32 = @bitCast(
            math.fixed(
                math.add(
                    math.mul(math.add(state.v_axis, state.v), change),
                    math.mul(state.v_axis, ratio),
                ),
            ),
        );

        state.v = math.add(state.v, math.mul(state.v_axis, 16.0));
        state.denominator = math.add(math.mul(state.denominator_step, 16.0), state.denominator);

        const remaining = destination.len - position;

        if (remaining > 16) {
            state.inverse = math.div(1.0, state.denominator);

            var packed_uv = ((u << 10) & 0xffff0000) | ((v >> 6) & 0xffff);
            const step = ((du << 10) & 0xffff0000) | ((dv >> 6) & 0xffff);

            for (destination[position..][0..16]) |*pixel| {
                const index = ((packed_uv >> 22) + (packed_uv & 0xfc00)) >> 4;
                const source = texels[index];
                pixel.* = if (translation) |table| table[source] else source;
                packed_uv +%= step;
            }

            position += 16;
        } else {
            for (destination[position..]) |*pixel| {
                const index = ((u & 0x3f0000) >> 16) + ((v & 0x3f0000) >> 10);
                const source = texels[index];

                pixel.* = if (translation) |table| table[source] else source;
                u +%= du;
                v +%= dv;
            }

            position = destination.len;
        }
    }
}

pub fn overlay(
    destination: []u8,
    texels: []const u8,
    width: usize,
    initial: @import("raster.zig").SpanCoordinates,
    translation: ?*const [256]u8,
) !void {
    if (width > 32767) return error.UnsupportedPlaneOverlaySize;

    const limit: i32 = @as(i32, @intCast(width)) << 16;
    var u = initial.u;
    var v = initial.v;
    var remaining = destination.len;

    while (remaining != 0) {
        remaining -= 1;

        const ubits: u32 = @bitCast(u);
        const vbits: u32 = @bitCast(v);
        const index = ((ubits & 0x7f0000) >> 16) + ((vbits & 0x7f0000) >> 9);

        if (u < limit and u >= 0 and v < limit and v >= 0) {
            if (index >= texels.len) return error.InvalidPlaneOverlayExtent;
            const source = texels[index];
            if (source != 0) destination[remaining] = if (translation) |table| table[source] else source;
        }

        u +%= initial.du;
        v +%= initial.dv;
    }
}

test "slope kernels preserve perspective correction, lighting and final-block arithmetic" {
    var texels: [4096]u8 = undefined;

    for (&texels, 0..) |*value, i| value.* = @intCast((i % 64) * 3 + i / 64);

    const initial = Perspective{
        .numerator = 17.3,
        .derivative = -0.346,
        .u_offset = 2.3,
        .v_offset = -4.7,
        .u_axis = 0.121,
        .v_axis = -0.093,
        .denominator_step = 0.02,
        .u = 12.3125,
        .v = -1.1875,
        .denominator = 2.5,
        .inverse = 0.4,
    };

    var pixels: [49]u8 = undefined;

    try perspective(&pixels, &texels, initial, null, 40);
    var expected: [49]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected,
        "7274747373727271737372727171707273727271717170707272717170706f6f6f6f7271717070706f6f6f6e7171707070",
    );

    try std.testing.expectEqualSlices(u8, &expected, &pixels);
    var colors: [8192]u8 = undefined;

    for (&colors, 0..) |*value, i| value.* = @truncate(i % 256 + i / 256);

    const light = walls.Lighting{
        .force_depth = 0,
        .depth_bias = 0,
        .depth_strength = 0,
        .ambient_bias = 0,
        .ambient = 18,
        .ambient_min = 0,
        .color_map = &colors,
        .depth_map = null,
    };

    try perspective(&pixels, &texels, initial, light, 40);
    _ = try std.fmt.hexToBytes(
        &expected,
        "91939392929191909292919190908f919291919090908f8f919190908f8f8e8e8e8e9190908f8f8f8e8e8e8d90908f8f8f",
    );

    try std.testing.expectEqualSlices(u8, &expected, &pixels);

    const boundary = Perspective{
        .numerator = 1,
        .derivative = 0,
        .u_offset = 0,
        .v_offset = 0,
        .u_axis = 63.0 / 65536.0,
        .v_axis = 65.0 / 65536.0,
        .denominator_step = 0,
        .u = @as(f32, 0x003fffc0) / 65536.0,
        .v = @as(f32, 0x003fffff) / 65536.0,
        .denominator = 1,
        .inverse = 1,
    };

    var short: [16]u8 = undefined;
    var long: [17]u8 = undefined;

    try perspective(&short, &texels, boundary, null, 1);
    try perspective(&long, &texels, boundary, null, 1);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 252, 189, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        &short,
    );

    try std.testing.expectEqualSlices(
        u8,
        &.{ 252, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        &long,
    );
}

test "plane decals use 128 stride, clip signed coordinates and retain zero" {
    var texels = [_]u8{0} ** (128 * 128);

    texels[128 + 1] = 7;
    texels[128 + 2] = 9;

    var pixels = [_]u8{99} ** 5;
    try overlay(&pixels, &texels, 128, .{ .u = -65536, .v = 65536, .du = 65536, .dv = 0 }, null);
    try std.testing.expectEqualSlices(u8, &.{ 99, 9, 7, 99, 99 }, &pixels);
}
