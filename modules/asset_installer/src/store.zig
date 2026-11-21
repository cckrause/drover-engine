//! Persistent installation state. No imports from the game or other modules.
const std = @import("std");
const media = @import("media.zig");
const A = std.mem.Allocator;
const Dir = std.Io.Dir;
pub const Kind = enum { retail, demo };
pub const archives = [_][]const u8{ "OUTLAWS.LAB", "OLGEO.LAB", "OLTEX.LAB", "OLOBJ.LAB", "OLWEAP.LAB", "OLSFX.LAB", "OLTAUNT.LAB" };
const movies = [_][]const []const u8{
    &.{ "IN_SHB.SAN", "SHE_TOB.SAN", "TOE_TRB.SAN", "TRE_CAB.SAN", "CAE_SAB.SAN" },
    &.{ "SAE_HIB.SAN", "HIE_MNB.SAN", "MNE_CLB.SAN", "CLE_RAB.SAN", "RAM.SAN", "RAE.SAN" },
};
const common_hashes = [_][]const u8{
    "978b5d6ec53fc0b3d83f65cd32d3e5fbac2ed7dd6e45352f61bb67ce89c2dfc0", "",
    "66a188214bf1b05b8dd49bc0e10b963df6b1d348746face200f6859bc4dc934d", "6e9d9d9e621985e1a009fc93f9f90f65c4da7bd0401c27d657a6095139bc5652",
    "0d1f2afd138924e80c1be879ee3d14298db3f61604729487a562f3f5d2f47c07", "6ade7e39b27f3c38d7a1390df5fae6d8a85ac819eb7d62d82952b82ddb37794f",
    "0a1f5f3a289206dafabae786eec14a8a6eddcb6d38cdef0352107d6b7595b286",
};
fn retailHash(index: usize, disc: u8) []const u8 {
    return if (index != 1) common_hashes[index] else if (disc == 1) "ca69fb4baecc973db1db4d5a1acdd755da9ca30652b4fa98ce759784fd57be4f" else "71180be5c3177ed4495df22b51fefa9d503f23dc4b27148512d56aa568ac2b7f";
}
pub const Store = struct {
    a: A,
    io: std.Io,
    root: Dir,
    path: []u8,
    pub fn init(a: A, io: std.Io, path: []const u8) !Store {
        const root = try Dir.cwd().createDirPathOpen(io, path, .{});
        errdefer root.close(io);
        return .{ .a = a, .io = io, .root = root, .path = try a.dupe(u8, path) };
    }
    pub fn deinit(self: *Store) void {
        self.root.close(self.io);
        self.a.free(self.path);
    }
    pub fn dataPath(self: *const Store, kind: Kind) ![]u8 {
        return std.fs.path.join(self.a, &.{ self.path, @tagName(kind), "OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB" });
    }
    fn lock(self: *const Store) !std.Io.File {
        const file = try self.root.createFile(self.io, "install.lock", .{ .truncate = false });
        errdefer file.close(self.io);
        if (!try file.tryLock(self.io, .exclusive)) return error.AnotherInstallationIsRunning;
        return file;
    }
    /// A manifest is published last, by renaming a complete staging directory.
    /// Verify the complete required set and SHA-256 before a game launch.
    pub fn installed(self: *const Store, kind: Kind) !bool {
        return self.installedAt(@tagName(kind), kind);
    }
    fn installedAt(self: *const Store, directory: []const u8, kind: Kind) !bool {
        const name = try std.fmt.allocPrint(self.a, "{s}/installed.txt", .{directory});
        defer self.a.free(name);
        const text = self.root.readFileAlloc(self.io, name, self.a, .limited(32 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.a.free(text);
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        if (!std.mem.eql(u8, lines.next() orelse return false, "OUTLAWS-ASSETS-1")) return false;
        var seen: u32 = 0;
        while (lines.next()) |line| {
            if (line.len < 66 or line[64] != ' ') return false;
            const relative = line[65..];
            const index = requiredIndex(kind, relative) orelse return false;
            const bit = @as(u32, 1) << index;
            if (seen & bit != 0) return false;
            seen |= bit;
            const path = try std.fs.path.join(self.a, &.{ directory, relative });
            defer self.a.free(path);
            const data = self.root.readFileAlloc(self.io, path, self.a, .limited(512 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            defer self.a.free(data);
            if (!std.mem.eql(u8, &media.hash(data), line[0..64])) return false;
        }
        return seen == (if (kind == .demo) @as(u32, 0x1ff) else 0x1ffffff);
    }
    fn requiredIndex(kind: Kind, path: []const u8) ?u5 {
        const prefix1 = "OUTLAWS_CD1/OUTLAWS/";
        const prefix2 = "OUTLAWS_CD2/OUTLAWS/";
        const second = std.mem.startsWith(u8, path, prefix2);
        if ((!second and !std.mem.startsWith(u8, path, prefix1)) or (second and kind == .demo)) return null;
        const name = path[prefix1.len..];
        const offset: usize = if (second) 12 else 0;
        for (archives, 0..) |archive, i| if (std.mem.eql(u8, name, archive)) return @intCast(offset + i);
        const list: []const []const u8 = if (kind == .demo) &.{ "START.SAN", "END.SAN" } else movies[@intFromBool(second)];
        for (list, 0..) |movie, i| if (std.mem.eql(u8, name, movie)) return @intCast(offset + archives.len + i);
        return null;
    }
    fn add(self: *const Store, stage: Dir, manifest: *std.Io.Writer.Allocating, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try stage.createDirPath(self.io, parent);
        try stage.writeFile(self.io, .{ .sub_path = path, .data = data });
        try manifest.writer.print("{s} {s}\n", .{ media.hash(data), path });
    }
    fn publish(self: *const Store, stage: []const u8, kind: Kind, manifest: []const u8) !void {
        var directory = try self.root.openDir(self.io, stage, .{});
        defer directory.close(self.io);
        try directory.writeFile(self.io, .{ .sub_path = "installed.txt", .data = manifest });
        if (!try self.installedAt(stage, kind)) return error.InvalidStagedInstallation;
        // Only replace an incomplete/corrupt installation. A complete retail
        // install is never modified by the demo or a failed disc import.
        if (try self.installed(kind)) {
            try self.root.deleteTree(self.io, stage);
            return;
        }
        try self.root.deleteTree(self.io, @tagName(kind));
        try self.root.rename(stage, self.root, @tagName(kind), self.io);
    }
    pub fn installDemo(self: *const Store, exe: []const u8) !void {
        const guard = try self.lock();
        defer guard.close(self.io);
        if (exe.len != media.demo_size or !std.mem.eql(u8, &media.hash(exe), media.demo_hash)) return error.DemoIntegrityCheckFailed;
        const stage = "demo-staging";
        try self.root.deleteTree(self.io, stage);
        var directory = try self.root.createDirPathOpen(self.io, stage, .{});
        defer directory.close(self.io);
        defer self.root.deleteTree(self.io, stage) catch {};
        var manifest = std.Io.Writer.Allocating.init(self.a);
        defer manifest.deinit();
        try manifest.writer.writeAll("OUTLAWS-ASSETS-1\n");
        for ([_][]const u8{ "OUTLAWS.LAB", "START.SAN", "END.SAN" }) |name| {
            const data = try media.demoAsset(self.a, exe, name);
            defer self.a.free(data);
            if (std.mem.endsWith(u8, name, ".LAB")) try media.validateLab(data) else try media.validateMovie(data);
            const path = try std.fs.path.join(self.a, &.{ "OUTLAWS_CD1/OUTLAWS", name });
            defer self.a.free(path);
            try self.add(directory, &manifest, path, data);
            if (std.mem.eql(u8, name, "OUTLAWS.LAB")) for (archives[1..]) |alias| {
                const dest = try std.fs.path.join(self.a, &.{ "OUTLAWS_CD1/OUTLAWS", alias });
                defer self.a.free(dest);
                // One combined original demo archive; aliases only adapt its
                // on-disk layout. No resources are modified or fabricated.
                try directory.hardLink(path, directory, dest, self.io, .{});
                try manifest.writer.print("{s} {s}\n", .{ media.hash(data), dest });
            };
        }
        try self.publish(stage, .demo, manifest.written());
    }
    pub const ImportResult = enum { need_disc_1, need_disc_2, complete, demo };
    pub fn importFile(self: *const Store, path: []const u8) !ImportResult {
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".exe")) {
            const bytes = try Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(media.demo_size + 1));
            defer self.a.free(bytes);
            try self.installDemo(bytes);
            return .demo;
        }
        const guard = try self.lock();
        defer guard.close(self.io);
        const ext = std.fs.path.extension(path);
        if (!std.ascii.eqlIgnoreCase(ext, ".iso") and !std.ascii.eqlIgnoreCase(ext, ".bin") and !std.ascii.eqlIgnoreCase(ext, ".mdf")) return error.UnsupportedDiscFormat;
        var disc = try media.Disc.open(self.a, self.io, path);
        defer disc.deinit();
        const stage = "disc-staging";
        try self.root.deleteTree(self.io, stage);
        var directory = try self.root.createDirPathOpen(self.io, stage, .{});
        defer directory.close(self.io);
        defer self.root.deleteTree(self.io, stage) catch {};
        var manifest = std.Io.Writer.Allocating.init(self.a);
        defer manifest.deinit();
        for (archives, 0..) |name, i| {
            const source = try std.fs.path.join(self.a, &.{ "OUTLAWS", name });
            defer self.a.free(source);
            const data = try disc.asset(source);
            defer self.a.free(data);
            try media.validateLab(data);
            if (!std.mem.eql(u8, &media.hash(data), retailHash(i, disc.number))) return error.UnsupportedRetailAssetRevision;
            try self.add(directory, &manifest, source, data);
        }
        for (movies[disc.number - 1]) |name| {
            const source = try std.fs.path.join(self.a, &.{ "OUTLAWS", name });
            defer self.a.free(source);
            const data = try disc.asset(source);
            defer self.a.free(data);
            try media.validateMovie(data);
            try self.add(directory, &manifest, source, data);
        }
        try directory.writeFile(self.io, .{ .sub_path = "disc.txt", .data = manifest.written() });
        try self.root.createDirPath(self.io, "retail-pending");
        const dest = try std.fmt.allocPrint(self.a, "retail-pending/OUTLAWS_CD{d}", .{disc.number});
        defer self.a.free(dest);
        try self.root.deleteTree(self.io, dest);
        try self.root.rename(stage, self.root, dest, self.io);
        var complete = std.Io.Writer.Allocating.init(self.a);
        defer complete.deinit();
        try complete.writer.writeAll("OUTLAWS-ASSETS-1\n");
        for (1..3) |number| {
            const filename = try std.fmt.allocPrint(self.a, "retail-pending/OUTLAWS_CD{d}/disc.txt", .{number});
            defer self.a.free(filename);
            const text = self.root.readFileAlloc(self.io, filename, self.a, .limited(16 * 1024)) catch |err| switch (err) {
                error.FileNotFound => return if (number == 1) .need_disc_1 else .need_disc_2,
                else => return err,
            };
            defer self.a.free(text);
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (line.len < 66 or line[64] != ' ') return error.InvalidStagedDisc;
                try complete.writer.print("{s} OUTLAWS_CD{d}/{s}\n", .{ line[0..64], number, line[65..] });
            }
        }
        try self.publish("retail-pending", .retail, complete.written());
        if (!try self.installed(.retail)) return error.InvalidStagedDisc;
        return .complete;
    }
    pub fn downloadDemo(self: *const Store) !void {
        var client = std.http.Client{ .allocator = self.a, .io = self.io };
        defer client.deinit();
        const bytes = try self.a.alloc(u8, media.demo_size);
        defer self.a.free(bytes);
        var output = std.Io.Writer.fixed(bytes);
        const result = try client.fetch(.{ .location = .{ .url = media.demo_url }, .response_writer = &output });
        if (result.status != .ok) return error.DemoDownloadFailed;
        try self.installDemo(output.buffered());
    }
};
