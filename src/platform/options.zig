//! The host side of the options pages: time, input and presentation around
//! the dialog's blocking loop. Layout, drawing, focus and the pages
//! themselves are engine code.
//!
//! Brightness is set to full on entry, and the first focus already requests
//! the hover sound. A mouse button press is latched and consumed once, so a
//! click cannot be seen twice.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const dialog = @import("../ui/dialog.zig");
const options = @import("../ui/options.zig");
const sdl = @import("sdl.zig");
const settings_file = @import("settings.zig");
const Runtime = @import("../audio/runtime.zig").Runtime;
const Device = @import("audio.zig").Device;
const c = sdl.c;

pub const Result = enum { done, quit, frame_limit };

pub fn run(
    a: std.mem.Allocator,
    io: std.Io,
    archive: lab.Archive,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    state: options.State,
    audio: *Runtime,
    device: *Device,
    frames: *usize,
    frame_limit: ?usize,
) !Result {
    _ = c.SDL_ShowCursor(c.SDL_DISABLE);
    defer _ = c.SDL_ShowCursor(c.SDL_ENABLE);

    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();

    _ = state.display.setBrightness(0xff);

    var shared = dialog.Shared{};
    var main = try options.Main.init(archive, state, &fonts);
    var screen: dialog.Dialog = undefined;

    try screen.open(
        a,
        archive,
        &shared,
        null,
        main.page(),
        &options.records,
        &fonts,
        &cursor,
        options.background,
        null,
        palette,
        mouseState(),
    );

    var open = true;
    defer if (open) {
        _ = screen.close() catch {};
    };

    var left_pressed = false;
    var played: u32 = 0;

    while (screen.running) {
        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) return .quit;

            if (event.type == c.SDL_MOUSEBUTTONDOWN and event.button.button == c.SDL_BUTTON_LEFT) left_pressed = true;

            if (event.type == c.SDL_KEYDOWN) if (sdl.gameScanCode(
                event.key.keysym.scancode,
            )) |scan| screen.keys.push(scan);
        }

        var input = mouseState();

        if (left_pressed) input.buttons.left = true;

        left_pressed = false;
        input.shift = c.SDL_GetModState() & c.KMOD_SHIFT != 0;

        try screen.frame(input, c.SDL_GetTicks(), palette);

        if (try screen.render(pixels, palette)) try window.present(palette);

        for (played..shared.sounds) |_|
            _ = try audio.play(
                .{ .basename = "RIFLOUT.WAV", .priority = 64, .volume = 127, .flags = .default },
                null,
                c.SDL_GetTicks(),
            );

        played = shared.sounds;

        try device.sync(audio);
        screen.reload();
        try settings_file.save(a, io, state.settings);

        frames.* += 1;

        if (frame_limit) |limit| if (frames.* >= limit) return .frame_limit;

        c.SDL_Delay(16);
    }

    open = false;
    _ = try screen.close();

    try settings_file.save(a, io, state.settings);

    while (mouseState().buttons.any()) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) if (event.type == c.SDL_QUIT) return .quit;
        c.SDL_Delay(16);
    }

    return .done;
}

fn mouseState() dialog.Input {
    var input = dialog.Input{};
    input.buttons = sdl.mouseButtons(c.SDL_GetMouseState(&input.x, &input.y));

    return input;
}
