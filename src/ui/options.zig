//! The OPTIONS pages: what they change is the settings store, the display
//! gamma, the view box, and which input driver buttons are offered.
//!
//! The gamma label is a UI string followed by the step number. A controls
//! button is only enabled when the host actually found a driver with that
//! name. The preview sits inside its own frame rather than at the page
//! origin. Pages that are not implemented log a warning and leave the
//! setting alone instead of stopping the game.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const messages = @import("../assets/messages.zig");
const display_palette = @import("../render/display_palette.zig");
const view_box = @import("../render/view_box.zig");
const settings = @import("../settings.zig");
const dialog = @import("dialog.zig");
const Box = dialog.Box;

pub const records = [_]dialog.Record{
    .{ .kind = .box, .id = 0xc, .rect = box(200, 514, 64, 86), .highlight = box(197, 510, 70, 96) },
    .{ .kind = .box, .id = 0xd, .rect = box(201, 515, 63, 85), .highlight = box(197, 510, 70, 96) },
    .{ .kind = .text, .id = 0, .rect = box(20, 0, 100, 640) },
    .{ .kind = .text, .id = 0xb, .rect = box(217, 40, 30, 180) },
    .{ .kind = .slider, .id = 0xa, .rect = box(217, 220, 30, 280) },
    .{
        .kind = .button,
        .id = 4,
        .rect = box(300, 72, 23, 207),
        .highlight = box(297, 67, 27, 217),
    },
    .{
        .kind = .button,
        .id = 5,
        .rect = box(333, 72, 23, 207),
        .highlight = box(330, 67, 26, 217),
    },
    .{
        .kind = .button,
        .id = 6,
        .rect = box(300, 362, 23, 207),
        .highlight = box(297, 357, 26, 217),
    },
    .{
        .kind = .button,
        .id = 7,
        .rect = box(333, 362, 23, 207),
        .highlight = box(330, 357, 26, 217),
    },
    .{ .kind = .text, .id = 0xf, .rect = box(378, 72, 30, 180) },
    .{ .kind = .slider, .id = 0xe, .rect = box(378, 252, 30, 322) },
    .{ .kind = .button, .id = 8, .rect = box(430, 37, 23, 124) },
    .{ .kind = .button, .id = 9, .rect = box(430, 182, 23, 124) },
    .{ .kind = .button, .id = dialog.cancel_id, .rect = box(430, 327, 23, 124) },
    .{ .kind = .button, .id = 1000, .rect = box(430, 472, 23, 124) },
};

pub const background = "NC1.PCX";

pub const State = struct {
    settings: *settings.Store,
    display: *display_palette.Display,
    view_box: *view_box.State,
    drivers: []const []const u8,
};

pub const Main = struct {
    state: State,
    fonts: *const dialog.Fonts,
    messages: []const u8,
    label: [30]u8 = @splat(0),
    prefix: usize = 0,
    saved_gamma: i32 = 0,
    saved_view_box: i32 = 0,

    pub fn init(archive: lab.Archive, state: State, fonts: *const dialog.Fonts) !Main {
        return .{ .state = state, .fonts = fonts, .messages = try archive.find("LOCAL.MSG", 0) };
    }

    pub fn page(self: *Main) dialog.Page {
        return .{ .context = self, .call = call };
    }

    fn call(
        context: *anyopaque,
        d: *dialog.Dialog,
        message: dialog.Message,
        id: u32,
        value: i32,
    ) anyerror!void {
        const self: *Main = @ptrCast(@alignCast(context));

        switch (message) {
            .init => try self.open(d),
            .changed => try self.changed(d, id, value),
            .step => try d.stepFocus(id, value),
            .focus => switch (id) {
                0xa => d.setColor(0xb, if (value == 0) 0 else 0xffffff, 0x40000000),
                0xe => d.setColor(0xf, if (value == 0) 0 else 0xffffff, 0x40000000),
                else => {},
            },
            .activate => try self.activate(d, id),
            .close => {},
        }
    }

    fn open(self: *Main, d: *dialog.Dialog) !void {
        self.saved_gamma = self.state.display.setGamma(-1000).previous;

        const name = try messages.lookup(self.messages, 0x13f4);
        if (name.len + 2 > self.label.len) return error.MessageTooLong;

        @memcpy(self.label[0..name.len], name);

        self.label[name.len] = ' ';
        self.prefix = name.len + 1;
        self.saved_view_box = self.state.view_box.index;

        try d.setValue(0, .of("&7500"), 0);
        d.setFont(0, &self.fonts.title);

        for ([_][]const u8{ "&7501", "&7502", "&7503", "&7504" }, 4..) |text, id| {
            try d.setValue(@intCast(id), .of(text), 0);
            d.setFont(@intCast(id), &self.fonts.row);
        }

        try d.setValue(0xb, .of("&7505"), 0);
        d.setFont(0xb, &self.fonts.row);
        d.setColor(0xb, 0xffffff, 0x40000000);

        const current = self.state.view_box.index - 1;

        try d.setValue(0xa, .int((view_box.count() - 2) * 0x10000), current);
        try d.setValue(0xc, .int(0), 0);
        try d.setValue(0xd, .int(0x5c9ace), 0x5c9ace);
        try d.setValue(0xf, .of(self.labelText()), 0);
        d.setFont(0xf, &self.fonts.row);
        try d.setValue(0xe, .int(0x4fffc), self.saved_gamma);
        d.setColor(0xf, 0, 0x40000000);

        for ([_]struct {
            u32,
            []const u8,
        }{
            .{ 9, "&7506" },
            .{ 8, "&7507" },
            .{ dialog.cancel_id, "&7110" },
            .{ 1000, "&7109" },
        }) |entry| {
            try d.setValue(entry[0], .of(entry[1]), 0);
            d.setFont(entry[0], &self.fonts.row);
        }

        for (d.widgets) |*widget| {
            const found = switch (widget.id) {
                4 => self.hasDriver("Joystick"),
                5 => self.hasDriver("Mouse"),
                6 => self.hasDriver("Keyboard"),
                7 => self.hasOtherDriver("JoystickMouseKeyboard"),
                else => continue,
            };

            if (!found) widget.state = 2;
        }
    }

    fn hasDriver(self: *const Main, name: []const u8) bool {
        for (self.state.drivers) |driver| if (std.ascii.eqlIgnoreCase(driver, name)) return true;

        return false;
    }

    fn hasOtherDriver(self: *const Main, names: []const u8) bool {
        for (self.state.drivers) |driver| if (std.mem.indexOf(
            u8,
            names,
            driver,
        ) == null) return true;

        return false;
    }

    fn labelText(self: *const Main) []const u8 {
        return std.mem.sliceTo(&self.label, 0);
    }

    fn changed(self: *Main, d: *dialog.Dialog, id: u32, value: i32) !void {
        switch (id) {
            0xa => {
                try self.setViewBox(value + 1);

                const frame = records[1].rect;
                const preview = view_box.within(
                    value + 1,
                    .{
                        .x = frame.left,
                        .y = frame.top,
                        .width = frame.width,
                        .height = frame.height,
                    },
                );

                d.widgets[1].rect = .{
                    .top = preview.y,
                    .left = preview.x,
                    .height = preview.height,
                    .width = preview.width,
                };
            },
            0xe => {
                @memset(self.label[self.prefix..], 0);
                _ = try std.fmt.bufPrint(self.label[self.prefix..], "{d}", .{value});
                try d.setValue(0xf, .of(self.labelText()), 0);
                try self.setGamma(value);
            },
            else => {},
        }
    }

    fn setViewBox(self: *Main, index: i32) !void {
        if (!self.state.view_box.apply(index, 640, 480)) return;

        var text: [12]u8 = undefined;

        try self.state.settings.write(
            null,
            null,
            "View Box",
            try std.fmt.bufPrint(&text, "{d}", .{index}),
        );
    }

    fn setGamma(self: *Main, step: i32) !void {
        if (step <= -5 or step >= 5) return;

        var text: [12]u8 = undefined;

        try self.state.settings.write(
            null,
            null,
            "Gamma",
            try std.fmt.bufPrint(&text, "{d}", .{step}),
        );

        _ = self.state.display.setGamma(step);
    }

    fn activate(self: *Main, d: *dialog.Dialog, id: u32) !void {
        switch (id) {
            1000 => {
                var text: [12]u8 = undefined;
                try self.state.settings.write(
                    null,
                    null,
                    "View Box",
                    try std.fmt.bufPrint(&text, "{d}", .{self.state.view_box.index}),
                );

                d.running = false;
                d.result = -1;
            },
            4, 5, 6, 7 => std.log.warn(
                "OPTIONS: the input driver's controls dialog is not implemented; nothing changes",
                .{},
            ),
            8 => std.log.warn("OPTIONS: VOLUME is not implemented; nothing changes", .{}),
            9 => std.log.warn("OPTIONS: OTHER OPTIONS is not implemented; nothing changes", .{}),
            dialog.cancel_id => {
                self.state.view_box.index = self.saved_view_box;
                try self.setGamma(self.saved_gamma);
                d.running = false;
                d.result = -1;
            },
            else => {},
        }
    }
};

fn box(top: i32, left: i32, height: i32, width: i32) Box {
    return .{ .top = top, .left = left, .height = height, .width = width };
}
