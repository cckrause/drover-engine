//! Thrown weapons: the arc that reaches a target, and the velocity that
//! flies it.
//!
//! Both arc solutions are computed under a fixed gravity, and the cosine
//! table is inverted by a linear scan. A target closer than the minimum
//! throw distance is excluded rather than lobbed at.

const std = @import("std");
const Vec3 = @import("../assets/level.zig").Vec3;
const Angles = @import("../render/backends/software/camera.zig").Angles;
const perception = @import("perception.zig");

pub const Arc = struct { yaw: i16, low_pitch: i16, high_pitch: i16 };

pub fn solve(angles: *const Angles, start: Vec3, end: Vec3, speed: f32) !?Arc {
    const dx = f(@as(f64, end.x) - start.x);
    const dz = f(@as(f64, end.z) - start.z);
    const yaw = perception.angle(dx, dz);
    const horizontal_squared = f(@as(f64, dz) * dz + @as(f64, dx) * dx);
    if (!(speed > 0) or !(horizontal_squared > 0)) return error.InvalidEnemyBallisticInput;
    const horizontal = f(@sqrt(@as(f64, horizontal_squared)));
    const dy = f(@as(f64, end.y) - start.y);
    const speed_squared = f(@as(f64, speed) * speed);
    if (speed_squared < @as(f64, dy) * 60) return null;
    const a = f(@as(f64, speed_squared) * speed_squared * 4 * (@as(f64, dy) * dy + horizontal_squared));
    const b = f(@as(f64, horizontal_squared) * speed_squared * -4 * (@as(f64, dy) * -60 + speed_squared));
    const discriminant = f(@as(f64, b) * b + @as(f64, horizontal_squared) * horizontal_squared * 3600 * a * -4);
    if (discriminant < 0) return null;
    const inverse = 1.0 / (@as(f64, a) * 2);
    const root = @as(f64, f(@sqrt(@as(f64, discriminant)))) * inverse;
    const half_b = f(-(@as(f64, b) * inverse));
    const first_time = @as(f64, horizontal) / (@as(f64, f(@sqrt(@as(f64, f(root + half_b))))) * speed);
    const twice_y = f(@as(f64, dy) * 2);
    const first = f((@as(f64, twice_y) - first_time * first_time * -60) / (first_time * speed * 2));
    const second_time = @as(f64, horizontal) / (@as(f64, f(@sqrt(@as(f64, f(@as(f64, half_b) - f(root)))))) * speed);
    const second = f((@as(f64, twice_y) - second_time * second_time * -60) / (second_time * speed * 2));
    return .{ .yaw = yaw, .low_pitch = inverseSine(angles, first), .high_pitch = inverseSine(angles, second) };
}

pub fn velocity(angles: *const Angles, speed: f32, pitch: i16, yaw: i16) Vec3 {
    const horizontal = angles.sinCos(yaw);
    const vertical = angles.sinCos(pitch);
    const x = f(@as(f64, speed) * horizontal.sin);
    const z = f(@as(f64, speed) * horizontal.cos);
    return .{ .x = f(@as(f64, x) * vertical.cos), .y = f(@as(f64, speed) * vertical.sin), .z = f(@as(f64, z) * vertical.cos) };
}

fn inverseSine(angles: *const Angles, sine: f32) i16 {
    const negative = @as(u32, @bitCast(sine)) > 0x80000000;
    const value = if (negative) -sine else sine;
    var index: u16 = 0;
    while (index < 4096 and value < angles.cosine[index]) index += 1;
    return @intCast(if (negative) index + 0x3000 else 0x1000 - index);
}

fn f(value: f64) f32 {
    return @floatCast(value);
}

fn point(value: [3]u32) Vec3 {
    return .{ .x = @bitCast(value[0]), .y = @bitCast(value[1]), .z = @bitCast(value[2]) };
}

test "enemy thrown arcs and polar velocity match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/enemy-ballistics-reference.json", allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { start_bits: [3]u32, end_bits: [3]u32, speed_bits: u32, success: bool, angles: [3]i16 },
        velocities: []struct { pitch: i16, yaw: i16, speed_bits: u32, velocity_bits: [3]u32 },
    };
    const corpus = (try std.json.parseFromSlice(Corpus, allocator, bytes, .{})).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("e9c88d7e3d1a4b5bdabb36d503b9040f0ced42c55d3cf6813c63a9c695299a36", corpus.results_sha256);
    const angles = Angles.init();
    for (corpus.cases, 0..) |case, index| {
        errdefer std.debug.print("reference ballistics case {d}: {any}\n", .{ index, case });
        if (case.speed_bits == 0 or (case.start_bits[0] == case.end_bits[0] and case.start_bits[2] == case.end_bits[2])) {
            try std.testing.expectError(error.InvalidEnemyBallisticInput, solve(&angles, point(case.start_bits), point(case.end_bits), @bitCast(case.speed_bits)));
            continue;
        }
        const actual = try solve(&angles, point(case.start_bits), point(case.end_bits), @bitCast(case.speed_bits));
        try std.testing.expectEqual(case.success, actual != null);
        if (actual) |arc| try std.testing.expectEqual(case.angles, [3]i16{ arc.yaw, arc.low_pitch, arc.high_pitch });
    }
    for (corpus.velocities) |case| {
        const actual = velocity(&angles, @bitCast(case.speed_bits), case.pitch, case.yaw);
        try std.testing.expectEqual(case.velocity_bits, [3]u32{ @bitCast(actual.x), @bitCast(actual.y), @bitCast(actual.z) });
    }
}
