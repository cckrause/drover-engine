//! The dialog engine the option pages and the lobby run on: a table of
//! widget records, one page callback, and the focus and input handling
//! around them.
//!
//! Widget types are fixed by the dispatch table: list, text, button, text
//! field, slider and box. Records hold the widget rectangle and the
//! rectangle copied out of the highlight image while the widget has focus.
//! The dialog handed to a page callback is not always that page's own
//! dialog - moving focus dispatches through the parent - so a callback must
//! check what it was given.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const pcx = @import("../assets/pcx.zig");
const Font = @import("../assets/font.zig").Font;
const messages = @import("../assets/messages.zig");
const nwx = @import("../assets/nwx.zig");
const hud = @import("../render/hud.zig");
const draw = @import("surface.zig");

pub const width = 640;

pub const height = 480;

pub const cancel_id: u32 = 0x10000;

const plain_keys = keyTable("0000313233343536373839302d3d080971776572747975696f705b5d0a006173646667686a6b6c3b2760005c7a786376626e6d2c2e2f002a0020000000000000000000000000000000002d0800002b000000000000000000000000000000000000000000000000000000000000000000303132333435363738392d2a2f2b2e00");

const shifted_keys = keyTable("000021402324255e262a28295f2b080951574552545955494f507b7d0a004153444647484a4b4c3a2260005c5a584356424e4d3c3e3f002a0020000000000000000000000000000000002d0800002b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");

pub const Kind = enum(u32) { list = 1, text = 3, button = 5, field = 6, slider = 8, lines = 9, box = 10 };

pub const Box = struct { top: i32, left: i32, height: i32, width: i32 };

pub const Record = struct {
    kind: Kind,
    id: u32,
    rect: Box,
    highlight: Box = .{ .top = 0, .left = 0, .height = 0, .width = 0 },
};

pub const Message = enum(u32) { init = 0, close = 1, changed = 3, step = 4, focus = 5, activate = 6 };

pub const Page = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, dialog: *Dialog, message: Message, id: u32, value: i32) anyerror!void,

    pub fn send(self: Page, dialog: *Dialog, message: Message, id: u32, value: i32) !void {
        return self.call(self.context, dialog, message, id, value);
    }
};

pub const Handler = enum {
    none,
    toggle,
    slider,
    list,
    field,
};

pub const Shared = struct {
    focus: ?*Widget = null,
    handler: Handler = .none,
    lock: bool = false,
    depth: i32 = -1,
    sounds: u32 = 0,
};

pub const Fonts = struct {
    title: Font,
    row: Font,
    info: Font,

    pub fn load(archive: lab.Archive) !Fonts {
        return .{
            .title = try Font.init(try archive.find("fl3x.laf", 0x4e464e54)),
            .row = try Font.init(try archive.find("f24.laf", 0x4e464e54)),
            .info = try Font.init(try archive.find("info.laf", 0x4e464e54)),
        };
    }
};

pub const Text = struct {
    text: ?[]u8 = null,
    table: i32 = 0,
    color: i32 = -1,
    alignment: u32 = 1,
    middle: bool = true,
};

pub const Button = struct {
    label: ?[]u8 = null,
    toggle: i32 = 0,
    pressed: i32 = 0,
};

pub const Slider = struct {
    min: i16 = 0,
    max: i16 = 0,
    value: i16 = 0,
    dragging: i32 = 0,
};

pub const Frame = struct { inner: u32 = 0, outer: u32 = 0xffffff };

pub const List = struct {
    items: []const []const u8 = &.{},
    title: ?[]const u8 = null,
    selected: i32 = 0,
    top: i32 = 0,
    lit: bool = false,
};

pub const Field = struct {
    buffer: ?[]u8 = null,

    pub fn text(self: *const Field) []const u8 {
        return if (self.buffer) |buffer| std.mem.sliceTo(buffer, 0) else "";
    }
};

pub const Lines = struct {
    items: std.ArrayList([]u8) = .empty,
    bottom_up: bool = false,
};

pub const Data = union(Kind) {
    list: List,
    text: Text,
    button: Button,
    field: Field,
    slider: Slider,
    lines: Lines,
    box: Frame,
};

pub const Widget = struct {
    id: u32,
    focused: bool = false,
    state: i32 = 1,
    font: *const Font,
    font_height: i32,
    rect: Box,
    highlight: Box,
    dialog: *Dialog,
    data: Data,

    fn toggleWord(self: *Widget) *i32 {
        return switch (self.data) {
            .button => |*button| &button.toggle,
            .slider => |*slider| &slider.dragging,
            .text => |*text| &text.table,
            .box, .list, .field, .lines => unreachable,
        };
    }

    fn contains(self: *const Widget, x: i32, y: i32) bool {
        return self.rect.left <= x and x < self.rect.width + self.rect.left and
            self.rect.top <= y and y < self.rect.height + self.rect.top;
    }
};

pub const Input = struct {
    x: i32 = 0,
    y: i32 = 0,
    buttons: u32 = 0,
    shift: bool = false,
};

pub const KeyQueue = struct {
    values: [32]u8 = @splat(0),
    written: u32 = 0,
    read: u32 = 0,

    pub fn push(self: *KeyQueue, scan: u8) void {
        self.written +%= 1;
        self.values[self.written & 31] = scan;
    }

    pub fn next(self: *KeyQueue) u8 {
        if (@as(i32, @bitCast(self.read)) >= @as(i32, @bitCast(self.written))) return 0;
        self.read +%= 1;
        return self.values[self.read & 31];
    }
};

pub const Image = struct {
    pixels: []u8,
    palette: [256]u32,
    width: i32,
    height: i32,
};

pub const Dialog = struct {
    allocator: std.mem.Allocator,
    shared: *Shared,
    page: Page,
    widgets: []Widget,
    palette: [256]u32,
    ramp: [8]u32,
    image: ?Image,
    highlight_image: ?Image,
    background_loaded: bool,
    highlight_loaded: bool,
    palette_dirty: bool = true,
    running: bool = true,
    result: i32 = 0,
    buttons: u32 = 0,
    captured: i32 = -1,
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    keys: KeyQueue = .{},
    cursor: *const nwx.Costume,
    messages: []const u8,
    saved_focus: ?*Widget,
    saved_handler: Handler,
    parent: ?*Dialog,

    pub fn open(
        self: *Dialog,
        a: std.mem.Allocator,
        archive: lab.Archive,
        shared: *Shared,
        parent: ?*Dialog,
        page: Page,
        records: []const Record,
        fonts: *const Fonts,
        cursor: *const nwx.Costume,
        background: ?[]const u8,
        highlight: ?[]const u8,
        display: *const [256]u32,
        mouse: Input,
    ) !void {
        if (parent) |p| {
            p.background_loaded = false;
            p.highlight_loaded = false;
        }
        self.* = .{
            .allocator = a,
            .shared = shared,
            .page = page,
            .widgets = &.{},
            .palette = display.*,
            .ramp = undefined,
            .image = null,
            .highlight_image = null,
            .background_loaded = false,
            .highlight_loaded = false,
            .cursor = cursor,
            .messages = try archive.find("LOCAL.MSG", 0),
            .saved_focus = shared.focus,
            .saved_handler = shared.handler,
            .parent = parent,
        };
        shared.depth += 1;
        errdefer shared.depth -= 1;
        shared.lock = false;
        errdefer self.freeImages();
        if (background) |name| {
            self.image = try loadImage(a, archive, name);
            self.background_loaded = true;
            self.palette = self.image.?.palette;
            self.palette[218] = 0x7f7f7f;
            self.palette[219] = 0xffffff;
            self.highlight_image = if (highlight) |other| try loadImage(a, archive, other) else try loadImage(a, archive, name);
            self.highlight_loaded = true;
        }
        @memcpy(&self.ramp, self.palette[228..236]);
        self.widgets = try a.alloc(Widget, records.len);
        errdefer a.free(self.widgets);
        for (records, self.widgets) |record, *widget| widget.* = .{
            .id = record.id,
            .font = &fonts.info,
            .font_height = fonts.info.height,
            .rect = record.rect,
            .highlight = record.highlight,
            .dialog = self,
            .data = switch (record.kind) {
                .list => .{ .list = .{} },
                .field => .{ .field = .{} },
                .text => .{ .text = .{} },
                .button => .{ .button = .{} },
                .slider => .{ .slider = .{} },
                .lines => .{ .lines = .{} },
                .box => .{ .box = .{} },
            },
        };
        errdefer for (self.widgets) |*widget| self.freeWidget(widget);
        try self.page.send(self, .init, 0, 0);
        for (self.widgets) |*widget| if (try self.takeFocus(widget)) break;
        self.mouse_x = std.math.clamp(mouse.x, 0, width - 1);
        self.mouse_y = std.math.clamp(mouse.y, 0, height - 1);
        self.buttons = mouse.buttons;
    }

    pub fn close(self: *Dialog) !i32 {
        try self.page.send(self, .close, 0, 0);
        for (self.widgets) |*widget| self.freeWidget(widget);
        self.allocator.free(self.widgets);
        self.widgets = &.{};
        self.freeImages();
        self.shared.focus = self.saved_focus;
        self.shared.handler = self.saved_handler;
        self.shared.depth -= 1;
        return self.result;
    }

    pub fn reload(self: *Dialog) void {
        if (self.image != null) self.background_loaded = true;
        if (self.highlight_image != null) self.highlight_loaded = true;
    }

    pub fn setLines(self: *Dialog, id: u32, lines: []const []const u8, bottom_up: bool) !void {
        const widget = self.find(id) orelse return;
        const data = switch (widget.data) {
            .lines => |*value| value,
            else => return error.NotALinesWidget,
        };
        freeLines(self.allocator, data, 0);
        data.bottom_up = bottom_up;
        for (lines) |line| try data.items.append(self.allocator, try self.allocator.dupe(u8, line));
    }

    pub fn prependLine(self: *Dialog, id: u32, line: []const u8) !void {
        const widget = self.find(id) orelse return;
        const data = switch (widget.data) {
            .lines => |*value| value,
            else => return error.NotALinesWidget,
        };
        const copy = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(copy);
        try data.items.insert(self.allocator, 0, copy);
        data.bottom_up = true;
    }

    pub fn find(self: *Dialog, id: u32) ?*Widget {
        for (self.widgets) |*widget| if (widget.id == id) return widget;
        return null;
    }

    pub fn setValue(self: *Dialog, id: u32, a: Value, b: i32) !void {
        const widget = self.find(id) orelse return;
        switch (widget.data) {
            .text => |*text| {
                if (a.text) |value| {
                    if (text.text) |old| self.allocator.free(old);
                    text.text = null;
                    text.text = try self.copyText(value);
                }
                if (b != -1) text.table = b;
            },
            .button => |*button| {
                if (a.text) |value| {
                    if (button.label) |old| self.allocator.free(old);
                    button.label = null;
                    button.label = try self.copyText(value);
                }
                button.toggle = b;
            },
            .slider => |*slider| {
                slider.min = @truncate(a.number);
                slider.max = @truncate(a.number >> 16);
                slider.value = @truncate(b);
                try self.page.send(self, .changed, widget.id, slider.value);
            },
            .box => |*colors| {
                colors.inner = @bitCast(a.number);
                colors.outer = @bitCast(b);
            },
            .list => |*list| {
                list.items = a.items;
                list.title = a.text;
                list.top = 0;
                list.selected = 0;
                try self.page.send(self, .changed, widget.id, list.selected);
            },
            .field => |*field| field.buffer = a.buffer,
            .lines => return error.LinesNeedSetLines,
        }
    }

    pub fn setSelected(self: *Dialog, id: u32, index: i32) void {
        const widget = self.find(id) orelse return;
        switch (widget.data) {
            .list => |*list| list.selected = index,
            else => {},
        }
    }

    pub fn setLit(self: *Dialog, id: u32, flags: u32) void {
        const widget = self.find(id) orelse return;
        switch (widget.data) {
            .list => |*list| list.lit = flags & 1 != 0,
            else => {},
        }
    }

    pub fn valueOf(self: *Dialog, id: u32) ?i32 {
        const widget = self.find(id) orelse return null;
        return switch (widget.data) {
            .button => |button| button.toggle,
            .slider => |slider| slider.value,
            .list => |list| list.selected,
            else => null,
        };
    }

    pub fn setFont(self: *Dialog, id: u32, font: *const Font) void {
        const widget = self.find(id) orelse return;
        widget.font = font;
        widget.font_height = font.height;
    }

    pub fn setColor(self: *Dialog, id: u32, color: i32, flags: i32) void {
        const widget = self.find(id) orelse return;
        switch (widget.data) {
            .text => |*text| {
                if (color >= 0) text.color = color;
                if (flags >= 0) {
                    text.middle = flags & 0x40000000 != 0;
                    text.alignment = @as(u32, @bitCast(flags)) & 0xfffffff;
                }
            },
            else => {},
        }
    }

    pub fn takeFocus(self: *Dialog, widget: *Widget) !bool {
        switch (widget.data) {
            .button => if (widget.state != 1) return false,
            .slider, .list, .field => if (widget.state == 0) return false,
            .text, .box, .lines => return false,
        }
        self.shared.sounds += 1;
        self.shared.lock = false;
        try focusOn(widget, switch (widget.data) {
            .slider => .slider,
            .list => .list,
            .field => .field,
            else => .toggle,
        });
        return true;
    }

    pub fn stepFocus(self: *Dialog, id: u32, step: i32) !void {
        const count: i32 = @intCast(self.widgets.len);
        var at: i32 = for (self.widgets, 0..) |widget, i| {
            if (widget.id == id) break @intCast(i);
        } else return;
        while (true) {
            at += step;
            while (at < 0) at += count;
            while (count <= at) at -= count;
            if (try self.takeFocus(&self.widgets[@intCast(at)])) return;
        }
    }

    pub fn neighbour(self: *Dialog, id: u32, direction: u32) ?u32 {
        const Candidate = struct {
            left: i32,
            center_x: i32,
            right: i32,
            top: i32,
            center_y: i32,
            bottom: i32,
            id: ?u32,
        };
        var center_x: i32 = 0;
        var center_y: i32 = 0;
        var exclude: ?u32 = id;
        var first = true;
        while (true) {
            var best: ?u32 = null;
            var best_distance: i32 = 3000000;
            for (self.widgets) |*widget| {
                const r = widget.rect;
                if (exclude != null and widget.id == exclude.?) {
                    center_x = r.left + @divTrunc(r.width, 2);
                    center_y = r.top + @divTrunc(r.height, 2);
                }
            }
            for (self.widgets) |*widget| {
                const r = widget.rect;
                const candidate: Candidate = .{
                    .left = r.left,
                    .center_x = r.left + @divTrunc(r.width, 2),
                    .right = r.width + r.left,
                    .top = r.top,
                    .center_y = r.top + @divTrunc(r.height, 2),
                    .bottom = r.top + r.height,
                    .id = if ((exclude != null and widget.id == exclude.?) or !focusable(widget)) null else widget.id,
                };
                if (candidate.id == null) continue;
                const distance: ?i32 = switch (direction) {
                    1 => if (candidate.center_y < center_y and candidate.left <= center_x and center_x <= candidate.right) center_y - candidate.center_y else null,
                    2 => if (center_x < candidate.center_x and candidate.top <= center_y and center_y <= candidate.bottom) candidate.center_x - center_x else null,
                    4 => if (center_y < candidate.center_y and candidate.left <= center_x and center_x <= candidate.right) candidate.center_y - center_y else null,
                    8 => if (candidate.center_x < center_x and candidate.top <= center_y and center_y <= candidate.bottom) center_x - candidate.center_x else null,
                    else => null,
                };
                if (distance) |d| if (d < best_distance) {
                    best = candidate.id;
                    best_distance = d;
                };
            }
            if (!first or best != null) return best;
            first = false;
            exclude = null;
            switch (direction) {
                1 => center_y = height,
                2 => center_x = 0,
                4 => center_y = 0,
                8 => center_x = width,
                else => {},
            }
        }
    }

    pub fn frame(self: *Dialog, input: Input, now: u32, display: *[256]u32) !void {
        if (!self.running) return;
        const key = self.keys.next();
        if (key != 0) if (self.shared.focus) |focus| switch (self.shared.handler) {
            .none => {},
            .toggle => try toggleKey(focus, key, input.shift),
            .slider => try sliderKey(focus, key, input.shift),
            .list => try listKey(focus, key, input.shift),
            .field => try fieldKey(focus, key, input.shift),
        };
        if (!self.background_loaded) return;
        const phase = (now / 5) % 40;
        const percent: i32 = @intCast(if (phase < 20) 100 - phase else phase + 60);
        draw.ramp(self.palette[220..228], &self.ramp, self.palette[228..236], percent);
        display.* = self.palette;
        const previous_x = self.mouse_x;
        const previous_y = self.mouse_y;
        self.mouse_x = std.math.clamp(input.x, 0, width - 1);
        self.mouse_y = std.math.clamp(input.y, 0, height - 1);
        const buttons = input.buttons;
        if (previous_x != self.mouse_x or self.mouse_y != previous_y or buttons != 0) {
            if (self.captured == -1) {
                for (self.widgets) |*widget| if (widget.contains(self.mouse_x, self.mouse_y)) {
                    try self.motion(widget, @max(self.mouse_x - widget.rect.left - 2, 0));
                };
            } else {
                const widget = &self.widgets[@intCast(self.captured)];
                try self.motion(widget, @max(self.mouse_x - widget.rect.left - 2, 0));
            }
        }
        if (buttons & 1 == 0) {
            if (self.buttons & 1 != 0 and self.captured != -1) {
                endPress(&self.widgets[@intCast(self.captured)]);
                for (self.widgets, 0..) |*widget, i| if (widget.contains(self.mouse_x, self.mouse_y) and self.captured == i) {
                    if (try self.release(widget)) break;
                };
                self.captured = -1;
            }
        } else if (self.buttons & 1 == 0) {
            for (self.widgets, 0..) |*widget, i| if (widget.contains(self.mouse_x, self.mouse_y)) {
                if (try self.press(widget, self.mouse_x - widget.rect.left - 2, self.mouse_y - widget.rect.top - 2)) {
                    self.captured = @intCast(i);
                    break;
                }
            };
        }
        self.buttons = buttons;
    }

    pub fn render(self: *Dialog, pixels: []u8, display: *[256]u32) !bool {
        const screen = try draw.Surface.init(pixels, width, height);
        if (self.background_loaded) draw.blit(screen, null, 0, 0, imageOf(self.image.?));
        if (self.running) {
            if (self.highlight_loaded) if (self.shared.focus) |focus| if (focus.highlight.width != 0 and focus.highlight.height != 0)
                draw.blit(screen, .{ .x = focus.highlight.left, .y = focus.highlight.top, .width = focus.highlight.width, .height = focus.highlight.height }, 0, 0, imageOf(self.highlight_image.?));
            for (self.widgets) |*widget| try drawWidget(screen, widget, display);
            if (self.background_loaded) try self.drawCursor(pixels);
        }
        if (!self.background_loaded) return false;
        if (self.palette_dirty) {
            display.* = self.palette;
            self.palette_dirty = false;
        }
        return true;
    }

    fn freeImages(self: *Dialog) void {
        if (self.image) |image| self.allocator.free(image.pixels);
        if (self.highlight_image) |image| self.allocator.free(image.pixels);
        self.image = null;
        self.highlight_image = null;
    }

    fn freeWidget(self: *Dialog, widget: *Widget) void {
        switch (widget.data) {
            .text => |*text| if (text.text) |value| self.allocator.free(value),
            .button => |*button| if (button.label) |value| self.allocator.free(value),
            .lines => |*lines| freeLines(self.allocator, lines, 0),
            else => {},
        }
    }

    fn freeLines(a: std.mem.Allocator, lines: *Lines, from: usize) void {
        for (lines.items.items[from..]) |line| a.free(line);
        if (from == 0) lines.items.deinit(a) else lines.items.shrinkRetainingCapacity(from);
        if (from == 0) lines.items = .empty;
    }

    fn copyText(self: *Dialog, text: []const u8) ![]u8 {
        if (text.len == 0 or text[0] != '&') return self.allocator.dupe(u8, text);
        const id = std.fmt.parseInt(u32, text[1..], 10) catch return error.InvalidMessageReference;
        const message = try messages.lookup(self.messages, id);
        if (message.len >= 0x50) return error.MessageTooLong;
        return self.allocator.dupe(u8, message);
    }

    fn focusOn(widget: *Widget, handler: Handler) !void {
        const shared = widget.dialog.shared;
        if (shared.focus) |old| {
            try widget.dialog.page.send(old.dialog, .focus, old.id, 0);
            if (shared.focus) |still| still.focused = false;
        }
        widget.focused = true;
        shared.focus = widget;
        try widget.dialog.page.send(widget.dialog, .focus, widget.id, 1);
        shared.handler = handler;
    }

    fn focusable(widget: *const Widget) bool {
        return switch (widget.data) {
            .button => widget.state == 1,
            .slider, .list, .field => widget.state != 0,
            .text, .box, .lines => false,
        };
    }

    fn press(self: *Dialog, widget: *Widget, x: i32, y: i32) !bool {
        switch (widget.data) {
            .list => |*list| {
                if (widget.state == 0) return false;
                if (x <= 0) return true;
                try focusOn(widget, .list);
                self.shared.lock = true;
                var left = y - 2;
                if (list.title != null) left -= widget.font_height + 3;
                const count: i32 = @intCast(list.items.len);
                var at = list.top;
                while (at < count and hidden(list.items[@intCast(at)])) at += 1;
                while (widget.font_height + 1 < left and at < count) {
                    at += 1;
                    while (at < count and hidden(list.items[@intCast(at)])) at += 1;
                    left -= widget.font_height + 1;
                }
                if (at >= count) return true;
                if (!hidden(list.items[@intCast(at)])) {
                    list.selected = at;
                    try self.page.send(self, .changed, widget.id, at);
                }
                return true;
            },
            .field => {
                if (widget.state == 0) return false;
                try focusOn(widget, .field);
                self.shared.lock = true;
                try self.page.send(self, .activate, widget.id, 1);
                return true;
            },
            .button => |*button| {
                if (widget.state != 1) return false;
                if (x > 0) {
                    try focusOn(widget, .toggle);
                    button.pressed = 1;
                }
                return true;
            },
            .slider => |*slider| {
                if (widget.state == 0) return false;
                if (x > 0) {
                    try focusOn(widget, .toggle);
                    self.shared.lock = true;
                    slider.dragging = 1;
                }
                return true;
            },
            .text, .box, .lines => return false,
        }
    }

    fn release(self: *Dialog, widget: *Widget) !bool {
        switch (widget.data) {
            .button => |*button| {
                button.pressed = 0;
                if (button.toggle == 1) button.toggle = 2 else if (button.toggle == 2) button.toggle = 1;
                try self.page.send(self, .activate, widget.id, @bitCast(@as(u32, @bitCast(button.toggle)) | 0x80000000));
            },
            else => {},
        }
        return false;
    }

    fn endPress(widget: *Widget) void {
        switch (widget.data) {
            .button => |*button| button.pressed = 0,
            .slider => |*slider| slider.dragging = 0,
            else => {},
        }
    }

    fn hidden(line: []const u8) bool {
        return line.len != 0 and line[0] == '~';
    }

    fn motion(self: *Dialog, widget: *Widget, x: i32) !void {
        switch (widget.data) {
            .button => if (!widget.focused and !self.shared.lock) {
                _ = try self.takeFocus(widget);
            },
            .slider => |*slider| {
                if (slider.dragging == 0) {
                    if (!widget.focused and !self.shared.lock) _ = try self.takeFocus(widget);
                    return;
                }
                const travel = widget.rect.width - 16;
                const span = @as(i32, slider.max) - slider.min;
                var at = (x & 0xffff) - 8 + @divTrunc(@divTrunc(travel, span), 2);
                if (at < 0) at = 0;
                if (travel < at) at = travel;
                slider.value = @truncate(@divTrunc(span * at, travel) + slider.min);
                try self.page.send(self, .changed, widget.id, slider.value);
            },
            .list, .field => if (!widget.focused and !self.shared.lock) {
                _ = try self.takeFocus(widget);
            },
            .text, .box, .lines => {},
        }
    }

    fn toggleKey(widget: *Widget, scan: u8, shift: bool) !void {
        const dialog = widget.dialog;
        switch (scan) {
            1 => try dialog.page.send(dialog, .activate, cancel_id, 0),
            0xf => try dialog.page.send(dialog, .step, widget.id, if (shift) -1 else 1),
            0x1c, 0x39 => {
                const word = widget.toggleWord();
                if (word.* == 1) word.* = 2 else if (word.* == 2) word.* = 1;
                try dialog.page.send(dialog, .activate, widget.id, word.*);
            },
            0x48, 0x4b, 0x4d, 0x50 => try dialog.arrow(widget, scan),
            else => {},
        }
    }

    fn arrow(self: *Dialog, widget: *Widget, scan: u8) !void {
        const direction: u32 = switch (scan) {
            0x48 => 1,
            0x4b => 8,
            0x4d => 2,
            else => 4,
        };
        const next = self.neighbour(widget.id, direction) orelse return;
        if (self.find(next)) |target| _ = try self.takeFocus(target);
    }

    fn listKey(widget: *Widget, scan: u8, shift: bool) !void {
        const dialog = widget.dialog;
        const list = &widget.data.list;
        const count: i32 = @intCast(list.items.len);
        switch (scan) {
            1 => try dialog.page.send(dialog, .activate, cancel_id, 0),
            0xf => try dialog.page.send(dialog, .step, widget.id, if (shift) -1 else 1),
            0x48 => {
                const from = list.selected;
                while (true) {
                    if (list.selected == 0) {
                        list.selected = from;
                        break;
                    }
                    list.selected -= 1;
                    if (!hidden(list.items[@intCast(list.selected)])) break;
                }
                try dialog.page.send(dialog, .changed, widget.id, list.selected);
            },
            0x4b, 0x4d => try dialog.arrow(widget, scan),
            0x50 => {
                const from = list.selected;
                while (true) {
                    list.selected += 1;
                    if (count <= list.selected) break;
                    if (!hidden(list.items[@intCast(list.selected)])) break;
                }
                if (count <= list.selected) list.selected = from;
                try dialog.page.send(dialog, .changed, widget.id, list.selected);
            },
            else => {},
        }
    }

    fn fieldKey(widget: *Widget, scan: u8, shift: bool) !void {
        const dialog = widget.dialog;
        switch (scan) {
            1 => try dialog.page.send(dialog, .activate, cancel_id, 0),
            0xf => try dialog.page.send(dialog, .step, widget.id, if (shift) -1 else 1),
            0x1c => {
                try dialog.page.send(dialog, .activate, widget.id, 0);
                dialog.shared.lock = false;
            },
            0x48, 0x4b, 0x4d, 0x50 => try dialog.arrow(widget, scan),
            else => {
                const buffer = widget.data.field.buffer orelse return error.DialogFieldWithoutBuffer;
                const length = std.mem.indexOfScalar(u8, buffer, 0) orelse return error.DialogFieldWithoutEnd;
                const character = (if (shift) &shifted_keys else &plain_keys)[scan & 0x7f];
                if (character == 8) {
                    if (length != 0) buffer[length - 1] = 0;
                } else if (character > 0x1f and length + 1 < buffer.len) {
                    buffer[length] = character;
                    buffer[length + 1] = 0;
                }
                try dialog.page.send(dialog, .changed, widget.id, 0);
            },
        }
    }

    fn sliderKey(widget: *Widget, scan: u8, shift: bool) !void {
        const dialog = widget.dialog;
        const slider = &widget.data.slider;
        switch (scan) {
            1 => try dialog.page.send(dialog, .activate, cancel_id, 0),
            0xf => try dialog.page.send(dialog, .step, widget.id, if (shift) -1 else 1),
            0x47 => slider.value = slider.min,
            0x48, 0x50 => try dialog.arrow(widget, scan),
            0x49, 0x4b => {
                if (scan == 0x49) slider.value -%= 4;
                slider.value -%= 1;
                if (slider.value < slider.min) slider.value = slider.min;
            },
            0x4f => slider.value = slider.max,
            0x51, 0x4d => {
                if (scan == 0x51) slider.value +%= 4;
                slider.value +%= 1;
                if (slider.max < slider.value) slider.value = slider.max;
            },
            else => {},
        }
        try dialog.page.send(dialog, .changed, widget.id, widget.data.slider.value);
    }

    fn drawCursor(self: *Dialog, pixels: []u8) !void {
        if (self.mouse_x == 0 or self.mouse_y == 0) return;
        var playback = nwx.Playback{};
        try playback.select(self.cursor, 0, 0, null);
        const cell = try self.cursor.select(playback.choreography, playback.frame, 0, 0);
        try hud.blit(pixels, width, height, self.cursor, cell, .{ .x = self.mouse_x, .y = self.mouse_y }, .{ .width = width, .height = height });
    }
};

pub const Value = struct {
    text: ?[]const u8 = null,
    number: i32 = 0,
    items: []const []const u8 = &.{},
    buffer: ?[]u8 = null,

    pub fn lines(items: []const []const u8, title: ?[]const u8) Value {
        return .{ .items = items, .text = title };
    }

    pub fn field(buffer: []u8) Value {
        return .{ .buffer = buffer };
    }

    pub fn of(text: []const u8) Value {
        return .{ .text = text };
    }

    pub fn int(number: i32) Value {
        return .{ .number = number };
    }
};

pub fn wrap(font: *const Font, text: []u8, room: i32) !usize {
    if (text.len >= 199) return error.WrappedLineTooLong;
    var measured = try font.width(text);
    if (measured <= room) return 1;
    var copy: [200]u8 = @splat(0);
    @memcpy(copy[0..text.len], text);
    var start: usize = 0;
    var count: usize = 1;
    var at: usize = 1;
    while (measured > room and at != 0) {
        at = std.mem.indexOfScalar(u8, &copy, 0).? -| 1;
        while (at != 0) : (at -= 1) {
            if (copy[at] != ' ') continue;
            copy[at] = 0;
            measured = try font.width(std.mem.sliceTo(&copy, 0));
            if (measured <= room) {
                const split = start + at;
                count += 1;
                start = split + 1;
                text[split] = 0;
                @memset(&copy, 0);
                const rest = std.mem.sliceTo(text[start..], 0);
                @memcpy(copy[0..@min(rest.len, 199)], rest[0..@min(rest.len, 199)]);
                measured = try font.width(std.mem.sliceTo(&copy, 0));
                break;
            }
        }
    }
    return count;
}

fn imageOf(image: Image) draw.Image {
    return .{ .pixels = image.pixels, .width = image.width, .height = image.height };
}

fn loadImage(a: std.mem.Allocator, archive: lab.Archive, name: []const u8) !Image {
    const decoded = try pcx.decode(a, try archive.find(name, 0x50424d50));
    return .{ .pixels = decoded.pixels, .palette = decoded.palette, .width = @intCast(decoded.width), .height = @intCast(decoded.height) };
}

fn hiddenLine(line: []const u8) bool {
    return line.len != 0 and line[0] == '~';
}

fn solid(color: u8) [256]u8 {
    var table: [256]u8 = @splat(color);
    table[0] = 0;
    return table;
}

fn shifted(offset: u8, black: u8, white: u8) [256]u8 {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, i| entry.* = @as(u8, @intCast(i)) -% offset;
    table[0] = black;
    table[255] = white;
    return table;
}

fn keyTable(comptime hex: *const [256]u8) [128]u8 {
    var table: [128]u8 = undefined;
    _ = std.fmt.hexToBytes(&table, hex) catch unreachable;
    return table;
}

fn wrapInPlace(a: std.mem.Allocator, font: *const Font, lines: *Lines, index: usize, room: i32) !void {
    const line = lines.items.items[index];
    const text = try a.dupe(u8, line[1..]);
    defer a.free(text);
    const count = try wrap(font, text, room);
    if (count < 2) return;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(a);
    var rest: []const u8 = text;
    for (0..count) |_| {
        const part = std.mem.sliceTo(rest, 0);
        try parts.append(a, part);
        rest = if (part.len < rest.len) rest[part.len + 1 ..] else rest[rest.len..];
    }
    const letter = line[0];
    var made: std.ArrayList([]u8) = .empty;
    defer made.deinit(a);
    errdefer for (made.items) |piece| a.free(piece);
    for (0..count) |i| {
        const which = if (lines.bottom_up) count - 1 - i else i;
        const piece = try a.alloc(u8, parts.items[which].len + 1);
        errdefer a.free(piece);
        piece[0] = letter;
        @memcpy(piece[1..], parts.items[which]);
        try made.append(a, piece);
    }
    try lines.items.insertSlice(a, index + 1, made.items[1..]);
    a.free(line);
    lines.items.items[index] = made.items[0];
    made.clearRetainingCapacity();
}

fn drawWidget(screen: draw.Surface, widget: *Widget, display: *const [256]u32) !void {
    if (widget.state == 0) return;
    const r = widget.rect;
    switch (widget.data) {
        .list => |*list| {
            const lit = widget.focused or list.lit;
            const edge = draw.nearest(display, 1, 0xdb, if (lit) 0xffffff else 0x7f7f7f);
            const bar = if (lit) draw.nearest(display, 1, 0xdb, 0xff0000) else edge;
            const black = draw.nearest(display, 1, 0xdb, 0);
            const white = draw.nearest(display, 1, 0xdb, 0xffffff);
            const grey = draw.nearest(display, 1, 0xdb, 0x7f7f7f);
            draw.fill(screen, null, r.left, r.top, r.width, r.height, black);
            var top = r.top;
            var room = r.height;
            if (list.title) |title| {
                var heading: [80 + 0x50]u8 = undefined;
                if (title.len > 0x50) return error.MessageTooLong;
                const line = std.fmt.bufPrint(&heading, "{s: >40}{s}{s: >40}", .{ "", title, "" }) catch unreachable;
                try widget.font.drawFilled(screen.pixels, width, .{ .x = r.left, .y = r.top, .width = r.width, .height = r.height }, line, r.left + @divTrunc(r.width, 2), widget.font.baseline + r.top + 1, .center, &shifted(0x25, bar, white));
                top += widget.font_height + 1;
                draw.horizontal(screen, null, r.left, top, r.width, edge);
                top += 3;
                room -= widget.font_height + 3;
            }
            top += 2;
            const clip: Font.Clip = .{ .x = r.left + 2, .y = top, .width = r.width - 4, .height = room - 4 };
            const count: i32 = @intCast(list.items.len);
            if (count == 0) return;
            if (list.selected < list.top) list.top = list.selected;
            if (hiddenLine(list.items[@intCast(list.selected)])) {
                list.selected = 0;
                while (list.selected < count and hiddenLine(list.items[@intCast(list.selected)])) list.selected += 1;
                if (count <= list.selected) list.selected = 0;
            }
            var y = top;
            var at = list.top;
            while (at < count) : (at += 1) {
                const line = list.items[@intCast(at)];
                if (hiddenLine(line)) continue;
                var text = line;
                var front = edge;
                while (true) {
                    while (text.len != 0 and text[0] == ')') text = text[1..];
                    if (text.len == 0 or text[0] != '~') break;
                    text = text[1..];
                    front = grey;
                }
                const table = if (list.selected == at)
                    shifted(0x25, edge, if (front == grey and text.ptr != line.ptr and line[text.ptr - line.ptr - 1] == '~') grey else black)
                else
                    shifted(0x25, black, front);
                try widget.font.drawFilled(screen.pixels, width, clip, text, r.left + 2, widget.font.baseline + y, .left, &table);
                y += widget.font_height + 1;
                if (room - 4 + top <= y) {
                    if (list.selected == at) list.top += 1;
                    return;
                }
            }
        },
        .field => |*field| {
            const color: u32 = if (widget.focused) 0xffffff else 0;
            const table = solid(draw.nearest(display, 1, 0xdb, color));
            const buffer = field.buffer orelse return;
            while (true) {
                const text = std.mem.sliceTo(buffer, 0);
                if (try widget.font.width(text) <= r.width - 4 or text.len == 0) break;
                buffer[text.len - 1] = 0;
            }
            var shown: [0x100]u8 = undefined;
            const text = std.mem.sliceTo(buffer, 0);
            if (text.len + 1 > shown.len) return error.MessageTooLong;
            @memcpy(shown[0..text.len], text);
            shown[text.len] = '_';
            const y = widget.font.baseline - @divTrunc(widget.font_height, 2) + @divTrunc(r.height - 4, 2) + r.top + 2;
            try widget.font.drawClipped(screen.pixels, width, .{ .x = 0, .y = 0, .width = width, .height = height }, shown[0 .. text.len + 1], r.left + 2, y, .left, &table);
        },
        .text => |*text| {
            const black = draw.nearest(display, 1, 0xdb, 0);
            const white = draw.nearest(display, 1, 0xdb, 0xffffff);
            const table = if (text.color == -1)
                (if (text.table == 0) shifted(0x25, black, white) else shifted(0x1d, black, white))
            else
                solid(draw.nearest(display, 1, 0xdb, @bitCast(text.color)));
            const value = text.text orelse return;
            var top = r.top;
            if (text.middle) top = top - @divTrunc(widget.font_height, 2) + @divTrunc(r.height, 2);
            const x = switch (text.alignment & 3) {
                0 => r.left,
                2 => r.width + r.left,
                else => @divTrunc(r.width, 2) + r.left,
            };
            const alignment: Font.Alignment = if (text.alignment & 1 != 0) .center else if (text.alignment & 2 != 0) .right else .left;
            try widget.font.drawClipped(screen.pixels, width, .{ .x = r.left, .y = r.top, .width = r.width, .height = r.height }, value, x, widget.font.baseline + top, alignment, &table);
        },
        .button => |*button| {
            const color: u32 = if (widget.state == 2) 0x7f7f7f else if (widget.focused) 0xffffff else 0;
            const table = solid(draw.nearest(display, 1, 0xdb, color));
            const inner_width = r.width - 4;
            const inner_height = r.height - 4;
            const top = r.top + 2;
            const left = r.left + 2;
            const clip: Font.Clip = .{ .x = left, .y = top, .width = inner_width, .height = inner_height };
            const label = button.label orelse return;
            const y = widget.font.baseline - @divTrunc(widget.font_height, 2) + @divTrunc(inner_height, 2) + top - 2;
            switch (button.toggle) {
                1 => if (label.len == 0) {
                    try widget.font.drawClipped(screen.pixels, width, clip, "X", @divTrunc(inner_width, 2) + left, y, .center, &table);
                } else {
                    try widget.font.drawClipped(screen.pixels, width, clip, "X", left, y, .left, &table);
                    try widget.font.drawClipped(screen.pixels, width, clip, label, widget.font_height + left, y, .left, &table);
                },
                2 => if (label.len != 0)
                    try widget.font.drawClipped(screen.pixels, width, clip, label, widget.font_height + left, y, .left, &table),
                else => try widget.font.drawClipped(screen.pixels, width, clip, label, @divTrunc(inner_width, 2) + left, y, .center, &table),
            }
        },
        .slider => |*slider| {
            const black = draw.nearest(display, 1, 0xdb, 0);
            const white = draw.nearest(display, 1, 0xdb, 0xffffff);
            const knob = draw.nearest(display, 1, 0xdb, 0x5c9ace);
            const middle = @divTrunc(r.height, 2) + r.top;
            var at: i32 = 0;
            if (slider.max != slider.min)
                at = @divTrunc((@as(i32, slider.value) - slider.min) * (r.width - 16), @as(i32, slider.max) - slider.min);
            at += r.left;
            draw.fill(screen, null, at + 1, middle - 4, 15, 8, knob);
            draw.horizontal(screen, null, at, middle - 5, 16, white);
            draw.horizontal(screen, null, at, middle + 4, 16, black);
            draw.vertical(screen, null, at, middle - 5, 10, white);
            draw.vertical(screen, null, at + 16, middle - 5, 10, black);
            draw.horizontal(screen, null, at + 4, middle - 1, 9, if (widget.focused) white else black);
        },
        .lines => |*lines| {
            if (widget.state == 0) return;
            const a = widget.dialog.allocator;
            const frame_color = draw.nearest(display, 1, 0xdb, if (widget.focused) 0xffffff else 0x404040);
            const black = draw.nearest(display, 1, 0xdb, 0);
            draw.fill(screen, null, r.left, r.top, r.width, r.height, frame_color);
            draw.fill(screen, null, r.left + 2, r.top + 2, r.width - 4, r.height - 4, black);
            const inner_width = r.width - 8;
            const inner_height = r.height - 8;
            const top = r.top + 4;
            const clip: Font.Clip = .{ .x = r.left + 4, .y = top, .width = inner_width, .height = inner_height };
            const red = draw.nearest(display, 1, 0xdb, 0xff);
            const green = draw.nearest(display, 1, 0xdb, 0xff00);
            const blue = draw.nearest(display, 1, 0xdb, 0xff0000);
            const white = draw.nearest(display, 1, 0xdb, 0xffffff);
            var table: [256]u8 = @splat(0);
            table[0] = black;
            table[0xff] = white;
            var cursor = top;
            if (lines.bottom_up) cursor = (inner_height - widget.font_height) + top;
            var index: usize = 0;
            while (index < lines.items.items.len) : (index += 1) {
                const line = lines.items.items[index];
                if (line.len == 0) return error.LineWithoutColour;
                table[0xff] = switch (std.ascii.toUpper(line[0])) {
                    'B' => blue,
                    'G' => green,
                    'R' => red,
                    'W' => white,
                    else => return error.LineWithoutColour,
                };
                if (try widget.font.width(line[1..]) > inner_width) try wrapInPlace(a, widget.font, lines, index, inner_width);
                const shown = lines.items.items[index][1..];
                try widget.font.drawClipped(screen.pixels, width, clip, shown, r.left + 4, widget.font.baseline + cursor, .left, &table);
                const done = if (lines.bottom_up) blk: {
                    cursor -= widget.font_height;
                    break :blk cursor < top;
                } else blk: {
                    cursor += widget.font_height;
                    break :blk inner_height + top <= cursor;
                };
                if (done) {
                    Dialog.freeLines(a, lines, index + 1);
                    return;
                }
            }
        },
        .box => |*colors| {
            const inner = draw.nearest(display, 1, 0xdb, colors.inner);
            const outer = draw.nearest(display, 1, 0xdb, colors.outer);
            draw.fill(screen, null, r.left + 1, r.top, r.width - 2, r.height, outer);
            draw.fill(screen, null, r.left, r.top + 1, r.width, r.height - 2, outer);
            draw.fill(screen, null, r.left + 3, r.top + 2, r.width - 6, r.height - 4, inner);
            draw.fill(screen, null, r.left + 2, r.top + 3, r.width - 4, r.height - 6, inner);
        },
    }
}
