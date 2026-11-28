//! The header of a saved game: which disc, which resource, and which story
//! node the save sits on.
//!
//! The story node is stored as a one-based ordinal; restoring reloads the
//! resource and walks its links to that node. Compression starts after the
//! header, so the header is always readable.

const std = @import("std");

const GameType = @import("../game_type.zig").GameType;
const stream = @import("stream.zig");

pub const EngineState = struct {
    difficulty: u32,
    mode_mask: u32,
    badge: u32,
    game_860: u32,
    game_864: u32,
    game_type: GameType,
    game_state: u32,
    previous_game_state: u32,
    scenario: u32,
    previous_scenario: u32,

    pub fn write(self: EngineState, writer: *stream.Writer) !void {
        inline for (std.meta.fields(
            EngineState,
        )) |field| {
            const value = @field(self, field.name);
            try writer.integer(u32, if (field.type == GameType) @intFromEnum(value) else value);
        }
    }

    pub fn read(reader: *stream.Reader) !EngineState {
        var state: EngineState = undefined;

        inline for (std.meta.fields(
            EngineState,
        )) |field| {
            const value = try reader.integer(u32);
            @field(state, field.name) = if (field.type == GameType) @enumFromInt(value) else value;
        }

        return state;
    }
};

pub const Thumbnail = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

pub const RecipeState = struct {
    disc: u32,
    filename: []const u8,
    ordinal: u32,
};

pub const Header = struct {
    description: [15]u8,
    thumbnail: Thumbnail,
    mounted_disc: u32,
    level_archive: []const u8,
    engine: EngineState,
    clock: u32,
    palette: u32,
    level_name: []const u8,
    pushed_state: ?[]const u8 = null,
    recipe: ?RecipeState,

    pub fn write(self: Header, writer: *stream.Writer) !void {
        if (writer.compressed or writer.used != 0) return error.SaveHeaderAfterCompressedData;

        const count = std.math.mul(
            u32,
            self.thumbnail.width,
            self.thumbnail.height,
        ) catch return error.InvalidSaveThumbnail;

        if (count != self.thumbnail.pixels.len) return error.InvalidSaveThumbnail;

        try writer.marker(0x42534c4f, 1, 2);
        try writer.write(&self.description);
        try writer.integer(u32, self.thumbnail.width);
        try writer.integer(u32, self.thumbnail.height);
        try writer.write(self.thumbnail.pixels);
        try writer.integer(u32, self.mounted_disc);
        try writer.string(self.level_archive);
        try self.engine.write(writer);
        try writer.integer(u32, self.clock);
        try writer.integer(u32, self.palette);
        try writer.string(self.level_name);
        try writer.boolean(self.pushed_state != null);

        if (self.pushed_state) |state| {
            try writer.integer(u32, @intCast(state.len));
            try writer.write(state);
        }

        try writer.boolean(self.recipe != null);

        if (self.recipe) |recipe| {
            try writer.integer(u32, recipe.disc);
            try writer.string(recipe.filename);
            try writer.integer(u32, recipe.ordinal);
        }

        writer.compressed = true;
    }

    pub fn read(arena: std.mem.Allocator, reader: *stream.Reader) !Header {
        if (reader.compressed or reader.remaining != 0) return error.SaveHeaderAfterCompressedData;

        try reader.marker(0x42534c4f, 1, 2);
        var result: Header = undefined;
        try reader.read(&result.description);

        result.thumbnail.width = try reader.integer(u32);
        result.thumbnail.height = try reader.integer(u32);

        const count = std.math.mul(
            u32,
            result.thumbnail.width,
            result.thumbnail.height,
        ) catch return error.InvalidSaveThumbnail;

        if (count > reader.bytes.len - reader.position) return error.TruncatedSaveGame;

        const pixels = try arena.alloc(u8, count);

        try reader.read(pixels);

        result.thumbnail.pixels = pixels;
        result.mounted_disc = try reader.integer(u32);
        result.level_archive = try readString(arena, reader);
        result.engine = try EngineState.read(reader);
        result.clock = try reader.integer(u32);
        result.palette = try reader.integer(u32);
        result.level_name = try readString(arena, reader);
        result.pushed_state = null;

        if (try reader.boolean()) {
            const size = try reader.integer(u32);
            if (size > reader.bytes.len - reader.position) return error.TruncatedSaveGame;

            const state = try arena.alloc(u8, size);

            try reader.read(state);
            result.pushed_state = state;
        }

        result.recipe = null;

        if (try reader.boolean()) result.recipe = .{
            .disc = try reader.integer(u32),
            .filename = try readString(arena, reader),
            .ordinal = try reader.integer(u32),
        };

        reader.compressed = true;

        return result;
    }
};

pub const Statistics = struct {
    accumulated: ?[15]u32,
    level: [15]u32,

    pub fn write(self: Statistics, writer: *stream.Writer) !void {
        try writer.integer(u32, @intFromBool(self.accumulated != null));
        if (self.accumulated) |values| for (values) |value| try writer.integer(u32, value);
        for (self.level) |value| try writer.integer(u32, value);
    }

    pub fn read(reader: *stream.Reader) !Statistics {
        var result: Statistics = .{ .accumulated = null, .level = undefined };

        if (try reader.integer(u32) != 0) {
            var values: [15]u32 = undefined;
            for (&values) |*value| value.* = try reader.integer(u32);
            result.accumulated = values;
        }

        for (&result.level) |*value| value.* = try reader.integer(u32);

        return result;
    }
};

fn readString(arena: std.mem.Allocator, reader: *stream.Reader) ![]const u8 {
    var buffer: [255]u8 = undefined;

    return arena.dupe(u8, try reader.string(&buffer));
}

test "save header, story reference and statistics match the reference" {
    const a = std.testing.allocator;
    var engine: EngineState = undefined;

    inline for (std.meta.fields(EngineState), 0..) |field, i| {
        @field(engine, field.name) = if (field.type == GameType) @enumFromInt(11 + i) else 11 + i;
    }

    const header: Header = .{
        .description = "ORACLE".* ++ [_]u8{0} ** 9,
        .thumbnail = .{ .width = 2, .height = 2, .pixels = &.{ 1, 2, 3, 4 } },
        .mounted_disc = 1,
        .level_archive = "hideout",
        .engine = engine,
        .clock = 90000,
        .palette = 7,
        .level_name = "hideout",
        .recipe = .{ .disc = 1, .filename = "OUTLAWS.RCS", .ordinal = 2 },
    };

    var statistics: Statistics = .{ .accumulated = undefined, .level = undefined };

    for (0..15) |i| {
        statistics.accumulated.?[i] = @intCast(100 + i);
        statistics.level[i] = @intCast(115 + i);
    }

    var writer: stream.Writer = .{ .allocator = a };
    defer writer.deinit();

    try header.write(&writer);
    try writer.integer(u32, 0);
    try statistics.write(&writer);

    const bytes = try writer.finish();
    defer a.free(bytes);
    var hash: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected,
        "0993f7883dbe92af74d4c97e13a4ad2c9fcfec7550c2825609e29924004b6a8a",
    );

    try std.testing.expectEqualSlices(u8, &expected, &hash);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reader: stream.Reader = .{ .bytes = bytes };
    const restored = try Header.read(arena.allocator(), &reader);

    try std.testing.expectEqualDeep(header, restored);
    try std.testing.expectEqual(@as(u32, 0), try reader.integer(u32));
    try std.testing.expectEqualDeep(statistics, try Statistics.read(&reader));

    try reader.end();
}
