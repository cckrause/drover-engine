//! How object messages are dispatched through the object database.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const message = @import("message.zig");
const database = @import("database.zig");
const Router = @import("router.zig").Router;

fn nameOf(named: anytype, object: database.Object) []const u8 {
    for (named) |entry| if (std.meta.eql(entry.object, object)) return entry.name;
    return "?";
}

fn int(object: std.json.ObjectMap, key: []const u8) u32 {
    return @intCast(object.get(key).?.integer);
}

test "object messages are dispatched as the reference database does" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/network-dispatch-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("f71a8db8743d12a14317393148a0ade05e2f86d7d80a98d4a76f1bffa20a52d1", root.get("executable_sha256").?.string);

    var router = try Router.init(a);
    defer router.deinit();
    router.reset();
    var db = database.Database.init(a);
    defer db.deinit();
    try db.reset(&router);
    const Named = struct {
        name: []const u8,
        object: database.Object,
        mask: u32,
    };
    var named: std.ArrayList(Named) = .empty;
    defer named.deinit(a);
    var objects = root.get("objects").?.object.iterator();
    var index: usize = 0;
    while (objects.next()) |pair| : (index += 1) {
        const kind = int(pair.value_ptr.object, "kind");
        const object: database.Object = switch (kind) {
            0x10000 => .{ .wall = .{ .sector = index, .wall = index + 1 } },
            0x20000 => .{ .sector = index },
            0x40000 => .{ .actor = index },
            0x100000 => .{ .generator = index },
            else => return error.MalformedReference,
        };
        db.set(int(pair.value_ptr.object, "number"), object, 0);
        try named.append(a, .{ .name = pair.key_ptr.*, .object = object, .mask = int(pair.value_ptr.object, "mask") });
    }
    db.repeating = 7;

    for (root.get("ops").?.array.items) |item| {
        const op = item.object;
        if (std.mem.eql(u8, op.get("op").?.string, "post")) {
            var buffer: [message.words_size]u8 = @splat(0);
            message.set(&buffer, message.sender_offset, int(op, "sender"));
            message.set(&buffer, message.reply_offset, int(op, "target"));
            message.set(&buffer, message.number_offset, int(op, "number"));
            for (op.get("words").?.array.items, message.word_offsets) |word, offset| message.set(&buffer, offset, @intCast(word.integer));
            const posted = try router.post(int(op, "destination"), int(op, "number"), buffer[0..int(op, "size")]);
            try std.testing.expectEqual(int(op, "result"), @intFromBool(posted != .queued));
            continue;
        }
        const calls = op.get("calls").?.array.items;
        var call: usize = 0;
        while (try db.next(&router, op.get("loaded").?.bool, int(op, "now"))) |request| : (call += 1) {
            const expected = calls[call].object;
            const kind = expected.get("call").?.string;
            try std.testing.expectEqual(int(expected, "repeat"), db.repeating);
            switch (request) {
                .link => |link| {
                    try std.testing.expectEqualStrings("link", kind);
                    try std.testing.expectEqualStrings(expected.get("object").?.string, nameOf(named.items, link.object));
                    try std.testing.expectEqual(int(expected, "code"), link.code);
                    for (expected.get("words").?.array.items, link.words) |word, got| try std.testing.expectEqual(@as(u32, @intCast(word.integer)), got);
                    try std.testing.expectEqual(int(expected, "event"), link.words[0]);
                    const mask = if (link.sender) |sender| for (named.items) |entry| {
                        if (entry.object == .actor and entry.object.actor == sender) break entry.mask;
                    } else unreachable else 0xffffffff;
                    try std.testing.expectEqual(int(expected, "mask"), mask);
                },
                .bits => |link| {
                    try std.testing.expectEqualStrings(if (link.object == .wall) "wall_dirty" else "sector_dirty", kind);
                    try std.testing.expectEqualStrings(expected.get("object").?.string, nameOf(named.items, link.object));
                },
                .actor => |actor| {
                    try std.testing.expectEqualStrings("actor", kind);
                    try std.testing.expectEqualStrings(expected.get("object").?.string, nameOf(named.items, .{ .actor = actor.index }));
                    try std.testing.expectEqual(int(expected, "number"), message.get(actor.bytes, message.number_offset));
                },
                .generator => |generator| {
                    try std.testing.expectEqualStrings("generator", kind);
                    try std.testing.expectEqualStrings(expected.get("object").?.string, nameOf(named.items, .{ .generator = generator.index }));
                    try std.testing.expectEqual(int(expected, "code"), generator.code);
                },
                else => return error.UnexpectedRequest,
            }
        }
        try std.testing.expectEqual(calls.len, call);
        try std.testing.expectEqual(int(op, "repeat"), db.repeating);
        for (op.get("throttle").?.array.items, db.requests) |pair, entry| {
            try std.testing.expectEqual(@as(u32, @intCast(pair.array.items[0].integer)), entry.due);
            try std.testing.expectEqual(@as(u32, @intCast(pair.array.items[1].integer)), entry.number);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), router.taken.count);
}
