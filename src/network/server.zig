//! The server: it runs on the machine that is client 1 and answers the
//! requests the game sends - campaign start, level start, level end, the
//! death match rules, scores and item drops.
//!
//! Single player runs a server too; the only difference is that it is local.
//! The level-end request has a cooldown compared with a wrapping clock, so
//! a second request inside that window is dropped. A request that needs
//! something unimplemented fails loudly instead of being ignored.

const std = @import("std");

const message = @import("message.zig");
const router_module = @import("router.zig");
const Router = router_module.Router;
const FixedList = @import("../util/fixed_list.zig").FixedList;

/// User messages one server pass may hand to the level. The level frame
/// turns each into an effect, and its effect list holds no more than this
/// (`inventory.max_effects`), so a longer list could not be handed on.
pub const max_user_messages = 256;
pub const UserMessages = FixedList(i32, error{TooManyUserMessages});
pub const UserMessageBuffer = [max_user_messages]i32;

pub const CompletionGate = struct {
    last: u32 = 0,

    pub fn accept(self: *CompletionGate, now: u32) bool {
        if (self.last +% 10000 >= now) return false;
        self.last = now;

        return true;
    }
};

pub const Server = struct {
    record: message.GameRecord = .{},
    starts: [16]message.Start = @splat(@splat(0)),
    start_count: u32 = 0,
    red_start: u32 = 0xffffffff,
    blue_start: u32 = 0xffffffff,
    completion_gate: CompletionGate = .{},
    new_it_gate: u32 = 0,
    tail_due: u32 = 0,
    first_start_request: u32 = 0,
    started: bool = false,
    password: [0x40]u8 = @splat(0),
    player_limit: u32 = 8,
    configuration: Configuration = .{},
    critical: [12]u32 = @splat(0),

    pub fn reset(self: *Server) void {
        self.record = .{};
        self.new_it_gate = 0;
        self.completion_gate = .{};
        self.tail_due = 0;
        self.first_start_request = 0;
        self.started = false;
        self.critical = @splat(0);
    }

    pub fn close(self: *Server) void {
        self.record = .{};
        self.critical = @splat(0);
    }

    pub fn forget(self: *Server, client: u32) void {
        for ([_]usize{ 11, 2, 5, 8, 0 }) |index| {
            if (self.critical[index] == client) self.critical[index] = 0;
        }
    }
};

pub const Configuration = struct {
    options: [7]bool = @splat(false),
    flags: u32 = 0,

    pub fn bits(self: *const Configuration) u32 {
        var result: u32 = 0;

        for (self.options, 0..) |option, index| {
            if (option) result |= @as(u32, 1) << @intCast(index);
        }

        for ([_]u32{
            1,
            2,
            4,
            0x10,
            0x20,
            0x40,
            0x80,
            0x200,
        }, [_]u32{ 0x80, 0x100, 0x200, 0x800, 0x1000, 0x2000, 0x4000, 0x20000 }) |flag, bit| {
            if (self.flags & flag != 0) result |= bit;
        }

        return result;
    }

    pub fn fromDatabase(self: *Configuration, value: u32) void {
        for (&self.options, 0..) |*option, index| option.* = value & (@as(
            u32,
            1,
        ) << @intCast(index)) != 0;

        if (value & 0x20000 == 0) self.flags &= ~@as(u32, 0x200) else self.flags |= 0x200;
    }
};

pub const Context = struct {
    now: ?u32,
    game_type: u32,
    mode: u32 = 0,
    level_loaded: bool,
    allocator: std.mem.Allocator,
    user_messages: *UserMessages,
    level: ?Level = null,
};

pub const Level = struct {
    context: *anyopaque,
    sectors: usize,
    create: *const fn (context: *anyopaque, value: message.HaveServerCreate) anyerror!void,
};

pub fn postGameInfo(router: *Router, record: *const message.GameRecord) !void {
    var buffer: [message.game_info_capacity]u8 = undefined;
    const bytes = try message.gameInfo(&buffer, 0x3ec, router.own_client, record);

    message.set(bytes, message.reply_offset, (router.own_client & 0xff) << 11);
    message.set(bytes, message.sender_offset, ownServer(router));
    try post(router, 0x100800, bytes);
}

pub fn requestGameInfo(router: *Router) !void {
    var bytes = message.request(0x3eb, router.own_client);
    message.set(&bytes, message.reply_offset, (router.own_client & 0xff) << 11);
    message.set(&bytes, message.sender_offset, ownServer(router));
    try post(router, 0x100800, &bytes);
}

pub fn setStartPosition(router: *Router, record: message.Start) !void {
    var bytes = message.start(0x3f2, router.own_client, record);
    message.set(&bytes, message.reply_offset, (router.own_client & 0xff) << 11);
    message.set(&bytes, message.sender_offset, ownServer(router));
    try post(router, 0x100800, &bytes);
}

pub fn addStartPosition(router: *Router, record: message.Start) !void {
    var bytes = message.start(0x3f3, router.own_client, record);
    message.set(&bytes, message.reply_offset, ownServer(router));
    message.set(&bytes, message.sender_offset, ownServer(router));
    try post(router, 0x100800, &bytes);
}

pub fn requestStartPosition(router: *Router, team: u8) !void {
    var bytes = message.startRequest(router.own_client, team);
    message.set(&bytes, message.reply_offset, (router.own_client & 0xff) << 11);
    message.set(&bytes, message.sender_offset, ownServer(router));
    try post(router, 0x100800, &bytes);
}

pub fn requestEndLevel(router: *Router) !void {
    var bytes = message.request(0x3ef, router.own_client);

    message.set(
        &bytes,
        message.reply_offset,
        message.addressWord(message.Queue.database, @truncate(router.own_client)),
    );

    message.set(&bytes, message.sender_offset, ownServer(router));
    try post(router, 0x100800, &bytes);
}

pub fn processRequests(server: *Server, router: *Router, context: Context) !void {
    while (try router.read(message.Queue.server)) |bytes| {
        defer router.release(bytes);
        const number = message.get(bytes, message.number_offset);

        switch (number) {
            0x3eb => {
                const parameter = server.record.parameter;

                if (parameter == 0 and message.client(
                    message.get(bytes, message.sender_offset),
                ) != 1) continue;

                var buffer: [message.game_info_capacity]u8 = undefined;
                const reply = try message.gameInfo(
                    &buffer,
                    0x406,
                    router.own_client,
                    &server.record,
                );

                if (parameter != server.record.checksum) return error.CorruptedGameRecordChecksum;

                const reply_address = message.get(bytes, message.reply_offset);

                message.set(reply, message.reply_offset, reply_address);
                message.set(reply, message.sender_offset, ownServer(router));
                try post(router, reply_address, reply);
            },
            0x3ec => {
                try message.readGameInfo(bytes, &server.record);
                server.start_count = 0;
                server.red_start = 0xffffffff;
                server.blue_start = 0xffffffff;
            },
            0x3e9 => {
                const join = try message.readJoin(bytes);

                if (!std.mem.startsWith(u8, join.tag_and_password, router_module.version_tag)) {
                    var text: [0x3c + 1]u8 = @splat(0);
                    router.game.text(router.game.context, 0x140d, text[0..0x3c]);
                    try rejectJoin(router, bytes, &join.address, std.mem.sliceTo(&text, 0));
                    continue;
                }

                const password = std.mem.sliceTo(&server.password, 0);

                if (password.len != 0 and !std.ascii.eqlIgnoreCase(
                    join.tag_and_password[6..],
                    password,
                )) {
                    try rejectJoin(router, bytes, &join.address, "&5119");
                    continue;
                }

                if (server.player_limit != 0 and router.clientCount() >= server.player_limit) {
                    try rejectJoin(router, bytes, &join.address, "&5127");
                    continue;
                }

                if (context.level_loaded) _ = try router.join(&join.address, join.name);
            },
            0x3ed, 0x3ee => {
                const now = context.now orelse return error.ServerClockNotSampled;
                if (server.completion_gate.last +% 10000 >= now) continue;
                return error.ServerFlagCaptureNotPorted;
            },
            0x3ef => {
                if (!server.completion_gate.accept(
                    context.now orelse return error.ServerClockNotSampled,
                )) continue;

                const text = if (context.game_type == 5 and !router.dropped) "~5122" else "";
                var buffer: [message.end_level_capacity]u8 = undefined;
                const everyone = message.endLevel(&buffer, router.own_client, text);

                try post(router, 0, everyone);
                const own = message.endLevel(&buffer, router.own_client, "");
                try post(router, (router.own_client & 0xff) << 11, own);
            },
            0x3f1 => {
                if (bytes.len < message.start_request_size) return error.MalformedNetworkMessage;

                const now = context.now orelse return error.ServerClockNotSampled;

                if (server.first_start_request == 0) server.first_start_request = now;

                const sender = message.client(message.get(bytes, message.sender_offset));
                if (router.clients[sender].player != null and (context.mode == 1 or context.mode == 3)) return error.HolderDropNotPorted;

                const start = if (context.game_type >= 1 and context.game_type <= 3)
                    server.starts[0]
                else blk: {
                    if (context.mode == 1 or context.mode == 4) return error.ServerTeamStartNotPorted;
                    if (server.start_count == 0) return error.NetworkStartPositionsNotFound;

                    const state = now *% 0x343fd +% 0x269ec3;
                    const roll = (state >> 16) & 0x7fff;

                    break :blk server.starts[roll % server.start_count];
                };

                server.started = true;

                var reply = message.start(0x407, router.own_client, start);
                const reply_address = message.get(bytes, message.reply_offset);

                message.set(&reply, message.reply_offset, reply_address);
                message.set(&reply, message.sender_offset, ownServer(router));
                try post(router, reply_address, &reply);
            },
            0x3f2 => server.starts[0] = try message.readStart(bytes),
            0x3f3 => if (server.start_count < server.starts.len) {
                server.starts[server.start_count] = try message.readStart(bytes);
                server.start_count += 1;
            },
            0x7e5 => {
                if (bytes.len < message.words_size) return error.MalformedNetworkMessage;
                try context.user_messages.append(
                    @bitCast(message.get(bytes, message.word_offsets[1])),
                );
            },
            0x3f4 => {
                if (bytes.len < 0x14) return error.MalformedNetworkMessage;

                if (message.get(bytes, 0x10) == 0) continue;

                const now = context.now orelse return error.ServerClockNotSampled;

                if (server.new_it_gate +% 5000 >= now) continue;

                server.new_it_gate = now;
                return error.ServerTagNotPorted;
            },
            0x3f6 => {
                if (!context.level_loaded) continue;

                const value = try message.readCorpse(bytes);
                const level = context.level orelse return error.ServerCorpseNotPorted;
                if (value.sector >= level.sectors) return error.MalformedNetworkMessage;

                var buffer: [message.corpse_capacity]u8 = undefined;
                const created = try message.corpse(&buffer, 0x413, router.own_client, value);

                message.set(created, message.sender_offset, ownServer(router));
                try router.postHereAndEveryone(0, 0x413, created);
            },
            0x415 => {
                if (!context.level_loaded) continue;

                const value = try message.readHaveServerCreate(bytes);
                const level = context.level orelse return error.ServerCreateObjectNotPorted;
                if (value.sector >= level.sectors) return error.MalformedNetworkMessage;

                try level.create(level.context, value);
            },
            0x41f => {
                if (bytes.len < 0x14) return error.MalformedNetworkMessage;

                const bits = message.get(bytes, 0x10);
                const config = &server.configuration;

                for (&config.options, 0..) |*option, index| option.* = bits & (@as(
                    u32,
                    1,
                ) << @intCast(index)) != 0;

                if (config.flags & 0x100 == 0) {
                    for ([_]u32{
                        0x80,
                        0x100,
                        0x200,
                        0x800,
                        0x1000,
                        0x2000,
                        0x4000,
                    }, [_]u32{ 1, 2, 4, 0x10, 0x20, 0x40, 0x80 }) |from, to| {
                        if (bits & from != 0) config.flags |= to else config.flags &= ~to;
                    }
                }

                if (bits & 0x20000 != 0) config.flags |= 0x200 else config.flags &= ~@as(
                    u32,
                    0x200,
                );
            },
            else => {
                var name: [16]u8 = undefined;
                std.log.debug(
                    "Server_ProcessRequests: Unhandled message {s}",
                    .{message.name(number, &name)},
                );
            },
        }
    }

    if (!server.started or !context.level_loaded) return;

    if (context.mode == 1 or context.mode == 3) return error.ServerGameModeNotPorted;

    const now = context.now orelse return error.ServerClockNotSampled;
    if (now <= server.tail_due) return;

    server.tail_due = now +% 0x9c4;
    if (context.mode == 2) return error.ServerGameModeNotPorted;
}

pub fn dropRequests(router: *Router) !void {
    while (try router.read(message.Queue.server)) |bytes| router.release(bytes);
}

fn post(router: *Router, destination: u32, bytes: []u8) !void {
    _ = try router.post(destination, message.get(bytes, message.number_offset), bytes);
}

fn ownServer(router: *const Router) u32 {
    return message.addressWord(message.Queue.server, @truncate(router.own_client));
}

fn rejectJoin(
    router: *Router,
    request: []const u8,
    address: *const message.Address,
    text: []const u8,
) !void {
    var buffer: [message.reject_capacity]u8 = undefined;
    const bytes = try message.rejectJoin(&buffer, router.own_client, text);

    message.set(bytes, message.sender_offset, ownServer(router));
    message.set(bytes, message.destination_offset, message.get(request, message.sender_offset));
    message.set(bytes, message.reply_offset, message.get(request, message.sender_offset));
    try router.sendDirect(bytes, address, 1);
}

test "server queue is emptied while the switch is off" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();

    router.reset();
    var request: [message.header_size]u8 = @splat(0);

    _ = try router.post(message.addressWord(message.Queue.server, 1), 0x3ef, &request);
    _ = try router.post(message.addressWord(message.Queue.database, 1), 0x404, &request);

    try dropRequests(&router);
    try std.testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.server));
    const kept = (try router.read(message.Queue.database)).?;
    router.release(kept);
}

test "MakeMeACorpse comes back as CreateCorpse here and for everyone" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();

    router.reset();

    var server: Server = .{};
    var users_buffer: UserMessageBuffer = undefined;
    var users = UserMessages.init(&users_buffer);
    const Hooks = struct {
        fn create(_: *anyopaque, _: message.HaveServerCreate) anyerror!void {
            return error.UnexpectedCreate;
        }
    };

    var context: u8 = 0;
    const level: Level = .{ .context = &context, .sectors = 8, .create = Hooks.create };
    const sent: message.Corpse = .{
        .choreography = 0x15,
        .sector = 7,
        .position = .{ 0x3f800000, 0xc0000000, 0x40500000 },
        .costume = "james.nwx",
    };

    var buffer: [message.corpse_capacity]u8 = undefined;

    _ = try router.post(0x100800, 0x3f6, try message.corpse(&buffer, 0x3f6, 1, sent));
    try processRequests(
        &server,
        &router,
        .{
            .now = 1,
            .game_type = 5,
            .mode = 6,
            .level_loaded = false,
            .allocator = std.testing.allocator,
            .user_messages = &users,
            .level = level,
        },
    );

    try std.testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.database));
    _ = try router.post(0x100800, 0x3f6, try message.corpse(&buffer, 0x3f6, 1, sent));
    try processRequests(
        &server,
        &router,
        .{
            .now = 1,
            .game_type = 5,
            .mode = 6,
            .level_loaded = true,
            .allocator = std.testing.allocator,
            .user_messages = &users,
            .level = level,
        },
    );

    const created = (try router.read(message.Queue.database)).?;
    defer router.release(created);

    try std.testing.expectEqual(@as(u32, 0x413), message.get(created, message.number_offset));
    try std.testing.expectEqual(
        message.addressWord(message.Queue.server, 1),
        message.get(created, message.sender_offset),
    );

    const value = try message.readCorpse(created);

    try std.testing.expectEqual(sent.choreography, value.choreography);
    try std.testing.expectEqual(sent.sector, value.sector);
    try std.testing.expectEqual(sent.position, value.position);
    try std.testing.expectEqualStrings(sent.costume, value.costume);

    var past = sent;

    past.sector = 8;
    _ = try router.post(0x100800, 0x3f6, try message.corpse(&buffer, 0x3f6, 1, past));

    try std.testing.expectError(
        error.MalformedNetworkMessage,
        processRequests(
            &server,
            &router,
            .{
                .now = 1,
                .game_type = 5,
                .mode = 6,
                .level_loaded = true,
                .allocator = std.testing.allocator,
                .user_messages = &users,
                .level = level,
            },
        ),
    );
}

test "v1.1.1 Death Match start matches the reference server reply" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();

    router.reset();

    var server: Server = .{};
    var users_buffer: UserMessageBuffer = undefined;
    var users = UserMessages.init(&users_buffer);

    try addStartPosition(&router, @splat(101));
    try addStartPosition(&router, @splat(202));
    try requestStartPosition(&router, 0);
    try processRequests(
        &server,
        &router,
        .{
            .now = 12345,
            .game_type = 5,
            .mode = 6,
            .level_loaded = true,
            .allocator = std.testing.allocator,
            .user_messages = &users,
        },
    );

    const reply = (try router.read(message.Queue.database)).?;
    defer router.release(reply);
    var expected: [message.start_size]u8 = undefined;

    _ = try std.fmt.hexToBytes(
        &expected,
        "0008000000081000000800000704000065000000650000006500000065000000650000006500000065000000",
    );

    try std.testing.expectEqualSlices(u8, &expected, reply);
    try std.testing.expect(server.started);
}
