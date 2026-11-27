//! Isolated asset installer. std-only storage/media; macOS presentation uses
//! system AppKit/WebKit from Zig, inside the caller's existing window.
pub const Store = @import("store.zig").Store;
pub const Kind = @import("store.zig").Kind;
pub const media = @import("media.zig");
pub const macos = @import("platform/macos.zig");

test {
    _ = @import("media.zig");
    _ = @import("tests.zig");
}
