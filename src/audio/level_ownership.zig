//! Who owns which registered sound in a level, so that unloading releases
//! exactly what it should.
//!
//! Item handles, texture resources, sector floors and the level's point
//! sounds all have a matching release. Script sounds do not, so they must
//! not be counted as owned here or they would be freed twice.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");

pub const Ownership = struct {
    item_sounds: [4]?[]const u8 = @splat(null),
    atx_sounds: []const []const u8 = &.{},
    floor_sounds: []?[]const u8 = &.{},
    point_sounds: []const []const u8 = &.{},

    pub fn init(self: *Ownership, session: anytype, restoring: bool) !void {
        try self.initGeometry(session);
        const a = session.arena.allocator();
        if (restoring) return;
        const name = try std.fmt.allocPrint(a, "{s}.ITM", .{session.level_name});
        const archives = [_]lab.Archive{ session.object_archive, session.weapon_archive, session.geometry_archive, session.system_archive };
        if (try find(&archives, name)) |bytes| {
            var definition = try Item.parse(a, bytes);
            defer definition.deinit();
            inline for (.{ "SND_REDWON", "SND_BLUEWON", "SND_DOCWON", "SND_TAGTRANS" }, 0..) |key, index| {
                self.item_sounds[index] = if (try definition.stringValue(key)) |stem| try wav(a, stem) else switch (index) {
                    0 => "hornblo4.wav",
                    1 => "hornblo1.wav",
                    else => null,
                };
            }
        } else {
            self.item_sounds[0] = "hornblo1.wav";
        }
        var points: std.ArrayList([]const u8) = .empty;
        for (session.objects.entries) |object| {
            if (object.flags[0] & 1 == 0 or object.flags[1] & session.difficulty_mask == 0 or session.level.sectorIndex(object.sector_id) == null) continue;
            try points.append(a, try wav(a, object.name));
        }
        self.point_sounds = try points.toOwnedSlice(a);
    }

    pub fn release(self: *Ownership, session: anytype) void {
        for (&self.item_sounds) |*name| if (name.*) |value| {
            session.releaseSound(value);
            name.* = null;
        };
        for (self.atx_sounds) |name| session.releaseSound(name);
        self.atx_sounds = &.{};
        for (self.floor_sounds, 0..) |*name, sector| {
            session.closeSectorSoundOwners(sector);
            if (name.*) |value| {
                session.releaseSound(value);
                name.* = null;
            }
        }
        self.floor_sounds = &.{};
        for (self.point_sounds) |name| session.releaseSound(name);
        self.point_sounds = &.{};
    }

    fn initGeometry(self: *Ownership, session: anytype) !void {
        const a = session.arena.allocator();
        self.floor_sounds = try a.alloc(?[]const u8, session.level.sectors.len);
        for (session.level.sectors, self.floor_sounds) |sector, *name| {
            name.* = if (sector.floor_sound.len == 0 or std.mem.eql(u8, sector.floor_sound, "NULL")) null else try wav(a, sector.floor_sound);
        }
        var atx_sounds: std.ArrayList([]const u8) = .empty;
        for (session.texture_animations.programs, 0..) |program, index| if (program) |value| {
            if (!lastTextureUse(session.level.textures, index)) continue;
            var pc = value.animation.instructions.len;
            while (pc != 0) {
                pc -= 1;
                const instruction = value.animation.instructions[pc];
                if (instruction == .start_sound) try atx_sounds.append(a, try wav(a, instruction.start_sound.name));
            }
        };
        self.atx_sounds = try atx_sounds.toOwnedSlice(a);
    }
};

pub fn firstTextureUse(names: []const []const u8, index: usize) bool {
    for (names[0..index]) |name| if (std.ascii.eqlIgnoreCase(name, names[index])) return false;
    return true;
}

fn lastTextureUse(names: []const []const u8, index: usize) bool {
    for (names[index + 1 ..]) |name| if (std.ascii.eqlIgnoreCase(name, names[index])) return false;
    return true;
}

fn wav(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}.wav", .{name});
}

fn find(archives: []const lab.Archive, name: []const u8) !?[]const u8 {
    for (archives) |archive| return archive.find(name, 0) catch |err| switch (err) {
        error.ResourceNotFound => continue,
        else => return err,
    };
    return null;
}

test "level sound ownership follows level sector and ATX destructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/level-sound-ownership-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Case = struct {
        programs: []struct { name: []const u8, source_sha256: []const u8 },
        item_sounds: [4]?[]const u8,
        floor_sounds: []?[]const u8,
        point_sounds: [][]const u8,
        released: [][]const u8,
    };
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []Case };
    const corpus = (try std.json.parseFromSlice(Corpus, a, bytes, .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("b115aded7e073eff4f275073bf2e96f0ade0a5a9abdb7054becd7e9dc98b8508", corpus.results_sha256);
    const archive = try lab.Archive.init(try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD2/OUTLAWS/OLTEX.LAB", a, .limited(128 * 1024 * 1024)));
    const Program = struct { animation: @import("../assets/atx.zig").Animation };
    const Sector = struct { floor_sound: []const u8 };
    const Capture = struct {
        arena: *std.heap.ArenaAllocator,
        level: struct { sectors: []Sector, textures: [][]const u8 },
        texture_animations: struct { programs: []?Program },
        released: [64][]const u8 = undefined,
        count: usize = 0,
        closed_sectors: usize = 0,

        pub fn releaseSound(self: *@This(), name: []const u8) void {
            self.released[self.count] = name;
            self.count += 1;
        }

        pub fn closeSectorSoundOwners(self: *@This(), sector: usize) void {
            std.debug.assert(self.closed_sectors == sector);
            self.closed_sectors += 1;
        }
    };
    for (corpus.cases) |case| {
        var capture = Capture{
            .arena = &arena,
            .level = .{ .sectors = try a.alloc(Sector, case.floor_sounds.len), .textures = try a.alloc([]const u8, case.programs.len) },
            .texture_animations = .{ .programs = try a.alloc(?Program, case.programs.len) },
        };
        for (case.floor_sounds, capture.level.sectors) |name, *sector| sector.floor_sound = if (name) |full| full[0 .. full.len - 4] else "NULL";
        for (case.programs, capture.level.textures, capture.texture_animations.programs) |program, *name, *value| {
            name.* = program.name;
            const source = try archive.find(program.name, 0);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
            try std.testing.expectEqualStrings(program.source_sha256, &std.fmt.bytesToHex(digest, .lower));
            value.* = .{ .animation = try @import("../assets/atx.zig").Animation.parse(a, source) };
        }
        var owner: Ownership = .{ .item_sounds = case.item_sounds, .point_sounds = case.point_sounds };
        try owner.initGeometry(&capture);
        owner.release(&capture);
        try std.testing.expectEqual(case.floor_sounds.len, capture.closed_sectors);
        try std.testing.expectEqual(case.released.len, capture.count);
        for (case.released, capture.released[0..capture.count]) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
        owner.release(&capture);
        try std.testing.expectEqual(case.released.len, capture.count);
    }
}
