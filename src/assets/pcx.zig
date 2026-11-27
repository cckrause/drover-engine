//! PCX images: the indexed, single-plane 8-bit form the menus use.
//!
//! The row length in the header is ignored; a run that crosses a row
//! boundary is cut there rather than carried into the next row. The 768-byte
//! palette is read from the end of the file and its marker byte is accepted
//! whatever it says. Images are refused before decoding when they are larger
//! than any the game ships or their encoded bytes cannot fill them.

const std = @import("std");

/// The largest image in the shipped archives is 640x480.
pub const max_pixels = 640 * 480;
/// One encoded run covers at most this many pixels.
const max_run = 0x3f;

pub const Image = struct {
    width: usize,
    height: usize,
    pixels: []u8,
    palette: [256]u32,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 128 + 769) return error.TruncatedPcx;
    if (data[0] != 10) return error.InvalidPcx;

    switch (data[1]) {
        0, 2, 3, 4, 5 => {},
        else => return error.UnsupportedPcxVersion,
    }

    if (data[3] != 8 or data[65] != 1) return error.UnsupportedPcxFormat;

    const x_min = read16(data, 4);
    const y_min = read16(data, 6);
    const x_max = read16(data, 8);
    const y_max = read16(data, 10);
    if (x_max < x_min or y_max < y_min) return error.InvalidPcxDimensions;

    const width = @as(usize, x_max) - x_min + 1;
    const height = @as(usize, y_max) - y_min + 1;
    if (@as(u64, width) * height > max_pixels) return error.PcxTooLarge;
    // Every row needs at least one encoded byte per run, and the palette
    // takes the last 769 bytes.
    if (height * ((width + max_run - 1) / max_run) > data.len - 128 - 769)
        return error.TruncatedPcx;

    const pixels = try allocator.alloc(u8, width * height);
    errdefer allocator.free(pixels);
    var source: usize = 128;
    const palette_start = data.len - 769;

    for (0..height) |y| {
        var x: usize = 0;

        while (x < width) {
            if (source >= palette_start) return error.TruncatedPcx;

            var value = data[source];

            source += 1;
            var count: usize = 1;

            if (value & 0xc0 == 0xc0) {
                count = value & 0x3f;
                if (source >= palette_start) return error.TruncatedPcx;
                value = data[source];
                source += 1;
            }

            count = @min(count, width - x);
            @memset(pixels[y * width + x ..][0..count], value);
            x += count;
        }
    }

    var palette: [256]u32 = undefined;

    for (&palette, 0..) |*color, index| {
        const rgb = data[palette_start + 1 + index * 3 ..][0..3];
        color.* = @as(u32, rgb[0]) | @as(u32, rgb[1]) << 8 | @as(u32, rgb[2]) << 16;
    }

    return .{ .width = width, .height = height, .pixels = pixels, .palette = palette };
}

fn read16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

test "row limits discard run excess and ignore bytesPerLine" {
    var data = [_]u8{0} ** (128 + 4 + 769);
    @memcpy(data[0..4], &[_]u8{ 10, 5, 1, 8 });

    std.mem.writeInt(u16, data[8..10], 2, .little);
    std.mem.writeInt(u16, data[10..12], 1, .little);

    data[65] = 1;
    std.mem.writeInt(u16, data[66..68], 4, .little);
    @memcpy(data[128..132], &[_]u8{ 0xc4, 7, 0xc3, 9 });
    data[132] = 0x99;
    @memcpy(data[133..136], &[_]u8{ 0x12, 0x34, 0x56 });

    const image = try decode(std.testing.allocator, &data);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), image.width);
    try std.testing.expectEqual(@as(usize, 2), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 7, 7, 7, 9, 9, 9 }, image.pixels);
    try std.testing.expectEqual(@as(u32, 0x563412), image.palette[0]);
}

test "images larger than the shipped ones or too short to fill are refused first" {
    var data = [_]u8{0} ** (128 + 4 + 769);
    @memcpy(data[0..4], &[_]u8{ 10, 5, 1, 8 });
    data[65] = 1;

    std.mem.writeInt(u16, data[8..10], 0xffff, .little);
    std.mem.writeInt(u16, data[10..12], 0xffff, .little);

    try std.testing.expectError(error.PcxTooLarge, decode(std.testing.failing_allocator, &data));

    std.mem.writeInt(u16, data[8..10], 639, .little);
    std.mem.writeInt(u16, data[10..12], 479, .little);

    try std.testing.expectError(error.TruncatedPcx, decode(std.testing.failing_allocator, &data));
    std.mem.writeInt(u16, data[8..10], 640, .little);
    try std.testing.expectError(error.PcxTooLarge, decode(std.testing.failing_allocator, &data));
}

test "malformed runs cannot consume palette bytes and unsupported planes fail" {
    var data = [_]u8{0} ** (128 + 1 + 769);
    @memcpy(data[0..4], &[_]u8{ 10, 5, 1, 8 });

    data[65] = 1;
    data[128] = 0xc1;

    try std.testing.expectError(error.TruncatedPcx, decode(std.testing.allocator, &data));
    data[65] = 3;
    try std.testing.expectError(error.UnsupportedPcxFormat, decode(std.testing.allocator, &data));
}
