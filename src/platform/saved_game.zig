//! The host side of saved games: where the save directory is, and the
//! blocking loop around the save and load menus.
//!
//! The directory sits next to the executable and slot files keep their
//! numbered names. A title is uppercased and cut at the first control byte,
//! and a thumbnail is only accepted at exactly the expected size. Rendering
//! and input decisions stay in save/menu.zig.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const native = @import("../save/menu.zig");
const stream = @import("../save/stream.zig");
const sdl = @import("sdl.zig");
const mission_menu = @import("mission_menu.zig");
const Runtime = @import("../audio/runtime.zig").Runtime;
const Device = @import("audio.zig").Device;
const c = sdl.c;

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    directory: []const u8,
    slots: [9]native.Slot = @splat(.{}),
    files: [9]?[]const u8 = @splat(null),

    pub fn open(a: std.mem.Allocator, io: std.Io) !Catalog {
        var result: Catalog = .{ .arena = std.heap.ArenaAllocator.init(a), .directory = undefined };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        const executable_directory = try std.process.executableDirPathAlloc(io, arena);
        result.directory = try std.fs.path.join(arena, &.{ executable_directory, "SAVE" });
        for (0..9) |slot| {
            const path = try result.filename(arena, slot);
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            result.slots[slot] = readSlot(bytes) catch |err| {
                std.log.err("save slot {d}: {s}", .{ slot, @errorName(err) });
                continue;
            };
            result.files[slot] = bytes;
        }
        return result;
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }

    pub fn write(self: *const Catalog, a: std.mem.Allocator, io: std.Io, slot: usize, bytes: []const u8) !void {
        const path = try self.filename(a, slot);
        defer a.free(path);
        try std.Io.Dir.cwd().createDirPath(io, self.directory);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    fn filename(self: *const Catalog, a: std.mem.Allocator, slot: usize) ![]u8 {
        if (slot >= 9) return error.InvalidSaveSlot;
        var name: [11]u8 = "SAVE000.OSG".*;
        name[6] = '0' + @as(u8, @intCast(slot));
        return std.fs.path.join(a, &.{ self.directory, &name });
    }
};

pub const Selection = struct { slot: u4, description: [15]u8, thumbnail: ?[]u8 };

pub const Result = union(enum) { cancel, quit, frame_limit, selection: Selection };

pub fn run(a: std.mem.Allocator, archive: lab.Archive, mode: native.Mode, catalog: *const Catalog, window: sdl.Window, pixels: []u8, palette: *[256]u32, source: []const u8, source_palette: [256]u32, input: *sdl.PlayerInput, audio: *Runtime, device: *Device, frames: *usize, frame_limit: ?usize) !Result {
    input.suspendMenu();
    _ = c.SDL_ShowCursor(c.SDL_DISABLE);
    defer _ = c.SDL_ShowCursor(c.SDL_ENABLE);
    audio.pauseMusic(c.SDL_GetTicks());
    defer audio.resumeMusic(c.SDL_GetTicks());
    var dialog = try native.Dialog.init(a, archive, mode, &catalog.slots, source, source_palette);
    defer dialog.deinit(a);
    var scans: [32]u8 = @splat(0);
    var written: u32 = 0;
    var read: u32 = 0;
    var left_pressed = false;
    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) return .quit;
            input.menuEvent(&event, dialog.control.result == null);
            if (event.type == c.SDL_MOUSEBUTTONDOWN and event.button.button == c.SDL_BUTTON_LEFT) left_pressed = true;
            if (event.type != c.SDL_KEYDOWN or dialog.control.result != null) continue;
            if (sdl.gameScanCode(event.key.keysym.scancode)) |scan| {
                written +%= 1;
                scans[written & 31] = scan;
            }
        }
        var mouse = mission_menu.mouseState();
        if (left_pressed) mouse.buttons |= 1;
        left_pressed = false;
        if (dialog.control.result == null) {
            var key: native.Key = .{};
            if (@as(i32, @bitCast(read)) < @as(i32, @bitCast(written))) {
                read +%= 1;
                key = .{ .scan = scans[read & 31], .shift = c.SDL_GetModState() & c.KMOD_SHIFT != 0 };
            }
            try dialog.frame(pixels, mouse, key);
            if (dialog.control.takeSound())
                _ = try audio.play(.{ .basename = "RIFLOUT.WAV", .priority = 64, .volume = 127, .flags = 4 }, null, c.SDL_GetTicks());
            try device.sync(audio);
            palette.* = dialog.background.palette;
            try window.present(palette);
            dialog.control.presented = true;
            frames.* += 1;
            if (frame_limit) |limit| if (frames.* >= limit) return .frame_limit;
        }
        if (dialog.control.takeResult(mission_menu.mouseState().buttons)) |action| switch (action) {
            .cancel => return .cancel,
            .slot => |slot| return .{ .selection = .{
                .slot = slot,
                .description = dialog.control.description[0..15].*,
                .thumbnail = if (mode == .save) try dialog.diskThumbnail(a) else null,
            } },
        };
        try device.sync(audio);
        c.SDL_Delay(16);
    }
}

fn readSlot(bytes: []const u8) !native.Slot {
    var reader: stream.Reader = .{ .bytes = bytes };
    try reader.marker(0x42534c4f, 1, 2);
    var slot: native.Slot = .{};
    try reader.read(slot.description[0..15]);
    for (&slot.description) |*byte| {
        if (byte.* < 32) {
            byte.* = 0;
            break;
        }
        byte.* = std.ascii.toUpper(byte.*);
    }
    const width = try reader.integer(u32);
    const height = try reader.integer(u32);
    const count = std.math.mul(u32, width, height) catch return error.InvalidSaveThumbnail;
    if (count > bytes.len - reader.position) return error.TruncatedSaveGame;
    if (width == native.thumbnail_width and height == native.thumbnail_height)
        slot.thumbnail = bytes[reader.position..][0..count];
    return slot;
}
