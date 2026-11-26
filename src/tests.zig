//! Root of the engine test suite: imports every module that has tests so
//! one `zig build test` covers them all.
//!
//! Add new modules here, including ones whose tests sit at the bottom of the
//! implementation file. Fixture-driven tests skip when the data is absent -
//! see testing/fixtures.zig.

const std = @import("std");

test {
    _ = @import("memory/layout.zig");
    _ = @import("platform/MemoryBudget.zig");
    _ = @import("platform/c_memory.zig");
    _ = @import("audio/registration.zig");
    _ = @import("audio/level_ownership.zig");
    _ = @import("save/sound.zig");
    _ = @import("assets/atx.zig");
    _ = @import("assets/level_text.zig");
    _ = @import("script/actor_nudge_test.zig");
    _ = @import("script/inf_inventory_test.zig");
    _ = @import("save/inf.zig");
    _ = @import("enemy/save.zig");
    _ = @import("render/inventory_browser_test.zig");
    _ = @import("save/level_test.zig");
    _ = @import("projectile/weapon_test.zig");
    _ = @import("save/header.zig");
    _ = @import("save/modules.zig");
    _ = @import("save/menu.zig");
    _ = @import("save/player_module.zig");
    _ = @import("save/player.zig");
    _ = @import("save/actor.zig");
    _ = @import("save/game_test.zig");
    _ = @import("projectile/runtime_test.zig");
    _ = @import("player/inventory_interaction_test.zig");
    _ = @import("enemy/config_test.zig");
    _ = @import("enemy/generator.zig");
    _ = @import("enemy/sanchez_test.zig");
    _ = @import("enemy/perception_test.zig");
    _ = @import("enemy/broadcast_test.zig");
    _ = @import("enemy/physics_test.zig");
    _ = @import("enemy/blood_test.zig");
    _ = @import("enemy/blood_nan_test.zig");
    _ = @import("enemy/explosion_fragment_test.zig");
    _ = @import("enemy/bubble_test.zig");
    _ = @import("enemy/impact_test.zig");
    _ = @import("enemy/impact_reentry_test.zig");
    _ = @import("enemy/drop_test.zig");
    _ = @import("enemy/controller_test.zig");
    _ = @import("enemy/session_test.zig");
    _ = @import("enemy/fifo_test.zig");
    _ = @import("player/weapon_session_test.zig");
    _ = @import("audio/asset.zig");
    _ = @import("audio/engine.zig");
    _ = @import("audio/music.zig");
    _ = @import("audio/ambient.zig");
    _ = @import("audio/indexed.zig");
    _ = @import("audio/occlusion.zig");
    _ = @import("audio/runtime.zig");
    _ = @import("audio/rail.zig");
    _ = @import("platform/audio_mix.zig");
    _ = @import("platform/mission.zig");
    _ = @import("video/san.zig");
    _ = @import("video/audio_stream.zig");
    _ = @import("video/playback.zig");
    _ = @import("video/smush_present.zig");
    _ = @import("video/campaign_test.zig");
    _ = @import("player/input.zig");
    _ = @import("player/movement.zig");
    _ = @import("player/choreography.zig");
    _ = @import("player/damage.zig");
    _ = @import("player/damage_test.zig");
    _ = @import("player/surface_test.zig");
    _ = @import("player/moving_planes_test.zig");
    _ = @import("player/secrets_test.zig");
    _ = @import("player/shot_damage_test.zig");
    _ = @import("player/shooting_test.zig");
    _ = @import("player/target_test.zig");
    _ = @import("player/weapon_test.zig");
    _ = @import("player/damage_session_test.zig");
    _ = @import("render/damage_flash.zig");
    _ = @import("render/automap_test.zig");
    _ = @import("render/object_numbers_test.zig");
    _ = @import("player/collision.zig");
    _ = @import("player/inventory.zig");
    _ = @import("player/pickup_contact_test.zig");
    _ = @import("player/pickup_session_test.zig");
    _ = @import("script/cmm.zig");
    _ = @import("script/cmm_parser.zig");
    _ = @import("script/interaction.zig");
    _ = @import("script/inf.zig");
    _ = @import("script/inf_geometry.zig");
    _ = @import("script/inf_floor_test.zig");
    _ = @import("script/inf_session_test.zig");
    _ = @import("script/runtime.zig");
    _ = @import("script/object_test.zig");
    _ = @import("script/lamp_test.zig");
    _ = @import("player/lamp.zig");
    _ = @import("player/lamp_session_test.zig");
    _ = @import("assets/model.zig");
    _ = @import("render/model_state.zig");
    _ = @import("render/model_session_test.zig");
    _ = @import("render/backends/software/model.zig");
    _ = @import("platform/patches.zig");
    _ = @import("assets/lab.zig");
    _ = @import("assets/pcx.zig");
    _ = @import("assets/font.zig");
    _ = @import("assets/messages.zig");
    _ = @import("assets/rcp.zig");
    _ = @import("assets/level.zig");
    _ = @import("assets/texture.zig");
    _ = @import("assets/item.zig");
    _ = @import("assets/nwx.zig");
    _ = @import("render/scene.zig");
    _ = @import("render/backends/software/walls.zig");
    _ = @import("render/backends/software/world.zig");
    _ = @import("render/session.zig");
    _ = @import("render/texture_animation.zig");
    _ = @import("render/actor_links.zig");
    _ = @import("render/objects.zig");
    _ = @import("render/first_view_test.zig");
    _ = @import("render/toilet_test.zig");
    _ = @import("render/hud_reference_test.zig");
    _ = @import("render/sector_palette_test.zig");
    _ = @import("render/weapon.zig");
    _ = @import("render/object_state.zig");
    _ = @import("render/backends/software/shades.zig");
    _ = @import("campaign.zig");
    _ = @import("ui/shell.zig");
    _ = @import("ui/network_menu.zig");
    _ = @import("ui/network_lobby.zig");
    _ = @import("ui/menu.zig");
    _ = @import("ui/mission_menu.zig");
    _ = @import("ui/mission_menu_test.zig");
    _ = @import("ui/surface.zig");
    _ = @import("ui/loading_display.zig");
    _ = @import("network/message.zig");
    _ = @import("network/router.zig");
    _ = @import("network/server.zig");
    _ = @import("network/router_reference_test.zig");
    _ = @import("network/startup_reference_test.zig");
    _ = @import("network/objects_reference_test.zig");
    _ = @import("network/dispatch_reference_test.zig");
    _ = @import("network/post_reference_test.zig");
    _ = @import("network/database.zig");
    _ = @import("network/driver.zig");
    _ = @import("network/remote_reference_test.zig");
    _ = @import("network/join_reference_test.zig");
    _ = @import("network/connect_reference_test.zig");
    _ = @import("render/network_combat_reference_test.zig");
    _ = @import("render/network_architecture_reference_test.zig");
    _ = @import("settings.zig");
    _ = @import("render/view_box.zig");
    _ = @import("render/display_palette.zig");
    _ = @import("ui/options_test.zig");
    _ = @import("platform/drivers.zig");
    _ = @import("platform/settings.zig");
    _ = @import("player/collision_test.zig");
    _ = @import("testing/fixtures.zig");
    _ = @import("game/title.zig");
}

test "CD1 menu assets decode to independently checked reference pixels" {
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", std.testing.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(data);
    const archive = try @import("assets/lab.zig").Archive.init(data);
    var screen = try @import("ui/menu.zig").Menu.init(std.testing.allocator, archive);
    defer screen.deinit(std.testing.allocator);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(screen.background.pixels, &hash, .{});
    var expected_bytes: [32]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&expected_bytes, "81ee67977477780df5bd0499f0d5e447068bc8d91fb5e1f1c8c6366e18788949");
    try std.testing.expectEqualSlices(u8, expected, &hash);
    try std.testing.expectEqualStrings("MAIN GAME", screen.labels[0]);
    try std.testing.expectEqual(@as(i32, 93), screen.fonts[0].height);
    try std.testing.expectEqual(@as(i32, 45), screen.fonts[1].height);
    try std.testing.expectEqual(@as(i32, 71), screen.fonts[2].height);
    try std.testing.expectEqual(@as(i32, 14), screen.fonts[3].height);
    const pixels = try std.testing.allocator.alloc(u8, 640 * 480);
    defer std.testing.allocator.free(pixels);
    _ = try screen.render(pixels, 0);
    std.crypto.hash.sha2.Sha256.hash(pixels, &hash, .{});
    _ = try std.fmt.hexToBytes(&expected_bytes, "90f23d649e36490a94c6430cf5486e2edee71678d434e0299229a4c70e39fc60");
    try std.testing.expectEqualSlices(u8, &expected_bytes, &hash);
    screen.select(1, 10);
    const hovered = try screen.render(pixels, 260);
    screen.select(-1, 300);
    const unselected = try screen.render(pixels, 300);
    try std.testing.expectEqualSlices(u32, &hovered, &unselected);
    screen.arrow(.up, 400);
    try std.testing.expectEqual(@as(i32, 3), screen.selected);
    screen.select(-1, 450);
    screen.arrow(.left, 500);
    try std.testing.expectEqual(@as(i32, 0), screen.selected);
}

test "CD1 story startup preserves the launch record and all nineteen campaign events" {
    const campaign = @import("campaign.zig");
    const rcp = @import("assets/rcp.zig");
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", std.testing.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(data);
    const archive = try @import("assets/lab.zig").Archive.init(data);

    const expected_story = [_]rcp.Entry{
        .{ .kind = .movie, .disc = 1, .name = "in_shb.san" },
        .{ .kind = .level, .disc = 1, .name = "hideout" },
        .{ .kind = .movie, .disc = 1, .name = "she_tob.san" },
        .{ .kind = .level, .disc = 1, .name = "town" },
        .{ .kind = .movie, .disc = 1, .name = "toe_trb.san" },
        .{ .kind = .level, .disc = 1, .name = "train" },
        .{ .kind = .movie, .disc = 1, .name = "tre_cab.san" },
        .{ .kind = .level, .disc = 1, .name = "canyon" },
        .{ .kind = .movie, .disc = 1, .name = "cae_sab.san" },
        .{ .kind = .level, .disc = 2, .name = "mill" },
        .{ .kind = .movie, .disc = 2, .name = "sae_hib.san" },
        .{ .kind = .level, .disc = 2, .name = "simms" },
        .{ .kind = .movie, .disc = 2, .name = "hie_mnb.san" },
        .{ .kind = .level, .disc = 2, .name = "miner" },
        .{ .kind = .movie, .disc = 2, .name = "mne_clb.san" },
        .{ .kind = .level, .disc = 2, .name = "cliff" },
        .{ .kind = .movie, .disc = 2, .name = "cle_rab.san" },
        .{ .kind = .level, .disc = 2, .name = "ranch" },
        .{ .kind = .credits, .disc = 2, .name = "rae.san" },
    };

    for ([_]u32{ 0x100000, 0x200000, 0x800000 }, 0..) |mask, selection| {
        const difficulty = try campaign.Difficulty.fromSelection(@intCast(selection));
        var startup = try campaign.Startup.prepare(std.testing.allocator, archive, difficulty);
        defer startup.deinit(std.testing.allocator);
        try std.testing.expectEqual(mask, @intFromEnum(startup.difficulty));

        try std.testing.expectEqual(@as(usize, 44), @sizeOf(campaign.StartRequest));
        try std.testing.expectEqual(@as(usize, 20), @offsetOf(campaign.StartRequest, "filename"));
        try std.testing.expectEqual(@as(u32, 0), startup.request.reserved);
        try std.testing.expectEqual(@as(u32, 0), startup.request.flags);
        try std.testing.expectEqual(@as(u32, 1), startup.request.game_type);
        try std.testing.expectEqual(@as(u32, 0), startup.request.mode);
        try std.testing.expectEqual(@as(u32, 0), startup.request.parameter);
        try std.testing.expectEqualStrings("OUTLAWS.rcs", startup.request.path());
        try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 13), startup.request.filename[11..]);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&startup.request), std.mem.asBytes(&startup.server.record));
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&startup.request), std.mem.asBytes(&startup.database.record));
        try std.testing.expectEqual(@as(u32, 1), startup.engine.scenario);
        try std.testing.expectEqual(@as(u32, 4), startup.engine.previous_scenario);
        try std.testing.expectEqual(@as(u32, 1), startup.engine.game_type);
        try std.testing.expectEqual(@as(u32, 0), startup.mode);
        for (startup.router.queues) |queue| try std.testing.expectEqual(@as(usize, 0), queue.items.len);

        try std.testing.expectEqualStrings("Outlaws Story", startup.recipe.name);
        try std.testing.expectEqual(@as(u32, 0), startup.recipe.modes);
        try std.testing.expectEqual(@as(usize, 0), startup.recipe.paths.len);
        try std.testing.expectEqual(@as(usize, 19), startup.recipe.story.len);
        var levels: usize = 0;
        var movies: usize = 0;
        var credits: usize = 0;
        for (expected_story, startup.recipe.story) |expected, actual| {
            try std.testing.expectEqual(expected.kind, actual.kind);
            try std.testing.expectEqual(expected.disc, actual.disc);
            try std.testing.expectEqualStrings(expected.name, actual.name);
            switch (actual.kind) {
                .level => levels += 1,
                .movie => movies += 1,
                .credits => credits += 1,
                .text => return error.UnexpectedTextEvent,
            }
        }
        try std.testing.expectEqual(@as(usize, 9), levels);
        try std.testing.expectEqual(@as(usize, 9), movies);
        try std.testing.expectEqual(@as(usize, 1), credits);
        try std.testing.expectEqual(rcp.Kind.movie, startup.first_event.kind);
        try std.testing.expectEqual(@as(u8, 1), startup.first_event.disc);
        try std.testing.expectEqualStrings("in_shb.san", startup.first_event.name);

        try std.testing.expectEqual(@as(u32, 0), startup.character);
        try std.testing.expectEqualStrings("cidjames.itm", startup.player_definition);
        try std.testing.expectEqual(@as(u8, 'J'), startup.character_code);
        const level = try startup.levelForDiagnostics();
        try std.testing.expectEqual(rcp.Kind.level, level.kind);
        try std.testing.expectEqualStrings("hideout", level.name);
        try std.testing.expectEqual(@as(u8, 1), level.disc);
        try std.testing.expectEqual(@as(usize, 1), startup.skipped_movies);
        try std.testing.expectEqual(@as(?usize, 1), startup.story_index);
        try std.testing.expectEqual(rcp.Kind.movie, startup.first_event.kind);
        try std.testing.expectError(error.LevelAlreadySelected, startup.levelForDiagnostics());
    }
}
