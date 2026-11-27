//! The router's message storage: one block of message bytes and a fixed
//! number of slots, both made once with the router and reused from then on.
//!
//! New messages go after the last one. When the space at the end runs out
//! but there is room in the gaps, the waiting messages are packed together
//! first. A message the game is reading (taken) never moves, so the gap in
//! front of it stays unusable until it is released, as with the original's
//! locked blocks.

const std = @import("std");

pub const Index = u16;
pub const none: Index = std.math.maxInt(Index);

const State = enum(u8) { free, waiting, taken };

const Slot = struct {
    start: u32 = 0,
    length: u32 = 0,
    /// Next slot in the same chain (a queue, the taken list, a bundle or the
    /// free list).
    next: Index = none,
    /// Neighbours in the block, in address order, for packing.
    before: Index = none,
    after: Index = none,
    state: State = .free,
};

pub const MessageStore = struct {
    pub fn storageBytes(byte_capacity: usize, slot_capacity: usize) usize {
        return byte_capacity + slot_capacity * @sizeOf(Slot);
    }

    bytes: []u8,
    slots: []Slot,
    free_slot: Index = none,
    first: Index = none,
    last: Index = none,
    end: usize = 0,
    used_bytes: usize = 0,
    used_slots: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        byte_capacity: usize,
        slot_capacity: usize,
    ) !MessageStore {
        std.debug.assert(slot_capacity > 0 and slot_capacity < none);
        std.debug.assert(byte_capacity <= std.math.maxInt(u32));

        const bytes = try allocator.alloc(u8, byte_capacity);
        errdefer allocator.free(bytes);
        const slots = try allocator.alloc(Slot, slot_capacity);
        var self: MessageStore = .{ .bytes = bytes, .slots = slots };

        for (slots, 0..) |*slot, index| slot.* = .{
            .next = if (index + 1 < slot_capacity) @intCast(index + 1) else none,
        };

        self.free_slot = 0;

        return self;
    }

    pub fn deinit(self: *MessageStore, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn add(self: *MessageStore, data: []const u8) error{NetworkQueueFull}!Index {
        if (self.free_slot == none) return error.NetworkQueueFull;

        if (data.len > self.bytes.len - self.end) {
            if (data.len > self.bytes.len - self.used_bytes) return error.NetworkQueueFull;
            self.pack();
            if (data.len > self.bytes.len - self.end) return error.NetworkQueueFull;
        }

        const index = self.free_slot;
        const slot = &self.slots[index];

        self.free_slot = slot.next;
        slot.* = .{
            .start = @intCast(self.end),
            .length = @intCast(data.len),
            .before = self.last,
            .state = .waiting,
        };

        if (self.last == none) self.first = index else self.slots[self.last].after = index;

        self.last = index;
        @memcpy(self.bytes[self.end..][0..data.len], data);

        self.end += data.len;
        self.used_bytes += data.len;
        self.used_slots += 1;

        return index;
    }

    pub fn remove(self: *MessageStore, index: Index) void {
        const slot = &self.slots[index];

        std.debug.assert(slot.state != .free);

        if (slot.before == none) self.first = slot.after else self.slots[slot.before].after = slot.after;

        if (slot.after == none) {
            self.last = slot.before;
            self.end = if (slot.before == none) 0 else self.slots[slot.before].start + self.slots[slot.before].length;
        } else self.slots[slot.after].before = slot.before;

        self.used_bytes -= slot.length;
        self.used_slots -= 1;

        slot.* = .{ .next = self.free_slot };
        self.free_slot = index;
    }

    pub fn get(self: *const MessageStore, index: Index) []u8 {
        const slot = &self.slots[index];
        std.debug.assert(slot.state != .free);

        return self.bytes[slot.start..][0..slot.length];
    }

    /// Keeps the message in place until it is removed.
    pub fn take(self: *MessageStore, index: Index) void {
        std.debug.assert(self.slots[index].state == .waiting);
        self.slots[index].state = .taken;
    }

    fn pack(self: *MessageStore) void {
        var cursor: usize = 0;
        var at = self.first;

        for (0..self.slots.len + 1) |_| {
            if (at == none) break;

            const slot = &self.slots[at];

            if (slot.state == .taken) {
                std.debug.assert(slot.start >= cursor);
                cursor = slot.start + slot.length;
            } else {
                if (slot.start != cursor) {
                    std.mem.copyForwards(
                        u8,
                        self.bytes[cursor..][0..slot.length],
                        self.bytes[slot.start..][0..slot.length],
                    );

                    slot.start = @intCast(cursor);
                }

                cursor += slot.length;
            }

            at = slot.after;
        } else unreachable;

        self.end = cursor;
    }
};

/// Messages in arrival order, linked through their slots.
pub const Chain = struct {
    first: Index = none,
    last: Index = none,
    count: usize = 0,

    pub fn push(self: *Chain, store: *MessageStore, index: Index) void {
        store.slots[index].next = none;

        if (self.last == none) self.first = index else store.slots[self.last].next = index;

        self.last = index;
        self.count += 1;
    }

    pub fn pop(self: *Chain, store: *MessageStore) ?Index {
        if (self.first == none) return null;

        const index = self.first;

        self.first = store.slots[index].next;

        if (self.first == none) self.last = none;

        store.slots[index].next = none;
        self.count -= 1;

        return index;
    }

    /// Finds the message whose bytes start at `bytes` and unlinks it.
    pub fn unlink(self: *Chain, store: *MessageStore, bytes: []const u8) ?Index {
        var previous: Index = none;
        var at = self.first;

        for (0..self.count) |_| {
            const next = store.slots[at].next;

            if (store.get(at).ptr == bytes.ptr) {
                if (previous == none) self.first = next else store.slots[previous].next = next;

                if (self.last == at) self.last = previous;

                store.slots[at].next = none;
                self.count -= 1;

                return at;
            }

            previous = at;
            at = next;
        }

        return null;
    }

    /// Removes every message in the chain from the store.
    pub fn clear(self: *Chain, store: *MessageStore) void {
        while (self.pop(store)) |index| store.remove(index);
    }
};

test "messages fill the block, and packing makes room from the gaps" {
    var store = try MessageStore.init(std.testing.allocator, 12, 8);
    defer store.deinit(std.testing.allocator);
    var queue: Chain = .{};

    for ("abcdef") |letter| queue.push(&store, try store.add(&.{ letter, letter }));

    try std.testing.expectError(error.NetworkQueueFull, store.add("x"));

    store.remove(queue.pop(&store).?);
    store.remove(queue.pop(&store).?);
    queue.push(&store, try store.add("ghij"));

    try std.testing.expectEqual(@as(usize, 12), store.end);
    var expected: [5][]const u8 = .{ "cc", "dd", "ee", "ff", "ghij" };

    for (&expected) |text| {
        const index = queue.pop(&store).?;
        try std.testing.expectEqualStrings(text, store.get(index));
        store.remove(index);
    }

    try std.testing.expectEqual(@as(usize, 0), store.end);
    try std.testing.expectEqual(@as(usize, 0), store.used_slots);
}

test "a message being read stays in place, and the gap in front of it stays unused" {
    var store = try MessageStore.init(std.testing.allocator, 8, 8);
    defer store.deinit(std.testing.allocator);
    const first = try store.add("aa");
    const reading = try store.add("bb");
    const third = try store.add("cccc");

    store.take(reading);
    const before = store.get(reading).ptr;

    store.remove(first);
    store.remove(third);

    const added = try store.add("dddd");

    try std.testing.expectEqual(before, store.get(reading).ptr);
    try std.testing.expectEqualStrings("bb", store.get(reading));
    try std.testing.expectEqualStrings("dddd", store.get(added));
    try std.testing.expectError(error.NetworkQueueFull, store.add("ee"));

    store.remove(reading);
    _ = try store.add("ee");
}

test "every slot is reused once freed" {
    var store = try MessageStore.init(std.testing.allocator, 64, 3);
    defer store.deinit(std.testing.allocator);

    for (0..100) |_| {
        var chain: Chain = .{};

        for (0..3) |_| chain.push(&store, try store.add("m"));

        try std.testing.expectError(error.NetworkQueueFull, store.add("m"));
        const middle = store.get(store.slots[chain.first].next);
        store.remove(chain.unlink(&store, middle).?);
        try std.testing.expectEqual(@as(usize, 2), chain.count);
        chain.clear(&store);
    }

    try std.testing.expectEqual(@as(usize, 0), store.used_bytes);
}
