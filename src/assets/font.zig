//! Bitmap fonts: a header, a character map, fixed-size glyph records and
//! indexed pixels, plus the text layout the menus and HUD draw with.
//!
//! Glyphs grow from 16 bytes on disk to 24 in memory. Lines are placed by
//! alignment against the given x, one font height apart; centre and right
//! alignment do not start a line at x, which is why the alignment is part of
//! the layout call rather than the font.

const std = @import("std");

pub const Error = error{
    TruncatedFont,
    InvalidFont,
    UnsupportedCharacter,
    InvalidSurface,
    TextTooWide,
};

pub const Font = struct {
    height: i32,
    baseline: i32,
    first_character: u8,
    last_character: u8,
    character_map: []const u8,
    glyph_records: []const u8,
    bitmap: []const u8,

    pub const Alignment = enum { left, center, right };

    pub const Clip = struct { x: i32, y: i32, width: i32, height: i32 };

    pub const Glyph = struct {
        offset: usize,
        advance: i32,
        step: i8,
        x_offset: i8,
        y_offset: i8,
        width: i32,
        height: i32,
    };

    pub fn init(data: []const u8) Error!Font {
        if (data.len < 32) return error.TruncatedFont;
        const first = readSigned(data, 24);
        const last = readSigned(data, 28);
        if (first < 0 or last < first or last > 255) return error.InvalidFont;
        const count: usize = @intCast(last - first + 1);
        const glyph_start = 32 + count * 2;
        const bitmap_start = glyph_start + count * 16;
        const bitmap_size: usize = readUnsigned(data, 4);
        if (bitmap_start > data.len or bitmap_size > data.len - bitmap_start)
            return error.TruncatedFont;
        const font: Font = .{
            .height = readSigned(data, 8),
            .baseline = readSigned(data, 12),
            .first_character = @intCast(first),
            .last_character = @intCast(last),
            .character_map = data[32..glyph_start],
            .glyph_records = data[glyph_start..bitmap_start],
            .bitmap = data[bitmap_start..][0..bitmap_size],
        };
        if (font.height < 0) return error.InvalidFont;
        for (0..count) |i| {
            const mapped = std.mem.readInt(u16, font.character_map[i * 2 ..][0..2], .little);
            if (mapped >= count) return error.InvalidFont;
            const record = font.glyph_records[i * 16 ..][0..16];
            const glyph_width = readSigned(record, 8);
            const glyph_height = readSigned(record, 12);
            if (glyph_width < 0 or glyph_height < 0) return error.InvalidFont;
            const size = @as(u64, @intCast(glyph_width)) * @as(u64, @intCast(glyph_height));
            const offset: usize = readUnsigned(record, 0);
            if (offset > bitmap_size or size > bitmap_size - offset)
                return error.TruncatedFont;
        }
        return font;
    }

    pub fn width(self: Font, text: []const u8) Error!i32 {
        var longest: i32 = 0;
        var line_width: i32 = 0;
        for (text) |character| {
            if (character == 0) break;
            if (character == '\r' or character == '\n') {
                longest = @max(longest, line_width);
                line_width = 0;
            } else if (try self.glyph(character)) |item| {
                line_width = std.math.add(i32, line_width, item.advance) catch return error.TextTooWide;
            }
        }
        return @max(longest, line_width);
    }

    pub fn drawCentered(
        self: Font,
        pixels: []u8,
        stride: usize,
        target_height: usize,
        text: []const u8,
        center_x: i32,
        baseline_y: i32,
        translation: *const [256]u8,
    ) Error!void {
        return self.drawLines(pixels, stride, target_height, text, center_x, baseline_y, translation, true);
    }

    pub fn drawLeft(
        self: Font,
        pixels: []u8,
        stride: usize,
        target_height: usize,
        text: []const u8,
        left_x: i32,
        baseline_y: i32,
        translation: *const [256]u8,
    ) Error!void {
        return self.drawLines(pixels, stride, target_height, text, left_x, baseline_y, translation, false);
    }

    pub fn drawClipped(
        self: Font,
        pixels: []u8,
        stride: usize,
        clip: Clip,
        text: []const u8,
        origin_x: i32,
        baseline_y: i32,
        alignment: Alignment,
        translation: *const [256]u8,
    ) Error!void {
        return self.drawText(pixels, stride, clip, text, origin_x, baseline_y, alignment, translation, false);
    }

    pub fn drawFilled(
        self: Font,
        pixels: []u8,
        stride: usize,
        clip: Clip,
        text: []const u8,
        origin_x: i32,
        baseline_y: i32,
        alignment: Alignment,
        translation: *const [256]u8,
    ) Error!void {
        return self.drawText(pixels, stride, clip, text, origin_x, baseline_y, alignment, translation, true);
    }

    pub fn glyphIndex(self: Font, character: u8) Error!?usize {
        if (character > self.last_character) return null;
        if (character < self.first_character) return error.UnsupportedCharacter;
        return std.mem.readInt(u16, self.character_map[@as(usize, character - self.first_character) * 2 ..][0..2], .little);
    }

    pub fn glyphCount(self: Font) usize {
        return self.glyph_records.len / 16;
    }

    pub fn glyphAt(self: Font, index: usize) Glyph {
        const record = self.glyph_records[index * 16 ..][0..16];
        const signed_advance: i32 = @as(i8, @bitCast(record[4]));
        const fixed_advance: u32 = @bitCast(signed_advance * 0x10000);
        return .{
            .offset = readUnsigned(record, 0),
            .advance = @intCast((fixed_advance +% 0xffff) >> 16),
            .step = @bitCast(record[4]),
            .x_offset = @bitCast(record[5]),
            .y_offset = @bitCast(record[6]),
            .width = readSigned(record, 8),
            .height = readSigned(record, 12),
        };
    }

    fn drawLines(
        self: Font,
        pixels: []u8,
        stride: usize,
        target_height: usize,
        text: []const u8,
        origin_x: i32,
        baseline_y: i32,
        translation: *const [256]u8,
        centered: bool,
    ) Error!void {
        if (stride == 0 or stride > std.math.maxInt(i32) or target_height > std.math.maxInt(i32) or
            target_height > pixels.len / stride) return error.InvalidSurface;
        const clip = Clip{ .x = 0, .y = 0, .width = @intCast(stride), .height = @intCast(target_height) };
        return self.drawClipped(pixels, stride, clip, text, origin_x, baseline_y, if (centered) .center else .left, translation);
    }

    fn drawText(
        self: Font,
        pixels: []u8,
        stride: usize,
        clip: Clip,
        text: []const u8,
        origin_x: i32,
        baseline_y: i32,
        alignment: Alignment,
        translation: *const [256]u8,
        fill: bool,
    ) Error!void {
        if (stride == 0 or stride > std.math.maxInt(i32) or clip.x < 0 or clip.y < 0 or clip.width < 0 or clip.height < 0 or
            @as(u64, @intCast(clip.x)) + @as(u64, @intCast(clip.width)) > stride or
            (@as(u64, @intCast(clip.y)) + @as(u64, @intCast(clip.height))) * stride > pixels.len) return error.InvalidSurface;
        _ = try self.width(text);
        var line_start: usize = 0;
        var y: i64 = baseline_y;
        while (line_start < text.len and text[line_start] != 0) {
            var line_end = line_start;
            while (line_end < text.len and text[line_end] != 0 and
                text[line_end] != '\r' and text[line_end] != '\n') : (line_end += 1)
            {}
            const line = text[line_start..line_end];
            var x: i64 = @as(i64, origin_x) - switch (alignment) {
                .left => @as(i32, 0),
                .center => @divTrunc(try self.width(line), 2),
                .right => try self.width(line),
            };
            if (fill) {
                const left = @max(x, clip.x);
                const right = @min(x + try self.width(line), @as(i64, clip.x) + clip.width);
                const top = @max(y - self.baseline, clip.y);
                const bottom = @min(y - self.baseline + self.height, @as(i64, clip.y) + clip.height);
                var row = top;
                while (row < bottom) : (row += 1) {
                    if (left < right) @memset(pixels[@intCast(row * @as(i64, @intCast(stride)) + left)..][0..@intCast(right - left)], translation[0]);
                }
            }
            for (line) |character| {
                if (try self.glyph(character)) |item| {
                    self.drawGlyph(pixels, stride, clip, item, x, y, translation);
                    x += item.advance;
                }
            }
            if (line_end == text.len or text[line_end] == 0) break;
            line_start = line_end + 1;
            if (text[line_end] == '\r' and line_start < text.len and text[line_start] == '\n')
                line_start += 1;
            y += self.height;
        }
    }

    fn glyph(self: Font, character: u8) Error!?Glyph {
        const index = (try self.glyphIndex(character)) orelse return null;
        return self.glyphAt(index);
    }

    fn drawGlyph(
        self: Font,
        pixels: []u8,
        stride: usize,
        clip: Clip,
        item: Glyph,
        pen_x: i64,
        pen_y: i64,
        translation: *const [256]u8,
    ) void {
        const x = pen_x + item.x_offset;
        const y = pen_y + item.y_offset;
        const clip_bottom = @as(i64, clip.y) + clip.height;
        const left_skip = @max(x, clip.x) - x;
        const top_skip = @max(y, clip.y) - y;
        const right = @min(x + item.width, @as(i64, clip.x) + clip.width) - x;
        const bottom = @min(y + item.height, clip_bottom) - y;
        if (left_skip >= right or top_skip >= bottom) return;
        const row_width: usize = @intCast(right - left_skip);
        const row_count: usize = @intCast(bottom - top_skip);
        const glyph_stride: usize = @intCast(item.width);
        var source = item.offset + @as(usize, @intCast(top_skip)) * glyph_stride + @as(usize, @intCast(left_skip));
        const target_x: usize = @intCast(x + left_skip);
        for (0..row_count) |row| {
            const target_y = y + @as(i64, @intCast(row));
            if (target_y >= clip.y and target_y < clip_bottom) {
                const destination = @as(usize, @intCast(target_y)) * stride + target_x;
                for (0..row_width) |column| {
                    const color = self.bitmap[source + column];
                    if (color != 0) pixels[destination + column] = translation[color];
                }
            }
            source += glyph_stride;
        }
    }
};

fn readUnsigned(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

fn readSigned(data: []const u8, offset: usize) i32 {
    return @bitCast(readUnsigned(data, offset));
}

fn fixture() [58]u8 {
    var data = [_]u8{0} ** 58;
    std.mem.writeInt(u32, data[4..8], 8, .little);
    std.mem.writeInt(u32, data[8..12], 4, .little);
    std.mem.writeInt(u32, data[12..16], 3, .little);
    std.mem.writeInt(u32, data[24..28], 'A', .little);
    std.mem.writeInt(u32, data[28..32], 'A', .little);
    data[38] = 3;
    data[39] = @bitCast(@as(i8, -1));
    data[40] = @bitCast(@as(i8, -2));
    std.mem.writeInt(u32, data[42..46], 2, .little);
    std.mem.writeInt(u32, data[46..50], 4, .little);
    @memcpy(data[50..58], &[_]u8{ 1, 0, 2, 3, 4, 5, 6, 7 });
    return data;
}

test "LAF bounds, signed offsets, centering, transparency and newline baseline" {
    const data = fixture();
    const font = try Font.init(&data);
    try std.testing.expectEqual(@as(i32, 4), font.height);
    try std.testing.expectEqual(@as(i32, 3), font.baseline);
    try std.testing.expectEqual(@as(i32, 6), try font.width("AA\r\nA"));
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, i| entry.* = @as(u8, @intCast(i)) +% 10;
    var pixels = [_]u8{99} ** 64;
    try font.drawCentered(&pixels, 8, 8, "A\r\nA", 4, 2, &table);
    try std.testing.expectEqualSlices(u8, &.{ 99, 99, 11, 99, 99, 99, 99, 99 }, pixels[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 99, 99, 12, 13, 99, 99, 99, 99 }, pixels[8..16]);
    try std.testing.expectEqualSlices(u8, pixels[0..32], pixels[32..64]);
    try std.testing.expectError(error.TruncatedFont, Font.init(data[0..57]));
    try std.testing.expectError(error.UnsupportedCharacter, font.width("@"));
}

test "clipped glyph path retains its top clipping behavior" {
    const data = fixture();
    const font = try Font.init(&data);
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, i| entry.* = @intCast(i);
    var pixels = [_]u8{99} ** 16;
    try font.drawCentered(&pixels, 4, 4, "A", 1, 1, &table);
    try std.testing.expectEqualSlices(u8, &.{ 5, 99, 99, 99, 7, 99, 99, 99 }, pixels[0..8]);
    try std.testing.expectEqualSlices(u8, &([_]u8{99} ** 8), pixels[8..16]);
    var negative_advance = data;
    negative_advance[38] = @bitCast(@as(i8, -1));
    try std.testing.expectEqual(@as(i32, 65535), try (try Font.init(&negative_advance)).width("A"));
}
