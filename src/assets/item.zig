//! ITEM resources: the text records describing pickups, weapons and the
//! other objects a level can place.
//!
//! Fields are prepended as they are read, so a lookup finds the *last*
//! matching definition first - shipped data relies on that. The declared
//! field count is advisory: a record may declare more fields than it has,
//! and a field whose value cannot be read stays empty instead of being
//! dropped. Unknown top-level directives are reported and skipped. All
//! strings belong to the arena passed in.

const std = @import("std");

pub const Value = union(enum) { string: []const u8, integer: i32, float: f32 };

pub const Field = struct { name: []const u8, value: Value };

pub const Item = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    function: []const u8,
    animation: []const u8,
    fields: []Field,
    ignored_directives: [][]const u8,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Item {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var lines = Lines{ .bytes = bytes };
        if (!std.mem.eql(u8, try lines.next() orelse return error.MissingItemHeader, "ITEM 1.0")) return error.UnsupportedItemVersion;
        var name: []const u8 = "";
        var function: []const u8 = "";
        var animation: []const u8 = "";
        var fields = std.array_list.Managed(Field).init(a);
        var ignored = std.array_list.Managed([]const u8).init(a);
        while (try lines.next()) |line| {
            var words = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = words.next().?;
            if (std.mem.eql(u8, key, "NAME")) {
                name = try upper(a, words.next() orelse return error.MissingItemName);
                if (name.len > 32) return error.ItemNameTooLong;
            } else if (std.mem.eql(u8, key, "FUNC")) {
                const value = words.next() orelse return error.MissingItemFunction;
                function = if (std.ascii.eqlIgnoreCase(value, "NULL")) "" else try a.dupe(u8, value);
                if (function.len > 32) return error.ItemFunctionTooLong;
            } else if (std.mem.eql(u8, key, "ANIM")) {
                if (words.next()) |value| {
                    animation = if (std.ascii.eqlIgnoreCase(value, "NULL")) "" else try upper(a, value);
                    if (animation.len > 32) return error.ItemAnimationTooLong;
                }
            } else if (std.mem.eql(u8, key, "DATA")) {
                var count = try std.fmt.parseInt(u32, words.next() orelse return error.MissingItemDataCount, 10);
                while (count != 0) {
                    const data_line = try lines.next() orelse break;
                    const field = try parseField(a, data_line) orelse {
                        try ignored.append(try a.dupe(u8, data_line));
                        continue;
                    };
                    try fields.append(field);
                    count -= 1;
                }
            } else {
                try ignored.append(try a.dupe(u8, line));
            }
        }
        const owned_fields = try fields.toOwnedSlice();
        const ignored_directives = try ignored.toOwnedSlice();
        return .{ .arena = arena, .name = name, .function = function, .animation = animation, .fields = owned_fields, .ignored_directives = ignored_directives };
    }

    pub fn deinit(self: *Item) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Item, name: []const u8) ?Value {
        var i = self.fields.len;
        while (i != 0) {
            i -= 1;
            if (std.ascii.eqlIgnoreCase(self.fields[i].name, name)) return self.fields[i].value;
        }
        return null;
    }

    pub fn floatValue(self: *const Item, name: []const u8) ?f32 {
        const value = self.get(name) orelse return null;
        return switch (value) {
            .float => |number| number,
            else => 0,
        };
    }

    pub fn intValue(self: *const Item, name: []const u8) ?i32 {
        const value = self.get(name) orelse return null;
        return switch (value) {
            .integer => |number| number,
            else => 0,
        };
    }

    pub fn stringValue(self: *const Item, name: []const u8) !?[]const u8 {
        const value = self.get(name) orelse return null;
        return switch (value) {
            .string => |string| string,
            else => error.ItemFieldIsNotString,
        };
    }
};

pub const Lines = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn next(self: *Lines) !?[]const u8 {
        while (self.offset < self.bytes.len) {
            const start = self.offset;
            const end = std.mem.indexOfScalarPos(u8, self.bytes, start, '\n') orelse self.bytes.len;
            self.offset = if (end < self.bytes.len) end + 1 else end;
            if (end - start > 254) return error.AssetLineTooLong;
            const line = std.mem.trim(u8, self.bytes[start..end], " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            return line;
        }
        return null;
    }
};

fn parseField(a: std.mem.Allocator, line: []const u8) !?Field {
    var entry = std.mem.tokenizeAny(u8, line, " \t\r");
    const kind = entry.next() orelse return null;
    const name = entry.next() orelse return null;
    const raw = entry.next() orelse return null;
    const value: Value = if (std.mem.eql(u8, kind, "STR"))
        .{ .string = try upper(a, raw) }
    else if (std.mem.eql(u8, kind, "INT"))
        .{ .integer = std.fmt.parseInt(i32, raw, 10) catch return null }
    else if (std.mem.eql(u8, kind, "FLOAT"))
        .{ .float = parseFloat(raw) catch |err| switch (err) {
            error.InvalidCharacter => return null,
            else => return err,
        } }
    else
        return null;
    return .{ .name = try upper(a, name), .value = value };
}

fn upper(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    const result = try a.dupe(u8, value);
    for (result) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return result;
}

fn parseFloat(raw: []const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, raw);
    if (!std.math.isFinite(value)) return error.InvalidItemFloat;
    return value;
}

test "CIDJAMES metadata retains default-height distinction" {
    const a = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB", a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(data);
    const archive = try @import("lab.zig").Archive.init(data);
    var item = try Item.parse(a, try archive.find("cidjames.itm", 0x4954454d));
    defer item.deinit();
    try std.testing.expectEqualStrings("JAMES", item.name);
    try std.testing.expectEqual(@as(usize, 42), item.fields.len);
    try std.testing.expectEqual(@as(?f32, null), item.floatValue("HEIGHT"));
    try std.testing.expectEqual(@as(?f32, 0.5), item.floatValue("HEAD_HEIGHT"));
    try std.testing.expectEqualStrings("JAMES.NWX", (try item.stringValue("PLAYER_WAX")).?);
}

test "ITEM loader leaves empty STR and unknown DATA records absent" {
    const a = std.testing.allocator;
    const fixture = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/item-loader-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(fixture);
    const json = try std.json.parseFromSlice(std.json.Value, a, fixture, .{});
    defer json.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD2/OUTLAWS/OLOBJ.LAB", a, .limited(32 * 1024 * 1024));
    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);
    for (json.value.object.get("cases").?.array.items) |case| {
        var item = try Item.parse(a, try archive.find(case.object.get("name").?.string, 0));
        defer item.deinit();
        try std.testing.expectEqualStrings(case.object.get("item_name").?.string, item.name);
        try std.testing.expectEqualStrings(case.object.get("function").?.string, item.function);
        try std.testing.expectEqualStrings(case.object.get("animation").?.string, item.animation);
        const fields = case.object.get("fields").?.array.items;
        try std.testing.expectEqual(fields.len, item.fields.len);
        for (fields, item.fields) |expected, actual| {
            try std.testing.expectEqualStrings(expected.object.get("name").?.string, actual.name);
            switch (actual.value) {
                .string => |value| {
                    try std.testing.expectEqual(@as(i64, 1), expected.object.get("kind").?.integer);
                    try std.testing.expectEqualStrings(expected.object.get("string").?.string, value);
                },
                .integer => |value| {
                    try std.testing.expectEqual(@as(i64, 4), expected.object.get("kind").?.integer);
                    try std.testing.expectEqual(expected.object.get("integer").?.integer, value);
                },
                .float => |value| {
                    try std.testing.expectEqual(@as(i64, 2), expected.object.get("kind").?.integer);
                    try std.testing.expectEqual(@as(u32, @intCast(expected.object.get("bits").?.integer)), @as(u32, @bitCast(value)));
                },
            }
        }
    }
}
