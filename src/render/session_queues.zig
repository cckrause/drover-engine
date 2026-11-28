//! Fixed storage for the lists a level session keeps from one frame to the
//! next: hits waiting to be delivered, messages to actors, enemy shots and
//! effects gathered outside a frame.
//!
//! The game has no hard ceiling for these. Frame time is not capped, so a
//! long stall catches up every missed animation frame in one pass. Each
//! size is therefore a busy frame with plenty of room, built on the number
//! of actors a session can hold, and a fuller list stops with its own error.

const enemy = @import("../enemy/controller.zig");
const MessageCode = @import("../message_code.zig").MessageCode;
const inventory = @import("../player/inventory.zig");
const shooting = @import("../player/shooting.zig");
const FixedList = @import("../util/fixed_list.zig").FixedList;
const network_router = @import("../network/router.zig");
const object_logic = @import("../script/object.zig");
const network_actors = @import("network_actors.zig");

const actor_slots = @import("actor_slots.zig").capacity;

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
/// A breakable object queues one or two sprite choices for each hit or
/// message it gets.
pub const max_object_selections = 2 * (max_hit_groups + max_actor_messages);
/// One stand-in for every other machine the router can hold.
pub const max_remote_players = network_router.client_slots;

pub const ActorMessage = struct { target: usize, code: MessageCode, serial: u64 };
pub const PendingHits = FixedList(shooting.PendingHit, error{TooManyPendingHits});
pub const ActorMessages = FixedList(ActorMessage, error{TooManyActorMessages});
pub const RemotePlayers = FixedList(network_actors.RemotePlayer, error{TooManyRemotePlayers});

/// Lives inside the session, which stays at one address for its whole life,
/// so the lists can point into it.
pub const Storage = struct {
    hits: [2][max_hit_groups]shooting.PendingHit,
    actor_messages: [max_actor_messages]ActorMessage,
    enemy_effects: [max_enemy_shots]enemy.Effect,
    enemy_native_effects: inventory.EffectBuffer,
    pickup_effects: inventory.EffectBuffer,
    object_selections: [max_object_selections]object_logic.Selection,
    remote_players: [max_remote_players]network_actors.RemotePlayer,
};
