//! Putting a decoded movie frame on screen: the scaling and the palette.
//!
//! Black and white are installed at the first and last palette entries and
//! are never updated by a frame's own palette. Source cropping is kept
//! through the scaled copy.

const std = @import("std");

pub const Bitmap = struct {
    pixels: []const u8,
    width: u16,
    height: u16,
    x: i16 = 0,
    y: i16 = 0,
};

pub const Rect = struct { x: i32 = 0, y: i32 = 0, width: i32, height: i32 };

pub const Surface = struct { pixels: []u8, stride: usize, height: usize, clip: Rect };

pub fn screenPalette(colors: [256]u32) [256]u32 {
    var result = colors;
    result[0] = 0;
    result[255] = 0xffffff;

    return result;
}

pub const BlitMode = packed struct(u32) {
    /// Picks the doubling below from the clip size.
    fit: bool = false,
    double_height: bool = false,
    double_size: bool = false,
    unused_3: u29 = 0,
};

pub fn blit(source: Bitmap, destination: Surface, flags: BlitMode) !void {
    const clip = destination.clip;
    if (source.width == 0 or source.height == 0) return;
    if (source.width > 32767 or source.height > 32767 or
        destination.stride == 0 or destination.height == 0 or
        destination.stride > std.math.maxInt(i32) or destination.height > std.math.maxInt(i32) or
        destination.pixels.len / destination.stride < destination.height or
        clip.x < 0 or clip.y < 0 or clip.width < 0 or clip.height < 0 or
        @as(i64, clip.x) + clip.width > destination.stride or
        @as(i64, clip.y) + clip.height > destination.height)
        return error.InvalidMovieSurface;

    var mode = flags;

    if (mode.fit) {
        mode.double_height = false;
        mode.double_size = false;
        if (@divTrunc(clip.width, 2) < source.width) {
            if (source.height < clip.height) mode.double_height = true;
        } else mode.double_size = true;
    }

    const scale_y: i32 = if (mode.double_height or mode.double_size) 2 else 1;
    const scale_x: i32 = if (mode.double_size) 2 else 1;
    var x: i32 = source.x;
    var y: i32 = source.y;
    var width: i32 = short(@as(i32, source.width) * scale_x);
    var height: i32 = short(@as(i32, source.height) * scale_y);

    if (x < clip.x) {
        width = short(width - short(clip.x) + x);
        x = short(clip.x);
    }

    if (@as(i64, clip.x) + clip.width < @as(i64, width) + x)
        width = short(short(clip.width) - x + short(clip.x));

    if (y < clip.y) {
        height = short(height - short(clip.y) + y);
        y = short(clip.y);
    }

    if (@as(i64, clip.y) + clip.height < @as(i64, height) + y)
        height = short(short(clip.y) - y + short(clip.height));

    const rows = short(@divTrunc(height, scale_y));
    const aligned_x = x & ~@as(i32, 7);
    const columns = (@divTrunc(width, scale_x) + x + 7) & ~@as(i32, 7);
    const count = columns - aligned_x;
    if (rows < 0 or count < 0 or aligned_x < 0 or y < 0) return error.InvalidMovieBlit;
    if (rows == 0 or count == 0) return;

    const src_start = @as(i64, scale_y) * source.width * y + scale_x * aligned_x;
    const dst_start = @as(
        i64,
        scale_y,
    ) * @as(i64, @intCast(destination.stride)) * y + scale_x * aligned_x;

    const src_end = src_start + @as(i64, rows - 1) * source.width + count;
    const dst_end = dst_start + (@as(
        i64,
        rows,
    ) * scale_y - 1) * @as(i64, @intCast(destination.stride)) + count * scale_x;

    if (src_start < 0 or src_end > source.pixels.len or dst_start < 0 or dst_end > destination.pixels.len)
        return error.InvalidMovieBlit;

    var src: usize = @intCast(src_start);
    var dst: usize = @intCast(dst_start);
    var row: i32 = 0;

    while (row < rows) : (row += 1) {
        var column: usize = 0;

        while (column < count) : (column += 1) {
            const value = source.pixels[src + column];
            const out = dst + column * @as(usize, @intCast(scale_x));

            destination.pixels[out] = value;

            if (scale_x == 2) destination.pixels[out + 1] = value;

            if (scale_y == 2) {
                destination.pixels[out + destination.stride] = value;
                if (scale_x == 2) destination.pixels[out + destination.stride + 1] = value;
            }
        }

        src += source.width;
        dst += destination.stride * @as(usize, @intCast(scale_y));
    }
}

fn short(value: i32) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(u32, @bitCast(value))))));
}

test "movie copy rejects out of range padding accesses" {
    const source = [_]u8{1} ** 15;
    var output = [_]u8{0} ** 32;

    try std.testing.expectError(
        error.InvalidMovieBlit,
        blit(
            .{ .pixels = &source, .width = 15, .height = 1 },
            .{
                .pixels = &output,
                .stride = 32,
                .height = 1,
                .clip = .{ .width = 32, .height = 1 },
            },
            .{},
        ),
    );
}

test "reference CPU scaling and palette references" {
    const allocator = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/movie-playback-reference.json",
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(data);
    const BlitCase = struct {
        width: u16,
        height: u16,
        x: i16,
        y: i16,
        dest_width: usize,
        dest_height: usize,
        clip: [4]i32,
        flags: u32,
        sha256: []const u8,
    };

    const PaletteCase = struct { name: []const u8, colors: [256]u32, result: [256]u32 };
    const parsed = try std.json.parseFromSlice(
        struct { blits: []BlitCase, palettes: []PaletteCase },
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );

    defer parsed.deinit();
    const source = try allocator.alloc(u8, 65536);
    defer allocator.free(source);

    for (source, 0..) |*pixel, i| pixel.* = @truncate(i * 37 + (i >> 5) * 11 + 7);

    const output = try allocator.alloc(u8, 65536);
    defer allocator.free(output);

    for (parsed.value.blits) |reference| {
        @memset(output, 197);
        try blit(.{
            .pixels = source,
            .width = reference.width,
            .height = reference.height,
            .x = reference.x,
            .y = reference.y,
        }, .{
            .pixels = output,
            .stride = reference.dest_width,
            .height = reference.dest_height,
            .clip = .{
                .x = reference.clip[0],
                .y = reference.clip[1],
                .width = reference.clip[2],
                .height = reference.clip[3],
            },
        }, @bitCast(reference.flags));

        var actual: [32]u8 = undefined;
        var expected: [32]u8 = undefined;

        std.crypto.hash.sha2.Sha256.hash(
            output[0 .. reference.dest_width * reference.dest_height],
            &actual,
            .{},
        );

        _ = try std.fmt.hexToBytes(&expected, reference.sha256);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }

    for (parsed.value.palettes) |reference| {
        const actual = screenPalette(reference.colors);
        try std.testing.expectEqualSlices(u32, &reference.result, &actual);
    }
}
