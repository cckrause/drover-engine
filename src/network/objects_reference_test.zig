//! The object number tables of a loaded level.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const database = @import("database.zig");
const Database = database.Database;

fn word(object: ?database.Object) u32 {
    const value = object orelse return 0;
    return @intCast(value.actor);
}

fn field(object: std.json.ObjectMap, key: []const u8) u32 {
    return int(object.get(key).?);
}

fn int(value: std.json.Value) u32 {
    return @intCast(value.integer);
}

test "object number tables match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/network-objects-reference.json", a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("f71a8db8743d12a14317393148a0ade05e2f86d7d80a98d4a76f1bffa20a52d1", root.get("executable_sha256").?.string);

    var router = @import("router.zig").Router.init(a);
    defer router.deinit();
    var db = Database.init(a);
    defer db.deinit();
    var steps: usize = 0;
    for (root.get("ops").?.array.items) |item| {
        const op = item.object;
        const kind = op.get("op").?.string;
        errdefer std.debug.print("object reference step {d} ({s})\n", .{ steps, kind });
        steps += 1;
        if (std.mem.eql(u8, kind, "dump")) {
            var tables = op.get("tables").?.object.iterator();
            while (tables.next()) |pair| {
                const client = try std.fmt.parseInt(u8, pair.key_ptr.*, 10);
                const table = db.tables[client].?;
                for (pair.value_ptr.*.array.items, table) |expected, entry| {
                    try std.testing.expectEqual(int(expected.array.items[0]), word(entry.object));
                    try std.testing.expectEqual(int(expected.array.items[1]), entry.freed);
                }
            }
            continue;
        }
        const checks = op.get("checks").?.array.items.len;
        if (std.mem.eql(u8, kind, "reset")) {
            try db.reset(&router);
        } else if (std.mem.eql(u8, kind, "give")) {
            const result = db.give(field(op, "own"), .{ .actor = field(op, "object") });
            if (checks != 0) {
                try std.testing.expectError(error.ObjectNumbersExhausted, result);
            } else try std.testing.expectEqual(field(op, "result"), try result);
        } else if (std.mem.eql(u8, kind, "free")) {
            db.free(field(op, "number"), field(op, "clock"));
        } else if (std.mem.eql(u8, kind, "set")) {
            const object = field(op, "object");
            db.set(field(op, "number"), if (object == 0) null else .{ .actor = object }, field(op, "clock"));
        } else if (std.mem.eql(u8, kind, "get")) {
            const client: u32 = field(op, "client");
            try std.testing.expectEqual(field(op, "result"), word(db.find(client << 11 | field(op, "index"))));
        } else return error.MalformedReference;
        if (!std.mem.eql(u8, kind, "give")) try std.testing.expectEqual(@as(usize, 0), checks);
        var made: usize = 0;
        for (db.tables, 0..) |table, client| if (table != null) {
            try std.testing.expectEqual(int(op.get("tables").?.array.items[made]), client);
            made += 1;
        };
        try std.testing.expectEqual(op.get("tables").?.array.items.len, made);
        var last = op.get("last").?.object.iterator();
        while (last.next()) |pair| try std.testing.expectEqual(int(pair.value_ptr.*), db.last[try std.fmt.parseInt(u8, pair.key_ptr.*, 10)]);
    }
    try std.testing.expectEqual(@as(usize, 2074), steps);
}
