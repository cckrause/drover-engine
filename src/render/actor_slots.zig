//! A level session's actor slots: one fixed set, the same size for every
//! level. A level's own objects take the first slots, in object order, and
//! keep them for the whole level. Actors made during play take the rest.
//!
//! A slot made during play goes back on the free list once its actor is gone
//! and nothing points at it any more, so spawning and removing actors never
//! takes more memory. Actors made during play still run in the order they
//! were made, whatever slot they got; `Made` keeps that order.

const std = @import("std");

const level = @import("../assets/level.zig");
const blood = @import("../enemy/blood.zig");
const dynamic = @import("../enemy/dynamic.zig");
const inventory = @import("../player/inventory.zig");
const target = @import("../player/target.zig");
const projectile = @import("../projectile/runtime.zig");
const actor_links = @import("actor_links.zig");
const max_level_sectors = @import("backends/software/world.zig").max_level_sectors;
const Actor = @import("objects.zig").Actor;

/// The most map objects in a shipped level (655, CANYON) plus the most
/// actors made during play that were alive at once over the test suite
/// (234).
/// TODO: The original grows its actor pool without a limit, so this is a
/// measured size, not one from the original program. Check it against
/// custom maps too: shipped levels and the tests may not show the most a
/// level ever needs. 1024 slots would cost about 470 KiB more per session.
pub const capacity = 655 + 234;

/// Every per-actor array a session keeps, all indexed by slot. Lives inside
/// the session, which stays at one address for its whole life.
pub const Storage = struct {
    actors: [capacity]?Actor,
    /// The live actors packed together for drawing and collision.
    drawn: [capacity]Actor,
    transformed: [capacity]level.Vec3,
    drawn_index: [capacity]?usize,
    removed: [capacity]bool,
    targets: [capacity]?target.Target,
    pickups: [capacity]?inventory.Pickup,
    projectiles: [capacity]?projectile.State,
    next_update: [capacity]i32,
    numbers: [capacity]u32,
    blood: [capacity]?blood.State,
    general: [capacity]?blood.State,
    splash: [capacity]?dynamic.SplashState,
    links: [capacity]actor_links.Node,
    /// The first actor in each sector.
    sector_heads: [max_level_sectors]?usize,
};

/// The slots made during play that are in use, in the order they were
/// made, and the ones free to hand out again.
pub const Made = struct {
    first: ?usize = null,
    last: ?usize = null,
    next: [capacity]?usize = undefined,
    previous: [capacity]?usize = undefined,
    listed: [capacity]bool = @splat(false),
    free: [capacity]usize = undefined,
    free_count: usize = 0,

    /// Puts `slot` at the end of the made order.
    pub fn append(self: *Made, slot: usize) void {
        std.debug.assert(slot < capacity);
        std.debug.assert(!self.listed[slot]);

        self.listed[slot] = true;
        self.next[slot] = null;
        self.previous[slot] = self.last;

        if (self.last) |last| self.next[last] = slot else self.first = slot;

        self.last = slot;
    }

    pub fn after(self: *const Made, slot: usize) ?usize {
        std.debug.assert(self.listed[slot]);

        return self.next[slot];
    }

    pub fn before(self: *const Made, slot: usize) ?usize {
        std.debug.assert(self.listed[slot]);

        return self.previous[slot];
    }

    /// The slot freed most recently, if any.
    pub fn takeFree(self: *Made) ?usize {
        if (self.free_count == 0) return null;

        self.free_count -= 1;
        const slot = self.free[self.free_count];

        std.debug.assert(!self.listed[slot]);

        return slot;
    }

    /// Takes `slot` out of the made order and onto the free list. Only call
    /// this between frames: a walk over the made order keeps the next slot
    /// it will visit, and that slot must stay listed.
    pub fn release(self: *Made, slot: usize) void {
        std.debug.assert(self.listed[slot]);
        std.debug.assert(self.free_count < capacity);

        if (self.previous[slot]) |previous| self.next[previous] = self.next[slot] else self.first = self.next[slot];

        if (self.next[slot]) |following| self.previous[following] = self.previous[slot] else self.last = self.previous[slot];

        self.listed[slot] = false;
        self.free[self.free_count] = slot;
        self.free_count += 1;
    }
};

test "freed slots come back last-freed first and keep the made order" {
    var made: Made = .{};

    for ([_]usize{ 4, 5, 6, 7 }) |slot| made.append(slot);

    made.release(5);
    made.release(7);

    try std.testing.expectEqual(@as(?usize, 7), made.takeFree());

    made.append(7);

    try std.testing.expectEqual(@as(?usize, 5), made.takeFree());
    try std.testing.expectEqual(@as(?usize, null), made.takeFree());

    made.append(5);

    var order: [4]usize = undefined;
    var count: usize = 0;
    var cursor = made.first;

    while (cursor) |slot| : (cursor = made.after(slot)) {
        order[count] = slot;
        count += 1;
    }

    try std.testing.expectEqualSlices(usize, &.{ 4, 6, 7, 5 }, order[0..count]);
    try std.testing.expectEqual(@as(?usize, 7), made.before(5));
    try std.testing.expectEqual(@as(?usize, null), made.before(4));
}

test "releasing the only slot empties the made order" {
    var made: Made = .{};

    made.append(3);
    made.release(3);

    try std.testing.expectEqual(@as(?usize, null), made.first);
    try std.testing.expectEqual(@as(?usize, null), made.last);
    try std.testing.expectEqual(@as(usize, 1), made.free_count);
}
