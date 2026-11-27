//! The start-up requests single player sends to its own server.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const message = @import("message.zig");
const Router = @import("router.zig").Router;
const server_module = @import("server.zig");

fn expectServer(want: std.json.ObjectMap, server: *const server_module.Server) !void {
    var record: [@sizeOf(message.GameRecord)]u8 = undefined;
    _ = try std.fmt.hexToBytes(&record, want.get("record").?.string);
    try std.testing.expectEqualSlices(u8, &record, std.mem.asBytes(&server.record));
    for (server.starts, want.get("starts").?.array.items) |start, json| {
        for (start, json.array.items) |value, want_value| try std.testing.expectEqual(@as(u32, @intCast(want_value.integer)), value);
    }
    try std.testing.expectEqual(int(want, "start_count"), server.start_count);
    try std.testing.expectEqual(int(want, "red_start"), server.red_start);
    try std.testing.expectEqual(int(want, "blue_start"), server.blue_start);
    try std.testing.expectEqual(int(want, "gate"), server.completion_gate.last);
    try std.testing.expectEqual(int(want, "first_start_request"), server.first_start_request);
    try std.testing.expectEqual(int(want, "started") != 0, server.started);
    try std.testing.expectEqual(int(want, "new_it_gate"), server.new_it_gate);
    try std.testing.expectEqual(int(want, "tail_due"), server.tail_due);
    for (server.configuration.options, want.get("configuration").?.array.items) |option, value| try std.testing.expectEqual(value.integer != 0, option);
    try std.testing.expectEqual(int(want, "configuration_flags"), server.configuration.flags);
}

fn int(object: std.json.ObjectMap, key: []const u8) u32 {
    return @intCast(object.get(key).?.integer);
}

fn hex(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try a.alloc(u8, text.len / 2);
    errdefer a.free(out);
    _ = try std.fmt.hexToBytes(out, text);
    return out;
}

test "single-player start-up requests match the reference server" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/network-startup-reference.json", a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("f71a8db8743d12a14317393148a0ade05e2f86d7d80a98d4a76f1bffa20a52d1", root.get("executable_sha256").?.string);

    var router = Router.init(a);
    defer router.deinit();
    var server: server_module.Server = .{};
    var game_type: u32 = 0;
    var mode: u32 = 0;
    var loaded = false;
    var user_messages_buffer: server_module.UserMessageBuffer = undefined;
    var user_messages = server_module.UserMessages.init(&user_messages_buffer);
    var stopped = false;
    for (root.get("ops").?.array.items) |item| {
        const op = item.object;
        const kind = op.get("op").?.string;
        if (std.mem.eql(u8, kind, "reset")) {
            router.reset();
            server.reset();
            try expectServer(op.get("server").?.object, &server);
        } else if (std.mem.eql(u8, kind, "clear")) {
            for (0..16) |queue| while (try router.read(@intCast(queue))) |taken| router.release(taken);
        } else if (std.mem.eql(u8, kind, "setup")) {
            game_type = int(op, "game_type");
            router.own_client = int(op, "own");
            mode = int(op, "mode");
            loaded = op.get("loaded").?.bool;
            server.configuration.flags = int(op, "flags");
            server.password = @splat(0);
            const password = op.get("password").?.string;
            @memcpy(server.password[0..password.len], password);
            router.client_count = int(op, "count");
            router.dropped = op.get("dropped").?.bool;
        } else if (std.mem.eql(u8, kind, "game_info")) {
            var record: [@sizeOf(message.GameRecord)]u8 = undefined;
            _ = try std.fmt.hexToBytes(&record, op.get("record").?.string);
            const game_record: message.GameRecord = @bitCast(record);
            try server_module.postGameInfo(&router, &game_record);
        } else if (std.mem.eql(u8, kind, "request_game_info")) {
            try server_module.requestGameInfo(&router);
        } else if (std.mem.eql(u8, kind, "request_start")) {
            try server_module.requestStartPosition(&router, @intCast(op.get("args").?.array.items[0].integer));
        } else if (std.mem.eql(u8, kind, "set_start") or std.mem.eql(u8, kind, "add_start")) {
            var record: message.Start = undefined;
            for (&record, op.get("record").?.array.items) |*value, json| value.* = @intCast(json.integer);
            if (kind[0] == 's') try server_module.setStartPosition(&router, record) else try server_module.addStartPosition(&router, record);
        } else if (std.mem.eql(u8, kind, "raw")) {
            const raw = try hex(a, op.get("bytes").?.string);
            defer a.free(raw);
            _ = try router.post(int(op, "destination"), int(op, "number"), raw);
        } else if (std.mem.eql(u8, kind, "drain")) {
            const clock = int(op, "clock");
            const result = server_module.processRequests(&server, &router, .{ .now = clock, .game_type = game_type, .mode = mode, .level_loaded = loaded, .allocator = a, .user_messages = &user_messages });
            const reached = op.get("reached").?.array.items;
            if (op.get("checks").?.array.items.len != 0) {
                try std.testing.expectError(error.CorruptedGameRecordChecksum, result);
                stopped = true;
            } else if (reached.len != 0) {
                switch (reached[0].integer) {
                    0x47b8b0, 0x47e4d0 => try result,
                    0x462bd0 => try std.testing.expectError(error.NetworkGamePartNotPorted, result),
                    0x4640b0 => try std.testing.expectError(error.ServerTagNotPorted, result),
                    0x4dbf90 => try std.testing.expectError(error.ServerFlagCaptureNotPorted, result),
                    else => return error.MalformedReference,
                }
                try std.testing.expectEqual(int(op.get("server").?.object, "new_it_gate"), server.new_it_gate);
                continue;
            } else try result;
            try std.testing.expectEqual(@as(usize, 0), op.get("logs").?.array.items.len);
            for (op.get("seeds").?.array.items) |seed| try std.testing.expectEqual(clock, @as(u32, @intCast(seed.integer)));
            try expectServer(op.get("server").?.object, &server);
        } else if (std.mem.eql(u8, kind, "database")) {
            const expected = op.get("messages").?.array.items;
            if (stopped) {
                stopped = false;
                try std.testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.database));
                continue;
            }
            for (expected) |json| {
                const want = try hex(a, json.object.get("bytes").?.string);
                defer a.free(want);
                const got = (try router.read(message.Queue.database)).?;
                defer router.release(got);
                try std.testing.expectEqualSlices(u8, want, got);
                switch (message.get(got, message.number_offset)) {
                    0x406 => {
                        var record: message.GameRecord = @bitCast(@as([@sizeOf(message.GameRecord)]u8, @splat(0xa5)));
                        try message.readGameInfo(got, &record);
                        var unpacked: [@sizeOf(message.GameRecord)]u8 = undefined;
                        _ = try std.fmt.hexToBytes(&unpacked, json.object.get("unpacked").?.string);
                        try std.testing.expectEqualSlices(u8, &unpacked, std.mem.asBytes(&record));
                    },
                    0x407 => {
                        const start = try message.readStart(got);
                        for (start, json.object.get("unpacked").?.array.items) |value, want_value| try std.testing.expectEqual(@as(u32, @intCast(want_value.integer)), value);
                    },
                    0x404 => {},
                    else => return error.MalformedReference,
                }
            }
            try std.testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.database));
        } else return error.MalformedReference;
    }
}
