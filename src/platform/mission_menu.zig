//! The host side of the in-level popup: SDL events, the clock, the sound
//! sync and presentation around the popup's own frame loop.
//!
//! Text, cursor pixels and palette work all stay in the engine. The popup
//! blocks the game loop while it is open, which is why the music is paused
//! here and resumed unless the caller takes over.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const popup = @import("../ui/mission_menu.zig");
const sdl = @import("sdl.zig");
const Runtime = @import("../audio/runtime.zig").Runtime;
const Device = @import("audio.zig").Device;
const c = sdl.c;

pub const Result = enum { resume_game, restart, end_game, options, save, load, quit, frame_limit };

pub fn mouseState() popup.Mouse {
    var mouse = popup.Mouse{};
    mouse.buttons = c.SDL_GetMouseState(&mouse.x, &mouse.y);
    return mouse;
}

pub fn opens(event: *const c.SDL_Event) bool {
    return event.type == c.SDL_KEYDOWN and
        event.key.keysym.sym == c.SDLK_ESCAPE and
        event.key.keysym.mod & (c.KMOD_SHIFT | c.KMOD_CTRL | c.KMOD_ALT) == 0;
}

pub fn run(a: std.mem.Allocator, archive: lab.Archive, window: sdl.Window, pixels: []u8, palette: *[256]u32, input: *sdl.PlayerInput, audio: *Runtime, device: *Device, frames: *usize, frame_limit: ?usize) !Result {
    input.suspendMenu();
    _ = c.SDL_ShowCursor(c.SDL_DISABLE);
    defer _ = c.SDL_ShowCursor(c.SDL_ENABLE);
    audio.pauseMusic(c.SDL_GetTicks());
    var music_paused = true;
    defer if (music_paused) audio.resumeMusic(c.SDL_GetTicks());
    var screen = try popup.Popup.init(a, archive, pixels, palette.*, mouseState());
    defer screen.deinit(a);
    var keys = popup.KeyQueue{};
    var left_pressed = false;
    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) return .quit;
            input.menuEvent(&event, screen.control.result == null);
            if (event.type == c.SDL_MOUSEBUTTONDOWN and event.button.button == c.SDL_BUTTON_LEFT) left_pressed = true;
            if (event.type != c.SDL_KEYDOWN or screen.control.result != null) continue;
            const key: popup.Key = switch (sdl.gameScanCode(event.key.keysym.scancode) orelse 0) {
                1 => .escape,
                28 => .enter,
                72 => .up,
                80 => .down,
                15 => .tab,
                else => .none,
            };
            keys.push(key);
        }
        var mouse = mouseState();
        if (left_pressed) mouse.buttons |= 1;
        left_pressed = false;
        if (screen.control.result == null) {
            var key = keys.next();
            if (key == .tab and c.SDL_GetModState() & c.KMOD_SHIFT != 0) key = .back_tab;
            try screen.frame(pixels, mouse, key);
            if (screen.control.takeSound()) |name|
                _ = try audio.play(.{ .basename = name, .priority = 64, .volume = 127, .flags = 4 }, null, c.SDL_GetTicks());
            try device.sync(audio);
            palette.* = screen.paletteAt(c.SDL_GetTicks());
            try window.present(palette);
            screen.control.presented = true;
            frames.* += 1;
            if (frame_limit) |limit| if (frames.* >= limit) return .frame_limit;
        }
        if (screen.control.takeResult(mouseState().buttons)) |result| {
            keys = .{};
            if (screen.control.kind == .quit) {
                if (result == 0) return .quit;
                reopen(&screen, .mission);
            } else switch (result) {
                -1, 0 => {
                    return .resume_game;
                },
                1 => {
                    return .restart;
                },
                2 => {
                    return .end_game;
                },
                3 => {
                    music_paused = false;
                    return .options;
                },
                4 => return .save,
                5 => return .load,
                6 => reopen(&screen, .quit),
                else => return error.InvalidMissionMenuResult,
            }
        }
        try device.sync(audio);
        c.SDL_Delay(16);
    }
}

fn reopen(screen: *popup.Popup, kind: popup.Kind) void {
    screen.open(kind, mouseState());
}
