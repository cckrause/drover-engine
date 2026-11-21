//! The ring buffer between the movie's decoded sound and the output device.
//!
//! The device only reads; the play cursor advances as it consumes. Buffer
//! thresholds decide when the movie must wait for the sound to catch up.

const std = @import("std");
const audio = @import("audio.zig");

pub const bytes_per_second: u32 = audio.sample_rate * audio.channels * 2;

pub const device_bytes: u32 = bytes_per_second * 5;

pub const Stream = struct {
    source: [audio.ring_bytes]u8 = @splat(0),
    device: [device_bytes]u8 = @splat(0),
    source_write: u32 = 0,
    source_read: u32 = 0,
    device_write: u32 = 0,
    play_cursor: u32 = 0,
    last_cursor: u32 = 0,
    wraps: u32 = 0,
    cursor_time: u32 = 0,
    sampled_at: u32,
    returned_time: u32 = 0,
    resume_at: u32 = bytes_per_second,
    buffering: bool = true,
    paused: bool = false,
    playing: bool = false,

    pub fn init(now: u32) Stream {
        return .{ .sampled_at = now };
    }

    pub fn append(self: *Stream, pcm: []const u8) !void {
        if (pcm.len % audio.block_bytes != 0) return error.InvalidMovieAudioPcmLength;
        const pending = self.source_write -% self.source_read;
        if (pending > audio.ring_bytes or pcm.len > audio.ring_bytes - pending)
            return error.MovieAudioRingOverflow;
        var offset: usize = 0;
        while (offset < pcm.len) {
            const index = self.source_write % audio.ring_bytes;
            const length = @min(pcm.len - offset, audio.ring_bytes - index);
            @memcpy(self.source[index..][0..length], pcm[offset..][0..length]);
            self.source_write +%= @intCast(length);
            offset += length;
        }
    }

    pub fn padTail(self: *Stream, frame: u16, last_audio_frame: u16, frame_count: u16, rate: u16) void {
        if (@as(i32, frame) - @as(i32, last_audio_frame) <= 5) return;
        const product = @as(i32, @bitCast(self.source_write)) *% @as(i32, rate);
        if (@as(i32, frame_count) - 1 > @divTrunc(product, bytes_per_second)) return;
        const available: i32 = @bitCast(self.source_read -% self.source_write +% audio.ring_bytes);
        if (available <= audio.block_bytes) return;
        var count = (@as(u32, @intCast(available)) - 1) >> 12;
        while (count > 0) : (count -= 1) {
            const index = self.source_write % audio.ring_bytes;
            @memset(self.source[index..][0..audio.block_bytes], 0);
            self.source_write +%= audio.block_bytes;
        }
    }

    pub fn time(self: *Stream, now: u32) u32 {
        if (self.last_cursor != self.play_cursor) {
            if (self.play_cursor < self.last_cursor) self.wraps +%= 1;
            const position = self.play_cursor +% device_bytes *% self.wraps;
            const milliseconds_per_byte: f64 = 1000.0 / @as(f64, bytes_per_second);
            self.cursor_time = @intFromFloat(@as(f80, @floatFromInt(position)) * @as(f80, milliseconds_per_byte));
            self.last_cursor = self.play_cursor;
            self.sampled_at = now;
            if (!self.buffering) {
                const threshold = position +% (bytes_per_second * 500 / 1000);
                if (self.device_write < threshold) {
                    self.playing = false;
                    self.buffering = true;
                    self.resume_at = threshold;
                }
            }
        }
        var result = self.cursor_time;
        if (!self.buffering and !self.paused)
            result = (self.cursor_time -% self.sampled_at) +% now;
        if (self.returned_time <= result) self.returned_time = result;
        return self.returned_time;
    }

    pub fn process(self: *Stream, now: u32) void {
        _ = self.time(now);
        const position = self.wraps *% device_bytes +% self.last_cursor;
        const device_available: i32 = @bitCast(((position -% self.device_write) +% device_bytes) -% 0x1000);
        const source_available: i32 = @bitCast((self.source_write -% self.source_read) -% 0x400);
        const available = @min(device_available, source_available);
        if (available <= 0) return;
        var remaining: u32 = @intCast(available);
        while (remaining > 0) {
            const source_index = self.source_read % audio.ring_bytes;
            const device_index = self.device_write % device_bytes;
            const count = @min(remaining, audio.ring_bytes - source_index, device_bytes - device_index);
            @memcpy(self.device[device_index..][0..count], self.source[source_index..][0..count]);
            self.source_read +%= count;
            self.device_write +%= count;
            remaining -= count;
        }
        if (self.buffering and @as(i32, @bitCast(self.resume_at)) < @as(i32, @bitCast(self.device_write))) {
            self.playing = true;
            self.play_cursor = self.last_cursor;
            self.buffering = false;
            self.sampled_at = now;
        }
    }

    pub fn pause(self: *Stream) void {
        self.playing = false;
        self.paused = true;
    }

    pub fn unpause(self: *Stream, now: u32) void {
        self.paused = false;
        self.sampled_at = now;
        self.playing = true;
        self.play_cursor = self.last_cursor;
    }
};

const ReferenceState = struct {
    source_written: u32,
    source_read: u32,
    device_written: u32,
    wraps: u32,
    resume_at: u32,
    previous_cursor: u32,
    last_tick: u32,
    cursor_ms: u32,
    monotonic_ms: u32,
    buffering: u32,
    paused: u32,

    fn apply(self: ReferenceState, stream: *Stream) void {
        stream.source_write = self.source_written;
        stream.source_read = self.source_read;
        stream.device_write = self.device_written;
        stream.wraps = self.wraps;
        stream.resume_at = self.resume_at;
        stream.last_cursor = self.previous_cursor;
        stream.play_cursor = self.previous_cursor;
        stream.sampled_at = self.last_tick;
        stream.cursor_time = self.cursor_ms;
        stream.returned_time = self.monotonic_ms;
        stream.buffering = self.buffering != 0;
        stream.paused = self.paused != 0;
        stream.playing = !stream.buffering and !stream.paused;
    }

    fn check(self: ReferenceState, stream: *const Stream) !void {
        try std.testing.expectEqual(self, ReferenceState{
            .source_written = stream.source_write,
            .source_read = stream.source_read,
            .device_written = stream.device_write,
            .wraps = stream.wraps,
            .resume_at = stream.resume_at,
            .previous_cursor = stream.last_cursor,
            .last_tick = stream.sampled_at,
            .cursor_ms = stream.cursor_time,
            .monotonic_ms = stream.returned_time,
            .buffering = @intFromBool(stream.buffering),
            .paused = @intFromBool(stream.paused),
        });
    }
};

fn expectHash(expected: []const u8, bytes: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(&digest, .lower);
    try std.testing.expectEqualStrings(expected, &actual);
}

test "movie stream rejects partial PCM blocks and source-ring overwrite" {
    const allocator = std.testing.allocator;
    const stream = try allocator.create(Stream);
    defer allocator.destroy(stream);
    stream.* = Stream.init(0);
    try std.testing.expectError(error.InvalidMovieAudioPcmLength, stream.append(&.{0}));
    const pcm: [audio.block_bytes]u8 = @splat(37);
    for (0..audio.ring_bytes / audio.block_bytes) |_| try stream.append(&pcm);
    try std.testing.expectError(error.MovieAudioRingOverflow, stream.append(&pcm));
    stream.process(1000);
    try stream.append(&pcm);
    try std.testing.expectEqualSlices(u8, &pcm, stream.source[0..pcm.len]);
}

test "movie stream ring copies and timing match the reference" {
    const allocator = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/movie-stream-reference.json", allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(data);
    const HostCall = struct {
        call: []const u8,
        cursor: ?u32 = null,
    };
    const Step = struct {
        op: []const u8,
        now: u32,
        cursor: u32,
        source_written: ?u32 = null,
        result: ?u32 = null,
        state: ReferenceState,
        host_calls: []const HostCall,
        device_sha256: []const u8,
    };
    const Scenario = struct { name: []const u8, initial: ReferenceState, steps: []const Step };
    const Tail = struct {
        frame: u16,
        last_audio_frame: u16,
        frame_count: u16,
        rate: u16,
        source_written: u32,
        source_read: u32,
        after_written: u32,
        after_read: u32,
        source_sha256: []const u8,
    };
    const parsed = try std.json.parseFromSlice(struct { scenarios: []const Scenario, tails: []const Tail }, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const stream = try allocator.create(Stream);
    defer allocator.destroy(stream);
    for (parsed.value.scenarios) |scenario| {
        stream.* = Stream.init(1000);
        scenario.initial.apply(stream);
        for (&stream.source, 0..) |*byte, index| byte.* = @truncate(index * 37 + (index >> 5) * 11 + 7);
        var playing = stream.playing;
        for (scenario.steps) |step| {
            stream.play_cursor = step.cursor;
            var cursor = step.cursor;
            if (step.source_written) |written| stream.source_write = written;
            if (std.mem.eql(u8, step.op, "process")) {
                stream.process(step.now);
            } else if (std.mem.eql(u8, step.op, "time")) {
                try std.testing.expectEqual(step.result.?, stream.time(step.now));
            } else if (std.mem.eql(u8, step.op, "pause")) {
                stream.pause();
            } else if (std.mem.eql(u8, step.op, "resume")) {
                stream.unpause(step.now);
            } else return error.InvalidMovieStreamReference;
            for (step.host_calls) |call| {
                if (std.mem.eql(u8, call.call, "play")) playing = true;
                if (std.mem.eql(u8, call.call, "stop")) playing = false;
                if (std.mem.eql(u8, call.call, "set_cursor")) cursor = call.cursor.?;
            }
            try step.state.check(stream);
            try std.testing.expectEqual(playing, stream.playing);
            try std.testing.expectEqual(cursor, stream.play_cursor);
            try expectHash(step.device_sha256, &stream.device);
        }
    }
    for (parsed.value.tails) |tail| {
        stream.* = Stream.init(0);
        @memset(&stream.source, 0xa5);
        stream.source_write = tail.source_written;
        stream.source_read = tail.source_read;
        stream.padTail(tail.frame, tail.last_audio_frame, tail.frame_count, tail.rate);
        try std.testing.expectEqual(tail.after_written, stream.source_write);
        try std.testing.expectEqual(tail.after_read, stream.source_read);
        try expectHash(tail.source_sha256, &stream.source);
    }
}
