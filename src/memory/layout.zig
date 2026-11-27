//! Target-sized accounting for resource and movie budgets, sound state,
//! decoder storage and frame buffers.
//! TODO: Account for actor, queue, cache and workspace capacities.
//! TODO: Reserve and enforce resource and movie input budgets separately.

const std = @import("std");
const limits = @import("limits.zig");
const sound = @import("../audio/engine.zig");
const movie_audio = @import("../video/audio_stream.zig");
const pcm = @import("../video/audio.zig");
const codec = @import("../video/smush_codec.zig");
const MemoryBudget = @import("../platform/MemoryBudget.zig");
const world = @import("../render/backends/software/world.zig");
const session_queues = @import("../render/session_queues.zig");
const inf = @import("../script/inf.zig");
const router = @import("../network/router.zig");
const message_store = @import("../network/message_store.zig");

// Native master pointers grow with the target ABI; encoded asset data does not.
pub const resource_handles_bytes: u64 = limits.current.resource_handles * @as(u64, @sizeOf(?[*]u8));
pub const sound_state_bytes: u64 = @sizeOf(sound.Engine);
pub const movie_audio_bytes: u64 = @sizeOf(movie_audio.Stream) + @sizeOf(pcm.Decoder);
pub const movie_decoder_bytes: u64 = @sizeOf(codec.Decoder) + 3 * 640 * 480;
pub const framebuffer_bytes: u64 = 640 * 480;
// The software renderer's frame storage, reserved once in main, sized for a
// 640-wide view and the largest shipped level.
pub const software_frame_bytes: u64 = @sizeOf(world.Workspace);
// Queues each level session holds from frame to frame, allocated with the
// session; two sessions overlap while a level changes.
pub const session_queue_bytes: u64 = @sizeOf(session_queues.Storage) +
    inf.max_pending * @sizeOf(inf.Pending) + inf.max_effects * @sizeOf(inf.Effect);
// The router's message storage, allocated with each new game's router.
pub const router_storage_bytes: u64 = message_store.MessageStore.storageBytes(router.max_queued_bytes, router.max_queued_messages);
pub const known_storage_bytes: u64 = limits.current.resource_bytes + resource_handles_bytes +
    limits.current.movie_input_bytes + sound_state_bytes + movie_audio_bytes +
    movie_decoder_bytes + framebuffer_bytes + software_frame_bytes;

pub const reservation_bytes: u64 = MemoryBudget.reservationSize(limits.heap_bytes) catch
    @compileError("Memory profile reservation exceeds the target address space");
pub const heap_metadata_bytes: u64 = reservation_bytes - limits.current.heap_bytes;

comptime {
    if (known_storage_bytes > limits.current.heap_bytes)
        @compileError("Known target storage exceeds the memory profile; review capacities");
    if (reservation_bytes > std.math.maxInt(usize))
        @compileError("Memory profile bookkeeping exceeds the target address space");
}
