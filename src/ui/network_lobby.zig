//! The lobby of a network game: the player list, the chat lines and the
//! character choice, shown inside level frames while the game waits to
//! start.
//!
//! The host opens it as part of its level entry and refills the player list
//! every frame; a joiner reaches the same screen after its objects arrive.
//! The mode words decide whether it is a team game and which background is
//! used. CHARACTER is disabled - nothing enables it. Sending a typed chat
//! line is not implemented; Escape asks for the in-level menu instead.

const std = @import("std");
const dialog = @import("dialog.zig");
const messages_module = @import("../assets/messages.zig");
const router_module = @import("../network/router.zig");
const Box = dialog.Box;

pub const records = [_]dialog.Record{
    .{ .kind = .text, .id = 0, .rect = box(25, 0, 100, 640) },
    .{ .kind = .lines, .id = 1, .rect = box(181, 49, 154, 336), .highlight = box(164, 27, 190, 378) },
    .{ .kind = .lines, .id = 2, .rect = box(181, 441, 153, 160), .highlight = box(163, 427, 188, 186) },
    .{ .kind = .text, .id = 4, .rect = box(365, 68, 22, 75), .highlight = box(365, 63, 28, 139) },
    .{ .kind = .field, .id = 3, .rect = box(365, 143, 22, 431), .highlight = box(364, 208, 29, 371) },
    .{ .kind = .button, .id = 8, .rect = box(400, 68, 22, 130), .highlight = box(396, 63, 29, 140) },
    .{ .kind = .text, .id = 9, .rect = box(398, 214, 22, 360), .highlight = box(396, 209, 29, 370) },
    .{ .kind = .button, .id = 1000, .rect = box(437, 46, 22, 130), .highlight = box(433, 41, 29, 140) },
    .{ .kind = .button, .id = 1001, .rect = box(437, 152, 22, 130), .highlight = box(433, 147, 29, 140) },
    .{ .kind = .button, .id = 6, .rect = box(437, 253, 22, 130), .highlight = box(433, 248, 29, 140) },
    .{ .kind = .button, .id = 7, .rect = box(437, 455, 22, 130), .highlight = box(433, 450, 29, 140) },
    .{ .kind = .button, .id = 5, .rect = box(437, 354, 22, 130), .highlight = box(433, 349, 29, 140) },
    .{ .kind = .text, .id = 10, .rect = box(5, 5, 15, 630) },
};

pub const mode_words = [_]u32{ 0, 1, 2, 2, 1, 1, 0 };

pub const character_texts = [_]u32{ 0x13bd, 0x13c3, 0x13c1, 0x13c0, 0x13bf, 0x13be, 0x13c2 };

pub const Lobby = struct {
    fonts: *const dialog.Fonts,
    mode: u32,
    top_line: [0x50]u8 = @splat(0),
    chat: [0x50]u8 = @splat(0),
    character_locked: bool = false,
    menu_requested: bool = false,
    character_requested: bool = false,

    pub fn page(self: *Lobby) dialog.Page {
        return .{ .context = self, .call = call };
    }

    fn call(context: *anyopaque, d: *dialog.Dialog, message: dialog.Message, id: u32, value: i32) anyerror!void {
        const self: *Lobby = @ptrCast(@alignCast(context));
        switch (message) {
            .init => try self.open(d),
            .step => try d.stepFocus(id, value),
            .focus => if (id == 3) d.setColor(4, if (value == 0) 0 else 0xffffff, 0x40000000),
            .activate => switch (id) {
                1000, 1001 => {
                    d.running = false;
                    d.result = 0;
                },
                3 => if (value == 0) return error.LobbyChatNotPorted,
                4 => return error.LobbyChatNotPorted,
                5, 6, 7 => {
                    d.running = false;
                    d.result = @intCast(id - 4);
                },
                8 => self.character_requested = true,
                dialog.cancel_id => return error.LobbyEscapeMenuNotPorted,
                else => {},
            },
            .changed, .close => {},
        }
    }

    fn open(self: *Lobby, d: *dialog.Dialog) !void {
        self.chat[0] = 0;
        try d.setValue(10, .of(std.mem.sliceTo(&self.top_line, 0)), 0);
        d.setColor(10, 0xffffff, 0);
        for ([_]struct { u32, []const u8 }{
            .{ 0, "&7400" }, .{ 4, "&7401" }, .{ 1000, "&7402" }, .{ 1001, "&7402" },
            .{ 8, "&7403" }, .{ 9, "&7403" }, .{ 5, "&7404" },    .{ 6, "&7405" },
            .{ 7, "&7406" },
        }) |entry| {
            try d.setValue(entry[0], .of(entry[1]), 0);
            d.setFont(entry[0], if (entry[0] == 0) &self.fonts.title else &self.fonts.row);
        }
        try d.setValue(3, .field(&self.chat), 0x50);
        d.setFont(3, &self.fonts.row);
        d.setColor(4, 0, 0x40000000);
        const teams = mode_words[self.mode] & 1 != 0;
        for (d.widgets) |*widget| switch (widget.id) {
            1000, 6, 7 => widget.state = @intFromBool(teams),
            1001, 5 => widget.state = @intFromBool(!teams),
            8 => if (self.character_locked) {
                widget.state = 0;
            },
            else => {},
        };
    }
};

pub const PlayerLine = struct { team: u32, score: i16, stand_in: bool, name: []const u8, letter: u8 };

pub fn picture(mode: u32) ![]const u8 {
    if (mode >= mode_words.len) return error.InvalidMultiplayerMode;
    return if (mode_words[mode] & 1 == 0) "L1D216.PCX" else "L2D216.PCX";
}

pub fn showCharacter(d: *dialog.Dialog, local_messages: []const u8, costume: u32) !void {
    if (costume >= character_texts.len) return error.InvalidMultiplayerCharacter;
    const name = messages_module.lookup(local_messages, character_texts[costume]) catch |err| switch (err) {
        error.MessageNotFound => "",
        else => return err,
    };
    try d.setValue(9, .of(name[0..@min(name.len, 0x3b)]), 0);
}

pub fn refreshPlayers(a: std.mem.Allocator, d: *dialog.Dialog, router: *const router_module.Router, players: []const u8, mode: u32, game_type: u32) !void {
    if (mode >= mode_words.len) return error.InvalidMultiplayerMode;
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| a.free(line);
        lines.deinit(a);
    }
    for (players) |number| {
        if (number == 0) continue;
        const client = &router.clients[number];
        var team: u32 = 0;
        if (client.player) |player| {
            if (mode_words[mode] & 1 != 0) team = player.flags & 0xf else if (mode_words[mode] & 2 != 0 and player.flags & 0xf == 1) team = 1;
        }
        const letter: u8 = if (client.player) |player| (if (game_type == 4 or game_type == 5) player.code else 'J') else '?';
        const colour: u8 = switch (team) {
            1 => 'R',
            2 => 'B',
            3 => 'G',
            else => 'W',
        };
        var digits: [8]u8 = undefined;
        const score = try std.fmt.bufPrint(&digits, "{d}", .{router.scores[number].points});
        const line = try std.fmt.allocPrint(a, "{c}{s}{s} : {s}-{c}", .{ colour, "   "[0..3 -| score.len], score, client.playerName(), letter });
        errdefer a.free(line);
        try lines.append(a, line);
    }
    try d.setLines(2, lines.items, false);
}

pub fn addChat(d: *dialog.Dialog, text: []const u8) !void {
    var line: [0x101]u8 = undefined;
    if (text.len + 1 > line.len) return error.LobbyChatTooLong;
    line[0] = 'W';
    @memcpy(line[1..][0..text.len], text);
    try d.prependLine(1, line[0 .. text.len + 1]);
}

fn box(top: i32, left: i32, height: i32, width: i32) Box {
    return .{ .top = top, .left = left, .height = height, .width = width };
}

test "Death Match lobby: texts, enabled buttons, the player list and ENTER GAME" {
    const a = std.testing.allocator;
    const lab = @import("../assets/lab.zig");
    const nwx = @import("../assets/nwx.zig");
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var shared = dialog.Shared{};
    var page = Lobby{ .fonts = &fonts, .mode = 6 };
    var palette: [256]u32 = @splat(0);
    var screen: dialog.Dialog = undefined;
    try screen.open(a, archive, &shared, null, page.page(), &records, &fonts, &cursor, try picture(6), null, &palette, .{});
    defer _ = screen.close() catch {};
    try showCharacter(&screen, try archive.find("LOCAL.MSG", 0), 2);
    try std.testing.expectEqualStrings("OUTLAWS LOBBY", screen.find(0).?.data.text.text.?);
    try std.testing.expectEqualStrings("James Anderson", screen.find(9).?.data.text.text.?);
    for ([_]struct { u32, i32 }{ .{ 1000, 0 }, .{ 1001, 1 }, .{ 6, 0 }, .{ 7, 0 }, .{ 5, 1 }, .{ 8, 1 } }) |entry|
        try std.testing.expectEqual(entry[1], screen.find(entry[0]).?.state);
    var router = try router_module.Router.init(a);
    defer router.deinit();
    router.reset();
    router.clients[1].player = .{ .code = 'J', .flags = 0x1000090 };
    @memcpy(router.clients[1].name[0..6], "Player");
    router.clients[3].player = .{ .code = 'J', .flags = 0x1000090 };
    @memcpy(router.clients[3].name[0..6], "Joiner");
    router.scores[3].points = -2;
    try refreshPlayers(a, &screen, &router, &.{ 1, 3 }, 6, 5);
    const lines = screen.find(2).?.data.lines.items.items;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("W  0 : Player-J", lines[0]);
    try std.testing.expectEqualStrings("W -2 : Joiner-J", lines[1]);
    try addChat(&screen, "Joiner joined the game!");
    try std.testing.expectEqualStrings("WJoiner joined the game!", screen.find(1).?.data.lines.items.items[0]);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    try std.testing.expect(try screen.render(pixels, &palette));
    try page.page().send(&screen, .activate, 5, 0);
    try std.testing.expect(!screen.running);
    try std.testing.expectEqual(@as(i32, 1), screen.result);
}
