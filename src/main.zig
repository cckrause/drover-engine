//! Program entry: command line, window, audio device, the menu shell and
//! the main loop that drives menus, movies, levels and the network game.
//!
//! Everything here is host-side sequencing; the engine modules it calls do
//! the work. The level renderer and HUD are implemented for view box size
//! 14 only - other sizes keep that size. Options with no implementation log
//! a warning and leave the setting as it is, so an unfinished page never
//! stops the game.

const std = @import("std");

const lab = @import("assets/lab.zig");
const title = @import("game/title.zig");
const menu = @import("ui/menu.zig");
const Shell = @import("ui/shell.zig").Shell;
const campaign = @import("campaign.zig");
const Session = @import("render/session.zig").Session;
const build_options = @import("build_options");

const audio_runtime = @import("audio/runtime.zig");
const memory_limits = @import("memory/limits.zig");
const MemoryBudget = @import("platform/MemoryBudget.zig");
const asset_installer = @import("platform/asset_installer.zig");
const audio_platform = @import("platform/audio.zig");
const c_memory = @import("platform/c_memory.zig");
const drivers = @import("platform/drivers.zig");
const enet_driver = @import("platform/enet_driver.zig");
const memory_hooks = @import("platform/memory_hooks.zig");
const mission = @import("platform/mission.zig");
const mission_menu = @import("platform/mission_menu.zig");
const movie_platform = @import("platform/movie.zig");
const network_join = @import("platform/network_join.zig");
const network_lobby_platform = @import("platform/network_lobby.zig");
const network_menu_platform = @import("platform/network_menu.zig");
const options_platform = @import("platform/options.zig");
const patches = @import("platform/patches.zig");
const saved_game = @import("platform/saved_game.zig");
const platform = @import("platform/sdl.zig");
const settings_file = @import("platform/settings.zig");
const trigger_movie = @import("platform/trigger_movie.zig");
const world = @import("render/backends/software/world.zig");
const display_palette = @import("render/display_palette.zig");
const view_box = @import("render/view_box.zig");
const save_game = @import("save/game.zig");
const save_header = @import("save/header.zig");
const save_menu = @import("save/menu.zig");
const save_player_module = @import("save/player_module.zig");
const save_stream = @import("save/stream.zig");
const settings = @import("settings.zig");
const c = platform.c;

comptime {
    _ = @import("memory/layout.zig");
}

const RestoredClock = struct { host_time: u32, engine_time: u32 };

pub fn main(init: std.process.Init) !void {
    const capacity = memory_limits.heap_bytes;
    const backing = std.heap.page_allocator;
    const memory = blk: {
        const owner = try backing.create(MemoryBudget);
        errdefer backing.destroy(owner);

        // The budget only uses uncancelable futex operations from this static
        // I/O instance; those remain valid for foreign threads at process exit.
        owner.* = try MemoryBudget.init(
            backing,
            std.Io.Threaded.global_single_threaded.io(),
            capacity,
        );

        break :blk owner;
    };

    var release_reservation = true;
    defer if (release_reservation) {
        memory.deinit(backing);
        backing.destroy(memory);
    };

    // Some SDL implementations retain process globals after SDL_Quit.
    // Their callbacks and allocator owner must outlive library destructors.
    const hooks = try memory_hooks.install(memory.allocator());
    defer release_reservation = hooks.restore();

    var runtime_io = std.Io.Threaded.init(memory.allocator(), .{
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });

    defer runtime_io.deinit();

    var bounded = init;

    bounded.gpa = memory.allocator();
    bounded.io = runtime_io.io();

    run(bounded, memory) catch |err| {
        if (err == error.OutOfMemory or err == error.MemoryBudgetExceeded or c_memory.exhausted()) {
            const state = memory.stats();
            std.log.err("memory profile {s} exceeded: capacity {d} MiB, reserved {d} bytes, peak {d} bytes; fix residency or review the build profile", .{
                @tagName(
                    memory_limits.profile,
                ),
                state.capacity / (1024 * 1024),
                state.reserved,
                state.peak,
            });

            return error.MemoryBudgetExceeded;
        }

        return err;
    };

    try checkMemory(memory);
}

fn checkMemory(memory: *MemoryBudget) error{MemoryBudgetExceeded}!void {
    try memory.check();
    if (c_memory.exhausted()) return error.MemoryBudgetExceeded;
}

fn run(init: std.process.Init, memory: *MemoryBudget) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var data_path: []const u8 = title.current.default_data_path;
    var snapshot: ?[]const u8 = null;
    var headless = false;
    var frame_limit: ?usize = null;
    var initial_menu: menu.Kind = .main;
    var diagnostic_start: ?campaign.Difficulty = null;
    var movie_path: ?[]const u8 = null;
    var patch: patches.Level = .latest;
    var explicit_patch = false;
    var installer_requested = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--data")) {
            data_path = args.next() orelse return error.MissingDataPath;
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            snapshot = args.next() orelse return error.MissingSnapshotPath;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--menu")) {
            initial_menu = std.meta.stringToEnum(
                menu.Kind,
                args.next() orelse return error.MissingMenu,
            ) orelse return error.InvalidMenu;
        } else if (std.mem.eql(u8, arg, "--start")) {
            diagnostic_start = std.meta.stringToEnum(
                campaign.Difficulty,
                args.next() orelse return error.MissingDifficulty,
            ) orelse return error.InvalidDifficulty;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            frame_limit = try std.fmt.parseInt(
                usize,
                args.next() orelse return error.MissingFrameCount,
                10,
            );

            if (frame_limit.? == 0) return error.InvalidFrameCount;
        } else if (std.mem.eql(u8, arg, "--movie")) {
            movie_path = args.next() orelse return error.MissingMoviePath;
        } else if (std.mem.eql(u8, arg, "--patch")) {
            patch = try patches.Level.parse(args.next() orelse return error.MissingPatch);
            explicit_patch = true;
        } else if (std.mem.eql(u8, arg, "--installer")) {
            installer_requested = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("drover [--data DATA.LAB] [--patch none|1.1|2.0] [--snapshot frame.ppm] [--frames N]\n" ++
                "        [--menu main|difficulty] [--headless [--start good|bad|ugly]]\n" ++
                "        [--movie FILE.SAN [--headless --frames N]] [--installer]\n" ++
                "memory profile: {s}, {d} MiB heap (selected at build time)\n", .{
                @tagName(memory_limits.profile), memory_limits.heap_bytes / (1024 * 1024),
            });

            return;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }

    if (diagnostic_start != null and (!headless or initial_menu != .main)) return error.StartRequiresHeadlessMain;

    if (movie_path != null and (diagnostic_start != null or initial_menu != .main)) return error.IncompatibleMovieArguments;

    if (movie_path) |path| {
        const pixels = try init.gpa.alloc(u8, menu.width * menu.height);
        defer init.gpa.free(pixels);
        var palette: [256]u32 = @splat(0);

        if (headless) {
            palette = try movie_platform.renderFrames(
                init.gpa,
                init.io,
                path,
                frame_limit orelse 1,
                pixels,
            );
        } else {
            const window = try platform.Window.init(pixels, menu.width, menu.height);
            defer window.deinit();
            var frames: usize = 0;

            _ = try movie_platform.play(
                init.gpa,
                init.io,
                path,
                window,
                pixels,
                &palette,
                &frames,
                frame_limit,
            );
        }

        if (snapshot) |path_out| try writeSnapshot(init, path_out, pixels, &palette);
        return;
    }

    const pixels = try init.gpa.alloc(u8, menu.width * menu.height);
    defer init.gpa.free(pixels);

    @memset(pixels, 0);

    var owned_data_path: ?[]u8 = null;
    defer if (owned_data_path) |path| init.gpa.free(path);
    var startup_window: ?platform.Window = null;
    defer if (startup_window) |window| window.deinit();
    const missing_data = blk: {
        std.Io.Dir.cwd().access(init.io, data_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk true,
            else => return err,
        };

        break :blk false;
    };

    if (!headless and (installer_requested or missing_data)) {
        if (!installer_requested) owned_data_path = try asset_installer.bundledPath(
            init.gpa,
            init.io,
        );

        if (owned_data_path == null) {
            startup_window = try platform.Window.init(pixels, menu.width, menu.height);
            const selected = (try asset_installer.run(init, &startup_window.?)) orelse return;
            owned_data_path = selected.path;
        }

        data_path = owned_data_path.?;

        if (!explicit_patch) patch = .none;
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        data_path,
        init.gpa,
        .limited(64 * 1024 * 1024),
    ) catch |err| {
        std.log.err("cannot read {s}: {s}", .{ data_path, @errorName(err) });
        return err;
    };

    defer init.gpa.free(bytes);
    var patch_archives = try patches.Patches.load(init.gpa, init.io, patch);
    defer patch_archives.deinit(init.gpa);
    var archive = try lab.Archive.init(bytes);

    archive.front = patch_archives.front();

    var mounts = mission.Mounts.init(init.gpa, data_path, archive);
    defer mounts.deinit();
    var shell = Shell{ .screen = try menu.Menu.initKind(init.gpa, archive, initial_menu) };
    defer shell.deinit(init.gpa);
    var palette = try shell.screen.render(pixels, 0);
    // Frame drawing storage for every level, reserved once here.
    const render_workspace = try world.Workspace.create(init.gpa);
    defer render_workspace.destroy(init.gpa);
    var session: ?*Session = null;
    defer if (session) |loaded| loaded.deinit(init.gpa);

    if (headless) {
        if (diagnostic_start) |difficulty| {
            try shell.accept(init.gpa, archive, 0, 0, .{});
            const index: i32 = switch (difficulty) {
                .good => 0,
                .bad => 1,
                .ugly => 2,
            };

            shell.screen.select(index, 0);
            palette = try shell.screen.render(pixels, 0);
            try shell.accept(init.gpa, archive, index, 0, .{});

            if (build_options.mission) |name| try mission.select(&shell.startup.?, name);

            const diagnostic_level = try shell.startup.?.levelForDiagnostics();
            try mounts.selectDisc(init.io, diagnostic_level.disc);

            session = try Session.openWithState(
                init.gpa,
                render_workspace,
                init.io,
                mounts.path(),
                mounts.system(),
                &shell.startup.?,
                0,
                .{ .base_palette = palette },
            );

            palette = try session.?.render(pixels, 0);

            reportStartup(&shell.startup.?, session.?);
        }

        if (snapshot) |path| try writeSnapshot(init, path, pixels, &palette);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pixels, &hash, .{});

        if (session) |loaded| {
            std.debug.print(
                "Rendered level {s}: {d}x{d}, indexed pixels SHA256 {x}\n",
                .{ loaded.level_name, menu.width, menu.height, &hash },
            );
        } else {
            std.debug.print(
                "Rendered {s} menu: {d}x{d}, indexed pixels SHA256 {x}\n",
                .{ @tagName(shell.screen.kind), menu.width, menu.height, &hash },
            );
        }

        return;
    }

    if (startup_window == null) startup_window = try platform.Window.init(
        pixels,
        menu.width,
        menu.height,
    );

    var window = startup_window.?;

    var store = settings.Store.init(init.gpa);
    defer store.deinit();

    try settings_file.load(init.gpa, init.io, &store);

    var view = view_box.State{ .index = try view_box.load(&store) };
    var display = display_palette.Display{};

    if (!try display_palette.load(&store, &display))
        std.log.warn(
            "\"Palette Tinting\" N (OTHER OPTIONS' TINTING off) is not implemented; tinting stays on",
            .{},
        );

    try settings_file.save(init.gpa, init.io, &store);

    _ = display.setBrightness(0xff);

    window.display = &display;

    const audio = try audio_runtime.Runtime.open(init.gpa, init.io, data_path, archive);
    defer audio.deinit();

    const audio_device = try audio_platform.Device.open(init.gpa);
    defer audio_device.deinit();

    var player_input = platform.PlayerInput{};
    defer player_input.deinit();
    var network_opener: enet_driver.Opener = .{ .allocator = init.gpa };
    var join_selection: network_menu_platform.JoinSelection = undefined;
    defer if (shell.startup) |*startup| startup.router.close();
    var persistent_state = Session.PersistentState{ .base_palette = palette };
    var engine_clock_offset: u32 = 0;

    _ = c.SDL_GetMouseState(&shell.screen.mouse_x, &shell.screen.mouse_y);
    shell.screen.mouse_x = std.math.clamp(shell.screen.mouse_x, 0, menu.width - 1);
    shell.screen.mouse_y = std.math.clamp(shell.screen.mouse_y, 0, menu.height - 1);
    shell.screen.selected_at = c.SDL_GetTicks();

    var running = true;
    var frames: usize = 0;
    var menu_requested = false;

    main_loop: while (running) {
        try checkMemory(memory);
        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event) != 0) {
            const now = c.SDL_GetTicks();

            if (session != null and mission_menu.opens(&event)) {
                menu_requested = true;
                continue;
            }

            if (session != null) try player_input.event(&event);

            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (session != null) continue;

                    if (event.key.repeat != 0) continue;

                    switch (event.key.keysym.sym) {
                        c.SDLK_TAB => shell.screen.tab(
                            event.key.keysym.mod & c.KMOD_SHIFT != 0,
                            now,
                        ),
                        c.SDLK_UP => shell.screen.arrow(.up, now),
                        c.SDLK_DOWN => shell.screen.arrow(.down, now),
                        c.SDLK_LEFT => shell.screen.arrow(.left, now),
                        c.SDLK_RIGHT => shell.screen.arrow(.right, now),
                        c.SDLK_RETURN, c.SDLK_KP_ENTER => shell.screen.enter(),
                        c.SDLK_ESCAPE => shell.screen.escape(),
                        else => {},
                    }
                },
                else => {},
            }
        }

        if (!running) break;

        try audio_device.sync(audio);

        if (session) |loaded| {
            if (loaded.campaign_completion_requested) {
                loaded.campaign_completion_requested = false;

                const startup = &shell.startup.?;
                var carry = try loaded.campaignState(init.gpa);
                defer carry.deinit();

                persistent_state = loaded.persistentState();
                engine_clock_offset = player_input.last_sample -% loaded.animation_time;

                player_input.suspendMenu();
                try loaded.closeSounds();
                try audio_device.sync(audio);
                loaded.deinit(init.gpa);

                session = null;
                try startup.finishLevel();
                const story_result = try playCampaignMovies(
                    init.gpa,
                    init.io,
                    data_path,
                    &mounts,
                    startup,
                    window,
                    pixels,
                    &palette,
                    audio,
                    audio_device,
                    &frames,
                    frame_limit,
                );

                if (story_result == .quit or story_result == .frame_limit) break :main_loop;

                if (startup.currentEvent() == null) {
                    const mouse = mission_menu.mouseState();
                    try shell.endGame(
                        init.gpa,
                        archive,
                        c.SDL_GetTicks(),
                        .{ .x = mouse.x, .y = mouse.y, .buttons = mouse.buttons },
                    );

                    continue :main_loop;
                }

                const next_entry = startup.currentEvent().?;
                if (next_entry.kind != .level) return error.UnsupportedCampaignStoryEvent;

                try mounts.selectDisc(init.io, next_entry.disc);
                try audio.remount(init.io, mounts.path(), mounts.system());

                const opened_at = c.SDL_GetTicks();
                warnViewBox(&view);
                const next = try Session.openWithCampaignState(
                    init.gpa,
                    render_workspace,
                    init.io,
                    mounts.path(),
                    mounts.system(),
                    startup,
                    opened_at -% engine_clock_offset,
                    persistent_state,
                    &carry,
                );

                startRequest(next);
                session = next;

                try next.bindAudio(audio);
                try audio.engine.updateListener(next.audioListener());
                try audio.beginLevel(init.io, &next.level, next.geometry_archive, c.SDL_GetTicks());
                try audio.beginAmbient(&next.level, &next.objects, startup.difficulty);
                try audio_device.sync(audio);

                palette = try next.render(pixels, c.SDL_GetTicks());

                try window.present(&palette);
                player_input.clearLevelKeys();

                player_input.last_sample = opened_at;
                player_input.capture_map_arrows = next.automap.capture_arrows;

                try player_input.resumeMenu();
                menu_requested = false;
                continue :main_loop;
            }

            if (loaded.death_restart_requested and (loaded.game_type == 4 or loaded.game_type == 5)) {
                loaded.death_restart_requested = false;

                try loaded.revive(loaded.animation_time);
                try audio_device.sync(audio);
                try mounts.selectDisc(init.io, 0);
                try loaded.removePlayer(loaded.animation_time);
                try shell.startup.?.restartInLevel();

                switch (try network_lobby_platform.waitForStart(
                    init.gpa,
                    audio,
                    audio_device,
                    &player_input,
                    loaded,
                    &shell.startup.?,
                )) {
                    .quit, .frame_limit => break :main_loop,
                    .playing => {},
                }

                continue :main_loop;
            }

            if (loaded.death_restart_requested) {
                loaded.death_restart_requested = false;

                player_input.suspendMenu();
                audio.stopAll();
                try audio_device.sync(audio);

                const opened_at = c.SDL_GetTicks();
                const engine_now = loaded.animation_time +% (opened_at -% player_input.last_sample);

                warnViewBox(&view);
                const next = try loaded.restart(
                    init.gpa,
                    init.io,
                    mounts.path(),
                    mounts.system(),
                    &shell.startup.?,
                    engine_now,
                );

                startRequest(next);
                loaded.deinit(init.gpa);

                session = next;

                try next.bindAudio(audio);
                shell.startup.?.bindLevel();
                try audio.engine.updateListener(next.audioListener());
                try audio.beginLevel(init.io, &next.level, next.geometry_archive, c.SDL_GetTicks());
                try audio.beginAmbient(&next.level, &next.objects, shell.startup.?.difficulty);
                try audio_device.sync(audio);
                player_input.clearLevelKeys();

                player_input.last_sample = opened_at;
                player_input.capture_map_arrows = next.automap.capture_arrows;

                try player_input.resumeMenu();
                menu_requested = false;
                continue :main_loop;
            }
        }

        if (session) |loaded| if (menu_requested and loaded.animation_tick_count > 2) {
            menu_requested = false;
            try loaded.prepareMenu(init.gpa, audio);

            const game_pixels = try init.gpa.dupe(u8, pixels);
            defer init.gpa.free(game_pixels);
            const game_palette = palette;
            const result = try mission_menu.run(
                init.gpa,
                archive,
                window,
                pixels,
                &palette,
                &player_input,
                audio,
                audio_device,
                &frames,
                frame_limit,
            );

            try audio_device.sync(audio);

            switch (result) {
                .resume_game => {
                    loaded.framebuffer_initialized = false;
                    try player_input.resumeMenu();
                },
                .restart => {
                    audio.stopAll();
                    try audio_device.sync(audio);

                    const opened_at = c.SDL_GetTicks();
                    const engine_now = loaded.animation_time +% (opened_at -% player_input.last_sample);

                    warnViewBox(&view);
                    const next = try loaded.restart(
                        init.gpa,
                        init.io,
                        mounts.path(),
                        mounts.system(),
                        &shell.startup.?,
                        engine_now,
                    );

                    startRequest(next);
                    loaded.deinit(init.gpa);

                    session = next;

                    try next.bindAudio(audio);
                    shell.startup.?.bindLevel();
                    try audio.engine.updateListener(next.audioListener());
                    try audio.beginLevel(
                        init.io,
                        &next.level,
                        next.geometry_archive,
                        c.SDL_GetTicks(),
                    );

                    try audio.beginAmbient(&next.level, &next.objects, shell.startup.?.difficulty);
                    try audio_device.sync(audio);
                    player_input.clearLevelKeys();

                    player_input.last_sample = opened_at;
                    player_input.capture_map_arrows = next.automap.capture_arrows;

                    try player_input.resumeMenu();
                },
                .options => {
                    switch (try runOptions(
                        init,
                        archive,
                        window,
                        pixels,
                        &palette,
                        data_path,
                        &store,
                        &display,
                        &view,
                        audio,
                        audio_device,
                        &frames,
                        frame_limit,
                    )) {
                        .quit, .frame_limit => break :main_loop,
                        .done => {},
                    }

                    warnViewBox(&view);
                    audio.resumeMusic(c.SDL_GetTicks());

                    loaded.framebuffer_initialized = false;
                    try player_input.resumeMenu();
                },
                .save, .load => {
                    var catalog = try saved_game.Catalog.open(init.gpa, init.io);
                    defer catalog.deinit();
                    const choice = try saved_game.run(
                        init.gpa,
                        archive,
                        if (result == .save) .save else .load,
                        &catalog,
                        window,
                        pixels,
                        &palette,
                        game_pixels,
                        game_palette,
                        &player_input,
                        audio,
                        audio_device,
                        &frames,
                        frame_limit,
                    );

                    switch (choice) {
                        .quit, .frame_limit => break :main_loop,
                        .cancel => {},
                        .selection => |selected| {
                            defer if (selected.thumbnail) |thumbnail| init.gpa.free(thumbnail);

                            if (result == .save) {
                                const engine_now = loaded.animation_time +% (c.SDL_GetTicks() -% player_input.last_sample);
                                const links = save_player_module.TaskLinks.of(&loaded.inventory);
                                const bytes_out = try save_game.write(
                                    init.gpa,
                                    loaded,
                                    &shell.startup.?,
                                    audio,
                                    mounts.active,
                                    engine_now,
                                    selected.description,
                                    .{
                                        .width = save_menu.thumbnail_width,
                                        .height = save_menu.thumbnail_height,
                                        .pixels = selected.thumbnail orelse return error.MissingSaveThumbnail,
                                    },
                                );

                                defer init.gpa.free(bytes_out);

                                catalog.write(init.io, selected.slot, bytes_out) catch |err| {
                                    links.restore(&loaded.inventory);
                                    return err;
                                };
                            } else {
                                persistent_state = loaded.persistentState();

                                const bytes_in = try catalog.read(init.gpa, init.io, selected.slot);
                                defer init.gpa.free(bytes_in);

                                warnViewBox(&view);
                                const restored = try restoreGame(
                                    init.gpa,
                                    render_workspace,
                                    init.io,
                                    bytes_in,
                                    &shell,
                                    &mounts,
                                    &session,
                                    audio,
                                    audio_device,
                                    persistent_state,
                                );

                                engine_clock_offset = restored.host_time -% restored.engine_time;
                                player_input.last_sample = restored.host_time;

                                player_input.clearLevelKeys();
                                player_input.capture_map_arrows = session.?.automap.capture_arrows;
                            }
                        },
                    }

                    session.?.framebuffer_initialized = false;
                    try player_input.resumeMenu();
                },
                .end_game => {
                    try loaded.closeSounds();
                    try audio_device.sync(audio);

                    persistent_state = loaded.persistentState();
                    engine_clock_offset = player_input.last_sample -% loaded.animation_time;

                    loaded.deinit(init.gpa);
                    session = null;
                    const mouse = mission_menu.mouseState();
                    try shell.endGame(
                        init.gpa,
                        archive,
                        c.SDL_GetTicks(),
                        .{ .x = mouse.x, .y = mouse.y, .buttons = mouse.buttons },
                    );

                    palette = try shell.screen.render(pixels, c.SDL_GetTicks());
                    try window.present(&palette);
                    continue :main_loop;
                },
                .quit, .frame_limit => break :main_loop,
            }
        };

        if (session) |loaded| {
            const network_game = loaded.game_type == 4 or loaded.game_type == 5;
            const sampled = (try player_input.sample(c.SDL_GetTicks())) orelse
                if (network_game) player_input.sampleIdle(c.SDL_GetTicks()) else null;

            if (sampled) |sample| {
                loaded.automap_input = sample.map_input;
                var movie_host = trigger_movie.Host{
                    .allocator = init.gpa,
                    .io = init.io,
                    .initial_data_path = data_path,
                    .disc = mounts.active,
                    .window = window,
                    .pixels = pixels,
                    .palette = &palette,
                    .input = &player_input,
                    .audio = audio,
                    .device = audio_device,
                    .frames = &frames,
                    .limit = frame_limit,
                };

                loaded.movie_host = .{ .context = &movie_host, .play = trigger_movie.Host.play };
                defer loaded.movie_host = null;

                loaded.advanceWithAudio(
                    init.gpa,
                    &sample.packet,
                    sample.elapsed_ms,
                    audio,
                ) catch |err| switch (err) {
                    error.QuitFromMovie, error.MovieFrameLimit => break :main_loop,
                    else => return err,
                };

                for (loaded.pickup_effects.items) |effect| switch (effect) {
                    .sound => |request| {
                        if (!request.delivered) _ = try audio.play(
                            request,
                            loaded.audioWorld(),
                            c.SDL_GetTicks(),
                        );
                    },
                    else => {},
                };

                try audio.engine.updateListener(loaded.audioListener());
            }

            palette = try loaded.render(pixels, c.SDL_GetTicks());
            player_input.capture_map_arrows = loaded.automap.capture_arrows;

            if (loaded.hud.sound_request) |effect| {
                _ = try audio.play(effect.sound, loaded.audioWorld(), c.SDL_GetTicks());
            }

            try audio.advanceMusic(init.io, c.SDL_GetTicks());
            try audio.advanceAmbient(
                c.SDL_GetTicks(),
                loaded.level.sectors[loaded.player.sector].layer,
            );

            try audio_device.sync(audio);
            try window.present(&palette);

            frames += 1;

            if (frame_limit) |limit| if (frames >= limit) break;

            c.SDL_Delay(16);
            continue;
        }

        var mouse_x: c_int = 0;
        var mouse_y: c_int = 0;
        const buttons = c.SDL_GetMouseState(&mouse_x, &mouse_y);

        shell.screen.mouseState(mouse_x, mouse_y, buttons, c.SDL_GetTicks());

        if (shell.screen.takeSelectionSound()) {
            _ = try audio.play(
                .{ .basename = "RIFLOUT.WAV", .priority = 64, .volume = 127, .flags = 4 },
                null,
                c.SDL_GetTicks(),
            );
        }

        try audio_device.sync(audio);
        palette = try shell.screen.render(pixels, c.SDL_GetTicks());

        try window.present(&palette);
        shell.screen.presented(c.SDL_GetTicks());

        if (shell.screen.takeResult(c.SDL_GetTicks(), buttons)) |result| {
            shell.accept(
                init.gpa,
                archive,
                result,
                c.SDL_GetTicks(),
                .{ .x = mouse_x, .y = mouse_y, .buttons = buttons },
            ) catch |err| switch (err) {
                error.MenuActionNotImplemented => std.log.info(
                    "Requested menu branch is not implemented",
                    .{},
                ),
                else => return err,
            };

            if (shell.load_requested) {
                shell.load_requested = false;

                var catalog = try saved_game.Catalog.open(init.gpa, init.io);
                defer catalog.deinit();
                const background = try init.gpa.dupe(u8, pixels);
                defer init.gpa.free(background);
                const choice = try saved_game.run(
                    init.gpa,
                    archive,
                    .load,
                    &catalog,
                    window,
                    pixels,
                    &palette,
                    background,
                    palette,
                    &player_input,
                    audio,
                    audio_device,
                    &frames,
                    frame_limit,
                );

                switch (choice) {
                    .quit, .frame_limit => break :main_loop,
                    .cancel => {
                        const mouse = mission_menu.mouseState();
                        try shell.returnFromLoad(
                            init.gpa,
                            archive,
                            c.SDL_GetTicks(),
                            .{ .x = mouse.x, .y = mouse.y, .buttons = mouse.buttons },
                        );
                    },
                    .selection => |selected| {
                        warnViewBox(&view);

                        const bytes_in = try catalog.read(init.gpa, init.io, selected.slot);
                        defer init.gpa.free(bytes_in);
                        const restored = try restoreGame(
                            init.gpa,
                            render_workspace,
                            init.io,
                            bytes_in,
                            &shell,
                            &mounts,
                            &session,
                            audio,
                            audio_device,
                            persistent_state,
                        );

                        engine_clock_offset = restored.host_time -% restored.engine_time;
                        player_input.last_sample = restored.host_time;

                        player_input.clearLevelKeys();
                        player_input.capture_map_arrows = session.?.automap.capture_arrows;
                        try player_input.resumeMenu();
                    },
                }

                continue :main_loop;
            }

            if (shell.options_requested) {
                switch (try runOptions(
                    init,
                    archive,
                    window,
                    pixels,
                    &palette,
                    data_path,
                    &store,
                    &display,
                    &view,
                    audio,
                    audio_device,
                    &frames,
                    frame_limit,
                )) {
                    .quit, .frame_limit => break :main_loop,
                    .done => {},
                }

                const mouse = mission_menu.mouseState();
                try shell.returnFromOptions(
                    init.gpa,
                    archive,
                    c.SDL_GetTicks(),
                    .{ .x = mouse.x, .y = mouse.y, .buttons = mouse.buttons },
                );

                continue :main_loop;
            }

            if (shell.multiplayer_requested) {
                const choice = try network_menu_platform.run(
                    init.gpa,
                    init.io,
                    archive,
                    window,
                    pixels,
                    &palette,
                    &store,
                    audio,
                    audio_device,
                    &frames,
                    frame_limit,
                );

                switch (choice) {
                    .quit, .frame_limit => break :main_loop,
                    .choice => |selected| switch (selected) {
                        .cancel => {},
                        .host => switch (try network_menu_platform.runHost(
                            init.gpa,
                            init.io,
                            archive,
                            data_path,
                            window,
                            pixels,
                            &palette,
                            &store,
                            audio,
                            audio_device,
                            &frames,
                            frame_limit,
                        )) {
                            .quit, .frame_limit => break :main_loop,
                            .cancel => {},
                            .selected => |selection| {
                                shell.startup = try campaign.Startup.initHost(
                                    init.gpa,
                                    try network_menu_platform.hostChoice(&selection),
                                );

                                const startup = &shell.startup.?;
                                try network_menu_platform.bindPlayer(startup, &store, archive);
                                startup.router.now = c.SDL_GetTicks() -% engine_clock_offset;

                                if (try hostSession(startup, &network_opener)) {
                                    try startup.beginHost(init.gpa, init.io, data_path, archive);
                                    const level_entry = startup.currentEvent() orelse return error.CampaignHasNoLevel;

                                    try mounts.selectDisc(init.io, level_entry.disc);
                                    try audio.remount(init.io, mounts.path(), mounts.system());

                                    const opened_at = c.SDL_GetTicks();
                                    warnViewBox(&view);

                                    persistent_state.base_palette = palette;
                                    session = try Session.openWithState(
                                        init.gpa,
                                        render_workspace,
                                        init.io,
                                        mounts.path(),
                                        mounts.system(),
                                        startup,
                                        opened_at -% engine_clock_offset,
                                        persistent_state,
                                    );

                                    try session.?.bindAudio(audio);
                                    try audio.engine.updateListener(session.?.audioListener());
                                    try audio.beginLevel(
                                        init.io,
                                        &session.?.level,
                                        session.?.geometry_archive,
                                        c.SDL_GetTicks(),
                                    );

                                    try audio.beginAmbient(
                                        &session.?.level,
                                        &session.?.objects,
                                        startup.difficulty,
                                    );

                                    try audio_device.sync(audio);
                                    startup.networkLevelLoaded();

                                    player_input.last_sample = opened_at;

                                    switch (try network_lobby_platform.run(
                                        init.gpa,
                                        archive,
                                        window,
                                        pixels,
                                        &palette,
                                        audio,
                                        audio_device,
                                        &frames,
                                        frame_limit,
                                        &player_input,
                                        session.?,
                                        startup,
                                    )) {
                                        .quit, .frame_limit => break :main_loop,
                                        .playing => {},
                                    }

                                    palette = try session.?.render(pixels, c.SDL_GetTicks());

                                    try window.present(&palette);
                                    reportNetworkStartup(startup, session.?);

                                    player_input.capture_map_arrows = session.?.automap.capture_arrows;
                                    try player_input.resumeMenu();
                                    continue :main_loop;
                                }

                                shell.startup.?.deinit(init.gpa);
                                shell.startup = null;
                            },
                        },
                        .join => switch (try network_menu_platform.runJoin(
                            init.gpa,
                            init.io,
                            archive,
                            window,
                            pixels,
                            &palette,
                            &store,
                            audio,
                            audio_device,
                            &frames,
                            frame_limit,
                        )) {
                            .quit, .frame_limit => break :main_loop,
                            .cancel => {},
                            .selected => |selection| {
                                join_selection = selection;
                                const host_length = std.mem.indexOfScalar(
                                    u8,
                                    &join_selection.host,
                                    0,
                                ) orelse return error.InvalidJoinHost;

                                network_opener.host = join_selection.host[0..host_length :0];
                                shell.startup = try campaign.Startup.initJoin(init.gpa, .{
                                    .session_name = std.mem.sliceTo(&join_selection.name, 0),
                                    .password = std.mem.sliceTo(&join_selection.password, 0),
                                });

                                const startup = &shell.startup.?;

                                try network_menu_platform.bindPlayer(startup, &store, archive);
                                warnViewBox(&view);

                                switch (try network_join.run(
                                    init.gpa,
                                    render_workspace,
                                    init.io,
                                    archive,
                                    data_path,
                                    &mounts,
                                    window,
                                    pixels,
                                    &palette,
                                    audio,
                                    audio_device,
                                    &frames,
                                    frame_limit,
                                    startup,
                                    &network_opener,
                                    std.mem.sliceTo(&join_selection.name, 0),
                                    engine_clock_offset,
                                    persistent_state,
                                )) {
                                    .quit, .frame_limit => break :main_loop,
                                    .menu => {
                                        shell.startup.?.deinit(init.gpa);
                                        shell.startup = null;
                                    },
                                    .level => |loaded| {
                                        session = loaded;
                                        const opened_at = c.SDL_GetTicks();

                                        try session.?.bindAudio(audio);
                                        try audio.engine.updateListener(session.?.audioListener());
                                        try audio.beginLevel(
                                            init.io,
                                            &session.?.level,
                                            session.?.geometry_archive,
                                            opened_at,
                                        );

                                        try audio.beginAmbient(
                                            &session.?.level,
                                            &session.?.objects,
                                            startup.difficulty,
                                        );

                                        try audio_device.sync(audio);
                                        startup.networkLevelLoaded();

                                        player_input.last_sample = opened_at;

                                        switch (try network_lobby_platform.run(
                                            init.gpa,
                                            archive,
                                            window,
                                            pixels,
                                            &palette,
                                            audio,
                                            audio_device,
                                            &frames,
                                            frame_limit,
                                            &player_input,
                                            session.?,
                                            startup,
                                        )) {
                                            .quit, .frame_limit => break :main_loop,
                                            .playing => {},
                                        }

                                        palette = try session.?.render(pixels, c.SDL_GetTicks());

                                        try window.present(&palette);
                                        reportNetworkStartup(startup, session.?);

                                        player_input.capture_map_arrows = session.?.automap.capture_arrows;
                                        try player_input.resumeMenu();
                                        continue :main_loop;
                                    },
                                }
                            },
                        },
                    },
                }

                const mouse = mission_menu.mouseState();
                try shell.returnFromMultiplayer(
                    init.gpa,
                    archive,
                    c.SDL_GetTicks(),
                    .{ .x = mouse.x, .y = mouse.y, .buttons = mouse.buttons },
                );

                continue :main_loop;
            }

            if (shell.startup) |*startup| {
                if (build_options.mission) |name| try mission.select(startup, name);

                const story_result = try playCampaignMovies(
                    init.gpa,
                    init.io,
                    data_path,
                    &mounts,
                    startup,
                    window,
                    pixels,
                    &palette,
                    audio,
                    audio_device,
                    &frames,
                    frame_limit,
                );

                if (story_result == .quit or story_result == .frame_limit) break;

                const level_entry = startup.currentEvent() orelse return error.CampaignHasNoLevel;

                try mounts.selectDisc(init.io, level_entry.disc);
                try audio.remount(init.io, mounts.path(), mounts.system());

                const opened_at = c.SDL_GetTicks();
                warnViewBox(&view);

                persistent_state.base_palette = palette;
                session = try Session.openWithState(
                    init.gpa,
                    render_workspace,
                    init.io,
                    mounts.path(),
                    mounts.system(),
                    startup,
                    opened_at -% engine_clock_offset,
                    persistent_state,
                );

                startRequest(session.?);
                try session.?.bindAudio(audio);
                try audio.engine.updateListener(session.?.audioListener());
                try audio.beginLevel(
                    init.io,
                    &session.?.level,
                    session.?.geometry_archive,
                    c.SDL_GetTicks(),
                );

                try audio.beginAmbient(&session.?.level, &session.?.objects, startup.difficulty);
                try audio_device.sync(audio);

                {
                    palette = try session.?.render(pixels, c.SDL_GetTicks());
                    try window.present(&palette);
                }

                reportStartup(startup, session.?);
                player_input.clearLevelKeys();

                player_input.last_sample = opened_at;
                player_input.capture_map_arrows = session.?.automap.capture_arrows;

                try player_input.resumeMenu();
            }
        }

        frames += 1;

        if (frame_limit) |limit| if (frames >= limit) break;

        c.SDL_Delay(16);
    }

    if (snapshot) |path| try writeSnapshot(init, path, pixels, &palette);
}

fn warnViewBox(view: *view_box.State) void {
    if (view.index == view_box.default) return;

    std.log.warn(
        "view box {d} (OPTIONS' SCREEN SIZE) is not implemented; the level keeps view box 14",
        .{view.index},
    );
}

fn runOptions(
    init: std.process.Init,
    archive: lab.Archive,
    window: platform.Window,
    pixels: []u8,
    palette: *[256]u32,
    data_path: []const u8,
    store: *settings.Store,
    display: *display_palette.Display,
    view: *view_box.State,
    audio: *audio_runtime.Runtime,
    device: *audio_platform.Device,
    frames: *usize,
    frame_limit: ?usize,
) !options_platform.Result {
    const names = drivers.names(
        init.gpa,
        init.io,
        std.fs.path.dirname(data_path) orelse ".",
        "LEC INPUT DRIVER",
    ) catch |err| blk: {
        std.log.warn(
            "OPTIONS: cannot list the input drivers ({s}); the controls buttons are disabled",
            .{@errorName(err)},
        );

        break :blk try init.gpa.alloc([]const u8, 0);
    };

    defer drivers.free(init.gpa, names);

    return options_platform.run(
        init.gpa,
        init.io,
        archive,
        window,
        pixels,
        palette,
        .{ .settings = store, .display = display, .view_box = view, .drivers = names },
        audio,
        device,
        frames,
        frame_limit,
    );
}

fn playCampaignMovies(
    allocator: std.mem.Allocator,
    io: std.Io,
    initial_data_path: []const u8,
    mounts: *mission.Mounts,
    startup: *campaign.Startup,
    window: platform.Window,
    pixels: []u8,
    palette: *[256]u32,
    audio: *audio_runtime.Runtime,
    device: *audio_platform.Device,
    frames: *usize,
    limit: ?usize,
) !movie_platform.Result {
    audio.stopAll();
    try device.sync(audio);

    while (startup.currentEvent()) |entry| {
        if (entry.kind != .movie) break;

        if (startup.recipe.paths.len != 0) return error.MovieSearchPathsNotImplemented;

        try mounts.selectDisc(io, entry.disc);
        try audio.remount(io, mounts.path(), mounts.system());

        const path = try mission.moviePath(
            allocator,
            initial_data_path,
            .{ .kind = entry.kind, .disc = mounts.active, .name = entry.name },
        );

        defer allocator.free(path);
        const result = try movie_platform.play(
            allocator,
            io,
            path,
            window,
            pixels,
            palette,
            frames,
            limit,
        );

        if (result == .quit or result == .frame_limit) return result;

        try startup.finishMovie(result == .cancelled);
    }

    return .completed;
}

fn hostSession(startup: *campaign.Startup, opener: *enet_driver.Opener) !bool {
    return startup.connectHost(opener.provider()) catch |err| switch (err) {
        error.CannotOpen, error.UnknownHost, error.NoAnswer, error.Refused => {
            std.log.err("network: cannot open the game ({s})", .{@errorName(err)});
            return false;
        },
        else => return err,
    };
}

fn reportNetworkStartup(startup: *const campaign.Startup, session: *const Session) void {
    std.debug.print(
        "Network level loaded: {s}\n  game type {d}, mode {d}, own client {d}, clients {d}\n  level: {s}, sector {d}\n",
        .{
            startup.request.path(),
            startup.engine.game_type,
            startup.mode,
            startup.router.own_client,
            startup.router.clientCount(),
            session.level_name,
            session.player.sector,
        },
    );
}

fn reportStartup(startup: *const campaign.Startup, session: *const Session) void {
    std.debug.print("Campaign level loaded: {s}\n" ++
        "  recipe: {s}\n  difficulty: {s} (0x{x})\n" ++
        "  player definition: {s} ({c})\n" ++
        "  movies: {d} completed, {d} cancelled, {d} diagnostic skips\n  level: {s}, disc {d}\n" ++
        "  software view: sector {d}, eye ({d}, {d}, {d})\n", .{
        startup.recipe.name,
        startup.request.path(),
        @tagName(startup.difficulty),
        @intFromEnum(startup.difficulty),
        startup.player_definition,
        startup.character_code,
        startup.completed_movies,
        startup.cancelled_movies,
        startup.skipped_movies,
        session.level_name,
        startup.selected_level.?.disc,
        session.spawn.sector,
        session.view.x,
        session.view.y,
        session.view.z,
    });
}

fn writeSnapshot(
    init: std.process.Init,
    path: []const u8,
    pixels: []const u8,
    palette: *const [256]u32,
) !void {
    const header = "P6\n640 480\n255\n";
    const output = try init.gpa.alloc(u8, header.len + pixels.len * 3);
    defer init.gpa.free(output);

    @memcpy(output[0..header.len], header);

    for (pixels, 0..) |index, i| {
        const color = palette[index];
        output[header.len + i * 3] = @truncate(color);
        output[header.len + i * 3 + 1] = @truncate(color >> 8);
        output[header.len + i * 3 + 2] = @truncate(color >> 16);
    }

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = output });
    std.debug.print("Saved {s}\n", .{path});
}

fn startRequest(session: *Session) void {
    session.seedStartRequest(c.SDL_GetTicks());
}

fn restoreGame(
    a: std.mem.Allocator,
    render_workspace: *world.Workspace,
    io: std.Io,
    bytes: []const u8,
    shell: *Shell,
    mounts: *mission.Mounts,
    session: *?*Session,
    audio: *audio_runtime.Runtime,
    device: *audio_platform.Device,
    persistent: Session.PersistentState,
) !RestoredClock {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reader: save_stream.Reader = .{ .bytes = bytes };
    const header = try save_header.Header.read(arena.allocator(), &reader);
    const difficulty = try save_game.validate(header);
    const recipe = header.recipe.?;

    try mounts.selectDisc(io, @intCast(header.mounted_disc));

    var restored = try campaign.Startup.restore(
        a,
        mounts.system(),
        difficulty,
        recipe.filename,
        recipe.ordinal,
    );

    var placed = false;
    errdefer if (!placed) restored.deinit(a);
    const selected = restored.currentEvent().?;
    if (!std.ascii.eqlIgnoreCase(
        selected.name,
        header.level_name,
    ) or (selected.disc != 0 and selected.disc != header.mounted_disc)) return error.SaveCampaignLevelMismatch;

    if (session.*) |old| try old.closeSounds() else audio.endLevel();

    try device.sync(audio);

    if (session.*) |old| old.deinit(a);

    session.* = null;

    if (shell.startup) |*old| old.deinit(a);

    shell.startup = restored;
    placed = true;

    const startup = &shell.startup.?;
    try audio.remount(io, mounts.path(), mounts.system());

    const next = try Session.openForRestore(
        a,
        render_workspace,
        io,
        mounts.path(),
        mounts.system(),
        startup,
        header.clock,
        persistent,
    );

    errdefer next.deinit(a);

    try next.bindAudio(audio);
    try save_game.readBody(next, startup, audio, &reader, header);
    try audio.engine.updateListener(next.audioListener());

    const host_time = c.SDL_GetTicks();
    try audio.beginLevel(io, &next.level, next.geometry_archive, host_time);

    if (next.saved_music) |music| try audio.restoreMusic(io, music.name, music.cue, host_time);

    try audio.beginEmptyAmbient();
    try device.sync(audio);

    session.* = next;

    return .{ .host_time = host_time, .engine_time = header.clock };
}
