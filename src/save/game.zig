//! A saved game on disk: the header, then each subsystem's records in the
//! order they registered.
//!
//! There is no host-side snapshot and no replacement container - the file is
//! the subsystems' own records. The host part is validated before anything
//! is handed to the engine.

const std = @import("std");

const campaign = @import("../campaign.zig");
const header = @import("header.zig");
const palette = @import("palette.zig");
const player_module = @import("player_module.zig");
const statistics = @import("statistics.zig");
const stream = @import("stream.zig");

pub fn write(
    a: std.mem.Allocator,
    session: anytype,
    startup: *const campaign.Startup,
    audio: anytype,
    disc: u8,
    now: u32,
    description: [15]u8,
    thumbnail: header.Thumbnail,
) ![]u8 {
    const entry = startup.selected_level orelse return error.LevelNotSelected;
    var writer: stream.Writer = .{ .allocator = a };
    defer writer.deinit();
    const saved_header: header.Header = .{
        .description = description,
        .thumbnail = thumbnail,
        .mounted_disc = disc,
        .level_archive = session.level_name,
        .engine = startup.engine,
        .clock = now,
        .palette = session.palette_index,
        .level_name = session.level_name,
        .recipe = .{
            .disc = entry.disc,
            .filename = startup.request.path(),
            .ordinal = @intCast((startup.story_index orelse return error.CampaignExhausted) + 1),
        },
    };

    try saved_header.write(&writer);

    // Writing the player module clears the inventory's task links; a save
    // that fails afterwards leaves the running game as it was.
    const links = player_module.TaskLinks.of(&session.inventory);
    errdefer links.restore(&session.inventory);

    try session.writeSaved(&writer, audio);
    try writer.integer(u32, 0);
    try (header.Statistics{
        .accumulated = startup.accumulated_stats,
        .level = statistics.level(session),
    }).write(&writer);

    return writer.finish();
}

pub fn validate(saved: header.Header) !campaign.Difficulty {
    if (saved.engine.game_type != .campaign or saved.engine.scenario != 2 or saved.engine.game_state != 1) return error.UnsupportedSavedGameMode;
    if (saved.pushed_state != null) return error.UnsupportedPushedSaveState;

    const recipe = saved.recipe orelse return error.MissingSavedCampaign;
    if (saved.mounted_disc < 1 or saved.mounted_disc > 2 or recipe.disc > 2) return error.UnsupportedSavedDisc;
    if (!std.ascii.eqlIgnoreCase(
        saved.level_archive,
        saved.level_name,
    )) return error.SavedLevelNameMismatch;

    return @import("../difficulty.zig").Difficulty.fromWord(saved.engine.mode_mask);
}

pub fn readBody(
    session: anytype,
    startup: *campaign.Startup,
    audio: anytype,
    reader: *stream.Reader,
    saved: header.Header,
) !void {
    try session.restoreSaved(reader, audio);
    if (try reader.integer(u32) != 0) return error.UnsupportedSavedSpawnClient;

    const stats = try header.Statistics.read(reader);

    try reader.end();
    statistics.apply(session, stats);

    if (stats.accumulated) |values| startup.accumulated_stats = values;

    startup.engine = saved.engine;
    try palette.apply(session, saved.palette);
}
