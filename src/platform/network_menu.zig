//! The host side of the network setup pages: the blocking dialog loops, and
//! the values the accepted pages leave for the game to start from.
//!
//! An empty game name keeps the default name, and the team flag is set by
//! the mode page. The player name is shared with the setup dialog's field.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const dialog = @import("../ui/dialog.zig");
const network_menu = @import("../ui/network_menu.zig");
const settings = @import("../settings.zig");
const settings_file = @import("settings.zig");
const rcp = @import("../assets/rcp.zig");
const enet_driver = @import("enet_driver.zig");
const sdl = @import("sdl.zig");
const Runtime = @import("../audio/runtime.zig").Runtime;
const Device = @import("audio.zig").Device;
const c = sdl.c;
const campaign = @import("../campaign.zig");

pub const Result = union(enum) { choice: network_menu.Choice, quit, frame_limit };

pub const HostResult = union(enum) { selected: HostSelection, cancel, quit, frame_limit };

pub const JoinResult = union(enum) { selected: JoinSelection, cancel, quit, frame_limit };

pub const JoinSelection = struct {
    name: [49]u8,
    host: [64]u8,
    password: [0x80]u8,
};

pub const HostSelection = struct {
    basename: [24]u8 = @splat(0),
    game_name: [14]u8 = @splat(0),
    location: [0x200]u8 = @splat(0),
    mode: u32,
    password: [40]u8,
    maximum_players: u8,
    end_minutes: i32,
    end_kills: i32,
    friendly_fire: bool,
    cheats: bool,
    options: [7]bool,
};

const DriveResult = enum { done, quit, frame_limit };

pub fn hostChoice(selection: *const HostSelection) !campaign.HostChoice {
    if (selection.mode == 0 or selection.mode > network_menu.HostGame.mode_names.len) return error.InvalidMultiplayerMode;
    const game_name = std.mem.sliceTo(&selection.game_name, 0);
    return .{
        .basename = std.mem.sliceTo(&selection.basename, 0),
        .location = std.mem.sliceTo(&selection.location, 0),
        .mode = selection.mode,
        .mode_name = network_menu.HostGame.mode_names[selection.mode - 1],
        .game_name = if (game_name.len == 0) "Outlaws" else game_name,
        .password = std.mem.sliceTo(&selection.password, 0),
        .player_limit = selection.maximum_players,
        .kill_limit = selection.end_kills,
        .minute_limit = selection.end_minutes,
        .options = selection.options,
        .team = 1,
    };
}

pub fn bindPlayer(startup: *campaign.Startup, store: *settings.Store, archive: lab.Archive) !void {
    const messages = try archive.find("LOCAL.MSG", 0);
    startup.bindRouterParts(messages);
    const name = (try store.read("", "Multiplayer", "Network Name")) orelse "Player";
    const length = @min(name.len, startup.router.player_name.len - 1);
    @memset(&startup.router.player_name, 0);
    @memcpy(startup.router.player_name[0..length], name[0..length]);
    const character = std.mem.trimStart(u8, (try store.read("", "Multiplayer", "Character")) orelse "2", " \t");
    var value: u32 = 0;
    for (character) |digit| {
        if (digit < '0' or digit > '9') break;
        value = value *% 10 +% (digit - '0');
    }
    startup.costume = value;
}

pub fn run(
    a: std.mem.Allocator,
    io: std.Io,
    archive: lab.Archive,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    store: *settings.Store,
    audio: *Runtime,
    device: *Device,
    frames: *usize,
    frame_limit: ?usize,
) !Result {
    _ = c.SDL_ShowCursor(c.SDL_DISABLE);
    defer _ = c.SDL_ShowCursor(c.SDL_ENABLE);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var shared = dialog.Shared{};
    var setup = try network_menu.Setup.init(archive, store, &fonts);
    var screen: dialog.Dialog = undefined;
    try screen.open(a, archive, &shared, null, setup.page(), &network_menu.records, &fonts, &cursor, "mcd216.PCX", null, palette, mouseState());
    var open = true;
    defer if (open) {
        _ = screen.close() catch {};
    };
    var played: u32 = 0;
    switch (try drive(a, io, &screen, window, pixels, palette, store, audio, device, frames, frame_limit, &played, null, null)) {
        .quit => return .quit,
        .frame_limit => return .frame_limit,
        .done => {},
    }
    open = false;
    const raw = try screen.close();
    try settings_file.save(a, io, store);
    while (mouseState().buttons != 0) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) if (event.type == c.SDL_QUIT) return .quit;
        c.SDL_Delay(16);
    }
    return .{ .choice = switch (raw) {
        -1 => .cancel,
        0 => .host,
        1 => .join,
        else => return error.InvalidNetworkMenuResult,
    } };
}

pub fn runHost(
    a: std.mem.Allocator,
    io: std.Io,
    archive: lab.Archive,
    data_path: []const u8,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    store: *settings.Store,
    audio: *Runtime,
    device: *Device,
    frames: *usize,
    frame_limit: ?usize,
) !HostResult {
    const found = try locations(a, io, data_path);
    defer freeLocations(a, found);
    if (found.len == 0) return error.NoMultiplayerLocations;
    _ = c.SDL_ShowCursor(c.SDL_DISABLE);
    defer _ = c.SDL_ShowCursor(c.SDL_ENABLE);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var shared = dialog.Shared{};
    var page = try network_menu.HostGame.init(store, &fonts, found);
    var screen: dialog.Dialog = undefined;
    try screen.open(a, archive, &shared, null, page.page(), &network_menu.host_records, &fonts, &cursor, "SMD216.PCX", null, palette, mouseState());
    var open = true;
    defer if (open) {
        _ = screen.close() catch {};
    };
    var played: u32 = 0;
    while (screen.running) {
        switch (try drive(a, io, &screen, window, pixels, palette, store, audio, device, frames, frame_limit, &played, &page.open_options, null)) {
            .quit => return .quit,
            .frame_limit => return .frame_limit,
            .done => {},
        }
        if (!page.open_options) break;
        page.open_options = false;
        var options = try network_menu.StartOptions.init(store, &fonts, screen.valueOf(4).? == 0);
        var child: dialog.Dialog = undefined;
        try child.open(a, archive, &shared, &screen, options.page(), &network_menu.options_records, &fonts, &cursor, "MOD216.PCX", null, palette, mouseState());
        var child_open = true;
        defer if (child_open) {
            _ = child.close() catch {};
        };
        switch (try drive(a, io, &child, window, pixels, palette, store, audio, device, frames, frame_limit, &played, null, null)) {
            .quit => return .quit,
            .frame_limit => return .frame_limit,
            .done => {},
        }
        const accepted = try child.close();
        child_open = false;
        screen.reload();
        if (accepted == 1) {
            try page.accept(&screen);
            var selected = HostSelection{
                .mode = page.selected_mode,
                .password = options.password,
                .maximum_players = @intCast(@min(@as(u32, @intCast(@max(std.fmt.parseInt(i32, std.mem.sliceTo(&options.maximum, 0), 10) catch 0, 0))), 0xfe)),
                .end_minutes = if (options.end_minutes) std.fmt.parseInt(i32, std.mem.sliceTo(&options.minutes, 0), 10) catch 0 else 0,
                .end_kills = if (options.end_kills) std.fmt.parseInt(i32, std.mem.sliceTo(&options.kills, 0), 10) catch 0 else 0,
                .friendly_fire = options.friendly_fire,
                .cheats = options.cheats,
                .options = undefined,
            };
            for (&selected.options, options.flags[0..7]) |*option, mark| option.* = mark == 'X';
            const base = found[page.selected_location].basename;
            if (base.len >= selected.basename.len) return error.MultiplayerLocationNameTooLong;
            @memcpy(selected.basename[0..base.len], base);
            const line = found[page.selected_location].name;
            if (line.len >= selected.location.len) return error.MultiplayerLocationNameTooLong;
            @memcpy(selected.location[0..line.len], line);
            selected.game_name = page.game_name;
            open = false;
            _ = try screen.close();
            return .{ .selected = selected };
        }
    }
    open = false;
    _ = try screen.close();
    return .cancel;
}

pub fn runJoin(
    a: std.mem.Allocator,
    io: std.Io,
    archive: lab.Archive,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    store: *settings.Store,
    audio: *Runtime,
    device: *Device,
    frames: *usize,
    frame_limit: ?usize,
) !JoinResult {
    _ = c.SDL_ShowCursor(c.SDL_DISABLE);
    defer _ = c.SDL_ShowCursor(c.SDL_ENABLE);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var shared = dialog.Shared{};
    var sessions = try enet_driver.listSessions(a, @import("../network/driver.zig").port, 1000);
    defer a.free(sessions);
    var names = try a.alloc([]const u8, sessions.len);
    defer a.free(names);
    for (sessions, names) |*session, *name| name.* = session.sessionName();
    var page = network_menu.JoinGame{ .fonts = &fonts, .sessions = names };
    var screen: dialog.Dialog = undefined;
    try screen.open(a, archive, &shared, null, page.page(), &network_menu.join_records, &fonts, &cursor, "JMD216.PCX", null, palette, mouseState());
    var open = true;
    defer if (open) {
        _ = screen.close() catch {};
    };
    var played: u32 = 0;
    while (screen.running) {
        switch (try drive(a, io, &screen, window, pixels, palette, store, audio, device, frames, frame_limit, &played, &page.rescan, &page.get_info)) {
            .quit => return .quit,
            .frame_limit => return .frame_limit,
            .done => {},
        }
        if (page.rescan) {
            page.rescan = false;
            const fresh = try enet_driver.listSessions(a, @import("../network/driver.zig").port, 1000);
            errdefer a.free(fresh);
            const fresh_names = try a.alloc([]const u8, fresh.len);
            errdefer a.free(fresh_names);
            for (fresh, fresh_names) |*session, *name| name.* = session.sessionName();
            try page.updateSessions(&screen, fresh_names);
            a.free(names);
            a.free(sessions);
            sessions = fresh;
            names = fresh_names;
            continue;
        }
        if (page.get_info) return error.NetworkSessionDescriptionNotPorted;
        if (!screen.running) break;
    }
    const selected = if (screen.result == 1) JoinSelection{
        .name = sessions[page.selected].name,
        .host = sessions[page.selected].host,
        .password = page.password,
    } else null;
    open = false;
    _ = try screen.close();
    return if (selected) |value| .{ .selected = value } else .cancel;
}

fn locations(a: std.mem.Allocator, io: std.Io, data_path: []const u8) ![]network_menu.Location {
    const directory = std.fs.path.dirname(data_path) orelse ".";
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var found: std.ArrayList(network_menu.Location) = .empty;
    errdefer {
        for (found.items) |location| {
            a.free(location.basename);
            a.free(location.name);
        }
        found.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (file.kind != .file or !std.ascii.endsWithIgnoreCase(file.name, ".RCM")) continue;
        if (found.items.len == 100) break;
        const bytes = try dir.readFileAlloc(io, file.name, a, .limited(64 * 1024));
        defer a.free(bytes);
        const recipe = try rcp.Recipe.parse(a, bytes);
        defer recipe.deinit(a);
        const base = file.name[0 .. file.name.len - 4];
        const basename = try a.dupe(u8, base);
        errdefer a.free(basename);
        const display = try a.dupe(u8, if (recipe.name.len == 0) base else recipe.name);
        errdefer a.free(display);
        try found.append(a, .{ .basename = basename, .name = display, .modes = recipe.modes });
    }
    std.mem.sort(network_menu.Location, found.items, {}, struct {
        fn less(_: void, l: network_menu.Location, r: network_menu.Location) bool {
            return std.ascii.lessThanIgnoreCase(l.basename, r.basename);
        }
    }.less);
    return found.toOwnedSlice(a);
}

fn freeLocations(a: std.mem.Allocator, found: []const network_menu.Location) void {
    for (found) |location| {
        a.free(location.basename);
        a.free(location.name);
    }
    a.free(found);
}

fn drive(a: std.mem.Allocator, io: std.Io, screen: *dialog.Dialog, window: sdl.Window, pixels: []u8, palette: *[256]u32, store: *settings.Store, audio: *Runtime, device: *Device, frames: *usize, limit: ?usize, played: *u32, interrupt: ?*bool, interrupt_info: ?*bool) !DriveResult {
    var left_pressed = false;
    while (screen.running and (interrupt == null or !interrupt.?.*) and (interrupt_info == null or !interrupt_info.?.*)) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) return .quit;
            if (event.type == c.SDL_MOUSEBUTTONDOWN and event.button.button == c.SDL_BUTTON_LEFT) left_pressed = true;
            if (event.type == c.SDL_KEYDOWN) if (sdl.gameScanCode(event.key.keysym.scancode)) |scan| screen.keys.push(scan);
        }
        var input = mouseState();
        if (left_pressed) input.buttons |= 1;
        left_pressed = false;
        input.shift = c.SDL_GetModState() & c.KMOD_SHIFT != 0;
        try screen.frame(input, c.SDL_GetTicks(), palette);
        if (try screen.render(pixels, palette)) try window.present(palette);
        for (played.*..screen.shared.sounds) |_|
            _ = try audio.play(.{ .basename = "RIFLOUT.WAV", .priority = 64, .volume = 127, .flags = 4 }, null, c.SDL_GetTicks());
        played.* = screen.shared.sounds;
        try device.sync(audio);
        screen.reload();
        try settings_file.save(a, io, store);
        frames.* += 1;
        if (limit) |maximum| if (frames.* >= maximum) return .frame_limit;
        c.SDL_Delay(16);
    }
    return .done;
}

fn mouseState() dialog.Input {
    var input = dialog.Input{};
    input.buttons = c.SDL_GetMouseState(&input.x, &input.y);
    return input;
}
