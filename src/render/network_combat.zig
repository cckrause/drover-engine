//! Fighting across machines: a hit is posted to the machine that owns the
//! target, and that owner's player logic applies it.
//!
//! Damage, kill texts, score changes, dropped items and corpses all travel
//! as messages; nothing is applied locally to an actor another machine owns.
//! Aggregates carry the sender's and the target's numbers, and are sent
//! without a delivery guarantee.

const std = @import("std");

const MessageCode = @import("../message_code.zig").MessageCode;
const messages_module = @import("../assets/messages.zig");
const player_audio = @import("../audio/player.zig");
const campaign = @import("../campaign.zig");
const network_database = @import("../network/database.zig");
const message = @import("../network/message.zig");
const shooting = @import("../player/shooting.zig");
const shot_damage = @import("../player/shot_damage.zig");
const network_level = @import("network_level.zig");
const mode_words = @import("../ui/network_lobby.zig").mode_words;
const ActorKind = @import("../actor_flags.zig").ActorKind;
const local_player = shooting.local_player;

pub const Death = struct {
    texts: [2]Text = undefined,
    text_count: usize = 0,
    points: i32,

    pub const Text = struct {
        bytes: [0x50]u8 = undefined,
        len: usize = 0,
        destination: u32,

        pub fn slice(self: *const Text) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    fn add(
        self: *Death,
        template: []const u8,
        arguments: []const []const u8,
        destination: u32,
    ) !void {
        var text: Text = .{ .destination = destination };
        text.len = (try campaign.printStrings(template, arguments, &text.bytes)).len;
        self.texts[self.text_count] = text;
        self.text_count += 1;
    }
};

pub fn postDamage(session: anytype, pending: shooting.PendingHit) !bool {
    if (!session.game_type.isNetwork()) return false;

    const target = numberOf(session, pending.target);
    if (target != 0 and message.client(target) == session.router.own_client) return false;

    const input = pending.damageInput();
    const position = pending.messagePosition();
    var bytes = message.damage(session.router.own_client, .{
        .kind = input.kind,
        .damage = input.damage,
        .mass = input.mass,
        .speed = input.speed,
        .yaw = input.yaw,
        .pitch = input.pitch,
        .position = .{ position.x, position.y, position.z },
        .lateral = input.lateral,
        .height = input.height,
    });

    message.set(&bytes, message.reply_offset, target);
    message.set(
        &bytes,
        message.sender_offset,
        if (pending.sender) |sender| numberOf(session, sender) else 0,
    );

    _ = try session.router.post(target, .of(.damage), &bytes);

    return true;
}

pub fn playerMessage(session: anytype, bytes: []const u8) !void {
    switch (@as(MessageCode, @enumFromInt(message.get(bytes, message.number_offset)))) {
        .damage => try playerShot(session, bytes),
        .push => {
            if (bytes.len < message.words_size) return error.MalformedNetworkMessage;

            const push = [3]f32{
                @bitCast(message.get(bytes, 0x10)),
                @bitCast(message.get(bytes, 0x14)),
                @bitCast(message.get(bytes, 0x18)),
            };

            for (push) |value| if (!std.math.isFinite(value)) return error.MalformedNetworkMessage;

            session.player.velocity.x += push[0];
            session.player.velocity.y += push[1];
            session.player.velocity.z += push[2];
        },
        else => {},
    }
}

pub fn localShot(session: anytype, pending: shooting.PendingHit) !void {
    if (justStarted(session)) return;

    try takeShot(
        session,
        pending.damageInput(),
        if (pending.sender) |sender| numberOf(session, sender) else 0,
    );
}

pub fn justStartedAt(start: u32, now: u32) bool {
    return start <= now and now <= start +% 2000;
}

pub fn deathTexts(session: anytype, code: u32, killer: u8) !void {
    const death = try deathReport(
        session.router,
        session.startup.messages,
        session.mode,
        try network_level.actorEntity(session),
        code,
        killer,
    );

    for (death.texts[0..death.text_count]) |*text| try network_database.comment(
        session.router,
        text.slice(),
        text.destination,
    );

    try postFragDelta(session.router, session.mode, killer, death.points);
}

pub fn deathReport(
    router: anytype,
    messages: []const u8,
    mode: u32,
    own_entity: ActorKind,
    code: u32,
    killer: u8,
) !Death {
    const own_name = std.mem.sliceTo(&router.player_name, 0);
    const own = (router.own_client & 0xff) << 11;
    const client = &router.clients[killer];
    const named = client.name[0] != 0;
    var death: Death = .{ .points = 1 };
    var text: [0x50]u8 = undefined;

    switch (code) {
        0x2a, 0x3d => if (named) {
            try death.add(
                try localText(messages, code, &text),
                &.{ client.playerName(), own_name },
                0,
            );

            try death.add(
                "%s %s",
                &.{ client.playerName(), try localText(messages, code + 1, &text) },
                own,
            );
        },
        0x37, 0x3b, 0x2c, 0x2e, 0x30, 0x32 => if (named or code != 0x37) {
            try death.add(try localText(messages, code, &text), &.{own_name}, 0);
            try death.add("%s", &.{try localText(messages, code + 1, &text)}, own);
        },
        else => return error.UnknownNetworkDeathCode,
    }

    death.points = if (code != 0x2a and code != 0x37 and code != 0x3d) -1 else if (mode == 6) 1 else if (client.player) |player|
        (if (own_entity.team != player.flags.team) 1 else -1)
    else
        1;

    return death;
}

pub fn killPlayer(session: anytype, now: u32, effects: anytype, shots: anytype) !void {
    const inventory = &session.inventory;

    for ([_]u32{ 0x4655454c, 0x57454150 }) |class| {
        for (1..inventory.slots.len) |slot| if (inventory.slots[slot]) |owned| {
            if (owned.definition.item_class == class) try inventory.remove(slot);
        };
    }

    var offset: i32 = 0;

    for (1..inventory.slots.len) |slot| {
        if (inventory.slots[slot] == null) continue;
        const next = offset + 1;
        try session.dropItem(slot, .{ .offset = offset }, effects, shots);
        offset = if (next > 3) -3 else next;
    }

    session.death_restart.deadline = now +% 3000;
    try network_level.markRecord(session, now);
}

pub fn postFragDelta(router: anytype, mode: u32, client: u8, points: i32) !void {
    if (mode >= mode_words.len) return error.InvalidMultiplayerMode;

    var team: u32 = 0xffffffff;

    if (mode_words[mode].teams) if (router.clients[client].player) |player| {
        team = player.flags.team;
    };

    var bytes = message.fragDelta(
        router.own_client,
        .{ .client = client, .team = team, .points = @bitCast(points) },
    );

    message.set(&bytes, message.sender_offset, (router.own_client & 0xff) << 11);
    message.set(&bytes, message.reply_offset, 0);

    _ = try router.post(0x800, .{ .code = 0x408, .buffered = true, .must_arrive = true }, &bytes);
}

fn numberOf(session: anytype, index: usize) u32 {
    if (index == local_player) return session.player_number;

    return session.actor_numbers[index];
}

fn playerShot(session: anytype, bytes: []const u8) !void {
    if (justStarted(session)) return;

    const value = try message.readDamage(bytes);

    try takeShot(
        session,
        .{
            .kind = value.kind,
            .damage = value.damage,
            .mass = value.mass,
            .speed = value.speed,
            .pitch = value.pitch,
            .yaw = value.yaw,
            .lateral = value.lateral,
            .height = value.height,
        },
        message.get(bytes, message.sender_offset),
    );
}

fn justStarted(session: anytype) bool {
    return justStartedAt(session.database.start_clock, session.animation_time);
}

fn takeShot(session: anytype, input: shooting.DamageInput, sender: u32) !void {
    const now = session.animation_time;
    const killer = message.client(sender);
    const effects = session.active_effects orelse return error.MissingObjectEffects;
    var sound = player_audio.Context{
        .config = &session.player_audio_config,
        .state = &session.player_audio_state,
        .effects = effects,
    };

    session.inventory.player_flags = session.player.flags;
    const was_alive = session.inventory.health > 0;

    switch (try shot_damage.applyNetwork(
        &session.shot_damage_config,
        &session.angles,
        &session.player,
        &session.inventory,
        input,
        killer == session.router.own_client,
        &session.damage_flash,
        &sound,
        now,
    )) {
        .none => {},
        .blood => |position| try session.spawnBlood(position),
        .death => |code| {
            try deathTexts(session, code, killer);
            try sound.voice(.die);
        },
    }

    if (was_alive and session.inventory.health == 0) session.pending_player_death = null;

    const answer: MessageCode = if (session.inventory.health <= 0) .hit_killed else .hit_survived;
    var reply = message.objectRequest(@intFromEnum(answer), session.router.own_client);

    message.set(&reply, message.reply_offset, sender);
    message.set(&reply, message.sender_offset, session.player_number);

    _ = try session.router.post(sender, .{ .code = message.Number.of(answer).code, .buffered = true }, &reply);
}

fn localText(messages: []const u8, id: u32, buffer: *[0x50]u8) ![]const u8 {
    const found = messages_module.lookup(messages, id) catch |err| switch (err) {
        error.MessageNotFound => return error.DeathTextNotFound,
        else => return err,
    };

    if (found.len >= buffer.len) return error.DeathTextTooLong;

    @memcpy(buffer[0..found.len], found);

    return buffer[0..found.len];
}
