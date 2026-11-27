//! Compile-only entry point: no SDL, libc, assets or target execution needed.
const layout = @import("memory/layout.zig");

export fn droverKnownMemoryBytes() u64 {
    return layout.known_storage_bytes;
}
