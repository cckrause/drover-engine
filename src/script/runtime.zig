//! The context scripts run in: who sent a message, which entities may
//! receive it, and the effects a script produced this frame.
//!
//! The entity filter is derived from the sender's own flags. Native messages
//! execute where they are raised, so a script can see the result of its own
//! message within the same call.

const std = @import("std");
const ActorKind = @import("../actor_flags.zig").ActorKind;
const bits = @import("../util/bits.zig");
const Events = @import("inf_flags.zig").Events;

const inventory = @import("../player/inventory.zig");
const Actor = @import("../render/objects.zig").Actor;
const level_module = @import("../assets/level.zig");
const actor_links = @import("../render/actor_links.zig");
const cmm = @import("cmm.zig");
const inf_module = @import("inf.zig");
const interaction = @import("interaction.zig");

pub const Context = struct {
    inventory: *inventory.Inventory,
    pickups: []const ?inventory.Pickup,
    removed: []bool,
    now_ms: u32,
    effects: *inventory.Effects,
    contact_state: *cmm.ContactState,
    actor_next_update: []i32 = &.{},
    contact_log: ?*std.array_list.Managed(usize) = null,
    inf: ?*inf_module.Runtime = null,
    level: ?*level_module.Level = null,
    collision_diameter: ?*f32 = null,
    entity_mask: ActorKind = .{ .player = true },
    sector_messages: bool = true,
    sector_relinked: ?*bool = null,
    links: ?*actor_links.Links = null,
    linked_actor: ?usize = null,
    link_order: ?*u64 = null,
    link_serial: ?*u64 = null,
    bubble_host: ?struct {
        context: *anyopaque,
        spawn: *const fn (*anyopaque, *Context, usize, level_module.Vec3, i32) anyerror!void,
    } = null,
    actor_host: ?struct {
        context: *anyopaque,
        activate: *const fn (*anyopaque, usize) anyerror!void,
    } = null,
    solid_host: ?struct {
        context: *anyopaque,
        touch: *const fn (*anyopaque, usize) anyerror!void,
    } = null,
    pickup_release: ?struct {
        context: *anyopaque,
        emit: *const fn (*anyopaque, usize) anyerror!void,
    } = null,
    palette_host: ?struct {
        context: *anyopaque,
        enter: *const fn (*anyopaque, usize) anyerror!void,
    } = null,

    pub fn spawnBubbles(
        self: *Context,
        sector: usize,
        position: level_module.Vec3,
        count: i32,
    ) !void {
        const host = self.bubble_host orelse return error.MissingBubbleRuntime;
        try host.spawn(host.context, self, sector, position, count);
    }

    pub fn infEvent(self: *Context, event: interaction.Event) !void {
        if (event.actor) |source| {
            const host = self.actor_host orelse return error.MissingActorActivationRuntime;
            return host.activate(host.context, source);
        }

        const inf = self.inf orelse return;

        try inf.event(self.level orelse return error.MissingInfLevel, .{
            .sector = event.sector,
            .wall = event.wall,
            .mask = event.mask,
            .object_id = event.object_id,
            .entity_mask = self.entity_mask,
            .from_player = self.entity_mask.player and event.wall == null and bits.any(event.mask, Events.nudge),
            .now_ms = self.now_ms,
        });
    }

    pub fn crossWall(
        self: *Context,
        level: *const level_module.Level,
        sector: usize,
        wall: usize,
    ) !void {
        for (interaction.wallEvents(
            level,
            sector,
            wall,
            .{ .cross_front = true },
            0,
            0,
        )) |event| if (event) |value| try self.infEvent(value);
    }

    pub fn changeSector(self: *Context, old: usize, new: usize) !void {
        if (old == new) return;

        if (self.sector_relinked) |value| value.* = true;

        if (self.links) |links| if (self.linked_actor) |source| links.remove(source);

        if (self.sector_messages) try self.infEvent(.{ .sector = old, .mask = .{ .leave_sector = true } });

        if (self.links) |links| if (self.linked_actor) |source| links.move(source, new);

        if (self.link_order) |order| if (self.link_serial) |serial| {
            order.* = serial.*;
            serial.* += 1;
        };

        if (self.sector_messages) try self.infEvent(.{ .sector = new, .mask = .{ .enter_sector = true } });

        if (self.palette_host) |host| try host.enter(host.context, new);
    }

    pub fn isRemoved(self: *const Context, actor: Actor) bool {
        const index = actor.source_index orelse return false;

        return index < self.removed.len and self.removed[index];
    }

    pub fn touch(self: *Context, actor: Actor) !void {
        if (actor.logic_name.len == 0 or self.isRemoved(actor)) return;

        const index = actor.source_index orelse return error.MissingScriptActor;
        if (index >= self.removed.len) return error.InvalidScriptActor;

        if (self.contact_log) |log| try log.append(index);

        if (std.mem.eql(u8, actor.logic_name, "DRECK_PEX")) return;

        const native = try cmm.resolve(actor.logic_name);

        switch (native) {
            .ground_object, .instant_ground_object, .ground_sheriff_star, .ground_vanishing_cream, .projectile_dispatch => {
                if (index >= self.pickups.len) return error.MissingPickupState;
                // A thrown knife still in flight has no pickup yet; touching it does nothing.
                if (native == .projectile_dispatch and self.pickups[index] == null) return;

                const pickup = &(self.pickups[index] orelse return error.MissingPickupState);
                if (pickup.function != native) return error.InvalidPickupBinding;

                self.removed[index] = try self.inventory.take(pickup, self.now_ms, self.effects);

                if (self.removed[index]) if (self.pickup_release) |host| try host.emit(
                    host.context,
                    index,
                );

                if (self.removed[index]) if (self.links) |links| links.remove(index);
            },
            else => {
                if (self.solid_host) |host| return host.touch(host.context, index);

                const result = try cmm.touchSolid(native, self.contact_state, false);

                if (result.next_tick) |tick| {
                    if (index >= self.actor_next_update.len) return error.MissingActorSchedule;
                    self.actor_next_update[index] = @bitCast(tick);
                }
            },
        }
    }
};
