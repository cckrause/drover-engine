//! The unique enemy that may only exist once.
//!
//! Every placement in the map is appended before the singleton test, so only
//! the first one gets logic; the later ones are flagged and destroyed on
//! creation.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const level = @import("../assets/level.zig");
const Item = @import("../assets/item.zig").Item;
const Actor = @import("../render/objects.zig").Actor;
const controller = @import("controller.zig");
const perception = @import("perception.zig");

pub const Site = struct { source: usize, sector: usize, position: level.Vec3 };

pub fn placements(
    a: std.mem.Allocator,
    geometry: *const level.Level,
    objects: *const level.Objects,
    archives: []const lab.Archive,
    difficulty_mask: u32,
) ![]Site {
    var result: std.ArrayList(Site) = .empty;
    errdefer result.deinit(a);

    for (objects.entries, 0..) |object, source| {
        if (object.flags[1] & difficulty_mask == 0 or object.flags[0] & 1 != 0) continue;

        const sector = geometry.sectorIndex(object.sector_id) orelse continue;
        const path = try std.fmt.allocPrint(a, "{s}.ITM", .{std.fs.path.stem(object.name)});
        defer a.free(path);
        var bytes: ?[]const u8 = null;

        for (archives) |archive| {
            bytes = archive.find(path, 0) catch |err| switch (err) {
                error.ResourceNotFound => continue,
                else => return err,
            };

            break;
        }

        var item = try Item.parse(a, bytes orelse continue);
        defer item.deinit();

        if (!std.mem.eql(
            u8,
            item.function,
            "Sanchez_New",
        ) and !std.mem.eql(u8, item.function, "TwoFeathers_New")) continue;

        try result.append(a, .{ .source = source, .sector = sector, .position = object.position });
    }

    return result.toOwnedSlice(a);
}

pub fn tick(target: anytype, actor: *Actor, ctx: *controller.Context) !bool {
    ctx.shared.sanchez_enabled = actor.flags & 4 != 0;
    if (ctx.shared.sanchez_enabled) return true;
    if (@as(f64, ctx.shared.killed_enemies) <= @as(f64, ctx.shared.total_enemies) * 0.8) {
        if (@as(
            f64,
            ctx.shared.total_enemies,
        ) * 0.5 < ctx.shared.killed_enemies and target.ai.taunt_at < ctx.shared.now) if (ctx.player) |player| {
            const point = perception.randomPoint(
                ctx.angles,
                ctx.random,
                perception.point(player.position),
                0,
                0x3f1c,
                50,
                150,
            );

            if (ctx.contact_residue) |residue| residue.projection.words[2] = 0x00640000;

            try relocate(
                actor,
                .{ .x = point.point.x, .y = player.position.y, .z = point.point.z },
                player.sector,
                ctx,
            );

            if (ctx.contact_residue) |residue| residue.projection.words[3] = @bitCast(
                @abs(@as(f32, @floatCast(@as(f64, player.position.x) - actor.position.x))),
            );

            const previous_taunt = ctx.contact_hidden_taunt;

            ctx.contact_hidden_taunt = true;
            defer ctx.contact_hidden_taunt = previous_taunt;

            try controller.taunt(target, actor.*, 1, true, ctx);
            const delay = controller.randomDelay(
                ctx.random,
                0x3fff,
                @as(i32, @bitCast(target.config.taunt_timer_time)) -% 0x2000,
            );

            target.ai.taunt_at = ctx.shared.now +% delay;
        };

        target.next_tick = ctx.shared.now +% 2000;
        return false;
    }

    if (ctx.sanchez_sites.len == 0) return false;

    const player = ctx.player orelse return error.MissingSanchezPlayer;
    var selected: usize = 0;
    var selected_distance: f32 = undefined;

    for (ctx.sanchez_sites, 0..) |site, i| {
        const distance: f32 = @floatCast(
            perception.distance(perception.point(site.position), perception.point(player.position)),
        );

        if (i == 0) selected_distance = distance;

        try relocate(actor, site.position, site.sector, ctx);
        const builds_list = site.sector != player.sector and ctx.now & 1 == 0 and ctx.visibility.lists[site.sector] == null;

        if (ctx.contact_residue) |residue| {
            var sample_random = ctx.random.*;
            const random = @import("../player/weapon.zig");

            if (@as(
                u32,
                @bitCast(actor.height),
            ) < 0x80000001) _ = random.randomFloat(&sample_random, 2);

            if (@as(
                u32,
                @bitCast(player.height),
            ) < 0x80000001) _ = random.randomFloat(&sample_random, 2);

            const radius: f32 = @floatCast(
                random.randomFloat(&sample_random, @abs(actor.collision_radius)),
            );

            residue.projection.words[0] = null;
            residue.projection.words[1] = null;
            residue.projection.words[2] = @bitCast(radius);
        }

        const visible = try ctx.visible(controller.Subject.fromActor(actor.*), player);

        if (builds_list) if (ctx.contact_residue) |residue| {
            @import(
                "contact_stack.zig",
            ).Enemy.hiddenConnectivity(
                residue,
                ctx.visibility.lists[site.sector] orelse return error.MissingSanchezVisibilityList,
            );
        };

        if (!visible and distance < selected_distance) {
            selected = i;
            selected_distance = distance;
        }
    }

    const site = ctx.sanchez_sites[selected];
    try relocate(actor, site.position, site.sector, ctx);

    actor.flags = (actor.flags & ~@as(u32, 0x100)) | 0x80000004;
    ctx.shared.sanchez_enabled = true;

    try controller.retarget(target, actor, .player, ctx);

    if (ctx.contact_residue) |residue| {
        const dx: f32 = @floatCast(@as(f64, player.position.x) - actor.position.x);
        const raw_yaw = @as(
            i32,
            actor.yaw,
        ) - @as(i32, if (actor.yaw != 0 and std.math.signbit(dx)) 0x4000 else 0);

        residue.projection.words[3] = @bitCast(raw_yaw);
    }

    target.sight_at = ctx.shared.now +% 2000;

    return false;
}

fn relocate(actor: *Actor, position: level.Vec3, sector: usize, ctx: *controller.Context) !void {
    const previous = actor.sector;
    actor.position = position;

    if (previous != sector and ctx.contact_sector_events) if (ctx.contact_residue) |residue| residue.invalidate();

    if (ctx.actors.runtime) |runtime| try runtime.changeSector(previous, sector);

    actor.sector = sector;
}
