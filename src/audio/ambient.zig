//! Looping ambient sounds placed in the level: created per point, given a
//! position, and left running.
//!
//! They are created in the order the level data lists them and they are not
//! occlusion-tested, unlike sounds that come from actors.

const std = @import("std");

const level = @import("../assets/level.zig");
const engine = @import("engine.zig");

pub const Source = struct {
    basename: []const u8,
    position: level.Vec3,
    layer: f32,
    entered: bool = false,
    handle: u32 = 0,

    pub fn params(self: Source) engine.Params {
        return .{
            .flags = engine.Flags.effects | engine.Flags.spatial | engine.Flags.loop | engine.Flags.ambient,
            .position = .{ self.position.x, self.position.y, self.position.z },
        };
    }
};

pub const Action = struct { source: usize, kind: enum { start, stop }, handle: u32 = 0 };

pub const Scheduler = struct {
    sources: []Source,
    actions: []Action,
    deadline: u32 = 0,

    pub fn init(
        a: std.mem.Allocator,
        geometry: *const level.Level,
        objects: *const level.Objects,
        difficulty: u32,
    ) !Scheduler {
        const mask: u32 = switch (difficulty) {
            0x100000 => 0x10000000,
            0x200000 => 0x20000000,
            0x400000 => 0x40000000,
            0x800000 => 0x80000000,
            else => return error.InvalidDifficulty,
        };

        var sources: std.ArrayList(Source) = .empty;
        defer sources.deinit(a);

        for (objects.entries) |object| {
            if (object.flags[0] & 1 == 0 or object.flags[1] & mask == 0) continue;

            const sector = geometry.sectorIndex(
                object.sector_id,
            ) orelse return error.SoundSectorNotFound;

            _ = try layerNumber(geometry.sectors[sector].layer);
            if (!std.math.isFinite(
                object.position.x,
            ) or !std.math.isFinite(object.position.y) or !std.math.isFinite(object.position.z))
                return error.InvalidSoundPosition;

            try sources.append(
                a,
                .{
                    .basename = object.name,
                    .position = object.position,
                    .layer = geometry.sectors[sector].layer,
                },
            );
        }

        const owned = try sources.toOwnedSlice(a);
        errdefer a.free(owned);

        return .{ .sources = owned, .actions = try a.alloc(Action, owned.len) };
    }

    pub fn deinit(self: Scheduler, a: std.mem.Allocator) void {
        a.free(self.actions);
        a.free(self.sources);
    }

    pub fn poll(self: *Scheduler, now: u32, listener_layer: f32) ![]const Action {
        if (now <= self.deadline) return self.actions[0..0];

        const listener = try layerNumber(listener_layer);
        var count: usize = 0;

        for (self.sources, 0..) |*source, i| {
            if (listener == try layerNumber(source.layer)) {
                if (!source.entered) {
                    self.actions[count] = .{ .source = i, .kind = .start };
                    count += 1;
                    source.entered = true;
                }
            } else if (source.entered) {
                self.actions[count] = .{ .source = i, .kind = .stop, .handle = source.handle };
                count += 1;
                source.entered = false;
                source.handle = 0;
            }
        }

        self.deadline = now +% 500;

        return self.actions[0..count];
    }
};

pub fn layerNumber(value: f32) !i32 {
    if (!std.math.isFinite(value) or value >= 2147483648.0 or value < -2147483648.0)
        return error.InvalidSoundLayer;

    const lower = @floor(@as(f64, value));
    const fraction = @as(f64, value) - lower;
    const integer: i32 = @intFromFloat(lower);

    return integer + @as(
        i32,
        @intFromBool(fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)),
    );
}

test "ambient layer rounding uses nearest even and rejects malformed positions" {
    for ([_]f32{
        -2.5,
        -1.5,
        -0.5,
        0.5,
        1.5,
        2.5,
        1.6,
    }, [_]i32{ -2, -2, 0, 0, 2, 2, 2 }) |value, expected|
        try std.testing.expectEqual(expected, try layerNumber(value));

    try std.testing.expectError(error.InvalidSoundLayer, layerNumber(std.math.nan(f32)));
}

test "Hideout object list contains no enabled point-sound records" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(bytes);
    var geometry = try level.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    defer geometry.deinit();
    var objects = try level.Objects.parse(a, try archive.find("HIDEOUT.OBB", 0));
    defer objects.deinit();

    for ([_]u32{ 0x100000, 0x200000, 0x800000 }) |difficulty| {
        var scheduler = try Scheduler.init(a, &geometry, &objects, difficulty);
        defer scheduler.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), scheduler.sources.len);
        try std.testing.expectEqual(@as(usize, 0), (try scheduler.poll(1, 0)).len);
    }
}

test "ambient polling matches the reference handles and failed-start retention" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/ambient-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Fixture = struct {
        exe_sha256: []const u8,
        layers: []f32,
        steps: []struct {
            now: u32,
            layer: f32,
            deadline: u32,
            handles: []u32,
            actions: []struct { kind: []const u8, source: usize },
            driver_starts: []struct {
                source: usize,
                flags: u32,
                volume: i8,
                pan: i8,
                priority: i8,
                position: [3]f32,
                result: u32,
            },
        },
        reuse_cases: []const std.json.Value,
    };

    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{});
    defer parsed.deinit();
    const fixture = parsed.value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        fixture.exe_sha256,
    );

    var scheduler = Scheduler{
        .sources = try a.alloc(Source, fixture.layers.len),
        .actions = try a.alloc(Action, fixture.layers.len),
    };

    defer scheduler.deinit(a);

    for (scheduler.sources, fixture.layers, 0..) |*source, layer, i| source.* = .{
        .basename = "fixture",
        .layer = layer,
        .position = .{ .x = @floatFromInt(i), .y = -3, .z = 4 },
    };

    for (fixture.steps) |step| {
        const actions = try scheduler.poll(step.now, step.layer);

        try std.testing.expectEqual(step.deadline, scheduler.deadline);
        try std.testing.expectEqual(step.actions.len, actions.len);

        for (step.actions, actions) |expected, actual| {
            try std.testing.expectEqual(expected.source, actual.source);
            try std.testing.expectEqualStrings(expected.kind, @tagName(actual.kind));
        }

        for (step.driver_starts) |start| {
            const params = scheduler.sources[start.source].params();

            try std.testing.expectEqual(start.flags, params.flags);
            try std.testing.expectEqual(start.volume, params.volume);
            try std.testing.expectEqual(start.pan, params.pan);
            try std.testing.expectEqual(start.priority, params.priority);
            try std.testing.expectEqualSlices(f32, &start.position, &params.position);
        }

        for (scheduler.sources, step.handles) |*source, handle| {
            try std.testing.expectEqual(handle != 0, source.entered);
            source.handle = handle;
        }
    }
}

test "ambient raw IDs stop replacements after failed starts and completion" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/ambient-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Fixture = struct {
        exe_sha256: []const u8,
        reuse_cases: []struct {
            failed_start: bool,
            stale_id: u32,
            rotated_ids: []u32,
            reused_id: u32,
            driver_stops: []struct { id: u32, source: usize },
            replacement_active_after: bool,
        },
    };

    const parsed = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.exe_sha256,
    );

    for (parsed.value.reuse_cases) |case| {
        var scheduler = Scheduler{
            .sources = try a.alloc(Source, 1),
            .actions = try a.alloc(Action, 1),
        };

        defer scheduler.deinit(a);

        scheduler.sources[0] = .{
            .basename = "fixture",
            .position = .{ .x = 0, .y = 0, .z = 0 },
            .layer = 0,
        };

        var driver: engine.Engine = .{};
        driver.effects_volume = if (case.failed_start) 0 else 127;
        try std.testing.expectEqual(@as(usize, 1), (try scheduler.poll(1, 0)).len);
        const started = try driver.start(0, 22050, scheduler.sources[0].params(), 1);
        scheduler.sources[0].handle = driver.next_id;

        try std.testing.expectEqual(case.stale_id, scheduler.sources[0].handle);
        try std.testing.expectEqual(!case.failed_start, started != null);

        if (started) |id| driver.complete(id);

        driver.effects_volume = 127;

        for (case.rotated_ids) |expected| {
            const id = (try driver.start(1, 22050, .{}, 2)).?;
            try std.testing.expectEqual(expected, id);
            driver.stop(id);
        }

        const replacement = (try driver.start(1, 22050, .{}, 2)).?;
        try std.testing.expectEqual(case.reused_id, replacement);
        const actions = try scheduler.poll(502, 1);
        try std.testing.expectEqual(case.driver_stops.len, actions.len);

        for (actions, case.driver_stops) |action, expected| {
            try std.testing.expectEqual(expected.id, action.handle);
            try std.testing.expectEqual(expected.source, driver.find(action.handle).?.asset);
            driver.stop(action.handle);
        }

        try std.testing.expectEqual(
            case.replacement_active_after,
            driver.find(replacement) != null,
        );

        try std.testing.expectEqual(@as(u32, 0), scheduler.sources[0].handle);
    }
}
