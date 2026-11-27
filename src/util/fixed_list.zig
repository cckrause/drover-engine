//! A list that never grows. It fills a buffer its owner hands it and refuses
//! an item past the end of that buffer with the list's own error, so a burst
//! bigger than its size is reported instead of taking more memory.
//!
//! `items` is the filled part of the buffer and reads like `std.ArrayList`.
//! The list borrows the buffer: the owner keeps it alive and in place for as
//! long as the list is used.

const std = @import("std");

/// `Full` is an error set with exactly one error, returned when the buffer
/// is full.
pub fn FixedList(comptime T: type, comptime Full: type) type {
    const full = fullError(Full);

    return struct {
        const Self = @This();

        items: []T,
        capacity: usize,

        pub fn init(buffer: []T) Self {
            return .{ .items = buffer[0..0], .capacity = buffer.len };
        }

        pub fn append(self: *Self, item: T) Full!void {
            std.debug.assert(self.items.len <= self.capacity);
            if (self.items.len == self.capacity) return full;
            self.items.len += 1;
            self.items[self.items.len - 1] = item;
        }

        /// Adds every value or none of them.
        pub fn appendSlice(self: *Self, values: []const T) Full!void {
            std.debug.assert(self.items.len <= self.capacity);
            if (values.len > self.capacity - self.items.len) return full;

            const start = self.items.len;
            self.items.len += values.len;
            @memcpy(self.items[start..], values);
        }

        /// Puts `item` at `index` and moves the later items up by one.
        pub fn insert(self: *Self, index: usize, item: T) Full!void {
            std.debug.assert(index <= self.items.len);
            if (self.items.len == self.capacity) return full;

            self.items.len += 1;
            std.mem.copyBackwards(
                T,
                self.items[index + 1 ..],
                self.items[index .. self.items.len - 1],
            );

            self.items[index] = item;
        }

        /// Removes the item at `index` and moves the later items down by one.
        pub fn orderedRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.items.len);
            const removed = self.items[index];
            std.mem.copyForwards(
                T,
                self.items[index .. self.items.len - 1],
                self.items[index + 1 ..],
            );

            self.items.len -= 1;

            return removed;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.items.len = 0;
        }

        pub fn shrinkRetainingCapacity(self: *Self, len: usize) void {
            std.debug.assert(len <= self.items.len);
            self.items.len = len;
        }
    };
}

fn fullError(comptime Full: type) Full {
    const errors = @typeInfo(
        Full,
    ).error_set orelse @compileError("FixedList needs a named error set");

    if (errors.len != 1) @compileError("FixedList needs an error set with exactly one error");

    return @field(Full, errors[0].name);
}

const TestFull = error{TestListFull};

test "a fixed list refuses an item past its buffer and keeps what it had" {
    var buffer: [2]u8 = undefined;
    var list = FixedList(u8, TestFull).init(&buffer);

    try list.append(1);

    try std.testing.expectError(error.TestListFull, list.appendSlice(&.{ 2, 3 }));
    try std.testing.expectEqualSlices(u8, &.{1}, list.items);

    try list.append(2);

    try std.testing.expectError(error.TestListFull, list.append(3));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, list.items);
    try std.testing.expectError(error.TestListFull, list.insert(0, 3));

    list.shrinkRetainingCapacity(1);
    try list.appendSlice(&.{4});

    try std.testing.expectEqualSlices(u8, &.{ 1, 4 }, list.items);

    list.shrinkRetainingCapacity(1);
    try list.insert(0, 5);

    try std.testing.expectEqualSlices(u8, &.{ 5, 1 }, list.items);
    try std.testing.expectEqual(@as(u8, 5), list.orderedRemove(0));
    try std.testing.expectEqualSlices(u8, &.{1}, list.items);

    list.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}
