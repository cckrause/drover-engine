const std = @import("std");
const Store = @import("store.zig").Store;
const media = @import("media.zig");
test "demo extraction and persistent launch state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const exe = std.Io.Dir.cwd().readFileAlloc(io, "bin/outdemo_v2.exe", a, .limited(media.demo_size + 1)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var store = try Store.init(a, io, path);
    defer store.deinit();
    try std.testing.expect(!try store.installed(.demo));
    try std.testing.expect(!try store.installed(.retail));
    try store.installDemo(exe);
    try std.testing.expect(try store.installed(.demo));
    try std.testing.expect(!try store.installed(.retail));
    const lab = try tmp.dir.readFileAlloc(io, "demo/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024));
    defer a.free(lab);
    try media.validateLab(lab);
    try std.testing.expectEqualStrings("79223e21e9562741240c8d4901dcefb35134af6d8c0a9b04568eff9530fc1248", &media.hash(lab));
    // A damaged install must never suppress the installer on a later launch.
    try tmp.dir.writeFile(io, .{ .sub_path = "demo/OUTLAWS_CD1/OUTLAWS/START.SAN", .data = "truncated" });
    try std.testing.expect(!try store.installed(.demo));
    try std.testing.expectError(error.DemoIntegrityCheckFailed, store.installDemo("MZ"));
    try store.installDemo(exe);
    try std.testing.expect(try store.installed(.demo));
}

test "discs publish only after both are installed and survive a failed demo install" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const first = "bin/Outlaws_CD1/OUTLAWS_CD1.mdf";
    const second = "bin/Outlaws_CD2/OUTLAWS_CD2.mdf";
    std.Io.Dir.cwd().access(io, first, .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, second, .{}) catch return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var store = try Store.init(a, io, path);
    defer store.deinit();
    try std.testing.expectEqual(Store.ImportResult.need_disc_1, try store.importFile(second));
    try std.testing.expect(!try store.installed(.retail));
    try std.testing.expectError(error.UnsupportedDiscFormat, store.importFile("unsupported.cue"));
    try std.testing.expectEqual(Store.ImportResult.complete, try store.importFile(first));
    try std.testing.expect(try store.installed(.retail));
    try std.testing.expect(!try store.installed(.demo));
    try std.testing.expectError(error.DemoIntegrityCheckFailed, store.installDemo("not a demo"));
    try std.testing.expect(try store.installed(.retail));
    const data = try tmp.dir.readFileAlloc(io, "retail/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024));
    defer a.free(data);
    try std.testing.expectEqualStrings("978b5d6ec53fc0b3d83f65cd32d3e5fbac2ed7dd6e45352f61bb67ce89c2dfc0", &media.hash(data));
}
