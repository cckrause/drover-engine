//! Drawing actors: the sprite-facing state of each actor and the passes
//! that place them in the view.
//!
//! The renderer never picks a sequence or a frame of its own - what an actor
//! shows is whatever its own playback selected. Presentation caches live
//! with the actor even though the renderer owns its work arrays.

const std = @import("std");
const nwx = @import("../assets/nwx.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("scene.zig");
const camera = @import("backends/software/camera.zig");
const planes = @import("backends/software/planes.zig");
const walls = @import("backends/software/walls.zig");
const m = @import("backends/software/math.zig");
const actor_links = @import("actor_links.zig");
const model_asset = @import("../assets/model.zig");
const model_render = @import("backends/software/model.zig");

pub const Actor = struct {
    logic_id: u32 = 0,
    birth_order: u64 = 0,
    object_id: u32 = 0,
    child_source: ?usize = null,
    transformed: level_module.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    palette_time: u32 = 0,
    head_angles: [2]i16 = .{ 0, 0 },
    eye_height: f32 = 0,
    velocity: level_module.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    angular_velocity: level_module.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    model_matrix: [9]f32 = @splat(0),
    model_rotation: level_module.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    source_index: ?usize = null,
    sector_link_order: u64 = 0,
    logic_name: []const u8 = "",
    logic_resource: ?[]const u8 = null,
    logic_kind: ?u32 = null,
    wax_binding: ?[]const u8 = null,
    model_instance_present: bool = true,
    costume: ?*const nwx.Costume = null,
    model: ?*const model_asset.Model = null,
    projectile_explodes: bool = false,
    network_item: []const u8 = "",
    sector: usize,
    position: level_module.Vec3,
    yaw: i16,
    pitch: i16 = 0,
    roll: i16 = 0,
    flags: u32,
    secondary_flags: u32,
    scale_x: f32,
    scale_y: f32,
    height: f32,
    collision_radius: f32 = 0,
    choreography: u32,
    frame: u32,
    angle_offset: i16,
    playback: ?nwx.Playback = null,

    pub fn sprite(self: Actor) !*const nwx.Costume {
        return self.costume orelse error.ActorHasNoSprite;
    }

    pub fn advanceUnboundAnimation(self: *Actor, now: u32) !void {
        if (self.playback) |*playback| {
            try playback.advance(try self.sprite(), 0, now);
            self.choreography = playback.choreography;
            self.frame = playback.frame;
            self.angle_offset = playback.angle_offset;
        }
    }
};

pub const Context = struct {
    native_slots: ?[]?Actor = null,
    native_player: ?*Actor = null,
    view: *const camera.View,
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    camera_sector: usize,
    pixels: []u8,
    lighting: walls.Lighting,
    blend_table: ?[]const u8,
    links: ?*const actor_links.Links = null,
    source_to_entry: ?[]const ?usize = null,
    angles: ?*const camera.Angles = null,
};

pub const Objects = struct {
    allocator: std.mem.Allocator,
    context: Context,
    actors: []const Actor,
    transformed: []level_module.Vec3,
    transformed_sectors: []bool = &.{},
    collected: [256]usize = undefined,
    count: usize = 0,
    drawn: usize = 0,
    aim_static: [256]usize = undefined,
    aim_static_count: usize = 0,
    aim_dynamic: [256]usize = undefined,
    aim_dynamic_count: usize = 0,

    const SectorActors = struct {
        owner: *const Objects,
        sector: usize,
        source: ?usize,
        remaining: usize,

        fn next(self: *SectorActors) ?usize {
            if (self.owner.context.links) |links| {
                while (self.source) |source| {
                    self.source = links.next(source);
                    if (source == actor_links.player_id) continue;
                    if (self.owner.context.source_to_entry.?[source]) |index| return index;
                }
            } else {
                while (self.remaining != 0) {
                    self.remaining -= 1;
                    if (self.owner.actors[self.remaining].sector == self.sector) return self.remaining;
                }
            }
            return null;
        }
    };

    const Mode = union(enum) {
        dynamic: struct { window: planes.ClipWindow, depth: []const i16 },
        final: *const walls.DepthBuffer,
    };

    const Blend = enum { none, colors, shadow1, shadow5 };

    pub fn init(allocator: std.mem.Allocator, context: Context, actors: []const Actor) !Objects {
        const transformed = try allocator.alloc(level_module.Vec3, actors.len);
        errdefer allocator.free(transformed);
        for (actors) |actor| if (actor.sector >= context.level.sectors.len) return error.InvalidObjectSector;
        var self = Objects{ .allocator = allocator, .context = context, .actors = actors, .transformed = transformed };
        if (context.links) |links| {
            const entries = context.source_to_entry orelse return error.MissingActorEntryMap;
            if (entries.len != links.nodes.items.len or links.heads.len != context.level.sectors.len) return error.InvalidActorEntryMap;
            self.transformed_sectors = try allocator.alloc(bool, context.level.sectors.len);
            @memset(self.transformed_sectors, false);
        } else {
            for (actors, 0..) |_, index| self.transformActor(index);
        }
        return self;
    }

    pub fn deinit(self: *Objects) void {
        self.allocator.free(self.transformed);
        self.allocator.free(self.transformed_sectors);
        self.* = undefined;
    }

    pub fn collectSector(self: *Objects, sector: usize) bool {
        self.transformSector(sector);
        var added: usize = 0;
        var has_model = false;
        var actors = self.sectorActors(sector);
        while (added < 128 and self.count < 256) {
            const i = actors.next() orelse break;
            if (!self.eligible(i, self.context.view.left, self.context.view.right)) continue;
            self.collected[self.count] = i;
            self.count += 1;
            added += 1;
            has_model = has_model or self.actors[i].model != null;
        }
        return has_model;
    }

    pub fn drawDynamic(self: *Objects, sector: usize, window: planes.ClipWindow, depth_clip: []const i16, lighting: walls.Lighting) !void {
        var indices: [256]usize = undefined;
        var count: usize = 0;
        const source = self.context.level.sectors[sector];
        const other: ?usize = if (source.vadjoin >= 0 and self.context.scene.sectors[sector].flags & 0x80 == 0) @intCast(source.vadjoin) else null;
        for ([_]?usize{ sector, other }) |selected| {
            const own = selected orelse continue;
            self.transformSector(own);
            var actors = self.sectorActors(own);
            var added: usize = 0;
            while (added < 128) {
                const i = actors.next() orelse break;
                if (!self.eligible(i, window.left, window.right)) continue;
                indices[count] = i;
                count += 1;
                added += 1;
            }
        }
        self.sort(indices[0..count]);
        for (indices[0..count]) |i| {
            const actor = self.actors[i];
            if (actor.model) |model| {
                if (self.context.native_slots) |slots| if (actor.source_index) |source_index| {
                    slots[source_index].?.model_matrix = model_render.rotation(self.context.angles orelse return error.MissingModelAngles, .{ .position = actor.position, .yaw = actor.yaw, .pitch = actor.pitch, .roll = actor.roll });
                };
                try model_render.draw(.{ .view = self.context.view, .angles = self.context.angles orelse return error.MissingModelAngles, .pixels = self.context.pixels, .window = window, .depth = depth_clip, .lighting = lighting }, model, .{ .position = actor.position, .yaw = actor.yaw, .pitch = actor.pitch, .roll = actor.roll });
                self.drawn += 1;
                continue;
            }
            if (try self.drawActor(i, .{ .dynamic = .{ .window = window, .depth = depth_clip } }, lighting)) {
                self.drawn += 1;
                if (self.aim_dynamic_count < 256) {
                    self.aim_dynamic[self.aim_dynamic_count] = i;
                    self.aim_dynamic_count += 1;
                }
            }
        }
    }

    pub fn drawFinal(self: *Objects, depth: *const walls.DepthBuffer) !void {
        self.sort(self.collected[0..self.count]);
        const maximum = m.mul(@floatFromInt(@as(i32, depth.maximum) << 12), 0x1p-16);
        for (self.collected[0..self.count]) |i| {
            if (self.actors[i].flags & 4 == 0 or self.actors[i].model != null or maximum <= self.transformed[i].z) continue;
            var lighting = self.context.lighting;
            lighting.ambient = m.integer(m.add(@floatFromInt(self.context.level.sectors[self.actors[i].sector].ambient), 0.5));
            const light = lighting.ambient +% lighting.ambient_bias;
            lighting.ambient_min = (light >> 2) +% (light >> 3) +% (light >> 1);
            if (try self.drawActor(i, .{ .final = depth }, lighting)) {
                self.drawn += 1;
                self.aim_static[self.aim_static_count] = i;
                self.aim_static_count += 1;
            }
        }
    }

    fn transformActor(self: *Objects, index: usize) void {
        const actor = self.actors[index];
        self.transformed[index] = transformPosition(self.context.view, actor.position);
        if (self.context.native_slots) |slots| {
            if (actor.source_index) |source| slots[source].?.transformed = self.transformed[index];
        }
    }

    fn transformSector(self: *Objects, sector: usize) void {
        if (self.context.links == null or self.transformed_sectors[sector]) return;
        self.transformed_sectors[sector] = true;
        if (self.context.native_player) |player| {
            if (self.context.links.?.player.sector == sector and player.flags & 4 != 0)
                player.transformed = transformPosition(self.context.view, player.position);
        }
        var actors = self.sectorActors(sector);
        while (actors.next()) |index| {
            if (self.actors[index].flags & 4 != 0) self.transformActor(index);
        }
    }

    fn sectorActors(self: *const Objects, sector: usize) SectorActors {
        return .{ .owner = self, .sector = sector, .source = if (self.context.links) |links| links.first(sector) else null, .remaining = self.actors.len };
    }

    fn eligible(self: *const Objects, index: usize, left: i32, right: i32) bool {
        const actor = self.actors[index];
        if (actor.flags & 4 == 0) return false;
        if (actor.model) |model| return model_render.eligible(self.context.view, self.transformed[index], model.radius, left, right);
        return actor.costume != null and m.signedBits(self.transformed[index].z) >= 0x3f800000;
    }

    fn drawActor(self: *Objects, index: usize, mode: Mode, lighting: walls.Lighting) !bool {
        const actor = self.actors[index];
        const point = self.transformed[index];
        const view = self.context.view;
        const orientation = (direction(m.sub(view.x, actor.position.x), m.sub(view.z, actor.position.z)) -% actor.yaw) & 0x3fff;
        const frame = try (try actor.sprite()).select(actor.choreography, actor.frame, orientation, actor.angle_offset);
        const owner = self.context.level.sectors[actor.sector];
        const owner_flags = self.context.scene.sectors[actor.sector].flags;
        const camera_flags = self.context.scene.sectors[self.context.camera_sector].flags;
        const water_clip = owner_flags & 0x80 != 0 or owner.vadjoin >= 0;
        const bounds_sector: usize = if (camera_flags & 0x80 == 0 and owner_flags & 0x80 != 0)
            if (owner.vadjoin >= 0) @intCast(owner.vadjoin) else return error.WaterObjectWithoutVerticalAdjoin
        else
            actor.sector;
        const bounds = self.context.level.sectors[bounds_sector];
        const state = self.context.scene.sectors[bounds_sector];
        try state.validateSlopes();
        const ceiling = surfaceHeight(if (state.flags & 0x80000000 != 0) state.ceiling_slope else null, bounds.ceiling.height, actor.position);
        const floor = surfaceHeight(if (state.flags & 0x40000000 != 0) state.floor_slope else null, bounds.floor.height, actor.position);
        var bottom_adjustment: f32 = 0;
        var drawn = false;
        for (frame.parts) |part| {
            const cell = (try actor.sprite()).cells[part.cell];
            const mirrored = part.flags & 0x100 != 0;
            const world_height = m.mul(part.height, actor.scale_y);
            const offset_x = m.add(if (mirrored) m.sub(part.width, part.offset_x) else part.offset_x, frame.offset_x);
            const cx = m.sub(point.x, offset_x);
            const cy = m.add(m.sub(world_height, m.add(part.offset_y, frame.offset_y)), point.y);
            if (m.signedBits(point.z) <= 0x3f7fffff) continue;
            const scale = m.mul(m.div(1, point.z), view.focal);
            const float_left = m.add(m.mul(scale, cx), view.center_x_f);
            const float_top = m.sub(view.horizon_f, m.mul(cy, scale));
            var left = m.integer(m.add(float_left, 0.5));
            var top = m.integer(m.add(float_top, 0.5));
            const clip_left = switch (mode) {
                .dynamic => |value| value.window.left,
                .final => view.left,
            };
            const clip_right = switch (mode) {
                .dynamic => |value| value.window.right,
                .final => view.right,
            };
            const clip_top = switch (mode) {
                .dynamic => |value| value.window.top,
                .final => view.top,
            };
            const clip_bottom = switch (mode) {
                .dynamic => |value| value.window.bottom,
                .final => view.bottom,
            };
            if (clip_right < left or clip_bottom < top) continue;
            const float_right = m.add(m.mul(m.add(cx, m.mul(part.width, actor.scale_x)), scale), view.center_x_f);
            const float_bottom = m.sub(view.horizon_f, m.mul(m.sub(cy, world_height), scale));
            var right = m.integer(m.add(float_right, 0.5));
            var bottom = m.integer(m.add(float_bottom, 0.5));
            const fixed_depth: i16 = @truncate(m.fixed(point.z) >> 12);
            if (mode == .final) {
                var visible = false;
                var x = @max(left, view.left);
                while (x <= @min(right, view.right)) : (x += 1) {
                    if (fixed_depth < mode.final.furthest[@intCast(x)]) {
                        visible = true;
                        break;
                    }
                }
                if (!visible) continue;
            }
            if (water_clip) {
                const projected_ceiling = m.sub(view.horizon_f, m.mul(m.sub(ceiling, view.y), scale));
                const projected_floor = m.sub(view.horizon_f, m.mul(m.sub(floor, view.y), scale));
                if (float_top < projected_ceiling) top = m.integer(m.add(projected_ceiling, 0.5));
                if (projected_floor < float_bottom) {
                    bottom_adjustment = m.sub(projected_floor, float_bottom);
                    bottom = m.integer(m.add(projected_floor, 0.5));
                }
            }
            if (right < clip_left or bottom < clip_top or bottom < top or right -% left +% 1 <= 0) continue;
            const dv = try fixedDivide(@bitCast(cell.height << 16), m.fixed(m.sub(float_bottom, float_top)) +% 65536);
            const du = try fixedDivide(@bitCast(cell.width << 16), m.fixed(m.sub(float_right, float_left)) +% 65536);
            const bottom_v = fixedMultiply(m.fixed(bottom_adjustment), dv);
            var u: i32 = 0;
            if (left < clip_left) {
                u = fixedMultiply(du, (clip_left -% left) *% 65536);
                left = clip_left;
            }
            right = @min(right, clip_right);
            var table: ?*const [256]u8 = if (lighting.color_map) |map| if (map.len >= 256) map[0..256] else return error.InvalidColorMap else null;
            if (actor.flags & 8 != 0) table = try lighting.wallTable(point.z, 0);
            if (actor.secondary_flags & 3 != 0 and table == null) {
                if (lighting.color_map) |map| table = map[0..256];
            }
            const blend: Blend = if (self.context.blend_table == null) .none else if (actor.secondary_flags & 0x2000000 != 0) if (lighting.ambient < 25) .shadow5 else .shadow1 else if (cell.flags & 0x20 != 0) .colors else .none;
            var x = left;
            while (x <= right) : ({
                x += 1;
                u +%= du;
            }) {
                const column_number = u >> 16;
                if (column_number < 0 or column_number >= cell.width) return error.InvalidSpriteColumn;
                const column_index: usize = @intCast(if (mirrored) @as(i32, @intCast(cell.width)) - column_number - 1 else column_number);
                const texels = cell.pixels[column_index * cell.height ..][0..cell.height];
                switch (mode) {
                    .dynamic => |dynamic| {
                        if (point.z >= m.mul(@floatFromInt(@as(i32, dynamic.depth[@intCast(x)]) << 12), 0x1p-16)) continue;
                        const y1 = @max(top, dynamic.window.top_clip[@intCast(x)]);
                        const y2 = @min(bottom, dynamic.window.bottom_clip[@intCast(x)]);
                        if (y1 <= y2) {
                            try self.column(x, y1, y2, texels, fixedMultiply((bottom -% y2) *% 65536, dv) -% bottom_v, dv, table, blend);
                            drawn = true;
                        }
                    },
                    .final => |depth| {
                        const y1 = @max(top, view.top);
                        const y2 = @min(bottom, view.bottom);
                        if (y2 < y1) continue;
                        var owner_ceiling = owner.ceiling.height;
                        var owner_floor = owner.floor.height;
                        if (owner.vadjoin >= 0) {
                            const adjacent = self.context.level.sectors[@intCast(owner.vadjoin)];
                            owner_ceiling = @max(owner_ceiling, adjacent.ceiling.height);
                            owner_floor = @min(owner_floor, adjacent.floor.height);
                        }
                        const foot = @max(actor.position.y, owner_floor);
                        const head = @min(m.add(foot, actor.height), owner_ceiling);
                        const xi: usize = @intCast(x);
                        for (depth.strips[xi * 30 ..][0..depth.counts[xi]]) |strip| {
                            const strip_sector = self.context.level.sectors[strip.sector];
                            if (fixed_depth > strip.distance or y1 > strip.bottom or strip.top > y2 or
                                strip_sector.floor.height >= owner_ceiling or owner_floor >= strip_sector.ceiling.height or
                                head > strip_sector.ceiling.height or strip_sector.floor.height > foot) continue;
                            const clipped_top = @max(y1, strip.top);
                            const clipped_bottom = @min(y2, strip.bottom);
                            try self.column(x, clipped_top, clipped_bottom, texels, fixedMultiply((bottom -% clipped_bottom) *% 65536, dv) -% bottom_v, dv, table, blend);
                            drawn = true;
                        }
                    },
                }
            }
        }
        return drawn;
    }

    fn column(self: *Objects, x: i32, top: i32, bottom: i32, source: []const u8, initial_v: i32, dv: i32, table: ?*const [256]u8, blend: Blend) !void {
        var v = initial_v;
        var y = bottom;
        while (y >= top) : ({
            y -= 1;
            v +%= dv;
        }) {
            if (v < 0 and blend == .none and (table == null or self.context.view.width == 320 or self.context.view.width == 640)) continue;
            const sample = v >> 16;
            if (sample < 0 or sample >= source.len) return error.InvalidSpriteRow;
            const color = source[@intCast(sample)];
            if (color == 0) continue;
            const destination = &self.context.pixels[@as(usize, @intCast(y)) * @as(usize, @intCast(self.context.view.width)) + @as(usize, @intCast(x))];
            if (blend != .none and color < 16) {
                const colors = self.context.blend_table.?;
                const index = @as(usize, color) * 256 + destination.*;
                if (index >= colors.len) return error.InvalidBlendTable;
                destination.* = colors[index];
            } else switch (blend) {
                .none, .colors => destination.* = if (table) |translation| translation[color] else color,
                .shadow1, .shadow5 => {
                    const colors = self.context.blend_table.?;
                    const index = @as(usize, if (blend == .shadow1) 256 else 1280) + destination.*;
                    if (index >= colors.len) return error.InvalidBlendTable;
                    destination.* = colors[index];
                },
            }
        }
    }

    fn compare(self: *const Objects, a: usize, b: usize) i32 {
        const am = self.actors[a].model;
        const bm = self.actors[b].model;
        if (am != null and bm != null) {
            if (am.?.sort_mode == 1 and bm.?.sort_mode != 1) return -1;
            if (am.?.sort_mode != 1 and bm.?.sort_mode == 1) return 1;
            const ap = self.transformed[a];
            const bp = self.transformed[b];
            const ad = m.towardZero(@sqrt(@as(f64, m.add(m.add(m.mul(ap.y, ap.y), m.mul(ap.x, ap.x)), m.mul(ap.z, ap.z)))));
            const bd = m.towardZero(@sqrt(@as(f64, m.add(m.add(m.mul(bp.y, bp.y), m.mul(bp.x, bp.x)), m.mul(bp.z, bp.z)))));
            return m.integer(m.sub(bd, ad));
        }
        if (am != null and am.?.sort_mode == 1) return -1;
        if (bm != null and bm.?.sort_mode == 1) return 1;
        return m.integer(m.sub(self.transformed[b].z, self.transformed[a].z));
    }

    fn sort(self: *const Objects, entries: []usize) void {
        if (entries.len < 2) return;
        if (entries.len <= 8) {
            var last = entries.len - 1;
            while (last != 0) : (last -= 1) {
                var greatest: usize = 0;
                for (1..last + 1) |i| if (self.compare(entries[i], entries[greatest]) > 0) {
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
            while (lo < entries.len and self.compare(entries[lo], entries[0]) <= 0) lo += 1;
            hi -= 1;
            while (hi > 0 and self.compare(entries[hi], entries[0]) >= 0) hi -= 1;
            if (lo > hi) break;
            std.mem.swap(usize, &entries[lo], &entries[hi]);
        }
        std.mem.swap(usize, &entries[0], &entries[hi]);
        self.sort(entries[0..hi]);
        self.sort(entries[lo..]);
    }
};

fn transformPosition(view: *const camera.View, position: level_module.Vec3) level_module.Vec3 {
    return .{
        .x = m.add(m.add(m.mul(position.z, view.sin_yaw), m.mul(position.x, view.cos_yaw)), view.translation_x),
        .y = m.sub(position.y, view.y),
        .z = m.add(m.sub(m.mul(position.z, view.cos_yaw), m.mul(position.x, view.sin_yaw)), view.translation_z),
    };
}

fn surfaceHeight(slope: ?scene_module.Slope, base: f32, point: level_module.Vec3) f32 {
    const value = slope orelse return base;
    return m.sub(m.sub(value.constant, m.mul(point.x, value.coeff_x)), m.mul(point.z, value.coeff_z));
}

fn direction(x: f32, z: f32) i16 {
    const radians = m.towardZero(std.math.atan2(@as(f64, x), @as(f64, z)));
    const turns = m.towardZero(@as(f64, radians) * 0.15915494309644432);
    return @intCast(m.integer(m.mul(turns, 16384)) & 0x3fff);
}

fn fixedMultiply(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * b) >> 16);
}

fn fixedDivide(a: i32, b: i32) !i32 {
    const result = @divTrunc(@as(i64, a) << 16, if (b == 0) @as(i64, 1) else b);
    return std.math.cast(i32, result) orelse error.SpriteFixedDivideOverflow;
}

test "sprite direction preserves FPATAN and truncation boundaries" {
    const inputs = [_][2]f32{ .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 }, .{ 1, 1 }, .{ 1, -1 }, .{ -1, -1 }, .{ 0.1415, 0.334 }, .{ -40.125, 15.0625 } };
    const expected = [_]i16{ 0, 4095, 12289, 2047, 6143, 10241, 1044, 13225 };
    for (inputs, expected) |point, angle| try std.testing.expectEqual(angle, direction(point[0], point[1]));
}

test "local player transform cache follows visible sector traversal" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/actor-transform-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Case = struct {
        position_bits: [3]u32,
        eye_bits: [3]u32,
        yaw: i16,
        flags: u32,
        adjacent: bool,
        water: bool,
        transformed_bits: [3]u32,
    };
    const Corpus = struct { executable_sha256: []const u8, cases: []Case };
    const corpus = try std.json.parseFromSlice(Corpus, a, bytes, .{});
    defer corpus.deinit();
    const angles = camera.Angles.init();
    var view = try camera.View.init(a, &angles, 640, 480);
    defer view.deinit(a);
    for (corpus.value.cases) |case| {
        view.setPose(&angles, @bitCast(case.eye_bits[0]), @bitCast(case.eye_bits[1]), @bitCast(case.eye_bits[2]), case.yaw, 0);
        var sectors: [2]level_module.Sector = @splat(std.mem.zeroes(level_module.Sector));
        sectors[0].vadjoin = if (case.adjacent) 1 else -1;
        sectors[1].vadjoin = -1;
        var level: level_module.Level = undefined;
        level.sectors = &sectors;
        var states: [2]scene_module.SectorState = @splat(std.mem.zeroes(scene_module.SectorState));
        states[0].flags = if (case.water) 0x80 else 0;
        var collision_check: u32 = 0;
        const scene = scene_module.Scene{ .arena = undefined, .sectors = &states, .collision_check = &collision_check };
        var links = try actor_links.Links.init(a, 2, 0);
        defer links.deinit();
        links.move(actor_links.player_id, @intFromBool(case.adjacent));
        var player = std.mem.zeroes(Actor);
        player.position = .{ .x = @bitCast(case.position_bits[0]), .y = @bitCast(case.position_bits[1]), .z = @bitCast(case.position_bits[2]) };
        player.flags = case.flags;
        player.transformed = .{ .x = 123, .y = 456, .z = 789 };
        const lighting = std.mem.zeroes(walls.Lighting);
        var objects = try Objects.init(a, .{
            .view = &view,
            .level = &level,
            .scene = &scene,
            .camera_sector = 0,
            .pixels = &.{},
            .lighting = lighting,
            .blend_table = null,
            .links = &links,
            .source_to_entry = &.{},
            .native_player = &player,
        }, &.{});
        defer objects.deinit();
        try objects.drawDynamic(0, std.mem.zeroes(planes.ClipWindow), &.{}, lighting);
        const actual = [_]u32{ @bitCast(player.transformed.x), @bitCast(player.transformed.y), @bitCast(player.transformed.z) };
        try std.testing.expectEqualSlices(u32, &case.transformed_bits, &actual);
        player.position.y = 900;
        try objects.drawDynamic(0, std.mem.zeroes(planes.ClipWindow), &.{}, lighting);
        try std.testing.expectEqual(case.transformed_bits[1], @as(u32, @bitCast(player.transformed.y)));
    }
}

test "sprite projection, water clipping, strips, mirroring and blending match the reference" {
    const a = std.testing.allocator;
    const angles = camera.Angles.init();
    var view = try camera.View.init(a, &angles, 64, 48);
    defer view.deinit(a);
    view.setPose(&angles, 0, 0, 0, 0, 0);
    var sectors: [4]level_module.Sector = undefined;
    for (&sectors) |*sector| {
        sector.* = std.mem.zeroes(level_module.Sector);
        sector.ambient = 20;
        sector.vadjoin = -1;
        sector.ceiling.height = 8;
        sector.floor.height = -4;
    }
    var level: level_module.Level = undefined;
    level.sectors = &sectors;
    var sector_states: [4]scene_module.SectorState = @splat(std.mem.zeroes(scene_module.SectorState));
    var scene: scene_module.Scene = undefined;
    scene.sectors = &sector_states;
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;
    var texels: [99]u8 = undefined;
    for (&texels, 0..) |*byte, i| byte.* = @truncate(i * 17);
    var cells = [_]nwx.Cell{.{ .width = 9, .height = 11, .flags = 0, .pixels = &texels }};
    var parts = [_]nwx.Part{.{ .cell = 0, .raw_x = 0, .raw_y = 0, .offset_x = 1.25, .offset_y = 3.5, .width = 3.75, .height = 4.25, .flags = 0 }};
    var frames = [_]nwx.Frame{.{ .offset_x = 0.125, .offset_y = -0.25, .parts = &parts }};
    var choreographies = [_]nwx.Choreography{.{ .values = .{ 0, 0, 0, 0 }, .directions = 1, .frames_per_direction = 1, .frames = &.{0} }};
    const costume = nwx.Costume{ .arena = undefined, .scale = 1, .secondary_scale = 1, .cells = &cells, .frames = &frames, .choreographies = &choreographies };
    var actors = [_]Actor{.{ .costume = &costume, .sector = 0, .position = .{ .x = -0.4, .y = 0.6, .z = 7.25 }, .yaw = 0, .flags = 12, .secondary_flags = 0, .scale_x = 1.2, .scale_y = 0.85, .height = 4.25, .choreography = 0, .frame = 0, .angle_offset = 0 }};
    var cmap: [8192]u8 = undefined;
    for (&cmap, 0..) |*byte, i| byte.* = @truncate(i * 13);
    var bmap: [4096]u8 = undefined;
    for (&bmap, 0..) |*byte, i| byte.* = @truncate(i * 11 + i / 256 * 7);
    var top: [64]i16 = undefined;
    var bottom: [64]i16 = undefined;
    var dynamic_depth: [64]i16 = undefined;
    var depth = try walls.DepthBuffer.init(a, 64);
    defer depth.deinit(a);
    for (0..64) |x| {
        top[x] = @intCast(3 + x % 5);
        bottom[x] = @intCast(44 - x % 7);
        dynamic_depth[x] = if (x % 7 == 0) 100 else 320;
        depth.furthest[x] = dynamic_depth[x];
        depth.counts[x] = 2;
        depth.strips[x * 30] = .{ .distance = dynamic_depth[x], .sector = 2, .top = top[x], .bottom = 23 };
        depth.strips[x * 30 + 1] = .{ .distance = 320, .sector = 2, .top = 27, .bottom = bottom[x] };
    }
    const window = planes.ClipWindow{ .left = 8, .right = 56, .top = 3, .bottom = 44, .inner_top = 3, .inner_bottom = 44, .top_clip = &top, .bottom_clip = &bottom };
    const hashes = [_][]const u8{
        "469aacb8ad990bb45dccd7b6e0590fa47ebb28fa4fb65ddf238493ca68e45b4e",
        "67fcf6663802fc2d10f241814e068479d83863050afc0c2d0e715d9e06db0ccf",
        "acd63420b1e51d36b3f313f815bcf556ae9b37ae3c7fa483ce7f87fc41c9f222",
        "8b361541285973ec38671905cd06c13eb4132e03ec2cae38fb6656ca60b15204",
        "dd3c1b90d2ddb29f73b2f042ab75e0d81ddf8321316d3141fbe7f7d9b4634bd0",
        "5371d7201e543f4ac37a50a7d6f69351fd5ea0bd5209da0ef9cbd5367097bb0b",
        "42a2c38599a0bd4f29297e4bce68f8275c1101d1189d9c6e60af603c4ae890b5",
        "3c61bc8b8f3c335164621ce10b933b73f8b11c6d263a4e5bd1acf09b160ee563",
        "0a7e739ed17ea1bc1d2d16ba0b6f3cf84670ebc291e9e9a1cdf881be3edca4bb",
        "0a7e739ed17ea1bc1d2d16ba0b6f3cf84670ebc291e9e9a1cdf881be3edca4bb",
        "8b361541285973ec38671905cd06c13eb4132e03ec2cae38fb6656ca60b15204",
        "dd3c1b90d2ddb29f73b2f042ab75e0d81ddf8321316d3141fbe7f7d9b4634bd0",
    };
    for (hashes, 0..) |expected_hash, sample| {
        const water = sample == 3 or sample == 4 or sample >= 8;
        sector_states[0].flags = if (water) 0x80 else 0;
        sectors[0].vadjoin = if (water) 1 else -1;
        sectors[1].ceiling.height = if (water) 3 else 8;
        sectors[1].floor.height = if (water) -1 else -4;
        sector_states[1].flags = if (sample == 8 or sample == 9) 0xc0000000 else 0;
        sector_states[1].ceiling_slope = if (sample >= 8) std.mem.zeroInit(scene_module.Slope, .{ .coeff_x = 0.1, .coeff_z = -0.05, .constant = 1.5 }) else null;
        sector_states[1].floor_slope = if (sample >= 8) std.mem.zeroInit(scene_module.Slope, .{ .coeff_x = 0.1, .coeff_z = -0.05, .constant = -0.25 }) else null;
        parts[0].flags = if (sample == 2) 0x100 else 0;
        const blend = sample == 6 or sample == 7;
        cells[0].flags = if (blend) 0x20 else 0;
        actors[0].flags = if (sample == 5) 4 else 12;
        actors[0].secondary_flags = if (sample == 7) 0x2000000 else 0;
        const lighting = walls.Lighting{ .force_depth = 0, .depth_bias = 0, .depth_strength = 0, .ambient_bias = 0, .ambient = 20, .ambient_min = 17, .color_map = if (sample == 5) null else &cmap, .depth_map = null };
        var framebuffer: [64 * 48]u8 = undefined;
        for (&framebuffer, 0..) |*byte, i| byte.* = @truncate(i * 29);
        var objects = try Objects.init(a, .{ .view = &view, .level = &level, .scene = &scene, .camera_sector = 2, .pixels = &framebuffer, .lighting = lighting, .blend_table = if (blend) &bmap else null }, &actors);
        defer objects.deinit();
        objects.transformed[0] = actors[0].position;
        const mode: Objects.Mode = if (sample == 1 or sample == 4 or sample == 9 or sample == 11) .{ .final = &depth } else .{ .dynamic = .{ .window = window, .depth = &dynamic_depth } };
        try std.testing.expect(try objects.drawActor(0, mode, lighting));
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&framebuffer, &actual, .{});
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, expected_hash);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        if (sample == 0) {
            for ([_]u32{ 0x40000000, 0x80000000 }) |flag| {
                sector_states[0].flags = flag;
                try std.testing.expectError(error.MissingSceneSlope, objects.drawActor(0, mode, lighting));
            }
            sector_states[0].flags = 0;
        }
    }
}

test "sprite sort matches library ordering of truncated depth ties" {
    const distances = [_]f32{ 5.5, 5.25, 2, 8, 1, 5.75, 8.5, 2.5, 5.125, 9, 8.125, 2.25, 10, 1.5, 7, 5.875, 4, 11, 11.5, 3 };
    var transformed: [distances.len]level_module.Vec3 = undefined;
    var actors: [distances.len]Actor = undefined;
    var indices: [distances.len]usize = undefined;
    for (distances, 0..) |distance, i| {
        transformed[i] = .{ .x = 0, .y = 0, .z = distance };
        actors[i].model = null;
        indices[i] = i;
    }
    const objects = Objects{ .allocator = std.testing.allocator, .context = undefined, .actors = &actors, .transformed = &transformed };
    objects.sort(&indices);
    try std.testing.expectEqualSlices(usize, &.{ 18, 17, 12, 3, 10, 6, 9, 14, 8, 5, 0, 15, 1, 16, 7, 19, 2, 13, 11, 4 }, &indices);
}

test "specialized sprite columns skip negative prefix in320 and 640 modes" {
    var translation: [256]u8 = undefined;
    for (&translation, 0..) |*byte, i| byte.* = @as(u8, @intCast(i)) ^ 64;
    for ([_]i32{ 320, 640 }) |width| {
        var view: camera.View = undefined;
        view.width = width;
        var pixels = [_]u8{85} ** (640 * 8);
        var context: Context = undefined;
        context.view = &view;
        context.pixels = pixels[0 .. @as(usize, @intCast(width)) * 8];
        var objects = Objects{ .allocator = std.testing.allocator, .context = context, .actors = &.{}, .transformed = &.{} };
        try objects.column(2, 1, 6, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, -65536, 32768, &translation, .none);
        for ([_]u8{ 65, 65, 85, 85, 85, 85 }, 1..) |expected, y| try std.testing.expectEqual(expected, pixels[y * @as(usize, @intCast(width)) + 2]);
    }
}

test "3DO mixed actor sort matches both reference comparators" {
    const points = [_][3]f32{
        .{ 0, 0, 9.25 },
        .{ 20, 0, 4 },
        .{ 0, -12, 5 },
        .{ 0, 0, 4.25 },
        .{ 1, 0, 2.125 },
        .{ 1, 2, 9 },
        .{ 0, 9, 5 },
        .{ 0, 0, 9.75 },
        .{ 0, 0, 9.5 },
        .{ 0, 0, 10 },
        .{ 0, 0, 20 },
        .{ -15, 0, 4.5 },
        .{ 0, 0, 2 },
        .{ 0, 0, 3 },
        .{ 0, 0, 3.25 },
        .{ 0, 0, 3.5 },
    };
    const kinds = [_]u32{ 1, 2, 2, 1, 2, 2, 2, 1, 2, 2, 1, 2, 2, 2, 1, 2 };
    const modes = [_]u32{ 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0 };
    var actors: [points.len]Actor = undefined;
    var models: [points.len]model_asset.Model = undefined;
    var transformed: [points.len]level_module.Vec3 = undefined;
    var order: [points.len]usize = undefined;
    for (points, kinds, modes, 0..) |p, kind, mode, i| {
        models[i].sort_mode = mode;
        actors[i].model = if (kind == 2) &models[i] else null;
        transformed[i] = .{ .x = p[0], .y = p[1], .z = p[2] };
        order[i] = i;
    }
    const objects = Objects{ .allocator = std.testing.allocator, .context = undefined, .actors = &actors, .transformed = &transformed };
    objects.sort(&order);
    try std.testing.expectEqualSlices(usize, &.{ 9, 6, 13, 4, 10, 7, 0, 1, 11, 2, 5, 8, 3, 14, 15, 12 }, &order);
}
