//! The network setup screens: the driver and transport, the game list and
//! location, the mode and its options, and joining a listed session.
//!
//! The mode list is filtered by the bits the story's game records declare,
//! and changing the location leaves the list selection at zero. Accepting a
//! page writes its values straight into the settings store under the keys
//! the game expects. A session name carries a version prefix that the join
//! path checks before offering the session. The user name comes from the
//! settings store and is copied into a fourteen-character field.

const std = @import("std");
const network_driver = @import("../network/driver.zig");
const lab = @import("../assets/lab.zig");
const messages = @import("../assets/messages.zig");
const dialog = @import("dialog.zig");
const settings = @import("../settings.zig");
const nwx = @import("../assets/nwx.zig");
const Box = dialog.Box;

pub const records = [_]dialog.Record{
    .{ .kind = .text, .id = 0, .rect = box(23, 0, 100, 640) },
    .{ .kind = .text, .id = 1, .rect = box(153, 20, 43, 300) },
    .{ .kind = .field, .id = 2, .rect = box(168, 331, 23, 234) },
    .{ .kind = .text, .id = 5, .rect = box(213, 37, 43, 246) },
    .{ .kind = .list, .id = 6, .rect = box(290, 37, 112, 246) },
    .{ .kind = .text, .id = 8, .rect = box(213, 357, 43, 245) },
    .{ .kind = .list, .id = 9, .rect = box(289, 357, 112, 245) },
    .{ .kind = .button, .id = dialog.cancel_id, .rect = box(431, 24, 22, 130), .highlight = box(427, 19, 29, 140) },
    .{ .kind = .button, .id = 7, .rect = box(431, 176, 22, 131), .highlight = box(427, 171, 29, 140) },
    .{ .kind = .button, .id = 10, .rect = box(431, 333, 22, 130), .highlight = box(427, 328, 29, 140) },
    .{ .kind = .button, .id = 11, .rect = box(430, 484, 24, 132), .highlight = box(427, 480, 29, 140) },
};

pub const host_records = [_]dialog.Record{
    .{ .kind = .text, .id = 0, .rect = box(22, 0, 100, 640) },
    .{ .kind = .text, .id = 1, .rect = box(142, 38, 43, 249) },
    .{ .kind = .list, .id = 2, .rect = box(216, 38, 139, 249), .highlight = box(202, 18, 167, 288) },
    .{ .kind = .text, .id = 3, .rect = box(142, 358, 43, 247) },
    .{ .kind = .list, .id = 4, .rect = box(216, 358, 138, 247), .highlight = box(202, 339, 167, 284) },
    .{ .kind = .text, .id = 15, .rect = box(384, 20, 29, 164) },
    .{ .kind = .field, .id = 16, .rect = box(385, 196, 22, 356), .highlight = box(384, 189, 29, 370) },
    .{ .kind = .button, .id = dialog.cancel_id, .rect = box(431, 56, 22, 130), .highlight = box(427, 51, 29, 140) },
    .{ .kind = .button, .id = 17, .rect = box(431, 446, 22, 130), .highlight = box(427, 440, 29, 140) },
};

pub const options_records = [_]dialog.Record{
    .{ .kind = .text, .id = 0, .rect = box(28, 0, 90, 640) },
    .{ .kind = .text, .id = 6, .rect = box(163, 20, 21, 309) },
    .{ .kind = .button, .id = 7, .rect = box(165, 344, 23, 21) },
    .{ .kind = .text, .id = 8, .rect = box(163, 350, 21, 130) },
    .{ .kind = .field, .id = 9, .rect = box(164, 500, 21, 57) },
    .{ .kind = .text, .id = 10, .rect = box(232, 20, 21, 309) },
    .{ .kind = .button, .id = 11, .rect = box(234, 344, 23, 21) },
    .{ .kind = .text, .id = 12, .rect = box(232, 350, 21, 130) },
    .{ .kind = .field, .id = 13, .rect = box(233, 500, 21, 57) },
    .{ .kind = .text, .id = 18, .rect = box(300, 20, 21, 139) },
    .{ .kind = .button, .id = 19, .rect = box(301, 174, 23, 21) },
    .{ .kind = .text, .id = 1, .rect = box(300, 198, 21, 182) },
    .{ .kind = .button, .id = 3, .rect = box(301, 395, 23, 21) },
    .{ .kind = .text, .id = 14, .rect = box(369, 20, 21, 139) },
    .{ .kind = .field, .id = 15, .rect = box(368, 177, 21, 57) },
    .{ .kind = .text, .id = 16, .rect = box(369, 244, 21, 134) },
    .{ .kind = .field, .id = 17, .rect = box(368, 398, 21, 116) },
    .{ .kind = .button, .id = 21, .rect = box(435, 324, 22, 130) },
    .{ .kind = .button, .id = 20, .rect = box(435, 476, 22, 130) },
};

pub const join_records = [_]dialog.Record{
    .{ .kind = .text, .id = 0, .rect = box(25, 7, 90, 477) },
    .{ .kind = .list, .id = 1, .rect = box(226, 28, 111, 174) },
    .{ .kind = .text, .id = 2, .rect = box(160, 5, 40, 221) },
    .{ .kind = .text, .id = 3, .rect = box(227, 254, 111, 174) },
    .{ .kind = .text, .id = 4, .rect = box(160, 230, 40, 220) },
    .{ .kind = .text, .id = 10, .rect = box(367, 77, 24, 116) },
    .{ .kind = .field, .id = 11, .rect = box(392, 77, 23, 116) },
    .{ .kind = .button, .id = 13, .rect = box(392, 213, 23, 116) },
    .{ .kind = .button, .id = dialog.cancel_id, .rect = box(438, 9, 23, 116) },
    .{ .kind = .button, .id = 14, .rect = box(438, 145, 23, 116) },
    .{ .kind = .button, .id = 12, .rect = box(438, 281, 23, 116) },
};

pub const Location = struct {
    basename: []const u8,
    name: []const u8,
    modes: u32,
};

pub const Choice = enum(i32) { cancel = -1, host = 0, join = 1 };

pub const HostGame = struct {
    store: *settings.Store,
    fonts: *const dialog.Fonts,
    locations: []const Location,
    location_lines: [100][]const u8 = undefined,
    modes: [6][32]u8 = undefined,
    mode_lines: [6][]const u8 = undefined,
    game_name: [14]u8 = @splat(0),
    open_options: bool = false,
    selected_location: usize = 0,
    selected_mode: u32 = 1,

    pub const mode_names = [_][]const u8{ "C.T.F.", "Tag", "K.F.C.", "Secret Document", "Teams", "Death Match" };

    pub fn init(store: *settings.Store, fonts: *const dialog.Fonts, locations: []const Location) !HostGame {
        if (locations.len == 0) return error.NoMultiplayerLocations;
        if (locations.len > 100) return error.TooManyMultiplayerLocations;
        var self: HostGame = .{ .store = store, .fonts = fonts, .locations = locations };
        const saved = (try store.read("", "Multiplayer", "Default Game")) orelse "";
        const length = @min(saved.len, self.game_name.len - 1);
        @memcpy(self.game_name[0..length], saved[0..length]);
        return self;
    }

    pub fn page(self: *HostGame) dialog.Page {
        return .{ .context = self, .call = call };
    }

    pub fn accept(self: *HostGame, d: *dialog.Dialog) !void {
        const selected = d.valueOf(4) orelse return error.InvalidMultiplayerMode;
        if (selected < 0 or selected >= 6) return error.InvalidMultiplayerMode;
        if (self.locations[self.selected_location].modes & (@as(u32, 1) << @intCast(selected)) == 0) return error.UnsupportedMultiplayerMode;
        self.selected_mode = @as(u32, @intCast(selected)) + 1;
        try self.store.write("", "Multiplayer", "Default Game", std.mem.sliceTo(&self.game_name, 0));
        d.running = false;
        d.result = 1;
    }

    fn call(context: *anyopaque, d: *dialog.Dialog, message: dialog.Message, id: u32, value: i32) anyerror!void {
        const self: *HostGame = @ptrCast(@alignCast(context));
        switch (message) {
            .init => try self.open(d),
            .changed => if (id == 2 and value >= 0 and value < self.locations.len) try self.locationChanged(d, @intCast(value)),
            .step => try d.stepFocus(id, value),
            .activate => switch (id) {
                dialog.cancel_id => {
                    d.running = false;
                    d.result = 0;
                },
                17 => self.open_options = true,
                else => {},
            },
            .close, .focus => {},
        }
    }

    fn open(self: *HostGame, d: *dialog.Dialog) !void {
        for (self.locations, 0..) |location, i| self.location_lines[i] = location.name;
        for (mode_names, 0..) |name, i| {
            self.modes[i][0] = '~';
            @memcpy(self.modes[i][1 .. 1 + name.len], name);
            self.mode_lines[i] = self.modes[i][0 .. 1 + name.len];
        }
        for ([_]struct { u32, []const u8 }{
            .{ 0, "&7200" },  .{ 1, "&7201" },                .{ 3, "&7202" },
            .{ 15, "&7203" }, .{ dialog.cancel_id, "&7205" }, .{ 17, "&7204" },
        }) |entry| {
            try d.setValue(entry[0], .of(entry[1]), 0);
            d.setFont(entry[0], if (entry[0] == 0) &self.fonts.title else if (entry[0] == 1 or entry[0] == 3) &self.fonts.row else &self.fonts.info);
        }
        try d.setValue(16, .field(&self.game_name), 0);
        try d.setValue(2, .lines(self.location_lines[0..self.locations.len], null), 0);
    }

    fn locationChanged(self: *HostGame, d: *dialog.Dialog, index: usize) !void {
        self.selected_location = index;
        const allowed = self.locations[index].modes;
        for (&self.modes, 0..) |*line, i| line[0] = if (allowed & (@as(u32, 1) << @intCast(i)) == 0) '~' else ')';
        try d.setValue(4, .lines(&self.mode_lines, null), 0);
    }
};

pub const StartOptions = struct {
    store: *settings.Store,
    fonts: *const dialog.Fonts,
    capture_mode: bool,
    end_minutes: bool = false,
    end_kills: bool = false,
    friendly_fire: bool = false,
    cheats: bool = false,
    minutes: [8]u8 = @splat(0),
    kills: [8]u8 = @splat(0),
    maximum: [8]u8 = @splat(0),
    password: [40]u8 = @splat(0),
    flags: [8]u8 = @splat(' '),

    pub fn init(store: *settings.Store, fonts: *const dialog.Fonts, capture_mode: bool) !StartOptions {
        var self: StartOptions = .{ .store = store, .fonts = fonts, .capture_mode = capture_mode };
        self.maximum[0] = '8';
        if (try store.read("", "Multiplayer", "Start Options")) |flags| {
            @memcpy(self.flags[0..@min(flags.len, 8)], flags[0..@min(flags.len, 8)]);
            self.friendly_fire = self.flags[1] == 'X';
            self.cheats = self.flags[2] == 'X';
        }
        self.end_minutes = std.mem.eql(u8, (try store.read("", "Multiplayer", "End Game After N Minutes")) orelse "N", "Y");
        self.end_kills = std.mem.eql(u8, (try store.read("", "Multiplayer", "End Game After N Kills")) orelse "N", "Y");
        for ([_]struct { []const u8, *[8]u8 }{
            .{ "Minutes To End Game", &self.minutes },
            .{ "Kills To End Game", &self.kills },
            .{ "Maximum Players", &self.maximum },
        }) |entry| if (try store.read("", "Multiplayer", entry[0])) |value| {
            @memset(entry[1], 0);
            @memcpy(entry[1][0..@min(value.len, 7)], value[0..@min(value.len, 7)]);
        };
        return self;
    }

    pub fn page(self: *StartOptions) dialog.Page {
        return .{ .context = self, .call = call };
    }

    fn call(context: *anyopaque, d: *dialog.Dialog, message: dialog.Message, id: u32, value: i32) anyerror!void {
        const self: *StartOptions = @ptrCast(@alignCast(context));
        switch (message) {
            .init => try self.open(d),
            .changed => switch (id) {
                13 => clamp(&self.kills, 100),
                15 => clamp(&self.maximum, 0xfe),
                else => {},
            },
            .activate => switch (id) {
                7 => {
                    self.end_minutes = d.valueOf(7).? == 1;
                    self.enable(d, 8, 9, self.end_minutes);
                },
                11 => {
                    self.end_kills = d.valueOf(11).? == 1;
                    self.enable(d, 12, 13, self.end_kills);
                },
                19 => {
                    self.friendly_fire = !self.friendly_fire;
                    try d.setValue(19, .of(if (self.friendly_fire) "X" else ""), 0);
                },
                3 => {
                    self.cheats = !self.cheats;
                    try d.setValue(3, .of(if (self.cheats) "X" else ""), 0);
                },
                20 => {
                    try self.persist();
                    d.running = false;
                    d.result = 1;
                },
                21, dialog.cancel_id => {
                    d.running = false;
                    d.result = 0;
                },
                else => {},
            },
            .step => try d.stepFocus(id, value),
            .close, .focus => {},
        }
    }

    fn open(self: *StartOptions, d: *dialog.Dialog) !void {
        for ([_]struct { u32, []const u8 }{
            .{ 0, "&7100" },                                      .{ 6, "&7112" },                                      .{ 8, "&7113" },
            .{ 10, if (self.capture_mode) "&7114" else "&7102" }, .{ 12, if (self.capture_mode) "&7115" else "&7111" }, .{ 18, "&7101" },
            .{ 1, "&7105" },                                      .{ 14, "&7103" },                                     .{ 16, "&7104" },
            .{ 20, "&7109" },                                     .{ 21, "&7110" },
        }) |entry| {
            try d.setValue(entry[0], .of(entry[1]), 0);
            d.setFont(entry[0], if (entry[0] == 0) &self.fonts.title else &self.fonts.info);
        }
        try d.setValue(7, .of(""), if (self.end_minutes) 1 else 2);
        try d.setValue(11, .of(""), if (self.end_kills) 1 else 2);
        try d.setValue(19, .of(if (self.friendly_fire) "X" else ""), 0);
        try d.setValue(3, .of(if (self.cheats) "X" else ""), 0);
        try d.setValue(9, .field(&self.minutes), 0);
        try d.setValue(13, .field(&self.kills), 0);
        try d.setValue(15, .field(&self.maximum), 0);
        try d.setValue(17, .field(&self.password), 0);
        self.enable(d, 8, 9, self.end_minutes);
        self.enable(d, 12, 13, self.end_kills);
    }

    fn enable(_: *StartOptions, d: *dialog.Dialog, label: u32, field: u32, enabled: bool) void {
        if (d.find(label)) |widget| widget.state = if (enabled) 1 else 0;
        if (d.find(field)) |widget| widget.state = if (enabled) 1 else 0;
    }

    fn clamp(buffer: *[8]u8, ceiling: u32) void {
        const value = std.fmt.parseInt(i32, std.mem.sliceTo(buffer, 0), 10) catch 0;
        const text = std.fmt.bufPrint(buffer, "{d}", .{@min(@as(u32, @intCast(@max(value, 0))), ceiling)}) catch unreachable;
        if (text.len < buffer.len) buffer[text.len] = 0;
    }

    fn persist(self: *StartOptions) !void {
        self.flags[1] = if (self.friendly_fire) 'X' else ' ';
        self.flags[2] = if (self.cheats) 'X' else ' ';
        try self.store.write("", "Multiplayer", "Start Options", &self.flags);
        try self.store.write("", "Multiplayer", "End Game After N Minutes", if (self.end_minutes) "Y" else "N");
        try self.store.write("", "Multiplayer", "End Game After N Kills", if (self.end_kills) "Y" else "N");
        try self.store.write("", "Multiplayer", "Kills To End Game", std.mem.sliceTo(&self.kills, 0));
        try self.store.write("", "Multiplayer", "Minutes To End Game", std.mem.sliceTo(&self.minutes, 0));
        try self.store.write("", "Multiplayer", "Maximum Players", std.mem.sliceTo(&self.maximum, 0));
    }
};

pub const JoinGame = struct {
    fonts: *const dialog.Fonts,
    sessions: []const []const u8 = &.{},
    empty_lines: [1][]const u8 = .{"&7309"},
    password: [0x80]u8 = @splat(0),
    selected: usize = 0,
    rescan: bool = false,
    get_info: bool = false,

    pub fn page(self: *JoinGame) dialog.Page {
        return .{ .context = self, .call = call };
    }

    pub fn updateSessions(self: *JoinGame, d: *dialog.Dialog, sessions: []const []const u8) !void {
        self.sessions = sessions;
        self.selected = 0;
        try d.setValue(1, .lines(if (sessions.len == 0) &self.empty_lines else sessions, null), 0);
        for ([_]u32{ 12, 14 }) |id| {
            if (d.find(id)) |widget| widget.state = if (sessions.len == 0) 2 else 1;
        }
    }

    fn call(context: *anyopaque, d: *dialog.Dialog, message: dialog.Message, id: u32, value: i32) anyerror!void {
        const self: *JoinGame = @ptrCast(@alignCast(context));
        switch (message) {
            .init => try self.open(d),
            .changed => if (id == 1 and value >= 0 and value < self.sessions.len) {
                self.selected = @intCast(value);
                try d.setValue(3, .of("&7306"), 0);
            },
            .step => try d.stepFocus(id, value),
            .activate => switch (id) {
                dialog.cancel_id => {
                    d.running = false;
                    d.result = 0;
                },
                13 => self.rescan = true,
                14 => self.get_info = true,
                12 => {
                    if (self.sessions.len == 0) return;
                    const name = self.sessions[self.selected];
                    if (name.len < 7 or !std.mem.eql(u8, name[1..7], "(1.1) ")) return error.IncompatibleNetworkVersion;
                    d.running = false;
                    d.result = 1;
                },
                else => {},
            },
            .close, .focus => {},
        }
    }

    fn open(self: *JoinGame, d: *dialog.Dialog) !void {
        for ([_]struct { u32, []const u8 }{
            .{ 0, "&7300" },                .{ 2, "&7301" },  .{ 3, "&7306" },
            .{ 4, "&7302" },                .{ 10, "&7303" }, .{ 13, "&7307" },
            .{ dialog.cancel_id, "&7205" }, .{ 14, "&7308" }, .{ 12, "&7304" },
        }) |entry| {
            try d.setValue(entry[0], .of(entry[1]), 0);
            d.setFont(entry[0], if (entry[0] == 0) &self.fonts.title else &self.fonts.info);
        }
        try d.setValue(11, .field(&self.password), 0);
        try self.updateSessions(d, self.sessions);
    }
};

pub const Setup = struct {
    store: *settings.Store,
    fonts: *const dialog.Fonts,
    messages: []const u8,
    player: [20]u8 = @splat(0),
    initialized: bool = false,

    const drivers = [_][]const u8{"LEC WinSock Driver DLL"};

    const transports = [_][]const u8{"TCP/IP (Internet/LAN)"};

    pub fn init(archive: lab.Archive, store: *settings.Store, fonts: *const dialog.Fonts) !Setup {
        return .{ .store = store, .fonts = fonts, .messages = try archive.find("LOCAL.MSG", 0) };
    }

    pub fn page(self: *Setup) dialog.Page {
        return .{ .context = self, .call = call };
    }

    fn call(context: *anyopaque, d: *dialog.Dialog, message: dialog.Message, id: u32, value: i32) anyerror!void {
        const self: *Setup = @ptrCast(@alignCast(context));
        switch (message) {
            .init => try self.open(d),
            .changed => if (self.initialized and id == 6) try driverChanged(d, value),
            .step => try d.stepFocus(id, value),
            .activate => try self.activate(d, id),
            .close, .focus => {},
        }
    }

    fn open(self: *Setup, d: *dialog.Dialog) !void {
        const fallback = try messages.lookup(self.messages, 7008);
        const name = (try self.store.read("", "Multiplayer", "Network Name")) orelse fallback;
        const length = @min(name.len, 13);
        @memcpy(self.player[0..length], name[0..length]);
        self.player[length] = 0;
        try d.setValue(0, .of("&7000"), 0);
        d.setFont(0, &self.fonts.title);
        try d.setValue(1, .of("&7001"), 0);
        d.setFont(1, &self.fonts.row);
        try d.setValue(2, .field(self.player[0..14]), 0);
        try d.setValue(5, .of("&7002"), 0);
        d.setFont(5, &self.fonts.row);
        try d.setValue(6, .lines(&drivers, null), 0);
        try d.setValue(8, .of("&7004"), 0);
        d.setFont(8, &self.fonts.row);
        try d.setValue(9, .lines(&transports, null), 0);
        for ([_]struct { u32, []const u8 }{
            .{ dialog.cancel_id, "&7005" }, .{ 7, "&7003" },
            .{ 10, "&7007" },               .{ 11, "&7006" },
        }) |entry| {
            try d.setValue(entry[0], .of(entry[1]), 0);
            d.setFont(entry[0], &self.fonts.info);
        }
        self.initialized = true;
        try driverChanged(d, 0);
    }

    fn driverChanged(d: *dialog.Dialog, selected: i32) !void {
        if (selected != 0) return error.UnsupportedNetworkDriver;
        try d.setValue(9, .lines(&transports, null), 0);
    }

    fn activate(self: *Setup, d: *dialog.Dialog, id: u32) !void {
        switch (id) {
            dialog.cancel_id => {
                d.running = false;
                d.result = @intFromEnum(Choice.cancel);
            },
            7 => return error.NetworkDriverConfigurationNotPorted,
            10, 11 => {
                const name = std.mem.sliceTo(&self.player, 0);
                try self.store.write("", "Multiplayer", "Network Name", if (name.len == 0) try messages.lookup(self.messages, 7008) else name);
                try self.store.write(null, null, "Network Driver", network_driver.settings_name);
                d.running = false;
                d.result = if (id == 10) @intFromEnum(Choice.host) else @intFromEnum(Choice.join);
            },
            else => {},
        }
    }
};

fn box(top: i32, left: i32, height: i32, width: i32) Box {
    return .{ .top = top, .left = left, .height = height, .width = width };
}

test "1.1.1 multiplayer setup opens with the reference assets and returns Host" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var store = settings.Store.init(a);
    defer store.deinit();
    try store.write("", "Multiplayer", "Network Name", "Jessie");
    var page = try Setup.init(archive, &store, &fonts);
    var shared = dialog.Shared{};
    var palette: [256]u32 = @splat(0);
    var screen: dialog.Dialog = undefined;
    try screen.open(a, archive, &shared, null, page.page(), &records, &fonts, &cursor, "mcd216.PCX", null, &palette, .{});
    defer _ = screen.close() catch {};
    try std.testing.expectEqualStrings("Jessie", screen.find(2).?.data.field.text());
    try std.testing.expectEqualStrings("LEC WinSock Driver DLL", screen.find(6).?.data.list.items[0]);
    const pixels = try a.alloc(u8, dialog.width * dialog.height);
    defer a.free(pixels);
    _ = try screen.render(pixels, &palette);
    _ = try screen.takeFocus(screen.find(10).?);
    screen.keys.push(0x1c);
    try screen.frame(.{}, 100, &palette);
    try std.testing.expect(!screen.running);
    try std.testing.expectEqual(@as(i32, 0), screen.result);
    try std.testing.expectEqualStrings("Jessie", (try store.read("", "Multiplayer", "Network Name")).?);
    try std.testing.expectEqualStrings(network_driver.settings_name, (try store.read(null, null, "Network Driver")).?);
}

test "1.1.1 host selection and nested options use the reference dialog assets" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var store = settings.Store.init(a);
    defer store.deinit();
    try store.write("", "Multiplayer", "Default Game", "Test Game");
    const locations = [_]Location{.{ .basename = "DRYGULCH", .name = "Dry Gulch", .modes = 0x35 }};
    var host = try HostGame.init(&store, &fonts, &locations);
    var shared = dialog.Shared{};
    var palette: [256]u32 = @splat(0);
    var screen: dialog.Dialog = undefined;
    try screen.open(a, archive, &shared, null, host.page(), &host_records, &fonts, &cursor, "SMD216.PCX", null, &palette, .{});
    defer _ = screen.close() catch {};
    const pixels = try a.alloc(u8, dialog.width * dialog.height);
    defer a.free(pixels);
    _ = try screen.render(pixels, &palette);
    try std.testing.expectEqualStrings("Test Game", screen.find(16).?.data.field.text());
    try std.testing.expectEqualStrings(")C.T.F.", screen.find(4).?.data.list.items[0]);
    try std.testing.expectEqualStrings("~Tag", screen.find(4).?.data.list.items[1]);
    _ = try screen.takeFocus(screen.find(17).?);
    screen.keys.push(0x1c);
    try screen.frame(.{}, 100, &palette);
    try std.testing.expect(host.open_options);
    var options = try StartOptions.init(&store, &fonts, true);
    var child: dialog.Dialog = undefined;
    try child.open(a, archive, &shared, &screen, options.page(), &options_records, &fonts, &cursor, "MOD216.PCX", null, &palette, .{});
    _ = try child.render(pixels, &palette);
    _ = try child.takeFocus(child.find(20).?);
    child.keys.push(0x1c);
    try child.frame(.{}, 200, &palette);
    try std.testing.expectEqual(@as(i32, 1), try child.close());
    try host.accept(&screen);
    try std.testing.expectEqual(@as(u32, 1), host.selected_mode);
    try std.testing.expectEqualStrings("Test Game", (try store.read("", "Multiplayer", "Default Game")).?);
}

test "1.1.1 join dialog accepts a versioned session" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var page = JoinGame{ .fonts = &fonts, .sessions = &.{" (1.1) Test Game"} };
    var shared = dialog.Shared{};
    var palette: [256]u32 = @splat(0);
    var screen: dialog.Dialog = undefined;
    try screen.open(a, archive, &shared, null, page.page(), &join_records, &fonts, &cursor, "JMD216.PCX", null, &palette, .{});
    defer _ = screen.close() catch {};
    const pixels = try a.alloc(u8, dialog.width * dialog.height);
    defer a.free(pixels);
    _ = try screen.render(pixels, &palette);
    try std.testing.expectEqualStrings(" (1.1) Test Game", screen.find(1).?.data.list.items[0]);
    _ = try screen.takeFocus(screen.find(12).?);
    screen.keys.push(0x1c);
    try screen.frame(.{}, 100, &palette);
    try std.testing.expectEqual(@as(i32, 1), screen.result);
}
