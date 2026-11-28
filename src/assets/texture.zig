//! Textures: TXTM resources decoded into runtime textures.
//!
//! Texels are stored as columns, bottom first. The crop pass deliberately
//! leaves out the last row and compares width against the row count, which
//! matters for non-square images. An entirely transparent texture keeps a
//! zero extent. Dimensions are sign-extended from 16 bits before use, so
//! sizes that would overflow that are rejected here.

const std = @import("std");

const atx = @import("atx.zig");
const lab = @import("lab.zig");
const pcx = @import("pcx.zig");

pub const Texture = struct {
    width: usize,
    height: usize,
    pixels: []u8,
    height_shift: u5,
    flags: TextureFlags,
    animation: ?atx.Animation = null,

    pub fn deinit(self: Texture, allocator: std.mem.Allocator) void {
        if (self.animation) |animation| animation.deinit(allocator);
        allocator.free(self.pixels);
    }

    pub fn isTransparent(self: Texture) bool {
        return self.flags.transparent;
    }
};

pub const TextureFlags = packed struct(u8) {
    unused_0: bool = false,
    width_power_of_two: bool = false,
    height_power_of_two: bool = false,
    /// Has see-through pixels (colour 0).
    transparent: bool = false,
    unused_4: u4 = 0,
};

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Texture {
    const image = try pcx.decode(allocator, data);
    defer image.deinit(allocator);
    var rotated = try allocator.alloc(u8, image.pixels.len);
    errdefer allocator.free(rotated);

    for (0..image.height) |y| {
        for (0..image.width) |x| {
            rotated[x * image.height + image.height - 1 - y] = image.pixels[y * image.width + x];
        }
    }

    var last_nonzero: usize = 0;
    var i = rotated.len;

    while (i != 0) {
        i -= 1;
        if (rotated[i] != 0 and last_nonzero < i) last_nonzero = i;
    }

    const last_row = last_nonzero / image.height;
    var first_column: usize = 0;

    search: for (0..image.height) |column| {
        for (0..last_row) |row| {
            if (rotated[row * image.height + column] != 0) {
                first_column = column;
                break :search;
            }
        }
    }

    var width = image.width;
    var height = image.height;

    if (first_column > 0 or @as(i64, @intCast(image.height)) - @as(i64, @intCast(last_row)) != 1) {
        width = last_row + 1;
        height = image.height - first_column;
        if (width > 32767 or height > 32767 or first_column > 32767)
            return error.UnsupportedTextureCropDimensions;

        const cropped = try allocator.alloc(u8, width * height);

        for (0..width) |column| {
            @memcpy(
                cropped[column * height ..][0..height],
                rotated[column * image.height + first_column ..][0..height],
            );
        }

        allocator.free(rotated);
        rotated = cropped;
    }

    const flags: TextureFlags = .{
        .transparent = std.mem.indexOfScalar(u8, rotated, 0) != null,
        .width_power_of_two = std.math.isPowerOfTwo(width),
        .height_power_of_two = std.math.isPowerOfTwo(height),
    };

    return .{
        .width = width,
        .height = height,
        .pixels = rotated,
        .height_shift = @intCast(@ctz(@as(u32, @intCast(height)))),
        .flags = flags,
    };
}

pub fn loadInitial(allocator: std.mem.Allocator, archive: lab.Archive, name: []const u8) !Texture {
    if (std.ascii.endsWithIgnoreCase(name, ".pcx"))
        return decode(allocator, try archive.find(name, 0));

    if (!std.ascii.endsWithIgnoreCase(name, ".atx")) return error.UnsupportedTextureFormat;

    const animation = try atx.Animation.parse(allocator, try archive.find(name, 0));
    errdefer animation.deinit(allocator);
    const initial_name = animation.initialTexture() orelse return error.AtXHasNoTexture;
    if (!std.ascii.endsWithIgnoreCase(initial_name, ".pcx")) return error.UnsupportedTextureFormat;

    const frame_bytes = archive.find(initial_name, 0) catch |err| switch (err) {
        error.ResourceNotFound => try archive.find("DEFAULT.PCX", 0),
        else => return err,
    };

    var texture = try decode(allocator, frame_bytes);

    texture.animation = animation;

    return texture;
}

pub fn loadLevelInitial(
    allocator: std.mem.Allocator,
    archive: lab.Archive,
    name: []const u8,
) !Texture {
    return loadInitial(allocator, archive, name) catch |err| switch (err) {
        error.ResourceNotFound => loadInitial(
            allocator,
            archive,
            "DEFAULT.PCX",
        ) catch |default_err| switch (default_err) {
            error.ResourceNotFound => error.UnsupportedSystemDefaultTexture,
            else => default_err,
        },
        else => err,
    };
}

pub fn decodeColorMap(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const image = try pcx.decode(allocator, data);
    if (image.width != 256 or image.height != 128) {
        image.deinit(allocator);
        return error.InvalidColorMapDimensions;
    }

    return image.pixels;
}

pub fn decodePalette(data: []const u8) ![256]u32 {
    if (data.len < 769) return error.TruncatedPcxPalette;

    const rgb = data[data.len - 768 ..];
    var result: [256]u32 = undefined;

    for (&result, 0..) |*color, i| {
        color.* = @as(
            u32,
            rgb[i * 3],
        ) | @as(u32, rgb[i * 3 + 1]) << 8 | @as(u32, rgb[i * 3 + 2]) << 16;
    }

    return result;
}

pub fn levelPalette(system: [256]u32, level: [256]u32) [256]u32 {
    var result = system;
    @memcpy(result[16..], level[16..]);

    return result;
}

pub fn defaultDepthMap() [128]u8 {
    var result: [128]u8 = undefined;
    const coefficient: f32 = @bitCast(@as(u32, 0x3e71e3c8));

    for (0..128) |i| {
        const value: f32 = @floatCast(
            @min(31.0, @max(0.0, 31.0 - @as(f64, @floatFromInt(i)) * @as(f64, coefficient))),
        );

        const lower = @floor(value);
        const integer: u8 = @intFromFloat(lower);
        const fraction = value - lower;

        result[127 - i] = integer + @as(
            u8,
            @intFromBool(fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)),
        );
    }

    return result;
}

fn assetFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn expectHash(actual: [32]u8, comptime expected: []const u8) !void {
    var bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, expected);
    try std.testing.expectEqualSlices(u8, &bytes, &actual);
}

test "Train missing texture entries use the reference DEFAULT PCX" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLTEX.LAB",
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const expected = try decode(allocator, try archive.find("DEFAULT.PCX", 0x5458544d));
    defer expected.deinit(allocator);

    for ([_][]const u8{ "GWTRAI~1.PCX", "GWTRAI~2.PCX" }) |name| {
        try std.testing.expectError(error.ResourceNotFound, loadInitial(allocator, archive, name));

        const actual = try loadLevelInitial(allocator, archive, name);
        defer actual.deinit(allocator);

        try std.testing.expectEqual(expected.width, actual.width);
        try std.testing.expectEqual(expected.height, actual.height);
        try std.testing.expectEqualSlices(u8, expected.pixels, actual.pixels);
    }

    try std.testing.expectError(
        error.UnsupportedTextureFormat,
        loadLevelInitial(allocator, archive, "UNKNOWN.BMP"),
    );
}

test "TXTM rotation, bottom trim, and transparency flags match crop" {
    var data = [_]u8{0} ** (128 + 16 + 769);
    @memcpy(data[0..4], &[_]u8{ 10, 5, 1, 8 });

    std.mem.writeInt(u16, data[8..10], 3, .little);
    std.mem.writeInt(u16, data[10..12], 3, .little);

    data[65] = 1;
    @memcpy(data[128..144], &[_]u8{ 1, 2, 0, 0, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

    const texture = try decode(std.testing.allocator, &data);
    defer texture.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), texture.width);
    try std.testing.expectEqual(@as(usize, 2), texture.height);
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 4, 2 }, texture.pixels);
    try std.testing.expectEqual(TextureFlags{ .width_power_of_two = true, .height_power_of_two = true }, texture.flags);
    try std.testing.expectEqual(@as(u5, 1), texture.height_shift);
}

test "TXTM crop preserves final-row exclusion and width comparison quirks" {
    var data = [_]u8{0} ** (128 + 8 + 769);
    @memcpy(data[0..4], &[_]u8{ 10, 5, 1, 8 });

    std.mem.writeInt(u16, data[8..10], 3, .little);
    std.mem.writeInt(u16, data[10..12], 1, .little);

    data[65] = 1;
    @memcpy(data[128..136], &[_]u8{ 0, 9, 0, 0, 0, 0, 0, 0 });

    const texture = try decode(std.testing.allocator, &data);
    defer texture.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), texture.width);
    try std.testing.expectEqual(@as(usize, 2), texture.height);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 9, 0, 0, 0, 0 }, texture.pixels);
    try std.testing.expectEqual(TextureFlags{ .width_power_of_two = true, .height_power_of_two = true, .transparent = true }, texture.flags);
}

test "CD1 hideout textures and color maps match independent routine transcriptions" {
    const allocator = std.testing.allocator;
    const texture_data = try assetFile("inputs/OUTLAWS_CD1/OUTLAWS/OLTEX.LAB");
    defer allocator.free(texture_data);
    const geometry_data = try assetFile("inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB");
    defer allocator.free(geometry_data);
    const system_data = try assetFile("inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB");
    defer allocator.free(system_data);
    const textures = try lab.Archive.init(texture_data);
    const geometry = try lab.Archive.init(geometry_data);
    const system = try lab.Archive.init(system_data);
    const level = try geometry.find("HIDEOUT.LVT", 0);
    var lines = std.mem.splitScalar(u8, level, '\n');
    var count: usize = 0;
    var animation_count: usize = 0;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});

    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const token = words.next() orelse continue;

        if (!std.mem.eql(u8, token, "TEXTURE:")) continue;

        const texture = try loadInitial(
            allocator,
            textures,
            words.next() orelse return error.InvalidTextureName,
        );

        defer texture.deinit(allocator);
        var metadata: [10]u8 = undefined;

        std.mem.writeInt(u32, metadata[0..4], @intCast(texture.width), .little);
        std.mem.writeInt(u32, metadata[4..8], @intCast(texture.height), .little);

        metadata[8] = @bitCast(texture.flags);
        metadata[9] = texture.height_shift;

        digest.update(&metadata);
        digest.update(texture.pixels);

        count += 1;

        if (texture.animation) |animation| {
            animation_count += 1;
            try std.testing.expectEqualStrings(
                if (animation_count == 1) "GAWIN2A.PCX" else "HWNCRTIA.PCX",
                animation.initialTexture().?,
            );
        }
    }

    try std.testing.expectEqual(@as(usize, 87), count);
    try std.testing.expectEqual(@as(usize, 2), animation_count);

    var hash: [32]u8 = undefined;

    digest.final(&hash);
    try expectHash(hash, "863783357c102c79c1c5d9d36d40ea28669d381d3ddf91556e60df87f7fe997c");

    const cmap = try decodeColorMap(allocator, try system.find("HIDEOUT.PCX", 0));
    defer allocator.free(cmap);

    std.crypto.hash.sha2.Sha256.hash(cmap, &hash, .{});
    try expectHash(hash, "5c4106b967bb0d42f116fe91e68937469716b0402ec9798408093973a6e74782");

    const dmap = defaultDepthMap();

    std.crypto.hash.sha2.Sha256.hash(&dmap, &hash, .{});
    try expectHash(hash, "6dfd741cc26caff2f61a67561debbdd00745ab38eea0edd8b0bd9c9963335f46");

    const sys_palette = try decodePalette(try system.find("SYSPAL.PCX", 0x50435850));
    const hideout_palette = try decodePalette(try system.find("HIDEOUT.PCX", 0x50435850));
    const palette = levelPalette(sys_palette, hideout_palette);

    try std.testing.expectEqualSlices(u32, sys_palette[0..16], palette[0..16]);
    try std.testing.expectEqualSlices(u32, hideout_palette[16..], palette[16..]);
}
