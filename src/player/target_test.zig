//! Targeting enemies: the damage message, the queued death and its selection.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;
const nwx = @import("../assets/nwx.zig");
const target_module = @import("target.zig");
const Actor = @import("../render/objects.zig").Actor;
const Angles = @import("../render/backends/software/camera.zig").Angles;

const Snapshot = struct {
    health_bits: u32,
    velocity_bits: [3]u32,
    mode: u32,
    previous_mode: u32,
    anger_bits: u32,
    fear_bits: u32,
    attack_at: u32,
    sight_at: u32,
    next_tick: u32,
    current_chor: u32,
    animation_ended: bool,
    saved_mode: ?u32,
    saved_health_bits: ?u32,
    flags: u32,
    height_bits: u32,
    playback: [8]u32,
    random: u32,
};

const Case = struct {
    name: []const u8,
    difficulty: u32,
    damage: f32,
    height_ratio: f32,
    aggressiveness: i32,
    initial: struct {
        animation: []const u8,
        flags: u32,
        secondary_flags: u32,
        scale_x: f32,
        scale_y: f32,
        height: f32,
        collision_radius: f32,
    },
    hits: []Snapshot,
    delivered: Snapshot,
};

fn expectSnapshot(
    expected: Snapshot,
    target: target_module.Target,
    actor: Actor,
    random: u32,
    selected: bool,
) !void {
    try std.testing.expectEqual(expected.health_bits, @as(u32, @bitCast(target.damage.health)));
    try std.testing.expectEqual(
        expected.velocity_bits,
        [3]u32{
            @bitCast(target.damage.velocity.x),
            @bitCast(target.damage.velocity.y),
            @bitCast(target.damage.velocity.z),
        },
    );

    try std.testing.expectEqual(expected.mode, target.mode);
    try std.testing.expectEqual(expected.previous_mode, target.previous_mode);
    try std.testing.expectEqual(expected.anger_bits, @as(u32, @bitCast(target.anger)));
    try std.testing.expectEqual(expected.fear_bits, @as(u32, @bitCast(target.fear)));
    try std.testing.expectEqual(expected.attack_at, target.attack_at);
    try std.testing.expectEqual(expected.sight_at, target.sight_at);
    try std.testing.expectEqual(expected.next_tick, target.next_tick);
    try std.testing.expectEqual(expected.current_chor, target.damage.current_chor);
    try std.testing.expectEqual(expected.animation_ended, target.animation_ended);
    try std.testing.expectEqual(
        expected.saved_mode,
        if (target.saved) |saved| saved.mode else null,
    );

    try std.testing.expectEqual(
        expected.saved_health_bits,
        if (target.saved) |saved| @as(u32, @bitCast(saved.damage.health)) else null,
    );

    try std.testing.expectEqual(expected.flags, actor.flags);
    try std.testing.expectEqual(expected.height_bits, @as(u32, @bitCast(actor.height)));
    try std.testing.expectEqual(expected.random, random);

    if (selected) {
        const playback = target.playback;
        try std.testing.expectEqual(
            expected.playback[0..7].*,
            [7]u32{
                playback.last_time,
                @as(u16, @bitCast(playback.angle_offset)),
                playback.direction,
                playback.choreography,
                playback.next_frame,
                playback.frame,
                playback.flags,
            },
        );
    }
}

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "enemy damage messages and queued death selection match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try read(a, "testdata/target-message-reference.json");
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []Case,
    };

    const parsed = try std.json.parseFromSlice(Corpus, a, data, .{ .ignore_unknown_fields = true });

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "fbed7ed80f03641a9bc7dbc37eb18fdfc603d111359386aadf50342cb078f47c",
        parsed.value.results_sha256,
    );

    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    const angles = Angles.init();

    for (parsed.value.cases, 0..) |case, index| {
        errdefer std.debug.print(
            "reference enemy message sequence {d}: {s}/{x}\n",
            .{ index, case.name, case.difficulty },
        );

        const name = try std.fmt.allocPrint(a, "{s}.ITM", .{case.name});
        var definition = try Item.parse(a, try archive.find(name, 0));
        defer definition.deinit();
        var target = (try target_module.Target.load(
            a,
            &.{archive},
            &definition,
            case.difficulty,
        )).?;

        try std.testing.expectEqual(case.aggressiveness, target.aggressiveness);

        var costume = try nwx.Costume.parse(a, try archive.find(case.initial.animation, 0));
        defer costume.deinit();
        var actor = Actor{
            .costume = &costume,
            .sector = 0,
            .position = .{ .x = 0, .y = 0, .z = 0 },
            .yaw = 0,
            .flags = case.initial.flags,
            .secondary_flags = case.initial.secondary_flags,
            .scale_x = case.initial.scale_x,
            .scale_y = case.initial.scale_y,
            .height = case.initial.height,
            .collision_radius = case.initial.collision_radius,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };

        var random: u32 = 0x742389ac;

        for (case.hits) |expected| {
            try target.hit(
                &angles,
                &actor,
                .{
                    .kind = 1,
                    .damage = case.damage,
                    .mass = 0.03,
                    .speed = 1000,
                    .pitch = 0,
                    .yaw = 4096,
                    .lateral = 0,
                    .height = actor.height * case.height_ratio,
                    .shooter_position = .{ .x = 20, .z = 0 },
                },
                &random,
                1000,
            );

            try expectSnapshot(expected, target, actor, random, false);
        }

        try target.deliverSelection(&actor, &random, 1000);
        try expectSnapshot(case.delivered, target, actor, random, target.dead);

        try std.testing.expect(actor.playback == null);
    }
}

test "Hideout pistol routes ray hit through queued enemy damage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        victim_id: u32,
        sector: usize,
        player_position: [3]f32,
        shot: [11]u32,
        group: struct {
            kind: u32,
            damage_bits: u32,
            mass_bits: u32,
            speed_bits: u32,
            yaw: i16,
            pitch: i16,
            lateral_bits: u32,
            height_bits: u32,
        },
        after_selection: Snapshot,
    };

    const parsed = try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/session-shot-reference.json"),
        .{ .ignore_unknown_fields = true },
    );

    const expected = parsed.value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        expected.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "15cdddbaa4d6b2ebaf03c2bd60d99746347b1db5cce607163190ff3a6a1932f5",
        expected.results_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    const session = try @import(
        "../render/session.zig",
    ).Session.open(
        a,
        @import("../render/test_workspace.zig").get(),
        std.testing.io,
        path,
        archive,
        &startup,
    );

    defer session.deinit(a);
    const pixels = try a.alloc(u8, 640 * 480);

    _ = try session.render(pixels, 0);

    session.player.position = .{
        .x = expected.player_position[0],
        .y = expected.player_position[1],
        .z = expected.player_position[2],
    };

    session.player.sector = expected.sector;
    session.player.velocity = .{ .x = 0, .y = 0, .z = 0 };
    session.player.yaw = 0;
    session.player.pitch = 0;
    session.player.head_yaw = 0;
    session.player.eye_height = session.player.standing_height - session.player.head_height - 0.01;
    session.player.body_height = 5.99;
    session.player.head_bob = 0;
    session.contact_state.random = 0x742389ac;
    session.enemy_shared.crt_random = 1;
    session.weapon_state.action = 0;
    session.animation_time = 1000;
    session.aim_count = 0;

    const visible = try a.alloc(bool, session.level.sectors.len);
    @memset(visible, false);

    visible[expected.sector] = true;
    _ = try session.loadActorsInSectors(visible);

    const source_index = for (session.objects.entries, 0..) |object, index| {
        if (object.id == expected.victim_id) break index;
    } else return error.MissingReferenceShotTarget;

    try std.testing.expectEqual(@as(f32, 2), session.targets[source_index].?.damage.health);

    const weapon = @import("weapon.zig");
    var effects_buffer: @import("inventory.zig").EffectBuffer = undefined;
    var effects = @import("inventory.zig").Effects.init(&effects_buffer);
    var shots_buffer: weapon.ShotBuffer = undefined;
    var shots = weapon.Shots.init(&shots_buffer);
    var context = weapon.Context{
        .state = &session.weapon_state,
        .inventory = &session.inventory,
        .player = &session.player,
        .random = &session.contact_state.random,
        .effects = &effects,
        .shots = &shots,
        .now = session.animation_time,
        .ready = true,
        .angles = &session.angles,
    };

    const animation = session.hud.weaponAnimation().?;

    try context.event(animation.playback, animation.costume, 1, &.{}, session.animation_time);
    try std.testing.expectEqual(@as(usize, 1), shots.items.len);
    const shot = shots.items[0];

    try std.testing.expectEqual(expected.shot[0], @intFromEnum(shot.kind));
    try std.testing.expectEqual(
        expected.shot[2..9].*,
        [7]u32{
            @bitCast(shot.damage),
            @bitCast(shot.mass),
            @bitCast(shot.rate),
            @bitCast(shot.range),
            @bitCast(shot.origin.x),
            @bitCast(shot.origin.y),
            @bitCast(shot.origin.z),
        },
    );

    try std.testing.expectEqual(
        expected.shot[9],
        @as(u32, @as(u16, @bitCast(shot.yaw))) << 16 | @as(u16, @bitCast(shot.pitch)),
    );

    try std.testing.expectEqual(expected.shot[10] != 0, shot.impact_sound);

    try session.castShots(a, shots.items, &effects);
    std.mem.swap(@TypeOf(session.pending_hits), &session.pending_hits, &session.queued_hits);

    try std.testing.expectEqual(@as(usize, 1), session.queued_hits.items.len);
    const queued = session.queued_hits.items[0];
    try std.testing.expectEqual(source_index, queued.target);
    const damage = queued.damageInput();

    try std.testing.expectEqual(expected.group.kind, damage.kind);
    try std.testing.expectEqual(expected.group.damage_bits, @as(u32, @bitCast(damage.damage)));
    try std.testing.expectEqual(expected.group.mass_bits, @as(u32, @bitCast(damage.mass)));
    try std.testing.expectEqual(expected.group.speed_bits, @as(u32, @bitCast(damage.speed)));
    try std.testing.expectEqual(expected.group.pitch, damage.pitch);
    try std.testing.expectEqual(expected.group.yaw, damage.yaw);
    try std.testing.expectEqual(expected.group.lateral_bits, @as(u32, @bitCast(damage.lateral)));
    try std.testing.expectEqual(expected.group.height_bits, @as(u32, @bitCast(damage.height)));
    try std.testing.expectEqual(@as(f32, 2), session.targets[source_index].?.damage.health);

    try session.deliverHits(a, null, &effects);
    try @import("../enemy/session.zig").deliverSelections(session, a, null);
    try expectSnapshot(
        expected.after_selection,
        session.targets[source_index].?,
        session.actor_slots[source_index].?,
        session.contact_state.random,
        true,
    );

    try std.testing.expectEqual(@as(i32, 5), session.inventory.slots[2].?.loaded);
}
