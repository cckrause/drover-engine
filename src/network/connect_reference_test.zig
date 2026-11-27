//! Connecting: the wait, clearing a client that left, and the refusal of a message that does not come from the client it names.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const message = @import("message.zig");
const router_module = @import("router.zig");
const reference = @import("reference_driver.zig");
const Router = router_module.Router;

const Feed = struct {
    packets: [8]Packet = undefined,
    count: usize = 0,
    next: usize = 0,
    host: message.Address,

    const Packet = struct { bytes: [0x100]u8, length: usize, sender: message.Address };

    fn add(self: *Feed, bytes: []const u8, sender: message.Address) void {
        var buffer: [0x100]u8 = undefined;
        buffer[0] = 'G';
        @memcpy(buffer[1..][0..bytes.len], bytes);
        self.packets[self.count] = .{ .bytes = buffer, .length = bytes.len + 1, .sender = sender };
        self.count += 1;
    }

    fn session(self: *Feed) @import("network.zig").Driver {
        return .{ .context = self, .send = send, .get = get, .host_address = self.host };
    }

    fn send(_: *anyopaque, _: []const u8, _: ?*const message.Address, _: u32) anyerror!void {}

    fn get(context: *anyopaque, buffer: []u8, sender: *message.Address) anyerror!usize {
        const self: *Feed = @ptrCast(@alignCast(context));
        if (self.next == self.count) return 0;
        const packet = &self.packets[self.next];
        self.next += 1;
        sender.* = packet.sender;
        @memcpy(buffer[0..packet.length], packet.bytes[0..packet.length]);
        return packet.length;
    }
};

fn replay(a: std.mem.Allocator, root: std.json.ObjectMap, sender_check: bool) !u32 {
    var router = try Router.init(a);
    defer router.deinit();
    var driver: reference.Driver = .{ .allocator = a };
    defer driver.deinit();
    var game: reference.Game = .{ .allocator = a, .router = &router, .left_text = root.get("left_text").?.string };
    defer game.deinit();
    var opener: reference.Opener = .{ .driver = &driver, .game = &game };
    driver.game = &game;
    _ = try std.fmt.hexToBytes(&driver.host_address, "020a0f14191e23282d32373c41464b50");
    router.game = game.hooks();
    router.network.provider = opener.provider();
    router.sender_check = sender_check;

    for (root.get("ops").?.array.items) |item| {
        const op = item.object;
        const kind = op.get("op").?.string;
        if (std.mem.eql(u8, kind, "setup")) {
            router.own_client = int(op, "own");
            router.own_address = message.no_address;
            if (op.get("own_address").? == .string) _ = try std.fmt.hexToBytes(&router.own_address, op.get("own_address").?.string);
            router.clients = @splat(.{});
            var clients = op.get("clients").?.object.iterator();
            while (clients.next()) |entry| {
                const slot = try std.fmt.parseInt(u8, entry.key_ptr.*, 10);
                _ = try std.fmt.hexToBytes(&router.clients[slot].address, entry.value_ptr.string);
            }
            var names = op.get("names").?.object.iterator();
            while (names.next()) |entry| {
                const name = entry.value_ptr.string;
                @memcpy(router.clients[try std.fmt.parseInt(u8, entry.key_ptr.*, 10)].name[0..name.len], name);
            }
            for (op.get("in_level").?.array.items) |slot| router.clients[@intCast(slot.integer)].in_level = true;
            for (&router.scores, 0..) |*score, slot| score.* = .{ .points = @intCast(slot), .seconds = -@as(i16, @intCast(slot)) };
            router.client_count = int(op, "count");
            router.reset_done = true;
            router.session_open = op.get("session_open").?.bool;
            router.network.session = if (router.session_open) driver.session() else null;
            router.dropped = op.get("dropped").?.bool;
            router.leave_game = op.get("leave").?.bool;
            router.lost = null;
            router.game_type = int(op, "game_type");
            router.player_name = @splat(0);
            const player = op.get("player").?.string;
            @memcpy(router.player_name[0..player.len], player);
            router.join_password = @splat(0);
            const password = op.get("password").?.string;
            @memcpy(router.join_password[0..password.len], password);
            router.reject_text = @splat(0);
            const older = "An older text of many letters.";
            @memcpy(router.reject_text[0..older.len], older);
            router.join_done = false;
            router.now = int(op, "clock");
            driver.incoming = &.{};
            driver.next = 0;
            continue;
        }
        driver.clear();
        game.clear();
        if (std.mem.eql(u8, kind, "connect")) {
            opener.fail = op.get("open_error").? == .string;
            _ = try std.fmt.hexToBytes(&opener.address, op.get("address").?.string);
            const started = router.connect(op.get("hosting").?.bool, op.get("name").?.string) catch |err| switch (err) {
                error.ReferenceDriverCannotOpen => false,
                else => return err,
            };
            const passes = op.get("passes").?.array.items;
            var joined = started;
            var shown: ?[message.reject_text_limit + 1]u8 = null;
            if (started and !op.get("hosting").?.bool) {
                var cancelled = false;
                var pass: usize = 0;
                const end = while (true) : (pass += 1) {
                    if (try router.stepJoin(cancelled)) |end| break end;
                    const expected = passes[pass].object;
                    try driver.expectSends(expected.get("sends").?.array.items);
                    try game.expectCalls(expected.get("calls").?.array.items);
                    try expectLost(expected.get("calls").?.array.items, &router);
                    try expectState(expected.get("state").?.object, &router);
                    driver.clear();
                    game.clear();
                    const next = expected.get("next").?.object;
                    router.now = int(next, "clock");
                    cancelled = next.get("cancel").?.bool;
                    if (next.get("leave").?.bool) router.leave_game = true;
                    driver.incoming = next.get("packets").?.array.items;
                    driver.next = 0;
                };
                try std.testing.expectEqual(passes.len, pass);
                try std.testing.expectEqual(driver.incoming.len, driver.next);
                joined = end == .joined;
                if (end == .failed) shown = end.failed.shown;
            } else try std.testing.expectEqual(@as(usize, 0), passes.len);
            try std.testing.expectEqual(int(op, "result"), @intFromBool(joined));
            try expectShown(op.get("calls").?.array.items, shown);
        } else if (std.mem.eql(u8, kind, "clear")) {
            try router.clearClient(@intCast(int(op, "client")));
        } else if (std.mem.eql(u8, kind, "read")) {
            router.now = int(op, "clock");
            driver.incoming = op.get("packets").?.array.items;
            driver.next = 0;
            try std.testing.expectEqual(@as(?[]u8, null), try router.read(@intCast(int(op, "queue"))));
            try std.testing.expectEqual(driver.incoming.len, driver.next);
        } else return error.UnknownReferenceOperation;

        try driver.expectSends(op.get("sends").?.array.items);
        try game.expectCalls(op.get("calls").?.array.items);
        try expectState(op.get("state").?.object, &router);
    }
    return router.rejected;
}

fn expectLost(calls: []const std.json.Value, router: *Router) !void {
    var expected: ?router_module.Lost = null;
    for (calls) |call| {
        const popup = call.object.get("popup") orelse continue;
        const title = popup.array.items[0].string;
        const text = popup.array.items[1].string;
        expected = if (std.mem.eql(u8, title, "&6120") and std.mem.eql(u8, text, "&6121"))
            .server
        else if (std.mem.eql(u8, title, "&6130") and std.mem.eql(u8, text, "&6131"))
            .network
        else
            return error.UnknownPopup;
    }
    try std.testing.expectEqual(expected, router.lost);
    router.lost = null;
}

fn expectShown(calls: []const std.json.Value, shown: ?[message.reject_text_limit + 1]u8) !void {
    var seen = false;
    for (calls) |call| {
        if (call.object.get("popup")) |popup| {
            const text = std.mem.sliceTo(&shown.?, 0);
            try std.testing.expect(text.len == 0 or text[0] != '$');
            try std.testing.expectEqualStrings(popup.array.items[0].string, text);
            try std.testing.expectEqualStrings("&6131", popup.array.items[1].string);
            try std.testing.expectEqual(@as(usize, 2), popup.array.items.len);
            seen = true;
        } else if (call.object.get("box")) |box| {
            if (shown == null) continue;
            const text = std.mem.sliceTo(&shown.?, 0);
            try std.testing.expectEqual(@as(u8, '$'), text[0]);
            try std.testing.expectEqualStrings(box.string, text[1..]);
            seen = true;
        }
    }
    try std.testing.expectEqual(seen, shown != null);
}

fn expectState(state: std.json.ObjectMap, router: *Router) !void {
    try std.testing.expectEqual(int(state, "own"), router.own_client);
    try std.testing.expectEqual(int(state, "count"), router.client_count);
    try std.testing.expectEqual(state.get("join_done").?.bool, router.join_done);
    try std.testing.expectEqual(int(state, "dropped") != 0, router.dropped);
    try std.testing.expectEqual(state.get("session_open").?.bool, router.session_open);
    try std.testing.expectEqual(state.get("session").?.integer != -1, router.network.session != null);
    try std.testing.expectEqual(state.get("reset_done").?.bool, router.reset_done);
    try std.testing.expectEqual(int(state, "game_state") == 2, router.leave_game);
    try std.testing.expectEqual(int(state, "last_send"), router.last_send);
    try std.testing.expectEqual(int(state, "sent_count"), router.network.sent_count);
    try std.testing.expectEqual(int(state, "sent_bytes"), router.network.sent_bytes);
    try std.testing.expectEqual(int(state, "received_count"), router.network.received_count);
    try std.testing.expectEqual(int(state, "received_bytes"), router.network.received_bytes);
    try std.testing.expectEqualStrings(state.get("player").?.string, std.mem.sliceTo(&router.player_name, 0));
    var buffer: [0x28]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buffer, state.get("reject_bytes").?.string), &router.reject_text);
    var address: message.Address = message.no_address;
    if (state.get("own_address").? == .string) _ = try std.fmt.hexToBytes(&address, state.get("own_address").?.string);
    try std.testing.expectEqual(address, router.own_address);
    var queued: u32 = 0;
    for (router.queues) |list| queued += @intFromBool(list.count != 0);
    try std.testing.expectEqual(int(state, "queued"), queued);
    for (state.get("scores").?.array.items, router.scores) |expected, score| {
        try std.testing.expectEqual(expected.array.items[0].integer, @as(i64, score.points));
        try std.testing.expectEqual(expected.array.items[1].integer, @as(i64, score.seconds));
    }
    var in_level: usize = 0;
    for (state.get("in_level").?.array.items) |slot| {
        try std.testing.expect(router.clients[@intCast(slot.integer)].in_level);
        in_level += 1;
    }
    const clients = state.get("clients").?.object;
    const heard = state.get("heard").?.object;
    for (&router.clients, 0..) |*client, slot| {
        in_level -= @intFromBool(client.in_level);
        var name: [3]u8 = undefined;
        if (clients.get(try std.fmt.bufPrint(&name, "{d}", .{slot}))) |value| {
            const expected = value.object;
            if (expected.get("address").? == .string) {
                _ = try std.fmt.hexToBytes(&address, expected.get("address").?.string);
                try std.testing.expectEqual(address, client.address);
            } else try std.testing.expect(message.isNone(&client.address));
            try std.testing.expectEqualStrings(expected.get("name").?.string, client.playerName());
        } else {
            try std.testing.expect(message.isNone(&client.address));
            try std.testing.expectEqual(@as(usize, 0), client.playerName().len);
        }
        const expected: u32 = if (heard.get(try std.fmt.bufPrint(&name, "{d}", .{slot}))) |value| @intCast(value.integer) else 0;
        try std.testing.expectEqual(expected, client.last_heard);
    }
    try std.testing.expectEqual(@as(usize, 0), in_level);
}

fn int(object: std.json.ObjectMap, name: []const u8) u32 {
    return @intCast(object.get(name).?.integer);
}

test "connect, its wait and the client clear match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/network-connect-reference.json", a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("f71a8db8743d12a14317393148a0ade05e2f86d7d80a98d4a76f1bffa20a52d1", root.get("executable_sha256").?.string);
    try std.testing.expectEqual(@as(u32, 0), try replay(a, root, false));
    try std.testing.expectEqual(@as(u32, 2), try replay(a, root, true));
}

test "the router refuses messages that do not come from the client they name" {
    const a = std.testing.allocator;
    const host: message.Address = @splat(1);
    const three: message.Address = @splat(3);
    const four: message.Address = @splat(4);
    const five: message.Address = @splat(5);

    var router = try Router.init(a);
    defer router.deinit();
    var recorded: reference.Game = .{ .allocator = a };
    defer recorded.deinit();
    router.game = recorded.hooks();
    var feed: Feed = .{ .host = host };
    router.network.session = feed.session();
    router.session_open = true;
    router.own_client = 1;
    router.own_address = host;
    router.clients[1].address = host;
    router.clients[3].address = three;
    router.clients[4].address = four;

    var request = message.request(0x3ef, 3);
    message.set(&request, message.destination_offset, 0x100800);
    feed.add(&request, three);
    feed.add(&request, four);
    var buffer: [message.join_capacity]u8 = undefined;
    const asking = try message.join(&buffer, 0, &five, "Five", "(1.1) ");
    message.set(asking, message.destination_offset, 0x100000);
    feed.add(asking, five);
    feed.add(asking, four);
    message.set(asking, message.sender_offset, message.addressWord(message.Queue.router, 4));
    feed.add(asking, five);
    var record: [message.client_address_capacity]u8 = undefined;
    const stolen = try message.clientAddress(&record, 1, .{ .client = 3, .address = four, .name = "x" });
    message.set(stolen, message.destination_offset, 0x180800);
    feed.add(stolen, four);
    var bundle: [0x14 + 2 * 0x12]u8 = @splat(0);
    @memcpy(bundle[0..message.header_size], &message.request(0x3f8, 3));
    message.set(&bundle, message.destination_offset, 0x180800);
    message.set(&bundle, 0x10, 2);
    bundle[0x14] = 0x10;
    @memcpy(bundle[0x16..0x26], &request);
    bundle[0x26] = 0x10;
    @memcpy(bundle[0x28..0x38], &message.request(0x3ef, 4));
    feed.add(&bundle, three);

    const first = (try router.read(message.Queue.server)).?;
    try std.testing.expectEqual(@as(u32, 0x3ef), message.get(first, message.number_offset));
    router.release(first);
    const second = (try router.read(message.Queue.server)).?;
    try std.testing.expectEqual(@as(u32, 0x3e9), message.get(second, message.number_offset));
    router.release(second);
    try std.testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.server));
    try std.testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.router));
    try std.testing.expectEqual(@as(u32, 5), router.rejected);
    try std.testing.expectEqual(three, router.clients[3].address);

    var joiner = try Router.init(a);
    defer joiner.deinit();
    joiner.game = recorded.hooks();
    var arriving: Feed = .{ .host = host };
    joiner.network.session = arriving.session();
    joiner.session_open = true;
    joiner.own_client = 0xffffffff;
    joiner.own_address = five;
    const false_server = try message.clientAddress(&record, 1, .{ .client = 1, .address = four, .name = "Host" });
    message.set(false_server, message.destination_offset, 0x180800);
    arriving.add(false_server, four);
    const server = try message.clientAddress(&record, 1, .{ .client = 1, .address = host, .name = "Host" });
    message.set(server, message.destination_offset, 0x180800);
    arriving.add(server, host);
    const own = try message.clientAddress(&record, 1, .{ .client = 5, .address = five, .name = "Five" });
    message.set(own, message.destination_offset, 0x180800);
    arriving.add(own, host);
    const itself = try message.clientAddress(&record, 4, .{ .client = 4, .address = four, .name = "Four" });
    message.set(itself, message.destination_offset, 0x180000);
    arriving.add(itself, four);
    const as_another = try message.clientAddress(&record, 3, .{ .client = 3, .address = four, .name = "Three" });
    message.set(as_another, message.destination_offset, 0x180000);
    arriving.add(as_another, four);
    const taken = try message.clientAddress(&record, 5, .{ .client = 5, .address = four, .name = "Me" });
    message.set(taken, message.destination_offset, 0x180000);
    arriving.add(taken, four);
    try joiner.process();
    try std.testing.expectEqual(@as(u32, 2), joiner.rejected);
    try std.testing.expectEqual(@as(u32, 5), joiner.own_client);
    try std.testing.expectEqual(host, joiner.clients[1].address);
    try std.testing.expectEqual(four, joiner.clients[4].address);
    try std.testing.expectEqual(five, joiner.clients[5].address);
    try std.testing.expectEqual(four, joiner.clients[3].address);
}
