//! The state the player and its actor start a level with: the defaults,
//! then whatever the character's item definition overrides.
//!
//! Eye height is derived from the actor's height and head height, and the
//! three offsets are added in a fixed order - changing the order changes the
//! first frame's camera. Object angles are quantised once at load and sent
//! on in degrees.

const std = @import("std");

const item_asset = @import("../assets/item.zig");
const level_asset = @import("../assets/level.zig");
const scene_module = @import("scene.zig");

pub const PlayerEye = struct {
    height: f32,
    head_height: f32,
    eye_offset: f32,

    pub fn fromItem(item: *const item_asset.Item) PlayerEye {
        const height = item.floatValue("HEIGHT") orelse 6.0;
        const head_height = item.floatValue("HEAD_HEIGHT") orelse 0.5;

        return .{
            .height = height,
            .head_height = head_height,
            .eye_offset = height - head_height,
        };
    }

    pub fn position(self: PlayerEye, spawn: level_asset.Vec3) level_asset.Vec3 {
        return .{
            .x = spawn.x,
            .y = @floatCast(@as(f64, self.eye_offset) + spawn.y),
            .z = spawn.z,
        };
    }

    pub fn actorAngles(spawn: level_asset.Spawn) ![3]i16 {
        return .{
            try level_asset.angleFromDegrees(spawn.rotation.x),
            try level_asset.angleFromDegrees(spawn.rotation.y),
            try level_asset.angleFromDegrees(spawn.rotation.z),
        };
    }
};

pub const InfStartup = struct {
    runtime: @import("../script/inf.zig").Runtime,

    pub fn apply(
        allocator: std.mem.Allocator,
        level: *level_asset.Level,
        bytes: []const u8,
    ) !InfStartup {
        return .{
            .runtime = try @import("../script/inf.zig").Runtime.load(allocator, level, bytes),
        };
    }

    pub fn applyScene(
        self: *const InfStartup,
        level: *const level_asset.Level,
        scene: *scene_module.Scene,
    ) void {
        self.runtime.applyScene(level, scene);
    }

    pub fn deinit(self: *InfStartup) void {
        self.runtime.deinit();
        self.* = undefined;
    }
};

test "Hideout INF initial stops modify geometry before rendering" {
    const a = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(32 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(data);
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_asset.Level.parse(a, try archive.find("hideout.lvb", 0x4c565446));
    defer level.deinit();
    var startup = try InfStartup.apply(a, &level, try archive.find("hideout.inf", 0));
    defer startup.deinit();

    try std.testing.expectEqual(@as(f32, -3), level.sectors[7].ceiling.height);
    try std.testing.expectEqual(@as(f32, 0.125), level.sectors[20].ceiling.height);
    try std.testing.expectEqual(@as(f32, -38.6), level.sectors[80].ceiling.height);
    try std.testing.expectEqual(@as(i32, 20), level.sectors[334].ambient);
    try std.testing.expectEqual(@as(i32, 20), level.sectors[356].ambient);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});

    for (level.sectors) |sector| {
        var bytes: [12]u8 = undefined;

        std.mem.writeInt(u32, bytes[0..4], @bitCast(sector.ceiling.height), .little);
        std.mem.writeInt(u32, bytes[4..8], @bitCast(sector.floor.height), .little);
        std.mem.writeInt(i32, bytes[8..12], sector.ambient, .little);
        hash.update(&bytes);
    }

    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqualStrings(
        "c3b3e0cdc4fa5483b6d354243df149d2565e3afe98ecba792006daf13d3459c3",
        &std.fmt.bytesToHex(digest, .lower),
    );
}
