//! Enemies in a live level: sector destruction, collision dispatch, player noise, and corpse construction after a restore.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const Session = @import("../render/session.zig").Session;
const enemy_session = @import("session.zig");

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

test "sector destruction releases pickup sounds in current link order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Sound = struct {
        name: []const u8,
        resource_type: u32,
        priority: u8,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        pickups: struct {
            names: [][]const u8,
            calls: []Sound,
            moved: []usize,
            releases: [][]const u8,
        },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/actor-audio-ownership-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "26ee1180d4cddf03dc7c4bdd3a7f0088faf4ac6af64f160ebbba2a3adc5e0f2b",
        corpus.results_sha256,
    );

    const Links = @import("../render/actor_links.zig").Links;
    const Capture = struct {
        allocator: std.mem.Allocator,
        actor_links: Links,
        removed_actors: []bool,
        sounds: []?[]const u8,
        released: std.ArrayList([]const u8) = .empty,

        pub fn releasePickupSound(self: *@This(), source: usize) void {
            const name = self.sounds[source] orelse return;
            self.released.append(self.allocator, name) catch unreachable;
            self.sounds[source] = null;
        }
    };

    const count = corpus.pickups.names.len;
    var capture: Capture = .{
        .allocator = a,
        .actor_links = try Links.init(a, 2, count),
        .removed_actors = try a.alloc(bool, count),
        .sounds = try a.alloc(?[]const u8, count),
    };

    @memset(capture.removed_actors, false);

    for (corpus.pickups.calls, capture.sounds, 0..) |call, *sound, source| {
        sound.* = call.name;
        capture.actor_links.move(source, 0);
    }

    for (corpus.pickups.moved) |source| {
        capture.actor_links.move(source, 1);
        capture.actor_links.move(source, 0);
    }

    enemy_session.releaseSectorPickupSounds(&capture, 0);
    try std.testing.expectEqualDeep(corpus.pickups.releases, capture.released.items);
    enemy_session.releaseSectorPickupSounds(&capture, 0);
    try std.testing.expectEqualDeep(corpus.pickups.releases, capture.released.items);
}

test "live collision dispatch wakes every enemy wrapper and preserves Sanchez gate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        executable_sha256: []const u8,
        contacts: []const struct {
            name: []const u8,
            seed: u32,
            last_random: u32,
            next_tick_before: u32,
            next_tick: u32,
            random: u32,
            enemy_random: u32,
            sanchez_enabled: bool,
        },
    };

    const fixture = (try std.json.parseFromSlice(
        Fixture,
        a,
        try read(a, "testdata/cmm-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        fixture.executable_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
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
    const source = for (session.targets, 0..) |target, index| {
        if (target != null) break index;
    } else return error.MissingOriginalEnemyPlacement;

    const original = session.targets[source].?;
    var effects_buffer: @import("../player/inventory.zig").EffectBuffer = undefined;
    var effects = @import("../player/inventory.zig").Effects.init(&effects_buffer);
    const cmm = @import("../script/cmm.zig");

    for (fixture.contacts) |entry| {
        const native = try cmm.resolve(entry.name);
        session.targets[source] = if (native == .object or native == .explosive_projectile_dispatch) null else original;

        if (session.targets[source]) |*target| {
            target.native = native;
            target.sanchez = native == .sanchez;
            target.next_tick = entry.next_tick_before;
        }

        session.actor_slots[source].?.logic_name = entry.name;
        session.actor_next_update[source] = @bitCast(entry.next_tick_before);
        session.contact_state = .{ .random = entry.seed, .last_enemy_random = entry.last_random };
        session.enemy_shared.sanchez_enabled = entry.sanchez_enabled;
        session.enemy_shared.entry_random = entry.last_random;

        var context = enemy_session.scriptContext(session, &effects, 0x10);
        try context.touch(session.actor_slots[source].?);
        try std.testing.expectEqual(
            entry.next_tick,
            @as(u32, @bitCast(session.actor_next_update[source])),
        );

        if (session.targets[source]) |target| try std.testing.expectEqual(
            entry.next_tick,
            target.next_tick,
        );

        try std.testing.expectEqual(entry.random, session.contact_state.random);
        try std.testing.expectEqual(entry.enemy_random, session.contact_state.last_enemy_random);
    }
}

test "player noise preserves radii recipient masks and synchronous order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        results_sha256: []const u8,
        cases: []const struct {
            layers: []f32,
            connected: []u16,
            bodies: []const struct { sector: usize, position: [3]f32, flags: u32, logic: bool },
            relinks: []usize,
            recipients: []usize,
            radius: f32,
        },
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        try read(a, "testdata/impact-noise-reference.json"),
        .{ .ignore_unknown_fields = true },
    );

    try std.testing.expectEqualStrings(
        "3077713caf82975c320c381a1f2fe21df9402d85af2ddb645c01ab6ced3b4234",
        fixture.value.results_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
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

    try enemy_session.preload(session, a);
    var sources: std.ArrayList(usize) = .empty;

    for (session.targets, session.actor_slots, 0..) |target, *slot, source| {
        if (slot.*) |*actor| {
            actor.secondary_flags = 0;
            session.syncActor(source);
        }

        if (target != null and sources.items.len < fixture.value.cases[0].bodies.len) try sources.append(a, source);
    }

    try std.testing.expectEqual(fixture.value.cases[0].bodies.len, sources.items.len);
    const saved = try a.alloc(@import("../player/target.zig").Target, sources.items.len);

    for (sources.items, saved) |source, *target| target.* = session.targets[source].?;

    var effects_buffer: @import("../player/inventory.zig").EffectBuffer = undefined;
    var effects = @import("../player/inventory.zig").Effects.init(&effects_buffer);

    for (fixture.value.cases) |case| {
        for (case.layers, 0..) |layer, sector| session.level.sectors[sector].layer = layer;

        session.enemy_visibility.lists[0] = try session.arena.allocator().dupe(u16, case.connected);
        session.player.sector = 0;
        session.player.position = .{
            .x = case.bodies[0].position[0],
            .y = 0,
            .z = case.bodies[0].position[2],
        };

        for (0..case.recipients.len + 1) |failure| {
            const unsupported: ?usize = if (failure == case.recipients.len) null else case.recipients[failure];

            if (unsupported) |source| if (std.mem.indexOfScalar(
                usize,
                case.recipients,
                source,
            ).? != failure) continue;

            for (sources.items) |source| session.actor_links.remove(source);

            for (sources.items, saved, case.bodies, 0..) |source, original, body, index| {
                session.targets[source] = original;
                const target = &session.targets[source].?;

                target.mode = 1;
                target.sanchez = false;
                target.anger = 7;
                target.fear = 0;
                target.next_tick = 777;
                session.actor_next_update[source] = 777;

                const actor = &session.actor_slots[source].?;

                actor.sector = body.sector;
                actor.position = .{
                    .x = body.position[0],
                    .y = body.position[1],
                    .z = body.position[2],
                };

                actor.secondary_flags = body.flags;
                actor.logic_name = if (body.logic) "BGY_New" else "";

                session.syncActor(source);

                if (unsupported == index) session.targets[source] = null;
            }

            for (case.relinks) |index| {
                const source = sources.items[index];
                const sector = case.bodies[index].sector;
                session.actor_links.move(source, (sector + 1) % case.layers.len);
                session.actor_links.move(source, sector);
            }

            session.contact_state.random = 0x742389ac;
            const result = enemy_session.playerNoise(session, a, &effects, case.radius, 0x83);

            if (unsupported != null) try std.testing.expectError(
                error.UnsupportedEnemyImpactRecipient,
                result,
            ) else try result;

            const prefix = case.recipients[0..failure];

            for (sources.items, 0..) |source, index| {
                if (unsupported == index) continue;

                var count: usize = 0;

                for (prefix) |recipient| if (recipient == index) {
                    count += 1;
                };

                try std.testing.expectEqual(
                    7 - @as(f32, @floatFromInt(count)),
                    session.targets[source].?.anger,
                );

                try std.testing.expectEqual(
                    @as(f32, @floatFromInt(count)),
                    session.targets[source].?.fear,
                );

                try std.testing.expectEqual(
                    @as(i32, if (count == 0) 777 else 0),
                    session.actor_next_update[source],
                );
            }

            var random: u32 = 0x742389ac;

            for (prefix) |_| _ = @import("../player/weapon.zig").randomNext(&random);

            try std.testing.expectEqual(random, session.contact_state.random);
        }
    }
}

test "live Hideout session schedules enemies and completes death playback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
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

    try enemy_session.preload(session, a);

    const Fixture = struct {
        victim_id: u32,
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        try read(a, "testdata/session-shot-reference.json"),
        .{ .ignore_unknown_fields = true },
    );

    const victim = for (session.objects.entries, 0..) |object, index| {
        if (object.id == fixture.value.victim_id) break index;
    } else return error.MissingOriginalEnemyPlacement;

    const costume = session.actor_slots[victim].?.costume;
    const pixels = try a.alloc(u8, 640 * 480);

    _ = try session.render(pixels, 0);
    try session.advance(a, &.{}, 50);
    var scheduled = false;

    for (session.targets) |slot| if (slot) |target| {
        scheduled = scheduled or target.ai.updated_at == session.animation_time;
    };

    try std.testing.expect(scheduled);
    try std.testing.expect(!session.removed_actors[victim]);
    try std.testing.expectEqual(@as(f32, 0), session.enemy_shared.killed_enemies);

    const actor = session.actor_slots[victim].?;
    try session.queued_hits.append(.{
        .target = victim,
        .count = 1,
        .input = .{
            .kind = 1,
            .damage = 100,
            .mass = 0.03,
            .speed = 1000,
            .pitch = 0,
            .yaw = 4096,
            .lateral = 0,
            .height = actor.height * 0.75,
            .shooter_position = .{ .x = session.player.position.x, .z = session.player.position.z },
        },
    });

    var selected_death = false;

    for (0..160) |_| {
        try session.advance(a, &.{}, 50);
        const target = session.targets[victim].?;
        selected_death = selected_death or target.dead;
        if (session.removed_actors[victim]) break;
    }

    try std.testing.expect(selected_death);
    try std.testing.expect(session.removed_actors[victim]);
    try std.testing.expectEqual(@as(f32, 1), session.enemy_shared.killed_enemies);

    var corpse_found = false;

    for (session.corpse_sources) |slot| if (slot) |source| {
        const corpse = session.actor_slots[source].?;
        if (corpse.costume == costume and corpse.secondary_flags == 0x800) corpse_found = true;
    };

    try std.testing.expect(corpse_found);
    _ = try session.render(pixels, session.animation_time);
}

test "left turn and strafe then walk toward Hideout road enemy keeps alerts live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
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
    const road_enemy = for (session.objects.entries, 0..) |object, index| {
        if (object.id == 0x2f07d) break index;
    } else return error.MissingOriginalEnemyPlacement;

    const dynamite = for (session.objects.entries, 0..) |object, index| {
        if (std.mem.eql(u8, object.name, "GDYNAM")) break index;
    } else return error.MissingOriginalDynamitePlacement;

    const pixels = try a.alloc(u8, 640 * 480);

    _ = try session.render(pixels, 0);
    var input: @import("../player/input.zig").State = .{ .previous_time = 1000 };
    input.key(75, true, 1000);

    var now: u32 = 1000;
    var strafe_ticks: ?usize = null;
    var walking = false;
    var acquired_player = false;
    const initial_health = session.inventory.health;
    const spawn_yaw: i16 = @intFromFloat(
        @round(@as(f64, session.spawn.rotation.y) / 0.02197261333473958),
    );

    for (0..600) |_| {
        if (strafe_ticks == null and session.player.yaw <= spawn_yaw - 0x1000) {
            input.key(75, false, now);
            input.key(30, true, now);
            strafe_ticks = 0;
        } else if (strafe_ticks) |ticks| {
            if (!walking) {
                strafe_ticks = ticks + 1;

                if (strafe_ticks.? == 60) {
                    input.key(30, false, now);
                    input.key(17, true, now);
                    walking = true;
                }
            }
        }

        now += 16;
        const packet = try input.sample(now, .{});
        try session.advance(a, &packet, 16);
        _ = try session.render(pixels, now);

        if (session.targets[road_enemy].?.ai.target) |target| {
            acquired_player = acquired_player or target == .player;
        }
    }

    try std.testing.expect(walking);
    try std.testing.expect(acquired_player);
    try std.testing.expect(session.player.position.x > 440);
    try std.testing.expect(
        session.inventory.health < initial_health or session.impact_state.next_mark != 0,
    );

    try std.testing.expect(session.actor_slots[dynamite] != null);
    try std.testing.expectEqual(
        @as(u32, 0),
        session.actor_slots[dynamite].?.secondary_flags & 0x40,
    );
}

test "map scenery and pickups receive sector removal before appended actors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        executable_sha256: []const u8,
        cases: []const struct {
            sector_flags: u32,
            actor_flags: u32,
            secondary_flags: u32,
            removed: bool,
        },
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        try read(a, "testdata/sector-removal-reference.json"),
        .{ .ignore_unknown_fields = true },
    );

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        fixture.value.executable_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
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
    const source = for (session.actor_slots, session.targets, 0..) |slot, target, index| {
        if (slot != null and target == null) break index;
    } else return error.MissingOriginalSceneryPlacement;

    const original = session.actor_slots[source].?;

    @memset(session.removed_actors, true);

    var effects_buffer: @import("../player/inventory.zig").EffectBuffer = undefined;
    var effects = @import("../player/inventory.zig").Effects.init(&effects_buffer);

    for (fixture.value.cases) |case| {
        session.actor_slots[source] = original;
        session.actor_slots[source].?.flags = case.actor_flags;
        session.actor_slots[source].?.secondary_flags = case.secondary_flags;
        session.scene.sectors[original.sector].flags = case.sector_flags;
        session.removed_actors[source] = false;

        session.syncActor(source);
        try enemy_session.tick(session, a, null, &effects);

        try std.testing.expectEqual(case.removed, session.removed_actors[source]);
        try std.testing.expectEqual(!case.removed, session.source_to_entry[source] != null);
    }

    var appended = original;

    appended.flags = 0;
    appended.secondary_flags = 0;
    session.scene.sectors[original.sector].flags = 0x01000000;

    const dynamic_source = try enemy_session.appendActor(session, appended, null);
    try enemy_session.tick(session, a, null, &effects);
    try std.testing.expect(!session.removed_actors[dynamic_source]);
    try @import(
        "dynamic.zig",
    ).tick(session, a, &effects, @import("dynamic.zig").firstActor(session));

    try std.testing.expect(session.removed_actors[dynamic_source]);
    try std.testing.expect(session.source_to_entry[dynamic_source] == null);
}

test "corpse construction follows independent outer resource after restore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Corpse = struct {
        outer: []const u8,
        flags: u32,
        secondary_flags: u32,
        position_bits: [3]u32,
        playback: [8]i64,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []const struct { outer: []const u8, corpse: ?Corpse, cursor: usize },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/projectile-enemy-corpse-outer.json"),
        .{},
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "0cffa97704c458b25c12f39e8b244348c3753dc0155f9ca89f7da3c92b508b5b",
        corpus.results_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive = try lab.Archive.init(try read(a, path));
    var startup = try @import("../campaign.zig").Startup.prepare(a, archive, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    for (corpus.cases) |case| {
        const session = try Session.open(
            a,
            @import("../render/test_workspace.zig").get(),
            std.testing.io,
            path,
            archive,
            &startup,
        );

        defer session.deinit(a);

        session.animation_time = 1000;
        const source = (try enemy_session.spawnItem(
            session,
            "BGY1",
            .{ .position = .{ .x = 100, .y = 0, .z = 0 }, .sector = session.player.sector },
        )).?;

        session.actor_slots[source].?.logic_resource = case.outer;
        session.targets[source].?.drop_item = "";

        const old_count = session.actor_slots.len;
        try enemy_session.finishDeath(session, a, source);

        try std.testing.expect(session.removed_actors[source]);
        try std.testing.expectEqual(case.cursor, session.corpse_pool.cursor);

        if (case.corpse) |expected| {
            try std.testing.expectEqual(old_count + 1, session.actor_slots.len);
            const corpse = session.actor_slots[session.corpse_sources[case.cursor].?].?;

            try std.testing.expectEqualStrings(expected.outer, corpse.logic_resource.?);
            try std.testing.expect(
                corpse.costume == try enemy_session.costume(session, expected.outer),
            );

            try std.testing.expectEqual(expected.flags, corpse.flags);
            try std.testing.expectEqual(expected.secondary_flags, corpse.secondary_flags);
            try std.testing.expectEqualDeep(
                expected.position_bits,
                [3]u32{
                    @bitCast(corpse.position.x),
                    @bitCast(corpse.position.y),
                    @bitCast(corpse.position.z),
                },
            );

            try std.testing.expectEqual(
                @as(u32, @intCast(expected.playback[3])),
                corpse.choreography,
            );

            try std.testing.expectEqual(@as(u32, @intCast(expected.playback[5])), corpse.frame);
        } else {
            try std.testing.expectEqual(old_count, session.actor_slots.len);
            try std.testing.expect(session.corpse_sources[case.cursor] == null);
        }
    }
}
