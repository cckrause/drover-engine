//! The network driver, on the ENet library compiled into the program. It
//! provides what the game asks of a driver: open and close a session, send
//! a buffer, receive a buffer, list sessions.
//!
//! Deliberate differences from the original driver: everything goes through
//! the host, so a joiner only ever talks to the host and the host passes
//! messages on. ENet keeps each channel in order by itself, so a must-arrive
//! message being resent does not hold up the others. Every packet starts
//! with its kind and one player number, and the host turns away a connection
//! whose handshake is not this driver's.
//!
//! Playing against original clients is not a goal.

const std = @import("std");

const contract = @import("../network/driver.zig");
const message = @import("../network/message.zig");
const network_layer = @import("../network/network.zig");
const router_module = @import("../network/router.zig");
const Address = message.Address;
const testing = std.testing;
const c_memory = @import("c_memory.zig");

pub const c = @cImport({
    @cInclude("enet.h");
});

const protocol: u32 = 0x4f4c_0001;

const host_id: u32 = 1;

const channel_must_arrive = 0;

const channel_may_be_lost = 1;

const channels = 2;

const header = 5;

const kind_message = 'M';

const kind_welcome = 'W';

const kind_left = 'L';

pub const description_limit = 0x400;

var open_sessions: u32 = 0;

const Waiting = struct {
    sender: Address,
    length: u16,
    data: [contract.max_data]u8,
};

const Inbox = struct {
    slots: []Waiting,
    first: usize = 0,
    count: usize = 0,

    fn full(self: *const Inbox) bool {
        return self.count == self.slots.len;
    }

    fn push(self: *Inbox, sender: Address, data: []const u8) void {
        std.debug.assert(!self.full() and data.len <= contract.max_data);
        const slot = &self.slots[(self.first + self.count) % self.slots.len];

        slot.sender = sender;
        slot.length = @intCast(data.len);

        @memcpy(slot.data[0..data.len], data);
        self.count += 1;
    }

    fn peek(self: *const Inbox) ?*const Waiting {
        return if (self.count == 0) null else &self.slots[self.first];
    }

    fn drop(self: *Inbox) void {
        self.first = (self.first + 1) % self.slots.len;
        self.count -= 1;
    }
};

const Player = struct {
    id: u32,
    peer: *c.ENetPeer,
};

pub const HostOptions = struct {
    port: u16 = contract.port,
    name: []const u8 = "",
};

pub const JoinOptions = struct {
    host: [:0]const u8,
    port: u16 = contract.port,
    wait_ms: u32 = 10000,
};

pub const OpenError = error{ CannotOpen, UnknownHost, NoAnswer, Refused, OutOfMemory };

pub const SendError = error{ SessionEnded, BadLength, OutOfMemory, SendFailed, InboxFull };

pub const JoinState = enum { waiting, joined, refused };

pub const SessionInfo = struct {
    name: [49]u8 = @splat(0),
    host: [64]u8 = @splat(0),

    pub fn sessionName(self: *const SessionInfo) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    pub fn hostName(self: *const SessionInfo) []const u8 {
        return std.mem.sliceTo(&self.host, 0);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    enet: *c.ENetHost,
    hosting: bool,
    own: u32,
    server: ?*c.ENetPeer = null,
    players: std.ArrayList(Player) = .empty,
    next_id: u32 = host_id + 1,
    inbox: Inbox,
    ended: bool = false,
    refused: bool = false,
    rejected: u32 = 0,
    discovery: c.ENetSocket = c.ENET_SOCKET_NULL,
    name: [49]u8 = @splat(0),
    description: [description_limit]u8 = undefined,
    description_length: usize = 0,
    /// A send the host made on its own (a relay, a welcome, a leave notice)
    /// that failed; the next receive reports it.
    failure: ?SendError = null,

    pub fn host(allocator: std.mem.Allocator, options: HostOptions) OpenError!Session {
        var address = std.mem.zeroes(c.ENetAddress);
        address.port = options.port;
        var self = try create(allocator, &address, contract.max_players - 1);

        self.hosting = true;
        self.own = host_id;
        if (options.name.len > 48) {
            self.destroy();
            return error.CannotOpen;
        }

        @memcpy(self.name[0..options.name.len], options.name);

        if (options.name.len != 0) {
            if (self.port() == std.math.maxInt(u16)) {
                self.destroy();
                return error.CannotOpen;
            }

            self.discovery = c.enet_socket_create(c.ENET_SOCKET_TYPE_DATAGRAM);
            if (self.discovery == c.ENET_SOCKET_NULL) {
                self.destroy();
                return error.CannotOpen;
            }

            var where = std.mem.zeroes(c.ENetAddress);

            where.port = self.port() + 1;
            if (c.enet_socket_set_option(
                self.discovery,
                c.ENET_SOCKOPT_NONBLOCK,
                1,
            ) != 0 or c.enet_socket_bind(self.discovery, &where) != 0) {
                self.destroy();
                return error.CannotOpen;
            }
        }

        return self;
    }

    pub fn beginJoin(allocator: std.mem.Allocator, options: JoinOptions) OpenError!Session {
        var self = try create(allocator, null, 1);
        errdefer self.destroy();
        var address = std.mem.zeroes(c.ENetAddress);
        if (c.enet_address_set_host(&address, options.host.ptr) != 0) return error.UnknownHost;

        address.port = options.port;
        self.server = c.enet_host_connect(
            self.enet,
            &address,
            channels,
            protocol,
        ) orelse return error.CannotOpen;

        return self;
    }

    pub fn joinStep(self: *Session) JoinState {
        self.service(0);

        return self.joinState();
    }

    pub fn join(allocator: std.mem.Allocator, options: JoinOptions) OpenError!Session {
        var self = try beginJoin(allocator, options);
        errdefer self.close();
        const began = c.enet_time_get();

        while (true) {
            switch (self.joinState()) {
                .joined => return self,
                .refused => return error.Refused,
                .waiting => {},
            }

            const passed = c.enet_time_get() -% began;
            if (passed >= options.wait_ms) return error.NoAnswer;

            self.service(@min(50, options.wait_ms - passed));
        }
    }

    pub fn port(self: *const Session) u16 {
        return self.enet.*.address.port;
    }

    pub fn ownAddress(self: *const Session) Address {
        return addressOf(self.own);
    }

    pub fn close(self: *Session) void {
        var saying: usize = 0;

        if (self.hosting) {
            for (self.players.items) |player| c.enet_peer_disconnect(player.peer, 0);
            saying = self.players.items.len;
        } else if (self.server) |server| {
            if (self.own != 0) {
                c.enet_peer_disconnect(server, 0);
                saying = 1;
            } else c.enet_peer_reset(server);
        }

        const began = c.enet_time_get();

        while (saying > 0) {
            const passed = c.enet_time_get() -% began;

            if (passed >= contract.goodbye_ms) break;

            var event: c.ENetEvent = undefined;
            const got = c.enet_host_service(
                self.enet,
                &event,
                @min(100, contract.goodbye_ms - passed),
            );

            if (got < 0) break;

            if (got == 0) continue;

            switch (event.type) {
                c.ENET_EVENT_TYPE_RECEIVE => c.enet_packet_destroy(event.packet),
                c.ENET_EVENT_TYPE_DISCONNECT, c.ENET_EVENT_TYPE_DISCONNECT_TIMEOUT => saying -= 1,
                c.ENET_EVENT_TYPE_CONNECT => c.enet_peer_disconnect_now(event.peer, 0),
                else => {},
            }
        }

        self.destroy();
    }

    pub fn send(self: *Session, data: []const u8, to: ?*const Address, flags: u8) SendError!void {
        if (self.ended) return error.SessionEnded;
        if (data.len == 0 or data.len > contract.max_data) return error.BadLength;

        const everyone = contract.isEveryone(to);
        const must = flags & contract.must_arrive != 0 and !everyone;
        const target: u32 = if (everyone) 0 else idOf(to.?) orelse return;
        if (target == self.own) {
            // A must-arrive message to this machine cannot be dropped quietly.
            if (self.inbox.full()) return if (must) error.InboxFull else {};
            self.inbox.push(addressOf(self.own), data);
            return;
        }

        // Every player still gets the message when one send fails; the first
        // failure is reported afterwards.
        var failure: ?SendError = null;

        if (self.hosting) {
            for (self.players.items) |player| {
                if (target == 0 or player.id == target) post(
                    player.peer,
                    kind_message,
                    self.own,
                    data,
                    must,
                ) catch |err| {
                    if (failure == null) failure = err;
                };
            }
        } else if (self.server) |server| post(
            server,
            kind_message,
            target,
            data,
            must,
        ) catch |err| {
            failure = err;
        };

        c.enet_host_flush(self.enet);
        if (failure) |err| return err;
    }

    pub fn receive(
        self: *Session,
        buffer: []u8,
        sender: *Address,
    ) (error{BufferTooSmall} || SendError)!usize {
        self.service(0);
        if (self.failure) |err| {
            self.failure = null;
            return err;
        }

        const waiting = self.inbox.peek() orelse return 0;
        const length: usize = waiting.length;
        if (buffer.len < length) return error.BufferTooSmall;

        @memcpy(buffer[0..length], waiting.data[0..length]);
        sender.* = waiting.sender;
        self.inbox.drop();

        return length;
    }

    pub fn driver(self: *Session) network_layer.Driver {
        return .{
            .context = self,
            .send = driverSend,
            .get = driverGet,
            .describe = driverDescribe,
            .host_address = addressOf(host_id),
        };
    }

    pub fn describe(self: *Session, data: []const u8) error{ NotHosting, DescriptionTooLong }!void {
        if (!self.hosting) return error.NotHosting;
        if (data.len > description_limit) return error.DescriptionTooLong;
        @memcpy(self.description[0..data.len], data);
        self.description_length = data.len;
    }

    pub fn service(self: *Session, wait_ms: u32) void {
        if (self.hosting) self.answerDiscovery();

        var wait = wait_ms;

        // At most one inbox of messages is taken from the network per call.
        while (!self.inbox.full()) {
            var event: c.ENetEvent = undefined;
            if (c.enet_host_service(self.enet, &event, wait) <= 0) return;
            wait = 0;
            if (self.hosting) self.hostEvent(&event) else self.joinerEvent(&event);
        }
    }

    fn joinState(self: *const Session) JoinState {
        if (self.refused) return .refused;

        return if (self.own == 0) .waiting else .joined;
    }

    fn create(
        allocator: std.mem.Allocator,
        address: ?*const c.ENetAddress,
        peers: usize,
    ) OpenError!Session {
        try start();
        errdefer stop();

        const slots = try allocator.alloc(Waiting, contract.waiting_messages);
        errdefer allocator.free(slots);
        // One entry for every peer ENet lets in, so a join asks for no memory.
        var players: std.ArrayList(Player) = try .initCapacity(allocator, peers);
        errdefer players.deinit(allocator);
        const enet = c.enet_host_create(
            address,
            peers,
            channels,
            0,
            0,
        ) orelse return error.CannotOpen;

        // A peer may hold back no more than an inbox of messages while they
        // are put together. Oversized messages still arrive and are refused
        // by the driver, so they cannot block the rest of that peer's channel.
        enet.*.maximumWaitingData = contract.waiting_messages * (header + contract.max_data);

        return .{
            .allocator = allocator,
            .enet = enet,
            .hosting = false,
            .own = 0,
            .players = players,
            .inbox = .{ .slots = slots },
        };
    }

    fn destroy(self: *Session) void {
        if (self.discovery != c.ENET_SOCKET_NULL) c.enet_socket_destroy(self.discovery);

        c.enet_host_destroy(self.enet);
        self.players.deinit(self.allocator);
        self.allocator.free(self.inbox.slots);
        stop();

        self.* = undefined;
    }

    fn driverDescribe(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        try self.describe(data);
    }

    fn driverSend(
        context: *anyopaque,
        data: []const u8,
        to: ?*const Address,
        flags: u32,
    ) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));

        return quietAfterEnd(self.send(data, to, @truncate(flags)));
    }

    fn driverGet(context: *anyopaque, buffer: []u8, sender: *Address) anyerror!usize {
        const self: *Session = @ptrCast(@alignCast(context));

        return self.receive(buffer, sender);
    }

    fn answerDiscovery(self: *Session) void {
        if (self.discovery == c.ENET_SOCKET_NULL or self.name[0] == 0) return;

        var incoming: [64]u8 = undefined;
        var buffer = c.ENetBuffer{ .data = &incoming, .dataLength = incoming.len };
        var from = std.mem.zeroes(c.ENetAddress);

        // Requests beyond one inbox's worth wait for the next pass.
        for (0..contract.waiting_messages) |_| {
            const n = c.enet_socket_receive(self.discovery, &from, &buffer, 1);
            if (n <= 0) return;

            if (n != 4 or !std.mem.eql(u8, incoming[0..4], "OLD1")) continue;

            var reply: [54]u8 = @splat(0);
            @memcpy(reply[0..4], "OLS1");
            const name = std.mem.sliceTo(&self.name, 0);
            reply[4] = @intCast(name.len);
            @memcpy(reply[5 .. 5 + name.len], name);
            const packet = c.ENetBuffer{ .data = &reply, .dataLength = 5 + name.len };
            _ = c.enet_socket_send(self.discovery, &from, &packet, 1);
        }
    }

    fn hostEvent(self: *Session, event: *const c.ENetEvent) void {
        switch (event.type) {
            c.ENET_EVENT_TYPE_CONNECT => self.welcome(event.peer, event.data),
            c.ENET_EVENT_TYPE_RECEIVE => {
                defer c.enet_packet_destroy(event.packet);
                const from = self.playerOf(event.peer) orelse return self.reject();
                const bytes = event.packet.*.data[0..event.packet.*.dataLength];
                const body = messageBody(bytes) orelse return self.reject();
                const to = std.mem.readInt(u32, bytes[1..5], .little);
                const must = event.channelID == channel_must_arrive;

                if (to == 0 or to == host_id) self.inbox.push(addressOf(from), body);

                if (to == host_id) return;

                for (self.players.items) |player| {
                    if (if (to == 0) player.id != from else player.id == to) self.postOwn(
                        player.peer,
                        kind_message,
                        from,
                        body,
                        must,
                    );
                }
            },
            c.ENET_EVENT_TYPE_DISCONNECT, c.ENET_EVENT_TYPE_DISCONNECT_TIMEOUT => {
                const gone = self.forget(event.peer) orelse return;
                self.inbox.push(addressOf(gone), contract.player_gone);

                for (self.players.items) |player| self.postOwn(
                    player.peer,
                    kind_left,
                    gone,
                    "",
                    true,
                );
            },
            else => {},
        }
    }

    fn welcome(self: *Session, peer: *c.ENetPeer, asked: u32) void {
        if (asked != protocol or self.next_id == std.math.maxInt(
            u32,
        )) return c.enet_peer_disconnect_now(peer, 0);

        if (self.players.items.len == self.players.capacity) return c.enet_peer_disconnect_now(
            peer,
            0,
        );

        self.players.appendAssumeCapacity(.{ .id = self.next_id, .peer = peer });
        c.enet_peer_timeout(peer, 0, contract.silence_ms, contract.silence_ms);
        self.postOwn(peer, kind_welcome, self.next_id, "", true);

        self.next_id += 1;
    }

    fn postOwn(
        self: *Session,
        peer: *c.ENetPeer,
        kind: u8,
        id: u32,
        data: []const u8,
        must: bool,
    ) void {
        post(peer, kind, id, data, must) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }

    fn joinerEvent(self: *Session, event: *const c.ENetEvent) void {
        switch (event.type) {
            c.ENET_EVENT_TYPE_CONNECT => c.enet_peer_timeout(
                event.peer,
                0,
                contract.silence_ms,
                contract.silence_ms,
            ),
            c.ENET_EVENT_TYPE_RECEIVE => {
                defer c.enet_packet_destroy(event.packet);
                const bytes = event.packet.*.data[0..event.packet.*.dataLength];
                if (bytes.len < header) return self.reject();

                const id = std.mem.readInt(u32, bytes[1..5], .little);
                const bare = bytes.len == header;

                switch (bytes[0]) {
                    kind_welcome => if (self.own == 0 and bare and id > host_id) {
                        self.own = id;
                    } else self.reject(),
                    kind_message => {
                        const body = messageBody(bytes) orelse return self.reject();
                        if (self.own == 0 or id == 0) return self.reject();
                        self.inbox.push(addressOf(id), body);
                    },
                    kind_left => if (self.own != 0 and bare and id > host_id and id != self.own) {
                        self.inbox.push(addressOf(id), contract.player_gone);
                    } else self.reject(),
                    else => self.reject(),
                }
            },
            c.ENET_EVENT_TYPE_DISCONNECT, c.ENET_EVENT_TYPE_DISCONNECT_TIMEOUT => {
                self.server = null;

                if (self.own == 0) {
                    self.refused = true;
                } else if (!self.ended) {
                    self.inbox.push(addressOf(host_id), contract.session_ended);
                    self.ended = true;
                }
            },
            else => {},
        }
    }

    fn reject(self: *Session) void {
        self.rejected += 1;
    }

    fn playerOf(self: *const Session, peer: *c.ENetPeer) ?u32 {
        for (self.players.items) |player| {
            if (player.peer == peer) return player.id;
        }

        return null;
    }

    fn forget(self: *Session, peer: *c.ENetPeer) ?u32 {
        for (self.players.items, 0..) |player, index| {
            if (player.peer != peer) continue;
            _ = self.players.orderedRemove(index);
            return player.id;
        }

        return null;
    }
};

pub const Opener = struct {
    allocator: std.mem.Allocator,
    host: [:0]const u8 = "",
    port: u16 = contract.port,
    wait_ms: u32 = 10000,
    session: ?Session = null,

    pub fn provider(self: *Opener) network_layer.Provider {
        return .{ .context = self, .open = open };
    }

    fn open(
        context: *anyopaque,
        hosting: bool,
        name: []const u8,
        player: []const u8,
        address: *Address,
    ) anyerror!network_layer.Driver {
        const self: *Opener = @ptrCast(@alignCast(context));

        _ = player;
        if (self.session != null) return error.SessionAlreadyOpen;

        self.session = if (hosting)
            try Session.host(self.allocator, .{ .port = self.port, .name = name })
        else
            try Session.join(
                self.allocator,
                .{ .host = self.host, .port = self.port, .wait_ms = self.wait_ms },
            );

        address.* = self.session.?.ownAddress();

        return .{
            .context = self,
            .send = send,
            .get = get,
            .close = close,
            .describe = describe,
            .host_address = addressOf(host_id),
        };
    }

    fn describe(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Opener = @ptrCast(@alignCast(context));
        try self.session.?.describe(data);
    }

    fn send(context: *anyopaque, data: []const u8, to: ?*const Address, flags: u32) anyerror!void {
        const self: *Opener = @ptrCast(@alignCast(context));

        return quietAfterEnd(self.session.?.send(data, to, @truncate(flags)));
    }

    fn get(context: *anyopaque, buffer: []u8, sender: *Address) anyerror!usize {
        const self: *Opener = @ptrCast(@alignCast(context));

        return self.session.?.receive(buffer, sender);
    }

    fn close(context: *anyopaque) void {
        const self: *Opener = @ptrCast(@alignCast(context));
        self.session.?.close();
        self.session = null;
    }
};

const Answering = struct {
    session: *Session,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Answering) void {
        while (!self.stop.load(.acquire)) self.session.service(1);
    }
};

pub fn addressOf(id: u32) Address {
    var address: Address = @splat(0);
    std.mem.writeInt(u32, address[0..4], id, .little);

    return address;
}

pub fn idOf(address: *const Address) ?u32 {
    if (!std.mem.allEqual(u8, address[4..], 0)) return null;
    const id = std.mem.readInt(u32, address[0..4], .little);

    return if (id == 0) null else id;
}

pub fn listSessions(allocator: std.mem.Allocator, port: u16, wait_ms: u32) OpenError![]SessionInfo {
    if (port == std.math.maxInt(u16)) return error.CannotOpen;

    try start();
    defer stop();

    const socket = c.enet_socket_create(c.ENET_SOCKET_TYPE_DATAGRAM);
    if (socket == c.ENET_SOCKET_NULL) return error.CannotOpen;

    defer c.enet_socket_destroy(socket);
    if (c.enet_socket_set_option(socket, c.ENET_SOCKOPT_NONBLOCK, 1) != 0 or
        c.enet_socket_set_option(socket, c.ENET_SOCKOPT_BROADCAST, 1) != 0) return error.CannotOpen;

    const request = c.ENetBuffer{ .data = @ptrCast(@constCast("OLD1")), .dataLength = 4 };

    for ([_][:0]const u8{ "127.0.0.1", "255.255.255.255" }) |target| {
        var where = std.mem.zeroes(c.ENetAddress);
        if (c.enet_address_set_host(&where, target.ptr) != 0) continue;
        where.port = port + 1;
        _ = c.enet_socket_send(socket, &where, &request, 1);
    }

    var found: std.ArrayList(SessionInfo) = .empty;
    errdefer found.deinit(allocator);
    const began = c.enet_time_get();

    while (c.enet_time_get() -% began < wait_ms and found.items.len < 16) {
        var ready: c.enet_uint32 = c.ENET_SOCKET_WAIT_RECEIVE;
        const remain = wait_ms - (c.enet_time_get() -% began);

        if (c.enet_socket_wait(socket, &ready, remain) != 0) break;

        if (ready & c.ENET_SOCKET_WAIT_RECEIVE == 0) continue;

        var bytes: [54]u8 = undefined;
        var buffer = c.ENetBuffer{ .data = &bytes, .dataLength = bytes.len };
        var from = std.mem.zeroes(c.ENetAddress);
        const n = c.enet_socket_receive(socket, &from, &buffer, 1);

        if (n < 6 or n > bytes.len or !std.mem.eql(u8, bytes[0..4], "OLS1")) continue;

        const length: usize = bytes[4];

        if (length == 0 or length > 48 or n != length + 5) continue;

        var info = SessionInfo{};
        @memcpy(info.name[0..length], bytes[5 .. 5 + length]);

        if (std.mem.indexOfScalar(u8, info.name[0..length], 0) != null) continue;

        if (c.enet_address_get_host_ip(&from, &info.host, info.host.len) != 0) continue;

        var duplicate = false;

        for (found.items) |*old| if (std.mem.eql(
            u8,
            old.sessionName(),
            info.sessionName(),
        ) and std.mem.eql(u8, old.hostName(), info.hostName())) {
            duplicate = true;
            break;
        };

        if (!duplicate) try found.append(allocator, info);
    }

    return found.toOwnedSlice(allocator);
}

fn start() OpenError!void {
    if (open_sessions == 0) {
        // Standalone driver callers keep libc allocation. The application
        // installs its reservation before any session can be opened.
        const bounded = c_memory.installed();
        var callbacks: c.ENetCallbacks = std.mem.zeroes(c.ENetCallbacks);

        callbacks.malloc = if (bounded) c_memory.malloc else std.c.malloc;
        callbacks.free = if (bounded) c_memory.free else std.c.free;
        callbacks.no_memory = if (bounded) c_memory.noMemory else abortOnNoMemory;
        if (c.enet_initialize_with_callbacks(c.ENET_VERSION, &callbacks) != 0)
            return error.CannotOpen;
    }

    open_sessions += 1;
}

fn abortOnNoMemory() callconv(.c) void {
    std.c.abort();
}

test "memory budget ENet callbacks release storage and report exhaustion" {
    var budget = try @import(
        "MemoryBudget.zig",
    ).init(testing.allocator, testing.io, 4 * 1024 * 1024);

    defer budget.deinit(testing.allocator);

    try c_memory.install(budget.allocator());
    defer c_memory.uninstall();

    {
        var session = try Session.host(budget.allocator(), .{ .port = 0 });
        defer session.close();

        try testing.expect(c_memory.count() > 0);
        const packet = c.enet_packet_create(null, 128, 0) orelse return error.OutOfMemory;

        c.enet_packet_destroy(packet);
        try testing.expect(c.enet_packet_create(null, 8 * 1024 * 1024, 0) == null);
        try testing.expect(c_memory.exhausted());
        try testing.expectError(error.MemoryBudgetExceeded, budget.check());
    }

    try testing.expectEqual(@as(usize, 0), c_memory.count());
    try testing.expectEqual(@as(usize, 0), budget.stats().used);
}

test "a player joins the host without the host asking for memory" {
    var watch = testing.FailingAllocator.init(testing.allocator, .{});
    var server = try Session.host(watch.allocator(), .{ .port = 0 });
    defer server.close();

    watch.fail_index = watch.alloc_index;
    watch.resize_fail_index = watch.resize_index;

    var joiner = try joinSoon(&server);
    defer closeSoon(&server, &joiner);

    try testing.expectEqual(1, server.players.items.len);
    try testing.expectEqual(contract.max_players - 1, server.players.capacity);
}

fn stop() void {
    open_sessions -= 1;
    if (open_sessions == 0) c.enet_deinitialize();
}

fn messageBody(bytes: []const u8) ?[]const u8 {
    if (bytes.len <= header or bytes.len > header + contract.max_data) return null;

    return if (bytes[0] == kind_message) bytes[header..] else null;
}

/// The game learns that a session ended from the session-ended packet, so a
/// send after that is not a failure.
fn quietAfterEnd(result: SendError!void) SendError!void {
    result catch |err| if (err != error.SessionEnded) return err;
}

/// A peer that is already disconnecting gets nothing; its leaving reaches
/// the game as a player-gone message.
fn post(
    peer: *c.ENetPeer,
    kind: u8,
    id: u32,
    data: []const u8,
    must: bool,
) error{ OutOfMemory, SendFailed }!void {
    if (peer.state != c.ENET_PEER_STATE_CONNECTED) return;

    const packet = c.enet_packet_create(
        null,
        header + data.len,
        if (must) c.ENET_PACKET_FLAG_RELIABLE else 0,
    ) orelse return error.OutOfMemory;

    const bytes = packet.*.data[0 .. header + data.len];

    bytes[0] = kind;
    std.mem.writeInt(u32, bytes[1..5], id, .little);

    @memcpy(bytes[header..], data);
    if (c.enet_peer_send(
        peer,
        if (must) channel_must_arrive else channel_may_be_lost,
        packet,
    ) < 0) {
        c.enet_packet_destroy(packet);
        return error.SendFailed;
    }
}

fn receiveSoon(all: []const *Session, from: *Session, buffer: []u8, sender: *Address) ![]u8 {
    for (0..2000) |_| {
        for (all) |session| session.service(1);
        const length = try from.receive(buffer, sender);
        if (length != 0) return buffer[0..length];
    }

    return error.NothingArrived;
}

fn expectQuiet(all: []const *Session, from: *Session) !void {
    var buffer: [contract.max_data]u8 = undefined;
    var sender: Address = undefined;

    for (0..50) |_| {
        for (all) |session| session.service(1);
        try testing.expectEqual(0, try from.receive(&buffer, &sender));
    }
}

fn joinSoon(server: *Session) !Session {
    var joiner = try Session.beginJoin(
        testing.allocator,
        .{ .host = "127.0.0.1", .port = server.port() },
    );

    errdefer joiner.close();

    for (0..2000) |_| {
        server.service(1);

        switch (joiner.joinStep()) {
            .joined => return joiner,
            .refused => return error.Refused,
            .waiting => {},
        }
    }

    return error.NoAnswer;
}

fn closeSoon(server: *Session, joiner: *Session) void {
    const closer = std.Thread.spawn(.{}, Session.close, .{joiner}) catch return joiner.close();
    var buffer: [contract.max_data]u8 = undefined;
    var sender: Address = undefined;
    const before = server.players.items.len;

    for (0..2000) |_| {
        server.service(1);
        if (server.players.items.len < before) break;
        if (server.inbox.full()) _ = server.receive(&buffer, &sender) catch unreachable;
    }

    closer.join();
}

fn readSoon(all: []const *Session, router: *router_module.Router, queue: u4) ![]u8 {
    for (0..2000) |_| {
        for (all) |session| session.service(1);
        if (try router.read(queue)) |bytes| return bytes;
    }

    return error.NothingArrived;
}

test "ListSessions finds an ENet host on local UDP and keeps its versioned name" {
    var host = try Session.host(testing.allocator, .{ .port = 0, .name = " (1.1) Dry Gulch" });
    defer host.close();
    const pump = try std.Thread.spawn(.{}, struct {
        fn run(session: *Session) void {
            const began = c.enet_time_get();

            while (c.enet_time_get() -% began < 600) {
                var buffer: [contract.max_data]u8 = undefined;
                var from: Address = undefined;
                _ = session.receive(&buffer, &from) catch {};
            }
        }
    }.run, .{&host});

    defer pump.join();
    const found = try listSessions(testing.allocator, host.port(), 300);
    defer testing.allocator.free(found);

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings(" (1.1) Dry Gulch", found[0].sessionName());
    try testing.expect(found[0].hostName().len != 0);
}

test "addresses name players and nothing else" {
    try testing.expectEqual(7, idOf(&addressOf(7)));
    try testing.expectEqual(null, idOf(&message.no_address));
    try testing.expectEqual(null, idOf(&@as(Address, @splat(0))));

    var odd = addressOf(7);
    odd[9] = 1;

    try testing.expectEqual(null, idOf(&odd));
    try testing.expect(!contract.isEveryone(&addressOf(host_id)));
}

test "the waiting list hands messages out oldest first and wraps" {
    const slots = try testing.allocator.alloc(Waiting, 3);
    defer testing.allocator.free(slots);
    var inbox: Inbox = .{ .slots = slots };

    for (0..5) |round| {
        inbox.push(addressOf(1), &.{@intCast(round)});
        inbox.push(addressOf(2), &.{ 9, @intCast(round) });
        try testing.expectEqualSlices(
            u8,
            &.{@intCast(round)},
            inbox.peek().?.data[0..inbox.peek().?.length],
        );

        inbox.drop();
        try testing.expectEqual(addressOf(2), inbox.peek().?.sender);
        inbox.drop();
    }

    try testing.expectEqual(null, inbox.peek());

    for (0..3) |_| inbox.push(addressOf(1), "x");

    try testing.expect(inbox.full());
}

test "messages go through the host to the right players" {
    var server = try Session.host(testing.allocator, .{ .port = 0 });
    defer server.close();
    var first = try joinSoon(&server);
    defer closeSoon(&server, &first);
    var second = try joinSoon(&server);
    defer closeSoon(&server, &second);
    const all = [_]*Session{ &server, &first, &second };
    var buffer: [contract.max_data]u8 = undefined;
    var sender: Address = undefined;

    try testing.expectEqual(addressOf(host_id), server.ownAddress());
    try testing.expectEqual(addressOf(2), first.ownAddress());
    try testing.expectEqual(addressOf(3), second.ownAddress());

    try first.send("Gall", null, contract.must_arrive);
    try testing.expectEqualStrings("Gall", try receiveSoon(&all, &server, &buffer, &sender));
    try testing.expectEqual(first.ownAddress(), sender);
    try testing.expectEqualStrings("Gall", try receiveSoon(&all, &second, &buffer, &sender));
    try testing.expectEqual(first.ownAddress(), sender);
    try expectQuiet(&all, &first);

    try first.send("Gone", &second.ownAddress(), contract.must_arrive);
    try testing.expectEqualStrings("Gone", try receiveSoon(&all, &second, &buffer, &sender));
    try testing.expectEqual(first.ownAddress(), sender);
    try expectQuiet(&all, &server);

    try second.send("Ghost", &server.ownAddress(), 0);
    try testing.expectEqualStrings("Ghost", try receiveSoon(&all, &server, &buffer, &sender));
    try testing.expectEqual(second.ownAddress(), sender);
    try server.send("Gback", &first.ownAddress(), contract.must_arrive);
    try testing.expectEqualStrings("Gback", try receiveSoon(&all, &first, &buffer, &sender));
    try testing.expectEqual(server.ownAddress(), sender);
    try expectQuiet(&all, &second);

    try server.send("Gboth", null, 0);
    try testing.expectEqualStrings("Gboth", try receiveSoon(&all, &first, &buffer, &sender));
    try testing.expectEqualStrings("Gboth", try receiveSoon(&all, &second, &buffer, &sender));
    try testing.expectEqual(server.ownAddress(), sender);

    var large: [contract.max_data + 1]u8 = undefined;

    for (&large, 0..) |*byte, index| byte.* = @truncate(index * 7);

    try first.send(large[0..contract.max_data], &second.ownAddress(), contract.must_arrive);
    try testing.expectEqualSlices(
        u8,
        large[0..contract.max_data],
        try receiveSoon(&all, &second, &buffer, &sender),
    );

    try testing.expectError(error.BadLength, first.send(&large, null, 0));
    try testing.expectError(error.BadLength, first.send("", null, 0));

    try first.send("Gnone", &message.no_address, contract.must_arrive);
    try first.send("Gnone", &addressOf(99), contract.must_arrive);
    try expectQuiet(&all, &server);
    try expectQuiet(&all, &second);
    try testing.expectEqual(0, server.rejected);
}

test "a joiner that leaves arrives as SD on the host and the other joiner" {
    var server = try Session.host(testing.allocator, .{ .port = 0 });
    defer server.close();
    var staying = try joinSoon(&server);
    defer closeSoon(&server, &staying);
    var leaving = try joinSoon(&server);
    const gone = leaving.ownAddress();
    const closer = try std.Thread.spawn(.{}, Session.close, .{&leaving});
    const all = [_]*Session{ &server, &staying };
    var buffer: [contract.max_data]u8 = undefined;
    var sender: Address = undefined;

    try testing.expectEqualStrings(
        contract.player_gone,
        try receiveSoon(&all, &server, &buffer, &sender),
    );

    try testing.expectEqual(gone, sender);
    closer.join();
    try testing.expectEqualStrings(
        contract.player_gone,
        try receiveSoon(&all, &staying, &buffer, &sender),
    );

    try testing.expectEqual(gone, sender);

    var next = try joinSoon(&server);
    defer closeSoon(&server, &next);

    try testing.expectEqual(addressOf(4), next.ownAddress());
}

test "a host that closes arrives as SE once and ends the joiner's session" {
    var server = try Session.host(testing.allocator, .{ .port = 0 });
    var joiner = try joinSoon(&server);
    defer joiner.close();
    const closer = try std.Thread.spawn(.{}, Session.close, .{&server});
    const all = [_]*Session{&joiner};
    var buffer: [contract.max_data]u8 = undefined;
    var sender: Address = undefined;

    try testing.expectEqualStrings(
        contract.session_ended,
        try receiveSoon(&all, &joiner, &buffer, &sender),
    );

    try testing.expectEqual(addressOf(host_id), sender);
    closer.join();
    try testing.expectError(error.SessionEnded, joiner.send("G", null, 0));
    try expectQuiet(&all, &joiner);
}

test "the host turns away strangers and throws away broken packets" {
    var server = try Session.host(testing.allocator, .{ .port = 0 });
    defer server.close();
    var address = std.mem.zeroes(c.ENetAddress);

    try testing.expectEqual(0, c.enet_address_set_host(&address, "127.0.0.1"));
    address.port = server.port();

    var stranger = try Session.create(testing.allocator, null, 1);
    stranger.server = c.enet_host_connect(stranger.enet, &address, channels, protocol + 1).?;

    for (0..2000) |_| {
        server.service(1);
        if (stranger.joinStep() != .waiting) break;
    }

    try testing.expectEqual(.refused, stranger.joinStep());
    stranger.close();
    try testing.expectEqual(0, server.players.items.len);

    var joiner = try joinSoon(&server);
    defer closeSoon(&server, &joiner);
    const peer = joiner.server.?;

    try post(peer, kind_welcome, 1, "", true);
    try post(peer, kind_left, 1, "", true);
    try post(peer, kind_message, 0, "", true);
    try post(peer, 'G', 0, "data", true);

    const short = c.enet_packet_create("M", 1, c.ENET_PACKET_FLAG_RELIABLE).?;
    try testing.expectEqual(0, c.enet_peer_send(peer, channel_must_arrive, short));
    const long = c.enet_packet_create(
        null,
        header + contract.max_data + 1,
        c.ENET_PACKET_FLAG_RELIABLE,
    ).?;

    @memset(long.*.data[0..long.*.dataLength], kind_message);

    try testing.expectEqual(0, c.enet_peer_send(peer, channel_must_arrive, long));
    try joiner.send("Gok", &server.ownAddress(), contract.must_arrive);

    const all = [_]*Session{ &server, &joiner };
    var buffer: [contract.max_data]u8 = undefined;
    var sender: Address = undefined;

    try testing.expectEqualStrings("Gok", try receiveSoon(&all, &server, &buffer, &sender));
    try testing.expectEqual(joiner.ownAddress(), sender);
    try testing.expectEqual(6, server.rejected);
    try expectQuiet(&all, &server);
}

test "the host stops reading while its waiting list is full and loses nothing" {
    var server = try Session.host(testing.allocator, .{ .port = 0 });
    defer server.close();
    var joiner = try joinSoon(&server);
    defer closeSoon(&server, &joiner);
    const all = [_]*Session{ &server, &joiner };
    const total = contract.waiting_messages + 40;

    for (0..total) |index| {
        try joiner.send(
            &.{ 'G', @truncate(index), @truncate(index >> 8) },
            &server.ownAddress(),
            contract.must_arrive,
        );
    }

    for (0..200) |_| {
        server.service(1);
        joiner.service(1);
    }

    try testing.expect(server.inbox.full());

    var buffer: [contract.max_data]u8 = undefined;
    var sender: Address = undefined;

    for (0..total) |index| {
        const got = try receiveSoon(&all, &server, &buffer, &sender);
        try testing.expectEqualSlices(u8, &.{ 'G', @truncate(index), @truncate(index >> 8) }, got);
    }

    try expectQuiet(&all, &server);
}

test "a joiner connects to a host's game through the driver and both send each other messages" {
    const reference = @import("../network/reference_driver.zig");
    const server_module = @import("../network/server.zig");
    const Router = router_module.Router;
    const a = testing.allocator;

    var host_game: reference.Game = .{ .allocator = a };
    defer host_game.deinit();
    var hosting = try Router.init(a);
    defer hosting.deinit();

    hosting.reset();
    hosting.game = host_game.hooks();
    var host_opener: Opener = .{ .allocator = a, .port = 0 };
    hosting.network.provider = host_opener.provider();

    try testing.expect(try hosting.connect(true, "PGame"));
    defer hosting.close();

    const host_session = &host_opener.session.?;

    try testing.expectEqual(1, hosting.own_client);
    try testing.expectEqual(host_session.ownAddress(), hosting.clients[1].address);

    var join_game: reference.Game = .{ .allocator = a };
    defer join_game.deinit();
    var joined = try Router.init(a);
    defer joined.deinit();

    joined.reset();

    joined.game = join_game.hooks();
    join_game.router = &joined;
    joined.player_name[0..7].* = "Joiner\x00".*;

    var join_opener: Opener = .{ .allocator = a, .host = "127.0.0.1", .port = host_session.port() };

    joined.network.provider = join_opener.provider();
    defer if (join_opener.session) |*session| {
        closeSoon(host_session, session);
        join_opener.session = null;
        joined.network.session = null;
        joined.session_open = false;
    };

    {
        var answering: Answering = .{ .session = host_session };
        const thread = try std.Thread.spawn(.{}, Answering.run, .{&answering});
        defer {
            answering.stop.store(true, .release);
            thread.join();
        }

        try testing.expect(try joined.connect(false, "P(1.1) Game"));
    }

    const join_session = &join_opener.session.?;
    try testing.expectEqual(0xffffffff, joined.own_client);

    var server: server_module.Server = .{};
    var user_messages_buffer: server_module.UserMessageBuffer = undefined;
    var user_messages = server_module.UserMessages.init(&user_messages_buffer);
    const end = for (0..2000) |_| {
        host_session.service(1);
        join_session.service(1);
        try server_module.processRequests(
            &server,
            &hosting,
            .{
                .now = 0,
                .game_type = 1,
                .level_loaded = true,
                .allocator = a,
                .user_messages = &user_messages,
            },
        );

        if (try joined.stepJoin(false)) |end| break end;
    } else return error.NothingArrived;

    try testing.expect(end == .joined);
    try testing.expectEqual(3, joined.own_client);
    try testing.expectEqual(2, joined.client_count);
    try testing.expectEqual(host_session.ownAddress(), joined.clients[1].address);
    try testing.expectEqualStrings("Player", joined.clients[1].playerName());
    try testing.expectEqual(join_session.ownAddress(), joined.clients[3].address);
    try testing.expectEqual(2, hosting.client_count);
    try testing.expectEqual(join_session.ownAddress(), hosting.clients[3].address);
    try testing.expectEqualStrings("Joiner", hosting.clients[3].playerName());
    try testing.expectEqual(0, hosting.rejected);
    try testing.expectEqual(0, joined.rejected);

    const all = [_]*Session{ host_session, join_session };

    var request = message.request(0x3ef, 3);

    try testing.expectEqual(
        .sent,
        try joined.post(message.addressWord(message.Queue.server, 1), 0x800003ef, &request),
    );

    const asked = try readSoon(&all, &hosting, message.Queue.server);

    try testing.expectEqualSlices(u8, &request, asked);
    try testing.expectEqual(3, message.client(message.get(asked, message.sender_offset)));
    hosting.release(asked);

    var ended = message.request(0x404, 1);
    try testing.expectEqual(
        .sent,
        try hosting.post(message.addressWord(message.Queue.database, 0), 0x80000404, &ended),
    );

    const told = try readSoon(&all, &joined, message.Queue.database);

    try testing.expectEqualSlices(u8, &ended, told);
    joined.release(told);
    try testing.expectEqual(null, try hosting.read(message.Queue.database));

    var false_word = message.request(0x404, 1);

    message.set(
        &false_word,
        message.destination_offset,
        message.addressWord(message.Queue.database, 1),
    );

    try joined.sendDirect(&false_word, &joined.clients[1].address, 1);

    for (0..2000) |_| {
        for (all) |session| session.service(1);
        try testing.expectEqual(null, try hosting.read(message.Queue.database));
        if (hosting.rejected != 0) break;
    }

    try testing.expectEqual(1, hosting.rejected);

    {
        var answering: Answering = .{ .session = host_session };
        const thread = try std.Thread.spawn(.{}, Answering.run, .{&answering});
        defer {
            answering.stop.store(true, .release);
            thread.join();
        }

        joined.close();
    }

    try testing.expectEqual(null, join_opener.session);
    host_game.clear();

    for (0..2000) |_| {
        host_session.service(1);
        try testing.expectEqual(null, try hosting.read(message.Queue.server));
        if (hosting.client_count == 1) break;
    }

    try testing.expectEqual(1, hosting.client_count);
    try testing.expect(message.isNone(&hosting.clients[3].address));
    try testing.expectEqualStrings("Joiner", hosting.clients[3].playerName());
    try testing.expectEqual(3, host_game.calls.items.len);
    try testing.expectEqualStrings("describe", host_game.calls.items[0]);
    try testing.expectEqualStrings("remove 3", host_game.calls.items[1]);
    try testing.expectEqualStrings("players", host_game.calls.items[2]);
}

test "a joiner's router is told to leave when the host closes" {
    const Router = router_module.Router;
    var server = try Session.host(testing.allocator, .{ .port = 0 });
    var joiner = try joinSoon(&server);
    defer joiner.close();
    var joined = try Router.init(testing.allocator);
    defer joined.deinit();

    joined.reset();

    joined.own_client = 3;
    joined.own_address = joiner.ownAddress();
    joined.clients[1].address = server.ownAddress();
    joined.network.session = joiner.driver();
    joined.session_open = true;

    var waiting = message.request(0x3ef, 3);
    try testing.expectEqual(
        .queued,
        try joined.post(message.addressWord(message.Queue.server, 3), 0x3ef, &waiting),
    );

    const closer = try std.Thread.spawn(.{}, Session.close, .{&server});

    for (0..2000) |_| {
        joiner.service(1);
        try testing.expectEqual(null, try joined.read(message.Queue.database));
        if (joined.leave_game) break;
    }

    closer.join();
    try testing.expectEqual(.network, joined.lost);
    try testing.expect(joined.dropped);
    try testing.expectEqual(null, try joined.read(message.Queue.server));
    try testing.expectEqual(
        .sent,
        try joined.post(message.addressWord(message.Queue.server, 1), 0x3ef, &waiting),
    );

    try testing.expectError(error.SessionEnded, joiner.send("G", null, 0));
}
