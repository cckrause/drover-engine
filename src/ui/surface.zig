//! An 8-bit drawing surface - pixels, pitch and height - and the handful of
//! 2D primitives the menus and dialogs draw with.
//!
//! One quirk to keep: a filled box drawn without a clip rectangle, running
//! past the right edge, loses height rather than width. Blits draw only
//! where they fall inside the clip rectangle, which defaults to the whole
//! surface. The nearest-colour search weighs the squared RGB difference plus
//! the squared difference of the sum of the components.

const std = @import("std");

pub const Surface = struct {
    pixels: []u8,
    pitch: i32,
    height: i32,

    pub fn init(pixels: []u8, width: usize, height: usize) error{InvalidSurface}!Surface {
        if (width == 0 or pixels.len != width * height or width > std.math.maxInt(i32) or height > std.math.maxInt(i32))
            return error.InvalidSurface;
        return .{ .pixels = pixels, .pitch = @intCast(width), .height = @intCast(height) };
    }

    fn at(self: Surface, x: i32, y: i32) usize {
        return @intCast(@as(i64, y) * self.pitch + x);
    }
};

pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

pub const Image = struct { pixels: []const u8, width: i32, height: i32 };

pub fn fill(surface: Surface, clip: ?Rect, x_in: i32, y_in: i32, width_in: i32, height_in: i32, color: u8) void {
    var x = x_in;
    var y = y_in;
    var width = width_in;
    var height = height_in;
    if (clip) |c| {
        if (y < c.y) {
            height += y - c.y;
            y = c.y;
        }
        if (c.y + c.height < y + height) height = c.y + c.height - y;
        if (x < c.x) {
            width += x - c.x;
            x = c.x;
        }
        if (c.x + c.width < x + width) width = c.x + c.width - x;
    } else {
        if (y < 0) {
            height += y;
            y = 0;
        }
        if (surface.height < y + height) height = surface.height - y;
        if (x < 0) {
            width += x;
            x = 0;
        }
        if (surface.pitch < x + width) height = surface.pitch - x;
    }
    if (width < 0 or height <= 0) return;
    var row = surface.at(x, y);
    var rows = height;
    while (rows != 0) : (rows -= 1) {
        @memset(surface.pixels[row..][0..@intCast(width)], color);
        row += @intCast(surface.pitch);
    }
}

pub fn horizontal(surface: Surface, clip: ?Rect, x_in: i32, y: i32, length_in: i32, color: u8) void {
    var x = x_in;
    var length = length_in;
    if (clip) |c| {
        if (x < c.x) {
            length += x - c.x;
            x = c.x;
        }
        if (c.x + c.width < x + length) length = c.width - x + c.x;
        if (y < c.y or c.height + c.y - 1 < y) return;
    } else {
        if (x < 0) {
            length += x;
            x = 0;
        }
        if (surface.pitch < x + length) length = surface.pitch - x;
        if (y < 0 or surface.height - 1 < y) return;
    }
    if (length > 0) @memset(surface.pixels[surface.at(x, y)..][0..@intCast(length)], color);
}

pub fn vertical(surface: Surface, clip: ?Rect, x: i32, y_in: i32, length_in: i32, color: u8) void {
    var y = y_in;
    var length = length_in;
    if (clip) |c| {
        if (y < c.y) {
            length += y - c.y;
            y = c.y;
        }
        if (c.y + c.height < y + length) length = c.y + c.height - y;
        if (x < c.x or c.width + c.x - 1 < x) return;
    } else {
        if (y < 0) {
            length += y;
            y = 0;
        }
        if (surface.height < y + length) length = surface.height - y;
        if (x < 0 or surface.pitch - 1 < x) return;
    }
    var at = surface.at(x, y);
    while (length > 0) : (length -= 1) {
        surface.pixels[at] = color;
        at += @intCast(surface.pitch);
    }
}

pub fn outline(surface: Surface, clip: ?Rect, x: i32, y: i32, width: i32, height: i32, color: u8) void {
    horizontal(surface, clip, x, y, width, color);
    vertical(surface, clip, x, y, height, color);
    vertical(surface, clip, width + x - 1, y, height, color);
    horizontal(surface, clip, x, height + y - 1, width, color);
}

pub fn blit(surface: Surface, clip_in: ?Rect, x_in: i32, y_in: i32, image: Image) void {
    const clip = clip_in orelse Rect{ .x = 0, .y = 0, .width = surface.pitch, .height = surface.height };
    var x = x_in;
    var y = y_in;
    var source_x: i32 = 0;
    var source_y: i32 = 0;
    var width = image.width;
    var height = image.height;
    if (clip.x - x > 0) {
        source_x = clip.x - x;
        width -= source_x;
        x += source_x;
    }
    if (clip.y - y > 0) {
        source_y = clip.y - y;
        height -= source_y;
        y += source_y;
    }
    if (clip.x + clip.width < width + x) width = clip.width - x + clip.x;
    if (clip.height + clip.y < height + y) height = clip.height + clip.y - y;
    if (width <= 0 or height <= 0) return;
    var row: i32 = 0;
    while (row < height) : (row += 1) {
        const from: usize = @intCast((source_y + row) * image.width + source_x);
        @memcpy(surface.pixels[surface.at(x, y + row)..][0..@intCast(width)], image.pixels[from..][0..@intCast(width)]);
    }
}

pub fn nearest(palette: *const [256]u32, first: u8, last: u8, color: u32) u8 {
    var best: i32 = std.math.maxInt(i32);
    var result: u8 = first;
    const r: i32 = @intCast(color & 0xff);
    const g: i32 = @intCast((color >> 8) & 0xff);
    const b: i32 = @intCast((color >> 16) & 0xff);
    var index: u32 = first;
    while (index <= last) : (index += 1) {
        if (best < 1) break;
        const entry = palette[index];
        const er: i32 = @intCast(entry & 0xff);
        const eg: i32 = @intCast((entry >> 8) & 0xff);
        const eb: i32 = @intCast((entry >> 16) & 0xff);
        const brightness = @divTrunc(g * 5 + r * 3 + b * 2, 10) + @divTrunc(eg * 5 + er * 3 + eb * 2, -10);
        const distance = brightness * brightness + (b - eb) * (b - eb) + (g - eg) * (g - eg) + (r - er) * (r - er);
        if (distance < best) {
            best = distance;
            result = @intCast(index);
        }
    }
    return result;
}

pub fn ramp(from: []const u32, target: []const u32, to: []u32, percent: i32) void {
    for (from, target, to) |a, b, *out| {
        var color: u32 = 0;
        inline for (.{ 0, 8, 16 }) |shift| {
            const start: i32 = @intCast((a >> shift) & 0xff);
            const end: i32 = @intCast((b >> shift) & 0xff);
            color |= @as(u32, @intCast(std.math.clamp(start + @divTrunc((end - start) * percent, 100), 0, 255))) << shift;
        }
        out.* = color;
    }
}

test "keeps the height store for a box past the right edge" {
    var pixels = [_]u8{0} ** (8 * 4);
    const surface = try Surface.init(&pixels, 8, 4);
    fill(surface, null, 6, 0, 4, 3, 7);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 7, 7 }, pixels[0..8]);
    try std.testing.expectEqual(@as(u8, 7), pixels[8 + 6]);
    try std.testing.expectEqual(@as(u8, 0), pixels[16 + 6]);
}
