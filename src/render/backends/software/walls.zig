//! Wall columns: the projected wall records and the spans the rasteriser
//! gets.
//!
//! The record layout is fixed because the plane scan reads it directly.
//! There is a hard limit on records per frame, and the final clamp is
//! deliberately skipped for one flag combination - a wall with both of those
//! flags set draws past the clamp.

const std = @import("std");

const level = @import("../../../assets/level.zig");
const WallParts = @import("../../scene.zig").WallParts;
const texture = @import("../../../assets/texture.zig");
const camera = @import("camera.zig");
const math = @import("math.zig");
const projection = @import("projection.zig");
const raster = @import("raster.zig");
const bits = @import("../../../util/bits.zig");

pub const Edge = extern struct {
    visited: u32 = 0,
    top_first: f32,
    top_last: f32,
    top_step: f32,
    top_min: i32,
    top_max: i32,
    bottom_first: f32,
    bottom_last: f32,
    bottom_step: f32,
    bottom_max: i32,
    bottom_min: i32,
    count: i32,
    left: i32,
    right: i32,
    /// Only `lower_opening` is ever set: the edge belongs to the lower of
    /// two openings.
    parts: WallParts,

    pub fn init(
        top: f32,
        top_last: f32,
        top_step: f32,
        bottom: f32,
        bottom_last: f32,
        bottom_step: f32,
        left: i32,
        count: i32,
        lower_opening: bool,
    ) Edge {
        const y1 = math.integer(top);
        const y2 = math.integer(top_last);
        const y3 = math.integer(bottom);
        const y4 = math.integer(bottom_last);

        return .{
            .top_first = top,
            .top_last = top_last,
            .top_step = top_step,
            .top_min = @min(y1, y2),
            .top_max = @max(y1, y2),
            .bottom_first = bottom,
            .bottom_last = bottom_last,
            .bottom_step = bottom_step,
            .bottom_max = @max(y3, y4),
            .bottom_min = @min(y3, y4),
            .count = count,
            .left = left,
            .right = left +% count -% 1,
            .parts = .{ .lower_opening = lower_opening },
        };
    }
};

pub const EdgeList = struct {
    entries: [0x568]Edge = undefined,
    count: usize = 0,
    view_top: i32,
    view_bottom: i32,
    top_limit: i32,
    bottom_limit: i32,

    pub fn add(
        self: *EdgeList,
        top: f32,
        top_step: f32,
        bottom: f32,
        bottom_step: f32,
        left: i32,
        count: i32,
        parts: WallParts,
    ) !void {
        if (self.count > 0x567) {
            std.log.debug("Render_AddWallEdge: exceeded MAX_WALL_EDGES", .{});
            return;
        }

        if (count < 1) return;

        const distance: f32 = @floatFromInt(count - 1);
        const top_last = if (@abs(
            top_step,
        ) == 0) top else math.add(math.mul(distance, top_step), top);

        const bottom_last = if (@abs(
            bottom_step,
        ) == 0) bottom else math.add(math.mul(distance, bottom_step), bottom);

        const edge = Edge.init(
            top,
            top_last,
            top_step,
            bottom,
            bottom_last,
            bottom_step,
            left,
            count,
            false,
        );

        self.entries[self.count] = edge;

        if (!parts.double_adjoin) {
            if (self.top_limit < edge.top_max -% 1) self.top_limit = edge.top_max -% 1;
            if (edge.bottom_min +% 1 < self.bottom_limit) self.bottom_limit = edge.bottom_min +% 1;
            if (self.bottom_limit < self.view_top) self.bottom_limit = self.view_top;
        } else {
            if (parts.lower_opening) {
                if (edge.bottom_min +% 1 < self.bottom_limit) self.bottom_limit = edge.bottom_min +% 1;
                if (self.bottom_limit < self.view_top) self.bottom_limit = self.view_top;
                self.count += 1;
                return;
            }

            if (self.top_limit < edge.top_max -% 1) self.top_limit = edge.top_max -% 1;
        }

        if (self.view_bottom < self.top_limit) self.top_limit = self.view_bottom;

        self.count += 1;
    }
};

pub const Lighting = struct {
    force_depth: i32,
    depth_bias: i32,
    depth_strength: i32,
    ambient_bias: i32,
    ambient: i32,
    ambient_min: i32,
    color_map: ?[]const u8,
    depth_map: ?*const [128]u8,

    pub fn wallTable(self: Lighting, distance: f32, wall_light: i32) !?*const [256]u8 {
        const color_map = self.color_map orelse return null;
        if (color_map.len < 32 * 256) return error.InvalidColorMap;

        var light = self.ambient_bias +% self.ambient;
        if (light > 30) return null;

        const depth = math.fixed(if (distance <= 0) 0 else distance);
        var depth_light: i32 = 0;

        if (self.force_depth != 0 or (self.depth_map != null and self.depth_strength != 0)) {
            const depth_map = self.depth_map orelse return error.MissingDepthMap;
            var index = depth >> 14;

            if (index > 126) index = 127;

            if (index < 0) return error.InvalidLightDistance;

            const candidate = ((self.depth_strength -% @as(
                i32,
                depth_map[@intCast(index)],
            )) -% self.depth_bias) +% 31;

            if (candidate > 0) depth_light = candidate;
        }

        if (light <= depth_light) light = depth_light;

        light -%= (depth >> 20) +% (depth >> 21);
        var result = self.ambient_min;

        if (self.ambient_min <= light) result = light;

        result +%= wall_light;
        if (result > 30) return null;

        if (result < 1) result = 0;

        const offset: usize = @intCast((31 - result) * 256);

        return color_map[offset..][0..256];
    }

    fn tableTail(self: Lighting, table: ?*const [256]u8) ?[]const u8 {
        const selected = table orelse return null;
        const map = self.color_map.?;

        return map[@intFromPtr(selected) - @intFromPtr(map.ptr) ..];
    }
};

pub const DepthStrip = struct { distance: i16, sector: usize, top: i16, bottom: i16 };

pub const DepthBuffer = struct {
    strips: []DepthStrip,
    counts: []u8,
    furthest: []i16,
    maximum: i16 = 0,

    pub fn init(allocator: std.mem.Allocator, width: usize) !DepthBuffer {
        const strips = try allocator.alloc(DepthStrip, width * 30);
        errdefer allocator.free(strips);
        const counts = try allocator.alloc(u8, width);
        errdefer allocator.free(counts);
        const furthest = try allocator.alloc(i16, width);

        @memset(counts, 0);
        @memset(furthest, 0);

        return .{ .strips = strips, .counts = counts, .furthest = furthest };
    }

    pub fn deinit(self: DepthBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.strips);
        allocator.free(self.counts);
        allocator.free(self.furthest);
    }

    pub fn clear(self: *DepthBuffer) void {
        @memset(self.counts, 0);
        self.maximum = 0;
    }
};

pub const Context = struct {
    view: *const camera.View,
    pixels: []u8,
    clip_top: []const i16,
    clip_bottom: []const i16,
    top_y: []i32,
    bottom_y: []i32,
    window_top: i32,
    window_bottom: i32,
    edges: *EdgeList,
    lighting: Lighting,
    textures: []const texture.Texture,
    depth: *DepthBuffer,
    dynamic_depth: []i16,
    dynamic: bool,

    pub fn recordDepth(self: *Context, x: usize, distance: f32, sector: usize) !void {
        if (self.dynamic) {
            self.dynamic_depth[x] = @truncate(math.fixed(distance) >> 12);
        } else if (self.clip_top[x] <= self.clip_bottom[x]) {
            const top = @max(self.clip_top[x], self.view.top);
            const bottom = @min(self.clip_bottom[x], self.view.bottom);
            const count = self.depth.counts[x];
            if (count >= 30) {
                std.log.debug("wall_FillZBuffer: out of strip space for column {d}", .{x});
                return;
            }

            const fixed: i16 = @truncate(math.fixed(distance) >> 12);

            self.depth.strips[x * 30 + count] = .{
                .distance = fixed,
                .sector = sector,
                .top = @intCast(top),
                .bottom = @intCast(bottom),
            };

            if (count == 0 or self.depth.furthest[x] < fixed) self.depth.furthest[x] = fixed;

            if (self.depth.maximum < fixed) self.depth.maximum = fixed;

            self.depth.counts[x] += 1;
        }
    }

    fn textureAt(self: Context, index: i32) !*const texture.Texture {
        if (index < 0 or index >= self.textures.len) return error.InvalidWallTexture;

        return &self.textures[@intCast(index)];
    }
};

pub const SurfaceEndpoints = struct {
    upper1: f32,
    upper2: f32,
    lower1: f32,
    lower2: f32,
    lower_base: f32,
    lower_sloped: bool,
};

pub const Portal = struct { edge: Edge, projected: projection.ProjectedWall, lower_opening: bool };

pub const WindowList = struct {
    entries: [60]Portal = undefined,
    count: usize = 0,
    total_count: *usize,

    pub fn add(
        self: *WindowList,
        projected: projection.ProjectedWall,
        top: f32,
        top_step: f32,
        bottom: f32,
        bottom_step: f32,
        left: i32,
        count: i32,
        parts: WallParts,
    ) !void {
        if (self.total_count.* > 0x467) {
            std.log.debug("Render_AddWallWindow: exceeded MAX_WALL_WINDOWS", .{});
            return;
        }

        if (self.count > 0x3b) {
            std.log.debug("Render_AddWallWindow: exceeded MAX_ADJOINING_SECTORS", .{});
            return;
        }

        const distance = float(count - 1);
        const top_last = if (@abs(
            top_step,
        ) == 0) top else math.add(math.mul(distance, top_step), top);

        const bottom_last = if (@abs(
            bottom_step,
        ) == 0) bottom else math.add(math.mul(distance, bottom_step), bottom);

        self.entries[self.count] = .{
            .edge = Edge.init(
                top,
                top_last,
                top_step,
                bottom,
                bottom_last,
                bottom_step,
                left,
                count,
                parts.lower_opening,
            ),
            .projected = projected,
            .lower_opening = parts.lower_opening,
        };

        self.total_count.* += 1;
        self.count += 1;
    }
};

pub const AdjoinEndpoints = struct {
    surfaces: SurfaceEndpoints,
    neighbor_upper1: f32,
    neighbor_upper2: f32,
    neighbor_lower1: f32,
    neighbor_lower2: f32,
    neighbor_upper_sloped: bool,
    sector_flags: level.SectorFlags,
    neighbor_flags: level.SectorFlags,
};

const ScreenLine = struct {
    raw_first: f32,
    first: f32,
    last: f32,
    step: f32,

    fn init(
        view: *const camera.View,
        projected: projection.ProjectedWall,
        height1: f32,
        height2: f32,
        sky: ?i32,
    ) ScreenLine {
        const first = if (sky) |value| float(
            value,
        ) else math.sub(
            view.horizon_f,
            math.mul(math.sub(height1, view.y), math.div(view.focal, projected.z1)),
        );

        const last = if (sky) |value| float(
            value,
        ) else math.sub(
            view.horizon_f,
            math.mul(math.sub(height2, view.y), math.div(view.focal, projected.z2)),
        );

        const step = if (projected.left == projected.right) 0 else math.mul(
            math.sub(last, first),
            math.div(1, float(projected.right - projected.left)),
        );

        const offset = float(projected.visible_left - projected.left);

        return .{
            .raw_first = first,
            .first = if (@abs(offset) == 0) first else math.add(math.mul(offset, step), first),
            .last = last,
            .step = step,
        };
    }
};

pub const AdjoinPart = enum { upper, lower, both };

const Strip = struct {
    top: ScreenLine,
    bottom: ScreenLine,
    height: f32,
    height_delta: f32,
    numerator: f32,
    denominator: f32,
    numerator_step: f32,
    denominator_step: f32,
    offset_base: f32,
    offset_numerator: f32,
    offset_denominator: f32,
    offset_numerator_step: f32,
    offset_sloped: bool,

    fn init(
        view: *const camera.View,
        p: projection.ProjectedWall,
        top: ScreenLine,
        bottom: ScreenLine,
        upper1: f32,
        upper2: f32,
        lower1: f32,
        lower2: f32,
        lower_base: f32,
        sloped: bool,
    ) Strip {
        const height = math.mul(math.sub(upper1, lower1), 8);
        const delta = math.sub(math.mul(math.sub(upper2, lower2), 8), height);
        const offset = math.sub(lower1, lower_base);
        const offset_delta = math.sub(math.sub(lower2, lower_base), offset);
        const screen_x = math.sub(float(p.visible_left), view.center_x_f);
        const z_delta = math.sub(p.z2, p.z1);
        const numerator = math.sub(math.mul(p.x1, view.focal), math.mul(p.z1, screen_x));
        const denominator = math.sub(
            math.mul(z_delta, screen_x),
            math.mul(math.sub(p.x2, p.x1), view.focal),
        );

        return .{
            .top = top,
            .bottom = bottom,
            .height = height,
            .height_delta = delta,
            .numerator = math.mul(numerator, delta),
            .denominator = denominator,
            .numerator_step = -math.mul(p.z1, delta),
            .denominator_step = z_delta,
            .offset_base = math.mul(offset, 8),
            .offset_numerator = math.mul(math.mul(numerator, offset_delta), 8),
            .offset_denominator = denominator,
            .offset_numerator_step = math.mul(math.mul(p.z1, offset_delta), -8),
            .offset_sloped = sloped,
        };
    }

    fn sample(self: *Strip) struct { height: f32, offset: f32 } {
        var height = self.height;

        if (math.signedBits(@abs(self.height_delta)) > 0x38d1b716) {
            height = math.add(math.div(self.numerator, self.denominator), self.height);
            self.numerator = math.add(self.numerator_step, self.numerator);
            self.denominator = math.add(self.denominator_step, self.denominator);
        }

        var offset: f32 = 0;

        if (self.offset_sloped) {
            offset = math.add(
                math.div(self.offset_numerator, self.offset_denominator),
                self.offset_base,
            );

            self.offset_numerator = math.add(self.offset_numerator_step, self.offset_numerator);
            self.offset_denominator = math.add(self.denominator_step, self.offset_denominator);
        }

        return .{ .height = height, .offset = offset };
    }
};

pub fn drawSolid(
    ctx: *Context,
    sector_index: usize,
    wall: level.Wall,
    projected: projection.ProjectedWall,
    surfaces: SurfaceEndpoints,
) !void {
    const view = ctx.view;
    const tex = try ctx.textureAt(wall.mid.texture);
    if (tex.width == 0 or tex.height == 0) return error.InvalidWallTexture;

    const wall_mask: u32 = @intCast(tex.height - 1);
    var active_mask = wall_mask;
    const fixed_mask = wall_mask == 63 or wall_mask == 127 or wall_mask == 255 or wall_mask == 511;
    const left = projected.visible_left;
    const right = projected.visible_right;
    if (left < 0 or right >= view.width or right < left) return error.InvalidWallProjection;

    const count = right - left + 1;
    const upper1 = math.sub(surfaces.upper1, view.y);
    const upper2 = math.sub(surfaces.upper2, view.y);
    const lower1 = math.sub(surfaces.lower1, view.y);
    const lower2 = math.sub(surfaces.lower2, view.y);
    var top = math.sub(view.horizon_f, math.mul(math.div(view.focal, projected.z1), upper1));
    const top_last = math.sub(view.horizon_f, math.mul(math.div(view.focal, projected.z2), upper2));
    const intercept = if (projected.axis == 0)
        math.add(math.mul(-projected.slope, projected.x1), projected.z1)
    else
        math.add(math.mul(-projected.slope, projected.z1), projected.x1);

    if (ctx.window_bottom < math.integer(top) and ctx.window_bottom < math.integer(top_last)) {
        @memset(ctx.top_y[@intCast(left)..@intCast(right + 1)], ctx.window_bottom);
        const y = float(ctx.window_bottom + 1);
        try ctx.edges.add(y, 0, y, 0, left, count, .{});

        for (@as(usize, @intCast(left))..@as(usize, @intCast(right + 1))) |x|
            try ctx.recordDepth(
                x,
                intersection(view, projected, x, intercept).distance,
                sector_index,
            );

        return;
    }

    var bottom = math.sub(view.horizon_f, math.mul(math.div(view.focal, projected.z1), lower1));
    const bottom_last = math.sub(
        view.horizon_f,
        math.mul(math.div(view.focal, projected.z2), lower2),
    );

    if (math.integer(bottom) < ctx.window_top and math.integer(bottom_last) < ctx.window_top) {
        @memset(ctx.bottom_y[@intCast(left)..@intCast(right + 1)], ctx.window_top);
        const y = float(ctx.window_top - 1);
        try ctx.edges.add(y, 0, y, 0, left, count, .{});

        for (@as(usize, @intCast(left))..@as(usize, @intCast(right + 1))) |x|
            try ctx.recordDepth(
                x,
                intersection(view, projected, x, intercept).distance,
                sector_index,
            );

        return;
    }

    const step = if (projected.left == projected.right) 0 else math.div(
        1,
        float(projected.right - projected.left),
    );

    const top_step = math.mul(math.sub(top_last, top), step);
    const bottom_step = math.mul(step, math.sub(bottom_last, bottom));
    const screen_offset = float(left - projected.left);

    if (@abs(screen_offset) != 0) {
        top = math.add(math.mul(top_step, screen_offset), top);
        bottom = math.add(math.mul(bottom_step, screen_offset), bottom);
    }

    const height = math.sub(math.mul(upper1, 8), math.mul(lower1, 8));
    const height_delta = math.sub(math.sub(math.mul(upper2, 8), math.mul(lower2, 8)), height);
    const screen_x = math.sub(float(left), view.center_x_f);
    const z_delta = math.sub(projected.z2, projected.z1);
    const height_numerator_step = -math.mul(height_delta, projected.z1);
    var height_numerator = math.mul(
        math.sub(math.mul(projected.x1, view.focal), math.mul(projected.z1, screen_x)),
        height_delta,
    );

    var height_denominator = math.sub(
        math.mul(screen_x, z_delta),
        math.mul(math.sub(projected.x2, projected.x1), view.focal),
    );

    const floor_relative = math.add(lower1, math.sub(view.y, surfaces.lower_base));
    const floor_delta = math.sub(
        math.add(math.sub(view.y, surfaces.lower_base), lower2),
        floor_relative,
    );

    const floor_numerator_step = math.mul(math.mul(floor_delta, projected.z1), -8);
    const floor_base = math.mul(floor_relative, 8);
    var floor_numerator = math.mul(
        math.mul(
            math.sub(math.mul(projected.x1, view.focal), math.mul(projected.z1, screen_x)),
            floor_delta,
        ),
        8,
    );

    var floor_denominator = math.sub(
        math.mul(screen_x, z_delta),
        math.mul(math.sub(projected.x2, projected.x1), view.focal),
    );

    try ctx.edges.add(top, top_step, bottom, bottom_step, left, count, .{});

    var current_top = top;
    var current_bottom = bottom;

    for (@as(usize, @intCast(left))..@as(usize, @intCast(right + 1))) |x| {
        var sample_height = height;

        if (math.signedBits(@abs(height_delta)) > 0x38d1b716) {
            sample_height = math.add(math.div(height_numerator, height_denominator), height);
            height_numerator = math.add(height_numerator_step, height_numerator);
            height_denominator = math.add(z_delta, height_denominator);
        }

        var floor_offset: f32 = 0;

        if (surfaces.lower_sloped) {
            floor_offset = math.add(math.div(floor_numerator, floor_denominator), floor_base);
            floor_numerator = math.add(floor_numerator_step, floor_numerator);
            floor_denominator = math.add(z_delta, floor_denominator);
        }

        var y1 = math.integer(current_top);
        var y2 = math.integer(current_bottom);

        ctx.top_y[x] = y1 -% 1;
        ctx.bottom_y[x] = y2 +% 1;

        if (y1 < ctx.clip_top[x]) y1 = ctx.clip_top[x];

        if (ctx.clip_bottom[x] < y2) y2 = ctx.clip_bottom[x];

        const sample = intersection(view, projected, x, intercept);
        const u = math.add(math.add(sample.u, wall.mid.offset.x), projected.u1);

        try ctx.recordDepth(x, sample.distance, sector_index);

        if (y2 >= y1) {
            if (tex.width == 0 or tex.height == 0) return error.InvalidWallTexture;

            var column_index = @as(
                u32,
                @bitCast(math.fixed(u) >> 16),
            ) & @as(u32, @intCast(tex.width - 1));

            if (wall.flags.flip_texture) column_index = @as(
                u32,
                @intCast(tex.width),
            ) - column_index - 1;

            const dv = math.fixed(
                math.div(sample_height, math.add(math.sub(current_bottom, current_top), 1)),
            );

            const v = math.fixed(
                math.add(
                    math.add(
                        math.mul(
                            math.mul(float(dv), 1.5258789e-05),
                            math.sub(current_bottom, float(y2)),
                        ),
                        wall.mid.offset.z,
                    ),
                    floor_offset,
                ),
            );

            const offset = @as(usize, column_index) << tex.height_shift;
            if (offset >= tex.pixels.len) return error.WallTextureBounds;

            const translation = try ctx.lighting.wallTable(sample.distance, wall.light);

            try raster.column(
                ctx.pixels,
                .{
                    .top = @as(usize, @intCast(y1)) * @as(usize, @intCast(view.width)) + x,
                    .stride = @intCast(view.width),
                    .count = @intCast(y2 - y1 + 1),
                    .texels = tex.pixels[offset..],
                    .mask = if (fixed_mask) wall_mask else active_mask,
                    .v = v,
                    .dv = dv,
                    .fixed_height = fixed_mask,
                },
                ctx.lighting.tableTail(translation),
            );

            if (wall.overlay.texture >= 0) {
                const overlay = try ctx.textureAt(wall.overlay.texture);
                active_mask = @intCast(overlay.height - 1);

                const overlay_left = wall.overlay.offset.x;
                const overlay_right = math.add(float(@intCast(overlay.width)), overlay_left);

                if (overlay_left <= u and u <= overlay_right) {
                    const scale = math.mul(float(dv), 1.5258789e-05);
                    const origin = math.add(math.div(wall.overlay.offset.z, scale), current_bottom);
                    var overlay_top = math.integer(
                        math.add(
                            math.add(
                                math.sub(origin, math.div(float(@intCast(overlay.height)), scale)),
                                1,
                            ),
                            0.5,
                        ),
                    );

                    var overlay_bottom = math.integer(math.add(origin, 0.5));

                    if (y2 < overlay_bottom) overlay_bottom = y2;

                    if (overlay_top < y1) overlay_top = y1;

                    if (overlay_bottom >= overlay_top) {
                        const overlay_v = math.fixed(
                            math.add(
                                math.mul(math.sub(origin, float(overlay_bottom)), scale),
                                floor_offset,
                            ),
                        );

                        const overlay_x = math.integer(math.sub(u, overlay_left));
                        if (overlay_x < 0) return error.OverlayTextureBounds;

                        const overlay_offset = @as(
                            usize,
                            @intCast(overlay_x),
                        ) << overlay.height_shift;

                        if (overlay_offset >= overlay.pixels.len) return error.OverlayTextureBounds;

                        const column_args = raster.Column{
                            .top = @as(
                                usize,
                                @intCast(overlay_top),
                            ) * @as(usize, @intCast(view.width)) + x,
                            .stride = @intCast(view.width),
                            .count = @intCast(overlay_bottom - overlay_top + 1),
                            .texels = overlay.pixels[overlay_offset..],
                            .mask = @intCast(overlay.height - 1),
                            .v = overlay_v,
                            .dv = dv,
                        };

                        const overlay_translation = if (!wall.flags.full_bright_overlay) translation else null;

                        if (overlay.isTransparent()) try raster.overlayColumn(
                            ctx.pixels,
                            column_args,
                            ctx.lighting.tableTail(overlay_translation),
                        ) else try raster.column(
                            ctx.pixels,
                            column_args,
                            ctx.lighting.tableTail(overlay_translation),
                        );
                    }
                }
            }
        }

        current_top = math.add(top_step, current_top);
        current_bottom = math.add(bottom_step, current_bottom);
    }
}

pub fn drawMasked(
    ctx: *Context,
    wall: level.Wall,
    p: projection.ProjectedWall,
    edge: Edge,
    mid_height: f32,
    blend: ?[]const u8,
) !void {
    const tex = try ctx.textureAt(wall.mid.texture);
    if (tex.width == 0 or tex.height == 0) return error.InvalidWallTexture;
    if (edge.count <= 0) return;
    if (edge.left < 0 or edge.left + edge.count > ctx.view.width) return error.InvalidWallProjection;

    const intercept = wallIntercept(p);
    var top = edge.top_first;
    var bottom = edge.bottom_first;

    for (@as(usize, @intCast(edge.left))..@as(usize, @intCast(edge.left + edge.count))) |x| {
        const y1 = @max(math.integer(top), ctx.clip_top[x]);
        const y2 = @min(math.integer(bottom), ctx.clip_bottom[x]);

        if (y2 >= y1) {
            const sample = intersection(ctx.view, p, x, intercept);
            const u = math.add(math.add(sample.u, p.u1), wall.mid.offset.x);
            var column_index = @as(
                u32,
                @bitCast(math.fixed(u) >> 16),
            ) & @as(u32, @intCast(tex.width - 1));

            if (wall.flags.flip_texture) column_index = @as(
                u32,
                @intCast(tex.width),
            ) - column_index - 1;

            const offset = @as(usize, column_index) << tex.height_shift;
            if (offset >= tex.pixels.len) return error.WallTextureBounds;

            const dv = math.fixed(math.div(mid_height, math.add(math.sub(bottom, top), 1)));
            const v = math.fixed(
                math.add(
                    math.mul(math.mul(float(dv), 1.5258789e-05), math.sub(bottom, float(y2))),
                    wall.mid.offset.z,
                ),
            );

            const c = raster.Column{
                .top = @as(usize, @intCast(y1)) * @as(usize, @intCast(ctx.view.width)) + x,
                .stride = @intCast(ctx.view.width),
                .count = @intCast(y2 - y1 + 1),
                .texels = tex.pixels[offset..],
                .mask = @intCast(tex.height - 1),
                .v = v,
                .dv = dv,
                .fixed_height = tex.height == 64 or tex.height == 128 or tex.height == 256 or tex.height == 512,
            };

            const translation = try ctx.lighting.wallTable(sample.distance, wall.light);

            if (wall.flags.translucent and blend != null) try raster.blendedColumn(
                ctx.pixels,
                c,
                blend.?,
            ) else if (tex.isTransparent()) try raster.maskedColumn(
                ctx.pixels,
                c,
                translation,
            ) else try raster.column(ctx.pixels, c, ctx.lighting.tableTail(translation));
        }

        top = math.add(edge.top_step, top);
        bottom = math.add(edge.bottom_step, bottom);
    }
}

pub fn drawOpen(
    ctx: *Context,
    windows: *WindowList,
    sector_index: usize,
    projected: projection.ProjectedWall,
    endpoints: AdjoinEndpoints,
    render_flags: WallParts,
) !void {
    const view = ctx.view;
    const left = projected.visible_left;
    const right = projected.visible_right;
    const count = right - left + 1;
    const range_start: usize = @intCast(left);
    const range_end: usize = @intCast(right + 1);
    const upper_sky = endpoints.sector_flags.sky_ceiling and endpoints.neighbor_flags.sky_ceiling_adjoin;
    const lower_sky = endpoints.sector_flags.sky_floor and endpoints.neighbor_flags.sky_floor_adjoin;
    const top = ScreenLine.init(
        view,
        projected,
        endpoints.surfaces.upper1,
        endpoints.surfaces.upper2,
        if (upper_sky) view.top else null,
    );

    if (ctx.window_bottom < math.integer(
        top.raw_first,
    ) and ctx.window_bottom < math.integer(top.last)) {
        if (!render_flags.lower_opening) @memset(ctx.top_y[range_start..range_end], ctx.window_bottom);
        const y = float(ctx.window_bottom + 1);
        try ctx.edges.add(y, 0, y, 0, left, count, render_flags);
        return depthRange(ctx, sector_index, projected);
    }

    const bottom = ScreenLine.init(
        view,
        projected,
        endpoints.surfaces.lower1,
        endpoints.surfaces.lower2,
        if (lower_sky) view.bottom else null,
    );

    if (math.integer(
        bottom.raw_first,
    ) < ctx.window_top and math.integer(bottom.last) < ctx.window_top) {
        if (!upperOpening(render_flags)) @memset(ctx.bottom_y[range_start..range_end], ctx.window_top);

        if (upperOpening(render_flags) and endpoints.sector_flags.sky_ceiling) @memset(
            ctx.top_y[range_start..range_end],
            ctx.window_top - 1,
        );

        const y = float(ctx.window_top - 1);
        try ctx.edges.add(y, 0, y, 0, left, count, render_flags);
        return depthRange(ctx, sector_index, projected);
    }

    try ctx.edges.add(top.first, top.step, bottom.first, bottom.step, left, count, render_flags);

    if (endpoints.neighbor_lower1 < endpoints.neighbor_upper1)
        try windows.add(
            projected,
            top.first,
            top.step,
            bottom.first,
            bottom.step,
            left,
            count,
            render_flags,
        );

    const intercept = wallIntercept(projected);
    var y1 = top.first;
    var y2 = bottom.first;

    for (range_start..range_end) |x| {
        if (!render_flags.double_adjoin or !render_flags.lower_opening) ctx.top_y[x] = math.integer(y1) -% 1;

        if (!render_flags.double_adjoin or render_flags.lower_opening) ctx.bottom_y[x] = math.integer(y2) +% 1;

        try ctx.recordDepth(x, intersection(view, projected, x, intercept).distance, sector_index);

        y1 = math.add(y1, top.step);
        y2 = math.add(y2, bottom.step);
    }
}

pub fn drawAdjoin(
    ctx: *Context,
    windows: *WindowList,
    sector_index: usize,
    wall: level.Wall,
    p: projection.ProjectedWall,
    e: AdjoinEndpoints,
    render_flags: WallParts,
    part: AdjoinPart,
) !void {
    const view = ctx.view;
    const left = p.visible_left;
    const right = p.visible_right;
    const start: usize = @intCast(left);
    const end: usize = @intCast(right + 1);
    const count = right - left + 1;
    const upper_sky = part == .lower and e.sector_flags.sky_ceiling and e.neighbor_flags.sky_ceiling_adjoin;
    const lower_sky = part == .upper and e.sector_flags.sky_floor and e.neighbor_flags.sky_floor_adjoin;
    const top = ScreenLine.init(
        view,
        p,
        e.surfaces.upper1,
        e.surfaces.upper2,
        if (upper_sky) view.top else null,
    );

    if (ctx.window_bottom < math.integer(
        top.raw_first,
    ) and ctx.window_bottom < math.integer(top.last)) {
        if (!render_flags.lower_opening) @memset(ctx.top_y[start..end], ctx.window_bottom);
        const y = float(ctx.window_bottom + 1);
        try ctx.edges.add(y, 0, y, 0, left, count, render_flags);
        return depthRange(ctx, sector_index, p);
    }

    const bottom = ScreenLine.init(
        view,
        p,
        e.surfaces.lower1,
        e.surfaces.lower2,
        if (lower_sky) view.bottom else null,
    );

    if (math.integer(
        bottom.raw_first,
    ) < ctx.window_top and math.integer(bottom.last) < ctx.window_top) {
        if (!upperOpening(render_flags)) @memset(ctx.bottom_y[start..end], ctx.window_top);
        const y = float(ctx.window_top - 1);
        try ctx.edges.add(y, 0, y, 0, left, count, render_flags);
        return depthRange(ctx, sector_index, p);
    }

    const neighbor_top = ScreenLine.init(view, p, e.neighbor_upper1, e.neighbor_upper2, null);
    const neighbor_bottom = ScreenLine.init(view, p, e.neighbor_lower1, e.neighbor_lower2, null);
    const upper_offscreen = math.integer(
        neighbor_top.first,
    ) < ctx.window_top and math.integer(neighbor_top.last) < ctx.window_top;

    const lower_offscreen = ctx.window_bottom < math.integer(
        neighbor_bottom.first,
    ) and ctx.window_bottom < math.integer(neighbor_bottom.last);

    if (part != .both) try ctx.edges.add(
        top.first,
        top.step,
        bottom.first,
        bottom.step,
        left,
        count,
        render_flags,
    );

    if (part == .upper) {
        if ((math.integer(
            neighbor_top.first,
        ) < ctx.window_bottom or math.integer(
            neighbor_top.last,
        ) < ctx.window_bottom) and e.surfaces.lower1 < e.neighbor_upper1)
            try windows.add(
                p,
                math.add(neighbor_top.first, 1),
                neighbor_top.step,
                bottom.first,
                bottom.step,
                left,
                count,
                render_flags,
            );
    } else if (part == .lower) {
        if ((ctx.window_top < math.integer(
            neighbor_bottom.first,
        ) or ctx.window_top < math.integer(
            neighbor_bottom.last,
        )) and e.neighbor_lower1 < e.surfaces.upper1)
            try windows.add(
                p,
                top.first,
                top.step,
                math.sub(neighbor_bottom.first, 1),
                neighbor_bottom.step,
                left,
                count,
                render_flags,
            );
    }

    if (part != .lower) {
        if (upper_offscreen) {
            if (!render_flags.lower_opening) @memset(ctx.top_y[start..end], ctx.window_top - 1);

            if (part == .upper) {
                if (upperOpening(render_flags) and e.sector_flags.sky_ceiling) @memset(
                    ctx.top_y[start..end],
                    ctx.window_top - 1,
                );

                var y = bottom.first;

                for (start..end) |x| {
                    const clipped = @min(math.integer(y), ctx.clip_bottom[x]);
                    if (!upperOpening(render_flags)) ctx.bottom_y[x] = clipped +% 1;
                    y = math.add(y, bottom.step);
                }

                try depthRange(ctx, sector_index, p);
            }
        } else {
            const strip = Strip.init(
                view,
                p,
                top,
                neighbor_top,
                e.surfaces.upper1,
                e.surfaces.upper2,
                e.neighbor_upper1,
                e.neighbor_upper2,
                e.surfaces.lower_base,
                e.neighbor_upper_sloped,
            );

            try drawStrip(
                ctx,
                sector_index,
                wall,
                p,
                strip,
                .upper,
                part == .both,
                top,
                bottom,
                render_flags,
            );
        }
    }

    if (part != .upper) {
        if (lower_offscreen) {
            if (!upperOpening(render_flags)) @memset(ctx.bottom_y[start..end], ctx.window_bottom + 1);

            if (part == .lower) {
                var y = top.first;

                for (start..end) |x| {
                    if (!render_flags.lower_opening) ctx.top_y[x] = math.integer(y) -% 1;
                    y = math.add(y, top.step);
                }

                try depthRange(ctx, sector_index, p);
            }
        } else {
            const strip = Strip.init(
                view,
                p,
                neighbor_bottom,
                bottom,
                e.neighbor_lower1,
                e.neighbor_lower2,
                e.surfaces.lower1,
                e.surfaces.lower2,
                e.surfaces.lower_base,
                e.surfaces.lower_sloped,
            );

            try drawStrip(
                ctx,
                sector_index,
                wall,
                p,
                strip,
                .lower,
                part == .both,
                top,
                bottom,
                render_flags,
            );
        }
    }

    if (part == .both) {
        try ctx.edges.add(
            top.first,
            top.step,
            bottom.first,
            bottom.step,
            left,
            count,
            render_flags,
        );

        if ((ctx.window_top < math.integer(
            neighbor_bottom.first,
        ) or ctx.window_top < math.integer(neighbor_bottom.last)) and
            (math.integer(
                neighbor_top.first,
            ) < ctx.window_bottom or math.integer(neighbor_top.last) < ctx.window_bottom) and
            e.neighbor_lower1 < e.neighbor_upper1)
            try windows.add(
                p,
                math.add(neighbor_top.first, 1),
                neighbor_top.step,
                math.sub(neighbor_bottom.first, 1),
                neighbor_bottom.step,
                left,
                count,
                render_flags,
            );
    }
}

/// Drawing the upper of two openings.
fn upperOpening(parts: WallParts) bool {
    return parts.double_adjoin and !parts.lower_opening;
}

fn float(value: i32) f32 {
    return @floatFromInt(value);
}

fn intersection(
    view: *const camera.View,
    wall: projection.ProjectedWall,
    x: usize,
    intercept: f32,
) struct { distance: f32, u: f32 } {
    if (wall.axis == 0) {
        const delta = math.sub(
            math.div(intercept, math.sub(view.reciprocal_x[x], wall.slope)),
            wall.x1,
        );

        return .{
            .distance = math.add(math.mul(delta, wall.slope), wall.z1),
            .u = math.mul(wall.u_scale, delta),
        };
    }

    const distance = math.div(intercept, math.sub(view.ray_x[x], wall.slope));

    return .{ .distance = distance, .u = math.mul(math.sub(distance, wall.z1), wall.u_scale) };
}

fn wallIntercept(wall: projection.ProjectedWall) f32 {
    return if (wall.axis == 0) math.add(
        math.mul(-wall.slope, wall.x1),
        wall.z1,
    ) else math.add(math.mul(-wall.slope, wall.z1), wall.x1);
}

fn depthRange(ctx: *Context, sector_index: usize, projected: projection.ProjectedWall) !void {
    const intercept = wallIntercept(projected);

    for (@as(
        usize,
        @intCast(projected.visible_left),
    )..@as(usize, @intCast(projected.visible_right + 1))) |x|
        try ctx.recordDepth(
            x,
            intersection(ctx.view, projected, x, intercept).distance,
            sector_index,
        );
}

fn drawStrip(
    ctx: *Context,
    sector_index: usize,
    wall: level.Wall,
    p: projection.ProjectedWall,
    strip_value: Strip,
    part: enum { upper, lower },
    both: bool,
    outer_top: ScreenLine,
    outer_bottom: ScreenLine,
    render_flags: WallParts,
) !void {
    var strip = strip_value;
    const view = ctx.view;
    const reference = if (part == .upper) wall.top else wall.bottom;
    const tex = try ctx.textureAt(reference.texture);
    if (tex.width == 0 or tex.height == 0) return error.InvalidWallTexture;

    const wall_mask: u32 = @intCast(tex.height - 1);
    var active_mask = wall_mask;
    const fixed_mask = wall_mask == 63 or wall_mask == 127 or wall_mask == 255 or wall_mask == 511;
    const intercept = wallIntercept(p);
    var y_top = strip.top.first;
    var y_bottom = strip.bottom.first;
    var plane_top = outer_top.first;
    var plane_bottom = outer_bottom.first;

    for (@as(usize, @intCast(p.visible_left))..@as(usize, @intCast(p.visible_right + 1))) |x| {
        const ratio = strip.sample();
        var y1 = math.integer(y_top);
        var y2 = math.integer(y_bottom);

        if (part == .upper) y1 +%= @intFromBool(render_flags.lower_opening);

        if (both) {
            if (part == .upper and !render_flags.lower_opening) ctx.top_y[x] = y1 -% 1;
            if (part == .lower and !upperOpening(render_flags)) ctx.bottom_y[x] = y2 +% 1;
        } else {
            if (!render_flags.double_adjoin or !render_flags.lower_opening)
                ctx.top_y[x] = if (part == .upper) y1 -% 1 else math.integer(plane_top) -% 1;

            if (!render_flags.double_adjoin or render_flags.lower_opening)
                ctx.bottom_y[x] = if (part == .lower) y2 +% 1 else math.integer(plane_bottom) +% 1;
        }

        if (y1 < ctx.clip_top[x]) y1 = ctx.clip_top[x];

        if (ctx.clip_bottom[x] < y2) y2 = ctx.clip_bottom[x];

        const sample = intersection(view, p, x, intercept);
        const u = if (part == .upper) math.add(
            math.add(sample.u, p.u1),
            reference.offset.x,
        ) else math.add(math.add(sample.u, reference.offset.x), p.u1);

        try ctx.recordDepth(x, sample.distance, sector_index);

        if (y2 >= y1) {
            var column_index = @as(
                u32,
                @bitCast(math.fixed(u) >> 16),
            ) & @as(u32, @intCast(tex.width - 1));

            if (wall.flags.flip_texture) column_index = @as(
                u32,
                @intCast(tex.width),
            ) - column_index - 1;

            const dv = math.fixed(math.div(ratio.height, math.add(math.sub(y_bottom, y_top), 1)));
            const v = math.fixed(
                math.add(
                    math.add(
                        math.mul(math.mul(float(dv), 1.5258789e-05), math.sub(y_bottom, float(y2))),
                        ratio.offset,
                    ),
                    reference.offset.z,
                ),
            );

            const offset = @as(usize, column_index) << tex.height_shift;
            if (offset >= tex.pixels.len) return error.WallTextureBounds;

            const translation = try ctx.lighting.wallTable(sample.distance, wall.light);

            try raster.column(
                ctx.pixels,
                .{
                    .top = @as(usize, @intCast(y1)) * @as(usize, @intCast(view.width)) + x,
                    .stride = @intCast(view.width),
                    .count = @intCast(y2 - y1 + 1),
                    .texels = tex.pixels[offset..],
                    .mask = if (fixed_mask) wall_mask else active_mask,
                    .v = v,
                    .dv = dv,
                    .fixed_height = fixed_mask,
                },
                ctx.lighting.tableTail(translation),
            );

            if ((!both or part == .lower) and wall.overlay.texture >= 0) {
                const overlay = try ctx.textureAt(wall.overlay.texture);
                active_mask = @intCast(overlay.height - 1);

                const overlay_left = wall.overlay.offset.x;
                const overlay_right = math.add(float(@intCast(overlay.width)), overlay_left);

                if (overlay_left <= u and u <= overlay_right) {
                    const scale = math.mul(float(dv), 1.5258789e-05);
                    const origin = math.add(math.div(wall.overlay.offset.z, scale), y_bottom);
                    var overlay_top = math.integer(
                        math.add(
                            math.add(
                                math.sub(origin, math.div(float(@intCast(overlay.height)), scale)),
                                1,
                            ),
                            0.5,
                        ),
                    );

                    var overlay_bottom = math.integer(math.add(origin, 0.5));

                    if (y2 < overlay_bottom) overlay_bottom = y2;

                    if (overlay_top < y1) overlay_top = y1;

                    if (overlay_bottom >= overlay_top) {
                        const overlay_v = math.fixed(
                            math.add(
                                math.mul(
                                    math.mul(math.sub(origin, float(overlay_bottom)), float(dv)),
                                    1.5258789e-05,
                                ),
                                ratio.offset,
                            ),
                        );

                        const overlay_x = math.integer(math.sub(u, overlay_left));
                        if (overlay_x < 0) return error.OverlayTextureBounds;

                        const overlay_offset = @as(
                            usize,
                            @intCast(overlay_x),
                        ) << overlay.height_shift;

                        if (overlay_offset >= overlay.pixels.len) return error.OverlayTextureBounds;

                        const args = raster.Column{
                            .top = @as(
                                usize,
                                @intCast(overlay_top),
                            ) * @as(usize, @intCast(view.width)) + x,
                            .stride = @intCast(view.width),
                            .count = @intCast(overlay_bottom - overlay_top + 1),
                            .texels = overlay.pixels[overlay_offset..],
                            .mask = active_mask,
                            .v = overlay_v,
                            .dv = dv,
                        };

                        const overlay_translation = if (!wall.flags.full_bright_overlay) translation else null;

                        if (overlay.isTransparent()) try raster.overlayColumn(
                            ctx.pixels,
                            args,
                            ctx.lighting.tableTail(overlay_translation),
                        ) else try raster.column(
                            ctx.pixels,
                            args,
                            ctx.lighting.tableTail(overlay_translation),
                        );
                    }
                }
            }
        }

        y_top = math.add(y_top, strip.top.step);
        y_bottom = math.add(y_bottom, strip.bottom.step);
        plane_top = math.add(plane_top, outer_top.step);
        plane_bottom = math.add(plane_bottom, outer_bottom.step);
    }
}

test "wall-edge record preserves minima, maxima and branch-specific limits" {
    try std.testing.expectEqual(@as(usize, 60), @sizeOf(Edge));
    try std.testing.expectEqual(@as(usize, 0x30), @offsetOf(Edge, "left"));

    var edges = EdgeList{ .view_top = 0, .view_bottom = 479, .top_limit = -1, .bottom_limit = 480 };
    try edges.add(10.9, -0.5, 30.9, 0.25, 3, 5, .{});
    const edge = edges.entries[0];

    try std.testing.expectEqual(@as(i32, 8), edge.top_min);
    try std.testing.expectEqual(@as(i32, 10), edge.top_max);
    try std.testing.expectEqual(@as(i32, 31), edge.bottom_max);
    try std.testing.expectEqual(@as(i32, 30), edge.bottom_min);
    try std.testing.expectEqual(@as(i32, 7), edge.right);
    try std.testing.expectEqual(@as(i32, 9), edges.top_limit);
    try std.testing.expectEqual(@as(i32, 31), edges.bottom_limit);
}

test "wall raster paths match isolated reference routines" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/walls-reference.json",
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(bytes);
    const Case = struct {
        kind: []const u8,
        variant: []const u8,
        lit: bool,
        initial_depth_count: u8 = 0,
        repeats: usize = 1,
        initial_edge_count: usize = 0,
        initial_window_count: usize = 0,
        initial_total_windows: usize = 1,
        heights: [4]f32,
        floor_base: f32,
        render_flags: u32,
        slopes: [][]f32,
        projection: [16]u32,
        pixels: []const u8,
        top_y: []const u8,
        bottom_y: []const u8,
        edges: []const u8,
        edge_count: usize,
        window_count: usize,
        total_windows: ?usize = null,
        windows: []const u8,
        limits: [2]i32,
        depth_counts: []const u8,
        dynamic_depth: []const u8,
        strips: []const u8,
        furthest: ?[]const u8 = null,
        maximum: ?i16 = null,
    };

    const parsed = try std.json.parseFromSlice(
        struct { executable_sha256: []const u8, cases: []Case },
        allocator,
        bytes,
        .{},
    );

    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.executable_sha256,
    );

    const angles = camera.Angles.init();
    var view = try camera.View.init(allocator, &angles, 64, 48);
    defer view.deinit(allocator);
    var texels: [4096]u8 = undefined;

    for (&texels, 0..) |*value, i| value.* = @intCast((i % 64) * 3 + i / 64);

    var overlay_texels: [2048]u8 = undefined;

    for (&overlay_texels, 0..) |*value, i| value.* = @truncate(i * 13);

    var blend: [17 * 256]u8 = undefined;

    for (&blend, 0..) |*value, i| value.* = @truncate((i / 256) * 7 + (i % 256) * 3);

    const lab = @import("../../../assets/lab.zig");
    const texture_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLTEX.LAB",
        allocator,
        .limited(100 * 1024 * 1024),
    );

    defer allocator.free(texture_bytes);
    const texture_archive = try lab.Archive.init(texture_bytes);
    const asset_wall = try texture.decode(allocator, try texture_archive.find("GWBRWN2.PCX", 0));
    defer asset_wall.deinit(allocator);
    const asset_fence = try texture.decode(allocator, try texture_archive.find("GWFENCE1.PCX", 0));
    defer asset_fence.deinit(allocator);
    const system_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB",
        allocator,
        .limited(100 * 1024 * 1024),
    );

    defer allocator.free(system_bytes);
    const system_archive = try lab.Archive.init(system_bytes);
    const asset_cmap = try texture.decodeColorMap(
        allocator,
        try system_archive.find("HIDEOUT.PCX", 0),
    );

    defer allocator.free(asset_cmap);
    var cmap: [8192]u8 = undefined;

    for (&cmap, 0..) |*value, i| value.* = @truncate((i % 256) + (i / 256) * 3);

    var failures: usize = 0;

    for (parsed.value.cases) |case| {
        const generic = std.mem.eql(u8, case.variant, "generic_overlay");
        const asset = std.mem.eql(u8, case.variant, "asset");
        const masked = std.mem.eql(u8, case.kind, "masked");
        const overlay = std.mem.indexOf(u8, case.variant, "overlay") != null;
        const transparent = std.mem.eql(
            u8,
            case.variant,
            "transparent",
        ) or std.mem.startsWith(u8, case.variant, "blend");

        const tall_overlay = std.mem.eql(u8, case.variant, "overlay_sloped");
        const textures = [_]texture.Texture{
            if (asset) (if (masked) asset_fence else asset_wall) else .{
                .width = 64,
                .height = if (generic) 32 else 64,
                .pixels = texels[0..if (generic) 2048 else 4096],
                .height_shift = if (generic) 5 else 6,
                .flags = .{ .width_power_of_two = true, .height_power_of_two = true, .transparent = transparent },
            },
            .{
                .width = 16,
                .height = if (tall_overlay) 128 else 16,
                .pixels = overlay_texels[0..if (tall_overlay) 2048 else 256],
                .height_shift = if (tall_overlay) 7 else 4,
                .flags = .{ .width_power_of_two = true, .height_power_of_two = true, .transparent = true },
            },
        };

        var pixels = [_]u8{197} ** (64 * 48);
        var top_y = [_]i32{-12345} ** 64;
        var bottom_y = [_]i32{12345} ** 64;
        const clip_top = [_]i16{0} ** 64;
        const clip_bottom = [_]i16{47} ** 64;
        var dynamic_depth = [_]i16{0} ** 64;
        var edges = EdgeList{
            .count = case.initial_edge_count,
            .view_top = 0,
            .view_bottom = 47,
            .top_limit = -1,
            .bottom_limit = 48,
        };

        @memset(edges.entries[0..edges.count], std.mem.zeroes(Edge));

        var total_windows = case.initial_total_windows;
        var windows = WindowList{
            .count = case.initial_window_count,
            .total_count = &total_windows,
        };

        @memset(windows.entries[0..windows.count], std.mem.zeroes(Portal));

        var depth = try DepthBuffer.init(allocator, 64);
        defer depth.deinit(allocator);

        if (case.initial_depth_count != 0) {
            @memset(depth.counts, case.initial_depth_count);
            @memset(depth.furthest, -123);

            depth.maximum = -123;

            for (0..64) |x| for (0..case.initial_depth_count) |i| {
                depth.strips[x * 30 + i] = .{
                    .distance = -123,
                    .sector = 0,
                    .top = -7,
                    .bottom = 12,
                };
            };
        }

        var ctx = Context{
            .view = &view,
            .pixels = &pixels,
            .clip_top = &clip_top,
            .clip_bottom = &clip_bottom,
            .top_y = &top_y,
            .bottom_y = &bottom_y,
            .window_top = 0,
            .window_bottom = 47,
            .edges = &edges,
            .lighting = .{
                .force_depth = 0,
                .depth_bias = 0,
                .depth_strength = 0,
                .ambient_bias = 0,
                .ambient = 18,
                .ambient_min = 15,
                .color_map = if (case.lit) (if (asset) asset_cmap else &cmap) else null,
                .depth_map = null,
            },
            .textures = &textures,
            .depth = &depth,
            .dynamic_depth = &dynamic_depth,
            .dynamic = std.mem.eql(u8, case.variant, "dynamic"),
        };

        const b = case.projection;
        const p = projection.ProjectedWall{
            .wall_index = 0,
            .left = @bitCast(b[0]),
            .right = @bitCast(b[1]),
            .z1 = @bitCast(b[2]),
            .z2 = @bitCast(b[3]),
            .u1 = @bitCast(b[4]),
            .x1 = @bitCast(b[5]),
            .x2 = @bitCast(b[6]),
            .visible_left = @bitCast(b[7]),
            .visible_right = @bitCast(b[8]),
            .axis = @bitCast(b[9]),
            .slope = @bitCast(b[10]),
            .u_scale = @bitCast(b[11]),
            .world_x1 = @bitCast(b[12]),
            .world_z1 = @bitCast(b[13]),
            .world_x2 = @bitCast(b[14]),
            .world_z2 = @bitCast(b[15]),
        };

        var wall = std.mem.zeroes(level.Wall);

        wall.top = .{ .texture = 0, .offset = .{ .x = 1.25, .z = 4.5 } };
        wall.mid = .{ .texture = 0, .offset = .{ .x = 2.75, .z = 5.75 } };
        wall.bottom = .{ .texture = 0, .offset = .{ .x = 3.125, .z = 6.125 } };
        wall.overlay = .{ .texture = if (overlay) 1 else -1, .offset = .{ .x = 25, .z = -6.25 } };
        wall.light = -2;
        wall.flags = .{
            .flip_texture = std.mem.eql(u8, case.variant, "flipped"),
            .full_bright_overlay = std.mem.eql(u8, case.variant, "overlay_unlit"),
            .translucent = std.mem.startsWith(u8, case.variant, "blend"),
        };

        var h: [4][2]f32 = undefined;

        for (&h, 0..) |*pair, i| {
            pair.* = .{ case.heights[i], case.heights[i] };

            if (case.slopes.len != 0) {
                const slope = case.slopes[i];
                pair.* = .{
                    math.sub(
                        math.sub(slope[2], math.mul(slope[1], p.world_z1)),
                        math.mul(slope[0], p.world_x1),
                    ),
                    math.sub(
                        math.sub(slope[2], math.mul(slope[1], p.world_z2)),
                        math.mul(slope[0], p.world_x2),
                    ),
                };
            }
        }

        const surfaces = SurfaceEndpoints{
            .upper1 = h[0][0],
            .upper2 = h[0][1],
            .lower1 = h[1][0],
            .lower2 = h[1][1],
            .lower_base = case.floor_base,
            .lower_sloped = case.slopes.len != 0,
        };

        const endpoints = AdjoinEndpoints{
            .surfaces = surfaces,
            .neighbor_upper1 = h[2][0],
            .neighbor_upper2 = h[2][1],
            .neighbor_lower1 = h[3][0],
            .neighbor_lower2 = h[3][1],
            .neighbor_upper_sloped = case.slopes.len != 0,
            .sector_flags = if (std.mem.endsWith(u8, case.variant, "sky")) .{ .sky_ceiling = true, .sky_floor = true } else .{},
            .neighbor_flags = if (std.mem.endsWith(u8, case.variant, "sky")) .{ .sky_ceiling_adjoin = true, .sky_floor_adjoin = true } else .{},
        };

        for (0..case.repeats) |_| {
            if (masked) {
                const edge = Edge.init(
                    -3.25,
                    0,
                    0.25,
                    49.75,
                    0,
                    -0.125,
                    p.visible_left,
                    p.visible_right - p.visible_left + 1,
                    false,
                );

                try drawMasked(
                    &ctx,
                    wall,
                    p,
                    edge,
                    120,
                    if (std.mem.eql(u8, case.variant, "blend")) &blend else null,
                );
            } else if (std.mem.eql(
                u8,
                case.kind,
                "solid",
            )) try drawSolid(
                &ctx,
                0,
                wall,
                p,
                surfaces,
            ) else if (std.mem.eql(
                u8,
                case.kind,
                "open",
            )) try drawOpen(&ctx, &windows, 0, p, endpoints, bits.from(WallParts, case.render_flags)) else {
                const part = std.meta.stringToEnum(AdjoinPart, case.kind).?;
                drawAdjoin(
                    &ctx,
                    &windows,
                    0,
                    wall,
                    p,
                    endpoints,
                    bits.from(WallParts, case.render_flags),
                    part,
                ) catch |err| {
                    std.debug.print(
                        "\n{s} {s} lit={}: {}\n",
                        .{ case.kind, case.variant, case.lit, err },
                    );

                    return err;
                };
            }
        }

        var window_data: [60 * 60]u8 = undefined;

        for (windows.entries[0..windows.count], 0..) |entry, i| @memcpy(
            window_data[i * 60 ..][0..60],
            std.mem.asBytes(&entry.edge),
        );

        var depth_data = [_]u8{0} ** (64 * 30 * 12);

        for (depth.counts, 0..) |count, x| for (0..count) |i| {
            const entry = depth.strips[x * 30 + i];
            const out = depth_data[(x * 30 + i) * 12 ..][0..12];

            std.mem.writeInt(i16, out[0..2], entry.distance, .little);
            std.mem.writeInt(i16, out[8..10], entry.top, .little);
            std.mem.writeInt(i16, out[10..12], entry.bottom, .little);
        };

        const checks = .{
            .{ "pixels", case.pixels, &pixels },
            .{ "top_y", case.top_y, std.mem.sliceAsBytes(&top_y) },
            .{ "bottom_y", case.bottom_y, std.mem.sliceAsBytes(&bottom_y) },
            .{ "edges", case.edges, std.mem.sliceAsBytes(edges.entries[0..edges.count]) },
            .{ "windows", case.windows, window_data[0 .. windows.count * 60] },
            .{ "depth_counts", case.depth_counts, depth.counts },
            .{ "dynamic_depth", case.dynamic_depth, std.mem.sliceAsBytes(&dynamic_depth) },
            .{ "strips", case.strips, &depth_data },
        };

        inline for (checks) |check| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(check[2], &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);

            if (!std.mem.eql(u8, check[1], &hex)) {
                std.debug.print(
                    "\n{s} {s} lit={} {s}: got {s} expected {s}\n",
                    .{ case.kind, case.variant, case.lit, check[0], hex, check[1] },
                );

                failures += 1;
            }
        }

        if (edges.count != case.edge_count or windows.count != case.window_count or edges.top_limit != case.limits[0] or edges.bottom_limit != case.limits[1]) {
            std.debug.print(
                "\n{s} {s}: edge/window counts or limits differ\n",
                .{ case.kind, case.variant },
            );

            failures += 1;
        }

        if (case.furthest) |expected| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(depth.furthest), &digest, .{});
            try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(digest, .lower));
        }

        if (case.maximum) |expected| try std.testing.expectEqual(expected, depth.maximum);

        if (case.total_windows) |expected| try std.testing.expectEqual(expected, total_windows);
    }

    try std.testing.expectEqual(@as(usize, 0), failures);
}
