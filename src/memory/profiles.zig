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
            // CD1 OLWIN 0042d6b0: 6000 KiB and 0x2000 master pointers.
            .resource_bytes = 6000 * 1024,
            .resource_handles = 8192,
            // OLWIN 0046f1f0 -> LECSMUSH Allocate (10001090).
            .movie_input_bytes = 1024 * 1024,
            // OLWIN 00489b00's instance table; existing eight-voice mixer.
            .sound_instances = 200,
            .sound_voices = 8,
        },
    };
}
