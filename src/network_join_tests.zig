//! A host and a joining game in one process, talking over the network
//! driver on local UDP ports: the host's start and level, the joiner's
//! connect, its loading screen and its level load, then both playing.
//!
//! The clock is driven by the test, not by the wall, and one pass services
//! both drivers and runs a level frame each. The host's driver has to keep
//! answering while the joiner waits for its welcome, which is what a second
//! machine would do.

const std = @import("std");
const lab = @import("assets/lab.zig");
const campaign = @import("campaign.zig");
const enet_driver = @import("platform/enet_driver.zig");
const loading_display = @import("ui/loading_display.zig");
const session_module = @import("render/session.zig");
const player_input = @import("player/input.zig");
const Session = session_module.Session;
const cmm = @import("script/cmm.zig");
const level_asset = @import("assets/level.zig");
const testing = std.testing;

const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";

const Window = struct {
    pixels: [loading_display.width * loading_display.height]u8 = @splat(0),
    palette: [256]u32 = @splat(0),
    now: *u32,
    presents: u32 = 0,

    fn host(self: *Window, archive: lab.Archive) campaign.FrameHost {
        return .{
            .context = self,
            .pump = pump,
            .sound = sound,
            .clock = clock,
            .screen = .{ .pixels = &self.pixels, .palette = &self.palette, .context = self, .present = present },
            .archive = archive,
        };
    }

    fn of(context: *anyopaque) *Window {
        return @ptrCast(@alignCast(context));
    }

    fn pump(_: *anyopaque) anyerror!void {}

    fn sound(_: *anyopaque) anyerror!void {}

    fn clock(context: *anyopaque) u32 {
        return of(context).now.*;
    }

    fn present(context: *anyopaque, _: []const u8, _: *const [256]u32) anyerror!void {
        of(context).presents += 1;
    }
};

const Answering = struct {
    session: *enet_driver.Session,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Answering) void {
        while (!self.stop.load(.acquire)) self.session.service(1);
    }
};

const Pair = struct {
    host: *campaign.Startup,
    joiner: *campaign.Startup,
    host_level: *Session,
    join_level: *Session,
    host_driver: *enet_driver.Session,
    join_driver: *enet_driver.Session,
    now: *u32,

    fn frame(self: Pair, host_packet: *const player_input.Packet, join_packet: *const player_input.Packet) !void {
        self.now.* += 10;
        self.host_driver.service(1);
        self.join_driver.service(1);
        self.host.router.now = self.now.*;
        try self.host_level.advance(testing.allocator, host_packet, self.now.* -% self.host_level.animation_time);
        self.joiner.router.now = self.now.*;
        try self.join_level.advance(testing.allocator, join_packet, self.now.* -% self.join_level.animation_time);
    }
};

const Glass = struct { sector: usize, wall: usize, mirror_sector: usize, mirror_wall: usize };

fn countItems(level: *const Session, name: []const u8) usize {
    var count: usize = 0;
    for (level.actor_slots, level.removed_actors) |slot, removed| if (!removed) if (slot) |actor| {
        if (std.ascii.eqlIgnoreCase(actor.network_item, name)) count += 1;
    };
    return count;
}

fn countCorpses(level: *const Session) usize {
    var count: usize = 0;
    for (level.actor_slots, level.removed_actors) |slot, removed| if (!removed) if (slot) |actor| {
        if (std.mem.eql(u8, actor.logic_name, "misc_CorpseDispatch")) count += 1;
    };
    return count;
}

fn sourceOf(level: *const Session, number: u32) ?usize {
    for (level.actor_numbers, 0..) |value, source| if (value == number and !level.removed_actors[source] and level.actor_slots[source] != null) return source;
    return null;
}

fn insideSector(level: *const Session, sector: usize, x: f32, z: f32) bool {
    const value = level.level.sectors[sector];
    var inside = false;
    for (value.walls) |wall| {
        const a = value.vertices[wall.v1];
        const b = value.vertices[wall.v2];
        if ((a.z > z) != (b.z > z) and x < a.x + (z - a.z) * (b.x - a.x) / (b.z - a.z)) inside = !inside;
    }
    return inside;
}

fn faceGlass(level: *Session) !Glass {
    for (level.level.sectors, 0..) |sector, sector_index| for (sector.walls, 0..) |wall, wall_index| {
        if (level.scene.sectors[sector_index].walls[wall_index].flags & 0x4000 == 0 or wall.adjoin < 0) continue;
        const a = sector.vertices[wall.v1];
        const b = sector.vertices[wall.v2];
        const length = @sqrt((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z));
        if (length < 2) continue;
        const middle: [2]f32 = .{ (a.x + b.x) * 0.5, (a.z + b.z) * 0.5 };
        for ([_]f32{ 1, -1 }) |side| {
            const x = middle[0] + side * 4 * (b.z - a.z) / length;
            const z = middle[1] - side * 4 * (b.x - a.x) / length;
            if (!insideSector(level, sector_index, x, z)) continue;
            const other: usize = @intCast(wall.adjoin);
            const floor = try level.scene.floorHeight(&level.level, sector_index, .{ .x = x, .z = z });
            const bottom = @max(try level.scene.floorHeight(&level.level, sector_index, .{ .x = middle[0], .z = middle[1] }), try level.scene.floorHeight(&level.level, other, .{ .x = middle[0], .z = middle[1] }));
            const top = @min(try level.scene.ceilingHeight(&level.level, sector_index, .{ .x = middle[0], .z = middle[1] }), try level.scene.ceilingHeight(&level.level, other, .{ .x = middle[0], .z = middle[1] }));
            level.player.position = .{ .x = x, .y = floor, .z = z };
            level.player.velocity = .{ .x = 0, .y = 0, .z = 0 };
            level.player.sector = sector_index;
            const turn = 16384.0 / (2.0 * std.math.pi);
            const eye = level.player.body_height * 0.92 + floor;
            level.player.yaw = @intFromFloat(std.math.atan2(middle[0] - x, middle[1] - z) * turn);
            level.player.head_yaw = 0;
            level.player.pitch = @intFromFloat(std.math.atan2((bottom + top) * 0.5 - eye, 4.0) * turn);
            return .{ .sector = sector_index, .wall = wall_index, .mirror_sector = other, .mirror_wall = @intCast(wall.mirror) };
        }
    };
    return error.NoGlassInLevel;
}

fn hasMessage(level: *const Session, text: []const u8) bool {
    for (level.messages.entries) |entry| if (std.mem.eql(u8, std.mem.sliceTo(&entry.text, 0), text)) return true;
    return false;
}

fn hostFrame(level: *Session, now: u32) !void {
    const packet: player_input.Packet = .{};
    try level.advance(testing.allocator, &packet, now -% level.animation_time);
}

test "two games on local UDP: a joiner gets its client number, the game record and Dry Gulch" {
    const a = testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    const messages = try system.find("LOCAL.MSG", 0);
    var now: u32 = 1000;

    var host = try campaign.Startup.initHost(a, .{ .basename = "DRYGULCH", .location = "Dry Gulch", .mode = 6, .mode_name = "Death Match", .game_name = "Outlaws" });
    defer host.deinit(a);
    host.bindRouterParts(messages);
    host.router.now = now;
    var host_opener: enet_driver.Opener = .{ .allocator = a, .port = 0 };
    try testing.expect(try host.connectHost(host_opener.provider()));
    defer host.router.close();
    const host_driver = &host_opener.session.?;
    try host.beginHost(a, testing.io, path, system);
    const log_level = testing.log_level;
    testing.log_level = .err;
    const host_level_open = Session.open(a, testing.io, path, system, &host);
    testing.log_level = log_level;
    const host_level = try host_level_open;
    defer host_level.deinit(a);
    try testing.expectEqual(@as(u32, 0x37169dc6), host.server.record.parameter);
    host.networkLevelLoaded();
    try host_level.bindStandIn(host_level.animation_time);
    try host.enterLobby();
    for (0..100) |_| {
        now += 10;
        try hostFrame(host_level, now);
    }

    var joiner = try campaign.Startup.initJoin(a, .{ .session_name = " (1.1) Outlaws" });
    defer joiner.deinit(a);
    joiner.bindRouterParts(messages);
    joiner.router.player_name[0..7].* = "Joiner\x00".*;
    var window: Window = .{ .now = &now };
    joiner.frame_host = window.host(system);
    joiner.router.now = now;
    var join_opener: enet_driver.Opener = .{ .allocator = a, .host = "127.0.0.1", .port = host_driver.port() };
    defer joiner.router.close();
    {
        var answering: Answering = .{ .session = host_driver };
        const thread = try std.Thread.spawn(.{}, Answering.run, .{&answering});
        defer {
            answering.stop.store(true, .release);
            thread.join();
        }
        try testing.expect(try joiner.beginJoin(join_opener.provider(), " (1.1) Outlaws"));
    }
    const join_driver = &join_opener.session.?;
    try testing.expectEqualStrings("CONNECTED", std.mem.sliceTo(&joiner.loading.text, 0));
    try testing.expectEqual(@as(u32, 0xffffffff), joiner.router.own_client);

    var keys: campaign.KeyQueue = .{};
    const end = for (0..4000) |_| {
        now += 10;
        host_driver.service(1);
        join_driver.service(1);
        try hostFrame(host_level, now);
        if (try joiner.stepJoin(&keys)) |found| break found;
    } else return error.NothingArrived;
    try testing.expect(end == .joined);
    try testing.expectEqual(@as(u32, 3), joiner.router.own_client);
    try testing.expectEqual(@as(u32, 2), host.router.clientCount());
    try testing.expectEqual(@as(u32, 3), joiner.engine.scenario);
    try testing.expectEqualStrings("!", joiner.request.path());

    for (0..4000) |_| {
        now += 10;
        host_driver.service(1);
        join_driver.service(1);
        try hostFrame(host_level, now);
        if (try joiner.joinPass(a, testing.io, path, system, &keys) == .story) break;
    } else return error.NoGameRecord;
    try testing.expectEqualStrings("GETTING INFO", std.mem.sliceTo(&joiner.loading.text, 0));
    try testing.expectEqual(@as(u32, 4), joiner.engine.game_type);
    try testing.expectEqual(@as(u32, 6), joiner.mode);
    try testing.expectEqual(@as(u32, 1), joiner.engine.scenario);
    try testing.expectEqual(@as(u32, 0x37169dc6), joiner.database.record.parameter);
    try testing.expectEqualStrings("cidmjame.itm", joiner.player_definition);
    try testing.expectEqualStrings("drygulch", joiner.currentEvent().?.name);

    try joiner.beginJoinedLevel();
    try testing.expectEqualStrings("LOADING LEVEL", std.mem.sliceTo(&joiner.loading.text, 0));
    const join_level = try Session.open(a, testing.io, path, system, &joiner);
    defer join_level.deinit(a);
    try joiner.endJoinedLevel();
    joiner.networkLevelLoaded();
    try testing.expect(!joiner.loading.isOpen());
    try testing.expectEqualStrings("drygulch", join_level.level_name);
    try testing.expectEqual(@as(usize, 0), join_level.objects.entries.len);
    try testing.expectEqual(@as(usize, 0), join_level.player.sector);
    try testing.expectEqual(@as(f32, -10000.0), join_level.player.position.y);
    try testing.expectEqual(@as(u32, 7), joiner.engine.scenario);
    try testing.expectEqual(@as(u32, 2), host.router.clientCount());

    try join_level.bindStandIn(join_level.animation_time);
    try joiner.enterLobby();
    try testing.expectEqual(@as(u32, 1), joiner.engine.game_state);
    try testing.expectEqual(@as(u32, 8), joiner.engine.scenario);
    const rejected_before = joiner.router.rejected;
    const packet: player_input.Packet = .{};
    for (0..300) |_| {
        now += 10;
        host_driver.service(1);
        join_driver.service(1);
        try hostFrame(host_level, now);
        joiner.router.now = now;
        try join_level.advance(a, &packet, now -% join_level.animation_time);
    }
    try testing.expectEqual(@as(u32, 0), host.router.rejected);
    try testing.expectEqual(rejected_before, joiner.router.rejected);

    const stand_in: @import("network/router.zig").Player = .{ .code = 'J', .flags = 0x1000090 };
    for ([_]*campaign.Startup{ &host, &joiner }) |side| {
        try testing.expectEqual(@as(usize, 2), side.database.player_count);
        try testing.expectEqualSlices(u8, &.{ 3, 1 }, side.database.player_order[0..2]);
        try testing.expectEqual(@as(?@TypeOf(stand_in), stand_in), side.router.clients[1].player);
        try testing.expectEqual(@as(?@TypeOf(stand_in), stand_in), side.router.clients[3].player);
    }
    try testing.expectEqual(@as(usize, 1), host_level.remote_players.items.len);
    try testing.expectEqual(@as(usize, 1), join_level.remote_players.items.len);
    const remote_joiner = host_level.actor_slots[host_level.remote_players.items[0].source].?;
    try testing.expectEqual(join_level.player_number, host_level.actor_numbers[host_level.remote_players.items[0].source]);
    try testing.expectEqual(@as(f32, -10000.0), remote_joiner.position.y);
    try testing.expectEqualStrings("DRECK_PEX", remote_joiner.logic_name);
    try testing.expectEqual(host_level.player_number, join_level.actor_numbers[join_level.remote_players.items[0].source]);

    var copies: usize = 0;
    for (host_level.actor_slots, host_level.removed_actors, host_level.actor_numbers, 0..) |slot, removed, number, source| {
        if (removed or source == host_level.remote_players.items[0].source) continue;
        const actor = slot orelse continue;
        if (number == 0 or actor.network_item.len == 0) continue;
        const found = join_level.database.find(number) orelse return error.MissingJoinerCopy;
        const copy = join_level.actor_slots[found.actor].?;
        try testing.expectEqualStrings(actor.network_item, copy.network_item);
        try testing.expectEqual(actor.sector, copy.sector);
        try testing.expectEqual(actor.position, copy.position);
        try testing.expectEqual(actor.yaw, copy.yaw);
        try testing.expectEqualStrings(actor.logic_name, copy.logic_name);
        copies += 1;
    }
    try testing.expect(copies > 0);

    var walls: usize = 0;
    for (host_level.scene.sectors, join_level.scene.sectors) |host_sector, join_sector| {
        for (host_sector.walls, join_sector.walls) |host_wall, join_wall| if (host_wall.runtime_flags & 4 != 0) {
            try testing.expectEqual(host_wall.flags, join_wall.flags);
            try testing.expect(join_wall.runtime_flags & 4 != 0);
            walls += 1;
        };
    }
    try testing.expect(walls > 0);

    var joined = false;
    for (host_level.messages.entries) |entry| {
        if (std.mem.eql(u8, std.mem.sliceTo(&entry.text, 0), "Joiner joined the game!")) joined = true;
    }
    try testing.expect(joined);

    const sides = [_]struct { startup: *campaign.Startup, level: *Session }{
        .{ .startup = &host, .level = host_level },
        .{ .startup = &joiner, .level = join_level },
    };
    for (sides, 0..) |side, which| {
        try side.level.removeStandIn(side.level.animation_time);
        try side.startup.leaveLobby(1);
        if (side.level.server_enabled) side.level.seedStartRequest(now);
        const started = for (0..1000) |_| {
            now += 10;
            host_driver.service(1);
            join_driver.service(1);
            for (sides, 0..) |other, index| {
                other.startup.router.now = now;
                if (index == which)
                    try other.level.networkPass(a, now -% other.level.animation_time, null)
                else
                    try other.level.advance(a, &packet, now -% other.level.animation_time);
            }
            if (side.startup.engine.game_state == 1) break true;
            try side.startup.startStep(side.level.animation_time);
        } else false;
        try testing.expect(started);
        try testing.expectEqual(@as(u32, 2), side.startup.engine.scenario);
        try testing.expect(!side.level.stand_in);
        try testing.expect(side.level.player.position.y != -10000.0);
    }

    const host_start = host_level.player.position;
    var walking: player_input.Packet = .{};
    walking.entries[@intFromEnum(player_input.Slot.forward)] = .{ .value = 5120, .flags = player_input.absolute };
    var largest_gap: f32 = 0;
    var reckoned_frames: usize = 0;
    var last_place = join_level.actor_slots[join_level.remote_players.items[0].source].?.position;
    var last_update = join_level.remote_players.items[0].record.?.time;
    for (0..200) |_| {
        now += 10;
        host_driver.service(1);
        join_driver.service(1);
        host.router.now = now;
        try host_level.advance(a, &walking, now -% host_level.animation_time);
        joiner.router.now = now;
        try join_level.advance(a, &packet, now -% join_level.animation_time);
        const copy = join_level.actor_slots[join_level.remote_players.items[0].source].?;
        const update = join_level.remote_players.items[0].record.?.time;
        if (update == last_update and (copy.position.x != last_place.x or copy.position.z != last_place.z)) reckoned_frames += 1;
        last_place = copy.position;
        last_update = update;
        const gap_x = copy.position.x - host_level.player.position.x;
        const gap_z = copy.position.z - host_level.player.position.z;
        largest_gap = @max(largest_gap, @sqrt(gap_x * gap_x + gap_z * gap_z));
    }
    try testing.expect(reckoned_frames > 100);
    try testing.expect(largest_gap < 10);
    const host_chors = host_level.player_choreographies;
    try testing.expect(host_chors.walk != host_chors.stand);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, host_chors.walk))), host_level.player_animation);
    try testing.expectEqual(@as(u32, 0x20), host_level.player.flags & 0x3f0);
    try testing.expectEqual(host_level.player_animation, join_level.actor_slots[join_level.remote_players.items[0].source].?.choreography);
    for (0..50) |_| {
        now += 10;
        host_driver.service(1);
        join_driver.service(1);
        host.router.now = now;
        try host_level.advance(a, &packet, now -% host_level.animation_time);
        joiner.router.now = now;
        try join_level.advance(a, &packet, now -% join_level.animation_time);
    }
    try testing.expectEqual(@as(u32, 0), host.router.rejected);
    try testing.expectEqual(rejected_before, joiner.router.rejected);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, host_chors.stand))), host_level.player_animation);
    try testing.expectEqual(host_level.player_animation, join_level.actor_slots[join_level.remote_players.items[0].source].?.choreography);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, join_level.player_choreographies.stand))), join_level.player_animation);
    const walked = host_level.player.position;
    try testing.expect(@abs(walked.x - host_start.x) + @abs(walked.z - host_start.z) > 10);
    try testing.expectEqual(@as(usize, 1), join_level.remote_players.items.len);
    const remote_host = join_level.actor_slots[join_level.remote_players.items[0].source].?;
    try testing.expectEqual(host_level.player_number, join_level.actor_numbers[join_level.remote_players.items[0].source]);
    try testing.expectEqual(@as(u32, 0), remote_host.secondary_flags & 0x1000000);
    try testing.expectEqual(host_level.player.sector, remote_host.sector);
    try testing.expect(@abs(remote_host.position.x - walked.x) + @abs(remote_host.position.z - walked.z) < 1);
    try testing.expectEqual(@as(usize, 1), host_level.remote_players.items.len);
    const remote_join = host_level.actor_slots[host_level.remote_players.items[0].source].?;
    try testing.expectEqual(join_level.player_number, host_level.actor_numbers[host_level.remote_players.items[0].source]);
    try testing.expectEqual(join_level.player.sector, remote_join.sector);
    try testing.expect(@abs(remote_join.position.x - join_level.player.position.x) + @abs(remote_join.position.z - join_level.player.position.z) < 1);

    const pair: Pair = .{ .host = &host, .joiner = &joiner, .host_level = host_level, .join_level = join_level, .host_driver = host_driver, .join_driver = join_driver, .now = &now };
    join_level.player.position = .{ .x = 195, .y = host_level.player.position.y, .z = 254 };
    join_level.player.sector = host_level.player.sector;
    for (0..50) |_| try pair.frame(&packet, &packet);
    {
        const copy = host_level.actor_slots[host_level.remote_players.items[0].source].?;
        try testing.expectEqual(join_level.player.sector, copy.sector);
        const eye_y = host_level.player.body_height * 0.92 + host_level.player.position.y;
        const dx = copy.position.x - host_level.player.position.x;
        const dy = copy.position.y + copy.height * 0.5 - eye_y;
        const dz = copy.position.z - host_level.player.position.z;
        const turn = 16384.0 / (2.0 * std.math.pi);
        host_level.player.yaw = @intFromFloat(std.math.atan2(dx, dz) * turn);
        host_level.player.head_yaw = 0;
        host_level.player.pitch = @intFromFloat(std.math.atan2(dy, @sqrt(dx * dx + dz * dz)) * turn);
    }
    var drops: [26][]const u8 = undefined;
    var drop_count: usize = 0;
    var drops_before: [26]usize = undefined;
    for (join_level.inventory.slots[1..]) |slot| if (slot) |owned| {
        const class = owned.definition.item_class;
        if (class == 0x4655454c or class == 0x57454150 or owned.definition.no_drop or owned.definition.ground_item.len == 0) continue;
        drops[drop_count] = owned.definition.ground_item;
        drops_before[drop_count] = countItems(host_level, owned.definition.ground_item);
        drop_count += 1;
    };
    try testing.expect(drop_count > 0);
    var firing: player_input.Packet = .{};
    firing.entries[@intFromEnum(player_input.Slot.fire)] = .{ .value = 1, .flags = player_input.absolute | player_input.pressed };
    var releasing: player_input.Packet = .{};
    releasing.entries[@intFromEnum(player_input.Slot.fire)] = .{ .flags = player_input.released };
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    var hurt = false;
    var dead_at: ?usize = null;
    const shoot: u32 = @bitCast(@as(i32, host_chors.shoot));
    const stand: u32 = @bitCast(@as(i32, host_chors.stand));
    var shot_frames: usize = 0;
    var stood_after_shot = false;
    var copy_shot_frames: usize = 0;
    for (0..800) |frame| {
        _ = try host_level.render(a, pixels, host_level.animation_time);
        const shooting = if (frame % 40 == 0) &firing else if (frame % 40 == 1) &releasing else &packet;
        try pair.frame(if (dead_at == null) shooting else &packet, &packet);
        if (host_level.player_animation == shoot) shot_frames += 1;
        if (shot_frames != 0 and host_level.player_animation == stand) stood_after_shot = true;
        if (join_level.actor_slots[join_level.remote_players.items[0].source].?.choreography == shoot) copy_shot_frames += 1;
        if (join_level.inventory.health < 10 and join_level.inventory.health > 0) hurt = true;
        if (dead_at == null and join_level.inventory.health == 0) dead_at = frame;
        if (dead_at) |at| if (frame > at + 50) break;
    }
    try testing.expect(hurt);
    try testing.expect(dead_at != null);
    try testing.expect(shoot != stand);
    try testing.expect(shot_frames > 0);
    try testing.expect(stood_after_shot);
    try testing.expect(copy_shot_frames > 0);
    try testing.expectEqual(@as(f32, 10), host_level.inventory.health);
    try testing.expect(join_level.player.flags & 0x10000000 != 0);
    for (join_level.inventory.slots[1..]) |slot| if (slot) |owned| {
        try testing.expect(owned.definition.item_class != 0x57454150);
    };
    try testing.expect(hasMessage(join_level, "Player killed you!"));
    try testing.expect(hasMessage(host_level, "killed"));
    try testing.expectEqual(@as(i16, 1), host.router.scores[1].points);
    try testing.expectEqual(@as(i16, 1), joiner.router.scores[1].points);
    try testing.expectEqual(@as(i16, 0), host.router.scores[3].points);
    for (drops[0..drop_count], drops_before[0..drop_count]) |name, before| {
        try testing.expect(countItems(host_level, name) > before);
        try testing.expectEqual(countItems(host_level, name), countItems(join_level, name));
    }

    var pressing: player_input.Packet = .{};
    pressing.entries[@intFromEnum(player_input.Slot.fire)] = .{ .value = 1, .flags = player_input.absolute | player_input.pressed };
    for (0..400) |frame| {
        try pair.frame(&packet, if (frame % 30 == 0) &pressing else &packet);
        if (join_level.death_restart_requested) break;
    } else return error.NoRevival;
    join_level.death_restart_requested = false;
    const fell_at = join_level.player.position;
    const old_number = join_level.player_number;
    const corpses_before = .{ countCorpses(host_level), countCorpses(join_level) };
    try join_level.revive(join_level.animation_time);
    try testing.expectEqual(@as(u32, 3), joiner.engine.game_state);
    try join_level.removePlayer(join_level.animation_time);
    try joiner.restartInLevel();
    const restarted = for (0..1000) |_| {
        now += 10;
        host_driver.service(1);
        join_driver.service(1);
        host.router.now = now;
        try host_level.advance(a, &packet, now -% host_level.animation_time);
        joiner.router.now = now;
        try join_level.networkPass(a, now -% join_level.animation_time, null);
        if (joiner.engine.game_state == 1) break true;
        try joiner.startStep(join_level.animation_time);
    } else false;
    try testing.expect(restarted);
    try testing.expectEqual(@as(u32, 2), joiner.engine.scenario);
    try testing.expectEqual(@as(f32, 10), join_level.inventory.health);
    try testing.expect(join_level.player.flags & 0x10000000 == 0);
    try testing.expect(join_level.player_number != old_number);
    for (0..100) |_| try pair.frame(&packet, &packet);
    for ([_]*Session{ host_level, join_level }, [_]usize{ corpses_before[0], corpses_before[1] }) |level, before| {
        try testing.expectEqual(before + 1, countCorpses(level));
        var found = false;
        for (level.actor_slots, level.removed_actors) |slot, removed| if (!removed) if (slot) |actor| {
            if (!std.mem.eql(u8, actor.logic_name, "misc_CorpseDispatch")) continue;
            if (actor.position.x == fell_at.x and actor.position.z == fell_at.z and std.ascii.eqlIgnoreCase(actor.logic_resource.?, join_level.player_wax)) found = true;
        };
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 1), host_level.remote_players.items.len);
    const respawned = host_level.actor_slots[host_level.remote_players.items[0].source].?;
    try testing.expectEqual(join_level.player_number, host_level.actor_numbers[host_level.remote_players.items[0].source]);
    try testing.expect(host_level.database.find(old_number) == null);
    try testing.expect(@abs(respawned.position.x - join_level.player.position.x) + @abs(respawned.position.z - join_level.player.position.z) < 1);

    const Taking = struct {
        taker: *Session,
        other: *Session,
    };
    for ([_]Taking{ .{ .taker = join_level, .other = host_level }, .{ .taker = host_level, .other = join_level } }) |side| {
        var taken: ?struct { source: usize, number: u32, copy: usize } = null;
        for (side.taker.actor_slots, 0..) |slot, source| {
            if (taken != null) break;
            const actor = slot orelse continue;
            const number = side.taker.actor_numbers[source];
            if (side.taker.removed_actors[source] or number == 0) continue;
            const native = cmm.resolve(actor.logic_name) catch continue;
            if (native != .ground_object) continue;
            const copy = sourceOf(side.other, number) orelse continue;
            side.taker.player.position = actor.position;
            side.taker.player.velocity = .{ .x = 0, .y = 0, .z = 0 };
            side.taker.player.sector = actor.sector;
            for (0..20) |_| {
                if (side.taker == host_level) try pair.frame(&walking, &packet) else try pair.frame(&packet, &walking);
                if (side.taker.removed_actors[source]) break;
            }
            if (side.taker.removed_actors[source]) taken = .{ .source = source, .number = number, .copy = copy };
        }
        const pickup = taken orelse return error.NoPickupTaken;
        try testing.expectEqual(@as(u32, 0), side.taker.actor_numbers[pickup.source]);
        for (0..20) |_| try pair.frame(&packet, &packet);
        try testing.expect(side.other.removed_actors[pickup.copy]);
        try testing.expect(sourceOf(side.other, pickup.number) == null);
    }

    const Shooting = struct { shooter: *Session, other: *Session };
    for ([_]Shooting{ .{ .shooter = host_level, .other = join_level }, .{ .shooter = join_level, .other = host_level } }) |side| {
        const glass = try faceGlass(side.shooter);
        try testing.expect(side.other.scene.sectors[glass.sector].walls[glass.wall].flags & 0x4000 != 0);
        for (0..300) |_| {
            _ = try side.shooter.render(a, pixels, side.shooter.animation_time);
            try pair.frame(&packet, &packet);
            const weapon = side.shooter.hud.weaponAnimation() orelse continue;
            if (weapon.ready and side.shooter.weapon_state.action == -1) break;
        } else return error.WeaponNeverReady;
        try testing.expect(side.shooter.player.sector == glass.sector);
        const shots_before = side.shooter.weapon_state.shot_count;
        for (0..60) |frame| {
            _ = try side.shooter.render(a, pixels, side.shooter.animation_time);
            const shot = if (frame == 0) &firing else if (frame == 1) &releasing else &packet;
            if (side.shooter == host_level) try pair.frame(shot, &packet) else try pair.frame(&packet, shot);
            if (side.shooter.scene.sectors[glass.sector].walls[glass.wall].flags & 0x4000 == 0) break;
        }
        try testing.expect(side.shooter.weapon_state.shot_count != shots_before);
        try testing.expectEqual(@as(u32, 0), side.shooter.scene.sectors[glass.sector].walls[glass.wall].flags & 0x4000);
        for (0..20) |_| try pair.frame(&packet, &packet);
        for ([_][2]usize{ .{ glass.sector, glass.wall }, .{ glass.mirror_sector, glass.mirror_wall } }) |at| {
            const wall = side.other.scene.sectors[at[0]].walls[at[1]];
            try testing.expectEqual(@as(u32, 0), wall.flags & 0x4800);
            try testing.expect(wall.runtime_flags & 4 != 0);
        }
    }

    {
        const door = for (host_level.level.sectors, 0..) |sector, index| {
            if (std.mem.eql(u8, sector.name, "ROTATING_DOOR01")) break index;
        } else return error.NoRotatingDoor;
        const room: usize = @intCast(host_level.level.sectors[door].walls[0].adjoin);
        const elevator = for (host_level.inf.elevators) |*value| {
            if (value.sector == door) break value;
        } else return error.NoDoorElevator;
        try testing.expectEqual(@as(usize, 2), elevator.stops.items.len);
        try testing.expectEqual(@as(f32, 0), elevator.stops.items[0].value);
        try testing.expectEqual(@as(f32, 4096), elevator.stops.items[1].value);
        try testing.expectEqual(@as(f32, 0), elevator.value);
        const start = try a.dupe(level_asset.Vec2, join_level.level.sectors[door].vertices);
        defer a.free(start);
        const stood = .{ host_level.player.position, host_level.player.sector };
        const facing = for ([_]struct { z: f32, yaw: i16 }{ .{ .z = 250.5, .yaw = 8192 }, .{ .z = 240.5, .yaw = 0 } }) |side| {
            if (insideSector(host_level, room, 73.25, side.z)) break side;
        } else return error.NoRoomByTheDoor;
        host_level.player.position = .{ .x = 73.25, .y = try host_level.scene.floorHeight(&host_level.level, room, .{ .x = 73.25, .z = facing.z }), .z = facing.z };
        host_level.player.velocity = .{ .x = 0, .y = 0, .z = 0 };
        host_level.player.sector = room;
        host_level.player.yaw = facing.yaw;
        host_level.player.head_yaw = 0;
        host_level.player.pitch = 0;
        var nudging: player_input.Packet = .{};
        nudging.entries[@intFromEnum(player_input.Slot.nudge)].flags = player_input.pressed;
        try pair.frame(&nudging, &packet);
        host_level.player.position = stood[0];
        host_level.player.sector = stood[1];
        for (0..400) |_| {
            try pair.frame(&packet, &packet);
            if (elevator.value == elevator.stops.items[1].value) break;
        } else return error.DoorNeverOpened;
        for (0..30) |_| try pair.frame(&packet, &packet);
        var turned: usize = 0;
        for ([_]usize{ door, room }) |sector| {
            const host_sector = host_level.level.sectors[sector];
            const join_sector = join_level.level.sectors[sector];
            for (host_sector.vertices, join_sector.vertices) |host_vertex, join_vertex| {
                try testing.expectEqual(@as(u32, @bitCast(host_vertex.x)), @as(u32, @bitCast(join_vertex.x)));
                try testing.expectEqual(@as(u32, @bitCast(host_vertex.z)), @as(u32, @bitCast(join_vertex.z)));
            }
            for (host_level.scene.sectors[sector].walls, join_level.scene.sectors[sector].walls) |host_wall, join_wall| {
                if (host_wall.runtime_flags & 2 == 0) continue;
                try testing.expectEqual(host_wall.length, join_wall.length);
                try testing.expectEqual(host_wall.direction, join_wall.direction);
                try testing.expectEqual(host_wall.angle, join_wall.angle);
                turned += 1;
            }
        }
        for (host_level.scene.sectors[door].walls) |wall| try testing.expect(wall.runtime_flags & 2 != 0);
        try testing.expect(turned >= 8);
        var moved = false;
        for (start, join_level.level.sectors[door].vertices) |before, now_at| {
            if (before.x != now_at.x or before.z != now_at.z) moved = true;
        }
        try testing.expect(moved);
    }
    try testing.expectEqual(@as(u32, 0), host.router.rejected);
    try testing.expectEqual(rejected_before, joiner.router.rejected);
}
