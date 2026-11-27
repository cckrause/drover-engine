//! The frame drawing storage tests open sessions with. Tests run one at a
//! time, and a frame holds the storage only while it draws, so one is enough.

const world = @import("backends/software/world.zig");

var storage: world.Workspace = .{};

pub fn get() *world.Workspace {
    return &storage;
}
