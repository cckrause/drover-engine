//! The software renderer's frame: walks the level from the player's sector
//! through portals and draws what is visible.
//!
//! The view window is established before the walk starts, and each recursion
//! carries its own window; a restored window means the walk came back out of
//! a portal. Sector visitation state is per frame, so a sector reached twice
//! through different portals is drawn twice with different windows.

const std = @import("std");
const level_module = @import("../../../assets/level.zig");
const texture = @import("../../../assets/texture.zig");
const scene_module = @import("../../scene.zig");
const objects_module = @import("../../objects.zig");
const camera = @import("camera.zig");
const projection = @import("projection.zig");
const visibility = @import("visibility.zig");
const walls = @import("walls.zig");
const planes = @import("planes.zig");
const raster = @import("raster.zig");
const ripple = @import("ripple.zig");
const m = @import("math.zig");

pub const Frame = struct {
    arena: std.heap.ArenaAllocator,
    view: *const camera.View,
    angles: *const camera.Angles,
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    textures: []const texture.Texture,
    pixels: []u8,
    lighting: walls.Lighting,
    arithmetic: raster.SpanArithmetic,
    blend_table: ?[]const u8 = null,
    objects: ?*objects_module.Objects = null,
    ticks: u32,
    depth: walls.DepthBuffer,
    edges: *walls.EdgeList,
    top_y: []i32,
    bottom_y: []i32,
    cached: []?[]visibility.Wall,
    active: [][]bool,
    visited: []bool,
    model_sectors: []bool,
    completed: []bool,
    dynamic_depths: []i16,
    total_windows: usize = 1,
    total_projected: usize = 0,
    total_filtered: usize = 0,
    sector_visits: usize = 0,

    pub fn init(allocator: std.mem.Allocator, view: *const camera.View, angles: *const camera.Angles, level: *const level_module.Level, scene: *const scene_module.Scene, textures: []const texture.Texture, pixels: []u8, lighting: walls.Lighting, arithmetic: raster.SpanArithmetic, ticks: u32) !Frame {
        if (pixels.len != @as(usize, @intCast(view.width)) * @as(usize, @intCast(view.height))) return error.InvalidFramebuffer;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const width: usize = @intCast(view.width);
        const active = try a.alloc([]bool, level.sectors.len);
        for (active, level.sectors) |*flags, sector| {
            flags.* = try a.alloc(bool, sector.walls.len);
            @memset(flags.*, false);
        }
        const cached = try a.alloc(?[]visibility.Wall, level.sectors.len);
        @memset(cached, null);
        const visited = try a.alloc(bool, level.sectors.len);
        @memset(visited, false);
        const model_sectors = try a.alloc(bool, level.sectors.len);
        @memset(model_sectors, false);
        const completed = try a.alloc(bool, level.sectors.len);
        @memset(completed, false);
        const edges = try a.create(walls.EdgeList);
        edges.* = .{ .view_top = view.top, .view_bottom = view.bottom, .top_limit = view.top - 1, .bottom_limit = view.bottom + 1 };
        const depth_buffer = try walls.DepthBuffer.init(a, width);
        const top_y = try a.alloc(i32, width);
        const bottom_y = try a.alloc(i32, width);
        const dynamic_depths = try a.alloc(i16, width * 140);
        @memset(dynamic_depths, 0);
        return .{
            .arena = arena,
            .view = view,
            .angles = angles,
            .level = level,
            .scene = scene,
            .textures = textures,
            .pixels = pixels,
            .lighting = lighting,
            .arithmetic = arithmetic,
            .ticks = ticks,
            .depth = depth_buffer,
            .edges = edges,
            .top_y = top_y,
            .bottom_y = bottom_y,
            .cached = cached,
            .active = active,
            .visited = visited,
            .model_sectors = model_sectors,
            .completed = completed,
            .dynamic_depths = dynamic_depths,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn draw(self: *Frame, sector: usize) !void {
        if (sector >= self.level.sectors.len) return error.InvalidCameraSector;
        const a = self.arena.allocator();
        const width: usize = @intCast(self.view.width);
        const top = try a.alloc(i16, width);
        const bottom = try a.alloc(i16, width);
        @memset(top, @intCast(self.view.top));
        @memset(bottom, @intCast(self.view.bottom));
        const dynamic_depth = self.dynamic_depths[0..width];
        const window = planes.ClipWindow{
            .left = self.view.left,
            .right = self.view.right,
            .top = self.view.top,
            .bottom = self.view.bottom,
            .inner_top = self.view.top,
            .inner_bottom = self.view.bottom,
            .top_clip = top,
            .bottom_clip = bottom,
        };
        try self.drawSector(sector, window, null, 0, 1, false, dynamic_depth);
        if (self.objects) |objects| try objects.drawFinal(&self.depth);
    }

    fn projected(self: *Frame, sector_index: usize) ![]visibility.Wall {
        if (self.cached[sector_index]) |cached| return cached;
        const a = self.arena.allocator();
        const sector = self.level.sectors[sector_index];
        const transformed = try a.alloc(projection.Vec2, sector.vertices.len);
        try projection.transform(self.view, sector.vertices, transformed);
        const result = try a.alloc(visibility.Wall, sector.walls.len);
        var count: usize = 0;
        const own = self.scene.sectors[sector_index];
        const own_slope = own.floor_slope != null or own.ceiling_slope != null;
        for (sector.walls, self.scene.sectors[sector_index].walls, 0..) |wall, state, index| {
            var slopes = own_slope;
            for ([_]i32{ wall.adjoin, wall.dadjoin }) |neighbor| {
                if (neighbor >= 0) {
                    const adjacent = self.scene.sectors[@intCast(neighbor)];
                    if (adjacent.floor_slope != null or adjacent.ceiling_slope != null) slopes = true;
                }
            }
            if (try projection.project(self.view, transformed[wall.v1], transformed[wall.v2], state.length, index, slopes)) |p| {
                result[count] = .{ .projected = p, .first = transformed[wall.v1], .second = transformed[wall.v2] };
                count += 1;
            }
        }
        self.total_projected += count;
        if (self.total_projected > 0x568) return error.MaximumProjectedWalls;
        self.cached[sector_index] = result[0..count];
        return result[0..count];
    }

    fn drawSector(self: *Frame, sector_index: usize, window: planes.ClipWindow, entrance: ?visibility.Wall, minimum_z: f32, depth: usize, inherited_dynamic: bool, dynamic_depth: []i16) anyerror!void {
        const a = self.arena.allocator();
        self.visited[sector_index] = true;
        self.sector_visits += 1;
        var sector = self.level.sectors[sector_index];
        const state = self.scene.sectors[sector_index];
        try state.validateSlopes();
        sector.flags = state.flags;
        if (self.cached[sector_index] == null) {
            if (self.objects) |objects| {
                self.model_sectors[sector_index] = objects.collectSector(sector_index);
                if (sector.vadjoin >= 0 and sector.flags & 0x80 == 0) _ = objects.collectSector(@intCast(sector.vadjoin));
            }
        }
        const dynamic = inherited_dynamic or self.model_sectors[sector_index];
        const source = try self.projected(sector_index);
        for (source) |*wall| wall.active = self.active[sector_index][wall.projected.wall_index];
        const filtered = try a.alloc(visibility.Wall, 0x568 - self.total_filtered);
        const bounds = visibility.Window{ .left = window.left, .right = window.right, .minimum_z = minimum_z };
        const count = if (state.runtime_flags & 0x40000000 != 0)
            visibility.convex(source, filtered, bounds, entrance)
        else
            visibility.filter(source, filtered, bounds, entrance);
        if (state.runtime_flags & 0x40000000 == 0) {
            std.mem.sortUnstable(visibility.Wall, filtered[0..count], {}, lessThan);
        }
        self.total_filtered += count;
        var portals = walls.WindowList{ .total_count = &self.total_windows };
        const first_edge = self.edges.count;
        self.edges.view_top = window.top;
        self.edges.view_bottom = window.bottom;
        self.edges.top_limit = window.top - 1;
        self.edges.bottom_limit = window.bottom + 1;
        var lighting = self.lighting;
        lighting.ambient = m.integer(m.add(@floatFromInt(sector.ambient), 0.5));
        lighting.ambient_min = (lighting.ambient >> 2) +% (lighting.ambient >> 3) +% (lighting.ambient >> 1);
        var ctx = walls.Context{
            .view = self.view,
            .pixels = self.pixels,
            .clip_top = window.top_clip,
            .clip_bottom = window.bottom_clip,
            .top_y = self.top_y,
            .bottom_y = self.bottom_y,
            .window_top = window.top,
            .window_bottom = window.bottom,
            .edges = self.edges,
            .lighting = lighting,
            .textures = self.textures,
            .depth = &self.depth,
            .dynamic_depth = dynamic_depth,
            .dynamic = dynamic,
        };
        var double_adjoins = false;
        for (filtered[0..count]) |candidate| {
            const p = candidate.projected;
            var wall = sector.walls[p.wall_index];
            const wall_state = state.walls[p.wall_index];
            wall.flags = wall_state.flags;
            const flags = wall_state.render_flags;
            if (flags & 4 == 0) {
                if (wall.adjoin < 0) {
                    try walls.drawSolid(&ctx, sector_index, wall, p, try self.surfaces(sector_index, p));
                } else if (!self.active[sector_index][p.wall_index]) {
                    try self.adjoin(&ctx, &portals, sector_index, wall, p, flags, flags & 3);
                }
            } else if (!self.active[sector_index][p.wall_index]) {
                double_adjoins = true;
                try self.adjoin(&ctx, &portals, sector_index, wall, p, 4, flags & 1);
                wall.top = wall.mid;
                try self.adjoin(&ctx, &portals, sector_index, wall, p, 12, if (flags & 2 == 0) 1 else 3);
                if (self.edges.count < first_edge + 2) return error.InvalidDoubleAdjoinEdges;
                const lower = self.edges.entries[self.edges.count - 1];
                const upper = &self.edges.entries[self.edges.count - 2];
                upper.bottom_first = lower.bottom_first;
                upper.bottom_last = lower.bottom_last;
                upper.bottom_step = lower.bottom_step;
                upper.bottom_max = lower.bottom_max;
                upper.bottom_min = lower.bottom_min;
                self.edges.count -= 1;
                state.walls[p.wall_index].runtime_flags |= 1;
            }
            state.walls[p.wall_index].runtime_flags |= 0x40000000;
        }
        const plane_ctx = planes.Context{
            .pixels = self.pixels,
            .view = self.view,
            .angles = self.angles,
            .textures = self.textures,
            .window = window,
            .edges = self.edges.entries[first_edge..self.edges.count],
            .top_y = self.top_y,
            .bottom_y = self.bottom_y,
            .top_limit = self.edges.top_limit,
            .bottom_limit = self.edges.bottom_limit,
            .lighting = lighting,
            .arithmetic = self.arithmetic,
        };
        var warped: [4096]u8 = undefined;
        var ceiling_override: ?[]const u8 = null;
        var floor_override: ?[]const u8 = null;
        if (sector.flags & 0x80 != 0 and sector.vadjoin >= 0) {
            try ripple.warp64(self.angles, try self.texels(sector.ceiling.texture), &warped, self.ticks);
            ceiling_override = &warped;
        } else if (sector.vadjoin >= 0 or sector.flags & 0x800 != 0) {
            try ripple.warp64(self.angles, try self.texels(sector.floor.texture), &warped, self.ticks);
            floor_override = &warped;
        }
        try planes.draw(plane_ctx, &sector, .ceiling, state.ceiling_slope, ceiling_override);
        try planes.draw(plane_ctx, &sector, .floor, state.floor_slope, floor_override);
        if (portals.count != 0 and depth < 0x8c) {
            const top = try a.dupe(i16, window.top_clip);
            const bottom = try a.dupe(i16, window.bottom_clip);
            const alternate_top = if (double_adjoins) try a.dupe(i16, window.top_clip) else top;
            const alternate_bottom = if (double_adjoins) try a.dupe(i16, window.bottom_clip) else bottom;
            for (portals.entries[0..portals.count]) |portal| {
                clipPortal(portal.edge, window, if (portal.flags == 8) alternate_top else top, if (portal.flags == 8) alternate_bottom else bottom);
            }
            for (portals.entries[0..portals.count]) |portal| {
                const p = portal.projected;
                const wall = sector.walls[p.wall_index];
                const neighbor = if (portal.flags == 8) wall.dadjoin else wall.adjoin;
                if (neighbor < 0) return error.InvalidPortalSector;
                const child = planes.ClipWindow{
                    .left = portal.edge.left,
                    .right = portal.edge.right,
                    .top = @max(window.top, portal.edge.top_min),
                    .bottom = @min(window.bottom, portal.edge.bottom_max),
                    .inner_top = @max(window.inner_top, portal.edge.top_max),
                    .inner_bottom = @min(window.inner_bottom, portal.edge.bottom_min),
                    .top_clip = if (portal.flags == 8) alternate_top else top,
                    .bottom_clip = if (portal.flags == 8) alternate_bottom else bottom,
                };
                const width: usize = @intCast(self.view.width);
                const child_depth = self.dynamic_depths[depth * width ..][0..width];
                self.active[sector_index][p.wall_index] = true;
                defer self.active[sector_index][p.wall_index] = false;
                const original = findSource(source, p.wall_index);
                const masked = state.walls[p.wall_index].flags & 1 != 0;
                if (dynamic or masked) @memcpy(child_depth, dynamic_depth);
                try self.drawSector(@intCast(neighbor), child, original, @min(p.z1, p.z2), depth + 1, dynamic or masked, child_depth);
                if ((dynamic or masked or self.model_sectors[@intCast(neighbor)]) and self.scene.sectors[@intCast(neighbor)].runtime_flags & 0x80000000 == 0 and !self.completed[sector_index]) {
                    const start: usize = @intCast(child.left);
                    const end: usize = @intCast(child.right + 1);
                    @memcpy(dynamic_depth[start..end], child_depth[start..end]);
                }
                if (masked) {
                    var masked_wall = wall;
                    masked_wall.flags = state.walls[p.wall_index].flags;
                    try walls.drawMasked(&ctx, masked_wall, p, portal.edge, state.walls[p.wall_index].mid_height, self.blend_table);
                }
            }
        }
        if (dynamic) if (self.objects) |objects| try objects.drawDynamic(sector_index, window, dynamic_depth, lighting);
        self.completed[sector_index] = true;
    }

    fn texels(self: *const Frame, index: i32) ![]const u8 {
        if (index < 0 or index >= self.textures.len) return error.InvalidPlaneTexture;
        return self.textures[@intCast(index)].pixels;
    }

    fn height(self: *const Frame, sector: usize, ceiling: bool, p: projection.ProjectedWall, second: bool, reverse: bool) !f32 {
        const slope = if (ceiling) self.scene.sectors[sector].ceiling_slope else self.scene.sectors[sector].floor_slope;
        const flag: u32 = if (ceiling) 0x80000000 else 0x40000000;
        if (self.scene.sectors[sector].flags & flag != 0) {
            const s = slope orelse return error.MissingSceneSlope;
            const x = if (second) p.world_x2 else p.world_x1;
            const z = if (second) p.world_z2 else p.world_z1;
            if (reverse) return m.sub(m.sub(s.constant, m.mul(s.coeff_x, x)), m.mul(s.coeff_z, z));
            return m.sub(m.sub(s.constant, m.mul(s.coeff_z, z)), m.mul(s.coeff_x, x));
        }
        return if (ceiling) self.level.sectors[sector].ceiling.height else self.level.sectors[sector].floor.height;
    }

    fn surfaces(self: *const Frame, sector: usize, p: projection.ProjectedWall) !walls.SurfaceEndpoints {
        return .{
            .upper1 = try self.height(sector, true, p, false, false),
            .upper2 = try self.height(sector, true, p, true, false),
            .lower1 = try self.height(sector, false, p, false, false),
            .lower2 = try self.height(sector, false, p, true, false),
            .lower_base = self.level.sectors[sector].floor.height,
            .lower_sloped = self.scene.sectors[sector].flags & 0x40000000 != 0,
        };
    }

    fn adjoin(self: *Frame, ctx: *walls.Context, portals: *walls.WindowList, sector: usize, wall: level_module.Wall, p: projection.ProjectedWall, flags: u32, part: u32) !void {
        const primary: usize = @intCast(wall.adjoin);
        const neighbor: usize = if (flags == 12) @intCast(wall.dadjoin) else primary;
        const neighbor_flags = self.scene.sectors[neighbor].flags;
        const dispatch_flags = self.scene.sectors[primary].flags;
        var surface = try self.surfaces(sector, p);
        if (flags == 4) {
            surface.lower1 = try self.height(primary, false, p, false, false);
            surface.lower2 = try self.height(primary, false, p, true, false);
        } else if (flags == 12) {
            surface.upper1 = try self.height(primary, false, p, false, false);
            surface.upper2 = try self.height(primary, false, p, true, false);
        }
        var chosen: ?walls.AdjoinPart = switch (part) {
            0 => null,
            1 => .upper,
            2 => .lower,
            3 => .both,
            else => unreachable,
        };
        if (chosen == .upper and dispatch_flags & 4 != 0) chosen = null;
        if (chosen == .lower and dispatch_flags & 8 != 0) chosen = null;
        if (chosen == .both) {
            chosen = if (dispatch_flags & 4 != 0)
                (if (dispatch_flags & 8 != 0) null else .lower)
            else
                (if (dispatch_flags & 8 != 0) .upper else .both);
        }
        const endpoints = walls.AdjoinEndpoints{
            .surfaces = surface,
            .neighbor_upper1 = try self.height(neighbor, true, p, false, chosen == null),
            .neighbor_upper2 = try self.height(neighbor, true, p, true, false),
            .neighbor_lower1 = try self.height(neighbor, false, p, false, chosen == null),
            .neighbor_lower2 = try self.height(neighbor, false, p, true, false),
            .neighbor_upper_sloped = self.scene.sectors[if (chosen == .both) primary else neighbor].flags & 0x80000000 != 0,
            .sector_flags = self.scene.sectors[sector].flags,
            .neighbor_flags = neighbor_flags,
        };
        if (chosen) |selected| try walls.drawAdjoin(ctx, portals, sector, wall, p, endpoints, flags, selected) else try walls.drawOpen(ctx, portals, sector, p, endpoints, flags);
    }
};

fn lessThan(_: void, first: visibility.Wall, second: visibility.Wall) bool {
    return first.projected.visible_left < second.projected.visible_left;
}

fn findSource(source: []const visibility.Wall, index: usize) visibility.Wall {
    for (source) |wall| if (wall.projected.wall_index == index) return wall;
    unreachable;
}

fn clipPortal(edge: walls.Edge, parent: planes.ClipWindow, top: []i16, bottom: []i16) void {
    var top_value = edge.top_first;
    var bottom_value = edge.bottom_first;
    for (@as(usize, @intCast(edge.left))..@as(usize, @intCast(edge.right + 1))) |x| {
        const y1 = m.integer(top_value);
        if (parent.top_clip[x] < y1) top[x] = if (parent.bottom_clip[x] < y1) parent.bottom_clip[x] + 1 else @intCast(y1);
        const y2 = m.integer(bottom_value);
        if (y2 < parent.bottom_clip[x]) bottom[x] = if (y2 < parent.top_clip[x]) parent.top_clip[x] - 1 else @intCast(y2);
        top_value = m.add(top_value, edge.top_step);
        bottom_value = m.add(bottom_value, edge.bottom_step);
    }
}

fn checkGeometryReference(initial_state: bool) !void {
    const allocator = std.testing.allocator;
    const lab = @import("../../../assets/lab.zig");
    const geometry_data = try testAsset("OLGEO.LAB");
    defer allocator.free(geometry_data);
    const texture_data = try testAsset("OLTEX.LAB");
    defer allocator.free(texture_data);
    const system_data = try testAsset("OUTLAWS.LAB");
    defer allocator.free(system_data);
    const geometry = try lab.Archive.init(geometry_data);
    const texture_archive = try lab.Archive.init(texture_data);
    const system = try lab.Archive.init(system_data);
    var level = try level_module.Level.parse(allocator, try geometry.find("hideout.lvb", 0));
    defer level.deinit();
    const initial_module = @import("../../initial_state.zig");
    var initial = if (initial_state) try initial_module.InfStartup.apply(allocator, &level, try geometry.find("hideout.inf", 0)) else null;
    defer if (initial) |*state| state.deinit();
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(allocator, &level, &angles);
    defer scene.deinit();
    if (initial) |state| state.applyScene(&level, &scene);
    const textures = try allocator.alloc(texture.Texture, level.textures.len);
    defer allocator.free(textures);
    var loaded: usize = 0;
    defer for (textures[0..loaded]) |tex| tex.deinit(allocator);
    for (textures, level.textures) |*tex, name| {
        tex.* = try texture.loadInitial(allocator, texture_archive, name);
        loaded += 1;
    }
    const cmap = try texture.decodeColorMap(allocator, try system.find("HIDEOUT.PCX", 0));
    defer allocator.free(cmap);
    const dmap = texture.defaultDepthMap();
    var view = try camera.View.init(allocator, &angles, 640, 480);
    defer view.deinit(allocator);
    view.setParallax(level.parallax.x, level.parallax.z);
    view.setPose(&angles, 322.36, 2.5, 271.88, if (initial_state) 8034 else 8035, 0);
    const pixels = try allocator.alloc(u8, 640 * 480);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    var frame = try Frame.init(allocator, &view, &angles, &level, &scene, textures, pixels, .{ .force_depth = 0, .depth_bias = 0, .depth_strength = 0, .ambient_bias = 0, .ambient = 0, .ambient_min = 0, .color_map = cmap, .depth_map = &dmap }, .scalar, 0);
    defer frame.deinit();
    try frame.draw(410);
    try std.testing.expectEqual(@as(usize, 65), frame.sector_visits);
    try std.testing.expectEqual(@as(usize, if (initial_state) 101 else 100), frame.total_projected);
    try std.testing.expectEqual(@as(usize, if (initial_state) 97 else 96), frame.total_filtered);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pixels, &hash, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, if (initial_state)
        "3f9485f0f7296bca2d7dfa7c41f2dd11968e06afe44cc021d8b4d534136da0e1"
    else
        "43c6694773cf169c571eaf2a8a3b83b5e735634f40bd29a63cc22d2e73b1371b");
    try std.testing.expectEqualSlices(u8, &expected, &hash);
}

fn testAsset(comptime name: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/" ++ name, std.testing.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "CD1 hideout geometry exercises the reference portal renderer" {
    try checkGeometryReference(false);
}

test "CD1 campaign-start geometry matches the reference" {
    try checkGeometryReference(true);
}
