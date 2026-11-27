//! Opt-in integration check: the real Internet Archive download, with std TLS,
//! extracted and validated in temporary storage without the game or AppKit.
const std = @import("std");
const Store = @import("store.zig").Store;

test "download the verified Internet Archive demo" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var store = try Store.init(a, io, path);
    defer store.deinit();

    try store.downloadDemo();

    try std.testing.expect(try store.installed(.demo));
    try std.testing.expect(!try store.installed(.retail));
}
