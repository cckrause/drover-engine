//! Projectiles in flight: launch, movement, contact and expiry.
//!
//! A projectile's record is fully zeroed before its definition is read, and
//! resource names are kept as the definition had them - the session resolves
//! them to actual models, sprites and sounds.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const Vec3 = @import("../assets/level.zig").Vec3;
const Actor = @import("../render/objects.zig").Actor;
const Angles = @import("../render/backends/software/camera.zig").Angles;
const random_module = @import("../player/weapon.zig");

pub const Kind = enum(u32) { knife = 2, explosive = 3 };

pub const Config = struct {
    name: []const u8,
    model: []const u8,
    ground_chor: i16 = 0,
    dead_item: ?[]const u8 = null,
    explosion: ?[]const u8 = null,
    fuse_sound: ?[]const u8 = null,
    explode_sound: ?[]const u8 = null,
    radius: f32 = 0,
    wall_radius: f32 = 0,
    rate: f32 = 0,
    mass: f32 = 0,
    damage: f32 = 0,
    throw_pitch: f32 = 0,
    collide_radius: f32 = 0,
    life: i32 = 0,
    allow_bounce: i32 = 0,

    pub fn load(a: std.mem.Allocator, item: *const Item, name: []const u8) !Config {
        var result: Config = .{ .name = try configName(a, name), .model = try a.dupe(u8, item.animation) };
        result.ground_chor = @truncate(item.intValue("GROUND_CHOR") orelse 0);
        result.life = item.intValue("LIFE") orelse 0;
        result.allow_bounce = item.intValue("ALLOW_BOUNCE") orelse 0;
        inline for (.{ .{ "dead_item", "DEAD_ITEM" }, .{ "explosion", "EXPLOSION" }, .{ "fuse_sound", "FUSE_SOUND" }, .{ "explode_sound", "EXPLODE_SOUND" } }) |field| {
            @field(result, field[0]) = if (try item.stringValue(field[1])) |value| try a.dupe(u8, value) else null;
        }
        inline for (.{ .{ "radius", "RADIUS" }, .{ "wall_radius", "WALL_RADIUS" }, .{ "rate", "RATE" }, .{ "mass", "MASS" }, .{ "damage", "DAMAGE" }, .{ "throw_pitch", "THROW_PITCH" }, .{ "collide_radius", "COLLIDE_RADIUS" } }) |field| {
            const value = item.floatValue(field[1]) orelse 0;
            if (!std.math.isFinite(value)) return error.InvalidProjectileFloat;
            @field(result, field[0]) = value;
        }
        return result;
    }
};

pub const Descriptor = struct {
    kind: Kind,
    item: []const u8,
    owner: ?usize,
    origin: Vec3,
    sector: usize,
    pitch: i16,
    yaw: i16,
    damage: f32,
    mass: f32,
    rate: f32,
    range: f32,
};

pub const Owner = struct {
    source: usize,
    position: Vec3,
    sector: usize,
    height: f32,
    velocity: Vec3,
    pitch: i16,
    yaw: i16,
    launch_yaw: ?i16 = null,
};

pub const State = struct {
    config: *const Config,
    descriptor: Descriptor,
    held: bool = true,
    explode: bool = false,
    deadline: u32 = 0,
    velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    floor_cache: f32 = -0x1p31,
    wall_memory: @import("../player/collision.zig").WallMemory = .{},
    rotation: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    bounced: bool = false,
    fuse_handle: ?u32 = null,
    pickup: bool = false,
};

pub const Blast = struct { damage: @import("../player/shooting.zig").DamageInput, impact: Vec3 };

pub fn configName(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, path, "\\/:")) |position| position + 1 else 0;
    const tail = path[start..];
    const end = std.mem.indexOfScalar(u8, tail, '.') orelse tail.len;
    if (end == 0 or end + 4 >= 32) return error.InvalidProjectileName;
    return std.fmt.allocPrint(a, "{s}.itm", .{tail[0..end]});
}

pub fn initialize(actor: *Actor, config: *const Config, descriptor: Descriptor, now: u32) State {
    actor.pitch = descriptor.pitch;
    actor.yaw = descriptor.yaw;
    actor.roll = 0;
    actor.height = f(@as(f64, config.collide_radius) * 2.0);
    actor.collision_radius = config.collide_radius;
    actor.flags = (actor.flags & ~@as(u32, 0x404)) | 0x80000140;
    actor.secondary_flags |= 0x420;
    actor.logic_name = if (descriptor.kind == .explosive) "shot_ExpProjectileDispatch" else "shot_ProjectileDispatch";
    actor.projectile_explodes = config.explosion != null;
    return .{ .config = config, .descriptor = descriptor, .deadline = if (descriptor.kind == .explosive) now +% @as(u32, @bitCast(config.life)) else 0 };
}

pub fn launch(actor: *Actor, state: *State, owner: Owner, fraction: f32, angles: *const Angles, random: *u32) !void {
    if (!std.math.isFinite(fraction)) return error.InvalidProjectileFloat;
    actor.flags = (actor.flags & ~@as(u32, 0x100)) | 0x80000004;
    const degrees = @as(f64, state.config.throw_pitch) * 45.5112;
    if (!std.math.isFinite(degrees) or degrees < -2147483648 or degrees >= 2147483648) return error.InvalidProjectilePitch;
    const pitch = @min(owner.pitch +% @as(i16, @truncate(@as(i32, @intFromFloat(degrees)))), 0xaaa);
    var launch_speed = f(@as(f64, state.descriptor.rate) * fraction);
    if (@as(i32, @bitCast(fraction)) > 0 and launch_speed <= 10) launch_speed = 10;
    const direction = vector(angles, owner.launch_yaw orelse owner.yaw, pitch, launch_speed);
    actor.position = .{ .x = owner.position.x, .y = f(@as(f64, owner.height) * @as(f32, 0.85) + owner.position.y), .z = owner.position.z };
    state.velocity = .{ .x = f(@as(f64, owner.velocity.x) + direction.x), .y = f(@as(f64, owner.velocity.y) + direction.y), .z = f(@as(f64, owner.velocity.z) + direction.z) };
    const roll = random_module.randomFloat(random, f(@as(f64, fraction) * 45.0)) - @as(f64, fraction) * 22.5;
    state.rotation.y = f(@as(f64, fraction) * -720.0);
    state.rotation.z = f(roll);
    state.rotation.x = f(random_module.randomFloat(random, f(@as(f64, fraction) * 180.0)) - @as(f64, fraction) * 90.0);
    state.held = false;
}

pub fn follow(actor: *Actor, owner: Owner) void {
    actor.position = .{ .x = owner.position.x, .y = f(@as(f64, owner.height) * @as(f32, 0.85) + owner.position.y), .z = owner.position.z };
    actor.sector = owner.sector;
}

pub fn vector(angles: *const Angles, yaw: i16, pitch: i16, magnitude: f32) Vec3 {
    const y = angles.sinCos(yaw);
    const p = angles.sinCos(pitch);
    return .{ .x = f(@as(f64, f(@as(f64, magnitude) * y.sin)) * p.cos), .y = f(@as(f64, magnitude) * p.sin), .z = f(@as(f64, f(@as(f64, magnitude) * y.cos)) * p.cos) };
}

pub fn alignFloor(actor: *Actor, rotation: *Vec3, world: @import("../enemy/physics.zig").World) !void {
    const physics = @import("../enemy/physics.zig");
    if (actor.position.y > try physics.height(world, actor.sector, actor.position, false, true)) return;
    if (world.scene.sectors[actor.sector].floor_slope) |slope| {
        actor.pitch = slopeAngle(world.angles, slope, actor.yaw);
        actor.roll = slopeAngle(world.angles, slope, actor.yaw -% 0x1000);
    } else {
        actor.pitch = 0;
        actor.roll = 0;
    }
    rotation.y = 0;
    rotation.z = 0;
}

pub fn rotate(actor: *Actor, rotation: Vec3, dt: f32) void {
    inline for (.{ .{ "yaw", "x" }, .{ "pitch", "y" }, .{ "roll", "z" } }) |axis| {
        const rate = @field(rotation, axis[1]);
        if (@as(u32, @bitCast(rate)) & 0x7fffffff != 0)
            @field(actor, axis[0]) +%= @as(i16, @truncate(@as(i32, @intFromFloat(@as(f64, dt) * rate * 45.5112))));
    }
}

pub fn afterMove(state: *State, previous: Vec3) void {
    if (negative(state.velocity.y) != negative(previous.y)) {
        state.rotation.x = -f(@as(f64, state.rotation.x) * 0.5);
        state.rotation.z = -f(@as(f64, state.rotation.z) * 0.5);
        state.bounced = true;
    }
    if (@abs(state.velocity.y) < 0.1) scaleHorizontal(&state.velocity, 0.75);
    if (negative(state.velocity.x) != negative(previous.x) or negative(state.velocity.z) != negative(previous.z)) scaleHorizontal(&state.velocity, 0.5);
}

pub fn speed(state: State) f64 {
    const v = state.velocity;
    return @sqrt(@as(f64, if (state.descriptor.kind == .knife)
        f(@as(f64, v.z) * v.z + @as(f64, v.x) * v.x + @as(f64, v.y) * v.y)
    else
        f(@as(f64, v.y) * v.y + @as(f64, v.z) * v.z + @as(f64, v.x) * v.x)));
}

pub fn blast(config: *const Config, origin: Vec3, target: @import("../player/collision.zig").Body) Blast {
    const dx = f(@as(f64, target.position.x) - origin.x);
    const dz = f(@as(f64, target.position.z) - origin.z);
    const dy = f(@as(f64, f(@as(f64, target.height) * 0.5 + target.position.y)) - origin.y);
    const horizontal_squared = f(@as(f64, dx) * dx + @as(f64, dz) * dz);
    const distance = f(@sqrt(@as(f64, f(@as(f64, dy) * dy + horizontal_squared))));
    const horizontal = f(@sqrt(@as(f64, horizontal_squared)));
    var factor: f32 = 1;
    if (@as(f64, config.radius) * 0.25 <= distance) {
        const quotient = (@as(f64, config.radius) - distance) / (@as(f64, config.radius) - f(@as(f64, config.radius) * 0.25));
        factor = f(quotient * quotient);
    }
    return .{ .damage = .{ .kind = 4, .damage = f(@as(f64, config.damage) * factor), .mass = config.mass, .speed = f(@as(f64, config.rate) * factor), .pitch = angle(f(@as(f64, dy) * 0.5), horizontal), .yaw = angle(dx, dz), .lateral = @abs(target.radius), .height = f(@as(f64, target.height) * 0.5) }, .impact = .{ .x = target.position.x, .y = f(@as(f64, target.height) * 0.5 + target.position.y), .z = target.position.z } };
}

fn slopeAngle(angles: *const Angles, slope: @import("../render/scene.zig").Slope, yaw: i16) i16 {
    const basis = angles.sinCos(yaw);
    const gradient = -f(@as(f64, slope.coeff_z) * basis.cos + @as(f64, slope.coeff_x) * basis.sin);
    return @truncate(@as(i32, @intFromFloat(@as(f64, f(std.math.atan(@as(f64, gradient)))) * @as(f64, @bitCast(@as(u64, 0x3fc45f306dcc48b9))) * 16384.0)));
}

fn negative(value: f32) bool {
    return @as(u32, @bitCast(value)) > 0x80000000;
}

fn scaleHorizontal(velocity: *Vec3, factor: f32) void {
    const squared = f(@as(f64, velocity.x) * 0.5 * velocity.x * 0.5 + @as(f64, velocity.z) * 0.5 * velocity.z * 0.5);
    const requested = f(@as(f64, f(@sqrt(@as(f64, squared)))) * 2.0 * factor);
    const magnitude = f(@as(f64, f(@sqrt(@as(f64, squared)))) * 2.0);
    if (magnitude == 0) return;
    const ratio = @as(f64, requested) / magnitude;
    velocity.x = f(@as(f64, velocity.x) * ratio);
    velocity.z = f(@as(f64, ratio) * velocity.z);
}

fn angle(x: f32, z: f32) i16 {
    const radians = f(std.math.atan2(@as(f64, x), @as(f64, z)));
    return @intCast(@as(u32, @bitCast(@as(i32, @intFromFloat(@as(f64, radians) * @as(f64, @bitCast(@as(u64, 0x3fc45f306dcc48b9))) * 16384.0)))) & 0x3fff);
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
