//! LOCAL.MSG: the numbered UI strings the menus and HUD show.
//!
//! Each line holds two integers and a quoted string; the text is taken
//! verbatim between the first two quotes without unescaping. Both integers
//! are kept - the second is a record field, not a colour. Comments and
//! malformed lines are skipped, and the first definition of an id wins.
//! Lines longer than the 1024-byte input buffer are rejected rather than
//! truncated.

const std = @import("std");

pub const Record = struct { text: []const u8, category: u32 };

pub fn lookup(data: []const u8, id: u32) ![]const u8 {
    return (try lookupRecord(data, id)).text;
}

pub fn lookupRecord(data: []const u8, id: u32) !Record {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len > 1023) return error.UnsupportedMessageLine;
        const end = std.mem.indexOfScalar(u8, raw_line, 0) orelse raw_line.len;
        const line = raw_line[0..end];
        var cursor: usize = 0;
        const message_id = scanInteger(line, &cursor) orelse continue;
        const category = scanInteger(line, &cursor) orelse continue;
        if (message_id != id) continue;

        const opening = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const text = line[opening + 1 ..];
        const closing = std.mem.indexOfScalar(u8, text, '"') orelse continue;
        return .{ .text = text[0..closing], .category = category };
    }
    return error.MessageNotFound;
}

fn scanInteger(line: []const u8, cursor: *usize) ?u32 {
    while (cursor.* < line.len and std.ascii.isWhitespace(line[cursor.*]))
        cursor.* += 1;
    const start = cursor.*;
    if (cursor.* < line.len and (line[cursor.*] == '+' or line[cursor.*] == '-'))
        cursor.* += 1;
    const digits_start = cursor.*;
    while (cursor.* < line.len and std.ascii.isDigit(line[cursor.*]))
        cursor.* += 1;
    if (cursor.* == digits_start) return null;
    const number = std.fmt.parseInt(i32, line[start..cursor.*], 10) catch return null;
    return @bitCast(number);
}

test "message lookup skips comments and malformed lines and keeps the first ID" {
    const data =
        "# main menu\r\n" ++
        "6000 missing \"INVALID\"\r\n" ++
        "6000 9: \"unterminated\r\n" ++
        "\t6000  9: \"MAIN GAME\"\r\n" ++
        "6000 9: \"DUPLICATE\"\r\n" ++
        "6001 9: \"MULTIPLAYER\"\r\n";
    const text = try lookup(data, 6000);
    try std.testing.expectEqualStrings("MAIN GAME", text);
    try std.testing.expectEqualStrings("MULTIPLAYER", try lookup(data, 6001));
    try std.testing.expectError(error.MessageNotFound, lookup(data, 6002));
    try std.testing.expect(@intFromPtr(text.ptr) >= @intFromPtr(data.ptr));
    try std.testing.expect(@intFromPtr(text.ptr) + text.len <= @intFromPtr(data.ptr) + data.len);
}

test "parser checks two assignments and does not process escapes" {
    try std.testing.expectEqualStrings("a\\nb", try lookup("+6000+9 \"a\\nb\"", 6000));
    try std.testing.expectEqualStrings("prefix\\", try lookup("6000 9: \"prefix\\\"suffix\"", 6000));
    try std.testing.expectEqualStrings("", try lookup("6000 9: \"\"", 6000));
    try std.testing.expectError(error.MessageNotFound, lookup("6000 9: \x00\"hidden\"", 6000));
}
