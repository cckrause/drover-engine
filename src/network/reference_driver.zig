//! A driver for the reference tests: it records what was sent, hands back
//! the packets a step should receive, and notes the calls the router makes
//! into the game.

const std = @import("std");
const message = @import("message.zig");
const network_layer = @import("network.zig");
const router_module = @import("router.zig");

pub const Driver = struct {
    allocator: std.mem.Allocator,
    sends: std.ArrayList(Sent) = .empty,
    incoming: []const std.json.Value = &.{},
    next: usize = 0,
    game: ?*Game = null,
    host_address: message.Address = message.no_address,
    description: std.ArrayList(u8) = .empty,

    pub const Sent = struct { bytes: []u8, to: ?message.Address, flags: u32 };

    pub fn deinit(self: *Driver) void {
        self.clear();
        self.sends.deinit(self.allocator);
        self.description.deinit(self.allocator);
    }

    pub fn clear(self: *Driver) void {
        for (self.sends.items) |sent| self.allocator.free(sent.bytes);
        self.sends.clearRetainingCapacity();
    }

    pub fn session(self: *Driver) network_layer.Driver {
        return .{ .context = self, .send = send, .get = get, .close = close, .describe = describe, .host_address = self.host_address };
    }

    pub fn expectSends(self: *const Driver, expected: []const std.json.Value) !void {
        try std.testing.expectEqual(expected.len, self.sends.items.len);
        var buffer: [0x800]u8 = undefined;
        for (expected, self.sends.items) |value, sent| {
            const object = value.object;
            try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buffer, object.get("bytes").?.string), sent.bytes);
            try std.testing.expectEqual(@as(u32, @intCast(object.get("flags").?.integer)), sent.flags);
            if (object.get("to").? == .string) {
                var to: message.Address = undefined;
                _ = try std.fmt.hexToBytes(&to, object.get("to").?.string);
                try std.testing.expectEqual(@as(?message.Address, to), sent.to);
            } else try std.testing.expectEqual(@as(?message.Address, null), sent.to);
        }
    }

    fn describe(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Driver = @ptrCast(@alignCast(context));
        self.description.clearRetainingCapacity();
        try self.description.appendSlice(self.allocator, data);
    }

    fn send(context: *anyopaque, data: []const u8, to: ?*const message.Address, flags: u32) void {
        const self: *Driver = @ptrCast(@alignCast(context));
        const bytes = self.allocator.dupe(u8, data) catch @panic("out of memory");
        self.sends.append(self.allocator, .{ .bytes = bytes, .to = if (to) |address| address.* else null, .flags = flags }) catch @panic("out of memory");
    }

    fn get(context: *anyopaque, buffer: []u8, sender: *message.Address) anyerror!usize {
        const self: *Driver = @ptrCast(@alignCast(context));
        if (self.next == self.incoming.len) return 0;
        const packet = self.incoming[self.next].object;
        self.next += 1;
        _ = try std.fmt.hexToBytes(sender, packet.get("sender").?.string);
        return (try std.fmt.hexToBytes(buffer, packet.get("bytes").?.string)).len;
    }

    fn close(context: *anyopaque) void {
        const self: *Driver = @ptrCast(@alignCast(context));
        if (self.game) |game| game.note("close", .{});
    }
};

pub const Opener = struct {
    driver: *Driver,
    game: *Game,
    address: message.Address = message.no_address,
    fail: bool = false,

    pub fn provider(self: *Opener) network_layer.Provider {
        return .{ .context = self, .open = open };
    }

    fn open(context: *anyopaque, hosting: bool, name: []const u8, player: []const u8, address: *message.Address) anyerror!network_layer.Driver {
        const self: *Opener = @ptrCast(@alignCast(context));
        self.game.note("open {d} {s}|{s}", .{ @intFromBool(hosting), name, player });
        if (self.fail) return error.ReferenceDriverCannotOpen;
        address.* = self.address;
        return self.driver.session();
    }
};

pub const Game = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList([]u8) = .empty,
    router: ?*router_module.Router = null,
    left_text: []const u8 = "",

    pub fn deinit(self: *Game) void {
        self.clear();
        self.calls.deinit(self.allocator);
    }

    pub fn clear(self: *Game) void {
        for (self.calls.items) |call| self.allocator.free(call);
        self.calls.clearRetainingCapacity();
    }

    pub fn hooks(self: *Game) router_module.Game {
        return .{ .context = self, .players = players, .addClient = addClient, .removeClient = removeClient, .describe = describe, .scores = scores, .departed = departed, .connecting = connecting, .leave = leave, .local = local, .text = text, .forget = forget };
    }

    pub fn note(self: *Game, comptime format: []const u8, values: anytype) void {
        const line = std.fmt.allocPrint(self.allocator, format, values) catch @panic("out of memory");
        self.calls.append(self.allocator, line) catch @panic("out of memory");
    }

    pub fn expectCalls(self: *const Game, expected: []const std.json.Value) !void {
        var index: usize = 0;
        var buffer: [0x200]u8 = undefined;
        for (expected) |value| {
            const object = value.object;
            if (object.get("popup") != null or object.get("box") != null or object.get("log") != null) continue;
            const line = if (object.get("players") != null)
                "players"
            else if (object.get("describe") != null)
                "describe"
            else if (object.get("scores") != null)
                "scores"
            else if (object.get("connecting") != null)
                "connecting"
            else if (object.get("leave") != null)
                "leave"
            else if (object.get("local") != null)
                "local"
            else if (object.get("close") != null)
                "close"
            else if (object.get("add")) |client|
                try std.fmt.bufPrint(&buffer, "add {d}", .{client.integer})
            else if (object.get("remove")) |client|
                try std.fmt.bufPrint(&buffer, "remove {d}", .{client.integer})
            else if (object.get("text")) |id|
                try std.fmt.bufPrint(&buffer, "text {d}", .{id.integer})
            else if (object.get("announce")) |words|
                try std.fmt.bufPrint(&buffer, "announce {d} {s}", .{ object.get("to").?.integer, words.string })
            else if (object.get("open")) |open| blk: {
                const arguments = open.object;
                try std.testing.expectEqualStrings("LEC-OL-B22", arguments.get("tag").?.string);
                try std.testing.expectEqual(@as(i64, 0), arguments.get("last").?.integer);
                break :blk try std.fmt.bufPrint(&buffer, "open {d} {s}|{s}", .{ arguments.get("hosting").?.integer, arguments.get("name").?.string, arguments.get("player").?.string });
            } else return error.UnknownReferenceCall;
            try std.testing.expect(index < self.calls.items.len);
            try std.testing.expectEqualStrings(line, self.calls.items[index]);
            index += 1;
        }
        try std.testing.expectEqual(index, self.calls.items.len);
    }

    fn from(context: *anyopaque) *Game {
        return @ptrCast(@alignCast(context));
    }

    fn players(context: *anyopaque) anyerror!void {
        from(context).note("players", .{});
    }

    fn addClient(context: *anyopaque, client: u32) anyerror!void {
        from(context).note("add {d}", .{client});
    }

    fn removeClient(context: *anyopaque, client: u32) anyerror!void {
        from(context).note("remove {d}", .{client});
    }

    fn describe(context: *anyopaque) anyerror!void {
        from(context).note("describe", .{});
    }

    fn scores(context: *anyopaque) anyerror!void {
        from(context).note("scores", .{});
    }

    fn connecting(context: *anyopaque) anyerror!void {
        from(context).note("connecting", .{});
    }

    fn departed(context: *anyopaque, name: []const u8, destination: u32) anyerror!void {
        const self = from(context);
        self.note("text 5123", .{});
        const place = std.mem.indexOf(u8, self.left_text, "%s") orelse return error.MalformedReference;
        self.note("announce {d} {s}{s}{s}", .{ destination, self.left_text[0..place], name, self.left_text[place + 2 ..] });
    }

    fn leave(context: *anyopaque) anyerror!void {
        const self = from(context);
        self.note("leave", .{});
        self.router.?.close();
        self.router.?.dropQueued();
    }

    fn local(context: *anyopaque) anyerror!void {
        const self = from(context);
        self.note("local", .{});
        self.router.?.reset();
    }

    fn forget(_: *anyopaque, _: u32) anyerror!void {}

    fn text(context: *anyopaque, id: u32, buffer: []u8) void {
        from(context).note("text {d}", .{id});
        var made: [32]u8 = undefined;
        const value: []const u8 = switch (id) {
            7777 => return,
            5133 => "Outlaws 1.1 Required!",
            5119 => "INVALID PASSWORD!",
            else => std.fmt.bufPrint(&made, "Text {d}", .{id}) catch unreachable,
        };
        const length = @min(value.len, buffer.len);
        @memcpy(buffer[0..length], value[0..length]);
        if (length < buffer.len) buffer[length] = 0;
    }
};
