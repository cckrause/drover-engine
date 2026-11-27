//! Where a shot lands: the mark it leaves, the actors it creates and the
//! rate at which marks replace each other.
//!
//! Only the per-frame count is reset before the late weapon update, so a
//! second shot in the same frame continues the same batch. The owner's
//! active plane decides which surface the mark goes on.

const std = @import("std");

const level_module = @import("../assets/level.zig");
const inventory = @import("../player/inventory.zig");
const shooting = @import("../player/shooting.zig");
const weapon = @import("../player/weapon.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene_module = @import("../render/scene.zig");
const blood = @import("blood.zig");
const session_module = @import("session.zig");
const Vec3 = level_module.Vec3;

pub const dust_costume = "DUST.NWX";

pub const mark_costume = "BULLETHL.NWX";

pub const State = struct {
    count: u32 = 0,
    noise_due: u32 = 0,
    marks: [32]?usize = @splat(null),
    next_mark: usize = 0,
};

pub const Impact = struct { position: Vec3, mark: bool, splash: bool };

pub fn locate(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    angles: *const camera.Angles,
    hit: shooting.WallHit,
    origin: Vec3,
    moving_plane: bool,
) !?Impact {
    const sector = scene.sectors[hit.sector];
    const source = level.sectors[hit.sector];
    const wall = sector.walls[hit.index];
    var result = Impact{ .position = hit.position, .mark = !moving_plane, .splash = false };
    const ceiling = if (sector.flags & 0x80000000 != 0) impactHeight(
        sector.ceiling_slope orelse return error.MissingSceneSlope,
        hit.position,
    ) else source.ceiling.height;

    if (hit.position.y <= ceiling) {
        const floor = if (sector.flags & 0x40000000 != 0) impactHeight(
            sector.floor_slope orelse return error.MissingSceneSlope,
            hit.position,
        ) else source.floor.height;

        if (floor <= hit.position.y) {
            const direction = angles.sinCos(wall.angle +% 0x1000);

            result.position.x = f(@as(f64, @as(f32, 0.07)) * direction.sin + hit.position.x);
            result.position.z = f(@as(f64, @as(f32, 0.07)) * direction.cos + hit.position.z);

            if (wall.runtime_flags & 0x04000000 != 0 or wall.flags & 0x40 != 0 or sector.flags & 4 != 0 or
                nonzero(
                    source.velocity.x,
                ) or nonzero(source.velocity.y) or nonzero(source.velocity.z)) result.mark = false;
        } else {
            result.position = planeIntersection(
                origin,
                hit.position,
                source.floor.height,
                sector.floor_slope,
            );

            if (sector.flags & 0x40 != 0) result.mark = false;

            if (source.vadjoin >= 0 and sector.flags & 0x80 == 0) {
                result.mark = false;
                result.splash = true;
            }
        }
    } else if (sector.flags & 1 == 0) {
        result.position = planeIntersection(
            origin,
            hit.position,
            source.ceiling.height,
            sector.ceiling_slope,
        );
    } else return null;

    return result;
}

pub fn apply(
    session: anytype,
    allocator: std.mem.Allocator,
    shot: weapon.Shot,
    hit: shooting.WallHit,
    effects: *inventory.Effects,
) !void {
    if (shot.kind != .bullet or !shot.impact_effect) return;

    var runtime = session_module.scriptContext(session, effects, 0);
    var context = session_module.context(session, allocator, null, null);

    context.actors.runtime = &runtime;

    const moving = blood.planeSpeed(
        context.world(),
        hit.sector,
        false,
    ) != 0 or blood.planeSpeed(context.world(), hit.sector, true) != 0;

    const impact = (try locate(
        &session.level,
        &session.scene,
        &session.angles,
        hit,
        shot.origin,
        moving,
    )) orelse return;

    session.impact_state.count +%= 1;

    if (@as(i32, @bitCast(session.impact_state.count)) < 6) {
        if (impact.splash) {
            try spawnBound(session, blood.splash_costume_name, hit.sector, impact.position);
            if (shot.impact_sound) try effects.append(.{
                .sound = blood.splashSound(.{ .sector = hit.sector, .position = impact.position }),
            });
        } else {
            _ = weapon.randomNext(&session.contact_state.random);
            try spawnBound(session, dust_costume, hit.sector, impact.position);

            if (shot.impact_sound and weapon.randomNext(&session.contact_state.random) & 3 < 1) {
                try effects.append(.{
                    .sound = .{
                        .basename = "ricochet.wav",
                        .priority = 32,
                        .volume = 127,
                        .flags = 4,
                        .sector = hit.sector,
                        .position = impact.position,
                    },
                });
            }
        }

        if (session.impact_state.noise_due < session.animation_time) {
            try session_module.impactNoise(session, allocator, effects);
            session.impact_state.noise_due = session.animation_time +% 300;
        }
    }

    if (impact.mark) try spawnMark(session, hit.sector, impact.position);
}

pub fn spawnBound(session: anytype, animation: []const u8, sector: usize, position: Vec3) !void {
    const costume = try session_module.costume(session, animation);
    const actor = try blood.spawnSplash(
        costume,
        .{ .sector = sector, .position = position },
        session.animation_time,
    );

    const index = try session_module.appendActor(session, actor, null);

    session.splash_slots[index] = .{ .selection_serial = session.enemy_selection_serial };
    session.enemy_selection_serial += 1;
}

fn impactHeight(slope: scene_module.Slope, position: Vec3) f32 {
    return f(
        (@as(
            f64,
            slope.constant,
        ) - @as(f64, slope.coeff_x) * position.x) - @as(f64, slope.coeff_z) * position.z,
    );
}

fn planeIntersection(origin: Vec3, hit: Vec3, height: f32, slope: ?scene_module.Slope) Vec3 {
    const factor = if (slope) |s|
        f((((@as(
            f64,
            s.constant,
        ) - @as(f64, origin.z) * s.coeff_z) - @as(f64, origin.x) * s.coeff_x) - origin.y) /
            ((((@as(
                f64,
                hit.z,
            ) - origin.z) * s.coeff_z + (@as(
                f64,
                hit.x,
            ) - origin.x) * s.coeff_x) - origin.y) + hit.y))
    else
        f((@as(f64, height) - origin.y) / (@as(f64, hit.y) - origin.y));

    return .{
        .x = f((@as(f64, hit.x) - origin.x) * factor + origin.x),
        .y = f((@as(f64, hit.y) - origin.y) * factor + origin.y),
        .z = f((@as(f64, hit.z) - origin.z) * factor + origin.z),
    };
}

fn spawnMark(session: anytype, sector: usize, position: Vec3) !void {
    const costume = try session_module.costume(session, mark_costume);
    var actor = try blood.spawnSplash(
        costume,
        .{ .sector = sector, .position = position },
        session.animation_time,
    );

    actor.position.y = f(@as(f64, position.y) - 0.0625);
    actor.flags |= 0x2000;

    const index = try session_module.appendActor(session, actor, null);

    if (session.impact_state.next_mark > 31) session.impact_state.next_mark = 0;

    const slot = session.impact_state.next_mark;

    if (session.impact_state.marks[slot]) |old| try session_module.removeActor(session, old);

    session.impact_state.marks[slot] = index;
    session.impact_state.next_mark += 1;
}

fn nonzero(value: f32) bool {
    return @as(u32, @bitCast(value)) & 0x7fffffff != 0;
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
