const std = @import("std");
pub fn build(b: *std.Build) void {
    const module = b.addModule("asset_installer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Test installer without the engine").dependOn(&b.addRunArtifact(tests).step);
}
