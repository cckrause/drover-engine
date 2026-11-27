const std = @import("std");

const memory_profiles = @import("src/memory/profiles.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const macos = target.result.os.tag == .macos;
    const brew_prefix = if (target.result.cpu.arch == .aarch64) "/opt/homebrew" else "/usr/local";
    const sdl_prefix = b.option(
        []const u8,
        "sdl-prefix",
        "SDL2 installation prefix",
    ) orelse brew_prefix;

    const engine = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const options = b.addOptions();
    const memory_profile = b.option(
        memory_profiles.Profile,
        "memory-profile",
        "Fixed shipping memory profile",
    ) orelse .original_pc;

    options.addOption([]const u8, "memory_profile", @tagName(memory_profile));
    const mission = b.option(
        enum { hideout, town, train, canyon },
        "mission",
        "Skip the menus and start this campaign mission",
    );

    options.addOption(?[]const u8, "mission", if (mission) |selected| @tagName(selected) else null);
    engine.addOptions("build_options", options);
    addMemoryChecks(b, target, optimize, options);

    const asset_installer = b.createModule(.{
        .root_source_file = b.path("modules/asset_installer/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    engine.addImport("asset_installer", asset_installer);

    if (macos) {
        // The installer puts up its own window, which needs AppKit and a web view.
        engine.linkFramework("Cocoa", .{});
        engine.linkFramework("WebKit", .{});
        engine.linkSystemLibrary("objc", .{});
    }

    addSdl(b, engine, sdl_prefix);
    addEnet(b, engine);

    const exe = b.addExecutable(.{ .name = "drover", .root_module = engine });
    const run = if (macos) macosBundle(b, exe) else plainInstall(b, exe);

    run.step.dependOn(b.getInstallStep());

    if (b.args) |args| run.addArgs(args);

    b.step("run", "Run the game").dependOn(&run.step);

    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Run only tests whose names contain this text",
    );

    const filters = if (test_filter) |f| b.dupeStrings(&.{f}) else &.{};

    const tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });

    const test_step = b.step("test", "Run the engine tests");

    tests.root_module.addOptions("build_options", options);
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const installer_tests = b.addTest(.{ .root_module = asset_installer });
    const run_installer_tests = b.addRunArtifact(installer_tests);

    run_installer_tests.setCwd(b.path("."));
    b.step(
        "test-installer",
        "Test the asset installer against installed discs",
    ).dependOn(&run_installer_tests.step);

    test_step.dependOn(&run_installer_tests.step);

    const download_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("modules/asset_installer/src/download_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    b.step(
        "test-installer-download",
        "Download and validate the public demo",
    ).dependOn(&b.addRunArtifact(download_tests).step);

    if (macos) {
        const native_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("modules/asset_installer/src/native_test.zig"),
            .target = target,
            .optimize = optimize,
        }) });

        native_tests.root_module.linkFramework("Cocoa", .{});
        native_tests.root_module.linkFramework("WebKit", .{});
        native_tests.root_module.linkSystemLibrary("objc", .{});
        b.step(
            "test-installer-native",
            "Exercise the installer window and demo replay",
        ).dependOn(&b.addRunArtifact(native_tests).step);
    }

    // Audio goes through SDL's dummy device, so this needs no sound hardware.
    const audio_tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/audio_host_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });

    addSdl(b, audio_tests.root_module, sdl_prefix);
    audio_tests.root_module.addOptions("build_options", options);
    b.step(
        "test-audio",
        "Play game audio through SDL's dummy device",
    ).dependOn(&b.addRunArtifact(audio_tests).step);

    const network_step = b.step(
        "test-network",
        "Run two sessions against each other (opens local UDP ports)",
    );

    const network_tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/network_host_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });

    addEnet(b, network_tests.root_module);
    network_tests.root_module.addOptions("build_options", options);
    network_step.dependOn(&b.addRunArtifact(network_tests).step);

    // A host and a joining game in one process; the engine tests its root
    // imports pull in run under `test`.
    const join_tests = b.addTest(.{ .filters = b.dupeStrings(&.{
        test_filter orelse "two games on local UDP",
    }), .root_module = b.createModule(.{
        .root_source_file = b.path("src/network_join_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });

    addEnet(b, join_tests.root_module);
    join_tests.root_module.addOptions("build_options", options);
    network_step.dependOn(&b.addRunArtifact(join_tests).step);
}

fn addMemoryChecks(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) void {
    const check = b.addObject(.{ .name = "memory-check", .root_module = b.createModule(.{
        .root_source_file = b.path("src/memory_check.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    check.root_module.addOptions("build_options", options);
    b.step(
        "check-memory",
        "Check the target's memory layout without SDL or execution",
    ).dependOn(&check.step);

    const report = b.addExecutable(.{ .name = "memory-report", .root_module = b.createModule(.{
        .root_source_file = b.path("src/memory_report.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    report.root_module.addOptions("build_options", options);
    b.step(
        "memory-report",
        "Print the selected profile and target-sized storage accounting",
    ).dependOn(&b.addRunArtifact(report).step);
}

fn addSdl(b: *std.Build, module: *std.Build.Module, prefix: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/SDL2", .{prefix}) });
    module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    module.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    module.linkSystemLibrary("SDL2", .{ .use_pkg_config = .no });
}

/// ENet is compiled into the program rather than linked as a library, so the
/// network driver has no runtime dependency to install.
fn addEnet(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/enet"));
    module.addCSourceFile(.{ .file = b.path("vendor/enet/enet.c") });

    if (module.resolved_target.?.result.os.tag == .windows) {
        module.linkSystemLibrary("ws2_32", .{});
        module.linkSystemLibrary("winmm", .{});
    }
}

fn plainInstall(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    b.installArtifact(exe);

    return b.addRunArtifact(exe);
}

/// macOS wants an application bundle, otherwise the window has no menu bar and
/// the installer's web view refuses to open.
fn macosBundle(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const contents = "Drover.app/Contents";
    const install_exe = b.addInstallArtifact(
        exe,
        .{ .dest_dir = .{ .override = .{ .custom = contents ++ "/MacOS" } } },
    );

    b.getInstallStep().dependOn(&install_exe.step);
    const plist = b.addWriteFiles().add("Info.plist",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key><string>drover</string>
        \\  <key>CFBundleIdentifier</key><string>local.drover.engine</string>
        \\  <key>CFBundleName</key><string>Drover</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\</dict>
        \\</plist>
        \\
    );

    b.getInstallStep().dependOn(&b.addInstallFile(plist, contents ++ "/Info.plist").step);

    return b.addSystemCommand(&.{b.getInstallPath(.{ .custom = contents ++ "/MacOS" }, "drover")});
}
