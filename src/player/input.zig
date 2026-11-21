//! Player input: the slot table the game reads, and the host deltas and
//! buttons that fill it.
//!
//! Right and down are positive. A key held down keeps producing presses, so
//! a slot's pressed bit means "pressed this frame" and callers have to
//! consume it.

const std = @import("std");

pub const absolute: u16 = 2;

pub const pressed: u16 = 8;

pub const released: u16 = 0x10;

pub const unscaled: u16 = 0x20;

const default_bindings = [_]Binding{
    .{ .action = 0, .keys = &.{72} },        .{ .action = 0, .keys = &.{17} },
    .{ .action = 1, .keys = &.{80} },        .{ .action = 1, .keys = &.{31} },
    .{ .action = 2, .keys = &.{75} },        .{ .action = 3, .keys = &.{77} },
    .{ .action = 4, .keys = &.{51} },        .{ .action = 4, .keys = &.{30} },
    .{ .action = 4, .keys = &.{ 56, 75 } },  .{ .action = 5, .keys = &.{52} },
    .{ .action = 5, .keys = &.{32} },        .{ .action = 5, .keys = &.{ 56, 77 } },
    .{ .action = 6, .keys = &.{45} },        .{ .action = 6, .keys = &.{18} },
    .{ .action = 7, .keys = &.{58} },        .{ .action = 8, .keys = &.{42} },
    .{ .action = 10, .keys = &.{46} },       .{ .action = 11, .keys = &.{ 47, 75 } },
    .{ .action = 11, .keys = &.{ 33, 75 } }, .{ .action = 12, .keys = &.{ 47, 77 } },
    .{ .action = 12, .keys = &.{ 33, 77 } }, .{ .action = 13, .keys = &.{73} },
    .{ .action = 13, .keys = &.{ 33, 72 } }, .{ .action = 14, .keys = &.{81} },
    .{ .action = 14, .keys = &.{ 33, 80 } }, .{ .action = 15, .keys = &.{76} },
    .{ .action = 16, .keys = &.{79} },       .{ .action = 17, .keys = &.{15} },
    .{ .action = 18, .keys = &.{ 42, 15 } }, .{ .action = 18, .keys = &.{ 54, 15 } },
    .{ .action = 19, .keys = &.{26} },       .{ .action = 20, .keys = &.{27} },
    .{ .action = 21, .keys = &.{29} },       .{ .action = 22, .keys = &.{44} },
    .{ .action = 22, .keys = &.{16} },       .{ .action = 23, .keys = &.{35} },
    .{ .action = 24, .keys = &.{19} },       .{ .action = 25, .keys = &.{11} },
    .{ .action = 26, .keys = &.{2} },        .{ .action = 27, .keys = &.{3} },
    .{ .action = 28, .keys = &.{4} },        .{ .action = 29, .keys = &.{5} },
    .{ .action = 30, .keys = &.{6} },        .{ .action = 31, .keys = &.{7} },
    .{ .action = 32, .keys = &.{8} },        .{ .action = 33, .keys = &.{9} },
    .{ .action = 34, .keys = &.{10} },       .{ .action = 35, .keys = &.{56} },
    .{ .action = 36, .keys = &.{33} },       .{ .action = 37, .keys = &.{57} },
    .{ .action = 38, .keys = &.{38} },       .{ .action = 39, .keys = &.{35} },
    .{ .action = 40, .keys = &.{20} },       .{ .action = 41, .keys = &.{ 56, 16 } },
    .{ .action = 42, .keys = &.{34} },       .{ .action = 43, .keys = &.{37} },
    .{ .action = 44, .keys = &.{28} },       .{ .action = 45, .keys = &.{ 56, 21 } },
    .{ .action = 46, .keys = &.{ 56, 38 } }, .{ .action = 47, .keys = &.{ 42, 59 } },
    .{ .action = 48, .keys = &.{ 42, 60 } }, .{ .action = 49, .keys = &.{ 42, 61 } },
    .{ .action = 50, .keys = &.{ 42, 62 } }, .{ .action = 51, .keys = &.{ 42, 63 } },
    .{ .action = 52, .keys = &.{ 42, 64 } }, .{ .action = 53, .keys = &.{ 42, 65 } },
    .{ .action = 54, .keys = &.{ 42, 66 } }, .{ .action = 55, .keys = &.{ 42, 67 } },
    .{ .action = 56, .keys = &.{ 42, 68 } }, .{ .action = 57, .keys = &.{59} },
    .{ .action = 58, .keys = &.{60} },       .{ .action = 59, .keys = &.{61} },
    .{ .action = 60, .keys = &.{62} },       .{ .action = 61, .keys = &.{63} },
    .{ .action = 62, .keys = &.{64} },       .{ .action = 63, .keys = &.{65} },
    .{ .action = 64, .keys = &.{66} },       .{ .action = 65, .keys = &.{67} },
    .{ .action = 66, .keys = &.{68} },
};

pub const Slot = enum(u5) {
    forward = 0,
    strafe = 1,
    turn = 2,
    pitch = 3,
    head_turn = 5,
    head_pitch = 6,
    look_yaw = 7,
    mouse_pitch = 8,
    jump = 10,
    crouch = 11,
    weapon = 12,
    fire = 13,
    map = 14,
    modifiers = 15,
    fire_big = 16,
    fire_other = 17,
    reload = 18,
    nudge = 19,
    lamp = 20,
    hud = 21,
    frags = 22,
    speed = 23,
    exit = 24,
    drop = 25,
    kick = 26,
    use = 27,
    chat = 28,
    lobby = 29,
};

pub const Entry = extern struct {
    value: i16 = 0,
    flags: u16 = 0,
};

pub const Packet = extern struct {
    count: u16 = 30,
    stride: u16 = 4,
    reserved: u32 = 0,
    entries: [30]Entry = @splat(.{}),

    pub fn get(self: *const Packet, slot: Slot) Entry {
        return self.entries[@intFromEnum(slot)];
    }
};

pub const Mouse = struct {
    dx: i32 = 0,
    dy: i32 = 0,
    buttons: u3 = 0,
};

const KeyState = struct { down: bool = false, down_time: u32 = 0, up_time: u32 = 0 };

const Binding = struct { action: u8, keys: []const u7 };

pub const State = struct {
    keys: [128]KeyState = @splat(.{}),
    previous_time: u32 = 0,
    previous: [30]bool = @splat(false),
    current: [30]bool = @splat(false),
    mouse_previous: u3 = 0,
    mouse_started: bool = false,

    pub fn key(self: *State, scan_code: u7, down: bool, now_ms: u32) void {
        const state = &self.keys[scan_code];
        if (down) {
            if (!state.down) state.down_time = now_ms;
            state.down = true;
        } else if (state.down) {
            state.down = false;
            state.up_time = now_ms;
        }
    }

    pub fn sample(self: *State, now_ms: u32, mouse_input: Mouse) !Packet {
        if (self.previous_time == 0) self.previous_time = now_ms -% 100;
        const elapsed: i32 = @bitCast(now_ms -% self.previous_time);
        if (elapsed == 0) return error.ZeroInputInterval;
        var packet: Packet = .{};
        self.set(&packet, .speed, true, 100, 0x800);
        packet.entries[@intFromEnum(Slot.speed)].flags |= unscaled;
        self.current = @splat(false);
        var duration: [128]u32 = @splat(0);
        var age: [128]u32 = @splat(0);
        for (self.keys, 0..) |key_state, i| {
            var start = self.previous_time;
            if (self.previous_time < key_state.down_time) {
                duration[i] = 0x80000000;
                start = key_state.down_time;
                if (now_ms == start) start -%= 1;
            }
            var end = now_ms;
            if (key_state.down_time <= key_state.up_time) end = @max(key_state.up_time, self.previous_time);
            age[i] = ((start +% end) >> 1) -% key_state.down_time;
            duration[i] |= end -% start;
        }
        var count: usize = 2;
        while (count != 0) : (count -= 1) {
            for (default_bindings) |binding| {
                if (binding.keys.len != count) continue;
                var held: u32 = std.math.maxInt(u32);
                var held_age: u32 = std.math.maxInt(u32);
                for (binding.keys) |scan_code| {
                    held = @min(held, duration[scan_code] & 0x7fffffff);
                    if (held == 0) break;
                    held_age = @min(held_age, age[scan_code]);
                }
                if (held == 0) continue;
                duration[binding.keys[binding.keys.len - 1]] = 0;
                self.action(&packet, binding.action, @bitCast(held), elapsed, held_age);
            }
        }
        self.previous_time = now_ms;
        for (self.previous, self.current, 0..) |was, is, i| {
            if (was) {
                if (!is) packet.entries[i].flags |= released else packet.entries[i].flags &= ~released;
            }
        }
        self.previous = self.current;
        self.mouse(&packet, mouse_input);
        return packet;
    }

    fn set(self: *State, packet: *Packet, slot: Slot, is_absolute: bool, input_value: i16, scale: i32) void {
        var value = input_value;
        if (scale < 0) value = 0 else if (scale < 0x800) {
            value = @intCast(@divTrunc(@as(i32, value) * scale, 0x800));
        }
        const i = @intFromEnum(slot);
        self.current[i] = true;
        const entry = &packet.entries[i];
        if (is_absolute) entry.flags |= absolute else entry.flags &= ~absolute;
        entry.value = value;
        if (!self.previous[i]) entry.flags |= pressed else entry.flags &= ~pressed;
    }

    fn action(self: *State, packet: *Packet, id: u8, held: i32, elapsed: i32, age: u32) void {
        const full: i32 = 0x800;
        const acceleration: i32 = if (age < 200) @intCast((age << 11) / 200) else full;
        switch (id) {
            0, 1 => self.set(packet, .forward, true, fraction(held, if (id == 0) 0x1400 else -0x1400, elapsed), full),
            2, 3 => {
                const value = fraction(held, if (id == 2) -0x1400 else 0x1400, elapsed);
                self.set(packet, .turn, false, value, acceleration);
                self.set(packet, .head_turn, false, value, acceleration);
            },
            4, 5 => self.set(packet, .strafe, true, fraction(held, if (id == 4) -0x1400 else 0x1400, elapsed), full),
            6 => self.set(packet, .jump, true, 0x1400, full),
            7, 8, 9 => self.set(packet, .speed, true, @truncate(@divTrunc(@as(i32, packet.get(.speed).value) * @as(i32, if (id == 7) 66 else if (id == 8) 150 else 300), 100)), full),
            10 => self.set(packet, .crouch, true, 0x1400, full),
            11, 12, 16 => self.set(packet, .look_yaw, true, if (id == 11) -0x4000 else if (id == 12) 0x4000 else -0x8000, full),
            13, 14 => {
                var value = fraction(held, 0x2000, elapsed);
                if (id == 14) value = -%value;
                self.set(packet, .pitch, false, value, acceleration);
                self.set(packet, .head_pitch, false, value, acceleration);
            },
            15 => for ([_]Slot{ .pitch, .head_pitch, .look_yaw, .mouse_pitch }) |slot| self.set(packet, slot, true, 0, full),
            17, 18 => self.set(packet, .map, false, if (id == 17) 1 else 2, full),
            19, 20 => self.set(packet, .weapon, false, if (id == 19) -1 else 1, full),
            21 => self.set(packet, .fire, true, 1, full),
            22 => self.set(packet, .fire_big, true, 1, full),
            23 => self.set(packet, .fire_other, true, 1, full),
            24 => self.set(packet, .reload, true, 1, full),
            25...34 => self.set(packet, .weapon, true, id - 25, full),
            35, 36 => {
                self.current[@intFromEnum(Slot.modifiers)] = true;
                packet.entries[@intFromEnum(Slot.modifiers)].value |= if (id == 35) 1 else 2;
            },
            37...40 => self.set(packet, @enumFromInt(@as(u5, @intCast(id - 18))), true, 1, full),
            41...44 => self.set(packet, @enumFromInt(@as(u5, @intCast(id - 17))), true, 1, full),
            45 => self.set(packet, .chat, true, 0, full),
            46 => self.set(packet, .lobby, true, 1, full),
            47...56 => self.set(packet, .chat, true, id - 46, full),
            57...66 => self.set(packet, .chat, true, -@as(i16, id - 56), full),
            else => unreachable,
        }
    }

    fn mouse(self: *State, packet: *Packet, input: Mouse) void {
        const buttons = input.buttons;
        for ([_]struct { mask: u3, slot: Slot, repeat: bool, value: i16 }{
            .{ .mask = 1, .slot = .fire, .repeat = true, .value = 1 },
            .{ .mask = 4, .slot = .forward, .repeat = true, .value = 0x1400 },
            .{ .mask = 2, .slot = .reload, .repeat = false, .value = 1 },
        }) |binding| {
            const entry = &packet.entries[@intFromEnum(binding.slot)];
            const was = self.mouse_previous & binding.mask != 0;
            if (buttons & binding.mask != 0) {
                if (binding.repeat or !was) {
                    entry.flags |= absolute;
                    entry.value = binding.value;
                }
                if (!was) entry.flags |= pressed;
            } else if (was) entry.flags |= released;
        }
        self.mouse_previous = buttons;
        const turn = &packet.entries[@intFromEnum(Slot.turn)];
        const yaw = input.dx *% 16 *% 10;
        if (yaw != 0) {
            turn.flags = (turn.flags | unscaled) & ~absolute;
            turn.value = @intCast(std.math.clamp(yaw, -0x8000, 0x7fff));
        }
        if (!self.mouse_started) turn.flags |= pressed;
        const pitch = &packet.entries[@intFromEnum(Slot.mouse_pitch)];
        const delta = @divTrunc((-%input.dy) *% 16, 6);
        pitch.flags = (pitch.flags | unscaled) & ~absolute;
        pitch.value = @intCast(std.math.clamp(delta, -0x8000, 0x7fff));
        if (!self.mouse_started) packet.entries[@intFromEnum(Slot.look_yaw)].flags |= pressed;
        self.mouse_started = true;
    }
};

pub const Control = struct {
    forward: f32 = 0,
    strafe: f32 = 0,
    turn: f32 = 0,
    jump: f32 = 0,
    look_up: f32 = 0,
    look_down: f32 = 0,
    flags: u32 = 0,
};

pub const LookState = struct {
    pitch_active: bool = false,
    pitch_accumulator: i32 = 0,
    yaw_active: bool = false,
    yaw_accumulator: i32 = 0,

    pub fn control(self: *LookState, packet: *const Packet) Control {
        return self.controlForLife(packet, true);
    }

    pub fn controlForLife(self: *LookState, packet: *const Packet, alive: bool) Control {
        var result: Control = .{};
        const percent: i16 = if (alive and packet.get(.speed).flags & unscaled != 0) packet.get(.speed).value else 100;
        if (alive) {
            if (percent == 66) result.flags |= 1 else if (percent == 150) result.flags |= 2 else if (percent >= 300) result.flags |= 4;
            result.forward = axis(packet.get(.forward), percent);
            if (packet.get(.jump).value > 0) {
                result.jump = @floatCast(@as(f64, @floatFromInt(packet.get(.jump).value)) * @as(f64, @as(f32, 0.0001953125)) * @as(f64, @floatFromInt(percent)) * @as(f64, @as(f32, 0.01)));
                result.flags |= 8;
            }
            if (packet.get(.crouch).value > 0) result.flags |= 0x10;
            result.strafe = axis(packet.get(.strafe), percent);
        }
        const pitch = packet.get(.pitch);
        if (pitch.value > 0) result.look_up = @as(f32, @floatFromInt(pitch.value)) * @as(f32, 0.0001220703125);
        if (pitch.value < 0) result.look_down = @as(f32, @floatFromInt(pitch.value)) * @as(f32, -0.0001220703125);
        if (pitch.flags & absolute != 0 and pitch.value == 0) result.flags |= 0x20;
        const mouse_pitch = packet.get(.mouse_pitch);
        self.pitch_active = mouse_pitch.flags & unscaled != 0;
        if (self.pitch_active) self.pitch_accumulator = std.math.clamp(self.pitch_accumulator +% mouse_pitch.value, -0x8000, 0x7fff);
        const turn = packet.get(.turn);
        if (turn.flags & absolute == 0) {
            if (turn.flags & unscaled == 0) {
                result.turn = axis(turn, percent);
            } else {
                result.turn = @floatCast(@as(f64, @floatFromInt(turn.value)) * @as(f64, @as(f32, 0.0001953125)) * 0.03125);
                result.flags |= 0x40000;
            }
        }
        const yaw = packet.get(.look_yaw);
        self.yaw_active = yaw.flags & unscaled != 0;
        if (self.yaw_active) {
            self.yaw_accumulator = @as(i16, @truncate(self.yaw_accumulator +% yaw.value));
        } else self.yaw_accumulator = 0;
        if (yaw.value == -0x8000) result.flags |= 0x100 else if (yaw.value < 0) result.flags |= 0x80 else if (yaw.value > 0) result.flags |= 0x40;
        return result;
    }
};

fn fraction(held: i32, amount: i32, elapsed: i32) i16 {
    return @truncate(@divTrunc(held *% amount, elapsed));
}

fn axis(entry: Entry, percent: i16) f32 {
    const value: f32 = @floatCast(@as(f64, @floatFromInt(entry.value)) * @as(f64, @as(f32, 0.0001953125)));
    if (entry.flags & unscaled != 0) return value;
    return @floatCast(@as(f64, @floatFromInt(percent)) * @as(f64, value) * @as(f64, @as(f32, 0.01)));
}

test "control packet has the 128-byte layout" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Packet));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Packet, "entries"));
}

test "default keyboard and mouse packets match 168 reference input frames" {
    var state: State = .{};
    var look: LookState = .{};
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..168) |i| {
        const now: u32 = 1000 + @as(u32, @intCast(i)) * 16;
        state.key(@intCast(i % 84 + 1), i < 84, now - 8);
        const packet = try state.sample(now, .{
            .dx = @as(i32, @intCast(i % 9)) - 4,
            .dy = @as(i32, @intCast(i % 7)) - 3,
            .buttons = @intCast(i % 8),
        });
        const control = look.control(&packet);
        const fields = [_]u32{ @bitCast(control.forward), @bitCast(control.strafe), @bitCast(control.turn), @bitCast(control.jump), @bitCast(control.look_up), @bitCast(control.look_down), control.flags };
        const look_fields = [_]i32{ @intFromBool(look.pitch_active), look.pitch_accumulator, @intFromBool(look.yaw_active), look.yaw_accumulator };
        hash.update(std.mem.asBytes(&packet));
        hash.update(std.mem.asBytes(&fields));
        hash.update(std.mem.asBytes(&look_fields));
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "77893a096504a0ff4b8bce2bcfa9e69c1290e02f3b69858ee4fd3dac26947a6f");
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}
