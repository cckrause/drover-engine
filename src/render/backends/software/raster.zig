//! The column kernels: one specialised version per screen stride, opaque
//! and masked, palette-translated or not.
//!
//! Texture coordinates start at the bottom pixel and callers pass the top
//! address and the count. Height-specialised entries exist for the common
//! cases; picking the wrong stride kernel does not fail, it just draws
//! skewed.

const std = @import("std");

pub const Column = struct {
    top: usize,
    stride: usize,
    count: usize,
    texels: []const u8,
    mask: u32,
    v: i32,
    dv: i32,
    fixed_height: bool = false,
};

pub const SpanCoordinates = struct {
    u: i32,
    v: i32,
    du: i32,
    dv: i32,
};

pub const SpanArithmetic = enum { scalar, mmx };

pub fn column(pixels: []u8, c: Column, translation: ?[]const u8) !void {
    try checkColumn(pixels, c);
    var v: u32 = @bitCast(c.v);
    const dv: u32 = @bitCast(c.dv);
    var remaining = c.count;
    while (remaining != 0) {
        remaining -= 1;
        const index = (v >> 16) & c.mask;
        const source = c.texels[index];
        v +%= dv;
        if (translation) |table| {
            const color = if (c.fixed_height and c.mask == 511) (index & 0x100) | source else source;
            if (color >= table.len) return error.ColorMapBounds;
            pixels[c.top + remaining * c.stride] = table[color];
        } else pixels[c.top + remaining * c.stride] = source;
    }
}

pub fn maskedColumn(pixels: []u8, c: Column, translation: ?*const [256]u8) !void {
    try checkColumn(pixels, c);
    var v: u32 = @bitCast(c.v);
    const dv: u32 = @bitCast(c.dv);
    var remaining = c.count;
    while (remaining != 0) {
        remaining -= 1;
        const source = c.texels[(v >> 16) & c.mask];
        v +%= dv;
        if (source != 0) pixels[c.top + remaining * c.stride] = if (translation) |table| table[source] else source;
    }
}

pub fn overlayColumn(pixels: []u8, c: Column, translation: ?[]const u8) !void {
    if (translation) |table| {
        if (table.len < 256) return error.ColorMapBounds;
        if (c.stride != 320 and c.stride != 640)
            return maskedColumn(pixels, c, table[0..256]);
    }
    try checkColumn(pixels, c);
    var v = c.v;
    var remaining = c.count;
    while (v < 0 and remaining != 0) {
        if (c.dv <= 0) return error.InvalidOverlayStep;
        remaining -= 1;
        v +%= c.dv;
    }
    while (remaining != 0) {
        remaining -= 1;
        const index = @as(u32, @bitCast(v)) >> 16;
        if (index >= c.texels.len) return error.OverlayTextureBounds;
        const source = c.texels[index];
        v +%= c.dv;
        if (source != 0) {
            if (translation) |table| {
                const color = (index & 0xffffff00) | source;
                if (color >= table.len) return error.ColorMapBounds;
                pixels[c.top + remaining * c.stride] = table[color];
            } else pixels[c.top + remaining * c.stride] = source;
        }
    }
}

pub fn blendedColumn(pixels: []u8, c: Column, blend: []const u8) !void {
    try checkColumn(pixels, c);
    if (blend.len < 16 * 256) return error.InvalidBlendTable;
    var v: u32 = @bitCast(c.v);
    const dv: u32 = @bitCast(c.dv);
    var remaining = c.count;
    while (remaining != 0) {
        remaining -= 1;
        const source = c.texels[(v >> 16) & c.mask];
        v +%= dv;
        const destination = &pixels[c.top + remaining * c.stride];
        if (source != 0) {
            if (source <= 16) {
                const index = @as(usize, source) * 256 + destination.*;
                if (index >= blend.len) return error.BlendTableBounds;
                destination.* = blend[index];
            } else destination.* = source;
        }
    }
}

pub fn span64(destination: []u8, texels: []const u8, coords: SpanCoordinates, arithmetic: SpanArithmetic, translation: ?*const [256]u8) !void {
    if (texels.len < 64 * 64) return error.UnsupportedSpanTextureSize;
    var u: u32 = @bitCast(coords.u);
    var v: u32 = @bitCast(coords.v);
    const du: u32 = @bitCast(coords.du);
    const dv: u32 = @bitCast(coords.dv);
    var packed_uv = ((u << 10) & 0xffff0000) | ((v >> 6) & 0xffff);
    const packed_step = ((du << 10) & 0xffff0000) | ((dv >> 6) & 0xffff);
    var remaining = destination.len;
    while (remaining != 0) {
        remaining -= 1;
        const index = switch (arithmetic) {
            .mmx => ((u >> 16) & 0x3f) + ((v >> 10) & 0xfc0),
            .scalar => ((packed_uv >> 22) + (packed_uv & 0xfc00)) >> 4,
        };
        const source = texels[index];
        destination[remaining] = if (translation) |table| table[source] else source;
        switch (arithmetic) {
            .mmx => {
                u +%= du;
                v +%= dv;
            },
            .scalar => packed_uv +%= packed_step,
        }
    }
}

pub fn maskedSpan(destination: []u8, texels: []const u8, mask: u32, coords: SpanCoordinates, translation: ?*const [256]u8) !void {
    if (mask >= texels.len) return error.InvalidSpanTexture;
    var u = coords.u;
    var v = coords.v;
    var remaining = destination.len;
    while (remaining != 0) {
        remaining -= 1;
        const ux: u32 = @bitCast(u >> 16);
        const vy: u32 = @bitCast(v >> 10);
        const source = texels[(ux & (mask & 0x3f)) + (vy & (mask & 0xffffffc0))];
        u +%= coords.du;
        v +%= coords.dv;
        if (source != 0) destination[remaining] = if (translation) |table| table[source] else source;
    }
}

pub fn solidColumn(pixels: []u8, top: usize, stride: usize, count: usize, color: u8) !void {
    if (stride == 0) return error.InvalidRasterStride;
    if (count == 0) return;
    const distance = std.math.mul(usize, count - 1, stride) catch return error.RasterBounds;
    const last = std.math.add(usize, top, distance) catch return error.RasterBounds;
    if (last >= pixels.len) return error.RasterBounds;
    var remaining = count;
    while (remaining != 0) {
        remaining -= 1;
        pixels[top + remaining * stride] = color;
    }
}

fn checkColumn(pixels: []u8, c: Column) !void {
    if (c.stride == 0) return error.InvalidRasterStride;
    if (c.mask > 0xffff or c.mask >= c.texels.len) return error.InvalidTextureColumn;
    if (c.count == 0) return;
    const distance = std.math.mul(usize, c.count - 1, c.stride) catch return error.RasterBounds;
    const last = std.math.add(usize, c.top, distance) catch return error.RasterBounds;
    if (last >= pixels.len) return error.RasterBounds;
}

test "columns run bottom to top, wrap fixed point and translate zero" {
    var pixels = [_]u8{99} ** 24;
    var translation: [256]u8 = undefined;
    for (&translation, 0..) |*value, i| value.* = @intCast(255 - i);
    const c = Column{ .top = 1, .stride = 5, .count = 5, .texels = &.{ 0, 10, 20, 30 }, .mask = 3, .v = -65536, .dv = 65536 };
    try column(&pixels, c, &translation);
    try std.testing.expectEqualSlices(u8, &.{ 99, 225, 99, 99, 99, 99, 235, 99, 99, 99, 99, 245, 99, 99, 99, 99, 255, 99, 99, 99, 99, 225, 99, 99 }, &pixels);
    @memset(&pixels, 99);
    try maskedColumn(&pixels, c, &translation);
    try std.testing.expectEqual(@as(u8, 99), pixels[16]);
    try std.testing.expectEqual(@as(u8, 225), pixels[1]);
    try std.testing.expectError(error.RasterBounds, column(&pixels, .{ .top = 4, .stride = 5, .count = 5, .texels = c.texels, .mask = 3, .v = 0, .dv = 0 }, null));
}

test "scalar packed plane stepping retains cross-coordinate carry" {
    var texels: [4096]u8 = undefined;
    for (&texels, 0..) |*value, i| value.* = @intCast((i % 64) * 3 + (i / 64));
    var mmx: [9]u8 = undefined;
    var scalar: [9]u8 = undefined;
    const coords = SpanCoordinates{ .u = 0x003fffc0, .v = 0x003fffff, .du = 63, .dv = 65 };
    try span64(&mmx, &texels, coords, .mmx, null);
    try span64(&scalar, &texels, coords, .scalar, null);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 189, 252 }, &mmx);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 252 }, &scalar);
}

test "column kernels match isolated reference at all three strides" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/raster-reference.json", allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);
    const Case = struct {
        kind: []const u8,
        stride: usize,
        mask: u32,
        lit: bool,
        v: i32,
        dv: i32,
        address: []const u8,
        pixels: []const u8,
    };
    const parsed = try std.json.parseFromSlice(struct { executable_sha256: []const u8, cases: []Case }, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", parsed.value.executable_sha256);
    var texels: [1024]u8 = undefined;
    for (&texels, 0..) |*value, i| value.* = @truncate(i * 37 + (i / 256) * 11);
    var table: [1024]u8 = undefined;
    for (&table, 0..) |*value, i| value.* = @truncate((i % 256) * 3 + (i / 256) * 17);
    var blend: [17 * 256]u8 = undefined;
    for (&blend, 0..) |*value, i| value.* = @truncate((i / 256) * 7 + (i % 256) * 3);
    var failures: usize = 0;
    for (parsed.value.cases) |case| {
        const pixels = try allocator.alloc(u8, case.stride * 20);
        defer allocator.free(pixels);
        @memset(pixels, 197);
        const c = Column{ .top = case.stride + 3, .stride = case.stride, .count = 17, .texels = &texels, .mask = case.mask, .v = case.v, .dv = case.dv, .fixed_height = std.mem.eql(u8, case.kind, "column") };
        if (std.mem.eql(u8, case.kind, "overlay")) try overlayColumn(pixels, c, if (case.lit) &table else null) else if (std.mem.eql(u8, case.kind, "masked")) try maskedColumn(pixels, c, if (case.lit) table[0..256] else null) else if (std.mem.eql(u8, case.kind, "blend")) try blendedColumn(pixels, c, &blend) else try column(pixels, c, if (case.lit) &table else null);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pixels, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, case.pixels, &hex)) {
            std.debug.print("\n{s} stride={} mask={} lit={} v={} dv={} at{s}: got{s} expected{s}\n", .{ case.kind, case.stride, case.mask, case.lit, case.v, case.dv, case.address, hex, case.pixels });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
