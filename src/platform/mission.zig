//! Mounting the archive set of a given disc, and the build option that
//! starts a chosen mission directly.
//!
//! A disc is selected before the story callback runs, and disc zero means
//! "whatever is mounted". All resources of a mission come from one disc; a
//! missing or malformed asset is an error rather than a lookup that falls
//! through to another disc.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const title = @import("../game/title.zig");

pub const Mounts = struct {
    arena: std.heap.ArenaAllocator,
    initial_path: []const u8,
    initial_system: lab.Archive,
    second_path: ?[]const u8 = null,
    second_system: ?lab.Archive = null,
    active: u8 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        initial_path: []const u8,
        initial_system: lab.Archive,
    ) Mounts {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .initial_path = initial_path,
            .initial_system = initial_system,
        };
    }

    pub fn deinit(self: *Mounts) void {
        self.arena.deinit();
    }

    pub fn selectDisc(self: *Mounts, io: std.Io, disc: u8) !void {
        if (disc == 0 or disc == self.active) return;
        if (disc != 1 and disc != 2) return error.UnsupportedCampaignDisc;

        if (disc == 2 and self.second_system == null) {
            const a = self.arena.allocator();
            const second_path = try dataPath(a, self.initial_path, 2);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(
                io,
                second_path,
                a,
                .limited(64 * 1024 * 1024),
            );

            self.second_system = try lab.Archive.init(bytes);
            self.second_system.?.front = self.initial_system.front;
            self.second_path = second_path;
        }

        self.active = disc;
    }

    pub fn path(self: *const Mounts) []const u8 {
        return if (self.active == 2) self.second_path.? else self.initial_path;
    }

    pub fn system(self: *const Mounts) lab.Archive {
        return if (self.active == 2) self.second_system.? else self.initial_system;
    }
};

pub fn dataPath(allocator: std.mem.Allocator, initial_data_path: []const u8, disc: u8) ![]u8 {
    return title.current.discPath(allocator, initial_data_path, disc);
}

pub fn moviePath(
    allocator: std.mem.Allocator,
    initial_data_path: []const u8,
    event: @import("../assets/rcp.zig").Entry,
) ![]u8 {
    const mounted = try dataPath(allocator, initial_data_path, event.disc);
    defer allocator.free(mounted);
    const filename = try allocator.dupe(u8, event.name);
    defer allocator.free(filename);

    _ = std.ascii.upperString(filename, filename);

    return std.fs.path.join(allocator, &.{ std.fs.path.dirname(mounted) orelse ".", filename });
}

pub fn select(startup: *campaign.Startup, name: []const u8) !void {
    if (startup.selected_level != null or startup.story_index != 0 or
        startup.completed_movies != 0 or startup.cancelled_movies != 0 or startup.skipped_movies != 0)
        return error.CampaignAlreadyStarted;

    var beginning: usize = 0;

    for (startup.recipe.story, 0..) |entry, index| {
        if (entry.kind != .level) continue;

        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            startup.story_index = beginning;
            startup.first_event = startup.recipe.story[beginning];
            return;
        }

        beginning = index + 1;
    }

    return error.MissionNotInCampaign;
}

test "Town and Train builds keep the reference intro, launch record and ordered campaign" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB",
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(bytes);
    const Mission = struct {
        name: []const u8,
        movie: []const u8,
        index: usize,
    };

    for ([_]Mission{
        .{ .name = "town", .movie = "she_tob.san", .index = 2 },
        .{ .name = "train", .movie = "toe_trb.san", .index = 4 },
    }) |mission| for ([_]bool{ false, true }) |cancelled| {
        var startup = try campaign.Startup.prepare(allocator, archive, .good);
        defer startup.deinit(allocator);
        const request = startup.request;

        try std.testing.expectError(error.MissionNotInCampaign, select(&startup, "unknown"));
        try std.testing.expectEqual(@as(?usize, 0), startup.story_index);

        try select(&startup, mission.name);

        try std.testing.expectEqual(@as(usize, 19), startup.recipe.story.len);
        try std.testing.expectEqual(@as(?usize, mission.index), startup.story_index);
        try std.testing.expectEqualStrings("in_shb.san", startup.recipe.story[0].name);
        try std.testing.expectEqualStrings(mission.movie, startup.first_event.name);
        try std.testing.expectEqualDeep(request, startup.request);
        try std.testing.expectError(error.MoviePlaybackPending, startup.selectLevel());

        try startup.finishMovie(cancelled);
        const level = try startup.selectLevel();

        try std.testing.expectEqualStrings(mission.name, level.name);
        try std.testing.expectEqual(@as(u8, 1), level.disc);
        try std.testing.expectEqual(@as(usize, 0), startup.skipped_movies);
        try std.testing.expectError(error.CampaignAlreadyStarted, select(&startup, "hideout"));
    };
}

test "Town and Train missions load actors and advance at every difficulty" {
    const allocator = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(bytes);
    const pixels = try allocator.alloc(u8, 640 * 480);
    defer allocator.free(pixels);

    for ([_][]const u8{
        "town",
        "train",
    }) |name| for ([_]campaign.Difficulty{ .good, .bad, .ugly }) |difficulty| {
        var startup = try campaign.Startup.prepare(allocator, archive, difficulty);
        defer startup.deinit(allocator);

        try select(&startup, name);
        try startup.finishMovie(true);

        const session = try @import(
            "../render/session.zig",
        ).Session.open(
            allocator,
            @import("../render/test_workspace.zig").get(),
            std.testing.io,
            path,
            archive,
            &startup,
        );

        defer session.deinit(allocator);

        try std.testing.expectEqualStrings(name, session.level_name);

        if (std.mem.eql(u8, name, "town")) {
            try std.testing.expectEqual(
                @as(u32, 0x9cb1f272),
                session.level.sectors[session.spawn.sector].id,
            );

            try std.testing.expectEqual(@as(f32, 67.78), session.spawn.position.x);
            try std.testing.expectEqual(@as(f32, 0), session.spawn.position.y);
            try std.testing.expectEqual(@as(f32, 36.39), session.spawn.position.z);
        }

        _ = try session.render(pixels, 0);
        var input: @import("../player/input.zig").State = .{ .previous_time = 1000 };

        for (0..if (std.mem.eql(u8, name, "town")) @as(usize, 120) else 3) |tick| {
            const now: u32 = 1016 + @as(u32, @intCast(tick)) * 16;
            const packet = try input.sample(now, .{});
            try session.advance(allocator, &packet, 16);
            _ = try session.render(pixels, now);
        }

        var civilians: usize = 0;
        var bloodeye: usize = 0;
        var sanchez: usize = 0;

        for (session.actors) |actor| {
            if (std.mem.eql(u8, actor.logic_name, "Civilian_New")) civilians += 1;
            if (std.mem.eql(u8, actor.logic_name, "Bloodeye_New")) bloodeye += 1;
            if (std.mem.eql(u8, actor.logic_name, "Sanchez_New")) sanchez += 1;
        }

        if (std.mem.eql(
            u8,
            name,
            "train",
        )) try std.testing.expect(civilians != 0 and bloodeye != 0);

        if (std.mem.eql(u8, name, "town")) {
            const total: f32 = switch (difficulty) {
                .good => 90,
                .bad => 94,
                .ugly => 84,
                .unpicked => unreachable,
            };

            try std.testing.expectEqual(total, session.enemy_shared.total_enemies);
            try std.testing.expectEqual(@as(f32, 0), session.enemy_shared.killed_enemies);
            try std.testing.expectEqual(@as(usize, 10), civilians);
            try std.testing.expectEqual(@as(usize, 1), sanchez);

            const sites = session.sanchez_sites.?;

            try std.testing.expectEqual(@as(usize, if (difficulty == .good) 15 else 14), sites.len);
            try std.testing.expectEqual(
                @as(u32, if (difficulty == .good) 0x9cb21867 else 0x9cb1f1d8),
                session.objects.entries[sites[0].source].id,
            );

            try std.testing.expectEqual(
                @as(u32, 0x9cb1e594),
                session.level.sectors[sites[0].sector].id,
            );

            try std.testing.expect(session.targets[sites[0].source].?.sanchez);

            for (sites[1..]) |site| {
                try std.testing.expect(session.removed_actors[site.source]);
                try std.testing.expect(session.actor_slots[site.source] == null);
                try std.testing.expect(session.targets[site.source] == null);
            }
        }
    };
}
