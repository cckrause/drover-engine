//! Changing palette when the player walks into a sector with another one.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const campaign = @import("../campaign.zig");
const lab = @import("../assets/lab.zig");
const texture = @import("../assets/texture.zig");
const inventory = @import("../player/inventory.zig");
const script_runtime = @import("../script/runtime.zig");
const Session = @import("session.zig").Session;

const Case = struct {
    routine: []const u8,
    start: usize,
    target: usize,
    number: u32,
    flags: u32,
    target_palette: u8,
    calls: []const [2]u32,
};

const Recorder = struct {
    sectors: std.ArrayList(usize) = .empty,
    allocator: std.mem.Allocator,

    fn enter(context: *anyopaque, sector: usize) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        try self.sectors.append(self.allocator, sector);
    }
};

test "player sector changes switch palettes as the reference relinks do" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(128 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const fixture_bytes = std.Io.Dir.cwd().readFileAlloc(io, "testdata/sector-palette-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(fixture_bytes);
    const fixture = try std.json.parseFromSlice(struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []Case }, a, fixture_bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.value.executable_sha256);
    try std.testing.expectEqualStrings("848841eef6e42a58ce7b56f6f619c887ac1304b533e4ae1b8b79200b4293e039", fixture.value.results_sha256);
    try std.testing.expectEqual(@as(usize, 14), fixture.value.cases.len);

    const archive = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("test_workspace.zig").get(), io, path, archive, &startup);
    defer session.deinit(a);

    var effects_buffer: inventory.EffectBuffer = undefined;
    var effects = inventory.Effects.init(&effects_buffer);
    for (fixture.value.cases) |case| {
        errdefer std.debug.print("sector palette case {s} {d}->{d} number={d} flags={x}\n", .{ case.routine, case.start, case.target, case.number, case.flags });
        try std.testing.expectEqual(case.target_palette, session.level.sectors[case.target].palette);
        var recorder: Recorder = .{ .allocator = a };
        defer recorder.sectors.deinit(a);
        var context = script_runtime.Context{ .inventory = &session.inventory, .pickups = &.{}, .removed = &.{}, .now_ms = 0, .effects = &effects, .contact_state = &session.contact_state };
        if (case.number == 0 and case.flags & 0x10 != 0) context.palette_host = .{ .context = &recorder, .enter = Recorder.enter };
        try context.changeSector(case.start, case.target);
        try std.testing.expectEqual(case.calls.len, recorder.sectors.items.len);
        for (case.calls, recorder.sectors.items) |call, sector| {
            try std.testing.expectEqual(@as(u32, session.level.sectors[sector].palette), call[0]);
            try std.testing.expectEqual(@as(u32, 1), call[1]);
        }
    }

    const system = try texture.decodePalette(try archive.find("SYSPAL.PCX", 0x50435850));
    const dry = try texture.decodePalette(try archive.find("HIDEOUT.PCX", 0x50435850));
    const wet = try texture.decodePalette(try archive.find("UWHIDOT.PCX", 0x50435850));
    try std.testing.expectEqualStrings("uwhidot.pcx", session.level.palettes[1]);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    try std.testing.expectEqual(@as(u8, 0), session.palette_index);
    try std.testing.expectEqualSlices(u32, dry[16..], session.palette[16..]);

    session.player.sector = 70;
    session.player.position = .{ .x = 465.5, .y = -10, .z = 460 };
    session.player.velocity = .{ .x = 0, .y = 0, .z = 0 };
    session.player.floor_cache = -2147483648;
    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(usize, 66), session.player.sector);
    try std.testing.expectEqual(@as(u8, 1), session.palette_index);
    const under = try session.render(pixels, 0);
    try std.testing.expectEqualSlices(u32, system[0..16], under[0..16]);
    try std.testing.expectEqualSlices(u32, wet[16..], under[16..]);

    session.player.position.y = @floatCast(-3.5 - @as(f64, session.player.eye_height) + 0.5);
    session.player.velocity = .{ .x = 0, .y = 0, .z = 0 };
    session.player.floor_cache = -2147483648;
    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(usize, 70), session.player.sector);
    try std.testing.expectEqual(@as(u8, 0), session.palette_index);
    const above = try session.render(pixels, 0);
    try std.testing.expectEqualSlices(u32, system[0..16], above[0..16]);
    try std.testing.expectEqualSlices(u32, dry[16..], above[16..]);
}
