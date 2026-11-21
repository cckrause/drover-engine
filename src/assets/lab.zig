//! LAB archives: the container every other asset is read out of.
//!
//! A directory of uppercase names with a type tag and a hash. Lookup walks
//! the entries in archive order and takes the first match, so a duplicate
//! name later in the archive is unreachable. Patch archives are searched
//! before the base archive, highest patch number first.

const std = @import("std");

pub const Archive = struct {
    data: []const u8,
    entries: []const u8,
    strings: []const u8,
    front: []const Archive = &.{},

    pub const Entry = struct { name: []const u8, resource_type: u32, bytes: []const u8 };

    pub const Iterator = struct {
        archive: Archive,
        cursor: usize = 0,

        pub fn next(self: *Iterator) !?Entry {
            if (self.cursor == self.archive.entries.len) return null;
            const record = self.archive.entries[self.cursor..][0..16];
            self.cursor += 16;
            const offset: usize = read32(record, 4);
            const size: usize = read32(record, 8);
            return .{
                .name = try self.archive.entryName(record),
                .resource_type = read32(record, 12),
                .bytes = self.archive.data[offset..][0..size],
            };
        }
    };

    pub fn iterator(self: Archive) Iterator {
        return .{ .archive = self };
    }

    pub fn init(data: []const u8) !Archive {
        if (data.len < 16) return error.TruncatedArchive;
        if (!std.mem.eql(u8, data[0..4], "LABN")) return error.InvalidArchive;
        if (read32(data, 4) > 0x10000) return error.UnsupportedArchiveVersion;

        const count: usize = read32(data, 8);
        const strings_size: usize = read32(data, 12);
        const strings_start = 16 + count * 16;

        if (count > (data.len - 16) / 16) return error.TruncatedArchive;

        if (strings_size > data.len - strings_start) return error.TruncatedArchive;

        const archive: Archive = .{
            .data = data,
            .entries = data[16..strings_start],
            .strings = data[strings_start..][0..strings_size],
        };
        var cursor: usize = 0;

        while (cursor < archive.entries.len) : (cursor += 16) {
            const entry = archive.entries[cursor..][0..16];
            _ = try archive.entryName(entry);

            const offset: usize = read32(entry, 4);
            const size: usize = read32(entry, 8);

            if (offset > data.len or size > data.len - offset)
                return error.TruncatedArchive;
        }

        return archive;
    }

    pub fn find(self: Archive, name: []const u8, resource_type: u32) ![]const u8 {
        for (self.front) |patch| return patch.findHere(name, resource_type) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };
        return self.findHere(name, resource_type);
    }

    fn findHere(self: Archive, name: []const u8, resource_type: u32) ![]const u8 {
        const wanted_hash = nameHash(name);
        var cursor: usize = 0;
        while (cursor < self.entries.len) : (cursor += 16) {
            const entry = self.entries[cursor..][0..16];
            const stored_type = read32(entry, 12);
            if (resource_type != 0 and stored_type != 0 and stored_type != resource_type)
                continue;
            const stored_name = try self.entryName(entry);
            if (nameHash(stored_name) != wanted_hash or
                !std.ascii.eqlIgnoreCase(stored_name, name)) continue;

            const offset: usize = read32(entry, 4);
            const size: usize = read32(entry, 8);
            return self.data[offset..][0..size];
        }
        return error.ResourceNotFound;
    }

    fn entryName(self: Archive, entry: []const u8) ![]const u8 {
        const offset: usize = read32(entry, 0);
        if (offset >= self.strings.len) return error.InvalidArchiveName;
        const tail = self.strings[offset..];
        const length = std.mem.indexOfScalar(u8, tail, 0) orelse
            return error.InvalidArchiveName;
        return tail[0..length];
    }
};

fn read32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn nameHash(name: []const u8) u32 {
    const length: u32 = @truncate(name.len);
    var hash = length | ((length << 16 | length) << 8) | (length << 16);
    for (name) |character| {
        hash = ((hash << 1) | (hash >> 31)) ^ std.ascii.toUpper(character);
    }
    return hash;
}

test "lookup preserves duplicate order, case and optional resource type" {
    var data = [_]u8{0} ** 81;
    @memcpy(data[0..4], "LABN");
    std.mem.writeInt(u32, data[4..8], 0x10000, .little);
    std.mem.writeInt(u32, data[8..12], 3, .little);
    std.mem.writeInt(u32, data[12..16], 14, .little);
    @memcpy(data[16..32], &[_]u8{ 0, 0, 0, 0, 78, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 });
    @memcpy(data[32..48], &[_]u8{ 0, 0, 0, 0, 79, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0 });
    @memcpy(data[48..64], &[_]u8{ 7, 0, 0, 0, 80, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(data[64..78], "a.pcx\x00\x00b.pcx\x00\x00");
    @memcpy(data[78..81], "123");
    const archive = try Archive.init(&data);
    try std.testing.expectEqualStrings("1", try archive.find("A.PCX", 0));
    try std.testing.expectEqualStrings("2", try archive.find("a.PcX", 2));
    try std.testing.expectEqualStrings("3", try archive.find("B.PCX", 0x50424d50));
    try std.testing.expectError(error.ResourceNotFound, archive.find("A.PCX", 3));
    try std.testing.expectError(error.ResourceNotFound, archive.find("C.PCX", 0));
}

test "patch archives in front are searched first, in their order" {
    var patch_data = [_]u8{0} ** 39;
    @memcpy(patch_data[0..4], "LABN");
    std.mem.writeInt(u32, patch_data[8..12], 1, .little);
    std.mem.writeInt(u32, patch_data[12..16], 6, .little);
    @memcpy(patch_data[16..32], &[_]u8{ 0, 0, 0, 0, 38, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(patch_data[32..39], "a.pcx\x00p");
    var data = [_]u8{0} ** 62;
    @memcpy(data[0..4], "LABN");
    std.mem.writeInt(u32, data[8..12], 2, .little);
    std.mem.writeInt(u32, data[12..16], 12, .little);
    @memcpy(data[16..32], &[_]u8{ 0, 0, 0, 0, 60, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(data[32..48], &[_]u8{ 6, 0, 0, 0, 61, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 });
    @memcpy(data[48..62], "a.pcx\x00b.pcx\x0012");
    const patch = try Archive.init(&patch_data);
    var archive = try Archive.init(&data);
    archive.front = &.{patch};
    try std.testing.expectEqualStrings("p", try archive.find("A.PCX", 0));
    try std.testing.expectEqualStrings("2", try archive.find("b.pcx", 0));
    try std.testing.expectError(error.ResourceNotFound, archive.find("C.PCX", 0));
}

test "directory, string and payload extents are validated before lookup" {
    var data = [_]u8{0} ** 34;
    @memcpy(data[0..4], "LABN");
    std.mem.writeInt(u32, data[8..12], 1, .little);
    std.mem.writeInt(u32, data[12..16], 2, .little);
    @memcpy(data[32..34], "a\x00");
    _ = try Archive.init(&data);

    std.mem.writeInt(u32, data[16..20], 2, .little);
    try std.testing.expectError(error.InvalidArchiveName, Archive.init(&data));
    std.mem.writeInt(u32, data[16..20], 0, .little);
    data[33] = 'b';
    try std.testing.expectError(error.InvalidArchiveName, Archive.init(&data));
    data[33] = 0;
    std.mem.writeInt(u32, data[20..24], 34, .little);
    std.mem.writeInt(u32, data[24..28], 1, .little);
    try std.testing.expectError(error.TruncatedArchive, Archive.init(&data));
    std.mem.writeInt(u32, data[8..12], 0xffffffff, .little);
    try std.testing.expectError(error.TruncatedArchive, Archive.init(&data));
}
