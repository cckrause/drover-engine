//! The router: client numbers and one message queue per module.
//!
//! Every message goes through here, single player included. A message for
//! this machine's own client stays local; anything else goes to the network
//! driver. Client records hold the address, the clock of the last message
//! from that client and the player name, and a client that leaves is
//! cleared rather than removed, so numbers stay stable.
//!
//! One deliberate addition: a message is refused when it does not come from
//! the client it claims to be from.

const std = @import("std");
const message = @import("message.zig");
const network_layer = @import("network.zig");
const contract = @import("driver.zig");
const message_store = @import("message_store.zig");
const MessageStore = message_store.MessageStore;
const Chain = message_store.Chain;
pub const Score = message.Score;

pub const client_slots = 256;

const multiplex_limit = 0x200;

/// Header of a multiplex packet plus the length word in front of a part.
const multiplex_overhead = 0x14 + 2;

/// The original router keeps its messages in a 512 KiB handle heap with
/// 32768 handles. The port reserves the same totals once, for queued
/// messages, messages being read and bundled parts waiting to be sent.
pub const max_queued_bytes = 512 * 1024;
pub const max_queued_messages = 32768;

const one_message = 'G';

pub const version_tag = "(1.1) ";

const no_name = "No Name Guy";

const unknown_name = "???";

const no_answer_text = "&5128\x00";

const set_client_address = 0x3f7;

pub const Client = struct {
    address: message.Address = message.no_address,
    last_heard: u32 = 0,
    name: [message.client_name_limit + 1]u8 = @splat(0),
    player: ?Player = null,
    in_level: bool = false,

    pub fn playerName(self: *const Client) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    pub fn setName(self: *Client, name: []const u8) void {
        const length = @min(name.len, message.client_name_limit);
        @memcpy(self.name[0..length], name[0..length]);
        @memset(self.name[length..message.client_name_limit], 0);
    }
};

pub const Player = struct { code: u8, flags: u32 };

pub const Game = struct {
    context: *anyopaque = undefined,
    players: *const fn (context: *anyopaque) anyerror!void = noPart,
    addClient: *const fn (context: *anyopaque, client: u32) anyerror!void = noClientPart,
    removeClient: *const fn (context: *anyopaque, client: u32) anyerror!void = noClientPart,
    describe: *const fn (context: *anyopaque) anyerror!void = noPart,
    scores: *const fn (context: *anyopaque) anyerror!void = noPart,
    departed: *const fn (context: *anyopaque, name: []const u8, destination: u32) anyerror!void = noDeparture,
    connecting: *const fn (context: *anyopaque) anyerror!void = noPart,
    leave: *const fn (context: *anyopaque) anyerror!void = noPart,
    local: *const fn (context: *anyopaque) anyerror!void = noPart,
    text: *const fn (context: *anyopaque, id: u32, buffer: []u8) void = noText,
    forget: *const fn (context: *anyopaque, client: u32) anyerror!void = noClientPart,

    fn noPart(_: *anyopaque) anyerror!void {
        return error.NetworkGamePartNotPorted;
    }

    fn noClientPart(_: *anyopaque, _: u32) anyerror!void {
        return error.NetworkGamePartNotPorted;
    }

    fn noDeparture(_: *anyopaque, _: []const u8, _: u32) anyerror!void {
        return error.NetworkGamePartNotPorted;
    }

    fn noText(_: *anyopaque, _: u32, _: []u8) void {}
};

pub const Posted = enum { queued, sent, invalid_client, no_session, multiplexed, too_large };

/// Messages for one client, sent bundled into MultiplexPackets.
pub const Multiplex = struct {
    client: u16,
    parts: Chain = .{},
};

pub const Lost = enum {
    server,
    network,
};

pub const JoinEnd = union(enum) {
    joined,
    failed: struct { shown: ?[message.reject_text_limit + 1]u8 },
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    own_client: u32 = 1,
    own_address: message.Address = message.no_address,
    reset_done: bool = false,
    clients: [client_slots]Client = @splat(.{}),
    client_count: u32 = 0,
    store: MessageStore,
    queues: [16]Chain = @splat(.{}),
    /// Messages handed out by `read`, kept until released.
    taken: Chain = .{},
    dropped: bool = false,
    network: network_layer.Network = .{},
    session_open: bool = false,
    now: u32 = 0,
    last_send: u32 = 0,
    queue_closed: [16]bool = @splat(false),
    lost: ?Lost = null,
    leave_game: bool = false,
    rejected: u32 = 0,
    receive_buffer: [0x800]u8 = undefined,
    game: Game = .{},
    scores: [client_slots]Score = @splat(.{}),
    team_points: [3]i16 = @splat(0),
    player_name: [message.client_name_limit + 1]u8 = ("Player" ++ [_]u8{0} ** (message.client_name_limit + 1 - 6)).*,
    join_password: [0x40]u8 = @splat(0),
    reject_text: [message.reject_text_limit + 1]u8 = @splat(0),
    join_done: bool = false,
    joining: bool = false,
    join_deadline: u32 = 0,
    join_tries: u32 = 0,
    join_saved_leave: bool = false,
    game_type: u32 = 1,
    sender_check: bool = true,
    multiplex: ?Multiplex = null,
    multiplex_ring: [8]?Multiplex = @splat(null),
    multiplex_write: u32 = 0,
    multiplex_read: u32 = 0,
    multiplex_due: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !Router {
        return .{ .allocator = allocator, .store = try MessageStore.init(allocator, max_queued_bytes, max_queued_messages) };
    }

    pub fn deinit(self: *Router) void {
        self.store.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Router) void {
        if (self.reset_done) return;

        self.dropped = false;
        self.client_count = 0;
        self.clients = @splat(.{});
        @memset(self.scores[0..0xff], .{});
        self.team_points = @splat(0);
        self.last_send = 0;
        self.multiplex_due = 0;
        self.own_client = 1;
        self.reset_done = true;
    }

    pub fn close(self: *Router) void {
        if (!self.reset_done) return;

        if (self.session_open) {
            self.network.close();
            self.session_open = false;
            self.clients = @splat(.{});
        }

        self.reset_done = false;
    }

    pub fn connect(self: *Router, hosting: bool, name: []const u8) !bool {
        if (self.session_open) {
            self.session_open = false;
            return false;
        }

        var buffer: [120]u8 = undefined;
        const session_name = if (hosting) blk: {
            if (name.len == 0) return error.MalformedNetworkSessionName;
            break :blk std.fmt.bufPrint(buffer[0..119], "{c}{s}{s}", .{ name[0], version_tag, name[1..] }) catch return error.MalformedNetworkSessionName;
        } else blk: {
            if (name.len != 0 and (name.len < 1 + version_tag.len or !std.mem.eql(u8, name[1..][0..version_tag.len], version_tag))) return false;
            if (name.len > 119) return error.MalformedNetworkSessionName;
            break :blk name;
        };

        if (self.player_name[0] == 0) @memcpy(self.player_name[0 .. no_name.len + 1], no_name ++ "\x00");

        try self.network.open(hosting, session_name, std.mem.sliceTo(&self.player_name, 0), &self.own_address);
        errdefer self.network.close();

        try self.game.connecting(self.game.context);
        self.join_saved_leave = self.leave_game;
        self.session_open = true;

        if (hosting) {
            self.clients[1].address = self.own_address;
            self.own_client = 1;
            self.clients[1].setName(std.mem.sliceTo(&self.player_name, 0));
            self.client_count = 1;
            self.scores[1] = .{};
            try self.game.scores(self.game.context);
            return true;
        }

        self.reject_text[0..no_answer_text.len].* = no_answer_text.*;
        self.join_done = false;

        try self.askForClient();

        self.join_deadline = self.now +% 5000;
        self.join_tries = 0;
        self.joining = true;

        return true;
    }

    pub fn stepJoin(self: *Router, cancelled: bool) !?JoinEnd {
        if (!self.joining) return error.NetworkJoinNotStarted;

        if (self.own_client == 0xffffffff and !self.join_done and !self.leave_game) {
            if (cancelled) self.join_done = true;
            self.clients[1].last_heard = self.now;
            if (self.join_deadline < self.now) {
                if (self.join_tries < 0x10) {
                    self.join_tries += 1;
                    try self.askForClient();
                    self.join_deadline = self.now +% 5000;
                } else self.join_done = true;
            }

            try self.process();
            return null;
        }

        self.joining = false;

        var shown: ?[message.reject_text_limit + 1]u8 = null;
        if (self.join_done) {
            self.own_client = 1;
            self.network.close();
            self.session_open = false;
            if (!self.dropped) {
                self.dropped = true;
                self.dropQueued();
                shown = self.reject_text;
            }

            self.leave_game = true;
        }

        if (!self.leave_game) return .joined;

        self.leave_game = self.join_saved_leave;
        try self.game.leave(self.game.context);
        self.dropped = false;
        try self.game.local(self.game.context);

        if (self.session_open) {
            self.network.close();
            self.session_open = false;
        }

        return .{ .failed = .{ .shown = shown } };
    }

    pub fn clearClient(self: *Router, number: u8) !void {
        const client = &self.clients[number];
        if (message.isNone(&client.address)) {
            std.log.debug("router_clearClientAddress: client entry {d} is already empty", .{number});
            return;
        }

        if (client.name[0] != 0 and client.in_level)
            try self.game.departed(self.game.context, client.playerName(), (self.own_client & 0xff) << 11);

        self.client_count -%= 1;
        client.address = message.no_address;
        client.in_level = false;

        if (self.own_client == 1) try self.game.describe(self.game.context);
        try self.game.removeClient(self.game.context, number);
        try self.game.players(self.game.context);
        if (self.game_type == 5) try self.game.forget(self.game.context, number);
    }

    pub fn post(self: *Router, destination: u32, number: u32, bytes: []u8) !Posted {
        if (bytes.len < message.header_size or bytes.len > 0xffff) return error.MalformedNetworkMessage;

        if (self.multiplex) |*table| {
            // A part that cannot fit an empty packet would never leave the
            // table and would hold every later table back (the original
            // sends an empty packet every 100 ms instead), so it is refused.
            if (bytes.len + multiplex_overhead >= multiplex_limit) {
                std.log.warn("router: a {d}-byte message does not fit a multiplex packet and is not sent", .{bytes.len});
                return .too_large;
            }

            const index = try self.store.add(bytes);
            const copy = self.store.get(index);
            message.set(copy, message.destination_offset, destination);
            message.set(copy, message.number_offset, number);
            table.parts.push(&self.store, index);

            return .multiplexed;
        }

        const target = message.client(destination);
        const must: u32 = number >> 31;
        message.set(bytes, message.destination_offset, destination);
        message.set(bytes, message.number_offset, number & 0xffffff);

        if (target == self.own_client and target != 0) {
            try self.addToQueues(bytes);
            return .queued;
        }

        if (target != 0 and message.isNone(&self.clients[target].address)) {
            std.log.debug("Router_PostMessage: Invalid client id {d}.", .{target});
            return .invalid_client;
        }

        if (message.isNone(&self.own_address) or self.own_client == 0xffffffff) return .no_session;
        if (bytes.len >= contract.max_data) return error.MalformedNetworkMessage;

        var packet: [contract.max_data]u8 = undefined;
        packet[0] = one_message;
        @memcpy(packet[1..][0..bytes.len], bytes);
        const sending = packet[0 .. bytes.len + 1];

        if (target != 0) {
            if (target == 1 and self.own_client != 1) self.last_send = self.now;
            try self.network.send(sending, &self.clients[target].address, must);
            return .sent;
        }

        self.last_send = self.now;
        if (must == 0) {
            try self.network.send(sending, null, 0);
            return .sent;
        }

        for (self.clients[1..], 1..) |*client, index| {
            if (index == 2 or index == self.own_client or message.isNone(&client.address)) continue;
            try self.network.send(sending, &client.address, must);
        }

        return .sent;
    }

    /// Starts bundling every message posted from here on for `client`.
    /// Returns the bundle that was being filled before, which
    /// `endMultiplex` or `cancelMultiplex` puts back.
    pub fn beginMultiplex(self: *Router, client: u16) ?Multiplex {
        const previous = self.multiplex;
        self.multiplex = .{ .client = client };
        return previous;
    }

    /// Queues the bundle for sending and goes back to `previous`.
    pub fn endMultiplex(self: *Router, previous: ?Multiplex) void {
        const table = self.multiplex.?;
        self.multiplex = previous;

        if (self.multiplex_ring[self.multiplex_write]) |*old| old.parts.clear(&self.store);
        self.multiplex_ring[self.multiplex_write] = table;
        self.multiplex_write += 1;
        if (self.multiplex_write > 7) self.multiplex_write = 0;
    }

    /// Drops the bundle without sending it and goes back to `previous`.
    pub fn cancelMultiplex(self: *Router, previous: ?Multiplex) void {
        self.multiplex.?.parts.clear(&self.store);
        self.multiplex = previous;
    }

    pub fn postHereAndEveryone(self: *Router, destination: u32, number: u32, bytes: []u8) !void {
        _ = try self.post((self.own_client & 0xff) << 11 | (destination & 0x7807ff), number, bytes);
        _ = try self.post(destination & 0x7807ff, number, bytes);
    }

    pub fn addToQueues(self: *Router, bytes: []const u8) !void {
        const index = try self.store.add(bytes);
        self.queues[message.queue(message.get(bytes, message.destination_offset))].push(&self.store, index);
    }

    /// The message stays valid and in place until it is released.
    pub fn read(self: *Router, queue_index: u4) !?[]u8 {
        try self.receive();

        const index = self.queues[queue_index].pop(&self.store) orelse return null;
        self.store.take(index);
        self.taken.push(&self.store, index);
        return self.store.get(index);
    }

    /// The next message waiting in a queue, left where it is.
    pub fn peek(self: *const Router, queue_index: u4) ?[]const u8 {
        const first = self.queues[queue_index].first;
        return if (first == message_store.none) null else self.store.get(first);
    }

    pub fn clientByAddress(self: *const Router, address: *const message.Address) ?u32 {
        for (self.clients[3..255], 3..) |*client, index| {
            if (index != self.own_client and std.mem.eql(u8, &client.address, address)) return @intCast(index);
        }
        return null;
    }

    pub fn dropQueued(self: *Router) void {
        for (&self.queues) |*queue| queue.clear(&self.store);
    }

    pub fn sendDirect(self: *Router, bytes: []const u8, to: *const message.Address, flags: u32) !void {
        if (bytes.len >= contract.max_data) return error.MalformedNetworkMessage;

        var packet: [contract.max_data]u8 = undefined;
        packet[0] = one_message;
        @memcpy(packet[1..][0..bytes.len], bytes);
        try self.network.send(packet[0 .. bytes.len + 1], to, flags);
    }

    pub fn setClient(self: *Router, number: u8, address: *const message.Address, name: []const u8) !void {
        const client = &self.clients[number];
        const new = message.isNone(&client.address);

        client.setName(name);
        client.address = address.*;
        client.last_heard = self.now;

        if (new) {
            self.client_count += 1;
            if (self.own_client == 1) try self.game.describe(self.game.context);
            try self.game.addClient(self.game.context, number);
        }

        try self.game.players(self.game.context);
    }

    pub fn announce(self: *Router) !void {
        if (!self.session_open or self.own_client == 0xffffffff or message.isNone(&self.own_address))
            return error.NetworkSessionNotOpen;

        var buffer: [message.client_address_capacity]u8 = undefined;
        const name = std.mem.sliceTo(&self.player_name, 0);
        const bytes = try message.clientAddress(&buffer, self.own_client, .{
            .client = self.own_client,
            .address = self.own_address,
            .name = name,
        });

        message.set(bytes, message.sender_offset, message.addressWord(message.Queue.router, @truncate(self.own_client)));
        message.set(bytes, message.reply_offset, 0x180000);
        _ = try self.post(0x180000, 0x3f7, bytes);

        try self.setClient(@truncate(self.own_client), &self.own_address, name);
    }

    pub fn join(self: *Router, address: *const message.Address, name: []const u8) !?u32 {
        for (self.clients[3..255], 3..) |*client, number| {
            if (std.mem.eql(u8, &client.address, address)) return @intCast(number);
        }

        const number: u8 = for (self.clients[3..255], 3..) |*client, number| {
            if (message.isNone(&client.address)) break @intCast(number);
        } else return null;

        const client = &self.clients[number];
        client.address = address.*;
        client.last_heard = self.now;
        client.setName(name);
        self.scores[number] = .{};

        try self.game.players(self.game.context);
        try self.game.addClient(self.game.context, number);
        self.client_count += 1;
        if (self.own_client == 1) try self.game.describe(self.game.context);

        try self.sendClientAddress(address, 1, &self.own_address, self.clients[1].playerName());
        for (self.clients[3..255], 3..) |*other, other_number| {
            if (message.isNone(&other.address)) continue;
            const other_name = other.playerName();
            try self.sendClientAddress(address, @intCast(other_number), &other.address, if (other_name.len == 0) unknown_name else other_name);
        }

        try self.game.scores(self.game.context);

        return number;
    }

    pub fn process(self: *Router) !void {
        try self.flushMultiplex();

        while (try self.read(message.Queue.router)) |bytes| {
            defer self.release(bytes);
            switch (message.get(bytes, message.number_offset)) {
                0x3f7 => {
                    const set = message.readClientAddress(bytes) catch {
                        self.rejected += 1;
                        continue;
                    };

                    if (self.sender_check and set.client == self.own_client and !std.mem.eql(u8, &self.own_address, &set.address)) {
                        self.rejected += 1;
                        continue;
                    }

                    if (std.mem.eql(u8, &self.own_address, &set.address)) self.own_client = set.client;
                    try self.setClient(@intCast(set.client), &set.address, set.name);
                },
                0x3f8 => self.repost(bytes) catch |err| switch (err) {
                    error.MalformedNetworkMessage => self.rejected += 1,
                    else => return err,
                },
                0x3f9 => {},
                0x3fb => {
                    const text = message.readRejectJoin(bytes) catch {
                        self.rejected += 1;
                        continue;
                    };
                    @memcpy(self.reject_text[0..text.len], text);
                    self.reject_text[text.len] = 0;

                    if (text.len != 0 and text[0] == '~') {
                        const id = atoi(text[1..]);
                        if (id != 0) self.game.text(self.game.context, id, &self.reject_text);
                    }

                    self.join_done = true;
                },
                else => {
                    var name: [16]u8 = undefined;
                    std.log.debug("Router_ProcessMessages: Unhandled message {s}", .{message.name(message.get(bytes, message.number_offset), &name)});
                },
            }
        }
    }

    pub fn setQueueClosed(self: *Router, queue_index: u4, closed: bool) void {
        self.queue_closed[queue_index] = closed;
    }

    pub fn release(self: *Router, bytes: []const u8) void {
        const index = self.taken.unlink(&self.store, bytes) orelse return;
        self.store.remove(index);
    }

    pub fn clientCount(self: *const Router) u32 {
        return self.client_count;
    }

    pub fn playerCount(self: *const Router) u32 {
        var count: u32 = 0;
        for (self.clients[1..], 1..) |*client, number| {
            if (number == 2 or message.isNone(&client.address)) continue;
            const player = client.player orelse continue;
            if (player.flags & 0x1000000 == 0) count += 1;
        }

        return count;
    }

    pub fn lastClient(self: *const Router) u32 {
        var number: u32 = 0xff;
        while (number != 0) : (number -= 1) {
            if (!message.isNone(&self.clients[number].address)) return number - 1;
        }

        return 1;
    }

    fn askForClient(self: *Router) !void {
        self.own_client = 0;

        var tag: [version_tag.len + 0x40]u8 = undefined;
        const password = std.fmt.bufPrint(&tag, "{s}{s}", .{ version_tag, std.mem.sliceTo(&self.join_password, 0) }) catch unreachable;

        var buffer: [message.join_capacity]u8 = undefined;
        const bytes = try message.join(&buffer, self.own_client, &self.own_address, std.mem.sliceTo(&self.player_name, 0), password);
        message.set(bytes, message.reply_offset, message.get(bytes, message.sender_offset));
        _ = try self.post(0x100000, 0x3e9, bytes);

        self.own_client = 0xffffffff;
    }

    fn fromItsClient(self: *const Router, bytes: []const u8, sender: *const message.Address) bool {
        if (bytes.len < message.header_size or message.isNone(sender)) return false;

        const from = message.client(message.get(bytes, message.sender_offset));
        const on_file = &self.clients[from].address;

        switch (message.get(bytes, message.number_offset)) {
            0x3e9 => {
                const request = message.readJoin(bytes) catch return false;
                return from == 0 and std.mem.eql(u8, &request.address, sender);
            },
            set_client_address => {
                const set = message.readClientAddress(bytes) catch return false;
                if (from == 1) {
                    const driver = self.network.session orelse return false;
                    return std.mem.eql(u8, &driver.host_address, sender);
                }
                return from >= 3 and from < 255 and set.client == from and std.mem.eql(u8, &set.address, sender) and
                    (message.isNone(on_file) or std.mem.eql(u8, on_file, sender));
            },
            0x3f8 => {
                if (!std.mem.eql(u8, on_file, sender) or bytes.len < 0x14) return false;

                var offset: usize = 0x14;
                for (0..message.get(bytes, 0x10)) |_| {
                    if (bytes.len - offset < 2) return false;
                    const length = std.mem.readInt(u16, bytes[offset..][0..2], .little);
                    offset += 2;
                    if (bytes.len - offset < length or !self.fromItsClient(bytes[offset..][0..length], sender)) return false;
                    offset += length;
                }

                return true;
            },
            else => return std.mem.eql(u8, on_file, sender),
        }
    }

    fn flushMultiplex(self: *Router) !void {
        if (self.now < self.multiplex_due) return;
        self.multiplex_due = self.now +% 100;

        if (self.multiplex_read == self.multiplex_write) return;
        const table = if (self.multiplex_ring[self.multiplex_read]) |*table| table else return;
        if (table.parts.count != 0) {
            var packet: [multiplex_limit]u8 = @splat(0);
            const own = message.addressWord(message.Queue.router, @truncate(self.own_client));
            message.set(&packet, message.sender_offset, own);
            message.set(&packet, message.reply_offset, own);

            var length: usize = 0x14;
            var count: u32 = 0;

            while (table.parts.first != message_store.none) {
                const part = self.store.get(table.parts.first);
                if (part.len + length + 2 >= multiplex_limit) break;

                std.mem.writeInt(u16, packet[length..][0..2], @intCast(part.len), .little);
                @memcpy(packet[length + 2 ..][0..part.len], part);
                length += part.len + 2;
                count += 1;
                message.set(&packet, 0x10, count);
                self.store.remove(table.parts.pop(&self.store).?);
            }

            const destination = message.addressWord(message.Queue.router, @truncate(table.client));
            _ = try self.post(destination, 0x3f8, packet[0..length]);
            if (table.parts.count != 0) return;
        }

        self.multiplex_ring[self.multiplex_read] = null;
        self.multiplex_read += 1;
        if (self.multiplex_read >= 8) self.multiplex_read = 0;
    }

    /// Takes at most one driver inbox of packets per call, so a flood of
    /// traffic cannot keep one read going.
    fn receive(self: *Router) !void {
        for (0..contract.waiting_messages) |_| {
            if (!self.session_open) return;

            var sender: message.Address = undefined;
            const length = try self.network.get(&self.receive_buffer, &sender);
            if (length == 0) return;

            const packet = self.receive_buffer[0..length];
            if (packet[0] == one_message) {
                const bytes = packet[1..];
                if (bytes.len < message.header_size or (self.sender_check and !self.fromItsClient(bytes, &sender))) {
                    self.rejected += 1;
                    continue;
                }

                const queue_index = message.queue(message.get(bytes, message.destination_offset));
                if (self.queue_closed[queue_index] or self.dropped) continue;

                const from = message.client(message.get(bytes, message.sender_offset));
                if (message.get(bytes, message.number_offset) != set_client_address) {
                    if (queue_index == message.Queue.server) {
                        if (self.own_client != 1) continue;
                    } else if (message.isNone(&self.clients[from].address)) continue;
                }

                self.clients[from].last_heard = self.now;
                try self.addToQueues(bytes);
                continue;
            }

            if (packet[0] != contract.player_gone[0]) continue;
            if (packet.len < 2) {
                self.rejected += 1;
                continue;
            }

            if (packet[1] == contract.player_gone[1]) {
                if (!std.mem.eql(u8, &sender, &self.clients[1].address)) {
                    if (self.clientByAddress(&sender)) |number| {
                        try self.clearClient(@intCast(number));
                    } else {
                        std.log.debug("router_clearClientByAddress: Unable to find a client with address!", .{});
                    }
                    continue;
                }

                if (!self.dropped) {
                    self.dropped = true;
                    self.dropQueued();
                    self.lost = .server;
                }
            } else {
                if (packet[1] != contract.session_ended[1]) continue;

                if (!self.dropped) {
                    self.dropped = true;
                    self.dropQueued();
                    self.lost = .network;
                }
            }

            self.leave_game = true;
        }
    }

    fn sendClientAddress(self: *Router, to: *const message.Address, number: u32, address: *const message.Address, name: []const u8) !void {
        var buffer: [message.client_address_capacity]u8 = undefined;
        const bytes = try message.clientAddress(&buffer, self.own_client, .{ .client = number, .address = address.*, .name = name });

        message.set(bytes, message.destination_offset, 0x180800);
        message.set(bytes, message.reply_offset, 0x180800);
        try self.sendDirect(bytes, to, 1);
    }

    fn repost(self: *Router, bytes: []u8) !void {
        if (bytes.len < 0x14) return error.MalformedNetworkMessage;

        var offset: usize = 0x14;
        for (0..message.get(bytes, 0x10)) |_| {
            if (bytes.len - offset < 2) return error.MalformedNetworkMessage;
            const length = std.mem.readInt(u16, bytes[offset..][0..2], .little);
            offset += 2;

            if (length < message.header_size or bytes.len - offset < length) return error.MalformedNetworkMessage;

            const part = bytes[offset..][0..length];
            offset += length;
            _ = try self.post(message.get(part, message.destination_offset), message.get(part, message.number_offset), part);
        }
    }
};

fn atoi(text: []const u8) u32 {
    var rest = std.mem.trimStart(u8, text, " \t\n\r\x0b\x0c");
    const negative = rest.len != 0 and rest[0] == '-';
    if (rest.len != 0 and (rest[0] == '-' or rest[0] == '+')) rest = rest[1..];

    var value: u32 = 0;
    for (rest) |digit| {
        if (digit < '0' or digit > '9') break;
        value = value *% 10 +% (digit - '0');
    }

    return if (negative) 0 -% value else value;
}

test "router keeps queued messages through reset and frees only taken ones" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();
    router.reset();

    var request: [message.header_size]u8 = @splat(0);
    try std.testing.expectEqual(Posted.queued, try router.post(message.addressWord(message.Queue.server, 1), 0x3ef, &request));

    router.close();
    router.own_client = 6;
    router.reset();
    try std.testing.expectEqual(@as(u32, 1), router.own_client);

    try std.testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.database));

    const taken = (try router.read(message.Queue.server)).?;
    try std.testing.expectEqual(@as(u32, 0x3ef), message.get(taken, message.number_offset));
    router.release(taken);
    try std.testing.expectEqual(@as(usize, 0), router.taken.count);
}

test "post here and to everyone keeps the own client on the first copy" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();
    router.reset();
    router.own_client = 5;

    var request: [message.header_size]u8 = @splat(0);
    try router.postHereAndEveryone(0x100800, 0x7d6, &request);

    const queued = (try router.read(message.Queue.server)).?;
    try std.testing.expectEqual(@as(u32, 0x102800), message.get(queued, message.destination_offset));
    router.release(queued);

    try std.testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.server));
    try std.testing.expectEqual(@as(u32, 0x100000), message.get(&request, message.destination_offset));
}

test "a multiplexed message too large for any packet is refused when posted" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();
    router.reset();

    _ = router.beginMultiplex(3);
    defer router.cancelMultiplex(null);

    var fits: [multiplex_limit - multiplex_overhead - 1]u8 = @splat(0);
    try std.testing.expectEqual(Posted.multiplexed, try router.post(0x100000, 0x3ef, &fits));

    var too_large: [multiplex_limit - multiplex_overhead]u8 = @splat(0);
    try std.testing.expectEqual(Posted.too_large, try router.post(0x100000, 0x3ef, &too_large));
    try std.testing.expectEqual(@as(usize, 1), router.multiplex.?.parts.count);
}

test "queued messages are held to the router's totals and counted until freed" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();
    router.reset();

    var request: [0x400]u8 = @splat(0);
    const destination = message.addressWord(message.Queue.server, 1);

    for (0..max_queued_bytes / request.len) |_| _ = try router.post(destination, 0x3ef, &request);
    try std.testing.expectEqual(@as(usize, max_queued_bytes), router.store.used_bytes);
    try std.testing.expectError(error.NetworkQueueFull, router.post(destination, 0x3ef, &request));

    const taken = (try router.read(message.Queue.server)).?;
    try std.testing.expectError(error.NetworkQueueFull, router.post(destination, 0x3ef, &request));
    router.release(taken);
    _ = try router.post(destination, 0x3ef, &request);

    router.dropQueued();
    try std.testing.expectEqual(@as(usize, 0), router.store.used_bytes);
    try std.testing.expectEqual(@as(usize, 0), router.store.used_slots);

    var small: [message.header_size]u8 = @splat(0);
    for (0..max_queued_messages) |_| _ = try router.post(destination, 0x3ef, &small);
    try std.testing.expectError(error.NetworkQueueFull, router.post(destination, 0x3ef, &small));
}

test "queued messages, messages being read and bundles reuse the router's storage without asking for memory" {
    var watch = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var router = try Router.init(watch.allocator());
    defer router.deinit();
    router.reset();

    watch.fail_index = watch.alloc_index;
    watch.resize_fail_index = watch.resize_index;

    var request: [message.header_size + 8]u8 = @splat(0);
    const destination = message.addressWord(message.Queue.server, 1);

    for (0..1000) |_| {
        const previous = router.beginMultiplex(1);
        for (0..10) |_| try std.testing.expectEqual(Posted.multiplexed, try router.post(destination, 0x3ef, &request));
        router.endMultiplex(previous);

        _ = try router.post(destination, 0x3f0, &request);
        router.now += 100;
        try router.process();

        const first = (try router.read(message.Queue.server)).?;
        try std.testing.expectEqual(@as(u32, 0x3f0), message.get(first, message.number_offset));

        var parts: usize = 0;
        while (try router.read(message.Queue.server)) |bytes| {
            defer router.release(bytes);
            try std.testing.expectEqual(@as(u32, 0x3ef), message.get(bytes, message.number_offset));
            try std.testing.expectEqual(destination, message.get(bytes, message.destination_offset));
            parts += 1;
        }

        try std.testing.expectEqual(@as(usize, 10), parts);
        try std.testing.expectEqual(@as(u32, 0x3f0), message.get(first, message.number_offset));
        router.release(first);
        try std.testing.expectEqual(@as(usize, 0), router.store.used_slots);
    }
}

test "one read takes at most one driver inbox of packets" {
    const Flood = struct {
        sent: usize = 0,

        fn send(_: *anyopaque, _: []const u8, _: ?*const message.Address, _: u32) anyerror!void {}

        fn get(context: *anyopaque, buffer: []u8, sender: *message.Address) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sent += 1;
            sender.* = message.no_address;
            sender[0] = 3;
            buffer[0] = one_message;
            @memset(buffer[1 .. 1 + message.header_size], 0);
            message.set(buffer[1..], message.destination_offset, message.addressWord(message.Queue.database, 1));
            message.set(buffer[1..], message.sender_offset, message.addressWord(message.Queue.database, 3));
            return 1 + message.header_size;
        }
    };

    var flood: Flood = .{};
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();
    router.reset();

    router.sender_check = false;
    router.session_open = true;
    router.clients[3].address = message.no_address;
    router.clients[3].address[0] = 3;
    router.network.session = .{ .context = &flood, .send = Flood.send, .get = Flood.get };
    defer router.network.session = null;

    const first = (try router.read(message.Queue.database)).?;
    router.release(first);

    try std.testing.expectEqual(@as(usize, contract.waiting_messages), flood.sent);
    try std.testing.expectEqual(@as(usize, contract.waiting_messages - 1), router.queues[message.Queue.database].count);
}

test "a driver that fails to receive is reported, not read as silence" {
    const Broken = struct {
        fn send(_: *anyopaque, _: []const u8, _: ?*const message.Address, _: u32) anyerror!void {
            return error.SendFailed;
        }

        fn get(_: *anyopaque, _: []u8, _: *message.Address) anyerror!usize {
            return error.ReceiveFailed;
        }
    };

    var router = try Router.init(std.testing.allocator);
    defer router.deinit();
    router.reset();

    router.session_open = true;
    var context: u8 = 0;
    router.network.session = .{ .context = &context, .send = Broken.send, .get = Broken.get };
    defer router.network.session = null;

    try std.testing.expectError(error.ReceiveFailed, router.read(message.Queue.database));

    router.own_address = message.no_address;
    router.own_address[0] = 1;
    router.clients[3].address = router.own_address;
    router.clients[3].address[0] = 3;

    var request: [message.header_size]u8 = @splat(0);
    try std.testing.expectError(error.SendFailed, router.post(message.addressWord(message.Queue.database, 3), 0x3ef, &request));
}
