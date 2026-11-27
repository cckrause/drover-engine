//! The object database: which object a message is about, and the tables
//! that map object numbers to things in the level.
//!
//! The request queue is drained at the end of every main loop pass, after
//! the frame step. Script and actor messages still travel through the
//! script engine's own list; this layer handles the object-numbered ones.
//! Ranked lists are sorted with util/qsort.zig because ties must come out in
//! one defined order.

const std = @import("std");
const message = @import("message.zig");
const router_module = @import("router.zig");
const Router = router_module.Router;
const messages_module = @import("../assets/messages.zig");
const qsort = @import("../util/qsort.zig");

pub const Table = [0x800]Entry;

pub const comment_text_limit = 0x180;

pub const Request = union(enum) {
    end_level,
    game_info: message.GameRecord,
    start_here: message.Start,
    link: Link,
    bits: Link,
    actor: struct { index: usize, bytes: []u8 },
    generator: struct { index: usize, code: u32 },
    frag_update: []const u8,
    frag_delta: message.FragDelta,
    corpse: message.Corpse,
    shatter_wall: message.WallIndex,
    comment: []const u8,
    configuration: u32,
    critical: []const u8,
    object_request: struct { sender: u32 },
    actor_create: message.ActorCreate,
};

pub const Link = struct {
    object: Object,
    code: u32,
    words: [3]u32,
    sender: ?usize,
};

pub const Object = union(enum) {
    wall: struct { sector: usize, wall: usize },
    sector: usize,
    actor: usize,
    generator: usize,
    leaked,
};

pub const Entry = struct {
    object: ?Object = null,
    freed: u32 = 0,
};

pub const Party = struct { object: Object, number: u32 };

pub const Repeat = struct { target: ?Object, sender: ?Object, words: [4]u32, time: u32 };

pub const Database = struct {
    allocator: std.mem.Allocator,
    record: message.GameRecord = .{},
    tables: [router_module.client_slots]?*Table = @splat(null),
    last: [router_module.client_slots]u32 = @splat(0),
    requests: [40]struct { due: u32 = 0, number: u32 = 0 } = @splat(.{}),
    repeating: u32 = 0,
    repeat_previous: ?u32 = null,
    held: ?struct { bytes: []u8, repeat: ?u32 } = null,
    repeats: ?std.ArrayList(Repeat) = null,
    player_order: [router_module.client_slots]u8 = @splat(0),
    player_count: usize = 0,
    board: [50]BoardEntry = @splat(.{}),
    critical: [12]u32 = @splat(0),
    game_over: bool = false,
    score_clock: i32 = 0,
    start_clock: u32 = 0,
    holder_clock: u32 = 0,
    object_list_resume: u32 = 0xffffffff,

    pub const ScoreContext = struct {
        now: u32,
        game_type: u32,
        mode: u32,
        game_state: u32,
        holder: u32,
        kill_limit: i32,
        minute_limit: i32,
        first_start: u32,
    };

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Database) void {
        self.stopLinks();
        for (self.tables) |table| if (table) |owned| self.allocator.destroy(owned);
        self.* = undefined;
    }

    pub fn reset(self: *Database, router: *Router) !void {
        for (&self.tables) |*table| if (table.*) |owned| {
            self.allocator.destroy(owned);
            table.* = null;
        };
        try self.newTable(1);
        try self.newTable(2);
        @memset(router.scores[0..0xff], .{});
        router.team_points = @splat(0);
        self.requests = @splat(.{});
        self.board = @splat(.{});
        self.critical = @splat(0);
        self.player_count = 0;
        self.player_order = @splat(0);
        self.game_over = false;
        self.score_clock = 0;
        self.start_clock = 0;
        self.holder_clock = 0;
        self.object_list_resume = 0xffffffff;
    }

    pub fn close(self: *Database) void {
        for (&self.tables) |*table| if (table.*) |owned| {
            self.allocator.destroy(owned);
            table.* = null;
        };
    }

    pub fn addClient(self: *Database, client: u8) !void {
        if (self.tables[client] != null) {
            std.log.debug("Dbm_AddClient: Client {d} already exists.", .{client});
            return;
        }
        try self.newTable(client);
    }

    pub fn removeClient(self: *Database, client: u8) !void {
        const table = self.tables[client] orelse {
            std.log.debug("Dbm_AddClient: Client {d} doesn't exist.", .{client});
            return;
        };
        for (table) |entry| if (entry.object != null) return error.DatabaseClientObjectsNotPorted;
        self.allocator.destroy(table);
        self.tables[client] = null;
    }

    pub fn startLinks(self: *Database) void {
        if (self.repeats == null) self.repeats = .empty;
    }

    pub fn stopLinks(self: *Database) void {
        if (self.repeats) |*list| list.deinit(self.allocator);
        self.repeats = null;
    }

    pub fn post(self: *Database, router: *Router, target: ?Party, sender: ?Party, words: [4]u32, now: u32) !void {
        var repeat = self.repeating;
        if (self.repeating == 0) if (self.repeats) |*list| {
            var index: usize = 0;
            var found: ?usize = null;
            while (index < list.items.len) {
                const entry = list.items[index];
                if (entry.time +% 0xfa < now) {
                    _ = list.orderedRemove(index);
                    index = 1;
                    continue;
                }
                if (same(entry.target, target) and same(entry.sender, sender) and std.mem.eql(u32, &entry.words, &words)) {
                    found = index;
                    repeat = 1;
                    break;
                }
                index += 1;
            }
            const seen = found orelse blk: {
                try list.append(self.allocator, .{ .target = if (target) |party| party.object else null, .sender = if (sender) |party| party.object else null, .words = words, .time = now });
                break :blk list.items.len - 1;
            };
            list.items[seen].time = now;
        };
        const to = target orelse return;
        if (to.number == 0) return;
        var bytes = message.words(words[0], router.own_client, .{ words[1], words[2], words[3] });
        message.set(&bytes, message.sender_offset, message.addressWord(message.Queue.database, @truncate(router.own_client)));
        message.set(&bytes, message.reply_offset, to.number);
        if (sender) |from| if (from.number != 0) message.set(&bytes, message.sender_offset, from.number);
        if (repeat == 0)
            try router.postHereAndEveryone(to.number, words[0] | 0x80000000, &bytes)
        else
            _ = try router.post(to.number, words[0] | 0x80008000, &bytes);
    }

    pub fn give(self: *Database, own_client: u32, object: Object) !u32 {
        const client: u8 = @truncate(own_client);
        const index = try self.newNumber(client);
        const number = @as(u32, client) << 11 | index;
        self.tables[client].?[index].object = object;
        return number;
    }

    pub fn set(self: *Database, number: u32, object: ?Object, now: u32) void {
        const found = self.slot(number) orelse return std.log.debug("Dbm_SetObjectPtr: ClientID {d} doesn't have a valid nid list.", .{message.client(number)});
        found.object = object;
        if (object == null) found.freed = now;
    }

    pub fn free(self: *Database, number: u32, now: u32) void {
        self.set(number, null, now);
    }

    pub fn find(self: *Database, number: u32) ?Object {
        const found = self.slot(number) orelse {
            std.log.debug("Dbm_GetObjectPtr: ClientID {d} doesn't have a valid nid list.", .{message.client(number)});
            return null;
        };
        return found.object;
    }

    pub fn next(self: *Database, router: *Router, level_loaded: bool, now: u32) !?Request {
        self.finish(router);
        while (try router.read(message.Queue.database)) |bytes| {
            const target = message.get(bytes, message.reply_offset);
            if (target != 0 and target & 0x7ff != 0) {
                errdefer {
                    self.endRepeat();
                    router.release(bytes);
                }
                if (try self.objectMessage(router, bytes, level_loaded, now)) |request| return request;
                router.release(bytes);
                continue;
            }
            switch (message.get(bytes, message.number_offset)) {
                0x409 => return self.hold(bytes, .{ .frag_update = bytes }),
                0x40a => {
                    const text = message.readComment(bytes) catch |err| {
                        router.release(bytes);
                        return err;
                    };
                    return self.hold(bytes, .{ .comment = text });
                },
                0x423 => return self.hold(bytes, .{ .critical = bytes }),
                0x402 => if (level_loaded) return self.hold(bytes, .{ .object_request = .{ .sender = message.get(bytes, message.sender_offset) } }),
                0x3fd => if (level_loaded) {
                    const value = message.readActorCreate(bytes) catch |err| {
                        router.release(bytes);
                        return err;
                    };
                    if (value.flags & 0x8000 == 0) return self.hold(bytes, .{ .actor_create = value });
                },
                0x413 => if (level_loaded) {
                    const value = message.readCorpse(bytes) catch |err| {
                        router.release(bytes);
                        return err;
                    };
                    return self.hold(bytes, .{ .corpse = value });
                },
                else => {},
            }
            defer router.release(bytes);
            switch (message.get(bytes, message.number_offset)) {
                0x41f => return .{ .configuration = try message.readConfiguration(bytes) },
                0x404 => {
                    if (bytes.len <= message.header_size) return error.MalformedNetworkMessage;
                    if (bytes[message.header_size] != 0) return error.EndLevelTextNotPorted;
                    return .end_level;
                },
                0x406 => {
                    try message.readGameInfo(bytes, &self.record);
                    return .{ .game_info = self.record };
                },
                0x408 => return .{ .frag_delta = try message.readFragDelta(bytes) },
                0x422 => {
                    if (!level_loaded) continue;
                    return .{ .shatter_wall = try message.readShatterWall(bytes) };
                },
                0x402, 0x3fd, 0x413 => continue,
                0x407 => {
                    if (!level_loaded) continue;
                    const start = try message.readStart(bytes);
                    if (start[0] == 0 and start[1] & 0x7fffffff == 0 and start[2] & 0x7fffffff == 0 and start[3] & 0x7fffffff == 0)
                        return error.InvalidStartPositionNotPorted;
                    return .{ .start_here = start };
                },
                0x400, 0x401, 0x405, 0x40b, 0x40d, 0x40e, 0x414, 0x41c, 0x41d, 0x41e, 0x420, 0x421 => return error.DatabaseMessageNotPorted,
                else => |code| {
                    var name: [16]u8 = undefined;
                    std.log.debug("Dbm_ProcessRequests: Unhandled message {s}", .{message.name(code, &name)});
                },
            }
        }
        return null;
    }

    pub fn finish(self: *Database, router: *Router) void {
        const held = self.held orelse return;
        router.release(held.bytes);
        if (held.repeat) |previous| self.repeating = previous;
        self.held = null;
    }

    pub fn swapRepeat(self: *Database, value: u32) u32 {
        const previous = self.repeating;
        self.repeating = value;
        return previous;
    }

    pub fn rebuildPlayers(self: *Database, router: *Router, mode: u32, game_type: u32, now: u32) !void {
        self.player_count = 0;
        if (game_type == 4) try self.countHolderOnce(router, mode, now);
        try self.listPlayers(router, mode);
    }

    pub fn countHolder(self: *Database, router: *Router, mode: u32, game_type: u32, now: u32, rebuild: bool) !void {
        if (router.playerCount() < 2) return;
        const elapsed = now -% self.holder_clock;
        if (elapsed <= 1000) return;
        var holder: u32 = 0;
        var mark: u32 = 0;
        if (mode == 3) {
            mark = 0x80000;
            holder = self.critical[0];
        } else if (mode == 2) {
            mark = 0x100000;
            holder = self.critical[11];
        }
        if (holder == 0 and mark != 0) return error.HolderActorSearchNotPorted;
        const seconds = elapsed / 1000;
        self.holder_clock +%= seconds * 1000;
        if (holder != 0) {
            if (holder >= router_module.client_slots) return error.InvalidNetworkClientNumber;
            router.scores[holder].seconds +%= @bitCast(@as(u16, @truncate(seconds)));
        }
        if (!rebuild) return;
        self.player_count = 0;
        if (game_type == 4) try self.countHolderOnce(router, mode, now);
        try self.listPlayers(router, mode);
    }

    pub fn sendScores(self: *Database, router: *Router, context: ScoreContext) !void {
        if (router.own_client != 1 or context.game_type != 5) return;
        const seconds: i32 = @intCast(context.now / 1000);
        if (context.holder == 0 or self.score_clock == 0 or router.playerCount() < 2) self.score_clock = seconds;
        if (context.holder != 0) {
            if (context.holder >= router_module.client_slots) return error.InvalidNetworkClientNumber;
            const score = &router.scores[context.holder];
            score.seconds = @truncate(@as(i32, score.seconds) + (@as(i32, @as(i16, @truncate(seconds))) - @as(i16, @truncate(self.score_clock))));
            self.score_clock = seconds;
        }
        var buffer: [message.frag_update_capacity]u8 = undefined;
        const bytes = message.fragUpdate(&buffer, router.own_client, router.team_points[1..3], router.scores[0 .. router.lastClient() + 1]);
        message.set(bytes, message.sender_offset, (router.own_client & 0xff) << 11);
        message.set(bytes, message.reply_offset, 0);
        _ = try router.post(0, 0x409 | 0x40000000, bytes);
        var over = false;
        if (context.kill_limit != 0 and !self.game_over) {
            const team_modes = [_]u32{ 0, 1, 2, 2, 1, 1, 0 };
            if (context.mode >= team_modes.len) return error.InvalidMultiplayerMode;
            if (team_modes[context.mode] & 1 == 0) {
                for (self.player_order[0..self.player_count]) |number| {
                    if (number != 0 and context.kill_limit <= router.scores[number].points) over = true;
                }
            } else if (context.kill_limit <= router.team_points[1] or context.kill_limit <= router.team_points[2]) over = true;
        }
        if (context.minute_limit != 0 and !self.game_over and context.first_start != 0 and
            @as(u32, @bitCast(context.minute_limit *% 60000)) +% context.first_start < context.now) over = true;
        if (over) {
            var end: [message.end_level_capacity]u8 = undefined;
            const ended = message.endLevel(&end, router.own_client, "~5126");
            try router.postHereAndEveryone(0, 0x404 | 0x40000000, ended);
            self.game_over = true;
        }
        self.updateBoard(router, context.game_state, context.game_type);
    }

    pub fn updateBoard(self: *Database, router: *const Router, game_state: u32, game_type: u32) void {
        if (game_state != 1) return;
        for (&router.clients, 0..) |*client, number| {
            if (message.isNone(&client.address) or client.name[0] == 0) continue;
            const player = client.player orelse continue;
            const name = client.playerName();
            var index: usize = 0;
            while (index < self.board.len and self.board[index].used) : (index += 1) {
                if (std.mem.eql(u8, self.board[index].nameText(), name)) break;
            }
            if (index == self.board.len) continue;
            const entry = &self.board[index];
            if (!entry.used) {
                entry.* = .{ .used = true };
                @memcpy(entry.name[0..name.len], name);
            }
            entry.code = if (game_type == 5 or game_type == 4) player.code else 'J';
            entry.team = player.flags & 0xf;
            entry.points = router.scores[number].points;
            entry.seconds = router.scores[number].seconds;
        }
    }

    pub fn applyFragUpdate(self: *Database, router: *Router, bytes: []const u8, context: LevelContext) !void {
        if (bytes.len < 0x14) return error.MalformedNetworkMessage;
        const teams = std.mem.readInt(u16, bytes[0x10..0x12], .little);
        const clients = std.mem.readInt(u16, bytes[0x12..0x14], .little);
        if (teams > 2 or clients > router_module.client_slots or bytes.len < 0x14 + 2 * @as(usize, teams) + 4 * @as(usize, clients))
            return error.MalformedNetworkMessage;
        for (0..teams) |index| router.team_points[1 + index] = std.mem.readInt(i16, bytes[0x14 + 2 * index ..][0..2], .little);
        const scores = 0x14 + 2 * @as(usize, teams);
        for (0..clients) |index| router.scores[index] = .{
            .points = std.mem.readInt(i16, bytes[scores + 4 * index ..][0..2], .little),
            .seconds = std.mem.readInt(i16, bytes[scores + 4 * index + 2 ..][0..2], .little),
        };
        self.player_count = 0;
        if (context.game_type == 4) try self.countHolderOnce(router, context.mode, context.now);
        try self.listPlayers(router, context.mode);
        self.holder_clock = context.now;
        self.updateBoard(router, context.game_state, context.game_type);
    }

    pub fn applyFragDelta(self: *Database, router: *Router, value: message.FragDelta, context: LevelContext) !void {
        if (value.client >= router_module.client_slots) return error.MalformedNetworkMessage;
        const points: i16 = @bitCast(@as(u16, @truncate(value.points)));
        const score = &router.scores[value.client];
        score.points +%= points;
        if (value.team != 0xffffffff and context.mode != 1) {
            if (value.team >= router.team_points.len) return error.MalformedNetworkMessage;
            router.team_points[value.team] +%= points;
        }
        try self.rebuildPlayers(router, context.mode, context.game_type, context.now);
    }

    pub fn sendObjectList(self: *Database, router: *Router) !void {
        var entries: [200]u16 = undefined;
        var count: usize = 0;
        var index: u32 = self.object_list_resume;
        if (index == 0xffffffff) {
            index = 0;
            entries[0] = 0xffff;
            count = 1;
        }
        const own: u8 = @truncate(router.own_client);
        var full = false;
        while (true) {
            if (count == entries.len) {
                full = true;
                break;
            }
            const object: ?Object = if (self.tables[own]) |table| table[index].object else blk: {
                std.log.debug("Dbm_GetObjectPtr: ClientID {d} doesn't have a valid nid list.", .{own});
                break :blk null;
            };
            if (object) |found| if (found == .actor) {
                entries[count] = @truncate(index);
                count += 1;
                self.object_list_resume = index;
            };
            index += 1;
            if (index == 0x800) break;
        }
        if (!full) {
            if (count == entries.len) return error.ObjectListOverflow;
            self.object_list_resume = 0xffffffff;
            entries[count] = 0xffff;
            count += 1;
        }
        if (count < 2) return;
        var buffer: [message.object_list_capacity]u8 = undefined;
        const bytes = message.objectList(&buffer, router.own_client, entries[0..count]);
        message.set(bytes, message.sender_offset, (router.own_client & 0xff) << 11);
        message.set(bytes, message.reply_offset, message.addressWord(message.Queue.server, own));
        _ = try router.post(0x100000, 0x414 | 0x40000000, bytes);
    }

    pub fn requestObject(self: *Database, router: *Router, sender: u32, number: u32, level_loaded: bool, now: u32) !void {
        if (number & 0x7ff == 0 or !level_loaded) return;
        if (self.throttled(number, now)) return;
        var request = message.objectRequest(0x402, router.own_client);
        message.set(&request, message.reply_offset, number);
        if (message.client(sender) != router.own_client) _ = try router.post(sender & 0x7f800, 0x402, &request);
    }

    pub fn drained(self: *Database, router: *Router, context: LevelContext, holder: u32) !void {
        if (context.game_type == 4) return self.countHolder(router, context.mode, context.game_type, context.now, true);
        if (context.game_type != 5) return;
        const seconds: i32 = @intCast(context.now / 1000);
        if (holder == 0 or self.score_clock == 0 or router.playerCount() < 2) self.score_clock = seconds;
        if (holder != 0) {
            if (holder >= router_module.client_slots) return error.InvalidNetworkClientNumber;
            const score = &router.scores[holder];
            score.seconds = @truncate(@as(i32, score.seconds) + (@as(i32, @as(i16, @truncate(seconds))) - @as(i16, @truncate(self.score_clock))));
            self.score_clock = seconds;
        }
    }

    fn same(listed: ?Object, party: ?Party) bool {
        const object = listed orelse return party == null;
        return if (party) |value| std.meta.eql(object, value.object) else false;
    }

    fn newTable(self: *Database, client: u8) !void {
        if (self.tables[client] == null)
            self.tables[client] = try self.allocator.create(Table)
        else
            std.log.debug("dbm_NewClientNIDList: Reallocating client {d}'s nid list.", .{client});
        self.tables[client].?.* = @splat(.{});
        self.last[client] = 0;
    }

    fn newNumber(self: *Database, client: u8) !u32 {
        var found: ?u32 = null;
        if (self.tables[client]) |table| {
            var oldest: u32 = 0x7fffffff;
            var index = self.last[client];
            for (1..0x7ff) |_| {
                index += 1;
                if (index > 0x7fe) index = 1;
                const entry = table[index];
                if (entry.object != null) continue;
                if (entry.freed < oldest) {
                    oldest = entry.freed;
                    found = index;
                }
                if (entry.freed == 0) break;
            }
        } else std.log.debug("Dbm_NewObjectID: Client ID {d} is not a valid client.", .{client});
        const index = found orelse return error.ObjectNumbersExhausted;
        self.last[client] = index;
        return index;
    }

    fn slot(self: *Database, number: u32) ?*Entry {
        const table = self.tables[message.client(number)] orelse return null;
        return &table[number & 0x7ff];
    }

    fn objectMessage(self: *Database, router: *Router, bytes: []u8, level_loaded: bool, now: u32) !?Request {
        const target = message.get(bytes, message.reply_offset);
        const number = message.get(bytes, message.number_offset);
        const object = self.find(target) orelse {
            if (number != 0x402 and number != 0x411 and level_loaded and !self.throttled(target, now)) {
                const sender = message.get(bytes, message.sender_offset);
                if (router.own_client != message.client(sender)) {
                    var request = message.request(0x402, router.own_client);
                    message.set(&request, message.sender_offset, message.addressWord(message.Queue.database, @truncate(router.own_client)));
                    message.set(&request, message.reply_offset, target);
                    _ = try router.post(sender, 0x402, &request);
                }
            }
            return null;
        };
        switch (object) {
            .wall, .sector => {
                const code = self.strip(bytes);
                const sender = self.senderActor(bytes);
                switch (code) {
                    0x7d4...0x7de, 0x7e1, 0x7e2, 0x7e7...0x7ea => return self.hold(bytes, .{ .link = try link(object, code, bytes, sender) }),
                    0x7df, 0x7e0 => return self.hold(bytes, .{ .bits = try link(object, code, bytes, sender) }),
                    0x402 => return error.ObjectRequestNotPorted,
                    else => {
                        var name: [16]u8 = undefined;
                        std.log.debug("dbm_ProcessGeoRequest: Unhandled message {s}", .{message.name(code, &name)});
                        self.endRepeat();
                        return null;
                    },
                }
            },
            .actor => |index| return self.hold(bytes, .{ .actor = .{ .index = index, .bytes = bytes } }),
            .leaked => return error.MessageToFreedObject,
            .generator => |index| {
                const code = self.strip(bytes);
                const sender = message.get(bytes, message.sender_offset);
                if (self.tables[message.client(sender)] == null) std.log.debug("Dbm_GetObjectPtr: ClientID {d} doesn't have a valid nid list.", .{message.client(sender)});
                switch (code) {
                    0x7d4...0x7de, 0x7e1, 0x7e2 => {
                        if (bytes.len < message.words_size) return error.MalformedNetworkMessage;
                        return self.hold(bytes, .{ .generator = .{ .index = index, .code = code } });
                    },
                    else => {
                        var name: [16]u8 = undefined;
                        std.log.debug("dbm_ProcessGeneratorRequest: Unhandled message {s}", .{message.name(code, &name)});
                        self.endRepeat();
                        return null;
                    },
                }
            },
        }
    }

    fn strip(self: *Database, bytes: []u8) u32 {
        const number = message.get(bytes, message.number_offset);
        message.set(bytes, message.number_offset, number & 0xffff7fff);
        self.repeat_previous = if (number & 0x8000 != 0) self.swapRepeat(1) else null;
        return number & 0xffff7fff;
    }

    fn endRepeat(self: *Database) void {
        if (self.repeat_previous) |previous| self.repeating = previous;
        self.repeat_previous = null;
    }

    fn senderActor(self: *Database, bytes: []const u8) ?usize {
        const sender = message.get(bytes, message.sender_offset);
        const object = self.find(sender) orelse return null;
        return switch (object) {
            .actor => |index| index,
            else => null,
        };
    }

    fn link(object: Object, code: u32, bytes: []const u8, sender: ?usize) !Link {
        if (bytes.len < message.words_size) return error.MalformedNetworkMessage;
        return .{ .object = object, .code = code, .words = .{ message.get(bytes, 0x10), message.get(bytes, 0x14), message.get(bytes, 0x18) }, .sender = sender };
    }

    fn hold(self: *Database, bytes: []u8, request: Request) Request {
        self.held = .{ .bytes = bytes, .repeat = self.repeat_previous };
        self.repeat_previous = null;
        return request;
    }

    fn throttled(self: *Database, number: u32, now: u32) bool {
        var open: ?usize = null;
        for (&self.requests, 0..) |*entry, index| {
            if (entry.number == number) {
                if (now < entry.due) return true;
                entry.due = now +% 2000;
                return false;
            }
            if (open == null and entry.due <= now) open = index;
        }
        if (open) |index| self.requests[index] = .{ .due = now +% 2000, .number = number };
        return false;
    }

    fn listPlayers(self: *Database, router: *Router, mode: u32) !void {
        self.player_count = 0;
        for (&router.clients, 0..) |*client, number| {
            if (message.isNone(&client.address) or client.name[0] == 0 or client.player == null) continue;
            self.player_order[self.player_count] = @intCast(number);
            self.player_count += 1;
        }
        if (self.player_count == 0) return;
        const order = self.player_order[0..self.player_count];
        switch (mode) {
            3 => qsort.sort(u8, order, router, byTagTime),
            2 => qsort.sort(u8, order, router, byChickenTime),
            else => qsort.sort(u8, order, router, byPoints),
        }
    }

    fn byPoints(router: *Router, a: *const u8, b: *const u8) i32 {
        const points = @as(i32, router.scores[b.*].points) - router.scores[a.*].points;
        if (points != 0) return points;
        return nameOrder(router, a.*, b.*);
    }

    fn byTagTime(router: *Router, a: *const u8, b: *const u8) i32 {
        var order = @as(i32, router.scores[b.*].seconds) - router.scores[a.*].seconds;
        if (order == 0) order = @as(i32, router.scores[b.*].points) - router.scores[a.*].points;
        if (order != 0) return order;
        return nameOrder(router, a.*, b.*);
    }

    fn byChickenTime(router: *Router, a: *const u8, b: *const u8) i32 {
        var order = @as(i32, router.scores[a.*].seconds) - router.scores[b.*].seconds;
        if (order == 0) order = @as(i32, router.scores[b.*].points) - router.scores[a.*].points;
        if (order != 0) return order;
        return nameOrder(router, a.*, b.*);
    }

    fn nameOrder(router: *Router, a: u8, b: u8) i32 {
        return switch (std.mem.order(u8, router.clients[a].playerName(), router.clients[b].playerName())) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    fn countHolderOnce(self: *Database, router: *Router, mode: u32, now: u32) error{ HolderActorSearchNotPorted, InvalidNetworkClientNumber }!void {
        if (router.playerCount() < 2) return;
        const elapsed = now -% self.holder_clock;
        if (elapsed <= 1000) return;
        const holder: u32 = if (mode == 3) self.critical[0] else if (mode == 2) self.critical[11] else 0;
        if (holder == 0 and (mode == 2 or mode == 3)) return error.HolderActorSearchNotPorted;
        const seconds = elapsed / 1000;
        self.holder_clock +%= seconds * 1000;
        if (holder != 0) {
            if (holder >= router_module.client_slots) return error.InvalidNetworkClientNumber;
            router.scores[holder].seconds +%= @bitCast(@as(u16, @truncate(seconds)));
        }
    }
};

pub const LevelContext = struct {
    now: u32,
    game_type: u32,
    mode: u32,
    game_state: u32,
};

pub const BoardEntry = struct {
    used: bool = false,
    name: [100]u8 = @splat(0),
    code: u8 = 0,
    team: u32 = 0,
    points: i32 = 0,
    seconds: i32 = 0,

    pub fn nameText(self: *const BoardEntry) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

pub fn requestServerCreate(router: *Router, value: message.HaveServerCreate) !void {
    if (value.name.len > std.math.maxInt(usize) - 0x23) return error.MalformedNetworkMessage;
    const buffer = try router.allocator.alloc(u8, value.name.len + 0x23);
    defer router.allocator.free(buffer);
    const bytes = try message.haveServerCreate(buffer, router.own_client, value);
    _ = try router.post(0x100800, 0x415 | 0xc0000000, bytes);
}

pub fn comment(router: *Router, text: []const u8, destination: u32) !void {
    if (text.len < 4) return error.CommentTooShort;
    if (std.ascii.eqlIgnoreCase(text[text.len - 4 ..], ".wav")) return error.ChatSoundNotPorted;
    var buffer: [message.comment_capacity]u8 = undefined;
    const bytes = try message.comment(&buffer, router.own_client, text);
    message.set(bytes, message.sender_offset, (router.own_client & 0xff) << 11);
    message.set(bytes, message.reply_offset, destination);
    _ = try router.post(destination, 0x40a | 0xc0000000, bytes);
}

pub fn sendConfiguration(router: *Router, bits: u32) !void {
    var bytes = message.configuration(router.own_client, bits);
    message.set(&bytes, message.sender_offset, (router.own_client & 0xff) << 11);
    message.set(&bytes, message.reply_offset, 0);
    _ = try router.post(0, 0x41f | 0x40000000, &bytes);
}

pub fn commentText(messages: []const u8, raw: []const u8, out: *[comment_text_limit]u8) ![]const u8 {
    if (raw.len >= comment_text_limit) return error.MalformedNetworkMessage;
    if (raw.len >= 2 and raw[0] == '$' and raw[1] == '$') {
        var template_buffer: [100]u8 = undefined;
        const template = try copyText(messages, atoi(raw[2..]), &template_buffer);
        var arguments: [5][80]u8 = undefined;
        for (&arguments) |*argument| argument[0] = 0;
        var i: usize = 2;
        while (i < raw.len and !(raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '$')) : (i += 1) {}
        if (i < raw.len and i + 2 < raw.len) {
            var argument: usize = 0;
            while (true) {
                i += 2;
                var length: usize = 0;
                while (i < raw.len and !(raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '$')) : (i += 1) {
                    if (length + 1 >= arguments[argument].len) return error.MalformedNetworkMessage;
                    arguments[argument][length] = raw[i];
                    length += 1;
                }
                arguments[argument][length] = 0;
                argument += 1;
                if (i >= raw.len or argument == arguments.len) break;
            }
        }
        return printTemplate(template, &arguments, out);
    }
    if (raw.len >= 1 and raw[0] == '~') {
        const id = atoi(raw[1..]);
        if (id != 0) {
            const found = messages_module.lookup(messages, id) catch |err| switch (err) {
                error.MessageNotFound => {
                    @memcpy(out[0..raw.len], raw);
                    return out[0..raw.len];
                },
                else => return err,
            };
            if (found.len >= 0x50) return error.CommentTextTooLong;
            @memcpy(out[0..found.len], found);
            return out[0..found.len];
        }
    }
    @memcpy(out[0..raw.len], raw);
    return out[0..raw.len];
}

fn copyText(messages: []const u8, id: u32, buffer: []u8) ![]const u8 {
    const found = messages_module.lookup(messages, id) catch |err| switch (err) {
        error.MessageNotFound => return error.CommentTemplateNotFound,
        else => return err,
    };
    if (found.len >= buffer.len) return error.CommentTextTooLong;
    @memcpy(buffer[0..found.len], found);
    return buffer[0..found.len];
}

fn printTemplate(template: []const u8, arguments: *const [5][80]u8, out: *[comment_text_limit]u8) ![]const u8 {
    var length: usize = 0;
    var next: usize = 0;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        var piece: []const u8 = template[i .. i + 1];
        if (template[i] == '%') {
            if (i + 1 >= template.len) return error.UnsupportedCommentTemplate;
            i += 1;
            switch (template[i]) {
                '%' => piece = "%",
                's' => {
                    if (next == arguments.len) return error.UnsupportedCommentTemplate;
                    piece = std.mem.sliceTo(&arguments[next], 0);
                    next += 1;
                },
                else => return error.UnsupportedCommentTemplate,
            }
        }
        if (length + piece.len >= out.len) return error.CommentTextTooLong;
        @memcpy(out[length..][0..piece.len], piece);
        length += piece.len;
    }
    return out[0..length];
}

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

test "PostFragDelta adds to the client and, outside mode 1, to its team" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();
    var database = Database.init(std.testing.allocator);
    defer database.deinit();
    try database.reset(&router);
    router.reset();
    var bytes = message.fragDelta(1, .{ .client = 3, .team = 2, .points = 1 });
    _ = try router.post(0x800, 0x408 | 0xc0000000, &bytes);
    const request = (try database.next(&router, true, 0)).?;
    try std.testing.expectEqual(message.FragDelta{ .client = 3, .team = 2, .points = 1 }, request.frag_delta);
    const context: LevelContext = .{ .now = 0, .game_type = 5, .mode = 4, .game_state = 1 };
    try database.applyFragDelta(&router, request.frag_delta, context);
    try database.applyFragDelta(&router, .{ .client = 3, .team = 2, .points = 0xffffffff }, context);
    try database.applyFragDelta(&router, .{ .client = 3, .team = 2, .points = 0x10002 }, context);
    try std.testing.expectEqual(@as(i16, 2), router.scores[3].points);
    try std.testing.expectEqual(@as(i16, 2), router.team_points[2]);
    try database.applyFragDelta(&router, .{ .client = 3, .team = 0xffffffff, .points = 1 }, context);
    try database.applyFragDelta(&router, .{ .client = 3, .team = 1, .points = 1 }, .{ .now = 0, .game_type = 5, .mode = 1, .game_state = 1 });
    try std.testing.expectEqual(@as(i16, 4), router.scores[3].points);
    try std.testing.expectEqual([3]i16{ 0, 0, 2 }, router.team_points);
    try std.testing.expectError(error.MalformedNetworkMessage, database.applyFragDelta(&router, .{ .client = 3, .team = 3, .points = 1 }, context));
    try std.testing.expectError(error.MalformedNetworkMessage, database.applyFragDelta(&router, .{ .client = 256, .team = 0xffffffff, .points = 1 }, context));
}

test "a joining client's number table is owned until it leaves" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();
    var database = Database.init(std.testing.allocator);
    defer database.deinit();
    try database.reset(&router);
    try database.addClient(3);
    try database.addClient(3);
    const number = try database.give(3, .{ .actor = 7 });
    try std.testing.expectEqual(@as(u32, 3 << 11 | 1), number);
    try std.testing.expectError(error.DatabaseClientObjectsNotPorted, database.removeClient(3));
    try std.testing.expect(database.find(number) != null);
    database.free(number, 100);
    try database.removeClient(3);
    try std.testing.expect(database.tables[3] == null);
}
