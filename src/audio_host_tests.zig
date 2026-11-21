//! Audio tests that need a real device: these run through SDL's dummy
//! output, so they need no sound hardware but do need SDL.

test {
    _ = @import("platform/audio.zig");
    _ = @import("platform/sdl.zig");
    _ = @import("platform/movie_audio.zig");
    _ = @import("platform/movie.zig");
}
