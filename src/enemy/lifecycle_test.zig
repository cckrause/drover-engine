//! Where dropped items land, checked on two rooms built here so no game
//! files are needed.

const std = @import("std");
const lifecycle = @import("lifecycle.zig");
const physics = @import("physics.zig");
const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const Actor = @import("../render/objects.zig").Actor;

/// Two 10x10 rooms joined by a doorway at x = 10.
const TwoRooms = struct {
    vertices: [2][4]level_module.Vec2,
    walls: [2][4]level_module.Wall,
    sectors: [2]level_module.Sector,
    level: level_module.Level,
    scene: scene_module.Scene,
    angles: camera.Angles,

    fn init(self: *TwoRooms) !void {
        self.vertices = .{
            .{ .{ .x = 0, .z = 0 }, .{ .x = 10, .z = 0 }, .{ .x = 10, .z = 10 }, .{ .x = 0, .z = 10 } },
            .{ .{ .x = 10, .z = 0 }, .{ .x = 20, .z = 0 }, .{ .x = 20, .z = 10 }, .{ .x = 10, .z = 10 } },
        };
        for (&self.walls) |*room| for (room, 0..) |*wall, index| {
            wall.* = std.mem.zeroes(level_module.Wall);
            wall.v1 = @intCast(index);
            wall.v2 = @intCast((index + 1) % 4);
            wall.adjoin = -1;
            wall.mirror = -1;
            wall.dadjoin = -1;
            wall.dmirror = -1;
        };
        self.walls[0][1].adjoin = 1;
        self.walls[0][1].mirror = 3;
        self.walls[1][3].adjoin = 0;
        self.walls[1][3].mirror = 1;
        for (&self.sectors, 0..) |*sector, index| {
            sector.* = std.mem.zeroes(level_module.Sector);
            sector.vadjoin = -1;
            sector.ceiling.height = 20;
            sector.vertices = &self.vertices[index];
            sector.walls = &self.walls[index];
        }
        self.level = std.mem.zeroInit(level_module.Level, .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) });
        self.level.sectors = &self.sectors;
        self.angles = camera.Angles.init();
        self.scene = try scene_module.Scene.init(std.testing.allocator, &self.level, &self.angles);
    }

    fn deinit(self: *TwoRooms) void {
        self.scene.deinit();
    }

    fn world(self: *const TwoRooms) physics.World {
        return .{ .level = &self.level, .scene = &self.scene, .angles = &self.angles, .actors = .{ .entries = &.{} } };
    }
};

fn actorAt(x: f32, z: f32) Actor {
    return .{ .sector = 0, .position = .{ .x = x, .y = 0, .z = z }, .yaw = 0, .flags = 0, .secondary_flags = 0, .scale_x = 1, .scale_y = 1, .height = 0, .choreography = 0, .frame = 0, .angle_offset = 0 };
}

test "drop placement: an item dropped at a doorway lands in the next room every time" {
    var rooms: TwoRooms = undefined;
    try rooms.init();
    defer rooms.deinit();
    const actor = actorAt(9, 5);
    const first = try lifecycle.dropPlacement(rooms.world(), actor);
    try std.testing.expectEqual(@as(usize, 1), first.sector);
    try std.testing.expectEqual(@as(f32, 10.5), first.position.x);
    try std.testing.expectEqual(@as(f32, 6.5), first.position.z);
    try std.testing.expectEqual(@as(u32, 1), rooms.scene.collision_check.*);
    const second = try lifecycle.dropPlacement(rooms.world(), actor);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, 2), rooms.scene.collision_check.*);
}

test "drop placement: only the doorway and its twin are recorded as crossed" {
    var rooms: TwoRooms = undefined;
    try rooms.init();
    defer rooms.deinit();
    _ = try lifecycle.dropPlacement(rooms.world(), actorAt(9, 5));
    const check = rooms.scene.collision_check.*;
    for (rooms.scene.sectors, 0..) |sector, sector_index| for (sector.walls, 0..) |wall, wall_index| {
        const crossed = (sector_index == 0 and wall_index == 1) or (sector_index == 1 and wall_index == 3);
        try std.testing.expectEqual(if (crossed) check else 0, wall.last_collision_check);
    };
    for (rooms.scene.sectors) |sector| try std.testing.expectEqual(@as(u32, 0), sector.last_collision_check);
}

test "drop placement: an item dropped against a solid wall stays where it was" {
    var rooms: TwoRooms = undefined;
    try rooms.init();
    defer rooms.deinit();
    const actor = actorAt(5, 9);
    const placement = try lifecycle.dropPlacement(rooms.world(), actor);
    try std.testing.expectEqual(@as(usize, 0), placement.sector);
    try std.testing.expectEqual(actor.position, placement.position);
}

test "drop placement: a bad start sector is refused before any wall is touched" {
    var rooms: TwoRooms = undefined;
    try rooms.init();
    defer rooms.deinit();
    var actor = actorAt(9, 5);
    actor.sector = 2;
    try std.testing.expectError(error.InvalidEnemySector, lifecycle.dropPlacement(rooms.world(), actor));
    try std.testing.expectEqual(@as(u32, 0), rooms.scene.collision_check.*);
}
