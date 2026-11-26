//! Resolve build-selected limits in the target compilation, never by the
//! host's pointer size. Profiles contain fixed-width counts and byte limits.

const std = @import("std");
const options = @import("build_options");
const profiles = @import("profiles.zig");

pub const profile = std.meta.stringToEnum(profiles.Profile, options.memory_profile) orelse
    @compileError("Unknown memory profile");
pub const current = profiles.get(profile);
pub const heap_bytes: usize = @intCast(current.heap_bytes);

comptime {
    if (current.heap_bytes > std.math.maxInt(usize))
        @compileError("Memory profile does not fit the target address space");
    if (!std.math.isPowerOfTwo(current.heap_bytes) or current.heap_bytes < 256)
        @compileError("Memory profile requires a power-of-two heap of at least 256 bytes");
    if (current.resource_bytes > current.heap_bytes or current.movie_input_bytes > current.heap_bytes)
        @compileError("Subsystem storage exceeds the memory profile heap");
    if (current.resource_handles == 0 or current.sound_instances < 2 or
        current.sound_voices == 0 or current.sound_voices >= current.sound_instances)
        @compileError("Memory profile has invalid pool capacities");
}
