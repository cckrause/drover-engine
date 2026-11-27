//! Movie playback: decoding on a deadline, the frame clock and the decision
//! to hold a frame.
//!
//! A frame is decoded before its deadline is tested. Audio normally drives
//! the clock; without an audio device the movie's own timing does.

const std = @import("std");

pub const Clock = struct {
    rate: u32 = 12,
    base_time: u32 = 0,
    last_release: u32,
    first: bool = true,
    paused: bool = false,
    displayed_frame: i32 = 0,
    consecutive_skips: u8 = 0,
    skip_decode: bool = false,
    flags: u32 = 0x40000001,
    audio_enabled: bool = false,
    stream_paused: bool = false,
    no_audio_base: u32 = 0,

    pub fn init(now: u32, rate: i16) !Clock {
        if (rate <= 0) return error.InvalidMovieFrameRate;

        return .{ .last_release = now, .rate = @intCast(rate) };
    }

    pub fn initAudio(now: u32, rate: i16) !Clock {
        var self = try init(now, rate);
        self.flags = 1;
        self.audio_enabled = true;

        return self;
    }

    pub fn audioTime(
        self: *Clock,
        now: u32,
        stream_ms: u32,
        decoded_frame: u16,
        last_audio_frame: u16,
    ) u32 {
        if (!self.audio_enabled) return now;
        if (last_audio_frame == 0 and decoded_frame > 2) {
            if (self.no_audio_base == 0)
                self.no_audio_base = now -% (@as(u32, decoded_frame) * 1000) / self.rate;

            return stream_ms +% (now -% self.no_audio_base);
        }

        return stream_ms;
    }

    pub fn setRate(self: *Clock, rate: i16, now: u32) !void {
        if (rate <= 0) return error.InvalidMovieFrameRate;
        self.rate = @intCast(rate);
        if (self.base_time != 0) self.base_time = now;
    }

    pub fn deficit(self: *const Clock, now: u32) i32 {
        if (self.first) return 1;
        const elapsed_frames = ((now -% self.base_time) *% self.rate) / 1000;

        return @as(i32, @bitCast(elapsed_frames)) -% self.displayed_frame;
    }

    pub fn due(self: *const Clock, now: u32) bool {
        return self.dueAt(now, now);
    }

    pub fn dueAt(self: *const Clock, wall_now: u32, media_now: u32) bool {
        if (self.paused) return false;

        return self.releaseDeficit(wall_now, media_now) > 0;
    }

    pub fn synchronizeAudio(self: *Clock, wall_now: u32, media_now: u32) ?bool {
        if (!self.audio_enabled or self.paused) return null;

        const late = self.releaseDeficit(wall_now, media_now);

        if (late > @as(i32, @intCast(self.rate / 2)) and !self.stream_paused) {
            self.stream_paused = true;
            return true;
        } else if (late < 1 and self.stream_paused) {
            self.stream_paused = false;
            return false;
        }

        return null;
    }

    pub fn released(self: *Clock, now: u32) void {
        self.releasedAt(now, now);
    }

    pub fn releasedAt(self: *Clock, wall_now: u32, media_now: u32) void {
        self.last_release = wall_now;

        if (self.first) {
            self.first = false;
            self.base_time = media_now;
        }
    }

    pub fn present(self: *Clock, frame_number: u16, now: u32) bool {
        const late = self.deficit(now);
        self.displayed_frame = frame_number;
        const copy = !(self.flags & 8 == 0 and late > 1 and self.consecutive_skips < 3);

        if (copy) self.consecutive_skips = 0 else self.consecutive_skips += 1;

        const after = self.deficit(now);

        if (after >= 2) {
            self.skip_decode = true;
        } else if (after == 0) {
            self.skip_decode = false;
        }

        return copy;
    }

    pub fn renderFlags(self: *const Clock) u16 {
        return if (self.skip_decode) 0x10 else 0;
    }

    pub fn togglePause(self: *Clock) void {
        self.paused = !self.paused;
        if (self.audio_enabled) self.stream_paused = self.paused;
    }

    pub fn complete(self: *const Clock, frame_count: u16, stopped: bool) bool {
        return stopped or self.displayed_frame >= @as(i32, frame_count) - 1;
    }

    fn releaseDeficit(self: *const Clock, wall_now: u32, media_now: u32) i32 {
        return if (wall_now -% self.last_release >= 201) 1 else self.deficit(media_now);
    }
};

test "silent movie clock preserves the 201ms rescue and unrebased pause" {
    var clock = try Clock.init(1000, 12);
    try std.testing.expect(clock.due(1000));
    clock.released(1000);

    try std.testing.expect(clock.present(1, 1000));
    try std.testing.expect(!clock.due(1166));
    try std.testing.expect(clock.due(1167));

    clock.togglePause();
    try std.testing.expect(!clock.due(9000));
    clock.togglePause();

    try std.testing.expect(clock.due(9000));
    try std.testing.expectEqual(@as(i32, 95), clock.deficit(9000));

    clock.released(9000);

    try std.testing.expect(!clock.present(2, 9000));
    try std.testing.expect(!clock.present(3, 9000));
    try std.testing.expect(!clock.present(4, 9000));
    try std.testing.expect(clock.present(5, 9000));
    try std.testing.expectEqual(@as(u16, 0x10), clock.renderFlags());

    var slow = try Clock.init(10, 1);
    slow.released(10);
    _ = slow.present(1, 10);

    try std.testing.expect(!slow.due(210));
    try std.testing.expect(slow.due(211));
    try std.testing.expect(!slow.complete(3, false));

    _ = slow.present(2, 211);
    try std.testing.expect(slow.complete(3, false));
}

test "reference movie clock references" {
    const allocator = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/movie-playback-reference.json",
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(data);
    const ClockCase = struct {
        first: u32,
        base: u32,
        displayed: i32,
        now: u32,
        last: u32,
        paused: u32,
        rate: i16,
        deficit: i32,
        due: bool,
        after_base: u32,
        after_last: u32,
    };

    const SkipCase = struct {
        number: u16,
        displayed: i32,
        consecutive: u8,
        skip_decode: u32,
        copy: bool,
    };

    const parsed = try std.json.parseFromSlice(
        struct { clock: []ClockCase, skips: []SkipCase },
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );

    defer parsed.deinit();

    for (parsed.value.clock) |reference| {
        var clock = try Clock.init(reference.last, reference.rate);

        clock.first = reference.first != 0;
        clock.base_time = reference.base;
        clock.displayed_frame = reference.displayed;
        clock.paused = reference.paused != 0;

        try std.testing.expectEqual(reference.deficit, clock.deficit(reference.now));
        try std.testing.expectEqual(reference.due, clock.due(reference.now));

        if (clock.due(reference.now)) clock.released(reference.now);

        try std.testing.expectEqual(reference.after_base, clock.base_time);
        try std.testing.expectEqual(reference.after_last, clock.last_release);
    }

    var clock = try Clock.init(1000, 12);
    clock.released(1000);
    _ = clock.present(1, 1000);

    for (parsed.value.skips) |reference| {
        try std.testing.expectEqual(reference.copy, clock.present(reference.number, 9000));
        try std.testing.expectEqual(reference.displayed, clock.displayed_frame);
        try std.testing.expectEqual(reference.consecutive, clock.consecutive_skips);
        try std.testing.expectEqual(reference.skip_decode != 0, clock.skip_decode);
    }
}

test "reference audio callback clocks and stream hold decisions" {
    const allocator = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/movie-playback-reference.json",
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(data);
    const Case = struct {
        first: u32,
        base: u32,
        displayed: i32,
        now: u32,
        last: u32,
        paused: u32,
        rate: i16,
        stream_paused: u32,
        decoded: u16,
        last_audio: u16,
        no_audio_base: u32,
        stream_ms: u32,
        media_time: u32,
        deficit: i32,
        due: bool,
        after_base: u32,
        after_last: u32,
        after_no_audio_base: u32,
        after_stream_paused: u32,
    };

    const parsed = try std.json.parseFromSlice(
        struct { audio_clock: []Case = &.{} },
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );

    defer parsed.deinit();
    if (parsed.value.audio_clock.len == 0) return error.SkipZigTest;

    for (parsed.value.audio_clock) |reference| {
        var clock = try Clock.initAudio(reference.last, reference.rate);

        clock.first = reference.first != 0;
        clock.base_time = reference.base;
        clock.displayed_frame = reference.displayed;
        clock.paused = reference.paused != 0;
        clock.stream_paused = reference.stream_paused != 0;
        clock.no_audio_base = reference.no_audio_base;

        const media = clock.audioTime(
            reference.now,
            reference.stream_ms,
            reference.decoded,
            reference.last_audio,
        );

        try std.testing.expectEqual(reference.media_time, media);
        try std.testing.expectEqual(reference.deficit, clock.deficit(media));

        const action = clock.synchronizeAudio(reference.now, media);
        const expected_action: ?bool = if (reference.stream_paused == reference.after_stream_paused) null else reference.after_stream_paused != 0;

        try std.testing.expectEqual(expected_action, action);
        try std.testing.expectEqual(reference.due, clock.dueAt(reference.now, media));

        if (clock.dueAt(reference.now, media)) clock.releasedAt(reference.now, media);

        try std.testing.expectEqual(reference.after_base, clock.base_time);
        try std.testing.expectEqual(reference.after_last, clock.last_release);
        try std.testing.expectEqual(reference.after_no_audio_base, clock.no_audio_base);
        try std.testing.expectEqual(reference.after_stream_paused != 0, clock.stream_paused);
    }
}

test "audio pause preserves the media baseline and resumes an automatic stream hold" {
    var clock = try Clock.initAudio(1000, 12);
    clock.releasedAt(1000, 0);
    _ = clock.present(1, 0);
    try std.testing.expectEqual(@as(?bool, true), clock.synchronizeAudio(1100, 1000));
    clock.togglePause();

    try std.testing.expect(clock.paused and clock.stream_paused);
    try std.testing.expect(!clock.dueAt(9000, 1000));
    try std.testing.expectEqual(@as(?bool, null), clock.synchronizeAudio(9000, 1000));

    clock.togglePause();

    try std.testing.expect(!clock.paused and !clock.stream_paused);
    try std.testing.expectEqual(@as(u32, 0), clock.base_time);
    try std.testing.expect(clock.dueAt(9000, 1000));
}
