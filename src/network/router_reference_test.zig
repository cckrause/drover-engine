//! The router on one machine: queues, client numbers and message names.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const message = @import("message.zig");
const router_module = @import("router.zig");
const Router = router_module.Router;

fn int(object: std.json.ObjectMap, key: []const u8) u32 {
    return @intCast(object.get(key).?.integer);
}

fn hex(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try a.alloc(u8, text.len / 2);
    errdefer a.free(out);
    _ = try std.fmt.hexToBytes(out, text);
    return out;
}

test "router one-machine half and message names match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/network-router-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
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
    var taken: std.StringHashMapUnmanaged([]u8) = .empty;
    defer taken.deinit(a);
    for (root.get("ops").?.array.items) |item| {
        const op = item.object;
        const kind = op.get("op").?.string;
        if (std.mem.eql(u8, kind, "setup")) {
            router.own_client = int(op, "own");
            router.client_count = int(op, "count");
            router.reset_done = op.get("reset_done").?.bool;
            for (op.get("slots").?.array.items) |slot| {
                const index: u8 = @intCast(slot.integer);
                router.clients[index].address = @splat(0);
                router.clients[index].address[0] = index;
            }
        } else if (std.mem.eql(u8, kind, "reset")) {
            router.reset();
            const after = op.get("after").?.object;
            try std.testing.expectEqual(int(after, "own"), router.own_client);
            try std.testing.expectEqual(int(after, "count"), router.client_count);
            try std.testing.expectEqual(after.get("reset_done").?.bool, router.reset_done);
            var set: usize = 0;
            for (router.clients) |client| set += @intFromBool(!message.isNone(&client.address));
            try std.testing.expectEqual(after.get("set_slots").?.array.items.len, set);
        } else if (std.mem.eql(u8, kind, "post")) {
            const buffer = try hex(a, op.get("bytes").?.string);
            defer a.free(buffer);
            const destination = int(op, "destination");
            const posted = try router.post(destination, int(op, "number"), buffer);
            try std.testing.expectEqual(int(op, "result"), @intFromBool(posted != .queued));
            const logs = op.get("logs").?.array.items;
            try std.testing.expectEqual(posted == .invalid_client, logs.len == 1);
            if (posted == .invalid_client) {
                var text: [64]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&text, "Router_PostMessage: Invalid client id {d}.\n", .{message.client(destination)}), logs[0].string);
            }
            const after = try hex(a, op.get("after").?.string);
            defer a.free(after);
            try std.testing.expectEqualSlices(u8, after, buffer);
        } else if (std.mem.eql(u8, kind, "read")) {
            const got = try router.read(@intCast(int(op, "queue")));
            switch (op.get("bytes").?) {
                .null => try std.testing.expectEqual(@as(?[]u8, null), got),
                .string => |text| {
                    const expected = try hex(a, text);
                    defer a.free(expected);
                    try std.testing.expectEqualSlices(u8, expected, got.?);
                    try taken.put(a, op.get("name").?.string, got.?);
                },
                else => return error.MalformedReference,
            }
        } else if (std.mem.eql(u8, kind, "release")) {
            const before = router.taken.items.len;
            router.release(taken.get(op.get("name").?.string).?);
            try std.testing.expectEqual(int(op, "freed"), 2 * @as(u32, @intCast(before - router.taken.items.len)));
        } else return error.MalformedReference;
    }
    var buffer: [16]u8 = undefined;
    for (root.get("names").?.array.items) |item| {
        try std.testing.expectEqualStrings(item.object.get("name").?.string, message.name(int(item.object, "number"), &buffer));
    }
}
