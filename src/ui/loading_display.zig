//! The loading screen: a full-screen picture, one centred line of UI text
//! and a progress bar under it.
//!
//! Opened both when joining a network game and when a level loads. It draws
//! into the software frame buffer and palette, and every point where the
//! display would be unlocked or flipped is a `present` here. The frame
//! step's network half belongs to the caller. The last text number outlives
//! a close, so reopening without setting one shows the previous line.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const pcx = @import("../assets/pcx.zig");
const messages = @import("../assets/messages.zig");
const Font = @import("../assets/font.zig").Font;
const draw = @import("surface.zig");

pub const width = 640;

pub const height = 480;

const system_colors = [16]u32{
    0x000000, 0xaa0000, 0x00aa00, 0xaaaa00, 0x0000aa, 0xaa00aa, 0x0055aa, 0xaaaaaa,
    0x555555, 0xff5555, 0x55ff55, 0xffff55, 0x5555ff, 0xff55ff, 0x55ffff, 0xffffff,
};

const system_white: u32 = 0xffffff;

const text_capacity = 0x100;

pub const Screen = struct {
    pixels: []u8,
    palette: *[256]u32,
    context: *anyopaque,
    present: *const fn (context: *anyopaque, pixels: []const u8, palette: *const [256]u32) anyerror!void,

    fn show(self: Screen) !void {
        try self.present(self.context, self.pixels, self.palette);
    }

    fn surface(self: Screen) !draw.Surface {
        return draw.Surface.init(self.pixels, width, height) catch error.InvalidLoadingScreen;
    }
};

pub const LoadingDisplay = struct {
    depth: u32 = 0,
    font: ?Font = null,
    image: ?pcx.Image = null,
    bar_color: u8 = 0,
    text_rect: draw.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    bar_rect: draw.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    text_save: []u8 = &.{},
    bar_save: []u8 = &.{},
    shown: i32 = 0,
    part_start: i32 = 0,
    part_end: i32 = 0,
    total: i32 = 0,
    text: [text_capacity]u8 = @splat(0),
    text_id: u32 = 0,
    redraws: u32 = 0,

    pub fn isOpen(self: *const LoadingDisplay) bool {
        return self.font != null;
    }

    pub fn open(self: *LoadingDisplay, a: std.mem.Allocator, archive: lab.Archive, screen: Screen, total: i32) !void {
        if (self.depth != 0) {
            self.total = total;
            self.depth += 1;
            return;
        }
        const font = try Font.init(try archive.find("sf3.laf", 0x4e464e54));
        const image = pcx.decode(a, archive.find("mm220.pcx", 0x50424d50) catch |err| switch (err) {
            error.ResourceNotFound => return error.LoadScreenNotFound,
            else => return err,
        }) catch |err| return err;
        errdefer image.deinit(a);
        if (image.width != width or image.height != height) return error.UnsupportedLoadScreen;
        @memset(screen.palette, 0);
        try clearBuffers(screen);
        screen.palette.* = image.palette;
        const bar_color = draw.nearest(&image.palette, 1, 0xfe, 0x60);
        const text_rect: draw.Rect = .{ .x = 0x28, .y = 0x1a4, .width = 0x140, .height = font.height };
        const bar_rect: draw.Rect = .{ .x = text_rect.x + 0x28, .y = text_rect.y + font.height + 5, .width = text_rect.width - 0x50, .height = 5 };
        const text_save = try a.alloc(u8, @intCast(text_rect.width * text_rect.height));
        errdefer a.free(text_save);
        const bar_save = try a.alloc(u8, @intCast(bar_rect.width * bar_rect.height));
        errdefer a.free(bar_save);
        const picture = picture_of(&image);
        draw.blit(try draw.Surface.init(text_save, @intCast(text_rect.width), @intCast(text_rect.height)), .{ .x = 0, .y = 0, .width = text_rect.width, .height = text_rect.height }, -text_rect.x, -text_rect.y, picture);
        draw.blit(try draw.Surface.init(bar_save, @intCast(bar_rect.width), @intCast(bar_rect.height)), .{ .x = 0, .y = 0, .width = bar_rect.width, .height = bar_rect.height }, -bar_rect.x, -bar_rect.y, picture);
        self.font = font;
        self.image = image;
        self.bar_color = bar_color;
        self.text_rect = text_rect;
        self.bar_rect = bar_rect;
        self.text_save = text_save;
        self.bar_save = bar_save;
        self.shown = 0;
        self.part_end = 0;
        self.part_start = 0;
        self.total = total;
        self.text[0] = 0;
        self.depth = 1;
        try self.drawPicture(screen);
    }

    pub fn beginPart(self: *LoadingDisplay, size: i32) void {
        self.part_start = self.part_end;
        self.part_end +%= size;
    }

    pub fn show(self: *LoadingDisplay, local_messages: []const u8, screen: Screen, text_id_in: u32, from: i32, to: i32, at: i32) !void {
        if (!self.isOpen()) return;
        var text_id = text_id_in;
        if (text_id != 0) self.text_id = text_id;
        if (self.redraws != 0) {
            self.redraws -= 1;
            try self.drawPicture(screen);
            text_id = self.text_id;
        }
        const surface = try screen.surface();
        const image = &self.image.?;
        const target = try draw.Surface.init(image.pixels, width, height);
        const picture = picture_of(image);
        const font = &self.font.?;
        if (text_id != 0) {
            if (messages.lookup(local_messages, text_id)) |found| {
                if (found.len >= self.text.len) return error.LoadingTextTooLong;
                @memcpy(self.text[0..found.len], found);
                self.text[found.len] = 0;
            } else |err| switch (err) {
                error.MessageNotFound => {},
                else => return err,
            }
            const r = self.text_rect;
            draw.blit(target, r, r.x, r.y, .{ .pixels = self.text_save, .width = r.width, .height = r.height });
            var table: [256]u8 = undefined;
            for (&table, 0..) |*entry, i| entry.* = @intCast(i);
            table[0] = 0;
            table[0xff] = self.bar_color;
            const x = r.x + @divTrunc(r.width, 2);
            const y = (font.baseline - @divTrunc(font.height, 2)) + @divTrunc(r.height, 2) + r.y;
            try font.drawClipped(image.pixels, width, .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }, std.mem.sliceTo(&self.text, 0), x, y, .center, &table);
            draw.blit(surface, r, 0, 0, picture);
        }
        const value = if (self.part_end == 0) self.total else self.part_end;
        if (to != from) {
            const bar = self.bar_rect;
            const span = to -% from;
            const divisor = self.total *% span;
            if (divisor == 0) return error.LoadingProgressDivideByZero;
            const product = ((value -% self.part_start) *% (at -% from) +% self.part_start *% span) *% bar.width;
            var shown = @divTrunc(product, divisor);
            if (bar.width <= shown) shown = bar.width;
            if (shown != self.shown) {
                self.shown = shown;
                if (shown > 0) {
                    draw.fill(target, null, bar.x, bar.y, shown, bar.height, self.bar_color);
                    const rest: draw.Rect = .{ .x = bar.x + shown, .y = bar.y, .width = bar.width - shown, .height = bar.height };
                    draw.blit(target, rest, bar.x, bar.y, .{ .pixels = self.bar_save, .width = bar.width, .height = bar.height });
                    draw.blit(surface, bar, 0, 0, picture);
                }
            }
        }
        try screen.show();
    }

    pub fn close(self: *LoadingDisplay, a: std.mem.Allocator, screen: Screen) !void {
        if (self.depth == 0) return;
        self.depth -= 1;
        if (self.depth != 0) return;
        self.release(a);
        try clearBuffers(screen);
        @memcpy(screen.palette[0..16], &system_colors);
        screen.palette[0xff] = system_white;
    }

    pub fn release(self: *LoadingDisplay, a: std.mem.Allocator) void {
        if (self.image) |image| image.deinit(a);
        if (self.text_save.len != 0) a.free(self.text_save);
        if (self.bar_save.len != 0) a.free(self.bar_save);
        self.image = null;
        self.font = null;
        self.text_save = &.{};
        self.bar_save = &.{};
    }

    fn drawPicture(self: *LoadingDisplay, screen: Screen) !void {
        const surface = try screen.surface();
        const clip: draw.Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
        draw.blit(surface, clip, 0, 0, picture_of(&self.image.?));
        const bar = self.bar_rect;
        draw.outline(surface, clip, bar.x - 2, bar.y - 2, bar.width + 4, bar.height + 4, 0);
        try screen.show();
    }
};

const TestScreen = struct {
    pixels: [width * height]u8 = @splat(0xaa),
    palette: [256]u32 = @splat(0x123456),
    presents: u32 = 0,
    last: [width * height]u8 = undefined,

    fn screen(self: *TestScreen) Screen {
        return .{ .pixels = &self.pixels, .palette = &self.palette, .context = self, .present = present };
    }

    fn present(context: *anyopaque, pixels: []const u8, _: *const [256]u32) anyerror!void {
        const self: *TestScreen = @ptrCast(@alignCast(context));
        self.presents += 1;
        @memcpy(&self.last, pixels);
    }
};

fn picture_of(image: *const pcx.Image) draw.Image {
    return .{ .pixels = image.pixels, .width = @intCast(image.width), .height = @intCast(image.height) };
}

fn clearBuffers(screen: Screen) !void {
    @memset(screen.pixels, 0);
    try screen.show();
    @memset(screen.pixels, 0);
}

fn testArchive(a: std.mem.Allocator) !?struct { bytes: []u8, archive: lab.Archive } {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD2/OUTLAWS/OUTLAWS.LAB", a, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return .{ .bytes = bytes, .archive = try lab.Archive.init(bytes) };
}

test "text and bar are laid out from the reference assets" {
    const a = std.testing.allocator;
    const loaded = (try testArchive(a)) orelse return error.SkipZigTest;
    defer a.free(loaded.bytes);
    const local = try loaded.archive.find("LOCAL.MSG", 0);
    var target = TestScreen{};
    var display = LoadingDisplay{};
    try display.open(a, loaded.archive, target.screen(), 100);
    defer display.release(a);
    try std.testing.expectEqual(@as(u32, 2), target.presents);
    const font = display.font.?;
    try std.testing.expectEqual(draw.Rect{ .x = 40, .y = 420, .width = 320, .height = font.height }, display.text_rect);
    try std.testing.expectEqual(draw.Rect{ .x = 80, .y = 420 + font.height + 5, .width = 240, .height = 5 }, display.bar_rect);
    try std.testing.expectEqual(draw.nearest(&display.image.?.palette, 1, 0xfe, 0x60), display.bar_color);
    try std.testing.expectEqual(@as(u8, 0), target.pixels[@intCast((display.bar_rect.y - 2) * width + display.bar_rect.x - 2)]);
    try display.show(local, target.screen(), 0x389, 0, 1, 0);
    try std.testing.expectEqualStrings("CONNECTING", std.mem.sliceTo(&display.text, 0));
    try std.testing.expectEqual(@as(i32, 0), display.shown);
    try std.testing.expectEqual(@as(u32, 3), target.presents);
    display.beginPart(25);
    try display.show(local, target.screen(), 0, 0, 2, 1);
    try std.testing.expectEqual(@as(i32, 30), display.shown);
    const bar = display.bar_rect;
    try std.testing.expectEqual(display.bar_color, target.pixels[@intCast(bar.y * width + bar.x + 29)]);
    try std.testing.expectEqual(display.bar_save[30], target.pixels[@intCast(bar.y * width + bar.x + 30)]);
    try display.show(local, target.screen(), 0x38c, 0, 1, 0);
    try std.testing.expectEqualStrings("CONNECTED", std.mem.sliceTo(&display.text, 0));
    try std.testing.expectEqual(@as(u32, 0x38c), display.text_id);
    try display.close(a, target.screen());
    try std.testing.expect(!display.isOpen());
    try std.testing.expectEqual(@as(u32, 0xaa0000), target.palette[1]);
    try std.testing.expectEqual(@as(u8, 0), target.pixels[1234]);
}

test "nested opens only change the total; the display closes at depth 0" {
    const a = std.testing.allocator;
    const loaded = (try testArchive(a)) orelse return error.SkipZigTest;
    defer a.free(loaded.bytes);
    var target = TestScreen{};
    var display = LoadingDisplay{};
    try display.open(a, loaded.archive, target.screen(), 100);
    defer display.release(a);
    try display.open(a, loaded.archive, target.screen(), 90);
    try std.testing.expectEqual(@as(u32, 2), display.depth);
    try std.testing.expectEqual(@as(i32, 90), display.total);
    try display.close(a, target.screen());
    try std.testing.expect(display.isOpen());
    try display.close(a, target.screen());
    try std.testing.expect(!display.isOpen());
}
