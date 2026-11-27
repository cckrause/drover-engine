//! Finding input driver plug-ins in the game's folder, so the options pages
//! know which controls buttons to offer.
//!
//! A library counts as a driver when its string table marks it as an
//! extension driver of the asked-for category; its display name is taken
//! from the same table. The PE string table is read directly instead of
//! loading the library. With no readable folder nothing is found, which
//! leaves the controls buttons disabled.

const std = @import("std");

pub fn names(
    a: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    category: []const u8,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer free(a, result.items);
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();

    while (try iterator.next(io)) |file| {
        if (file.kind != .file or !std.ascii.endsWithIgnoreCase(file.name, ".DLL")) continue;

        const bytes = try dir.readFileAlloc(io, file.name, a, .limited(64 * 1024 * 1024));
        defer a.free(bytes);
        var signature: [120]u8 = undefined;
        var kind: [120]u8 = undefined;
        var name: [120]u8 = undefined;

        if (!std.mem.eql(
            u8,
            try loadString(bytes, 1000, &signature),
            "LEC EXTENSION DRIVER",
        )) continue;

        if (!std.mem.eql(u8, try loadString(bytes, 1010, &kind), category)) continue;

        const text = try loadString(bytes, 1020, &name);
        try result.append(a, try a.dupe(u8, text));
    }

    return result.toOwnedSlice(a);
}

pub fn free(a: std.mem.Allocator, list: []const []const u8) void {
    for (list) |name| a.free(name);
    a.free(list);
}

fn loadString(image: []const u8, id: u16, buffer: *[120]u8) ![]const u8 {
    const block = (try resource(image, 6, (id >> 4) + 1)) orelse return buffer[0..0];
    var at: usize = 0;
    var index: u16 = 0;

    while (true) : (index += 1) {
        if (at + 2 > block.len) return error.InvalidStringTable;

        const length = std.mem.readInt(u16, block[at..][0..2], .little);

        at += 2;
        if (at + @as(usize, length) * 2 > block.len) return error.InvalidStringTable;
        if (index == id & 15) {
            if (length >= buffer.len) return error.DriverStringTooLong;

            for (0..length) |i| {
                const unit = std.mem.readInt(u16, block[at + i * 2 ..][0..2], .little);
                if (unit == 0 or unit > 0x7f) return error.UnsupportedDriverString;
                buffer[i] = @intCast(unit);
            }

            return buffer[0..length];
        }

        at += @as(usize, length) * 2;
        if (index == 15) return buffer[0..0];
    }
}

fn resource(image: []const u8, kind: u32, id: u32) !?[]const u8 {
    if (image.len < 0x40 or !std.mem.eql(u8, image[0..2], "MZ")) return error.InvalidDriverImage;

    const pe = read(u32, image, 0x3c) orelse return error.InvalidDriverImage;
    if (pe > image.len - 24 or !std.mem.eql(
        u8,
        image[pe..][0..4],
        "PE\x00\x00",
    )) return error.InvalidDriverImage;

    const sections = read(u16, image, pe + 6) orelse return error.InvalidDriverImage;
    const optional_size = read(u16, image, pe + 20) orelse return error.InvalidDriverImage;
    const optional = pe + 24;
    if ((read(u16, image, optional) orelse 0) != 0x10b) return error.InvalidDriverImage;
    if (optional_size < 96 + 3 * 8) return null;

    const root_rva = read(u32, image, optional + 96 + 2 * 8) orelse return error.InvalidDriverImage;
    if (root_rva == 0) return null;

    const Mapper = struct {
        image: []const u8,
        table: usize,
        count: u16,

        fn offset(self: @This(), rva: u32) !usize {
            for (0..self.count) |i| {
                const header = self.table + i * 40;
                const size = read(
                    u32,
                    self.image,
                    header + 8,
                ) orelse return error.InvalidDriverImage;

                const virtual = read(
                    u32,
                    self.image,
                    header + 12,
                ) orelse return error.InvalidDriverImage;

                const raw = read(
                    u32,
                    self.image,
                    header + 20,
                ) orelse return error.InvalidDriverImage;

                if (rva >= virtual and rva - virtual < size) return raw + (rva - virtual);
            }

            return error.InvalidDriverImage;
        }
    };

    const mapper = Mapper{ .image = image, .table = optional + optional_size, .count = sections };
    const root = try mapper.offset(root_rva);
    const by_type = (try subdirectory(image, root, root, kind)) orelse return null;
    const by_id = (try subdirectory(image, root, by_type, id)) orelse return null;
    const languages = by_id;
    if (read(u16, image, languages + 14) == null) return error.InvalidDriverImage;
    if ((read(
        u16,
        image,
        languages + 12,
    ) orelse 0) + (read(u16, image, languages + 14) orelse 0) == 0) return null;

    const leaf = read(u32, image, languages + 16 + 4) orelse return error.InvalidDriverImage;
    if (leaf & 0x80000000 != 0) return error.InvalidDriverImage;

    const data = root + leaf;
    const data_rva = read(u32, image, data) orelse return error.InvalidDriverImage;
    const size = read(u32, image, data + 4) orelse return error.InvalidDriverImage;
    const start = try mapper.offset(data_rva);
    if (start > image.len or size > image.len - start) return error.InvalidDriverImage;

    return image[start..][0..size];
}

fn subdirectory(image: []const u8, root: usize, directory: usize, id: u32) !?usize {
    const named = read(u16, image, directory + 12) orelse return error.InvalidDriverImage;
    const ids = read(u16, image, directory + 14) orelse return error.InvalidDriverImage;

    for (named..@as(usize, named) + ids) |i| {
        const at = directory + 16 + i * 8;
        const name = read(u32, image, at) orelse return error.InvalidDriverImage;
        const target = read(u32, image, at + 4) orelse return error.InvalidDriverImage;
        if (name == id) {
            if (target & 0x80000000 == 0) return error.InvalidDriverImage;
            return root + (target & 0x7fffffff);
        }
    }

    return null;
}

fn read(comptime T: type, bytes: []const u8, offset: usize) ?T {
    if (offset > bytes.len or bytes.len - offset < @sizeOf(T)) return null;

    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "the CD's input drivers name themselves Joystick, Keyboard and Mouse" {
    const a = std.testing.allocator;
    const list = names(
        a,
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS",
        "LEC INPUT DRIVER",
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer free(a, list);
    var found: [3]bool = @splat(false);

    for (list) |name| {
        for ([_][]const u8{
            "Joystick",
            "Keyboard",
            "Mouse",
        }, &found) |expected, *seen| if (std.mem.eql(u8, name, expected)) {
            seen.* = true;
        };
    }

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expect(found[0] and found[1] and found[2]);
}
