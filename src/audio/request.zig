//! A sound request: which resource, how loud, how important, and where.
//!
//! The argument in front of volume is priority, not pan. Only a request with
//! a position gets spatialised, and one game flag suppresses that even then.

const level = @import("../assets/level.zig");
const sound = @import("engine.zig");

pub const Request = struct {
    basename: []const u8,
    priority: ?i32 = null,
    volume: ?i32 = null,
    flags: ?u32 = null,
    sector: ?usize = null,
    position: ?level.Vec3 = null,
    source: ?usize = null,
    occlusion_applied: bool = false,
    listener: ?sound.Listener = null,
    mode: enum { once, loop, stop, update } = .once,
    delivered: bool = false,
};
