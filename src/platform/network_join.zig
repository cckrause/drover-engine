//! Joining a game from the menu, up to the point where the level is loaded:
//! the window's messages, the clock, the sound sync and the screen the
//! loading display draws on.
//!
//! The game-side work belongs to campaign.Startup and the loading display.
//! If the driver cannot open the session, or the connect is refused, this
//! returns to the menu.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const loading_display = @import("../ui/loading_display.zig");
const enet_driver = @import("enet_driver.zig");
const mission = @import("mission.zig");
const sdl = @import("sdl.zig");
const Session = @import("../render/session.zig").Session;
const world = @import("../render/backends/software/world.zig");
const Runtime = @import("../audio/runtime.zig").Runtime;
const Device = @import("audio.zig").Device;
const c = sdl.c;

pub const Result = union(enum) {
    level: *Session,
    menu,
    quit,
    frame_limit,
};

const Window = struct {
    window: sdl.Window,
    audio: *Runtime,
    device: *Device,
    frames: *usize,
    frame_limit: ?usize,
    clock_offset: u32,
    keys: campaign.KeyQueue = .{},
    quit: bool = false,

    fn of(context: *anyopaque) *Window {
        return @ptrCast(@alignCast(context));
    }

    fn pump(context: *anyopaque) anyerror!void {
        const self = of(context);
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) self.quit = true;
            if (event.type == c.SDL_KEYDOWN and event.key.repeat == 0)
                if (sdl.gameScanCode(event.key.keysym.scancode)) |scan| self.keys.push(scan);
        }
        if (self.quit) return error.WindowClosed;
    }

    fn sound(context: *anyopaque) anyerror!void {
        const self = of(context);
        try self.device.sync(self.audio);
    }

    fn clock(context: *anyopaque) u32 {
        const self = of(context);
        return c.SDL_GetTicks() -% self.clock_offset;
    }

    fn present(context: *anyopaque, _: []const u8, palette: *const [256]u32) anyerror!void {
        const self = of(context);
        try self.window.present(palette);
        self.frames.* += 1;
        if (self.frame_limit) |limit| if (self.frames.* >= limit) return error.FrameLimit;
    }
};

pub fn run(
    a: std.mem.Allocator,
    render_workspace: *world.Workspace,
    io: std.Io,
    archive: lab.Archive,
    data_path: []const u8,
    mounts: *mission.Mounts,
    window: sdl.Window,
    pixels: []u8,
    palette: *[256]u32,
    audio: *Runtime,
    device: *Device,
    frames: *usize,
    frame_limit: ?usize,
    startup: *campaign.Startup,
    opener: *enet_driver.Opener,
    session_name: []const u8,
    clock_offset: u32,
    persistent: Session.PersistentState,
) !Result {
    var host = Window{ .window = window, .audio = audio, .device = device, .frames = frames, .frame_limit = frame_limit, .clock_offset = clock_offset };
    startup.frame_host = .{
        .context = &host,
        .pump = Window.pump,
        .sound = Window.sound,
        .clock = Window.clock,
        .screen = .{ .pixels = pixels, .palette = palette, .context = &host, .present = Window.present },
        .archive = archive,
    };
    defer startup.frame_host = null;
    return joinGame(a, render_workspace, io, archive, data_path, mounts, audio, startup, opener, session_name, &host, persistent) catch |err| switch (err) {
        error.WindowClosed => .quit,
        error.FrameLimit => .frame_limit,
        else => err,
    };
}

fn joinGame(a: std.mem.Allocator, render_workspace: *world.Workspace, io: std.Io, archive: lab.Archive, data_path: []const u8, mounts: *mission.Mounts, audio: *Runtime, startup: *campaign.Startup, opener: *enet_driver.Opener, session_name: []const u8, host: *Window, persistent: Session.PersistentState) !Result {
    startup.router.now = Window.clock(host);
    const opened = startup.beginJoin(opener.provider(), session_name) catch |err| switch (err) {
        error.CannotOpen, error.UnknownHost, error.NoAnswer, error.Refused => {
            std.log.err("network: cannot join the game ({s})", .{@errorName(err)});
            return .menu;
        },
        else => return err,
    };
    if (!opened) return .menu;
    const end = while (true) {
        if (try startup.stepJoin(&host.keys)) |found| break found;
        c.SDL_Delay(1);
    };
    switch (end) {
        .joined => {},
        .failed => |failure| {
            if (failure.shown) |text| std.log.err("network: the join failed: {s}", .{std.mem.sliceTo(&text, 0)});
            std.log.err("network: the failed join's popup and the way back to the menu are not implemented", .{});
            return error.JoinFailurePopupNotPorted;
        },
    }
    while (try startup.joinPass(a, io, data_path, archive, &host.keys) != .story) c.SDL_Delay(1);
    return openLevel(a, render_workspace, io, mounts, audio, startup, host, persistent);
}

fn openLevel(a: std.mem.Allocator, render_workspace: *world.Workspace, io: std.Io, mounts: *mission.Mounts, audio: *Runtime, startup: *campaign.Startup, host: *Window, persistent: Session.PersistentState) !Result {
    audio.stopAll();
    try host.device.sync(audio);
    const level_entry = startup.currentEvent() orelse return error.CampaignHasNoLevel;
    if (level_entry.kind != .level) return error.UnsupportedNetworkStoryEvent;
    try mounts.selectDisc(io, level_entry.disc);
    try audio.remount(io, mounts.path(), mounts.system());
    try startup.beginJoinedLevel();
    const session = try Session.openWithState(a, render_workspace, io, mounts.path(), mounts.system(), startup, Window.clock(host), persistent);
    errdefer session.deinit(a);
    try startup.endJoinedLevel();
    return .{ .level = session };
}
