//! What a projectile looks like: its sprite or model, and the light flash
//! on impact.
//!
//! The flash is a one-frame addition to the view, not camera motion. A zero
//! rate would fault the modulo, so rates are checked before use.

const std = @import("std");
const Events = @import("../script/inf_flags.zig").Events;
const Config = @import("runtime.zig").Config;
const Actor = @import("../render/objects.zig").Actor;
const level = @import("../assets/level.zig");
const blood = @import("../enemy/blood.zig");
const bubble = @import("../enemy/bubble.zig");
const perception = @import("../enemy/perception.zig");
const enemy = @import("../enemy/session.zig");
const inventory = @import("../player/inventory.zig");
const random = @import("../player/weapon.zig");
const interaction = @import("../script/interaction.zig");

pub fn explode(
    session: anytype,
    allocator: std.mem.Allocator,
    effects: *inventory.Effects,
    config: *const Config,
    actor: Actor,
) !void {
    _ = allocator;
    const sector = session.scene.sectors[actor.sector];

    if (!sector.flags.underwater) {
        if (config.explosion) |name| {
            const source = try bound(session, name, actor.sector, actor.position);
            // Explosions light themselves.
            session.actor_slots[source].?.flags.shaded = false;
            session.actor_slots[source].?.flags.changed = true;

            session.syncActor(source);
        }
    } else {
        const width: u32 = @bitCast(
            perception.nearest(@as(f32, @floatCast(@as(f64, config.radius) * @as(f32, 0.2)))),
        );

        if (width < 2 or width > std.math.maxInt(
            i32,
        )) return error.InvalidUnderwaterExplosionRadius;

        const count = (random.randomNext(&session.contact_state.random) & 15) + 32;
        const costume = try enemy.costume(session, bubble.costume_name);

        for (0..count) |_| {
            var position = actor.position;

            position.x = @floatCast(
                (@as(
                    f64,
                    @floatFromInt(random.randomNext(&session.contact_state.random) % width),
                ) - @as(f64, @floatFromInt(width)) * 0.5) + position.x,
            );

            position.z = @floatCast(
                (@as(
                    f64,
                    @floatFromInt(random.randomNext(&session.contact_state.random) % width),
                ) - @as(f64, @floatFromInt(width)) * 0.5) + position.z,
            );

            position.y = @floatCast(
                @as(
                    f64,
                    @floatFromInt(random.randomNext(&session.contact_state.random) % (width >> 1)),
                ) + position.y,
            );

            const spawned = bubble.spawn(
                costume,
                &session.contact_state.random,
                actor.sector,
                position,
                session.animation_time,
            );

            const source = try enemy.appendActor(session, spawned, null);

            session.general_slots[source] = .{ .velocity = .{ .x = 0, .y = 0, .z = 0 } };
        }
    }

    if (config.explode_sound) |name| try effects.append(.{
        .sound = .{
            .basename = name,
            .sector = actor.sector,
            .position = actor.position,
            .priority = 64,
            .volume = 127,
            .flags = .default,
        },
    });

    const dx: f32 = actor.position.x - session.player.position.x;
    const dy: f32 = actor.position.y - session.player.position.y;
    const dz: f32 = actor.position.z - session.player.position.z;
    const squared: f32 = @floatCast(@as(f64, dx) * dx + @as(f64, dy) * dy + @as(f64, dz) * dz);

    if (@sqrt(
        @as(f64, squared),
    ) < 10 or try session.enemy_visibility.connected(
        &session.level,
        &session.scene,
        &session.angles,
        actor.sector,
        session.player.sector,
    )) {
        session.explosion_flash +%= 10;
        session.scope_explosion_flash +%= 10;
    }

    try events(session, effects, actor.sector, actor.position, config.wall_radius, .{ .explosion = true });
    try events(session, effects, actor.sector, actor.position, config.radius, .{ .blast = true });

    const upper = session.level.sectors[actor.sector].vadjoin;

    if (sector.flags.underwater and upper >= 0) {
        var position = actor.position;

        position.y = try session.scene.ceilingHeight(
            &session.level,
            actor.sector,
            perception.point(position),
        );

        _ = try bound(session, "SPLASH3.NWX", @intCast(upper), position);

        try effects.append(.{
            .sound = .{
                .basename = "splash.wav",
                .sector = @intCast(upper),
                .position = position,
                .priority = 64,
                .volume = 127,
                .flags = .default,
            },
        });
    }
}

pub fn events(
    session: anytype,
    effects: *inventory.Effects,
    origin_sector: usize,
    position: level.Vec3,
    radius: f32,
    mask: Events,
) !void {
    const cache = &session.enemy_visibility;

    if (cache.lists[origin_sector] == null and session.level.sectors.len > 1)
        _ = try cache.connected(
            &session.level,
            &session.scene,
            &session.angles,
            origin_sector,
            (origin_sector + 1) % session.level.sectors.len,
        );

    const single = [_]u16{@intCast(origin_sector)};
    const sectors = cache.lists[origin_sector] orelse &single;

    for (sectors) |source| {
        const sector = session.level.sectors[source];
        var total: f32 = 0;

        for (sector.vertices) |vertex| total = @floatCast(
            perception.distance(perception.point(position), vertex) + total,
        );

        if (@as(f64, total) / @as(f32, @floatFromInt(sector.vertices.len)) < radius) {
            var context = enemy.scriptContext(session, effects, .{});
            try context.infEvent(.{ .sector = source, .mask = mask });

            for (sector.walls, 0..) |wall, index| {
                const first: f32 = @floatCast(
                    perception.distance(perception.point(position), sector.vertices[wall.v1]),
                );

                const second = perception.distance(
                    perception.point(position),
                    sector.vertices[wall.v2],
                );

                if ((second + first) * 0.5 < radius) {
                    for (interaction.wallEvents(
                        &session.level,
                        source,
                        index,
                        mask,
                        0,
                        0,
                    )) |entry| if (entry) |event| try context.infEvent(event);
                }
            }
        }
    }
}

fn bound(session: anytype, name: []const u8, sector: usize, position: level.Vec3) !usize {
    const costume = try enemy.costume(session, name);
    const actor = try blood.spawnSplash(
        costume,
        .{ .sector = sector, .position = position },
        session.animation_time,
    );

    const source = try enemy.appendActor(session, actor, null);

    session.splash_slots[source] = .{ .selection_serial = session.enemy_selection_serial };
    session.enemy_selection_serial += 1;

    return source;
}
