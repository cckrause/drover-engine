//! Campaign movies: completion, cancellation, consecutive entries and the disc each one asks for.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const campaign = @import("../campaign.zig");
const lab = @import("../assets/lab.zig");
const rcp = @import("../assets/rcp.zig");
const Session = @import("../render/session.zig").Session;

fn readArchive() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", std.testing.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn parsedStartup(text: []const u8) !campaign.Startup {
    const recipe = try rcp.Recipe.parse(std.testing.allocator, text);
    errdefer recipe.deinit(std.testing.allocator);
    if (recipe.story.len == 0) return error.EmptyCampaign;
    return .{
        .request = try campaign.StartRequest.init("TEST"),
        .difficulty = .good,
        .recipe = recipe,
        .recipe_loaded = true,
        .first_event = recipe.story[0],
        .router = .init(std.testing.allocator),
        .database = .init(std.testing.allocator),
    };
}

test "campaign movie completion and cancellation gate the reference first level" {
    const allocator = std.testing.allocator;
    const bytes = try readArchive();
    defer allocator.free(bytes);
    const archive = try lab.Archive.init(bytes);
    for ([_]campaign.Difficulty{ .good, .bad, .ugly }) |difficulty| {
        for ([_]bool{ false, true }) |cancelled| {
            var startup = try campaign.Startup.prepare(allocator, archive, difficulty);
            defer startup.deinit(allocator);
            try std.testing.expectEqualStrings("in_shb.san", startup.currentEvent().?.name);
            try std.testing.expectEqual(@as(?usize, 0), startup.story_index);
            try std.testing.expectError(error.MoviePlaybackPending, startup.selectLevel());
            try std.testing.expectError(error.MoviePlaybackPending, Session.open(allocator, std.testing.io, "missing/OUTLAWS.LAB", archive, &startup));
            try std.testing.expectEqual(@as(?usize, 0), startup.story_index);
            try std.testing.expect(startup.selected_level == null);
            try std.testing.expectEqual(@as(usize, 0), startup.skipped_movies);
            try std.testing.expectEqual(@as(usize, 0), startup.completed_movies + startup.cancelled_movies);

            try startup.finishMovie(cancelled);
            try std.testing.expectEqual(@as(?usize, 1), startup.story_index);
            try std.testing.expectEqual(@as(usize, @intFromBool(!cancelled)), startup.completed_movies);
            try std.testing.expectEqual(@as(usize, @intFromBool(cancelled)), startup.cancelled_movies);
            try std.testing.expectEqual(@as(usize, 0), startup.skipped_movies);
            try std.testing.expect(startup.selected_level == null);
            const level = try startup.selectLevel();
            try std.testing.expectEqual(rcp.Kind.level, level.kind);
            try std.testing.expectEqualStrings("hideout", level.name);
            try std.testing.expectEqual(@as(u8, 1), level.disc);
            try std.testing.expectEqualStrings("in_shb.san", startup.first_event.name);
            try std.testing.expectEqual(difficulty, startup.difficulty);
            try std.testing.expectError(error.CurrentEventIsNotMovie, startup.finishMovie(!cancelled));
            try std.testing.expectError(error.LevelAlreadySelected, startup.selectLevel());
            try std.testing.expectEqual(@as(usize, 1), startup.completed_movies + startup.cancelled_movies);
            try std.testing.expectEqual(@as(?usize, 1), startup.story_index);
        }
    }
}

test "campaign diagnostic level selection records its explicit movie bypass" {
    const allocator = std.testing.allocator;
    const bytes = try readArchive();
    defer allocator.free(bytes);
    var startup = try campaign.Startup.prepare(allocator, try lab.Archive.init(bytes), .good);
    defer startup.deinit(allocator);
    try std.testing.expectError(error.MoviePlaybackPending, startup.selectLevel());
    const level = try startup.levelForDiagnostics();
    try std.testing.expectEqualStrings("hideout", level.name);
    try std.testing.expectEqual(@as(?usize, 1), startup.story_index);
    try std.testing.expectEqual(@as(usize, 1), startup.skipped_movies);
    try std.testing.expectEqual(@as(usize, 0), startup.completed_movies);
    try std.testing.expectEqual(@as(usize, 0), startup.cancelled_movies);
    try std.testing.expectEqualStrings("in_shb.san", startup.first_event.name);
    try std.testing.expectError(error.LevelAlreadySelected, startup.levelForDiagnostics());
    try std.testing.expectEqual(@as(usize, 1), startup.skipped_movies);
}

test "campaign consecutive movie entries advance individually and preserve requested discs" {
    var startup = try parsedStartup(
        \\RCP 1.0
        \\NAME: Sequence test
        \\STORY:
        \\BEGIN
        \\MOVIE: first.san 1
        \\MOVIE: second.san 2
        \\LEVEL: hideout 2
        \\END
    );
    defer startup.deinit(std.testing.allocator);
    try startup.finishMovie(false);
    try std.testing.expectEqual(@as(?usize, 1), startup.story_index);
    try std.testing.expectEqualStrings("second.san", startup.currentEvent().?.name);
    try std.testing.expectEqual(@as(u8, 2), startup.currentEvent().?.disc);
    try std.testing.expectError(error.MoviePlaybackPending, startup.selectLevel());
    try std.testing.expectEqual(@as(usize, 1), startup.completed_movies);
    try std.testing.expectEqual(@as(usize, 0), startup.cancelled_movies);
    try startup.finishMovie(true);
    try std.testing.expectEqual(@as(?usize, 2), startup.story_index);
    const level = try startup.selectLevel();
    try std.testing.expectEqualStrings("hideout", level.name);
    try std.testing.expectEqual(@as(u8, 2), level.disc);
    try std.testing.expectEqual(@as(usize, 1), startup.completed_movies);
    try std.testing.expectEqual(@as(usize, 1), startup.cancelled_movies);
    try std.testing.expectEqual(@as(usize, 0), startup.skipped_movies);
}

test "campaign exhaustion after its last movie cannot restart the sequence" {
    var startup = try parsedStartup(
        \\RCP 1.0
        \\STORY:
        \\BEGIN
        \\MOVIE: only.san 1
        \\END
    );
    defer startup.deinit(std.testing.allocator);
    try startup.finishMovie(false);
    try std.testing.expect(startup.currentEvent() == null);
    try std.testing.expectEqual(@as(?usize, null), startup.story_index);
    try std.testing.expectError(error.CampaignExhausted, startup.finishMovie(true));
    try std.testing.expectError(error.CampaignHasNoLevel, startup.selectLevel());
    try std.testing.expectError(error.CampaignHasNoLevel, startup.levelForDiagnostics());
    try std.testing.expect(startup.currentEvent() == null);
    try std.testing.expectEqual(@as(usize, 1), startup.completed_movies);
    try std.testing.expectEqual(@as(usize, 0), startup.cancelled_movies);
    try std.testing.expectEqual(@as(usize, 0), startup.skipped_movies);
}
