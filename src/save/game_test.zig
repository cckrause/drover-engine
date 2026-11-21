//! Saving and restoring a campaign across every level and both discs.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const game = @import("game.zig");
const stream = @import("stream.zig");
const header = @import("header.zig");
const campaign = @import("../campaign.zig");
const lab = @import("../assets/lab.zig");
const Session = @import("../render/session.zig").Session;
const Runtime = @import("../audio/runtime.zig").Runtime;

fn liveSaveRoundTrip(a: std.mem.Allocator, io: std.Io, path: []const u8, archive: lab.Archive, level_name: []const u8) !void {
    var mounts = @import("../platform/mission.zig").Mounts.init(a, path, archive);
    defer mounts.deinit();
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    try @import("../platform/mission.zig").select(&startup, level_name);
    const event = try startup.levelForDiagnostics();
    try mounts.selectDisc(io, event.disc);
    const old = try Session.openWithState(a, io, mounts.path(), mounts.system(), &startup, 90000, .{});
    defer old.deinit(a);
    const audio = try Runtime.open(a, io, mounts.path(), mounts.system());
    defer audio.deinit();
    try old.bindAudio(audio);
    try audio.beginLevel(io, &old.level, old.geometry_archive, 90000);
    try old.advanceWithAudio(a, &.{}, 16, audio);
    try old.prepareMenu(a, audio);
    old.inventory.health = 4.25;
    old.player.energy = 43;
    old.player.jump_peak = 19.5;
    old.player.auto_pitch_elapsed = 0.125;
    old.player.normal_yaw = -123;
    const slot = old.inventory.selected_weapon;
    old.inventory.slots[slot].?.loaded = 1;
    old.inventory.statistics.hits = 7;
    old.inventory.statistics.kills = 2;
    old.inventory.statistics.gold = 3;
    old.weapon_state.shot_count = 11;
    const sleeping_enemy = for (old.targets, 0..) |target, source| {
        if (target != null and !old.removed_actors[source]) break source;
    } else return error.MissingOriginalEnemyPlacement;
    const sleeping_id = old.actor_slots[sleeping_enemy].?.logic_id;
    const sleep_until = old.animation_time +% 5000;
    old.targets[sleeping_enemy].?.next_tick = sleep_until;
    old.actor_next_update[sleeping_enemy] = @bitCast(sleep_until);
    old.inventory.sheriff_due = 92000;
    old.inventory.sheriff_task_linked = true;
    old.inventory.sheriff_task_parameter = 3;
    old.inventory.sheriff_remaining = 5;
    startup.accumulated_stats[3] = 37;
    const dirty = old.player.sector;
    old.level.sectors[dirty].ambient = 37;
    old.scene.sectors[dirty].runtime_flags |= 1;
    old.inf.elevators[0].speed += 0.25;
    const speed = old.inf.elevators[0].speed;
    const changed_elevator = old.inf.elevators[0];
    var removed_id: ?u32 = null;
    for (old.pickup_slots, 0..) |pickup, source| {
        if (pickup == null or old.actor_slots[source] == null) continue;
        removed_id = old.actor_slots[source].?.logic_id;
        try @import("../enemy/session.zig").removeActor(old, source);
        break;
    }
    try std.testing.expect(removed_id != null);
    const encoded = try game.write(a, old, &startup, audio, mounts.active, old.animation_time, "MODULE TEST".* ++ [_]u8{0} ** 4, .{ .width = 2, .height = 2, .pixels = &.{ 1, 2, 3, 4 } });
    defer a.free(encoded);
    try std.testing.expect(!old.inventory.sheriff_task_linked);
    try std.testing.expectEqual(@as(?u32, 92000), old.inventory.sheriff_due);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reader: stream.Reader = .{ .bytes = encoded };
    const saved = try header.Header.read(arena.allocator(), &reader);
    const difficulty = try game.validate(saved);
    var resumed = try campaign.Startup.restore(a, archive, difficulty, saved.recipe.?.filename, saved.recipe.?.ordinal);
    defer resumed.deinit(a);
    try old.closeSounds();
    const fresh = try Session.openForRestore(a, io, mounts.path(), mounts.system(), &resumed, saved.clock, old.persistentState());
    defer fresh.deinit(a);
    try fresh.bindAudio(audio);
    try game.readBody(fresh, &resumed, audio, &reader, saved);
    try expectRestoredNumbers(fresh);
    try std.testing.expectEqualStrings(level_name, fresh.level_name);
    try std.testing.expectEqual(@as(f32, 4.25), fresh.inventory.health);
    try std.testing.expectEqual(@as(f32, 43), fresh.player.energy);
    try std.testing.expectEqual(@as(f32, 19.5), fresh.player.jump_peak);
    try std.testing.expectEqual(@as(f32, 0.125), fresh.player.auto_pitch_elapsed);
    try std.testing.expectEqual(@as(i16, -123), fresh.player.normal_yaw);
    try std.testing.expectEqualDeep(old.player.position, fresh.player.position);
    try std.testing.expectEqual(slot, fresh.inventory.selected_weapon);
    try std.testing.expectEqual(@as(i32, 1), fresh.inventory.slots[slot].?.loaded);
    try std.testing.expectEqual(@as(u32, 7), fresh.inventory.statistics.hits);
    try std.testing.expectEqual(@as(u32, 2), fresh.inventory.statistics.kills);
    try std.testing.expectEqual(@as(u32, 11), fresh.weapon_state.shot_count);
    const restored_enemy = for (fresh.actor_slots, 0..) |actor, source| {
        if (actor != null and actor.?.logic_id == sleeping_id) break source;
    } else return error.MissingRestoredEnemy;
    try std.testing.expectEqual(sleep_until, fresh.targets[restored_enemy].?.next_tick);
    try std.testing.expectEqual(sleep_until, @as(u32, @bitCast(fresh.actor_next_update[restored_enemy])));
    try std.testing.expectEqual(@as(u32, 37), resumed.accumulated_stats[3]);
    try std.testing.expectEqual(@as(i32, 37), fresh.level.sectors[dirty].ambient);
    const restored_elevator = for (fresh.inf.elevators) |elevator| {
        if (elevator.sector == changed_elevator.sector and elevator.kind == changed_elevator.kind) break elevator;
    } else return error.MissingRestoredElevator;
    try std.testing.expectEqual(speed, restored_elevator.speed);
    try std.testing.expect(fresh.inventory.sheriff_task_linked);
    try std.testing.expectEqual(@as(?u32, 92000), fresh.inventory.sheriff_due);
    try std.testing.expectEqual(@as(u32, 3), fresh.inventory.sheriff_task_parameter);
    try std.testing.expectEqual(@as(i32, 5), fresh.inventory.sheriff_remaining);
    for (fresh.actor_slots) |actor| if (actor) |value| try std.testing.expect(value.logic_id != removed_id.?);
    try audio.beginLevel(io, &fresh.level, fresh.geometry_archive, fresh.animation_time);
    try audio.beginEmptyAmbient();
    if (fresh.saved_music) |music| try audio.restoreMusic(io, music.name, music.cue, fresh.animation_time);
    try fresh.advanceWithAudio(a, &.{}, 16, audio);
    try audio.advanceAmbient(fresh.animation_time, fresh.level.sectors[fresh.player.sector].layer);
    try std.testing.expectEqual(@as(usize, 0), audio.ambient.?.sources.len);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    _ = try fresh.render(a, pixels, fresh.animation_time);
    try std.testing.expectEqual(saved.clock + 16, fresh.animation_time);
    try fresh.closeSounds();
}

fn expectRestoredNumbers(session: *Session) !void {
    const Object = @import("../network/database.zig").Object;
    for (session.actor_slots, session.removed_actors, session.actor_numbers, 0..) |slot, removed, number, source| {
        if (slot == null or removed) continue;
        try std.testing.expect(number != 0);
        try std.testing.expect(std.meta.eql(session.database.find(number).?, Object{ .actor = source }));
    }
    try std.testing.expect(std.meta.eql(session.database.find(session.player_number).?, Object{ .actor = @import("../player/shooting.zig").local_player }));
    for (session.generators.records.items, 0..) |record, index|
        try std.testing.expect(std.meta.eql(session.database.find(record.number).?, Object{ .generator = index }));
    for (session.scene.sectors, 0..) |sector, index| {
        try std.testing.expectEqual(sector.runtime_flags & 0x10 != 0, sector.number != 0);
        if (sector.number != 0) try std.testing.expect(std.meta.eql(session.database.find(sector.number).?, Object{ .sector = index }));
        for (sector.walls, 0..) |wall, wall_index| {
            if (wall.runtime_flags & 8 != 0 and sector.number == 0) try std.testing.expect(wall.number != 0);
            if (wall.number != 0) try std.testing.expect(std.meta.eql(session.database.find(wall.number).?, Object{ .wall = .{ .sector = index, .wall = wall_index } }));
        }
    }
}

test "campaign opens all nine levels across both discs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    var mounts = @import("../platform/mission.zig").Mounts.init(a, path, archive);
    defer mounts.deinit();
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);
    var carry: ?Session.CampaignState = null;
    defer if (carry) |*state| state.deinit();
    var count: usize = 0;
    var failures: usize = 0;
    var disc_two = false;
    story: while (startup.currentEvent()) |event| switch (event.kind) {
        .movie => try startup.finishMovie(false),
        .level => {
            errdefer std.debug.print("campaign level {s}, disc{d}, completed{d}\n", .{ event.name, event.disc, count });
            try mounts.selectDisc(io, event.disc);
            disc_two = disc_two or mounts.active == 2;
            const session = (if (carry) |*state|
                Session.openWithCampaignState(a, io, mounts.path(), mounts.system(), &startup, @intCast(count * 90000), .{}, state)
            else
                Session.openWithState(a, io, mounts.path(), mounts.system(), &startup, 0, .{})) catch |err| {
                std.debug.print("campaign open {s}, disc{d}: {s}\n", .{ event.name, event.disc, @errorName(err) });
                if (err == error.ResourceNotFound) if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                failures += 1;
                count += 1;
                try startup.finishLevel();
                continue :story;
            };
            defer session.deinit(a);
            const visible = try a.alloc(bool, session.level.sectors.len);
            defer a.free(visible);
            @memset(visible, true);
            _ = session.loadActors(a, visible, true) catch |err| {
                std.debug.print("campaign actors {s}, disc{d}: {s}\n", .{ event.name, event.disc, @errorName(err) });
                failures += 1;
                count += 1;
                try startup.finishLevel();
                continue :story;
            };
            try std.testing.expectEqualStrings(event.name, session.level_name);
            if (std.ascii.eqlIgnoreCase(event.name, "canyon")) {
                const discarded = for (session.level.sectors, 0..) |sector, index| {
                    if (std.ascii.eqlIgnoreCase(sector.name, "WFALL21")) break index;
                } else return error.MissingOriginalCanyonSector;
                for (session.inf.elevators) |elevator| try std.testing.expect(elevator.sector != discarded);
            }
            try std.testing.expectEqual(@as(f32, 10), session.inventory.health);
            if (carry) |*state| state.deinit();
            carry = null;
            carry = try session.campaignState(a);
            count += 1;
            try startup.finishLevel();
        },
        .credits => break,
        else => return error.UnsupportedCampaignStoryEvent,
    };
    try std.testing.expectEqual(@as(usize, 9), count);
    try std.testing.expect(disc_two);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "live campaign save restores all nine levels and resumes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    var failures: usize = 0;
    for ([_][]const u8{ "hideout", "town", "train", "canyon", "mill", "simms", "miner", "cliff", "ranch" }) |level_name| {
        liveSaveRoundTrip(a, io, path, archive, level_name) catch |err| {
            std.debug.print("campaign save/resume {s}: {s}\n", .{ level_name, @errorName(err) });
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
