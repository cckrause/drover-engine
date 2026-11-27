//! The geometry side of the script engine: moving walls, floors and
//! ceilings, and which actors they carry.
//!
//! A movement query leaves its diameter behind, and the next query reuses it
//! even for a different actor - that is how the data expects it to behave.
//! A network game supplies its marks here so changes can be sent on.

const std = @import("std");

const level_module = @import("../assets/level.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene_module = @import("../render/scene.zig");
const Actor = @import("../render/objects.zig").Actor;
const Player = @import("../player/movement.zig").Player;
const collision = @import("../player/collision.zig");
const actor_links = @import("../render/actor_links.zig");
const Vec2 = level_module.Vec2;

pub const World = struct {
    level: *level_module.Level,
    scene: *scene_module.Scene,
    angles: *const camera.Angles,
    actors: []const Actor,
    links: ?*const actor_links.Links = null,
    source_to_entry: ?[]const ?usize = null,
    live_entries: ?*const []Actor = null,
    live_slots: ?*const []?Actor = null,
    loader: ?collision.ActorLoader = null,
    player: ?*Player = null,
    loaded_sectors: ?[]const bool = null,
    required_sectors: ?[]bool = null,
    collision_diameter: f32,
    marks: ?Marks = null,
    actor_messages: ?struct {
        context: *anyopaque,
        send: *const fn (*anyopaque, usize, u32) anyerror!void,
    } = null,
    reshaped: ?Reshaped = null,

    fn actorView(self: *const World) collision.Actors {
        return .{
            .entries = self.actors,
            .links = self.links,
            .source_to_entry = self.source_to_entry,
            .live_entries = self.live_entries,
            .live_slots = self.live_slots,
            .loader = self.loader,
            .loaded_sectors = self.loaded_sectors,
            .required_sectors = self.required_sectors,
            .player = if (self.player) |player| .{
                .position = player.position,
                .sector = player.sector,
                .height = player.body_height,
                .radius = player.radius,
                .flags = 0,
                .secondary_flags = 0x10,
            } else null,
        };
    }
};

pub const Reshaped = struct {
    context: *anyopaque,
    forget: *const fn (*anyopaque, usize) anyerror!void,
};

pub const Marks = struct {
    context: *anyopaque,
    mark: *const fn (*anyopaque, Mark) anyerror!void,

    pub fn call(self: Marks, value: Mark) !void {
        try self.mark(self.context, value);
    }
};

pub const Mark = union(enum) {
    light: usize,
    floor: usize,
    ceiling: usize,
    sector_flags: usize,
    wall_flags: WallRef,
    corners: WallRef,
};

pub const WallRef = struct { sector: usize, index: usize };

pub const Contact = struct {
    wall: WallRef,
    actor: ?usize,
    source_index: ?usize = null,
};

pub fn moveVertical(
    world: *World,
    sector_index: usize,
    floor_delta: f32,
    ceiling_delta: f32,
) !void {
    if (!std.math.isFinite(
        floor_delta,
    ) or !std.math.isFinite(ceiling_delta)) return error.InvalidInfTransform;

    const count = world.level.sectors.len;
    if (sector_index >= count or world.scene.sectors.len != count) return error.InvalidInfWorld;

    if (world.loaded_sectors) |loaded| if (loaded.len != count) return error.InvalidInfWorld;

    if (world.required_sectors) |required| if (required.len != count) return error.InvalidInfWorld;

    const sector = &world.level.sectors[sector_index];
    const floor = f(@as(f64, sector.floor.height) + floor_delta);
    const ceiling = f(@as(f64, sector.ceiling.height) + ceiling_delta);
    if (!std.math.isFinite(floor) or !std.math.isFinite(ceiling)) return error.InvalidInfTransform;

    for (sector.walls, 0..) |wall, index| {
        try validateFloorWall(world, .{ .sector = sector_index, .index = index });

        for ([_]i32{
            wall.adjoin,
            wall.dadjoin,
        }, [_]i32{ wall.mirror, wall.dmirror }) |adjacent, mirror| {
            if (adjacent < 0) continue;

            try validateFloorWall(
                world,
                .{ .sector = @intCast(adjacent), .index = @intCast(mirror) },
            );
        }
    }

    const actors = world.actorView();
    try actors.requireSector(sector_index);
    var iterator = actors.inLoadedSector(sector_index);

    while (iterator.next()) |index| {
        if (index == actor_links.player_id) continue;

        const actor = actors.get(index);

        if (actor.flags & 0x400 == 0) continue;

        if (!std.math.isFinite(
            f(@as(f64, actor.position.y) + floor_delta),
        )) return error.InvalidInfTransform;

        const entries = world.live_entries orelse return error.MissingInfMutableActors;
        if (index >= entries.*.len) return error.InvalidInfActor;

        if (world.live_slots) |slots| {
            const source = actor.source_index orelse return error.MissingInfActorIdentity;
            if (source >= slots.*.len or slots.*[source] == null) return error.InvalidInfActor;
        }
    }

    if (@abs(floor_delta) != 0) {
        const pixels = f(@as(f64, floor_delta) * 8.0);

        for (sector.walls, 0..) |_, index| try shiftFloorWall(
            world,
            .{ .sector = sector_index, .index = index },
            pixels,
        );

        const mirrored_pixels = f(-@as(f64, floor_delta) * 8.0);

        for (sector.walls) |wall| {
            if (wall.adjoin >= 0) try shiftFloorWall(
                world,
                .{ .sector = @intCast(wall.adjoin), .index = @intCast(wall.mirror) },
                mirrored_pixels,
            );

            if (wall.dadjoin >= 0) try shiftFloorWall(
                world,
                .{ .sector = @intCast(wall.dadjoin), .index = @intCast(wall.dmirror) },
                mirrored_pixels,
            );
        }
    }

    iterator = actors.inLoadedSector(sector_index);

    while (iterator.next()) |index| {
        if (index == actor_links.player_id) continue;

        const actor = actors.get(index);

        if (actor.flags & 0x400 == 0) continue;

        const y = f(@as(f64, actor.position.y) + floor_delta);
        world.live_entries.?.*[index].position.y = y;

        if (world.live_slots) |slots| slots.*[actor.source_index.?].?.position.y = y;
    }

    sector.ceiling.height = ceiling;
    sector.floor.height = floor;

    for (sector.walls, 0..) |wall, index| {
        try world.scene.prepareWall(world.level, sector_index, index);

        if (wall.adjoin >= 0) try world.scene.prepareWall(
            world.level,
            @intCast(wall.adjoin),
            @intCast(wall.mirror),
        );
    }

    if (world.marks) |marks| {
        if (@abs(floor_delta) != 0) return marks.call(.{ .floor = sector_index });
        if (@abs(ceiling_delta) != 0) return marks.call(.{ .ceiling = sector_index });
    }
}

pub fn move(world: *World, sector_index: usize, delta: f32, sin: f32, cos: f32) !?Contact {
    if (!std.math.isFinite(
        delta,
    ) or !std.math.isFinite(sin) or !std.math.isFinite(cos)) return error.InvalidInfTransform;

    try preflight(world, sector_index, false);

    const displacement = Vec2{ .x = f(@as(f64, sin) * delta), .z = f(@as(f64, cos) * delta) };
    var contact: ?Contact = null;

    for (world.level.sectors[sector_index].walls, 0..) |wall, i| {
        if (world.scene.sectors[sector_index].walls[i].flags & 0x40 == 0) continue;

        try moveWall(world, .{ .sector = sector_index, .index = i }, displacement, &contact);

        if (wall.adjoin >= 0) {
            const mirror = WallRef{
                .sector = @intCast(wall.adjoin),
                .index = @intCast(wall.mirror),
            };

            if (world.scene.sectors[mirror.sector].walls[mirror.index].flags & 0x40 != 0)
                try moveWall(world, mirror, displacement, &contact);
        }

        if (wall.dadjoin >= 0) {
            const mirror = WallRef{
                .sector = @intCast(wall.dadjoin),
                .index = @intCast(wall.dmirror),
            };

            if (world.scene.sectors[mirror.sector].walls[mirror.index].flags & 0x40 != 0)
                try moveWall(world, mirror, displacement, &contact);
        }
    }

    return contact;
}

pub fn spin(
    world: *World,
    sector_index: usize,
    angle: i16,
    center: Vec2,
    base_vertices: []const []const Vec2,
) !?Contact {
    if (!std.math.isFinite(
        center.x,
    ) or !std.math.isFinite(center.z)) return error.InvalidInfTransform;

    if (base_vertices.len != world.level.sectors.len) return error.InvalidInfOriginalVertices;

    for (world.level.sectors, base_vertices) |sector, original|
        if (original.len != sector.vertices.len) return error.InvalidInfOriginalVertices;

    try preflight(world, sector_index, true);

    const direction = world.angles.sinCos(angle);
    var contact: ?Contact = null;

    for (world.level.sectors[sector_index].walls, 0..) |wall, i| {
        if (world.scene.sectors[sector_index].walls[i].flags & 0x40 == 0) continue;

        try spinWall(
            world,
            .{ .sector = sector_index, .index = i },
            direction.sin,
            direction.cos,
            center,
            base_vertices,
            &contact,
        );

        if (wall.adjoin >= 0)
            try spinWall(
                world,
                .{ .sector = @intCast(wall.adjoin), .index = @intCast(wall.mirror) },
                direction.sin,
                direction.cos,
                center,
                base_vertices,
                &contact,
            );

        if (wall.dadjoin >= 0)
            try spinWall(
                world,
                .{ .sector = @intCast(wall.dadjoin), .index = @intCast(wall.dmirror) },
                direction.sin,
                direction.cos,
                center,
                base_vertices,
                &contact,
            );
    }

    return contact;
}

pub fn ensureLoaded(world: *World, sector_index: usize) !void {
    return preflight(world, sector_index, true);
}

pub fn wallVectors(
    level: *const level_module.Level,
    scene: *scene_module.Scene,
    ref: WallRef,
) !void {
    const sector = level.sectors[ref.sector];
    const wall = sector.walls[ref.index];
    const state = &scene.sectors[ref.sector].walls[ref.index];
    const first = sector.vertices[wall.v1];
    const last = sector.vertices[wall.v2];
    const dx = f(@as(f64, last.x) - first.x);
    const dz = f(@as(f64, last.z) - first.z);
    if (!std.math.isFinite(dx) or !std.math.isFinite(dz)) return error.InvalidInfTransform;

    const half_x = f(@as(f64, dx) * 0.5);
    const half_z = f(@as(f64, dz) * 0.5);
    const squared = f(@as(f64, half_x) * half_x + @as(f64, half_z) * half_z);
    const root = f(@sqrt(@as(f64, squared)));
    if (!std.math.isFinite(root)) return error.InvalidInfTransform;

    state.length = f(@as(f64, root) * 2);
    state.direction = if (state.length == 0) .{ .x = 0, .z = 0 } else .{
        .x = f(@as(f64, dx) / state.length),
        .z = f(@as(f64, dz) / state.length),
    };

    const radians = f(std.math.atan2(@as(f64, dx), @as(f64, dz)));
    const raw_angle: i32 = @intFromFloat(@as(f64, radians) * 0.15915494309644432 * 16384);

    state.angle = @intCast(raw_angle & 0x3fff);
    state.runtime_flags |= 1;
}

fn validateFloorWall(world: *const World, ref: WallRef) !void {
    if (ref.sector >= world.level.sectors.len) return error.InvalidInfMirror;

    const sector = world.level.sectors[ref.sector];
    if (ref.index >= sector.walls.len or world.scene.sectors[ref.sector].walls.len != sector.walls.len) return error.InvalidInfMirror;

    const wall = sector.walls[ref.index];
    if (wall.v1 >= sector.vertices.len or wall.v2 >= sector.vertices.len) return error.InvalidInfWorld;

    for ([_]i32{
        wall.adjoin,
        wall.dadjoin,
    }, [_]i32{ wall.mirror, wall.dmirror }) |adjacent, mirror| {
        if (adjacent < -1 or mirror < -1) return error.InvalidInfMirror;
        if (adjacent < 0) continue;
        if (adjacent >= world.level.sectors.len or mirror < 0 or mirror >= world.level.sectors[@intCast(adjacent)].walls.len) return error.InvalidInfMirror;
    }
}

fn shiftFloorWall(world: *World, ref: WallRef, pixels: f32) !void {
    const wall = &world.level.sectors[ref.sector].walls[ref.index];
    const state = &world.scene.sectors[ref.sector].walls[ref.index];

    if (state.flags & 8 != 0) {
        const surface = if (wall.adjoin < 0) &wall.mid else &wall.bottom;
        const offset = f(@as(f64, surface.offset.z) + pixels);
        if (!std.math.isFinite(offset)) return error.InvalidInfTransform;

        surface.offset.z = offset;
        state.runtime_flags |= 1;
    }

    if (state.flags & 0x10 != 0) {
        const offset = f(@as(f64, wall.overlay.offset.z) + pixels);
        if (!std.math.isFinite(offset)) return error.InvalidInfTransform;
        wall.overlay.offset.z = offset;
        state.runtime_flags |= 1;
    }
}

fn preflight(world: *World, sector_index: usize, rotating: bool) !void {
    const count = world.level.sectors.len;
    if (sector_index >= count or world.scene.sectors.len != count) return error.InvalidInfWorld;

    if (world.loaded_sectors) |loaded| if (loaded.len != count) return error.InvalidInfWorld;

    if (world.required_sectors) |required| if (required.len != count) return error.InvalidInfWorld;

    const actors = world.actorView();

    for (world.level.sectors[sector_index].walls, 0..) |wall, i| {
        if (world.scene.sectors[sector_index].walls[i].flags & 0x40 == 0) continue;

        try actors.requireSector(sector_index);

        for ([_]i32{
            wall.adjoin,
            wall.dadjoin,
        }, [_]i32{ wall.mirror, wall.dmirror }) |adjacent, mirror| {
            if (adjacent < 0) continue;

            if (mirror < 0) return error.InvalidInfMirror;

            const other: usize = @intCast(adjacent);
            const other_wall: usize = @intCast(mirror);
            if (other >= count or other_wall >= world.scene.sectors[other].walls.len) return error.InvalidInfMirror;

            if (rotating or world.scene.sectors[other].walls[other_wall].flags & 0x40 != 0) {
                try actors.requireSector(other);
            }
        }
    }
}

fn moveWall(world: *World, ref: WallRef, displacement: Vec2, contact: *?Contact) !void {
    const sector = &world.level.sectors[ref.sector];
    const wall = sector.walls[ref.index];
    const vertex = &sector.vertices[wall.v1];
    const moved = Vec2{
        .x = f(@as(f64, vertex.x) + displacement.x),
        .z = f(@as(f64, vertex.z) + displacement.z),
    };

    if (!std.math.isFinite(
        moved.x,
    ) or !std.math.isFinite(moved.z)) return error.InvalidInfTransform;

    vertex.* = moved;
    world.scene.sectors[ref.sector].runtime_flags |= 1;

    try updateWall(world, ref, contact);

    const previous = WallRef{
        .sector = ref.sector,
        .index = if (ref.index == 0) sector.walls.len - 1 else ref.index - 1,
    };

    const endpoint = sector.vertices[sector.walls[previous.index].v2];

    if (vertex.x == endpoint.x and vertex.z == endpoint.z) try updateWall(world, previous, contact);

    if (world.reshaped) |hook| try hook.forget(hook.context, ref.sector);
}

fn spinWall(
    world: *World,
    ref: WallRef,
    sin: f32,
    cos: f32,
    center: Vec2,
    originals: []const []const Vec2,
    contact: *?Contact,
) !void {
    const sector = &world.level.sectors[ref.sector];
    const wall = sector.walls[ref.index];

    _ = originals;

    const original = world.scene.sectors[ref.sector].walls[ref.index].original_start;
    const x = @as(f64, original.x) - center.x;
    const z = @as(f64, original.z) - center.z;
    const rotated = Vec2{
        .x = f((@as(f64, cos) * x - @as(f64, sin) * z) + center.x),
        .z = f((z * cos + @as(f64, sin) * x) + center.z),
    };

    if (!std.math.isFinite(
        rotated.x,
    ) or !std.math.isFinite(rotated.z)) return error.InvalidInfTransform;

    sector.vertices[wall.v1] = rotated;
    world.scene.sectors[ref.sector].runtime_flags |= 1;

    try updateWall(world, ref, contact);
    try updateWall(
        world,
        .{
            .sector = ref.sector,
            .index = if (ref.index == 0) sector.walls.len - 1 else ref.index - 1,
        },
        contact,
    );

    if (world.reshaped) |hook| try hook.forget(hook.context, ref.sector);
}

fn updateWall(world: *World, ref: WallRef, contact: *?Contact) !void {
    try wallVectors(world.level, world.scene, ref);
    if (try checkActors(world, ref)) |hit| contact.* = hit;
    if (world.marks) |marks| try marks.call(.{ .corners = ref });
}

fn checkActors(world: *const World, ref: WallRef) !?Contact {
    const sector = world.level.sectors[ref.sector];
    const first = sector.vertices[sector.walls[ref.index].v1];
    const wall = world.scene.sectors[ref.sector].walls[ref.index];
    const actors = world.actorView();
    var iterator = try actors.inSector(ref.sector);

    while (iterator.next()) |i| {
        if (i == actor_links.player_id) {
            const player = world.player.?;
            if (circleTouchesWall(
                first,
                wall.direction,
                wall.length,
                .{ .x = player.position.x, .z = player.position.z },
                @abs(player.radius),
                world.collision_diameter,
            ))
                return Contact{ .wall = ref, .actor = null };

            continue;
        }

        const actor = actors.get(i);

        if (actor.sector != ref.sector) continue;

        if (actor.flags & 0x100 != 0) continue;

        if (actor.secondary_flags & 0x20 != 0) continue;

        if (actor.secondary_flags & 0x400 != 0) continue;

        if (actor.secondary_flags & 0x800 != 0) continue;

        if (!circleTouchesWall(
            first,
            wall.direction,
            wall.length,
            .{ .x = actor.position.x, .z = actor.position.z },
            @abs(actor.collision_radius),
            world.collision_diameter,
        )) continue;

        if (actor.secondary_flags & 0x4000 != 0) {
            const sink = world.actor_messages orelse return error.MissingInfActorMessageRuntime;
            try sink.send(
                sink.context,
                actor.source_index orelse return error.MissingInfActorIdentity,
                0x66,
            );
        }

        return Contact{ .wall = ref, .actor = i, .source_index = actor.source_index };
    }

    return null;
}

fn circleTouchesWall(
    first: Vec2,
    direction: Vec2,
    length: f32,
    position: Vec2,
    radius: f32,
    collision_diameter: f32,
) bool {
    const dx = f(@as(f64, position.x) - first.x);
    const dz = f(@as(f64, position.z) - first.z);
    const cross = @as(f64, dx) * direction.z - @as(f64, direction.x) * dz;
    if (cross < 0 or radius < f(cross)) return false;

    const along = @as(f64, direction.z) * dz + @as(f64, dx) * direction.x;
    if (along >= 0 and f(along) <= length) return true;

    const shifted = @as(f64, radius) + f(along);

    return shifted >= 0 and f(shifted) <= @as(f64, length) + collision_diameter;
}

fn f(value: f64) f32 {
    return @floatCast(value);
}

test "INF moving-wall endpoint test preserves the shared diameter" {
    const origin = Vec2{ .x = 0, .z = 0 };
    const direction = Vec2{ .x = 1, .z = 0 };

    try std.testing.expect(circleTouchesWall(origin, direction, 10, .{ .x = 5, .z = -1 }, 1, 0));
    try std.testing.expect(!circleTouchesWall(origin, direction, 10, .{ .x = 5, .z = 1 }, 1, 2));
    try std.testing.expect(
        !circleTouchesWall(origin, direction, 10, .{ .x = 10.5, .z = -1 }, 1, 0),
    );

    try std.testing.expect(circleTouchesWall(origin, direction, 10, .{ .x = 10.5, .z = -1 }, 1, 2));
}

test "INF morph geometry and actor filters match Hideout execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/inf-geometry-reference.json",
        a,
        .limited(8 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const Fixture = struct {
        transformations: []const struct {
            kind: []const u8,
            sector: usize,
            delta_bits: u32 = 0,
            direction_bits: [2]u32 = .{ 0, 0 },
            angle: u16 = 0,
            center_bits: [2]u32 = .{ 0, 0 },
            result: u32,
            changes: []const struct {
                sector: usize,
                runtime_flags: u32,
                vertices: []const struct { index: usize, bits: [2]u32 },
                walls: []const struct {
                    index: usize,
                    direction_bits: [2]u32,
                    angle: u16,
                    length_bits: u32,
                    runtime_flags: u32,
                },
            },
        },
        contacts: []const struct {
            sector: usize,
            wall: usize,
            position_bits: [3]u32,
            radius_bits: u32,
            flags: u32,
            secondary: u32,
            diameter_bits: u32,
            result: u32,
            messages: []const struct { kind: u32, argument: u32, target_tag: u32 },
        },
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        fixture_bytes,
        .{ .ignore_unknown_fields = true },
    );

    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(128 * 1024 * 1024),
    );

    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_module.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    const originals = try a.alloc([]const Vec2, level.sectors.len);
    const saved_walls = try a.alloc([]scene_module.WallState, level.sectors.len);
    const saved_flags = try a.alloc(u32, level.sectors.len);

    for (level.sectors, scene.sectors, originals, saved_walls, saved_flags) |sector, state, *vertices, *walls, *flags| {
        vertices.* = try a.dupe(Vec2, sector.vertices);
        walls.* = try a.dupe(scene_module.WallState, state.walls);
        flags.* = state.runtime_flags;
    }

    var world = World{
        .level = &level,
        .scene = &scene,
        .angles = &angles,
        .actors = &.{},
        .collision_diameter = 0,
    };

    for (fixture.value.transformations) |sample| {
        for (level.sectors, scene.sectors, originals, saved_walls, saved_flags) |*sector, *state, vertices, walls, flags| {
            @memcpy(sector.vertices, vertices);
            @memcpy(state.walls, walls);
            state.runtime_flags = flags;
        }

        const result = if (std.mem.eql(u8, sample.kind, "move"))
            try move(
                &world,
                sample.sector,
                @bitCast(sample.delta_bits),
                @bitCast(sample.direction_bits[0]),
                @bitCast(sample.direction_bits[1]),
            )
        else
            try spin(
                &world,
                sample.sector,
                @bitCast(sample.angle),
                .{ .x = @bitCast(sample.center_bits[0]), .z = @bitCast(sample.center_bits[1]) },
                originals,
            );

        try std.testing.expectEqual(sample.result != 0, result != null);

        for (sample.changes) |change| {
            try std.testing.expectEqual(
                saved_flags[change.sector] | change.runtime_flags,
                scene.sectors[change.sector].runtime_flags,
            );

            for (change.vertices) |expected| {
                const actual = level.sectors[change.sector].vertices[expected.index];
                try std.testing.expectEqual(
                    expected.bits,
                    .{ @as(u32, @bitCast(actual.x)), @as(u32, @bitCast(actual.z)) },
                );
            }

            for (change.walls) |expected| {
                const actual = scene.sectors[change.sector].walls[expected.index];

                try std.testing.expectEqual(
                    expected.direction_bits,
                    .{
                        @as(u32, @bitCast(actual.direction.x)),
                        @as(u32, @bitCast(actual.direction.z)),
                    },
                );

                try std.testing.expectEqual(expected.angle, @as(u16, @bitCast(actual.angle)));
                try std.testing.expectEqual(
                    expected.length_bits,
                    @as(u32, @bitCast(actual.length)),
                );

                try std.testing.expectEqual(expected.runtime_flags, actual.runtime_flags);
            }
        }
    }

    for (level.sectors, scene.sectors, originals, saved_walls) |*sector, *state, vertices, walls| {
        @memcpy(sector.vertices, vertices);
        @memcpy(state.walls, walls);
    }

    for (fixture.value.contacts) |sample| {
        var actor: Actor = undefined;

        actor.source_index = 7;
        actor.sector = sample.sector;
        actor.position = .{
            .x = @bitCast(sample.position_bits[0]),
            .y = @bitCast(sample.position_bits[1]),
            .z = @bitCast(sample.position_bits[2]),
        };

        actor.flags = sample.flags;
        actor.secondary_flags = sample.secondary;
        actor.collision_radius = @bitCast(sample.radius_bits);
        world.actors = (&actor)[0..1];
        world.collision_diameter = @bitCast(sample.diameter_bits);

        const ref = WallRef{ .sector = sample.sector, .index = sample.wall };
        const Capture = struct {
            count: usize = 0,

            fn send(raw: *anyopaque, source: usize, code: u32) !void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                try std.testing.expectEqual(@as(usize, 7), source);
                try std.testing.expectEqual(@as(u32, 0x66), code);
                self.count += 1;
            }
        };

        var capture: Capture = .{};

        world.actor_messages = .{ .context = &capture, .send = Capture.send };
        const hit = try checkActors(&world, ref);
        try std.testing.expectEqual(sample.result != 0, hit != null);

        if (hit) |contact| try std.testing.expectEqual(@as(?usize, 0), contact.actor);

        try std.testing.expectEqual(sample.messages.len, capture.count);
    }
}
