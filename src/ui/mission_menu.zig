//! The in-level popup: resume, restart, end game, options, save, load and
//! quit over a frozen copy of the game screen.
//!
//! Unlike the main menus every popup starts on the first row, draws before
//! it applies input, and has no confirmation flash. The key queue holds 32
//! scan codes and overwrites without advancing the read cursor; one frame
//! dequeues exactly one code, including codes nothing handles. The pointer
//! is sampled on entry but the previous button state is not, so a held
//! button counts as a click on the first loop. The screen capture is taken
//! once and reused by nested popups.

const std = @import("std");
const MouseButtons = @import("../mouse_buttons.zig").MouseButtons;

const lab = @import("../assets/lab.zig");
const pcx = @import("../assets/pcx.zig");
const Font = @import("../assets/font.zig").Font;
const messages = @import("../assets/messages.zig");
const nwx = @import("../assets/nwx.zig");
const hud = @import("../render/hud.zig");

pub const width = 640;

pub const height = 480;

pub const Mouse = struct { x: i32 = 0, y: i32 = 0, buttons: MouseButtons = .{} };

pub const Key = enum { none, escape, enter, up, down, tab, back_tab };

pub const Kind = enum { mission, quit };

pub const KeyQueue = struct {
    values: [32]Key = @splat(.none),
    written: u32 = 0,
    read: u32 = 0,

    pub fn push(self: *KeyQueue, key: Key) void {
        self.written +%= 1;
        self.values[self.written & 31] = key;
    }

    pub fn next(self: *KeyQueue) Key {
        if (@as(i32, @bitCast(self.read)) >= @as(i32, @bitCast(self.written))) return .none;
        self.read +%= 1;

        return self.values[self.read & 31];
    }
};

pub const Control = struct {
    kind: Kind = .mission,
    selected: i32 = 0,
    mouse: Mouse = .{},
    previous_buttons: MouseButtons = .{},
    sound_selection: i32 = -3,
    result: ?i32 = null,
    presented: bool = false,

    pub fn count(self: Control) i32 {
        return if (self.kind == .mission) 7 else 2;
    }

    pub fn init(kind: Kind, mouse: Mouse) Control {
        return .{ .kind = kind, .mouse = mouse };
    }

    pub fn update(self: *Control, mouse: Mouse, key: Key, first_y: i32, spacing: i32) void {
        if (self.result != null) return;

        const clicked = mouse.buttons.left and !self.previous_buttons.left;
        var next: ?i32 = null;

        if (self.mouse.x != mouse.x or self.mouse.y != mouse.y or clicked) {
            var row: i32 = 0;

            while (row < self.count()) : (row += 1) {
                const top = first_y + row * spacing;

                if (mouse.y >= top and mouse.y < top + spacing) {
                    next = row;
                    if (clicked) self.result = row;
                }
            }
        }

        self.previous_buttons = mouse.buttons;
        self.mouse = .{
            .x = std.math.clamp(mouse.x, 0, width - 1),
            .y = std.math.clamp(mouse.y, 0, height - 1),
            .buttons = mouse.buttons,
        };

        switch (key) {
            .none => {},
            .escape => if (self.result == null) {
                self.result = -1;
            },
            .enter => self.result = self.selected,
            .up, .back_tab => next = if (self.selected == 0) self.count() - 1 else self.selected - 1,
            .down, .tab => next = if (self.selected + 1 == self.count()) 0 else self.selected + 1,
        }

        if (next) |row| self.selected = row;
    }

    pub fn takeSound(self: *Control) ?[]const u8 {
        if (self.sound_selection == self.selected) return null;
        self.sound_selection = self.selected;

        return if (self.kind == .mission and self.selected == 6) "CHICKEN1.WAV" else "RIFLOUT.WAV";
    }

    pub fn takeResult(self: *const Control, buttons: MouseButtons) ?i32 {
        if (!self.presented or buttons.any()) return null;

        return self.result;
    }
};

pub const Popup = struct {
    background: []u8,
    palette: [256]u32,
    fonts: [2]Font,
    mission_labels: [7][]const u8,
    quit_labels: [3][]const u8,
    cursor: nwx.Costume,
    cursor_playback: nwx.Playback,
    control: Control,

    pub fn init(
        a: std.mem.Allocator,
        archive: lab.Archive,
        pixels: []const u8,
        source_palette: [256]u32,
        mouse: Mouse,
    ) !Popup {
        if (pixels.len != width * height) return error.InvalidFramebuffer;

        var self = try load(a, archive, mouse);
        errdefer self.deinit(a);

        self.background = try a.alloc(u8, pixels.len);
        const map = backgroundMap(source_palette, self.palette);

        for (pixels, self.background) |pixel, *out| out.* = map[pixel];

        return self;
    }

    pub fn load(a: std.mem.Allocator, archive: lab.Archive, mouse: Mouse) !Popup {
        const image = try pcx.decode(a, try archive.find("POP_PAL.PCX", 0x50435850));
        defer image.deinit(a);
        const text = try archive.find("LOCAL.MSG", 0);
        var labels: [7][]const u8 = undefined;

        for (&labels, 0..) |*label, i| label.* = try messages.lookup(text, @intCast(6050 + i));

        var quit_labels: [3][]const u8 = undefined;

        for (&quit_labels, 0..) |*label, i| label.* = try messages.lookup(text, @intCast(6030 + i));

        var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
        errdefer cursor.deinit();
        var playback = nwx.Playback{};

        try playback.select(&cursor, 0, 0, null);

        return .{
            .background = &.{},
            .palette = image.palette,
            .fonts = .{
                try Font.init(try archive.find("mf3x.laf", 0x4e464e54)),
                try Font.init(try archive.find("sf3.laf", 0x4e464e54)),
            },
            .mission_labels = labels,
            .quit_labels = quit_labels,
            .cursor = cursor,
            .cursor_playback = playback,
            .control = Control.init(.mission, mouse),
        };
    }

    pub fn deinit(self: *Popup, a: std.mem.Allocator) void {
        self.cursor.deinit();
        a.free(self.background);
    }

    pub fn open(self: *Popup, kind: Kind, mouse: Mouse) void {
        self.control = Control.init(kind, mouse);
    }

    pub fn spacing(self: *const Popup) i32 {
        return @divTrunc(self.fonts[1].height * 7, 6);
    }

    pub fn top(self: *const Popup) i32 {
        var size = self.fonts[1].height + self.spacing() * (self.control.count() - 1);
        if (self.control.kind == .quit) size += @divTrunc(self.fonts[0].height * 7, 6);

        return @divTrunc(height - size, 2);
    }

    pub fn firstRow(self: *const Popup) i32 {
        return self.top() + if (self.control.kind == .quit) self.spacing() - self.fonts[1].height + self.fonts[0].height else @as(i32, 0);
    }

    pub fn frame(self: *Popup, pixels: []u8, mouse: Mouse, key: Key) !void {
        if (pixels.len != self.background.len) return error.InvalidFramebuffer;

        @memcpy(pixels, self.background);

        const normal = translation(0x2d);
        const selected = translation(0x1d);

        if (self.control.kind == .quit)
            try self.fonts[0].drawCentered(
                pixels,
                width,
                height,
                self.quit_labels[0],
                width / 2,
                self.top() + self.fonts[0].baseline,
                &normal,
            );

        const labels: []const []const u8 = if (self.control.kind == .mission) &self.mission_labels else self.quit_labels[1..];

        for (labels, 0..) |label, i| {
            const y = self.firstRow() + @as(
                i32,
                @intCast(i),
            ) * self.spacing() + self.fonts[1].baseline;

            try self.fonts[1].drawCentered(
                pixels,
                width,
                height,
                label,
                width / 2,
                y,
                if (self.control.selected == i) &selected else &normal,
            );
        }

        self.control.update(mouse, key, self.firstRow(), self.spacing());
        const pointer = self.control.mouse;

        if (pointer.x != 0 and pointer.y != 0) {
            const frame_def = try self.cursor.select(
                self.cursor_playback.choreography,
                self.cursor_playback.frame,
                0,
                0,
            );

            try hud.blit(
                pixels,
                width,
                height,
                &self.cursor,
                frame_def,
                .{ .x = pointer.x, .y = pointer.y },
                .{ .width = width, .height = height },
            );
        }
    }

    pub fn paletteAt(self: *const Popup, now: u32) [256]u32 {
        var palette = self.palette;
        const phase = (now / 5) % 40;
        const percent: i32 = @intCast(if (phase < 20) 100 - phase else phase + 60);

        for (0..8) |i| palette[228 + i] = interpolate(
            self.palette[212 + i],
            self.palette[228 + i],
            percent,
        );

        return palette;
    }
};

pub fn translation(offset: u8) [256]u8 {
    var table: [256]u8 = undefined;
    table[0] = 0;
    for (1..256) |i| table[i] = @as(u8, @intCast(i)) -% offset;

    return table;
}

pub fn backgroundMap(source: [256]u32, destination: [256]u32) [256]u8 {
    var map: [256]u8 = undefined;

    for (source, &map) |color, *out| {
        const rgb = channels(color);
        const brightness = @divTrunc(rgb[0] * 3 + rgb[1] * 5 + rgb[2] * 2, 10);
        var best: i32 = std.math.maxInt(i32);

        out.* = 1;

        for (1..50) |i| {
            if (best < 1) break;

            const target = channels(destination[i]);
            const delta = brightness - @divTrunc(target[0] * 3 + target[1] * 5 + target[2] * 2, 10);
            var distance = delta * delta;

            for (rgb, target) |a, b| distance += (a - b) * (a - b);

            if (distance < best) {
                best = distance;
                out.* = @intCast(i);
            }
        }
    }

    return map;
}

fn channels(color: u32) [3]i32 {
    return .{ @intCast(color & 255), @intCast((color >> 8) & 255), @intCast((color >> 16) & 255) };
}

fn interpolate(from: u32, to: u32, percent: i32) u32 {
    var result: u32 = 0;

    inline for (.{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((from >> shift) & 255);
        const b: i32 = @intCast((to >> shift) & 255);

        result |= @as(
            u32,
            @intCast(std.math.clamp(a + @divTrunc((b - a) * percent, 100), 0, 255)),
        ) << shift;
    }

    return result;
}
