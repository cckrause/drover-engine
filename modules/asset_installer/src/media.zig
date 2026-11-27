//! Host media preflight; independent of the game's LAB and movie decoders.
const std = @import("std");
const A = std.mem.Allocator;

pub fn read16(p: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, p[at..][0..2], .little);
}

pub fn read32(p: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, p[at..][0..4], .little);
}

pub fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    return std.fmt.bytesToHex(digest, .lower);
}

pub fn validateLab(p: []const u8) !void {
    if (p.len < 16 or p.len > 128 * 1024 * 1024 or !std.mem.eql(
        u8,
        p[0..4],
        "LABN",
    ) or read32(p, 4) > 0x10000) return error.UnsupportedLab;

    const count: usize = read32(p, 8);
    const size: usize = read32(p, 12);
    if (count == 0 or count > (p.len - 16) / 16) return error.MalformedLab;

    const start = 16 + count * 16;
    if (size == 0 or size > p.len - start or size > 32 * 1024 * 1024 or p[start + size - 1] != 0) return error.MalformedLab;

    for (0..count) |i| {
        const r = p[16 + i * 16 ..][0..16];
        const offset = read32(r, 4);
        if (read32(
            r,
            0,
        ) >= size or offset > p.len or read32(r, 8) > p.len - offset) return error.MalformedLab;
    }
}

pub fn validateMovie(p: []const u8) !void {
    if (p.len < 790 or p.len > 512 * 1024 * 1024 or !std.mem.eql(
        u8,
        p[0..4],
        "ANIM",
    ) or std.mem.readInt(
        u32,
        p[4..8],
        .big,
    ) != p.len - 8 or !std.mem.eql(u8, p[8..12], "AHDR")) return error.MalformedMovie;

    const version = read16(p, 16);
    const frames = read16(p, 18);
    const size = std.mem.readInt(u32, p[12..16], .big);
    if ((version != 1 and version != 2) or frames == 0 or frames > 32767 or size < (if (version == 1) @as(u32, 774) else 776) or size > p.len - 16) return error.UnsupportedMovie;
}

pub const Disc = struct {
    a: A,
    io: std.Io,
    file: std.Io.File,
    stride: u32,
    payload: u32,
    sectors: u32,
    number: u8,
    entries: std.StringHashMapUnmanaged(Extent) = .empty,
    records: usize = 0,
    const Extent = struct { sector: u32, size: u32 };

    pub fn open(a: A, io: std.Io, path: []const u8) !Disc {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const size = (try file.stat(io)).size;
        var pvd: [2048]u8 = undefined;
        var stride: u32 = 2048;
        var payload: u32 = 0;

        if (try file.readPositionalAll(
            io,
            &pvd,
            16 * 2048,
        ) != 2048 or !std.mem.eql(u8, pvd[0..7], "\x01CD001\x01")) {
            stride = 2352;
            payload = 16;
            if (try file.readPositionalAll(
                io,
                &pvd,
                16 * 2352 + 16,
            ) != 2048 or !std.mem.eql(
                u8,
                pvd[0..7],
                "\x01CD001\x01",
            )) return error.UseIso9660OrRawMode1;
        }

        if (read16(
            &pvd,
            128,
        ) != 2048 or read16(
            &pvd,
            120,
        ) != 1 or read16(&pvd, 124) != 1) return error.UnsupportedIsoVolume;

        const label = std.mem.trimEnd(u8, pvd[40..72], " ");
        const number: u8 = if (std.mem.eql(
            u8,
            label,
            "OUTLAWS_1",
        )) 1 else if (std.mem.eql(
            u8,
            label,
            "OUTLAWS_2",
        )) 2 else return error.NotAnOriginalOutlawsDisc;

        const sectors = read32(&pvd, 80);
        if (sectors < 17 or sectors > size / stride or pvd[156] < 34 or pvd[181] & 2 == 0) return error.TruncatedIso;

        var self = Disc{
            .a = a,
            .io = io,
            .file = file,
            .stride = stride,
            .payload = payload,
            .sectors = sectors,
            .number = number,
        };

        errdefer self.freeEntries();

        try self.directory(.{ .sector = read32(&pvd, 158), .size = read32(&pvd, 166) }, "", &.{});

        return self;
    }

    fn freeEntries(self: *Disc) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| self.a.free(key.*);
        self.entries.deinit(self.a);
    }

    pub fn deinit(self: *Disc) void {
        self.freeEntries();
        self.file.close(self.io);
    }

    pub fn read(self: *const Disc, e: Extent) ![]u8 {
        if (e.sector >= self.sectors or (@as(
            u64,
            e.size,
        ) + 2047) / 2048 > self.sectors - e.sector) return error.IsoExtentOutsideVolume;

        const data = try self.a.alloc(u8, e.size);
        errdefer self.a.free(data);
        var at: usize = 0;
        var sector: u64 = e.sector;

        while (at < data.len) : (sector += 1) {
            const n = @min(2048, data.len - at);

            if (self.stride == 2352) {
                var header: [16]u8 = undefined;
                if (try self.file.readPositionalAll(
                    self.io,
                    &header,
                    sector * self.stride,
                ) != 16 or !std.mem.eql(
                    u8,
                    header[0..12],
                    &.{ 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0 },
                ) or header[15] != 1) return error.UnsupportedRawSector;
            }

            if (try self.file.readPositionalAll(
                self.io,
                data[at..][0..n],
                sector * self.stride + self.payload,
            ) != n) return error.TruncatedIso;

            at += n;
        }

        return data;
    }

    fn directory(self: *Disc, e: Extent, prefix: []const u8, ancestors: []const u32) anyerror!void {
        if (e.size > 8 * 1024 * 1024 or ancestors.len >= 16 or std.mem.indexOfScalar(
            u32,
            ancestors,
            e.sector,
        ) != null) return error.CyclicIsoDirectory;

        var chain: [16]u32 = undefined;

        @memcpy(chain[0..ancestors.len], ancestors);
        chain[ancestors.len] = e.sector;

        const data = try self.read(e);
        defer self.a.free(data);
        var at: usize = 0;

        while (at < data.len) {
            const n: usize = data[at];

            if (n == 0) {
                at = (at / 2048 + 1) * 2048;
                continue;
            }

            if (n < 34 or n > data.len - at or at % 2048 + n > 2048) return error.TruncatedIsoRecord;

            self.records += 1;
            if (self.records > 10000) return error.ExcessiveIsoDirectory;

            const r = data[at..][0..n];

            at += n;
            if (r[32] == 0 or 33 + @as(
                usize,
                r[32],
            ) > n or r[1] != 0 or r[26] != 0 or r[27] != 0 or r[25] & 0x80 != 0 or read16(
                r,
                28,
            ) != 1) return error.UnsupportedIsoRecord;

            if (r[32] == 1 and (r[33] == 0 or r[33] == 1)) continue;

            const raw = r[33..][0..r[32]];
            const name = raw[0..(std.mem.indexOfScalar(u8, raw, ';') orelse raw.len)];
            if (name.len == 0 or std.mem.eql(
                u8,
                name,
                ".",
            ) or std.mem.eql(
                u8,
                name,
                "..",
            ) or std.mem.indexOfAny(u8, name, "/\\:\x00") != null) return error.UnsafeIsoFilename;

            const path = try std.fs.path.join(self.a, &.{ prefix, name });
            errdefer self.a.free(path);

            for (path) |*ch| {
                if (ch.* < 32 or ch.* > 126) return error.UnsafeIsoFilename;
                ch.* = std.ascii.toUpper(ch.*);
            }

            const child = Extent{ .sector = read32(r, 2), .size = read32(r, 10) };

            if (r[25] & 2 != 0) {
                defer self.a.free(path);
                try self.directory(child, path, chain[0 .. ancestors.len + 1]);
            } else {
                if (self.entries.count() >= 10000 or self.entries.contains(
                    path,
                )) return error.DuplicateIsoEntry;

                try self.entries.put(self.a, path, child);
            }
        }
    }

    pub fn asset(self: *const Disc, path: []const u8) ![]u8 {
        const entry = self.entries.get(path) orelse return error.MissingDiscAsset;
        if (entry.size == 0 or entry.size > 512 * 1024 * 1024) return error.InvalidAssetSize;

        return self.read(entry);
    }
};

pub const demo_url = "https://archive.org/download/outdemo_v2/outdemo_v2.exe";
pub const demo_size = 14186356;
pub const demo_hash = "501f37aa475b6c27c87ce04e30b5207f91b81603cb376aaa9ffde1647a40e7b3";

/// The publisher's verified ZIP self-extractor. Read only the requested assets;
/// never run its executable or extract an archive-supplied filesystem path.
pub fn demoAsset(a: A, exe: []const u8, wanted: []const u8) ![]u8 {
    if (exe.len != demo_size or !std.mem.eql(
        u8,
        &hash(exe),
        demo_hash,
    )) return error.DemoIntegrityCheckFailed;

    const end = exe.len - 22;
    if (!std.mem.eql(
        u8,
        exe[end..][0..4],
        "PK\x05\x06",
    ) or read16(exe, end + 4) != 0 or read16(exe, end + 6) != 0) return error.UnsupportedDemoZip;

    var at: usize = read32(exe, end + 16);

    for (0..read16(exe, end + 10)) |_| {
        if (at > exe.len or exe.len - at < 46 or !std.mem.eql(
            u8,
            exe[at..][0..4],
            "PK\x01\x02",
        )) return error.MalformedDemoZip;

        const c = exe[at..];
        const name_len = read16(c, 28);
        const total = @as(usize, 46) + name_len + read16(c, 30) + read16(c, 32);
        if (total > c.len) return error.MalformedDemoZip;

        at += total;

        if (!std.ascii.eqlIgnoreCase(c[46..][0..name_len], wanted)) continue;

        const size = read32(c, 24);
        const compressed = read32(c, 20);
        const local: usize = read32(c, 42);
        if (size == 0 or size > 64 * 1024 * 1024 or local > exe.len or exe.len - local < 30 or read16(c, 8) & 1 != 0 or read16(c, 10) != 8) return error.UnsupportedDemoZip;

        const h = exe[local..];
        if (!std.mem.eql(u8, h[0..4], "PK\x03\x04")) return error.MalformedDemoZip;

        const start = local + 30 + read16(h, 26) + read16(h, 28);
        if (start > exe.len or compressed > exe.len - start) return error.MalformedDemoZip;

        var input = std.Io.Reader.fixed(exe[start..][0..compressed]);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decoder = std.compress.flate.Decompress.init(&input, .raw, &window);
        const data = try decoder.reader.allocRemaining(a, .limited(@as(usize, size) + 1));
        errdefer a.free(data);
        if (data.len != size or std.hash.Crc32.hash(
            data,
        ) != read32(c, 16)) return error.DemoIntegrityCheckFailed;

        return data;
    }

    return error.MissingDemoAsset;
}

test "reject malformed LAB and unauthenticated demo before extraction" {
    try std.testing.expectError(error.UnsupportedLab, validateLab("LABN"));
    try std.testing.expectError(
        error.DemoIntegrityCheckFailed,
        demoAsset(std.testing.allocator, "MZ", "OUTLAWS.LAB"),
    );
}
