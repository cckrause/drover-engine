//! Mixing PCM for the output device. Volume and pan arrive already resolved
//! by audio/engine.zig; this module only presents samples.
//!
//! Volume and pan are in hundredths of a decibel, and pan attenuates one
//! channel and combines with volume. That is the behaviour of the sound API
//! the game was written against, not a curve invented here.

const std = @import("std");

pub const Buffer = struct {
    samples: []const f32 = &.{},
    cursor: usize = 0,
    loop: bool = false,
    playing: bool = false,
    complete: bool = false,
    gain: [2]f32 = .{ 1, 1 },

    pub fn mix(self: *Buffer, output: []f32) void {
        if (!self.playing or self.complete or self.samples.len == 0) return;

        var i: usize = 0;

        while (i + 1 < output.len) : (i += 2) {
            if (self.cursor == self.samples.len) {
                if (self.loop) self.cursor = 0 else {
                    self.complete = true;
                    return;
                }
            }

            output[i] += self.samples[self.cursor] * self.gain[0];
            output[i + 1] += self.samples[self.cursor + 1] * self.gain[1];
            self.cursor += 2;
        }

        if (!self.loop and self.cursor == self.samples.len) self.complete = true;
    }
};

pub fn gains(volume_db: i32, pan_db: i32) [2]f32 {
    return .{ gain(volume_db - @max(0, pan_db)), gain(volume_db + @min(0, pan_db)) };
}

pub fn finish(output: []f32) void {
    for (output) |*value| value.* = std.math.clamp(value.*, -1, 1);
}

fn gain(db: i32) f32 {
    if (db <= -10000) return 0;

    return std.math.pow(f32, 10, @as(f32, @floatFromInt(db)) / 2000);
}

test "host buffers preserve loop boundaries, pause cursors and completion" {
    var buffer: Buffer = .{ .samples = &.{ 0.5, -0.5, 1, -1 }, .playing = true, .loop = true };
    var output = [_]f32{0} ** 6;

    buffer.mix(&output);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, -0.5, 1, -1, 0.5, -0.5 }, &output);
    buffer.playing = false;
    buffer.mix(&output);
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);

    buffer.playing = true;
    buffer.loop = false;

    @memset(&output, 0);
    buffer.mix(&output);

    try std.testing.expectEqualSlices(f32, &.{ 1, -1, 0, 0, 0, 0 }, &output);
    try std.testing.expect(buffer.complete);
}

test "host gains combine decibel pan and volume and clip after summation" {
    try std.testing.expectEqualSlices(f32, &.{ 1, 1 }, &gains(0, 0));
    try std.testing.expectEqualSlices(f32, &.{ 0, 1 }, &gains(0, 10000));

    const attenuated = gains(-2000, -2000);

    try std.testing.expectApproxEqAbs(@as(f32, 0.1), attenuated[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), attenuated[1], 0.000001);

    var values = [_]f32{ 2, -2, 0.5, -0.5 };
    finish(&values);
    try std.testing.expectEqualSlices(f32, &.{ 1, -1, 0.5, -0.5 }, &values);
}
