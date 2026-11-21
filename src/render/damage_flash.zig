//! The red flash when the player is hit: its strength and the alpha that
//! is actually shown.
//!
//! Strength and displayed alpha are separate on purpose: the cap on the
//! shown value delays the visible fade after a big hit, which is what makes
//! heavy damage read as heavy.

const std = @import("std");

pub const Display = struct {
    context: *anyopaque,
    blend: *const fn (*anyopaque, i32) anyerror!void,
    blend_color: *const fn (*anyopaque, u32) anyerror!void,
};

pub const State = struct {
    strength: i32 = 0,
    last_ms: u32 = 0,
    alpha: u8 = 0,
    active: bool = false,
    display: ?Display = null,

    pub fn trigger(self: *State, loss: f32, dead: bool, now_ms: u32) !void {
        if (@as(i32, @bitCast(loss)) < 1) return;
        if (self.display) |d| try d.blend_color(d.context, 0xff);
        const value: f32 = @floatCast((@as(f64, loss) + 1) * @as(f64, if (dead) 100 else 50));
        self.strength = std.math.clamp(nearest(value), @as(i32, if (dead) 50 else 35), @as(i32, if (dead) 382 else 255));
        self.last_ms = now_ms;
        self.active = true;
        self.updateAlpha(dead);
        if (self.display) |d| try d.blend(d.context, self.alpha);
    }

    pub fn advance(self: *State, dead: bool, now_ms: u32) !void {
        if (!self.active or !(self.last_ms < now_ms)) return;
        const elapsed: i32 = @bitCast(now_ms -% self.last_ms);
        self.strength -%= @divTrunc(elapsed *% 255000, 1000000);
        self.last_ms = now_ms;
        self.active = self.strength > 0;
        self.updateAlpha(dead);
        if (self.display) |d| try d.blend(d.context, self.alpha);
    }

    pub fn clear(self: *State) !void {
        if (self.display) |d| try d.blend_color(d.context, 0);
        self.strength = 0;
        self.alpha = 0;
        if (self.display) |d| try d.blend(d.context, 0);
    }

    pub fn palette(self: *const State, base: [256]u32) [256]u32 {
        var result: [256]u32 = undefined;
        const alpha: u32 = self.alpha;
        const inverse: u32 = 255 - alpha;
        for (&result, base) |*output, color| {
            const red = (255 * alpha + inverse * (color & 255)) / 255;
            const green = inverse * ((color >> 8) & 255) / 255;
            const blue = inverse * ((color >> 16) & 255) / 255;
            output.* = red | green << 8 | blue << 16;
        }
        return result;
    }

    fn updateAlpha(self: *State, dead: bool) void {
        self.alpha = @intCast(std.math.clamp(self.strength, 0, @as(i32, if (dead) 229 else 127)));
    }
};

fn nearest(value: f32) i32 {
    if (!std.math.isFinite(value) or value < -2147483648.0 or value >= 2147483648.0) return std.math.minInt(i32);
    const lower = @floor(value);
    var rounded: i32 = @intFromFloat(lower);
    if (value - lower > 0.5 or (value - lower == 0.5 and rounded & 1 != 0)) rounded +%= 1;
    return rounded;
}

fn hashFrame(hash: *std.crypto.hash.sha2.Sha256, state: State, base: [256]u32) void {
    var word: [4]u8 = undefined;
    for ([_]u32{ @bitCast(state.strength), state.last_ms, state.alpha, @intFromBool(state.active) }) |value| {
        std.mem.writeInt(u32, &word, value, .little);
        hash.update(&word);
    }
    for (state.palette(base)) |value| {
        std.mem.writeInt(u32, &word, value, .little);
        hash.update(&word);
    }
}

test "damage flash matches health fade and archived Hideout palette" {
    const a = std.testing.allocator;
    const raw = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(raw);
    const archive = try @import("../assets/lab.zig").Archive.init(raw);
    const texture = @import("../assets/texture.zig");
    const base = texture.levelPalette(try texture.decodePalette(try archive.find("SYSPAL.PCX", 0x50435850)), try texture.decodePalette(try archive.find("HIDEOUT.PCX", 0x50435850)));
    const Case = struct {
        health: f32,
        amount: f32,
        now_ms: u32,
        times: []const u32,
    };
    const cases = [_]Case{
        .{ .health = 10, .amount = 0.2, .now_ms = 1000, .times = &.{ 1000, 1001, 1004, 1008, 1024, 1040, 1250, 1266 } },
        .{ .health = 10, .amount = 2.25, .now_ms = 100, .times = &.{ 116, 132, 148, 164, 180, 400, 800 } },
        .{ .health = 10, .amount = 9, .now_ms = 100, .times = &.{ 116, 300, 600, 900, 1200 } },
        .{ .health = 0.2, .amount = 0.2, .now_ms = 100, .times = &.{ 116, 132, 400, 600 } },
        .{ .health = 10, .amount = 10, .now_ms = 100, .times = &.{ 116, 300, 600, 900, 1200, 1800 } },
        .{ .health = 10, .amount = 0.01, .now_ms = 0xfffffff0, .times = &.{ 0xfffffff1, 0xffffffff, 0, 16 } },
        .{ .health = 10, .amount = 0.01, .now_ms = 0, .times = &.{ 8422, 10000 } },
        .{ .health = 10, .amount = 0.25, .now_ms = 100, .times = &.{ 116, 400 } },
        .{ .health = 10, .amount = 0.27, .now_ms = 100, .times = &.{ 116, 400 } },
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (cases) |case| {
        var state: State = .{};
        const dead = case.amount >= case.health;
        try state.trigger(@min(case.amount, case.health), dead, case.now_ms);
        hashFrame(&hash, state, base);
        for (case.times) |now| {
            try state.advance(dead, now);
            hashFrame(&hash, state, base);
        }
    }
    try std.testing.expectEqualStrings("a1bce6629b96161687766c034b7ab02ae544e970f229b0cdd5fd94f059489fe0", &std.fmt.bytesToHex(hash.finalResult(), .lower));
}
