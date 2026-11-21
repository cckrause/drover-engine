//! How much a sound is muffled by the geometry between it and the listener,
//! for sounds at a fixed position.
//!
//! Sounds bound to an actor take their own path and must not be routed
//! through here.

const std = @import("std");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const intersection = @import("../player/collision.zig").intersection;
const Vec2 = level_module.Vec2;
const Vec3 = level_module.Vec3;

const Wall = struct { sector: usize, index: usize };

pub const ActorPoint = struct { position: Vec3, sector: usize, height: f32, radius: f32 };

pub const Cache = struct {
    allocator: std.mem.Allocator,
    lists: []?[]const u16,
    offsets: []usize,
    seen: []u32,
    generation: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, level: *const level_module.Level) !Cache {
        if (level.sectors.len > 32768) return error.UnsupportedAudioSectorCount;
        const lists = try allocator.alloc(?[]const u16, level.sectors.len);
        errdefer allocator.free(lists);
        @memset(lists, null);
        const offsets = try allocator.alloc(usize, level.sectors.len + 1);
        errdefer allocator.free(offsets);
        offsets[0] = 0;
        for (level.sectors, 0..) |sector, index| offsets[index + 1] = offsets[index] + sector.walls.len;
        const seen = try allocator.alloc(u32, offsets[level.sectors.len]);
        @memset(seen, 0);
        return .{ .allocator = allocator, .lists = lists, .offsets = offsets, .seen = seen };
    }

    pub fn deinit(self: *Cache) void {
        for (self.lists) |list| if (list) |entries| self.allocator.free(entries);
        self.allocator.free(self.lists);
        self.allocator.free(self.offsets);
        self.allocator.free(self.seen);
        self.* = undefined;
    }

    pub fn volume(self: *Cache, level: *const level_module.Level, scene: *const scene_module.Scene, angles: *const camera.Angles, source_sector: usize, listener_sector: usize, source: Vec3, listener_eye: Vec3, value: i32, flags: u32, now_ms: u32) !i32 {
        if (flags & 0x10 != 0) return value;
        if (!try self.connected(level, scene, angles, source_sector, listener_sector)) return value >> 1;
        if (!try self.visible(level, scene, angles, source_sector, listener_sector, source, listener_eye, now_ms)) return value >> 1;
        return value;
    }

    pub fn connected(self: *Cache, level: *const level_module.Level, scene: *const scene_module.Scene, angles: *const camera.Angles, from: usize, to: usize) !bool {
        if (from >= self.lists.len or to >= self.lists.len) return error.InvalidAudioSector;
        if (from == to) return true;
        if (self.lists[from] == null) try self.build(level, scene, angles, from);
        for (self.lists[from].?) |sector| if (sector == to) return true;
        return false;
    }

    pub fn visible(self: *Cache, level: *const level_module.Level, scene: *const scene_module.Scene, angles: *const camera.Angles, from: usize, to: usize, start: Vec3, end: Vec3, now_ms: u32) !bool {
        if (from >= self.lists.len or to >= self.lists.len) return error.InvalidAudioSector;
        if (now_ms & 1 == 0 and !try self.connected(level, scene, angles, from, to)) return false;
        var cast = self.ray(level, scene, .{ .x = start.x, .z = start.z }, .{ .x = end.x, .z = end.z });
        if (cast.start.x == cast.end.x and cast.start.z == cast.end.z) return from == to;
        const gradient = f((@as(f64, end.y) - start.y) / distance(cast.start, cast.end));
        var sector = from;
        while (cast.next(sector)) |hit| {
            const wall = level.sectors[hit.sector].walls[hit.index];
            if (wall.adjoin < 0) return false;
            const y = f(@as(f64, cast.previous) * gradient + start.y);
            const main: usize = @intCast(wall.adjoin);
            const next: usize = if (wall.dadjoin >= 0 and y < level.sectors[main].floor.height) @intCast(wall.dadjoin) else main;
            const position = Vec3{ .x = cast.hit.x, .y = y, .z = cast.hit.z };
            if (try ceiling(level, scene, sector, position) < y) return false;
            if (try ceiling(level, scene, next, position) < y) return false;
            if (y < try floor(level, scene, sector, position)) return false;
            if (y < try floor(level, scene, next, position)) return false;
            sector = next;
        }
        return sector == to;
    }

    pub fn actorsVisible(self: *Cache, level: *const level_module.Level, scene: *const scene_module.Scene, angles: *const camera.Angles, from: ActorPoint, to: ActorPoint, random: *u32, now_ms: u32) !bool {
        const sampled = try sampleActorRay(level, scene, angles, from, to, random);
        return self.visible(level, scene, angles, from.sector, to.sector, sampled.start, sampled.end, now_ms);
    }

    pub fn ray(self: *Cache, level: *const level_module.Level, scene: *const scene_module.Scene, start: Vec2, end: Vec2) Ray {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.seen, 0);
            self.generation = 1;
        }
        return .{ .cache = self, .level = level, .scene = scene, .start = start, .end = end };
    }

    fn build(self: *Cache, level: *const level_module.Level, scene: *const scene_module.Scene, angles: *const camera.Angles, sector: usize) !void {
        var list: List = .{};
        _ = list.add(sector);
        for (level.sectors[sector].walls, scene.sectors[sector].walls) |wall, state| {
            for ([_]i32{ wall.adjoin, wall.dadjoin }) |adjacent| {
                if (adjacent < 0) continue;
                const next: usize = @intCast(adjacent);
                const midpoint = offset(angles, level.sectors[sector].vertices[wall.v1], f(@as(f64, state.length) * 0.5), state.angle -% 45);
                var angle = state.angle;
                for (0..36) |_| {
                    angle = @intCast((@as(u16, @bitCast(angle)) -% 227) & 0x3fff);
                    const endpoint = offset(angles, midpoint, 100, angle);
                    _ = list.add(next);
                    var ray_state = self.ray(level, scene, midpoint, endpoint);
                    if (ray_state.next(next)) |hit| {
                        const crossed = level.sectors[hit.sector].walls[hit.index];
                        if (crossed.adjoin < 0) continue;
                        _ = ray_state.walk(@intCast(crossed.adjoin), &list);
                        if (crossed.dadjoin >= 0) _ = ray_state.walk(@intCast(crossed.dadjoin), &list);
                    }
                }
            }
        }
        self.lists[sector] = try self.allocator.dupe(u16, list.entries[0..list.count]);
    }
};

pub const ActorRay = struct { start: Vec3, end: Vec3 };

const List = struct {
    entries: [512]u16 = undefined,
    count: usize = 0,

    fn add(self: *List, sector: usize) bool {
        if (self.count == 512) return false;
        for (self.entries[0..self.count]) |entry| if (entry == sector) return true;
        self.entries[self.count] = @intCast(sector);
        self.count += 1;
        return self.count < 512;
    }
};

pub const Ray = struct {
    cache: *Cache,
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    start: Vec2,
    end: Vec2,
    previous: f32 = -0x1p31,
    hit: Vec2 = .{ .x = 0, .z = 0 },

    pub fn next(self: *Ray, sector: usize) ?Wall {
        if (self.start.x == self.end.x and self.start.z == self.end.z) return null;
        var best: ?Wall = null;
        var closest: f32 = 0x1p31;
        const source = self.level.sectors[sector];
        for (source.walls, self.scene.sectors[sector].walls, 0..) |wall, state, index| {
            if (self.cache.seen[self.cache.offsets[sector] + index] == self.cache.generation) continue;
            const hit = intersection(self.start, self.end, source.vertices[wall.v1], source.vertices[wall.v2]) orelse continue;
            if (self.start.x == hit.x and self.start.z == hit.z and 0 <= (@as(f64, self.end.x) - self.start.x) * state.direction.z - (@as(f64, self.end.z) - self.start.z) * state.direction.x) continue;
            const exact = distance(self.start, hit);
            const stored = f(exact);
            if (exact < closest and self.previous < stored) {
                closest = stored;
                best = .{ .sector = sector, .index = index };
                self.hit = hit;
            }
        }
        if (best) |wall| {
            self.mark(wall);
            for (mirrors(source.walls[wall.index])) |mirror| if (mirror) |m| {
                self.mark(m);
                for (mirrors(self.level.sectors[m.sector].walls[m.index])) |second| if (second) |s| self.mark(s);
            };
            self.previous = closest;
        }
        return best;
    }

    fn walk(self: *Ray, sector: usize, list: *List) bool {
        if (!list.add(sector)) return false;
        var current = self.next(sector);
        while (current) |hit| {
            const wall = self.level.sectors[hit.sector].walls[hit.index];
            if (wall.adjoin < 0) return true;
            const adjoining: usize = @intCast(wall.adjoin);
            if (!list.add(adjoining)) return false;
            current = self.next(adjoining);
            if (current) |next_hit| {
                const double = self.level.sectors[next_hit.sector].walls[next_hit.index].dadjoin;
                if (double >= 0 and !self.walk(@intCast(double), list)) return false;
            }
        }
        return true;
    }

    fn mark(self: *Ray, wall: Wall) void {
        self.cache.seen[self.cache.offsets[wall.sector] + wall.index] = self.cache.generation;
    }
};

pub fn sampleActorRay(level: *const level_module.Level, scene: *const scene_module.Scene, angles: *const camera.Angles, from: ActorPoint, to: ActorPoint, random: *u32) !ActorRay {
    const rng = @import("../player/weapon.zig");
    const from_y = if (@as(u32, @bitCast(from.height)) < 0x80000001)
        f((@as(f64, from.position.y) - rng.randomFloat(random, 2)) + from.height)
    else
        f(@as(f64, try ceiling(level, scene, from.sector, from.position)) - 1);
    const to_y = if (@as(u32, @bitCast(to.height)) < 0x80000001)
        f((@as(f64, to.position.y) - rng.randomFloat(random, 2)) + to.height)
    else
        f(@as(f64, try ceiling(level, scene, to.sector, to.position)) - 1);
    const from_radius = f(rng.randomFloat(random, @abs(from.radius)));
    const to_radius = f(rng.randomFloat(random, @abs(to.radius)));
    const from_angle: i16 = @intCast(rng.randomNext(random) & 0x3fff);
    const to_angle: i16 = @intCast(rng.randomNext(random) & 0x3fff);
    const start = offset(angles, .{ .x = from.position.x, .z = from.position.z }, from_radius, from_angle);
    const end = offset(angles, .{ .x = to.position.x, .z = to.position.z }, to_radius, to_angle);
    return .{ .start = .{ .x = start.x, .y = from_y, .z = start.z }, .end = .{ .x = end.x, .y = to_y, .z = end.z } };
}

fn mirrors(wall: level_module.Wall) [2]?Wall {
    return .{ if (wall.adjoin < 0) null else .{ .sector = @intCast(wall.adjoin), .index = @intCast(wall.mirror) }, if (wall.dadjoin < 0) null else .{ .sector = @intCast(wall.dadjoin), .index = @intCast(wall.dmirror) } };
}

fn offset(angles: *const camera.Angles, point: Vec2, length: f32, angle: i16) Vec2 {
    const trig = angles.sinCos(angle);
    return .{ .x = f(@as(f64, length) * trig.sin + point.x), .z = f(@as(f64, length) * trig.cos + point.z) };
}

fn distance(a: Vec2, b: Vec2) f64 {
    const x = @abs(f(@as(f64, b.x) - a.x));
    const z = @abs(f(@as(f64, b.z) - a.z));
    return (@as(f64, x) - @as(f64, @min(x, z)) * 0.25 * 2.0) + z;
}

fn ceiling(level: *const level_module.Level, scene: *const scene_module.Scene, sector: usize, point: Vec3) !f32 {
    if (scene.sectors[sector].flags & 0x80000000 == 0) return level.sectors[sector].ceiling.height;
    return height(scene.sectors[sector].ceiling_slope orelse return error.MissingAudioSlope, point);
}

fn floor(level: *const level_module.Level, scene: *const scene_module.Scene, sector: usize, point: Vec3) !f32 {
    if (scene.sectors[sector].flags & 0x40000000 == 0) return level.sectors[sector].floor.height;
    return height(scene.sectors[sector].floor_slope orelse return error.MissingAudioSlope, point);
}

fn height(slope: scene_module.Slope, point: Vec3) f32 {
    return f((@as(f64, slope.constant) - @as(f64, slope.coeff_x) * point.x) - @as(f64, slope.coeff_z) * point.z);
}

fn f(value: f64) f32 {
    return @floatCast(value);
}

test "Hideout audio fans and LOS match the reference traversal" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", allocator, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(bytes);
    var level = try level_module.Level.parse(allocator, try archive.find("hideout.lvb", 0x4c565446));
    defer level.deinit();
    var startup = try @import("../render/initial_state.zig").InfStartup.apply(allocator, &level, try archive.find("hideout.inf", 0));
    defer startup.deinit();
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(allocator, &level, &angles);
    defer scene.deinit();
    startup.applyScene(&level, &scene);
    var cache = try Cache.init(allocator, &level);
    defer cache.deinit();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const sectors = [_]usize{ 0, 7, 20, 36, 80, 100, 150, 200, 250, 300, 334, 356, 400, 409, 410, 415 };
    for (sectors) |sector| {
        try cache.build(&level, &scene, &angles, sector);
        const list = cache.lists[sector].?;
        var word: [2]u8 = undefined;
        std.mem.writeInt(u16, &word, @intCast(list.len), .little);
        hash.update(&word);
        for (list) |entry| {
            std.mem.writeInt(u16, &word, entry, .little);
            hash.update(&word);
        }
        const first = level.sectors[sector].vertices[0];
        const source: Vec3 = .{ .x = f(@as(f64, first.x) + 1.25), .y = f(@as(f64, level.sectors[sector].floor.height) + 2.5), .z = f(@as(f64, first.z) - 0.75) };
        for ([_]u32{ 0, 1 }) |now| {
            for ([_]f32{ 2.5, 102.5 }) |eye_y| {
                const visible = try cache.visible(&level, &scene, &angles, sector, 410, source, .{ .x = 322.36, .y = eye_y, .z = 271.88 }, now);
                hash.update(&.{@intFromBool(visible)});
            }
        }
    }
    for (sectors) |sector| {
        const source = level.sectors[sector];
        for (source.walls, scene.sectors[sector].walls) |wall, state| {
            if (wall.adjoin < 0) continue;
            const first = source.vertices[wall.v1];
            const last = source.vertices[wall.v2];
            const x = f((@as(f64, first.x) + last.x) * 0.5);
            const z = f((@as(f64, first.z) + last.z) * 0.5);
            for ([_]f32{ f(@as(f64, source.floor.height) + 2.5), f(@as(f64, source.floor.height) - 1), f(@as(f64, source.ceiling.height) + 1) }) |y| {
                const start = Vec3{ .x = f(@as(f64, x) - @as(f64, state.direction.z) * 0.25), .y = y, .z = f(@as(f64, z) + @as(f64, state.direction.x) * 0.25) };
                const end = Vec3{ .x = f(@as(f64, x) + @as(f64, state.direction.z) * 0.25), .y = y, .z = f(@as(f64, z) - @as(f64, state.direction.x) * 0.25) };
                const visible = try cache.visible(&level, &scene, &angles, sector, @intCast(wall.adjoin), start, end, 1);
                hash.update(&.{@intFromBool(visible)});
            }
        }
    }
    const actual = hash.finalResult();
    try std.testing.expectEqualStrings("c3544d4dcd8cfd378c9d592aea077f43bb08306b8b1bd90f285ccf341f812cee", &std.fmt.bytesToHex(actual, .lower));
}
