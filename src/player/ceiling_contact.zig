//! Being pushed by a moving ceiling: the contact and its bounce.
//!
//! The speed comes from the ceiling's live velocity and the retained slope
//! is tested rather than the current high flag. The bounce reuses the X
//! contribution for Y and Z as well, which is deliberate.

const Vec3 = @import("../assets/level.zig").Vec3;
const Slope = @import("../render/scene.zig").Slope;

pub fn bounce(velocity: *Vec3, slope: ?Slope, elasticity: f32, speed: f32) f32 {
    if (slope) |s| {
        const squared = f(@as(f64, s.coeff_x) * s.coeff_x + @as(f64, s.coeff_z) * s.coeff_z + 1);
        const inverse = 1.0 / -@as(f64, f(@sqrt(@as(f64, squared))));
        const nx = f(@as(f64, s.coeff_x) * inverse);
        const nz = f(@as(f64, s.coeff_z) * inverse);
        const dot = @as(
            f64,
            velocity.x,
        ) * nx + ((@as(f64, velocity.y) - speed) * inverse + @as(f64, velocity.z) * nz);

        const stored_dot = f(dot);
        const projected_x = dot * nx;
        const full_bounce = -(@as(f64, elasticity) * f(projected_x));
        const bounce_x = f(full_bounce);

        velocity.x = f(full_bounce + f(@as(f64, velocity.x) - projected_x));
        velocity.y = f(
            @as(f64, speed) - ((@as(f64, velocity.y) - inverse * stored_dot) + bounce_x),
        );

        velocity.z = f((@as(f64, velocity.z) - @as(f64, stored_dot) * nz) + bounce_x);
        return @abs(stored_dot);
    }

    velocity.y = f(@as(f64, speed) - (@as(f64, velocity.y) - speed) * elasticity);

    return @abs(f(@as(f64, velocity.y) - speed));
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
