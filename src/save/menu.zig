//! The save and load menus: nine slots, each selectable.
//!
//! The screen is drawn before input is handled, so activating uses the
//! selection from the previous frame - including when the mouse re-selects
//! the row it is already on.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const pcx = @import("../assets/pcx.zig");
const Font = @import("../assets/font.zig").Font;
const messages = @import("../assets/messages.zig");
const nwx = @import("../assets/nwx.zig");
const hud = @import("../render/hud.zig");
const popup = @import("../ui/mission_menu.zig");

pub const thumbnail_width = 276;

pub const thumbnail_height = 208;

pub const Mode = enum { save, load };

pub const Slot = struct {
    description: [16]u8 = @splat(0),
    thumbnail: ?[]const u8 = null,

    pub fn title(self: *const Slot) []const u8 {
        return std.mem.sliceTo(&self.description, 0);
    }
};

pub const Key = struct { scan: u8 = 0, shift: bool = false };

pub const Action = union(enum) { cancel, slot: u4 };

pub const Control = struct {
    mode: Mode,
    selected: i32 = 0,
    editing: bool = false,
    cancel_hover: bool = false,
    mouse: popup.Mouse = .{ .x = -1, .y = -1 },
    description: [16]u8 = @splat(0),
    result: ?Action = null,
    sound: bool = false,
    presented: bool = false,

    pub fn init(mode: Mode, slots: *const [9]Slot) Control {
        return .{ .mode = mode, .description = slots[0].description };
    }

    pub fn update(self: *Control, slots: *const [9]Slot, pointer: popup.Mouse, input: Key) void {
        if (self.result != null) return;

        const mouse: popup.Mouse = .{
            .x = std.math.clamp(pointer.x, 0, 639),
            .y = std.math.clamp(pointer.y, 0, 479),
            .buttons = pointer.buttons,
        };

        const moved = mouse.x != self.mouse.x or mouse.y != self.mouse.y;

        self.mouse = mouse;
        if (mouse.buttons > 1) {
            self.result = .cancel;
            return;
        }

        const cancel = mouse.x >= 440 and mouse.x <= 569 and mouse.y >= 411 and mouse.y <= 432;
        self.cancel_hover = cancel;

        var next: ?i32 = null;
        var scan = input.scan;

        if ((moved and (self.mode == .load or !self.editing)) or mouse.buttons & 1 != 0) {
            if (cancel) {
                next = 9;
                if (mouse.buttons & 1 != 0) scan = 1;
            } else if (mouse.x > 399 and mouse.x < 601) {
                const row = @divTrunc(mouse.y - 40, 40);
                next = if (row < 9) row else self.selected;

                if (row < 9 and mouse.buttons & 1 != 0) {
                    if (self.mode == .save) self.editing = true else scan = 28;
                }
            }
        }

        if (self.mode == .save and scan == 15) scan = if (input.shift) 72 else 80;

        switch (scan) {
            0 => {},
            1 => self.result = .cancel,
            28 => {
                if (self.mode == .save and !self.editing and self.selected < 9) {
                    self.editing = true;
                } else if (self.selected >= 0) {
                    const text = if (self.mode == .save) std.mem.sliceTo(
                        &self.description,
                        0,
                    ) else if (self.selected < 9) slots[@intCast(self.selected)].title() else "";

                    self.result = if (self.selected < 9 and text.len != 0) .{
                        .slot = @intCast(self.selected),
                    } else .cancel;
                }
            },
            72 => {
                next = if (self.selected == 0) 9 else self.selected - 1;
                if (self.mode == .save) self.editing = false;
            },
            80 => {
                next = if (self.selected + 1 > 9) 0 else self.selected + 1;
                if (self.mode == .save) self.editing = false;
            },
            else => if (self.mode == .save and self.selected != -1) {
                self.editing = true;

                const byte = character(scan, input.shift);
                const length = std.mem.sliceTo(&self.description, 0).len;

                if (byte == 8) {
                    if (length != 0) self.description[length - 1] = 0;
                } else if (byte > 31 and length < 14) {
                    self.description[length] = byte;
                    self.description[length + 1] = 0;
                }
            },
        }

        if (next) |selected| {
            self.sound = self.selected != selected;
            self.selected = selected;
            if (self.mode == .save and selected >= 0 and selected < 9)
                self.description = slots[@intCast(selected)].description;
        }
    }

    pub fn takeSound(self: *Control) bool {
        const value = self.sound;
        self.sound = false;

        return value;
    }

    pub fn takeResult(self: *const Control, buttons: u32) ?Action {
        return if (self.presented and buttons == 0) self.result else null;
    }
};

pub const Dialog = struct {
    background: pcx.Image,
    fonts: [2]Font,
    labels: [3][]const u8,
    slots: *const [9]Slot,
    preview: []u8,
    cursor: nwx.Costume,
    cursor_playback: nwx.Playback,
    control: Control,

    pub fn init(
        a: std.mem.Allocator,
        archive: lab.Archive,
        mode: Mode,
        slots: *const [9]Slot,
        source: []const u8,
        source_palette: [256]u32,
    ) !Dialog {
        const background = try pcx.decode(a, try archive.find("SAVEMENU.PCX", 0x50424d50));
        errdefer background.deinit(a);
        if (background.width != 640 or background.height != 480) return error.UnsupportedMenuDimensions;

        const preview = try a.alloc(u8, thumbnail_width * thumbnail_height);
        errdefer a.free(preview);

        @memset(preview, 0);

        if (mode == .save) {
            if (source.len != 640 * 480) return error.InvalidFramebuffer;

            const map = thumbnailMap(source_palette, background.palette);

            for (0..thumbnail_height) |y| for (0..thumbnail_width) |x| {
                preview[y * thumbnail_width + x] = map[source[(y * 480 / thumbnail_height) * 640 + x * 640 / thumbnail_width]];
            };
        }

        const local = try archive.find("LOCAL.MSG", 0);
        var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
        errdefer cursor.deinit();
        var playback = nwx.Playback{};

        try playback.select(&cursor, 0, 0, null);

        return .{
            .background = background,
            .fonts = .{
                try Font.init(try archive.find("F24.LAF", 0x4e464e54)),
                try Font.init(try archive.find("FL3X.LAF", 0x4e464e54)),
            },
            .labels = .{
                try messages.lookup(local, if (mode == .save) 5018 else 5017),
                try messages.lookup(local, 7110),
                try messages.lookup(local, 5075),
            },
            .slots = slots,
            .preview = preview,
            .cursor = cursor,
            .cursor_playback = playback,
            .control = Control.init(mode, slots),
        };
    }

    pub fn deinit(self: *Dialog, a: std.mem.Allocator) void {
        self.background.deinit(a);
        a.free(self.preview);
        self.cursor.deinit();
    }

    pub fn frame(self: *Dialog, pixels: []u8, mouse: popup.Mouse, key: Key) !void {
        if (pixels.len != 640 * 480) return error.InvalidFramebuffer;

        @memcpy(pixels, self.background.pixels);

        if (self.control.mode == .load) {
            @memset(self.preview, 0);

            if (self.control.selected >= 0 and self.control.selected < 9) {
                if (self.slots[@intCast(self.control.selected)].thumbnail) |preview| {
                    if (preview.len != self.preview.len) return error.InvalidSaveThumbnail;
                    for (self.preview, preview) |*out, byte| out.* = byte -% 98;
                }
            }
        }

        if (self.control.selected != -1 or self.control.mode == .save) for (0..thumbnail_height) |y| {
            @memcpy(
                pixels[(207 + y) * 640 + 58 ..][0..thumbnail_width],
                self.preview[y * thumbnail_width ..][0..thumbnail_width],
            );
        };

        const normal = translation(156);
        const selected = translation(157);
        const editing = translation(255);
        var heading: [256]u8 = undefined;

        for (&heading, 0..) |*out, i| out.* = @as(u8, @intCast(i)) -% 29;

        heading[0] = 0;

        for (self.slots, 0..) |*slot, i| {
            const active = self.control.selected == i;
            const y: i32 = @as(i32, @intCast(i)) * 40;

            if (self.control.mode == .save and active) {
                rectangle(pixels, 399, y + 39, 204, 29);
                rectangle(pixels, 400, y + 38, 202, 31);
            }

            const text = if (self.control.mode == .save and active) std.mem.sliceTo(
                &self.control.description,
                0,
            ) else if (self.control.mode == .load and slot.title().len == 0) self.labels[2] else slot.title();

            const color = if (active and self.control.mode == .save and self.control.editing) &editing else if (active) &selected else &normal;

            try self.fonts[0].drawLeft(
                pixels,
                640,
                480,
                text,
                410,
                y + 43 + self.fonts[0].baseline,
                color,
            );

            if (active and self.control.mode == .save and self.control.editing)
                try self.fonts[0].drawLeft(
                    pixels,
                    640,
                    480,
                    "_",
                    410 + try self.fonts[0].width(text),
                    y + 43 + self.fonts[0].baseline,
                    color,
                );
        }

        const cancel_active = self.control.selected == 9 or (self.control.mode == .save and self.control.cancel_hover);

        try self.fonts[0].drawCentered(
            pixels,
            640,
            480,
            self.labels[1],
            504,
            409 + self.fonts[0].baseline,
            if (cancel_active) &selected else &normal,
        );

        try self.fonts[1].drawCentered(
            pixels,
            640,
            480,
            self.labels[0],
            200,
            47 + self.fonts[1].baseline,
            &heading,
        );

        const pointer: popup.Mouse = .{
            .x = std.math.clamp(mouse.x, 0, 639),
            .y = std.math.clamp(mouse.y, 0, 479),
            .buttons = mouse.buttons,
        };

        if (pointer.x != 0 and pointer.y != 0) {
            const frame_def = try self.cursor.select(
                self.cursor_playback.choreography,
                self.cursor_playback.frame,
                0,
                0,
            );

            try hud.blit(
                pixels,
                640,
                480,
                &self.cursor,
                frame_def,
                .{ .x = pointer.x, .y = pointer.y },
                .{ .width = 640, .height = 480 },
            );
        }

        self.control.update(self.slots, mouse, key);
    }

    pub fn diskThumbnail(self: *const Dialog, a: std.mem.Allocator) ![]u8 {
        const pixels = try a.alloc(u8, self.preview.len);
        for (pixels, self.preview) |*out, byte| out.* = byte +% 98;

        return pixels;
    }
};

pub fn thumbnailMap(source: [256]u32, destination: [256]u32) [256]u8 {
    var map: [256]u8 = undefined;

    for (source, &map) |color, *out| {
        const rgb = channels(color);
        const brightness = @divTrunc(rgb[0] * 3 + rgb[1] * 5 + rgb[2] * 2, 10);
        var best: i32 = std.math.maxInt(i32);

        out.* = 158;

        for (158..207) |i| {
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

fn character(scan: u8, shifted: bool) u8 {
    const plain = "\x00\x001234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-\x08\x00\x00+";
    const upper = "\x00\x00!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"`\x00\\ZXCVBNM<>?\x00*\x00 \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00-\x08\x00\x00+";
    const table: []const u8 = if (shifted) upper else plain;
    const index = scan & 0x7f;

    return if (index < table.len) table[index] else 0;
}

fn translation(color: u8) [256]u8 {
    var result: [256]u8 = @splat(color);
    result[0] = 0;

    return result;
}

fn rectangle(pixels: []u8, x: usize, y: i32, width: usize, height: usize) void {
    const top: usize = @intCast(y);

    @memset(pixels[top * 640 + x ..][0..width], 0);
    @memset(pixels[(top + height - 1) * 640 + x ..][0..width], 0);

    for (0..height) |row| {
        pixels[(top + row) * 640 + x] = 0;
        pixels[(top + row) * 640 + x + width - 1] = 0;
    }
}

fn channels(color: u32) [3]i32 {
    return .{ @intCast(color & 255), @intCast((color >> 8) & 255), @intCast((color >> 16) & 255) };
}

fn expectHash(bytes: []const u8, expected: []const u8) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const actual = std.fmt.bytesToHex(hash, .lower);
    try std.testing.expectEqualStrings(expected, &actual);
}

test "save and load menu frames and input match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB",
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const source = try pcx.decode(a, try archive.find("NMM.PCX", 0x50424d50));
    defer source.deinit(a);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    var slots: [9]Slot = @splat(.{});

    @memcpy(slots[0].description[0..5], "ALPHA");
    @memcpy(slots[1].description[0..4], "BETA");

    var thumbnails: [2][thumbnail_width * thumbnail_height]u8 = undefined;

    for (&thumbnails, 0..) |*thumbnail, slot| {
        for (thumbnail, 0..) |*byte, i| byte.* = @intCast((i + slot) % 49);
        slots[slot].thumbnail = thumbnail;
    }

    const Frame = struct {
        key: Key = .{},
        mouse: popup.Mouse = .{},
        selected: i32,
        editing: bool = false,
        active: bool,
        slot: ?u4 = null,
        title: ?[]const u8 = null,
        hash: []const u8,
    };

    const Case = struct { mode: Mode, frames: []const Frame };
    const cases = [_]Case{
        .{ .mode = .save, .frames = &.{
            .{
                .key = .{ .scan = 0, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 0,
                .active = true,
                .editing = false,
                .title = "ALPHA",
                .hash = "62a55ceafa157cf181e8479c0890015c9d007b64336846a975057134dbe4ebb7",
            },
            .{
                .key = .{ .scan = 28, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 0,
                .active = true,
                .editing = true,
                .title = "ALPHA",
                .hash = "62a55ceafa157cf181e8479c0890015c9d007b64336846a975057134dbe4ebb7",
            },
            .{
                .key = .{ .scan = 30, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 0,
                .active = true,
                .editing = true,
                .title = "ALPHAa",
                .hash = "53f0db43aad4d8729be4642230778acb37042bd912d0d9dc87602e96a5be216d",
            },
            .{
                .key = .{ .scan = 14, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 0,
                .active = true,
                .editing = true,
                .title = "ALPHA",
                .hash = "76d764b4ff189592cd08bb4b0cc4a74f61543d2ff412296c294feb94868fa6dc",
            },
            .{
                .key = .{ .scan = 48, .shift = true },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 0,
                .active = true,
                .editing = true,
                .title = "ALPHAB",
                .hash = "53f0db43aad4d8729be4642230778acb37042bd912d0d9dc87602e96a5be216d",
            },
            .{
                .key = .{ .scan = 28, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 0,
                .active = false,
                .editing = true,
                .title = "ALPHAB",
                .slot = 0,
                .hash = "1c5745e2c11472c1a9b75df602b97b7f44e6febb148cc4e75637e49bd8d0613e",
            },
        } },
        .{ .mode = .save, .frames = &.{
            .{
                .key = .{ .scan = 0, .shift = false },
                .mouse = .{ .x = 450, .y = 90, .buttons = 1 },
                .selected = 1,
                .active = true,
                .editing = true,
                .title = "BETA",
                .hash = "c06e400c2b2d6b339dba37e562c2fea28e0b4c4ed599ec40c2eda80fba87ce43",
            },
            .{
                .key = .{ .scan = 0, .shift = false },
                .mouse = .{ .x = 450, .y = 90, .buttons = 0 },
                .selected = 1,
                .active = true,
                .editing = true,
                .title = "BETA",
                .hash = "70512a051f0fc146833fd6823cc50937e6db54efd78028b4dcd8a3b3e0329b61",
            },
            .{
                .key = .{ .scan = 28, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 1,
                .active = false,
                .editing = true,
                .title = "BETA",
                .slot = 1,
                .hash = "9e4aec026b74c3b2628c0cd5d906ce5de563c2d5a9f0194b8a30d5556f7fe2f9",
            },
        } },
        .{ .mode = .save, .frames = &.{
            .{
                .key = .{ .scan = 72, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 9,
                .active = true,
                .editing = false,
                .title = "ALPHA",
                .hash = "62a55ceafa157cf181e8479c0890015c9d007b64336846a975057134dbe4ebb7",
            },
            .{
                .key = .{ .scan = 15, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 0,
                .active = true,
                .editing = false,
                .title = "ALPHA",
                .hash = "849e1e0c2b214c76cbc45849c14de8d8abd085fcc7a558806bda4895f5e1a094",
            },
            .{
                .key = .{ .scan = 80, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 1,
                .active = true,
                .editing = false,
                .title = "BETA",
                .hash = "62a55ceafa157cf181e8479c0890015c9d007b64336846a975057134dbe4ebb7",
            },
            .{
                .key = .{ .scan = 1, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 1,
                .active = false,
                .editing = false,
                .title = "BETA",
                .hash = "f1c58a4c418a97d139a2c8511693e8a85f1ce957fb3964f381b31a7d26121150",
            },
        } },
        .{ .mode = .load, .frames = &.{
            .{
                .key = .{ .scan = 0, .shift = false },
                .mouse = .{ .x = 450, .y = 90, .buttons = 1 },
                .selected = 1,
                .active = false,
                .slot = 0,
                .hash = "bcfb1d4d53b6fdee3bbc08af857710454b10dbbca5a5d32ff5468f5c37087661",
            },
        } },
        .{ .mode = .load, .frames = &.{
            .{
                .key = .{ .scan = 15, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 0,
                .active = true,
                .hash = "3bfe8c0fb9e896ec22a5e600f2a864f17ca02391c70ffaa6619ecded9dde4395",
            },
            .{
                .key = .{ .scan = 80, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 1,
                .active = true,
                .hash = "3bfe8c0fb9e896ec22a5e600f2a864f17ca02391c70ffaa6619ecded9dde4395",
            },
            .{
                .key = .{ .scan = 28, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 1,
                .active = false,
                .slot = 1,
                .hash = "c07b25143f1645a21faa187b918b6253d2945ef2d5031bcfe175b7d6ebb55038",
            },
        } },
        .{ .mode = .load, .frames = &.{
            .{
                .key = .{ .scan = 80, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 1,
                .active = true,
                .hash = "3bfe8c0fb9e896ec22a5e600f2a864f17ca02391c70ffaa6619ecded9dde4395",
            },
            .{
                .key = .{ .scan = 80, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 2,
                .active = true,
                .hash = "c07b25143f1645a21faa187b918b6253d2945ef2d5031bcfe175b7d6ebb55038",
            },
            .{
                .key = .{ .scan = 28, .shift = false },
                .mouse = .{ .x = 0, .y = 0, .buttons = 0 },
                .selected = 2,
                .active = false,
                .hash = "204ea4be46cace7c893400a5a4b9387d7fcea95cca2b8a10d74b6d32d16c0e29",
            },
        } },
    };

    for (cases, 0..) |case, case_index| {
        var dialog = try Dialog.init(a, archive, case.mode, &slots, source.pixels, source.palette);
        defer dialog.deinit(a);

        if (case.mode == .save) try expectHash(
            dialog.preview,
            "be95bbf7422c6e3effe48d12119991800f5911c89aca6ff02c95da9920e117f2",
        );

        for (case.frames, 0..) |frame, frame_index| {
            try dialog.frame(pixels, frame.mouse, frame.key);

            try std.testing.expectEqual(frame.selected, dialog.control.selected);
            try std.testing.expectEqual(frame.editing, dialog.control.editing);
            try std.testing.expectEqual(frame.active, dialog.control.result == null);

            if (frame.slot) |slot| try std.testing.expectEqual(slot, dialog.control.result.?.slot);

            if (frame.title) |title| try std.testing.expectEqualStrings(
                title,
                std.mem.sliceTo(&dialog.control.description, 0),
            );

            expectHash(pixels, frame.hash) catch |err| {
                std.debug.print("save menu case{d} frame{d}\n", .{ case_index, frame_index });
                try std.Io.Dir.cwd().writeFile(
                    std.testing.io,
                    .{ .sub_path = "testdata/save-menu-zig-failed.idx", .data = pixels },
                );

                return err;
            };
        }
    }
}
