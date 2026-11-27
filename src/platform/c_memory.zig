//! C allocation entry points for the startup reservation. Installation and
//! removal happen with all foreign users stopped; calls in between are safe
//! on host threads through the budget's allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

var active: ?Allocator = null;
var failed: std.atomic.Value(bool) = .init(false);
var outstanding: std.atomic.Value(usize) = .init(0);
const header_bytes = 16;
const alignment: std.mem.Alignment = .@"16";

pub fn install(allocator: Allocator) error{ForeignMemoryAlreadyInstalled}!void {
    if (active != null) return error.ForeignMemoryAlreadyInstalled;

    std.debug.assert(outstanding.load(.acquire) == 0);

    active = allocator;
    failed.store(false, .release);
}

pub fn uninstall() void {
    std.debug.assert(active != null);
    std.debug.assert(outstanding.load(.acquire) == 0);
    active = null;
}

pub fn installed() bool {
    return active != null;
}

pub fn count() usize {
    return outstanding.load(.acquire);
}

pub fn exhausted() bool {
    return failed.load(.acquire);
}

pub fn noMemory() callconv(.c) void {
    failed.store(true, .release);
}

pub fn malloc(length: usize) callconv(.c) ?*anyopaque {
    const total = std.math.add(usize, length, header_bytes) catch {
        noMemory();
        return null;
    };
    const bytes = active.?.alignedAlloc(u8, alignment, total) catch {
        noMemory();
        return null;
    };

    std.mem.bytesAsValue(usize, bytes[0..@sizeOf(usize)]).* = total;
    _ = outstanding.fetchAdd(1, .release);

    return bytes.ptr + header_bytes;
}

pub fn calloc(count_items: usize, size: usize) callconv(.c) ?*anyopaque {
    const length = std.math.mul(usize, count_items, size) catch {
        noMemory();
        return null;
    };
    const memory = malloc(length) orelse return null;

    @memset(@as([*]u8, @ptrCast(memory))[0..length], 0);

    return memory;
}

pub fn realloc(memory: ?*anyopaque, length: usize) callconv(.c) ?*anyopaque {
    const pointer = memory orelse return malloc(length);

    if (length == 0) {
        free(pointer);
        return null;
    }

    const total = std.math.add(usize, length, header_bytes) catch {
        noMemory();
        return null;
    };
    const old = allocation(pointer);
    const bytes = active.?.realloc(old, total) catch {
        noMemory();
        return null;
    };

    std.mem.bytesAsValue(usize, bytes[0..@sizeOf(usize)]).* = total;

    return bytes.ptr + header_bytes;
}

pub fn free(memory: ?*anyopaque) callconv(.c) void {
    const pointer = memory orelse return;

    active.?.free(allocation(pointer));

    const previous = outstanding.fetchSub(1, .release);
    std.debug.assert(previous > 0);
}

fn allocation(memory: *anyopaque) []align(16) u8 {
    const start: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(memory)) - header_bytes);
    const length = std.mem.bytesAsValue(usize, start[0..@sizeOf(usize)]).*;

    std.debug.assert(length >= header_bytes);
    std.debug.assert(active != null);

    return start[0..length];
}

test "memory budget C callbacks preserve alignment and old data on exhaustion" {
    var budget = try @import("MemoryBudget.zig").init(std.testing.allocator, std.testing.io, 4096);
    defer budget.deinit(std.testing.allocator);
    try install(budget.allocator());
    defer uninstall();
    const first = calloc(7, 31).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(first) % 16);
    const bytes = @as([*]u8, @ptrCast(first))[0..217];
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    @memset(bytes, 0x37);
    const second = malloc(1500).?;
    try std.testing.expect(realloc(first, 4096) == null);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0x37), byte);
    free(second);
    free(first);
    free(null);
    try std.testing.expectEqual(@as(usize, 0), count());
    try std.testing.expect(exhausted());
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
}
