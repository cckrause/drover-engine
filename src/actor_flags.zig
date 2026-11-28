//! The two flag words every actor carries: what it is doing (`ActorFlags`)
//! and what kind of thing it is (`ActorKind`).
//!
//! The network's player record uses the `ActorKind` layout too.

const std = @import("std");

const bits = @import("util/bits.zig");

pub const ActorFlags = packed struct(u32) {
    /// The actor takes part in the level. Logic and physics only run for
    /// active actors.
    active: bool = false,
    unused_1: bool = false,
    visible: bool = false,
    /// Darkened with distance like the walls around it.
    shaded: bool = false,
    /// Lit up by its own light; enemies see it from any distance.
    glowing: bool = false,
    /// A player, with a player record behind it.
    has_player_record: bool = false,
    has_logic: bool = false,
    /// Set when its logic or physics ran; nothing reads it.
    updated: bool = false,
    /// Shots, walkers and enemies ignore it.
    not_solid: bool = false,
    unused_9: bool = false,
    /// Falls and rides on moving floors.
    physics: bool = false,
    /// Drawn with the level's tint table.
    level_tint: bool = false,
    unused_12: bool = false,
    /// Set on water splashes; nothing reads it.
    water_splash: bool = false,
    dead: bool = false,
    /// Never sent to other machines.
    local_only: bool = false,
    unused_16: u15 = 0,
    /// Set whenever anything about the actor changes; nothing reads it, but
    /// saves and packets carry it.
    changed: bool = false,

    pub const new: ActorFlags = .{
        .active = true,
        .unused_1 = true,
        .visible = true,
        .shaded = true,
        .changed = true,
    };

    /// What the player's actor starts with.
    pub const new_player = bits.with(new, .{ .has_player_record = true, .has_logic = true });

    /// What short-lived effects like blood and bubbles start with.
    pub const new_effect = bits.with(new, .{ .has_logic = true, .not_solid = true });

    pub fn logicReady(self: ActorFlags) bool {
        return self.active and self.has_logic;
    }
};

pub const ActorKind = packed struct(u32) {
    team: u4 = 0,
    player: bool = false,
    projectile: bool = false,
    /// Thinks for itself: enemies, but also bystanders and helpers.
    ai_controlled: bool = false,
    /// Shots hit it and it bleeds. The player and helpers have it; enemies
    /// and bystanders get the same treatment through their own bits.
    takes_hits: bool = false,
    enemy: bool = false,
    unused_9: bool = false,
    /// Objects, pickups and projectiles: walkers pass through them and only
    /// touch them, and shots don't hit them.
    item: bool = false,
    corpse: bool = false,
    /// Does its job when the player uses it.
    used_when_activated: bool = false,
    /// Does its job when shot, and also when the player uses it.
    used_when_shot: bool = false,
    /// Harmless creatures and people: no enemy, but they react.
    bystander: bool = false,
    unused_15: bool = false,
    /// Its own tint instead of the team's.
    own_tint: u3 = 0,
    /// Picks one of the level's tint tables.
    tint_table: u2 = 0,
    boss: bool = false,
    unused_22: bool = false,
    /// Short-lived effects like blood and bubbles; saves leave them out.
    effect: bool = false,
    /// A network stand-in that waits for the game to start.
    waiting_for_start: bool = false,
    shadow: bool = false,
    /// When the player hurts it, the player gets hurt too.
    reflects_player_damage: bool = false,
    unused_27: u4 = 0,
    /// Shots test the sprite's pixels, not just its box.
    mask_hit: bool = false,
};

test "actor flag bits sit where saves and packets expect them" {
    try std.testing.expectEqual(@as(u32, 0x8000000f), bits.word(ActorFlags.new));
    try std.testing.expectEqual(@as(u32, 0x400), bits.word(ActorFlags{ .physics = true }));
    try std.testing.expectEqual(@as(u32, 0x4000), bits.word(ActorFlags{ .dead = true }));
    try std.testing.expectEqual(@as(u32, 0x8000), bits.word(ActorFlags{ .local_only = true }));
    try std.testing.expectEqual(
        @as(u32, 0x90),
        bits.word(ActorKind{ .player = true, .takes_hits = true }),
    );

    try std.testing.expectEqual(@as(u32, 0x70000), bits.word(ActorKind{ .own_tint = 7 }));
    try std.testing.expectEqual(@as(u32, 0x200000), bits.word(ActorKind{ .boss = true }));
    try std.testing.expectEqual(
        @as(u32, 0x01000000),
        bits.word(ActorKind{ .waiting_for_start = true }),
    );

    try std.testing.expectEqual(@as(u32, 0x80000000), bits.word(ActorKind{ .mask_hit = true }));
}
