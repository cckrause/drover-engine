//! Dead reckoning: a player sends its own position, and every machine
//! predicts the others between updates.
//!
//! Each participating actor carries a record that is zeroed when it is made.
//! A player sends from the maintenance pass, to everyone and to its own
//! record, so the sender predicts itself the same way the receivers do.

const std = @import("std");

const message = @import("message.zig");
const router_module = @import("router.zig");
const actor_flags = @import("../actor_flags.zig");
const bits = @import("../util/bits.zig");
const ActorFlags = actor_flags.ActorFlags;
const ActorKind = actor_flags.ActorKind;
const Router = router_module.Router;

pub const update_size = 0x3e;

pub const Record = struct {
    /// Send at the next chance, even if nothing changed.
    send_soon: bool = true,
    rate: f32 = 0.2,
    limit: u16 = 0x38e,
    rate2: f32 = 0.2,
    time: u32 = 0,
    made: u32,
    sent: u32 = 0,
    sector: u16 = 0,
    actor_flags: ActorFlags = .{},
    entity: ActorKind = .{},
    position: [3]f32,
    angles: [3]i16 = @splat(0),
    origin: [3]f32,
    velocity: [3]u32 = @splat(0),
    distance: f32 = 0,

    pub fn init(position: [3]f32, now: u32) Record {
        return .{ .made = now, .position = position, .origin = position };
    }

    pub fn reckon(self: *Record, now: u32) void {
        var seconds: f32 = 0;

        if (now >= self.time) seconds = @floatCast(
            @as(f64, @floatFromInt(now - self.time)) * @as(f32, 0.001),
        );

        if (@as(u32, @bitCast(seconds)) > 0x80000000) seconds = 0;

        for (&self.origin, self.velocity, self.position) |*reckoned, velocity, position|
            reckoned.* = @floatCast(@as(f64, @as(f32, @bitCast(velocity))) * seconds + position);
    }

    pub fn take(self: *Record, update: *const Update, now: u32) void {
        self.sector = update.sector;
        self.position = update.position;
        self.velocity = update.velocity;
        self.angles = update.angles;
        self.actor_flags = update.actor_flags;
        self.entity = update.entity;
        self.time = if (update.time == 0) now else update.time;
    }
};

pub const Actor = struct {
    number: u32,
    flags: ActorFlags,
    entity: ActorKind,
    position: [3]f32,
    angles: [3]i16,
    sector: u16,
    velocity: [3]u32,
    animation: u16,
    airborne: bool,
    gravity: f32,
    frame_seconds: f32,
};

pub const Update = struct {
    sector: u16,
    animation: u16,
    position: [3]f32,
    angles: [3]i16,
    velocity: [3]u32,
    time: u32,
    actor_flags: ActorFlags,
    entity: ActorKind,
};

pub const Change = struct {
    kind: u32,
    sector: u16,
    wall: u16,
    words: [4]u32 = @splat(0),
};

pub const ArchitectureQueue = struct {
    entries: std.ArrayList(Change) = .empty,
    count: usize = 0,

    pub fn deinit(self: *ArchitectureQueue, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn queue(
        self: *ArchitectureQueue,
        allocator: std.mem.Allocator,
        router: *const Router,
        change: Change,
    ) !void {
        if (!router.session_open or router.own_client != 1) return;

        for (self.entries.items[0..self.count]) |*entry| {
            if (entry.kind == change.kind and entry.sector == change.sector and entry.wall == change.wall) {
                entry.* = change;
                return;
            }
        }

        if (self.count < self.entries.items.len)
            self.entries.items[self.count] = change
        else
            try self.entries.append(allocator, change);

        self.count += 1;
    }

    pub fn send(self: *ArchitectureQueue, router: *Router, destination: u32) !void {
        var index: usize = 0;

        while (index < self.count) {
            var bytes: [0x200]u8 = @splat(0);
            const own = message.addressWord(
                message.Queue.dead_reckoning,
                @truncate(router.own_client),
            );

            message.set(&bytes, message.sender_offset, own);
            message.set(&bytes, message.reply_offset, own);

            const start = index;
            const length = try pack(
                self.entries.items[0..self.count],
                &index,
                bytes[0x12..][0..0x1ee],
            );

            std.mem.writeInt(u16, bytes[0x10..0x12], @truncate(index - start), .little);
            _ = try router.post(destination, .{ .code = 0x419, .must_arrive = true }, bytes[0 .. length + 0x12]);
        }

        self.count = 0;
    }
};

pub fn readUpdate(bytes: []const u8) !Update {
    if (bytes.len < update_size) return error.MalformedNetworkMessage;

    const update: Update = .{
        .sector = std.mem.readInt(u16, bytes[0x10..0x12], .little),
        .animation = std.mem.readInt(u16, bytes[0x12..0x14], .little),
        .position = .{
            @bitCast(message.get(bytes, 0x14)),
            @bitCast(message.get(bytes, 0x18)),
            @bitCast(message.get(bytes, 0x1c)),
        },
        .angles = .{
            std.mem.readInt(i16, bytes[0x20..0x22], .little),
            std.mem.readInt(i16, bytes[0x22..0x24], .little),
            std.mem.readInt(i16, bytes[0x24..0x26], .little),
        },
        .velocity = .{
            message.get(bytes, 0x26),
            message.get(bytes, 0x2a),
            message.get(bytes, 0x2e),
        },
        .time = message.get(bytes, 0x32),
        .actor_flags = bits.from(ActorFlags, message.get(bytes, 0x36)),
        .entity = bits.from(ActorKind, message.get(bytes, 0x3a)),
    };

    for (update.position) |value| if (!std.math.isFinite(
        value,
    )) return error.MalformedNetworkMessage;

    return update;
}

pub fn sendActor(router: *Router, actor: Actor, now: u32) !void {
    var bytes: [update_size]u8 = @splat(0);
    @memcpy(bytes[0..message.header_size], &message.request(0, router.own_client));

    std.mem.writeInt(u16, bytes[0x10..0x12], actor.sector, .little);
    std.mem.writeInt(u16, bytes[0x12..0x14], actor.animation, .little);

    for (actor.position, 0..) |value, index| message.set(&bytes, 0x14 + 4 * index, @bitCast(value));

    for (actor.angles, 0..) |value, index| std.mem.writeInt(
        i16,
        bytes[0x20 + 2 * index ..][0..2],
        value,
        .little,
    );

    var vertical: f32 = @bitCast(actor.velocity[1]);

    if (actor.airborne) vertical = @floatCast(
        @as(f64, vertical) - @as(f64, actor.gravity) * @as(f64, actor.frame_seconds),
    );

    message.set(&bytes, 0x26, actor.velocity[0]);
    message.set(&bytes, 0x2a, @bitCast(vertical));
    message.set(&bytes, 0x2e, actor.velocity[2]);
    message.set(&bytes, 0x36, bits.word(actor.flags));
    message.set(&bytes, 0x3a, bits.word(actor.entity));

    const own = message.addressWord(message.Queue.dead_reckoning, @truncate(router.own_client));
    const word = actor.number & 0x7ff | own;

    message.set(&bytes, message.sender_offset, word);
    message.set(&bytes, message.reply_offset, word);

    _ = try router.post(0x200000, .{ .code = 0x418 }, &bytes);
    message.set(&bytes, 0x32, now);
    _ = try router.post(word, .{ .code = 0x418 }, &bytes);
}

pub fn packOne(change: Change, out: []u8) !usize {
    const size: usize = switch (change.kind) {
        0, 1 => 5,
        2, 3, 4, 7 => 7,
        5 => 11,
        6 => 21,
        8 => 9,
        9 => 4,
        else => return error.InvalidArchitectureChange,
    };

    if (out.len < size) return 0;

    out[0] = @truncate(change.kind);
    std.mem.writeInt(u16, out[1..3], change.sector, .little);

    switch (change.kind) {
        0, 1 => std.mem.writeInt(u16, out[3..5], @truncate(change.words[0]), .little),
        2 => {
            std.mem.writeInt(u16, out[3..5], @truncate(change.words[0]), .little);
            std.mem.writeInt(u16, out[5..7], @truncate(change.words[1]), .little);
        },
        3, 4, 7 => std.mem.writeInt(u32, out[3..7], change.words[0], .little),
        5 => {
            std.mem.writeInt(u32, out[3..7], change.words[0], .little);
            std.mem.writeInt(u32, out[7..11], change.words[1], .little);
        },
        6 => {
            std.mem.writeInt(u16, out[3..5], change.wall, .little);

            for (change.words, 0..) |word, i| std.mem.writeInt(
                u32,
                out[5 + 4 * i ..][0..4],
                word,
                .little,
            );
        },
        8 => {
            std.mem.writeInt(u16, out[3..5], change.wall, .little);
            std.mem.writeInt(u32, out[5..9], change.words[0], .little);
        },
        9 => out[3] = @truncate(change.words[0]),
        else => unreachable,
    }

    return size;
}

fn pack(changes: []const Change, index: *usize, out: []u8) !usize {
    var length: usize = 0;

    while (index.* < changes.len) {
        const change = changes[index.*];

        if (change.kind >= 10) {
            index.* += 1;
            continue;
        }

        const written = try packOne(change, out[length..]);
        if (written == 0) {
            if (length == 0) return error.ArchitectureChangeTooLong;
            return length;
        }

        length += written;
        index.* += 1;
    }

    return length;
}
