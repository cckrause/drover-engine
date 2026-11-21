//! A movie played from inside a script trigger, rather than by the story.
//!
//! The caller stays inside its trigger callback and the story does not
//! advance. Effects are stopped while the separate music stream keeps
//! playing. The call returns before any clock is read again, and the session
//! adds the elapsed interval itself - do not sample it twice.

const std = @import("std");
const sdl = @import("sdl.zig");
const movie = @import("movie.zig");
const mission = @import("mission.zig");
const audio_runtime = @import("../audio/runtime.zig");
const audio_platform = @import("audio.zig");

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    initial_data_path: []const u8,
    disc: u8,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    input: *sdl.PlayerInput,
    audio: *audio_runtime.Runtime,
    device: *audio_platform.Device,
    frames: *usize,
    limit: ?usize,

    pub fn play(context: *anyopaque, name: []const u8, flags: u32) anyerror!u32 {
        const self: *Host = @ptrCast(@alignCast(context));
        if (flags != 1) return error.UnsupportedTriggeredMovieFlags;
        const started = sdl.c.SDL_GetTicks();
        self.input.suspendMenu();
        self.audio.stopAll();
        try self.device.sync(self.audio);
        const path = try mission.moviePath(self.allocator, self.initial_data_path, .{ .kind = .movie, .disc = self.disc, .name = name });
        defer self.allocator.free(path);
        const result = try movie.playWithInput(self.allocator, self.io, path, self.window, self.pixels, self.palette, self.frames, self.limit, self.input);
        switch (result) {
            .quit => return error.QuitFromMovie,
            .frame_limit => return error.MovieFrameLimit,
            .completed, .cancelled => {},
        }
        const elapsed = sdl.c.SDL_GetTicks() -% started;
        self.input.last_sample +%= elapsed;
        try self.input.resumeMenu();
        return elapsed;
    }
};
