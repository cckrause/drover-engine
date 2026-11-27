//! Sending to and receiving from other machines, including packets too short to hold what is read from them.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const message = @import("message.zig");
const router_module = @import("router.zig");
const Router = router_module.Router;
const reference = @import("reference_driver.zig");
const Driver = reference.Driver;

fn int(object: std.json.ObjectMap, name: []const u8) u32 {
    return @intCast(object.get(name).?.integer);
}

test "router sends to and receives from other machines as the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/network-remote-reference.json",
        a,
        .limited(4 * 1024 * 1024),
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
    var driver: Driver = .{ .allocator = a };
    defer driver.deinit();

    router.network.session = driver.session();

    var game: reference.Game = .{ .allocator = a };
    defer game.deinit();

    router.game = game.hooks();
    router.sender_check = false;

    var buffer: [0x800]u8 = undefined;

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

            router.session_open = op.get("session_open").?.bool;
            router.dropped = op.get("dropped").?.bool;

            for (0..16) |queue| router.setQueueClosed(@intCast(queue), false);

            for (op.get(
                "closed",
            ).?.array.items) |queue| router.setQueueClosed(@intCast(queue.integer), true);

            router.last_send = 0;
            continue;
        }

        router.now = int(op, "clock");

        if (std.mem.eql(u8, kind, "post")) {
            const data = try std.fmt.hexToBytes(&buffer, op.get("bytes").?.string);
            driver.clear();
            const posted = try router.post(int(op, "destination"), int(op, "number"), data);

            try std.testing.expectEqual(int(op, "result"), @as(u32, switch (posted) {
                .queued, .sent, .multiplexed => 0,
                .invalid_client, .no_session => 1,
                // The reference never posts a part too large to multiplex.
                .too_large => return error.TestUnexpectedResult,
            }));

            try std.testing.expectEqual(
                op.get("logs").?.array.items.len != 0,
                posted == .invalid_client,
            );

            var after: [0x800]u8 = undefined;
            try std.testing.expectEqualSlices(
                u8,
                try std.fmt.hexToBytes(&after, op.get("after").?.string),
                data,
            );

            try driver.expectSends(op.get("sends").?.array.items);
        } else if (std.mem.eql(u8, kind, "read")) {
            driver.incoming = op.get("packets").?.array.items;
            driver.next = 0;
            router.lost = null;
            router.leave_game = false;

            var cleared: ?u32 = null;
            var popup: ?router_module.Lost = null;

            for (op.get("calls").?.array.items) |call| {
                if (call.object.get("clear")) |client| cleared = @intCast(client.integer);

                if (call.object.get("popup")) |texts| {
                    const title = texts.array.items[0].string;
                    const text = texts.array.items[1].string;

                    popup = if (std.mem.eql(u8, title, "&6120") and std.mem.eql(u8, text, "&6121"))
                        .server
                    else if (std.mem.eql(u8, title, "&6130") and std.mem.eql(u8, text, "&6131"))
                        .network
                    else
                        return error.UnknownPopup;
                }
            }

            if (cleared) |client| {
                var gone: message.Address = undefined;
                _ = try std.fmt.hexToBytes(
                    &gone,
                    driver.incoming[driver.incoming.len - 1].object.get("sender").?.string,
                );

                try std.testing.expectEqual(@as(?u32, client), router.clientByAddress(&gone));
            }

            game.clear();
            const got = try router.read(@intCast(int(op, "queue")));

            if (op.get("bytes").? == .string) {
                try std.testing.expectEqualSlices(
                    u8,
                    try std.fmt.hexToBytes(&buffer, op.get("bytes").?.string),
                    got.?,
                );
            } else try std.testing.expectEqual(@as(?[]u8, null), got);

            if (cleared) |client| {
                try std.testing.expect(message.isNone(&router.clients[client].address));
                try std.testing.expect(game.calls.items.len != 0);
            } else try std.testing.expectEqual(@as(usize, 0), game.calls.items.len);

            try std.testing.expectEqual(int(op, "left"), driver.incoming.len - driver.next);
            try std.testing.expectEqual(popup, router.lost);
            try std.testing.expectEqual(
                int(op.get("state").?.object, "game_state") == 2,
                router.leave_game,
            );
        } else return error.UnknownReferenceOperation;

        const state = op.get("state").?.object;

        try std.testing.expectEqual(int(state, "dropped") != 0, router.dropped);
        try std.testing.expectEqual(int(state, "last_send"), router.last_send);
        try std.testing.expectEqual(int(state, "sent_count"), router.network.sent_count);
        try std.testing.expectEqual(int(state, "sent_bytes"), router.network.sent_bytes);
        try std.testing.expectEqual(int(state, "received_count"), router.network.received_count);
        try std.testing.expectEqual(int(state, "received_bytes"), router.network.received_bytes);

        const heard = state.get("heard").?.object;

        for (router.clients, 0..) |client, slot| {
            var name: [3]u8 = undefined;
            const expected: u32 = if (heard.get(
                try std.fmt.bufPrint(&name, "{d}", .{slot}),
            )) |value| @intCast(value.integer) else 0;

            try std.testing.expectEqual(expected, client.last_heard);
        }
    }
}

test "the router refuses network packets too short to hold what it reads" {
    const a = std.testing.allocator;
    var router = try Router.init(a);
    defer router.deinit();
    const Short = struct {
        var packets = [_][]const u8{ "G", "G0123456789abcde", "S", "G0123456789abcdef" };

        var next: usize = 0;

        fn send(_: *anyopaque, _: []const u8, _: ?*const message.Address, _: u32) anyerror!void {}

        fn get(_: *anyopaque, buffer: []u8, sender: *message.Address) anyerror!usize {
            if (next == packets.len) return 0;

            defer next += 1;

            sender.* = @splat(1);

            @memcpy(buffer[0..packets[next].len], packets[next]);

            return packets[next].len;
        }
    };

    var context: u8 = 0;

    router.network.session = .{ .context = &context, .send = Short.send, .get = Short.get };
    router.session_open = true;
    router.own_client = 1;

    try std.testing.expectEqual(@as(?[]u8, null), try router.read(6));
    try std.testing.expectEqual(@as(u32, 4), router.rejected);
    try std.testing.expectEqual(@as(u32, 4), router.network.received_count);

    router.own_address = @splat(2);
    router.clients[3].address = @splat(3);

    var long: [2032]u8 = @splat(0);

    try std.testing.expectError(error.MalformedNetworkMessage, router.post(0x001800, 0x418, &long));
    try std.testing.expectEqual(
        router_module.Posted.sent,
        try router.post(0x001800, 0x418, long[0..2031]),
    );
}
