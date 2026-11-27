//! What the player's shots and nudges hit among the enemies, and the
//! messages that result.
//!
//! Enemy decisions and ticks live in src/enemy; this is only the targeting
//! and the message that leaves. Queued damage is delivered later in the
//! frame, so the order of several hits in one frame is defined.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const cmm = @import("../script/cmm.zig");
const shooting = @import("shooting.zig");
const Actor = @import("../render/objects.zig").Actor;
const Angles = @import("../render/backends/software/camera.zig").Angles;
const config_module = @import("../enemy/config.zig");
pub const controller = @import("../enemy/controller.zig");
const weapon = @import("weapon.zig");

pub const Target = struct {
    native: cmm.Native = .enemy,
    sanchez: bool = false,
    damage: shooting.EnemyState,
    config: config_module.Config = .{},
    config_name: []const u8 = "",
    ai: controller.State = .{},
    allocator: std.mem.Allocator,
    hit_chor: u32 = 20,
    hit_sound: []const u8 = "bgy1hit.wav",
    die_sound: []const u8 = "bgy1die.wav",
    drop_item: []const u8 = "gdrop1.itm",
    dead: bool = false,
    aggressiveness: i32 = 4,
    mode: u32 = 0x80000001,
    previous_mode: u32 = 0,
    anger: f32 = 0,
    fear: f32 = 0,
    attack_at: u32 = 0,
    sight_at: u32 = 0,
    next_tick: u32 = 0,
    animation_ended: bool = true,
    playback: nwx.Playback = .{},
    pending_selection: ?u32 = null,
    selections: std.ArrayList(Selection) = .empty,
    selection_serial: ?*u64 = null,
    selection_cursor: usize = 0,
    saved: ?Saved = null,

    pub const Selection = struct { serial: u64, choreography: u32 };

    pub const Saved = struct {
        mode: u32,
        previous_mode: u32,
        damage: shooting.EnemyState,
        anger: f32,
        fear: f32,
        animation_ended: bool,
    };

    const AnimationContext = struct {
        target: *Target,
        actor: *Actor,
        runtime: *controller.Context,

        pub fn event(
            self: *AnimationContext,
            playback: *nwx.Playback,
            costume: *const nwx.Costume,
            message: u32,
            arguments: []const u32,
            now: u32,
        ) !void {
            _ = costume;
            _ = now;
            self.actor.choreography = playback.choreography;
            self.actor.frame = playback.frame;
            self.actor.angle_offset = playback.angle_offset;

            try controller.message(self.target, self.actor, message, arguments, self.runtime);
        }
    };

    const SelectionContext = struct {
        random: *u32,

        pub fn event(
            self: *SelectionContext,
            playback: *nwx.Playback,
            costume: *const nwx.Costume,
            message: u32,
            arguments: []const u32,
            now: u32,
        ) !void {
            _ = playback;
            _ = costume;
            _ = arguments;
            _ = now;
            _ = weapon.randomNext(self.random);

            switch (message) {
                0x5f, 0x61, 2 => {},
                else => return error.UnsupportedEnemyAnimationCallback,
            }
        }
    };

    pub fn hit(
        self: *Target,
        angles: *const Angles,
        actor: *Actor,
        input: shooting.DamageInput,
        random: *u32,
        now: u32,
    ) !void {
        _ = weapon.randomNext(random);
        self.next_tick = 0;
        if (self.mode == 0x3c0) return;

        const death = try shooting.damageEnemy(angles, actor.*, &self.damage, input);

        if (death) |choreography| {
            if (self.mode == 0x800003c0) return error.UnsupportedEnemyDeathTick;

            self.mode = 0x800003c0;
            actor.flags |= 0x80000100;
            self.dead = true;

            if (!try self.requestDeath(actor, choreography))
                _ = try self.requestDeath(actor, self.damage.death_chor);
        } else {
            if (self.mode == 0x800003c0) return error.UnsupportedEnemyDeathTick;

            self.anger = std.math.clamp(@as(f32, @floatCast(@as(f64, self.anger) - 3.0)), 0, 7);
            self.fear = std.math.clamp(@as(f32, @floatCast(@as(f64, self.fear) + 3.0)), 0, 7);

            if (self.aggressiveness >= 4) self.attack_at = now;

            if (self.mode == 1) return error.UnsupportedEnemyAlertBroadcast;

            if (self.mode & 0xffff != 8) {
                if (self.saved != null) return error.UnsupportedEnemyStateStack;

                self.saved = .{
                    .mode = self.mode,
                    .previous_mode = self.previous_mode,
                    .damage = self.damage,
                    .anger = self.anger,
                    .fear = self.fear,
                    .animation_ended = self.animation_ended,
                };

                self.mode = 0x80000008;
            }

            if (input.shooter_position != null) {
                if (actor.secondary_flags == 0) return error.UnsupportedEnemyRetarget;
                self.sight_at = now +% 2000;
            }
        }

        if (actor.secondary_flags & 0x04000000 != 0) return error.UnsupportedEnemyReflectedDamage;
    }

    pub fn select(self: *Target, actor: *Actor, choreography: u32) !bool {
        self.animation_ended = true;
        if (choreography >= (try actor.sprite()).choreographies.len) return false;

        const serial = if (self.selection_serial) |value| blk: {
            const result = value.*;
            value.* +%= 1;
            break :blk result;
        } else 0;

        try self.selections.append(
            self.allocator,
            .{ .serial = serial, .choreography = choreography },
        );

        self.pending_selection = choreography;
        self.animation_ended = false;
        self.damage.current_chor = @as(u8, @truncate(choreography));

        const frame = try (try actor.sprite()).select(
            actor.choreography,
            actor.frame,
            0,
            actor.angle_offset,
        );

        if (frame.parts.len != 0) actor.height = frame.parts[0].height;

        return true;
    }

    pub fn deliverSelection(self: *Target, actor: *Actor, random: *u32, now: u32) !void {
        if (self.selections.items.len == 0) return;

        self.pending_selection = null;
        var context = SelectionContext{ .random = random };

        for (self.selections.items) |selection| {
            try self.playback.select(try actor.sprite(), selection.choreography, now, &context);
            _ = weapon.randomNext(random);
        }

        self.selections.clearRetainingCapacity();

        actor.choreography = self.playback.choreography;
        actor.frame = self.playback.frame;
        actor.angle_offset = self.playback.angle_offset;
        self.next_tick = 0;
    }

    pub fn advanceAnimation(self: *Target, actor: *Actor, context: *controller.Context) !void {
        var bound = AnimationContext{ .target = self, .actor = actor, .runtime = context };
        try self.playback.advanceWithContext(try actor.sprite(), 0, context.now, &bound);
        self.syncAnimation(actor);
    }

    pub fn deliverWithContext(self: *Target, actor: *Actor, context: *controller.Context) !void {
        while (self.selection_cursor < self.selections.items.len) try self.deliverNext(
            actor,
            context,
        );

        self.selections.clearRetainingCapacity();
        self.selection_cursor = 0;
    }

    pub fn deliverNext(self: *Target, actor: *Actor, context: *controller.Context) !void {
        if (self.selection_cursor == self.selections.items.len) return;

        var bound = AnimationContext{ .target = self, .actor = actor, .runtime = context };
        const selection = self.selections.items[self.selection_cursor];

        self.selection_cursor += 1;

        try self.playback.select(try actor.sprite(), selection.choreography, context.now, &bound);
        self.syncAnimation(actor);
        try controller.message(self, actor, 0x78, &.{0x403}, context);

        self.pending_selection = if (self.selection_cursor == self.selections.items.len) null else self.selections.items[self.selections.items.len - 1].choreography;
    }

    pub fn load(
        a: std.mem.Allocator,
        archives: []const lab.Archive,
        item: *const Item,
        difficulty: u32,
    ) !?Target {
        const native = try cmm.resolve(item.function);

        switch (native) {
            .enemy, .slim, .chicken, .civilian, .sanchez, .farmer, .bob, .dynamite, .marshal => {},
            else => return null,
        }

        const config = try config_module.Config.load(a, archives, item, difficulty);
        var ai = controller.State.init(config);

        ai.special = native == .slim or native == .bob;

        return .{
            .native = if (std.ascii.eqlIgnoreCase(item.function, "Bowers_New")) .enemy else native,
            .sanchez = native == .sanchez,
            .allocator = a,
            .config = config,
            .config_name = try a.dupe(u8, item.name),
            .ai = ai,
            .damage = .{
                .health = config.health,
                .crouch_chor = config.duck_chor,
                .death_chor = config.chest_die_chor,
                .leg_death_chor = config.leg_die_chor,
                .left_death_chor = config.left_die_chor,
                .right_death_chor = config.right_die_chor,
            },
            .aggressiveness = config.aggressiveness,
            .hit_chor = config.hit_chor,
            .hit_sound = config.hit_sound,
            .die_sound = config.die_sound,
            .drop_item = config.drop_item,
        };
    }

    fn requestDeath(self: *Target, actor: *Actor, choreography: u32) !bool {
        return self.select(actor, choreography);
    }

    fn syncAnimation(self: *const Target, actor: *Actor) void {
        actor.choreography = self.playback.choreography;
        actor.frame = self.playback.frame;
        actor.angle_offset = self.playback.angle_offset;
    }
};
