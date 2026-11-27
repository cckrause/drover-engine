//! Use rays: their filters, their bounds and the order recipients get them in.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const campaign = @import("../campaign.zig");
const Session = @import("../render/session.zig").Session;
const Actor = @import("../render/objects.zig").Actor;
const interaction = @import("interaction.zig");

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "actor use rays preserve filters bounds and recipient ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct {
        actors: []struct {
            sector: usize,
            position: [3]f32,
            flags: u32,
            secondary_flags: u32,
            height: f32,
            radius: f32,
        },
        ray: struct {
            sector: usize,
            position_bits: [3]u32,
            yaw: i16,
            height_bits: u32,
            object_id: u32,
            events: []interaction.Event,
        },
        recipients: []usize,
    };

    const Fixture = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []Case,
    };

    const fixture = (try std.json.parseFromSlice(
        Fixture,
        a,
        try read(a, "testdata/actor-nudge-reference.json"),
        .{},
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        fixture.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "2e724be18a76f51b3bc3df79e5a4089a90896659abef0f600262379936e3af23",
        fixture.results_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try campaign.Startup.prepare(a, archive, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    const session = try Session.open(
        a,
        @import("../render/test_workspace.zig").get(),
        std.testing.io,
        path,
        archive,
        &startup,
    );

    defer session.deinit(a);

    for (fixture.cases, 0..) |case, case_index| {
        errdefer std.debug.print("actor use native case{d}\n", .{case_index});
        var player = session.player;

        player.sector = case.ray.sector;
        player.position = .{
            .x = @bitCast(case.ray.position_bits[0]),
            .y = @bitCast(case.ray.position_bits[1]),
            .z = @bitCast(case.ray.position_bits[2]),
        };

        player.yaw = case.ray.yaw;
        player.body_height = @bitCast(case.ray.height_bits);

        const actors = try a.alloc(Actor, case.actors.len);

        for (case.actors, actors, 0..) |value, *actor, source| {
            actor.* = .{
                .source_index = source,
                .sector = value.sector,
                .position = .{
                    .x = value.position[0],
                    .y = value.position[1],
                    .z = value.position[2],
                },
                .yaw = 0,
                .flags = value.flags,
                .secondary_flags = value.secondary_flags,
                .scale_x = 1,
                .scale_y = 1,
                .height = value.height,
                .collision_radius = value.radius,
                .choreography = 0,
                .frame = 0,
                .angle_offset = 0,
            };
        }

        var events_buffer: interaction.RayEventBuffer = undefined;
        var events = interaction.RayEvents.init(&events_buffer);

        try interaction.activate(
            &events,
            &session.level,
            &session.scene,
            &session.angles,
            session.textures,
            &player,
            .{ .entries = actors },
            case.ray.object_id,
        );

        var recipients: std.ArrayList(usize) = .empty;
        var geometry: std.ArrayList(interaction.Event) = .empty;

        for (events.items) |event| {
            if (event.actor) |source| try recipients.append(
                a,
                source,
            ) else try geometry.append(a, event);
        }

        try std.testing.expectEqualSlices(usize, case.recipients, recipients.items);
        try std.testing.expectEqualDeep(case.ray.events, geometry.items);
    }
}
