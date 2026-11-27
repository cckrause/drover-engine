//! What a projectile hit: the query that is filled in at the point of
//! contact.
//!
//! Several callbacks share one query buffer in the same frame, and some
//! fields are deliberately left untouched - a reader sees what the previous
//! caller left there.

const Vec3 = @import("../assets/level.zig").Vec3;
const Vec2 = @import("../assets/level.zig").Vec2;

pub const Projection = struct {
    words: [4]?u32 = @splat(null),

    pub fn invalidate(self: *Projection) void {
        self.words = @splat(null);
    }

    pub fn write(self: *Projection, direction: Vec2, origin: Vec2) void {
        self.words = .{
            @bitCast(direction.x),
            @bitCast(direction.z),
            @bitCast(origin.x),
            @bitCast(origin.z),
        };
    }

    pub fn values(self: Projection) ?struct { direction: Vec2, origin: Vec2 } {
        return .{
            .direction = .{
                .x = @bitCast(self.words[0] orelse return null),
                .z = @bitCast(self.words[1] orelse return null),
            },
            .origin = .{
                .x = @bitCast(self.words[2] orelse return null),
                .z = @bitCast(self.words[3] orelse return null),
            },
        };
    }
};

pub const Residue = struct {
    words: [4]?u32 = @splat(null),
    projection: Projection = .{},

    pub fn invalidate(self: *Residue) void {
        self.words = @splat(null);
        self.invalidateProjection();
    }

    pub fn invalidateProjection(self: *Residue) void {
        self.projection.invalidate();
    }

    pub fn playerHeight(self: *Residue, value: f32) void {
        self.words[0] = @bitCast(value);
    }

    pub fn playerPoint(self: *Residue, point: Vec3) void {
        self.words[1] = @bitCast(point.x);
        self.words[2] = @bitCast(point.y);
        self.words[3] = @bitCast(point.z);
    }

    pub fn height(self: Residue) !f32 {
        return @bitCast(self.words[0] orelse return error.UnresolvedOriginalProjectileContactStack);
    }

    pub fn position(self: Residue) !Vec3 {
        return .{
            .x = @bitCast(
                self.words[1] orelse return error.UnresolvedOriginalProjectileContactStack,
            ),
            .y = @bitCast(
                self.words[2] orelse return error.UnresolvedOriginalProjectileContactStack,
            ),
            .z = @bitCast(
                self.words[3] orelse return error.UnresolvedOriginalProjectileContactStack,
            ),
        };
    }
};
