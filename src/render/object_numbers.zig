//! Object numbers for a level's walls, sectors, actors and generators: the
//! identity other machines use to talk about a thing.
//!
//! Numbers are handed out on the campaign's database, so they keep counting
//! across levels and are never reused. An actor its factory frees
//! immediately still consumed a number.

const std = @import("std");

const item = @import("../assets/item.zig");
const database = @import("../network/database.zig");

pub const temporary_actor = std.math.maxInt(usize) - 1;

pub const Kind = enum {
    actor,
    generator,
    node,
    sanchez,

    pub fn of(definition: ?*const item.Item) Kind {
        const value = definition orelse return .actor;
        if (std.mem.eql(u8, value.function, "Gen_New")) return .generator;
        if (std.mem.eql(u8, value.function, "Node_New")) return .node;
        if (std.mem.eql(
            u8,
            value.function,
            "Sanchez_New",
        ) or std.mem.eql(u8, value.function, "TwoFeathers_New")) return .sanchez;

        return .actor;
    }
};

pub fn linkWall(session: anytype, sector: usize, wall: usize) !void {
    const state = &session.scene.sectors[sector].walls[wall];
    if (state.number != 0) return;

    state.number = try session.database.give(
        session.router.own_client,
        .{ .wall = .{ .sector = sector, .wall = wall } },
    );

    state.runtime_flags.number_changed = true;
}

pub fn linkSector(session: anytype, sector: usize) !void {
    const state = &session.scene.sectors[sector];
    if (state.number != 0) return;
    state.number = try session.database.give(session.router.own_client, .{ .sector = sector });
    state.runtime_flags.number_changed = true;
}

pub fn unlink(session: anytype, sector: usize, wall: ?usize, now: u32) void {
    if (linked(session, sector, wall)) return;

    if (wall) |index| {
        const state = &session.scene.sectors[sector].walls[index];
        if (state.number == 0) return;

        session.database.free(state.number, now);

        state.number = 0;
        state.runtime_flags.number_changed = true;
    } else {
        const state = &session.scene.sectors[sector];
        if (state.number == 0) return;

        session.database.free(state.number, now);

        state.number = 0;
        state.runtime_flags.number_changed = true;
    }
}

pub fn giveActor(session: anytype, source: usize) !u32 {
    return session.database.give(session.router.own_client, .{ .actor = source });
}

pub fn freeActor(session: anytype, source: usize) !void {
    if (source >= session.actor_numbers.len) return;

    const number = session.actor_numbers[source];
    if (number == 0) return;

    session.database.free(number, session.animation_time);
    session.actor_numbers[source] = 0;

    if (session.game_type.isNetwork()) try @import(
        "network_actors.zig",
    ).postDelete(session.router, number);
}

pub fn level(session: anytype, geometry_classes: usize, kinds: []const ?Kind, now: u32) !void {
    try geometry(session, geometry_classes);
    try objects(session, kinds, now);

    for (session.inf.classes[geometry_classes..]) |class| switch (class) {
        .elevator => |index| try linkSector(session, session.inf.elevators[index].sector),
        .trigger => |index| {
            const target = session.inf.triggers[index].target;
            const sector = target.sector orelse continue;

            if (target.wall) |wall| try linkWall(
                session,
                sector,
                wall,
            ) else try linkSector(session, sector);
        },
    };

    session.player_number = try giveActor(session, @import("../player/shooting.zig").local_player);
}

pub fn geometry(session: anytype, geometry_classes: usize) !void {
    var instance: usize = 0;
    const instances = session.texture_animations.instances;

    for (0..session.level.sectors.len) |sector| {
        while (instance < instances.len and instances[instance].target.sector == sector) : (instance += 1) {
            const target = instances[instance].target;

            if (target.wall) |wall| try linkWall(
                session,
                sector,
                wall,
            ) else try linkSector(session, sector);
        }

        for (session.inf.classes[0..geometry_classes]) |class| switch (class) {
            .elevator => |index| if (session.inf.elevators[index].automatic_door and session.inf.elevators[index].sector == sector) try linkSector(session, sector),
            .trigger => {},
        };
    }

    if (instance != instances.len) return error.AtxInstancesOutOfOrder;

    for (session.inf.classes[0..geometry_classes]) |class| switch (class) {
        .trigger => |index| {
            const target = session.inf.triggers[index].target;
            try linkWall(session, target.sector.?, target.wall.?);
        },
        .elevator => {},
    };
}

pub fn restoreSector(session: anytype, sector: usize) !void {
    const state = &session.scene.sectors[sector];
    if (!state.runtime_flags.number_changed or state.number != 0) return;
    state.number = try session.database.give(session.router.own_client, .{ .sector = sector });
    state.runtime_flags.number_changed = true;
}

pub fn restoreWall(session: anytype, sector: usize, wall: usize) !void {
    const state = &session.scene.sectors[sector].walls[wall];
    if (!state.runtime_flags.number_changed or session.scene.sectors[sector].number != 0) return;

    state.number = try session.database.give(
        session.router.own_client,
        .{ .wall = .{ .sector = sector, .wall = wall } },
    );

    state.runtime_flags.number_changed = true;
}

pub fn restoreGenerators(session: anytype) !void {
    for (session.generators.records.items, 0..) |*record, index|
        record.number = try session.database.give(
            session.router.own_client,
            .{ .generator = index },
        );
}

pub fn restoreActor(session: anytype, source: usize) !void {
    const number = try giveActor(session, source);
    if (source == @import(
        "../player/shooting.zig",
    ).local_player) session.player_number = number else session.actor_numbers[source] = number;
}

pub fn restoreLinks(session: anytype) !void {
    for (session.inf.restored_links) |link| {
        const sector = link.target.sector orelse continue;

        if (link.target.wall) |wall| try linkWall(
            session,
            sector,
            wall,
        ) else try linkSector(session, sector);
    }
}

pub fn close(session: anytype, now: u32) void {
    for (session.scene.sectors) |*sector| {
        for (sector.walls) |*wall| if (wall.number != 0) {
            session.database.free(wall.number, now);
            wall.number = 0;
        };

        if (sector.number != 0) {
            session.database.free(sector.number, now);
            sector.number = 0;
        }
    }

    for (session.actor_numbers) |*number| if (number.* != 0) {
        session.database.free(number.*, now);
        number.* = 0;
    };

    if (session.player_number != 0) session.database.free(session.player_number, now);

    session.player_number = 0;

    for (session.generators.records.items) |*record| if (record.number != 0) {
        session.database.set(record.number, .leaked, now);
        record.number = 0;
    };
}

fn linked(session: anytype, sector: usize, wall: ?usize) bool {
    for (session.texture_animations.instances) |instance|
        if (instance.target.sector == sector and instance.target.wall == wall) return true;

    for (session.inf.elevators) |elevator|
        if (!elevator.deleted and wall == null and elevator.sector == sector) return true;

    for (session.inf.triggers) |trigger|
        if (!trigger.deleted and trigger.target.sector == sector and trigger.target.wall == wall) return true;

    return false;
}

fn objects(session: anytype, kinds: []const ?Kind, now: u32) !void {
    var generator: usize = 0;

    for (kinds, 0..) |entry, source| {
        const kind = entry orelse continue;
        const number = try giveActor(session, source);

        switch (kind) {
            .actor => session.actor_numbers[source] = number,
            .generator => {
                if (generator >= session.generators.records.items.len) return error.GeneratorOutOfOrder;

                session.generators.records.items[generator].number = try session.database.give(
                    session.router.own_client,
                    .{ .generator = generator },
                );

                generator += 1;

                session.database.free(number, now);
            },
            .node => session.database.free(number, now),
            .sanchez => {
                const sites = session.sanchez_sites orelse return error.MissingSanchezPlacement;
                if (sites.len != 0 and sites[0].source == source) session.actor_numbers[source] = number else session.database.free(number, now);
            },
        }
    }

    if (generator != session.generators.records.items.len) return error.GeneratorOutOfOrder;
}
