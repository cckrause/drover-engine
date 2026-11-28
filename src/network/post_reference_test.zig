//! Posting to an object number, the repeat list, and what happens when a delivery fails.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const database = @import("database.zig");
const message = @import("message.zig");
const Router = @import("router.zig").Router;

fn post(
    db: *database.Database,
    router: *Router,
    objects: std.json.ObjectMap,
    names: []const []const u8,
    op: std.json.ObjectMap,
    now: u32,
) !void {
    var words: [4]u32 = undefined;

    for (op.get("words").?.array.items, &words) |word, *out| out.* = int(word);

    try db.post(
        router,
        party(objects, names, op.get("target").?),
        party(objects, names, op.get("sender").?),
        words,
        now,
    );
}

fn party(
    objects: std.json.ObjectMap,
    names: []const []const u8,
    value: std.json.Value,
) ?database.Party {
    if (value == .null) return null;

    const index = for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, value.string)) break i;
    } else unreachable;

    const record = objects.get(value.string).?.object;

    return .{ .object = switch (int(record.get("kind").?)) {
        0x10000 => .{ .wall = .{ .sector = index, .wall = 0 } },
        0x20000 => .{ .sector = index },
        0x40000 => .{ .actor = index },
        0x100000 => .{ .generator = index },
        else => unreachable,
    }, .number = int(record.get("number").?) };
}

fn sameName(
    objects: std.json.ObjectMap,
    names: []const []const u8,
    value: std.json.Value,
    object: ?database.Object,
) bool {
    const expected = party(objects, names, value) orelse return object == null;

    return object != null and std.meta.eql(expected.object, object.?);
}

fn int(value: std.json.Value) u32 {
    return @intCast(value.integer);
}

test "posts to objects and the repeat list match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/network-post-reference.json",
        a,
        .limited(1024 * 1024),
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

    router.reset();

    var db = database.Database.init(a);
    defer db.deinit();

    try db.reset(&router);

    var objects = root.get("objects").?.object;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    var keys = objects.iterator();

    while (keys.next()) |pair| try names.append(a, pair.key_ptr.*);

    for (names.items) |name| {
        const value = party(objects, names.items, .{ .string = name }).?;
        if (value.number != 0) db.set(value.number, value.object, 0);
    }

    for (root.get("ops").?.array.items, 0..) |item, step| {
        const op = item.object;
        errdefer std.debug.print("post reference step {d}\n", .{step});
        const kind = op.get("op").?.string;

        if (std.mem.eql(u8, kind, "start")) {
            try std.testing.expectEqual(
                @as(u32, if (db.repeats != null) 1 else 0),
                int(op.get("result").?),
            );

            db.startLinks();
        } else if (std.mem.eql(u8, kind, "stop")) {
            try std.testing.expectEqual(
                @as(u32, if (db.repeats == null) 1 else 0),
                int(op.get("result").?),
            );

            db.stopLinks();
        } else if (std.mem.eql(u8, kind, "number")) {
            const old = party(objects, names.items, op.get("object").?).?;
            db.set(old.number, null, 0);
            const number = op.get("number").?;
            objects.getPtr(op.get("object").?.string).?.object.getPtr("number").?.* = number;
            db.set(int(number), old.object, 0);
            continue;
        } else if (std.mem.eql(u8, kind, "post")) {
            db.repeating = int(op.get("repeat").?);
            try post(&db, &router, objects, names.items, op, int(op.get("now").?));
            const queued = op.get("queued").?;

            if (queued != .null) {
                for (queued.array.items) |expected| {
                    const got = (try router.read(message.Queue.database)).?;
                    defer router.release(got);
                    const want = try a.alloc(u8, expected.string.len / 2);
                    defer a.free(want);

                    _ = try std.fmt.hexToBytes(want, expected.string);
                    try std.testing.expectEqualSlices(u8, want, got);
                }

                try std.testing.expectEqual(
                    @as(?[]u8, null),
                    try router.read(message.Queue.database),
                );
            }
        } else if (std.mem.eql(u8, kind, "drain")) {
            const now = int(op.get("now").?);
            const injected = op.get("inject").?.array.items;
            var injection: usize = 0;

            for (op.get("calls").?.array.items) |expected| {
                const call = expected.object;
                const request = (try db.next(&router, true, now)).?;

                try std.testing.expectEqual(int(call.get("repeat").?), db.repeating);
                const target = party(objects, names.items, call.get("object").?).?.object;

                switch (request) {
                    .link => |link| {
                        try std.testing.expectEqualStrings("link", call.get("call").?.string);
                        try std.testing.expect(std.meta.eql(target, link.object));
                        try std.testing.expectEqual(int(call.get("code").?), link.code);

                        for (call.get(
                            "words",
                        ).?.array.items, link.words) |word, got| try std.testing.expectEqual(
                            int(word),
                            got,
                        );

                        try std.testing.expectEqual(int(call.get("event").?), link.words[0]);
                        try std.testing.expectEqual(
                            @as(u32, if (link.sender != null) 0 else 0xffffffff),
                            int(call.get("mask").?),
                        );

                        if (injection < injected.len) {
                            try post(
                                &db,
                                &router,
                                objects,
                                names.items,
                                injected[injection].object,
                                now,
                            );

                            injection += 1;
                        }
                    },
                    .actor => |actor| {
                        try std.testing.expectEqualStrings("actor", call.get("call").?.string);
                        try std.testing.expectEqual(target.actor, actor.index);
                        try std.testing.expectEqual(
                            int(call.get("number").?),
                            message.get(actor.bytes, message.number_offset),
                        );
                    },
                    .generator => |generator| {
                        try std.testing.expectEqualStrings("generator", call.get("call").?.string);
                        try std.testing.expectEqual(target.generator, generator.index);
                        try std.testing.expectEqual(int(call.get("code").?), generator.code);
                    },
                    else => return error.UnexpectedReferenceDelivery,
                }
            }

            try std.testing.expectEqual(injected.len, injection);
            try std.testing.expect(try db.next(&router, true, now) == null);
            try std.testing.expectEqual(@as(usize, 0), router.taken.count);
        } else return error.UnknownReferenceOperation;

        try std.testing.expectEqual(int(op.get("repeat_after").?), db.repeating);
        const list_value = op.get("list").?;

        if (list_value == .null) {
            try std.testing.expect(db.repeats == null);
            continue;
        }

        const list = list_value.array.items;
        try std.testing.expectEqual(list.len, db.repeats.?.items.len);

        for (list, db.repeats.?.items) |expected, entry| {
            try std.testing.expect(
                sameName(objects, names.items, expected.object.get("target").?, entry.target),
            );

            try std.testing.expect(
                sameName(objects, names.items, expected.object.get("sender").?, entry.sender),
            );

            for (expected.object.get(
                "words",
            ).?.array.items, entry.words) |word, got| try std.testing.expectEqual(
                @as(u32, @intCast(word.integer)),
                got,
            );

            try std.testing.expectEqual(int(expected.object.get("time").?), entry.time);
        }
    }
}

test "failed object deliveries release their packet and restore the repeat flag" {
    var router = try Router.init(std.testing.allocator);
    defer router.deinit();

    router.reset();

    var db = database.Database.init(std.testing.allocator);
    defer db.deinit();

    try db.reset(&router);

    const sector = try db.give(router.own_client, .{ .sector = 0 });
    const generator = try db.give(router.own_client, .{ .generator = 0 });

    db.repeating = 7;

    for ([_]u32{ sector, generator }) |target| {
        var bytes = message.request(0x87d6, router.own_client);
        message.set(&bytes, message.reply_offset, target);
        _ = try router.post(target, .{ .code = message.Number.of(.trigger).code, .repeat = true }, &bytes);

        try std.testing.expectError(error.MalformedNetworkMessage, db.next(&router, true, 0));
        try std.testing.expectEqual(@as(u32, 7), db.repeating);
        try std.testing.expect(db.repeat_previous == null);
        try std.testing.expectEqual(@as(usize, 0), router.taken.count);
    }

    var request = message.request(0x8402, router.own_client);
    message.set(&request, message.reply_offset, sector);
    _ = try router.post(sector, .{ .code = 0x402, .repeat = true }, &request);

    try std.testing.expectError(error.ObjectRequestNotPorted, db.next(&router, true, 0));
    try std.testing.expectEqual(@as(u32, 7), db.repeating);
    try std.testing.expect(db.repeat_previous == null);
    try std.testing.expectEqual(@as(usize, 0), router.taken.count);
}
