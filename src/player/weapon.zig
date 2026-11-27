//! The weapon in hand: input, shots, reloading and melee.
//!
//! Impact sound is gated separately from impact effects: every pellet of a
//! shot makes effects, only the first makes a sound. A melee swing checks
//! the final ray's result before it plays its connect sound.

const std = @import("std");

const level = @import("../assets/level.zig");
const nwx = @import("../assets/nwx.zig");
const camera = @import("../render/backends/software/camera.zig");
const input = @import("input.zig");
const inventory_module = @import("inventory.zig");
const movement = @import("movement.zig");
const Native = @import("../script/cmm.zig").Native;
const projectile = @import("../projectile/runtime.zig");
const choreography = @import("choreography.zig");
pub const Config = @import("weapon_config.zig").Config;
pub const Mode = @import("weapon_config.zig").Mode;
const FixedList = @import("../util/fixed_list.zig").FixedList;

/// Shots one pass may collect before they are cast: four trigger pulls of
/// two rounds with the most pellets any shipped weapon fires (30). Frame time
/// is not capped, so a long stall can still go past this and stop with
/// `TooManyShots`.
pub const max_shots = 4 * 2 * 30;
pub const Shots = FixedList(Shot, error{TooManyShots});
pub const ShotBuffer = [max_shots]Shot;

pub const ShotKind = enum(u32) { melee = 0, bullet = 1 };

pub const Shot = struct {
    origin: level.Vec3,
    sector: usize,
    yaw: i16,
    pitch: i16,
    range: f32,
    damage: f32,
    mass: f32,
    rate: f32,
    kind: ShotKind,
    impact_effect: bool = true,
    impact_sound: bool = true,
    hit_sound: ?struct {
        request: @import("../audio/request.zig").Request,
        effect_index: usize,
    } = null,
};

pub const ShotSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Shot, *inventory_module.Effects) anyerror!void,
};

pub const NoiseSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, f32, u32, *inventory_module.Effects) anyerror!void,
};

pub const PlayerChoreography = struct {
    context: *anyopaque,
    table: choreography.Table,
    animation: *const u32,
    has_actor: bool,
    set: *const fn (*anyopaque, i16) anyerror!void,
};

pub const ProjectileSink = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, projectile.Descriptor, *inventory_module.Effects) anyerror!usize,
    launch: *const fn (*anyopaque, usize, projectile.Owner, f32) anyerror!void,
};

pub const AutoAimCandidate = struct { flags: u32, x: f32, y: f32, z: f32, height: f32 };

pub const State = struct {
    action: i32 = -1,
    pending: i32 = -1,
    ended: bool = false,
    released: bool = false,
    did_fire: bool = false,
    did_finish: bool = false,
    scope: bool = false,
    held: [4]bool = @splat(false),
    last_press: u32 = 0,
    bound_slot: usize = 0,
    crt_random: u32 = 1,
    shot_count: u32 = 0,
    fire_noise_due: u32 = 0,
    flash: i32 = 0,
    kick: f32 = 0,
    scope_flash: i32 = 0,
    scope_kick: f32 = 0,
    aim_x: i32 = 0,
    aim_y: i32 = 0,
    aim_weight: i32 = 0,
    aim_due: ?u32 = null,
    held_projectile: ?usize = null,
    charge_started: u32 = 0,
    throw_fraction: f32 = 0,
    player_choreography: i32 = 0,

    pub fn inputPacket(
        self: *State,
        inventory: *inventory_module.Inventory,
        packet: *const input.Packet,
        now: u32,
    ) !void {
        if (inventory.player_flags & 0x10000000 != 0 or inventory.health <= 0) return;
        try self.selectInput(inventory, packet.get(.weapon));
        try self.fireInput(inventory, packet, now);
    }

    pub fn selectInput(
        self: *State,
        inventory: *inventory_module.Inventory,
        select: input.Entry,
    ) !void {
        if (inventory.player_flags & 0x10000000 != 0 or inventory.health <= 0) return;

        if (select.flags & (input.absolute | input.pressed) == input.absolute | input.pressed and select.value >= 0) {
            const slot: usize = @intCast(select.value);
            if (slot >= inventory.slots.len) return error.InvalidInventorySlot;

            if (slot == 0) {
                if (inventory.selected_weapon != 0) self.reset();
                inventory.selected_weapon = 0;
            } else if (inventory.slots[slot]) |owned| {
                if (owned.definition.weapon != null) {
                    if (inventory.selected_weapon != slot) {
                        self.reset();
                        inventory.selected_weapon = slot;
                    } else self.pending = 6;
                }
            }
        }
    }

    pub fn fireInput(
        self: *State,
        inventory: *inventory_module.Inventory,
        packet: *const input.Packet,
        now: u32,
    ) !void {
        if (inventory.player_flags & 0x10000000 != 0 or inventory.health <= 0) return;

        const owned = inventory.slots[inventory.selected_weapon] orelse return;
        if (owned.definition.weapon == null) return;

        for ([_]input.Slot{ .fire, .fire_big, .fire_other, .reload }, 0..) |slot, i| {
            const entry = packet.get(slot);
            const mode = mappedMode(owned.definition.function, i);

            if (entry.flags & input.released != 0) {
                self.held[i] = false;
                if (mode != -1 and (i != 3 or !owned.definition.infinite)) {
                    if (self.action == mode) self.released = true else if (self.pending == mode) self.pending = -1;
                }
            }

            if (entry.flags & input.pressed != 0) {
                self.held[i] = true;
                if (self.last_press +% 250 > now) continue;
                self.last_press = now;
                if (mode != -1 and (i != 3 or !owned.definition.infinite)) self.pending = mode;
            }
        }
    }

    pub fn reset(self: *State) void {
        self.action = -1;
        self.pending = -1;
        self.ended = false;
        self.released = false;
        self.did_fire = false;
        self.did_finish = false;
        self.charge_started = 0;
        self.throw_fraction = 0;
    }

    pub fn reconcileSelection(self: *State, inventory: *const inventory_module.Inventory) void {
        const selected = if (inventory.slots[inventory.selected_weapon] != null) inventory.selected_weapon else 0;

        if (self.bound_slot != selected) {
            self.reset();
            self.scope = false;
            self.bound_slot = selected;
        }

        var held = false;

        for (self.held) |value| held = held or value;

        if (!held) self.released = true;
    }

    pub fn pitchKick(self: *const State) i16 {
        return @truncate(
            @as(i32, @intFromFloat(@as(f64, self.kick) * @as(f32, 5.0) * @as(f64, 45.5112))),
        );
    }

    pub fn advancePresentation(self: *State, seconds: f32) void {
        if (@as(u32, @bitCast(self.kick)) & 0x7fffffff != 0) {
            self.kick = @floatCast(
                @max(@as(f64, 0), @as(f64, self.kick) - @as(f64, seconds) * 4.0),
            );

            self.flash = 0;
        }
    }

    pub fn advanceScopePresentation(self: *State, seconds: f32) void {
        if (@as(u32, @bitCast(self.scope_kick)) & 0x7fffffff != 0) {
            self.scope_kick = @floatCast(
                @max(@as(f64, 0), @as(f64, self.scope_kick) - @as(f64, seconds) * 4.0),
            );

            self.scope_flash = 0;
        }
    }

    pub fn advanceAim(self: *State, now: u32) void {
        if (self.aim_due) |due| if (due < now) {
            self.aim_weight -%= 10;
            self.aim_due = if (self.aim_weight == 0) null else now +% 100;
        };
    }

    fn aim(self: *State, x: i32, y: i32, now: u32) void {
        self.aim_x = x;
        self.aim_y = y;
        self.aim_weight = 100;
        self.aim_due = now +% 1000;
    }
};

pub const Context = struct {
    state: *State,
    inventory: *inventory_module.Inventory,
    player: *const movement.Player,
    random: *u32,
    crt_random: ?*u32 = null,
    effects: *inventory_module.Effects,
    shots: *Shots,
    shot_sink: ?ShotSink = null,
    noise_sink: ?NoiseSink = null,
    projectile_sink: ?ProjectileSink = null,
    now: u32,
    ready: bool,
    animation_slot: ?usize = null,
    underwater: bool = false,
    game_flags: u32 = 0,
    auto_aim: bool = true,
    aim_horizontal: i16 = 182,
    aim_vertical: i16 = 182,
    player_team_flags: u32 = 0,
    friendly_fire: bool = false,
    quadruple_mass: bool = false,
    candidates: []const AutoAimCandidate = &.{},
    player_choreography: ?PlayerChoreography = null,
    angles: *const camera.Angles,
    bubble_context: ?@import("../script/runtime.zig").Context = null,

    pub fn tick(self: *Context, playback: *nwx.Playback, costume: *const nwx.Costume) !void {
        if (self.state.bound_slot != self.inventory.selected_weapon) try self.dropHeld();
        self.state.reconcileSelection(self.inventory);
        try self.transition(playback, costume);
    }

    pub fn reset(self: *Context, playback: *nwx.Playback, costume: *const nwx.Costume) !void {
        try self.dropHeld();
        self.state.reset();

        const item = self.inventory.slots[self.inventory.selected_weapon] orelse return;
        const config = item.definition.weapon orelse return error.MissingWeaponConfiguration;

        try self.rest(playback, costume, config);
    }

    pub fn inputPacket(
        self: *Context,
        playback: *nwx.Playback,
        costume: *const nwx.Costume,
        packet: *const input.Packet,
    ) !void {
        if (self.inventory.player_flags & 0x10000000 != 0 or self.inventory.health <= 0) return;
        try self.selectInput(packet.get(.weapon));
        try self.fireInput(playback, costume, packet);
    }

    pub fn selectInput(self: *Context, select: input.Entry) !void {
        if (self.inventory.player_flags & 0x10000000 != 0 or self.inventory.health <= 0) return;

        if (select.flags & (input.absolute | input.pressed) == input.absolute | input.pressed and select.value >= 0 and select.value != self.inventory.selected_weapon) {
            const slot: usize = @intCast(select.value);
            if (slot >= self.inventory.slots.len) return error.InvalidInventorySlot;
            if (slot == 0 or (self.inventory.slots[slot] != null and self.inventory.slots[slot].?.definition.weapon != null)) try self.dropHeld();
        }

        try self.state.selectInput(self.inventory, select);
    }

    pub fn fireInput(
        self: *Context,
        playback: *nwx.Playback,
        costume: *const nwx.Costume,
        packet: *const input.Packet,
    ) !void {
        if (self.inventory.player_flags & 0x10000000 != 0 or self.inventory.health <= 0) return;

        if (packet.get(
            .fire,
        ).flags & input.released != 0 and (self.state.action == 4 or self.state.action == 5)) {
            self.state.action = if (self.state.action == 4) 0 else 1;
            self.state.throw_fraction = @min(
                @max(
                    @as(
                        f32,
                        @floatCast(
                            @as(
                                f64,
                                @floatFromInt(self.now -% self.state.charge_started),
                            ) * @as(f32, 0.001),
                        ),
                    ),
                    0.5,
                ),
                1.0,
            );

            var budget: usize = 0;

            while (playback.flags & 2 == 0) : (budget += 1) {
                if (budget >= costume.choreographies[playback.choreography].frames.len + 1) return error.MissingProjectileChargePause;
                try playback.advanceWithContext(costume, 1, self.now, self);
            }

            playback.flags &= ~@as(u32, 2);
        }

        try self.state.fireInput(self.inventory, packet, self.now);
    }

    pub fn dropHeld(self: *Context) !void {
        if (self.state.held_projectile) |source| {
            const sink = self.projectile_sink orelse return error.MissingProjectileRuntime;
            try sink.launch(sink.context, source, self.projectileOwner(false), 0);
            self.state.held_projectile = null;
        }
    }

    pub fn event(
        self: *Context,
        playback: *nwx.Playback,
        costume: *const nwx.Costume,
        message: u32,
        arguments: []const u32,
        now: u32,
    ) anyerror!void {
        _ = arguments;
        self.now = now;
        if (self.inventory.slots[self.animation_slot orelse self.inventory.selected_weapon] == null) return;

        const state = self.state;
        const item = try self.owned();
        const projectile_weapon = item.definition.function == .weapon_tnt_handler or item.definition.function == .weapon_knife_handler;

        if (message == 1) {
            if (state.action == 0 or state.action == 1) {
                if (projectile_weapon) {
                    try self.projectileEvent(item.definition.function == .weapon_tnt_handler);
                } else if (item.definition.function == .weapon_fist_handler) {
                    try self.firePlayerChoreography(true);
                    try self.melee();
                } else {
                    const double = item.definition.function == .weapon_db_shotgun_handler or item.definition.function == .weapon_sawed_shotgun_handler;
                    try self.firePlayerChoreography(false);
                    try self.fire(if (double and state.action == 0 and item.loaded > 1) 2 else 1);
                }
            } else if (state.action == 3 and item.definition.function != .weapon_gatling_handler and item.definition.function != .weapon_fist_handler) try self.reloadOne(playback, costume);

            state.did_fire = true;
        } else if (message == 98 or message == 99) {
            state.did_finish = true;

            if (projectile_weapon) {
                if (item.count == 0) {
                    const slot = self.animation_slot orelse self.inventory.selected_weapon;
                    self.inventory.selected_weapon = 1;
                    try self.inventory.remove(slot);
                    return;
                }

                if (item.definition.function == .weapon_tnt_handler or state.action != 1) {
                    state.ended = true;
                    return;
                }
            }

            if ((!state.released and state.pending == -1) or state.pending == state.action) {
                state.pending = state.action;
                try self.transition(playback, costume);
            } else state.ended = true;
        }
    }

    fn owned(self: *Context) !*inventory_module.OwnedItem {
        return if (self.inventory.slots[self.animation_slot orelse self.inventory.selected_weapon]) |*value| value else error.MissingSelectedWeapon;
    }

    fn transition(
        self: *Context,
        playback: *nwx.Playback,
        costume: *const nwx.Costume,
    ) anyerror!void {
        const state = self.state;
        var pending = state.pending;

        if (state.ended and pending == state.action) pending = -1;

        if (!self.ready or (pending == -1 and (state.action == -1 or !state.ended))) return;

        const item = try self.owned();
        const config = item.definition.weapon orelse return error.MissingWeaponConfiguration;
        const interrupt_after_fire = item.definition.function == .weapon_pistol_handler or item.definition.function == .weapon_gatling_handler;
        if (state.action != -1 and !state.ended and !(if (interrupt_after_fire) state.did_fire else state.did_finish)) return;

        try self.rest(playback, costume, config);

        state.action = -1;
        state.pending = -1;
        state.ended = false;
        state.released = false;

        if (pending >= 0 and pending <= 2) {
            const mode: usize = @intCast(pending);
            state.action = pending;

            if ((self.game_flags & 0x40 != 0 or config.auto_reload) and item.loaded == 0) try self.refill();

            const empty = (item.loaded == 0 or self.underwater) and !item.definition.infinite;
            const sequence = if (state.scope) (if (empty) config.scope_empty[mode] else config.scope_fire[mode]) else (if (empty) config.empty[mode] else config.fire[mode]);

            try playback.select(costume, @bitCast(@as(i32, sequence)), self.now, self);
            try self.sound(config.action_sound[mode]);

            state.did_fire = false;
            state.did_finish = false;

            if ((item.definition.function == .weapon_knife_handler and mode == 0) or (item.definition.function == .weapon_tnt_handler and mode == 1)) {
                state.charge_started = self.now;
                state.action = if (mode == 0) 4 else 5;
            }
        } else if (pending == 3) {
            defer {
                state.did_fire = false;
                state.did_finish = false;
            }

            if (item.definition.infinite) return;

            if (self.underwater) {
                _ = randomFloat(self.random, 0.2);
                var aim: struct {
                    yaw: i16,
                    pitch: i16,
                } = .{ .yaw = self.player.yaw +% self.player.head_yaw, .pitch = self.player.pitch };

                if (!state.scope) self.autoAim(&aim, true);

                state.shot_count +%= 1;
                const count: i32 = @intCast(randomNext(self.random) & 3);
                try self.spawnBubbles(.{
                    .x = self.player.position.x,
                    .y = @floatCast(
                        @as(f64, self.player.body_height) * @as(f32, 0.92) + self.player.position.y,
                    ),
                    .z = self.player.position.z,
                }, aim.yaw, count);
            }

            const ammo = self.inventory.find(item.definition.ammo);
            if (self.game_flags & 8 == 0 and (ammo == 0 or self.inventory.slots[ammo].?.count < 1)) return;

            if (config.reload != 0 and item.loaded < item.definition.capacity) {
                state.action = 3;
                try playback.select(costume, @bitCast(@as(i32, config.reload)), self.now, self);
                state.aim(0, 0, self.now);
                try self.noise(150, 0x81);
            }
        } else if (pending == 6) {
            if (config.scope_item) |required| {
                if (required.len == 0 or self.inventory.find(required) != 0) {
                    state.scope = !state.scope;
                    try playback.select(
                        costume,
                        @bitCast(@as(i32, if (state.scope) config.scope_rest else config.rest)),
                        self.now,
                        self,
                    );
                }
            }
        }
    }

    fn rest(
        self: *Context,
        playback: *nwx.Playback,
        costume: *const nwx.Costume,
        config: Config,
    ) !void {
        if (self.state.action != -1 or (playback.choreography != @as(
            u32,
            @bitCast(@as(i32, config.rest)),
        ) and playback.choreography != @as(u32, @bitCast(@as(i32, config.scope_rest))))) {
            try playback.select(
                costume,
                @bitCast(@as(i32, if (self.state.scope) config.scope_rest else config.rest)),
                self.now,
                self,
            );

            try self.restorePlayerChoreography();

            self.state.action = -1;
        }
    }

    fn restorePlayerChoreography(self: *Context) !void {
        if (self.state.player_choreography == -1) return;

        const host = self.player_choreography orelse return;
        if (!host.has_actor) return;

        try host.set(host.context, @truncate(self.state.player_choreography));
        self.state.player_choreography = -1;
    }

    fn firePlayerChoreography(self: *Context, punch: bool) !void {
        const host = self.player_choreography orelse return;
        const current: i32 = @bitCast(host.animation.*);
        if (host.table.shoot != current and host.table.punch != current) self.state.player_choreography = current;
        try host.set(host.context, if (punch) host.table.punch else host.table.shoot);
    }

    fn projectileEvent(self: *Context, tnt: bool) !void {
        if (!(tnt and self.state.action == 0)) try self.firePlayerChoreography(true);

        if (!tnt and self.state.action == 1) return self.melee();

        const item = try self.owned();
        const config = item.definition.weapon.?;
        const sink = self.projectile_sink orelse return error.MissingProjectileRuntime;
        if (tnt and self.state.action == 0) {
            if (self.state.held_projectile == null and !self.underwater) {
                const shot = self.baseShot(config, config.modes[0], .melee, false);
                self.state.held_projectile = try sink.create(
                    sink.context,
                    try projectileDescriptor(config, shot, .explosive),
                    self.effects,
                );
            }

            return;
        }

        const knife_launch = self.state.held_projectile == null;
        var origin: level.Vec3 = undefined;
        var yaw: i16 = undefined;

        if (self.state.held_projectile == null) {
            const shot = self.baseShot(config, config.modes[0], .melee, false);

            self.state.held_projectile = try sink.create(
                sink.context,
                try projectileDescriptor(config, shot, .knife),
                self.effects,
            );

            origin = shot.origin;
            yaw = shot.yaw;
        } else {
            _ = randomFloat(self.random, 0.2);
            origin = .{
                .x = self.player.position.x,
                .y = @floatCast(
                    @as(f64, self.player.body_height) * @as(f32, 0.92) + self.player.position.y,
                ),
                .z = self.player.position.z,
            };

            yaw = self.player.yaw +% self.player.head_yaw;
        }

        if (self.underwater) {
            try self.spawnBubbles(origin, yaw, @intCast(randomNext(self.random) & 3));
            self.state.throw_fraction *= 0.5;
        }

        try sink.launch(
            sink.context,
            self.state.held_projectile.?,
            self.projectileOwner(knife_launch),
            self.state.throw_fraction,
        );

        self.state.held_projectile = null;
        try self.sound(config.fire_sound[@intCast(self.state.action)]);

        if (self.game_flags & 8 == 0) item.count -%= 1;
    }

    fn projectileDescriptor(
        config: Config,
        shot: Shot,
        kind: projectile.Kind,
    ) !projectile.Descriptor {
        return .{
            .kind = kind,
            .item = config.projectile orelse return error.MissingProjectileConfiguration,
            .owner = @import("shooting.zig").local_player,
            .origin = shot.origin,
            .sector = shot.sector,
            .pitch = shot.pitch,
            .yaw = shot.yaw,
            .damage = shot.damage,
            .mass = shot.mass,
            .rate = shot.rate,
            .range = shot.range,
        };
    }

    fn projectileOwner(self: *Context, knife: bool) projectile.Owner {
        var owner: projectile.Owner = .{
            .source = @import("shooting.zig").local_player,
            .position = self.player.position,
            .sector = self.player.sector,
            .height = self.player.body_height,
            .velocity = self.player.velocity,
            .pitch = self.player.pitch,
            .yaw = self.player.yaw,
        };

        if (knife) {
            var aim = .{ .pitch = self.player.pitch, .yaw = self.player.yaw };
            self.autoAim(&aim, false);
            owner.launch_yaw = aim.yaw;
        }

        return owner;
    }

    fn reloadOne(self: *Context, playback: *nwx.Playback, costume: *const nwx.Costume) !void {
        const item = try self.owned();
        const config = item.definition.weapon.?;

        if (self.game_flags & 8 != 0) {
            item.loaded = @min(item.loaded +% 1, item.definition.capacity);
            if (item.loaded == item.definition.capacity) try self.rest(playback, costume, config);
        } else {
            const ammo = self.inventory.find(item.definition.ammo);

            if (ammo != 0 and self.inventory.slots[ammo].?.count >= 1) {
                const count = self.inventory.slots[ammo].?.count;
                item.loaded +%= 1;

                if (count == 1) {
                    try self.inventory.remove(ammo);
                    try self.rest(playback, costume, config);
                } else {
                    self.inventory.slots[ammo].?.count = count -% 1;

                    if (item.loaded == item.definition.capacity) try self.rest(
                        playback,
                        costume,
                        config,
                    );
                }

                try self.sound(config.reload_sound);
            }
        }

        if (self.state.released) try self.rest(playback, costume, config);
    }

    fn refill(self: *Context) !void {
        const item = try self.owned();
        const before = item.loaded;
        if (self.game_flags & 8 != 0) item.loaded = item.definition.capacity else try self.inventory.reload(self.animation_slot orelse self.inventory.selected_weapon);
        if (self.game_flags & 8 == 0 and item.loaded != before and !item.definition.infinite) try self.sound(item.definition.weapon.?.reload_sound);
    }

    fn sound(self: *Context, name: ?[]const u8) !void {
        if (name) |value| try self.effects.append(.{ .sound = localSound(value) });
    }

    fn baseShot(
        self: *Context,
        config: Config,
        mode: Mode,
        kind: ShotKind,
        aim_offsets: bool,
    ) Shot {
        var shot: Shot = .{
            .origin = .{
                .x = self.player.position.x,
                .y = @floatCast(
                    @as(f64, self.player.body_height) * @as(f32, 0.92) + self.player.position.y,
                ),
                .z = self.player.position.z,
            },
            .sector = self.player.sector,
            .yaw = self.player.yaw +% self.player.head_yaw,
            .pitch = self.player.pitch,
            .range = mode.effective_range,
            .damage = @floatCast(
                (randomFloat(self.random, 0.2) + @as(f64, @as(f32, 0.9))) * mode.damage,
            ),
            .mass = mode.mass,
            .rate = mode.rate,
            .kind = kind,
        };

        if (!self.state.scope) self.autoAim(&shot, aim_offsets);

        if (self.inventory.sheriff_active) {
            shot.damage *= 4;
            shot.mass *= 2;
        }

        if (self.quadruple_mass) shot.mass *= 4;

        self.state.shot_count +%= 1;

        if (!self.underwater) {
            self.state.flash = config.flash;
            self.state.kick = config.kick;
            self.state.scope_flash = config.flash;
            self.state.scope_kick = config.kick;
        }

        return shot;
    }

    fn fire(self: *Context, rounds: i32) !void {
        const item = try self.owned();
        const config = item.definition.weapon.?;
        if (config.projectile != null) return error.UnsupportedProjectileWeapon;

        const mode_index: usize = @intCast(self.state.action);
        const mode = config.modes[mode_index];
        const variance: f32 = @floatCast(
            (100.0 - @as(f64, self.player.energy)) * @as(f32, 0.05) + mode.variance,
        );

        if (self.underwater) {
            const base = self.baseShot(config, mode, .bullet, !self.state.scope);
            try self.spawnBubbles(base.origin, base.yaw, config.multiples *% rounds);
            try self.sound(config.empty_sound[mode_index]);
            return;
        }

        if (self.game_flags & 0x40 != 0 and item.loaded == 0) try self.refill();

        var fired: i32 = 0;

        while (fired < rounds and item.loaded != 0) : (fired += 1) {
            var base = self.baseShot(config, mode, .bullet, !self.state.scope);

            if (!self.state.scope) {
                base.pitch = try self.disperse(base.pitch, variance);
                base.yaw = try self.disperse(base.yaw, variance);
                base.range = self.randomRange(mode);
            }

            var i: i32 = 0;

            while (i < config.multiples) : (i += 1) {
                var shot = base;

                shot.pitch = try self.disperse(shot.pitch, mode.spread);
                shot.yaw = try self.disperse(shot.yaw, mode.spread);
                shot.impact_sound = i == 0;

                try self.emitShot(shot);
            }

            if (self.game_flags & 8 == 0) item.loaded -%= 1;

            if (self.game_flags & 0x40 != 0 and item.loaded == 0) try self.refill();
        }

        if (fired == 0) {
            try self.sound(config.empty_sound[mode_index]);
            try self.noise(50, 0x80);
        } else if (config.fire_sound[mode_index]) |name| {
            try self.sound(name);

            if (self.state.fire_noise_due < self.now) {
                try self.noise(150, 0x82);
                self.state.fire_noise_due = self.now +% 300;
            }
        }
    }

    fn melee(self: *Context) !void {
        const item = try self.owned();
        const config = item.definition.weapon.?;
        const mode_index: usize = @intCast(self.state.action);
        const mode = config.modes[mode_index];
        const variance: f32 = @floatCast(
            (100.0 - @as(f64, self.player.energy)) * @as(f32, 0.05) + mode.variance,
        );

        var base = self.baseShot(config, mode, .melee, false);

        if (self.underwater) {
            try self.spawnBubbles(base.origin, base.yaw, @intCast(randomNext(self.random) & 3));
            base.damage *= 0.5;
        }

        base.pitch = try self.disperse(base.pitch, variance);
        base.yaw = try self.disperse(base.yaw, variance);

        const increment = try degrees(mode.spread);
        if (increment <= 0) return error.InvalidMeleeSpread;

        var sweep: i16 = -%@as(i16, @truncate(increment));
        const first = sweep;
        var emitted = false;

        while (@as(i32, sweep) <= increment) : (sweep +%= @as(i16, @truncate(increment))) {
            if (emitted and sweep == first) return error.InvalidMeleeSpread;

            emitted = true;
            var shot = base;

            shot.range = self.randomRange(mode);
            shot.impact_effect = false;
            shot.impact_sound = false;

            if (@as(i32, sweep) + increment > increment) {
                if (config.fire_sound[mode_index]) |name| shot.hit_sound = .{
                    .request = localSound(name),
                    .effect_index = self.effects.items.len,
                };
            }

            try self.emitShot(shot);
        }
    }

    fn emitShot(self: *Context, shot: Shot) !void {
        if (self.shot_sink) |sink| try sink.emit(
            sink.context,
            shot,
            self.effects,
        ) else try self.shots.append(shot);
    }

    fn noise(self: *Context, radius: f32, code: u32) !void {
        if (self.noise_sink) |sink| try sink.emit(sink.context, radius, code, self.effects);
    }

    fn spawnBubbles(self: *Context, origin: level.Vec3, yaw: i16, count: i32) !void {
        const basis = self.angles.sinCos(yaw);
        const runtime = if (self.bubble_context) |*context| context else return error.MissingBubbleRuntime;

        try runtime.spawnBubbles(self.player.sector, .{
            .x = @floatCast(@as(f64, @abs(self.player.radius)) * 2 * basis.sin + origin.x),
            .y = origin.y,
            .z = @floatCast(@as(f64, @abs(self.player.radius)) * 2 * basis.cos + origin.z),
        }, count);
    }

    fn randomRange(self: *Context, mode: Mode) f32 {
        if (randomNext(self.random) & 7 == 0) {
            const half = mode.effective_range * 0.5;
            return @floatCast(randomFloat(self.random, half) + half);
        }

        return @floatCast(
            randomFloat(self.random, mode.range - mode.effective_range) + mode.effective_range,
        );
    }

    fn crtRandom(self: *Context) *u32 {
        return self.crt_random orelse &self.state.crt_random;
    }

    fn disperse(self: *Context, angle: i16, amount: f32) !i16 {
        const offset = try degrees(
            randomFloatVariable(self.random, self.crtRandom(), amount * 2) - amount,
        );

        return @bitCast(
            (@as(u16, @bitCast(angle)) +% @as(u16, @truncate(@as(u32, @bitCast(offset))))) & 0x3fff,
        );
    }

    fn autoAim(self: *Context, shot: anytype, offsets: bool) void {
        self.state.aim(0, 0, self.now);
        if (!self.auto_aim) return;

        var target: ?AutoAimCandidate = null;
        const side = self.angles.tan(self.aim_horizontal);
        const above = self.angles.tan(shot.pitch +% self.aim_vertical);
        const below = self.angles.tan(shot.pitch -% self.aim_vertical);

        for (self.candidates) |candidate| {
            if (candidate.flags & 0x110 == 0) continue;

            if (candidate.flags & 0x10 != 0 and !self.friendly_fire and (candidate.flags ^ self.player_team_flags) & 15 == 0) continue;

            const vertical: f32 = @floatCast(
                @as(f64, candidate.height) * @as(f32, 0.85) + candidate.y,
            );

            if (@abs(
                candidate.x,
            ) > @abs(
                candidate.z * side,
            ) or vertical > candidate.z * above or candidate.z * below > vertical) continue;

            if (target == null or candidate.z < target.?.z) target = candidate;
        }

        if (target) |candidate| {
            var yaw = atanAngle(candidate.x, candidate.z);
            var pitch = atanAngle(
                @floatCast(@as(f64, candidate.height) * @as(f32, 0.85) + candidate.y),
                candidate.z,
            ) -% shot.pitch;

            if (yaw > 0x2000) yaw -%= 0x4000;

            if (pitch > 0x2000) pitch -%= 0x4000;

            const yaw_error: i16 = -%@as(
                i16,
                @truncate(
                    (@as(
                        i32,
                        @intCast(randomVariable(self.random, self.crtRandom()) & 0xffff),
                    ) * @as(i32, yaw)) >> 16,
                ),
            );

            const pitch_error: i16 = -%@as(
                i16,
                @truncate(
                    (@as(
                        i32,
                        @intCast(randomVariable(self.random, self.crtRandom()) & 0xffff),
                    ) * @as(i32, pitch)) >> 16,
                ),
            );

            shot.yaw +%= yaw +% yaw_error;
            shot.pitch +%= pitch +% pitch_error;

            if (offsets) {
                self.state.aim_x = nearest(
                    self.angles.sinCos(yaw +% @divTrunc(yaw_error, 3)).sin * 300,
                );

                self.state.aim_y = -%nearest(
                    self.angles.sinCos(pitch +% @divTrunc(pitch_error, 3)).sin * 300,
                );
            }
        }
    }
};

pub fn randomNext(state: *u32) u32 {
    state.* = if (state.* & 1 != 0) ~((state.* ^ 0xb9ffffff) >> 1) else state.* >> 1;

    return state.*;
}

pub fn randomFloat(state: *u32, maximum: f32) f64 {
    return randomScale(randomNext(state), maximum);
}

fn localSound(name: []const u8) @import("../audio/request.zig").Request {
    return .{ .basename = name, .priority = 0x40, .volume = 0x7f, .flags = 0 };
}

fn mappedMode(native: Native, index: usize) i32 {
    if (index == 3) return 3;
    if (index == 2) return -1;

    return switch (native) {
        .weapon_rifle_handler, .weapon_shotgun_handler => 0,
        .weapon_tnt_handler => if (index == 0) 1 else 0,
        else => @intCast(index),
    };
}

fn randomVariable(state: *u32, crt: *u32) u32 {
    crt.* = crt.* *% 0x343fd +% 0x269ec3;
    var count = (crt.* >> 16) & 7;
    while (count != 0) : (count -= 1) _ = randomNext(state);

    return state.*;
}

fn randomFloatVariable(state: *u32, crt: *u32, maximum: f32) f64 {
    return randomScale(randomVariable(state, crt), maximum);
}

fn randomScale(value: u32, maximum: f32) f64 {
    const limit = nearest(@as(f64, maximum) * 65536.0);
    var result: i32 = @bitCast(value);

    if (result < 0 or result >= limit) result = @truncate(
        (@as(i64, @intCast(value & 0xffff)) * limit) >> 16,
    );

    return @as(f64, @floatFromInt(result)) * 0.0000152587890625;
}

fn nearest(value: f64) i32 {
    if (!std.math.isFinite(
        value,
    ) or value >= 2147483647.5 or value < -2147483648.5) return std.math.minInt(i32);

    const lower = @floor(value);
    const fraction = value - lower;
    const base: i64 = @intFromFloat(lower);

    return @intCast(
        base + @as(i64, if (fraction > 0.5 or (fraction == 0.5 and base & 1 != 0)) 1 else 0),
    );
}

fn degrees(value: f64) !i32 {
    const angle = value * @as(f64, 0.002777777777777778) * 16384.0;
    const truncated = @trunc(angle);
    if (!std.math.isFinite(
        angle,
    ) or truncated < std.math.minInt(
        i32,
    ) or truncated > std.math.maxInt(i32)) return error.InvalidWeaponAngle;

    return @intFromFloat(angle);
}

fn atanAngle(x: f32, z: f32) i16 {
    const radians: f32 = @floatCast(std.math.atan2(@as(f64, x), @as(f64, z)));
    const value: i32 = @intFromFloat(
        @as(f64, radians) * @as(f64, @bitCast(@as(u64, 0x3fc45f306dcc48b9))) * 16384.0,
    );

    return @bitCast(@as(u16, @truncate(@as(u32, @bitCast(value)))) & 0x3fff);
}
