//! Saving and restoring enemies, generators and corpses.
//!
//! The placement list of the unique enemy is kept separately from the corpse
//! pool. A restore resolves only actors that existed before the saved
//! database, and keeps their ids.

const std = @import("std");
const bits = @import("../util/bits.zig");
const Difficulty = @import("../difficulty.zig").Difficulty;

const stream = @import("../save/stream.zig");
const controller = @import("controller.zig");
const generator = @import("generator.zig");
const sanchez = @import("sanchez.zig");
const Target = @import("../player/target.zig").Target;
const lab = @import("../assets/lab.zig");
const Item = @import("../assets/item.zig").Item;
const Vec3 = @import("../assets/level.zig").Vec3;
const Actor = @import("../render/objects.zig").Actor;
const sound_registration = @import("../audio/registration.zig");
const sound_save = @import("../save/sound.zig");

pub const References = struct {
    actor_ids: []const u32,
    player_id: ?u32 = null,
    sector_count: usize,
    node_count: usize,
    audio: ?*@import("../audio/runtime.zig").Runtime = null,
    sound_ledger: ?*sound_registration.Ledger = null,
    now: u32 = 0,
};

pub const RestoredEnemy = struct { owner_id: ?u32, target: Target };

pub fn writeLogic(
    writer: *stream.Writer,
    shared: controller.Shared,
    sites: []const sanchez.Site,
) !void {
    try writer.marker(0x42676f4c, 1, 0);
    try writer.float(shared.total_enemies);
    try writer.float(shared.killed_enemies);
    try writer.integer(u32, shared.next_shot);
    try writer.integer(u32, shared.next_taunt);
    try writer.integer(u32, @intCast(sites.len));

    for (sites) |site| {
        try writer.integer(u32, @intCast(site.sector));
        try writer.float(site.position.x);
        try writer.float(site.position.y);
        try writer.float(site.position.z);
    }
}

pub fn readLogic(
    reader: *stream.Reader,
    a: std.mem.Allocator,
    shared: *controller.Shared,
    sector_count: usize,
) ![]sanchez.Site {
    try reader.marker(0x42676f4c, 1, 0);

    shared.total_enemies = try reader.float();
    shared.killed_enemies = try reader.float();
    shared.next_shot = try reader.integer(u32);
    shared.next_taunt = try reader.integer(u32);

    const count = try reader.integer(u32);
    if (count > 65536) return error.InvalidSavedSanchezCount;

    const sites = try a.alloc(sanchez.Site, count);
    errdefer a.free(sites);

    for (sites, 0..) |*site, index| {
        const sector = try reader.integer(u32);
        if (sector >= sector_count) return error.InvalidSavedSector;

        site.* = .{
            .source = index,
            .sector = sector,
            .position = .{
                .x = try reader.float(),
                .y = try reader.float(),
                .z = try reader.float(),
            },
        };
    }

    return sites;
}

pub fn writeGen(
    writer: *stream.Writer,
    state: *const generator.State,
    actor_ids: []const u32,
) !void {
    return writeGenWithAudio(writer, state, actor_ids, null);
}

pub fn writeGenWithAudio(
    writer: *stream.Writer,
    state: *const generator.State,
    actor_ids: []const u32,
    audio: ?*@import("../audio/runtime.zig").Runtime,
) !void {
    try writer.marker(0x426e6547, 1, 1);
    try writer.integer(u32, @intCast(state.records.items.len));

    for (state.records.items, 0..) |record, record_index| {
        try writer.integer(u32, record.id);
        try writer.integer(u32, @intFromEnum(record.kind));
        try writer.string(record.generatee);
        try writer.float(record.position.x);
        try writer.float(record.position.y);
        try writer.float(record.position.z);
        try writer.integer(u32, @intCast(record.sector));
        try writer.integer(i16, record.yaw);
        try writer.integer(u32, record.frequency);
        try writer.integer(u32, record.variation);
        try writer.integer(u32, record.delay);
        try writer.integer(u32, bits.word(record.generatee_flags));
        try writer.integer(u32, record.deadline);
        try writer.integer(i32, record.maximum);
        try writer.float(record.minimum_distance);
        try writer.float(record.maximum_distance);
        try writer.float(record.volume);
        try writer.integer(i32, record.terminate);
        try writer.integer(i32, record.total);
        try writer.integer(i32, record.live);
        try writer.boolean(record.enabled);
        try writer.boolean(record.los);
        try writer.integer(u32, state.childCount(record_index));

        if (@intFromEnum(record.kind) >= 2) {
            for (0..record.sound_children) |_| try writer.integer(u32, 1);
        } else for (state.actorChildren()) |child| if (child.record == record_index) {
            if (child.source >= actor_ids.len) return error.InvalidSavedGeneratorActor;
            try writer.integer(u32, 0);
            try writer.integer(u32, actor_ids[child.source]);
        };

        const resource: ?sound_save.Record = if (record.sound_resource) |value| if (audio) |runtime| try sound_save.capture(runtime, value.name) else .{ .name = value.name, .priority = @bitCast(value.priority), .flags = value.flags, .registered_at = value.created_at, .volume = @bitCast(record.resource_volume) } else null;
        try sound_save.write(writer, resource);
    }

    try writer.integer(u32, @intFromBool(state.enabled));
}

pub fn readGen(
    reader: *stream.Reader,
    a: std.mem.Allocator,
    sector_count: usize,
    actor_ids: []const u32,
) !generator.State {
    try reader.marker(0x426e6547, 1, 1);

    var result: generator.State = .{};
    const count = try reader.integer(u32);
    if (count > 65536) return error.InvalidSavedGeneratorCount;

    for (0..count) |_| {
        var record: generator.Record = undefined;
        const id = try reader.integer(u32);
        const kind: generator.Kind = switch (try reader.integer(u32)) {
            0 => .item,
            1 => .enemy,
            2 => .point_sound,
            3 => .ambient_sound,
            4 => .indoor_sound,
            else => return error.InvalidSavedGeneratorKind,
        };

        var buffer: [255]u8 = undefined;
        const name = try a.dupe(u8, try reader.string(&buffer));
        if (name.len > 14) return error.InvalidSavedGeneratorName;

        record = .{
            .id = id,
            .kind = kind,
            .generatee = name,
            .position = .{
                .x = try reader.float(),
                .y = try reader.float(),
                .z = try reader.float(),
            },
            .sector = try reader.integer(u32),
            .yaw = try reader.integer(i16),
        };

        if (record.sector >= sector_count) return error.InvalidSavedSector;

        record.frequency = try reader.integer(u32);
        record.variation = try reader.integer(u32);
        record.delay = try reader.integer(u32);
        record.generatee_flags = @bitCast(try reader.integer(u32));
        record.deadline = try reader.integer(u32);
        record.maximum = try reader.integer(i32);
        record.minimum_distance = try reader.float();
        record.maximum_distance = try reader.float();
        record.volume = try reader.float();
        record.terminate = try reader.integer(i32);
        record.total = try reader.integer(i32);
        record.live = try reader.integer(i32);
        record.enabled = try reader.boolean();
        record.los = try reader.boolean();

        const children = try reader.integer(u32);
        if (children > 1048576) return error.InvalidSavedGeneratorChildren;

        for (0..children) |_| switch (try reader.integer(u32)) {
            0 => {
                const actor_id = try reader.integer(u32);

                for (actor_ids, 0..) |existing, source| if (existing == actor_id) {
                    try result.addActorChild(result.records.items.len, source);
                    break;
                };
            },
            1 => {},
            else => return error.InvalidSavedGeneratorChildKind,
        };

        record.live = 0;

        if (try reader.boolean()) {
            const sound_name = try a.dupe(u8, try reader.string(&buffer));
            if (try reader.integer(u32) != 0x57415644) return error.InvalidSavedGeneratorSoundType;

            record.sound_resource = .{
                .name = sound_name,
                .priority = try reader.integer(i8),
                .flags = bits.from(@import("../audio/engine.zig").Flags, try reader.integer(u32)),
                .created_at = try reader.integer(u32),
            };

            record.resource_volume = try reader.integer(i8);
        }

        try result.records.append(a, record);
    }

    result.enabled = (try reader.integer(u32)) != 0;

    return result;
}

pub fn readGenWithAudio(
    reader: *stream.Reader,
    a: std.mem.Allocator,
    sector_count: usize,
    actor_ids: []const u32,
    audio: *@import("../audio/runtime.zig").Runtime,
) !generator.State {
    const state = try readGen(reader, a, sector_count, actor_ids);

    for (state.records.items) |record| if (record.sound_resource) |value| {
        _ = try sound_save.restore(
            audio,
            .{
                .name = value.name,
                .priority = @bitCast(value.priority),
                .flags = value.flags,
                .registered_at = value.created_at,
                .volume = @bitCast(record.resource_volume),
            },
        );
    };

    return state;
}

pub fn writeEnemy(
    writer: *stream.Writer,
    target: *const Target,
    owner_id: ?u32,
    refs: References,
) !void {
    try writeFrame(writer, target, owner_id, refs, true);
}

pub fn readEnemy(
    reader: *stream.Reader,
    allocator: std.mem.Allocator,
    archives: []const lab.Archive,
    difficulty: Difficulty,
    shared: *controller.Shared,
    refs: References,
) !RestoredEnemy {
    const restored = try readFrame(reader, allocator, archives, difficulty, shared, refs, true);

    if (refs.sound_ledger) |ledger| try sound_registration.enemySounds(
        ledger,
        allocator,
        restored.target.config_name,
        restored.target.config,
        refs.now,
    );

    return restored;
}

pub fn applyEnemy(
    restored: RestoredEnemy,
    actor: *Actor,
    shared: *controller.Shared,
    serial: *u64,
) Target {
    var target = restored.target;
    target.selection_serial = serial;

    if (actor.playback) |playback| target.playback = playback;

    switch (target.native) {
        .slim, .bob => {
            target.ai.special = true;
            actor.secondary_flags.boss = true;
        },
        .farmer, .dynamite => actor.secondary_flags.boss = true,
        .sanchez => {
            actor.secondary_flags.boss = true;
            shared.sanchez_enabled = actor.flags.visible;
        },
        else => {},
    }

    return target;
}

fn writeFrame(
    w: *stream.Writer,
    t: *const Target,
    owner: ?u32,
    refs: References,
    outer: bool,
) anyerror!void {
    try optional(w, owner);
    if (t.ai.task_nodes.len > 255) return error.InvalidSavedEnemyTaskCount;

    try w.integer(u8, @intCast(t.ai.task_nodes.len));

    for (t.ai.task_nodes) |node| {
        try w.integer(u32, node.kind);
        try w.integer(u32, @intCast(node.sector));
        try vector(w, node.position);
        try w.integer(u32, node.used_at);
        try w.integer(u32, node.value1c);
        try w.integer(u32, node.value20);
        try w.integer(u32, node.time24);
    }

    try w.integer(u8, @truncate(t.damage.current_chor));
    try vector(w, t.ai.physics.position);
    try optional(w, if (t.ai.physics.sampled) @intCast(t.ai.physics.sector) else null);
    try w.integer(i16, t.ai.physics.yaw);
    try w.integer(u32, t.ai.updated_at);
    try w.boolean(t.animation_ended);

    if (outer) {
        var count: u32 = 0;
        var entry = t.ai.stack;

        while (entry) |saved| : (entry = saved.ai.stack) count += 1;

        try w.integer(u32, count);
        entry = t.ai.stack;

        while (entry) |saved| : (entry = saved.ai.stack) {
            var frame = t.*;

            frame.ai = saved.ai;
            frame.mode = saved.mode;
            frame.previous_mode = saved.previous_mode;
            frame.damage = saved.damage;
            frame.anger = saved.anger;
            frame.fear = saved.fear;
            frame.animation_ended = saved.animation_ended;
            frame.config_name = saved.config_name;
            frame.config = saved.config;
            frame.attack_at = saved.attack_at;
            frame.sight_at = saved.sight_at;

            try writeFrame(w, &frame, owner, refs, false);
        }
    }

    try w.integer(u8, t.ai.block_count);
    try vector(w, t.damage.velocity);
    try w.integer(u32, t.ai.base_mode);
    try w.integer(u32, t.mode);
    try w.integer(u32, t.previous_mode);
    try w.boolean(t.ai.remove);
    try w.boolean(t.damage.knockout);
    try w.boolean(t.damage.knockout);
    try w.boolean(t.damage.armor);

    for ([_]u32{
        t.ai.deadline,
        t.ai.timer20,
        t.ai.timer24,
        t.ai.sub_timer,
        t.ai.timer2c,
        t.ai.timer30,
        t.ai.watch_at,
        t.attack_at,
        t.ai.timer3c,
        t.ai.taunt_at,
    }) |time| try w.integer(u32, time);

    try w.string(t.config_name);
    try w.float(t.damage.health);
    try w.integer(i16, t.ai.aim_yaw);
    try sound_save.write(
        w,
        if (refs.audio) |audio| try sound_save.capture(
            audio,
            t.ai.last_taunt,
        ) else if (t.ai.last_taunt == null) null else t.ai.last_taunt_resource orelse return error.MissingSaveSoundRegistration,
    );

    const cover: i32 = if (t.ai.cover_task) |index| -@as(
        i32,
        @intCast(index + 1),
    ) else if (t.ai.cover_node) |index| @intCast(index + 1) else 0;

    try w.integer(i32, cover);
    try w.float(t.anger);
    try w.float(t.fear);
    try vector(w, t.ai.physics.goal);
    try w.float(t.ai.physics.move_speed);
    try w.boolean(t.ai.physics.move_complete);
    try w.boolean(t.ai.physics.movement_disabled);
    try w.boolean(t.ai.physics.landed);
    try w.integer(u32, t.ai.physics.movement_mode);
    try w.integer(i16, t.ai.obstacle_yaw);
    try vector(w, t.ai.physics.trial);
    try w.integer(i16, t.ai.physics.desired_yaw);
    try w.integer(u32, t.ai.physics.blocked_until);

    for ([_]bool{
        t.ai.check_los,
        t.ai.check_fov,
        t.ai.check_cover,
        t.ai.has_los,
        t.ai.in_fov,
        t.ai.covered,
    }) |flag| try w.boolean(flag);

    try w.integer(u32, t.ai.previous_seen_at);
    try w.integer(u32, t.ai.last_seen_at);
    try optional(w, if (t.ai.target) |id| switch (id) {
        .player => refs.player_id orelse return error.MissingSavedPlayerId,
        .actor => |source| if (source < refs.actor_ids.len) refs.actor_ids[source] else return error.InvalidSavedEnemyTarget,
    } else null);

    try vector(w, t.ai.last_seen);
    try optional(w, if (t.ai.last_seen_sector_valid) @intCast(t.ai.last_seen_sector) else null);
    try w.integer(i16, t.ai.target_yaw);
    try w.integer(u32, t.ai.timer12c);
    try w.integer(u32, t.sight_at);
    try w.integer(u32, t.ai.visible_until);
    try w.integer(i16, t.ai.throw_pitch);
    try w.integer(i16, t.ai.throw_yaw);
}

fn readFrame(
    r: *stream.Reader,
    a: std.mem.Allocator,
    archives: []const lab.Archive,
    difficulty: Difficulty,
    shared: *controller.Shared,
    refs: References,
    outer: bool,
) anyerror!RestoredEnemy {
    const owner = try readOptional(r);
    var ai: controller.State = .{};
    const tasks = try a.alloc(controller.TaskNode, try r.integer(u8));

    for (tasks) |*node| {
        node.* = .{
            .kind = try r.integer(u32),
            .sector = try readSector(r, refs.sector_count),
            .position = try readVector(r),
            .used_at = try r.integer(u32),
            .value1c = try r.integer(u32),
            .value20 = try r.integer(u32),
            .time24 = try r.integer(u32),
        };
    }

    ai.task_nodes = tasks;
    ai.task_active = tasks.len != 0;

    const choreography = try r.integer(u8);
    ai.physics.position = try readVector(r);

    if (try readOptional(r)) |sector| {
        if (sector >= refs.sector_count) return error.InvalidSavedSector;
        ai.physics.sampled = true;
        ai.physics.sector = sector;
    }

    ai.physics.yaw = try r.integer(i16);
    ai.updated_at = try r.integer(u32);

    const ended = try r.boolean();

    if (outer) {
        const count = try r.integer(u32);
        if (count > 1024) return error.InvalidSavedEnemyStack;

        var tail = &ai.stack;

        for (0..count) |_| {
            const frame = try readFrame(r, a, archives, difficulty, shared, refs, false);
            const saved = try a.create(controller.Snapshot);
            const t = frame.target;

            saved.* = .{
                .pool = &shared.free_snapshots,
                .ai = t.ai,
                .mode = t.mode,
                .previous_mode = t.previous_mode,
                .damage = t.damage,
                .anger = t.anger,
                .fear = t.fear,
                .animation_ended = t.animation_ended,
                .config = t.config,
                .config_name = t.config_name,
                .attack_at = t.attack_at,
                .sight_at = t.sight_at,
            };

            tail.* = saved;
            tail = &saved.ai.stack;
        }
    }

    ai.block_count = try r.integer(u8);
    const velocity = try readVector(r);

    ai.physics.velocity = velocity;
    ai.base_mode = try r.integer(u32);

    const mode = try r.integer(u32);
    const previous_mode = try r.integer(u32);

    ai.remove = try r.boolean();

    const knockout = try r.boolean();
    const armor = try r.boolean();

    ai.special = try r.boolean();
    ai.deadline = try r.integer(u32);
    ai.timer20 = try r.integer(u32);
    ai.timer24 = try r.integer(u32);
    ai.sub_timer = try r.integer(u32);
    ai.timer2c = try r.integer(u32);
    ai.timer30 = try r.integer(u32);
    ai.watch_at = try r.integer(u32);

    const attack_at = try r.integer(u32);

    ai.timer3c = try r.integer(u32);
    ai.taunt_at = try r.integer(u32);

    var buffer: [255]u8 = undefined;
    const name = try r.string(&buffer);
    const filename = try std.fmt.allocPrint(a, "{s}.ITM", .{name});
    var definition = try Item.parse(a, try itemBytes(archives, filename));
    defer definition.deinit();
    var target = try Target.load(
        a,
        archives,
        &definition,
        difficulty,
    ) orelse return error.InvalidSavedEnemyTemplate;

    if (refs.sound_ledger) |ledger| try sound_registration.enemyTemplate(
        ledger,
        a,
        archives,
        &definition,
        refs.now,
    );

    target.damage.health = try r.float();
    target.damage.velocity = velocity;
    target.damage.current_chor = choreography;
    target.damage.knockout = knockout;
    target.damage.armor = armor;
    target.mode = mode;
    target.previous_mode = previous_mode;
    target.animation_ended = ended;
    target.attack_at = attack_at;
    ai.aim_yaw = try r.integer(i16);
    ai.last_taunt_resource = try sound_save.read(r, a);

    if (refs.audio) |audio| ai.last_taunt = try sound_save.restore(
        audio,
        ai.last_taunt_resource,
    ) else if (ai.last_taunt_resource) |resource| ai.last_taunt = resource.name;

    const cover = try r.integer(i32);

    if (cover != 0) {
        const ordinal: usize = @intCast(if (cover < 0) -@as(i64, cover) else cover);

        if (cover < 0 and ordinal <= tasks.len) {
            ai.cover_task = ordinal - 1;
        } else {
            if (ordinal > 0xffff) return error.InvalidSavedEnemyNode;
            if (ordinal <= refs.node_count) ai.cover_node = ordinal - 1;
        }
    }

    target.anger = try r.float();
    target.fear = try r.float();
    ai.physics.goal = try readVector(r);
    ai.physics.move_speed = try r.float();
    ai.physics.move_complete = try r.boolean();
    ai.physics.movement_disabled = try r.boolean();
    ai.physics.landed = try r.boolean();
    ai.physics.movement_mode = try r.integer(u32);
    ai.obstacle_yaw = try r.integer(i16);
    ai.physics.trial = try readVector(r);
    ai.physics.desired_yaw = try r.integer(i16);
    ai.physics.blocked_until = try r.integer(u32);
    ai.check_los = try r.boolean();
    ai.check_fov = try r.boolean();
    ai.check_cover = try r.boolean();
    ai.has_los = try r.boolean();
    ai.in_fov = try r.boolean();
    ai.covered = try r.boolean();
    ai.previous_seen_at = try r.integer(u32);
    ai.last_seen_at = try r.integer(u32);

    if (try readOptional(r)) |id| {
        if (refs.player_id != null and refs.player_id.? == id) ai.target = .player else for (refs.actor_ids, 0..) |existing, source| {
            if (existing == id) {
                ai.target = .{ .actor = source };
                break;
            }
        }
    }

    ai.last_seen = try readVector(r);

    if (try readOptional(r)) |sector| {
        if (sector >= refs.sector_count) return error.InvalidSavedSector;
        ai.last_seen_sector_valid = true;
        ai.last_seen_sector = sector;
    }

    ai.target_yaw = try r.integer(i16);
    ai.timer12c = try r.integer(u32);
    target.sight_at = try r.integer(u32);
    ai.visible_until = try r.integer(u32);
    ai.throw_pitch = try r.integer(i16);
    ai.throw_yaw = try r.integer(i16);
    target.ai = ai;

    return .{ .owner_id = owner, .target = target };
}

fn itemBytes(archives: []const lab.Archive, filename: []const u8) ![]const u8 {
    for (archives) |archive| return archive.find(filename, 0) catch |err| switch (err) {
        error.ResourceNotFound => continue,
        else => return err,
    };

    return error.ResourceNotFound;
}

fn optional(w: *stream.Writer, value: ?u32) !void {
    try w.boolean(value != null);
    if (value) |number| try w.integer(u32, number);
}

fn readOptional(r: *stream.Reader) !?u32 {
    return if (try r.boolean()) try r.integer(u32) else null;
}

fn vector(w: *stream.Writer, value: Vec3) !void {
    try w.float(value.x);
    try w.float(value.y);
    try w.float(value.z);
}

fn readVector(r: *stream.Reader) !Vec3 {
    return .{ .x = try r.float(), .y = try r.float(), .z = try r.float() };
}

fn readSector(r: *stream.Reader, count: usize) !usize {
    const value = try r.integer(u32);
    if (value >= count) return error.InvalidSavedSector;

    return value;
}

fn fixtureRead(a: std.mem.Allocator, path: []const u8) ![]u8 {
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

fn expectHex(a: std.mem.Allocator, expected: []const u8, actual: []const u8) !void {
    const bytes = try a.alloc(u8, expected.len / 2);
    _ = try std.fmt.hexToBytes(bytes, expected);
    try std.testing.expectEqualSlices(u8, bytes, actual);
}

test "generator logic and enemy save bytes match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        generators: []struct { name: []const u8, bytes: []const u8 },
        enemies: []struct { name: []const u8, hit: bool, bytes: []const u8 },
        wax: []struct {
            name: []const u8,
            native: []const u8,
            resource: []const u8,
            playback: [8]u32,
            bytes: []const u8,
        },
        logic: []const u8,
    };

    const fixture = (try std.json.parseFromSlice(
        Corpus,
        a,
        try fixtureRead(a, "testdata/actor-save-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        fixture.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "72fbdb85d3bf8917c47cee9db0106613311e5f7bc90efdab3cc3f1ffa2956440",
        fixture.results_sha256,
    );

    const object_archive = try lab.Archive.init(
        try fixtureRead(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"),
    );

    const weapon_archive = try lab.Archive.init(
        try fixtureRead(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"),
    );

    for (fixture.generators) |case| {
        errdefer std.debug.print("reference saved generator {s}\n", .{case.name});
        var definition = try Item.parse(
            a,
            try object_archive.find(try std.fmt.allocPrint(a, "{s}.ITM", .{case.name}), 0),
        );

        defer definition.deinit();
        var object = std.mem.zeroes(@import("../assets/level.zig").Object);

        object.id = 42;
        object.position = .{ .x = 3, .y = 4, .z = 5 };

        var rng: u32 = 0x742389ac;
        var state: generator.State = .{};

        try state.append(a, &definition, object, 0, 1000, &rng);
        var writer = stream.Writer{ .allocator = a };
        try writeGen(&writer, &state, &.{});
        const bytes = try writer.finish();
        try expectHex(a, case.bytes, bytes);

        var reader = stream.Reader{ .bytes = bytes };
        const restored = try readGen(&reader, a, 1, &.{});

        try reader.end();

        try std.testing.expectEqual(
            state.records.items[0].frequency,
            restored.records.items[0].frequency,
        );

        try std.testing.expectEqual(@as(i32, 0), restored.records.items[0].live);
    }

    var writer = stream.Writer{ .allocator = a };
    try writeLogic(
        &writer,
        .{ .total_enemies = 10, .killed_enemies = 8, .next_shot = 123, .next_taunt = 456 },
        &.{
            .{ .source = 0, .sector = 0, .position = .{ .x = 0, .y = 0, .z = 0 } },
            .{ .source = 1, .sector = 0, .position = .{ .x = 10, .y = 2, .z = 30 } },
        },
    );

    const logic_bytes = try writer.finish();
    try expectHex(a, fixture.logic, logic_bytes);

    var logic_reader = stream.Reader{ .bytes = logic_bytes };
    var logic_shared: controller.Shared = .{};
    const sites = try readLogic(&logic_reader, a, &logic_shared, 1);

    try logic_reader.end();
    try std.testing.expectEqual(@as(usize, 2), sites.len);

    for (fixture.wax) |case| {
        const wax_save = @import("../save/costume.zig");
        const p = case.playback;
        const instance: wax_save.Instance = .{
            .resource = try std.ascii.allocUpperString(a, case.resource),
            .native = case.native,
            .playback = .{
                .last_time = p[0],
                .angle_offset = @bitCast(@as(u16, @truncate(p[1]))),
                .direction = p[2],
                .choreography = p[3],
                .next_frame = p[4],
                .frame = p[5],
                .flags = bits.from(@import("../assets/nwx.zig").PlaybackFlags, p[6]),
                .terminated = p[7] != 0,
            },
        };

        writer = .{ .allocator = a };
        try wax_save.write(&writer, instance);
        const bytes = try writer.finish();
        try expectHex(a, case.bytes, bytes);

        var reader = stream.Reader{ .bytes = bytes };
        const restored = (try wax_save.read(&reader, a)).?;

        try reader.end();
        try std.testing.expectEqualDeep(instance, restored);
    }

    const level_module = @import("../assets/level.zig");
    const scene_module = @import("../render/scene.zig");
    const camera = @import("../render/backends/software/camera.zig");
    const nwx = @import("../assets/nwx.zig");
    var sector = std.mem.zeroes(level_module.Sector);

    sector.vadjoin = -1;
    sector.ceiling.height = 64;

    var level: level_module.Level = undefined;
    level.sectors = (&sector)[0..1];

    var sector_state = std.mem.zeroes(scene_module.SectorState);
    var scene: scene_module.Scene = undefined;

    scene.sectors = (&sector_state)[0..1];
    var collision_check: u32 = 0;
    scene.collision_check = &collision_check;

    const angles = camera.Angles.init();
    const refs: References = .{
        .actor_ids = &.{101},
        .player_id = 102,
        .sector_count = 1,
        .node_count = 0,
    };

    for (fixture.enemies) |case| {
        errdefer std.debug.print("reference saved enemy {s} hit={}\n", .{ case.name, case.hit });
        var definition = try Item.parse(
            a,
            try object_archive.find(try std.fmt.allocPrint(a, "{s}.ITM", .{case.name}), 0),
        );

        defer definition.deinit();
        var costume = try nwx.Costume.parse(a, try object_archive.find(definition.animation, 0));
        defer costume.deinit();
        var object = std.mem.zeroes(level_module.Object);

        object.name = case.name;
        var actor = (try @import(
            "../render/object_state.zig",
        ).State.init(object, 0, &definition, &costume)).actor(&costume);

        actor.source_index = 0;

        var target = (try Target.load(
            a,
            &.{ object_archive, weapon_archive },
            &definition,
            .bad,
        )).?;

        var shared: controller.Shared = .{ .now = 1000 };

        if (case.hit) {
            var cache = try @import("../audio/occlusion.zig").Cache.init(a, &level);
            var random: u32 = 0x742389ac;
            var effects_buffer: [16]controller.Effect = undefined;
            var effects = controller.Effects.init(&effects_buffer);
            const player: controller.Subject = .{
                .position = .{ .x = 20, .y = 0, .z = 0 },
                .sector = 0,
                .height = 6,
                .radius = 1.5,
                .yaw = 0,
                .flags = .{ .active = true },
                .secondary_flags = .{ .player = true },
            };

            var context = controller.Context{
                .allocator = a,
                .level = &level,
                .scene = &scene,
                .angles = &angles,
                .actors = .{ .entries = &.{} },
                .player = player,
                .hit_sender = player,
                .visibility = &cache,
                .random = &random,
                .now = 1000,
                .elapsed_seconds = 0.016,
                .shared = &shared,
                .effects = &effects,
            };

            const Reflection = struct {
                count: usize = 0,

                pub fn enqueue(
                    raw: *anyopaque,
                    _: ?usize,
                    _: @import("../player/shooting.zig").DamageInput,
                ) !void {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    self.count += 1;
                }
            };

            var reflection: Reflection = .{};

            context.reflected_hit = .{ .context = &reflection, .enqueue = Reflection.enqueue };
            try controller.hitMessage(
                &target,
                &actor,
                .{
                    .kind = 1,
                    .damage = 0.25,
                    .mass = 0.03,
                    .speed = 1000,
                    .pitch = 0,
                    .yaw = 4096,
                    .lateral = 0.1,
                    .height = 3.25,
                    .shooter_position = .{ .x = 20, .z = 0 },
                },
                &context,
            );

            try std.testing.expectEqual(
                @as(usize, if (target.native == .civilian) 1 else 0),
                reflection.count,
            );
        }

        writer = .{ .allocator = a };
        try writeEnemy(&writer, &target, 101, refs);
        const bytes = try writer.finish();
        try expectHex(a, case.bytes, bytes);

        var reader = stream.Reader{ .bytes = bytes };
        const restored = try readEnemy(
            &reader,
            a,
            &.{ object_archive, weapon_archive },
            .bad,
            &shared,
            refs,
        );

        try reader.end();

        try std.testing.expectEqual(target.mode, restored.target.mode);
        try std.testing.expectEqual(target.damage.health, restored.target.damage.health);
        try std.testing.expectEqual(target.damage.knockout, restored.target.damage.armor);
        try std.testing.expectEqual(target.damage.armor, restored.target.ai.special);

        writer = .{ .allocator = a };

        try writeEnemy(&writer, &restored.target, restored.owner_id, refs);
        try expectHex(a, case.bytes, try writer.finish());
    }
}

test "generator restore resolves only actors present before DB and preserves deletion quirk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/generator-restore-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const NativeState = struct {
        fields: [14]u32,
        random: u32,
        children: []const u32,
    };

    const Fixture = struct {
        results_sha256: []const u8,
        saved: []const u8,
        saved_actor_id: u32,
        cases: []const struct {
            old_actor: bool,
            restored: NativeState,
            after_destroy: ?NativeState = null,
        },
    };

    const fixture = (try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "5dbe6df2de1d8a2c9589f3bb0f7cdd18a0726fb05168acc3fca55dd71bc0a534",
        fixture.results_sha256,
    );

    const raw = try a.alloc(u8, fixture.saved.len / 2);
    _ = try std.fmt.hexToBytes(raw, fixture.saved);

    for (fixture.cases) |case| {
        var reader = stream.Reader{ .bytes = raw };
        const ids = [_]u32{fixture.saved_actor_id};
        var state = try readGen(&reader, a, 1, if (case.old_actor) &ids else &.{});

        try reader.end();

        try std.testing.expectEqual(
            @as(i32, @bitCast(case.restored.fields[11])),
            state.records.items[0].live,
        );

        try std.testing.expectEqual(case.restored.fields[3], state.records.items[0].deadline);
        try std.testing.expectEqual(case.restored.children.len, state.childCount(0));

        if (case.after_destroy) |expected| {
            var rng: u32 = 0x12345678;
            state.removed(0, 90000, &rng);

            try std.testing.expectEqual(
                @as(i32, @bitCast(expected.fields[11])),
                state.records.items[0].live,
            );

            try std.testing.expectEqual(expected.fields[3], state.records.items[0].deadline);
            try std.testing.expectEqual(expected.random, rng);
            try std.testing.expectEqual(expected.children.len, state.childCount(0));
        }
    }
}

test "enemy restore registers cached templates before callback sounds" {
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
        restores: []struct { name: []const u8, hit: bool, bytes: []const u8, batches: [][]Sound },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try fixtureRead(a, "testdata/actor-audio-ownership-reference.json"),
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

    const objects = try lab.Archive.init(
        try fixtureRead(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"),
    );

    const weapons = try lab.Archive.init(
        try fixtureRead(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLWEAP.LAB"),
    );

    for (corpus.restores) |case| {
        errdefer std.debug.print(
            "reference enemy restore sound ownership {s} hit={}\n",
            .{ case.name, case.hit },
        );

        const bytes = try a.alloc(u8, case.bytes.len / 2);

        _ = try std.fmt.hexToBytes(bytes, case.bytes);

        var ledger: sound_registration.Ledger = .{};
        var shared: controller.Shared = .{};
        const refs: References = .{
            .actor_ids = &.{1},
            .sector_count = 1,
            .node_count = 0,
            .sound_ledger = &ledger,
            .now = 9000,
        };

        for (case.batches) |batch| {
            const begin = ledger.records.items.len;
            var reader: stream.Reader = .{ .bytes = bytes };

            _ = try readEnemy(&reader, a, &.{ objects, weapons }, .good, &shared, refs);
            try reader.end();
            const actual = ledger.records.items[begin..];
            try std.testing.expectEqual(batch.len, actual.len);

            for (batch, actual) |expected, value| {
                try std.testing.expectEqualStrings(expected.name, value.name);
                try std.testing.expectEqual(expected.resource_type, value.resource_type);
                try std.testing.expectEqual(expected.priority, value.priority);
                try std.testing.expectEqual(@as(u32, 9000), value.registered_at);
            }
        }
    }
}
