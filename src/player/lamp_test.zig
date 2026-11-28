//! The portable lamp: input, fuel, fade and the random draws it shares.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const RequestFlags = @import("../audio/engine.zig").RequestFlags;
const PlayerFlags = @import("flags.zig").PlayerFlags;

const lab = @import("../assets/lab.zig");
const lamp = @import("lamp.zig");
const Item = @import("../assets/item.zig").Item;
const inventory_module = @import("inventory.zig");
const bits = @import("../util/bits.zig");
const ActorFlags = @import("../actor_flags.zig").ActorFlags;

fn number(value: std.json.Value) f32 {
    return switch (value) {
        .float => |n| @floatCast(n),
        .integer => |n| @floatFromInt(n),
        else => unreachable,
    };
}

test "portable lamp matches input, fuel, fade and shared-random execution" {
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

    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/player-lamp-reference.json",
        a,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const Frame = struct {
        flags: u32,
        actor_flags: u32,
        count: ?i32,
        fuel_elapsed: u32,
        flicker_time: u32,
        random: u32,
        fade: u32,
        fading_in: u32,
        fading_out: u32,
        lighting: [2]i32,
        events: []const std.json.Value,
    };

    const Case = struct {
        name: []const u8,
        config: struct {
            flags: u32 = 4,
            count: ?i32 = null,
            fuel_elapsed: f32 = 0,
            flicker_time: u32 = 0,
            random: u32 = 0x742389ac,
        },
        actions: []const std.json.Value,
        frames: []const Frame,
    };

    const parsed = try std.json.parseFromSlice(
        struct { executable_sha256: []const u8, sha256: []const u8, cases: []const Case },
        a,
        data,
        .{ .ignore_unknown_fields = true },
    );

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "a44afc539b4549b4e453cdb8da268bbb538d1c6dea32af861356aeb8e01a9279",
        parsed.value.sha256,
    );

    const definition = try inventory_module.Definition.load(a, &archives, "IOIL");
    var cid = try Item.parse(a, try archives[0].find("CIDJAMES.ITM", 0));
    defer cid.deinit();
    const config = try lamp.Config.fromItem(&cid);

    try std.testing.expectEqualStrings("LIGHT.WAV", config.soundName());

    for (parsed.value.cases) |case| {
        var inventory: inventory_module.Inventory = .{ .player_flags = bits.from(PlayerFlags, case.config.flags) };

        if (case.config.count) |count| inventory.slots[11] = .{
            .definition = definition,
            .count = count,
        };

        var state: lamp.State = .{
            .fuel_elapsed = case.config.fuel_elapsed,
            .flicker_time = case.config.flicker_time,
        };

        var random = case.config.random;
        var actor_flags = bits.with(ActorFlags.new, .{ .has_logic = true });
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);

        for (case.actions, case.frames, 0..) |action, expected, frame| {
            effects.clearRetainingCapacity();

            const parts = action.array.items;
            const name = parts[0].string;

            if (std.mem.eql(u8, name, "tick")) {
                const seconds = number(parts[1]);

                if (seconds != 0) {
                    const before = inventory.player_flags.lamp_on;

                    if (parts[2].bool) try state.toggle(&inventory, &config, &effects);

                    try state.consume(&inventory, seconds);

                    if (before != inventory.player_flags.lamp_on)
                        actor_flags = lamp.actorFlags(
                            actor_flags,
                            inventory.player_flags.lamp_on,
                        );
                }
            } else if (std.mem.eql(u8, name, "render")) {
                state.advancePresentation(number(parts[1]), @intCast(parts[2].integer), &random);
            } else if (std.mem.eql(u8, name, "hard_off")) {
                state.hardOff();
            } else return error.UnknownLampReferenceAction;

            const actual = [_]u32{
                bits.word(inventory.player_flags),
                bits.word(actor_flags),
                @bitCast(state.fuel_elapsed),
                state.flicker_time,
                random,
                @bitCast(state.fade),
                @intFromBool(state.fading_in),
                @intFromBool(state.fading_out),
                @intFromBool(state.force_depth),
                @bitCast(state.depth_bias),
            };

            const wanted = [_]u32{
                expected.flags,
                expected.actor_flags,
                expected.fuel_elapsed,
                expected.flicker_time,
                expected.random,
                expected.fade,
                expected.fading_in,
                expected.fading_out,
                @bitCast(expected.lighting[0]),
                @bitCast(expected.lighting[1]),
            };

            std.testing.expectEqualSlices(u32, &wanted, &actual) catch |err| {
                std.debug.print("lamp reference {s}, frame {d}\n", .{ case.name, frame });
                return err;
            };

            try std.testing.expectEqual(
                expected.count,
                if (inventory.slots[11]) |owned| owned.count else null,
            );

            try std.testing.expectEqual(expected.events.len, effects.items.len);

            for (expected.events, effects.items) |event, effect| {
                try std.testing.expectEqualStrings("sound", event.array.items[0].string);
                try std.testing.expect(effect == .sound);
                try std.testing.expectEqualStrings(
                    event.array.items[1].string,
                    effect.sound.basename,
                );

                try std.testing.expectEqual(@as(?i32, 64), effect.sound.priority);
                try std.testing.expectEqual(@as(?i32, 127), effect.sound.volume);
                try std.testing.expectEqual(@as(?RequestFlags, .{}), effect.sound.flags);
            }
        }
    }
}
