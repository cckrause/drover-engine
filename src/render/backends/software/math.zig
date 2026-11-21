//! Floating-point setup for the software renderer: 24-bit precision,
//! rounding toward zero, for the duration of a frame.
//!
//! The renderer's arithmetic depends on this mode, so it is set and restored
//! around the frame and kept local to this backend rather than changing the
//! host's floating-point state.

const std = @import("std");

pub fn towardZero(value: f64) f32 {
    const nearest: f32 = @floatCast(value);
    if (@abs(@as(f64, nearest)) > @abs(value)) {
        const bits: u32 = @bitCast(nearest);
        return @bitCast(bits - 1);
    }
    return nearest;
}

pub fn add(a: f32, b: f32) f32 {
    return towardZero(@as(f64, a) + @as(f64, b));
}

pub fn sub(a: f32, b: f32) f32 {
    return towardZero(@as(f64, a) - @as(f64, b));
}

pub fn mul(a: f32, b: f32) f32 {
    return towardZero(@as(f64, a) * @as(f64, b));
}

pub fn div(a: f32, b: f32) f32 {
    return towardZero(@as(f64, a) / @as(f64, b));
}

pub fn integer(value: f32) i32 {
    if (!std.math.isFinite(value) or value >= 2147483648.0 or value < -2147483648.0)
        return std.math.minInt(i32);
    return @intFromFloat(value);
}

pub fn fixed(value: f32) i32 {
    return integer(mul(value, 65536.0));
}

pub fn unsignedBits(value: f32) u32 {
    return @bitCast(value);
}

pub fn signedBits(value: f32) i32 {
    return @bitCast(value);
}

test "render control word truncates arithmetic and FISTP independently of host rounding" {
    try std.testing.expectEqual(@as(u32, 0x3f800000), unsignedBits(add(1.0, 0x1.8p-24)));
    try std.testing.expectEqual(@as(u32, 0xbf800000), unsignedBits(sub(-1.0, 0x1.8p-24)));
    try std.testing.expectEqual(@as(u32, 0x3eaaaaaa), unsignedBits(div(1.0, 3.0)));
    try std.testing.expectEqual(@as(i32, -1), integer(-1.9));
    try std.testing.expectEqual(std.math.minInt(i32), integer(std.math.inf(f32)));
}
