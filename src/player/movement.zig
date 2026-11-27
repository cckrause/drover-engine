//! The player's movement: the physics resource's parameters, the
//! integrator, and the state that comes out of a step.
//!
//! A physics resource is sixteen floats in a fixed order. The loader zeroes
//! the first fifteen slots, so the last parameter has to be present in the
//! data or it stays whatever it was. Which resource applies - ground, air,
//! water - is decided by the surface the player is standing on.

const std = @import("std");
const level_asset = @import("../assets/level.zig");
const item_asset = @import("../assets/item.zig");
const scene_module = @import("../render/scene.zig");
const camera = @import("../render/backends/software/camera.zig");
const initial = @import("../render/initial_state.zig");
const input = @import("input.zig");
const collision = @import("collision.zig");
const player_audio = @import("../audio/player.zig");
const ceiling_contact = @import("ceiling_contact.zig");
const choreography = @import("choreography.zig");
const Vec3 = level_asset.Vec3;

pub const Physics = struct {
    acceleration: Vec3,
    deceleration: Vec3,
    max_velocity: f32,
    jump_velocity: f32,
    step_height: f32,
    step_speed: f32,
    body_yaw_rate: f32,
    head_yaw_rate: f32,
    head_back_rate: f32,
    head_return_rate: f32,
    pitch_rate: f32,
    off_ground_ability: f32,

    pub fn parse(bytes: []const u8) !Physics {
        var lines = item_asset.Lines{ .bytes = bytes };
        if (!std.mem.eql(u8, try lines.next() orelse return error.MissingPhysicsHeader, "PHYS 1.0"))
            return error.UnsupportedPhysicsVersion;
        var fields: [16]f32 = @splat(0);
        var has_off_ground = false;
        while (try lines.next()) |line| {
            if (line.len > 127) return error.PhysicsLineTooLong;
            var words = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = words.next().?;
            if (std.mem.eql(u8, key, "ACCEL") or std.mem.eql(u8, key, "DECEL")) {
                const offset: usize = if (std.mem.eql(u8, key, "ACCEL")) 0 else 3;
                for ([_][]const u8{ "X:", "Y:", "Z:" }, 0..) |axis, i| {
                    if (!std.mem.eql(u8, words.next() orelse return error.MalformedPhysicsVector, axis))
                        return error.MalformedPhysicsVector;
                    fields[offset + i] = try number(words.next());
                }
            } else {
                const names = [_][]const u8{ "MAX_VEL:", "JUMP_VEL:", "STEP_HEIGHT:", "STEP_SPEED:", "BODY_YAW_RATE:", "HEAD_YAW_RATE:", "HEAD_YAW_LOOK_BACK_RATE:", "HEAD_YAW_RETURN_RATE:", "PITCH_RATE:", "OFF_GROUND_ABILITY:" };
                var found = false;
                for (names, 6..) |name, slot| if (std.mem.eql(u8, key, name)) {
                    fields[slot] = try number(words.next());
                    if (slot == 15) has_off_ground = true;
                    found = true;
                    break;
                };
                if (!found) return error.UnsupportedPhysicsDirective;
            }
        }
        if (!has_off_ground) return error.MissingOffGroundAbility;
        return .{
            .acceleration = .{ .x = fields[0], .y = fields[1], .z = fields[2] },
            .deceleration = .{ .x = fields[3], .y = fields[4], .z = fields[5] },
            .max_velocity = fields[6],
            .jump_velocity = fields[7],
            .step_height = fields[8],
            .step_speed = fields[9],
            .body_yaw_rate = fields[10],
            .head_yaw_rate = fields[11],
            .head_back_rate = fields[12],
            .head_return_rate = fields[13],
            .pitch_rate = fields[14],
            .off_ground_ability = fields[15],
        };
    }

    pub fn withItem(self: Physics, item: *const item_asset.Item) Physics {
        var result = self;
        result.acceleration.x = item.floatValue("AIR_ACCEL_X") orelse result.acceleration.x;
        result.acceleration.z = item.floatValue("AIR_ACCEL_Z") orelse result.acceleration.z;
        result.max_velocity = item.floatValue("AIR_VEL_MAX") orelse result.max_velocity;
        result.body_yaw_rate = item.floatValue("AIR_YAWRATE") orelse result.body_yaw_rate;
        return result;
    }

    pub fn withWaterItem(self: Physics, item: *const item_asset.Item) Physics {
        var result = self;
        result.acceleration.x = item.floatValue("WATER_ACCEL_X") orelse result.acceleration.x;
        result.acceleration.z = item.floatValue("WATER_ACCEL_Z") orelse result.acceleration.z;
        result.max_velocity = item.floatValue("WATER_VEL_MAX") orelse result.max_velocity;
        result.body_yaw_rate = item.floatValue("WATER_YAWRATE") orelse result.body_yaw_rate;
        return result;
    }
};

pub const Player = struct {
    position: Vec3,
    velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    sector: usize,
    yaw: i16,
    pitch: i16,
    head_yaw: i16 = 0,
    eye_height: f32,
    body_height: f32,
    standing_height: f32,
    head_height: f32,
    crouch_height: f32,
    radius: f32,
    physics: Physics,
    water_physics: ?Physics = null,
    underwater_elapsed: f32 = 0,
    drowning: f32 = 0,
    flags: u32 = 4,
    floor_cache: f32 = -2147483648.0,
    jump_peak: f32 = 0,
    energy: f32 = 100,
    energy_rates: [5]f32,
    auto_pitch: bool = true,
    auto_pitch_elapsed: f32 = 0,
    normal_yaw: i16 = 0,
    move_pitch_return: bool = false,
    scope_active: bool = false,
    gatling_active: bool = false,
    head_bob: f32 = 0,
    weapon_offset: [2]i32 = .{ 0, 0 },
    stride: f32 = 0,
    stride_side: bool = false,
    last_floor_sector: ?usize = null,
    last_floor_height: f32 = 0,
    slope_velocity: f32 = 0,
    impact: f32 = 0,
    sector_damage: u32 = 0,
    crush_required: f32 = 0,
    crush_body: f32 = 0,
    rail_step: ?struct { distance: f32, speed: f32 } = null,
    move_sector: ?usize = null,
    water_surface: ?i32 = null,
    dead: bool = false,
    choreography_input: ?choreography.Input = null,
    contact_residue: @import("../projectile/contact.zig").Residue = .{},
    wall_memory: collision.WallMemory = .{},

    pub fn init(item: *const item_asset.Item, physics: Physics, spawn: level_asset.Spawn) !Player {
        const height = item.floatValue("HEIGHT") orelse 6.0;
        const head = item.floatValue("HEAD_HEIGHT") orelse 0.5;
        var crouch: f32 = 1.5;
        if (item.floatValue("CROUCH_DIV")) |raw| {
            const divisor: f32 = if (@as(i32, @bitCast(raw)) < 1) 4.0 else raw;
            crouch = store(@as(f64, height) / divisor);
        }
        const radius = item.floatValue("RADIUS") orelse 1.5;
        if (!(height > head and crouch > 0 and radius > 0)) return error.InvalidPlayerDimensions;
        const angles = try initial.PlayerEye.actorAngles(spawn);
        return .{
            .position = spawn.position,
            .sector = spawn.sector,
            .yaw = angles[1],
            .pitch = angles[0],
            .eye_height = store(@as(f64, height) - head),
            .body_height = height,
            .standing_height = height,
            .head_height = head,
            .crouch_height = crouch,
            .radius = radius,
            .physics = physics.withItem(item),
            .energy_rates = .{ item.floatValue("E_REST") orelse 4, item.floatValue("E_MOVE") orelse -4, item.floatValue("E_JUMP") orelse -5, item.floatValue("E_TURN") orelse 0, item.floatValue("E_CROUCH") orelse 2 },
        };
    }

    pub fn eyePosition(self: *const Player) Vec3 {
        return .{ .x = self.position.x, .y = store(@as(f64, self.head_bob) + self.eye_height + self.position.y), .z = self.position.z };
    }

    pub fn viewYaw(self: *const Player) i16 {
        return self.yaw +% self.head_yaw;
    }

    pub fn toggleRail(self: *Player, scene: *const scene_module.Scene, audio: *player_audio.Context) !bool {
        if (self.sector >= scene.sectors.len) return error.InvalidPlayerSector;
        if (scene.sectors[self.sector].flags & 0x10000000 == 0) return false;
        const rail = audio.rail orelse return error.MissingRailAudio;
        self.flags ^= 8;
        if (self.flags & 8 != 0) try rail.start(self.position) else try rail.stop();
        return true;
    }

    pub fn tick(self: *Player, level: *const level_asset.Level, scene: *const scene_module.Scene, actors: collision.Actors, angles: *const camera.Angles, control: input.Control, look: *input.LookState, seconds: f32) !void {
        return self.tickWithAudio(level, scene, actors, angles, control, look, seconds, null);
    }

    pub fn tickWithAudio(self: *Player, level: *const level_asset.Level, scene: *const scene_module.Scene, actors: collision.Actors, angles: *const camera.Angles, control: input.Control, look: *input.LookState, seconds: f32, audio: ?*player_audio.Context) !void {
        if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidPlayerTick;
        if (seconds == 0) {
            self.contact_residue.invalidateProjection();
            self.contact_residue.playerHeight(0);
            self.choreography_input = null;
            return;
        }
        var next = self.*;
        next.contact_residue.invalidateProjection();
        next.contact_residue.playerHeight(0);
        next.impact = 0;
        next.drowning = 0;
        next.crush_required = 0;
        next.crush_body = 0;
        next.rail_step = null;
        next.move_sector = null;
        next.water_surface = null;
        next.choreography_input = null;
        var next_look = look.*;
        const sound_state = if (audio) |context| context.state.* else player_audio.State{};
        const effect_count = if (audio) |context| context.effects.items.len else 0;
        errdefer if (audio) |context| {
            context.state.* = sound_state;
            context.effects.shrinkRetainingCapacity(effect_count);
        };
        try next.advance(level, scene, actors, angles, control, &next_look, seconds, audio);
        self.* = next;
        look.* = next_look;
    }

    fn advance(self: *Player, level: *const level_asset.Level, scene: *const scene_module.Scene, actors: collision.Actors, angles: *const camera.Angles, control: input.Control, look: *input.LookState, dt: f32, audio: ?*player_audio.Context) !void {
        if (self.sector >= level.sectors.len) return error.InvalidPlayerSector;
        if (scene.sectors[self.sector].flags & 0x10000000 == 0) self.flags &= ~@as(u32, 8);
        const rail = self.flags & 8 != 0;
        const rail_audio = if (rail) (if (audio) |context| context.rail else null) orelse return error.MissingRailAudio else null;
        const bounds = try verticalSectors(level, scene, self.sector, self.position);
        const swimming = if (bounds.surface) |surface| (level.sectors[self.sector].vadjoin < 0 or @as(f64, self.eye_height) * 0.75 + self.position.y < surface) else false;
        const submerged = if (bounds.surface) |surface| (level.sectors[self.sector].vadjoin < 0 or @as(f64, self.eye_height) + self.position.y < surface) else false;
        const physics_sector = if (swimming) bounds.lower else bounds.upper;
        const sector = level.sectors[physics_sector];
        const state = scene.sectors[physics_sector];
        const ceiling_source = level.sectors[bounds.upper];
        const ceiling_state = scene.sectors[bounds.upper];
        var floor_sector = bounds.lower;
        const floor_source = level.sectors[floor_sector];
        const floor_state = scene.sectors[floor_sector];
        const floor_slope = try activeSlope(floor_state, false);
        const ceiling_slope = try activeSlope(ceiling_state, true);
        const paired = bounds.surface != null;
        const p = if (swimming) self.water_physics orelse return error.MissingWaterPhysics else self.physics;
        const old = self.position;
        var target = old;
        const basis = angles.sinCos(self.yaw);
        const view_basis = angles.sinCos(self.viewYaw());
        if (submerged) {
            self.flags = (self.flags & ~@as(u32, 0x20000000)) | 0x8000;
            if (!self.dead) self.underwater_elapsed = store(@as(f64, self.underwater_elapsed) + dt);
            self.drowning = self.underwater_elapsed;
            const runtime = actors.runtime orelse return error.MissingBubbleRuntime;
            const random = @import("weapon.zig");
            const count: i32 = if (random.randomNext(&runtime.contact_state.random) & 0x7f == 0) 2 else if (random.randomNext(&runtime.contact_state.random) & 0x1f == 0) 1 else 0;
            if (count != 0) try runtime.spawnBubbles(self.sector, .{
                .x = store(@as(f64, view_basis.sin) * 2 + old.x),
                .y = store(@as(f64, self.eye_height) + old.y),
                .z = store(@as(f64, view_basis.cos) * 2 + old.z),
            }, count);
        } else {
            self.flags &= ~@as(u32, 0x8000);
            if (paired) {
                if (@as(i32, @bitCast(self.underwater_elapsed)) > 0x41700000) if (audio) |context| try context.voice(.gasp);
                self.underwater_elapsed = 0;
            }
        }
        const floor_slope_angle: i16 = if ((!paired or submerged) and floor_slope != null) slopeAngle(floor_slope.?, basis.sin, basis.cos) else 0;
        const target_pitch: i16 = if ((!paired or submerged) and floor_slope != null) std.math.clamp(slopeAngle(floor_slope.?, view_basis.sin, view_basis.cos), -0x8e3, 0x8e3) else 0;
        const slope_cos = angles.sinCos(floor_slope_angle).cos;
        const slow = control.flags & 1 != 0;
        const run = control.flags & 2 != 0;
        const sprint = control.flags & 4 != 0;
        const jump = !self.gatling_active and control.flags & 8 != 0 and !sprint;
        const crouch = self.dead or (!self.gatling_active and control.flags & 0x10 != 0);
        const crouch_height: f32 = if (self.dead) 1 else self.crouch_height;
        var forward = control.forward;
        var strafe = control.strafe;
        const forward_active = forward != 0;
        if (!forward_active and !self.gatling_active) self.auto_pitch_elapsed = 0;
        const strafe_active = strafe != 0;
        const magnitude = @max(@abs(forward), @abs(strafe));
        const energy_factor = if (rail) 1 else store(@as(f64, self.energy) * @as(f32, 0.01));
        const friction: f32 = if (rail) 0 else sector.friction;
        const accel = if (self.gatling_active) Vec3{ .x = 0, .y = 0, .z = 0 } else Vec3{
            .x = store(@as(f64, @max(store(@as(f64, p.acceleration.x) * energy_factor), p.acceleration.x)) * friction),
            .y = @max(store(@as(f64, p.acceleration.y) * energy_factor), p.acceleration.y),
            .z = store(@as(f64, @max(store(@as(f64, p.acceleration.z) * energy_factor), p.acceleration.z)) * friction),
        };
        const decel = Vec3{ .x = store(@as(f64, p.deceleration.x) * friction), .y = p.deceleration.y, .z = store(@as(f64, p.deceleration.z) * friction) };
        self.contact_residue.playerPoint(decel);
        const base_speed = @as(f64, p.max_velocity) * slope_cos;
        var speed_limit = store((@as(f64, magnitude) * base_speed - base_speed) * energy_factor + base_speed);
        speed_limit = @min(speed_limit, store(base_speed * 1.5));
        if (crouch) speed_limit = store(@as(f64, speed_limit) * 0.5);
        const jump_velocity = store((@as(f64, control.jump) * p.jump_velocity - p.jump_velocity) * energy_factor + p.jump_velocity);
        var step_height = p.step_height;
        if (self.flags & 0x2000 != 0 and self.velocity.y >= 0) step_height = @max(store(@as(f64, self.jump_peak) - old.y), step_height);
        var step_speed = rate(p.step_speed, slow, run);
        if (sprint) step_speed = store(@as(f64, step_speed) * 6);

        var local_velocity = Vec3{
            .x = store(@as(f64, basis.cos) * self.velocity.x - @as(f64, basis.sin) * self.velocity.z),
            .y = self.velocity.y,
            .z = store(@as(f64, basis.cos) * self.velocity.z + @as(f64, basis.sin) * self.velocity.x),
        };
        const actual_floor = runtimeHeight(floor_slope, floor_source.floor.height, old);
        const floor_speed = planeSpeed(actors, level, floor_sector, false);
        const floor = if (@abs(floor_speed) == 0 and actual_floor < self.floor_cache) self.floor_cache else actual_floor;
        const ceiling = runtimeHeight(ceiling_slope, ceiling_source.ceiling.height, old);
        const clearance = store(@as(f64, ceiling) - floor);
        const eye_limit = @min(store(@as(f64, self.standing_height) - self.head_height), store(@as(f64, clearance) - self.head_height));
        var grounded = self.flags & 4 != 0 or old.y <= floor;
        if (grounded) self.flags = (self.flags | 4) & ~@as(u32, 0x2000);
        const floor_distance = store(@as(f64, old.y) - floor);
        if (step_height < floor_distance) {
            grounded = false;
            self.flags &= ~@as(u32, 4);
        }
        const walking_surface = grounded and @as(f64, floor) - actual_floor < step_height;
        const was_wading = self.flags & 0x4000 != 0;
        const wading = if (bounds.surface) |surface|
            (if (was_wading) old.y <= surface else old.y < surface)
        else
            false;
        if (was_wading != wading) {
            if (audio) |context| try context.voice(.splash);
            if (wading) self.flags |= 0x4000 else self.flags &= ~@as(u32, 0x4000);
        }
        const has_sector_velocity = state.velocity_present;
        const transport_active = has_sector_velocity and (state.flags & 0x40 == 0 or walking_surface);
        const local_transport: Vec3 = if (transport_active) .{
            .x = store(@as(f64, basis.cos) * sector.velocity.x - @as(f64, sector.velocity.z) * basis.sin),
            .y = sector.velocity.y,
            .z = store(@as(f64, sector.velocity.x) * basis.sin + @as(f64, basis.cos) * sector.velocity.z),
        } else .{ .x = 0, .y = 0, .z = 0 };
        const previous_speed = if (transport_active)
            length(store(@as(f64, self.velocity.x) - sector.velocity.x), store(@as(f64, self.velocity.z) - sector.velocity.z))
        else
            length(self.velocity.x, self.velocity.z);
        if (previous_speed > speed_limit) {
            if (sign(forward) == sign(local_velocity.z) and strafe == 0) forward = 0 else if (sign(strafe) == sign(local_velocity.x) and forward == 0) strafe = 0;
        }
        self.sector_damage = if (state.flags & 0x1c0000 != 0)
            (if (state.flags & 0x100000 != 0) @as(u32, 4) else if (state.flags & 0x80000 != 0) @as(u32, 2) else @as(u32, 1))
        else if (walking_surface and floor_state.flags & 0xe00000 != 0)
            (if (floor_state.flags & 0x800000 != 0) @as(u32, 4) else if (floor_state.flags & 0x400000 != 0) @as(u32, 2) else @as(u32, 1))
        else
            0;
        const rail_wall_angle: ?i16 = if (rail) for (state.walls) |wall| {
            if (wall.runtime_flags & 0x20000000 != 0) break wall.angle;
        } else return error.MissingRailGuideWall else null;
        self.updateAngles(angles, control, look, dt, target_pitch, grounded, slow, run, p, rail_wall_angle);

        var jump_energy: f32 = 0;
        var eye = self.eye_height;
        const vertical_bits: u32 = @bitCast(local_velocity.y);
        const water_jump = paired and jump and swimming and !(vertical_bits < 0xbe4cccce and (submerged or vertical_bits < 0x80000001));
        const water_dive = paired and crouch and swimming and vertical_bits <= 0xc03fffff and !grounded and @as(i32, @bitCast(floor_distance)) > 0x40000001;
        if (water_jump) {
            if (submerged or vertical_bits < 0x80000001) {
                if (vertical_bits > 0xbe4ccccc) local_velocity.y = store(@as(f64, local_velocity.y) + jump_velocity);
            } else local_velocity.y = store(@as(f64, jump_velocity) * @as(f32, 0.33333334));
            target.y = store(@as(f64, local_velocity.y) * dt + target.y);
            self.flags &= ~@as(u32, 4);
        } else if (water_dive) {
            local_velocity.y = store(@as(f64, local_velocity.y) - p.jump_velocity);
            target.y = store(@as(f64, local_velocity.y) * dt + target.y);
        } else if ((self.flags & 4 == 0 or local_velocity.y > 0 or sector.gravity > 0) and
            ((floor_distance >= 0 and local_velocity.y != 0) or step_height < floor_distance or sector.gravity > 0))
        {
            const falling_velocity = @as(f64, sector.gravity) * dt + local_velocity.y;
            local_velocity.y = store(falling_velocity);
            target.y = store(falling_velocity * dt + target.y);
            self.flags &= ~@as(u32, 4);
        } else if (old.y <= floor or local_velocity.y != 0 or jump) {
            if (grounded and local_velocity.y < 0) {
                if (self.flags & 4 == 0) if (audio) |context| {
                    try context.footstep(floor_source.floor_sound);
                    if (!paired or @abs(@as(f64, local_velocity.y)) > @as(f64, p.jump_velocity) * @as(f32, 1.8))
                        try context.landing(local_velocity.y, local_velocity.y, p.jump_velocity);
                };
                self.flags = (self.flags | 4) & ~@as(u32, 0x2000);
                local_velocity.y = @min(store(@as(f64, decel.y) * dt + local_velocity.y), 0);
                eye = @max(store(@as(f64, local_velocity.y) * dt + eye), crouch_height);
                if (eye == crouch_height) local_velocity.y = 0;
            } else if (jump and local_velocity.y == 0 and grounded) {
                const inherited_jump = @as(f64, jump_velocity) + floor_speed;
                local_velocity.y = store(inherited_jump);
                target.y = store(inherited_jump * dt + target.y);
                self.flags = (self.flags & ~@as(u32, 4)) | 0x2000;
                if (sector.gravity >= 0) return error.UnsupportedPlayerJumpGravity;
                self.jump_peak = store((@as(f64, jump_velocity) * jump_velocity * 0.5) / -@as(f64, sector.gravity) + old.y);
                if (!submerged) if (audio) |context| try context.voice(.jump);
                jump_energy = control.jump;
            }
        } else {
            target.y = floor;
            self.flags = (self.flags | 4) & ~@as(u32, 0x2000);
            if (!rail) eye = store(@as(f64, floor_distance) + eye);
        }
        if (local_velocity.y == 0) {
            const desired_eye = if (crouch) crouch_height else store(@as(f64, eye_limit) - @as(f32, 0.01));
            if (eye < desired_eye) eye = @min(store(@as(f64, dt) * step_speed + eye), desired_eye) else if (eye > desired_eye) eye = @max(store(@as(f64, eye) - @as(f64, dt) * step_speed), desired_eye);
        }
        self.body_height = store(@as(f64, self.head_height) + eye);
        var acceleration_x: f32 = if (strafe_active) store(@as(f64, strafe) * accel.x) else 0;
        var acceleration_z: f32 = if (forward_active) store(@as(f64, forward) * accel.z) else 0;
        if (grounded and !submerged and !rail) {
            if (!forward_active) self.auto_pitch_elapsed = 0 else if (control.flags & 0x20 == 0 and !self.scope_active and self.move_pitch_return) {
                self.auto_pitch_elapsed = store(@as(f64, self.auto_pitch_elapsed) + dt);
                if (@as(i32, @bitCast(self.auto_pitch_elapsed)) > 0x3f000000) {
                    self.auto_pitch_elapsed = 0;
                    self.auto_pitch = true;
                }
            }
        }
        if (grounded and !submerged and rail) {
            if (state.flags & 0x08000000 != 0) {
                const slope = floor_slope orelse return error.MissingRailSlope;
                const angle = slopeAngle(slope, basis.sin, basis.cos);
                const cosine = angles.sinCos(angle).cos;
                if (angle > 0) {
                    if (@as(f64, local_velocity.z) < @as(f64, cosine) * 4) local_velocity.z = store(@as(f64, cosine) * 20);
                    try rail_audio.?.pull(target);
                } else try rail_audio.?.stopPull();
            } else try rail_audio.?.stopPull();
        }
        if (!grounded or submerged) {
            acceleration_x = store(@as(f64, acceleration_x) * p.off_ground_ability);
            if (swimming and forward_active) {
                const forward_accel = acceleration_z;
                acceleration_z = store(@as(f64, angles.sinCos(self.pitch).cos) * forward_accel);
                local_velocity.y = store(@as(f64, angles.sinCos(self.pitch +% 0x1c7).sin) * forward_accel * dt + local_velocity.y);
                if (grounded) {
                    target.y = store(@as(f64, local_velocity.y) * dt + target.y);
                    self.flags &= ~@as(u32, 4);
                }
            } else acceleration_z = store(@as(f64, acceleration_z) * p.off_ground_ability);
        }
        const strafe_change = if (strafe_active) store(@as(f64, acceleration_x) * dt) else @as(f32, 0);
        self.contact_residue.playerHeight(strafe_change);
        local_velocity.x = store(@as(f64, local_velocity.x) + strafe_change);
        local_velocity.z = store(@as(f64, local_velocity.z) + store(@as(f64, acceleration_z) * dt));
        inline for (.{ "x", "y", "z" }) |axis| @field(local_velocity, axis) = store(@as(f64, @field(local_velocity, axis)) - @field(local_transport, axis));
        if (swimming) dampWater(&local_velocity, dt) else if (grounded or (has_sector_velocity and state.flags & 0x40 == 0)) damp(&local_velocity, decel, dt);
        var speed = length(local_velocity.x, local_velocity.z);
        if (!rail and speed_limit < speed and previous_speed < speed) {
            const limit = @max(previous_speed, speed_limit);
            const inverse = @as(f64, limit) / speed;
            local_velocity.x = store(@as(f64, local_velocity.x) * inverse);
            local_velocity.z = store(@as(f64, inverse) * local_velocity.z);
            speed = limit;
        }
        inline for (.{ "x", "y", "z" }) |axis| @field(local_velocity, axis) = store(@as(f64, @field(local_velocity, axis)) + @field(local_transport, axis));
        self.slope_velocity = if (grounded and floor_slope_angle != 0) store(@as(f64, angles.tan(floor_slope_angle)) * speed) else 0;
        var velocity = Vec3{
            .x = store(@as(f64, local_velocity.z) * basis.sin + @as(f64, local_velocity.x) * basis.cos),
            .y = local_velocity.y,
            .z = store(@as(f64, local_velocity.z) * basis.cos - @as(f64, local_velocity.x) * basis.sin),
        };
        var vertical_impact: f32 = 0;
        if (eye < crouch_height) {
            eye = crouch_height;
            self.body_height = store(@as(f64, self.head_height) + eye);
        }
        if (ceiling_state.flags & 1 == 0 and ceiling < @as(f64, self.head_height) + eye + target.y) {
            if (self.body_height < clearance and !submerged) if (audio) |context| try context.headHit(local_velocity.y, p.jump_velocity);
            vertical_impact = ceiling_contact.bounce(&velocity, ceiling_state.ceiling_slope, if (rail) 0.2 else ceiling_source.elasticity, planeSpeed(actors, level, bounds.upper, true));
            target.y = store((@as(f64, ceiling) - eye) - self.head_height);
        }
        if (target.y < floor or @as(f64, eye) + target.y < floor) {
            const compression: f32 = if (rail) 0 else store(@as(f64, floor) - target.y);
            if (self.flags & 4 == 0) {
                vertical_impact = store(@as(f64, @abs(velocity.y)) + vertical_impact);
                self.flags = (self.flags | 4) & ~@as(u32, 0x2000);
                if (audio) |context| {
                    if (!paired or @abs(@as(f64, velocity.y)) > @as(f64, p.jump_velocity) * @as(f32, 1.8))
                        try context.landing(velocity.y, local_velocity.y, p.jump_velocity);
                }
            }
            if (velocity.y > 0) velocity.y = 0;
            target.y = floor;
            if (@as(f64, self.body_height) + floor <= ceiling) {
                eye = @max(store(@as(f64, eye) - compression), crouch_height);
            } else {
                eye = @min(store(@as(f64, eye) - compression), store(@as(f64, clearance) * 0.5));
                self.body_height = @min(store(@as(f64, eye) + self.head_height), clearance);
            }
        }
        const crush_minimum = store(@as(f64, self.head_height) + crouch_height);
        if (ceiling_state.flags & 1 == 0 and @max(self.body_height, clearance) < crush_minimum) {
            self.crush_required = crush_minimum;
            self.crush_body = self.body_height;
        }
        if (grounded and floor_slope != null and floor_state.flags & 0x20 == 0)
            slopeSlide(&velocity, floor_slope.?, floor_source.floor.slope.?.angle, if (rail) 0 else floor_source.friction, floor_source.gravity, speed_limit, dt);
        target.x = store(@as(f64, dt) * velocity.x + old.x);
        target.z = store(@as(f64, dt) * velocity.z + old.z);
        var query_step = step_height;
        if (bounds.surface) |surface| if (jump and old.y < surface and surface < @as(f64, eye) + old.y) {
            query_step = store(@as(f64, step_height) * 2);
        };
        if (rail) query_step = store(@as(f64, step_height) * 2);
        const body = store(@as(f64, self.head_height) + eye);
        if (crouch and body <= query_step) query_step = body;
        self.floor_cache = floor;
        const resolved = try collision.resolveWithOptions(level, scene, actors, self.sector, old, &target, &velocity, body, if (rail) 2.9 else self.radius, query_step, &self.floor_cache, .{ .rail_mode = rail, .projection = &self.contact_residue.projection, .wall_memory = &self.wall_memory });
        self.sector = resolved.actor_sector;
        target.x = resolved.position.x;
        target.z = resolved.position.z;
        self.move_sector = resolved.sector;
        if (resolved.sector) |entered| if (level.sectors[entered].vadjoin >= 0) {
            self.water_surface = if (scene.sectors[entered].flags & 0x80 == 0) level.sectors[entered].floor.texture else level.sectors[entered].ceiling.texture;
        };
        const vertical = if (resolved.sector) |entered|
            (if (level.sectors[entered].vadjoin >= 0) try verticalSectors(level, scene, entered, target) else null)
        else if (paired) bounds else null;
        if (vertical) |pair| {
            floor_sector = pair.lower;
            const surface = pair.surface.?;
            if (@as(f64, eye) + target.y == surface) target.y = store(@as(f64, target.y) - @as(f32, 0.001));
            const destination: usize = if (@as(f64, eye) + target.y < surface) pair.lower else pair.upper;
            if (destination != self.sector) {
                if (actors.runtime) |runtime| try runtime.changeSector(self.sector, destination);
                self.sector = destination;
                if (destination == pair.lower) self.underwater_elapsed = 0;
            }
        }
        if (rail and grounded) if (resolved.sector) |entered| {
            target.y = runtimeHeight(try activeSlope(scene.sectors[entered], false), level.sectors[entered].floor.height, target);
        };
        self.position = target;
        self.velocity = velocity;
        self.eye_height = eye;
        if (rail) self.rail_step = .{ .distance = store(@as(f64, dt) * (@as(f64, speed) / slope_cos)), .speed = store(@as(f64, speed) / slope_cos) };
        try self.updateBob(level.sectors[floor_sector], floor_sector, angles, speed, walking_surface, dt, audio);
        self.choreography_input = .{ .dead = self.dead, .crouch = crouch, .low_ceiling = clearance < self.standing_height, .speed = speed, .run = run };
        if (self.dead) {
            self.impact = vertical_impact;
            return;
        }
        const effort = if (control.forward == 0 or control.strafe == 0)
            @abs(@as(f64, control.forward)) + @abs(@as(f64, control.strafe))
        else
            @sqrt(@as(f64, length(control.forward, control.strafe)));
        const effort_float = store(effort);
        var used = store(@as(f64, self.energy_rates[2]) * jump_energy + @as(f64, self.energy_rates[1]) * effort_float * dt + @as(f64, self.energy_rates[3]) * @abs(control.turn) * dt);
        if (sprint) used = store(@as(f64, self.energy_rates[4]) * used);
        const change = store(@as(f64, self.energy_rates[0]) * dt + used);
        self.energy = std.math.clamp(store(@as(f64, change) + self.energy), 0, 100);
        if (audio) |context| try context.tired(self.energy, dt);
        self.impact = vertical_impact;
    }

    fn updateAngles(self: *Player, angles: *const camera.Angles, control: input.Control, look: *input.LookState, dt: f32, target_pitch: i16, grounded: bool, slow: bool, run: bool, p: Physics, rail_wall_angle: ?i16) void {
        _ = angles;
        const yaw_rate = if (self.scope_active and !(control.flags & 0x40000 != 0 and look.pitch_active)) store(@as(f64, p.body_yaw_rate) * @as(f32, 0.1)) else p.body_yaw_rate;
        var yaw_delta = @as(f64, control.turn) * yaw_rate;
        if (control.flags & 0x40000 == 0) yaw_delta *= dt;
        if (rail_wall_angle) |wall_angle| {
            var target = wall_angle;
            if (@abs(@as(i32, angleDifference(self.yaw, target))) >= 0x1000) target = @bitCast((@as(u16, @bitCast(target)) +% 0x2000) & 0x3fff);
            const delta: u16 = @as(u16, @bitCast(angleDifference(self.yaw, target))) & 0x3fff;
            const step = shortTrunc(@as(f64, dt) * 220 * 45.5112);
            if (delta > 0 and delta < 0x2000) {
                const next = self.yaw +% step;
                self.yaw = if (@as(u16, @bitCast(angleDifference(next, target))) & 0x3fff <= 0x2000) next else target;
            } else if (delta > 0x2000) {
                const next = self.yaw -% step;
                const remaining = @as(u16, @bitCast(angleDifference(next, target))) & 0x3fff;
                self.yaw = if (remaining == 0 or remaining >= 0x2000) next else target;
            }
        } else {
            self.yaw +%= shortTrunc(yaw_delta * 45.5112);
            self.normal_yaw = self.yaw;
        }
        const direction: f64 = @as(f64, @floatFromInt(@intFromBool(control.flags & 0x40 != 0))) - @as(f64, @floatFromInt(@intFromBool(control.flags & 0x80 != 0))) + @as(f64, @floatFromInt(@intFromBool(control.flags & 0x100 != 0)));
        if (rail_wall_angle != null) {
            const step = shortTrunc(@as(f64, yaw_rate) * 2 * control.turn * dt * 45.5112);
            self.head_yaw = @bitCast(@as(u16, @bitCast(self.head_yaw +% step)) & 0x3fff);
        } else if (control.flags & 0x40 != 0) {
            if (self.head_yaw < 0x1000) self.head_yaw = @intCast(@min(@as(i32, self.head_yaw) + shortTrunc(@as(f64, rate(p.head_yaw_rate, slow, run)) * direction * dt * 45.5112), 0x1000));
        } else if (control.flags & 0x80 != 0) {
            if (self.head_yaw > -0x1000) self.head_yaw = @intCast(@max(@as(i32, self.head_yaw) + shortTrunc(@as(f64, rate(p.head_yaw_rate, slow, run)) * direction * dt * 45.5112), -0x1000));
        } else if (control.flags & 0x100 != 0) {
            if (self.head_yaw < 0x2000) self.head_yaw = @intCast(@min(@as(i32, self.head_yaw) + shortTrunc(@as(f64, rate(p.head_back_rate, slow, run)) * direction * dt * 45.5112), 0x2000));
        } else {
            const delta: i32 = shortTrunc(@as(f64, dt) * rate(p.head_return_rate, slow, run) * 45.5112);
            if (self.head_yaw > 0) self.head_yaw = @intCast(@max(@as(i32, self.head_yaw) - delta, 0)) else if (self.head_yaw < 0) self.head_yaw = @intCast(@min(@as(i32, self.head_yaw) + delta, 0));
        }
        const look_delta = store(@as(f64, control.look_up) - control.look_down);
        const encoded_pitch = nearest(store(@as(f64, self.pitch) * 0.02197261333473958 * @as(f32, 14.403517)));
        if (look_delta != 0 or (look.pitch_active and look.pitch_accumulator != encoded_pitch)) self.auto_pitch = false;
        if (control.flags & 0x20 != 0) self.auto_pitch = true;
        const pitch_rate = rate(p.pitch_rate, slow, run);
        const manual_pitch_rate = if (self.scope_active and rail_wall_angle == null) store(@as(f64, pitch_rate) * @as(f32, 0.1)) else pitch_rate;
        if ((grounded and self.auto_pitch) or control.flags & 0x20 != 0) {
            const delta: i32 = shortTrunc((if (rail_wall_angle != null) 140 else @as(f64, pitch_rate) * 0.5) * dt * 45.5112);
            if (target_pitch < self.pitch) self.pitch = @intCast(@max(@as(i32, self.pitch) - delta, target_pitch)) else if (self.pitch < target_pitch) self.pitch = @intCast(@min(@as(i32, self.pitch) + delta, target_pitch));
        } else if (look.pitch_active) {
            self.pitch = std.math.clamp(shortTrunc(@as(f64, manual_pitch_rate) * look_delta * dt * 45.5112) +% shortTrunc(@as(f64, @floatFromInt(look.pitch_accumulator)) * @as(f32, 0.06942749) * 45.5112), -0x8e3, 0x8e3);
        } else if (look_delta != 0) {
            self.pitch = std.math.clamp(self.pitch +% shortTrunc(@as(f64, manual_pitch_rate) * look_delta * dt * 45.5112), -0x8e3, 0x8e3);
        }
        if (!((grounded and self.auto_pitch) or control.flags & 0x20 != 0) and look_delta == 0 and !look.pitch_active and rail_wall_angle != null and !self.scope_active and self.flags & 0x8000 == 0 and self.move_pitch_return) {
            self.auto_pitch_elapsed = store(@as(f64, self.auto_pitch_elapsed) + dt);
            if (@as(i32, @bitCast(self.auto_pitch_elapsed)) > 0x3f000000) {
                self.auto_pitch_elapsed = 0;
                self.auto_pitch = true;
            }
        }
        look.pitch_accumulator = nearest(store(@as(f64, self.pitch) * 0.02197261333473958 * @as(f32, 14.403517)));
    }

    fn updateBob(self: *Player, sector: level_asset.Sector, sector_index: usize, angles: *const camera.Angles, speed: f32, walking_surface: bool, dt: f32, audio: ?*player_audio.Context) !void {
        if (self.last_floor_sector != sector_index and sector.floor.height != self.last_floor_height and 15.0 * 0.25 < self.stride) self.stride = 15;
        const distance = store(@as(f64, dt) * speed);
        self.last_floor_sector = sector_index;
        self.last_floor_height = sector.floor.height;
        if (distance == 0) {
            self.stride = 7.5;
            self.stride_side = true;
        } else if (walking_surface) self.stride = store(@as(f64, self.stride) + distance);
        if (self.stride > 15) {
            self.stride = store(@as(f64, self.stride) - 15);
            self.stride_side = !self.stride_side;
            if (audio) |context| try context.footstep(sector.floor_sound);
        }
        if (sector.vadjoin >= 0) {
            self.head_bob = 0;
            return;
        }
        const amount = @min(store(@as(f64, speed) * @as(f32, 0.05)), 1);
        const angle = shortTrunc(@as(f64, self.stride) / 15 * 180 * 45.5112);
        const sine = angles.sinCos(angle).sin;
        const scale = store(@as(f64, amount) * @as(f32, 0.35));
        self.head_bob = store(-((1.0 - @as(f64, sine) * sine) * scale));
        const cosine = angles.sinCos(angle).cos;
        const horizontal = nearest(store(@as(f64, cosine) * amount * 10.0));
        const vertical = nearest(store(@as(f64, @abs(store(@as(f64, cosine) * amount))) * 5.0));
        self.weapon_offset = .{ if (self.stride_side) horizontal else -%horizontal, vertical };
    }
};

const VerticalSectors = struct { lower: usize, upper: usize, surface: ?f32 = null };

pub fn damp(velocity: *Vec3, deceleration: Vec3, dt: f32) void {
    inline for (.{ "x", "y", "z" }) |axis| {
        var value: f64 = @field(velocity, axis);
        const change = @as(f64, @field(deceleration, axis)) * dt;
        if (value <= 0) value = @min(value + change, 0) else value = @max(value - change, 0);
        @field(velocity, axis) = store(value);
        if (@abs(@field(velocity, axis)) < @as(f32, 0.0001)) @field(velocity, axis) = 0;
    }
}

fn verticalSectors(level: *const level_asset.Level, scene: *const scene_module.Scene, index: usize, position: Vec3) !VerticalSectors {
    const sector = level.sectors[index];
    const state = scene.sectors[index];
    if (sector.vadjoin < 0) {
        return .{ .lower = index, .upper = index, .surface = if (state.flags & 0x80 != 0) runtimeHeight(try activeSlope(state, true), sector.ceiling.height, position) else null };
    }
    const partner: usize = @intCast(sector.vadjoin);
    if (partner >= level.sectors.len) return error.InvalidPlayerSector;
    const underwater = state.flags & 0x80 != 0;
    const surface = runtimeHeight(try activeSlope(state, underwater), if (underwater) sector.ceiling.height else sector.floor.height, position);
    return .{ .lower = if (underwater) index else partner, .upper = if (underwater) partner else index, .surface = surface };
}

fn activeSlope(state: scene_module.SectorState, ceiling: bool) !?scene_module.Slope {
    if (state.flags & (if (ceiling) @as(u32, 0x80000000) else 0x40000000) == 0) return null;
    return (if (ceiling) state.ceiling_slope else state.floor_slope) orelse error.MissingPlayerSlope;
}

fn planeSpeed(actors: collision.Actors, level: *const level_asset.Level, sector: usize, ceiling: bool) f32 {
    const runtime = actors.runtime orelse return 0;
    const inf = runtime.inf orelse return 0;
    return inf.planeSpeed(level, sector, ceiling);
}

fn runtimeHeight(slope: ?scene_module.Slope, flat: f32, position: Vec3) f32 {
    if (slope) |s| return store((@as(f64, s.constant) - @as(f64, s.coeff_x) * position.x) - @as(f64, s.coeff_z) * position.z);
    return flat;
}

fn slopeAngle(slope: scene_module.Slope, x: f32, z: f32) i16 {
    const gradient = store(-(@as(f64, slope.coeff_z) * z + @as(f64, slope.coeff_x) * x));
    const radians = store(std.math.atan(@abs(@as(f64, gradient))));
    const result = shortTrunc(@as(f64, radians) * 0.15915494309644432 * 16384.0);
    return if (gradient > 0) result else -%result;
}

fn dampWater(velocity: *Vec3, dt: f32) void {
    const factor = @exp(@as(f64, dt) * -4);
    inline for (.{ "x", "y", "z" }) |axis| {
        @field(velocity, axis) = store(@as(f64, @field(velocity, axis)) * factor);
        if (@abs(@field(velocity, axis)) < @as(f32, 0.0001)) @field(velocity, axis) = 0;
    }
}

fn slopeSlide(velocity: *Vec3, slope: scene_module.Slope, angle: i16, friction: f32, gravity: f32, limit: f32, dt: f32) void {
    const degrees = shortTrunc(@as(f64, @floatFromInt(@abs(@as(i32, angle)))) * @as(f32, 0.021972613));
    const fraction = store(@as(f64, @floatFromInt(degrees)) * @as(f32, 0.011111111));
    if ((1 - @as(f64, fraction)) * limit * friction <= length(velocity.x, velocity.z)) {
        velocity.x = store(-@as(f64, gravity) * slope.coeff_x * (1 - @as(f64, friction)) * dt + velocity.x);
        velocity.z = store(@as(f64, slope.coeff_z) * -@as(f64, gravity) * (1 - @as(f64, friction)) * dt + velocity.z);
    }
}

fn rate(value: f32, slow: bool, run: bool) f32 {
    var result = if (run) store(@as(f64, value) * 1.5) else value;
    if (slow) result = store(@as(f64, result) * 0.25);
    return result;
}

fn angleDifference(first: i16, second: i16) i16 {
    const difference: i32 = @as(i32, @as(u16, @bitCast(second)) & 0x3fff) - @as(i32, @as(u16, @bitCast(first)) & 0x3fff);
    return @intCast(if (@abs(difference) <= 0x2000) difference else if (difference < 0) difference + 0x4000 else difference - 0x4000);
}

fn sign(value: f32) i32 {
    const raw: u32 = @bitCast(value);
    return if (raw > 0x80000000) -1 else if (@as(i32, @bitCast(raw)) > 0) 1 else 0;
}

fn length(x: f32, z: f32) f32 {
    const squared = store(@as(f64, x) * 0.5 * x * 0.5 + @as(f64, z) * 0.5 * z * 0.5);
    return store(@sqrt(@as(f64, squared)) * 2.0);
}

fn number(raw: ?[]const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, raw orelse return error.MissingPhysicsValue);
    if (!std.math.isFinite(value)) return error.NonfinitePhysicsValue;
    return value;
}

fn store(value: f64) f32 {
    return @floatCast(value);
}

fn shortTrunc(value: f64) i16 {
    return @truncate(@as(i32, @intFromFloat(value)));
}

fn nearest(value: f32) i32 {
    const floor = @floor(value);
    const whole: i32 = @intFromFloat(floor);
    const fraction = value - floor;
    return whole + @as(i32, @intFromBool(fraction > 0.5 or (fraction == 0.5 and whole & 1 != 0)));
}

fn checkWaterReference(fixture_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture_path, a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Snapshot = struct {
        sector: usize,
        position: [3]u32,
        velocity: [3]u32,
        angles: [3]i16,
        eye_height: u32,
        body_height: u32,
        floor_cache: u32,
        energy: u32,
        head_bob: u32,
        weapon_offset: [2]i32,
        stride: u32,
        flags: u32,
        pitch_accumulator: i32,
    };
    const Bubble = struct { sector: usize, position: [3]u32, count: i32, random: u32 };
    const Fixture = struct { cases: []const struct {
        name: []const u8,
        config: struct { sector: usize, position: [3]f32, floor_cache: f32 = -2147483648, player_flags: u32, velocity: [3]f32 = .{ 0, 0, 0 }, underwater_elapsed: f32 = 0, seed: u32 = 0x742389ac, unpaired: bool = false, yaw: i16 = 0, head_yaw: i16 = 0 },
        bubble: ?Bubble = null,
        slots: []const [3]i16,
        frames: []const struct {
            state: Snapshot,
            sounds: []const struct { name: []const u8, priority: i32, volume: i32, flags: u32 },
            underwater_elapsed: ?u32 = null,
            random: ?u32 = null,
        },
    } };
    const reference = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    var archives: [3]@import("../assets/lab.zig").Archive = undefined;
    for ([_][]const u8{ "OUTLAWS.LAB", "OLOBJ.LAB", "OLGEO.LAB" }, 0..) |name, index| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}", .{name});
        const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024));
        archives[index] = try @import("../assets/lab.zig").Archive.init(raw);
    }
    var item = try item_asset.Item.parse(a, try archives[1].find("CIDJAMES.ITM", 0x4954454d));
    defer item.deinit();
    const physics = try Physics.parse(try archives[0].find("AIR.PHY", 0x50485953));
    const water_physics = (try Physics.parse(try archives[0].find("WATER.PHY", 0x50485953))).withWaterItem(&item);
    var level = try level_asset.Level.parse(a, try archives[2].find("HIDEOUT.LVB", 0));
    defer level.deinit();
    var startup = try initial.InfStartup.apply(a, &level, try archives[2].find("HIDEOUT.INF", 0));
    defer startup.deinit();
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    startup.applyScene(&level, &scene);
    const config = try player_audio.Config.fromItem(&item);
    var effects_buffer: @import("inventory.zig").EffectBuffer = undefined;
    var effects = @import("inventory.zig").Effects.init(&effects_buffer);
    const runtime_module = @import("../script/runtime.zig");
    const Capture = struct {
        value: ?Bubble = null,

        fn spawn(raw: *anyopaque, runtime: *runtime_module.Context, sector: usize, position: Vec3, count: i32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.value = .{ .sector = sector, .position = .{ @bitCast(position.x), @bitCast(position.y), @bitCast(position.z) }, .count = count, .random = runtime.contact_state.random };
            return error.CapturedOriginalBubbleBoundary;
        }
    };
    for (reference.value.cases) |case| {
        const original_vadjoin = level.sectors[case.config.sector].vadjoin;
        defer level.sectors[case.config.sector].vadjoin = original_vadjoin;
        if (case.config.unpaired) level.sectors[case.config.sector].vadjoin = -1;
        var player = try Player.init(&item, physics, .{ .sector = case.config.sector, .position = .{ .x = case.config.position[0], .y = case.config.position[1], .z = case.config.position[2] }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        player.floor_cache = case.config.floor_cache;
        player.flags = case.config.player_flags;
        player.velocity = .{ .x = case.config.velocity[0], .y = case.config.velocity[1], .z = case.config.velocity[2] };
        player.underwater_elapsed = case.config.underwater_elapsed;
        player.water_physics = water_physics;
        player.yaw = case.config.yaw;
        player.head_yaw = case.config.head_yaw;
        var native: @import("../script/cmm.zig").ContactState = .{};
        native.random = case.config.seed;
        var inventory = std.mem.zeroes(@import("inventory.zig").Inventory);
        var captured: Capture = .{};
        var runtime: runtime_module.Context = .{ .inventory = &inventory, .pickups = &.{}, .removed = &.{}, .now_ms = 0, .effects = &effects, .contact_state = &native, .bubble_host = .{ .context = &captured, .spawn = Capture.spawn } };
        var look: input.LookState = .{};
        var sound_state: player_audio.State = .{};
        var context: player_audio.Context = .{ .config = &config, .state = &sound_state, .effects = &effects };
        for (case.frames, 0..) |frame, frame_index| {
            var packet: input.Packet = .{};
            packet.entries[23] = .{ .value = 100, .flags = 0x20 };
            for (case.slots) |slot| packet.entries[@intCast(slot[0])] = .{ .value = slot[1], .flags = @intCast(slot[2]) };
            effects.clearRetainingCapacity();
            player.tickWithAudio(&level, &scene, .{ .entries = &.{}, .runtime = &runtime }, &angles, look.control(&packet), &look, 0.016, &context) catch |err| {
                std.debug.print("wading case {s} frame {d}: {s}\n", .{ case.name, frame_index, @errorName(err) });
                return err;
            };
            const actual = Snapshot{
                .sector = player.sector,
                .position = .{ @bitCast(player.position.x), @bitCast(player.position.y), @bitCast(player.position.z) },
                .velocity = .{ @bitCast(player.velocity.x), @bitCast(player.velocity.y), @bitCast(player.velocity.z) },
                .angles = .{ player.pitch, player.yaw, player.head_yaw },
                .eye_height = @bitCast(player.eye_height),
                .body_height = @bitCast(player.body_height),
                .floor_cache = @bitCast(player.floor_cache),
                .energy = @bitCast(player.energy),
                .head_bob = @bitCast(player.head_bob),
                .weapon_offset = player.weapon_offset,
                .stride = @bitCast(player.stride),
                .flags = player.flags,
                .pitch_accumulator = look.pitch_accumulator,
            };
            var expected = frame.state;
            expected.flags &= 0xe004;
            std.testing.expectEqualDeep(expected, actual) catch |err| {
                std.debug.print("wading case {s} frame {d}\n", .{ case.name, frame_index });
                return err;
            };
            if (frame.underwater_elapsed) |elapsed| std.testing.expectEqual(elapsed, @as(u32, @bitCast(player.underwater_elapsed))) catch |err| {
                std.debug.print("water breath case {s} frame {d}\n", .{ case.name, frame_index });
                return err;
            };
            if (frame.random) |random| try std.testing.expectEqual(random, native.random);
            try std.testing.expectEqual(frame.sounds.len, effects.items.len);
            for (frame.sounds, effects.items) |sound, effect| {
                try std.testing.expect(std.ascii.eqlIgnoreCase(sound.name, effect.sound.basename));
                try std.testing.expectEqual(@as(?i32, sound.priority), effect.sound.priority);
                try std.testing.expectEqual(@as(?i32, sound.volume), effect.sound.volume);
                try std.testing.expectEqual(@as(?u32, sound.flags), effect.sound.flags);
            }
        }
        if (case.bubble) |expected| {
            var packet: input.Packet = .{};
            packet.entries[23] = .{ .value = 100, .flags = 0x20 };
            for (case.slots) |slot| packet.entries[@intCast(slot[0])] = .{ .value = slot[1], .flags = @intCast(slot[2]) };
            try std.testing.expectError(error.CapturedOriginalBubbleBoundary, player.tickWithAudio(&level, &scene, .{ .entries = &.{}, .runtime = &runtime }, &angles, look.control(&packet), &look, 0.016, &context));
            try std.testing.expectEqualDeep(expected, captured.value.?);
        }
    }
}

test {
    _ = @import("rail_test.zig");
}

test "player audio matches 539 frames and rolls back failed movement" {
    const a = std.testing.allocator;
    const inventory = @import("inventory.zig");
    const raw_system = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(raw_system);
    const raw_objects = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(raw_objects);
    const system = try @import("../assets/lab.zig").Archive.init(raw_system);
    const objects = try @import("../assets/lab.zig").Archive.init(raw_objects);
    var item = try item_asset.Item.parse(a, try objects.find("CIDJAMES.ITM", 0x4954454d));
    defer item.deinit();
    const physics = try Physics.parse(try system.find("AIR.PHY", 0x50485953));
    const config = try player_audio.Config.fromItem(&item);
    try std.testing.expectEqual(@as(i32, 50), config.foot_volume);
    const spawn: level_asset.Spawn = .{ .sector = 0, .position = .{ .x = 0, .y = 0, .z = 0 }, .rotation = .{ .x = 0, .y = 0, .z = 0 } };
    var sectors = [_]level_asset.Sector{std.mem.zeroes(level_asset.Sector)};
    sectors[0].friction = 1;
    sectors[0].elasticity = 0.2;
    sectors[0].floor_sound = "FLOOR.WAV";
    sectors[0].vadjoin = -1;
    var level = std.mem.zeroInit(level_asset.Level, .{ .arena = std.heap.ArenaAllocator.init(a) });
    level.sectors = &sectors;
    var scene_sectors = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
    var collision_check: u32 = 0;
    var scene = std.mem.zeroInit(scene_module.Scene, .{ .arena = std.heap.ArenaAllocator.init(a), .collision_check = &collision_check });
    scene.sectors = &scene_sectors;
    const angles = camera.Angles.init();
    var effects_buffer: inventory.EffectBuffer = undefined;
    var effects = inventory.Effects.init(&effects_buffer);
    const Chunk = struct {
        slots: []const [3]i16 = &.{},
        count: usize = 1,
    };
    const Case = struct { y: f32 = 0, vy: f32 = 0, flags: u32 = 4, energy: f32 = 100, ceiling: f32 = 30, gravity: f32 = -50, elapsed: f32 = 0, seconds: f32 = 0.016, chunks: []const Chunk = &.{.{}} };
    const cases = [_]Case{
        .{ .chunks = &.{ .{ .slots = &.{.{ 10, 5120, 0 }} }, .{ .count = 75 } } },
        .{ .chunks = &.{ .{ .slots = &.{.{ 0, 5120, 0 }}, .count = 160 }, .{ .count = 15 } } },
        .{ .energy = 20, .chunks = &.{.{ .slots = &.{ .{ 0, 5120, 0 }, .{ 23, 150, 0x20 } }, .count = 220 }} },
        .{ .y = 1, .vy = -10, .flags = 0, .chunks = &.{.{ .count = 20 }} },
        .{ .y = 1, .vy = -38, .flags = 0, .chunks = &.{.{ .count = 20 }} },
        .{ .y = 1, .vy = 40, .flags = 0, .ceiling = 7, .chunks = &.{.{ .count = 20 }} },
        .{ .y = 0.01, .vy = -4, .flags = 0, .gravity = 0 },
        .{ .y = 0.01, .vy = -4.000000476837158, .flags = 0, .gravity = 0 },
        .{ .y = 0.01, .vy = -36, .flags = 0, .gravity = 0 },
        .{ .y = 0.01, .vy = -35.999996185302734, .flags = 0, .gravity = 0 },
        .{ .energy = 0, .elapsed = 1.49, .seconds = 0.01 },
        .{ .energy = 0, .elapsed = 1, .seconds = 0.5, .chunks = &.{.{ .count = 2 }} },
        .{ .energy = 50, .elapsed = 1.49, .seconds = 0.01 },
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (cases) |case| {
        sectors[0].gravity = case.gravity;
        sectors[0].ceiling.height = case.ceiling;
        var player = try Player.init(&item, physics, spawn);
        player.position.y = case.y;
        player.velocity.y = case.vy;
        player.flags = case.flags;
        player.energy = case.energy;
        var sound_state: player_audio.State = .{ .tired_elapsed = case.elapsed };
        var context: player_audio.Context = .{ .config = &config, .state = &sound_state, .effects = &effects };
        var look: input.LookState = .{};
        for (case.chunks) |chunk| for (0..chunk.count) |_| {
            effects.clearRetainingCapacity();
            var packet: input.Packet = .{};
            packet.entries[23] = .{ .value = 100, .flags = 0x20 };
            for (chunk.slots) |slot| packet.entries[@intCast(slot[0])] = .{ .value = slot[1], .flags = @intCast(slot[2]) };
            const control = look.control(&packet);
            try player.tickWithAudio(&level, &scene, .{ .entries = &.{} }, &angles, control, &look, case.seconds, &context);
            var frame: [8]u8 = undefined;
            std.mem.writeInt(u32, frame[0..4], @bitCast(sound_state.tired_elapsed), .little);
            std.mem.writeInt(u32, frame[4..8], @intCast(effects.items.len), .little);
            hash.update(&frame);
            for (effects.items) |effect| {
                const sound = effect.sound;
                const id: u32 = for ([_][]const u8{ "JAJUMP.WAV", "LAND.WAV", "LANDLITE.WAV", "HITHEAD.WAV", "TIRED.WAV", "FLOOR.WAV" }, 1..) |name, id| {
                    if (std.ascii.eqlIgnoreCase(name, sound.basename)) break @intCast(id);
                } else return error.UnexpectedPlayerAudio;
                try std.testing.expect(sound.position == null and sound.sector == null);
                for ([_]u32{ id, @bitCast(sound.priority.?), @bitCast(sound.volume.?), sound.flags.? }) |word| {
                    var encoded: [4]u8 = undefined;
                    std.mem.writeInt(u32, &encoded, word, .little);
                    hash.update(&encoded);
                }
            }
        };
    }
    try std.testing.expectEqualStrings("703606a26064bf19e26f91c574a7c6e82192ac17f50d8e139e850f7922b7686b", &std.fmt.bytesToHex(hash.finalResult(), .lower));

    effects.clearRetainingCapacity();
    try effects.append(.{ .message = .{ .index = 7 } });
    sectors[0].gravity = 0;
    sectors[0].ceiling.height = 30;
    var player = try Player.init(&item, physics, spawn);
    player.position.y = 0.01;
    player.velocity.y = -38;
    player.flags = 0;
    var look: input.LookState = .{};
    const control: input.Control = .{ .forward = 1 };
    var sound_state: player_audio.State = .{ .tired_elapsed = 1.49 };
    var context: player_audio.Context = .{ .config = &config, .state = &sound_state, .effects = &effects };
    var loaded = [_]bool{false};
    const before = player;
    const before_look = look;
    try std.testing.expectError(error.CollisionActorsNotLoaded, player.tickWithAudio(&level, &scene, .{ .entries = &.{}, .loaded_sectors = &loaded }, &angles, control, &look, 0.016, &context));
    try std.testing.expectEqualDeep(before, player);
    try std.testing.expectEqualDeep(before_look, look);
    try std.testing.expectEqual(@as(f32, 1.49), sound_state.tired_elapsed);
    try std.testing.expectEqual(@as(usize, 1), effects.items.len);
    loaded[0] = true;
    try player.tickWithAudio(&level, &scene, .{ .entries = &.{}, .loaded_sectors = &loaded }, &angles, control, &look, 0.016, &context);
    try std.testing.expectEqual(@as(usize, 2), effects.items.len);
    try std.testing.expect(std.ascii.eqlIgnoreCase("LAND.WAV", effects.items[1].sound.basename));
    player = before;
    player.velocity.y = -46;
    player.energy = 0;
    sound_state.tired_elapsed = 1.49;
    try player.tickWithAudio(&level, &scene, .{ .entries = &.{} }, &angles, control, &look, 0.016, &context);
    try std.testing.expectEqual(@as(f32, 46), player.impact);
    try std.testing.expectEqual(@as(f32, 0), sound_state.tired_elapsed);
    try std.testing.expectEqual(@as(usize, 4), effects.items.len);
}

test "player integrator agrees across archived physics control sequences" {
    const a = std.testing.allocator;
    const State = struct {
        sector: usize,
        position: [3]u32,
        velocity: [3]u32,
        angles: [3]i16,
        eye_height: u32,
        body_height: u32,
        floor_cache: u32,
        energy: u32,
        head_bob: u32,
        weapon_offset: ?[2]i32 = null,
        stride: u32,
        flags: u32,
        pitch_accumulator: i32,
    };
    const Frame = struct { slots: []const [3]i32, seconds: u32, state: State };
    const Config = struct {
        original_scene: bool = false,
        sector: usize = 0,
        position: [3]f32 = .{ 0, 0, 0 },
        pitch: i16 = 0,
        yaw: i16 = 0,
        energy: f32 = 100,
        friction: f32 = 1,
        gravity: f32 = -50,
        ceiling: f32 = 30,
        floor: f32 = 0,
        seconds: f32 = 0.016,
        scope_active: bool = false,
        gatling_active: bool = false,
        velocity: [3]f32 = .{ 0, 0, 0 },
        conveyor: [3]f32 = .{ 0, 0, 0 },
        sector_flags: u32 = 0,
        floor_cache: f32 = -2147483648,
        player_flags: u32 = 4,
        floor_slope: ?[4]f32 = null,
        ceiling_slope: ?[4]f32 = null,
        cleared_slope_flags: u32 = 0,
    };
    const Case = struct { name: []const u8, config: Config, frames: []const Frame };
    const raw_system = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(raw_system);
    const raw_objects = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(raw_objects);
    const system = try @import("../assets/lab.zig").Archive.init(raw_system);
    const objects = try @import("../assets/lab.zig").Archive.init(raw_objects);
    var item = try item_asset.Item.parse(a, try objects.find("CIDJAMES.ITM", 0x4954454d));
    defer item.deinit();
    const physics = try Physics.parse(try system.find("AIR.PHY", 0x50485953));
    var sectors = [_]level_asset.Sector{std.mem.zeroes(level_asset.Sector)};
    sectors[0].friction = 1;
    sectors[0].gravity = -50;
    sectors[0].elasticity = 0.2;
    sectors[0].ceiling.height = 30;
    sectors[0].vadjoin = -1;
    var level = std.mem.zeroInit(level_asset.Level, .{ .arena = std.heap.ArenaAllocator.init(a) });
    level.sectors = &sectors;
    var scene_sectors = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
    var collision_check: u32 = 0;
    var scene = std.mem.zeroInit(scene_module.Scene, .{ .arena = std.heap.ArenaAllocator.init(a), .collision_check = &collision_check });
    scene.sectors = &scene_sectors;
    const angles = camera.Angles.init();
    const Chunk = struct { slots: []const [3]i16, count: usize };
    const sequences = [_][]const Chunk{
        &.{.{ .slots = &.{ .{ 0, 5120, 0 }, .{ 2, 5120, 0 } }, .count = 45 }},
        &.{ .{ .slots = &.{ .{ 10, 5120, 0 }, .{ 11, 5120, 0 } }, .count = 1 }, .{ .slots = &.{.{ 11, 5120, 0 }}, .count = 45 }, .{ .slots = &.{}, .count = 25 } },
        &.{ .{ .slots = &.{.{ 7, 8192, 0 }}, .count = 20 }, .{ .slots = &.{}, .count = 10 }, .{ .slots = &.{.{ 7, -8192, 0 }}, .count = 25 }, .{ .slots = &.{}, .count = 10 }, .{ .slots = &.{.{ 7, -32768, 0 }}, .count = 20 }, .{ .slots = &.{}, .count = 30 } },
        &.{ .{ .slots = &.{ .{ 2, 100, 0x20 }, .{ 8, 40, 0x20 } }, .count = 30 }, .{ .slots = &.{}, .count = 15 } },
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (sequences) |sequence| {
        var player = try Player.init(&item, physics, .{ .sector = 0, .position = .{ .x = 0, .y = 0, .z = 0 }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        var look = input.LookState{};
        for (sequence) |chunk| for (0..chunk.count) |_| {
            var packet = input.Packet{};
            packet.entries[23] = .{ .value = 100, .flags = 0x20 };
            for (chunk.slots) |slot| packet.entries[@intCast(slot[0])] = .{ .value = slot[1], .flags = @intCast(slot[2]) };
            const control = look.control(&packet);
            try player.tick(&level, &scene, .{ .entries = &.{} }, &angles, control, &look, 0.016);
            const words = [_]u32{ @bitCast(player.position.x), @bitCast(player.position.y), @bitCast(player.position.z), @bitCast(player.velocity.x), @bitCast(player.velocity.y), @bitCast(player.velocity.z), @bitCast(@as(i32, player.pitch)), @bitCast(@as(i32, player.yaw)), @bitCast(@as(i32, player.head_yaw)), @bitCast(player.eye_height), @bitCast(player.body_height), @bitCast(player.floor_cache), @bitCast(player.energy), @bitCast(player.head_bob), @bitCast(player.stride), player.flags, @bitCast(look.pitch_accumulator) };
            for (words) |word| {
                var encoded: [4]u8 = undefined;
                std.mem.writeInt(u32, &encoded, word, .little);
                hash.update(&encoded);
            }
        };
    }
    try std.testing.expectEqualStrings("54639aeaa354617af438d13194a3186dc27433ea9c26674c8c7050df77491fc9", &std.fmt.bytesToHex(hash.finalResult(), .lower));
    const TransportPin = struct { config: Config, position: [3]u32, velocity: [3]u32, bob: u32, stride: u32 };
    const transport_pins = [_]TransportPin{
        .{ .config = .{ .conveyor = .{ 0, 0, -62.5 }, .sector_flags = 0x40 }, .position = .{ 866224591, 0, 3165111714 }, .velocity = .{ 916308116, 0, 3215185664 }, .bob = 3198929421, .stride = 1065009620 },
        .{ .config = .{ .conveyor = .{ 0, 0, -62.5 }, .sector_flags = 0x40, .position = .{ 0, 8, 0 }, .velocity = .{ 4, 0, 6 }, .player_flags = 0 }, .position = .{ 1032000110, 1090492196, 1036295077 }, .velocity = .{ 1082130431, 3209481421, 1086324735 }, .bob = 3187751188, .stride = 0 },
        .{ .config = .{ .conveyor = .{ 0, 0, -62.5 }, .position = .{ 0, 8, 0 }, .velocity = .{ 4, 0, 6 }, .player_flags = 0 }, .position = .{ 1026703880, 1090492196, 1033546302 }, .velocity = .{ 1076761723, 0, 1083640384 }, .bob = 3199415091, .stride = 0 },
        .{ .config = .{ .conveyor = .{ 0, 0, -62.5 }, .sector_flags = 0x40, .position = .{ 0, 3, 0 }, .floor_cache = 3 }, .position = .{ 0, 1077936128, 0 }, .velocity = .{ 0, 0, 0 }, .bob = 2147483648, .stride = 1089470464 },
    };
    for (transport_pins) |pin| {
        const config = pin.config;
        sectors[0].velocity = .{ .x = config.conveyor[0], .y = config.conveyor[1], .z = config.conveyor[2] };
        scene_sectors[0].velocity_present = config.conveyor[0] != 0 or config.conveyor[1] != 0 or config.conveyor[2] != 0;
        scene_sectors[0].flags = config.sector_flags;
        var player = try Player.init(&item, physics, .{ .sector = 0, .position = .{ .x = config.position[0], .y = config.position[1], .z = config.position[2] }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        player.velocity = .{ .x = config.velocity[0], .y = config.velocity[1], .z = config.velocity[2] };
        player.floor_cache = config.floor_cache;
        player.flags = config.player_flags;
        var look: input.LookState = .{};
        var packet: input.Packet = .{};
        packet.entries[23] = .{ .value = 100, .flags = 0x20 };
        const control = look.control(&packet);
        try player.tick(&level, &scene, .{ .entries = &.{} }, &angles, control, &look, 0.016);
        try std.testing.expectEqual(pin.position, [3]u32{ @bitCast(player.position.x), @bitCast(player.position.y), @bitCast(player.position.z) });
        try std.testing.expectEqual(pin.velocity, [3]u32{ @bitCast(player.velocity.x), @bitCast(player.velocity.y), @bitCast(player.velocity.z) });
        try std.testing.expectEqual(pin.bob, @as(u32, @bitCast(player.head_bob)));
        try std.testing.expectEqual(pin.stride, @as(u32, @bitCast(player.stride)));
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/player-movement-reference.json", a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer a.free(bytes);
    const fixture = try std.json.parseFromSlice(struct { cases: []const Case }, a, bytes, .{});
    defer fixture.deinit();
    for (fixture.value.cases) |case| {
        var geometry_bytes: ?[]u8 = null;
        defer if (geometry_bytes) |loaded| a.free(loaded);
        var original_level: ?level_asset.Level = null;
        defer if (original_level) |*loaded| loaded.deinit();
        var original_scene: ?scene_module.Scene = null;
        defer if (original_scene) |*loaded| loaded.deinit();
        if (case.config.original_scene) {
            geometry_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(64 * 1024 * 1024));
            const archive = try @import("../assets/lab.zig").Archive.init(geometry_bytes.?);
            original_level = try level_asset.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
            var startup = try initial.InfStartup.apply(a, &original_level.?, try archive.find("HIDEOUT.INF", 0));
            defer startup.deinit();
            original_scene = try scene_module.Scene.init(a, &original_level.?, &angles);
            startup.applyScene(&original_level.?, &original_scene.?);
        }
        const active_level = if (original_level) |*loaded| loaded else &level;
        const active_scene = if (original_scene) |*loaded| loaded else &scene;
        sectors[0].friction = case.config.friction;
        sectors[0].gravity = case.config.gravity;
        sectors[0].floor.height = case.config.floor;
        sectors[0].ceiling.height = case.config.ceiling;
        sectors[0].velocity = .{ .x = case.config.conveyor[0], .y = case.config.conveyor[1], .z = case.config.conveyor[2] };
        scene_sectors[0].velocity_present = case.config.conveyor[0] != 0 or case.config.conveyor[1] != 0 or case.config.conveyor[2] != 0;
        sectors[0].floor.slope = null;
        sectors[0].ceiling.slope = null;
        scene_sectors[0].flags = case.config.sector_flags;
        scene_sectors[0].floor_slope = null;
        scene_sectors[0].ceiling_slope = null;
        inline for (.{ "floor", "ceiling" }, .{ @as(u32, 0x40000000), @as(u32, 0x80000000) }) |kind, flag| {
            if (@field(case.config, kind ++ "_slope")) |definition| {
                @field(sectors[0], kind).slope = .{ .sector = 0, .wall = 0, .angle = @intFromFloat(definition[3]) };
                var slope = std.mem.zeroes(scene_module.Slope);
                slope.coeff_x = definition[0];
                slope.coeff_z = definition[1];
                slope.constant = definition[2];
                @field(scene_sectors[0], kind ++ "_slope") = slope;
                scene_sectors[0].flags |= flag;
            }
        }
        scene_sectors[0].flags &= ~case.config.cleared_slope_flags;
        var player = try Player.init(&item, physics, .{ .sector = 0, .position = .{ .x = 0, .y = 0, .z = 0 }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        player.position = .{ .x = case.config.position[0], .y = case.config.position[1], .z = case.config.position[2] };
        player.yaw = case.config.yaw;
        player.pitch = case.config.pitch;
        player.energy = case.config.energy;
        player.scope_active = case.config.scope_active;
        player.gatling_active = case.config.gatling_active;
        player.velocity = .{ .x = case.config.velocity[0], .y = case.config.velocity[1], .z = case.config.velocity[2] };
        player.floor_cache = case.config.floor_cache;
        player.flags = case.config.player_flags;
        player.sector = case.config.sector;
        var look = input.LookState{};
        for (case.frames, 0..) |frame, frame_index| {
            var packet = input.Packet{};
            packet.entries[23] = .{ .value = 100, .flags = 0x20 };
            for (frame.slots) |slot| packet.entries[@intCast(slot[0])] = .{ .value = @intCast(slot[1]), .flags = @intCast(slot[2]) };
            const control = look.control(&packet);
            try player.tick(active_level, active_scene, .{ .entries = &.{} }, &angles, control, &look, @bitCast(frame.seconds));
            const actual = State{
                .sector = player.sector,
                .position = .{ @bitCast(player.position.x), @bitCast(player.position.y), @bitCast(player.position.z) },
                .velocity = .{ @bitCast(player.velocity.x), @bitCast(player.velocity.y), @bitCast(player.velocity.z) },
                .angles = .{ player.pitch, player.yaw, player.head_yaw },
                .eye_height = @bitCast(player.eye_height),
                .body_height = @bitCast(player.body_height),
                .floor_cache = @bitCast(player.floor_cache),
                .energy = @bitCast(player.energy),
                .head_bob = @bitCast(player.head_bob),
                .weapon_offset = if (frame.state.weapon_offset != null) player.weapon_offset else null,
                .stride = @bitCast(player.stride),
                .flags = player.flags,
                .pitch_accumulator = look.pitch_accumulator,
            };
            var expected = frame.state;
            expected.flags &= 0x2004;
            std.testing.expectEqualDeep(expected, actual) catch |err| {
                std.debug.print("player case {s}, frame {d}\n", .{ case.name, frame_index });
                std.debug.print("expected {any}\nactual {any}\n", .{ expected, actual });
                return err;
            };
        }
    }
}

test "outhouse movement preserves 442 dry vertical-adjoin states" {
    const a = std.testing.allocator;
    var archives: [3]@import("../assets/lab.zig").Archive = undefined;
    var bytes: [3][]u8 = undefined;
    var loaded: usize = 0;
    defer for (bytes[0..loaded]) |raw| a.free(raw);
    for ([_][]const u8{ "OUTLAWS.LAB", "OLOBJ.LAB", "OLGEO.LAB" }, 0..) |name, index| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}", .{name});
        defer a.free(path);
        bytes[index] = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        loaded += 1;
        archives[index] = try @import("../assets/lab.zig").Archive.init(bytes[index]);
    }
    var item = try item_asset.Item.parse(a, try archives[1].find("CIDJAMES.ITM", 0x4954454d));
    defer item.deinit();
    const physics = try Physics.parse(try archives[0].find("AIR.PHY", 0x50485953));
    var level = try level_asset.Level.parse(a, try archives[2].find("HIDEOUT.LVB", 0));
    defer level.deinit();
    var startup = try initial.InfStartup.apply(a, &level, try archives[2].find("HIDEOUT.INF", 0));
    defer startup.deinit();
    const angles = camera.Angles.init();
    var scene = try scene_module.Scene.init(a, &level, &angles);
    defer scene.deinit();
    startup.applyScene(&level, &scene);

    const Chunk = struct {
        slots: []const [3]i16 = &.{},
        count: usize = 1,
    };
    const Case = struct { sector: usize = 212, y: f32 = -3, z: f32 = 451, floor: f32 = -2147483648, chunks: []const Chunk };
    const cases = [_]Case{
        .{ .chunks = &.{ .{ .slots = &.{ .{ 0, 5120, 0 }, .{ 10, 5120, 0 } } }, .{ .slots = &.{.{ 0, 5120, 0 }}, .count = 59 }, .{ .count = 30 }, .{ .slots = &.{.{ 0, -5120, 0 }}, .count = 60 }, .{ .count = 30 } } },
        .{ .chunks = &.{ .{ .slots = &.{ .{ 0, 5120, 0 }, .{ 10, 5120, 0 } }, .count = 60 }, .{ .count = 30 }, .{ .slots = &.{.{ 0, -5120, 0 }}, .count = 60 }, .{ .count = 30 } } },
        .{ .sector = 70, .y = 1.5, .z = 460, .floor = 1.5, .chunks = &.{ .{ .count = 30 }, .{ .slots = &.{.{ 0, -5120, 0 }}, .count = 20 }, .{ .count = 30 } } },
        .{ .sector = 70, .y = -3.5, .z = 460, .floor = -3.5, .chunks = &.{.{}} },
        .{ .sector = 70, .y = -3.499999761581421, .z = 460, .floor = -3.499999761581421, .chunks = &.{.{}} },
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (cases) |case| {
        var player = try Player.init(&item, physics, .{ .sector = case.sector, .position = .{ .x = 465.5, .y = case.y, .z = case.z }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        player.floor_cache = case.floor;
        var look: input.LookState = .{};
        for (case.chunks) |chunk| for (0..chunk.count) |_| {
            var packet: input.Packet = .{};
            packet.entries[23] = .{ .value = 100, .flags = 0x20 };
            for (chunk.slots) |slot| packet.entries[@intCast(slot[0])] = .{ .value = slot[1], .flags = @intCast(slot[2]) };
            const control = look.control(&packet);
            try player.tick(&level, &scene, .{ .entries = &.{} }, &angles, control, &look, 0.016);
            const words = [_]u32{ @bitCast(player.position.x), @bitCast(player.position.y), @bitCast(player.position.z), @bitCast(player.velocity.x), @bitCast(player.velocity.y), @bitCast(player.velocity.z), @bitCast(@as(i32, player.pitch)), @bitCast(@as(i32, player.yaw)), @bitCast(@as(i32, player.head_yaw)), @bitCast(player.eye_height), @bitCast(player.body_height), @bitCast(player.floor_cache), @bitCast(player.energy), @bitCast(player.head_bob), @bitCast(player.stride), player.flags & 0x2004, @bitCast(look.pitch_accumulator), @intCast(player.sector), @bitCast(player.weapon_offset[0]), @bitCast(player.weapon_offset[1]) };
            for (words) |word| {
                var encoded: [4]u8 = undefined;
                std.mem.writeInt(u32, &encoded, word, .little);
                hash.update(&encoded);
            }
        };
    }
    try std.testing.expectEqualStrings("9e5dadefd94a7e660057cf18d2081a7d38c98b12bad77a7276dd6167aee5f045", &std.fmt.bytesToHex(hash.finalResult(), .lower));

    for ([_]usize{ 70, 66 }) |sector| for ([_]f32{ -3.5, -3.500000238418579, -7.625 }) |y| {
        const pair = try verticalSectors(&level, &scene, sector, .{ .x = 465.5, .y = y, .z = 460 });
        try std.testing.expectEqual(VerticalSectors{ .lower = 66, .upper = 70, .surface = -3.5 }, pair);
    };

    const config = try player_audio.Config.fromItem(&item);
    var effects_buffer: @import("inventory.zig").EffectBuffer = undefined;
    var effects = @import("inventory.zig").Effects.init(&effects_buffer);
    for ([_]usize{ 214, 70 }) |sector| for ([_]f32{ -10, -38 }) |velocity| {
        var player = try Player.init(&item, physics, .{ .sector = sector, .position = .{ .x = 465.5, .y = 1.6, .z = if (sector == 214) 458 else 460 }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        player.velocity.y = velocity;
        player.floor_cache = 1.5;
        player.flags = 0;
        var look: input.LookState = .{};
        var sound_state: player_audio.State = .{};
        var context: player_audio.Context = .{ .config = &config, .state = &sound_state, .effects = &effects };
        effects.clearRetainingCapacity();
        try player.tickWithAudio(&level, &scene, .{ .entries = &.{} }, &angles, .{}, &look, 0.016, &context);
        const expected: usize = if (sector == 70 and velocity == -10) 0 else 1;
        try std.testing.expectEqual(expected, effects.items.len);
        if (expected != 0) {
            const sound = effects.items[0].sound;
            try std.testing.expect(std.ascii.eqlIgnoreCase(if (velocity == -10) "LANDLITE.WAV" else "LAND.WAV", sound.basename));
            try std.testing.expectEqual(@as(?i32, 64), sound.priority);
            try std.testing.expectEqual(@as(?i32, 127), sound.volume);
            try std.testing.expectEqual(@as(?u32, 0), sound.flags);
        }
    };
}

test "Hideout shallow wading and splash state match the reference" {
    try checkWaterReference("testdata/player-wading-reference.json");
}

test "Hideout swimming matches WATER.PHY integration" {
    try checkWaterReference("testdata/player-water-reference.json");
}

test "forced water and both movement bubble branches" {
    try checkWaterReference("testdata/player-water-edges-reference.json");
}
