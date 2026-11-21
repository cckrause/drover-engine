//! The menu shell: which screen is open, what was selected on it, and what
//! the host should do next.
//!
//! It owns the campaign once a difficulty is confirmed, and the flags the
//! host polls for load, options and multiplayer. A screen keeps its own
//! selection, so leaving and re-entering a menu lands on the previous item.
//! Cancelling a submenu re-opens the menu above it, which resets its palette
//! and input state. A campaign with no story is an error, not a default.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const menu = @import("menu.zig");
const campaign = @import("../campaign.zig");

pub const MouseState = struct { x: i32 = 0, y: i32 = 0, buttons: u32 = 0 };

pub const Shell = struct {
    screen: menu.Menu,
    startup: ?campaign.Startup = null,
    main_selection: i32 = 0,
    difficulty_selection: i32 = 0,
    load_requested: bool = false,
    options_requested: bool = false,
    multiplayer_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator, archive: lab.Archive) !Shell {
        return .{ .screen = try menu.Menu.init(allocator, archive) };
    }

    pub fn deinit(self: *Shell, allocator: std.mem.Allocator) void {
        if (self.startup) |*startup| startup.deinit(allocator);
        self.screen.deinit(allocator);
    }

    pub fn endGame(self: *Shell, allocator: std.mem.Allocator, archive: lab.Archive, now: u32, mouse: MouseState) !void {
        try self.open(allocator, archive, .main, self.main_selection, now, mouse);
        if (self.startup) |*startup| {
            startup.router.close();
            startup.router.network.unload();
            startup.deinit(allocator);
        }
        self.startup = null;
    }

    pub fn accept(self: *Shell, allocator: std.mem.Allocator, archive: lab.Archive, result: i32, now: u32, mouse: MouseState) !void {
        if (self.startup != null) return error.CampaignAlreadyPrepared;
        switch (self.screen.kind) {
            .main => {
                self.main_selection = self.screen.selected;
                if (result == -1) {
                    try self.open(allocator, archive, .main, self.main_selection, now, mouse);
                    return;
                }
                if (result == 3) {
                    self.load_requested = true;
                    return;
                }
                if (result == 4) {
                    self.options_requested = true;
                    return;
                }
                if (result == 1) {
                    self.multiplayer_requested = true;
                    return;
                }
                if (result != 0) return error.MenuActionNotImplemented;
                try self.open(allocator, archive, .difficulty, self.difficulty_selection, now, mouse);
            },
            .difficulty => {
                self.difficulty_selection = self.screen.selected;
                if (result == -1 or result == 3) {
                    try self.open(allocator, archive, .main, self.main_selection, now, mouse);
                    return;
                }
                const difficulty = try campaign.Difficulty.fromSelection(result);
                self.startup = campaign.Startup.prepare(allocator, archive, difficulty) catch |err| switch (err) {
                    error.NoStoryCampaign => {
                        try self.open(allocator, archive, .difficulty, self.difficulty_selection, now, mouse);
                        return;
                    },
                    else => return err,
                };
            },
        }
    }

    pub fn returnFromOptions(self: *Shell, allocator: std.mem.Allocator, archive: lab.Archive, now: u32, mouse: MouseState) !void {
        self.options_requested = false;
        try self.open(allocator, archive, .main, self.main_selection, now, mouse);
    }

    pub fn returnFromLoad(self: *Shell, allocator: std.mem.Allocator, archive: lab.Archive, now: u32, mouse: MouseState) !void {
        self.load_requested = false;
        try self.open(allocator, archive, .main, self.main_selection, now, mouse);
    }

    pub fn returnFromMultiplayer(self: *Shell, allocator: std.mem.Allocator, archive: lab.Archive, now: u32, mouse: MouseState) !void {
        self.multiplayer_requested = false;
        try self.open(allocator, archive, .main, self.main_selection, now, mouse);
    }

    fn open(self: *Shell, allocator: std.mem.Allocator, archive: lab.Archive, kind: menu.Kind, selected: i32, now: u32, mouse: MouseState) !void {
        var next = try menu.Menu.initKind(allocator, archive, kind);
        next.selected = selected;
        next.selected_at = if (selected == -1) 0 else now;
        next.mouse_x = std.math.clamp(mouse.x, 0, menu.width - 1);
        next.mouse_y = std.math.clamp(mouse.y, 0, menu.height - 1);
        next.mouse_buttons = mouse.buttons;
        self.screen.deinit(allocator);
        self.screen = next;
    }
};

test "CD1 main-game transitions preserve descriptor selection and sample the current pointer" {
    const allocator = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(data);
    const archive = try lab.Archive.init(data);
    var shell = try Shell.init(allocator, archive);
    defer shell.deinit(allocator);

    shell.screen.select(-1, 1);
    shell.screen.enter();
    shell.screen.presented(1);
    try shell.accept(allocator, archive, shell.screen.takeResult(101, 0).?, 101, .{ .x = -10, .y = 500 });
    try std.testing.expectEqual(menu.Kind.main, shell.screen.kind);
    try std.testing.expectEqual(@as(i32, -1), shell.screen.selected);
    try std.testing.expectEqual(@as(i32, 0), shell.screen.mouse_x);
    try std.testing.expectEqual(@as(i32, 479), shell.screen.mouse_y);
    try std.testing.expect(shell.screen.mouse_suppressed);

    shell.screen.mouseState(100, 170, 0, 10);
    shell.screen.mouseState(100, 350, 1, 11);
    try std.testing.expectEqual(@as(?i32, 0), shell.screen.pending_result);
    try std.testing.expectEqual(@as(i32, 2), shell.screen.selected);
    shell.screen.presented(20);
    shell.screen.mouseState(500, 270, 0, 70);
    try std.testing.expectEqual(@as(?i32, null), shell.screen.takeResult(119, 0));
    try std.testing.expectEqual(@as(?i32, null), shell.screen.takeResult(120, 1));
    const clicked = shell.screen.takeResult(120, 0).?;
    try shell.accept(allocator, archive, clicked, 120, .{ .x = 500, .y = 270 });
    try std.testing.expectEqual(menu.Kind.difficulty, shell.screen.kind);
    shell.screen.mouseState(500, 270, 0, 121);
    try std.testing.expectEqual(@as(i32, 0), shell.screen.selected);
    try std.testing.expect(shell.screen.mouse_suppressed);

    shell.screen.escape();
    shell.screen.presented(200);
    try shell.accept(allocator, archive, shell.screen.takeResult(300, 0).?, 300, .{ .x = 500, .y = 270 });
    try std.testing.expectEqual(menu.Kind.main, shell.screen.kind);
    try std.testing.expectEqual(@as(i32, 2), shell.screen.selected);
    try std.testing.expect(shell.startup == null);

    shell.screen.select(0, 400);
    shell.screen.enter();
    shell.screen.presented(400);
    try shell.accept(allocator, archive, shell.screen.takeResult(500, 0).?, 500, .{});
    shell.screen.tab(true, 510);
    try std.testing.expectEqual(@as(i32, 3), shell.screen.selected);
    shell.screen.enter();
    shell.screen.presented(520);
    try shell.accept(allocator, archive, shell.screen.takeResult(620, 0).?, 620, .{});
    try std.testing.expectEqual(menu.Kind.main, shell.screen.kind);
    try std.testing.expectEqual(@as(i32, 0), shell.screen.selected);
    try std.testing.expect(shell.startup == null);
    shell.screen.escape();
    try std.testing.expect(shell.screen.pending_result == null);
    shell.screen.enter();
    shell.screen.presented(700);
    try shell.accept(allocator, archive, shell.screen.takeResult(800, 0).?, 800, .{});
    try std.testing.expectEqual(@as(i32, 3), shell.screen.selected);

    shell.screen.tab(true, 810);
    try std.testing.expectEqual(@as(i32, 2), shell.screen.selected);
    shell.screen.enter();
    shell.screen.presented(820);
    try std.testing.expect(shell.startup == null);
    try shell.accept(allocator, archive, shell.screen.takeResult(920, 0).?, 920, .{});
    try std.testing.expectEqual(campaign.Difficulty.ugly, shell.startup.?.difficulty);
    try std.testing.expectEqualStrings("OUTLAWS.rcs", shell.startup.?.request.path());
    try std.testing.expectEqualStrings("in_shb.san", shell.startup.?.first_event.name);

    try shell.endGame(allocator, archive, 1000, .{ .x = 123, .y = 456 });
    try std.testing.expect(shell.startup == null);
    try std.testing.expectEqual(menu.Kind.main, shell.screen.kind);
    try std.testing.expectEqual(@as(i32, 0), shell.screen.selected);
    try std.testing.expectEqual(@as(i32, 123), shell.screen.mouse_x);
    try shell.accept(allocator, archive, 0, 1010, .{});
    try std.testing.expectEqual(@as(i32, 2), shell.screen.selected);
    try shell.accept(allocator, archive, 2, 1020, .{});
    try std.testing.expectEqual(campaign.Difficulty.ugly, shell.startup.?.difficulty);
}

test "1.1.1 multiplayer entry returns to the saved main selection" {
    const allocator = std.testing.allocator;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(data);
    const archive = try lab.Archive.init(data);
    var shell = try Shell.init(allocator, archive);
    defer shell.deinit(allocator);
    shell.screen.select(1, 10);
    try shell.accept(allocator, archive, 1, 20, .{});
    try std.testing.expect(shell.multiplayer_requested);
    try std.testing.expectEqual(@as(i32, 1), shell.main_selection);
    try shell.returnFromMultiplayer(allocator, archive, 30, .{ .x = 321, .y = 123 });
    try std.testing.expect(!shell.multiplayer_requested);
    try std.testing.expectEqual(menu.Kind.main, shell.screen.kind);
    try std.testing.expectEqual(@as(i32, 1), shell.screen.selected);
    try std.testing.expectEqual(@as(i32, 321), shell.screen.mouse_x);
}
