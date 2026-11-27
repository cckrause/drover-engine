//! The weapon's pose: the forward displacement and pitch kick applied to
//! the view when firing.
//!
//! The displacement is only applied when a containing sector is found, but
//! the pitch kick applies either way. The sector probe looks at the given
//! sector and each wall's lower and upper adjoin, in order, and stops there
//! - it does not walk further through the level.

const level_module = @import("../assets/level.zig");
const camera = @import("backends/software/camera.zig");
const scene_module = @import("scene.zig");
const Player = @import("../player/movement.zig").Player;
const Vec2 = level_module.Vec2;
const Vec3 = level_module.Vec3;

pub const Pose = struct { eye: Vec3, sector: usize, pitch: i16 };

pub fn pose(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    angles: *const camera.Angles,
    player: *const Player,
    kick: f32,
) !Pose {
    if (player.sector >= level.sectors.len) return error.InvalidPlayerSector;

    var result = Pose{
        .eye = player.eyePosition(),
        .sector = player.sector,
        .pitch = player.pitch,
    };

    if (@as(u32, @bitCast(kick)) & 0x7fffffff == 0) return result;

    const yaw = angles.sinCos(player.viewYaw());
    const pitch = angles.sinCos(player.pitch);
    const dx = store(@as(f64, kick) * yaw.sin);
    const dz = store(@as(f64, kick) * yaw.cos);
    const displaced = Vec3{
        .x = store(@as(f64, dx) * pitch.cos + result.eye.x),
        .y = store(@as(f64, kick) * pitch.sin + result.eye.y),
        .z = store(@as(f64, dz) * pitch.cos + result.eye.z),
    };

    if (try locate(level, scene, player.sector, displaced)) |sector| {
        result.eye = displaced;
        result.sector = sector;
    }

    const delta: i16 = @truncate(
        @as(i32, @intFromFloat(@as(f64, kick) * @as(f32, 5.0) * @as(f64, 45.5112))),
    );

    result.pitch +%= delta;

    return result;
}

pub fn locate(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    sector: usize,
    point: Vec3,
) !?usize {
    if (try contains(level, scene, sector, point)) return sector;

    for (level.sectors[sector].walls) |wall| {
        if (wall.dadjoin >= 0) {
            const lower: usize = @intCast(wall.dadjoin);
            if (try contains(level, scene, lower, point)) return lower;
        }

        if (wall.adjoin >= 0) {
            const upper: usize = @intCast(wall.adjoin);
            if (try contains(level, scene, upper, point)) return upper;
        }
    }

    return null;
}

fn contains(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    sector: usize,
    point: Vec3,
) !bool {
    if (sector >= level.sectors.len or sector >= scene.sectors.len) return error.InvalidViewSector;

    const state = scene.sectors[sector];
    const source = level.sectors[sector];
    const ceiling = if (state.flags & 0x80000000 != 0) height(
        state.ceiling_slope orelse return error.MissingViewSlope,
        point,
    ) else source.ceiling.height;

    const floor = if (state.flags & 0x40000000 != 0) height(
        state.floor_slope orelse return error.MissingViewSlope,
        point,
    ) else source.floor.height;

    if (point.y > ceiling or point.y < floor) return false;

    return contains2d(source, .{ .x = point.x, .z = point.z });
}

fn height(slope: scene_module.Slope, point: Vec3) f32 {
    return store(
        (@as(
            f64,
            slope.constant,
        ) - @as(f64, slope.coeff_x) * point.x) - @as(f64, slope.coeff_z) * point.z,
    );
}

fn contains2d(sector: level_module.Sector, point: Vec2) !bool {
    if (sector.walls.len == 0) return error.EmptyViewSector;

    var low = sector.vertices[sector.walls[0].v1];
    var high = low;

    for (sector.walls[1..]) |wall| {
        const v = sector.vertices[wall.v1];

        low.x = @min(low.x, v.x);
        low.z = @min(low.z, v.z);
        high.x = @max(high.x, v.x);
        high.z = @max(high.z, v.z);
    }

    const width = store(@as(f64, high.x) - low.x);
    const depth = store(@as(f64, high.z) - low.z);
    if (point.x < low.x or @as(
        f64,
        point.x,
    ) > @as(
        f64,
        low.x,
    ) + width or point.z < low.z or @as(f64, point.z) > @as(f64, low.z) + depth) return false;

    const last = sector.walls[sector.walls.len - 1];
    var previous = store(@as(f64, sector.vertices[last.v2].z) - sector.vertices[last.v1].z);
    var crossings: u8 = 0;

    for (sector.walls) |wall| {
        const a = sector.vertices[wall.v1];
        const b = sector.vertices[wall.v2];
        var dz = store(@as(f64, b.z) - a.z);

        if (dz == 0) {
            if (relation(point, a, b) == 0) return true;
            dz = previous;
        } else if (point.z == a.z) {
            if (point.x == a.x) return true;

            if (point.x < a.x) {
                const negative = @as(u32, @bitCast(dz)) > 0x80000000;
                const was_negative = @as(u32, @bitCast(previous)) > 0x80000000;
                if (negative == was_negative or @abs(previous) == 0) crossings +%= 1;
            }
        } else if (point.z != b.z) {
            const side = relation(point, a, b);
            if (side == 1) crossings ^= 1 else if (side == 0) return true;
        }

        previous = dz;
    }

    return crossings & 1 != 0;
}

fn relation(p: Vec2, a: Vec2, b: Vec2) i32 {
    var dx = store(@as(f64, a.x) - b.x);
    var dz = store(@as(f64, a.z) - b.z);
    if (@abs(dx) == 0) {
        const inside = if (@as(
            i32,
            @bitCast(dz),
        ) < 1) a.z <= p.z and p.z <= b.z else b.z <= p.z and p.z <= a.z;

        if (!inside or p.x > a.x) return -1;

        return if (p.x == a.x) 0 else 1;
    }

    if (@abs(dz) != 0) {
        var x: f32 = undefined;
        var z: f32 = undefined;

        if (@as(i32, @bitCast(dx)) < 1) {
            if (b.x < p.x) return -1;

            x = store(@as(f64, p.x) - a.x);
            dx = -dx;

            if (@as(i32, @bitCast(dz)) < 1) {
                if (p.z < a.z or b.z < p.z) return -1;
                dz = -dz;
                z = store(@as(f64, p.z) - a.z);
            } else {
                if (p.z < b.z or a.z < p.z) return -1;
                z = store(@as(f64, a.z) - p.z);
            }
        } else {
            if (a.x < p.x) return -1;

            x = store(@as(f64, p.x) - b.x);

            if (@as(i32, @bitCast(dz)) < 1) {
                if (p.z < a.z or b.z < p.z) return -1;
                dz = -dz;
                z = store(@as(f64, b.z) - p.z);
            } else {
                if (p.z < b.z or a.z < p.z) return -1;
                z = store(@as(f64, p.z) - b.z);
            }
        }

        const z_product = store(@as(f64, z) * dx);
        const x_product = @as(f64, x) * dz;
        if (x_product == z_product) return 0;

        return if (z_product < store(x_product)) -1 else 1;
    }

    if (a.z != p.z) return -1;
    if (@as(i32, @bitCast(dx)) < 1) {
        if (b.x < p.x) return -1;
        return if (a.x <= p.x) 0 else 1;
    }

    if (a.x < p.x) return -1;

    return if (b.x <= p.x) 0 else 1;
}

fn store(value: f64) f32 {
    return @floatCast(value);
}

test {
    _ = @import("weapon_pose_reference_test.zig");
}
