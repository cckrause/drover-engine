//! A quicksort whose order for equal keys is part of its contract.
//!
//! Scoreboards and other ranked lists are sorted with it, and ties must come
//! out in one definite order, so the algorithm itself is fixed: the middle
//! element becomes the pivot by swapping it to the front, ranges of up to
//! eight elements are selection-sorted from the back, and the smaller side
//! is pushed on a 30-entry stack. Element indices stand in for pointers and
//! all comparisons are unsigned. Do not swap this for another sort.

const std = @import("std");

pub fn sort(comptime T: type, items: []T, context: anytype, comptime compare: fn (@TypeOf(context), *const T, *const T) i32) void {
    if (items.len < 2) return;
    var lo_stack: [30]usize = undefined;
    var hi_stack: [30]usize = undefined;
    var depth: usize = 0;
    var lo: usize = 0;
    var hi: usize = items.len - 1;
    while (true) {
        const size = hi - lo + 1;
        if (size <= 8) {
            shortsort(T, items, lo, hi, context, compare);
        } else {
            swap(T, items, lo + size / 2, lo);
            var loguy = lo;
            var higuy = hi + 1;
            while (true) {
                loguy += 1;
                while (loguy <= hi and compare(context, &items[loguy], &items[lo]) <= 0) loguy += 1;
                higuy -= 1;
                while (higuy > lo and compare(context, &items[higuy], &items[lo]) >= 0) higuy -= 1;
                if (higuy < loguy) break;
                swap(T, items, loguy, higuy);
            }
            swap(T, items, lo, higuy);
            const left: isize = @intCast(higuy - lo);
            const right = @as(isize, @intCast(hi)) - @as(isize, @intCast(loguy));
            if (left > right) {
                if (lo + 1 < higuy) {
                    lo_stack[depth] = lo;
                    hi_stack[depth] = higuy - 1;
                    depth += 1;
                }
                if (loguy < hi) {
                    lo = loguy;
                    continue;
                }
            } else {
                if (loguy < hi) {
                    lo_stack[depth] = loguy;
                    hi_stack[depth] = hi;
                    depth += 1;
                }
                if (lo + 1 < higuy) {
                    hi = higuy - 1;
                    continue;
                }
            }
        }
        if (depth == 0) return;
        depth -= 1;
        lo = lo_stack[depth];
        hi = hi_stack[depth];
    }
}

fn swap(comptime T: type, items: []T, a: usize, b: usize) void {
    if (a == b) return;
    std.mem.swap(T, &items[a], &items[b]);
}

fn shortsort(comptime T: type, items: []T, lo: usize, high: usize, context: anytype, comptime compare: fn (@TypeOf(context), *const T, *const T) i32) void {
    var hi = high;
    while (hi > lo) {
        var max = lo;
        var p = lo + 1;
        while (p <= hi) : (p += 1) {
            if (compare(context, &items[p], &items[max]) > 0) max = p;
        }
        swap(T, items, max, hi);
        hi -= 1;
    }
}
