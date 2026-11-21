//! The automap: walls the player has seen, the layers, the player glyph and
//! the panning and zooming around them.
//!
//! The background repeats the texture's memory rows and does not undo the
//! loader's rotation, so its row count is the texture's first dimension. Map
//! keys come through a 32-entry ring that overwrites rather than blocks.

const std = @import("std");
const level_module = @import("../assets/level.zig");
const scene_module = @import("scene.zig");
const camera = @import("backends/software/camera.zig");
const input = @import("../player/input.zig");
const messages_module = @import("hud_messages.zig");
const local_messages = @import("../assets/messages.zig");
const Vec2 = level_module.Vec2;

pub const Input = struct {
    down: [128]bool = @splat(false),
    queue: [32]u7 = @splat(0),
    written: u32 = 0,
    read: u32 = 0,

    pub fn key(self: *Input, scan: u7, down: bool) void {
        self.down[scan] = down;
        if (down) {
            self.written +%= 1;
            self.queue[self.written & 31] = scan;
        }
    }

    pub fn clear(self: *Input) void {
        self.written = 0;
        self.read = 0;
    }

    fn next(self: *Input) ?u7 {
        if (@as(i32, @bitCast(self.read)) >= @as(i32, @bitCast(self.written))) return null;
        self.read +%= 1;
        const scan = self.queue[self.read & 31];
        return if (scan == 0) null else scan;
    }
};

pub const Player = struct { position: Vec2, layer: f32, yaw: i16, head_yaw: i16 = 0 };

pub const Rect = struct { left: i32 = 0, top: i32 = 0, width: i32, height: i32 };

pub const Point = struct { x: i32, y: i32 };

pub const Canvas = struct {
    pixels: []u8,
    stride: i32,
    words: ?*const [256]u16 = null,

    fn put(self: Canvas, x: i32, y: i32, color: u8) void {
        const at: usize = @intCast(y * self.stride + x);
        if (self.words) |table| {
            std.mem.writeInt(u16, self.pixels[at * 2 ..][0..2], table[color], .little);
        } else self.pixels[at] = color;
    }
};

pub const Secrets = struct {
    found: u32,
    total: u32,
    v111: bool = false,
};

pub const State = struct {
    mode: u32 = 0,
    flags: u32 = 0,
    preference: u32 = 3,
    controller: u32 = 0,
    previous_controller: u32 = 0,
    initialized: bool = false,
    zoom: f32 = 0.75,
    previous_zoom: f32 = 1,
    follow: bool = true,
    all_layers: bool = false,
    reveal: bool = false,
    selected_layer: f32 = 0,
    previous_layer: f32 = 0,
    center: Vec2 = .{ .x = 0, .z = 0 },
    previous_player: Vec2 = .{ .x = 0, .z = 0 },
    previous_secrets: u32 = 0,
    capture_arrows: bool = false,

    pub fn packet(self: *State, controls: *const input.Packet) void {
        const entry = controls.get(.map);
        if (entry.value != 1 or entry.flags & input.pressed == 0) return;
        self.setMode(if (self.preference == 0) self.mode +% 1 else if (self.mode != 0) 0 else self.preference);
    }

    pub fn setMode(self: *State, mode: u32) void {
        const retained = self.flags & 8;
        switch (mode) {
            0 => {
                self.mode = 0;
                self.flags = retained;
                self.capture_arrows = false;
                self.initialized = false;
            },
            1 => self.initialized = true,
            2...5 => {
                self.mode = mode;
                self.flags = retained | switch (mode) {
                    2 => @as(u32, 2),
                    3 => 6,
                    4 => 1,
                    5 => 5,
                    else => unreachable,
                };
            },
            else => {
                self.mode = 0;
                self.flags = retained;
            },
        }
        self.controller = mode;
    }

    pub fn separate(self: *const State) bool {
        return self.flags & 1 != 0;
    }

    pub fn draw(self: *State, level: *const level_module.Level, scene: *const scene_module.Scene, angles: *const camera.Angles, player: Player, controls: *Input, seconds: f32, canvas: Canvas, width: i32, height: i32, rect: Rect, messages: *messages_module.HudMessages, now: u32, secrets: Secrets) !void {
        if (self.mode == 0) return;
        if (!self.initialized or self.previous_secrets != secrets.found) {
            var text: [64]u8 = undefined;
            try messages.postText(if (secrets.v111)
                try secretsText111(messages.source, &text, secrets.found, secrets.total)
            else
                try std.fmt.bufPrint(&text, "Secrets:  {d} of {d}\n", .{ secrets.found, secrets.total }), 1, now);
            self.previous_secrets = secrets.found;
        }
        if (!self.initialized) {
            controls.clear();
            self.setMode(1);
        }
        if (self.controller != self.previous_controller) {
            if (self.previous_controller == 0) self.recenter(player);
            self.previous_controller = self.controller;
        }
        if (player.layer != self.previous_layer) {
            self.recenter(player);
            self.previous_layer = player.layer;
        }
        if (self.follow) self.center = player.position;
        const projection = Projection.init(angles, self.center, player.yaw +% player.head_yaw, self.flags & 4 != 0, self.zoom, width, height, rect.width);
        try self.processControls(controls, level, projection, seconds, messages, now);
        if (!self.follow or player.layer != self.selected_layer) {
            const point = projection.project(self.center);
            line(canvas, rect, point, point, 14);
        }
        if (player.layer == self.selected_layer) {
            projection.rifle(canvas, rect, angles, player.position, player.yaw, 14);
            projection.triangle(canvas, rect, angles, player.position, player.yaw +% player.head_yaw, 14);
        }
        self.drawWalls(level, scene, projection, canvas, rect);
        if (!self.follow) {
            if (player.position.x != self.previous_player.x or player.position.z != self.previous_player.z) self.follow = true;
            self.previous_player = player.position;
        }
    }

    pub fn drawWalls(self: *const State, level: *const level_module.Level, scene: *const scene_module.Scene, projection: Projection, canvas: Canvas, rect: Rect) void {
        for (level.sectors, scene.sectors) |sector, live| {
            if ((!self.all_layers and sector.layer != self.selected_layer) or live.flags & 0x20000000 != 0) continue;
            for (sector.walls, live.walls) |wall, state| {
                if (state.flags & 0x20000 != 0) continue;
                const seen = state.runtime_flags & 0x40000000 != 0;
                if (!seen and (!self.reveal or state.flags & 0x40000 != 0)) continue;
                var first = sector.vertices[wall.v1];
                var last = sector.vertices[wall.v2];
                if (!projection.oriented and !projection.clip(&first, &last)) continue;
                line(canvas, rect, projection.project(first), projection.project(last), if (seen) 15 else 7);
            }
        }
    }

    fn recenter(self: *State, player: Player) void {
        self.center = player.position;
        self.selected_layer = player.layer;
    }

    fn processControls(self: *State, raw: *Input, level: *const level_module.Level, projection: Projection, seconds: f32, messages: *messages_module.HudMessages, now: u32) !void {
        if (self.controller == 0) return;
        while (raw.next()) |key| {
            if (key == 15 and raw.down[42]) {
                self.all_layers = !self.all_layers;
                try self.layerMessage(messages, now);
            } else if (key == 39 or key == 40) {
                if (!self.all_layers) {
                    var low: i32 = 100;
                    var high: i32 = -100;
                    for (level.sectors) |sector| {
                        const value: i32 = @intFromFloat(sector.layer);
                        low = @min(low, value);
                        high = @max(high, value);
                    }
                    self.selected_layer = if (key == 40) @min(self.selected_layer + 1, @as(f32, @floatFromInt(high))) else @max(self.selected_layer - 1, @as(f32, @floatFromInt(low)));
                }
                try self.layerMessage(messages, now);
            }
        }
        self.capture_arrows = raw.down[41];
        if (self.capture_arrows) {
            for ([_]u7{ 77, 75, 72, 80 }) |key| if (raw.down[key]) {
                if (!self.follow) {
                    const dt: f64 = seconds;
                    const c: f64 = projection.cos;
                    const s: f64 = projection.sin;
                    switch (key) {
                        77 => {
                            self.center.x = store(c * dt * 60.0 + self.center.x);
                            self.center.z = store(dt * 60.0 * s + self.center.z);
                        },
                        75 => {
                            self.center.x = store(self.center.x - c * dt * 60.0);
                            self.center.z = store(self.center.z - dt * 60.0 * s);
                        },
                        72 => {
                            self.center.z = store(c * dt * 60.0 + self.center.z);
                            self.center.x = store(self.center.x - dt * 60.0 * s);
                        },
                        80 => {
                            self.center.z = store(self.center.z - c * dt * 60.0);
                            self.center.x = store(dt * 60.0 * s + self.center.x);
                        },
                        else => unreachable,
                    }
                }
                self.follow = false;
            };
        }
        for ([_]u7{ 12, 13 }) |key| if (raw.down[key]) {
            self.previous_zoom = self.zoom;
            const delta = @as(f64, self.zoom) * 1.5 * @as(f32, 0.6666667) * seconds;
            self.zoom = if (key == 12) @max(store(self.zoom - delta), @as(f32, 0.025)) else @min(store(delta + self.zoom), 32.0);
        };
    }

    fn layerMessage(self: *const State, messages: *messages_module.HudMessages, now: u32) !void {
        try messages.post(if (self.all_layers) 671 else std.math.clamp(round(self.selected_layer) + 650, 630, 670), null, now);
    }
};

pub const Projection = struct {
    origin: Vec2,
    center: Point,
    scale: f32,
    sin: f32,
    cos: f32,
    oriented: bool,
    min: Vec2,
    max: Vec2,

    pub fn init(angles: *const camera.Angles, origin: Vec2, yaw: i16, oriented: bool, zoom: f32, width: i32, height: i32, clip_width: i32) Projection {
        const basis = angles.sinCos(-%yaw);
        const scale = store(@as(f64, @floatFromInt(clip_width)) * 0.003125 * zoom);
        const inverse = store(1.0 / @as(f64, scale));
        const half_x = @divTrunc(width, 2);
        const half_y = @divTrunc(height, 2);
        return .{
            .origin = origin,
            .center = .{ .x = half_x, .y = half_y },
            .scale = scale,
            .sin = if (oriented) basis.sin else 0,
            .cos = if (oriented) basis.cos else 1,
            .oriented = oriented,
            .min = .{ .x = origin.x + store(@as(f64, @floatFromInt(-half_x)) * inverse), .z = origin.z + store(@as(f64, @floatFromInt(height - half_y)) * -inverse) },
            .max = .{ .x = origin.x + store(@as(f64, @floatFromInt(width - half_x)) * inverse), .z = origin.z + store(@as(f64, @floatFromInt(-half_y)) * -inverse) },
        };
    }

    pub fn project(self: Projection, point: Vec2) Point {
        return self.projectDelta(.{ .x = point.x - self.origin.x, .z = point.z - self.origin.z });
    }

    pub fn triangle(self: Projection, canvas: Canvas, rect: Rect, angles: *const camera.Angles, position: Vec2, yaw: i16, color: u8) void {
        const direction = angles.sinCos(yaw);
        const side = angles.sinCos(yaw +% 0x1000);
        const bx: f64 = @as(f64, position.x) - @as(f64, direction.sin) * 2.0 * 0.125 * 2.0;
        const bz: f64 = @as(f64, position.z) - @as(f64, direction.cos) * 2.0 * 0.125 * 2.0;
        const tip = self.project(.{ .x = store(@as(f64, direction.sin) * 2.0 + bx), .z = store(@as(f64, direction.cos) * 2.0 + bz) });
        const left = self.project(.{ .x = store(bx + @as(f64, side.sin) * 2.0), .z = store(bz + @as(f64, side.cos) * 2.0) });
        const right = self.project(.{ .x = store(bx - @as(f64, side.sin) * 2.0), .z = store(bz - @as(f64, side.cos) * 2.0) });
        line(canvas, rect, tip, left, color);
        line(canvas, rect, tip, right, color);
        line(canvas, rect, left, right, color);
    }

    pub fn rifle(self: Projection, canvas: Canvas, rect: Rect, angles: *const camera.Angles, position: Vec2, yaw: i16, color: u8) void {
        const outline = [_][2]f32{ .{ 100, 0 }, .{ 74, 14 }, .{ 80, 2 }, .{ 72, 2 }, .{ 70, 4 }, .{ 62, 2 }, .{ 4, 2 }, .{ 0, 4 }, .{ -4, 2 }, .{ -62, 2 }, .{ -72, 14 }, .{ -92, 14 }, .{ -84, 2 }, .{ -90, 2 }, .{ -90, 4 }, .{ -100, 4 }, .{ -100, 2 }, .{ -96, 2 }, .{ -96, 0 } };
        const basis = angles.sinCos(yaw);
        const s = store(@as(f64, basis.sin) * 0.04);
        const c = store(@as(f64, basis.cos) * 0.04);
        for (outline[0 .. outline.len - 1], outline[1..]) |a, b| {
            for ([_]f32{ 1, -1 }) |sign| {
                const first = self.project(.{ .x = store(@as(f64, a[1] * sign) * -c + @as(f64, a[0]) * s + position.x), .z = store(@as(f64, a[1] * sign) * s + @as(f64, a[0]) * c + position.z) });
                const last = self.projectDelta(.{ .x = store(@as(f64, b[0]) * s + @as(f64, b[1] * sign) * -c + position.x - self.origin.x), .z = store(@as(f64, b[0]) * c + @as(f64, b[1] * sign) * s + position.z - self.origin.z) });
                line(canvas, rect, last, first, color);
            }
        }
    }

    fn projectDelta(self: Projection, point: Vec2) Point {
        const x = if (self.oriented) store(@as(f64, point.z) * self.sin + @as(f64, point.x) * self.cos) else point.x;
        const z = if (self.oriented) store(@as(f64, point.z) * self.cos - @as(f64, point.x) * self.sin) else point.z;
        return .{ .x = round(store(@as(f64, x) * self.scale + @as(f64, @floatFromInt(self.center.x)))), .y = round(store(@as(f64, z) * -self.scale + @as(f64, @floatFromInt(self.center.y)))) };
    }

    fn code(self: Projection, p: Vec2) u32 {
        var result: u32 = if (p.x < self.min.x) 1 else if (p.x > self.max.x) 0x10 else 0;
        result |= if (p.z < self.min.z) @as(u32, 0x1000) else if (p.z > self.max.z) 0x100 else 0;
        return result;
    }

    fn clip(self: Projection, first: *Vec2, last: *Vec2) bool {
        var a = first.*;
        var b = last.*;
        var ac = self.code(a);
        var bc = self.code(b);
        const horizontal = a.z == b.z;
        const vertical = a.x == b.x;
        while (ac != 0 or bc != 0) {
            if (ac & bc != 0) return false;
            const out = if (ac != 0) ac else bc;
            var point: Vec2 = undefined;
            if (out & 0x1100 != 0) {
                point.z = if (out & 0x1000 != 0) self.min.z else self.max.z;
                point.x = if (vertical) a.x else store((@as(f64, point.z) - a.z) * ((@as(f64, b.x) - a.x) / (@as(f64, b.z) - a.z)) + a.x);
            } else {
                point.x = if (out & 0x10 != 0) self.max.x else self.min.x;
                point.z = if (horizontal) a.z else store((@as(f64, point.x) - a.x) * ((@as(f64, b.z) - a.z) / (@as(f64, b.x) - a.x)) + a.z);
            }
            if (out == ac) {
                a = point;
                ac = self.code(a);
            } else {
                b = point;
                bc = self.code(b);
            }
        }
        first.* = a;
        last.* = b;
        return true;
    }
};

pub fn background(pixels: []u8, width: usize, height: usize, texture: @import("../assets/texture.zig").Texture) void {
    for (0..height) |y| for (0..width) |x| {
        pixels[y * width + x] = texture.pixels[((y & (texture.width - 1)) << texture.height_shift) + (x & (texture.height - 1))];
    };
}

pub fn line(canvas: Canvas, rect: Rect, first: Point, last: Point, color: u8) void {
    var a = first;
    var b = last;
    const right = rect.left + rect.width - 1;
    const bottom = rect.top + rect.height - 1;
    if (a.x == b.x) {
        if (a.x < rect.left or a.x > right) return;
    } else {
        if (a.x < rect.left or a.x > right) {
            const bound = if (a.x < rect.left) rect.left else right;
            if ((a.x < rect.left and b.x < rect.left) or (a.x > right and b.x > right)) return;
            a.y = b.y +% @divTrunc((a.y -% b.y) *% (bound -% b.x), a.x -% b.x);
            a.x = bound;
        }
        if (b.x < rect.left or b.x > right) {
            const bound = if (b.x < rect.left) rect.left else right;
            b.y = a.y +% @divTrunc((b.y -% a.y) *% (bound -% a.x), b.x -% a.x);
            b.x = bound;
        }
    }
    if (a.y == b.y) {
        if (a.y < rect.top or a.y > bottom) return;
    } else {
        if (a.y < rect.top or a.y > bottom) {
            const bound = if (a.y < rect.top) rect.top else bottom;
            if ((a.y < rect.top and b.y < rect.top) or (a.y > bottom and b.y > bottom)) return;
            a.x = b.x +% @divTrunc((a.x -% b.x) *% (bound -% b.y), a.y -% b.y);
            a.y = bound;
        }
        if (b.y < rect.top or b.y > bottom) {
            const bound = if (b.y < rect.top) rect.top else bottom;
            b.x = a.x +% @divTrunc((b.x -% a.x) *% (bound -% a.y), b.y -% a.y);
            b.y = bound;
        }
    }
    const dx: i32 = @intCast(@abs(b.x - a.x));
    const dy: i32 = @intCast(@abs(b.y - a.y));
    const sx: i32 = if (b.x < a.x) -1 else 1;
    const sy: i32 = if (b.y < a.y) -1 else 1;
    const major = @max(dx, dy);
    const minor = @min(dx, dy);
    var err = major >> 1;
    var count = major + 1;
    while (count > 0) : (count -= 1) {
        canvas.put(a.x, a.y, color);
        if (dx > dy) a.x += sx else a.y += sy;
        err -= minor;
        if (err < 0) {
            err += major;
            if (dx > dy) a.y += sy else a.x += sx;
        }
    }
}

fn secretsText111(source: []const u8, out: *[64]u8, found: u32, total: u32) ![]const u8 {
    const format = local_messages.lookup(source, 673) catch |err| switch (err) {
        error.MessageNotFound => return error.MapSecretsMessageMissing,
        else => return err,
    };
    if (format.len >= 40) return error.MapSecretsMessageTooLong;
    var length: usize = 0;
    var argument: usize = 0;
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%') {
            if (length >= 51) return error.MapSecretsTextTooLong;
            out[length] = format[i];
            length += 1;
            continue;
        }
        if (i + 1 >= format.len or (format[i + 1] != 'i' and format[i + 1] != 'd') or argument == 2) return error.UnsupportedMapSecretsFormat;
        const value: i32 = @bitCast(if (argument == 0) found else total);
        argument += 1;
        i += 1;
        const digits = std.fmt.bufPrint(out[length..], "{d}", .{value}) catch return error.MapSecretsTextTooLong;
        length += digits.len;
        if (length >= 51) return error.MapSecretsTextTooLong;
    }
    out[length] = '\n';
    return out[0 .. length + 1];
}

fn store(value: f64) f32 {
    return @floatCast(value);
}

fn round(value: f32) i32 {
    const base = @floor(@as(f64, value));
    const integer: i32 = @intFromFloat(base);
    const fraction = @as(f64, value) - base;
    return integer + @as(i32, @intFromBool(fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)));
}
