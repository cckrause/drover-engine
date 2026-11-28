//! A joining machine: the server's answer, the router's queue, and the refusal of a join that does not fit the records.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const message = @import("message.zig");
const reference = @import("reference_driver.zig");
const router_module = @import("router.zig");
const server_module = @import("server.zig");
const Router = router_module.Router;

fn int(object: std.json.ObjectMap, name: []const u8) u32 {
    return @intCast(object.get(name).?.integer);
}

test "the join's server answer and router queue match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/network-join-reference.json",
        a,
        .limited(16 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings(
        "f71a8db8743d12a14317393148a0ade05e2f86d7d80a98d4a76f1bffa20a52d1",
        root.get("executable_sha256").?.string,
    );

    var router = try Router.init(a);
    defer router.deinit();
    var server: server_module.Server = .{};
    var driver: reference.Driver = .{ .allocator = a };
    defer driver.deinit();
    var game: reference.Game = .{ .allocator = a };
    defer game.deinit();

    router.network.session = driver.session();
    router.game = game.hooks();
    router.sender_check = false;

    var user_messages_buffer: server_module.UserMessageBuffer = undefined;
    var user_messages = server_module.UserMessages.init(&user_messages_buffer);
    var loaded = false;
    var buffer: [0x800]u8 = undefined;
    var address: message.Address = undefined;

    for (root.get("ops").?.array.items) |item| {
        const op = item.object;
        const kind = op.get("op").?.string;

        if (std.mem.eql(u8, kind, "setup")) {
            router.own_client = int(op, "own");
            router.own_address = message.no_address;

            if (op.get(
                "own_address",
            ).? == .string) _ = try std.fmt.hexToBytes(
                &router.own_address,
                op.get("own_address").?.string,
            );

            router.clients = @splat(.{});
            var clients = op.get("clients").?.object.iterator();

            while (clients.next()) |entry| {
                const slot = try std.fmt.parseInt(u8, entry.key_ptr.*, 10);
                _ = try std.fmt.hexToBytes(&router.clients[slot].address, entry.value_ptr.string);
            }

            var names = op.get("names").?.object.iterator();

            while (names.next()) |entry| {
                const name = entry.value_ptr.string;
                @memcpy(
                    router.clients[try std.fmt.parseInt(u8, entry.key_ptr.*, 10)].name[0..name.len],
                    name,
                );
            }

            for (&router.scores, 0..) |*score, slot| score.* = .{
                .points = @intCast(slot),
                .seconds = -@as(i16, @intCast(slot)),
            };

            router.client_count = int(op, "count");
            router.session_open = true;
            router.dropped = false;
            router.reject_text = @splat(0);
            router.join_done = false;
            loaded = op.get("loaded").?.bool;
            server.password = @splat(0);

            const password = op.get("password").?.string;
            @memcpy(server.password[0..password.len], password);
            server.player_limit = int(op, "limit");
            continue;
        }

        router.now = int(op, "clock");

        driver.clear();
        game.clear();

        if (std.mem.eql(u8, kind, "server")) {
            const request = try std.fmt.hexToBytes(&buffer, op.get("bytes").?.string);
            try std.testing.expectEqual(
                router_module.Posted.queued,
                try router.post(0x100800, .{ .code = 0x3e9 }, request),
            );

            try server_module.processRequests(
                &server,
                &router,
                .{
                    .now = router.now,
                    .game_type = .campaign,
                    .level_loaded = loaded,
                    .allocator = a,
                    .user_messages = &user_messages,
                },
            );
        } else if (std.mem.eql(u8, kind, "join")) {
            _ = try std.fmt.hexToBytes(&address, op.get("address").?.string);
            const number = try router.join(&address, op.get("name").?.string);
            try std.testing.expectEqual(int(op, "result"), number orelse 0xffffffff);
            try std.testing.expectEqual(int(op, "new") != 0, game.calls.items.len != 0);
        } else if (std.mem.eql(u8, kind, "set_client")) {
            _ = try std.fmt.hexToBytes(&address, op.get("address").?.string);
            try router.setClient(@intCast(int(op, "client")), &address, op.get("name").?.string);
        } else if (std.mem.eql(u8, kind, "process")) {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(a);

            try text.append(a, '[');

            for (op.get("messages").?.array.items, 0..) |data, index| {
                if (index != 0) try text.append(a, ',');

                try text.print(
                    a,
                    "{{\"bytes\":\"47{s}\",\"sender\":\"{s}\"}}",
                    .{ data.string, op.get("sender").?.string },
                );
            }

            try text.append(a, ']');

            const packets = try std.json.parseFromSlice(std.json.Value, a, text.items, .{});
            defer packets.deinit();

            driver.incoming = packets.value.array.items;
            driver.next = 0;

            try router.process();
            try std.testing.expectEqual(driver.incoming.len, driver.next);

            driver.incoming = &.{};
            driver.next = 0;
        } else if (std.mem.eql(u8, kind, "read")) {
            const got = try router.read(@intCast(int(op, "queue")));

            if (op.get("bytes").? == .string) {
                try std.testing.expectEqualSlices(
                    u8,
                    try std.fmt.hexToBytes(&buffer, op.get("bytes").?.string),
                    got.?,
                );
            } else try std.testing.expectEqual(@as(?[]u8, null), got);
        } else return error.UnknownReferenceOperation;

        try driver.expectSends(op.get("sends").?.array.items);
        try game.expectCalls(op.get("calls").?.array.items);

        const state = op.get("state").?.object;

        try std.testing.expectEqual(int(state, "own"), router.own_client);
        try std.testing.expectEqual(int(state, "count"), router.client_count);
        try std.testing.expectEqual(int(state, "dropped") != 0, router.dropped);
        try std.testing.expectEqual(int(state, "last_send"), router.last_send);
        try std.testing.expectEqual(int(state, "sent_count"), router.network.sent_count);
        try std.testing.expectEqual(int(state, "sent_bytes"), router.network.sent_bytes);
        try std.testing.expectEqual(int(state, "received_count"), router.network.received_count);
        try std.testing.expectEqual(int(state, "received_bytes"), router.network.received_bytes);
        try std.testing.expectEqual(state.get("join_done").?.bool, router.join_done);
        try std.testing.expectEqualStrings(
            state.get("reject_text").?.string,
            std.mem.sliceTo(&router.reject_text, 0),
        );

        for (state.get("scores").?.array.items, router.scores) |expected, score| {
            try std.testing.expectEqual(expected.array.items[0].integer, @as(i64, score.points));
            try std.testing.expectEqual(expected.array.items[1].integer, @as(i64, score.seconds));
        }

        const clients = state.get("clients").?.object;

        for (&router.clients, 0..) |*client, slot| {
            var name: [3]u8 = undefined;

            if (clients.get(try std.fmt.bufPrint(&name, "{d}", .{slot}))) |value| {
                const expected = value.object;

                if (expected.get("address").? == .string) {
                    _ = try std.fmt.hexToBytes(&address, expected.get("address").?.string);
                    try std.testing.expectEqual(address, client.address);
                } else try std.testing.expect(message.isNone(&client.address));

                try std.testing.expectEqual(int(expected, "heard"), client.last_heard);
                try std.testing.expectEqualStrings(
                    expected.get("name").?.string,
                    client.playerName(),
                );
            } else {
                try std.testing.expect(message.isNone(&client.address));
                try std.testing.expectEqual(@as(usize, 0), client.playerName().len);
            }
        }
    }
}

test "the router refuses join messages that do not fit its records" {
    const a = std.testing.allocator;
    var router = try Router.init(a);
    defer router.deinit();
    var game: reference.Game = .{ .allocator = a };
    defer game.deinit();

    router.game = game.hooks();
    router.own_client = 3;

    const own_queue = message.addressWord(message.Queue.router, 3);

    var buffer: [message.client_address_capacity]u8 = undefined;
    const outside = try message.clientAddress(
        &buffer,
        1,
        .{ .client = 3, .address = @splat(7), .name = "x" },
    );

    message.set(outside, 0x10, 0x100);
    _ = try router.post(own_queue, .{ .code = 0x3f7 }, outside);
    var endless: [0x30]u8 = @splat('n');
    @memcpy(endless[0..message.header_size], &message.request(0x3f7, 1));
    message.set(&endless, 0x10, 4);
    _ = try router.post(own_queue, .{ .code = 0x3f7 }, &endless);
    var long: [message.header_size + 0x29]u8 = @splat('t');
    @memcpy(long[0..message.header_size], &message.request(0x3fb, 1));

    long[long.len - 1] = 0;
    _ = try router.post(own_queue, .{ .code = 0x3fb }, &long);

    var bundle: [0x18]u8 = @splat(0);
    @memcpy(bundle[0..message.header_size], &message.request(0x3f8, 1));
    message.set(&bundle, 0x10, 3);

    bundle[0x14] = 0xff;
    _ = try router.post(own_queue, .{ .code = 0x3f8 }, &bundle);

    try router.process();

    try std.testing.expectEqual(@as(u32, 4), router.rejected);
    try std.testing.expectEqual(@as(usize, 0), game.calls.items.len);
    try std.testing.expect(!router.join_done);

    for (router.clients) |client| try std.testing.expect(message.isNone(&client.address));
}
