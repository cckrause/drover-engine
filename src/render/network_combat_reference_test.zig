//! Fighting between machines: the messages, the kill texts and the points.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const message = @import("../network/message.zig");
const server_module = @import("../network/server.zig");
const database_module = @import("../network/database.zig");
const Router = @import("../network/router.zig").Router;
const network_combat = @import("network_combat.zig");
const shot_damage = @import("../player/shot_damage.zig");
const shooting = @import("../player/shooting.zig");
const inventory_module = @import("../player/inventory.zig");
const movement = @import("../player/movement.zig");
const player_audio = @import("../audio/player.zig");
const flash_module = @import("damage_flash.zig");
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const camera = @import("backends/software/camera.zig");
const testing = std.testing;

fn expectHex(op: std.json.ObjectMap, field: []const u8, bytes: []const u8) !void {
    var buffer: [0x400]u8 = undefined;
    const expected = try std.fmt.hexToBytes(&buffer, op.get(field).?.string);
    try testing.expectEqualSlices(u8, expected, bytes);
}

fn hex(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try a.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[2 * index] = digits[byte >> 4];
        out[2 * index + 1] = digits[byte & 15];
    }
    return out;
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "fighting between machines matches the reference's messages, texts and points" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, a, try read(a, "testdata/network-combat-reference.json"), .{})).object;
    try testing.expectEqualStrings("f71a8db8743d12a14317393148a0ade05e2f86d7d80a98d4a76f1bffa20a52d1", root.get("executable_sha256").?.string);
    const patch = try lab.Archive.init(try read(a, "patches/1.1/OLPATCH1.LAB"));
    const messages = try patch.find("LOCAL.MSG", 0);
    const objects = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const system = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"));
    var item = try Item.parse(a, try objects.find("CIDJAMES.ITM", 0));
    defer item.deinit();
    const physics = try movement.Physics.parse(try system.find("AIR.PHY", 0));
    const audio_config = try player_audio.Config.fromItem(&item);
    var shot_config = try shot_damage.Config.fromItem(&item);
    shot_config.mass = 150;
    shot_config.multiplier = 1;
    const angles = camera.Angles.init();
    const place = [3]u32{ @bitCast(@as(f32, 1.5)), @bitCast(@as(f32, -2.25)), @bitCast(@as(f32, 300)) };
    var players: usize = 0;

    for (root.get("ops").?.array.items) |entry| {
        const op = entry.object;
        const kind = op.get("op").?.string;
        if (std.mem.eql(u8, kind, "packers")) {
            var buffer: [message.corpse_capacity]u8 = undefined;
            const corpse: message.Corpse = .{ .choreography = 0x15, .sector = 7, .position = place, .costume = "james.nwx" };
            try expectHex(op, "make_corpse", try message.corpse(&buffer, 0x3f6, 3, corpse));
            try expectHex(op, "create_corpse", try message.corpse(&buffer, 0x413, 3, corpse));
            try expectHex(op, "frag_delta", &message.fragDelta(3, .{ .client = 3, .team = 0xffffffff, .points = 1 }));
            try expectHex(op, "damage", &message.damage(3, .{ .kind = 0x10003, .damage = 4.5, .mass = 1, .speed = 2400, .yaw = -0x456, .pitch = 0x123, .position = .{ 1.5, -2.25, 300 }, .lateral = 0.25, .height = 3.5 }));
        } else if (std.mem.eql(u8, kind, "server_corpse")) {
            var router = try Router.init(a);
            defer router.deinit();
            router.reset();
            var sent: [message.corpse_capacity]u8 = undefined;
            const bytes = try std.fmt.hexToBytes(&sent, op.get("sent").?.string);
            _ = try router.post(0x100800, 0x3f6, bytes);
            var server: server_module.Server = .{};
            var users_buffer: server_module.UserMessageBuffer = undefined;
            var users = server_module.UserMessages.init(&users_buffer);
            var context: u8 = 0;
            const Hooks = struct {
                fn create(_: *anyopaque, _: message.HaveServerCreate) anyerror!void {
                    return error.UnexpectedCreate;
                }
            };
            try server_module.processRequests(&server, &router, .{ .now = 5000, .game_type = 5, .mode = 6, .level_loaded = true, .allocator = a, .user_messages = &users, .level = .{ .context = &context, .sectors = 8, .create = Hooks.create } });
            for (op.get("answers").?.array.items) |answer| {
                const got = (try router.read(message.Queue.database)) orelse return error.MissingCreateCorpse;
                try testing.expectEqualStrings(answer.string, try hex(a, got));
                router.release(got);
            }
            try testing.expectEqual(@as(?[]u8, null), try router.read(message.Queue.database));
        } else if (std.mem.eql(u8, kind, "frag")) {
            var router = try Router.init(a);
            defer router.deinit();
            var database = database_module.Database.init(a);
            defer database.deinit();
            try database.reset(&router);
            router.reset();
            const mode: u32 = @intCast(op.get("mode").?.integer);
            const client: u8 = @intCast(op.get("client").?.integer);
            const points: i32 = @bitCast(@as(u32, @intCast(op.get("points").?.integer)));
            router.clients[1].setName("Player");
            router.clients[1].player = .{ .code = 'J', .flags = 0x91 };
            router.clients[3].setName("Joiner");
            router.clients[3].player = if (op.get("team").? == .integer) .{ .code = 'J', .flags = 0x90 | @as(u32, @intCast(op.get("team").?.integer)) } else null;
            try network_combat.postFragDelta(&router, mode, client, points);
            try testing.expectEqual(@as(usize, 1), router.queues[message.Queue.database].count);
            try testing.expectEqualStrings(op.get("posted").?.array.items[0].string, try hex(a, router.peek(message.Queue.database).?));
            const posted = (try database.next(&router, true, 0)) orelse return error.MissingFragDelta;
            try database.applyFragDelta(&router, posted.frag_delta, .{ .now = 0, .game_type = 5, .mode = mode, .game_state = 0 });
            for (op.get("scores").?.array.items, 0..) |expected, index| {
                const score = router.scores[index / 2];
                try testing.expectEqual(expected.integer, if (index % 2 == 0) score.points else score.seconds);
            }
            for (op.get("teams").?.array.items, router.team_points) |expected, actual| try testing.expectEqual(expected.integer, actual);
            database.finish(&router);
        } else if (std.mem.eql(u8, kind, "player")) {
            errdefer std.debug.print("reference network player case {s}\n", .{op.get("name").?.string});
            players += 1;
            var router = try Router.init(a);
            defer router.deinit();
            router.reset();
            router.own_client = 3;
            router.player_name[0..7].* = "Joiner\x00".*;
            const mode: u32 = @intCast(op.get("mode").?.integer);
            const entity: u32 = @intCast(op.get("entity").?.integer);
            router.clients[1].setName(op.get("killer_name").?.string);
            router.clients[1].player = if (op.get("killer_entity").? == .integer) .{ .code = 'J', .flags = @intCast(op.get("killer_entity").?.integer) } else null;
            router.clients[3].setName("Joiner");
            router.clients[3].player = .{ .code = 'J', .flags = entity };
            var raw: [message.damage_size]u8 = undefined;
            const bytes = try std.fmt.hexToBytes(&raw, op.get("message").?.string);
            const sender = message.get(bytes, message.sender_offset);
            const events = op.get("events").?.array.items;
            var health: f32 = 10;
            var feedback: shot_damage.NetworkResult = .none;
            var effects_buffer: inventory_module.EffectBuffer = undefined;
            var effects = inventory_module.Effects.init(&effects_buffer);
            if (!network_combat.justStartedAt(@intCast(op.get("start").?.integer), @intCast(op.get("clock").?.integer))) {
                const value = try message.readDamage(bytes);
                var player = try movement.Player.init(&item, physics, .{ .sector = 0, .position = .{ .x = 10, .y = 2, .z = -4 }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
                player.radius = 2;
                player.eye_height = 5.5;
                player.flags = 4;
                var inventory = inventory_module.Inventory{ .health = 10, .player_flags = 4 };
                var flash: flash_module.State = .{};
                var audio_state: player_audio.State = .{};
                var audio = player_audio.Context{ .config = &audio_config, .state = &audio_state, .effects = &effects };
                const input: shooting.DamageInput = .{ .kind = value.kind, .damage = value.damage, .mass = value.mass, .speed = value.speed, .pitch = value.pitch, .yaw = value.yaw, .lateral = value.lateral, .height = value.height };
                feedback = try shot_damage.applyNetwork(&shot_config, &angles, &player, &inventory, input, message.client(sender) == 3, &flash, &audio, 10000);
                health = inventory.health;
                const reply = events[events.len - 1].object;
                try testing.expectEqualStrings("reply", reply.get("event").?.string);
                try testing.expectEqual(@as(i64, sender), reply.get("target").?.integer);
                try testing.expectEqual(@as(i64, 3 << 11 | 5), reply.get("sender").?.integer);
                try testing.expectEqual(@as(i64, if (health <= 0) 0x7e3 else 0x7e4), reply.get("code").?.integer);
            } else try testing.expectEqual(@as(usize, 0), events.len);
            try testing.expectEqual(op.get("health").?.integer, @as(u32, @bitCast(health)));
            var comments: std.ArrayList(std.json.ObjectMap) = .empty;
            var frag: ?std.json.ObjectMap = null;
            var sounds: std.ArrayList(i64) = .empty;
            var blood = false;
            for (events) |event| {
                const name = event.object.get("event").?.string;
                if (std.mem.eql(u8, name, "comment")) try comments.append(a, event.object);
                if (std.mem.eql(u8, name, "frag")) frag = event.object;
                if (std.mem.eql(u8, name, "sound")) try sounds.append(a, event.object.get("sound").?.integer - 0x10000);
                if (std.mem.eql(u8, name, "blood")) blood = true;
            }
            switch (feedback) {
                .none => {
                    try testing.expectEqual(@as(usize, 0), comments.items.len + sounds.items.len);
                    try testing.expect(frag == null and !blood);
                },
                .blood => {
                    try testing.expect(blood and frag == null);
                    try testing.expectEqualSlices(i64, &.{0x18c}, sounds.items);
                    try testing.expectEqual(@as(usize, 1), effects.items.len);
                    try testing.expect(std.ascii.eqlIgnoreCase("gotshot.wav", effects.items[0].sound.basename));
                },
                .death => |code| {
                    const death = try network_combat.deathReport(&router, messages, mode, entity, code, message.client(sender));
                    try testing.expectEqual(death.text_count, comments.items.len);
                    for (death.texts[0..death.text_count], comments.items) |text, expected| {
                        try testing.expectEqualStrings(expected.get("text").?.string, text.slice());
                        try testing.expectEqual(expected.get("destination").?.integer, @as(i64, text.destination));
                    }
                    const points = frag orelse return error.MissingFrag;
                    try testing.expectEqual(@as(i64, message.client(sender)), points.get("client").?.integer);
                    try testing.expectEqual(points.get("points").?.integer, @as(u32, @bitCast(death.points)));
                    try testing.expectEqualSlices(i64, &.{0x9c}, sounds.items);
                    try testing.expect(!blood);
                },
            }
        } else return error.UnknownReferenceOp;
    }
    try testing.expect(players > 10);
}
