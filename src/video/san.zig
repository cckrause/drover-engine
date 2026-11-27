//! Movie files: the header and frame chunks, decoded one frame at a time.
//!
//! The decoder's storage is borrowed and only valid until the next frame is
//! fetched, so a caller that needs to keep a frame copies it.

const std = @import("std");

const audio = @import("audio.zig");
const codec = @import("smush_codec.zig");

pub const Frame = struct {
    pixels: []const u8,
    width: u16,
    height: u16,
    x: i16,
    y: i16,
    palette: [256]u32,
    palette_change: u2,
    subtitle_id: i16,
    number: u16,
    pcm: []const u8,
};

pub const Movie = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: usize,
    frame_count: u16,
    frame_number: u16 = 0,
    rate: u16,
    decoder: codec.Decoder,
    colors: Palette,
    last_image: ?codec.Frame = null,
    audio_chunks: u32 = 0,
    audio_bytes: u64 = 0,
    audio_decoder: audio.Decoder = .{},
    pcm: std.ArrayList(u8) = .empty,
    last_audio_frame: u16 = 0,
    ignored_fobjs: u32 = 0,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Movie {
        if (data.len < 8) return error.TruncatedSan;
        if (!std.mem.eql(u8, data[0..4], "ANIM")) return error.UnsupportedSanContainer;
        if (read32be(data, 4) != data.len - 8) return error.InvalidSanContainerSize;

        const header = try chunk(data, 8);
        if (!std.mem.eql(u8, header.tag, "AHDR")) return error.MissingSanHeader;
        if (header.payload.len < 774) return error.TruncatedSanHeader;

        const version = read16(header.payload, 0);
        if (version != 1 and version != 2) return error.UnsupportedSanVersion;

        const count = read16(header.payload, 2);
        if (count == 0 or count > std.math.maxInt(i16)) return error.InvalidSanFrameCount;

        var rate: u16 = 12;

        if (version > 1) {
            if (header.payload.len < 776) return error.TruncatedSanHeader;
            const declared_rate = read16(header.payload, 774);
            if (declared_rate > std.math.maxInt(i16)) return error.InvalidSanFrameRate;
            if (declared_rate != 0) rate = declared_rate;
        }

        var colors = Palette{};
        try colors.set(header.payload[6..774]);

        return .{
            .allocator = allocator,
            .data = data,
            .offset = header.end,
            .frame_count = count,
            .rate = rate,
            .decoder = try codec.Decoder.init(allocator, 640, 480),
            .colors = colors,
        };
    }

    pub fn deinit(self: *Movie, allocator: std.mem.Allocator) void {
        self.pcm.deinit(allocator);
        self.decoder.deinit(allocator);
        self.* = undefined;
    }

    pub fn next(self: *Movie) !?Frame {
        return self.nextWithFlags(0);
    }

    pub fn nextWithFlags(self: *Movie, flags: u16) !?Frame {
        if (self.failed) return error.SanDecoderFailed;

        errdefer self.failed = true;
        if (flags & ~@as(u16, 0x10) != 0) return error.UnsupportedSanRenderFlags;
        if (self.offset == self.data.len) {
            if (self.frame_number != self.frame_count) return error.InvalidSanFrameCount;
            return null;
        }

        if (self.frame_number == self.frame_count) return error.InvalidSanFrameCount;

        const frame = try chunk(self.data, self.offset);
        if (!std.mem.eql(u8, frame.tag, "FRME")) return error.UnsupportedSanTopLevelChunk;
        if (self.frame_number + 1 == self.frame_count and frame.end != self.data.len)
            return error.InvalidSanFrameCount;

        self.frame_number += 1;
        self.pcm.clearRetainingCapacity();

        var subtitle_id: i16 = 0;
        var offset: usize = 0;

        while (offset < frame.payload.len) {
            if (((self.offset + 8 + offset) & 1) != 0 and frame.payload[offset] == 0) {
                offset += 1;
                if (offset == frame.payload.len) break;
            }

            const item = try chunk(frame.payload, offset);

            if (std.mem.eql(u8, item.tag, "FOBJ")) {
                if (item.payload.len < 14) return error.TruncatedSanObject;

                switch (item.payload[0]) {
                    47 => {
                        if (read16(item.payload, 2) != 0 or read16(item.payload, 4) != 0)
                            return error.UnsupportedSanObjectPlacement;

                        if (read16(item.payload, 6) > 640 or read16(item.payload, 8) > 480)
                            return error.UnsupportedSanObjectClipping;

                        if (try self.decoder.decodeWithFlags(
                            item.payload,
                            flags,
                        )) |decoded| self.last_image = decoded;
                    },
                    1 => {
                        self.ignored_fobjs += 1;
                    },
                    else => return error.UnsupportedSanCodec,
                }
            } else if (std.mem.eql(u8, item.tag, "NPAL")) {
                try self.colors.set(item.payload);
            } else if (std.mem.eql(u8, item.tag, "XPAL")) {
                try self.colors.delta(item.payload);
            } else if (std.mem.eql(u8, item.tag, "TRES")) {
                if (item.payload.len < 18) return error.TruncatedSanText;
                subtitle_id = @bitCast(read16(item.payload, 16));
            } else if (std.mem.eql(u8, item.tag, "IACT")) {
                try self.interactive(item.payload);
            } else if (std.mem.eql(u8, item.tag, "STOR")) {
                if (item.payload.len < 4) return error.TruncatedSanOverlay;
            } else if (std.mem.eql(u8, item.tag, "FTCH")) {
                if (item.payload.len != 6 and item.payload.len != 12) return error.InvalidSanOverlay;
            } else {
                return error.UnsupportedSanFrameChunk;
            }

            offset = item.end;
        }

        if (self.frame_number == self.frame_count) try self.audio_decoder.finish();

        self.offset = frame.end;

        const image = self.last_image orelse return error.SanFrameBeforeImage;
        const change = self.colors.publish();

        return .{
            .pixels = image.pixels,
            .width = image.width,
            .height = image.height,
            .x = 0,
            .y = 0,
            .palette = self.colors.displayed,
            .palette_change = change,
            .subtitle_id = subtitle_id,
            .number = self.frame_number,
            .pcm = self.pcm.items,
        };
    }

    fn interactive(self: *Movie, payload: []const u8) !void {
        if (payload.len < 18) return error.TruncatedSanInteractive;
        if (read16(payload, 0) != 8) return error.UnsupportedSanInteractiveCommand;
        if (read16(payload, 6) != 0) return error.UnsupportedSanPaletteCommand;

        self.last_audio_frame = self.frame_number - 1;
        try self.audio_decoder.feed(self.allocator, payload[18..], &self.pcm);

        self.audio_chunks += 1;
        self.audio_bytes += payload.len - 18;
    }
};

const Chunk = struct { tag: []const u8, payload: []const u8, end: usize };

const Palette = struct {
    rgb: [768]u8 = @splat(0),
    fixed: [768]u16 = @splat(0),
    increment: [768]u16 = @splat(0),
    displayed: [256]u32 = @splat(0),
    change: u2 = 0,

    fn set(self: *Palette, payload: []const u8) !void {
        if (payload.len != 768) return error.InvalidSanPalette;
        @memcpy(&self.rgb, payload);
        self.change = 2;
    }

    fn delta(self: *Palette, payload: []const u8) !void {
        if (payload.len < 4) return error.TruncatedSanPaletteDelta;

        const mode = read16(payload, 2);
        if (mode != 0 and mode != 0x200) {
            for (&self.fixed, self.increment, &self.rgb) |*value, increment, *color| {
                value.* +%= increment;
                color.* = @truncate(value.* >> 7);
            }

            self.change = 1;
            return;
        }

        if (payload.len < 4 + 768 * 2) return error.TruncatedSanPaletteDelta;

        if (mode == 0x200) {
            if (payload.len < 4 + 768 * 3) return error.TruncatedSanPaletteDelta;
            @memcpy(&self.rgb, payload[4 + 768 * 2 ..][0..768]);
        }

        for (self.rgb, &self.fixed, &self.increment, 0..) |color, *value, *increment, index| {
            value.* = @as(u16, color) << 7;
            increment.* = read16(payload, 4 + index * 2);
        }
    }

    fn publish(self: *Palette) u2 {
        const changed = self.change;

        if (changed != 0) {
            for (&self.displayed, 0..) |*color, index| {
                const rgb = self.rgb[index * 3 ..][0..3];
                color.* = @as(u32, rgb[0]) | @as(u32, rgb[1]) << 8 | @as(u32, rgb[2]) << 16;
            }

            self.change = 0;
        }

        return changed;
    }
};

fn chunk(data: []const u8, offset: usize) !Chunk {
    if (offset > data.len or data.len - offset < 8) return error.TruncatedSanChunk;

    const size: usize = read32be(data, offset + 4);
    if (size > data.len - offset - 8) return error.TruncatedSanChunk;

    return .{
        .tag = data[offset..][0..4],
        .payload = data[offset + 8 ..][0..size],
        .end = offset + 8 + size,
    };
}

fn read16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn read32be(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

test "SAN XPAL retains delayed publication and 16-bit wrap" {
    var palette = Palette{};
    var rgb: [768]u8 = @splat(0);

    rgb[0] = 255;
    rgb[1] = 2;

    try palette.set(&rgb);

    try std.testing.expectEqual(@as(u2, 2), palette.publish());
    try std.testing.expectEqual(@as(u32, 0x0002ff), palette.displayed[0]);

    var initialization: [2308]u8 = @splat(0);

    initialization[3] = 2;
    initialization[4] = 128;

    std.mem.writeInt(u16, initialization[6..8], @bitCast(@as(i16, -384)), .little);
    @memcpy(initialization[1540..], &rgb);
    initialization[1542] = 7;
    try palette.delta(&initialization);

    try std.testing.expectEqual(@as(u2, 0), palette.publish());
    try std.testing.expectEqual(@as(u32, 0x0002ff), palette.displayed[0]);

    try palette.delta(&.{ 0, 0, 0, 1, 0, 0 });

    try std.testing.expectEqual(@as(u2, 1), palette.publish());
    try std.testing.expectEqual(@as(u32, 0x07ff00), palette.displayed[0]);
    try std.testing.expectEqual(@as(u2, 0), palette.publish());
}

test "SAN rejects truncated chunks and palette records" {
    try std.testing.expectError(error.TruncatedSanChunk, chunk("FRME\x00\x00\x00\x01", 0));
    try std.testing.expectError(error.TruncatedSanChunk, chunk("FOBJ", 0));

    var palette = Palette{};

    try std.testing.expectError(error.InvalidSanPalette, palette.set(&.{0}));
    try std.testing.expectError(error.TruncatedSanPaletteDelta, palette.delta(&.{ 0, 0, 0, 2 }));
    try std.testing.expectError(
        error.UnsupportedSanContainer,
        Movie.init(std.testing.allocator, "SAUD\x00\x00\x00\x00"),
    );

    try std.testing.expectError(
        error.InvalidSanContainerSize,
        Movie.init(std.testing.allocator, "ANIM\x00\x00\x00\x01"),
    );
}

test "SAN final advertised frame rejects extra frames and trailing bytes before completion" {
    var bytes: [918]u8 = @splat(0);

    @memcpy(bytes[0..4], "ANIM");
    @memcpy(bytes[8..12], "AHDR");

    std.mem.writeInt(u32, bytes[12..16], 774, .big);
    std.mem.writeInt(u16, bytes[16..18], 1, .little);
    std.mem.writeInt(u16, bytes[18..20], 1, .little);

    @memcpy(bytes[790..794], "FRME");
    std.mem.writeInt(u32, bytes[794..798], 112, .big);
    @memcpy(bytes[798..802], "FOBJ");
    std.mem.writeInt(u32, bytes[802..806], 104, .big);
    bytes[806] = 47;

    std.mem.writeInt(u16, bytes[812..814], 8, .little);
    std.mem.writeInt(u16, bytes[814..816], 8, .little);

    @memcpy(bytes[910..914], "FRME");

    for ([_]usize{ 910, 911, 918 }) |length| {
        std.mem.writeInt(u32, bytes[4..8], @intCast(length - 8), .big);

        var movie = try Movie.init(std.testing.allocator, bytes[0..length]);
        defer movie.deinit(std.testing.allocator);

        if (length == 910) {
            const frame = (try movie.next()).?;
            try std.testing.expectEqual(@as(u16, 1), frame.number);
            try std.testing.expectEqual(@as(usize, 64), frame.pixels.len);
            try std.testing.expect((try movie.next()) == null);
        } else {
            try std.testing.expectError(error.InvalidSanFrameCount, movie.next());
            try std.testing.expectEqual(@as(u16, 0), movie.frame_number);
            try std.testing.expectError(error.SanDecoderFailed, movie.next());
        }
    }
}

test "SAN intro frames and published palettes match the reference" {
    const allocator = std.testing.allocator;
    const reference_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/smush-display-reference.json",
        allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(reference_bytes);
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/IN_SHB.SAN",
        allocator,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(data);
    const Expected = struct {
        frame: usize,
        width: u16,
        height: u16,
        pixels: []const u8,
        palette: []const u8,
    };

    const Reference = struct {
        dll_sha256: []const u8,
        san_sha256: []const u8,
        frames: []Expected,
        combined_sha256: []const u8,
    };

    const parsed = try std.json.parseFromSlice(Reference, allocator, reference_bytes, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "edfd70c2ad4391bcb8b119b51b11576c2eb2c60eace8539c2283891bf1f1c634",
        parsed.value.dll_sha256,
    );

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    try std.testing.expectEqualStrings(
        parsed.value.san_sha256,
        &std.fmt.bytesToHex(digest, .lower),
    );

    var movie = try Movie.init(allocator, data);
    defer movie.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 12), movie.rate);
    try std.testing.expectEqual(@as(u16, 4971), movie.frame_count);

    var combined = std.crypto.hash.sha2.Sha256.init(.{});

    for (parsed.value.frames) |expected| {
        const frame = (try movie.next()) orelse return error.MissingSanReferenceFrame;

        try std.testing.expectEqual(expected.frame + 1, frame.number);
        try std.testing.expectEqual(expected.width, frame.width);
        try std.testing.expectEqual(expected.height, frame.height);

        std.crypto.hash.sha2.Sha256.hash(frame.pixels, &digest, .{});
        const pixel_hex = std.fmt.bytesToHex(digest, .lower);

        if (!std.mem.eql(u8, expected.pixels, &pixel_hex))
            std.debug.print(
                "\nSAN frame {d} pixels: {s}, expected {s}\n",
                .{ expected.frame, pixel_hex, expected.pixels },
            );

        try std.testing.expectEqualStrings(expected.pixels, &pixel_hex);
        var rgb: [768]u8 = undefined;

        for (frame.palette, 0..) |color, index| {
            rgb[index * 3] = @truncate(color);
            rgb[index * 3 + 1] = @truncate(color >> 8);
            rgb[index * 3 + 2] = @truncate(color >> 16);
        }

        std.crypto.hash.sha2.Sha256.hash(&rgb, &digest, .{});
        const palette_hex = std.fmt.bytesToHex(digest, .lower);

        if (!std.mem.eql(u8, expected.palette, &palette_hex))
            std.debug.print(
                "\nSAN frame {d} palette: {s}, expected {s}\n",
                .{ expected.frame, palette_hex, expected.palette },
            );

        try std.testing.expectEqualStrings(expected.palette, &palette_hex);

        combined.update(frame.pixels);
        combined.update(&rgb);
    }

    combined.final(&digest);
    try std.testing.expectEqualStrings(
        parsed.value.combined_sha256,
        &std.fmt.bytesToHex(digest, .lower),
    );

    if (parsed.value.frames.len == movie.frame_count) {
        try std.testing.expectEqual(@as(?Frame, null), try movie.next());
        try std.testing.expectEqual(@as(u32, 4931), movie.audio_chunks);
        try std.testing.expectEqual(@as(u32, 37), movie.ignored_fobjs);
    }
}

test "SAN intro PCM matches the reference for every IACT and silent frame" {
    const allocator = std.testing.allocator;
    const reference_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/movie-audio-reference.json",
        allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(reference_bytes);
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/IN_SHB.SAN",
        allocator,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(data);
    const Expected = struct {
        frame: u16,
        pcm_bytes: usize,
        pcm_sha256: []const u8,
        buffered: usize,
        last_audio_frame: u16,
    };

    const Reference = struct {
        dll_sha256: []const u8,
        san_sha256: []const u8,
        chunks: []const Expected,
        frame_count: u16,
        compressed_bytes: u64,
        decoded_bytes: u32,
        decoded_packets: u32,
        callback_order: []const struct {
            frame: u16,
            last_audio_frame: u16,
            decoded_frame: u16,
            pcm_bytes: u32,
        },
        final_buffered: usize,
        combined_sha256: []const u8,
    };

    const parsed = try std.json.parseFromSlice(
        Reference,
        allocator,
        reference_bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer parsed.deinit();
    const reference = parsed.value;

    try std.testing.expectEqualStrings(
        "edfd70c2ad4391bcb8b119b51b11576c2eb2c60eace8539c2283891bf1f1c634",
        reference.dll_sha256,
    );

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    try std.testing.expectEqualStrings(reference.san_sha256, &std.fmt.bytesToHex(digest, .lower));

    var movie = try Movie.init(allocator, data);
    defer movie.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 4971), movie.frame_count);
    try std.testing.expectEqual(reference.frame_count, movie.frame_count);

    var combined = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk_index: usize = 0;
    var last_audio_frame: u16 = 0;
    var decoded_bytes: usize = 0;

    for (1..@as(usize, movie.frame_count) + 1) |number| {
        const frame = (try movie.next()) orelse return error.MissingSanReferenceFrame;
        try std.testing.expectEqual(number, frame.number);
        var pcm_offset: usize = 0;

        while (chunk_index < reference.chunks.len and reference.chunks[chunk_index].frame == frame.number) : (chunk_index += 1) {
            const expected = reference.chunks[chunk_index];
            try std.testing.expect(expected.pcm_bytes <= frame.pcm.len - pcm_offset);
            const pcm = frame.pcm[pcm_offset..][0..expected.pcm_bytes];
            std.crypto.hash.sha2.Sha256.hash(pcm, &digest, .{});
            try std.testing.expectEqualStrings(
                expected.pcm_sha256,
                &std.fmt.bytesToHex(digest, .lower),
            );

            pcm_offset += expected.pcm_bytes;
            last_audio_frame = expected.last_audio_frame;

            if (chunk_index + 1 == reference.chunks.len or reference.chunks[chunk_index + 1].frame != frame.number)
                try std.testing.expectEqual(expected.buffered, movie.audio_decoder.buffered);
        }

        try std.testing.expectEqual(pcm_offset, frame.pcm.len);
        try std.testing.expectEqual(last_audio_frame, movie.last_audio_frame);

        decoded_bytes += frame.pcm.len;

        if (number <= reference.callback_order.len) {
            const expected = reference.callback_order[number - 1];

            try std.testing.expectEqual(expected.frame, frame.number);
            try std.testing.expectEqual(expected.decoded_frame, movie.frame_number);
            try std.testing.expectEqual(expected.last_audio_frame, movie.last_audio_frame);
            try std.testing.expectEqual(expected.pcm_bytes, decoded_bytes);
        }

        combined.update(frame.pcm);
    }

    try std.testing.expect((try movie.next()) == null);
    try movie.audio_decoder.finish();

    try std.testing.expectEqual(reference.chunks.len, chunk_index);
    try std.testing.expectEqual(reference.chunks.len, movie.audio_chunks);
    try std.testing.expectEqual(reference.compressed_bytes, movie.audio_bytes);
    try std.testing.expectEqual(reference.decoded_bytes, decoded_bytes);
    try std.testing.expectEqual(reference.decoded_bytes, movie.audio_decoder.written);
    try std.testing.expectEqual(
        reference.decoded_packets,
        movie.audio_decoder.written / audio.block_bytes,
    );

    try std.testing.expectEqual(reference.final_buffered, movie.audio_decoder.buffered);

    combined.final(&digest);
    try std.testing.expectEqualStrings(
        reference.combined_sha256,
        &std.fmt.bytesToHex(digest, .lower),
    );
}

test "SAN final frame rejects incomplete audio and unsupported IACT before completion" {
    var bytes: [938]u8 = @splat(0);

    @memcpy(bytes[0..4], "ANIM");
    @memcpy(bytes[8..12], "AHDR");

    std.mem.writeInt(u32, bytes[12..16], 774, .big);
    std.mem.writeInt(u16, bytes[16..18], 1, .little);
    std.mem.writeInt(u16, bytes[18..20], 1, .little);

    @memcpy(bytes[790..794], "FRME");
    @memcpy(bytes[798..802], "FOBJ");

    std.mem.writeInt(u32, bytes[802..806], 104, .big);
    bytes[806] = 47;

    std.mem.writeInt(u16, bytes[812..814], 8, .little);
    std.mem.writeInt(u16, bytes[814..816], 8, .little);

    @memcpy(bytes[910..914], "IACT");
    const Case = struct {
        size: usize,
        command: u16 = 8,
        subcommand: u16 = 0,
        packet: [2]u8 = .{ 8, 1 },
        err: anyerror,
    };

    for ([_]Case{
        .{ .size = 17, .err = error.TruncatedSanInteractive },
        .{ .size = 18, .command = 7, .err = error.UnsupportedSanInteractiveCommand },
        .{ .size = 18, .subcommand = 1, .err = error.UnsupportedSanPaletteCommand },
        .{ .size = 19, .err = error.TruncatedMovieAudioPacket },
        .{ .size = 20, .err = error.TruncatedMovieAudioPacket },
        .{ .size = 20, .packet = .{ 0x10, 0 }, .err = error.MovieAudioPacketTooLarge },
        .{ .size = 20, .packet = .{ 0, 1 }, .err = error.InvalidMovieAudioPacketLength },
    }) |case| {
        const length = 918 + case.size;

        std.mem.writeInt(u32, bytes[4..8], @intCast(length - 8), .big);
        std.mem.writeInt(u32, bytes[794..798], @intCast(length - 798), .big);
        std.mem.writeInt(u32, bytes[914..918], @intCast(case.size), .big);
        std.mem.writeInt(u16, bytes[918..920], case.command, .little);
        std.mem.writeInt(u16, bytes[924..926], case.subcommand, .little);

        bytes[936..938].* = case.packet;

        var movie = try Movie.init(std.testing.allocator, bytes[0..length]);
        defer movie.deinit(std.testing.allocator);

        try std.testing.expectError(case.err, movie.next());
        try std.testing.expectError(error.SanDecoderFailed, movie.next());
    }
}
