//! The display's colour state: brightness, gamma step, the transfer table
//! and the blend and tint that are applied to the raw palette to make the
//! palette the screen gets.

const std = @import("std");
const settings = @import("../settings.zig");

const gamma_table = [_]f64{ 2.1, 1.8, 1.5, 1.3, 1.0, 0.9, 0.8, 0.7, 0.6 };

const ln2: f128 = 0.69314718055994530941723212145817656807550013436025525412068000949339362196969471560586332699641868754200148102057068573368552023575813055703267075163507596193072757082837143519030703862389167347112335;

pub const Display = struct {
    brightness: i32 = 256,
    gamma: i32 = 0,
    table: [256]u8 = @splat(0),
    blend_amount: i32 = 0,
    blend_color: u32 = 0,
    tint_amount: i32 = 0,
    tint_color: u32 = 0,

    pub fn setBrightness(self: *Display, value: i32) i32 {
        const previous = self.brightness;
        if (value < 0 or value >= 0x100) return previous;
        self.brightness = value;
        self.gamma = std.math.clamp(self.gamma, -4, 4);
        self.build();
        return previous;
    }

    pub fn setGamma(self: *Display, value: i32) struct { previous: i32, changed: bool } {
        const previous = self.gamma;
        if (value <= -5 or value >= 5) return .{ .previous = previous, .changed = false };
        self.gamma = std.math.clamp(value, -4, 4);
        self.brightness = std.math.clamp(self.brightness, 0, 0xff);
        self.build();
        return .{ .previous = previous, .changed = true };
    }

    pub fn convert(self: *const Display, raw: *const [256]u32) [256]u32 {
        var result: [256]u32 = undefined;
        const tint = self.tint_amount;
        const blend = self.blend_amount;
        for (raw, &result) |color, *out| {
            var r: i32 = @intCast(color & 0xff);
            var g: i32 = @intCast((color >> 8) & 0xff);
            var b: i32 = @intCast((color >> 16) & 0xff);
            if (tint != 0) {
                const tr: u32 = self.tint_color & 0xff;
                const tg: u32 = (self.tint_color >> 8) & 0xff;
                const tb: u32 = (self.tint_color >> 16) & 0xff;
                const weight: u32 = @intCast((r + g * 2) * 3 + b);
                const tint_weight = (tr + tg * 2) * 3 + tb;
                r = @divTrunc(@as(i32, @intCast(tr * weight / tint_weight)) * tint + (0xff - tint) * r, 0xff);
                g = @divTrunc(@as(i32, @intCast(tg * weight / tint_weight)) * tint + (0xff - tint) * g, 0xff);
                b = @divTrunc(@as(i32, @intCast(tb * weight / tint_weight)) * tint + (0xff - tint) * b, 0xff);
            }
            if (blend != 0) {
                const unsigned_blend: u32 = @bitCast(blend);
                const rest: u32 = @bitCast(0xff - blend);
                r = @bitCast(((self.blend_color & 0xff) *% unsigned_blend +% rest *% @as(u32, @bitCast(r))) / 0xff);
                g = @bitCast((((self.blend_color >> 8) & 0xff) *% unsigned_blend +% rest *% @as(u32, @bitCast(g))) / 0xff);
                b = @bitCast((rest *% @as(u32, @bitCast(b)) +% ((self.blend_color >> 16) & 0xff) *% unsigned_blend) / 0xff);
            }
            out.* = @as(u32, self.table[clampChannel(b)]) << 16 | @as(u32, self.table[clampChannel(g)]) << 8 | self.table[clampChannel(r)];
        }
        return result;
    }

    fn build(self: *Display) void {
        const exponent: f64 = 1.0 / gamma_table[@intCast(self.gamma + 4)];
        const reciprocal_255: f64 = @bitCast(@as(u64, 0x3f70101010101010));
        for (&self.table, 0..) |*entry, i| {
            const power: f80 = if (i == 0) 0 else pow(@intCast(i), exponent);
            const scaled: f64 = @floatCast(power * 256.0);
            var value = scaled * @as(f64, @floatFromInt(self.brightness)) * reciprocal_255;
            if (!(0 < value)) value = 0;
            if (!(255 > value)) value = 255;
            entry.* = @intFromFloat(@trunc(value));
        }
    }
};

pub fn load(store: *settings.Store, display: *Display) !bool {
    var buffer: [20]u8 = undefined;
    const tinting = try settings.keep(store, null, null, "Palette Tinting", "Y", &buffer);
    const enabled = tinting.len == 0 or std.ascii.toUpper(tinting[0]) != 'N';
    var default: [12]u8 = undefined;
    const gamma = try settings.keep(store, null, null, "Gamma", try std.fmt.bufPrint(&default, "{d}", .{display.gamma}), &buffer);
    display.gamma = settings.atoi(gamma);
    return enabled;
}

fn clampChannel(value: i32) u8 {
    if (value < 0) return 0;
    if (0xfe < value) return 0xff;
    return @intCast(value);
}

fn lnNear1(m: f128) f128 {
    const z = (m - 1) / (m + 1);
    const z2 = z * z;
    var term = z;
    var sum: f128 = 0;
    var k: f128 = 1;
    while (true) : (k += 2) {
        const part = term / k;
        if (part < 0x1p-125) break;
        sum += part;
        term *= z2;
    }
    return 2 * sum;
}

fn exp2m1(f: f128) f128 {
    const u = f * ln2;
    var term = u;
    var sum: f128 = 0;
    var k: f128 = 1;
    while (term > 0x1p-125) {
        sum += term;
        k += 1;
        term = term * u / k;
    }
    return sum;
}

fn roundEven(value: f80) f80 {
    const lower = @floor(value);
    const rest = value - lower;
    if (rest > 0.5) return lower + 1;
    if (rest < 0.5) return lower;
    return if (@mod(lower, 2) == 0) lower else lower + 1;
}

fn pow(i: u32, y: f64) f80 {
    const shift: u5 = @intCast(std.math.log2_int(u32, i));
    const m = @as(f128, @floatFromInt(i)) / @as(f128, @floatFromInt(@as(u32, 1) << shift));
    const log2_x = lnNear1(m) / ln2 + @as(f128, @floatFromInt(@as(i32, shift) - 8));
    const t: f80 = @floatCast(@as(f128, y) * log2_x);
    const n = roundEven(t);
    const f = t - n;
    const e: f80 = @floatCast(exp2m1(@abs(@as(f128, f))));
    var s: f80 = 1 + e;
    if (f < 0) s = 1 / s;
    return std.math.ldexp(s, @intFromFloat(n));
}

test "brightness 255 at gamma 0 leaves every channel unchanged" {
    var display = Display{};
    _ = display.setBrightness(0xff);
    for (display.table, 0..) |entry, i| try std.testing.expectEqual(@as(u8, @intCast(i)), entry);
}
