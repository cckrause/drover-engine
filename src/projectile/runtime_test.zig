//! Projectiles: launch, contact damage, deferred particles, radial damage, movement and their save records.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const runtime = @import("runtime.zig");
const Actor = @import("../render/objects.zig").Actor;
const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;
const Angles = @import("../render/backends/software/camera.zig").Angles;
const Vec3 = @import("../assets/level.zig").Vec3;

fn point(value: [3]f32) Vec3 {
    return .{ .x = value[0], .y = value[1], .z = value[2] };
}

fn bits(value: Vec3) [3]u32 {
    return .{ @bitCast(value.x), @bitCast(value.y), @bitCast(value.z) };
}

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

test "projectile launch matches the reference float stores and RNG" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Input = struct {
        item: []const u8,
        fraction: f32,
        rate: f32,
        position: [3]f32,
        velocity: [3]f32,
        height: f32,
        pitch: i16,
        yaw: i16,
        seed: u32,
    };

    const Result = struct {
        position_bits: [3]u32,
        velocity_bits: [3]u32,
        rotation_bits: [3]u32,
        flags: u32,
        held: bool,
        random: u32,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        launches: []struct { config: Input, result: Result },
    };

    const json = try read(a, "testdata/projectiles-reference.json");
    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        json,
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "912a7a1dbd8cbb1579ec3d5ce2f93a1693f8e980cc52affc207fdbc96b22f298",
        corpus.results_sha256,
    );

    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    const angles = Angles.init();

    for (corpus.launches, 0..) |case, index| {
        errdefer std.debug.print("projectile launch case{d}\n", .{index});
        const input = case.config;
        var path: [64]u8 = undefined;
        var item = try Item.parse(
            a,
            try archive.find(try std.fmt.bufPrint(&path, "{s}.ITM", .{input.item}), 0),
        );

        const config = try runtime.Config.load(a, &item, input.item);
        var actor: Actor = .{
            .sector = 0,
            .position = .{ .x = 0, .y = 0, .z = 0 },
            .yaw = 0,
            .flags = 0x8000014b,
            .secondary_flags = 0,
            .scale_x = 1,
            .scale_y = 1,
            .height = 2,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };

        var state: runtime.State = .{
            .config = &config,
            .descriptor = .{
                .kind = if (std.mem.eql(u8, input.item, "PKNIFE")) .knife else .explosive,
                .item = input.item,
                .owner = 0,
                .origin = point(input.position),
                .sector = 0,
                .pitch = input.pitch,
                .yaw = input.yaw,
                .damage = 0,
                .mass = 0,
                .rate = input.rate,
                .range = 0,
            },
        };

        var random = input.seed;
        const owner: runtime.Owner = .{
            .source = 0,
            .position = point(input.position),
            .sector = 0,
            .height = input.height,
            .velocity = point(input.velocity),
            .pitch = input.pitch,
            .yaw = input.yaw,
        };

        try runtime.launch(&actor, &state, owner, input.fraction, &angles, &random);
        const actual: Result = .{
            .position_bits = bits(actor.position),
            .velocity_bits = bits(state.velocity),
            .rotation_bits = bits(state.rotation),
            .flags = actor.flags,
            .held = state.held,
            .random = random,
        };

        try std.testing.expectEqualDeep(case.result, actual);
    }
}

test "player scheduler writes the later knife contact residue" {
    const movement = @import("../player/movement.zig");
    const input = @import("../player/input.zig");
    const Level = @import("../assets/level.zig");
    const Scene = @import("../render/scene.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct {
        raw_query: [30]u32,
        player_config: struct { position: [3]f32, friction: f32 = 1 },
        player_input: []const [3]i32,
    };

    const cases = (try std.json.parseFromSlice(
        []Case,
        a,
        try read(a, "testdata/projectile-player-stack.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    const system = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"));
    const objects = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var item = try Item.parse(a, try objects.find("CIDJAMES.ITM", 0));
    const physics = try movement.Physics.parse(try system.find("AIR.PHY", 0));
    const angles = Angles.init();

    for (cases) |case| {
        var sector = std.mem.zeroes(Level.Sector);

        sector.vadjoin = -1;
        sector.gravity = -50;
        sector.friction = case.player_config.friction;
        sector.elasticity = 0.2;
        sector.ceiling.height = 30;

        var level: Level.Level = undefined;
        level.sectors = (&sector)[0..1];

        var sector_state = std.mem.zeroes(Scene.SectorState);
        var scene: Scene.Scene = undefined;

        scene.sectors = (&sector_state)[0..1];
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;

        var player = try movement.Player.init(
            &item,
            physics,
            .{
                .sector = 0,
                .position = point(case.player_config.position),
                .rotation = .{ .x = 0, .y = 0, .z = 0 },
            },
        );

        var packet: input.Packet = .{};

        packet.entries[23] = .{ .value = 100, .flags = 0x20 };

        for (case.player_input) |slot| packet.entries[
            @intCast(
                slot[0],
            )
        ] = .{ .value = @intCast(slot[1]), .flags = @intCast(slot[2]) };

        var look: input.LookState = .{};
        const control = look.control(&packet);

        try player.tick(&level, &scene, .{ .entries = &.{} }, &angles, control, &look, 0.2);
        try std.testing.expectEqualDeep(
            [4]?u32{
                case.raw_query[7],
                case.raw_query[10],
                case.raw_query[11],
                case.raw_query[12],
            },
            player.contact_residue.words,
        );
    }
}

test "knife contact damage and deferred particle transforms match the reference" {
    const shooting = @import("../player/shooting.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Input = struct {
        damage: f32,
        origin: [3]f32,
        raw: [3]f32,
        height: f32,
        yaw: i16,
        flags: u32,
    };

    const Message = struct {
        target: u32,
        kind: u32,
        damage_bits: u32,
        mass_bits: u32,
        speed_bits: u32,
        yaw: i16,
        pitch: i16,
        position_bits: [3]u32,
        lateral_bits: u32,
        height_bits: u32,
    };

    const Visual = struct { kind: []const u8, sector: usize, count: u32, position_bits: [3]u32 };
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { inputs: []Input, messages: []Message, visuals: []Visual },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/projectile-impact-reference.json"),
        .{},
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "3729bd8d756c84c281020754e73020be173b8938c0d26e34d36b205e2e59f9e8",
        corpus.results_sha256,
    );

    const angles = Angles.init();

    for (corpus.cases) |case| {
        var pending: ?shooting.PendingHit = null;

        for (case.inputs) |input| {
            const damage: shooting.DamageInput = .{
                .kind = 2,
                .damage = input.damage,
                .mass = 0.5,
                .speed = 100,
                .pitch = 0,
                .yaw = input.yaw,
                .lateral = 1.5,
                .height = input.height,
            };

            const hit: shooting.ActorHit = .{
                .index = 20,
                .position = point(input.raw),
                .lateral = 1.5,
                .height = input.height,
                .distance = input.raw[2],
            };

            if (pending) |*value| value.add(
                &angles,
                damage,
                hit,
            ) else pending = shooting.PendingHit.init(20, &angles, damage, hit);

            pending.?.position.x = @floatCast(@as(f64, pending.?.position.x) + input.raw[0]);

            if (input.flags & 0x10 == 0) {
                const visual = if (input.flags & 0x4180 != 0) &pending.?.blood else &pending.?.dust;
                visual.add(
                    &angles,
                    point(input.origin),
                    point(input.raw),
                    input.yaw,
                    73,
                    3,
                    input.flags & 0x4180 == 0,
                );
            }
        }

        const value = pending.?;
        const damage = value.damageInput();

        try std.testing.expectEqualDeep(
            case.messages[0],
            Message{
                .target = 20,
                .kind = damage.kind,
                .damage_bits = @bitCast(damage.damage),
                .mass_bits = @bitCast(damage.mass),
                .speed_bits = @bitCast(damage.speed),
                .yaw = damage.yaw,
                .pitch = damage.pitch,
                .position_bits = bits(value.messagePosition()),
                .lateral_bits = @bitCast(damage.lateral),
                .height_bits = @bitCast(damage.height),
            },
        );

        for (case.visuals) |expected| {
            const visual = if (std.mem.eql(u8, expected.kind, "blood")) value.blood else value.dust;
            try std.testing.expectEqual(expected.sector, visual.sector);
            try std.testing.expectEqual(expected.count, @as(u32, @bitCast(visual.count)));
            try std.testing.expectEqualDeep(expected.position_bits, bits(visual.average()));
        }

        if (case.visuals.len == 0) try std.testing.expect(
            value.blood.count == 0 and value.dust.count == 0,
        );
    }
}

test "projectile radial damage and aggregation match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Input = struct {
        origin: [3]f32,
        position: [3]f32,
        height: f32,
        radius: f32,
        seed: u32,
    };

    const Result = struct {
        damage_bits: [3]u32,
        angles: [2]i16,
        contact_bits: [2]u32,
        position_bits: [3]u32,
        random: u32,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { config: Input, result: Result },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/projectile-radial-reference.json"),
        .{},
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "41e8eb788d953019a94251d81eb788fcd72d7bf3ae34d460039e36927cc19ff0",
        corpus.results_sha256,
    );

    const archive = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"));
    var item = try Item.parse(a, try archive.find("PDYNAM.ITM", 0));
    const config = try runtime.Config.load(a, &item, "PDYNAM");

    for (corpus.cases) |case| {
        const input = case.config;
        const blast = runtime.blast(
            &config,
            point(input.origin),
            .{
                .position = point(input.position),
                .sector = 0,
                .height = input.height,
                .radius = input.radius,
                .flags = 0,
                .secondary_flags = 0x10,
            },
        );

        try std.testing.expectEqualDeep(
            case.result.damage_bits,
            [3]u32{
                @bitCast(blast.damage.damage),
                @bitCast(@as(f32, 1)),
                @bitCast(@as(f32, @floatCast(@as(f64, blast.damage.mass) * blast.damage.speed))),
            },
        );

        try std.testing.expectEqualDeep(
            case.result.angles,
            [2]i16{ blast.damage.pitch, blast.damage.yaw },
        );

        try std.testing.expectEqualDeep(
            case.result.contact_bits,
            [2]u32{ @bitCast(blast.damage.lateral), @bitCast(blast.damage.height) },
        );

        try std.testing.expectEqualDeep(case.result.position_bits, bits(blast.impact));
    }
}

test "projectile movement damping model rotation and slopes match the reference" {
    const blood = @import("../enemy/blood.zig");
    const physics = @import("../enemy/physics.zig");
    const level_module = @import("../assets/level.zig");
    const scene_module = @import("../render/scene.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Input = struct {
        dt: f32,
        position: [3]f32,
        velocity: [3]f32,
        angles: [3]i16,
        rotation: [3]f32,
        slope: ?[3]f32,
    };

    const Result = struct {
        position_bits: [3]u32,
        velocity_bits: [3]u32,
        angles: [3]i16,
        flags: u32,
        floor_cache_bits: u32,
        bounced: bool,
        rotation_bits: [3]u32,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { config: Input, result: Result },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/projectile-motion-reference.json"),
        .{},
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "bd7af1f60e70a1c70a381728f44eaf7a140a07daa2d445f6cc0b533917180df3",
        corpus.results_sha256,
    );

    const angles = Angles.init();
    const config = runtime.Config{ .name = "", .model = "" };

    for (corpus.cases, 0..) |case, index| {
        errdefer std.debug.print("projectile motion case{d}\n", .{index});
        const input = case.config;
        var sector = std.mem.zeroes(level_module.Sector);

        sector.vadjoin = -1;
        sector.gravity = -50;
        sector.friction = 0.5;
        sector.elasticity = 0.5;
        sector.ceiling.height = 60;

        var level: level_module.Level = undefined;
        level.sectors = (&sector)[0..1];
        var sector_state = std.mem.zeroes(scene_module.SectorState);

        if (input.slope) |slope| {
            sector_state.flags |= 0x40000000;
            sector_state.floor_slope = std.mem.zeroInit(
                scene_module.Slope,
                .{ .coeff_x = slope[0], .coeff_z = slope[1], .constant = slope[2] },
            );
        }

        var scene: scene_module.Scene = undefined;
        scene.sectors = (&sector_state)[0..1];
        var collision_check: u32 = 0;
        scene.collision_check = &collision_check;

        const world = physics.World{
            .level = &level,
            .scene = &scene,
            .angles = &angles,
            .actors = .{ .entries = &.{} },
        };

        var actor: Actor = .{
            .sector = 0,
            .position = point(input.position),
            .pitch = input.angles[0],
            .yaw = input.angles[1],
            .roll = input.angles[2],
            .flags = 0x8000004f,
            .secondary_flags = 0x420,
            .scale_x = 1,
            .scale_y = 1,
            .height = 2,
            .collision_radius = 1,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };

        var state: runtime.State = .{
            .config = &config,
            .held = false,
            .velocity = point(input.velocity),
            .rotation = point(input.rotation),
            .descriptor = .{
                .kind = .knife,
                .item = "",
                .owner = null,
                .origin = actor.position,
                .sector = 0,
                .pitch = 0,
                .yaw = 0,
                .damage = 0,
                .mass = 0,
                .rate = 0,
                .range = 0,
            },
        };

        var motion: blood.State = .{ .velocity = state.velocity };

        try blood.projectilePhysics(&actor, &motion, world, input.dt, null, null);
        state.velocity = motion.velocity;

        try runtime.alignFloor(&actor, &state.rotation, world);
        runtime.rotate(&actor, state.rotation, input.dt);
        runtime.afterMove(&state, point(input.velocity));

        const actual: Result = .{
            .position_bits = bits(actor.position),
            .velocity_bits = bits(state.velocity),
            .angles = .{ actor.pitch, actor.yaw, actor.roll },
            .flags = actor.flags,
            .floor_cache_bits = @bitCast(motion.floor_cache),
            .bounced = state.bounced,
            .rotation_bits = bits(state.rotation),
        };

        try std.testing.expectEqualDeep(case.result, actual);
    }
}

test "projectile pickup and sound save records match the reference writers and readers" {
    const codec = @import("../save/projectile.zig");
    const pickup_codec = @import("../save/pickup.zig");
    const sound_codec = @import("../save/sound.zig");
    const stream = @import("../save/stream.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Raw = struct {
        kind: u32,
        held: bool,
        explode: bool,
        deadline: u32,
        owner_id: u32,
        damage: f32,
        mass: f32,
        bounced: bool,
        pickup: ?struct {
            entries: []pickup_codec.Entry,
            sound: ?sound_codec.Record,
            flags: i16,
            enabled: bool,
        },
        configuration: []const u8,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { record: Raw, bytes: []const u8, omitted_words: [7]u32 },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/projectile-save-reference.json"),
        .{},
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "e95cd351cdb2c290eb3bbe4321ebf0be8cb6cc5227f63a7726a5beede1fd49e6",
        corpus.results_sha256,
    );

    for (corpus.cases) |case| {
        const value = case.record;
        const expected: codec.Record = .{
            .kind = @enumFromInt(value.kind),
            .held = value.held,
            .explode = value.explode,
            .deadline = value.deadline,
            .owner_id = value.owner_id,
            .damage = value.damage,
            .mass = value.mass,
            .bounced = value.bounced,
            .configuration = value.configuration,
            .pickup = if (value.pickup) |ground| .{
                .entries = ground.entries,
                .sound = ground.sound,
                .flags = ground.flags,
            } else null,
        };

        const bytes = try a.alloc(u8, case.bytes.len / 2);

        _ = try std.fmt.hexToBytes(bytes, case.bytes);
        var writer: stream.Writer = .{ .allocator = a };
        try expected.write(&writer);
        try std.testing.expectEqualSlices(u8, bytes, try writer.finish());

        var reader: stream.Reader = .{ .bytes = bytes };
        const restored = try codec.Record.read(&reader, a);

        try reader.end();

        try std.testing.expectEqualDeep(expected, restored);
        try std.testing.expectEqualDeep([_]u32{0} ** 7, case.omitted_words);

        if (value.pickup) |ground| try std.testing.expect(ground.enabled);
    }
}

test "instant health and sheriff pickup save records match the reference" {
    const pickup = @import("../save/pickup.zig");
    const stream = @import("../save/stream.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct {
        name: []const u8,
        encoded: []const u8,
        result: struct {
            entries: ?[]pickup.Entry = null,
            sound: ?@import("../save/sound.zig").Record,
            flags: i16 = 0,
            health_bonus: u8 = 0,
            message: i32 = -1,
        },
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []Case,
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/pickup-save-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "f4c6a79eb820d6559606c031f68cfdf829326cf62209f958b1317fd502fb811c",
        corpus.results_sha256,
    );

    for (corpus.cases) |case| {
        const bytes = try a.alloc(u8, case.encoded.len / 2);
        _ = try std.fmt.hexToBytes(bytes, case.encoded);

        var writer: stream.Writer = .{ .allocator = a };
        var reader: stream.Reader = .{ .bytes = bytes };

        if (case.result.entries) |entries| {
            const expected: pickup.Record = .{
                .entries = entries,
                .sound = case.result.sound,
                .flags = case.result.flags,
            };

            try expected.write(&writer);
            try std.testing.expectEqualDeep(expected, try pickup.Record.read(&reader, a));
        } else {
            const expected: pickup.Instant = .{
                .sound = case.result.sound,
                .health_bonus = case.result.health_bonus,
                .message = case.result.message,
            };

            try expected.write(&writer);
            try std.testing.expectEqualDeep(expected, try pickup.Instant.read(&reader, a));
        }

        try reader.end();
        try std.testing.expectEqualSlices(u8, bytes, try writer.finish());
    }
}

test "a projectile definition that fails part way through keeps none of its strings" {
    var item = try Item.parse(
        std.testing.allocator,
        "ITEM 1.0\nANIM PDYNAM.3DO\nDATA 3\nSTR EXPLOSION EXPLODE\nSTR FUSE_SOUND fuse.wav\nFLOAT RADIUS 2\n",
    );

    defer item.deinit();
    const Load = struct {
        fn run(a: std.mem.Allocator, source: *const Item) !void {
            var config = try runtime.Config.load(a, source, "PDYNAM.ITM");
            config.deinit(a);
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Load.run, .{&item});
    item.fields[2].value = .{ .float = std.math.inf(f32) };
    try std.testing.expectError(
        error.InvalidProjectileFloat,
        runtime.Config.load(std.testing.allocator, &item, "PDYNAM.ITM"),
    );
}
