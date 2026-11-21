//! The compression a saved game's body uses: run-length pairs over a
//! 1024-byte window.
//!
//! A run of at least three bytes becomes a count with its high bit set plus
//! the value; other bytes become a count and the literals, exclusive-ored
//! with a constant. A run never crosses the window boundary.

const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    compressed: bool = false,
    block: [1024]u8 = undefined,
    used: usize = 0,

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn write(self: *Writer, source: []const u8) !void {
        if (!self.compressed) return self.bytes.appendSlice(self.allocator, source);
        var remaining = source;
        while (remaining.len != 0) {
            const count = @min(remaining.len, self.block.len - self.used);
            @memcpy(self.block[self.used..][0..count], remaining[0..count]);
            self.used += count;
            remaining = remaining[count..];
            if (self.used == self.block.len) try self.flush();
        }
    }

    pub fn integer(self: *Writer, comptime T: type, value: T) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try self.write(&bytes);
    }

    pub fn float(self: *Writer, value: f32) !void {
        try self.integer(u32, @bitCast(value));
    }

    pub fn boolean(self: *Writer, value: bool) !void {
        try self.integer(u8, @intFromBool(value));
    }

    pub fn string(self: *Writer, value: []const u8) !void {
        const count: u8 = @truncate(value.len);
        try self.integer(u8, count);
        try self.write(value[0..count]);
    }

    pub fn marker(self: *Writer, tag: u32, major: u32, minor: u32) !void {
        try self.integer(u32, tag);
        try self.integer(u32, major);
        try self.integer(u32, minor);
    }

    pub fn finish(self: *Writer) ![]u8 {
        try self.flush();
        return self.bytes.toOwnedSlice(self.allocator);
    }

    fn flush(self: *Writer) !void {
        var position: usize = 0;
        var literal: usize = 0;
        while (position < self.used) {
            var end = position + 1;
            while (end < self.used and self.block[end] == self.block[position]) : (end += 1) {}
            if (end - position < 3) {
                position += 1;
                continue;
            }
            try self.literals(self.block[literal..position]);
            var count = end - position;
            while (count != 0) {
                const part = @min(count, 128);
                try self.bytes.append(self.allocator, @as(u8, @intCast(part - 1)) | 0x80);
                try self.bytes.append(self.allocator, self.block[position]);
                count -= part;
            }
            position = end;
            literal = end;
        }
        try self.literals(self.block[literal..self.used]);
        self.used = 0;
    }

    fn literals(self: *Writer, source: []const u8) !void {
        var remaining = source;
        while (remaining.len != 0) {
            const count = @min(remaining.len, 128);
            try self.bytes.append(self.allocator, @intCast(count - 1));
            for (remaining[0..count]) |byte| try self.bytes.append(self.allocator, byte ^ 0xee);
            remaining = remaining[count..];
        }
    }
};

pub const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    compressed: bool = false,
    repeated: bool = false,
    value: u8 = 0,
    remaining: usize = 0,

    pub fn read(self: *Reader, destination: []u8) !void {
        if (!self.compressed) {
            @memcpy(destination, try self.raw(destination.len));
            return;
        }
        var output = destination;
        while (output.len != 0) {
            if (self.remaining == 0) {
                const control = (try self.raw(1))[0];
                self.remaining = @as(usize, control & 0x7f) + 1;
                self.repeated = control & 0x80 != 0;
                if (self.repeated) self.value = (try self.raw(1))[0];
            }
            const count = @min(output.len, self.remaining);
            if (self.repeated) {
                @memset(output[0..count], self.value);
            } else {
                for (output[0..count], try self.raw(count)) |*byte, encoded| byte.* = encoded ^ 0xee;
            }
            output = output[count..];
            self.remaining -= count;
        }
    }

    pub fn integer(self: *Reader, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.read(&bytes);
        return std.mem.readInt(T, &bytes, .little);
    }

    pub fn float(self: *Reader) !f32 {
        return @bitCast(try self.integer(u32));
    }

    pub fn boolean(self: *Reader) !bool {
        return try self.integer(u8) != 0;
    }

    pub fn string(self: *Reader, buffer: []u8) ![]const u8 {
        const count = try self.integer(u8);
        if (count > buffer.len) return error.SaveStringTooLong;
        try self.read(buffer[0..count]);
        return buffer[0..count];
    }

    pub fn marker(self: *Reader, tag: u32, major: u32, minor: u32) !void {
        if (try self.integer(u32) != tag) return error.InvalidSaveModule;
        if (try self.integer(u32) != major) return error.UnsupportedSaveModuleVersion;
        if (try self.integer(u32) != minor) return error.UnsupportedSaveModuleVersion;
    }

    pub fn end(self: *const Reader) !void {
        if (self.position != self.bytes.len or self.remaining != 0) return error.TrailingSaveData;
    }

    fn raw(self: *Reader, count: usize) ![]const u8 {
        if (count > self.bytes.len - self.position) return error.TruncatedSaveGame;
        const result = self.bytes[self.position..][0..count];
        self.position += count;
        return result;
    }
};

test "save compression preserves packet and 1024-byte flush boundaries" {
    const a = std.testing.allocator;
    const Case = struct {
        input: []const u8,
        encoded: []const u8,
    };
    for ([_]Case{
        .{ .input = "", .encoded = "" },
        .{ .input = "A", .encoded = "\x00\xaf" },
        .{ .input = "AA", .encoded = "\x01\xaf\xaf" },
        .{ .input = "AAA", .encoded = "\x82A" },
        .{ .input = "ABBBCCCDDE", .encoded = "\x00\xaf\x82B\x82C\x02\xaa\xaa\xab" },
        .{ .input = "X" ** 129, .encoded = "\xffX\x80X" },
        .{ .input = "X" ** 1025, .encoded = "\xffX" ** 8 ++ "\x00\xb6" },
    }) |case| {
        var writer = Writer{ .allocator = a, .compressed = true };
        defer writer.deinit();
        for (case.input) |byte| try writer.integer(u8, byte);
        const encoded = try writer.finish();
        defer a.free(encoded);
        try std.testing.expectEqualSlices(u8, case.encoded, encoded);
        var reader = Reader{ .bytes = case.encoded, .compressed = true };
        for (case.input) |byte| try std.testing.expectEqual(byte, try reader.integer(u8));
        try reader.end();
    }
    var source: [2048]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index);
    var writer = Writer{ .allocator = a, .compressed = true };
    defer writer.deinit();
    try writer.write(source[0..1]);
    try writer.write(source[1..3]);
    try writer.write(source[3..]);
    const encoded = try writer.finish();
    defer a.free(encoded);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});
    try std.testing.expectEqualStrings("ef31868d8efc60444927e9cae64138653dd58a46ba9370ae305112aea174a948", &std.fmt.bytesToHex(hash, .lower));
    var reader = Reader{ .bytes = encoded, .compressed = true };
    var restored: [2048]u8 = undefined;
    try reader.read(restored[0..127]);
    try reader.read(restored[127..1031]);
    try reader.read(restored[1031..]);
    try std.testing.expectEqualSlices(u8, &source, &restored);
    try reader.end();
}

test "save stream rejects truncated packets and unconsumed data" {
    var literal = Reader{ .bytes = "\x02\x11", .compressed = true };
    var output: [3]u8 = undefined;
    try std.testing.expectError(error.TruncatedSaveGame, literal.read(&output));
    var repeat = Reader{ .bytes = "\x82", .compressed = true };
    try std.testing.expectError(error.TruncatedSaveGame, repeat.read(&output));
    var trailing = Reader{ .bytes = "\x82A", .compressed = true };
    _ = try trailing.integer(u8);
    try std.testing.expectError(error.TrailingSaveData, trailing.end());
}
