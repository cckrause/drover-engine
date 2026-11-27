//! Movie sound: the packets in the file turned into PCM.
//!
//! Output is 22050 Hz stereo 16-bit, a fixed number of sample frames per
//! call, assembled from the interleaved audio commands in the stream.

const std = @import("std");

pub const sample_rate = 22050;

pub const channels = 2;

pub const block_bytes = 0x1000;

pub const ring_bytes = 0x78000;

const packet_capacity = 0x1000;

const minimum_packet_bytes = 2 + 1 + 0x400 * 2;

pub const Decoder = struct {
    packet: [packet_capacity]u8 = undefined,
    buffered: usize = 0,
    written: u32 = 0,
    failed: bool = false,

    pub fn feed(
        self: *Decoder,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        output: *std.ArrayList(u8),
    ) !void {
        if (self.failed) return error.MovieAudioDecoderFailed;

        errdefer self.failed = true;
        var offset: usize = 0;

        while (offset < bytes.len) {
            if (self.buffered < 2) {
                const count = @min(2 - self.buffered, bytes.len - offset);
                @memcpy(self.packet[self.buffered..][0..count], bytes[offset..][0..count]);

                self.buffered += count;
                offset += count;

                if (self.buffered < 2) continue;

                _ = try packetLength(self.packet[0..2]);
            }

            const length = try packetLength(self.packet[0..2]);
            const count = @min(length - self.buffered, bytes.len - offset);

            @memcpy(self.packet[self.buffered..][0..count], bytes[offset..][0..count]);

            self.buffered += count;
            offset += count;

            if (self.buffered != length) continue;

            var pcm: [block_bytes]u8 = undefined;

            try decodePacket(self.packet[0..length], &pcm);
            try output.appendSlice(allocator, &pcm);

            self.written +%= block_bytes;
            self.buffered = 0;
        }
    }

    pub fn finish(self: *const Decoder) !void {
        if (self.failed) return error.MovieAudioDecoderFailed;
        if (self.buffered != 0) return error.TruncatedMovieAudioPacket;
    }
};

pub fn decodePacket(packet: []const u8, output: *[block_bytes]u8) !void {
    const length = try packetLength(packet);
    if (packet.len < length) return error.TruncatedMovieAudioPacket;
    if (packet.len != length) return error.InvalidMovieAudioPacketLength;

    const shifts = [2]u4{ @intCast(packet[2] >> 4), @truncate(packet[2]) };
    var offset: usize = 3;

    for (0..0x400) |frame| {
        for (shifts, 0..) |shift, channel| {
            if (offset == packet.len) return error.TruncatedMovieAudioPacket;

            const value = packet[offset];

            offset += 1;
            const sample: u16 = if (value == 0x80) literal: {
                if (packet.len - offset < 2) return error.TruncatedMovieAudioPacket;
                const word = std.mem.readInt(u16, packet[offset..][0..2], .big);
                offset += 2;
                break :literal word;
            } else @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(value))))) << shift;

            std.mem.writeInt(u16, output[(frame * 2 + channel) * 2 ..][0..2], sample, .little);
        }
    }
}

fn packetLength(header: []const u8) !usize {
    if (header.len < 2) return error.TruncatedMovieAudioPacket;

    const length = @as(usize, std.mem.readInt(u16, header[0..2], .big)) + 2;
    if (length > packet_capacity) return error.MovieAudioPacketTooLarge;
    if (length < minimum_packet_bytes) return error.InvalidMovieAudioPacketLength;

    return length;
}

fn expectHash(expected: []const u8, bytes: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(&digest, .lower);
    try std.testing.expectEqualStrings(expected, &actual);
}

test "movie audio retains channel shifts, signed low words and literal endian order" {
    var packet: [minimum_packet_bytes + 4]u8 = @splat(0);
    std.mem.writeInt(u16, packet[0..2], packet.len - 2, .big);

    packet[2] = 0xa3;
    packet[3] = 0x81;
    packet[4] = 0x7f;
    packet[5..11].* = .{ 0x80, 0x80, 0x01, 0x80, 0x12, 0x34 };

    var output: [block_bytes]u8 = undefined;
    try decodePacket(&packet, &output);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x04, 0xf8, 0x03, 0x01, 0x80, 0x34, 0x12 },
        output[0..8],
    );

    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** (block_bytes - 8)), output[8..]);

    @memset(packet[5..11], 0);
    @memset(packet[minimum_packet_bytes..], 0x80);

    try decodePacket(&packet, &output);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** (block_bytes - 4)), output[4..]);
}

test "IACT audio packets survive split length words and multiple packets per chunk" {
    const allocator = std.testing.allocator;
    var packet: [minimum_packet_bytes]u8 = @splat(0);

    std.mem.writeInt(u16, packet[0..2], packet.len - 2, .big);

    packet[2] = 0x12;
    packet[3] = 3;
    packet[4] = 0xff;

    var decoder = Decoder{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try decoder.feed(allocator, packet[0..1], &output);
    try std.testing.expectEqual(@as(usize, 1), decoder.buffered);
    try decoder.feed(allocator, &.{}, &output);
    try std.testing.expectError(error.TruncatedMovieAudioPacket, decoder.finish());

    try decoder.feed(allocator, packet[1..2], &output);
    try decoder.feed(allocator, packet[2 .. packet.len - 1], &output);

    try std.testing.expectEqual(@as(usize, 0), output.items.len);
    var remainder: [packet.len + 1]u8 = undefined;
    remainder[0] = packet[packet.len - 1];
    @memcpy(remainder[1..], &packet);

    try decoder.feed(allocator, &remainder, &output);
    try decoder.finish();

    try std.testing.expectEqual(@as(u32, 2 * block_bytes), decoder.written);
    try std.testing.expectEqualSlices(u8, &.{ 6, 0, 0xfc, 0xff }, output.items[0..4]);
    try std.testing.expectEqualSlices(
        u8,
        output.items[0..block_bytes],
        output.items[block_bytes..],
    );
}

test "movie audio rejects overlarge records and truncated literal samples" {
    const allocator = std.testing.allocator;
    var decoder = Decoder{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try std.testing.expectError(
        error.MovieAudioPacketTooLarge,
        decoder.feed(allocator, &.{ 0x10, 0 }, &output),
    );

    try std.testing.expectError(
        error.MovieAudioDecoderFailed,
        decoder.feed(allocator, &.{}, &output),
    );

    var packet: [minimum_packet_bytes]u8 = @splat(0);
    std.mem.writeInt(u16, packet[0..2], packet.len - 2, .big);
    packet[packet.len - 1] = 0x80;
    var pcm: [block_bytes]u8 = undefined;

    try std.testing.expectError(error.TruncatedMovieAudioPacket, decodePacket(&packet, &pcm));
    try std.testing.expectError(
        error.InvalidMovieAudioPacketLength,
        decodePacket(&.{ 0, 1, 0 }, &pcm),
    );

    try std.testing.expectError(
        error.TruncatedMovieAudioPacket,
        decodePacket(packet[0 .. packet.len - 1], &pcm),
    );
}

test "movie audio packets and streaming assembly match the reference" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/movie-audio-reference.json",
        allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(bytes);
    const Packet = struct {
        packet: []const u8,
        pcm_sha256: []const u8,
    };

    const Output = struct { pcm_bytes: usize, pcm_sha256: []const u8, buffered: usize };
    const Assembly = struct {
        packet_indexes: []const usize,
        splits: []const usize,
        outputs: []const Output,
    };

    const parsed = try std.json.parseFromSlice(
        struct { packets: []const Packet, assembly: []const Assembly },
        allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer parsed.deinit();

    for (parsed.value.packets) |packet| {
        var pcm: [block_bytes]u8 = undefined;
        try decodePacket(packet.packet, &pcm);
        try expectHash(packet.pcm_sha256, &pcm);
    }

    for (parsed.value.assembly) |reference| {
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(allocator);

        for (reference.packet_indexes) |index| try input.appendSlice(
            allocator,
            parsed.value.packets[index].packet,
        );

        var decoder = Decoder{};
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        var offset: usize = 0;

        for (reference.splits, reference.outputs) |length, expected| {
            output.clearRetainingCapacity();
            try decoder.feed(allocator, input.items[offset..][0..length], &output);

            offset += length;

            try std.testing.expectEqual(expected.pcm_bytes, output.items.len);
            try std.testing.expectEqual(expected.buffered, decoder.buffered);

            try expectHash(expected.pcm_sha256, output.items);
        }

        try std.testing.expectEqual(input.items.len, offset);
        try decoder.finish();
    }
}
