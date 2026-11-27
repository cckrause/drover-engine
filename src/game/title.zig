//! Per-title configuration. The engine itself is title-agnostic: every game
//! name, archive name and disc path it needs comes from here, so adding a
//! second title means adding a `Title` value, not touching engine code.
//!
//! Only the names the engine really reads belong here. Level lists, actor
//! tables and menu layouts live in the data files and must not be duplicated.

const std = @import("std");

/// Everything the engine needs to know about one game before it opens a file.
pub const Title = struct {
    /// Window caption, and the macOS bundle name.
    name: []const u8,
    /// The archive mounted for the whole session: menus, fonts, story files,
    /// shared sounds. Its directory is where every other archive is looked up.
    system_archive: []const u8,
    /// Mounted when a level loads, in this order. The engine reads them by
    /// role, so the order of the fields matters, not the names.
    level_archives: LevelArchives,
    /// Mounted next to the system archive and searched after it for sounds.
    sound_archives: []const []const u8,
    /// Where the data lies when nobody passed `--data`, relative to the
    /// working directory.
    default_data_path: []const u8,
    /// Directory names of the installed discs, in disc order starting at 1.
    /// A story event that asks for disc 2 remounts from `discs[1]`.
    discs: []const []const u8,
    /// The subdirectory holding the archives inside an installed disc.
    disc_data_directory: []const u8,

    pub const LevelArchives = struct {
        geometry: []const u8,
        textures: []const u8,
        objects: []const u8,
        weapons: []const u8,
    };

    /// Path to `system_archive` on another disc, derived from the path the
    /// first disc was mounted from. Caller frees.
    pub fn discPath(
        self: Title,
        allocator: std.mem.Allocator,
        mounted_path: []const u8,
        disc: u8,
    ) ![]u8 {
        if (disc == 0 or disc == 1) return allocator.dupe(u8, mounted_path);
        if (disc > self.discs.len) return error.UnsupportedCampaignDisc;

        const directory = std.fs.path.dirname(mounted_path) orelse ".";

        return std.fs.path.resolve(allocator, &.{
            directory,
            "..",
            "..",
            self.discs[disc - 1],
            self.disc_data_directory,
            self.system_archive,
        });
    }

    /// Path to the data installed inside a macOS application bundle, relative
    /// to the directory holding the executable. Caller frees.
    pub fn bundledDataPath(
        self: Title,
        allocator: std.mem.Allocator,
        executable_directory: []const u8,
    ) ![]u8 {
        return std.fs.path.resolve(allocator, &.{
            executable_directory,
            "../Resources/data",
            self.discs[0],
            self.disc_data_directory,
            self.system_archive,
        });
    }
};

/// The title this build runs. One day this becomes a build option.
pub const current: Title = .{
    .name = "Outlaws",
    .system_archive = "OUTLAWS.LAB",
    .level_archives = .{
        .geometry = "OLGEO.LAB",
        .textures = "OLTEX.LAB",
        .objects = "OLOBJ.LAB",
        .weapons = "OLWEAP.LAB",
    },
    .sound_archives = &.{ "OLSFX.LAB", "OLTAUNT.LAB" },
    .default_data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB",
    .discs = &.{ "OUTLAWS_CD1", "OUTLAWS_CD2" },
    .disc_data_directory = "OUTLAWS",
};

test "disc 2 resolves next to the first disc" {
    const path = try current.discPath(
        std.testing.allocator,
        "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB",
        2,
    );

    defer std.testing.allocator.free(path);

    try std.testing.expect(std.mem.endsWith(u8, path, "inputs/OUTLAWS_CD2/OUTLAWS/OUTLAWS.LAB"));
}

test "disc 0 and 1 keep the mounted path" {
    for ([_]u8{ 0, 1 }) |disc| {
        const path = try current.discPath(std.testing.allocator, "data/OUTLAWS.LAB", disc);
        defer std.testing.allocator.free(path);
        try std.testing.expectEqualStrings("data/OUTLAWS.LAB", path);
    }
}

test "an unknown disc is rejected" {
    try std.testing.expectError(
        error.UnsupportedCampaignDisc,
        current.discPath(std.testing.allocator, "data/OUTLAWS.LAB", 3),
    );
}
