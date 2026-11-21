//! The settings file next to the executable: one section per key path, then
//! `name=value` lines. It stands in for the registry the game used.
//!
//! The file is only written when a value changed since the last load or
//! save.

const std = @import("std");
const Store = @import("../settings.zig").Store;

pub const file_name = "REGISTRY.INI";

pub fn path(a: std.mem.Allocator, io: std.Io) ![]u8 {
    const directory = try std.process.executableDirPathAlloc(io, a);
    defer a.free(directory);
    return std.fs.path.join(a, &.{ directory, file_name });
}

pub fn load(a: std.mem.Allocator, io: std.Io, store: *Store) !void {
    const file = try path(a, io);
    defer a.free(file);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer a.free(bytes);
    try parse(store, bytes);
    store.dirty = false;
}

pub fn parse(store: *Store, bytes: []const u8) !void {
    var section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSettingsFile;
            section = line[1 .. line.len - 1];
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSettingsFile;
        const prefix = section orelse return error.InvalidSettingsFile;
        var key: [512]u8 = undefined;
        const joined = std.fmt.bufPrint(&key, "{s}\\{s}", .{ prefix, line[0..equals] }) catch return error.InvalidSettingsFile;
        try store.put(joined, line[equals + 1 ..]);
    }
}

pub fn save(a: std.mem.Allocator, io: std.Io, store: *Store) !void {
    if (!store.dirty) return;
    const file = try path(a, io);
    defer a.free(file);
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try format(store, &text.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = text.written() });
    store.dirty = false;
}

pub fn format(store: *const Store, writer: *std.Io.Writer) !void {
    var previous: ?[]const u8 = null;
    for (store.entries.items) |entry| {
        const split = std.mem.lastIndexOfScalar(u8, entry.key, '\\') orelse return error.InvalidSettingText;
        const section = entry.key[0..split];
        if (previous == null or !std.ascii.eqlIgnoreCase(previous.?, section)) {
            try writer.print("[{s}]\n", .{section});
            previous = section;
        }
        try writer.print("{s}={s}\n", .{ entry.key[split + 1 ..], entry.value });
    }
}

test "settings file round trip" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    try parse(&store, "[v1.0]\r\nView Box=9\nGamma=-2\n[Users\\Default User\\SOUND]\nMaster Volume=100\n");
    try std.testing.expectEqualStrings("9", (try store.read(null, null, "View Box")).?);
    try std.testing.expectEqualStrings("100", (try store.read("", "SOUND", "Master Volume")).?);
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try format(&store, &text.writer);
    try std.testing.expectEqualStrings("[v1.0]\nView Box=9\nGamma=-2\n[Users\\Default User\\SOUND]\nMaster Volume=100\n", text.written());
    try std.testing.expectError(error.InvalidSettingsFile, parse(&store, "View Box=9\n"));
}
