//! Sound resources: the WAV data in the archives and the runtime header in
//! front of it (sample count, channels, rate, byte rate, block align,
//! bits).

const std = @import("std");

pub const resource_type: u32 = 0x57415644;

pub const Wave = struct {
    channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
    pcm: []const u8,

    pub fn frameCount(self: Wave) usize {
        return self.pcm.len / self.block_align;
    }
};

pub fn decode(bytes: []const u8) !Wave {
    try validateContainer(bytes);
    var cursor: usize = 12;
    var format: ?Wave = null;
    var result: ?Wave = null;
    while (bytes.len - cursor >= 4) {
        const tag = bytes[cursor..][0..4];
        cursor += 4;
        if (!std.mem.eql(u8, tag, "fmt ") and !std.mem.eql(u8, tag, "data")) continue;
        if (bytes.len - cursor < 4) return error.TruncatedWave;
        const size = read(u32, bytes, cursor);
        cursor += 4;
        if (size > bytes.len - cursor) return error.TruncatedWave;
        const payload = bytes[cursor..][0..size];
        cursor += size;
        if (std.mem.eql(u8, tag, "fmt ")) {
            if (size < 16) return error.InvalidWaveFormat;
            if (read(u16, payload, 0) != 1) return error.UnsupportedWaveEncoding;
            const wave: Wave = .{
                .channels = read(u16, payload, 2),
                .sample_rate = read(u32, payload, 4),
                .byte_rate = read(u32, payload, 8),
                .block_align = read(u16, payload, 12),
                .bits_per_sample = read(u16, payload, 14),
                .pcm = &.{},
            };
            if (wave.channels != 1 and wave.channels != 2) return error.UnsupportedWaveChannels;
            if (wave.bits_per_sample != 8 and wave.bits_per_sample != 16) return error.UnsupportedWaveBits;
            const alignment = wave.channels * (wave.bits_per_sample / 8);
            if (wave.sample_rate == 0 or wave.block_align != alignment or
                @as(u64, wave.sample_rate) * alignment != wave.byte_rate)
                return error.InvalidWaveFormat;
            format = wave;
        } else {
            var wave = format orelse return error.MissingWaveFormat;
            if (size == 0) return error.InvalidWaveData;
            wave.pcm = payload;
            result = wave;
        }
    }
    return result orelse error.MissingWaveData;
}

fn validateContainer(bytes: []const u8) !void {
    if (bytes.len < 12) return error.TruncatedWave;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE"))
        return error.UnsupportedAudioFormat;
    const declared: u64 = @as(u64, read(u32, bytes, 4)) + 8;
    if (declared > bytes.len) return error.TruncatedWave;
    if (declared < bytes.len - 1) return error.InvalidWaveSize;
    var cursor: usize = 12;
    var final_pad = false;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 8) return error.TruncatedWave;
        const size = read(u32, bytes, cursor + 4);
        cursor += 8;
        if (size > bytes.len - cursor) return error.TruncatedWave;
        cursor += size;
        final_pad = size & 1 != 0;
        if (final_pad) {
            if (cursor == bytes.len) return error.TruncatedWave;
            cursor += 1;
        }
    }
    if (declared != bytes.len and !final_pad) return error.InvalidWaveSize;
}

fn read(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn fixture() [48]u8 {
    var bytes = [_]u8{0} ** 48;
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 40, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], 11025, .little);
    std.mem.writeInt(u32, bytes[28..32], 22050, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], 4, .little);
    @memcpy(bytes[44..48], &[_]u8{ 0, 0x80, 0xff, 0x7f });
    return bytes;
}

test "WAVD preserves PCM and rejects unsupported or malformed input" {
    var bytes = fixture();
    const wave = try decode(&bytes);
    try std.testing.expectEqual(@as(usize, 2), wave.frameCount());
    try std.testing.expectEqualSlices(u8, &.{ 0, 0x80, 0xff, 0x7f }, wave.pcm);
    try std.testing.expectError(error.TruncatedWave, decode(bytes[0..47]));
    std.mem.writeInt(u16, bytes[20..22], 2, .little);
    try std.testing.expectError(error.UnsupportedWaveEncoding, decode(&bytes));
    bytes = fixture();
    std.mem.writeInt(u16, bytes[32..34], 1, .little);
    try std.testing.expectError(error.InvalidWaveFormat, decode(&bytes));
    bytes = fixture();
    std.mem.writeInt(u32, bytes[40..44], 0xffffffff, .little);
    try std.testing.expectError(error.TruncatedWave, decode(&bytes));
}

test "scanner recognizes tags inside unknown chunk and returns last data" {
    const base = fixture();
    var bytes: [72]u8 = undefined;
    @memcpy(bytes[0..48], &base);
    std.mem.writeInt(u32, bytes[4..8], 64, .little);
    @memcpy(bytes[48..52], "JUNK");
    std.mem.writeInt(u32, bytes[52..56], 16, .little);
    @memcpy(bytes[56..60], "data");
    std.mem.writeInt(u32, bytes[60..64], 8, .little);
    @memcpy(bytes[64..72], &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const wave = try decode(&bytes);
    try std.testing.expectEqualSlices(u8, bytes[64..72], wave.pcm);
}

test "all effects and taunts match independent loader PCM hashes" {
    const archives = .{
        .{ "OLSFX.LAB", 239, "bf466426a9508103732baa5fd945b067775389caff3c6d52ebc90ea8100e7dd0" },
        .{ "OLTAUNT.LAB", 1236, "cbc200491922a170fa22922023ec1a5eb6569b4057a3d8177f3559ee6e5d36f8" },
    };
    inline for (archives) |entry| {
        const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/" ++ entry[0], std.testing.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer std.testing.allocator.free(data);
        const archive = try @import("../assets/lab.zig").Archive.init(data);
        var iterator = archive.iterator();
        var count: usize = 0;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        while (try iterator.next()) |sound| {
            const wave = try decode(sound.bytes);
            hash.update(sound.name);
            hash.update(&.{0});
            var metadata: [18]u8 = undefined;
            std.mem.writeInt(u32, metadata[0..4], @intCast(wave.pcm.len), .little);
            std.mem.writeInt(u16, metadata[4..6], wave.channels, .little);
            std.mem.writeInt(u32, metadata[6..10], wave.sample_rate, .little);
            std.mem.writeInt(u32, metadata[10..14], wave.byte_rate, .little);
            std.mem.writeInt(u16, metadata[14..16], wave.block_align, .little);
            std.mem.writeInt(u16, metadata[16..18], wave.bits_per_sample, .little);
            hash.update(&metadata);
            hash.update(wave.pcm);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, entry[1]), count);
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, entry[2]);
        try std.testing.expectEqualSlices(u8, &expected, &hash.finalResult());
    }
}
