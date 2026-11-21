//! The main and difficulty menus: a descriptor of item records, the hover
//! and selection state, and the palette ramp that confirms a choice.
//!
//! Timing details that are easy to break: the hover sound only plays once
//! the pointer has moved past five pixels and lands on an enabled item after
//! the first loop; confirmation has no sound of its own; a left button that
//! is already down can select the previous hover before the coordinates
//! update; and arrow keys restart the palette transition even when the
//! selection wraps back to the same item. Item -1 reads the record in front
//! of the table, which is how the descriptors express "nothing selected".

const std = @import("std");
const lab = @import("../assets/lab.zig");
const pcx = @import("../assets/pcx.zig");
const Font = @import("../assets/font.zig").Font;
const messages = @import("../assets/messages.zig");

pub const width = 640;

pub const height = 480;

pub const items = [_]Item{
    .{ .message = 6000, .rect = .{ 4, 147, 394, 247 }, .font = 2 },
    .{ .message = 6001, .rect = .{ 8, 218, 398, 328 }, .font = 2 },
    .{ .message = 6002, .rect = .{ 5, 301, 395, 401 }, .font = 2 },
    .{ .message = 6003, .rect = .{ 10, 408, 115, 446 }, .font = 1 },
    .{ .message = 6004, .rect = .{ 135, 408, 290, 446 }, .font = 1 },
    .{ .message = 6005, .rect = .{ 310, 408, 390, 446 }, .font = 1 },
    .{ .message = 6006, .rect = .{ 6, 21, 386, 121 }, .font = 0, .enabled = false },
    .{ .message = 0, .rect = .{ 0, 460, 320, 480 }, .font = 3, .enabled = false },
};

pub const difficulty_items = [_]Item{
    .{ .message = 6010, .rect = .{ 355, 155, 475, 240 }, .font = 2 },
    .{ .message = 6011, .rect = .{ 322, 252, 512, 305 }, .font = 2 },
    .{ .message = 6012, .rect = .{ 310, 311, 545, 406 }, .font = 2 },
    .{ .message = 6013, .rect = .{ 466, 405, 636, 480 }, .font = 1 },
    .{ .message = 6014, .rect = .{ 240, 31, 610, 111 }, .font = 0, .enabled = false },
};

const Item = struct { message: u32, rect: [4]i32, font: usize, enabled: bool = true };

pub const Kind = enum { main, difficulty };

pub const Direction = enum(u4) { up = 1, right = 2, down = 4, left = 8 };

pub const Menu = struct {
    kind: Kind = .main,
    item_defs: []const Item = &items,
    background: pcx.Image,
    palette: [256]u32,
    fonts: [4]Font,
    labels: [items.len][]const u8,
    version_label: ?[]u8 = null,
    selected: i32 = 0,
    selected_at: u32 = 0,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_suppressed: bool = true,
    mouse_buttons: u32 = 0,
    pending_result: ?i32 = null,
    flash_presented_at: ?u32 = null,
    audio_selection: ?i32 = null,

    pub fn takeSelectionSound(self: *Menu) bool {
        const previous = self.audio_selection;
        self.audio_selection = self.selected;
        return previous != null and previous.? != self.selected and self.selected != -1;
    }

    pub fn init(allocator: std.mem.Allocator, archive: lab.Archive) !Menu {
        return initKind(allocator, archive, .main);
    }

    pub fn initKind(allocator: std.mem.Allocator, archive: lab.Archive, kind: Kind) !Menu {
        const background_name: []const u8 = switch (kind) {
            .main => "NMM.PCX",
            .difficulty => "MD220c.PCX",
        };
        var self: Menu = .{
            .kind = kind,
            .item_defs = definitions(kind),
            .background = try pcx.decode(allocator, try archive.find(background_name, 0x50424d50)),
            .palette = undefined,
            .fonts = undefined,
            .labels = .{""} ** items.len,
        };
        errdefer self.background.deinit(allocator);
        self.palette = menuPalette(self.background.palette, 0, 0);
        if (self.background.width != width or self.background.height != height)
            return error.UnsupportedMenuDimensions;
        for ([_][]const u8{ "fl3x.laf", "sf3.laf", "mf3x.laf", "info.laf" }, &self.fonts) |name, *font|
            font.* = try Font.init(try archive.find(name, 0x4e464e54));
        const text = try archive.find("LOCAL.MSG", 0);
        if (kind == .main) self.version_label = try readVersionLabel(allocator, archive);
        errdefer if (self.version_label) |label| allocator.free(label);
        for (self.item_defs, self.labels[0..self.item_defs.len]) |item, *label| {
            label.* = if (item.message == 0) self.version_label.? else try messages.lookup(text, item.message);
        }
        return self;
    }

    pub fn deinit(self: Menu, allocator: std.mem.Allocator) void {
        if (self.version_label) |label| allocator.free(label);
        self.background.deinit(allocator);
    }

    pub fn select(self: *Menu, index: i32, now: u32) void {
        if (index != self.selected) {
            self.selected = index;
            self.selected_at = if (index == -1) 0 else now;
        }
    }

    pub fn mouseMove(self: *Menu, x: i32, y: i32, now: u32) void {
        self.mouseState(x, y, self.mouse_buttons, now);
    }

    pub fn mouseState(self: *Menu, x: i32, y: i32, buttons: u32, now: u32) void {
        if (self.pending_result == null) {
            if (buttons & 1 != 0 and !self.mouse_suppressed and self.selected != -1)
                self.beginExit(self.selected);
            if (self.mouse_suppressed and (buttons != 0 or
                x < self.mouse_x - 5 or x > self.mouse_x + 5 or
                y < self.mouse_y - 5 or y > self.mouse_y + 5))
                self.mouse_suppressed = false;
            if (!self.mouse_suppressed) {
                self.mouse_x = x;
                self.mouse_y = y;
                self.select(hitTestItems(self.item_defs, x, y), now);
            }
            if ((self.mouse_buttons ^ buttons) & 1 != 0) self.mouse_suppressed = true;
        }
        self.mouse_buttons = buttons;
    }

    pub fn tab(self: *Menu, backwards: bool, now: u32) void {
        if (self.pending_result != null) return;
        self.mouse_suppressed = true;
        var index = self.selected;
        while (true) {
            index += if (backwards) @as(i32, -1) else 1;
            if (index < 0) index = @intCast(self.item_defs.len - 1);
            if (index >= self.item_defs.len) index = 0;
            if (self.item_defs[@intCast(index)].enabled) break;
        }
        self.select(index, now);
    }

    pub fn arrow(self: *Menu, direction: Direction, now: u32) void {
        if (self.pending_result != null) return;
        self.mouse_suppressed = true;
        var index = nearest(self.item_defs, direction, self.selected, 0, 0);
        if (index == -1) {
            var x: i32 = if (self.kind == .difficulty) 0x00407f90 / 2 else 0;
            var y: i32 = 0;
            if (self.selected >= 0) {
                const rect = self.item_defs[@intCast(self.selected)].rect;
                x = @divTrunc(rect[0] + rect[2], 2);
                y = @divTrunc(rect[1] + rect[3], 2);
            }
            switch (direction) {
                .up => y = height,
                .down => y = 0,
                .left => x = width,
                .right => x = 0,
            }
            index = nearest(self.item_defs, direction, -1, x, y);
        }
        self.select(index, now);
        self.selected_at = if (index == -1) 0 else now;
    }

    pub fn enter(self: *Menu) void {
        if (self.pending_result != null) return;
        self.mouse_suppressed = true;
        self.beginExit(self.selected);
    }

    pub fn escape(self: *Menu) void {
        if (self.pending_result != null) return;
        self.mouse_suppressed = true;
        if (self.kind != .main) self.beginExit(-1);
    }

    pub fn presented(self: *Menu, now: u32) void {
        if (self.pending_result != null and self.flash_presented_at == null)
            self.flash_presented_at = now;
    }

    pub fn takeResult(self: *Menu, now: u32, buttons: u32) ?i32 {
        const result = self.pending_result orelse return null;
        const started = self.flash_presented_at orelse return null;
        if (now < started +% 100 or buttons != 0) return null;
        self.pending_result = null;
        self.flash_presented_at = null;
        return result;
    }

    pub fn render(self: *Menu, pixels: []u8, now: u32) ![256]u32 {
        if (pixels.len != width * height) return error.InvalidFramebuffer;
        @memcpy(pixels, self.background.pixels);
        const normal = translation(0x25);
        const selected = translation(0x1d);
        for (self.item_defs, self.labels[0..self.item_defs.len], 0..) |item, label, index| {
            const font = self.fonts[item.font];
            const x = @divTrunc(item.rect[0] + item.rect[2], 2);
            const y = font.baseline + @divTrunc(item.rect[1] + item.rect[3], 2) - @divTrunc(font.height, 2);
            try font.drawCentered(pixels, width, height, label, x, y, if (self.selected == index) &selected else &normal);
        }
        if (self.pending_result != null) {
            self.palette = paletteAtPercent(self.background.palette, 150);
        } else if (self.selected_at != 0) {
            self.palette = menuPalette(self.background.palette, self.selected_at, now);
        }
        return self.palette;
    }

    fn beginExit(self: *Menu, result: i32) void {
        self.pending_result = result;
        self.flash_presented_at = null;
    }
};

pub fn hitTest(x: i32, y: i32) i32 {
    return hitTestItems(&items, x, y);
}

pub fn menuPalette(original: [256]u32, selected_at: u32, now: u32) [256]u32 {
    var percent: u32 = 0;
    if (selected_at != 0) {
        percent = (now -% selected_at) / 5;
        if (percent > 100) {
            const phase = percent % 40;
            percent = if (phase < 20) 100 - phase else phase + 60;
        }
    }
    return paletteAtPercent(original, @intCast(percent));
}

fn readVersionLabel(allocator: std.mem.Allocator, archive: lab.Archive) ![]u8 {
    const version = archive.find("OL.VER", 0) catch |err| switch (err) {
        error.ResourceNotFound => return versionLabel(allocator, null),
        else => return err,
    };
    return versionLabel(allocator, version);
}

fn versionLabel(allocator: std.mem.Allocator, version: ?[]const u8) ![]u8 {
    const build_date = "Mar 14 1997 16:16:15";
    const data = version orelse return allocator.dupe(u8, build_date);
    var line: [99]u8 = undefined;
    var length: usize = 0;
    for (data[0..@min(data.len, line.len)]) |character| {
        if (character == 0) break;
        line[length] = if (character == '\r') '\n' else character;
        length += 1;
        if (character == '\r' or character == '\n') break;
    }
    return std.fmt.allocPrint(allocator, "{s} -- v. {s}", .{ build_date, line[0..length] });
}

fn definitions(kind: Kind) []const Item {
    return switch (kind) {
        .main => &items,
        .difficulty => &difficulty_items,
    };
}

fn hitTestItems(item_defs: []const Item, x: i32, y: i32) i32 {
    if (x < 0 or x >= width or y < 0 or y >= height) return -1;
    for (item_defs, 0..) |item, i| {
        if (item.enabled and x >= item.rect[0] and x <= item.rect[2] and
            y >= item.rect[1] and y <= item.rect[3]) return @intCast(i);
    }
    return -1;
}

fn translation(offset: u8) [256]u8 {
    var table: [256]u8 = undefined;
    table[0] = 0;
    for (1..256) |i| table[i] = @as(u8, @intCast(i)) -% offset;
    return table;
}

fn paletteAtPercent(original: [256]u32, percent: i32) [256]u32 {
    var palette = original;
    for (0..8) |i| palette[228 + i] = interpolate(original[220 + i], original[228 + i], percent);
    return palette;
}

fn interpolate(from: u32, to: u32, percent: i32) u32 {
    var result: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((from >> shift) & 255);
        const b: i32 = @intCast((to >> shift) & 255);
        result |= @as(u32, @intCast(std.math.clamp(a + @divTrunc((b - a) * percent, 100), 0, 255))) << shift;
    }
    return result;
}

fn nearest(item_defs: []const Item, direction: Direction, current: i32, initial_x: i32, initial_y: i32) i32 {
    var x = initial_x;
    var y = initial_y;
    if (current >= 0) {
        const rect = item_defs[@intCast(current)].rect;
        x = @divTrunc(rect[0] + rect[2], 2);
        y = @divTrunc(rect[1] + rect[3], 2);
    }
    var best: i32 = -1;
    var distance: i32 = 1_000_000;
    for (item_defs, 0..) |item, i| {
        if (!item.enabled or current == i) continue;
        const cx = @divTrunc(item.rect[0] + item.rect[2], 2);
        const cy = @divTrunc(item.rect[1] + item.rect[3], 2);
        const matches = switch (direction) {
            .up => cy < y - 20,
            .down => cy > y + 20,
            .right => cx > x + 20,
            .left => cx < x - 20,
        };
        const dx = x -% cx;
        const dy = y -% cy;
        const d = dx *% dx +% dy *% dy;
        if (matches and d < distance) {
            best = @intCast(i);
            distance = d;
        }
    }
    return best;
}

fn controlMenu(kind: Kind) Menu {
    return .{
        .kind = kind,
        .item_defs = definitions(kind),
        .background = undefined,
        .palette = undefined,
        .fonts = undefined,
        .labels = .{""} ** items.len,
    };
}

test "menu overlap uses the documented order and disabled labels cannot be selected" {
    try std.testing.expectEqual(@as(i32, 0), hitTest(100, 230));
    try std.testing.expectEqual(@as(i32, 5), hitTest(390, 446));
    try std.testing.expectEqual(@as(i32, -1), hitTest(100, 50));
    try std.testing.expectEqual(@as(i32, 1), nearest(&items, .down, 0, 0, 0));
    try std.testing.expectEqual(@as(i32, 5), nearest(&items, .left, -1, width, 427));
}

test "hover palette uses 220/228 ramps with the reference timing and truncation" {
    var original = [_]u32{0} ** 256;
    original[220] = 0x64500a;
    original[228] = 0x00146e;
    try std.testing.expectEqual(@as(u32, 0x64500a), menuPalette(original, 10, 10)[228]);
    try std.testing.expectEqual(@as(u32, 0x32323c), menuPalette(original, 10, 260)[228]);
    try std.testing.expectEqual(original[228], menuPalette(original, 10, 510)[228]);
    try std.testing.expectEqual(interpolate(original[220], original[228], 81), menuPalette(original, 10, 515)[228]);
    try std.testing.expectEqual(original[220], menuPalette(original, 0, 1000)[220]);
    try std.testing.expectEqual(@as(u32, 0x0000a0), paletteAtPercent(original, 150)[228]);
}

test "difficulty navigation preserves overlapping bounds and predecessor arithmetic" {
    try std.testing.expectEqual(@as(i32, 2), hitTestItems(&difficulty_items, 500, 406));
    try std.testing.expectEqual(@as(i32, 3), hitTestItems(&difficulty_items, 500, 407));
    try std.testing.expectEqual(@as(i32, -1), hitTestItems(&difficulty_items, 400, 70));
    var screen = controlMenu(.difficulty);
    screen.tab(true, 10);
    try std.testing.expectEqual(@as(i32, 3), screen.selected);
    screen.select(-1, 20);
    screen.arrow(.up, 30);
    try std.testing.expectEqual(@as(i32, 2), screen.selected);
    screen.select(-1, 40);
    screen.arrow(.left, 50);
    try std.testing.expectEqual(@as(i32, 0), screen.selected);
    screen.arrow(.left, 60);
    try std.testing.expectEqual(@as(i32, 0), screen.selected);
    try std.testing.expectEqual(@as(u32, 60), screen.selected_at);
}

test "mouse button transitions retain suppression and activation order" {
    var screen = controlMenu(.main);
    screen.mouse_x = 100;
    screen.mouse_y = 280;
    screen.mouseState(100, 280, 1, 10);
    try std.testing.expectEqual(@as(i32, 1), screen.selected);
    try std.testing.expect(screen.mouse_suppressed);
    try std.testing.expectEqual(@as(?i32, null), screen.pending_result);
    screen.mouseState(100, 280, 1, 20);
    try std.testing.expect(!screen.mouse_suppressed);
    try std.testing.expectEqual(@as(?i32, null), screen.pending_result);
    screen.mouseState(100, 280, 1, 30);
    try std.testing.expectEqual(@as(?i32, 1), screen.pending_result);

    screen = controlMenu(.main);
    screen.mouse_suppressed = false;
    screen.mouseState(100, 280, 1, 10);
    try std.testing.expectEqual(@as(?i32, 0), screen.pending_result);
    try std.testing.expectEqual(@as(i32, 1), screen.selected);
}

test "confirmation waits for first presentation, 100ms, and all released buttons" {
    var screen = controlMenu(.difficulty);
    screen.enter();
    try std.testing.expectEqual(@as(?i32, null), screen.takeResult(1000, 0));
    screen.presented(1000);
    screen.tab(false, 1050);
    try std.testing.expectEqual(@as(i32, 0), screen.selected);
    try std.testing.expectEqual(@as(?i32, null), screen.takeResult(1099, 0));
    screen.presented(1100);
    try std.testing.expectEqual(@as(?i32, null), screen.takeResult(1100, 4));
    try std.testing.expectEqual(@as(?i32, 0), screen.takeResult(1101, 0));
    try std.testing.expectEqual(@as(?i32, null), screen.takeResult(1102, 0));
    screen.escape();
    screen.presented(1200);
    try std.testing.expectEqual(@as(?i32, -1), screen.takeResult(1300, 0));
    screen = controlMenu(.main);
    screen.escape();
    try std.testing.expectEqual(@as(?i32, null), screen.pending_result);
    screen.select(-1, 10);
    screen.enter();
    try std.testing.expectEqual(@as(?i32, -1), screen.pending_result);
}

test "version label uses archive line reading and absent-file build-date fallback" {
    const allocator = std.testing.allocator;
    const label = try versionLabel(allocator, "1.0 Build 3\r\nsecond line");
    defer allocator.free(label);
    try std.testing.expectEqualStrings("Mar 14 1997 16:16:15 -- v. 1.0 Build 3\n", label);
    var empty_lab = [_]u8{0} ** 16;
    @memcpy(empty_lab[0..4], "LABN");
    const fallback = try readVersionLabel(allocator, try lab.Archive.init(&empty_lab));
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("Mar 14 1997 16:16:15", fallback);
    const empty = try versionLabel(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("Mar 14 1997 16:16:15 -- v. ", empty);
    const unterminated = try versionLabel(allocator, "1.0");
    defer allocator.free(unterminated);
    try std.testing.expectEqualStrings("Mar 14 1997 16:16:15 -- v. 1.0", unterminated);
    const long_line = [_]u8{'a'} ** 100;
    const truncated = try versionLabel(allocator, &long_line);
    defer allocator.free(truncated);
    try std.testing.expectEqual(@as(usize, 99), truncated.len - "Mar 14 1997 16:16:15 -- v. ".len);
}

test "CD1 difficulty scene matches independently composed reference pixels" {
    const allocator = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(data);
    var screen = try Menu.initKind(allocator, try lab.Archive.init(data), .difficulty);
    defer screen.deinit(allocator);
    try std.testing.expectEqualStrings("GOOD", screen.labels[0]);
    try std.testing.expectEqualStrings("CANCEL", screen.labels[3]);
    try std.testing.expect(screen.version_label == null);
    const pixels = try allocator.alloc(u8, width * height);
    defer allocator.free(pixels);
    _ = try screen.render(pixels, 0);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pixels, &hash, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "6099a024b45205065da47991b3b841751753503212266effe983dc2d43f5c11d");
    try std.testing.expectEqualSlices(u8, &expected, &hash);
}
