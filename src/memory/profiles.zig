//! Build-selected memory limits, independent of the build host and CPU target.
//! Raising a limit is a deliberate source change. No runtime override or
//! fallback profile may expand storage after startup.

pub const Profile = enum { original_pc };

pub const Limits = struct {
    heap_bytes: u64,
    resource_bytes: u64,
    resource_handles: u32,
    movie_input_bytes: u64,
    sound_instances: u32,
    sound_voices: u32,
};

pub fn get(profile: Profile) Limits {
    return switch (profile) {
        .original_pc => .{
            // Usable managed heap capacity; excludes process and host overhead.
            .heap_bytes = 64 * 1024 * 1024,
            // The original game's default resource heap and handle count.
            .resource_bytes = 6000 * 1024,
            .resource_handles = 8192,
            // What the original asks for to stream a movie; not a cap on movie size.
            .movie_input_bytes = 1024 * 1024,
            // Size of the original's playing-sound table; the mixer still has eight voices.
            .sound_instances = 200,
            .sound_voices = 8,
        },
    };
}
