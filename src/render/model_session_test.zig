//! Geometry models in a live level: rendering them and collecting them while moving.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const Session = @import("session.zig").Session;
const input = @import("../player/input.zig");

test "3DO real Hideout dynamite and Town knife render and collect through movement" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const shown = try a.alloc(u8, 640 * 480);
    defer a.free(shown);
    const hidden = try a.alloc(u8, 640 * 480);
    defer a.free(hidden);
    const Case = struct {
        mission: []const u8,
        id: u32,
        item: []const u8,
        message: i32,
        radius: f32,
    };

    for ([_]Case{
        .{ .mission = "hideout", .id = 0x38bdb, .item = "IDYNAM", .message = 106, .radius = 1 },
        .{ .mission = "town", .id = 0x9cb21757, .item = "IKNIFE", .message = 105, .radius = -1 },
    }) |case| {
        var startup = try campaign.Startup.prepare(a, archive, .good);
        defer startup.deinit(a);

        try @import("../platform/mission.zig").select(&startup, case.mission);
        _ = try startup.levelForDiagnostics();

        const session = try Session.open(
            a,
            @import("test_workspace.zig").get(),
            io,
            path,
            archive,
            &startup,
        );

        defer session.deinit(a);
        const source = for (session.objects.entries, 0..) |object, index| {
            if (object.id == case.id) break index;
        } else return error.MissingModelPlacement;

        const object = session.objects.entries[source];
        const sector = session.level.sectorIndex(
            object.sector_id,
        ) orelse return error.MissingModelSector;

        const requested = try a.alloc(bool, session.level.sectors.len);
        defer a.free(requested);

        @memset(requested, false);

        requested[sector] = true;
        _ = try session.loadActorsInSectors(requested);

        try std.testing.expect(session.actor_slots[source].?.model != null);
        try std.testing.expect(session.actor_slots[source].?.costume == null);
        try std.testing.expectEqual(case.radius, session.actor_slots[source].?.collision_radius);
        try std.testing.expectEqual(@as(f32, 0.5), session.actor_slots[source].?.height);

        const pickup = session.pickup_slots[source].?;
        try std.testing.expectEqualStrings(case.item, pickup.entries[0].name);
        var slot = session.inventory.find(case.item);

        if (slot == 0) slot = try session.inventory.acquire(
            try @import(
                "../player/inventory.zig",
            ).Definition.load(session.arena.allocator(), pickup.archives, pickup.entries[0].name),
            @intCast(pickup.entries[0].slot),
        );

        const maximum = session.inventory.slots[slot].?.definition.max_count;
        session.inventory.slots[slot].?.count = maximum;
        const saved_player = session.player;

        session.player.position = object.position;
        session.player.sector = sector;
        session.player.yaw = if (case.id == 0x38bdb) 0x1000 else 0;

        if (case.id == 0x38bdb) session.player.position.x -= 6 else session.player.position.z -= 3;

        session.player.floor_cache = object.position.y;
        var crouch: input.Packet = .{};
        crouch.entries[
            @intFromEnum(
                input.Slot.crouch,
            )
        ] = .{ .value = 5120, .flags = .{ .absolute = true } };

        for (0..64) |_| {
            try session.advance(a, &crouch, 16);
            if (session.player.eye_height == session.player.crouch_height) break;
        }

        try std.testing.expectEqual(session.player.crouch_height, session.player.eye_height);
        @memset(shown, 0);
        _ = try session.renderWorld(shown, 0);
        const flags = session.actor_slots[source].?.flags;
        session.actor_slots[source].?.flags.visible = false;
        session.syncActor(source);
        @memset(hidden, 0);
        _ = try session.renderWorld(hidden, 0);
        try std.testing.expect(!std.mem.eql(u8, shown, hidden));
        session.actor_slots[source].?.flags = flags;
        session.syncActor(source);

        var packet: input.Packet = .{};

        packet.entries[
            @intFromEnum(
                input.Slot.forward,
            )
        ] = .{ .value = 5120, .flags = .{ .absolute = true } };

        session.player = saved_player;
        session.player.position = object.position;
        session.player.sector = sector;
        session.player.yaw = 0;
        session.look = .{};

        try session.advance(a, &packet, 16);

        try std.testing.expect(!session.removed_actors[source]);
        try std.testing.expectEqual(maximum, session.inventory.slots[slot].?.count);

        session.inventory.slots[slot].?.count = maximum - 1;
        session.player = saved_player;
        session.player.position = object.position;
        session.player.sector = sector;
        session.player.yaw = 0;
        session.look = .{};

        try session.advance(a, &packet, 16);

        try std.testing.expect(session.removed_actors[source]);
        try std.testing.expect(session.source_to_entry[source] == null);
        try std.testing.expectEqual(maximum, session.inventory.slots[slot].?.count);

        var found = false;

        for (session.pickup_effects.items) |effect| switch (effect) {
            .message => |message| if (message.index == case.message) {
                found = true;
            },
            else => {},
        };

        try std.testing.expect(found);
    }
}
