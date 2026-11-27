//! Inspect the selected profile using sizes from this executable's target.
const builtin = @import("builtin");
const std = @import("std");

const layout = @import("memory/layout.zig");
const limits = @import("memory/limits.zig");

pub fn main() void {
    std.debug.print(
        "memory profile: {s}\ntarget: {s}-{s}; pointers: {d} bits\n" ++
            "heap: {d} bytes; tree bookkeeping: {d}; reservation: {d}\n" ++
            "resource budget: {d} bytes; handles: {d} ({d} target bytes)\n" ++
            "movie input budget: {d} bytes; sound instances: {d}; voices: {d}\n" ++
            "software frame storage: {d} bytes\n" ++
            "session queue storage: {d} bytes per level session\n" ++
            "network router storage: {d} bytes per game\n" ++
            "known storage floor: {d} bytes\n" ++
            "TODO: Reserve and enforce resource and movie input budgets separately.\n" ++
            "TODO: Replace whole-file archive/movie loading with bounded reads.\n" ++
            "TODO: Give runtime containers fixed startup capacities.\n" ++
            "Native libraries, thread stacks, bootstrap and the allocator owner are additional.\n",
        .{
            @tagName(
                limits.profile,
            ),
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
            @bitSizeOf(usize),
            limits.heap_bytes,
            layout.heap_metadata_bytes,
            layout.reservation_bytes,
            limits.current.resource_bytes,
            limits.current.resource_handles,
            layout.resource_handles_bytes,
            limits.current.movie_input_bytes,
            limits.current.sound_instances,
            limits.current.sound_voices,
            layout.software_frame_bytes,
            layout.session_queue_bytes,
            layout.router_storage_bytes,
            layout.known_storage_bytes,
        },
    );
}
