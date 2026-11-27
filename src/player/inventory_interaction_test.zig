//! Inventory in use: selection, using health, and dropping items.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const lab = @import("../assets/lab.zig");
const inventory_module = @import("inventory.zig");
const input = @import("input.zig");
const Session = @import("../render/session.zig").Session;
const campaign = @import("../campaign.zig");
const weapon = @import("weapon.zig");

test "inventory selection health use and drops match player/ execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var archives: [3]lab.Archive = undefined;
    for ([_][]const u8{ "OLOBJ", "OLWEAP", "OUTLAWS" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        archive.* = try lab.Archive.init(bytes);
    }
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inventory-interaction-reference.json", a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Slot = struct {
        slot: usize,
        name: []const u8,
        count: i32,
        hidden: ?u8 = null,
    };
    const Frame = struct {
        slots: []const Slot,
        health_bits: u32,
        health_stat: i32,
        selected: usize,
        cursor: usize,
        browsing: bool,
        activations: []const [2]u32,
        events: []const std.json.Value,
        drops: []const struct { name: []const u8, position: [3]u32 },
        dropped_counts: []const i16,
        dropped_flags: []const u8,
        dropped_enabled: []const u8,
    };
    const Case = struct { layout: []const Slot, health: f32, selected: usize, cursor: usize, browsing: bool, inputs: []const []const [3]i32, frames: []const Frame };
    const parsed = try std.json.parseFromSlice(struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []const Case }, a, data, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", parsed.value.executable_sha256);
    try std.testing.expectEqualStrings("a353b4d114f35a837be042b7e2d742b5a0ef752cb454543413408a3991e80a7e", parsed.value.results_sha256);
    for (parsed.value.cases, 0..) |case, case_index| {
        const has_drop = blk: {
            for (case.inputs) |entries| for (entries) |entry| {
                if (entry[0] == @intFromEnum(input.Slot.drop)) break :blk true;
            };
            break :blk false;
        };
        var startup: ?campaign.Startup = if (has_drop) try campaign.Startup.prepare(a, archives[2], .good) else null;
        defer if (startup) |*owned| owned.deinit(a);
        const session: ?*Session = if (has_drop) blk: {
            _ = try startup.?.levelForDiagnostics();
            const live = try Session.open(a, @import("../render/test_workspace.zig").get(), std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", archives[2], &startup.?);
            live.player.position = .{ .x = 0, .y = 0, .z = 0 };
            live.level.sectors[live.player.sector].floor.height = 0;
            live.level.sectors[live.player.sector].ceiling.height = 20;
            break :blk live;
        } else null;
        defer if (session) |live| live.deinit(a);
        var inventory = inventory_module.Inventory{ .health = case.health, .selected = case.selected, .browse_cursor = case.cursor, .browsing = case.browsing };
        for (case.layout) |slot| {
            var definition = try inventory_module.Definition.load(a, &archives, slot.name);
            if (slot.hidden) |hidden| definition.no_show = hidden != 0;
            inventory.slots[slot.slot] = .{ .definition = definition, .count = slot.count };
        }
        var effects = inventory_module.Effects.init(a);
        for (case.inputs, case.frames, 0..) |entries, expected, frame_index| {
            var packet = input.Packet{};
            for (entries) |entry| packet.entries[@intCast(entry[0])] = .{ .value = @intCast(entry[1]), .flags = @intCast(entry[2]) };
            effects.clearRetainingCapacity();
            inventory.browseInput(packet.get(.weapon));
            if (packet.get(.drop).flags & input.pressed != 0) {
                const live = session.?;
                live.inventory = inventory;
                const before = live.actor_slots.len;
                var shots = weapon.Shots.init(a);
                defer shots.deinit();
                try live.dropSelected(&effects, &shots);
                inventory = live.inventory;
                try std.testing.expectEqual(expected.drops.len, live.actor_slots.len - before);
                for (expected.drops, expected.dropped_counts, expected.dropped_flags, expected.dropped_enabled, 0..) |drop, count, flags, enabled, i| {
                    const actor = live.actor_slots[before + i].?;
                    const pickup = live.pickup_slots[before + i].?;
                    try std.testing.expectEqual(drop.position, [3]u32{ @bitCast(actor.position.x), @bitCast(actor.position.y), @bitCast(actor.position.z) });
                    try std.testing.expectEqual(count, pickup.entries[0].count);
                    try std.testing.expectEqual(flags, @as(u8, @truncate(@as(u16, @bitCast(pickup.flags)))));
                    try std.testing.expectEqual(enabled != 0, pickup.enabled);
                }
            }
            var activation: [2]u32 = undefined;
            var activation_count: usize = 0;
            if (packet.get(.use).flags & input.pressed != 0) {
                if (try inventory.useSelected(&effects)) |id| {
                    activation[activation_count] = id;
                    activation_count += 1;
                }
            }
            if (packet.get(.nudge).flags & input.pressed != 0) {
                activation[activation_count] = 0;
                activation_count += 1;
            }
            errdefer std.debug.print("inventory interaction case{d} frame{d}\n", .{ case_index, frame_index });
            try std.testing.expectEqual(expected.health_bits, @as(u32, @bitCast(inventory.health)));
            try std.testing.expectEqual(expected.health_stat, inventory.statistics.health);
            try std.testing.expectEqual(expected.selected, inventory.selected);
            try std.testing.expectEqual(expected.cursor, inventory.browse_cursor);
            try std.testing.expectEqual(expected.browsing, inventory.browsing);
            try std.testing.expectEqual(expected.activations.len, activation_count);
            for (expected.activations, activation[0..activation_count]) |wanted, actual| try std.testing.expectEqual(wanted[0], actual);
            var slot_count: usize = 0;
            for (inventory.slots[1..]) |slot| {
                if (slot != null) slot_count += 1;
            }
            try std.testing.expectEqual(expected.slots.len, slot_count);
            for (expected.slots) |slot| {
                const actual = inventory.slots[slot.slot] orelse return error.MissingExpectedInventory;
                try std.testing.expectEqual(slot.count, actual.count);
            }
            try std.testing.expectEqual(expected.events.len, effects.items.len);
            for (expected.events, effects.items) |wanted, actual| {
                if (std.mem.eql(u8, wanted.array.items[0].string, "message")) {
                    try std.testing.expect(actual == .message);
                    try std.testing.expectEqual(wanted.array.items[1].integer, actual.message.index);
                } else {
                    try std.testing.expect(actual == .sound);
                    try std.testing.expect(std.ascii.eqlIgnoreCase(std.fs.path.stem(wanted.array.items[1].string), std.fs.path.stem(actual.sound.basename)));
                }
            }
        }
    }
}
