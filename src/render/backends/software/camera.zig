//! The camera: yaw, pitch and the trigonometric tables the renderer indexes
//! with 14-bit angles.
//!
//! The tables are built from a constant that is very slightly off pi/8192,
//! which leaves small errors at the cardinal angles. Those errors are part
//! of how the world lines up and must not be "fixed".

const std = @import("std");

pub const Vec2 = struct { x: f32, z: f32 };

pub const Angles = struct {
    cosine: [4097]f32,
    tangent: [8193]f32,

    pub fn init() Angles {
        var result: Angles = undefined;
        const step: f64 = @bitCast(@as(u64, 0x3f3921fb3fa6defc));
        for (&result.cosine, 0..) |*value, i| value.* = @floatCast(@cos(@as(f64, @floatFromInt(i)) * step));
        for (&result.tangent, 0..) |*value, i| value.* = @floatCast(@tan(@as(f64, @floatFromInt(i)) * step));
        return result;
    }

    pub fn sinCos(self: *const Angles, angle: i16) struct { sin: f32, cos: f32 } {
        const a: usize = @as(u16, @bitCast(angle)) & 0x3fff;
        return switch (a >> 12) {
            0 => .{ .sin = self.cosine[4096 - a], .cos = self.cosine[a] },
            1 => .{ .sin = self.cosine[a - 4096], .cos = -self.cosine[8192 - a] },
            2 => .{ .sin = -self.cosine[12288 - a], .cos = -self.cosine[a - 8192] },
            3 => .{ .sin = -self.cosine[a - 12288], .cos = self.cosine[16384 - a] },
            else => unreachable,
        };
    }

    pub fn tan(self: *const Angles, angle: i16) f32 {
        const a: usize = @as(u16, @bitCast(angle)) & 0x3fff;
        return self.tangent[if (a < 8192) a else a - 8192];
    }
};

pub const View = struct {
    width: i32,
    height: i32,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    yaw: i16 = 0,
    pitch: i16 = 0,
    sin_yaw: f32 = 0,
    negative_sin_yaw: f32 = 0,
    cos_yaw: f32 = 0,
    translation_x: f32 = 0,
    translation_z: f32 = 0,
    focal: f32,
    inv_focal: f32,
    tan_half_fov: f32,
    cot_half_fov: f32,
    center_x: i32,
    center_y: i32,
    horizon: i32,
    center_x_f: f32,
    horizon_f: f32,
    model_clip_top: f32 = 0,
    model_clip_bottom: f32 = 0,
    left: i32 = 0,
    right: i32,
    top: i32 = 0,
    bottom: i32,
    reciprocal_x: []f32,
    ray_x: []f32,
    row_reciprocal: []f32,
    sky_angle: []i32,
    sky_scale: f32,
    parallax_x: f32 = 1024,
    parallax_y: f32 = 1024,
    sky_yaw: f32 = 0,
    sky_pitch: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, angles: *const Angles, width: i32, height: i32) !View {
        return initFov(allocator, angles, width, height, 0x1000);
    }

    pub fn initFov(allocator: std.mem.Allocator, angles: *const Angles, width: i32, height: i32, field_of_view: i16) !View {
        if (width < 2 or height < 2 or width > 32767 or height > 32767) return error.InvalidViewSize;
        if (field_of_view < 2 or field_of_view > 0x2000) return error.InvalidFieldOfView;
        const reciprocal_x = try allocator.alloc(f32, @intCast(width));
        errdefer allocator.free(reciprocal_x);
        const ray_x = try allocator.alloc(f32, @intCast(width));
        errdefer allocator.free(ray_x);
        const row_reciprocal = try allocator.alloc(f32, @intCast(height * 32));
        errdefer allocator.free(row_reciprocal);
        const sky_angle = try allocator.alloc(i32, @intCast(width));
        errdefer allocator.free(sky_angle);
        const center_x = @divTrunc(width, 2);
        const center_y = @divTrunc(height, 2);
        const tangent = angles.tan(@divTrunc(field_of_view, 2));
        const focal: f32 = @floatCast(@as(f64, @floatFromInt(center_x)) / @as(f64, tangent));
        for (reciprocal_x, ray_x, 0..) |*reciprocal, *ray, i| {
            const delta: f64 = @floatFromInt(@as(i32, @intCast(i)) - center_x);
            reciprocal.* = if (delta == 0) focal else @floatCast(@as(f64, focal) / delta);
            ray.* = @floatCast(delta / @as(f64, focal));
        }
        for (row_reciprocal, 0..) |*reciprocal, index| {
            const y = @as(i32, @intCast(index)) - height * 16;
            reciprocal.* = if (y == center_y) 1.0 else @floatCast(1.0 / @as(f64, @floatFromInt(y - center_y)));
        }
        var view = View{
            .width = width,
            .height = height,
            .focal = focal,
            .inv_focal = @floatCast(1.0 / @as(f64, focal)),
            .tan_half_fov = tangent,
            .cot_half_fov = @floatCast(1.0 / @as(f64, tangent)),
            .center_x = center_x,
            .center_y = center_y,
            .horizon = center_y,
            .center_x_f = @floatFromInt(center_x),
            .horizon_f = @floatFromInt(center_y),
            .right = width - 1,
            .bottom = height - 1,
            .reciprocal_x = reciprocal_x,
            .ray_x = ray_x,
            .row_reciprocal = row_reciprocal,
            .sky_angle = sky_angle,
            .sky_scale = @floatCast(1.0 / (@as(f64, @floatFromInt(width)) * 0.003125)),
        };
        view.setParallax(1024, 1024);
        view.setPose(angles, 0, 0, 0, 0, 0);
        return view;
    }

    pub fn deinit(self: View, allocator: std.mem.Allocator) void {
        allocator.free(self.reciprocal_x);
        allocator.free(self.ray_x);
        allocator.free(self.row_reciprocal);
        allocator.free(self.sky_angle);
    }

    pub fn setParallax(self: *View, horizontal: f32, vertical: f32) void {
        self.parallax_x = horizontal;
        self.parallax_y = vertical;
        const turns: f64 = @bitCast(@as(u64, 0x3fc45f306dcc48b9));
        for (self.sky_angle, 0..) |*offset, index| {
            const delta: f64 = @floatFromInt(@as(i32, @intCast(index)) - self.center_x);
            const angle: i32 = @intFromFloat(std.math.atan(delta / @as(f64, self.focal)) * turns * 16384.0);
            const short: i16 = @truncate(angle);
            const scaled: f32 = @floatCast(@as(f64, @floatFromInt(@as(i32, short) << 2)) * 0x1p-16 * @as(f64, horizontal));
            offset.* = nearestInteger(scaled * 65536.0);
        }
    }

    pub fn setPose(self: *View, angles: *const Angles, x: f32, y: f32, z: f32, yaw: i16, pitch: i16) void {
        self.x = x;
        self.y = y;
        self.z = z;
        self.yaw = yaw;
        self.pitch = pitch;
        const rotation = angles.sinCos(0 -% yaw);
        self.sin_yaw = rotation.sin;
        self.negative_sin_yaw = -rotation.sin;
        self.cos_yaw = rotation.cos;
        const pitch_offset: f32 = @floatCast(@as(f64, angles.tan(pitch)) * @as(f64, self.focal));
        self.horizon_f = @floatCast(@as(f64, angles.tan(pitch)) * @as(f64, self.focal) + @as(f64, @floatFromInt(self.center_y)));
        self.horizon = self.center_y + nearestInteger(pitch_offset);
        const viewport_height = self.bottom - self.top + 1;
        const vertical_offset = @divTrunc(self.height - viewport_height, 2) - self.top;
        const half: f32 = @floatCast(@as(f64, @floatFromInt(viewport_height)) * 0.25 * 2.0 + @as(f64, @floatFromInt(vertical_offset)));
        self.model_clip_top = @floatCast((-1.0 - (@as(f64, pitch_offset) + half)) / @as(f64, self.focal));
        self.model_clip_bottom = @floatCast((@as(f64, half) - pitch_offset) / @as(f64, self.focal));
        self.translation_x = @floatCast(@as(f64, rotation.cos) * -@as(f64, x) + @as(f64, rotation.sin) * -@as(f64, z));
        self.translation_z = @floatCast(@as(f64, rotation.cos) * -@as(f64, z) + -@as(f64, rotation.sin) * -@as(f64, x));
        self.sky_yaw = @floatCast(@as(f64, @floatFromInt(@as(i32, yaw) << 2)) * 0x1p-16 * @as(f64, self.parallax_x));
        self.sky_pitch = @floatCast(@as(f64, @floatFromInt(100 - self.center_y)) - @as(f64, @floatFromInt(@as(i32, pitch) << 2)) * 0x1p-16 * @as(f64, self.parallax_y));
    }
};

fn nearestInteger(value: f32) i32 {
    const lower = @floor(value);
    const integer: i32 = @intFromFloat(lower);
    const fraction = value - lower;
    return integer + @as(i32, if (fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)) 1 else 0);
}

test "angle lookup wraps and retains the reference approximate cardinal angle" {
    const angles = Angles.init();
    const zero = angles.sinCos(0);
    try std.testing.expectEqual(@as(f32, 1), zero.cos);
    try std.testing.expect(zero.sin > 0 and zero.sin < 0.000002);
    try std.testing.expectEqual(zero, angles.sinCos(0x4000));
    const quarter = angles.sinCos(0x1000);
    try std.testing.expectEqual(@as(f32, 1), quarter.sin);
    try std.testing.expectEqual(-zero.sin, quarter.cos);
}

test "trigonometric tables match the reference" {
    const angles = Angles.init();
    var actual: [32]u8 = undefined;
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(std.mem.asBytes(&angles.cosine), &actual, .{});
    _ = try std.fmt.hexToBytes(&expected, "b9f722bd79fe400d44b74d82facc5120e4fe060739bd61fa6054834b51f46948");
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    std.crypto.hash.sha2.Sha256.hash(std.mem.asBytes(&angles.tangent), &actual, .{});
    _ = try std.fmt.hexToBytes(&expected, "b373f628f6a046a385b2acd66ba4f4564327d012e30e88e2293af57448400f12");
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
