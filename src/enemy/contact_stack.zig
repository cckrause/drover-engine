//! The shared buffer collision callbacks pass their contact through.
//!
//! Callbacks at different depths use the same frame, so later fields alias
//! earlier ones. This is observable - a callback can read what a deeper one
//! left - and the layout is therefore fixed.

const collision = @import("../player/collision.zig");
const Residue = @import("../projectile/contact.zig").Residue;
const Vec3 = @import("../assets/level.zig").Vec3;

pub const Enemy = struct {
    residue: *Residue,
    bias: u8,
    successor_present: bool = true,
    now: u32 = 0,

    pub const HiddenSound = enum {
        null_handle,
        unknown_runtime,
        exhausted,
        driver_disabled,
        driver_enabled,
    };

    pub fn init(residue: *Residue, native: @import("../script/cmm.zig").Native) Enemy {
        return .{ .residue = residue, .bias = switch (native) {
            .enemy => 0x14,
            .farmer => 0x20,
            .chicken, .dynamite, .marshal, .civilian => 0x1c,
            .slim, .bob => 0x28,
            .sanchez => 0x54,
            else => unreachable,
        } };
    }

    pub fn write(self: Enemy, offset: usize, value: ?u32) void {
        for ([_]usize{ 0, 12, 16, 20 }, 0..) |delta, index| {
            if (offset == self.bias + delta) self.residue.words[index] = value;
        }
    }

    pub fn enter(self: Enemy, return_address: u32) void {
        self.write(0x68, return_address);
        self.write(0x18, 0);
        self.write(0x10, null);
        self.write(0x14, null);
    }

    pub fn frame(self: Enemy, value: *const @import("../assets/nwx.zig").Frame) void {
        self.frameAt(0x1c, value);
    }

    pub fn frameAt(
        self: Enemy,
        offset: i32,
        value: *const @import("../assets/nwx.zig").Frame,
    ) void {
        var words: [19]?u32 = @splat(null);

        words[0] = @bitCast(value.offset_x);
        words[1] = @bitCast(value.offset_y);
        words[2] = @intCast(value.parts.len);

        for (value.parts, 0..) |part, index| {
            const base = 3 + index * 8;

            if (base >= words.len) break;

            words[base + 1] = @bitCast(part.raw_x);
            words[base + 2] = @bitCast(part.raw_y);
            words[base + 3] = @bitCast(part.offset_x);
            words[base + 4] = @bitCast(part.offset_y);
            words[base + 5] = @bitCast(part.width);
            words[base + 6] = @bitCast(part.height);
            words[base + 7] = part.flags;
        }

        for (words, 0..) |word, index| {
            const destination = offset + @as(i32, @intCast(index)) * 4;
            if (destination >= 0) self.write(@intCast(destination), word);
        }
    }

    pub fn damp(self: Enemy, ceiling: f32) void {
        if (self.bias != 0x54) return;
        self.residue.words[1] = null;
        self.residue.words[2] = if (self.successor_present) null else 0;
        self.residue.words[3] = @bitCast(ceiling);
    }

    pub fn specialSelect(self: Enemy) void {
        self.write(0x14, self.now);
        self.write(0x68, 0x00422ae8);
    }

    pub fn commit(
        self: Enemy,
        old: Vec3,
        position: Vec3,
        sector_changed: bool,
        sector_events: bool,
    ) void {
        self.write(0x64, 0x76);
        self.write(0x68, null);
        if (!sector_changed and old.x == position.x and old.y == position.y and old.z == position.z) return;

        self.write(0x54, @bitCast(position.x));
        self.write(0x60, null);
        self.write(0x3c, null);
        if (!sector_changed or !sector_events) return;

        self.write(0x14, null);
        self.write(0x18, null);
        self.write(0x1c, 0x7d6);
        self.write(0x20, 4);
        self.write(0x24, 0);
        self.write(0x28, 0);
        self.write(0x2c, 0x004c128e);
        self.write(0x30, null);
        self.write(0x34, null);
        self.write(0x38, 4);
    }

    pub fn death(self: Enemy, costume_name: []const u8, original: Vec3, drop: ?Vec3) void {
        if (drop) |point| {
            self.write(0x54, @bitCast(@as(f32, @floatCast(@as(f64, original.x) + 1.5))));
            self.write(0x60, @bitCast(point.x));
            self.write(0x64, @bitCast(original.y));
            self.write(0x68, @bitCast(point.z));
        }

        var bytes: [32]u8 = @splat(0);

        if (costume_name.len == 0) {
            if (self.bias == 0x14) if (self.residue.words[0]) |old| {
                self.residue.words[0] = old & 0xffffff00;
            };
        } else {
            const count = @min(bytes.len, costume_name.len);
            @memcpy(bytes[0..count], costume_name[0..count]);

            for (0..8) |index| self.write(
                0x14 + index * 4,
                @import("std").mem.readInt(u32, bytes[index * 4 ..][0..4], .little),
            );
        }

        self.write(0x34, 0x00422660);
        self.write(0x38, null);
        self.write(0x3c, null);
    }

    pub fn broadcast(self: Enemy, position: Vec3, height: f32) void {
        self.write(0x1c, @bitCast(position.x));
        self.write(0x28, @bitCast(@as(f32, @floatCast(@as(f64, height) + position.y))));
        self.write(0x20, @bitCast(position.z));
        self.write(0x24, 0x42480000);
    }

    pub fn hiddenSound(residue: *Residue, outcome: HiddenSound) void {
        switch (outcome) {
            .null_handle => {},
            .unknown_runtime => residue.words = @splat(null),
            .exhausted => residue.words[0] = null,
            .driver_disabled => residue.words = .{ null, 0x027f0e7f, null, 0x00489d71 },
            .driver_enabled => residue.words = .{ null, 1, 1, null },
        }
    }

    pub fn hiddenConnectivity(residue: *Residue, sectors: []const u16) void {
        for ([_]usize{ 428, 434, 436, 438 }, 0..) |first, index| {
            if (first >= sectors.len) continue;

            if (first + 1 < sectors.len) {
                residue.words[index] = @as(
                    u32,
                    sectors[first],
                ) | (@as(u32, sectors[first + 1]) << 16);
            } else if (residue.words[index]) |old| {
                residue.words[index] = (old & 0xffff0000) | sectors[first];
            }
        }
    }
};

pub const Caller = enum { blood, bubble, fragment, scheduler, knife, explosive };

pub const Tracking = struct {
    residue: *Residue,
    caller: Caller,

    pub fn begin(self: Tracking, velocity: Vec3, floor_limit: f32) void {
        if (self.caller == .bubble) {
            self.residue.words = .{
                0x0051be40,
                @bitCast(floor_limit),
                @bitCast(velocity.x),
                @bitCast(velocity.y),
            };
        }
    }

    pub fn observer(self: *Tracking) collision.QueryObserver {
        return .{ .context = self, .emit = observe };
    }

    fn observe(raw: *anyopaque, event: collision.QueryEvent) void {
        const self: *Tracking = @ptrCast(@alignCast(raw));

        switch (event) {
            .query => |q| switch (self.caller) {
                .blood => {
                    self.residue.words = .{
                        @bitCast(q.height),
                        @bitCast(q.delta.z),
                        @bitCast(q.step),
                        @bitCast(q.drop),
                    };
                },
                .fragment => {
                    if (q.moving) self.residue.words[0] = @bitCast(q.initial_velocity.z);
                    self.residue.words[1] = @bitCast(q.radius);
                    self.residue.words[2] = @bitCast(q.position.y);
                    self.residue.words[3] = @bitCast(q.height);
                },
                .bubble, .scheduler, .knife, .explosive => {},
            },
            .subdivision => |step| if (self.caller == .scheduler) {
                self.residue.words[1] = @bitCast(step.reciprocal);
                self.residue.words[3] = @bitCast(step.rounded);
            },
            .halted => |halted| if (self.caller == .scheduler) {
                self.residue.words[0] = @intFromBool(halted);
            },
            .contact => |contact| switch (self.caller) {
                .knife => if (contact.height) |height| {
                    self.residue.words[0] = @bitCast(height);
                },
                .explosive => {
                    self.residue.words[0] = switch (contact.kind) {
                        .none => 0,
                        .wall => 1,
                        .actor => 2,
                        .slope => 3,
                    };

                    if (contact.actor_written) self.residue.words[1] = if (contact.actor == null) 0 else null;

                    if (contact.direction) |direction| {
                        self.residue.words[2] = @bitCast(direction.x);
                        self.residue.words[3] = @bitCast(direction.z);
                    }
                },
                else => {},
            },
        }
    }
};
