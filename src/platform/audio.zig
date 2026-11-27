//! The sound output device: takes mixed PCM from the engine and gives it to
//! SDL, which converts and resamples it.
//!
//! Only the main thread touches game state. Music and effects are separate
//! streams because the effects device keeps playing while the in-level popup
//! holds the music.

const std = @import("std");
const c = @import("sdl.zig").c;
const Runtime = @import("../audio/runtime.zig").Runtime;
const asset = @import("../audio/asset.zig");
const sound = @import("../audio/engine.zig");
const mix = @import("audio_mix.zig");

pub const Device = struct {
    allocator: std.mem.Allocator,
    id: c.SDL_AudioDeviceID = 0,
    frequency: c_int = 44100,
    cache: std.AutoHashMap(u64, []f32),
    voices: [sound.voice_count]Voice = @splat(.{}),
    music: mix.Buffer = .{},
    music_samples: ?[]f32 = null,
    music_generation: u64 = 0,

    const Voice = struct { generation: u64 = 0, id: u32 = 0, frequency: u32 = 0, buffer: mix.Buffer = .{} };

    pub fn open(allocator: std.mem.Allocator) !*Device {
        if (c.SDL_InitSubSystem(c.SDL_INIT_AUDIO) != 0) return failure();
        errdefer c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        const self = try allocator.create(Device);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .cache = std.AutoHashMap(u64, []f32).init(allocator) };
        var desired = std.mem.zeroes(c.SDL_AudioSpec);
        desired.freq = 44100;
        desired.format = c.AUDIO_F32SYS;
        desired.channels = 2;
        desired.samples = 1024;
        desired.callback = callback;
        desired.userdata = self;
        var obtained: c.SDL_AudioSpec = undefined;
        self.id = c.SDL_OpenAudioDevice(null, 0, &desired, &obtained, 0);
        if (self.id == 0) return failure();
        self.frequency = obtained.freq;
        c.SDL_PauseAudioDevice(self.id, 0);
        return self;
    }

    pub fn deinit(self: *Device) void {
        c.SDL_CloseAudioDevice(self.id);
        var iterator = self.cache.valueIterator();
        while (iterator.next()) |samples| self.allocator.free(samples.*);
        self.cache.deinit();
        if (self.music_samples) |samples| self.allocator.free(samples);
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        self.allocator.destroy(self);
    }

    /// Converts what the engine's voices and music need first, without the
    /// device lock: the callback only reads the device's own voice and music
    /// buffers, never the cache. The locked part just publishes the result.
    pub fn sync(self: *Device, runtime: *Runtime) !void {
        for (&runtime.engine.voices) |*voice| {
            if (!voice.active) continue;
            _ = try self.converted(runtime, voice.asset, voice.controls.frequency_hz);
        }
        const music_changed = self.music_generation != runtime.music_generation;
        const music_samples = if (music_changed) if (runtime.music_wave) |wave| try self.convert(wave, wave.sample_rate) else null else null;
        var replaced_music: ?[]f32 = null;
        defer if (replaced_music) |samples| self.allocator.free(samples);
        errdefer if (music_samples) |samples| self.allocator.free(samples);

        c.SDL_LockAudioDevice(self.id);
        defer c.SDL_UnlockAudioDevice(self.id);
        for (&self.voices, &runtime.engine.voices) |*host, *voice| {
            if (voice.active and voice.generation == host.generation and host.buffer.complete)
                runtime.engine.complete(voice.id);
            if (!voice.active) {
                host.* = .{};
                continue;
            }
            const hz = voice.controls.frequency_hz;
            const samples = try self.converted(runtime, voice.asset, hz);
            if (host.generation != voice.generation) {
                host.* = .{ .id = voice.id, .generation = voice.generation, .frequency = hz, .buffer = .{ .samples = samples } };
            } else if (host.frequency != hz) {
                const frames = host.buffer.cursor / 2;
                host.buffer.cursor = @min(samples.len, (frames * host.frequency / hz) * 2);
                host.buffer.samples = samples;
                host.frequency = hz;
            }
            host.buffer.playing = voice.playing;
            host.buffer.loop = voice.params.flags & 1 != 0;
            host.buffer.gain = mix.gains(voice.controls.volume_db, voice.controls.pan_db);
        }
        if (music_changed) {
            replaced_music = self.music_samples;
            self.music_samples = music_samples;
            self.music = .{ .samples = music_samples orelse &.{}, .playing = true, .gain = @splat(0x3838 / @as(f32, 65535)) };
            self.music_generation = runtime.music_generation;
            runtime.musicStarted(c.SDL_GetTicks());
        }
        self.music.playing = runtime.music_wave != null and !runtime.musicPaused();
    }

    /// The device-rate samples for one sound at one playback rate, converted
    /// once and kept.
    // TODO: Bound the cache; repeated pitches of one sound each keep a copy.
    fn converted(self: *Device, runtime: *const Runtime, asset_index: u32, hz: u32) ![]f32 {
        const key = (@as(u64, asset_index) << 32) | hz;
        if (self.cache.get(key)) |samples| return samples;
        try self.cache.ensureUnusedCapacity(1);
        const samples = try self.convert(runtime.waves.items[asset_index], hz);
        self.cache.putAssumeCapacityNoClobber(key, samples);
        return samples;
    }

    fn convert(self: *Device, wave: asset.Wave, frequency: u32) ![]f32 {
        const format: c.SDL_AudioFormat = switch (wave.bits_per_sample) {
            8 => c.AUDIO_U8,
            16 => c.AUDIO_S16LSB,
            else => return error.UnsupportedWaveBits,
        };
        const stream = c.SDL_NewAudioStream(format, @intCast(wave.channels), @intCast(frequency), c.AUDIO_F32SYS, 2, self.frequency) orelse return failure();
        defer c.SDL_FreeAudioStream(stream);
        const length = wave.frameCount() * wave.block_align;
        if (length > std.math.maxInt(c_int)) return error.AudioBufferTooLarge;
        if (c.SDL_AudioStreamPut(stream, wave.pcm.ptr, @intCast(length)) != 0 or c.SDL_AudioStreamFlush(stream) != 0) return failure();
        const available = c.SDL_AudioStreamAvailable(stream);
        if (available < 0) return failure();
        if (available == 0 or @mod(available, 8) != 0) return error.InvalidConvertedAudio;
        const output = try self.allocator.alloc(f32, @intCast(@divExact(available, 4)));
        errdefer self.allocator.free(output);
        if (c.SDL_AudioStreamGet(stream, output.ptr, available) != available) return failure();
        return output;
    }

    fn callback(userdata: ?*anyopaque, stream: [*c]u8, length: c_int) callconv(.c) void {
        const self: *Device = @ptrCast(@alignCast(userdata.?));
        const bytes = stream[0..@intCast(length)];
        @memset(bytes, 0);
        const output = std.mem.bytesAsSlice(f32, @as([]align(@alignOf(f32)) u8, @alignCast(bytes)));
        for (&self.voices) |*voice| voice.buffer.mix(output);
        self.music.mix(output);
        mix.finish(output);
    }
};

fn failure() error{SdlAudioFailure} {
    std.log.err("SDL audio: {s}", .{c.SDL_GetError()});
    return error.SdlAudioFailure;
}

test "effects reach SDL PCM and completed buffers release engine voices" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(bytes);
    const runtime = try Runtime.open(a, std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", archive);
    defer runtime.deinit();
    c.SDL_SetMainReady();
    if (c.SDL_setenv("SDL_AUDIODRIVER", "dummy", 1) != 0) return failure();
    const device = try Device.open(a);
    defer device.deinit();
    c.SDL_PauseAudioDevice(device.id, 1);
    const id = (try runtime.play(.{ .basename = "RIFLOUT" }, null, 1)).?;
    try device.sync(runtime);
    var output: [2048]f32 = undefined;
    var nonzero = false;
    var chunks: usize = 0;
    while (runtime.engine.find(id) != null) : (chunks += 1) {
        if (chunks > 1000) return error.AudioDidNotComplete;
        Device.callback(device, @ptrCast(&output), @sizeOf(@TypeOf(output)));
        for (output) |sample| {
            try std.testing.expect(std.math.isFinite(sample) and @abs(sample) <= 1);
            nonzero = nonzero or sample != 0;
        }
        try device.sync(runtime);
    }
    try std.testing.expect(nonzero);
    try std.testing.expect(chunks > 1);
    const loop = (try runtime.play(.{ .basename = "DOOR3", .source = 7, .mode = .loop, .flags = 1 }, null, 2)).?;
    try device.sync(runtime);
    for (0..100) |_| Device.callback(device, @ptrCast(&output), @sizeOf(@TypeOf(output)));
    try device.sync(runtime);
    try std.testing.expect(runtime.engine.find(loop) != null);
    _ = try runtime.play(.{ .basename = "DOOR3", .source = 7, .mode = .stop }, null, 3);
    try device.sync(runtime);
    Device.callback(device, @ptrCast(&output), @sizeOf(@TypeOf(output)));
    for (output) |sample| try std.testing.expectEqual(@as(f32, 0), sample);

    const geometry_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB", a, .limited(64 * 1024 * 1024));
    defer a.free(geometry_bytes);
    const geometry = try @import("../assets/lab.zig").Archive.init(geometry_bytes);
    var level = try @import("../assets/level.zig").Level.parse(a, try geometry.find("HIDEOUT.LVB", 0));
    defer level.deinit();
    try runtime.beginLevel(std.testing.io, &level, geometry, 100);
    try std.testing.expectEqual(@as(?u32, 200982), runtime.music_deadline);
    try device.sync(runtime);
    const music_deadline = runtime.music_deadline.?;
    const wave = runtime.music_wave.?;
    try std.testing.expectEqual(wave.frameCount() * 2, device.music.samples.len);
    var frame: usize = 0;
    while (frame < wave.frameCount()) : (frame += 1) {
        const left = std.mem.readInt(i16, wave.pcm[frame * 4 ..][0..2], .little);
        if (left == 0) continue;
        device.music.cursor = frame * 2;
        Device.callback(device, @ptrCast(&output), @sizeOf(@TypeOf(output)));
        const expected = (@as(f32, @floatFromInt(left)) / 32768) * (0x3838 / @as(f32, 65535));
        try std.testing.expectApproxEqAbs(expected, output[0], 0.000001);
        break;
    }
    try std.testing.expect(frame < wave.frameCount());
    const music_cursor = device.music.cursor;
    const effect = (try runtime.play(.{ .basename = "DOOR3", .source = 8, .mode = .loop, .flags = 1 }, null, 4)).?;
    runtime.pauseMusic(music_deadline -% 5000);
    try device.sync(runtime);
    const voice_slot: usize = for (device.voices, 0..) |voice, index| {
        if (voice.id == effect) break index;
    } else return error.MissingTestVoice;
    const effect_cursor = device.voices[voice_slot].buffer.cursor;
    Device.callback(device, @ptrCast(&output), @sizeOf(@TypeOf(output)));
    try std.testing.expectEqual(music_cursor, device.music.cursor);
    try std.testing.expect(device.voices[voice_slot].buffer.cursor != effect_cursor);
    try runtime.advanceMusic(std.testing.io, music_deadline +% 10000);
    try std.testing.expectEqual(@as(u64, 1), runtime.music_generation);
    runtime.resumeMusic(music_deadline +% 10000);
    const resumed_deadline = music_deadline +% 16000;
    try std.testing.expectEqual(@as(?u32, resumed_deadline), runtime.music_deadline);
    try device.sync(runtime);
    Device.callback(device, @ptrCast(&output), @sizeOf(@TypeOf(output)));
    try std.testing.expect(device.music.cursor > music_cursor);
    try runtime.advanceMusic(std.testing.io, resumed_deadline);
    try std.testing.expectEqual(@as(u64, 1), runtime.music_generation);
    try runtime.advanceMusic(std.testing.io, resumed_deadline +% 1);
    try std.testing.expectEqual(@as(u64, 2), runtime.music_generation);
    try std.testing.expectEqual(@as(usize, 1), runtime.player.?.cue);
    runtime.endLevel();
    try device.sync(runtime);
    try std.testing.expectEqual(@as(usize, 0), device.music.samples.len);
    try std.testing.expect(!device.music.playing);
    try std.testing.expect(runtime.engine.find(effect) == null);
    try std.testing.expect(runtime.visibility == null and runtime.script == null and runtime.player == null);
    try runtime.beginLevel(std.testing.io, &level, geometry, 100);
    try std.testing.expectEqual(@as(?u32, 200982), runtime.music_deadline);
}
