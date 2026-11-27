//! Floors and ceilings: the scan conversion and the water distortion on
//! top of it.
//!
//! Only the two ends of a span are clipped; central rows keep the endpoints
//! they came in with, because the callers have already bounded them. Water
//! texels come from the distorted copy when the preceding pass asked for
//! it.

const std = @import("std");

const level = @import("../../../assets/level.zig");
const texture = @import("../../../assets/texture.zig");
const scene = @import("../../scene.zig");
const camera = @import("camera.zig");
const math = @import("math.zig");
const kernels = @import("plane_raster.zig");
const raster = @import("raster.zig");
const walls = @import("walls.zig");

pub const Side = enum { ceiling, floor };

pub const Span = struct { left: i32, right: i32 };

pub const ClipWindow = struct {
    left: i32,
    right: i32,
    top: i32,
    bottom: i32,
    inner_top: i32,
    inner_bottom: i32,
    top_clip: []const i16,
    bottom_clip: []const i16,

    pub fn clip(self: ClipWindow, span: *Span, y: i32) !void {
        var left = span.left;
        var right = span.right;
        if (self.right < left or right < self.left) {
            span.left = right +% 1;
            return;
        }

        if (left < self.left) left = self.left;

        if (self.right < right) right = self.right;

        const check_top = y < self.inner_top;
        const check_bottom = self.inner_bottom < y;
        if (!check_top and !check_bottom) return;

        while (left <= right and try self.outside(left, y, check_top, check_bottom)) left += 1;

        span.left = left;
        if (right < left) return;

        while (left <= right and try self.outside(right, y, check_top, check_bottom)) right -= 1;

        span.right = right;
    }

    fn outside(self: ClipWindow, x: i32, y: i32, top: bool, bottom: bool) !bool {
        if (x < 0 or x >= self.top_clip.len or x >= self.bottom_clip.len) return error.InvalidPlaneClip;
        const index: usize = @intCast(x);

        return (top and y < self.top_clip[index]) or (bottom and self.bottom_clip[index] < y);
    }
};

pub const Context = struct {
    pixels: []u8,
    view: *const camera.View,
    angles: *const camera.Angles,
    textures: []const texture.Texture,
    window: ClipWindow,
    edges: []const walls.Edge,
    top_y: []const i32,
    bottom_y: []const i32,
    top_limit: i32,
    bottom_limit: i32,
    lighting: walls.Lighting,
    arithmetic: raster.SpanArithmetic,
};

const FlatMapping = struct {
    u_constant: f32,
    v_constant: f32,
    u_step: f32,
    v_step: f32,
    u_offset: f32,
    v_offset: f32,

    fn init(
        view: *const camera.View,
        angles: *const camera.Angles,
        height_delta: f32,
        offset: level.Vec2,
        angle: i16,
    ) FlatMapping {
        const combined = angles.sinCos(0 -% (view.yaw +% angle));
        const rotation = angles.sinCos(angle);
        const x = math.sub(view.x, offset.x);
        const z = math.sub(offset.z, view.z);
        const scaled_height = math.mul(height_delta, view.focal);

        return .{
            .u_constant = math.mul(math.mul(combined.cos, scaled_height), 8.0),
            .v_constant = math.mul(math.mul(combined.sin, scaled_height), 8.0),
            .u_step = math.mul(math.mul(height_delta, combined.sin), -8.0),
            .v_step = math.mul(math.mul(height_delta, combined.cos), -8.0),
            .u_offset = math.mul(
                math.add(math.mul(z, rotation.cos), math.mul(x, rotation.sin)),
                8.0,
            ),
            .v_offset = math.mul(
                math.sub(math.mul(rotation.cos, x), math.mul(rotation.sin, z)),
                8.0,
            ),
        };
    }

    fn coordinates(self: FlatMapping, x: f32, reciprocal: f32) raster.SpanCoordinates {
        return .{
            .u = math.fixed(
                math.sub(
                    math.mul(math.sub(self.u_constant, math.mul(x, self.u_step)), reciprocal),
                    self.u_offset,
                ),
            ),
            .v = math.fixed(
                math.sub(
                    math.mul(math.add(math.mul(self.v_step, x), self.v_constant), reciprocal),
                    self.v_offset,
                ),
            ),
            .du = math.fixed(math.mul(self.u_step, reciprocal)),
            .dv = math.fixed(-math.mul(self.v_step, reciprocal)),
        };
    }
};

const Spans = struct {
    ctx: Context,
    side: Side,
    row: i32,
    index: usize = 0,
    cursor: i32,

    fn init(ctx: Context, side: Side, row: i32) Spans {
        return .{ .ctx = ctx, .side = side, .row = row, .cursor = ctx.window.left };
    }

    fn advance(self: *Spans) void {
        self.cursor = self.ctx.edges[self.index].right +% 1;
        self.index += 1;
    }

    fn column(self: Spans, x: i32) !i32 {
        const array = if (self.side == .ceiling) self.ctx.top_y else self.ctx.bottom_y;
        if (x < 0 or x >= array.len) return error.InvalidPlaneEdgeColumn;

        return array[@intCast(x)];
    }

    fn next(self: *Spans) !?Span {
        if (self.index >= self.ctx.edges.len) return null;

        var found = false;
        var start: i32 = undefined;

        while (true) {
            const edge = self.ctx.edges[self.index];
            const wholly_outside = if (self.side == .ceiling) self.row < edge.top_min else edge.bottom_max < self.row;
            const crosses = if (self.side == .ceiling) self.row < edge.top_max else edge.bottom_min < self.row;

            if (wholly_outside) {
                start = self.cursor;
                self.advance();
                found = true;
                break;
            } else if (crosses) {
                const simple = if (self.side == .ceiling) math.signedBits(
                    edge.top_step,
                ) < 1 else math.unsignedBits(edge.bottom_step) < 0x80000001;

                if (simple) {
                    start = self.cursor;
                } else {
                    start = edge.left;

                    while (start < self.ctx.window.right) : (start += 1) {
                        const value = try self.column(start);
                        const keep = if (self.side == .ceiling) value < self.row else if (math.signedBits(edge.bottom_step) < 1) self.row < value else value <= self.row;
                        if (!keep) break;
                    }

                    self.advance();
                }

                found = true;
                break;
            } else {
                self.advance();

                if (self.index >= self.ctx.edges.len) {
                    start = self.cursor;
                    break;
                }
            }
        }

        var end = self.cursor;

        if (self.index < self.ctx.edges.len) {
            while (true) {
                const edge = self.ctx.edges[self.index];
                const wholly_outside = if (self.side == .ceiling) self.row < edge.top_min else edge.bottom_max < self.row;
                const crosses = if (self.side == .ceiling) self.row < edge.top_max else edge.bottom_min < self.row;

                if (wholly_outside) {
                    self.advance();
                    end = self.cursor;
                    if (self.index >= self.ctx.edges.len) break;
                } else {
                    end = self.cursor;

                    if (crosses) {
                        const simple = if (self.side == .ceiling) math.unsignedBits(
                            edge.top_step,
                        ) < 0x80000001 else math.signedBits(edge.bottom_step) < 1;

                        if (simple) break;

                        end = edge.left;

                        while (end < self.ctx.window.right) : (end += 1) {
                            const value = try self.column(end);
                            const keep = if (self.side == .ceiling)
                                (if (math.signedBits(
                                    edge.top_step,
                                ) < 1) self.row <= value else value < self.row)
                            else
                                value <= self.row;

                            if (!keep) break;
                        }
                    }

                    self.advance();
                    break;
                }
            }
        } else if (!found) return null;

        var result = Span{ .left = start, .right = end -% 1 };
        try self.ctx.window.clip(&result, self.row);

        return result;
    }
};

pub fn draw(
    ctx: Context,
    sector: *const level.Sector,
    side: Side,
    slope: ?scene.Slope,
    override_texels: ?[]const u8,
) !void {
    const sky_bit: u32 = if (side == .ceiling) 1 else 2;
    const slope_bit: u32 = if (side == .ceiling) 0x80000000 else 0x40000000;
    if (sector.flags & sky_bit != 0) return drawSky(ctx, sector, side);
    if (sector.flags & slope_bit != 0) return drawSlope(
        ctx,
        sector,
        side,
        slope orelse return error.MissingSlopePlane,
        override_texels,
    );

    return drawFlat(ctx, sector, side, override_texels);
}

fn getTexture(ctx: Context, index: i32) !*const texture.Texture {
    if (index < 0 or index >= ctx.textures.len) return error.InvalidPlaneTexture;

    return &ctx.textures[@intCast(index)];
}

fn destination(ctx: Context, span: Span, y: i32) ![]u8 {
    if (y < 0 or y >= ctx.view.height or span.left < 0 or span.right >= ctx.view.width or span.right < span.left)
        return error.PlaneRasterBounds;

    const offset: usize = @intCast(y * ctx.view.width + span.left);
    const count: usize = @intCast(span.right - span.left + 1);
    if (offset > ctx.pixels.len or count > ctx.pixels.len - offset) return error.PlaneRasterBounds;

    return ctx.pixels[offset..][0..count];
}

fn drawFlat(
    ctx: Context,
    sector: *const level.Sector,
    side: Side,
    override_texels: ?[]const u8,
) !void {
    const plane = if (side == .ceiling) sector.ceiling else sector.floor;

    if (side == .ceiling) {
        if (!(ctx.view.y <= plane.height)) return;
    } else if (!(plane.height <= ctx.view.y)) return;

    const tex = try getTexture(ctx, plane.texture);
    const height_delta = -math.sub(plane.height, ctx.view.y);
    const height_focal = math.mul(height_delta, ctx.view.focal);
    const mapping = FlatMapping.init(ctx.view, ctx.angles, height_delta, plane.offset, plane.angle);
    const overlay = if (side == .ceiling) sector.ceiling_overlay else sector.floor_overlay;
    const overlay_texture = if (overlay.texture >= 0) try getTexture(
        ctx,
        overlay.texture,
    ) else null;

    const overlay_mapping = FlatMapping.init(
        ctx.view,
        ctx.angles,
        height_delta,
        overlay.offset,
        overlay.angle,
    );

    const first_y = if (side == .ceiling) ctx.window.top else ctx.bottom_limit;
    const last_y = if (side == .ceiling) ctx.top_limit else ctx.window.bottom;
    var y = first_y;

    while (y <= last_y) : (y += 1) {
        const index = y - ctx.view.horizon + ctx.view.center_y + ctx.view.height * 16;
        if (index < 0 or index >= ctx.view.row_reciprocal.len) return error.InvalidPlaneProjection;

        const reciprocal = ctx.view.row_reciprocal[@intCast(index)];
        var spans = Spans.init(ctx, side, y);

        while (try spans.next()) |span| {
            if (span.right < span.left) continue;

            const pixels = try destination(ctx, span, y);
            const x: f32 = @floatFromInt(span.right - ctx.view.center_x);
            const translation = if (side == .floor and sector.flags & 0x4000000 != 0) null else try kernels.lightTable(ctx.lighting, math.fixed(math.mul(reciprocal, height_focal)));

            try raster.span64(
                pixels,
                override_texels orelse tex.pixels,
                mapping.coordinates(x, reciprocal),
                ctx.arithmetic,
                translation,
            );

            if (overlay_texture) |overlay_tex|
                try kernels.overlay(
                    pixels,
                    overlay_tex.pixels,
                    overlay_tex.width,
                    overlay_mapping.coordinates(x, reciprocal),
                    translation,
                );
        }
    }
}

fn drawSlope(
    ctx: Context,
    sector: *const level.Sector,
    side: Side,
    slope: scene.Slope,
    override_texels: ?[]const u8,
) !void {
    const view = ctx.view;
    const distance = math.add(
        math.sub(
            math.add(math.mul(slope.coeff_z, view.z), math.mul(slope.coeff_x, view.x)),
            slope.constant,
        ),
        view.y,
    );

    if (side == .ceiling) {
        if (!(distance <= 0)) return;
    } else if (!(0 <= distance)) return;

    const plane = if (side == .ceiling) sector.ceiling else sector.floor;
    const tex = try getTexture(ctx, plane.texture);
    const sine = view.sin_yaw;
    const cosine = view.cos_yaw;
    const u_axis = math.add(math.mul(sine, slope.u_axis.z), math.mul(cosine, slope.u_axis.x));
    const u_forward = math.sub(math.mul(cosine, slope.u_axis.z), math.mul(sine, slope.u_axis.x));
    const v_axis = math.add(math.mul(sine, slope.v_axis.z), math.mul(cosine, slope.v_axis.x));
    const v_forward = math.sub(math.mul(cosine, slope.v_axis.z), math.mul(sine, slope.v_axis.x));
    const denominator_step = math.add(
        math.mul(sine, slope.coeff_z),
        math.mul(cosine, slope.coeff_x),
    );

    const denominator_forward = math.sub(
        math.mul(slope.coeff_z, cosine),
        math.mul(sine, slope.coeff_x),
    );

    const world_z = math.sub(slope.origin.z, view.z);
    const world_x = math.sub(slope.origin.x, view.x);
    const local_x = math.add(math.mul(sine, world_z), math.mul(cosine, world_x));
    const local_y = math.sub(slope.origin.y, view.y);
    const local_z = math.sub(math.mul(world_z, cosine), math.mul(sine, world_x));
    const u_offset = math.mul(
        math.add(
            math.add(
                math.add(math.mul(slope.u_axis.y, local_y), math.mul(u_axis, local_x)),
                math.mul(local_z, u_forward),
            ),
            plane.offset.x,
        ),
        8.0,
    );

    const v_offset = math.mul(
        math.add(
            math.add(
                math.add(math.mul(slope.v_axis.y, local_y), math.mul(v_axis, local_x)),
                math.mul(v_forward, local_z),
            ),
            plane.offset.z,
        ),
        8.0,
    );

    const numerator = math.mul(
        math.add(
            math.add(math.mul(local_x, denominator_step), math.mul(denominator_forward, local_z)),
            local_y,
        ),
        8.0,
    );

    const derivative = -math.mul(numerator, denominator_step);
    const lighting: ?walls.Lighting = if (ctx.lighting.color_map == null or (side == .floor and sector.flags & 0x4000000 != 0)) null else ctx.lighting;
    var y = if (side == .ceiling) ctx.window.top else ctx.bottom_limit;
    const last_y = if (side == .ceiling) ctx.top_limit else ctx.window.bottom;

    while (y <= last_y) : (y += 1) {
        var spans = Spans.init(ctx, side, y);

        while (try spans.next()) |span| {
            if (span.right < span.left) continue;

            const x: f32 = @floatFromInt(span.left - view.center_x);
            const row: f32 = @floatFromInt(view.horizon - y);
            const denominator = math.add(
                math.add(math.mul(denominator_step, x), math.mul(view.focal, denominator_forward)),
                row,
            );

            const u = math.add(
                math.add(math.mul(slope.u_axis.y, row), math.mul(view.focal, u_forward)),
                math.mul(u_axis, x),
            );

            const v = math.add(
                math.add(math.mul(x, v_axis), math.mul(row, slope.v_axis.y)),
                math.mul(view.focal, v_forward),
            );

            try kernels.perspective(try destination(
                ctx,
                span,
                y,
            ), override_texels orelse tex.pixels, .{
                .numerator = numerator,
                .derivative = derivative,
                .u_offset = u_offset,
                .v_offset = v_offset,
                .u_axis = u_axis,
                .v_axis = v_axis,
                .denominator_step = denominator_step,
                .u = u,
                .v = v,
                .denominator = denominator,
                .inverse = math.div(1.0, denominator),
            }, lighting, math.mul(view.focal, 0.125));
        }
    }
}

fn drawSky(ctx: Context, sector: *const level.Sector, side: Side) !void {
    const view = ctx.view;
    const plane = if (side == .ceiling) sector.ceiling else sector.floor;
    const tex = try getTexture(ctx, plane.texture);
    const horizon_clip = sector.flags & 0x10 != 0;

    if (!horizon_clip) {
        if (side == .ceiling and ctx.window.top > ctx.top_limit) return;
        if (side == .floor and ctx.bottom_limit > ctx.window.bottom) return;
    }

    if (tex.width == 0 or tex.height == 0 or tex.height > 65536) return error.InvalidSkyTexture;

    const width_mask: u32 = @intCast(tex.width - 1);
    const height_mask: u32 = @intCast(tex.height - 1);
    const du = math.fixed(math.add(plane.offset.x, view.sky_yaw));
    const dv = math.fixed(view.sky_scale);
    var x = ctx.window.left;

    while (x <= ctx.window.right) : (x += 1) {
        if (x < 0 or x >= ctx.window.top_clip.len or x >= ctx.window.bottom_clip.len or x >= view.sky_angle.len or x >= ctx.top_y.len or x >= ctx.bottom_y.len)
            return error.InvalidSkyWindow;

        const index: usize = @intCast(x);
        const top: i32 = if (side == .ceiling) ctx.window.top_clip[index] else @max(
            if (horizon_clip) view.horizon else ctx.bottom_y[index],
            ctx.window.top_clip[index],
        );

        const bottom: i32 = if (side == .floor) ctx.window.bottom_clip[index] else @min(
            if (horizon_clip) view.horizon - 1 else ctx.top_y[index],
            ctx.window.bottom_clip[index],
        );

        if (bottom < top) continue;

        const delta: f32 = if (side == .ceiling and !horizon_clip) @floatFromInt(
            bottom - view.center_y,
        ) else math.mul(@as(f32, @floatFromInt((bottom -% view.center_y) *% 65536)), 0x1p-16);

        var vertical = math.add(math.mul(delta, view.sky_scale), @floatFromInt(view.center_y));

        if (horizon_clip) {
            vertical = math.add(math.add(vertical, plane.offset.z), view.sky_pitch);
        } else vertical = math.add(math.add(vertical, view.sky_pitch), plane.offset.z);

        const v = @as(i32, @bitCast(height_mask *% 65536)) -% math.fixed(vertical);
        const column_bits: u32 = @bitCast((view.sky_angle[index] +% du) >> 16);
        const column = (column_bits & width_mask) << tex.height_shift;
        if (column > tex.pixels.len or tex.height > tex.pixels.len - column) return error.InvalidSkyTextureColumn;
        if (top < 0 or bottom >= view.height) return error.SkyRasterBounds;

        try raster.column(ctx.pixels, .{
            .top = @intCast(top * view.width + x),
            .stride = @intCast(view.width),
            .count = @intCast(bottom - top + 1),
            .texels = tex.pixels[column..][0..tex.height],
            .mask = height_mask,
            .v = v,
            .dv = dv,
        }, null);
    }
}

test "flat, sloped and sky planes match isolated reference frames" {
    const allocator = std.testing.allocator;
    const angles = camera.Angles.init();
    var view = try camera.View.init(allocator, &angles, 64, 48);
    defer view.deinit(allocator);

    view.setPose(&angles, 1.5, 2.5, -4, 1000, 0);
    var texels: [4096]u8 = undefined;

    for (&texels, 0..) |*value, i| value.* = @intCast((i % 64) * 3 + i / 64);

    const textures = [_]texture.Texture{
        .{ .width = 64, .height = 64, .pixels = &texels, .height_shift = 6, .flags = 6 },
    };

    var sector: level.Sector = undefined;

    sector.ceiling = .{
        .height = 10,
        .texture = 0,
        .offset = .{ .x = -2.5, .z = -1.5 },
        .angle = -713,
    };

    sector.floor = .{
        .height = 0,
        .texture = 0,
        .offset = .{ .x = 1.25, .z = 3.75 },
        .angle = 312,
    };

    sector.floor_overlay = .{ .texture = -1, .offset = .{ .x = 0, .z = 0 }, .angle = 0 };
    sector.ceiling_overlay = sector.floor_overlay;

    var hinge: level.Wall = undefined;

    hinge.v1 = 0;
    hinge.v2 = 1;

    var hinges = [_]level.Wall{hinge};
    var vertices = [_]level.Vec2{ .{ .x = 0.5, .z = -3 }, .{ .x = 0.5, .z = 3 } };

    sector.vertices = &vertices;
    sector.walls = &hinges;
    sector.floor.slope = .{ .sector = 0, .wall = 0, .angle = 512 };
    sector.ceiling.slope = sector.floor.slope;

    var top: [64]i32 = undefined;
    var bottom: [64]i32 = undefined;
    var top_clip: [64]i16 = undefined;
    var bottom_clip: [64]i16 = undefined;

    for (0..64) |x| {
        top[x] = @intCast(16 + x / 8);
        bottom[x] = @intFromFloat(32.0 - @as(f32, @floatFromInt(x)) * 0.125);
        top_clip[x] = @intCast(x % 5);
        bottom_clip[x] = @intCast(47 - x % 5);
    }

    const edges = [_]walls.Edge{walls.Edge.init(16, 23.875, 0.125, 32, 24.125, -0.125, 0, 64, 0)};
    var pixels: [64 * 48]u8 = undefined;
    const ctx = Context{
        .pixels = &pixels,
        .view = &view,
        .angles = &angles,
        .textures = &textures,
        .window = .{
            .left = 0,
            .right = 63,
            .top = 0,
            .bottom = 47,
            .inner_top = 4,
            .inner_bottom = 43,
            .top_clip = &top_clip,
            .bottom_clip = &bottom_clip,
        },
        .edges = &edges,
        .top_y = &top,
        .bottom_y = &bottom,
        .top_limit = 22,
        .bottom_limit = 25,
        .lighting = .{
            .force_depth = 0,
            .depth_bias = 0,
            .depth_strength = 0,
            .ambient_bias = 0,
            .ambient = 0,
            .ambient_min = 0,
            .color_map = null,
            .depth_map = null,
        },
        .arithmetic = .scalar,
    };

    const cases = .{
        .{
            Side.ceiling,
            @as(u32, 0),
            "2c7be00c5d7e4ea196b812dbf860358410a112d46074e22c2a2666310c29dcc8",
        },
        .{
            Side.floor,
            @as(u32, 0),
            "72f587565290aef0dd39349a2182fd5cc874c8333e05a9fec5c189387ea36ea2",
        },
        .{
            Side.ceiling,
            @as(u32, 1),
            "0150829c022efa6317dd0aa6a00aa93075cac48cefaa53f78c7bd8892a93d185",
        },
        .{
            Side.floor,
            @as(u32, 2),
            "e4b79568c57193712f0d371c4020728f172634fde9e3a5c0cba9394f42457601",
        },
        .{
            Side.ceiling,
            @as(u32, 17),
            "9da7a9838a127dd95a99adc08ed107f23e9ece7b3c494766ac925ac1d2b62be0",
        },
        .{
            Side.floor,
            @as(u32, 18),
            "233bc46f9eaa1d871b37c6448235742c6c411dfdeeb7533a76317ce46e1f52bf",
        },
        .{
            Side.floor,
            @as(u32, 0x40000000),
            "d2ce77efee70b973b705dcde44f3d4bc49b2e63a14b8eccee2d65ccc10f5d8bf",
        },
        .{
            Side.ceiling,
            @as(u32, 0x80000000),
            "45575a045050f62daf3a47e3fbcb3bf49d62bf2d5c453f3808894b95a89f7f45",
        },
    };

    inline for (cases) |case| {
        @memset(&pixels, 99);
        sector.flags = case[1];

        var sectors = [_]level.Sector{sector};
        var geometry: level.Level = undefined;

        geometry.sectors = &sectors;
        const slope: ?scene.Slope = if (case[1] & 0xc0000000 != 0)
            try scene.Slope.init(
                &geometry,
                0,
                if (case[0] == .ceiling) sector.ceiling else sector.floor,
                &angles,
            )
        else
            null;

        try draw(ctx, &sector, case[0], slope, null);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&pixels, &digest, .{});
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case[2]);
        try std.testing.expectEqualSlices(u8, &expected, &digest);
    }
}
