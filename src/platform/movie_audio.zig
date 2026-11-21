//! The host side of movie sound: hands the decoded stream to SDL, which
//! converts the 22050 Hz stereo samples to whatever the hardware wants.
//!
//! Buffer thresholds and the stream clock live in video/audio_stream.zig.
//! PCM is published once per decoded frame, before the display deadline is
//! checked, and the campaign keeps its effects device open across movies.

const std = @import("std");
const c = @import("sdl.zig").c;
const audio = @import("../video/audio.zig");
const streaming = @import("../video/audio_stream.zig");

pub const Device = struct {
    allocator: std.mem.Allocator,
    id: c.SDL_AudioDeviceID = 0,
    stream: streaming.Stream,

    pub fn open(allocator: std.mem.Allocator) !*Device {
        if (c.SDL_InitSubSystem(c.SDL_INIT_AUDIO) != 0) return failure();
        errdefer c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        const self = try allocator.create(Device);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .stream = streaming.Stream.init(c.SDL_GetTicks()) };
        var desired = std.mem.zeroes(c.SDL_AudioSpec);
        desired.freq = audio.sample_rate;
        desired.format = c.AUDIO_S16LSB;
        desired.channels = audio.channels;
        desired.samples = 256;
        desired.callback = callback;
        desired.userdata = self;
        self.id = c.SDL_OpenAudioDevice(null, 0, &desired, null, 0);
        if (self.id == 0) return failure();
        c.SDL_PauseAudioDevice(self.id, 0);
        return self;
    }

    pub fn deinit(self: *Device) void {
        c.SDL_CloseAudioDevice(self.id);
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        self.allocator.destroy(self);
    }

    pub fn submit(self: *Device, pcm: []const u8, frame: u16, last_audio: u16, count: u16, rate: u16, now: u32) !void {
        c.SDL_LockAudioDevice(self.id);
        defer c.SDL_UnlockAudioDevice(self.id);
        try self.stream.append(pcm);
        self.stream.padTail(frame, last_audio, count, rate);
        self.stream.process(now);
    }

    pub fn time(self: *Device, now: u32) u32 {
        c.SDL_LockAudioDevice(self.id);
        defer c.SDL_UnlockAudioDevice(self.id);
        return self.stream.time(now);
    }

    pub fn setPaused(self: *Device, paused: bool, now: u32) void {
        c.SDL_LockAudioDevice(self.id);
        defer c.SDL_UnlockAudioDevice(self.id);
        if (paused) self.stream.pause() else self.stream.unpause(now);
    }

    fn callback(userdata: ?*anyopaque, output: [*c]u8, length: c_int) callconv(.c) void {
        const self: *Device = @ptrCast(@alignCast(userdata.?));
        const bytes = output[0..@intCast(length)];
        @memset(bytes, 0);
        if (!self.stream.playing) return;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const position = self.stream.play_cursor;
            const count = @min(bytes.len - offset, streaming.device_bytes - position);
            @memcpy(bytes[offset..][0..count], self.stream.device[position..][0..count]);
            self.stream.play_cursor = @intCast((position + count) % streaming.device_bytes);
            offset += count;
        }
    }
};

fn failure() error{SdlMovieAudioFailure} {
    std.log.err("SDL movie audio: {s}", .{c.SDL_GetError()});
    return error.SdlMovieAudioFailure;
}

test "SAN PCM reaches SDL unchanged and pause preserves its cursor" {
    const allocator = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/IN_SHB.SAN", allocator, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(data);
    var movie = try @import("../video/san.zig").Movie.init(allocator, data);
    defer movie.deinit(allocator);
    c.SDL_SetMainReady();
    if (c.SDL_setenv("SDL_AUDIODRIVER", "dummy", 1) != 0) return failure();
    const effects = try @import("audio.zig").Device.open(allocator);
    defer effects.deinit();
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    {
        const device = try Device.open(allocator);
        defer device.deinit();
        c.SDL_PauseAudioDevice(device.id, 1);
        while (!device.stream.playing) {
            const frame = (try movie.next()) orelse return error.MissingMovieAudio;
            try expected.appendSlice(allocator, frame.pcm);
            try device.submit(frame.pcm, frame.number, movie.last_audio_frame, movie.frame_count, movie.rate, 1000);
        }
        const available: usize = device.stream.device_write;
        try std.testing.expect(available > streaming.bytes_per_second);
        try std.testing.expect(available <= expected.items.len);
        const first_count = available / 8 * 4;
        const output = try allocator.alloc(u8, available);
        defer allocator.free(output);
        Device.callback(device, output.ptr, @intCast(first_count));
        try std.testing.expectEqualSlices(u8, expected.items[0..first_count], output[0..first_count]);
        const before_pause = device.time(1000);
        try std.testing.expect(before_pause > 0);
        try std.testing.expect(device.stream.playing);
        const cursor = device.stream.play_cursor;
        device.setPaused(true, 1000);
        var paused_output: [1024]u8 = @splat(0xa5);
        Device.callback(device, &paused_output, paused_output.len);
        try std.testing.expectEqualSlices(u8, &([_]u8{0} ** paused_output.len), &paused_output);
        try std.testing.expectEqual(cursor, device.stream.play_cursor);
        try std.testing.expectEqual(before_pause, device.time(9000));
        device.setPaused(false, 9000);
        try std.testing.expectEqual(cursor, device.stream.play_cursor);
        Device.callback(device, output[first_count..].ptr, @intCast(available - first_count));
        try std.testing.expectEqualSlices(u8, expected.items[0..available], output);
        try std.testing.expect(device.time(9001) >= before_pause);
        var nonzero = false;
        for (output) |byte| nonzero = nonzero or byte != 0;
        try std.testing.expect(nonzero);
    }
    try std.testing.expect(c.SDL_GetAudioDeviceStatus(effects.id) == c.SDL_AUDIO_PLAYING);
    const reopened = try Device.open(allocator);
    defer reopened.deinit();
    c.SDL_PauseAudioDevice(reopened.id, 1);
    var silence: [1024]u8 = @splat(0xa5);
    Device.callback(reopened, &silence, silence.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** silence.len), &silence);
    try std.testing.expectEqual(@as(u32, 0), reopened.stream.play_cursor);
    try std.testing.expectEqual(@as(u32, 0), reopened.stream.source_write);
}
