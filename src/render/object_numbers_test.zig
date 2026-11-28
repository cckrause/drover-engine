//! The order object numbers are handed out in while a level loads.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const Session = @import("session.zig").Session;
const shooting = @import("../player/shooting.zig");
const bits = @import("../util/bits.zig");

fn actors_source(session: *Session, number: u32) usize {
    return std.mem.indexOfScalar(u32, session.actor_numbers, number).?;
}

fn check(
    session: *Session,
    sector: usize,
    wall: ?usize,
    number: u32,
    number_changed: bool,
    geometry_max: *u32,
    inf_min: *u32,
    geometry_count: *usize,
) !void {
    var geometry = false;

    for (session.texture_animations.instances) |instance| {
        if (instance.target.sector == sector and instance.target.wall == wall) geometry = true;
    }

    var inf = false;

    for (session.inf.classes) |class| switch (class) {
        .elevator => |index| {
            const elevator = session.inf.elevators[index];
            if (wall == null and elevator.sector == sector) {
                if (elevator.automatic_door) geometry = true else inf = true;
            }
        },
        .trigger => |index| {
            const trigger = session.inf.triggers[index];
            if (trigger.target.sector == sector and trigger.target.wall == wall) {
                if (trigger.flags.kind == .glass and bits.word(trigger.event_mask) == 0x8100) geometry = true else inf = true;
            }
        },
    };

    try std.testing.expectEqual(geometry or inf, number != 0);
    try std.testing.expectEqual(number != 0, number_changed);
    if (number == 0) return;

    try std.testing.expect(
        std.meta.eql(
            session.database.find(number).?,
            if (wall) |index| @as(
                @import("../network/database.zig").Object,
                .{ .wall = .{ .sector = sector, .wall = index } },
            ) else .{ .sector = sector },
        ),
    );

    if (geometry) {
        geometry_max.* = @max(geometry_max.*, number);
        geometry_count.* += 1;
    } else inf_min.* = @min(inf_min.*, number);
}

test "Hideout's object numbers follow the reference load order" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    const session = try Session.open(
        a,
        @import("test_workspace.zig").get(),
        std.testing.io,
        path,
        system,
        &startup,
    );

    var closed = false;
    defer if (!closed) session.deinit(a);
    const db = &startup.database;
    const last = db.last[1];

    try std.testing.expect(db.repeats != null);
    try std.testing.expectEqual(@as(usize, 0), db.repeats.?.items.len);

    var geometry_max: u32 = 0;
    var inf_min: u32 = std.math.maxInt(u32);
    var geometry_count: usize = 0;

    for (session.scene.sectors, 0..) |sector, index| {
        try check(
            session,
            index,
            null,
            sector.number,
            sector.runtime_flags.number_changed,
            &geometry_max,
            &inf_min,
            &geometry_count,
        );

        for (sector.walls, 0..) |wall, wall_index|
            try check(
                session,
                index,
                wall_index,
                wall.number,
                wall.runtime_flags.number_changed,
                &geometry_max,
                &inf_min,
                &geometry_count,
            );
    }

    try std.testing.expect(geometry_count != 0);

    var previous: u32 = geometry_max;
    var actors: usize = 0;

    for (session.actor_numbers[0..session.objects.entries.len], session.map_actor_ids) |number, id| {
        if (number == 0) continue;

        try std.testing.expect(id != 0);
        try std.testing.expect(number > previous);
        try std.testing.expect(number < inf_min);
        try std.testing.expect(
            std.meta.eql(db.find(number).?, .{ .actor = actors_source(session, number) }),
        );

        previous = number;
        actors += 1;
    }

    try std.testing.expect(actors != 0);

    for (session.generators.records.items, 0..) |record, index| {
        try std.testing.expect(record.number > geometry_max and record.number < inf_min);
        try std.testing.expect(std.meta.eql(db.find(record.number).?, .{ .generator = index }));
        try std.testing.expectEqual(
            @as(?@import("../network/database.zig").Object, null),
            db.find(record.number - 1),
        );
    }

    try std.testing.expectEqual(@as(u32, 0x800) | last, session.player_number);
    try std.testing.expect(
        std.meta.eql(db.find(session.player_number).?, .{ .actor = shooting.local_player }),
    );

    for (db.tables[1].?[1 .. last + 1]) |entry| try std.testing.expect(
        entry.object != null or entry.freed == session.animation_time,
    );

    const sector_index = for (session.scene.sectors, 0..) |sector, index| {
        if (sector.number != 0) break index;
    } else return error.MissingNumberedSector;

    const to: @import(
        "../network/database.zig",
    ).Party = .{
        .object = .{ .sector = sector_index },
        .number = session.scene.sectors[sector_index].number,
    };

    const from: @import(
        "../network/database.zig",
    ).Party = .{ .object = .{ .actor = shooting.local_player }, .number = session.player_number };

    try db.post(session.router, to, from, .{ 0x7d6, 0x10, 1, 0 }, 100);
    try db.post(session.router, to, from, .{ 0x7d6, 0x10, 1, 0 }, 101);

    for ([_]u32{ 0, 1 }) |repeating| {
        const delivery = (try db.next(session.router, true, 101)).?.link;
        try std.testing.expectEqual(sector_index, delivery.object.sector);
        try std.testing.expectEqual(@as(?usize, shooting.local_player), delivery.sender);
        try std.testing.expectEqual(repeating, db.repeating);
    }

    try std.testing.expect(try db.next(session.router, true, 101) == null);
    try std.testing.expectEqual(@as(u32, 0), db.repeating);
    try std.testing.expectEqual(@as(usize, 1), db.repeats.?.items.len);

    try db.post(session.router, to, from, .{ 0x7d7, 0, 0, 0 }, 102);

    var generators: [64]u32 = undefined;
    const kept = session.generators.records.items.len;

    for (session.generators.records.items, 0..) |record, index| generators[index] = record.number;

    session.deinit(a);
    closed = true;

    try std.testing.expect(db.repeats == null);
    try std.testing.expectEqual(@as(usize, 1), startup.router.queues[0].count);
    try std.testing.expect(try db.next(&startup.router, false, 103) == null);

    for (db.tables[1].?[1 .. last + 1], 1..) |entry, index| {
        const number: u32 = 0x800 | @as(u32, @intCast(index));
        const generator = std.mem.indexOfScalar(u32, generators[0..kept], number) != null;
        try std.testing.expectEqual(generator, entry.object != null);
        if (generator) try std.testing.expect(entry.object.? == .leaked);
    }
}
