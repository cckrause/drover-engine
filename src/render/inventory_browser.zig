//! The inventory strip: the item being selected and its two neighbours,
//! each with its own sprite playback.
//!
//! The three instances are drawn in neighbour, current, selected order.
//! Layout is computed once from the initially selected item, and the third
//! cell deliberately reuses the second cell's dimensions.

const std = @import("std");
const nwx = @import("../assets/nwx.zig");
const font_module = @import("../assets/font.zig");
const inventory = @import("../player/inventory.zig");
const hud = @import("hud.zig");

pub const Instance = struct { costume: *const nwx.Costume, playback: nwx.Playback };

pub const Browser = struct {
    initialized: bool = false,
    restore_frames: u32 = 0,
    changed_at: u32 = 0,
    was_open: bool = false,
    instances: [3]?Instance = @splat(null),
    rects: [3]hud.Rect = @splat(.{}),
    bounds: hud.Rect = .{},
    cursor: i32 = 0,
    count: i32 = 0,
    font: ?font_module.Font = null,

    pub fn advance(self: *Browser, now: u32) !void {
        for (&self.instances) |*slot| if (slot.*) |*value| try value.playback.advance(value.costume, 0, now);
    }

    pub fn draw(self: *Browser, host: anytype, items: *inventory.Inventory, pixels: []u8) !void {
        if (pixels.len != 640 * 480) return error.InvalidHudFramebuffer;
        try self.update(host, items, false);
        if (self.restore_frames != 0) self.restore_frames -= 1;
        if (!items.browsing) return;
        self.restore_frames = 2;
        for (self.instances, self.rects) |instance, rect| if (instance) |value| try hud.blitMapped(pixels, 640, 480, value.costume, try frame(value, false), rect, .{ .width = 640, .height = 480 }, null, host.blend_table);
        if (self.countText(items)) |count| {
            var buffer: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, "(x{d})", .{count});
            const font = self.font.?;
            const center_x = self.bounds.x + @divTrunc(self.bounds.width, 2);
            const baseline_y = self.bounds.y + self.bounds.height - 4;
            const width = try font.width(text);
            const left = @max(0, center_x - @divTrunc(width, 2));
            const right = @min(640, center_x - @divTrunc(width, 2) + width);
            const top = @max(0, baseline_y - font.baseline);
            const bottom = @min(480, baseline_y - font.baseline + font.height);
            if (left < right and top < bottom) for (@intCast(top)..@intCast(bottom)) |y| @memset(pixels[y * 640 + @as(usize, @intCast(left)) .. y * 640 + @as(usize, @intCast(right))], 255);
            var translation: [256]u8 = undefined;
            for (&translation, 0..) |*value, i| value.* = @intCast(i);
            translation[0] = 255;
            translation[255] = 0;
            try font.drawCentered(pixels, 640, 480, text, center_x, baseline_y, &translation);
        }
    }

    pub fn countText(self: *const Browser, items: *const inventory.Inventory) ?i32 {
        if (items.browse_cursor == 0 or self.font == null) return null;
        const owned = items.slots[items.browse_cursor] orelse return null;
        return if (owned.count > 1) owned.count else null;
    }

    pub fn update(self: *Browser, host: anytype, items: *inventory.Inventory, four_views: bool) !void {
        var cursor: i32 = @intCast(items.browse_cursor);
        const count = items.itemCount();
        const changed = cursor != self.cursor or count != self.count;
        if (changed or (!self.was_open and items.browsing)) {
            self.changed_at = host.now;
        } else if (host.now -% self.changed_at > 5000) items.browsing = false;
        self.was_open = items.browsing;
        if (!items.browsing or changed) {
            self.instances = @splat(null);
            self.cursor = -1;
            self.count = -1;
        }
        if (items.browsing and changed) {
            if (cursor < 0 or cursor >= items.slots.len) return error.InvalidInventorySlot;
            var selected = items.slots[@intCast(cursor)];
            if (selected == null or selected.?.definition.no_show) {
                const start: usize = @intCast(std.math.clamp(cursor, 1, 25));
                if (items.adjacentItem(start, 1) orelse items.adjacentItem(start, -1)) |found| {
                    cursor = @intCast(found);
                    items.browse_cursor = found;
                    selected = items.slots[found];
                } else items.browsing = false;
            }
            if (items.browsing) {
                const owned = selected.?.definition;
                if (!self.initialized) {
                    if (!owned.wax_available) return error.InventoryLayoutWithoutWax;
                    try self.layout(host, try host.resource(owned.costume), four_views);
                }
                if (owned.wax_available) self.instances[2] = try make(try host.resource(owned.costume), 2, host.now);
                if (items.adjacentItem(@intCast(cursor), -1)) |previous| if (items.slots[previous].?.definition.wax_available) {
                    self.instances[1] = try make(try host.resource(items.slots[previous].?.definition.costume), 3, host.now);
                };
                if (items.adjacentItem(@intCast(cursor), 1)) |next| if (items.slots[next].?.definition.wax_available) {
                    self.instances[0] = try make(try host.resource(items.slots[next].?.definition.costume), 4, host.now);
                };
                self.cursor = cursor;
                self.count = count;
            }
        }
    }

    fn layout(self: *Browser, host: anytype, costume: *const nwx.Costume, four_views: bool) !void {
        self.* = .{ .initialized = true };
        var instance = try make(costume, 2, host.now);
        const selected = try frame(instance, four_views);
        const cell = try firstCell(costume, selected);
        self.rects[2] = .{ .x = 435, .y = host.status_y - 30, .width = @intCast(cell.width), .height = @intCast(cell.height) };
        var left = self.rects[2].x + selected.parts[0].raw_x;
        var top = self.rects[2].y + selected.parts[0].raw_y;
        var right = left + self.rects[2].width;
        var bottom = top + self.rects[2].height;
        for ([_]u32{ 3, 4 }, [_]usize{ 1, 0 }) |chor, index| {
            try instance.playback.select(costume, chor, host.now, null);
            const image = try frame(instance, four_views);
            const part = try firstCell(costume, image);
            self.rects[index] = .{ .x = self.rects[2].x, .y = self.rects[2].y, .width = @intCast(part.width), .height = @intCast(part.height) };
            const x = self.rects[1].x + image.parts[0].raw_x;
            const y = self.rects[1].y + image.parts[0].raw_y;
            left = @min(left, x);
            top = @min(top, y);
            right = @max(right, x + self.rects[1].width);
            bottom = @max(bottom, y + self.rects[1].height);
        }
        self.bounds = .{ .x = left - 2, .y = top - 2, .width = right - left + 4, .height = bottom - top + 4 };
        for (host.archives) |archive| {
            const bytes = archive.find("INFO.LAF", 0x4e464e54) catch |err| switch (err) {
                error.ResourceNotFound => continue,
                else => return err,
            };
            self.font = try font_module.Font.init(bytes);
            break;
        }
    }
};

pub fn frame(instance: Instance, four_views: bool) !*const nwx.Frame {
    return instance.costume.selectFacing(instance.playback.choreography, instance.playback.frame, 0, instance.playback.angle_offset, four_views);
}

fn make(costume: *const nwx.Costume, sequence: u32, now: u32) !Instance {
    var instance: Instance = .{ .costume = costume, .playback = .{ .last_time = now } };
    try instance.playback.select(costume, sequence, now, null);
    return instance;
}

fn firstCell(costume: *const nwx.Costume, image: *const nwx.Frame) !nwx.Cell {
    if (image.parts.len == 0) return error.MissingHudFramePart;
    return costume.cells[image.parts[0].cell];
}
