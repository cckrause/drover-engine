//! What a network game needs from the loaded level: the frame step's hooks,
//! the player's dead reckoning, the scan for changed architecture, and the
//! network side of placing a player.
//!
//! The architecture scan looks at a fixed number of changes per pass, so
//! changes are spread over frames rather than sent in one burst.

const std = @import("std");

const campaign = @import("../campaign.zig");
const dead_reckoning = @import("../network/dead_reckoning.zig");
const message = @import("../network/message.zig");
const Router = @import("../network/router.zig").Router;
const level_asset = @import("../assets/level.zig");
const inf_geometry = @import("../script/inf_geometry.zig");
const camera = @import("backends/software/camera.zig");
const scene_module = @import("scene.zig");
const local_player = @import("../player/shooting.zig").local_player;

const spawn_actor_flags: u32 = 0x8000006f;

const player_entity: u32 = 0x90;

const architecture_batch = 0x19;

pub const character_costumes = [_][]const u8{
    "james.nwx",
    "sanchez.nwx",
    "james.nwx",
    "twofeath.nwx",
    "drdeath.nwx",
    "bobgrahm.nwx",
    "mary.nwx",
};

const stand_in_entity: u32 = 0x1000000;

fn Hooks(comptime Session: type) type {
    return struct {
        fn of(context: *anyopaque) *Session {
            return @ptrCast(@alignCast(context));
        }

        fn deadReckoning(context: *anyopaque) anyerror!void {
            try receive(of(context));
        }

        fn player(context: *anyopaque, now: u32) anyerror!bool {
            return sendPlayer(of(context), now);
        }

        fn architecture(context: *anyopaque) anyerror!void {
            try scanArchitecture(of(context));
        }

        fn create(context: *anyopaque, value: message.HaveServerCreate) anyerror!void {
            try @import("network_actors.zig").createRequested(of(context), value);
        }

        fn mark(context: *anyopaque, value: inf_geometry.Mark) anyerror!void {
            try markChange(architectureOf(of(context)), value);
        }
    };
}

pub const Architecture = struct {
    level: *level_asset.Level,
    scene: *scene_module.Scene,
    angles: *const camera.Angles,
    router: *Router,
    queue: *dead_reckoning.ArchitectureQueue,
    game_type: u32,

    fn sending(self: Architecture) bool {
        return self.game_type == 5 and self.router.clientCount() > 1;
    }

    fn put(self: Architecture, change: dead_reckoning.Change) !void {
        try self.queue.queue(self.router.allocator, self.router, change);
    }

    fn slopes(self: Architecture, sector: usize) ?dead_reckoning.Change {
        const state = &self.scene.sectors[sector];
        const at: u16 = @intCast(sector);
        const floor: ?u32 = if (state.floor_slope) |slope| @as(
            u32,
            @bitCast(@as(i32, slope.angle)),
        ) else null;

        const ceiling: ?u32 = if (state.ceiling_slope) |slope| @as(
            u32,
            @bitCast(@as(i32, slope.angle)),
        ) else null;

        if (ceiling == null) return .{
            .kind = 1,
            .sector = at,
            .wall = 0,
            .words = .{ floor orelse return null, 0, 0, 0 },
        };

        if (floor == null) return .{
            .kind = 0,
            .sector = at,
            .wall = 0,
            .words = .{ ceiling.?, 0, 0, 0 },
        };

        return .{ .kind = 2, .sector = at, .wall = 0, .words = .{ floor.?, ceiling.?, 0, 0 } };
    }

    fn sectorWord(self: Architecture, kind: u32, sector: usize) dead_reckoning.Change {
        const source = &self.level.sectors[sector];
        const value: u32 = switch (kind) {
            3 => @bitCast(source.ceiling.height),
            4 => @bitCast(source.floor.height),
            7 => self.scene.sectors[sector].flags,
            9 => @bitCast(source.ambient),
            else => unreachable,
        };

        return .{
            .kind = kind,
            .sector = @intCast(sector),
            .wall = 0,
            .words = .{ value, 0, 0, 0 },
        };
    }

    fn heights(self: Architecture, sector: usize) dead_reckoning.Change {
        const source = &self.level.sectors[sector];

        return .{
            .kind = 5,
            .sector = @intCast(sector),
            .wall = 0,
            .words = .{ @bitCast(source.floor.height), @bitCast(source.ceiling.height), 0, 0 },
        };
    }

    fn wallFlags(self: Architecture, sector: usize, wall: usize) dead_reckoning.Change {
        return .{
            .kind = 8,
            .sector = @intCast(sector),
            .wall = @intCast(wall),
            .words = .{ self.scene.sectors[sector].walls[wall].flags, 0, 0, 0 },
        };
    }

    fn corners(self: Architecture, sector: usize, wall: usize) dead_reckoning.Change {
        const source = &self.level.sectors[sector];
        const first = source.vertices[source.walls[wall].v1];
        const last = source.vertices[source.walls[wall].v2];

        return .{
            .kind = 6,
            .sector = @intCast(sector),
            .wall = @intCast(wall),
            .words = .{ @bitCast(first.x), @bitCast(first.z), @bitCast(last.x), @bitCast(last.z) },
        };
    }
};

fn SessionEffects(comptime Session: type) type {
    return struct {
        session: *Session,

        pub fn refresh(self: @This(), sector: usize) !void {
            try refreshSector(&self.session.level, &self.session.scene, sector);
        }

        pub fn forget(self: @This(), sector: usize) !void {
            // The software renderer rebuilds a reshaped sector every frame, so
            // there is no cached split to drop. A renderer that caches geometry
            // hangs its invalidation here.
            _ = self;
            _ = sector;
        }

        pub fn shatter(self: @This(), sector: usize, wall: usize) !void {
            try shatterWall(self.session, sector, wall);
        }
    };
}

pub fn level(session: anytype) campaign.Startup.NetworkLevel {
    const H = Hooks(@TypeOf(session.*));

    return .{
        .context = session,
        .dead_reckoning = H.deadReckoning,
        .player = H.player,
        .architecture = H.architecture,
        .loaded = true,
        .server = .{ .context = session, .sectors = session.level.sectors.len, .create = H.create },
    };
}

pub fn playerEntity(mode: u32, team: u8) !u32 {
    return switch (mode) {
        1, 4, 5 => player_entity | @as(u32, if (team == 1) 1 else if (team == 2) 2 else 0),
        2 => error.TagPlayerNotPorted,
        3 => player_entity | 2,
        else => player_entity,
    };
}

pub fn actorEntity(session: anytype) !u32 {
    if (!session.stand_in) return playerEntity(session.mode, session.startup.team);
    if (session.mode == 2) return error.TagPlayerNotPorted;

    return player_entity | stand_in_entity;
}

pub fn actorFlags(session: anytype) u32 {
    const flags = playerActorFlags(session.player.flags);

    return if (session.stand_in) flags & ~@as(u32, 4) else flags;
}

pub fn playerActorFlags(player_flags: u32) u32 {
    var flags = spawn_actor_flags;
    if (player_flags & 0x20000000 != 0) flags = flags & ~@as(u32, 8) | 0x10;
    if (player_flags & 0x10000000 != 0) flags = (flags | 0x4100) & ~@as(u32, 0x10) | 8;

    return flags;
}

pub fn sendChangedPlayer(session: anytype, now: u32) !void {
    if (session.game_type != 4 and session.game_type != 5) return;
    if (message.client(session.player_number) != session.router.own_client) return;

    const flags = actorFlags(session);
    const entity = try actorEntity(session);
    if (!(flags & 0x20 != 0 and entity & 0x1000000 == 0) and entity & 0x20 == 0) return;

    const record = if (session.player_dead_reckoning) |*value| value else return;

    record.reckon(now);
    if (record.sent +% 0x96 > now) return;

    const actor = try playerActor(session);
    var changed = false;

    if (record.flags & 1 != 0) {
        record.flags &= ~@as(u32, 1);
        changed = true;
    }

    if (!changed) changed = actor.sector != record.sector;

    if (!changed) changed = record.actor_flags != actor.flags;

    if (!changed) changed = record.entity != actor.entity;

    if (!changed) changed = largerThan(record.origin, actor.position, record.rate);

    if (!changed) changed = largerThan(
        floats(record.velocity),
        floats(actor.velocity),
        record.rate2,
    );

    if (!changed) {
        var largest: i16 = 0;

        for ([_]usize{ 1, 0, 2 }, 0..) |axis, position| {
            const difference: i32 = angleDifference(record.angles[axis], actor.angles[axis]);
            const magnitude: i16 = @truncate(@as(i32, @intCast(@abs(difference))));
            if (position == 0 or magnitude > largest) largest = magnitude;
        }

        changed = largest > @as(i16, @bitCast(record.limit));
    }

    if (!changed) return;

    record.sent = now;
    try dead_reckoning.sendActor(session.router, actor, now);
}

pub fn markRecord(session: anytype, now: u32) !void {
    if (try actorEntity(session) & 0x30 != 0) playerRecord(session, now).flags |= 1;
}

pub fn architectureOf(session: anytype) Architecture {
    return .{
        .level = &session.level,
        .scene = &session.scene,
        .angles = &session.angles,
        .router = session.router,
        .queue = &session.startup.architecture,
        .game_type = session.game_type,
    };
}

pub fn marks(session: anytype) inf_geometry.Marks {
    return .{ .context = session, .mark = Hooks(@TypeOf(session.*)).mark };
}

pub fn markChange(a: Architecture, value: inf_geometry.Mark) !void {
    if (a.game_type != 5) return;

    const sending = a.sending();

    switch (value) {
        .light, .floor, .ceiling, .sector_flags => |sector| {
            const bit: u32 = switch (value) {
                .light => 0x20,
                .floor, .ceiling => 4,
                else => 8,
            };

            const kind: u32 = switch (value) {
                .light => 9,
                .floor => 4,
                .ceiling => 3,
                else => 7,
            };

            a.scene.sectors[sector].runtime_flags |= bit;

            if (sending) try a.put(a.sectorWord(kind, sector));
        },
        .wall_flags => |at| {
            a.scene.sectors[at.sector].walls[at.index].runtime_flags |= 4;
            if (sending) try a.put(a.wallFlags(at.sector, at.index));
        },
        .corners => |at| {
            a.scene.sectors[at.sector].walls[at.index].runtime_flags |= 2;
            if (sending) try a.put(a.corners(at.sector, at.index));
        },
    }
}

pub fn applyChanges(
    map: *level_asset.Level,
    scene: *scene_module.Scene,
    angles: *const camera.Angles,
    bytes: []const u8,
    effects: anytype,
) !void {
    if (bytes.len < 0x12) return error.MalformedNetworkMessage;

    var offset: usize = 0x12;

    for (0..std.mem.readInt(u16, bytes[0x10..0x12], .little)) |_| {
        if (offset >= bytes.len) return error.MalformedNetworkMessage;
        offset += try applyChange(map, scene, angles, bytes[offset..], effects);
    }
}

pub fn applyChange(
    map: *level_asset.Level,
    scene: *scene_module.Scene,
    angles: *const camera.Angles,
    bytes: []const u8,
    effects: anytype,
) !usize {
    const size: usize = switch (bytes[0]) {
        0, 1 => 5,
        2, 3, 4, 7 => 7,
        5 => 11,
        6 => 21,
        8 => 9,
        9 => 4,
        else => return error.MalformedNetworkMessage,
    };

    if (bytes.len < size) return error.MalformedNetworkMessage;

    const index = std.mem.readInt(u16, bytes[1..3], .little);
    if (index >= map.sectors.len) return error.MalformedNetworkMessage;

    const sector = &map.sectors[index];
    const state = &scene.sectors[index];

    switch (bytes[0]) {
        0, 1, 2 => {
            if (bytes[0] != 1 and state.ceiling_slope == null) return error.MalformedNetworkMessage;
            if (bytes[0] != 0 and state.floor_slope == null) return error.MalformedNetworkMessage;

            switch (bytes[0]) {
                0 => try setSlope(map, scene, angles, index, true, word(i16, bytes, 3)),
                1 => try setSlope(map, scene, angles, index, false, word(i16, bytes, 3)),
                else => {
                    try setSlope(map, scene, angles, index, true, word(i16, bytes, 5));
                    try setSlope(map, scene, angles, index, false, word(i16, bytes, 3));
                },
            }
        },
        3 => {
            sector.ceiling.height = try height(bytes, 3);
            state.runtime_flags |= 1;
        },
        4 => {
            sector.floor.height = try height(bytes, 3);
            state.runtime_flags |= 1;
        },
        5 => {
            const floor = try height(bytes, 3);
            sector.ceiling.height = try height(bytes, 7);
            state.runtime_flags |= 1;
            sector.floor.height = floor;
        },
        6 => {
            const wall = word(u16, bytes, 3);
            if (wall >= sector.walls.len) return error.MalformedNetworkMessage;

            var corner: [4]f32 = undefined;

            for (&corner, 0..) |*value, i| value.* = try height(bytes, 5 + 4 * i);

            sector.vertices[sector.walls[wall].v1] = .{ .x = corner[0], .z = corner[1] };
            sector.vertices[sector.walls[wall].v2] = .{ .x = corner[2], .z = corner[3] };

            try inf_geometry.wallVectors(map, scene, .{ .sector = index, .index = wall });
            try effects.forget(index);
        },
        7 => {
            state.flags = (word(u32, bytes, 3) ^ state.flags) & 0x3fffffff ^ state.flags;
            sector.flags = state.flags;
            state.runtime_flags |= 8;
        },
        8 => return applyWallFlags(map, scene, index, bytes, effects),
        9 => {
            sector.ambient = @as(i8, @bitCast(bytes[3]));
            state.runtime_flags |= 1;
            return size;
        },
        else => unreachable,
    }

    try effects.refresh(index);

    return size;
}

pub fn shatterWall(session: anytype, sector: usize, wall: usize) !void {
    if (sector >= session.level.sectors.len or wall >= session.level.sectors[sector].walls.len) return error.MalformedNetworkMessage;
    try session.inf.shatterWall(&session.level, &session.scene, sector, wall);
}

pub fn scan(a: Architecture, skip: *u32) !void {
    const first = skip.*;
    var budget: u32 = architecture_batch;
    var seen: u32 = 0;
    const sending = a.sending();

    for (a.scene.sectors, 0..) |*sector, sector_index| {
        const slopes = if (sector.runtime_flags & 2 != 0) a.slopes(sector_index) else null;
        const parts = [_]?dead_reckoning.Change{
            slopes,
            if (sector.runtime_flags & 4 != 0) a.heights(sector_index) else null,
            if (sector.runtime_flags & 8 != 0) a.sectorWord(7, sector_index) else null,
        };

        for (parts) |part| if (part) |change| {
            if (first <= seen and budget != 0) {
                if (sending) try a.put(change);
                budget -= 1;
            }

            seen += 1;
        };

        for (sector.walls, 0..) |*wall, wall_index| for ([_]u32{
            4,
            2,
        }) |bit| if (wall.runtime_flags & bit != 0) {
            if (first <= seen and budget != 0) {
                if (sending) try a.put(
                    if (bit == 4) a.wallFlags(
                        sector_index,
                        wall_index,
                    ) else a.corners(sector_index, wall_index),
                );

                budget -= 1;
            }

            seen += 1;
        };
    }

    if (a.queue.count > 0) try a.queue.send(a.router, 0x200000);

    a.queue.count = 0;
    skip.* = if (budget == 0) first +% architecture_batch else 0;
}

pub fn sendArchitecture(session: anytype, client: u16) !void {
    try sendTo(architectureOf(session), client);
}

pub fn sendTo(a: Architecture, client: u16) !void {
    if (a.queue.count > 0) try a.queue.send(a.router, 0x200000);

    a.queue.count = 0;

    if (a.sending()) for (a.scene.sectors, 0..) |*sector, sector_index| {
        if (sector.runtime_flags & 2 != 0) if (a.slopes(sector_index)) |change| try a.put(change);

        if (sector.runtime_flags & 4 != 0) try a.put(a.heights(sector_index));

        if (sector.runtime_flags & 8 != 0) try a.put(a.sectorWord(7, sector_index));

        for (sector.walls, 0..) |*wall, wall_index| {
            if (wall.runtime_flags & 4 != 0) try a.put(a.wallFlags(sector_index, wall_index));
            if (wall.runtime_flags & 2 != 0) try a.put(a.corners(sector_index, wall_index));
        }
    };

    if (a.queue.count > 0) try a.queue.send(
        a.router,
        message.addressWord(message.Queue.dead_reckoning, @truncate(client)),
    );

    a.queue.count = 0;
}

pub fn requestObjects(router: anytype) !void {
    var request = message.objectRequest(0x402, router.own_client);
    const own = (router.own_client & 0xff) << 11;

    message.set(&request, message.sender_offset, own);
    message.set(&request, message.reply_offset, own);

    _ = try router.post(0x800, 0x402 | 0x80000000, &request);
}

pub fn bindPlayer(session: anytype, now: u32) !void {
    const router = session.router;
    if (session.player_wax.len == 0) return error.MissingPlayerWax;
    if (!session.stand_in and (session.mode == 1 or session.mode == 4 or session.mode == 5)) return error.TeamStartTextNotPorted;

    const entity = try actorEntity(session);
    const code = std.ascii.toUpper(session.player_wax[0]);
    if (router.own_client == 0 or router.own_client >= router.clients.len) return error.InvalidNetworkClientNumber;

    session.player_dead_reckoning = null;
    router.clients[router.own_client].player = .{ .code = code, .flags = entity };
    router.clients[router.own_client].in_level = true;
    session.network_player_bound = true;

    if (entity & 0x30 != 0) playerRecord(session, now).flags |= 1;

    const joined = session.game_type == 4 and session.stand_in and session.joined_text_pending;

    if (joined) session.joined_text_pending = false;

    try router.announce();
    try announcePlayer(session, 0);

    if (joined) {
        var template: [0x50]u8 = @splat(0);
        router.game.text(router.game.context, 0x13fc, &template);

        var text: [0x50]u8 = undefined;
        const shown = try campaign.printName(
            std.mem.sliceTo(&template, 0),
            std.mem.sliceTo(&router.player_name, 0),
            &text,
        );

        try @import("../network/database.zig").comment(router, shown, 0);
    }

    playerRecord(session, now).flags |= 1;

    try session.database.rebuildPlayers(router, session.mode, session.game_type, now);
    router.setQueueClosed(message.Queue.dead_reckoning, false);
}

pub fn announcePlayer(session: anytype, destination: u32) !void {
    const player = &session.player;
    const startup = session.startup;
    if (startup.costume >= character_costumes.len) return error.InvalidMultiplayerCharacter;

    var buffer: [message.actor_create_capacity]u8 = undefined;
    const bytes = try message.actorCreate(&buffer, session.router.own_client, .{
        .sector = @intCast(player.sector),
        .animation = @truncate(session.player_animation),
        .number = session.player_number,
        .flags = actorFlags(session),
        .position = .{
            @bitCast(player.position.x),
            @bitCast(player.position.y),
            @bitCast(player.position.z),
        },
        .angles = .{ player.pitch, player.yaw, 0 },
        .kind = 0,
        .short_70 = 0,
        .short_72 = 0,
        .word_74 = @bitCast(player.eye_height),
        .words_7c = .{
            @bitCast(player.velocity.x),
            @bitCast(player.velocity.y),
            @bitCast(player.velocity.z),
            0,
            0,
            0,
        },
        .word_3c = @bitCast(player.body_height),
        .word_94 = @bitCast(player.radius),
        .words_40 = @splat(0),
        .entity = try actorEntity(session),
        .costume = character_costumes[startup.costume],
        .logic = "DRECK_PEX",
        .item = "",
    });

    _ = try session.router.post(destination, 0x3fd | 0x40000000, bytes);
}

fn playerActor(session: anytype) !dead_reckoning.Actor {
    const player = &session.player;
    if (player.sector >= session.level.sectors.len) return error.InvalidPlayerSector;

    return .{
        .number = session.player_number,
        .flags = actorFlags(session),
        .entity = try actorEntity(session),
        .position = .{ player.position.x, player.position.y, player.position.z },
        .angles = .{ player.pitch, player.yaw, 0 },
        .sector = @intCast(player.sector),
        .velocity = .{
            @bitCast(player.velocity.x),
            @bitCast(player.velocity.y),
            @bitCast(player.velocity.z),
        },
        .animation = @truncate(session.player_animation),
        .airborne = player.flags & 0x2000 != 0,
        .gravity = session.level.sectors[player.sector].gravity,
        .frame_seconds = session.frame_seconds,
    };
}

fn sendPlayer(session: anytype, now: u32) !bool {
    if (!session.network_player_bound) return false;

    const record = playerRecord(session, now);
    if (!(record.sent +% 1000 < now)) return false;

    record.sent = now;
    try dead_reckoning.sendActor(session.router, try playerActor(session), now);

    return true;
}

fn largerThan(a: [3]f32, b: [3]f32, limit: f32) bool {
    var largest = @abs(@as(f64, a[0]) - b[0]);

    for (1..3) |axis| {
        const next = @abs(@as(f64, a[axis]) - b[axis]);
        if (next >= largest) largest = next;
    }

    return largest > limit;
}

fn floats(words: [3]u32) [3]f32 {
    return .{ @bitCast(words[0]), @bitCast(words[1]), @bitCast(words[2]) };
}

fn angleDifference(from: i16, to: i16) i16 {
    const difference: i16 = (to & 0x3fff) - (from & 0x3fff);
    if (@abs(@as(i32, difference)) <= 0x2000) return difference;

    return if (difference < 0) difference +% 0x4000 else difference -% 0x4000;
}

fn playerRecord(session: anytype, now: u32) *dead_reckoning.Record {
    if (session.player_dead_reckoning == null) {
        const position = session.player.position;
        session.player_dead_reckoning = dead_reckoning.Record.init(
            .{ position.x, position.y, position.z },
            now,
        );
    }

    return &session.player_dead_reckoning.?;
}

fn receive(session: anytype) !void {
    const router = session.router;
    const now = router.now;
    const startup = session.startup;

    if (router.own_client == 1 and startup.architecture.count != 0 and startup.architecture_due < now) {
        startup.architecture_due = now +% 100;
        try startup.architecture.send(router, 0x200000);
    }

    while (try router.read(message.Queue.dead_reckoning)) |bytes| {
        defer router.release(bytes);

        switch (message.get(bytes, message.number_offset)) {
            0x416, 0x417, 0x41a => {},
            0x418 => try update(session, bytes, now),
            0x419 => try applyArchitecture(session, bytes),
            0x41b => return error.DeadReckoningMessage41bNotPorted,
            else => {
                var name: [16]u8 = undefined;
                std.log.debug(
                    "DeadReck_ProcessRequests: Unhandled message {s}",
                    .{message.name(message.get(bytes, message.number_offset), &name)},
                );
            },
        }
    }
}

fn applyArchitecture(session: anytype, bytes: []const u8) !void {
    const effects: SessionEffects(@TypeOf(session.*)) = .{ .session = session };
    try applyChanges(&session.level, &session.scene, &session.angles, bytes, effects);
}

fn word(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn height(bytes: []const u8, at: usize) !f32 {
    const value: f32 = @bitCast(word(u32, bytes, at));
    if (!std.math.isFinite(value)) return error.MalformedNetworkMessage;

    return value;
}

fn setSlope(
    map: *level_asset.Level,
    scene: *scene_module.Scene,
    angles: *const camera.Angles,
    sector: usize,
    ceiling: bool,
    angle: i16,
) !void {
    var plane = if (ceiling) map.sectors[sector].ceiling else map.sectors[sector].floor;
    const hinge = plane.slope orelse return error.MissingSlope;

    plane.slope = .{ .sector = hinge.sector, .wall = hinge.wall, .angle = angle };
    const slope = try scene_module.Slope.initV111(map, sector, plane, angles);

    if (ceiling) scene.sectors[sector].ceiling_slope = slope else scene.sectors[sector].floor_slope = slope;
}

fn applyWallFlags(
    map: *level_asset.Level,
    scene: *scene_module.Scene,
    sector: usize,
    bytes: []const u8,
    effects: anytype,
) !usize {
    const wall = word(u16, bytes, 3);
    const flags = word(u32, bytes, 5);
    if (wall >= map.sectors[sector].walls.len) return error.MalformedNetworkMessage;

    const state = &scene.sectors[sector].walls[wall];

    if ((state.flags ^ flags) & 0x4000 != 0 and flags & 0x4000 == 0) try effects.shatter(
        sector,
        wall,
    );

    state.flags = (state.flags ^ flags) & 0x4000 ^ flags;
    map.sectors[sector].walls[wall].flags = state.flags;
    state.runtime_flags |= 4;

    try effects.refresh(sector);

    return 9;
}

fn refreshSector(map: *const level_asset.Level, scene: *scene_module.Scene, sector: usize) !void {
    for (map.sectors[sector].walls, 0..) |wall, index| {
        if (wall.adjoin >= 0) try scene.prepareWall(
            map,
            @intCast(wall.adjoin),
            @intCast(wall.mirror),
        );

        try scene.prepareWall(map, sector, index);
    }
}

fn update(session: anytype, bytes: []const u8, now: u32) !void {
    const target = message.get(bytes, message.reply_offset);
    const sender = message.get(bytes, message.sender_offset);
    const object = session.database.find(target) orelse {
        try session.database.requestObject(session.router, sender, target, true, now);
        return;
    };

    const index = switch (object) {
        .actor => |value| value,
        else => return error.DeadReckoningForNonActor,
    };

    if (index != local_player) return @import(
        "network_actors.zig",
    ).updateRemote(session, index, sender, bytes, now);

    if (message.client(
        sender,
    ) != session.router.own_client) return error.RemoteActorUpdateNotPorted;

    const entity = try actorEntity(session);
    if (entity & 0x30 == 0) return;

    const value = try dead_reckoning.readUpdate(bytes);

    playerRecord(session, now).take(&value, now);
}

fn scanArchitecture(session: anytype) !void {
    try scan(architectureOf(session), &session.startup.architecture_skip);
}
