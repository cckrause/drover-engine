//! Saving sound registrations - what a level registered, not what is
//! currently playing.
//!
//! A name is stored in a 13-byte field with no terminator, so a longer name
//! is compared only by that prefix on restore.

const std = @import("std");
const stream = @import("stream.zig");

pub const Record = struct {
    name: []const u8,
    resource_type: u32 = 0x57415644,
    priority: u8 = 64,
    flags: u32 = 0x10000,
    registered_at: u32,
    volume: u8 = 127,
    zero_tail: bool = false,
};

pub fn write(writer: *stream.Writer, sound: ?Record) !void {
    try writer.boolean(sound != null);
    if (sound) |record| {
        if (record.name.len >= 13 and !record.zero_tail) return error.UnresolvedOriginalSoundNameTail;
        try writer.string(record.name);
        try writer.integer(u32, record.resource_type);
        try writer.integer(u8, record.priority);
        try writer.integer(u32, record.flags);
        try writer.integer(u32, record.registered_at);
        try writer.integer(u8, record.volume);
    }
}

pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !?Record {
    if (!try reader.boolean()) return null;
    var buffer: [255]u8 = undefined;
    return .{ .name = try a.dupe(u8, try reader.string(&buffer)), .resource_type = try reader.integer(u32), .priority = try reader.integer(u8), .flags = try reader.integer(u32), .registered_at = try reader.integer(u32), .volume = try reader.integer(u8) };
}

pub fn capture(audio: anytype, name: ?[]const u8) !?Record {
    const requested = name orelse return null;
    for (audio.registrations.items, 0..) |record, index| {
        if (!audio.registration_refs.items[index].active) continue;
        if (!matches(record.name, requested)) continue;
        var result: Record = .{ .name = record.name, .resource_type = record.resource_type, .priority = record.priority, .flags = record.flags, .registered_at = record.registered_at, .volume = record.volume };
        for (audio.registration_ids.items, 0..) |registered, resource| if (registered == index) {
            result.flags |= audio.resource_flags.items[resource];
            for (audio.ambient_resources) |ambient| if (ambient == resource) {
                result.flags |= 1;
                break;
            };
            break;
        };
        if (record.name.len >= 13 and !try audio.soundStartsWith(record.name[0..13])) {
            result.name = record.name[0..13];
            result.zero_tail = true;
        }
        return result;
    }
    return error.MissingSaveSoundRegistration;
}

pub fn restore(audio: anytype, record: ?Record) !?[]const u8 {
    const value = record orelse return null;
    const registration = try audio.declare(value.name, value.resource_type, value.priority, value.registered_at);
    audio.registrations.items[registration].flags = value.flags;
    audio.registrations.items[registration].registered_at = value.registered_at;
    audio.registrations.items[registration].volume = value.volume;
    for (audio.registration_ids.items, 0..) |registered, resource| if (registered == registration) {
        audio.resource_flags.items[resource] = value.flags;
    };
    return audio.registrations.items[registration].name;
}

fn matches(registered: []const u8, requested: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(registered, requested)) return true;
    return std.fs.path.extension(requested).len == 0 and registered.len == requested.len + 4 and
        std.ascii.eqlIgnoreCase(registered[0..requested.len], requested) and
        std.ascii.eqlIgnoreCase(registered[requested.len..], ".wav");
}

test "malformed Train sound retains the unresolved malloc tail boundary" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/sound-name-tail-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { pattern: u8, native_name: []const u8, encoded: []const u8 },
    };
    const parsed = try std.json.parseFromSlice(Corpus, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", parsed.value.executable_sha256);
    try std.testing.expectEqualStrings("1c4b9dd0f2816733d729798b2176a86446d0a780f6f02842fd96163727ddf30f", parsed.value.results_sha256);
    const cases = parsed.value.cases;
    try std.testing.expect(!std.mem.eql(u8, cases[0].encoded, cases[1].encoded));
    try std.testing.expect(!std.mem.eql(u8, cases[1].encoded, cases[2].encoded));
    var writer: stream.Writer = .{ .allocator = a };
    defer writer.deinit();
    try std.testing.expectError(error.UnresolvedOriginalSoundNameTail, write(&writer, .{ .name = "TRAINDR2.WAV.WAV", .priority = 12, .registered_at = 1000 }));
    const matchesNative = @import("../audio/runtime.zig").nativeNameMatches;
    try std.testing.expect(!try matchesNative("TRAINDR2.WAV.WAV", "TRAINDR1.WAV"));
    try std.testing.expectError(error.UnresolvedOriginalSoundNameTail, matchesNative("TRAINDR2.WAV.WAV", "TRAINDR2.WAV.WAV"));

    const Runtime = @import("../audio/runtime.zig").Runtime;
    const lab = @import("../assets/lab.zig");
    const name = "TRAINDR2.WAV.WAV";
    var data = [_]u8{0} ** 49;
    @memcpy(data[0..4], "LABN");
    std.mem.writeInt(u32, data[4..8], 0x10000, .little);
    std.mem.writeInt(u32, data[8..12], 1, .little);
    std.mem.writeInt(u32, data[12..16], name.len + 1, .little);
    std.mem.writeInt(u32, data[28..32], 0x57415644, .little);
    @memcpy(data[32..][0..name.len], name);
    const empty: lab.Archive = .{ .data = "", .entries = "", .strings = "" };
    var native: [64]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&native, cases[0].encoded);
    for ([_]bool{ true, false }) |shipped| {
        const runtime = try a.create(Runtime);
        runtime.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .archives = .{ if (shipped) try lab.Archive.init(&data) else empty, empty, empty }, .directory = "", .music_directory = "", .loops = .init(a) };
        defer runtime.deinit();
        _ = try runtime.declare(name, 0x57415644, 12, 1000);
        const record = try capture(runtime, name);
        var saved: stream.Writer = .{ .allocator = a };
        defer saved.deinit();
        if (shipped) {
            try std.testing.expectError(error.UnresolvedOriginalSoundNameTail, write(&saved, record));
        } else {
            try write(&saved, record);
            try std.testing.expectEqualSlices(u8, expected, saved.bytes.items);
        }
    }
}
