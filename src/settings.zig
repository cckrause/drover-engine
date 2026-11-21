//! The settings store: named values under a key path, as plain text.
//!
//! Key paths are either the bare version key or a per-user path, where an
//! empty user name means the default user. Values are text whatever they
//! represent, so a reader parses and a writer formats. Every write marks the
//! store dirty for the host to save; see platform/settings.zig for the file
//! behind it.

const std = @import("std");

pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    dirty: bool = false,

    pub const Entry = struct { key: []u8, value: []u8 };

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn path(buffer: []u8, user: ?[]const u8, section: ?[]const u8, name: []const u8) ![]const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        if (user) |who| {
            try writer.writeAll("Users\\");
            try writer.writeAll(if (who.len == 0) "Default User" else who);
        } else try writer.writeAll("v1.0");
        if (section) |part| {
            try writer.writeAll("\\");
            try writer.writeAll(part);
        }
        try writer.writeAll("\\");
        try writer.writeAll(name);
        return writer.buffered();
    }

    pub fn read(self: *const Store, user: ?[]const u8, section: ?[]const u8, name: []const u8) !?[]const u8 {
        var buffer: [512]u8 = undefined;
        return self.get(try path(&buffer, user, section, name));
    }

    pub fn write(self: *Store, user: ?[]const u8, section: ?[]const u8, name: []const u8, value: []const u8) !void {
        var buffer: [512]u8 = undefined;
        try self.put(try path(&buffer, user, section, name), value);
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| if (std.ascii.eqlIgnoreCase(entry.key, key)) return entry.value;
        return null;
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) !void {
        if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null or std.mem.indexOfAny(u8, key, "\r\n\x00=") != null)
            return error.InvalidSettingText;
        const copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(copy);
        self.dirty = true;
        for (self.entries.items) |*entry| if (std.ascii.eqlIgnoreCase(entry.key, key)) {
            self.allocator.free(entry.value);
            entry.value = copy;
            return;
        };
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try self.entries.append(self.allocator, .{ .key = key_copy, .value = copy });
    }
};

pub fn atoi(text: []const u8) i32 {
    var at: usize = 0;
    while (at < text.len and std.ascii.isWhitespace(text[at])) at += 1;
    var negative = false;
    if (at < text.len and (text[at] == '-' or text[at] == '+')) {
        negative = text[at] == '-';
        at += 1;
    }
    var value: i32 = 0;
    while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) value = value *% 10 +% (text[at] - '0');
    return if (negative) -%value else value;
}

pub fn keep(store: *Store, user: ?[]const u8, section: ?[]const u8, name: []const u8, default: []const u8, buffer: []u8) ![]const u8 {
    const text = (try store.read(user, section, name)) orelse default;
    if (text.len > buffer.len) return error.SettingTooLong;
    const copy = buffer[0..text.len];
    @memcpy(copy, text);
    try store.write(user, section, name, copy);
    return copy;
}

test "registry paths of the root and of a user's section" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("v1.0\\View Box", try Store.path(&buffer, null, null, "View Box"));
    try std.testing.expectEqualStrings("Users\\Default User\\SOUND\\Master Volume", try Store.path(&buffer, "", "SOUND", "Master Volume"));
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.write(null, null, "Gamma", "2");
    try store.write(null, null, "gamma", "3");
    try std.testing.expectEqualStrings("3", (try store.read(null, null, "Gamma")).?);
    try std.testing.expect(try store.read("", "SOUND", "Master Volume") == null);
}
