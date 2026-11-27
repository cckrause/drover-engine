//! The text form of level data: tokenizes .lvt and .obt into exactly the
//! same unaligned token records the binary parser produces, so everything
//! above this file sees one representation.
//!
//! Token ids, argument counts and value types come from a fixed table.
//! Values are parsed per field and packed by type; trailing text on a line
//! is ignored, and a directive without its value still emits its token with
//! no arguments. Lines are limited to 1024 bytes including the terminator.

const std = @import("std");

const level_rules = [_]Rule{
    .{ .id = 0, .action = 2, .jump = -1, .minimum = 1000, .format = "LVT %d.%d" },
    .{ .id = 1, .action = 2, .jump = -1, .minimum = 1000, .format = "LEVELNAME %s" },
    .{ .id = 2, .action = 2, .jump = -1, .minimum = 1000, .format = "VERSION %d.%d" },
    .{ .id = 3, .action = 2, .jump = -1, .minimum = 1000, .format = "PALETTES %d" },
    .{ .id = 4, .action = 1, .jump = 4, .minimum = 1000, .format = "PALETTE: %s" },
    .{ .id = 5, .action = 2, .jump = 7, .minimum = 1000, .format = "CMAPS %d" },
    .{ .id = 6, .action = 1, .jump = 6, .minimum = 1000, .format = "CMAP: %s" },
    .{ .id = 7, .action = 2, .jump = -2, .minimum = 1000, .format = "MUSIC %s" },
    .{ .id = 8, .action = 2, .jump = -1, .minimum = 1000, .format = "PARALLAX %f %f" },
    .{ .id = 9, .action = 2, .jump = -2, .minimum = 1000, .format = "LIGHT SOURCE %f %f %f %f" },
    .{ .id = 10, .action = 2, .jump = -1, .minimum = 1000, .format = "SHADES %d" },
    .{ .id = 11, .action = 1, .jump = 11, .minimum = 1000, .format = "SHADE: %d %d %d %d %d %c" },
    .{ .id = 12, .action = 2, .jump = -1, .minimum = 1000, .format = "TEXTURES %d" },
    .{ .id = 13, .action = 1, .jump = 13, .minimum = 1000, .format = "TEXTURE: %s" },
    .{ .id = 14, .action = 2, .jump = -1, .minimum = 1000, .format = "NUMSECTORS %d" },
    .{ .id = 15, .action = 2, .jump = 40, .minimum = 1000, .format = "SECTOR %x" },
    .{ .id = 16, .action = 2, .jump = -2, .minimum = 0, .format = "NAME %s" },
    .{ .id = 17, .action = 2, .jump = -1, .minimum = 1000, .format = "AMBIENT %d" },
    .{ .id = 18, .action = 2, .jump = -2, .minimum = 1000, .format = "PALETTE %d" },
    .{ .id = 19, .action = 2, .jump = -2, .minimum = 1000, .format = "CMAP %d" },
    .{ .id = 20, .action = 2, .jump = -2, .minimum = 1000, .format = "FRICTION %f" },
    .{ .id = 21, .action = 2, .jump = -2, .minimum = 1000, .format = "GRAVITY %f" },
    .{ .id = 22, .action = 2, .jump = -2, .minimum = 1000, .format = "ELASTICITY %f" },
    .{ .id = 23, .action = 2, .jump = -2, .minimum = 1000, .format = "VELOCITY %f %f %f" },
    .{ .id = 24, .action = 2, .jump = -2, .minimum = 1000, .format = "VADJOIN %d" },
    .{ .id = 25, .action = 2, .jump = -2, .minimum = 1000, .format = "FLOOR SOUND %s" },
    .{ .id = 26, .action = 2, .jump = -1, .minimum = 1000, .format = "FLOOR Y %f %d %f %f %f" },
    .{ .id = 27, .action = 2, .jump = -1, .minimum = 1000, .format = "CEILING Y %f %d %f %f %f" },
    .{ .id = 28, .action = 2, .jump = -1, .minimum = 1000, .format = "F_OVERLAY %d %f %f %f" },
    .{ .id = 29, .action = 2, .jump = -1, .minimum = 1000, .format = "C_OVERLAY %d %f %f %f" },
    .{ .id = 30, .action = 2, .jump = -1, .minimum = 1000, .format = "FLOOR OFFSETS %d" },
    .{
        .id = 31,
        .action = 1,
        .jump = 31,
        .minimum = 1000,
        .format = "OFFSET: %f %d %f %f FLAGS: %u %u",
    },
    .{ .id = 32, .action = 2, .jump = -1, .minimum = 1000, .format = "FLAGS %u %u" },
    .{ .id = 33, .action = 2, .jump = -2, .minimum = 1000, .format = "SLOPEDFLOOR %d %d %f" },
    .{ .id = 34, .action = 2, .jump = -2, .minimum = 1000, .format = "SLOPEDCEILING %d %d %f" },
    .{ .id = 35, .action = 2, .jump = -1, .minimum = 1000, .format = "LAYER %f" },
    .{ .id = 36, .action = 2, .jump = -1, .minimum = 1000, .format = "VERTICES %d" },
    .{ .id = 37, .action = 1, .jump = 37, .minimum = 1000, .format = "X: %f Z: %f" },
    .{ .id = 38, .action = 2, .jump = -1, .minimum = 1000, .format = "WALLS %d" },
    .{
        .id = 39,
        .action = 1,
        .jump = 39,
        .minimum = 1000,
        .format = "WALL: %x V1: %d V2: %d MID: %d %f %f TOP: %d %f %f BOT: %d %f %f OVERLAY: %d %f %f ADJOIN: %d MIRROR: %d DADJOIN: %d DMIRROR: %d FLAGS: %u %u LIGHT: %d",
    },
    .{ .id = -1, .action = 3, .jump = 15, .minimum = 0, .format = "" },
    .{ .id = 40, .action = 5, .jump = 0, .minimum = 0, .format = "" },
};

const object_rules = [_]Rule{
    .{ .id = 0, .action = 2, .jump = -1, .minimum = 1000, .format = "OBT %d.%d" },
    .{ .id = 1, .action = 2, .jump = -1, .minimum = 1000, .format = "LEVELNAME %s" },
    .{ .id = 2, .action = 2, .jump = -1, .minimum = 1000, .format = "OBJECTS %d" },
    .{
        .id = 3,
        .action = 1,
        .jump = 3,
        .minimum = 1000,
        .format = "NAME: %s ID: %x SECTOR: %x X: %f Y: %f Z: %f PCH: %f YAW: %f ROL: %f FLAGS: %u %u",
    },
    .{ .id = 4, .action = 5, .jump = 0, .minimum = 0, .format = "" },
};

const Rule = struct { id: i32, action: u8, jump: i32, minimum: u32, format: []const u8 };

pub fn tokenize(a: std.mem.Allocator, bytes: []const u8, kind: *const [4]u8) ![]u8 {
    const rules: []const Rule = if (std.mem.eql(
        u8,
        kind,
        ".LVT",
    )) &level_rules else if (std.mem.eql(
        u8,
        kind,
        ".OBT",
    )) &object_rules else return error.InvalidLevelTokenFormat;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);

    try output.appendSlice(a, &.{ 0, 0, 0, 0 });
    try output.appendSlice(a, kind);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var current: usize = 0;

    while (lines.next()) |raw| {
        if (raw.len > 1022) return error.UnsupportedTextLevelLineLength;

        const line = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");

        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        var visited: usize = 0;

        while (true) {
            if (current >= rules.len or visited > rules.len) return error.InvalidTextLevelParserState;

            visited += 1;

            const rule = rules[current];
            if (rule.action == 5) return output.toOwnedSlice(a);

            if (rule.action == 3) {
                current = try destination(rules, current);
                continue;
            }

            var record: [1024]u8 = undefined;
            const length = try scan(rule, line, &record);
            const matched = length != null;
            const jump = if (rule.action == 1) matched else !matched;

            current = if (jump) try destination(rules, current) else current + 1;

            if (length) |count| {
                try output.appendSlice(a, record[0..count]);
                break;
            }
        }
    }

    return output.toOwnedSlice(a);
}

fn destination(rules: []const Rule, current: usize) !usize {
    const id = rules[current].jump;
    if (id == -1) return error.UnexpectedTextLevelDirective;
    if (id == -2) return current + 1;

    for (rules, 0..) |rule, index| if (rule.id == id) return index;

    return error.InvalidTextLevelParserState;
}

fn scan(rule: Rule, line: []const u8, record: *[1024]u8) !?usize {
    var input: usize = 0;
    var format: usize = 0;
    var count: u8 = 0;
    var output: usize = 5;
    var expected: u8 = 0;

    for (rule.format) |byte| if (byte == '%') {
        expected += 1;
    };

    parsing: while (format < rule.format.len) {
        const byte = rule.format[format];
        format += 1;

        if (std.ascii.isWhitespace(byte)) {
            while (input < line.len and std.ascii.isWhitespace(line[input])) input += 1;
            continue;
        }

        if (byte != '%') {
            if (input == line.len or line[input] != byte) break;
            input += 1;
            continue;
        }

        const conversion = rule.format[format];
        format += 1;

        if (conversion != 'c') while (input < line.len and std.ascii.isWhitespace(line[input])) {
            input += 1;
        };

        if (input == line.len) break;

        switch (conversion) {
            's', 'c' => {
                const start = input;

                if (conversion == 'c') {
                    input += 1;
                } else {
                    while (input < line.len and !std.ascii.isWhitespace(line[input])) input += 1;
                }

                const value = line[start..input];
                if (value.len > 255 or output + value.len + 1 > record.len) return error.UnsupportedLevelStringLength;

                @memcpy(record[output..][0..value.len], value);

                output += value.len;
                record[output] = 0;
                output += 1;
            },
            'd', 'u', 'x' => {
                const negative = line[input] == '-';

                if (line[input] == '-' or line[input] == '+') input += 1;

                const base: u32 = if (conversion == 'x') 16 else 10;

                if (base == 16 and input + 1 < line.len and line[input] == '0' and std.ascii.toLower(line[input + 1]) == 'x') input += 2;

                const start = input;
                var value: u32 = 0;

                while (input < line.len) {
                    const digit = std.fmt.charToDigit(line[input], @intCast(base)) catch break;
                    value = value *% base +% digit;
                    input += 1;
                }

                if (input == start) break :parsing;

                if (negative) value = 0 -% value;

                std.mem.writeInt(u32, record[output..][0..4], value, .little);
                output += 4;
            },
            'f' => {
                const start = input;

                if (line[input] == '-' or line[input] == '+') input += 1;

                var digits: usize = 0;

                while (input < line.len and std.ascii.isDigit(
                    line[input],
                )) : (input += 1) digits += 1;

                if (input < line.len and line[input] == '.') {
                    input += 1;
                    while (input < line.len and std.ascii.isDigit(
                        line[input],
                    )) : (input += 1) digits += 1;
                }

                if (digits == 0) break :parsing;

                if (input < line.len and std.ascii.toLower(line[input]) == 'e') {
                    input += 1;

                    if (input < line.len and (line[input] == '-' or line[input] == '+')) input += 1;

                    const exponent = input;

                    while (input < line.len and std.ascii.isDigit(line[input])) input += 1;

                    if (input == exponent) return error.InvalidTextLevelFloat;
                }

                const value = std.fmt.parseFloat(
                    f32,
                    line[start..input],
                ) catch return error.InvalidTextLevelFloat;

                if (!std.math.isFinite(value)) return error.InvalidLevelCoordinate;

                std.mem.writeInt(u32, record[output..][0..4], @bitCast(value), .little);
                output += 4;
            },
            else => return error.UnsupportedTextLevelConversion,
        }

        count += 1;
    }

    if (count != expected and count < rule.minimum) return null;

    std.mem.writeInt(i32, record[0..4], rule.id, .little);
    record[4] = count;

    return output;
}

test "text tokenization matches every Miner LVT and OBT byte" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD2/OUTLAWS/OLGEO.LAB",
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try @import("lab.zig").Archive.init(bytes);

    inline for (.{
        .{ "MINER.LVT", ".LVT", "testdata/miner.lvt.native" },
        .{ "MINER.OBT", ".OBT", "testdata/miner.obt.native" },
    }) |entry| {
        const reference = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            entry[2],
            a,
            .limited(4 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };

        defer a.free(reference);
        const converted = try tokenize(a, try archive.find(entry[0], 0), entry[1]);
        defer a.free(converted);

        try std.testing.expectEqualSlices(u8, reference, converted);
    }
}
