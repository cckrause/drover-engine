//! Helpers for flag words kept as packed structs of named bools.
//!
//! A single flag reads and writes as a plain field (`sector.flags.rail`).
//! These helpers cover the rest: testing or changing several flags at once,
//! and turning a flag set into its raw word and back where files, saves and
//! network packets carry it.

const std = @import("std");

pub fn word(flags: anytype) Word(@TypeOf(flags)) {
    return @bitCast(flags);
}

pub fn from(comptime Flags: type, value: Word(Flags)) Flags {
    return @bitCast(value);
}

pub fn setWord(flags: anytype, value: Word(@TypeOf(flags.*))) void {
    flags.* = @bitCast(value);
}

pub fn any(flags: anytype, wanted: @TypeOf(flags)) bool {
    return word(flags) & word(wanted) != 0;
}

pub fn all(flags: anytype, wanted: @TypeOf(flags)) bool {
    return word(flags) & word(wanted) == word(wanted);
}

pub fn with(flags: anytype, added: @TypeOf(flags)) @TypeOf(flags) {
    return @bitCast(word(flags) | word(added));
}

pub fn without(flags: anytype, removed: @TypeOf(flags)) @TypeOf(flags) {
    return @bitCast(word(flags) & ~word(removed));
}

/// Only the flags of `flags` that are also set in `kept`.
pub fn only(flags: anytype, kept: @TypeOf(flags)) @TypeOf(flags) {
    return @bitCast(word(flags) & word(kept));
}

/// `flags`, but the flags marked in `taken` come from `source`.
pub fn merge(flags: anytype, source: @TypeOf(flags), taken: @TypeOf(flags)) @TypeOf(flags) {
    return @bitCast((word(flags) & ~word(taken)) | (word(source) & word(taken)));
}

fn Word(comptime Flags: type) type {
    const info = @typeInfo(Flags);

    if (info != .@"struct" or info.@"struct".layout != .@"packed") @compileError(
        "flag sets are packed structs",
    );

    return info.@"struct".backing_integer.?;
}

const Example = packed struct(u8) {
    a: bool = false,
    b: bool = false,
    c: bool = false,
    unused: u5 = 0,
};

test "flag set helpers" {
    const ab = Example{ .a = true, .b = true };

    try std.testing.expectEqual(@as(u8, 3), word(ab));
    try std.testing.expectEqual(ab, from(Example, 3));
    try std.testing.expect(any(ab, .{ .b = true, .c = true }));
    try std.testing.expect(!any(ab, .{ .c = true }));
    try std.testing.expect(all(ab, .{ .a = true, .b = true }));
    try std.testing.expect(!all(ab, .{ .a = true, .c = true }));
    try std.testing.expectEqual(
        Example{ .a = true, .b = true, .c = true },
        with(ab, .{ .c = true }),
    );

    try std.testing.expectEqual(Example{ .b = true }, without(ab, .{ .a = true }));
    try std.testing.expectEqual(Example{ .b = true }, only(ab, .{ .b = true, .c = true }));
    try std.testing.expectEqual(
        Example{ .a = true, .c = true },
        merge(ab, .{ .c = true }, .{ .b = true, .c = true }),
    );
}
