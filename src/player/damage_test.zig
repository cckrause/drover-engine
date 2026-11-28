//! Damage to the player: falls, drowning, crushing, the feedback and the rounding.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const PlayerFlags = @import("flags.zig").PlayerFlags;
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const level_module = @import("../assets/level.zig");
const player_audio = @import("../audio/player.zig");
const camera = @import("../render/backends/software/camera.zig");
const damage_flash = @import("../render/damage_flash.zig");
const scene_module = @import("../render/scene.zig");
const choreography = @import("choreography.zig");
const damage = @import("damage.zig");
const input = @import("input.zig");
const inventory_module = @import("inventory.zig");
const movement = @import("movement.zig");
const bits = @import("../util/bits.zig");

const MovementState = struct {
    sector: usize,
    position: [3]u32,
    velocity: [3]u32,
    angles: [3]i16,
    eye_height: u32,
    body_height: u32,
    floor_cache: u32,
    energy: u32,
    head_bob: u32,
    stride: u32,
    flags: u32,
    pitch_accumulator: i32,

    fn read(player: *const movement.Player, look: *const input.LookState) MovementState {
        return .{
            .sector = player.sector,
            .position = .{
                @bitCast(player.position.x),
                @bitCast(player.position.y),
                @bitCast(player.position.z),
            },
            .velocity = .{
                @bitCast(player.velocity.x),
                @bitCast(player.velocity.y),
                @bitCast(player.velocity.z),
            },
            .angles = .{ player.pitch, player.yaw, player.head_yaw },
            .eye_height = @bitCast(player.eye_height),
            .body_height = @bitCast(player.body_height),
            .floor_cache = @bitCast(player.floor_cache),
            .energy = @bitCast(player.energy),
            .head_bob = @bitCast(player.head_bob),
            .stride = @bitCast(player.stride),
            .flags = bits.word(bits.only(player.flags, .{ .on_ground = true, .dying = true, .jumped = true, .dead = true })),
            .pitch_accumulator = look.pitch_accumulator,
        };
    }

    fn hash(self: MovementState, digest: *std.crypto.hash.sha2.Sha256) void {
        for (self.position ++ self.velocity) |word| hashWord(digest, word);

        for (self.angles) |angle| hashWord(digest, @bitCast(@as(i32, angle)));

        for ([_]u32{
            self.eye_height,
            self.body_height,
            self.floor_cache,
            self.energy,
            self.head_bob,
            self.stride,
            self.flags,
            @bitCast(self.pitch_accumulator),
        }) |word| hashWord(digest, word);
    }
};

const DamageState = struct {
    health_bits: u32,
    damage_stat: i32,
    flash: i32,
    flash_time: u32,
    flash_red: i32,
    events: []const [4]u32,
};

const Reference = struct {
    cases: []const Case,
    dead_frames: []const struct { slots: []const [3]i32, state: MovementState },

    const Case = struct { name: []const u8, movement: MovementState, state: DamageState };
};

fn readAsset(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

fn hashWord(digest: *std.crypto.hash.sha2.Sha256, word: u32) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, word, .little);
    digest.update(&encoded);
}

fn soundEvent(effect: inventory_module.Effect) ![4]u32 {
    const sound = switch (effect) {
        .sound => |value| value,
        else => return error.UnexpectedDamageMessage,
    };

    const id: u32 = for ([_][]const u8{
        "JAJUMP.WAV",
        "LAND.WAV",
        "LANDLITE.WAV",
        "HITHEAD.WAV",
        "TIRED.WAV",
        "FLOOR.WAV",
        "CRUNCH.WAV",
        "JADIE.WAV",
        "CHOKE.WAV",
        "WATERDIE.WAV",
        "SHRIEK.WAV",
        "CRUSH.WAV",
        "SPLAT.WAV",
    }, 1..) |name, index| {
        if (std.ascii.eqlIgnoreCase(name, sound.basename)) break @intCast(index);
    } else return error.UnexpectedDamageSound;

    try std.testing.expect(sound.position == null and sound.sector == null);

    return .{ id, @bitCast(sound.priority.?), @bitCast(sound.volume.?), bits.word(sound.flags.?) };
}

fn checkEnvironmentReference(fixture_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        fixture_path,
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const Bubble = struct {
        sector: usize,
        position: [3]u32,
        count: i32,
    };

    const Fixture = struct { cases: []const struct {
        name: []const u8,
        config: struct {
            elapsed: f32,
            seconds: f32,
            impact: f32,
            surface: u32,
            health: f32,
            flags: u32,
            sheriff: u8 = 0,
            damage_multiplier: f32 = 1,
            seed: u32 = 0x742389ac,
            position: [3]f32,
            yaw: i16,
            crush_required: f32 = 0,
            crush_body: f32 = 0,
        },
        state: struct {
            health_bits: u32,
            damage_stat: i32,
            flash: i32,
            flash_time: u32,
            flash_red: i32,
            random: u32,
            events: []const [4]u32,
            bubbles: []const Bubble,
        },
    } };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    const runtime_module = @import("../script/runtime.zig");
    const Capture = struct {
        values: [8]Bubble = undefined,
        count: usize = 0,

        fn spawn(
            raw: *anyopaque,
            _: *runtime_module.Context,
            sector: usize,
            position: level_module.Vec3,
            count: i32,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));

            self.values[self.count] = .{
                .sector = sector,
                .position = .{ @bitCast(position.x), @bitCast(position.y), @bitCast(position.z) },
                .count = count,
            };

            self.count += 1;
        }
    };

    var archives: [2]lab.Archive = undefined;

    for ([_][]const u8{ "OUTLAWS.LAB", "OLOBJ.LAB" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}", .{name});
        archive.* = try lab.Archive.init(
            try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)),
        );
    }

    var item = try Item.parse(a, try archives[1].find("CIDJAMES.ITM", 0x4954454d));
    const physics = try movement.Physics.parse(try archives[0].find("AIR.PHY", 0x50485953));
    const audio_config = try player_audio.Config.fromItem(&item);
    const angles = camera.Angles.init();
    var effects_buffer: inventory_module.EffectBuffer = undefined;
    var effects = inventory_module.Effects.init(&effects_buffer);

    for (fixture.value.cases) |case| {
        errdefer std.debug.print("drowning case {s}\n", .{case.name});
        var player = try movement.Player.init(
            &item,
            physics,
            .{
                .sector = 0,
                .position = .{
                    .x = case.config.position[0],
                    .y = case.config.position[1],
                    .z = case.config.position[2],
                },
                .rotation = .{ .x = 0, .y = 0, .z = 0 },
            },
        );

        player.yaw = case.config.yaw;

        var inventory: inventory_module.Inventory = .{
            .health = case.config.health,
            .player_flags = bits.from(PlayerFlags, case.config.flags),
            .sheriff_active = case.config.sheriff != 0,
        };

        var native: @import("../script/cmm.zig").ContactState = .{};

        native.random = case.config.seed;

        var captured: Capture = .{};
        var runtime: runtime_module.Context = .{
            .inventory = &inventory,
            .pickups = &.{},
            .removed = &.{},
            .effects = &effects,
            .contact_state = &native,
            .now_ms = 1000,
            .bubble_host = .{ .context = &captured, .spawn = Capture.spawn },
        };

        var sound_state: player_audio.State = .{};
        var context: player_audio.Context = .{
            .config = &audio_config,
            .state = &sound_state,
            .effects = &effects,
        };

        var flash: damage_flash.State = .{};

        effects.clearRetainingCapacity();
        const message = try damage.applyMovementWithEnvironment(
            .{ .multiplier = case.config.damage_multiplier },
            &inventory,
            case.config.impact,
            case.config.surface,
            case.config.seconds,
            &flash,
            &context,
            1000,
            .{
                .elapsed = case.config.elapsed,
                .crush_required = case.config.crush_required,
                .crush_body = case.config.crush_body,
                .runtime = &runtime,
                .player = &player,
                .angles = &angles,
            },
        );

        try std.testing.expectEqual(case.state.health_bits, @as(u32, @bitCast(inventory.health)));
        try std.testing.expectEqual(case.state.damage_stat, inventory.statistics.damage);
        try std.testing.expectEqual(case.state.flash, flash.strength);
        try std.testing.expectEqual(case.state.flash_time, flash.last_ms);
        try std.testing.expectEqual(case.state.flash_red, flash.alpha);
        try std.testing.expectEqual(case.state.random, native.random);
        try std.testing.expectEqualDeep(case.state.bubbles, captured.values[0..captured.count]);
        try std.testing.expectEqual(case.state.events.len, effects.items.len);

        for (case.state.events, effects.items) |expected, effect| try std.testing.expectEqualSlices(
            u32,
            &expected,
            &(try soundEvent(effect)),
        );

        try std.testing.expectEqual(
            if (inventory.health == 0) @as(
                ?i32,
                if (case.config.crush_body < case.config.crush_required) 51 else if (case.config.elapsed > 30) 49 else if (case.config.surface != 0) 47 else 45,
            ) else null,
            message,
        );
    }
}

test "fall damage threshold health feedback and dead movement" {
    const a = std.testing.allocator;
    const raw_system = try readAsset("inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB");
    defer a.free(raw_system);
    const raw_objects = try readAsset("inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB");
    defer a.free(raw_objects);
    const system = try lab.Archive.init(raw_system);
    const objects = try lab.Archive.init(raw_objects);
    var item = try Item.parse(a, try objects.find("CIDJAMES.ITM", 0x4954454d));
    defer item.deinit();
    const physics = try movement.Physics.parse(try system.find("AIR.PHY", 0x50485953));
    const audio_config = try player_audio.Config.fromItem(&item);
    const damage_config = try damage.Config.fromItem(&item);
    const chors = choreography.Table.fromItem(&item);
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};

    sectors[0].friction = 1;
    sectors[0].elasticity = 0.2;
    sectors[0].ceiling.height = 30;
    sectors[0].floor_sound = "FLOOR.WAV";
    sectors[0].vadjoin = -1;

    var level = std.mem.zeroInit(level_module.Level, .{ .arena = std.heap.ArenaAllocator.init(a) });
    level.sectors = &sectors;

    var scene_sectors = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
    var collision_check: u32 = 0;
    var scene = std.mem.zeroInit(
        scene_module.Scene,
        .{ .arena = std.heap.ArenaAllocator.init(a), .collision_check = &collision_check },
    );

    scene.sectors = &scene_sectors;

    const angles = camera.Angles.init();
    const spawn: level_module.Spawn = .{
        .sector = 0,
        .position = .{ .x = 0, .y = 0.01, .z = 0 },
        .rotation = .{ .x = 0, .y = 0, .z = 0 },
    };

    var effects_buffer: inventory_module.EffectBuffer = undefined;
    var effects = inventory_module.Effects.init(&effects_buffer);
    const fixture_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/player-damage-reference.json",
        a,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    defer if (fixture_bytes) |bytes| a.free(bytes);
    const fixture = if (fixture_bytes) |bytes| try std.json.parseFromSlice(
        Reference,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) else null;

    defer if (fixture) |value| value.deinit();

    const Case = struct {
        name: []const u8,
        velocity: f32,
        health: f32 = 10,
        sheriff: bool = false,
        multiplier: ?f32 = null,
        flags: u32 = 0,
    };

    const cases = [_]Case{
        .{ .name = "below_threshold", .velocity = -44.999996185302734 },
        .{ .name = "threshold", .velocity = -45 },
        .{ .name = "above_threshold", .velocity = -45.000003814697266 },
        .{ .name = "light_damage", .velocity = -46 },
        .{ .name = "sheriff_damage", .velocity = -46, .sheriff = true },
        .{ .name = "heavy_damage", .velocity = -70 },
        .{ .name = "half_stat_even_zero", .velocity = -47.5 },
        .{ .name = "half_stat_even_two", .velocity = -52.5 },
        .{ .name = "half_stat_even_two_lower", .velocity = -57.5 },
        .{
            .name = "sheriff_fractional_multiplier",
            .velocity = -57.125,
            .sheriff = true,
            .multiplier = 1.3,
        },
        .{ .name = "no_stored_health_change", .velocity = -45.000003814697266, .multiplier = 0.01 },
        .{ .name = "immune_player_flag", .velocity = -100, .flags = 0x10000000 },
        .{ .name = "sheriff_heavy", .velocity = -100, .sheriff = true },
        .{ .name = "exactly_lethal", .velocity = -95 },
        .{ .name = "lethal_damage", .velocity = -100 },
        .{ .name = "low_health_lethal", .velocity = -46, .health = 0.1 },
        .{ .name = "sheriff_lethal", .velocity = -245, .sheriff = true },
    };

    var digest = std.crypto.hash.sha2.Sha256.init(.{});

    for (cases) |case| {
        var player = try movement.Player.init(&item, physics, spawn);

        player.velocity.y = case.velocity;
        player.flags = bits.from(PlayerFlags, case.flags);

        var inventory: inventory_module.Inventory = .{
            .health = case.health,
            .sheriff_active = case.sheriff,
            .player_flags = bits.from(PlayerFlags, case.flags),
        };

        var look: input.LookState = .{};
        var sound_state: player_audio.State = .{};
        var context: player_audio.Context = .{
            .config = &audio_config,
            .state = &sound_state,
            .effects = &effects,
        };

        effects.clearRetainingCapacity();

        var flash: damage_flash.State = .{};
        var packet: input.Packet = .{};

        packet.entries[23] = .{ .value = 100, .flags = .{ .unscaled = true } };
        const control = look.controlForLife(&packet, true);
        try player.tickWithAudio(
            &level,
            &scene,
            .{ .entries = &.{} },
            &angles,
            control,
            &look,
            0.016,
            &context,
        );

        inventory.player_flags = player.flags;
        _ = try damage.applyMovement(
            .{ .multiplier = case.multiplier orelse damage_config.multiplier },
            &inventory,
            player.impact,
            0,
            0.016,
            &flash,
            &context,
            1000,
        );

        if (player.choreography_input) |value| _ = choreography.select(&player.flags, chors, value);

        const motion = MovementState.read(&player, &look);
        motion.hash(&digest);

        for ([_]u32{
            @bitCast(inventory.health),
            @bitCast(inventory.statistics.damage),
            @bitCast(flash.strength),
            flash.last_ms,
            flash.alpha,
        }) |word| hashWord(&digest, word);

        hashWord(&digest, @intCast(effects.items.len));
        var events: [8][4]u32 = undefined;

        for (effects.items, 0..) |effect, index| {
            events[index] = try soundEvent(effect);
            for (events[index]) |word| hashWord(&digest, word);
        }

        if (fixture) |reference| {
            const expected = for (reference.value.cases) |candidate| {
                if (std.mem.eql(u8, candidate.name, case.name)) break candidate;
            } else return error.MissingOriginalDamageCase;

            std.testing.expectEqual(expected.movement.flags, bits.word(player.flags)) catch |err| {
                std.debug.print("reference damage flags case {s}\n", .{case.name});
                return err;
            };

            var expected_motion = expected.movement;
            expected_motion.flags = bits.word(bits.only(bits.from(PlayerFlags, expected_motion.flags), .{ .on_ground = true, .dying = true, .jumped = true, .dead = true }));
            std.testing.expectEqualDeep(expected_motion, motion) catch |err| {
                std.debug.print("reference damage movement case {s}\n", .{case.name});
                return err;
            };

            const actual = DamageState{
                .health_bits = @bitCast(inventory.health),
                .damage_stat = inventory.statistics.damage,
                .flash = flash.strength,
                .flash_time = flash.last_ms,
                .flash_red = flash.alpha,
                .events = events[0..effects.items.len],
            };

            std.testing.expectEqualDeep(expected.state, actual) catch |err| {
                std.debug.print("reference damage feedback case {s}\n", .{case.name});
                return err;
            };
        }
    }

    try std.testing.expectEqualStrings(
        "a90fde60887c738cb4079af83be63e83effb1f4547a6ddf842f99abdc00af873",
        &std.fmt.bytesToHex(digest.finalResult(), .lower),
    );

    var player = try movement.Player.init(&item, physics, spawn);

    player.position.y = 0;
    player.velocity.y = -100;
    player.eye_height = @bitCast(@as(u32, 1081752944));
    player.floor_cache = 0;
    player.stride = 7.5;
    player.stride_side = true;
    player.last_floor_sector = 0;
    player.flags = .{ .on_ground = true, .pose = .{ .stand = true }, .dead = true };
    player.dead = true;

    var look: input.LookState = .{};
    digest = std.crypto.hash.sha2.Sha256.init(.{});

    for (1..45) |index| {
        var packet: input.Packet = .{};
        packet.entries[23] = .{ .value = 100, .flags = .{ .unscaled = true } };

        for ([_]usize{ 0, 2, 10, 11 }) |slot| packet.entries[slot] = .{ .value = 5120, .flags = .{} };

        const control = look.controlForLife(&packet, false);
        try player.tick(&level, &scene, .{ .entries = &.{} }, &angles, control, &look, 0.016);

        if (player.choreography_input) |value| _ = choreography.select(&player.flags, chors, value);

        const actual = MovementState.read(&player, &look);
        actual.hash(&digest);

        if (fixture) |reference| {
            var expected = reference.value.dead_frames[index].state;
            std.testing.expectEqual(expected.flags, bits.word(player.flags)) catch |err| {
                std.debug.print("reference dead player flags frame {d}\n", .{index});
                return err;
            };

            expected.flags = bits.word(bits.only(bits.from(PlayerFlags, expected.flags), .{ .on_ground = true, .dying = true, .jumped = true, .dead = true }));
            std.testing.expectEqualDeep(expected, actual) catch |err| {
                std.debug.print("reference dead player frame {d}\n", .{index});
                return err;
            };
        }
    }

    try std.testing.expectEqualStrings(
        "b9180fd6d41caf2b1fa686f64e02c606c2e888e89bf4904f648a02b3746c7211",
        &std.fmt.bytesToHex(digest.finalResult(), .lower),
    );
}

test "drowning health feedback and synchronous bubble origin" {
    try checkEnvironmentReference("testdata/player-drowning-reference.json");
}

test "crushing damage precedence feedback and rounding" {
    try checkEnvironmentReference("testdata/player-crush-reference.json");
}

test "solid ceiling crushing records and compressed player motion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/player-crush-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const Fixture = struct {
        movement_cases: []const struct {
            config: struct { ceiling: f32, sector_flags: u32 },
            frames: []const struct {
                movement: MovementState,
                state: struct {
                    health_bits: u32,
                    damage_stat: i32,
                    flash: i32,
                    flash_time: u32,
                    flash_red: i32,
                    events: []const [4]u32,
                    requests: []const [6]u32,
                },
            },
        },
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    var archives: [2]lab.Archive = undefined;

    for ([_][]const u8{ "OUTLAWS.LAB", "OLOBJ.LAB" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}", .{name});
        archive.* = try lab.Archive.init(
            try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)),
        );
    }

    var item = try Item.parse(a, try archives[1].find("CIDJAMES.ITM", 0x4954454d));
    const physics = try movement.Physics.parse(try archives[0].find("AIR.PHY", 0x50485953));
    const audio_config = try player_audio.Config.fromItem(&item);
    const damage_config = try damage.Config.fromItem(&item);
    const angles = camera.Angles.init();
    var sectors = [_]level_module.Sector{std.mem.zeroes(level_module.Sector)};

    sectors[0].friction = 1;
    sectors[0].elasticity = 0.2;
    sectors[0].floor_sound = "FLOOR.WAV";
    sectors[0].vadjoin = -1;

    var level = std.mem.zeroInit(level_module.Level, .{ .arena = std.heap.ArenaAllocator.init(a) });
    level.sectors = &sectors;

    var scene_sectors = [_]scene_module.SectorState{std.mem.zeroes(scene_module.SectorState)};
    var collision_check: u32 = 0;
    var scene = std.mem.zeroInit(
        scene_module.Scene,
        .{ .arena = std.heap.ArenaAllocator.init(a), .collision_check = &collision_check },
    );

    scene.sectors = &scene_sectors;

    var effects_buffer: inventory_module.EffectBuffer = undefined;
    var effects = inventory_module.Effects.init(&effects_buffer);

    for (fixture.value.movement_cases) |case| {
        sectors[0].ceiling.height = case.config.ceiling;
        bits.setWord(&scene_sectors[0].flags, case.config.sector_flags);

        var player = try movement.Player.init(
            &item,
            physics,
            .{
                .sector = 0,
                .position = .{ .x = 0, .y = 0, .z = 0 },
                .rotation = .{ .x = 0, .y = 0, .z = 0 },
            },
        );

        var inventory: inventory_module.Inventory = .{ .health = 10 };
        var flash: damage_flash.State = .{};
        var sound_state: player_audio.State = .{};
        var audio: player_audio.Context = .{
            .config = &audio_config,
            .state = &sound_state,
            .effects = &effects,
        };

        var look: input.LookState = .{};

        effects.clearRetainingCapacity();

        for (case.frames, 0..) |frame, frame_index| {
            errdefer std.debug.print(
                "crush ceiling{d} flags{x} frame{d}\n",
                .{ case.config.ceiling, case.config.sector_flags, frame_index },
            );

            var packet: input.Packet = .{};

            packet.entries[23] = .{ .value = 100, .flags = .{ .unscaled = true } };
            try player.tickWithAudio(
                &level,
                &scene,
                .{ .entries = &.{} },
                &angles,
                look.control(&packet),
                &look,
                0.016,
                &audio,
            );

            _ = try damage.applyMovementWithEnvironment(
                damage_config,
                &inventory,
                player.impact,
                player.sector_damage,
                0.016,
                &flash,
                &audio,
                1000,
                .{ .crush_required = player.crush_required, .crush_body = player.crush_body },
            );

            var expected_motion = frame.movement;
            expected_motion.flags = bits.word(bits.only(bits.from(PlayerFlags, expected_motion.flags), .{ .on_ground = true, .dying = true, .jumped = true, .dead = true }));
            try std.testing.expectEqualDeep(expected_motion, MovementState.read(&player, &look));

            if (frame.state.requests.len != 0) {
                const request = frame.state.requests[frame.state.requests.len - 1];
                try std.testing.expectEqual(request[4], @as(u32, @bitCast(player.crush_required)));
                try std.testing.expectEqual(request[5], @as(u32, @bitCast(player.crush_body)));
            } else try std.testing.expectEqual(@as(f32, 0), player.crush_required);

            try std.testing.expectEqual(
                frame.state.health_bits,
                @as(u32, @bitCast(inventory.health)),
            );

            try std.testing.expectEqual(frame.state.damage_stat, inventory.statistics.damage);
            try std.testing.expectEqual(frame.state.flash, flash.strength);
            try std.testing.expectEqual(frame.state.flash_time, flash.last_ms);
            try std.testing.expectEqual(frame.state.flash_red, flash.alpha);
            try std.testing.expectEqual(frame.state.events.len, effects.items.len);

            for (frame.state.events, effects.items) |expected, effect| try std.testing.expectEqualSlices(u32, &expected, &(try soundEvent(effect)));
        }
    }
}
