//! Actors drawn as geometry rather than sprites: creating them and keeping
//! their transform.
//!
//! All three angles are copied after the factory returns, which replaces the
//! temporary floor alignment it did. Item-driven actors start with negative
//! dimensions, and the radius fallback compares against that.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const level = @import("../assets/level.zig");
const Item = @import("../assets/item.zig").Item;
const Model = @import("../assets/model.zig").Model;
const inventory = @import("../player/inventory.zig");
const cmm = @import("../script/cmm.zig");
const objects = @import("objects.zig");

pub const Constructed = struct { actor: objects.Actor, pickup: ?inventory.Pickup = null };

pub fn init(
    allocator: std.mem.Allocator,
    archives: []const lab.Archive,
    object: level.Object,
    sector: usize,
    definition: ?*const Item,
    model: *const Model,
    difficulty: u32,
    game_type: u32,
) !Constructed {
    var result: Constructed = .{ .actor = .{
        .model = model,
        .sector = sector,
        .position = object.position,
        .yaw = object.angles[1],
        .pitch = object.angles[0],
        .roll = object.angles[2],
        .flags = 0x8000000f,
        .secondary_flags = 0,
        .scale_x = 1,
        .scale_y = 1,
        .height = 6,
        .collision_radius = 3,
        .choreography = 0,
        .frame = 0,
        .angle_offset = 0,
    } };

    if (definition) |item| {
        if (!std.ascii.endsWithIgnoreCase(
            item.animation,
            ".3DO",
        )) return error.UnsupportedObjectModel;

        result.actor.logic_name = item.function;
        result.actor.collision_radius = -1;

        switch (try cmm.resolve(item.function)) {
            .object => {
                result.actor.flags |= 0x40;
                result.actor.secondary_flags = 0x400;

                if (try item.stringValue("TYPE")) |kind|
                    result.actor.secondary_flags = if (std.ascii.eqlIgnoreCase(
                        kind,
                        "SHOOT",
                    )) 0x2000 else 0x1000;
            },
            .ground_object, .ground_sheriff_star, .ground_vanishing_cream => {
                result.actor.flags |= 0x440;
                result.actor.secondary_flags = 0x400;
                result.pickup = try inventory.Pickup.parse(
                    allocator,
                    archives,
                    item,
                    difficulty,
                    game_type,
                );
            },
            .instant_ground_object => {
                result.actor.flags |= 0x400;
                result.actor.secondary_flags = 0x400;
                result.pickup = try inventory.Pickup.parse(
                    allocator,
                    archives,
                    item,
                    difficulty,
                    game_type,
                );
            },
            .projectile_dispatch => {
                const projectile_name = (try item.stringValue(
                    "PROJECTILE",
                )) orelse return error.UnsupportedMovingModelProjectile;

                var path: [128]u8 = undefined;
                const projectile_path = try std.fmt.bufPrint(
                    &path,
                    "{s}.ITM",
                    .{std.fs.path.stem(projectile_name)},
                );

                var projectile = try Item.parse(allocator, try resource(archives, projectile_path));
                defer projectile.deinit();
                const dead_name = (try projectile.stringValue(
                    "DEAD_ITEM",
                )) orelse return error.UnsupportedMovingModelProjectile;

                var dead_item = try Item.parse(allocator, try resource(archives, dead_name));
                defer dead_item.deinit();

                result.actor.collision_radius = projectile.floatValue("COLLIDE_RADIUS") orelse 0;

                if (try projectile.stringValue("EXPLOSION")) |name| {
                    _ = try resource(archives, name);
                    result.actor.projectile_explodes = true;
                }

                result.actor.height = @floatCast(@as(f64, result.actor.collision_radius) * 2.0);
                result.actor.flags |= 0x40;
                result.actor.secondary_flags = 0x400;
                result.pickup = try inventory.Pickup.parse(
                    allocator,
                    archives,
                    &dead_item,
                    difficulty,
                    game_type,
                );

                result.pickup.?.function = .projectile_dispatch;
            },
            else => return error.UnsupportedObjectModelFactory,
        }

        if (item.floatValue("HEIGHT")) |height| result.actor.height = height;

        if (item.floatValue("RADIUS")) |radius| result.actor.collision_radius = radius;
    } else if (object.flags[0] & 8 == 0) return error.UnsupportedObjectModel;

    if (object.flags[0] & 0x10 != 0) result.actor.flags |= 0x400;

    return result;
}

pub fn tick(session: anytype, source: usize) !void {
    const actor = &session.actor_slots[source].?;
    if (actor.flags & 0x41 != 0x41 or actor.secondary_flags & 0x01000000 != 0 or @as(
        u32,
        @bitCast(session.actor_next_update[source]),
    ) > session.animation_time) return;

    const pickup = if (session.pickup_slots[source]) |*value| value else return error.UnsupportedMovingModelProjectile;

    if (!pickup.enabled) pickup.enabled = 10.0 < @abs(
        @as(f64, session.player.position.x) - actor.position.x,
    ) + @abs(@as(f64, session.player.position.z) - actor.position.z);

    actor.flags |= 0x800000c0;
    session.syncActor(source);
}

fn resource(archives: []const lab.Archive, name: []const u8) ![]const u8 {
    for (archives) |archive| {
        const data = archive.find(name, 0) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };

        return data;
    }

    return error.ResourceNotFound;
}

test "3DO constructors match GDYNAM GKNIFE and bare actor factories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var archives: [3]lab.Archive = undefined;

    for ([_][]const u8{ "OLOBJ", "OLWEAP", "OUTLAWS" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            a,
            .limited(64 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };

        archive.* = try lab.Archive.init(bytes);
    }

    const cases = .{
        .{
            "GDYNAM",
            @as(u32, 0),
            @as(u32, 0x8000004f),
            @as(u32, 0x400),
            @as(f32, 0.5),
            @as(f32, 1),
        },
        .{
            "GKNIFE",
            @as(u32, 0),
            @as(u32, 0x8000044f),
            @as(u32, 0x400),
            @as(f32, 0.5),
            @as(f32, -1),
        },
        .{ "BARE", @as(u32, 8), @as(u32, 0x8000000f), @as(u32, 0), @as(f32, 6), @as(f32, 3) },
        .{ "BARE", @as(u32, 24), @as(u32, 0x8000040f), @as(u32, 0), @as(f32, 6), @as(f32, 3) },
    };

    var model = try Model.parse(a, try archives[0].find("GDYNAM.3DO", 0), &archives);
    defer model.deinit();

    inline for (cases) |case| {
        const definition: ?Item = if (std.mem.eql(
            u8,
            case[0],
            "BARE",
        )) null else try Item.parse(a, try archives[0].find(case[0] ++ ".ITM", 0));

        defer if (definition) |value| {
            var owned = value;
            owned.deinit();
        };

        const object: level.Object = .{
            .name = case[0],
            .id = 77,
            .sector_id = 1,
            .position = .{ .x = 4, .y = 0, .z = -3 },
            .rotation = .{ .x = 0, .y = 0, .z = 0 },
            .angles = .{ 100, -2345, 300 },
            .flags = .{ case[1], 0xffffffff },
        };

        const constructed = try init(
            a,
            &archives,
            object,
            0,
            if (definition) |*value| value else null,
            &model,
            0x100000,
            1,
        );

        try std.testing.expectEqual(case[2], constructed.actor.flags);
        try std.testing.expectEqual(case[3], constructed.actor.secondary_flags);
        try std.testing.expectEqual(case[4], constructed.actor.height);
        try std.testing.expectEqual(case[5], constructed.actor.collision_radius);
        try std.testing.expectEqualSlices(
            i16,
            &object.angles,
            &.{ constructed.actor.pitch, constructed.actor.yaw, constructed.actor.roll },
        );

        try std.testing.expectEqual(definition != null, constructed.pickup != null);

        if (constructed.pickup) |pickup| {
            var player: inventory.Inventory = .{};
            var effects_buffer: inventory.EffectBuffer = undefined;
            var effects = inventory.Effects.init(&effects_buffer);

            try std.testing.expect(try player.take(&pickup, 0, &effects));
            const slot = player.find(
                if (std.mem.eql(u8, case[0], "GDYNAM")) "IDYNAM" else "IKNIFE",
            );

            try std.testing.expect(slot != 0);
            try std.testing.expectEqual(@as(i32, 1), player.slots[slot].?.count);
        }
    }
}
