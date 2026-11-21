//! Story recipes: the ordered list of movies and levels a campaign plays,
//! and the multiplayer game records.
//!
//! A name consumes the whole rest of its line, spaces included. Paths are
//! prepended as they are read, and one that is too long is skipped. MODES
//! decides which multiplayer modes a record offers; the FLAGS field is not
//! read. Line endings are normalised, comments and blank lines dropped,
//! indentation preserved, and overlong lines rejected.

const std = @import("std");

pub const Kind = enum(u32) { level = 1, movie = 2, credits = 3, text = 4 };

pub const Entry = struct { kind: Kind, disc: u8, name: []const u8 };

pub const Recipe = struct {
    name: []const u8,
    modes: u32,
    story: []Entry,
    paths: [][]const u8,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Recipe {
        var lines = Lines{ .data = data };
        const header = try lines.next() orelse return error.MissingRcpHeader;
        if (!std.mem.startsWith(u8, header, "RCP")) return error.InvalidRcpHeader;
        var version = Scanner{ .remaining = header[3..] };
        const major = version.integer() orelse return error.InvalidRcpHeader;
        if (!version.literal(".")) return error.InvalidRcpHeader;
        const minor = version.integer() orelse return error.InvalidRcpHeader;
        if (major != 1 or minor != 0) return error.UnsupportedRcpVersion;

        var name: []const u8 = "";
        var modes: u32 = 0;
        var story: std.ArrayList(Entry) = .empty;
        errdefer story.deinit(allocator);
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer paths.deinit(allocator);
        while (try lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "NAME:")) {
                const remainder = std.mem.trimStart(u8, line[5..], " \t");
                if (remainder.len != 0) name = remainder[0..@min(32, remainder.len)];
            }
            if (std.mem.startsWith(u8, line, "MODES:")) {
                var mode_scan = Scanner{ .remaining = line[6..] };
                if (mode_scan.word()) |letters| for (letters) |letter| {
                    modes |= switch (std.ascii.toUpper(letter)) {
                        'C' => @as(u32, 1),
                        'T' => 2,
                        'K' => 4,
                        'S' => 8,
                        'M' => 16,
                        'D' => 32,
                        else => 0,
                    };
                };
            }
            if (hasDirective(line, "STORY:")) {
                const begin = try lines.next() orelse return error.UnterminatedStory;
                if (!hasDirective(begin, "BEGIN")) return error.MissingStoryBegin;
                while (true) {
                    const story_line = try lines.next() orelse return error.UnterminatedStory;
                    if (hasDirective(story_line, "END")) break;
                    if (parseEntry(story_line)) |entry| try story.append(allocator, entry);
                }
            }
            if (std.mem.startsWith(u8, line, "PATHS:")) {
                var count_scan = Scanner{ .remaining = line[6..] };
                var count = count_scan.integer() orelse continue;
                while (count != 0) {
                    const path_line = try lines.next() orelse break;
                    var path_scan = Scanner{ .remaining = path_line };
                    path_scan.skipWhitespace();
                    if (!path_scan.literal("PATH:")) continue;
                    const joined = path_scan.word() orelse continue;
                    var parts = std.mem.splitScalar(u8, joined, ';');
                    while (parts.next()) |part| {
                        const final = parts.index == null;
                        if (part.len < 64 and (!final or part.len != 0))
                            try paths.append(allocator, part);
                    }
                    count -%= 1;
                }
            }
        }
        std.mem.reverse([]const u8, paths.items);
        const story_owned = try story.toOwnedSlice(allocator);
        errdefer allocator.free(story_owned);
        return .{
            .name = name,
            .modes = modes,
            .story = story_owned,
            .paths = try paths.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: Recipe, allocator: std.mem.Allocator) void {
        allocator.free(self.story);
        allocator.free(self.paths);
    }
};

pub const Sequence = struct {
    recipe: *const Recipe,
    current: ?usize = null,
    finished: bool = false,

    pub fn advance(self: *Sequence) ?Entry {
        if (self.finished) return null;
        const next = if (self.current) |index| index + 1 else 0;
        if (next == self.recipe.story.len) {
            self.current = null;
            self.finished = true;
            return null;
        }
        self.current = next;
        return self.recipe.story[next];
    }
};

const Lines = struct {
    data: []const u8,
    cursor: usize = 0,

    fn next(self: *Lines) !?[]const u8 {
        while (self.cursor < self.data.len) {
            const start = self.cursor;
            while (self.cursor < self.data.len and self.data[self.cursor] != '\n' and self.data[self.cursor] != '\r')
                self.cursor += 1;
            const raw = self.data[start..self.cursor];
            if (raw.len > 254) return error.UnsupportedRcpLineLength;
            if (self.cursor < self.data.len) {
                const delimiter = self.data[self.cursor];
                self.cursor += 1;
                if (delimiter == '\r' and self.cursor < self.data.len and self.data[self.cursor] == '\n') self.cursor += 1;
            }
            const line = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            return line;
        }
        return null;
    }
};

const Scanner = struct {
    remaining: []const u8,

    fn skipWhitespace(self: *Scanner) void {
        while (self.remaining.len != 0 and std.ascii.isWhitespace(self.remaining[0]))
            self.remaining = self.remaining[1..];
    }

    fn literal(self: *Scanner, value: []const u8) bool {
        if (!std.mem.startsWith(u8, self.remaining, value)) return false;
        self.remaining = self.remaining[value.len..];
        return true;
    }

    fn word(self: *Scanner) ?[]const u8 {
        self.skipWhitespace();
        var end: usize = 0;
        while (end < self.remaining.len and !std.ascii.isWhitespace(self.remaining[end])) : (end += 1) {}
        if (end == 0) return null;
        const result = self.remaining[0..end];
        self.remaining = self.remaining[end..];
        return result;
    }

    fn integer(self: *Scanner) ?i32 {
        self.skipWhitespace();
        var end: usize = 0;
        if (end < self.remaining.len and (self.remaining[end] == '+' or self.remaining[end] == '-')) end += 1;
        const start = end;
        while (end < self.remaining.len and std.ascii.isDigit(self.remaining[end])) : (end += 1) {}
        if (end == start) return null;
        const result = std.fmt.parseInt(i32, self.remaining[0..end], 10) catch return null;
        self.remaining = self.remaining[end..];
        return result;
    }
};

fn parseEntry(line: []const u8) ?Entry {
    const directives = .{ "LEVEL:", "MOVIE:", "CREDITS:", "TEXT:" };
    inline for (directives, 1..) |directive, id| {
        var scan = Scanner{ .remaining = line };
        scan.skipWhitespace();
        if (scan.literal(directive)) {
            const name = scan.word() orelse return null;
            const disc: u32 = @bitCast(scan.integer() orelse @as(i32, 0));
            return .{ .kind = @enumFromInt(id), .name = name, .disc = @truncate(disc) };
        }
    }
    return null;
}

fn hasDirective(line: []const u8, directive: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), directive);
}

test "RCP preserves ordered typed story, disc truncation, and one-shot sequence" {
    const recipe = try Recipe.parse(std.testing.allocator, "# comment\r\nRCP 1.0\r\nNAME: Outlaws Story\r\nFLAGS: 255\r\n" ++
        "STORY:\r\n BEGIN\r\n MOVIE: in_shb.san 257\r\n LEVEL: hideout\r\n" ++
        " TEXT: intro.txt -1\r\n CREDITS: rae.san 2\r\n END\r\nPATHS: 0\r\n");
    defer recipe.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Outlaws Story", recipe.name);
    try std.testing.expectEqual(@as(u32, 0), recipe.modes);
    try std.testing.expectEqual(@as(usize, 4), recipe.story.len);
    var sequence = Sequence{ .recipe = &recipe };
    const movie = sequence.advance().?;
    try std.testing.expectEqual(Kind.movie, movie.kind);
    try std.testing.expectEqual(@as(u8, 1), movie.disc);
    const level = sequence.advance().?;
    try std.testing.expectEqualStrings("hideout", level.name);
    try std.testing.expectEqual(@as(u8, 0), level.disc);
    try std.testing.expectEqual(@as(u8, 255), sequence.advance().?.disc);
    try std.testing.expectEqual(Kind.credits, sequence.advance().?.kind);
    try std.testing.expect(sequence.advance() == null);
    try std.testing.expect(sequence.advance() == null);
}

test "RCP modes, prefix directives, path precedence and malformed stories" {
    const recipe = try Recipe.parse(std.testing.allocator, "RCP 1.0\nMODES: cTkSmDx\nSTORY: suffix\n BEGINsuffix\n UNKNOWN: ignored\n ENDsuffix\n" ++
        "PATHS: 2\n PATH: first;second\n PATH: third;\n");
    defer recipe.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 63), recipe.modes);
    try std.testing.expectEqual(@as(usize, 0), recipe.story.len);
    try std.testing.expectEqual(@as(usize, 3), recipe.paths.len);
    try std.testing.expectEqualStrings("third", recipe.paths[0]);
    try std.testing.expectEqualStrings("second", recipe.paths[1]);
    try std.testing.expectEqualStrings("first", recipe.paths[2]);
    try std.testing.expectError(error.UnterminatedStory, Recipe.parse(std.testing.allocator, "RCP 1.0\nSTORY:\nBEGIN\nLEVEL: hideout\n"));
    try std.testing.expectError(error.UnsupportedRcpVersion, Recipe.parse(std.testing.allocator, "RCP 1.1\n"));
}
