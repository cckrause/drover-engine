//! Playing a level asks for no memory: once the level is open, the frame
//! allocator and the session's own allocator (which the router shares) fail
//! every request, and the level's storage never grows.
//!
//! Needs the installed game data; skips without it.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const input = @import("../player/input.zig");
const Session = @import("session.zig").Session;

fn press(packet: *input.Packet, slot: input.Slot, frame: usize, period: usize, offset: usize) void {
    const phase = (frame + period - offset) % period;
    packet.entries[@intFromEnum(slot)] = if (phase == 0)
        .{ .value = 1, .flags = input.absolute | input.pressed }
    else if (phase == 1) .{ .flags = input.released } else .{};
}

test "memory budget: Hideout plays twelve thousand frames of walking, shooting and using without asking for memory" {
    var watch = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = watch.allocator();
    const io = std.testing.io;
    const data_path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const system_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        data_path,
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(system_bytes);
    const system = try lab.Archive.init(system_bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    const session = try Session.open(
        a,
        @import("test_workspace.zig").get(),
        io,
        data_path,
        system,
        &startup,
    );

    defer session.deinit(a);

    watch.fail_index = watch.alloc_index;
    watch.resize_fail_index = watch.resize_index;
    defer {
        watch.fail_index = std.math.maxInt(usize);
        watch.resize_fail_index = std.math.maxInt(usize);
    }

    const level_storage = session.arena.queryCapacity();
    const health = session.inventory.health;
    const actors = session.actors.len;
    var frame: usize = 0;

    while (frame < 12000) : (frame += 1) {
        var packet: input.Packet = .{};

        packet.entries[
            @intFromEnum(
                input.Slot.forward,
            )
        ] = .{ .value = if (frame % 700 < 500) 2560 else -2560, .flags = input.absolute };

        packet.entries[
            @intFromEnum(
                input.Slot.turn,
            )
        ] = .{ .value = if (frame % 300 < 40) 3000 else 0 };

        packet.entries[@intFromEnum(input.Slot.speed)] = .{ .value = 100, .flags = input.unscaled };

        press(&packet, .fire, frame, 20, 0);
        press(&packet, .use, frame, 90, 0);
        press(&packet, .nudge, frame, 90, 45);

        if (frame % 1500 == 750) packet.entries[
            @intFromEnum(
                input.Slot.weapon,
            )
        ] = .{ .value = @intCast(2 + (frame / 1500) % 5), .flags = input.absolute | input.pressed };

        session.advance(std.testing.failing_allocator, &packet, 16) catch |err| {
            std.debug.print("frame {d}\n", .{frame});
            return err;
        };

        if (session.arena.queryCapacity() != level_storage) {
            std.debug.print("frame {d} grew the level's storage\n", .{frame});
            return error.TestUnexpectedResult;
        }
    }

    // Enemies found and hurt the player, and new actors came and went.
    try std.testing.expect(session.inventory.health != health);
    try std.testing.expect(session.actors.len > actors);
}
