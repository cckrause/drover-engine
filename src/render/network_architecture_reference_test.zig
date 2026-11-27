//! Architecture changes between machines: the packers, the scan, the marks, the sends and the receivers.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const message = @import("../network/message.zig");
const dead_reckoning = @import("../network/dead_reckoning.zig");
const router_module = @import("../network/router.zig");
const Router = router_module.Router;
const level_asset = @import("../assets/level.zig");
const scene_module = @import("scene.zig");
const camera = @import("backends/software/camera.zig");
const network_level = @import("network_level.zig");
const inf_geometry = @import("../script/inf_geometry.zig");
const testing = std.testing;

const SlopeDef = ?[3]i32;

const State = []const struct {
    light: i32,
    ceiling: u32,
    floor: u32,
    flags: u32,
    runtime: u32,
    vertices: []const [2]u32,
    walls: []const struct { direction: [2]u32, angle: u16, length: u32, flags: u32, runtime: u32 },
    floor_slope: ?[20]i64,
    ceiling_slope: ?[20]i64,
};

const LevelSector = struct {
    vertices: []const [2]u32,
    walls: []const struct { flags: u32, runtime: u32 },
    floor: u32,
    ceiling: u32,
    light: i32,
    flags: u32,
    runtime: u32,
    floor_slope: SlopeDef,
    ceiling_slope: SlopeDef,
};

const Post = struct { destination: u32, number: u32, bytes: []const u8 };

const Fixture = struct {
    executable_sha256: []const u8,
    level: []const LevelSector,
    initial: State,
    packers: []const struct { kind: u32, sector: u16, wall: u16, words: [4]u32, size: usize, bytes: []const u8, short: u32 },
    scans: []const struct { game_type: u32, clients: u32, posts: []const Post, skip: u32, waiting: u32 },
    marks: []const struct {
        game_type: u32,
        clients: u32,
        steps: []const struct { kind: []const u8, sector: usize, wall: ?usize },
        queue: []const [7]u32,
        bits: []const struct { runtime: u32, walls: []const u32 },
    },
    send_to: struct { client: u16, posts: []const Post, waiting: u32 },
    receivers: []const struct { bytes: []const u8, length: usize, calls: []const []const std.json.Value, state: State },
};

const Call = union(enum) { refresh: usize, forget: usize, shatter: [2]usize };

const Recorder = struct {
    calls: std.ArrayList(Call) = .empty,
    allocator: std.mem.Allocator,

    pub fn refresh(self: *Recorder, sector: usize) !void {
        try self.calls.append(self.allocator, .{ .refresh = sector });
    }

    pub fn forget(self: *Recorder, sector: usize) !void {
        try self.calls.append(self.allocator, .{ .forget = sector });
    }

    pub fn shatter(self: *Recorder, sector: usize, wall: usize) !void {
        try self.calls.append(self.allocator, .{ .shatter = .{ sector, wall } });
    }
};

/// Records what the router hands to the driver. The router is set up as a
/// host with one other client (3), so a broadcast is sent exactly once.
const SendRecorder = struct {
    allocator: std.mem.Allocator,
    sends: std.ArrayList([]u8) = .empty,

    fn attach(self: *SendRecorder, router: *Router) void {
        router.own_address = message.no_address;
        router.own_address[0] = 1;
        router.clients[3].address = message.no_address;
        router.clients[3].address[0] = 3;
        router.network.session = .{ .context = self, .send = send, .get = get };
    }

    fn clear(self: *SendRecorder) void {
        for (self.sends.items) |bytes| self.allocator.free(bytes);
        self.sends.clearRetainingCapacity();
    }

    fn deinit(self: *SendRecorder) void {
        self.clear();
        self.sends.deinit(self.allocator);
    }

    fn send(context: *anyopaque, data: []const u8, _: ?*const message.Address, _: u32) anyerror!void {
        const self: *SendRecorder = @ptrCast(@alignCast(context));
        try self.sends.ensureUnusedCapacity(self.allocator, 1);
        self.sends.appendAssumeCapacity(try self.allocator.dupe(u8, data[1..]));
    }

    fn get(_: *anyopaque, _: []u8, _: *message.Address) anyerror!usize {
        return 0;
    }
};

fn expectPosts(expected: []const Post, recorder: *SendRecorder) !void {
    defer recorder.clear();
    try testing.expectEqual(expected.len, recorder.sends.items.len);
    for (expected, recorder.sends.items) |post, bytes| {
        try testing.expectEqual(post.destination, message.get(bytes, message.destination_offset));
        // A direct send keeps only the low 24 bits of the number; the top
        // bit is the must-arrive flag.
        try testing.expectEqual(post.number & 0xffffff, message.get(bytes, message.number_offset));
        var copy: [0x200]u8 = undefined;
        @memcpy(copy[0..bytes.len], bytes);
        message.set(copy[0..bytes.len], message.destination_offset, 0);
        message.set(copy[0..bytes.len], message.number_offset, 0);
        try expectHex(post.bytes, copy[0..bytes.len]);
    }
}

fn expectHex(hex: []const u8, actual: []const u8) !void {
    var buffer: [0x400]u8 = undefined;
    try testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&buffer, hex), actual);
}

fn expectState(expected: State, level: *const level_asset.Level, scene: *const scene_module.Scene) !void {
    for (expected, level.sectors, scene.sectors) |want, sector, state| {
        try testing.expectEqual(want.light, sector.ambient);
        try testing.expectEqual(want.ceiling, @as(u32, @bitCast(sector.ceiling.height)));
        try testing.expectEqual(want.floor, @as(u32, @bitCast(sector.floor.height)));
        try testing.expectEqual(want.flags, state.flags);
        try testing.expectEqual(want.flags, sector.flags);
        try testing.expectEqual(want.runtime, state.runtime_flags);
        for (want.vertices, sector.vertices) |v, got| try testing.expectEqual(v, [2]u32{ @bitCast(got.x), @bitCast(got.z) });
        for (want.walls, state.walls, sector.walls) |w, got, source| {
            try testing.expectEqual(w.direction, [2]u32{ @bitCast(got.direction.x), @bitCast(got.direction.z) });
            try testing.expectEqual(w.angle, @as(u16, @bitCast(got.angle)));
            try testing.expectEqual(w.length, @as(u32, @bitCast(got.length)));
            try testing.expectEqual(w.flags, got.flags);
            try testing.expectEqual(w.flags, source.flags);
            try testing.expectEqual(w.runtime, got.runtime_flags);
        }
        try expectSlope(want.floor_slope, state.floor_slope);
        try expectSlope(want.ceiling_slope, state.ceiling_slope);
    }
}

fn expectSlope(expected: ?[20]i64, actual: ?scene_module.Slope) !void {
    const want = expected orelse return testing.expect(actual == null);
    const s = actual orelse return error.TestExpectedSlope;
    try testing.expectEqual(want[0], @as(i64, s.angle));
    const words = [19]f32{
        s.min_y,         s.max_y,         s.coeff_x,       s.coeff_z,
        s.hinge_first.x, s.hinge_first.y, s.hinge_first.z, s.origin.x,
        s.origin.y,      s.origin.z,      s.constant,      s.u_axis.x,
        s.u_axis.y,      s.u_axis.z,      s.v_axis.x,      s.v_axis.y,
        s.v_axis.z,      s.u_offset,      s.v_offset,
    };
    for (want[1..], words) |w, got| try testing.expectEqual(@as(u32, @intCast(w)), @as(u32, @bitCast(got)));
}

test "architecture changes match the reference's packers, scan, marks, sends and receivers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, "testdata/network-architecture-reference.json", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const fixture = try std.json.parseFromSliceLeaky(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("f71a8db8743d12a14317393148a0ade05e2f86d7d80a98d4a76f1bffa20a52d1", fixture.executable_sha256);
    const angles = camera.Angles.init();

    const sectors = try a.alloc(level_asset.Sector, fixture.level.len);
    const states = try a.alloc(scene_module.SectorState, fixture.level.len);
    for (fixture.level, sectors, states) |source, *sector, *state| {
        sector.* = std.mem.zeroes(level_asset.Sector);
        sector.vertices = try a.alloc(level_asset.Vec2, source.vertices.len);
        for (source.vertices, sector.vertices) |v, *out| out.* = .{ .x = @bitCast(v[0]), .z = @bitCast(v[1]) };
        sector.walls = try a.alloc(level_asset.Wall, source.walls.len);
        state.* = std.mem.zeroes(scene_module.SectorState);
        state.walls = try a.alloc(scene_module.WallState, source.walls.len);
        for (source.walls, sector.walls, state.walls, 0..) |w, *wall, *wall_state, k| {
            wall.* = std.mem.zeroes(level_asset.Wall);
            wall.v1 = @intCast(k);
            wall.v2 = @intCast((k + 1) % source.walls.len);
            wall.adjoin = -1;
            wall.mirror = -1;
            wall.dadjoin = -1;
            wall.dmirror = -1;
            wall.flags = w.flags;
            wall_state.* = std.mem.zeroes(scene_module.WallState);
            wall_state.flags = w.flags;
            wall_state.runtime_flags = w.runtime;
        }
        sector.floor.height = @bitCast(source.floor);
        sector.ceiling.height = @bitCast(source.ceiling);
        sector.ambient = source.light;
        sector.flags = source.flags;
        state.flags = source.flags;
        state.runtime_flags = source.runtime;
        if (source.floor_slope) |s| sector.floor.slope = .{ .sector = @intCast(s[0]), .wall = @intCast(s[1]), .angle = @intCast(s[2]) };
        if (source.ceiling_slope) |s| sector.ceiling.slope = .{ .sector = @intCast(s[0]), .wall = @intCast(s[1]), .angle = @intCast(s[2]) };
    }
    var level: level_asset.Level = undefined;
    level.sectors = sectors;
    var scene: scene_module.Scene = undefined;
    scene.sectors = states;
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;
    for (sectors, states, 0..) |sector, *state, i| {
        if (sector.floor.slope != null) state.floor_slope = try scene_module.Slope.initV111(&level, i, sector.floor, &angles);
        if (sector.ceiling.slope != null) state.ceiling_slope = try scene_module.Slope.initV111(&level, i, sector.ceiling, &angles);
    }
    try expectState(fixture.initial, &level, &scene);

    for (fixture.packers) |case| {
        const change: dead_reckoning.Change = .{ .kind = case.kind, .sector = case.sector, .wall = case.wall, .words = case.words };
        var out: [32]u8 = undefined;
        try testing.expectEqual(case.size, try dead_reckoning.packOne(change, out[0..case.size]));
        try expectHex(case.bytes, out[0..case.size]);
        try testing.expectEqual(@as(usize, case.short), try dead_reckoning.packOne(change, out[0 .. case.size - 1]));
    }

    var router = Router.init(a);
    defer router.deinit();
    router.reset();
    router.session_open = true;
    var sends: SendRecorder = .{ .allocator = a };
    defer sends.deinit();
    sends.attach(&router);
    var queue: dead_reckoning.ArchitectureQueue = .{};
    var arch: network_level.Architecture = .{ .level = &level, .scene = &scene, .angles = &angles, .router = &router, .queue = &queue, .game_type = 5 };

    var skip: u32 = 0;
    for (fixture.scans) |pass| {
        arch.game_type = pass.game_type;
        router.client_count = pass.clients;
        try network_level.scan(arch, &skip);
        try expectPosts(pass.posts, &sends);
        try testing.expectEqual(pass.skip, skip);
        try testing.expectEqual(@as(usize, pass.waiting), queue.count);
    }

    for (fixture.marks) |case| {
        arch.game_type = case.game_type;
        router.client_count = case.clients;
        queue.count = 0;
        for (fixture.level, states) |source, *state| {
            state.runtime_flags = source.runtime & ~@as(u32, 0x2e);
            for (source.walls, state.walls) |w, *wall| wall.runtime_flags = w.runtime & ~@as(u32, 6);
        }
        for (case.steps, 0..) |step, index| {
            sectors[1].ambient = if (index == 8) -3 else 40;
            states[5].walls[2].flags = if (index < 6) 0x1111 else 0x2222;
            const at: inf_geometry.WallRef = .{ .sector = step.sector, .index = step.wall orelse 0 };
            const value: inf_geometry.Mark = if (std.mem.eql(u8, step.kind, "light")) .{ .light = step.sector } else if (std.mem.eql(u8, step.kind, "ceiling")) .{ .ceiling = step.sector } else if (std.mem.eql(u8, step.kind, "floor")) .{ .floor = step.sector } else if (std.mem.eql(u8, step.kind, "sector_flags")) .{ .sector_flags = step.sector } else if (std.mem.eql(u8, step.kind, "wall_flags")) .{ .wall_flags = at } else .{ .corners = at };
            try network_level.markChange(arch, value);
        }
        try testing.expectEqual(case.queue.len, queue.count);
        for (case.queue, queue.entries.items[0..queue.count]) |expected, entry| {
            const original: dead_reckoning.Change = .{ .kind = expected[0], .sector = @truncate(expected[1]), .wall = @truncate(expected[2]), .words = expected[3..7].* };
            var want: [32]u8 = undefined;
            var got: [32]u8 = undefined;
            const length = try dead_reckoning.packOne(original, &want);
            try testing.expectEqualSlices(u8, want[0..length], got[0..try dead_reckoning.packOne(entry, &got)]);
        }
        for (case.bits, states) |expected, state| {
            try testing.expectEqual(expected.runtime, state.runtime_flags);
            for (expected.walls, state.walls) |bits, wall| try testing.expectEqual(bits, wall.runtime_flags);
        }
    }
    sectors[1].ambient = fixture.level[1].light;
    states[5].walls[2].flags = fixture.level[5].walls[2].flags;
    for (fixture.level, states) |source, *state| {
        state.runtime_flags = source.runtime;
        for (source.walls, state.walls) |w, *wall| wall.runtime_flags = w.runtime;
    }

    arch.game_type = 5;
    router.client_count = 2;
    queue.count = 0;
    try network_level.markChange(arch, .{ .light = 2 });
    try network_level.sendTo(arch, fixture.send_to.client);
    try expectPosts(fixture.send_to.posts, &sends);
    try testing.expectEqual(@as(usize, fixture.send_to.waiting), queue.count);

    var recorder: Recorder = .{ .allocator = a };
    for (fixture.receivers) |step| {
        recorder.calls.clearRetainingCapacity();
        var change: [32]u8 = @splat(0);
        const given = try std.fmt.hexToBytes(&change, step.bytes);
        try testing.expectEqual(step.length, try network_level.applyChange(&level, &scene, &angles, change[0..given.len], &recorder));
        try testing.expectEqual(step.calls.len, recorder.calls.items.len);
        for (step.calls, recorder.calls.items) |expected, got| {
            const name = expected[0].string;
            switch (got) {
                .refresh => |sector| {
                    try testing.expectEqualStrings("refresh", name);
                    try testing.expectEqual(expected[1].integer, @as(i64, @intCast(sector)));
                },
                .forget => |sector| {
                    try testing.expectEqualStrings("forget", name);
                    try testing.expectEqual(expected[1].integer, @as(i64, @intCast(sector)));
                },
                .shatter => |at| {
                    try testing.expectEqualStrings("shatter", name);
                    try testing.expectEqual(expected[1].integer, @as(i64, @intCast(at[0])));
                    try testing.expectEqual(expected[2].integer, @as(i64, @intCast(at[1])));
                    try testing.expectEqual(@as(i64, 0), expected[3].integer);
                },
            }
        }
        try expectState(step.state, &level, &scene);
    }
}
