//! Picking things up in a live level, with real pickups and ammunition.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const campaign = @import("../campaign.zig");
const lab = @import("../assets/lab.zig");
const Session = @import("../render/session.zig").Session;
const input = @import("input.zig");

fn objectIndex(session: *const Session, id: u32) !usize {
    for (session.objects.entries, 0..) |object, i| if (object.id == id) return i;
    return error.MissingOriginalPickupFixture;
}

fn placeAt(session: *Session, index: usize) !void {
    const object = session.objects.entries[index];
    session.player.position = object.position;
    session.player.sector = session.level.sectorIndex(object.sector_id) orelse return error.MissingOriginalPickupSector;
    session.player.yaw = 0;
    session.look = .{};
}

fn hasActor(session: *const Session, index: usize) bool {
    for (session.actors) |actor| if (actor.source_index == index) return true;
    return false;
}

fn expectMessage(session: *const Session, index: i32, parameter: ?i32) !void {
    for (session.pickup_effects.items) |effect| switch (effect) {
        .message => |message| if (message.index == index and message.parameter == parameter) return,
        else => {},
    };
    return error.ExpectedOriginalPickupMessage;
}

fn expectSound(session: *const Session, name: []const u8) !void {
    for (session.pickup_effects.items) |effect| switch (effect) {
        .sound => |sound| if (std.mem.eql(u8, sound.basename, name)) return,
        else => {},
    };
    return error.ExpectedOriginalPickupSound;
}

test "Hideout pickup session dispatches real canteen and ammunition contacts" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    inline for (.{ "OUTLAWS.LAB", "OLGEO.LAB", "OLTEX.LAB", "OLOBJ.LAB", "OLWEAP.LAB" }) |name| {
        std.Io.Dir.cwd().access(io, "inputs/OUTLAWS_CD1/OUTLAWS/" ++ name, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, data_path, a, .limited(128 * 1024 * 1024));
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("../render/test_workspace.zig").get(), io, data_path, system, &startup);
    defer session.deinit(a);
    const initial_player = session.player;
    const canteen = try objectIndex(session, 0x36bc8);
    const ammunition = try objectIndex(session, 0x364de);
    try std.testing.expectEqualStrings("GCANTEEN", session.objects.entries[canteen].name);
    try std.testing.expectEqualStrings("GAMBOXB", session.objects.entries[ammunition].name);
    var packet: input.Packet = .{};
    packet.entries[@intFromEnum(input.Slot.forward)] = .{ .value = 5120, .flags = input.absolute };

    session.player = initial_player;
    try placeAt(session, canteen);
    session.inventory.health = 8;
    try session.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(f32, 8), session.inventory.health);
    try std.testing.expect(!session.removed_actors[canteen]);
    try std.testing.expectEqual(@as(usize, 0), session.pickup_effects.items.len);

    session.player = initial_player;
    try placeAt(session, canteen);
    session.inventory.health = 10;
    try session.advance(a, &packet, 16);
    try std.testing.expect(session.pickup_slots[canteen] != null);
    try std.testing.expect(session.actor_slots[canteen] != null);
    try std.testing.expect(hasActor(session, canteen));
    try std.testing.expectEqual(@as(f32, 10), session.inventory.health);
    try std.testing.expect(!session.removed_actors[canteen]);
    try std.testing.expectEqual(@as(usize, 0), session.pickup_effects.items.len);

    session.player = initial_player;
    try placeAt(session, canteen);
    session.inventory.health = 8;
    try session.advance(a, &packet, 16);
    try std.testing.expectEqual(@as(f32, 9), session.inventory.health);
    try std.testing.expectEqual(@as(i32, 1), session.inventory.statistics.health);
    try std.testing.expect(session.removed_actors[canteen]);
    try std.testing.expect(!hasActor(session, canteen));
    try expectMessage(session, 303, null);
    try std.testing.expectEqualStrings("Canteen", session.messages.entries[0].string());
    try std.testing.expectEqual(session.animation_time + 5000, session.messages.entries[0].expiry);
    try expectSound(session, "GULP");
    session.player = initial_player;
    try placeAt(session, canteen);
    try session.advance(a, &packet, 16);
    try std.testing.expectEqual(@as(f32, 9), session.inventory.health);
    try std.testing.expectEqual(@as(usize, 0), session.pickup_effects.items.len);

    try std.testing.expectEqualStrings("Canteen", session.messages.entries[0].string());
    try std.testing.expectEqualStrings("", session.messages.entries[1].string());

    const bullets = session.inventory.find("IBULLIT");
    try std.testing.expect(bullets != 0);
    const capacity = session.inventory.slots[bullets].?.definition.max_count;
    session.inventory.slots[bullets].?.count = capacity;
    session.player = initial_player;
    try placeAt(session, ammunition);
    try session.advance(a, &packet, 16);
    try std.testing.expect(session.pickup_slots[ammunition] != null);
    try std.testing.expect(!session.removed_actors[ammunition]);
    try std.testing.expect(hasActor(session, ammunition));
    try std.testing.expectEqual(capacity, session.inventory.slots[bullets].?.count);
    try std.testing.expectEqual(@as(usize, 0), session.pickup_effects.items.len);
    session.inventory.slots[bullets].?.count = capacity - 5;
    session.player = initial_player;
    try placeAt(session, ammunition);
    try session.advance(a, &packet, 16);
    try std.testing.expectEqual(capacity, session.inventory.slots[bullets].?.count);
    try std.testing.expectEqual(@as(i32, 1), session.inventory.statistics.items);
    try std.testing.expect(session.removed_actors[ammunition]);
    try std.testing.expect(!hasActor(session, ammunition));
    try expectMessage(session, 200, 12);
    try std.testing.expectEqualStrings("12 Bullets", session.messages.entries[1].string());
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    _ = try session.render(a, pixels, 0);
    _ = try session.render(a, pixels, 0);
    try std.testing.expectEqualStrings("", session.messages.entries[2].string());
}
