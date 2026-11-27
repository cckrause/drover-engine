//! Fixed storage for the lists a level session keeps from one frame to the
//! next: hits waiting to be delivered, messages to actors, enemy shots and
//! effects gathered outside a frame.
//!
//! The game has no hard ceiling for these. Frame time is not capped, so a
//! long stall catches up every missed animation frame in one pass. Each
//! size is therefore a busy frame with plenty of room, built on the number
//! of actors a session can hold, and a fuller list stops with its own error.

const shooting = @import("../player/shooting.zig");
const inventory = @import("../player/inventory.zig");
const enemy = @import("../enemy/controller.zig");
const FixedList = @import("../util/fixed_list.zig").FixedList;

/// The most map objects in a shipped level (655, CANYON) plus the most
/// actors made during play that were alive at once over the test suite
/// (234).
/// TODO: Use the session's actor slot capacity once actor slots are fixed.
pub const actor_slots = 655 + 234;
/// Every actor and the player can be hit in the same frame.
pub const hit_targets = actor_slots + 1;
/// One group of hits for every target, and room for each delivered hit to
/// be reflected back. Both hit lists swap storage, so they share this size.
pub const max_hit_groups = 2 * hit_targets;
/// One reply for each delivered hit, plus one wall contact or activation
/// for every target.
pub const max_actor_messages = max_hit_groups + hit_targets;
/// One shot from every actor.
pub const max_enemy_shots = actor_slots;

pub const ActorMessage = struct { target: usize, code: u32, serial: u64 };
pub const PendingHits = FixedList(shooting.PendingHit, error{TooManyPendingHits});
pub const ActorMessages = FixedList(ActorMessage, error{TooManyActorMessages});

/// Lives inside the session, which stays at one address for its whole life,
/// so the lists can point into it.
pub const Storage = struct {
    hits: [2][max_hit_groups]shooting.PendingHit,
    actor_messages: [max_actor_messages]ActorMessage,
    enemy_effects: [max_enemy_shots]enemy.Effect,
    enemy_native_effects: inventory.EffectBuffer,
    pickup_effects: inventory.EffectBuffer,
};
