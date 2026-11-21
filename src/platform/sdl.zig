//! The window, the input and the presentation boundary. Every game pixel is
//! already composed by engine code before it gets here.
//!
//! Presented palettes are the raw palette run through the gamma and
//! brightness table. This module and its neighbours are the only places
//! that may touch SDL.

const std = @import("std");
const title = @import("../game/title.zig");
const builtin = @import("builtin");
const input = @import("../player/input.zig");
const automap = @import("../render/automap.zig");
const display_palette = @import("../render/display_palette.zig");

const window_caption = title.current.name ++ "";

pub const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL.h");
});

pub const Window = struct {
    handle: *c.SDL_Window,
    surface: *c.SDL_Surface,
    display: ?*const display_palette.Display = null,

    pub fn init(pixels: []u8, width: usize, height: usize) !Window {
        c.SDL_SetMainReady();
        if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_TIMER) != 0) return fail();
        errdefer c.SDL_Quit();
        const window = c.SDL_CreateWindow(window_caption, c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, @intCast(width), @intCast(height), c.SDL_WINDOW_SHOWN) orelse return fail();
        errdefer c.SDL_DestroyWindow(window);
        const surface = c.SDL_CreateRGBSurfaceFrom(pixels.ptr, @intCast(width), @intCast(height), 8, @intCast(width), 0, 0, 0, 0) orelse return fail();
        return .{ .handle = window, .surface = surface };
    }

    pub fn deinit(self: Window) void {
        c.SDL_FreeSurface(self.surface);
        c.SDL_DestroyWindow(self.handle);
        c.SDL_Quit();
    }

    pub fn present(self: Window, raw: *const [256]u32) !void {
        const converted = if (self.display) |display| display.convert(raw) else raw.*;
        var colors: [256]c.SDL_Color = undefined;
        for (&converted, &colors) |rgb, *color| color.* = .{
            .r = @truncate(rgb),
            .g = @truncate(rgb >> 8),
            .b = @truncate(rgb >> 16),
            .a = 255,
        };
        if (c.SDL_SetPaletteColors(self.surface.format.*.palette, &colors, 0, 256) != 0) return fail();
        const destination = c.SDL_GetWindowSurface(self.handle) orelse return fail();
        if (c.SDL_BlitSurface(self.surface, null, destination, null) != 0) return fail();
        if (c.SDL_UpdateWindowSurface(self.handle) != 0) return fail();
    }
};

pub const PlayerInput = struct {
    state: input.State = .{},
    map_input: automap.Input = .{},
    capture_map_arrows: bool = false,
    last_sample: u32 = 0,
    focused: bool = false,
    started: bool = false,
    motion_x: i32 = 0,
    motion_y: i32 = 0,
    buttons: u3 = 0,

    pub const Sample = struct { packet: input.Packet, map_input: automap.Input, elapsed_ms: u32 };

    pub fn begin(self: *PlayerInput, now_ms: u32) !void {
        self.* = .{ .last_sample = now_ms, .focused = true, .started = true };
        try self.capture(now_ms);
    }

    pub fn deinit(self: *PlayerInput) void {
        if (self.started) _ = c.SDL_SetRelativeMouseMode(c.SDL_FALSE);
        self.started = false;
        self.focused = false;
    }

    pub fn suspendMenu(self: *PlayerInput) void {
        self.deinit();
    }

    pub fn menuEvent(self: *PlayerInput, value: *const c.SDL_Event, context_active: bool) void {
        if (value.type != c.SDL_KEYDOWN and value.type != c.SDL_KEYUP) return;
        const scan = gameScanCode(value.key.keysym.scancode) orelse return;
        const down = value.type == c.SDL_KEYDOWN;
        if (context_active and down and scan != 42 and scan != 54) return;
        if (context_active) self.map_input.down[scan] = down else self.map_input.key(scan, down);
        const captured = self.capture_map_arrows and (scan == 72 or scan == 80 or scan == 75 or scan == 77);
        if (!down or !captured) self.state.key(scan, down, value.key.timestamp);
    }

    pub fn movieEvent(self: *PlayerInput, value: *const c.SDL_Event) void {
        if (value.type != c.SDL_KEYUP) return;
        const scan = gameScanCode(value.key.keysym.scancode) orelse return;
        self.map_input.down[scan] = false;
        self.state.key(scan, false, value.key.timestamp);
    }

    pub fn resumeMenu(self: *PlayerInput) !void {
        try self.captureMouse();
        self.started = true;
        self.focused = true;
    }

    pub fn clearLevelKeys(self: *PlayerInput) void {
        self.state.keys = @splat(.{});
        self.map_input = .{};
        self.capture_map_arrows = false;
    }

    pub fn event(self: *PlayerInput, value: *const c.SDL_Event) !void {
        if (!self.started) return;
        const now_ms = value.common.timestamp;
        if (value.type == c.SDL_WINDOWEVENT) {
            switch (value.window.event) {
                c.SDL_WINDOWEVENT_FOCUS_LOST => {
                    for (self.state.keys, 0..) |key_state, scan| {
                        if (key_state.down) self.state.key(@intCast(scan), false, now_ms);
                    }
                    self.map_input.down = @splat(false);
                    self.focused = false;
                    self.motion_x = 0;
                    self.motion_y = 0;
                    self.buttons = 0;
                    if (c.SDL_SetRelativeMouseMode(c.SDL_FALSE) != 0) return fail();
                },
                c.SDL_WINDOWEVENT_FOCUS_GAINED => {
                    self.last_sample = now_ms;
                    self.state = .{};
                    self.map_input = .{};
                    self.focused = true;
                    try self.capture(now_ms);
                },
                else => {},
            }
            return;
        }
        if (!self.focused) return;
        switch (value.type) {
            c.SDL_KEYDOWN, c.SDL_KEYUP => {
                if (gameScanCode(value.key.keysym.scancode)) |scan| {
                    const down = value.type == c.SDL_KEYDOWN;
                    self.map_input.key(scan, down);
                    const captured = self.capture_map_arrows and (scan == 72 or scan == 80 or scan == 75 or scan == 77);
                    if (!down or !captured) self.state.key(scan, down, now_ms);
                }
            },
            c.SDL_MOUSEMOTION => {
                self.motion_x +%= value.motion.xrel;
                self.motion_y +%= value.motion.yrel;
            },
            c.SDL_MOUSEBUTTONDOWN, c.SDL_MOUSEBUTTONUP => {
                const mask: u3 = switch (value.button.button) {
                    c.SDL_BUTTON_LEFT => 1,
                    c.SDL_BUTTON_RIGHT => 2,
                    c.SDL_BUTTON_MIDDLE => 4,
                    else => 0,
                };
                if (value.type == c.SDL_MOUSEBUTTONDOWN) self.buttons |= mask else self.buttons &= ~mask;
            },
            else => {},
        }
    }

    pub fn sample(self: *PlayerInput, now_ms: u32) !?Sample {
        if (!self.started or !self.focused) return null;
        const elapsed = now_ms -% self.last_sample;
        if (elapsed == 0) return null;
        const packet = try self.state.sample(now_ms, .{ .dx = self.motion_x, .dy = self.motion_y, .buttons = self.buttons });
        self.motion_x = 0;
        self.motion_y = 0;
        self.last_sample = now_ms;
        const map_input = self.map_input;
        self.map_input.read = self.map_input.written;
        return .{ .packet = packet, .map_input = map_input, .elapsed_ms = elapsed };
    }

    pub fn sampleIdle(self: *PlayerInput, now_ms: u32) ?Sample {
        if (!self.started or self.focused) return null;
        const elapsed = now_ms -% self.last_sample;
        if (elapsed == 0) return null;
        self.last_sample = now_ms;
        return .{ .packet = .{}, .map_input = .{}, .elapsed_ms = elapsed };
    }

    fn capture(self: *PlayerInput, now_ms: u32) !void {
        try self.captureMouse();
        var count: c_int = 0;
        const held = c.SDL_GetKeyboardState(&count);
        for (0..@intCast(count)) |i| {
            if (held[i] == 0) continue;
            if (gameScanCode(@intCast(i))) |scan| {
                self.state.key(scan, true, now_ms);
                self.map_input.key(scan, true);
            }
        }
    }

    fn captureMouse(self: *PlayerInput) !void {
        if (c.SDL_SetRelativeMouseMode(c.SDL_TRUE) != 0) return fail();
        c.SDL_PumpEvents();
        c.SDL_FlushEvent(c.SDL_MOUSEMOTION);
        _ = c.SDL_GetRelativeMouseState(null, null);
        self.motion_x = 0;
        self.motion_y = 0;
        const buttons = c.SDL_GetMouseState(null, null);
        self.buttons = @as(u3, @intFromBool(buttons & c.SDL_BUTTON_LMASK != 0)) |
            (@as(u3, @intFromBool(buttons & c.SDL_BUTTON_RMASK != 0)) << 1) |
            (@as(u3, @intFromBool(buttons & c.SDL_BUTTON_MMASK != 0)) << 2);
    }
};

pub fn presentRgb(window: Window, rgb: []u32, width: u32, height: u32) !void {
    const frame = c.SDL_CreateRGBSurfaceFrom(rgb.ptr, @intCast(width), @intCast(height), 32, @intCast(width * 4), 0x00ff0000, 0x0000ff00, 0x000000ff, 0) orelse return fail();
    defer c.SDL_FreeSurface(frame);
    const destination = c.SDL_GetWindowSurface(window.handle) orelse return fail();
    if (c.SDL_BlitScaled(frame, null, destination, null) != 0) return fail();
    if (c.SDL_UpdateWindowSurface(window.handle) != 0) return fail();
}

pub fn gameScanCode(scan: c.SDL_Scancode) ?u7 {
    return switch (scan) {
        c.SDL_SCANCODE_ESCAPE => 1,
        c.SDL_SCANCODE_1 => 2,
        c.SDL_SCANCODE_2 => 3,
        c.SDL_SCANCODE_3 => 4,
        c.SDL_SCANCODE_4 => 5,
        c.SDL_SCANCODE_5 => 6,
        c.SDL_SCANCODE_6 => 7,
        c.SDL_SCANCODE_7 => 8,
        c.SDL_SCANCODE_8 => 9,
        c.SDL_SCANCODE_9 => 10,
        c.SDL_SCANCODE_0 => 11,
        c.SDL_SCANCODE_MINUS => 12,
        c.SDL_SCANCODE_EQUALS => 13,
        c.SDL_SCANCODE_BACKSPACE => 14,
        c.SDL_SCANCODE_TAB => 15,
        c.SDL_SCANCODE_Q => 16,
        c.SDL_SCANCODE_W => 17,
        c.SDL_SCANCODE_E => 18,
        c.SDL_SCANCODE_R => 19,
        c.SDL_SCANCODE_T => 20,
        c.SDL_SCANCODE_Y => 21,
        c.SDL_SCANCODE_U => 22,
        c.SDL_SCANCODE_I => 23,
        c.SDL_SCANCODE_O => 24,
        c.SDL_SCANCODE_P => 25,
        c.SDL_SCANCODE_LEFTBRACKET => 26,
        c.SDL_SCANCODE_RIGHTBRACKET => 27,
        c.SDL_SCANCODE_RETURN, c.SDL_SCANCODE_KP_ENTER => 28,
        c.SDL_SCANCODE_LCTRL, c.SDL_SCANCODE_RCTRL => 29,
        c.SDL_SCANCODE_A => 30,
        c.SDL_SCANCODE_S => 31,
        c.SDL_SCANCODE_D => 32,
        c.SDL_SCANCODE_F => 33,
        c.SDL_SCANCODE_G => 34,
        c.SDL_SCANCODE_H => 35,
        c.SDL_SCANCODE_J => 36,
        c.SDL_SCANCODE_K => 37,
        c.SDL_SCANCODE_L => 38,
        c.SDL_SCANCODE_SEMICOLON => 39,
        c.SDL_SCANCODE_APOSTROPHE => 40,
        c.SDL_SCANCODE_GRAVE => 41,
        c.SDL_SCANCODE_LSHIFT => 42,
        c.SDL_SCANCODE_BACKSLASH => 43,
        c.SDL_SCANCODE_Z => 44,
        c.SDL_SCANCODE_X => 45,
        c.SDL_SCANCODE_C => 46,
        c.SDL_SCANCODE_V => 47,
        c.SDL_SCANCODE_B => 48,
        c.SDL_SCANCODE_N => 49,
        c.SDL_SCANCODE_M => 50,
        c.SDL_SCANCODE_COMMA => 51,
        c.SDL_SCANCODE_PERIOD => 52,
        c.SDL_SCANCODE_SLASH, c.SDL_SCANCODE_KP_DIVIDE => 53,
        c.SDL_SCANCODE_RSHIFT => 54,
        c.SDL_SCANCODE_KP_MULTIPLY => 55,
        c.SDL_SCANCODE_LALT, c.SDL_SCANCODE_RALT => 56,
        c.SDL_SCANCODE_SPACE => 57,
        c.SDL_SCANCODE_CAPSLOCK => 58,
        c.SDL_SCANCODE_F1 => 59,
        c.SDL_SCANCODE_F2 => 60,
        c.SDL_SCANCODE_F3 => 61,
        c.SDL_SCANCODE_F4 => 62,
        c.SDL_SCANCODE_F5 => 63,
        c.SDL_SCANCODE_F6 => 64,
        c.SDL_SCANCODE_F7 => 65,
        c.SDL_SCANCODE_F8 => 66,
        c.SDL_SCANCODE_F9 => 67,
        c.SDL_SCANCODE_F10 => 68,
        c.SDL_SCANCODE_NUMLOCKCLEAR => 69,
        c.SDL_SCANCODE_SCROLLLOCK => 70,
        c.SDL_SCANCODE_HOME, c.SDL_SCANCODE_KP_7 => 71,
        c.SDL_SCANCODE_UP, c.SDL_SCANCODE_KP_8 => 72,
        c.SDL_SCANCODE_PAGEUP, c.SDL_SCANCODE_KP_9 => 73,
        c.SDL_SCANCODE_KP_MINUS => 74,
        c.SDL_SCANCODE_LEFT, c.SDL_SCANCODE_KP_4 => 75,
        c.SDL_SCANCODE_KP_5 => 76,
        c.SDL_SCANCODE_RIGHT, c.SDL_SCANCODE_KP_6 => 77,
        c.SDL_SCANCODE_KP_PLUS => 78,
        c.SDL_SCANCODE_END, c.SDL_SCANCODE_KP_1 => 79,
        c.SDL_SCANCODE_DOWN, c.SDL_SCANCODE_KP_2 => 80,
        c.SDL_SCANCODE_PAGEDOWN, c.SDL_SCANCODE_KP_3 => 81,
        c.SDL_SCANCODE_INSERT, c.SDL_SCANCODE_KP_0 => 82,
        c.SDL_SCANCODE_DELETE, c.SDL_SCANCODE_KP_PERIOD => 83,
        c.SDL_SCANCODE_SYSREQ => 84,
        else => null,
    };
}

fn fail() error{SdlFailure} {
    std.log.err("SDL2: {s}", .{c.SDL_GetError()});
    return error.SdlFailure;
}

test "an unfocused network game gets frames without input" {
    var player: PlayerInput = .{ .started = true, .focused = false, .last_sample = 100 };
    const idle = player.sampleIdle(150) orelse return error.NoIdleFrame;
    try std.testing.expectEqual(@as(u32, 50), idle.elapsed_ms);
    try std.testing.expectEqualDeep(input.Packet{}, idle.packet);
    try std.testing.expectEqual(@as(u32, 150), player.last_sample);
    try std.testing.expect(player.sampleIdle(150) == null);
    player.focused = true;
    try std.testing.expect(player.sampleIdle(200) == null);
}

test "mission popup propagates releases and shift while retaining gameplay input history" {
    var host: PlayerInput = .{ .last_sample = 1000 };
    host.state.previous_time = 900;
    host.state.key(29, true, 901);
    host.state.key(72, true, 901);
    _ = try host.state.sample(1000, .{ .buttons = 1 });
    const previous = host.state.previous;
    host.suspendMenu();
    var event = std.mem.zeroes(c.SDL_Event);
    event.key.type = c.SDL_KEYUP;
    event.key.timestamp = 1100;
    event.key.keysym.scancode = c.SDL_SCANCODE_LCTRL;
    host.menuEvent(&event, true);
    event.key.keysym.scancode = c.SDL_SCANCODE_UP;
    host.menuEvent(&event, true);
    try std.testing.expect(!host.state.keys[29].down and !host.state.keys[72].down);
    event.key.type = c.SDL_KEYDOWN;
    event.key.timestamp = 1200;
    for ([_]c.SDL_Scancode{ c.SDL_SCANCODE_LCTRL, c.SDL_SCANCODE_UP, c.SDL_SCANCODE_TAB }) |scan| {
        event.key.keysym.scancode = scan;
        host.menuEvent(&event, true);
    }
    try std.testing.expect(!host.state.keys[29].down and !host.state.keys[72].down and !host.state.keys[15].down);
    event.key.keysym.scancode = c.SDL_SCANCODE_LSHIFT;
    host.menuEvent(&event, true);
    try std.testing.expect(host.state.keys[42].down);
    try std.testing.expectEqualSlices(bool, &previous, &host.state.previous);
    try std.testing.expectEqual(@as(u3, 1), host.state.mouse_previous);
    try std.testing.expectEqual(@as(u32, 1000), host.state.previous_time);
    try std.testing.expectEqual(@as(u32, 1000), host.last_sample);
    var packet = try host.state.sample(2000, .{});
    try std.testing.expect(packet.get(.fire).flags & input.released != 0);
    packet = try host.state.sample(2016, .{});
    try std.testing.expect(packet.get(.fire).flags & input.released != 0);
    try std.testing.expect(packet.get(.forward).flags & input.released != 0);
    event.key.timestamp = 2020;
    event.key.keysym.scancode = c.SDL_SCANCODE_LCTRL;
    host.menuEvent(&event, false);
    try std.testing.expect(host.state.keys[29].down);
    const retained_actions = host.state.previous;
    const retained_mouse = host.state.mouse_previous;
    host.capture_map_arrows = true;
    host.map_input.key(72, true);
    host.clearLevelKeys();
    try std.testing.expect(!host.state.keys[29].down);
    try std.testing.expect(!host.capture_map_arrows);
    try std.testing.expectEqual(@as(u32, 0), host.map_input.written);
    try std.testing.expectEqual(@as(u32, 2016), host.state.previous_time);
    try std.testing.expectEqualSlices(bool, &retained_actions, &host.state.previous);
    try std.testing.expectEqual(retained_mouse, host.state.mouse_previous);
}
