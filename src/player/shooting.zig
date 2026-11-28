//! Firing: where the ray starts, where it points, and what it hits.
//!
//! The two yaw products are stored before being multiplied by the pitch
//! cosine, and the ray's Y is an absolute height rather than an offset.
//! Breakable surfaces are handled on the way through, so a shot can both
//! break glass and hit what is behind it.

const std = @import("std");
const Events = @import("../script/inf_flags.zig").Events;

const level_module = @import("../assets/level.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene_module = @import("../render/scene.zig");
const interaction = @import("../script/interaction.zig");
const collision = @import("collision.zig");
const Actor = @import("../render/objects.zig").Actor;
const Texture = @import("../assets/texture.zig").Texture;
const Vec2 = level_module.Vec2;
const Vec3 = level_module.Vec3;

pub const local_player = std.math.maxInt(usize);

pub const Ray = struct {
    sector: usize,
    origin: Vec3,
    range: f32,
    pitch: i16,
    yaw: i16,
    kind: u32 = 1,
    exclude_source: ?usize = null,

    pub fn end(self: Ray, angles: *const camera.Angles) Vec3 {
        const yaw = angles.sinCos(self.yaw);
        const pitch = angles.sinCos(self.pitch);
        const x = f(@as(f64, self.range) * yaw.sin);
        const z = f(@as(f64, self.range) * yaw.cos);

        return .{
            .x = f(@as(f64, f(@as(f64, x) * pitch.cos)) + self.origin.x),
            .y = f(@as(f64, f(@as(f64, self.range) * pitch.sin)) + self.origin.y),
            .z = f(@as(f64, f(@as(f64, z) * pitch.cos)) + self.origin.z),
        };
    }
};

pub const ActorHit = struct {
    index: usize,
    position: Vec3,
    lateral: f32,
    height: f32,
    distance: f32,
};

pub const WallHit = struct {
    sector: usize,
    index: usize,
    position: Vec3,
    along: f32,
};

pub const Hit = union(enum) { actor: ActorHit, wall: WallHit };

/// `events` points into the list handed to `trace`.
pub const Result = struct {
    hit: ?Hit,
    events: []const interaction.Event,
    ceiling: f32,
    floor: f32,
};

const Wall = struct { sector: usize, index: usize };

pub const EnemyState = struct {
    health: f32,
    velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    armor: bool = false,
    current_chor: u32 = 0,
    crouch_chor: u32,
    death_chor: u32,
    leg_death_chor: u32 = 0,
    left_death_chor: u32 = 0,
    right_death_chor: u32 = 0,
    knockout: bool = false,
};

pub const DamageInput = struct {
    kind: u32,
    damage: f32,
    mass: f32,
    speed: f32,
    pitch: i16,
    yaw: i16,
    lateral: f32,
    height: f32,
    shooter_position: ?Vec2 = null,
};

pub const PendingHit = struct {
    target: usize,
    sender: ?usize = local_player,
    queue_serial: ?u64 = null,
    count: u32 = 0,
    input: DamageInput,
    position: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    vector: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    vector_pitch: i16 = 0,
    vector_yaw: i16 = 0,
    blood: ContactVisual = .{},
    dust: ContactVisual = .{},

    pub fn init(
        target: usize,
        angles: *const camera.Angles,
        input: DamageInput,
        hit: ActorHit,
    ) PendingHit {
        return initFrom(target, local_player, angles, input, hit);
    }

    pub fn initFrom(
        target: usize,
        sender: ?usize,
        angles: *const camera.Angles,
        input: DamageInput,
        hit: ActorHit,
    ) PendingHit {
        var result = PendingHit{ .target = target, .sender = sender, .input = input };
        result.add(angles, input, hit);

        return result;
    }

    pub fn matches(self: PendingHit, target: usize, kind: u32) bool {
        return self.matchesFrom(target, kind, local_player);
    }

    pub fn matchesFrom(self: PendingHit, target: usize, kind: u32, sender: ?usize) bool {
        return self.target == target and self.sender == sender and (kind == 0 or self.input.kind == kind);
    }

    pub fn add(
        self: *PendingHit,
        angles: *const camera.Angles,
        input: DamageInput,
        hit: ActorHit,
    ) void {
        const speed = f(@as(f64, input.speed) * input.mass);

        if (self.count == 0) {
            self.input = input;
            self.input.mass = 1;
            self.input.speed = speed;
            self.input.damage = 0;
            self.input.lateral = 0;
            self.input.height = 0;
        }

        self.count +%= 1;
        self.input.damage = f(@as(f64, self.input.damage) + input.damage);
        self.input.lateral = f(@as(f64, self.input.lateral) + hit.lateral);
        self.input.height = f(@as(f64, self.input.height) + hit.height);
        self.position.y = f(@as(f64, self.position.y) + hit.position.y);
        self.position.z = f(@as(f64, self.position.z) + hit.distance);
        self.vector_pitch = input.pitch +% 0xe3;
        self.vector_yaw = input.yaw;

        const yaw = angles.sinCos(self.vector_yaw);
        const pitch = angles.sinCos(self.vector_pitch);
        const x = f(@as(f64, speed) * yaw.sin);
        const z = f(@as(f64, speed) * yaw.cos);

        self.vector.x = f(@as(f64, x) * pitch.cos + self.vector.x);
        self.vector.y = f(@as(f64, speed) * pitch.sin + self.vector.y);
        self.vector.z = f(@as(f64, z) * pitch.cos + self.vector.z);
    }

    pub fn damageInput(self: PendingHit) DamageInput {
        var result = self.input;

        result.kind = @as(u16, @truncate(result.kind));
        if (self.count <= 1) return result;

        const reciprocal = f(1.0 / @as(f64, @floatFromInt(self.count)));

        result.lateral = f(@as(f64, result.lateral) * reciprocal);
        result.height = f(@as(f64, result.height) * reciprocal);

        const horizontal = length(self.vector.x, self.vector.z);

        if (horizontal != 0) {
            result.speed = length(self.vector.y, horizontal);
            result.pitch = angle(
                f(std.math.atan(@as(f64, f(@as(f64, self.vector.y) / horizontal)))),
            );

            result.yaw = @bitCast(
                @as(
                    u16,
                    @bitCast(
                        angle(f(std.math.atan2(@as(f64, self.vector.x), @as(f64, self.vector.z)))),
                    ),
                ) & 0x3fff,
            );
        } else {
            result.speed = @abs(self.vector.y);
            result.pitch = if (self.vector.y > 0) 0x1000 else if (self.vector.y < 0) -0x1000 else self.vector_pitch;
            result.yaw = self.vector_yaw;
        }

        return result;
    }

    pub fn messagePosition(self: PendingHit) Vec3 {
        if (self.count <= 1) return self.position;

        const reciprocal = f(1.0 / @as(f64, @floatFromInt(self.count)));

        return .{
            .x = f(@as(f64, self.position.x) * reciprocal),
            .y = f(@as(f64, self.position.y) * reciprocal),
            .z = f(@as(f64, self.position.z) * reciprocal),
        };
    }
};

pub const ContactVisual = struct {
    count: i32 = 0,
    position: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    sector: usize = 0,

    pub fn add(
        self: *ContactVisual,
        angles: *const camera.Angles,
        origin: Vec3,
        raw: Vec3,
        yaw_angle: i16,
        sector: usize,
        count: i32,
        dust: bool,
    ) void {
        const yaw = angles.sinCos(yaw_angle);
        const x = f(
            @as(f64, yaw.sin) * (@as(f64, raw.z) - 0.25) + @as(f64, raw.x) * yaw.cos + origin.x,
        );

        const z = f((@as(f64, raw.z) - 0.25) * yaw.cos - @as(f64, raw.x) * yaw.sin + origin.z);
        const n: f32 = @floatFromInt(count);

        self.position.x = f(@as(f64, x) * n + self.position.x);
        self.position.y = f(@as(f64, raw.y) * n + self.position.y);
        self.position.z = f(@as(f64, z) * n + self.position.z);
        self.sector = sector;
        self.count = if (dust) self.count -% count else self.count +% count;
    }

    pub fn average(self: ContactVisual) Vec3 {
        const count = @abs(self.count);
        if (count <= 1) return self.position;

        const reciprocal = 1.0 / @as(f64, @floatFromInt(count));

        return .{
            .x = f(@as(f64, self.position.x) * reciprocal),
            .y = f(@as(f64, self.position.y) * reciprocal),
            .z = f(@as(f64, self.position.z) * reciprocal),
        };
    }
};

/// Fills `events`, which must start empty. Walls the ray has already passed
/// are remembered through the scene's collision check number.
pub fn trace(
    events: *interaction.RayEvents,
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    angles: *const camera.Angles,
    actors: collision.Actors,
    textures: []const Texture,
    ray: Ray,
) !Result {
    std.debug.assert(events.items.len == 0);
    if (ray.sector >= level.sectors.len or !(ray.range > 0) or !std.math.isFinite(ray.range) or
        !std.math.isFinite(
            ray.origin.x,
        ) or !std.math.isFinite(
        ray.origin.y,
    ) or !std.math.isFinite(ray.origin.z)) return error.InvalidShotRay;

    if (ray.kind != 0 and ray.kind != 1) return error.UnsupportedShotKind;

    const origin = Vec2{ .x = ray.origin.x, .z = ray.origin.z };
    const endpoint = ray.end(angles);
    const target = Vec2{ .x = endpoint.x, .z = endpoint.z };
    const yaw = angles.sinCos(ray.yaw);

    scene.startCollisionCheck();

    const check = scene.collision_check.*;
    var sector = ray.sector;
    var previous: f32 = -0x1p31;
    var ceiling: f32 = 0x1p31;
    var floor: f32 = -0x1p31;

    while (true) {
        floor = @max(floor, try scene.floorHeight(level, sector, origin));
        ceiling = @min(ceiling, try scene.ceilingHeight(level, sector, origin));

        const actor_hit = try nearestActor(
            level,
            scene,
            actors,
            sector,
            ray,
            endpoint,
            yaw.sin,
            yaw.cos,
        );

        var hit_wall: ?Wall = null;
        var hit_point: Vec2 = undefined;
        var distance: f32 = 0x1p31;

        for (level.sectors[sector].walls, scene.sectors[sector].walls, 0..) |wall, state, index| {
            if (state.last_collision_check == check) continue;

            const vertices = level.sectors[sector].vertices;
            const point = collision.intersection(
                origin,
                target,
                vertices[wall.v1],
                vertices[wall.v2],
            ) orelse continue;

            if (origin.x == point.x and origin.z == point.z and 0 <= (@as(
                f64,
                target.x,
            ) - origin.x) * state.direction.z - (@as(
                f64,
                target.z,
            ) - origin.z) * state.direction.x) continue;

            const exact = approximateDistance(origin, point);
            const stored = f(exact);

            if (exact < distance and previous < stored) {
                hit_wall = .{ .sector = sector, .index = index };
                hit_point = point;
                distance = stored;
            }
        }

        if (hit_wall == null) return .{
            .hit = if (actor_hit) |hit| .{ .actor = hit } else null,
            .events = events.items,
            .ceiling = ceiling,
            .floor = floor,
        };

        const hit = hit_wall.?;
        previous = distance;
        const wall = level.sectors[hit.sector].walls[hit.index];
        interaction.markPassed(level, scene, .{ .sector = hit.sector, .index = hit.index }, check);

        if (actor_hit) |actor| {
            const dx = @as(f64, hit_point.x) - origin.x;
            const dz = @as(f64, hit_point.z) - origin.z;
            const squared = f(dz * dz + dx * dx);
            if (actor.distance < @sqrt(
                @as(f64, squared),
            )) return .{
                .hit = .{ .actor = actor },
                .events = events.items,
                .ceiling = ceiling,
                .floor = floor,
            };
        }

        const full_length = length(
            f(@as(f64, target.x) - origin.x),
            f(@as(f64, target.z) - origin.z),
        );

        if (full_length == 0) return error.InvalidShotRay;

        const part_length = lengthExact(
            f(@as(f64, hit_point.x) - origin.x),
            f(@as(f64, hit_point.z) - origin.z),
        );

        const y = f(
            (@as(f64, endpoint.y) - ray.origin.y) * (part_length / full_length) + ray.origin.y,
        );

        var next: ?usize = null;

        if (wall.dadjoin >= 0) {
            const lower: usize = @intCast(wall.dadjoin);

            if (try scene.floorHeight(
                level,
                lower,
                hit_point,
            ) < y and y < try scene.ceilingHeight(level, lower, hit_point)) next = lower;
        }

        if (next == null and wall.adjoin >= 0) {
            const upper: usize = @intCast(wall.adjoin);

            if (try scene.floorHeight(
                level,
                upper,
                hit_point,
            ) < y and y < try scene.ceilingHeight(level, upper, hit_point)) next = upper;
        }

        const flags = scene.sectors[sector].walls[hit.index].flags;

        if ((!flags.mid_texture_on_adjoin or next != null) and flags.impassable and flags.triggers_on_shot) {
            for (interaction.wallEvents(
                level,
                sector,
                hit.index,
                .{ .cross_front = true, .shot_front = true },
                0,
                0,
            )) |event| if (event) |entry| try events.append(entry);
        }

        if (next) |target_sector| {
            sector = target_sector;
            continue;
        }

        const first = level.sectors[sector].vertices[wall.v1];
        const along = length(
            f(@as(f64, hit_point.x) - first.x),
            f(@as(f64, hit_point.z) - first.z),
        );

        const position = Vec3{ .x = hit_point.x, .y = y, .z = hit_point.z };

        if (ray.kind == 0 or (!flags.mid_texture_on_adjoin and try scene.floorHeight(
            level,
            sector,
            hit_point,
        ) <= y and y <= try scene.ceilingHeight(level, sector, hit_point))) {
            for (interaction.wallEvents(
                level,
                sector,
                hit.index,
                .{ .shot_front = true },
                ray.kind,
                y,
            )) |event| if (event) |entry| {
                if (try interaction.overlayAccepts(
                    level,
                    scene,
                    textures,
                    entry.sector,
                    entry.wall.?,
                    along,
                    y,
                )) try events.append(entry);
            };
        }

        return .{
            .hit = .{
                .wall = .{
                    .sector = sector,
                    .index = hit.index,
                    .position = position,
                    .along = along,
                },
            },
            .events = events.items,
            .ceiling = ceiling,
            .floor = floor,
        };
    }
}

pub fn damageEnemy(
    angles: *const camera.Angles,
    actor: Actor,
    state: *EnemyState,
    input: DamageInput,
) !?u32 {
    if (actor.height == 0 or actor.collision_radius == 0) return error.InvalidShotVictimDimensions;

    var damage = input.damage;
    var speed = input.speed;
    const boss = actor.secondary_flags.boss;

    if (input.kind == 4 and boss) {
        damage = 3;
        speed = 0;
    }

    if (state.armor) damage = f(@as(f64, damage) * 0.25);

    const magnitude = f(((@as(f64, input.mass) * speed) / 150.0) * 5.0);
    const yaw = angles.sinCos(input.yaw);
    const pitch = angles.sinCos(input.pitch);
    const horizontal = @as(f64, pitch.cos) * magnitude;

    state.velocity = .{
        .x = f(@as(f64, yaw.sin) * horizontal),
        .y = f(@as(f64, pitch.sin) * magnitude),
        .z = f(@as(f64, horizontal) * yaw.cos),
    };

    const half_height = f(@as(f64, actor.height) * 0.5);
    const normal = @max(
        -1.5,
        @min(1.5, f(@as(f64, input.lateral) / (@as(f64, @abs(actor.collision_radius)) * 0.5))),
    );

    const height = @max(-1.5, @min(1.5, f((@as(f64, input.height) - half_height) / half_height)));
    var amount = damage;

    if (@abs(normal) < 1.5 and @abs(height) < 1.5) {
        amount = f(@as(f64, damage) * 0.5);

        if (@abs(normal) < 0.75) {
            amount = damage;
            if (@abs(normal) < 0.5 and height > -0.5) amount = f(@as(f64, damage) * 2.0);
        }
    }

    if (@as(
        u8,
        @truncate(state.current_chor),
    ) == state.crouch_chor) amount = f(@as(f64, amount) * 0.5);

    if (input.shooter_position) |source| if (approximateDistance(
        .{ .x = actor.position.x, .z = actor.position.z },
        source,
    ) < 7.0) {
        amount = f(@as(f64, amount) * 4.0);
    };

    if (input.kind == 0 and boss) amount = f(@as(f64, amount) * 100.0);

    state.health = f(@as(f64, state.health) - amount);
    if (@as(i32, @bitCast(state.health)) >= 1) return null;

    if (boss and (input.kind == 0 or input.kind == 2)) state.knockout = true;

    state.velocity = .{
        .x = f(@as(f64, state.velocity.x) * 2.0),
        .y = f(@as(f64, state.velocity.y) * 2.0),
        .z = f(@as(f64, state.velocity.z) * 2.0),
    };

    const selected = if (height < 0) state.leg_death_chor else state.death_chor;
    const result = if (selected == 0) state.death_chor else selected;

    return if (result == 0) null else result;
}

fn nearestActor(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    actors: collision.Actors,
    sector: usize,
    ray: Ray,
    endpoint: Vec3,
    sin_yaw: f32,
    cos_yaw: f32,
) !?ActorHit {
    var iterator = try actors.inSector(sector);
    var nearest: ?ActorHit = null;

    while (iterator.next()) |index| {
        if (index == local_player) {
            if (playerHit(actors.player.?, sector, ray, endpoint, sin_yaw, cos_yaw)) |hit| {
                if (nearest == null or hit.distance < nearest.?.distance) nearest = hit;
            }

            continue;
        }

        const actor = actors.get(index);

        if (ray.exclude_source != null and actor.source_index == ray.exclude_source) continue;

        if (actor.sector != sector or actor.flags.not_solid) continue;

        if (actors.runtime) |runtime| if (runtime.isRemoved(actor)) continue;

        const radius = @abs(actor.collision_radius);

        if (radius == 0) continue;

        const x = f(@as(f64, actor.position.x) - ray.origin.x);
        const z = f(@as(f64, actor.position.z) - ray.origin.z);
        const normal_exact = @as(f64, cos_yaw) * x - @as(f64, sin_yaw) * z;

        if (@abs(normal_exact) > radius) continue;

        const along = f(@as(f64, sin_yaw) * x + @as(f64, cos_yaw) * z);

        if (along > @as(f64, ray.range) + radius or along < -radius) continue;

        const y = f(((@as(f64, endpoint.y) - ray.origin.y) / ray.range) * along + ray.origin.y);
        const top = if (actor.height < 0) try scene.ceilingHeight(
            level,
            sector,
            .{ .x = actor.position.x, .z = actor.position.z },
        ) else f(@as(f64, actor.position.y) + actor.height);

        const bottom = if (actor.height < 0) f(@as(f64, top) + actor.height) else actor.position.y;

        if (y < bottom or top < y) continue;

        const lateral = -f(normal_exact);

        if (!try interaction.actorMaskHit(
            actor,
            .{ .x = ray.origin.x, .z = ray.origin.z },
            lateral,
            f(@as(f64, y) - bottom),
        )) continue;

        if (nearest != null and !(along < nearest.?.distance)) continue;

        nearest = .{
            .index = index,
            .position = .{
                .x = f(@as(f64, sin_yaw) * along + ray.origin.x),
                .y = y,
                .z = f(@as(f64, cos_yaw) * along + ray.origin.z),
            },
            .lateral = lateral,
            .height = f(@as(f64, y) - actor.position.y),
            .distance = along,
        };
    }

    return nearest;
}

fn playerHit(
    body: collision.Body,
    sector: usize,
    ray: Ray,
    endpoint: Vec3,
    sin_yaw: f32,
    cos_yaw: f32,
) ?ActorHit {
    if (body.sector != sector or body.flags.not_solid) return null;

    const radius = @abs(body.radius);
    if (!(radius > 0) or body.height < 0) return null;

    const x = f(@as(f64, body.position.x) - ray.origin.x);
    const z = f(@as(f64, body.position.z) - ray.origin.z);
    const normal = @as(f64, cos_yaw) * x - @as(f64, sin_yaw) * z;
    if (@abs(normal) > radius) return null;

    const along = f(@as(f64, sin_yaw) * x + @as(f64, cos_yaw) * z);
    if (along > @as(f64, ray.range) + radius or along < -radius) return null;

    const y = f(((@as(f64, endpoint.y) - ray.origin.y) / ray.range) * along + ray.origin.y);
    const top = f(@as(f64, body.position.y) + body.height);
    if (y < body.position.y or top < y) return null;

    return .{
        .index = local_player,
        .position = .{
            .x = f(@as(f64, sin_yaw) * along + ray.origin.x),
            .y = y,
            .z = f(@as(f64, cos_yaw) * along + ray.origin.z),
        },
        .lateral = -f(normal),
        .height = f(@as(f64, y) - body.position.y),
        .distance = along,
    };
}

fn approximateDistance(first: Vec2, last: Vec2) f64 {
    const x = @abs(f(@as(f64, last.x) - first.x));
    const z = @abs(f(@as(f64, last.z) - first.z));

    return (@as(f64, x) - @as(f64, @min(x, z)) * 0.5) + z;
}

fn lengthExact(x: f32, z: f32) f64 {
    return @as(
        f64,
        f(@sqrt(@as(f64, f(@as(f64, x) * 0.5 * x * 0.5 + @as(f64, z) * 0.5 * z * 0.5)))),
    ) * 2.0;
}

fn length(x: f32, z: f32) f32 {
    return f(lengthExact(x, z));
}

fn f(value: f64) f32 {
    return @floatCast(value);
}

fn angle(radians: f32) i16 {
    const integer: i32 = @intFromFloat(@as(f64, radians) * 0.15915494309644432 * 16384.0);

    return @truncate(integer);
}
