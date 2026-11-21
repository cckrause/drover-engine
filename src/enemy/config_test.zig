//! Enemy templates and weapon descriptors, including inheritance and difficulty adjustment.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const Config = @import("config.zig").Config;
const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "enemy templates and weapon descriptors match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try std.json.parseFromSlice(std.json.Value, a, try read(a, "testdata/enemy-template-reference.json"), .{});
    const root = corpus.value.object;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", root.get("executable_sha256").?.string);
    try std.testing.expectEqualStrings("ab18dbb7611fe77e62354f8244cfd9d718bc8e582baa12121dbb9c81ce0b03d7", root.get("results_sha256").?.string);
    const object = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const weapon = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    for (root.get("cases").?.array.items) |row| {
        const name = row.object.get("name").?.string;
        const difficulty: u32 = @intCast(row.object.get("difficulty").?.integer);
        const path = try std.fmt.allocPrint(a, "{s}.ITM", .{name});
        var item = try Item.parse(a, if (row.object.get("definition")) |definition| definition.string else try object.find(path, 0));
        defer item.deinit();
        const actual = try Config.load(a, &.{ object, weapon }, &item, difficulty);
        const expected = row.object.get("template").?.object;
        inline for (std.meta.fields(Config)) |field| {
            if (comptime !std.mem.eql(u8, field.name, "radius") and !std.mem.eql(u8, field.name, "height") and !std.mem.eql(u8, field.name, "weapon_mode")) {
                errdefer std.debug.print("reference template {s}/{x} field {s}\n", .{ name, difficulty, field.name });
                const value = expected.get(field.name).?;
                const got = @field(actual, field.name);
                if (comptime field.type == f32) {
                    try std.testing.expectEqual(@as(u32, @intCast(value.integer)), @as(u32, @bitCast(got)));
                } else if (comptime field.type == u32) {
                    try std.testing.expectEqual(@as(u32, @intCast(value.integer)), got);
                } else if (comptime field.type == i32) {
                    try std.testing.expectEqual(@as(u32, @intCast(value.integer)), @as(u32, @bitCast(got)));
                } else if (comptime field.type == i16) {
                    try std.testing.expectEqual(@as(u16, @intCast(value.integer)), @as(u16, @bitCast(got)));
                } else if (comptime field.type == bool) {
                    try std.testing.expectEqual(value.bool, got);
                } else if (comptime field.type == Config.Weapon) {
                    try std.testing.expectEqual(@as(u32, @intCast(value.integer)), @intFromEnum(got));
                } else if (comptime field.type == []const u8) {
                    try std.testing.expect(std.ascii.eqlIgnoreCase(value.string, got));
                } else if (comptime field.type == []const []const u8) {
                    try std.testing.expectEqual(value.array.items.len, got.len);
                    for (value.array.items, got) |entry, sound| try std.testing.expect(std.ascii.eqlIgnoreCase(entry.string, sound));
                } else @compileError("unverified enemy config field");
            }
        }
        const mode = expected.get("weapon_mode").?.array.items;
        inline for (std.meta.fields(@TypeOf(actual.weapon_mode)), 0..) |field, index| {
            try std.testing.expectEqual(@as(u32, @intCast(mode[index].integer)), @as(u32, @bitCast(@field(actual.weapon_mode, field.name))));
        }
    }
}
