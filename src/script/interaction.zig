//! Using and nudging: the ray the player casts when it presses use, and the
//! events that come back.
//!
//! The ray uses body yaw and three quarters of body height. Its events are
//! delivered before player physics. A sector gets one message per
//! traversal, walls one each.

const std = @import("std");

const level_module = @import("../assets/level.zig");
const texture = @import("../assets/texture.zig");
const collision = @import("../player/collision.zig");
const movement = @import("../player/movement.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene_module = @import("../render/scene.zig");
const FixedList = @import("../util/fixed_list.zig").FixedList;

pub const Event = struct {
    sector: usize,
    wall: ?usize = null,
    mask: u32,
    object_id: u32 = 0,
    actor: ?usize = null,
};

/// Most events one use ray or shot can report, the same room the other
/// per-pass lists get.
/// TODO: No proven ceiling; a ray through many thin sectors could reach it.
pub const max_ray_events = 256;
pub const RayEvents = FixedList(Event, error{TooManyRayEvents});
pub const RayEventBuffer = [max_ray_events]Event;

pub const Wall = struct { sector: usize, index: usize };

/// Fills `events`, which must start empty. Walls and sectors the ray has
/// already passed are remembered through the scene's collision check number.
pub fn activate(
    events: *RayEvents,
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    angles: *const camera.Angles,
    textures: []const texture.Texture,
    player: *const movement.Player,
    actors: collision.Actors,
    object_id: u32,
) !void {
    std.debug.assert(events.items.len == 0);

    const origin = level_module.Vec2{ .x = player.position.x, .z = player.position.z };
    const basis = angles.sinCos(player.yaw);
    const end = level_module.Vec2{
        .x = f(@as(f64, basis.sin) * 5.0 + origin.x),
        .z = f(@as(f64, basis.cos) * 5.0 + origin.z),
    };

    const y = f(@as(f64, player.body_height) * 0.75 + player.position.y);

    scene.startCollisionCheck();

    const check = scene.collision_check.*;
    var sector = player.sector;

    try events.append(.{ .sector = sector, .mask = 0x10, .object_id = object_id });
    try actorActivation(events, level, scene, actors, sector, origin, end, y);

    var previous: f32 = -0x1p31;

    while (true) {
        var hit_wall: ?Wall = null;
        var hit_point: level_module.Vec2 = undefined;
        var distance: f32 = 0x1p31;

        for (level.sectors[sector].walls, scene.sectors[sector].walls, 0..) |wall, state, index| {
            if (state.last_collision_check == check) continue;

            const vertices = level.sectors[sector].vertices;
            const hit = collision.intersection(
                origin,
                end,
                vertices[wall.v1],
                vertices[wall.v2],
            ) orelse continue;

            if (origin.x == hit.x and origin.z == hit.z and 0 <= (@as(
                f64,
                end.x,
            ) - origin.x) * state.direction.z - (@as(
                f64,
                end.z,
            ) - origin.z) * state.direction.x) continue;

            const dx = @abs(f(@as(f64, hit.x) - origin.x));
            const dz = @abs(f(@as(f64, hit.z) - origin.z));
            const exact = (@as(f64, dx) - @as(f64, @min(dx, dz)) * 0.25 * 2.0) + dz;
            const stored = f(exact);

            if (exact < distance and previous < stored) {
                hit_wall = .{ .sector = sector, .index = index };
                hit_point = hit;
                distance = stored;
            }
        }

        const hit = hit_wall orelse break;
        previous = distance;
        const wall = level.sectors[hit.sector].walls[hit.index];
        markPassed(level, scene, hit, check);

        const first = level.sectors[hit.sector].vertices[wall.v1];
        const dx = f(@as(f64, first.x) - hit_point.x);
        const dz = f(@as(f64, first.z) - hit_point.z);
        const along = length(dx, dz);

        for (wallEvents(
            level,
            hit.sector,
            hit.index,
            0x10,
            object_id,
            y,
        )) |event| if (event) |entry| {
            if (try overlayAccepts(
                level,
                scene,
                textures,
                entry.sector,
                entry.wall.?,
                along,
                y,
            )) try events.append(entry);
        };

        const next: ?usize = if (wall.dadjoin >= 0 and y < level.sectors[
            @intCast(
                wall.adjoin,
            )
        ].floor.height)
            @intCast(wall.dadjoin)
        else if (wall.adjoin >= 0) @intCast(wall.adjoin) else null;

        if (next) |target| {
            if (scene.sectors[target].last_collision_check != check) {
                try events.append(.{ .sector = target, .mask = 0x20, .object_id = object_id });
                try actorActivation(events, level, scene, actors, target, origin, end, y);
                scene.sectors[target].last_collision_check = check;
            }

            if (y <= level.sectors[target].floor.height or level.sectors[target].ceiling.height <= y) break;

            sector = target;
        } else break;
    }
}

/// Marks a wall the ray passed, its mirrors and their mirrors, so the walk
/// never crosses the same wall twice.
pub fn markPassed(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    passed: Wall,
    check: u32,
) void {
    scene.sectors[passed.sector].walls[passed.index].last_collision_check = check;

    for (mirrors(level.sectors[passed.sector].walls[passed.index])) |mirror| if (mirror) |m| {
        scene.sectors[m.sector].walls[m.index].last_collision_check = check;
        for (mirrors(level.sectors[m.sector].walls[m.index])) |second| if (second) |s| {
            scene.sectors[s.sector].walls[s.index].last_collision_check = check;
        };
    };
}

pub fn wallEvents(
    level: *const level_module.Level,
    sector: usize,
    index: usize,
    mask: u32,
    object_id: u32,
    y: f32,
) [2]?Event {
    const wall = level.sectors[sector].walls[index];
    var other: ?Wall = null;

    if (wall.dadjoin >= 0 and level.sectors[
        @intCast(
            wall.adjoin,
        )
    ].floor.height > f(@as(f64, level.sectors[sector].floor.height) + y)) {
        other = .{ .sector = @intCast(wall.dadjoin), .index = @intCast(wall.dmirror) };
    } else if (wall.adjoin >= 0) other = .{
        .sector = @intCast(wall.adjoin),
        .index = @intCast(wall.mirror),
    };

    return .{
        .{ .sector = sector, .wall = index, .mask = mask, .object_id = object_id },
        if (other) |m| .{
            .sector = m.sector,
            .wall = m.index,
            .mask = mask *% 2,
            .object_id = object_id,
        } else null,
    };
}

pub fn overlayAccepts(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    textures: []const texture.Texture,
    sector: usize,
    index: usize,
    x: f32,
    y: f32,
) !bool {
    const wall = level.sectors[sector].walls[index];
    if (wall.overlay.texture < 0 or @abs(x) == 0 or @abs(y) == 0) return true;

    const tex_index: usize = @intCast(wall.overlay.texture);
    if (tex_index >= textures.len) return error.InvalidInfOverlayTexture;

    const tex = textures[tex_index];
    const h = f(@as(f64, @floatFromInt(tex.height)) * 0.125);
    var left = f(@as(f64, wall.overlay.offset.x) * 0.125);
    var top = f(@as(f64, h) - @as(f64, wall.overlay.offset.z) * 0.125);

    switch (scene.sectors[sector].walls[index].render_flags) {
        0 => {
            top = f(@as(f64, level.sectors[sector].floor.height) + top);
            left = f(@as(f64, left) - @as(f64, wall.mid.offset.x) * 0.125);
        },
        1 => {
            if (wall.adjoin < 0) return error.InvalidInfOverlayAdjoin;
            top = f(@as(f64, level.sectors[@intCast(wall.adjoin)].ceiling.height) + top);
            left = f(@as(f64, left) - @as(f64, wall.top.offset.x) * 0.125);
        },
        2, 3 => {
            top = f(@as(f64, level.sectors[sector].floor.height) + top);
            left = f(@as(f64, left) - @as(f64, wall.bottom.offset.x) * 0.125);
        },
        else => {},
    }

    return !(x < @as(
        f64,
        left,
    ) + 0.5 or @as(
        f64,
        @floatFromInt(tex.width),
    ) * 0.125 + left + 0.5 < x or @as(f64, top) + 0.5 < y or y < (@as(f64, top) - h) - 0.5);
}

pub fn actorMaskHit(
    actor: @import("../render/objects.zig").Actor,
    from: level_module.Vec2,
    normal: f32,
    height_above_bottom: f32,
) !bool {
    const costume = actor.costume orelse return true;
    if (actor.secondary_flags & 0x80000000 == 0) return true;

    const dx = f(@as(f64, from.x) - actor.position.x);
    const dz = f(@as(f64, from.z) - actor.position.z);
    const radians = f(std.math.atan2(@as(f64, dx), @as(f64, dz)));
    const angle: i32 = @intFromFloat(@as(f64, radians) * 0.15915494309644432 * 16384);
    const orientation: i16 = @intCast((angle -% actor.yaw) & 0x3fff);
    const frame = try costume.select(
        actor.choreography,
        actor.frame,
        orientation,
        actor.angle_offset,
    );

    var hit = false;

    for (frame.parts) |part| {
        if (part.cell >= costume.cells.len) return error.InvalidNwxCellIndex;

        const cell = costume.cells[part.cell];
        const offset_x = @as(f64, part.offset_x) + frame.offset_x;
        const offset_y = @as(f64, part.offset_y) + frame.offset_y;
        const pixel_x = f(
            @as(
                f64,
                @floatFromInt(cell.width),
            ) * ((normal + offset_x) / (@as(f64, @abs(actor.collision_radius)) * 2)),
        );

        const pixel_y = f(
            @as(
                f64,
                @floatFromInt(cell.height),
            ) * (((@as(
                f64,
                @abs(actor.height),
            ) - offset_y) - height_above_bottom) / @abs(actor.height)),
        );

        const x = nearestPixel(pixel_x);

        if (x < 0 or x >= cell.width) continue;

        if (cell.height > 1024 or cell.pixels.len != @as(
            usize,
            cell.width,
        ) * cell.height) return error.InvalidInfActorHitCell;

        const y = nearestPixel(pixel_y);

        if (y < 0 or x >= cell.height) continue;

        if (y >= cell.height) return error.InvalidInfActorHitPixel;

        const column: usize = @intCast(
            if (part.flags & 0x100 != 0) @as(i32, @intCast(cell.width)) - x - 1 else x,
        );

        const row: usize = @intCast(@as(i32, @intCast(cell.height)) - y - 1);
        const bytes = if (cell.flags & 1 != 0) cell.pixels else cell.encoded;
        const offset = column * cell.height + row;
        if (offset >= bytes.len) return error.InvalidInfActorHitPixel;

        if (bytes[offset] != 0) hit = true;
    }

    return hit;
}

fn actorActivation(
    events: *RayEvents,
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    actors: collision.Actors,
    sector: usize,
    from: level_module.Vec2,
    to: level_module.Vec2,
    y: f32,
) !void {
    var iterator = try actors.inSector(sector);
    const dx = f(@as(f64, to.x) - from.x);
    const dz = f(@as(f64, to.z) - from.z);
    const norm = length(dx, dz);
    if (norm == 0) return;

    const ux = f(@as(f64, dx) / norm);
    const uz = f(@as(f64, dz) / norm);
    const ray_length = f(
        (@as(f64, @abs(dx)) - @as(f64, @min(@abs(dx), @abs(dz))) * 0.5) + @abs(dz),
    );

    while (iterator.next()) |index| {
        if (index == @import("../render/actor_links.zig").player_id) continue;

        const actor = actors.get(index);

        if (actor.sector != sector or actor.secondary_flags & 0x1040 == 0 or actor.flags & 0x100 != 0) continue;

        if (actors.runtime) |runtime| if (runtime.isRemoved(actor)) continue;

        const radius = @abs(actor.collision_radius);

        if (radius == 0) continue;

        const x = f(@as(f64, actor.position.x) - from.x);
        const z = f(@as(f64, actor.position.z) - from.z);
        const normal = @as(f64, uz) * x - @as(f64, ux) * z;
        const along = f(@as(f64, ux) * x + @as(f64, uz) * z);

        if (@abs(
            normal,
        ) > radius or along > @as(f64, ray_length) + radius or along < -radius) continue;

        const top = if (actor.height < 0) try scene.ceilingHeight(
            level,
            sector,
            .{ .x = actor.position.x, .z = actor.position.z },
        ) else f(@as(f64, actor.position.y) + actor.height);

        const bottom = if (actor.height < 0) f(@as(f64, top) + actor.height) else actor.position.y;

        if (bottom <= y and y <= top and try actorMaskHit(
            actor,
            from,
            -f(normal),
            f(@as(f64, y) - bottom),
        ))
            try events.append(.{
                .sector = sector,
                .mask = 0,
                .actor = actor.source_index orelse return error.MissingScriptActor,
            });
    }
}

fn nearestPixel(value: f32) i32 {
    if (!std.math.isFinite(
        value,
    ) or value < -0x1p31 or value >= 0x1p31) return std.math.minInt(i32);

    const lower = @floor(value);
    const integer: i32 = @intFromFloat(lower);
    const fraction = value - lower;

    return integer + @as(
        i32,
        if (fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)) 1 else 0,
    );
}

fn mirrors(wall: level_module.Wall) [2]?Wall {
    return .{
        if (wall.adjoin >= 0) .{
            .sector = @intCast(wall.adjoin),
            .index = @intCast(wall.mirror),
        } else null,
        if (wall.dadjoin >= 0) .{
            .sector = @intCast(wall.dadjoin),
            .index = @intCast(wall.dmirror),
        } else null,
    };
}

fn length(x: f32, z: f32) f32 {
    const squared = f(@as(f64, x) * 0.5 * x * 0.5 + @as(f64, z) * 0.5 * z * 0.5);

    return f(@sqrt(@as(f64, squared)) * 2.0);
}

fn f(x: f64) f32 {
    return @floatCast(x);
}

test "INF actor transparency matches WAX hit testing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/actor-activation-reference.json",
        a,
        .limited(2 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const Fixture = struct {
        fixtures: []const struct {
            width: u32,
            height: u32,
            compressed: bool,
            mirrored: bool,
            offset_bits: [4]u32,
            pixels: []const u8,
            samples: []const struct {
                normal_bits: u32,
                height_bits: u32,
                result: u32,
                unsafe_pixel: bool,
            },
        },
    };

    const reference = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    const nwx = @import("../assets/nwx.zig");

    for (reference.value.fixtures) |fixture| {
        var cells = [_]nwx.Cell{
            .{
                .width = fixture.width,
                .height = fixture.height,
                .flags = @intFromBool(fixture.compressed),
                .pixels = fixture.pixels,
                .encoded = fixture.pixels,
            },
        };

        var parts = [_]nwx.Part{.{
            .cell = 0,
            .raw_x = 0,
            .raw_y = 0,
            .offset_x = @bitCast(fixture.offset_bits[2]),
            .offset_y = @bitCast(fixture.offset_bits[3]),
            .width = 0,
            .height = 0,
            .flags = if (fixture.mirrored) 0x100 else 0,
        }};

        var frames = [_]nwx.Frame{
            .{
                .offset_x = @bitCast(fixture.offset_bits[0]),
                .offset_y = @bitCast(fixture.offset_bits[1]),
                .parts = &parts,
            },
        };

        var choreographies = [_]nwx.Choreography{
            .{
                .values = .{ 0, 0, 0, 0 },
                .directions = 1,
                .frames_per_direction = 1,
                .frames = &.{0},
            },
        };

        const costume = nwx.Costume{
            .arena = undefined,
            .scale = 1,
            .secondary_scale = 1,
            .cells = &cells,
            .frames = &frames,
            .choreographies = &choreographies,
        };

        const actor = @import("../render/objects.zig").Actor{
            .costume = &costume,
            .sector = 0,
            .position = .{ .x = 0, .y = 0, .z = 0 },
            .yaw = 0,
            .flags = 0,
            .secondary_flags = 0x80000000,
            .scale_x = 1,
            .scale_y = 1,
            .height = 8,
            .collision_radius = 2,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };

        for (fixture.samples) |sample| {
            if (sample.unsafe_pixel) {
                try std.testing.expectError(
                    error.InvalidInfActorHitPixel,
                    actorMaskHit(
                        actor,
                        .{ .x = 0, .z = 0 },
                        @bitCast(sample.normal_bits),
                        @bitCast(sample.height_bits),
                    ),
                );

                continue;
            }

            const actual = actorMaskHit(
                actor,
                .{ .x = 0, .z = 0 },
                @bitCast(sample.normal_bits),
                @bitCast(sample.height_bits),
            ) catch |err| {
                std.debug.print(
                    "mask {d}x{d} mirror={} offsets={any} sample={any}\n",
                    .{
                        fixture.width,
                        fixture.height,
                        fixture.mirrored,
                        fixture.offset_bits,
                        sample,
                    },
                );

                return err;
            };

            try std.testing.expectEqual(sample.result != 0, actual);
        }
    }
}
