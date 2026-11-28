//! The host side of movie playback: the blocking loop, presentation and
//! input. Decoding, timing and palettes stay in src/video.
//!
//! Both display pages are cleared on entry. A frame is decoded before its
//! deadline is tested and released before completion is tested, and the
//! finished frame is not presented. Input is pumped after presentation,
//! including while paused.

const std = @import("std");

const playback = @import("../video/playback.zig");
const san = @import("../video/san.zig");
const presentation = @import("../video/smush_present.zig");
const movie_audio = @import("movie_audio.zig");
const sdl = @import("sdl.zig");
const c = sdl.c;

pub const Result = enum { completed, cancelled, quit, frame_limit };

pub fn play(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    frames: *usize,
    limit: ?usize,
) !Result {
    return playWithInput(allocator, io, path, window, pixels, palette, frames, limit, null);
}

pub fn playWithInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    frames: *usize,
    limit: ?usize,
    input: ?*sdl.PlayerInput,
) !Result {
    const data = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(512 * 1024 * 1024),
    );

    defer allocator.free(data);
    var movie = try san.Movie.init(allocator, data);
    defer movie.deinit(allocator);
    const sound = try movie_audio.Device.open(allocator);
    defer sound.deinit();
    var clock = try playback.Clock.initAudio(c.SDL_GetTicks(), @intCast(movie.rate));
    var pending: ?san.Frame = null;
    const saved_palette = palette.*;

    @memset(pixels, 0);
    palette.* = presentation.screenPalette(palette.*);
    try window.present(palette);

    const cursor = c.SDL_ShowCursor(c.SDL_DISABLE);
    defer _ = c.SDL_ShowCursor(cursor);
    const outcome: Result = play_loop: while (true) {
        if (!clock.paused) {
            if (pending == null) {
                pending = try movie.nextWithFlags(clock.renderFlags());

                if (pending) |frame|
                    try sound.submit(
                        frame.pcm,
                        frame.number,
                        movie.last_audio_frame,
                        movie.frame_count,
                        movie.rate,
                        c.SDL_GetTicks(),
                    );
            }

            const now = c.SDL_GetTicks();
            const media_now = clock.audioTime(
                now,
                sound.time(now),
                movie.frame_number,
                movie.last_audio_frame,
            );

            if (clock.synchronizeAudio(now, media_now)) |paused| sound.setPaused(paused, now);

            const due = clock.dueAt(now, media_now);

            if (due) clock.releasedAt(now, media_now);

            if (clock.complete(movie.frame_count, pending == null)) break :play_loop .completed;

            if (due) {
                const frame = pending.?;

                if (frame.palette_change == 2) @memset(pixels, 0);

                palette.* = presentation.screenPalette(frame.palette);

                if (clock.present(frame.number, media_now)) try copy(frame, pixels);

                try window.present(palette);

                pending = null;
                frames.* += 1;

                if (limit) |maximum| if (frames.* >= maximum) break :play_loop .frame_limit;
            }
        }

        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) break :play_loop .quit;

            if (input) |gameplay| gameplay.movieEvent(&event);

            if (event.type != c.SDL_KEYDOWN) continue;

            const modifiers = event.key.keysym.mod & (c.KMOD_SHIFT | c.KMOD_CTRL | c.KMOD_ALT);
            const scan = event.key.keysym.scancode;

            if (scan == c.SDL_SCANCODE_ESCAPE and modifiers == 0) break :play_loop .cancelled;

            if ((scan == c.SDL_SCANCODE_SPACE and modifiers == 0) or
                (scan == c.SDL_SCANCODE_P and modifiers & c.KMOD_ALT != 0 and modifiers & (c.KMOD_CTRL | c.KMOD_SHIFT) == 0))
            {
                clock.togglePause();
                sound.setPaused(clock.paused, c.SDL_GetTicks());
            }

            break;
        }

        c.SDL_Delay(1);
    };

    if (outcome == .completed or outcome == .cancelled) {
        @memset(pixels, 0);
        palette.* = presentation.screenPalette(saved_palette);
        try window.present(palette);
    }

    return outcome;
}

pub fn copy(frame: san.Frame, pixels: []u8) !void {
    try presentation.blit(.{
        .pixels = frame.pixels,
        .width = frame.width,
        .height = frame.height,
        .x = frame.x,
        .y = frame.y,
    }, .{
        .pixels = pixels,
        .stride = 640,
        .height = 480,
        .clip = .{ .width = 640, .height = 480 },
    }, .{ .fit = true });
}

pub fn renderFrames(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    count: usize,
    pixels: []u8,
) ![256]u32 {
    const data = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(512 * 1024 * 1024),
    );

    defer allocator.free(data);
    var movie = try san.Movie.init(allocator, data);
    defer movie.deinit(allocator);

    @memset(pixels, 0);
    var palette: [256]u32 = @splat(0);

    for (0..count) |_| {
        const frame = (try movie.next()) orelse return error.MovieFrameOutOfRange;
        if (frame.palette_change == 2) @memset(pixels, 0);
        palette = presentation.screenPalette(frame.palette);
        try copy(frame, pixels);
    }

    return palette;
}

test "movie loop cancels on Escape and releases its audio for restart" {
    const allocator = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/IN_SHB.SAN";

    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    if (c.SDL_setenv("SDL_VIDEODRIVER", "dummy", 1) != 0 or
        c.SDL_setenv("SDL_AUDIODRIVER", "dummy", 1) != 0) return error.SdlTestEnvironment;

    const pixels = try allocator.alloc(u8, 640 * 480);
    defer allocator.free(pixels);
    const window = try sdl.Window.init(pixels, 640, 480);
    defer window.deinit();
    var palette: [256]u32 = @splat(0x123456);
    const saved = presentation.screenPalette(palette);
    var frames: usize = 0;
    var event = std.mem.zeroes(c.SDL_Event);

    event.type = c.SDL_KEYDOWN;
    event.key.keysym.scancode = c.SDL_SCANCODE_ESCAPE;
    if (c.SDL_PushEvent(&event) != 1) return error.SdlTestEvent;

    try std.testing.expectEqual(
        Result.cancelled,
        try play(allocator, std.testing.io, path, window, pixels, &palette, &frames, null),
    );

    try std.testing.expectEqualSlices(u32, &saved, &palette);

    for (pixels) |pixel| try std.testing.expectEqual(@as(u8, 0), pixel);

    frames = 0;

    try std.testing.expectEqual(
        Result.frame_limit,
        try play(allocator, std.testing.io, path, window, pixels, &palette, &frames, 24),
    );

    try std.testing.expectEqual(@as(usize, 24), frames);
}
