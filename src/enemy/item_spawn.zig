//! Spawning a pickup: the item definition, or failing that the sprite set
//! named after it.
//!
//! With neither available the spawn returns nothing rather than inventing an
//! object.

const std = @import("std");
const level_flags = @import("../assets/level.zig");

const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;
const Object = @import("../assets/level.zig").Object;
const Actor = @import("../render/objects.zig").Actor;
const Model = @import("../assets/model.zig").Model;
const Target = @import("../player/target.zig").Target;
const inventory = @import("../player/inventory.zig");
const model_state = @import("../render/model_state.zig");
const object_state = @import("../render/object_state.zig");
const lifecycle = @import("lifecycle.zig");
const session_module = @import("session.zig");

pub fn spawn(session: anytype, name: []const u8, place: lifecycle.Placement) !?usize {
    if (std.ascii.eqlIgnoreCase(name, "NULL")) return null;

    return spawnWith(session, name, place, null);
}

pub fn spawnNumbered(
    session: anytype,
    name: []const u8,
    place: lifecycle.Placement,
    number: u32,
) !?usize {
    return spawnWith(session, name, place, number);
}

pub fn resource(session: anytype, name: []const u8) ![]const u8 {
    for ([_]@import(
        "../assets/lab.zig",
    ).Archive{
        session.object_archive,
        session.weapon_archive,
        session.texture_archive,
        session.system_archive,
    }) |archive| {
        const bytes = archive.find(name, 0) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };

        return bytes;
    }

    return error.ResourceNotFound;
}

pub fn model(session: anytype, name: []const u8) !*Model {
    const a = session.arena.allocator();
    var key_buffer: lab.NameBuffer = undefined;
    const key = try lab.upperName(&key_buffer, name);
    if (session.models.get(key)) |value| return value;

    const value = try a.create(Model);

    value.* = try Model.parse(
        a,
        try resource(session, name),
        &.{ session.object_archive, session.texture_archive, session.system_archive },
    );

    try session.models.put(try a.dupe(u8, key), value);

    return value;
}

pub fn bareModel(session: anytype, loaded: *const Model, place: lifecycle.Placement) !usize {
    const object = descriptor(session, "", place, .{ .model = true });
    const state = try model_state.init(
        session.arena.allocator(),
        &.{},
        object,
        place.sector,
        null,
        loaded,
        session.difficulty,
        session.game_type,
    );

    var actor = state.actor;

    actor.object_id = session.allocateObjectId();

    return session_module.appendActor(session, actor, null);
}

fn spawnWith(session: anytype, name: []const u8, place: lifecycle.Placement, given: ?u32) !?usize {
    const a = session.arena.allocator();
    const basename = std.fs.path.stem(std.fs.path.basename(name));
    var path_buffer: lab.NameBuffer = undefined;
    const path = try lab.printName(&path_buffer, "{s}.ITM", .{basename});
    const bytes = resource(session, path) catch |err| switch (err) {
        error.ResourceNotFound => null,
        else => return err,
    };

    var definition = if (bytes) |data| try Item.parse(a, data) else null;
    defer if (definition) |*value| value.deinit();
    const item = if (definition) |*value| value else null;
    const object = descriptor(session, basename, place, .{});

    if (given != null) {
        const value = item orelse return error.NetworkActorWithoutItemNotPorted;
        if (value.function.len == 0 or std.ascii.eqlIgnoreCase(
            value.function,
            "Gen_New",
        ) or std.ascii.eqlIgnoreCase(value.function, "Node_New") or
            std.ascii.eqlIgnoreCase(
                value.function,
                "Sanchez_New",
            ) or std.ascii.eqlIgnoreCase(value.function, "TwoFeathers_New"))
            return error.NetworkActorConstructorNotPorted;
    }

    if (item) |value| {
        if (std.ascii.eqlIgnoreCase(value.function, "Gen_New")) {
            try registerConstructor(session, value);
            _ = session.allocateActorId();
            const number = try temporaryNumber(session);
            try session.generators.append(
                a,
                value,
                object,
                place.sector,
                session.animation_time,
                &session.contact_state.random,
            );

            if (number) |actor| {
                const records = session.generators.records.items;
                records[records.len - 1].number = try session.database.give(
                    session.router.own_client,
                    .{ .generator = records.len - 1 },
                );

                session.database.free(actor, session.animation_time);
            }

            return null;
        }

        if (std.ascii.eqlIgnoreCase(value.function, "Node_New")) {
            _ = session.allocateActorId();

            if (try temporaryNumber(
                session,
            )) |actor| session.database.free(actor, session.animation_time);

            const old = session.enemy_nodes;
            const nodes = try a.alloc(@import("controller.zig").Node, old.len + 1);

            @memcpy(nodes[0..old.len], old);
            const type_name = (try value.stringValue("TYPE")) orelse "";

            nodes[old.len] = .{
                .kind = if (std.ascii.eqlIgnoreCase(
                    type_name,
                    "HIDE",
                )) 2 else if (std.ascii.eqlIgnoreCase(type_name, "NAV")) 3 else 0,
                .position = place.position,
                .sector = place.sector,
            };

            session.enemy_nodes = nodes;
            return null;
        }

        if (std.ascii.eqlIgnoreCase(
            value.function,
            "Sanchez_New",
        ) or std.ascii.eqlIgnoreCase(value.function, "TwoFeathers_New")) {
            const old = session.sanchez_sites orelse &.{};
            const sites = try a.alloc(@import("sanchez.zig").Site, old.len + 1);

            @memcpy(sites[0..old.len], old);

            sites[old.len] = .{
                .source = session.actor_slots.len,
                .position = place.position,
                .sector = place.sector,
            };

            session.sanchez_sites = sites;

            for (session.targets) |entry| if (entry) |existing| if (existing.sanchez) {
                _ = session.allocateActorId();

                if (try temporaryNumber(
                    session,
                )) |actor| session.database.free(actor, session.animation_time);

                return null;
            };
        }
    }

    var actor: Actor = undefined;
    var pickup: ?inventory.Pickup = null;
    var target: ?Target = null;

    if (item != null and item.?.function.len != 0 and std.ascii.endsWithIgnoreCase(
        item.?.animation,
        ".3DO",
    )) {
        const loaded = try model(session, item.?.animation);
        const constructed = try model_state.init(
            a,
            &.{ session.object_archive, session.weapon_archive, session.system_archive },
            object,
            place.sector,
            item,
            loaded,
            session.difficulty,
            session.game_type,
        );

        actor = constructed.actor;
        actor.logic_name = try a.dupe(u8, actor.logic_name);
        pickup = constructed.pickup;
    } else {
        var buffer: [128]u8 = undefined;
        const animation = try object_state.animationName(
            &buffer,
            basename,
            item,
        ) orelse return error.PassiveFactoryRequiresRegistration;

        const costume = session_module.costume(session, animation) catch |err| switch (err) {
            error.ResourceNotFound => if (item == null) return null else return err,
            else => return err,
        };

        actor = (try object_state.State.init(object, place.sector, item, costume)).actor(costume);

        if (item) |value| {
            actor.logic_name = try a.dupe(u8, object_state.nativeName(value.function));

            switch (try object_state.classify(value)) {
                .ground, .instant => pickup = try inventory.Pickup.parse(
                    a,
                    &.{ session.object_archive, session.weapon_archive, session.system_archive },
                    value,
                    session.difficulty,
                    session.game_type,
                ),
                .enemy, .chicken, .civilian, .slim, .sanchez => target = try Target.load(
                    a,
                    &.{ session.object_archive, session.weapon_archive, session.system_archive },
                    value,
                    session.difficulty,
                ),
                else => {},
            }
        }

        if (actor.playback) |*playback| playback.last_time = session.animation_time;
    }

    if (item) |value| try registerConstructor(session, value);

    if (item == null) actor.object_id = session.allocateObjectId();

    if (item != null and session.game_type.isNetwork()) actor.network_item = try a.dupe(u8, name);

    const source = try session_module.appendActor(session, actor, pickup);

    if (@hasField(
        @TypeOf(session.*),
        "actor_numbers",
    )) session.actor_numbers[source] = if (given) |number| blk: {
        session.database.set(number, .{ .actor = source }, session.animation_time);
        break :blk number;
    } else try @import("../render/object_numbers.zig").giveActor(session, source);

    if (std.ascii.eqlIgnoreCase(
        actor.logic_name,
        "shot_ProjectileDispatch",
    )) try @import("../projectile/session.zig").initializeMap(session, source, item.?);

    if (target) |*value| {
        value.playback.last_time = session.animation_time;
        value.selection_serial = &session.enemy_selection_serial;
        session.targets[source] = value.*;
        if (value.native != .civilian and value.native != .marshal) session.enemy_shared.total_enemies += 1;
    }

    return source;
}

fn temporaryNumber(session: anytype) !?u32 {
    if (!@hasField(@TypeOf(session.*), "actor_numbers")) return null;

    return try @import(
        "../render/object_numbers.zig",
    ).giveActor(session, @import("../render/object_numbers.zig").temporary_actor);
}

fn registerConstructor(session: anytype, definition: *const Item) !void {
    try @import(
        "../audio/registration.zig",
    ).actor(
        &session.sound_ledger,
        session.arena.allocator(),
        &.{ session.object_archive, session.weapon_archive, session.system_archive },
        definition,
        session.difficulty,
        session.animation_time,
    );

    if (session.active_audio) |sound| try session.sound_ledger.bind(sound);
}

fn descriptor(session: anytype, name: []const u8, place: lifecycle.Placement, flags: level_flags.ObjectFlags) Object {
    return .{
        .name = name,
        .id = 0,
        .sector_id = session.level.sectors[place.sector].id,
        .position = place.position,
        .rotation = .{ .x = 0, .y = 0, .z = 0 },
        .angles = .{ 0, 0, 0 },
        .flags = flags,
        .availability = .{},
    };
}
