//! The movie video codec: key frames and deltas over three buffers.
//!
//! The three buffers keep their contents across frames; only the roles - key,
//! delta, current - rotate. A newly allocated buffer is cleared, which is
//! what makes the first frame well defined.

const std = @import("std");

const motion_vectors = [_][2]i16{
    .{ 0, 0 },
    .{ -1, -43 },
    .{ 6, -43 },
    .{ -9, -42 },
    .{ 13, -41 },
    .{ -16, -40 },
    .{ 19, -39 },
    .{ -23, -36 },
    .{ 26, -34 },
    .{ -2, -33 },
    .{ 4, -33 },
    .{ -29, -32 },
    .{ -9, -32 },
    .{ 11, -31 },
    .{ -16, -29 },
    .{ 32, -29 },
    .{ 18, -28 },
    .{ -34, -26 },
    .{ -22, -25 },
    .{ -1, -25 },
    .{ 3, -25 },
    .{ -7, -24 },
    .{ 8, -24 },
    .{ 24, -23 },
    .{ 36, -23 },
    .{ -12, -22 },
    .{ 13, -21 },
    .{ -38, -20 },
    .{ 0, -20 },
    .{ -27, -19 },
    .{ -4, -19 },
    .{ 4, -19 },
    .{ -17, -18 },
    .{ -8, -17 },
    .{ 8, -17 },
    .{ 18, -17 },
    .{ 28, -17 },
    .{ 39, -17 },
    .{ -12, -15 },
    .{ 12, -15 },
    .{ -21, -14 },
    .{ -1, -14 },
    .{ 1, -14 },
    .{ -41, -13 },
    .{ -5, -13 },
    .{ 5, -13 },
    .{ 21, -13 },
    .{ -31, -12 },
    .{ -15, -11 },
    .{ -8, -11 },
    .{ 8, -11 },
    .{ 15, -11 },
    .{ -2, -10 },
    .{ 1, -10 },
    .{ 31, -10 },
    .{ -23, -9 },
    .{ -11, -9 },
    .{ -5, -9 },
    .{ 4, -9 },
    .{ 11, -9 },
    .{ 42, -9 },
    .{ 6, -8 },
    .{ 24, -8 },
    .{ -18, -7 },
    .{ -7, -7 },
    .{ -3, -7 },
    .{ -1, -7 },
    .{ 2, -7 },
    .{ 18, -7 },
    .{ -43, -6 },
    .{ -13, -6 },
    .{ -4, -6 },
    .{ 4, -6 },
    .{ 8, -6 },
    .{ -33, -5 },
    .{ -9, -5 },
    .{ -2, -5 },
    .{ 0, -5 },
    .{ 2, -5 },
    .{ 5, -5 },
    .{ 13, -5 },
    .{ -25, -4 },
    .{ -6, -4 },
    .{ -3, -4 },
    .{ 3, -4 },
    .{ 9, -4 },
    .{ -19, -3 },
    .{ -7, -3 },
    .{ -4, -3 },
    .{ -2, -3 },
    .{ -1, -3 },
    .{ 0, -3 },
    .{ 1, -3 },
    .{ 2, -3 },
    .{ 4, -3 },
    .{ 6, -3 },
    .{ 33, -3 },
    .{ -14, -2 },
    .{ -10, -2 },
    .{ -5, -2 },
    .{ -3, -2 },
    .{ -2, -2 },
    .{ -1, -2 },
    .{ 0, -2 },
    .{ 1, -2 },
    .{ 2, -2 },
    .{ 3, -2 },
    .{ 5, -2 },
    .{ 7, -2 },
    .{ 14, -2 },
    .{ 19, -2 },
    .{ 25, -2 },
    .{ 43, -2 },
    .{ -7, -1 },
    .{ -3, -1 },
    .{ -2, -1 },
    .{ -1, -1 },
    .{ 0, -1 },
    .{ 1, -1 },
    .{ 2, -1 },
    .{ 3, -1 },
    .{ 10, -1 },
    .{ -5, 0 },
    .{ -3, 0 },
    .{ -2, 0 },
    .{ -1, 0 },
    .{ 1, 0 },
    .{ 2, 0 },
    .{ 3, 0 },
    .{ 5, 0 },
    .{ 7, 0 },
    .{ -10, 1 },
    .{ -7, 1 },
    .{ -3, 1 },
    .{ -2, 1 },
    .{ -1, 1 },
    .{ 0, 1 },
    .{ 1, 1 },
    .{ 2, 1 },
    .{ 3, 1 },
    .{ -43, 2 },
    .{ -25, 2 },
    .{ -19, 2 },
    .{ -14, 2 },
    .{ -5, 2 },
    .{ -3, 2 },
    .{ -2, 2 },
    .{ -1, 2 },
    .{ 0, 2 },
    .{ 1, 2 },
    .{ 2, 2 },
    .{ 3, 2 },
    .{ 5, 2 },
    .{ 7, 2 },
    .{ 10, 2 },
    .{ 14, 2 },
    .{ -33, 3 },
    .{ -6, 3 },
    .{ -4, 3 },
    .{ -2, 3 },
    .{ -1, 3 },
    .{ 0, 3 },
    .{ 1, 3 },
    .{ 2, 3 },
    .{ 4, 3 },
    .{ 19, 3 },
    .{ -9, 4 },
    .{ -3, 4 },
    .{ 3, 4 },
    .{ 7, 4 },
    .{ 25, 4 },
    .{ -13, 5 },
    .{ -5, 5 },
    .{ -2, 5 },
    .{ 0, 5 },
    .{ 2, 5 },
    .{ 5, 5 },
    .{ 9, 5 },
    .{ 33, 5 },
    .{ -8, 6 },
    .{ -4, 6 },
    .{ 4, 6 },
    .{ 13, 6 },
    .{ 43, 6 },
    .{ -18, 7 },
    .{ -2, 7 },
    .{ 0, 7 },
    .{ 2, 7 },
    .{ 7, 7 },
    .{ 18, 7 },
    .{ -24, 8 },
    .{ -6, 8 },
    .{ -42, 9 },
    .{ -11, 9 },
    .{ -4, 9 },
    .{ 5, 9 },
    .{ 11, 9 },
    .{ 23, 9 },
    .{ -31, 10 },
    .{ -1, 10 },
    .{ 2, 10 },
    .{ -15, 11 },
    .{ -8, 11 },
    .{ 8, 11 },
    .{ 15, 11 },
    .{ 31, 12 },
    .{ -21, 13 },
    .{ -5, 13 },
    .{ 5, 13 },
    .{ 41, 13 },
    .{ -1, 14 },
    .{ 1, 14 },
    .{ 21, 14 },
    .{ -12, 15 },
    .{ 12, 15 },
    .{ -39, 17 },
    .{ -28, 17 },
    .{ -18, 17 },
    .{ -8, 17 },
    .{ 8, 17 },
    .{ 17, 18 },
    .{ -4, 19 },
    .{ 0, 19 },
    .{ 4, 19 },
    .{ 27, 19 },
    .{ 38, 20 },
    .{ -13, 21 },
    .{ 12, 22 },
    .{ -36, 23 },
    .{ -24, 23 },
    .{ -8, 24 },
    .{ 7, 24 },
    .{ -3, 25 },
    .{ 1, 25 },
    .{ 22, 25 },
    .{ 34, 26 },
    .{ -18, 28 },
    .{ -32, 29 },
    .{ 16, 29 },
    .{ -11, 31 },
    .{ 9, 32 },
    .{ 29, 32 },
    .{ -4, 33 },
    .{ 2, 33 },
    .{ -26, 34 },
    .{ 23, 36 },
    .{ -19, 39 },
    .{ 16, 40 },
    .{ -13, 41 },
    .{ 9, 42 },
    .{ -6, 43 },
    .{ 1, 43 },
    .{ 0, 0 },
    .{ 0, 0 },
    .{ 0, 0 },
};

pub const Frame = struct { pixels: []const u8, width: u16, height: u16 };

pub const Decoder = struct {
    storage: []u8,
    capacity: usize,
    key: usize = 0,
    delta: usize = 1,
    current: usize = 2,
    displayed: ?usize = null,
    last_sequence: i16 = -1,
    configured_width: ?u16 = null,
    motion: [255]i16 = @splat(0),
    tiles4: [256]u64,
    tiles8: [256]u64,
    smooth: [65536]u8 = @splat(0),

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Decoder {
        if (width == 0 or height == 0 or width > 32767 or height > 32760 or width % 8 != 0)
            return error.UnsupportedSmushDimensions;

        const capacity = @as(usize, width) * ((@as(usize, height) + 7) & ~@as(usize, 7));
        const storage = try allocator.alloc(u8, capacity * 3);

        @memset(storage, 0);

        return .{
            .storage = storage,
            .capacity = capacity,
            .tiles4 = makeTiles(4),
            .tiles8 = makeTiles(8),
        };
    }

    pub fn deinit(self: Decoder, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
    }

    pub fn decode(self: *Decoder, fobj: []const u8) !?Frame {
        return self.decodeWithFlags(fobj, 0);
    }

    pub fn decodeWithFlags(self: *Decoder, fobj: []const u8, flags: u16) !?Frame {
        if (fobj.len < 40) return error.TruncatedSmushObject;
        if (fobj[0] != 47) return error.UnsupportedSmushCodec;

        const width = le(u16, fobj[6..8]);
        const height = le(u16, fobj[8..10]);
        if (width == 0 or height == 0 or width > 32767 or height > 32760 or width % 8 != 0)
            return error.UnsupportedSmushDimensions;

        const count = @as(usize, width) * height;
        const padded = @as(usize, width) * ((@as(usize, height) + 7) & ~@as(usize, 7));
        if (padded > self.capacity) return error.SmushObjectTooLarge;

        const sequence = le(i16, fobj[14..16]);
        const mode = fobj[16];
        if (mode > 5) return error.UnsupportedSmushCompression;
        if (self.configured_width == null and sequence != 0) return error.MissingSmushKeyframe;

        var reader = Reader{ .bytes = fobj[40..] };

        if (sequence == 0) {
            self.configure(width);
            @memset(self.buffer(self.key)[0..padded], fobj[26]);
            @memset(self.buffer(self.delta)[0..padded], fobj[27]);
            self.last_sequence = -1;
        }

        if (self.configured_width != width) return error.UnsupportedSmushStrideChange;

        if (fobj[18] & 1 != 0) {
            for (0..256) |a| {
                for (a..256) |b| {
                    const color = try reader.byte();
                    self.smooth[a * 256 + b] = color;
                    self.smooth[b * 256 + a] = color;
                }
            }
        }

        if ((mode == 2 or mode == 3 or mode == 4) and flags & 0x10 != 0 and fobj[17] == 0) {
            self.last_sequence = sequence;
            return null;
        }

        const sequential = @as(i32, sequence) - self.last_sequence == 1;
        const output = self.buffer(self.current);
        var decoded = true;

        switch (mode) {
            0 => @memcpy(output[0..count], try reader.take(count)),
            1 => try self.lowKey(&reader, output, width, height),
            2 => {
                if (sequential) {
                    var y: usize = 0;

                    while (y < height) : (y += 8) {
                        var x: usize = 0;
                        while (x < width) : (x += 8)
                            try self.block(&reader, output, x + y * width, width, 8, fobj[22..26]);
                    }
                } else decoded = false;
            },
            3 => @memcpy(output[0..count], self.buffer(self.delta)[0..count]),
            4 => @memcpy(output[0..count], self.buffer(self.key)[0..count]),
            5 => {
                const expanded = le(u32, fobj[28..32]);
                if (expanded > padded) return error.InvalidSmushRleLength;
                try rle(&reader, output[0..expanded]);
            },
            else => unreachable,
        }

        if (decoded) self.displayed = self.current;

        const result: ?Frame = if (self.displayed) |index|
            .{ .pixels = self.buffer(index)[0..count], .width = width, .height = height }
        else
            null;

        if (sequential) {
            switch (fobj[17]) {
                1 => std.mem.swap(usize, &self.current, &self.delta),
                2 => {
                    const old_key = self.key;
                    self.key = self.delta;
                    self.delta = self.current;
                    self.current = old_key;
                },
                else => {},
            }
        }

        self.last_sequence = sequence;

        return result;
    }

    fn buffer(self: *Decoder, index: usize) []u8 {
        return self.storage[index * self.capacity ..][0..self.capacity];
    }

    fn configure(self: *Decoder, width: u16) void {
        if (self.configured_width == width) return;
        self.configured_width = width;
        for (motion_vectors, &self.motion) |vector, *offset|
            offset.* = @truncate(@as(i32, vector[1]) * width + vector[0]);
    }

    fn lowKey(self: *Decoder, reader: *Reader, output: []u8, width: usize, height: usize) !void {
        var y: usize = 1;

        while (y <= height) : (y += 2) {
            var previous = try reader.byte();

            output[y * width] = previous;
            output[y * width + 1] = previous;

            var x: usize = 2;

            while (x < width) : (x += 2) {
                const color = try reader.byte();
                output[y * width + x] = self.smooth[@as(usize, previous) * 256 + color];
                output[y * width + x + 1] = color;
                previous = color;
            }
        }

        @memcpy(output[0..width], output[width..][0..width]);
        y = 2;

        while (y < height) : (y += 2) {
            for (0..width) |x|
                output[y * width + x] = self.smooth[
                    @as(
                        usize,
                        output[(y - 1) * width + x],
                    ) + @as(usize, output[(y + 1) * width + x]) * 256
                ];
        }
    }

    fn block(
        self: *Decoder,
        reader: *Reader,
        output: []u8,
        position: usize,
        stride: usize,
        size: usize,
        colors: []const u8,
    ) !void {
        const opcode = try reader.byte();

        if (opcode < 0xf8 or (size == 2 and opcode == 0xfd)) {
            const source_position = @as(i64, @intCast(position)) + self.motion[opcode];
            try copyBlock(output, position, self.buffer(self.delta), source_position, stride, size);
        } else switch (opcode) {
            0xf8...0xfb => fillBlock(output, position, stride, size, colors[opcode - 0xf8]),
            0xfc => try copyBlock(
                output,
                position,
                self.buffer(self.key),
                @intCast(position),
                stride,
                size,
            ),
            0xfd => {
                const tile = try reader.byte();
                const foreground = try reader.byte();
                const background = try reader.byte();
                const mask = if (size == 8) self.tiles8[tile] else self.tiles4[tile];

                for (0..size) |y| {
                    for (0..size) |x| {
                        const bit: u6 = @intCast(y * size + x);
                        const offset: i16 = @bitCast(@as(u16, @truncate(y * stride + x)));
                        const target = @as(i64, @intCast(position)) + offset;
                        if (target < 0 or target >= output.len) return error.InvalidSmushTileOffset;

                        output[
                            @intCast(
                                target,
                            )
                        ] = if (mask & (@as(u64, 1) << bit) != 0) foreground else background;
                    }
                }
            },
            0xfe => fillBlock(output, position, stride, size, try reader.byte()),
            0xff => {
                if (size == 2) {
                    @memcpy(output[position..][0..2], try reader.take(2));
                    @memcpy(output[position + stride ..][0..2], try reader.take(2));
                } else {
                    const half = size / 2;

                    try self.block(reader, output, position, stride, half, colors);
                    try self.block(reader, output, position + half, stride, half, colors);
                    try self.block(reader, output, position + half * stride, stride, half, colors);
                    try self.block(
                        reader,
                        output,
                        position + half * stride + half,
                        stride,
                        half,
                        colors,
                    );
                }
            },
            else => unreachable,
        }
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn take(self: *Reader, count: usize) ![]const u8 {
        if (count > self.bytes.len - self.position) return error.TruncatedSmushObject;
        defer self.position += count;

        return self.bytes[self.position..][0..count];
    }

    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
};

fn fillBlock(output: []u8, position: usize, stride: usize, size: usize, color: u8) void {
    for (0..size) |y| @memset(output[position + y * stride ..][0..size], color);
}

fn copyBlock(
    output: []u8,
    position: usize,
    source: []const u8,
    source_position: i64,
    stride: usize,
    size: usize,
) !void {
    if (source_position < 0) return error.InvalidSmushMotionVector;

    const start: usize = @intCast(source_position);
    if (start > source.len or (size - 1) * stride + size > source.len - start)
        return error.InvalidSmushMotionVector;

    for (0..size) |y|
        @memcpy(output[position + y * stride ..][0..size], source[start + y * stride ..][0..size]);
}

fn rle(reader: *Reader, output: []u8) !void {
    var cursor: usize = 0;

    while (cursor < output.len) {
        const code = try reader.byte();
        const count = @min(@as(usize, code >> 1) + 1, output.len - cursor);

        if (code & 1 != 0) {
            @memset(output[cursor..][0..count], try reader.byte());
        } else {
            @memcpy(output[cursor..][0..count], try reader.take(count));
        }

        cursor += count;
    }
}

fn le(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn makeTiles(comptime size: usize) [256]u64 {
    const xs = if (size == 4) [_]i32{
        0,
        1,
        2,
        3,
        3,
        3,
        3,
        2,
        1,
        0,
        0,
        0,
        1,
        2,
        2,
        1,
    } else [_]i32{ 0, 2, 5, 7, 7, 7, 7, 7, 7, 5, 2, 0, 0, 0, 0, 0 };

    const ys = if (size == 4) [_]i32{
        0,
        0,
        0,
        0,
        1,
        2,
        3,
        3,
        3,
        3,
        2,
        1,
        1,
        1,
        2,
        2,
    } else [_]i32{ 0, 0, 0, 0, 1, 3, 4, 6, 7, 7, 7, 7, 6, 4, 3, 1 };

    var tiles: [256]u64 = @splat(0);

    for (0..16) |a| {
        for (0..16) |b| {
            const edge_a = edge(size, xs[a], ys[a]);
            const edge_b = edge(size, xs[b], ys[b]);
            const steps: i32 = @intCast(@max(@abs(xs[a] - xs[b]), @abs(ys[a] - ys[b])));
            var step: i32 = 0;

            while (step <= steps) : (step += 1) {
                const x = if (steps == 0) xs[a] else @divTrunc(
                    xs[b] * (steps - step) + xs[a] * step + @divTrunc(steps, 2),
                    steps,
                );

                const y = if (steps == 0) ys[a] else @divTrunc(
                    ys[b] * (steps - step) + ys[a] * step + @divTrunc(steps, 2),
                    steps,
                );

                const tile = &tiles[a * 16 + b];

                setPixel(tile, size, x, y);

                if ((edge_a == 2 and edge_b == 3) or (edge_b == 2 and edge_a == 3) or
                    (edge_a == 0 and edge_b != 1) or (edge_b == 0 and edge_a != 1))
                {
                    var fill_y = y;
                    while (fill_y >= 0) : (fill_y -= 1) setPixel(tile, size, x, fill_y);
                } else if ((edge_a == 1 and edge_b != 0) or (edge_b == 1 and edge_a != 0)) {
                    var fill_y = y;
                    while (fill_y < size) : (fill_y += 1) setPixel(tile, size, x, fill_y);
                } else if ((edge_a == 0 and edge_b == 1) or (edge_b == 0 and edge_a == 1) or
                    (edge_a == 3 and edge_b != 2) or (edge_b == 3 and edge_a != 2))
                {
                    var fill_x = x;
                    while (fill_x < size) : (fill_x += 1) setPixel(tile, size, fill_x, y);
                } else if ((edge_a == 2 and edge_b != 3) or (edge_b == 2 and edge_a != 3)) {
                    var fill_x = x;
                    while (fill_x >= 0) : (fill_x -= 1) setPixel(tile, size, fill_x, y);
                }
            }
        }
    }

    return tiles;
}

fn edge(comptime size: usize, x: i32, y: i32) u3 {
    if (y == 0) return 0;
    if (y == size - 1) return 1;
    if (x == 0) return 2;
    if (x == size - 1) return 3;

    return 4;
}

fn setPixel(mask: *u64, comptime size: usize, x: i32, y: i32) void {
    mask.* |= @as(u64, 1) << @as(u6, @intCast(y * @as(i32, size) + x));
}

test "block decoder rejects unsupported and truncated objects before reading" {
    var decoder = try Decoder.init(std.testing.allocator, 8, 8);
    defer decoder.deinit(std.testing.allocator);

    try std.testing.expectError(error.TruncatedSmushObject, decoder.decode(&.{}));
    var object = [_]u8{0} ** 104;

    object[0] = 47;
    object[6] = 8;
    object[8] = 8;
    object[16] = 0;

    try std.testing.expectError(error.TruncatedSmushObject, decoder.decode(object[0..42]));
    object[0] = 1;
    try std.testing.expectError(error.UnsupportedSmushCodec, decoder.decode(&object));

    object[0] = 47;
    object[6] = 7;

    try std.testing.expectError(error.UnsupportedSmushDimensions, decoder.decode(&object));

    object[6] = 8;
    object[16] = 5;
    object[28] = 65;

    try std.testing.expectError(error.InvalidSmushRleLength, decoder.decode(object[0..40]));
}

test "RLE truncates the final run and buffer rotation retains key and delta history" {
    var decoder = try Decoder.init(std.testing.allocator, 8, 8);
    defer decoder.deinit(std.testing.allocator);
    var object = [_]u8{0} ** 42;

    object[0] = 47;
    object[6] = 8;
    object[8] = 8;
    object[16] = 5;
    object[17] = 2;
    object[26] = 9;
    object[27] = 10;
    object[28] = 64;
    object[40] = 255;
    object[41] = 11;

    const first = (try decoder.decode(&object)).?;
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(11))), first.pixels);

    object[14] = 1;
    object[16] = 4;
    object[17] = 0;

    const key = (try decoder.decode(object[0..40])).?;
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(10))), key.pixels);

    object[14] = 2;
    object[16] = 3;

    const delta = (try decoder.decode(object[0..40])).?;
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(11))), delta.pixels);
}

test "delta sequence gaps retain the last displayed frame and do not rotate" {
    var decoder = try Decoder.init(std.testing.allocator, 8, 8);
    defer decoder.deinit(std.testing.allocator);
    var object = [_]u8{0} ** 104;

    object[0] = 47;
    object[6] = 8;
    object[8] = 8;
    object[17] = 1;

    for (object[40..], 0..) |*pixel, i| pixel.* = @intCast(i);

    _ = try decoder.decode(&object);
    object[14] = 2;
    object[16] = 2;
    object[17] = 2;

    const previous_current = decoder.current;
    const displayed = (try decoder.decode(object[0..40])).?;

    try std.testing.expectEqualSlices(u8, object[40..], displayed.pixels);
    try std.testing.expectEqual(previous_current, decoder.current);
}

test "all 512 generated tile masks match the reference" {
    inline for (.{
        .{ 4, "e5f649aa30ecb9fc1b7b399df530974f89a2df541c01f16d5fcf3384fcea38df" },
        .{ 8, "7595ef38daca58c1efc6d33da5ad81066bad70103bbfeb1b11d277eee045087e" },
    }) |entry| {
        const masks = makeTiles(entry[0]);
        var bytes: [256 * 8]u8 = undefined;

        for (masks, 0..) |mask, i| std.mem.writeInt(u64, bytes[i * 8 ..][0..8], mask, .little);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
        try std.testing.expectEqualStrings(entry[1], &std.fmt.bytesToHex(digest, .lower));
    }
}

test "frame skipping consumes sequence state but preserves referenced buffers" {
    var decoder = try Decoder.init(std.testing.allocator, 8, 8);
    defer decoder.deinit(std.testing.allocator);
    var object = [_]u8{0} ** 104;

    object[0] = 47;
    object[6] = 8;
    object[8] = 8;
    object[17] = 1;

    @memset(object[40..], 17);

    _ = try decoder.decode(&object);
    object[14] = 1;
    object[16] = 2;
    object[17] = 0;

    const current = decoder.current;
    const displayed = decoder.displayed;

    try std.testing.expectEqual(
        @as(?Frame, null),
        try decoder.decodeWithFlags(object[0..40], 0x10),
    );

    try std.testing.expectEqual(@as(i16, 1), decoder.last_sequence);
    try std.testing.expectEqual(current, decoder.current);
    try std.testing.expectEqual(displayed, decoder.displayed);

    object[14] = 2;
    object[40] = 0;

    const next = (try decoder.decode(object[0..41])).?;
    try std.testing.expectEqualSlices(u8, &(@as([64]u8, @splat(17))), next.pixels);
}
