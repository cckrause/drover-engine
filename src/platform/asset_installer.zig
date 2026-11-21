//! Startup glue for the asset installer. The installing and its window live
//! in the standalone modules/asset_installer; the engine only receives an
//! ordinary archive path back.
//!
//! The game's SDL window is reused: the installer adds a native view to it
//! and removes that view before returning.

const std = @import("std");
const title = @import("../game/title.zig");
const builtin = @import("builtin");
const installer = @import("asset_installer");
const sdl = @import("sdl.zig");

const native = if (builtin.os.tag == .macos) @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL.h");
    @cInclude("SDL_syswm.h");
}) else struct {};

pub const Selection = struct { path: []u8, kind: installer.Kind };

pub fn bundledPath(a: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (builtin.os.tag != .macos) return null;
    const executable = try std.process.executableDirPathAlloc(io, a);
    defer a.free(executable);
    const path = try title.current.bundledDataPath(a, executable);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            a.free(path);
            return null;
        },
        else => {
            a.free(path);
            return err;
        },
    };
    return path;
}

pub fn run(init: std.process.Init, window: *sdl.Window) !?Selection {
    return if (builtin.os.tag == .macos) runMac(init, window) else error.AssetInstallerRequiresMacOS;
}

fn pump(_: *anyopaque) bool {
    var event: sdl.c.SDL_Event = undefined;
    while (sdl.c.SDL_PollEvent(&event) != 0) {
        if (event.type == sdl.c.SDL_QUIT) return false;
        if (event.type == sdl.c.SDL_DROPFILE) sdl.c.SDL_free(event.drop.file);
    }
    sdl.c.SDL_Delay(8);
    return true;
}

fn runMac(init: std.process.Init, window: *sdl.Window) !?Selection {
    const home = init.environ_map.get("HOME") orelse return error.MissingHomeDirectory;
    const root = try std.fs.path.join(init.gpa, &.{ home, "Library/Application Support/o-reverse/Outlaws/assets" });
    defer init.gpa.free(root);
    var store = try installer.Store.init(init.gpa, init.io, root);
    defer store.deinit();
    const kind = if (try store.installed(.retail)) installer.Kind.retail else blk: {
        var info: native.SDL_SysWMinfo = undefined;
        native.SDL_GetVersion(&info.version);
        if (native.SDL_GetWindowWMInfo(@ptrCast(window.handle), &info) == 0 or info.subsystem != native.SDL_SYSWM_COCOA) return error.NativeWindowUnavailable;
        break :blk (try installer.macos.run(init.gpa, &store, .{ .window = @ptrCast(info.info.cocoa.window.?), .context = window, .pump = pump })) orelse return null;
    };
    return .{ .path = try store.dataPath(kind), .kind = kind };
}
