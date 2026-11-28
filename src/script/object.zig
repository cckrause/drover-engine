//! Script messages to and from actors: damage, sequence changes, sounds and
//! removal.
//!
//! With no sound list loaded, an indexed sound request simply returns
//! without playing anything. Damage messages ignore the magnitude - the
//! amount is in the message, not in the dispatch.

const std = @import("std");
const MessageCode = @import("../message_code.zig").MessageCode;
const ActorKind = @import("../actor_flags.zig").ActorKind;
const Actor = @import("../render/objects.zig").Actor;
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const indexed = @import("../audio/indexed.zig");
const inventory = @import("../player/inventory.zig");
const FixedList = @import("../util/fixed_list.zig").FixedList;
const bits = @import("../util/bits.zig");

pub const Selection = struct { source: usize, choreography: u16, serial: u64 };
pub const Selections = FixedList(Selection, error{TooManyObjectSelections});

pub const Runtime = struct {
    sounds: ?indexed.Table,
    selections: Selections,
    cursor: usize = 0,

    /// `selections` is the storage for the sprite choices waiting for delivery.
    pub fn init(a: std.mem.Allocator, archive: lab.Archive, selections: []Selection) !Runtime {
        const bytes = archive.find("SOUNDS.LST", 0) catch |err| switch (err) {
            error.ResourceNotFound => return .{ .sounds = null, .selections = .init(selections) },
            else => return err,
        };

        return .{ .sounds = try indexed.Table.parse(a, bytes), .selections = .init(selections) };
    }
};

fn AnimationContext(comptime Session: type) type {
    return struct {
        session: Session,
        source: usize,
        effects: *inventory.Effects,

        pub fn event(
            self: *@This(),
            playback: *nwx.Playback,
            _: *const nwx.Costume,
            code: u32,
            arguments: []const u32,
            now: u32,
        ) !void {
            const session = self.session;
            const actor = &session.actor_slots[self.source].?;

            switch (code) {
                2 => {
                    if (arguments.len == 0) return error.InvalidObjectSoundArguments;

                    if (session.object_logic.sounds) |table| {
                        var request = try table.request(arguments[0], actor.sector, actor.position);

                        if (session.active_audio) |audio| {
                            if (session.active_effects) |effects| try session.drainSounds(effects);
                            try session.drainSounds(self.effects);
                            _ = try audio.play(request, session.audioWorld(), now);
                            request.delivered = true;
                        }

                        try self.effects.append(.{ .sound = request });
                    }
                },
                3 => {
                    try session.inf.event(
                        &session.level,
                        .{
                            .sector = actor.sector,
                            .mask = .{ .object_script = true },
                            .entity_mask = bits.from(ActorKind, 0xffffffff),
                            .from_player = false,
                            .now_ms = now,
                        },
                    );
                },
                4 => actor.flags = bits.with(actor.flags, .{ .not_solid = true, .changed = true }),
                5 => {
                    const sector = actor.sector;
                    const position = actor.position;

                    try @import(
                        "../enemy/explosion_fragment.zig",
                    ).burst(session, self.effects, sector, position, now);

                    try session.inf.event(
                        &session.level,
                        .{
                            .sector = sector,
                            .mask = .{ .object_script = true },
                            .entity_mask = bits.from(ActorKind, 0xffffffff),
                            .from_player = false,
                            .now_ms = now,
                        },
                    );
                },
                0x5e, 0x66 => {
                    if (@hasField(
                        @TypeOf(session.*),
                        "actor_numbers",
                    )) try @import("../render/object_numbers.zig").freeActor(session, self.source);

                    session.removed_actors[self.source] = true;
                    session.actor_links.remove(self.source);
                    playback.terminated = true;
                },
                else => {},
            }
        }
    };
}

pub fn bound(actor: Actor) bool {
    return std.mem.eql(u8, actor.logic_name, "Inv_Object");
}

pub fn hit(session: anytype, source: usize) !void {
    try receive(session, source, .damage);
}

pub fn receive(session: anytype, source: usize, code: MessageCode) !void {
    const actor = session.actor_slots[source] orelse return error.MissingObjectActor;
    if (!bound(actor)) return error.InvalidObjectBinding;
    if (actor.model != null) return;

    if (code != .damage) {
        if (code != .activate) return;
        if (actor.secondary_flags.used_when_activated) try enqueue(session, source, actor);
    }

    if (actor.secondary_flags.used_when_shot) try enqueue(session, source, actor);
}

pub fn deliverNext(session: anytype, effects: *inventory.Effects) !void {
    const runtime = &session.object_logic;
    if (runtime.cursor == runtime.selections.items.len) return;

    const selection = runtime.selections.items[runtime.cursor];

    runtime.cursor += 1;
    if (session.removed_actors[selection.source]) return;

    const actor = if (session.actor_slots[selection.source]) |*value| value else return error.MissingObjectActor;
    var context = AnimationContext(
        @TypeOf(session),
    ){ .session = session, .source = selection.source, .effects = effects };

    const playback = if (actor.playback) |*value| value else return error.MissingObjectPlayback;

    try playback.select(
        try actor.sprite(),
        selection.choreography,
        session.animation_time,
        &context,
    );

    session.actor_slots[selection.source].?.playback = playback.*;

    sync(&session.actor_slots[selection.source].?);
    session.syncActor(selection.source);
}

pub fn advance(session: anytype, source: usize, effects: *inventory.Effects) !void {
    const actor = if (session.actor_slots[source]) |*value| value else return error.MissingObjectActor;
    if (actor.model != null) return;

    var context = AnimationContext(
        @TypeOf(session),
    ){ .session = session, .source = source, .effects = effects };

    const playback = if (actor.playback) |*value| value else return error.MissingObjectPlayback;

    try playback.advanceWithContext(try actor.sprite(), 0, session.animation_time, &context);
    session.actor_slots[source].?.playback = playback.*;

    sync(&session.actor_slots[source].?);
    session.syncActor(source);
}

pub fn tick(session: anytype, source: usize) void {
    const actor = &session.actor_slots[source].?;
    if (!actor.flags.logicReady() or actor.secondary_flags.waiting_for_start or
        @as(u32, @bitCast(session.actor_next_update[source])) > session.animation_time) return;

    schedule(session, source);
    actor.flags = bits.with(actor.flags, .{ .updated = true, .changed = true });
    session.syncActor(source);
}

pub fn schedule(session: anytype, source: usize) void {
    session.actor_next_update[source] = -1;
}

fn enqueue(session: anytype, source: usize, actor: Actor) !void {
    const playback = actor.playback orelse return error.MissingObjectPlayback;
    try session.object_logic.selections.append(.{
        .source = source,
        .choreography = @truncate(playback.choreography +% 1),
        .serial = session.enemy_selection_serial,
    });

    session.enemy_selection_serial += 1;
}

fn sync(actor: *Actor) void {
    const playback = actor.playback.?;
    actor.choreography = playback.choreography;
    actor.frame = playback.frame;
    actor.angle_offset = playback.angle_offset;
}
