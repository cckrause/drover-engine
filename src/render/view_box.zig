//! The view box table: where the 3D view sits on screen and which HUD mode
//! goes with it.
//!
//! Entries are fractions of the screen. Only size 14 is implemented in the
//! renderer and HUD; other sizes keep that one.

const std = @import("std");
const settings = @import("../settings.zig");

pub const table = [_]Entry{
    .{ .x = 0x00000000, .y = 0x00000000, .width = 0x00000000, .height = 0x00000000, .hud = 2 },
    .{ .x = 0x3e900000, .y = 0x3e900000, .width = 0x3ee00000, .height = 0x3eb55555, .hud = 2 },
    .{ .x = 0x3e800000, .y = 0x3e800000, .width = 0x3f000000, .height = 0x3ed55555, .hud = 2 },
    .{ .x = 0x3e600000, .y = 0x3e600000, .width = 0x3f100000, .height = 0x3ef55555, .hud = 2 },
    .{ .x = 0x3e400000, .y = 0x3e400000, .width = 0x3f200000, .height = 0x3f0aaaab, .hud = 2 },
    .{ .x = 0x3e200000, .y = 0x3e200000, .width = 0x3f300000, .height = 0x3f1aaaab, .hud = 2 },
    .{ .x = 0x3e000000, .y = 0x3e000000, .width = 0x3f400000, .height = 0x3f2aaaab, .hud = 2 },
    .{ .x = 0x3dc00000, .y = 0x3dc00000, .width = 0x3f500000, .height = 0x3f3aaaab, .hud = 2 },
    .{ .x = 0x3d800000, .y = 0x3d800000, .width = 0x3f600000, .height = 0x3f4aaaab, .hud = 2 },
    .{ .x = 0x3d000000, .y = 0x3d000000, .width = 0x3f700000, .height = 0x3f5aaaab, .hud = 2 },
    .{ .x = 0x00000000, .y = 0x3e2aaaab, .width = 0x3f800000, .height = 0x3f155555, .hud = 2 },
    .{ .x = 0x00000000, .y = 0x3e000000, .width = 0x3f800000, .height = 0x3f2aaaab, .hud = 2 },
    .{ .x = 0x00000000, .y = 0x3daaaaab, .width = 0x3f800000, .height = 0x3f400000, .hud = 2 },
    .{ .x = 0x00000000, .y = 0x3d2aaaab, .width = 0x3f800000, .height = 0x3f555555, .hud = 2 },
    .{ .x = 0x00000000, .y = 0x00000000, .width = 0x3f800000, .height = 0x3f6aaaab, .hud = 2 },
    .{ .x = 0x00000000, .y = 0x00000000, .width = 0x3f800000, .height = 0x3f800000, .hud = 1 },
    .{ .x = 0x00000000, .y = 0x00000000, .width = 0x3f800000, .height = 0x3f800000, .hud = 0 },
    .{ .x = 0x00000000, .y = 0x00000000, .width = 0x00000000, .height = 0x00000000, .hud = 2 },
};

pub const default = 14;

pub const Entry = struct { x: u32, y: u32, width: u32, height: u32, hud: i32 };

pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

pub const State = struct {
    index: i32 = default,
    rect: Rect = .{ .x = 0, .y = 0, .width = 640, .height = 440 },
    hud: i32 = 2,
    applied: u32 = 0,

    pub fn apply(self: *State, index: i32, screen_width: i32, screen_height: i32) bool {
        if (!valid(index)) return false;
        self.index = index;
        self.rect = rect(index, screen_width, screen_height);
        self.hud = table[@intCast(index)].hud;
        self.applied +%= 1;
        return true;
    }
};

pub fn count() i32 {
    var result: i32 = 1;
    var index: usize = 1;
    while (true) {
        index += 1;
        result += 1;
        if (table[index].width & 0x7fffffff == 0) return result;
    }
}

pub fn valid(index: i32) bool {
    return index >= 0 and index < table.len and table[@intCast(index)].width & 0x7fffffff != 0;
}

pub fn rect(index: i32, screen_width: i32, screen_height: i32) Rect {
    const entry = table[@intCast(index)];
    return .{
        .x = scale(screen_width, entry.x),
        .y = scale(screen_height, entry.y),
        .width = scale(screen_width, entry.width),
        .height = scale(screen_height, entry.height),
    };
}

pub fn within(index: i32, area: Rect) Rect {
    const entry = table[@intCast(index)];
    return .{
        .x = area.x + scale(area.width, entry.x),
        .y = area.y + scale(area.height, entry.y),
        .width = scale(area.width, entry.width),
        .height = scale(area.height, entry.height),
    };
}

pub fn load(store: *settings.Store) !i32 {
    var buffer: [20]u8 = undefined;
    var text = (try store.read(null, null, "View Box")) orelse "14";
    const value = settings.atoi(text);
    if (value <= 0 or value >= 0x12) text = "14";
    if (text.len > buffer.len) return error.SettingTooLong;
    @memcpy(buffer[0..text.len], text);
    try store.write(null, null, "View Box", buffer[0..text.len]);
    return settings.atoi(buffer[0..text.len]);
}

fn scale(whole: i32, fraction: u32) i32 {
    const product: f32 = @floatCast(@as(f64, @floatFromInt(whole)) * @as(f64, @as(f32, @bitCast(fraction))));
    const lower = @floor(product);
    const rest = product - lower;
    var result: i32 = @intFromFloat(lower);
    if (rest > 0.5 or (rest == 0.5 and @mod(result, 2) != 0)) result += 1;
    return result;
}

test "View Box table: count and default rectangle" {
    try std.testing.expectEqual(@as(i32, 17), count());
    try std.testing.expect(!valid(0) and valid(1) and valid(16) and !valid(17));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 640, .height = 440 }, rect(14, 640, 480));
}
