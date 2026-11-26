//! A fixed backing reservation shared by the engine and its host adapters.
//! Buddy blocks reuse freed storage; allocation never asks the backing heap
//! for another region. Destroying the budget invalidates every allocation.

const MemoryBudget = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

reservation: []align(4096) u8,
storage: []u8,
tree: []u8,
root_order: u8,
io: std.Io,
mutex: std.Io.Mutex = .init,
used: usize = 0,
peak: usize = 0,
failures: usize = 0,

const minimum_block = 256;
const block_shift = 8;
const maximum_alignment: Alignment = .fromByteUnits(4096);

pub const Error = error{InvalidMemoryBudget} || Allocator.Error;
pub const Stats = struct {
    capacity: usize,
    reserved: usize,
    used: usize,
    peak: usize,
    failures: usize,
};

/// Reserves capacity plus fixed tree bookkeeping in one backing allocation.
/// capacity must be a power of two. The returned value must remain at its
/// final address once allocator() has been called.
pub fn init(backing: Allocator, io: std.Io, capacity: usize) Error!MemoryBudget {
    const total = try reservationSize(capacity);
    const leaves = capacity / minimum_block;
    const reservation = try backing.alignedAlloc(u8, maximum_alignment, total);
    errdefer backing.free(reservation);
    const tree = reservation[capacity..];
    @memset(tree, 0);
    const order: u8 = @intCast(@ctz(leaves) + 1);
    tree[1] = order;
    std.debug.assert(tree.len == leaves * 2);
    std.debug.assert(order < @bitSizeOf(usize));
    return .{
        .reservation = reservation,
        .storage = reservation[0..capacity],
        .tree = tree,
        .root_order = order,
        .io = io,
    };
}

/// Exact requested backing size, also used by target-side budget accounting.
pub fn reservationSize(capacity: usize) error{InvalidMemoryBudget}!usize {
    if (capacity < minimum_block or !std.math.isPowerOfTwo(capacity))
        return error.InvalidMemoryBudget;
    const leaves = capacity / minimum_block;
    const metadata = std.math.mul(usize, leaves, 2) catch return error.InvalidMemoryBudget;
    return std.math.add(usize, capacity, metadata) catch error.InvalidMemoryBudget;
}

/// All users, including foreign callbacks, must stop before the reservation
/// is released. Individual allocations need not survive budget teardown.
pub fn deinit(self: *MemoryBudget, backing: Allocator) void {
    backing.free(self.reservation);
    self.* = undefined;
}

/// Thread-safe. Returned memory belongs to this budget, never the backing
/// allocator. Alignments above 4096 are unsupported and fail without fallback.
pub fn allocator(self: *MemoryBudget) Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

pub fn stats(self: *MemoryBudget) Stats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return .{
        .capacity = self.storage.len,
        .reserved = self.reservation.len,
        .used = self.used,
        .peak = self.peak,
        .failures = self.failures,
    };
}

/// Exhaustion is latched so a foreign API cannot silently discard an OOM.
pub fn check(self: *MemoryBudget) error{MemoryBudgetExceeded}!void {
    if (self.stats().failures != 0) return error.MemoryBudgetExceeded;
}

fn alloc(raw: *anyopaque, length: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const self: *MemoryBudget = @ptrCast(@alignCast(raw));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const order = self.orderFor(length, alignment) orelse {
        self.failures += 1;
        return null;
    };
    if (self.tree[1] < order) {
        self.failures += 1;
        return null;
    }
    const node = self.take(order);
    const size = blockSize(order);
    const offset = (node - self.storage.len / size) * size;
    std.debug.assert(offset + size <= self.storage.len);
    self.used += size;
    self.peak = @max(self.peak, self.used);
    std.debug.assert(self.used <= self.storage.len);
    return self.storage.ptr + offset;
}

fn resize(raw: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    const self: *MemoryBudget = @ptrCast(@alignCast(raw));
    const old_order = self.orderFor(memory.len, alignment) orelse unreachable;
    const new_order = self.orderFor(new_len, alignment) orelse return false;
    // A changed order needs a different allocation. Generic realloc copies
    // first and frees only after success, preserving the old block on OOM.
    return old_order == new_order;
}

fn remap(raw: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(raw, memory, alignment, new_len, ra)) memory.ptr else null;
}

fn free(raw: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const self: *MemoryBudget = @ptrCast(@alignCast(raw));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const order = self.orderFor(memory.len, alignment) orelse unreachable;
    const size = blockSize(order);
    const offset = @intFromPtr(memory.ptr) - @intFromPtr(self.storage.ptr);
    std.debug.assert(offset < self.storage.len and offset % size == 0);
    const node = self.storage.len / size + offset / size;
    std.debug.assert(self.tree[node] == 0);
    std.debug.assert(self.used >= size);
    self.tree[node] = order;
    self.updateParents(node, order);
    self.used -= size;
}

fn orderFor(self: *const MemoryBudget, length: usize, alignment: Alignment) ?u8 {
    if (length == 0 or length > self.storage.len or alignment.compare(.gt, maximum_alignment))
        return null;
    const required = @max(length, alignment.toByteUnits(), minimum_block);
    if (required > self.storage.len) return null;
    const bits = @bitSizeOf(usize) - @clz(required - 1);
    return @intCast(bits - block_shift + 1);
}

fn take(self: *MemoryBudget, wanted: u8) usize {
    std.debug.assert(self.tree[1] >= wanted);
    var node: usize = 1;
    var order = self.root_order;
    while (order > wanted) : (order -= 1) {
        if (self.tree[node] == order) {
            self.tree[node * 2] = order - 1;
            self.tree[node * 2 + 1] = order - 1;
        }
        node *= 2;
        if (self.tree[node] < wanted) node += 1;
    }
    std.debug.assert(self.tree[node] == wanted);
    self.tree[node] = 0;
    self.updateParents(node, wanted);
    return node;
}

fn updateParents(self: *MemoryBudget, child: usize, child_order: u8) void {
    var node = child;
    var order = child_order;
    while (node > 1) : (order += 1) {
        node /= 2;
        const left = self.tree[node * 2];
        const right = self.tree[node * 2 + 1];
        self.tree[node] = if (left == order and right == order) order + 1 else @max(left, right);
    }
    std.debug.assert(order == self.root_order);
    std.debug.assert(self.tree[1] <= self.root_order);
}

fn blockSize(order: u8) usize {
    std.debug.assert(order > 0);
    std.debug.assert(order + block_shift - 1 < @bitSizeOf(usize));
    return @as(usize, 1) << @intCast(order + block_shift - 1);
}

test "memory budget reuses non-last frees and coalesces the whole reservation" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var budget = try init(backing.allocator(), std.testing.io, 4096);
    defer budget.deinit(backing.allocator());
    const a = budget.allocator();
    var blocks: [16][]u8 = undefined;
    for (&blocks) |*block| block.* = try a.alloc(u8, 128);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    a.free(blocks[3]);
    const reused = try a.alloc(u8, 200);
    try std.testing.expectEqual(@intFromPtr(blocks[3].ptr), @intFromPtr(reused.ptr));
    a.free(reused);
    for (blocks, 0..) |block, i| if (i != 3) a.free(block);
    const whole = try a.alloc(u8, 4096);
    a.free(whole);
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
    try std.testing.expectEqual(@as(usize, 4096), budget.stats().peak);
    try std.testing.expectEqual(@as(usize, 1), backing.allocations);
    try std.testing.expectError(error.MemoryBudgetExceeded, budget.check());
}

test "memory budget keeps disjoint data through mixed allocation lifetimes" {
    var budget = try init(std.testing.allocator, std.testing.io, 65536);
    defer budget.deinit(std.testing.allocator);
    const a = budget.allocator();
    var slots: [64]?[]u8 = @splat(null);
    var random: u64 = 7;
    for (0..4000) |_| {
        random = random *% 6364136223846793005 +% 1442695040888963407;
        const index: usize = @intCast((random >> 32) % slots.len);
        if (slots[index]) |bytes| {
            for (bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
            a.free(bytes);
            slots[index] = null;
        } else {
            const length: usize = @intCast((random >> 16) % 4096 + 1);
            const bytes = a.alloc(u8, length) catch continue;
            @memset(bytes, @intCast(index));
            slots[index] = bytes;
        }
    }
    for (slots, 0..) |slot, i| if (slot) |bytes| {
        for (bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(i)), byte);
        a.free(bytes);
    };
    const whole = try a.alloc(u8, 65536);
    a.free(whole);
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
}

test "memory budget preserves allocations when a growing realloc fails" {
    var budget = try init(std.testing.allocator, std.testing.io, 4096);
    defer budget.deinit(std.testing.allocator);
    const a = budget.allocator();
    const first = try a.alignedAlloc(u8, .@"64", 1500);
    @memset(first, 0x5a);
    const second = try a.alloc(u8, 2048);
    try std.testing.expectError(error.OutOfMemory, a.realloc(first, 3000));
    for (first) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    a.free(second);
    const grown = try a.realloc(first, 1800);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(grown.ptr));
    a.free(grown);
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
}

test "memory budget validates capacities and accounts for bookkeeping" {
    try std.testing.expectError(error.InvalidMemoryBudget, init(std.testing.allocator, std.testing.io, 0));
    try std.testing.expectError(error.InvalidMemoryBudget, init(std.testing.allocator, std.testing.io, 300));
    var budget = try init(std.testing.allocator, std.testing.io, 4096);
    defer budget.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4096 + 32), budget.stats().reserved);
    const memory = try budget.allocator().alignedAlloc(u8, .fromByteUnits(4096), 1);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(memory.ptr) % 4096);
    budget.allocator().free(memory);
}
