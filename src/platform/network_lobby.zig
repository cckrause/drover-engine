//! A loaded network level before play starts: the stand-in player, the
//! lobby inside level frames, then the start request and the wait until the
//! player is placed.
//!
//! Host and joiner both come through here. The host runs the level frame
//! without the stand-in's own logic while the lobby is up, and quitting from
//! the lobby fades out and returns to the menu.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const campaign = @import("../campaign.zig");
const dialog = @import("../ui/dialog.zig");
const network_lobby = @import("../ui/network_lobby.zig");
const player_input = @import("../player/input.zig");
const sdl = @import("sdl.zig");
const Session = @import("../render/session.zig").Session;
const Runtime = @import("../audio/runtime.zig").Runtime;
const Device = @import("audio.zig").Device;
const c = sdl.c;

pub const Result = enum { playing, quit, frame_limit };

pub fn run(
    a: std.mem.Allocator,
    archive: lab.Archive,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    audio: *Runtime,
    device: *Device,
    frames: *usize,
    frame_limit: ?usize,
    input: *sdl.PlayerInput,
    session: *Session,
    startup: *campaign.Startup,
) !Result {
    var last = input.last_sample;
    defer input.last_sample = last;
    try session.bindStandIn(session.animation_time);
    try startup.enterLobby();
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var shared = dialog.Shared{};
    var page = network_lobby.Lobby{ .fonts = &fonts, .mode = startup.mode };
    var screen: dialog.Dialog = undefined;
    _ = c.SDL_ShowCursor(c.SDL_DISABLE);
    defer _ = c.SDL_ShowCursor(c.SDL_ENABLE);
    try screen.open(a, archive, &shared, null, page.page(), &network_lobby.records, &fonts, &cursor, try network_lobby.picture(startup.mode), null, palette, mouseState());
    var open = true;
    defer if (open) {
        session.lobby = null;
        _ = screen.close() catch {};
    };
    try network_lobby.showCharacter(&screen, startup.messages, startup.costume);
    session.lobby = &screen;
    const empty: player_input.Packet = .{};
    var played: u32 = 0;
    var left_pressed = false;
    const result = while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) return .quit;
            if (event.type == c.SDL_MOUSEBUTTONDOWN and event.button.button == c.SDL_BUTTON_LEFT) left_pressed = true;
            if (event.type == c.SDL_KEYDOWN) if (sdl.gameScanCode(event.key.keysym.scancode)) |scan| screen.keys.push(scan);
        }
        const now = c.SDL_GetTicks();
        try session.advanceWithAudio(a, &empty, now -% last, audio);
        last = now;
        try playEffects(session, audio);
        try network_lobby.refreshPlayers(a, &screen, session.router, session.database.player_order[0..session.database.player_count], startup.mode, startup.engine.game_type);
        var mouse = mouseState();
        if (left_pressed) mouse.buttons |= 1;
        left_pressed = false;
        mouse.shift = c.SDL_GetModState() & c.KMOD_SHIFT != 0;
        try screen.frame(mouse, now, palette);
        if (page.character_requested) return error.CharacterSelectNotPorted;
        if (try screen.render(pixels, palette)) {
            try window.present(palette);
            frames.* += 1;
            if (frame_limit) |limit| if (frames.* >= limit) return .frame_limit;
        }
        for (played..screen.shared.sounds) |_|
            _ = try audio.play(.{ .basename = "RIFLOUT.WAV", .priority = 64, .volume = 127, .flags = 4 }, null, now);
        played = screen.shared.sounds;
        try device.sync(audio);
        screen.reload();
        if (!screen.running) {
            open = false;
            session.lobby = null;
            break try screen.close();
        }
        c.SDL_Delay(16);
    };
    if (result == 0) return error.LobbyQuitNotPorted;
    try session.removeStandIn(session.animation_time);
    try startup.leaveLobby(result);
    input.last_sample = last;
    const started = try waitForStart(a, audio, device, input, session, startup);
    last = input.last_sample;
    return started;
}

pub fn waitForStart(a: std.mem.Allocator, audio: *Runtime, device: *Device, input: *sdl.PlayerInput, session: *Session, startup: *campaign.Startup) !Result {
    var last = input.last_sample;
    defer input.last_sample = last;
    if (session.server_enabled) session.seedStartRequest(c.SDL_GetTicks());
    while (!(startup.engine.game_state == 1 and startup.engine.scenario == 2)) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) if (event.type == c.SDL_QUIT) return .quit;
        const now = c.SDL_GetTicks();
        try session.networkPass(a, now -% last, audio);
        last = now;
        try playEffects(session, audio);
        if (startup.engine.game_state == 1) break;
        try startup.startStep(session.animation_time);
        try device.sync(audio);
        c.SDL_Delay(16);
    }
    session.start_keys_cleared = false;
    input.clearLevelKeys();
    return .playing;
}

fn playEffects(session: *Session, audio: *Runtime) !void {
    for (session.pickup_effects.items) |effect| switch (effect) {
        .sound => |request| {
            if (!request.delivered) _ = try audio.play(request, session.audioWorld(), c.SDL_GetTicks());
        },
        else => {},
    };
}

fn mouseState() dialog.Input {
    var input = dialog.Input{};
    input.buttons = c.SDL_GetMouseState(&input.x, &input.y);
    return input;
}
