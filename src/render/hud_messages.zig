//! The message lines the HUD shows: ten records, formatted text and the
//! timing that expires them.
//!
//! The small font is used below 512 horizontal pixels. Formatting clears the
//! argument count but leaves the argument values, so a record redrawn after
//! formatting shows the same text.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const font_module = @import("../assets/font.zig");
const messages = @import("../assets/messages.zig");

pub const Entry = extern struct {
    text: [256]u8 = @splat(0),
    category: u32 = 0,
    color: u32 = 0,
    expiry: u32 = 0,

    pub fn string(self: *const Entry) []const u8 {
        return std.mem.sliceTo(&self.text, 0);
    }
};

pub const HudMessages = struct {
    font: font_module.Font,
    source: []const u8,
    entries: [10]Entry = @splat(.{}),
    first_parameter: i32 = 0,
    restore_frames: u32 = 2,

    pub fn init(system: lab.Archive, width: usize) !HudMessages {
        return .{
            .font = try font_module.Font.init(try system.find(if (width < 512) "INFOSM.LAF" else "INFO.LAF", 0x4e464e54)),
            .source = try system.find("LOCAL.MSG", 0),
        };
    }

    pub fn post(self: *HudMessages, index: i32, parameter: ?i32, now: u32) !void {
        const first_parameter = parameter orelse self.first_parameter;
        const record = messages.lookupRecord(self.source, @bitCast(index)) catch |err| switch (err) {
            error.MessageNotFound => {
                self.first_parameter = first_parameter;
                return;
            },
            else => return err,
        };
        var entry: Entry = .{ .category = record.category, .color = 15, .expiry = now +% 5000 };
        try format(&entry.text, record.text, first_parameter);
        self.first_parameter = first_parameter;
        self.append(entry);
    }

    pub fn postRouted(self: *HudMessages, index: i32, now: u32) !void {
        const record = try messages.lookupRecord(self.source, @bitCast(index));
        var entry: Entry = .{ .category = 1, .color = 14, .expiry = now +% 5000 };
        try format(&entry.text, record.text, self.first_parameter);
        self.append(entry);
    }

    pub fn postComment(self: *HudMessages, text: []const u8, now: u32) !void {
        if (text.len >= 256) return error.HudMessageTooLong;
        var entry: Entry = .{ .category = 1, .color = 14, .expiry = now +% 5000 };
        @memcpy(entry.text[0..text.len], text);
        self.append(entry);
    }

    pub fn postText(self: *HudMessages, text: []const u8, category: u32, now: u32) !void {
        if (text.len >= 256) return error.HudMessageTooLong;
        var entry: Entry = .{ .category = category, .color = 15, .expiry = now +% 5000 };
        @memcpy(entry.text[0..text.len], text);
        self.append(entry);
    }

    pub fn render(self: *HudMessages, pixels: []u8, stride: usize, height: usize, now: u32) !void {
        self.expire(now);
        if (self.restore_frames != 0) self.restore_frames -= 1;
        var translation: [256]u8 = undefined;
        for (&translation, 0..) |*value, i| value.* = @intCast(i);
        const spacing = self.font.height - 2;
        var baseline = self.font.baseline + 4;
        for (&self.entries) |*entry| {
            if (entry.text[0] != 0) {
                translation[255] = @truncate(entry.color);
                try self.font.drawLeft(pixels, stride, height, entry.string(), 4, baseline, &translation);
            }
            baseline += spacing;
        }
    }

    pub fn expire(self: *HudMessages, now: u32) void {
        while (self.entries[0].expiry != 0 and self.entries[0].expiry < now) self.shift();
    }

    fn append(self: *HudMessages, entry: Entry) void {
        var slot: usize = 0;
        while (slot < self.entries.len and self.entries[slot].text[0] != 0) : (slot += 1) {}
        if (slot == self.entries.len) {
            self.shift();
            slot = self.entries.len - 1;
        }
        self.entries[slot] = entry;
    }

    fn shift(self: *HudMessages) void {
        std.mem.copyForwards(Entry, self.entries[0..9], self.entries[1..10]);
        self.entries[9] = .{};
        self.restore_frames = 2;
    }
};

fn format(destination: *[256]u8, source: []const u8, parameter: i32) !void {
    const conversion = std.mem.indexOfScalar(u8, source, '%') orelse {
        if (source.len >= destination.len) return error.HudMessageTooLong;
        @memcpy(destination[0..source.len], source);
        return;
    };
    if (conversion + 1 >= source.len or source[conversion + 1] != 'd' or
        std.mem.indexOfScalar(u8, source[conversion + 2 ..], '%') != null)
        return error.UnsupportedHudMessageFormat;
    const text = std.fmt.bufPrint(destination[0..255], "{s}{d}{s}", .{
        source[0..conversion], parameter, source[conversion + 2 ..],
    }) catch return error.HudMessageTooLong;
    destination[text.len] = 0;
}

fn testSystem(allocator: std.mem.Allocator) !lab.Archive {
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    return lab.Archive.init(data);
}

fn expectPixels(pixels: []const u8, expected: []const u8) !void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pixels, &actual, .{});
    var reference: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&reference, expected);
    try std.testing.expectEqualSlices(u8, &reference, &actual);
}

test "HUD message layout and unsupported formatting" {
    try std.testing.expectEqual(@as(usize, 0x10c), @sizeOf(Entry));
    var text: [256]u8 = @splat(0);
    try format(&text, "%d Bullets", -2147483648);
    try std.testing.expectEqualStrings("-2147483648 Bullets", std.mem.sliceTo(&text, 0));
    try std.testing.expectError(error.UnsupportedHudMessageFormat, format(&text, "%s is now IT!", 0));
    try std.testing.expectError(error.UnsupportedHudMessageFormat, format(&text, "%d%d", 0));
    try std.testing.expectError(error.HudMessageTooLong, format(&text, &(@as([256]u8, @splat('A'))), 0));
}

test "CD1 HUD message pixels match the reference queue and font output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const system = try testSystem(a);
    for ([_]usize{ 640, 320 }, [_]usize{ 480, 200 }, [_][]const u8{
        "299e2461f64ba967dc6976add1fadf1529c883d7e482fb4765318ba97300036f",
        "37b437e3c56605ef34c43e92bdcc138a70b53a2c93f6b95a49611159fd372921",
    }) |width, height, reference| {
        var hud = try HudMessages.init(system, width);
        try hud.post(303, null, 100);
        try hud.post(200, 18, 110);
        try hud.post(201, -2147483648, 120);
        try hud.post(-1, 17, 130);
        try hud.post(202, null, 140);
        const pixels = try a.alloc(u8, width * height);
        @memset(pixels, 91);
        try hud.render(pixels, width, height, 5100);
        try expectPixels(pixels, reference);
        try std.testing.expectEqualStrings("Canteen", hud.entries[0].string());
        try std.testing.expectEqualStrings("17 Shells", hud.entries[3].string());
        try std.testing.expectEqual(@as(u32, 1), hud.entries[0].category);
        try std.testing.expectEqual(@as(u32, 15), hud.entries[0].color);
        try std.testing.expectError(error.UnsupportedHudMessageFormat, hud.post(810, null, 5100));
        try hud.render(pixels, width, height, 5101);
        try std.testing.expectEqualStrings("18 Bullets", hud.entries[0].string());
    }
}

test "HUD reference preserves overflow timing formatting and font pixels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/hud-messages-reference.json", a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const ReferenceEntry = struct {
        text: []const u8,
        category: u32,
        color: u32,
        expiry: u32,
    };
    const State = struct { entries: []ReferenceEntry, first_parameter: i32, restore_frames: u32 };
    const Event = struct {
        kind: enum { post, draw },
        index: i32 = 0,
        parameter: ?i32 = null,
        now: u32,
        state: State,
        sha256: ?[]const u8 = null,
    };
    const Case = struct { width: usize, height: usize, events: []Event };
    const document = try std.json.parseFromSlice(struct { cases: []Case }, a, fixture, .{ .ignore_unknown_fields = true });
    const system = try testSystem(a);
    for (document.value.cases) |case| {
        var hud = try HudMessages.init(system, case.width);
        const pixels = try a.alloc(u8, case.width * case.height);
        for (case.events) |event| {
            switch (event.kind) {
                .post => try hud.post(event.index, event.parameter, event.now),
                .draw => {
                    @memset(pixels, 91);
                    try hud.render(pixels, case.width, case.height, event.now);
                    try expectPixels(pixels, event.sha256.?);
                },
            }
            try std.testing.expectEqual(event.state.first_parameter, hud.first_parameter);
            try std.testing.expectEqual(event.state.restore_frames, hud.restore_frames);
            try std.testing.expectEqual(@as(usize, 10), event.state.entries.len);
            for (&hud.entries, event.state.entries) |*actual, reference| {
                try std.testing.expectEqualStrings(reference.text, actual.string());
                try std.testing.expectEqual(reference.category, actual.category);
                try std.testing.expectEqual(reference.color, actual.color);
                try std.testing.expectEqual(reference.expiry, actual.expiry);
            }
        }
    }
}
