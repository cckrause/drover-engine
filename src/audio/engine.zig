//! Playing instances: volume, priority, position and the parameters the
//! output device gets.
//!
//! Point sounds carry their position so the device can place them; a request
//! without one is unplaced and is never spatialised.

const std = @import("std");
const limits = @import("../memory/limits.zig");

pub const instance_count = limits.current.sound_instances;
pub const voice_count = limits.current.sound_voices;

pub const Flags = struct {
    pub const loop: u32 = 1;

    pub const paused: u32 = 2;

    pub const spatial: u32 = 4;

    pub const ambient: u32 = 0x10;

    pub const effects: u32 = 0x10000;

    pub const speech: u32 = 0x20000;
};

pub const Params = struct {
    flags: u32 = Flags.effects,
    volume: i8 = 127,
    pan: i8 = 0,
    priority: i8 = 64,
    frequency_factor: f32 = 1,
    position: [3]f32 = .{ 0, 0, 0 },
    velocity: [3]f32 = .{ 0, 0, 0 },
};

pub const Listener = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    velocity: [3]f32 = .{ 0, 0, 0 },
    yaw: f32 = 0,
};

pub const Controls = struct {
    volume_db: i32 = 0,
    pan_db: i32 = 0,
    frequency_hz: u32 = 0,
};

pub const Voice = struct {
    active: bool = false,
    playing: bool = false,
    id: u32 = 0,
    asset: u32 = 0,
    generation: u64 = 0,
    started_at: u32 = 0,
    sample_rate: u32 = 0,
    params: Params = .{},
    effective_volume: i32 = 0,
    effective_pan: i32 = 0,
    controls: Controls = .{},
};

pub const Spatial = struct { volume: i32, pan: i32 };

pub const Engine = struct {
    voices: [voice_count]Voice = @splat(.{}),
    listener: Listener = .{},
    effects_volume: i32 = 127,
    speech_volume: i32 = 127,
    maximum_distance: f32 = 255,
    next_id: u32 = 0,
    allocated: [instance_count]bool = @splat(false),
    generation: u64 = 0,
    paused: bool = false,

    pub fn find(self: *Engine, id: u32) ?*Voice {
        if (id == 0) return null;
        for (&self.voices) |*voice| if (voice.active and voice.id == id) return voice;
        return null;
    }

    pub fn start(self: *Engine, asset: u32, sample_rate: u32, params: Params, now: u32) !?u32 {
        try validate(params, sample_rate);
        const id = self.allocateInstance() orelse return null;
        return self.admit(id, asset, sample_rate, params, now);
    }

    pub fn allocateInstance(self: *Engine) ?u32 {
        var id = self.next_id;
        for (0..instance_count - 1) |_| {
            id += 1;
            if (id >= instance_count) id = 1;
            if (!self.allocated[id] and self.find(id) == null) {
                self.allocated[id] = true;
                self.next_id = id;
                return id;
            }
        }
        return null;
    }

    pub fn admit(self: *Engine, id: u32, asset: u32, sample_rate: u32, params: Params, now: u32) !?u32 {
        if (id == 0 or id >= instance_count or !self.allocated[id] or self.find(id) != null) return error.InvalidSoundInstance;
        try validate(params, sample_rate);
        const values = self.evaluate(params);
        if (values.volume < 1) {
            self.allocated[id] = false;
            return null;
        }
        const selected = self.selectVoice(params.priority, now) orelse {
            self.allocated[id] = false;
            return null;
        };
        if (selected.active) self.allocated[selected.id] = false;
        self.generation +%= 1;
        selected.* = .{
            .active = true,
            .playing = params.flags & Flags.paused == 0,
            .id = id,
            .asset = asset,
            .generation = self.generation,
            .started_at = now,
            .sample_rate = sample_rate,
            .params = params,
            .effective_volume = values.volume,
            .effective_pan = values.pan,
        };
        apply(selected);
        return id;
    }

    pub fn stop(self: *Engine, id: u32) void {
        if (id != 0 and id < instance_count) self.allocated[id] = false;
        if (self.find(id)) |voice| voice.* = .{};
    }

    pub fn complete(self: *Engine, id: u32) void {
        self.stop(id);
    }

    pub fn stopAll(self: *Engine) void {
        @memset(&self.allocated, false);
        for (&self.voices) |*voice| voice.* = .{};
    }

    pub fn adjust(self: *Engine, id: u32, params: Params) !void {
        const voice = self.find(id) orelse return;
        try validate(params, voice.sample_rate);
        const values = self.evaluate(params);
        if (values.volume < 1) {
            self.allocated[id] = false;
            voice.* = .{};
            return;
        }
        const previous_flags = voice.params.flags;
        voice.params = params;
        voice.effective_volume = values.volume;
        voice.effective_pan = values.pan;
        const changed = previous_flags ^ params.flags;
        if (changed & Flags.loop != 0) {
            if (previous_flags & Flags.paused == 0) voice.playing = false;
            if (params.flags & Flags.paused != 0) return;
            apply(voice);
            voice.playing = true;
        } else if (changed & Flags.paused != 0) {
            if (previous_flags & Flags.paused != 0) {
                apply(voice);
                voice.playing = true;
            } else voice.playing = false;
        }
    }

    pub fn updateListener(self: *Engine, listener: Listener) !void {
        try validateVector(listener.position);
        try validateVector(listener.velocity);
        if (!std.math.isFinite(listener.yaw)) return error.InvalidAudioListener;
        self.listener = listener;
        if (self.paused) return;
        for (&self.voices) |*voice| {
            if (!voice.active or voice.params.flags & Flags.spatial == 0) continue;
            const values = self.evaluate(voice.params);
            voice.effective_volume = @max(1, values.volume);
            voice.effective_pan = values.pan;
            apply(voice);
        }
    }

    pub fn pausePlayback(self: *Engine) void {
        self.paused = true;
        for (&self.voices) |*voice| if (voice.active) {
            voice.playing = false;
        };
    }

    pub fn resumePlayback(self: *Engine) void {
        self.paused = false;
        for (&self.voices) |*voice| if (voice.active) {
            voice.playing = true;
        };
    }

    fn selectVoice(self: *Engine, requested_priority: i32, now: u32) ?*Voice {
        var priority = requested_priority;
        var timestamp = now;
        var selected: ?*Voice = null;
        var i: usize = self.voices.len;
        while (i != 0) {
            i -= 1;
            const voice = &self.voices[i];
            if (!voice.active) return voice;
            if (voice.params.priority <= priority and (voice.params.priority != priority or @as(i32, @bitCast(voice.started_at)) <= @as(i32, @bitCast(timestamp)))) {
                timestamp = if (priority != voice.params.priority) timestamp else voice.started_at;
                priority = voice.params.priority;
                selected = voice;
            }
        }
        return selected;
    }

    fn evaluate(self: *const Engine, params: Params) Spatial {
        const group = if (params.flags & Flags.speech != 0) self.speech_volume else self.effects_volume;
        const volume = @divTrunc(group * @as(i32, params.volume), 127);
        if (params.flags & Flags.spatial != 0)
            return spatial(params.position, self.listener, volume, self.effects_volume, self.maximum_distance);
        return .{ .volume = volume, .pan = params.pan };
    }
};

pub fn volumeDb(volume: i32) i32 {
    const v = std.math.clamp(volume, 0, 127);
    const low = [_]i32{ -10000, -7000, -6000, -5200, -5000, -4500, -4200, -4100 };
    if (v < 8) return low[@intCast(v)];
    if (v < 32) return @divTrunc((v - 8) * 2000, 23) - 4000;
    if (v < 64) return @divTrunc((v - 32) * 1000, 31) - 2000;
    return @divTrunc((v - 64) * 1000, 63) - 1000;
}

pub fn panDb(pan: i32) i32 {
    const p = std.math.clamp(pan, -127, 127);
    return if (p < 0) volumeDb(128 + p) else -volumeDb(127 - p);
}

pub fn distance(source: [3]f32, listener: [3]f32) f64 {
    const dx: f32 = listener[0] - source[0];
    const dz: f32 = listener[2] - source[2];
    const x: f64 = @abs(dx);
    const z: f64 = @abs(dz);
    return (z - @min(x, z) * 0.5) + x + @abs(@as(f64, listener[1]) - source[1]);
}

pub fn spatial(source: [3]f32, listener: Listener, volume: i32, effects_volume: i32, maximum_distance: f32) Spatial {
    const unrounded_distance = distance(source, listener.position);
    if (unrounded_distance > maximum_distance) return .{ .volume = 0, .pan = 0 };
    const d: f32 = @floatCast(unrounded_distance);
    var result: Spatial = .{ .volume = volume, .pan = 0 };
    if (d >= 150) {
        result.volume = 0;
    } else if (d >= 30) {
        const reciprocal: f32 = @bitCast(@as(u32, 0x3c088889));
        result.volume = @intFromFloat((120.0 - (@min(@as(f64, d), 150.0) - 30.0)) * @as(f64, reciprocal) * @as(f64, @floatFromInt(volume)));
    }
    if (@divTrunc(effects_volume * 85, 100) < result.volume or result.volume < 1) return result;
    var z: f32 = source[2] - listener.position[2];
    var x: f32 = source[0] - listener.position[0];
    const zb: u32 = @bitCast(z);
    const xb: u32 = @bitCast(x);
    if (zb < 0xbf000000 and @as(i32, @bitCast(zb)) < 0x3f000000) {
        z = if (zb <= 0x80000000) 0.5 else -0.5;
    } else if (xb < 0xbf000000 and @as(i32, @bitCast(xb)) < 0x3f000000) {
        x = if (xb <= 0x80000000) 0.5 else -0.5;
    }
    const angle: f32 = @floatCast(std.math.atan2(@as(f64, x), @as(f64, z)));
    const p: i32 = @intFromFloat(@sin(@as(f64, angle) - listener.yaw) * 128.0);
    result.pan = std.math.clamp(p, -127, 127);
    return result;
}

pub fn gameListener(position: [3]f32, velocity: [3]f32, yaw: i16) Listener {
    const turns = @as(f64, @floatFromInt(yaw)) * @as(f32, 6.1035156e-05);
    return .{ .position = position, .velocity = velocity, .yaw = @floatCast(turns * @as(f32, 6.2831855)) };
}

pub fn gameParams(priority: i8, volume: i8, game_flags: u32, position: ?[3]f32) !Params {
    if (game_flags & ~(1 | @as(u32, 4) | 0x10 | 0x80000000) != 0) return error.UnsupportedGameAudioFlags;
    var result: Params = .{ .priority = priority, .volume = volume };
    if (game_flags & 1 != 0) result.flags |= Flags.loop;
    if (position) |p| {
        result.position = p;
        result.flags |= Flags.spatial;
    }
    return result;
}

fn validate(params: Params, sample_rate: u32) !void {
    if (params.flags & ~(Flags.loop | Flags.paused | Flags.spatial | Flags.ambient | Flags.effects | Flags.speech) != 0) return error.UnsupportedAudioFlags;
    if (!std.math.isFinite(params.frequency_factor) or params.frequency_factor <= 0 or sample_rate == 0 or sample_rate > std.math.maxInt(i32)) return error.InvalidAudioFrequency;
    const frequency = @as(f64, @floatFromInt(sample_rate)) * params.frequency_factor;
    if (frequency < 1 or frequency >= 2147483648.0) return error.InvalidAudioFrequency;
    try validateVector(params.position);
    try validateVector(params.velocity);
}

fn validateVector(value: [3]f32) !void {
    for (value) |v| if (!std.math.isFinite(v)) return error.InvalidAudioPosition;
}

fn apply(voice: *Voice) void {
    voice.effective_volume = std.math.clamp(voice.effective_volume, 0, 127);
    voice.effective_pan = std.math.clamp(voice.effective_pan, -127, 127);
    voice.controls = .{
        .volume_db = volumeDb(voice.effective_volume),
        .pan_db = panDb(voice.effective_pan),
        .frequency_hz = @intFromFloat(@as(f64, @floatFromInt(voice.sample_rate)) * voice.params.frequency_factor),
    };
}

test "sound driver volume and pan tables match the reference initialization" {
    var volumes: [128 * 4]u8 = undefined;
    var pans: [255 * 4]u8 = undefined;
    for (0..128) |i| std.mem.writeInt(i32, volumes[i * 4 ..][0..4], volumeDb(@intCast(i)), .little);
    for (0..255) |i| std.mem.writeInt(i32, pans[i * 4 ..][0..4], panDb(@as(i32, @intCast(i)) - 127), .little);
    var actual: [32]u8 = undefined;
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&volumes, &actual, .{});
    _ = try std.fmt.hexToBytes(&expected, "ce6af2faae0f7b1901b9a4b70acfb5605b3382920a8b0f8119c87edc62c331c6");
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    std.crypto.hash.sha2.Sha256.hash(&pans, &actual, .{});
    _ = try std.fmt.hexToBytes(&expected, "a1570006f83a8827d3d18464106fb1885376fdd5dba3f14034ee27dec114b3b6");
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "sound driver spatialization matches independent reference results" {
    const Case = struct {
        source: [3]f32,
        yaw: f32,
        volume: i32,
        effects: i32,
        expected: Spatial,
    };
    const cases = [_]Case{
        .{ .source = .{ 0.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 127, .pan = 0 } },
        .{ .source = .{ 29.999, 0.0, 0.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 127, .pan = 0 } },
        .{ .source = .{ 30.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 127, .pan = 0 } },
        .{ .source = .{ 45.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 111, .pan = 0 } },
        .{ .source = .{ 60.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 95, .pan = 127 } },
        .{ .source = .{ 90.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 63, .pan = 127 } },
        .{ .source = .{ 149.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 1, .pan = 127 } },
        .{ .source = .{ 150.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 0, .pan = 0 } },
        .{ .source = .{ 45.0, 0.0, 30.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 95, .pan = 106 } },
        .{ .source = .{ -45.0, 0.0, 30.0 }, .yaw = 0.0, .volume = 127, .effects = 127, .expected = .{ .volume = 95, .pan = -106 } },
        .{ .source = .{ 0.0, 0.0, -45.0 }, .yaw = 0.0, .volume = 64, .effects = 127, .expected = .{ .volume = 56, .pan = 1 } },
        .{ .source = .{ 0.0, 0.0, 45.0 }, .yaw = 0.0, .volume = 64, .effects = 127, .expected = .{ .volume = 56, .pan = 1 } },
        .{ .source = .{ 0.0, 45.0, 0.0 }, .yaw = 0.0, .volume = 64, .effects = 127, .expected = .{ .volume = 56, .pan = 0 } },
        .{ .source = .{ -0.0, 45.0, -0.0 }, .yaw = 0.0, .volume = 64, .effects = 127, .expected = .{ .volume = 56, .pan = 0 } },
        .{ .source = .{ 0.25, 45.0, -0.25 }, .yaw = 0.0, .volume = 64, .effects = 127, .expected = .{ .volume = 55, .pan = 57 } },
        .{ .source = .{ -0.25, 45.0, 0.25 }, .yaw = 0.0, .volume = 64, .effects = 127, .expected = .{ .volume = 55, .pan = -57 } },
        .{ .source = .{ 60.0, 0.0, 0.0 }, .yaw = 1.57079637, .volume = 127, .effects = 127, .expected = .{ .volume = 95, .pan = -1 } },
        .{ .source = .{ 60.0, 0.0, 0.0 }, .yaw = -1.57079637, .volume = 127, .effects = 127, .expected = .{ .volume = 95, .pan = 1 } },
        .{ .source = .{ 60.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 64, .effects = 64, .expected = .{ .volume = 48, .pan = 127 } },
        .{ .source = .{ 10.0, 0.0, 0.0 }, .yaw = 0.0, .volume = 64, .effects = 127, .expected = .{ .volume = 64, .pan = 127 } },
    };
    for (cases) |c| try std.testing.expectEqual(c.expected, spatial(c.source, .{ .yaw = c.yaw }, c.volume, c.effects, 255));
}

test "sound driver reverse buffer scan preserves priority and timestamp quirks" {
    var engine: Engine = .{};
    engine.voices = @splat(.{});
    engine.voices[0] = .{ .active = false, .started_at = 0, .params = .{ .priority = 64 } };
    engine.voices[1] = .{ .active = false, .started_at = 1, .params = .{ .priority = 64 } };
    engine.voices[2] = .{ .active = false, .started_at = 2, .params = .{ .priority = 64 } };
    engine.voices[3] = .{ .active = false, .started_at = 3, .params = .{ .priority = 64 } };
    engine.voices[4] = .{ .active = false, .started_at = 4, .params = .{ .priority = 64 } };
    engine.voices[5] = .{ .active = false, .started_at = 5, .params = .{ .priority = 64 } };
    engine.voices[6] = .{ .active = false, .started_at = 6, .params = .{ .priority = 64 } };
    engine.voices[7] = .{ .active = false, .started_at = 7, .params = .{ .priority = 64 } };
    try std.testing.expect(engine.selectVoice(64, 1000).? == &engine.voices[7]);
    engine.voices = @splat(.{});
    engine.voices[0] = .{ .active = true, .started_at = 0, .params = .{ .priority = 64 } };
    engine.voices[1] = .{ .active = true, .started_at = 1, .params = .{ .priority = 64 } };
    engine.voices[2] = .{ .active = true, .started_at = 2, .params = .{ .priority = 64 } };
    engine.voices[3] = .{ .active = true, .started_at = 3, .params = .{ .priority = 64 } };
    engine.voices[4] = .{ .active = true, .started_at = 4, .params = .{ .priority = 64 } };
    engine.voices[5] = .{ .active = true, .started_at = 5, .params = .{ .priority = 64 } };
    engine.voices[6] = .{ .active = true, .started_at = 6, .params = .{ .priority = 64 } };
    engine.voices[7] = .{ .active = true, .started_at = 7, .params = .{ .priority = 64 } };
    try std.testing.expect(engine.selectVoice(63, 1000) == null);
    engine.voices = @splat(.{});
    engine.voices[0] = .{ .active = true, .started_at = 0, .params = .{ .priority = 64 } };
    engine.voices[1] = .{ .active = true, .started_at = 1, .params = .{ .priority = 64 } };
    engine.voices[2] = .{ .active = true, .started_at = 2, .params = .{ .priority = 64 } };
    engine.voices[3] = .{ .active = true, .started_at = 3, .params = .{ .priority = 64 } };
    engine.voices[4] = .{ .active = true, .started_at = 4, .params = .{ .priority = 64 } };
    engine.voices[5] = .{ .active = true, .started_at = 5, .params = .{ .priority = 64 } };
    engine.voices[6] = .{ .active = true, .started_at = 6, .params = .{ .priority = 64 } };
    engine.voices[7] = .{ .active = true, .started_at = 7, .params = .{ .priority = 64 } };
    try std.testing.expect(engine.selectVoice(64, 1000).? == &engine.voices[0]);
    engine.voices = @splat(.{});
    engine.voices[0] = .{ .active = true, .started_at = 42, .params = .{ .priority = 64 } };
    engine.voices[1] = .{ .active = true, .started_at = 42, .params = .{ .priority = 64 } };
    engine.voices[2] = .{ .active = true, .started_at = 42, .params = .{ .priority = 64 } };
    engine.voices[3] = .{ .active = true, .started_at = 42, .params = .{ .priority = 64 } };
    engine.voices[4] = .{ .active = true, .started_at = 42, .params = .{ .priority = 64 } };
    engine.voices[5] = .{ .active = true, .started_at = 42, .params = .{ .priority = 64 } };
    engine.voices[6] = .{ .active = true, .started_at = 42, .params = .{ .priority = 64 } };
    engine.voices[7] = .{ .active = true, .started_at = 42, .params = .{ .priority = 64 } };
    try std.testing.expect(engine.selectVoice(64, 1000).? == &engine.voices[0]);
    engine.voices = @splat(.{});
    engine.voices[0] = .{ .active = true, .started_at = 2, .params = .{ .priority = 107 } };
    engine.voices[1] = .{ .active = true, .started_at = 3, .params = .{ .priority = 64 } };
    engine.voices[2] = .{ .active = true, .started_at = 100, .params = .{ .priority = 1 } };
    engine.voices[3] = .{ .active = true, .started_at = 5, .params = .{ .priority = 64 } };
    engine.voices[4] = .{ .active = true, .started_at = 6, .params = .{ .priority = 107 } };
    engine.voices[5] = .{ .active = true, .started_at = 50, .params = .{ .priority = 1 } };
    engine.voices[6] = .{ .active = true, .started_at = 7, .params = .{ .priority = 64 } };
    engine.voices[7] = .{ .active = true, .started_at = 25, .params = .{ .priority = 1 } };
    try std.testing.expect(engine.selectVoice(64, 1000).? == &engine.voices[5]);
    engine.voices = @splat(.{});
    engine.voices[0] = .{ .active = true, .started_at = 4294967280, .params = .{ .priority = 64 } };
    engine.voices[1] = .{ .active = true, .started_at = 1, .params = .{ .priority = 64 } };
    engine.voices[2] = .{ .active = true, .started_at = 2, .params = .{ .priority = 64 } };
    engine.voices[3] = .{ .active = true, .started_at = 3, .params = .{ .priority = 64 } };
    engine.voices[4] = .{ .active = true, .started_at = 4, .params = .{ .priority = 64 } };
    engine.voices[5] = .{ .active = true, .started_at = 5, .params = .{ .priority = 64 } };
    engine.voices[6] = .{ .active = true, .started_at = 6, .params = .{ .priority = 64 } };
    engine.voices[7] = .{ .active = true, .started_at = 7, .params = .{ .priority = 64 } };
    try std.testing.expect(engine.selectVoice(64, 10).? == &engine.voices[0]);
}

test "sound driver control application matches DirectSound calls" {
    const Case = struct {
        volume: i32,
        pan: i32,
        rate: u32,
        factor: f32,
        expected: Controls,
    };
    const cases = [_]Case{
        .{ .volume = 127, .pan = 0, .rate = 11025, .factor = 1.0, .expected = .{ .volume_db = 0, .pan_db = 0, .frequency_hz = 11025 } },
        .{ .volume = 63, .pan = -127, .rate = 22050, .factor = 1.0, .expected = .{ .volume_db = -1000, .pan_db = -7000, .frequency_hz = 22050 } },
        .{ .volume = 64, .pan = 127, .rate = 22050, .factor = 1.3333334, .expected = .{ .volume_db = -1000, .pan_db = 10000, .frequency_hz = 29400 } },
        .{ .volume = 500, .pan = -500, .rate = 44100, .factor = 0.75, .expected = .{ .volume_db = 0, .pan_db = -7000, .frequency_hz = 33075 } },
        .{ .volume = -1, .pan = 500, .rate = 11025, .factor = 0.9, .expected = .{ .volume_db = -10000, .pan_db = 10000, .frequency_hz = 9922 } },
        .{ .volume = 1, .pan = -1, .rate = 22050, .factor = 1.1, .expected = .{ .volume_db = -7000, .pan_db = 0, .frequency_hz = 24255 } },
    };
    for (cases) |c| {
        var voice: Voice = .{ .effective_volume = c.volume, .effective_pan = c.pan, .sample_rate = c.rate, .params = .{ .frequency_factor = c.factor } };
        apply(&voice);
        try std.testing.expectEqual(c.expected, voice.controls);
    }
}

test "driver lifecycle drops inaudible starts but retains distant looping voices" {
    var engine: Engine = .{};
    var params = try gameParams(64, 127, 1, .{ 149, 0, 0 });
    const id = (try engine.start(23, 22050, params, 100)).?;
    try std.testing.expectEqual(@as(i32, -7000), engine.find(id).?.controls.volume_db);
    try engine.updateListener(.{ .position = .{ -100, 0, 0 } });
    try std.testing.expectEqual(@as(i32, 1), engine.find(id).?.effective_volume);
    try std.testing.expectEqual(@as(i32, 0), engine.find(id).?.effective_pan);
    try std.testing.expectEqual(@as(?u32, null), try engine.start(23, 22050, params, 101));
    params.volume = 0;
    try engine.adjust(id, params);
    try std.testing.expect(engine.find(id) == null);
    const audible = (try engine.start(24, 11025, try gameParams(64, 127, 4, null), 102)).?;
    try std.testing.expectEqual(@as(u32, 3), audible);
    const original_controls = engine.find(audible).?.controls;
    try engine.adjust(audible, .{ .volume = 32, .pan = 100 });
    try std.testing.expectEqual(original_controls, engine.find(audible).?.controls);
    try engine.adjust(audible, .{ .flags = Flags.effects | Flags.paused, .volume = 32 });
    try std.testing.expect(!engine.find(audible).?.playing);
    try engine.adjust(audible, .{ .volume = 32 });
    try std.testing.expect(engine.find(audible).?.playing);
    try std.testing.expectEqual(@as(i32, -2000), engine.find(audible).?.controls.volume_db);
    engine.pausePlayback();
    try std.testing.expect(!engine.find(audible).?.playing);
    engine.resumePlayback();
    try std.testing.expect(engine.find(audible).?.playing);
    engine.complete(audible);
    try std.testing.expect(engine.find(audible) == null);
}

test "memory budget sound instance pool rejects exhaustion and reuses retired slots" {
    var engine: Engine = .{};
    for (1..instance_count) |expected| {
        try std.testing.expectEqual(@as(?u32, @intCast(expected)), engine.allocateInstance());
    }
    try std.testing.expect(engine.allocateInstance() == null);
    engine.stop(17);
    try std.testing.expectEqual(@as(?u32, 17), engine.allocateInstance());
    try std.testing.expect(engine.allocateInstance() == null);
    for (engine.allocated[1..]) |allocated| try std.testing.expect(allocated);
}

test "instance ids rotate and generation distinguishes reused buffers" {
    var engine: Engine = .{};
    const first = (try engine.start(1, 11025, .{ .priority = 107, .flags = Flags.effects | Flags.loop }, 0)).?;
    try std.testing.expectEqual(@as(u32, 1), first);
    const first_generation = engine.find(first).?.generation;
    for (0..199) |i| {
        const id = (try engine.start(2, 11025, .{}, @intCast(i + 1))).?;
        try std.testing.expect(id != first);
        try std.testing.expect(engine.find(id).?.generation > first_generation);
        engine.complete(id);
    }
    try std.testing.expectEqual(@as(u32, 2), engine.next_id);
    engine.stopAll();
    for (engine.voices) |voice| try std.testing.expect(!voice.active);
    try std.testing.expectError(error.UnsupportedAudioFlags, engine.start(1, 11025, .{ .flags = 0x8000 }, 1));
    try std.testing.expectError(error.InvalidAudioFrequency, engine.start(1, 0, .{}, 1));
    try std.testing.expectError(error.InvalidAudioPosition, engine.start(1, 11025, .{ .position = .{ std.math.nan(f32), 0, 0 } }, 1));
    try std.testing.expectError(error.InvalidAudioListener, engine.updateListener(.{ .yaw = std.math.inf(f32) }));
}

test "game wrapper priority and spatial flags retain their separate meanings" {
    const menu = try gameParams(64, 127, 4, null);
    try std.testing.expectEqual(@as(i8, 64), menu.priority);
    try std.testing.expectEqual(@as(i8, 0), menu.pan);
    try std.testing.expectEqual(Flags.effects, menu.flags);
    const world = try gameParams(1, 63, 0x11, .{ 1, 2, 3 });
    try std.testing.expectEqual(Flags.effects | Flags.loop | Flags.spatial, world.flags);
    try std.testing.expectEqual(@as(i8, 63), world.volume);
    try std.testing.expectEqual(@as(f32, -6.2831855), gameListener(.{ 1, 2, 3 }, .{ 0, 0, 0 }, -16384).yaw);
}
