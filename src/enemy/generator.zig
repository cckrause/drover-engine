//! Enemy generators: a placement that spawns enemies on a timer.
//!
//! The interval is minutes and seconds combined into one value and then
//! truncated, so the result is not simply minutes*60+seconds. Each generator
//! carries its own object number.

const std = @import("std");

const MessageCode = @import("../message_code.zig").MessageCode;
const level = @import("../assets/level.zig");
const Item = @import("../assets/item.zig").Item;
const engine = @import("../audio/engine.zig");
const audio = @import("../audio/runtime.zig");
const inventory = @import("../player/inventory.zig");
const random = @import("../player/weapon.zig");
const session_queues = @import("../render/session_queues.zig");
const perception = @import("perception.zig");
const enemy_session = @import("session.zig");
const bits = @import("../util/bits.zig");

pub const Kind = enum(u32) { item, enemy, point_sound, ambient_sound, indoor_sound };

/// An actor a generator made, until the actor is removed.
pub const ActorChild = struct { record: usize, source: usize };
/// A sound a generator started, until it is found to have ended.
pub const PlayingSound = struct { record: usize, id: u32, generation: u64 };

/// Every generated actor belongs to one generator, so all of them together
/// never outnumber the actors a session can hold.
/// TODO: Use the session's actor slot capacity once actor slots are fixed.
pub const max_actor_children = session_queues.actor_slots;
/// A generated sound holds a sound instance until the next sound check sees
/// it ended. Twice the pool leaves room for instances that end and start
/// again before that check.
pub const max_playing_sounds = 2 * engine.instance_count;

pub const Record = struct {
    id: u32,
    number: u32 = 0,
    kind: Kind = .item,
    generatee: []const u8,
    position: level.Vec3,
    sector: usize,
    yaw: i16,
    frequency: u32 = 120000,
    variation: u32 = 0,
    delay: u32 = 0,
    deadline: u32 = 0,
    generatee_flags: level.ObjectFlags = .{},
    maximum: i32 = 1,
    minimum_distance: f32 = 0,
    maximum_distance: f32 = 2147483648,
    volume: f32 = 0,
    terminate: i32 = std.math.maxInt(i32),
    total: i32 = 0,
    live: i32 = 0,
    enabled: bool = true,
    los: bool = false,
    resource_volume: i8 = 127,
    sound_resource: ?struct {
        name: []const u8,
        priority: i8 = 1,
        flags: engine.Flags = .{ .effects = true },
        created_at: u32,
    } = null,
    /// Every sound this generator started, ended or not. The original never
    /// drops them and a saved game lists each one, so only the count is kept.
    sound_children: u32 = 0,

    pub fn init(
        a: std.mem.Allocator,
        item: *const Item,
        object: level.Object,
        sector: usize,
        now: u32,
        rng: *u32,
    ) !Record {
        const name = try item.stringValue("GENERATE") orelse return error.GeneratorMissingGeneratee;
        var result: Record = .{
            .id = @bitCast(object.id),
            .generatee = try a.dupe(u8, name[0..@min(name.len, 14)]),
            .position = object.position,
            .sector = sector,
            .yaw = 0,
        };

        if (try item.stringValue("TYPE")) |kind| {
            if (std.ascii.eqlIgnoreCase(kind, "ENEMY")) result.kind = .enemy;
            if (std.ascii.eqlIgnoreCase(kind, "POINT_SOUND")) result.kind = .point_sound;
            if (std.ascii.eqlIgnoreCase(kind, "AMB_SOUND")) result.kind = .ambient_sound;
            if (std.ascii.eqlIgnoreCase(kind, "AMB_SOUND_INDOOR")) result.kind = .indoor_sound;
        }

        switch (result.kind) {
            .item => {},
            .enemy => {
                result.frequency = 60000;
                result.minimum_distance = 50;
                result.maximum_distance = 400;
                result.los = true;
            },
            .point_sound => {
                result.frequency = 20000;
                result.maximum_distance = 200;
                result.los = true;
                result.volume = 127;
            },
            .ambient_sound, .indoor_sound => {
                result.frequency = 10000;
                result.volume = 127;
            },
        }

        if (item.intValue("GENERATEE_FLAGS")) |value| result.generatee_flags = @bitCast(value);

        if (item.floatValue("FREQ")) |value| result.frequency = try milliseconds(value);

        if (item.floatValue("RAND")) |value| result.variation = try milliseconds(value);

        if (item.floatValue("DELAY")) |value| result.delay = try milliseconds(value);

        if (item.intValue("MAX_GENERATEES")) |value| result.maximum = value;

        if (item.floatValue("MIN_PLAYER_DIST")) |value| result.minimum_distance = value;

        if (item.floatValue("MAX_PLAYER_DIST")) |value| result.maximum_distance = value;

        if (item.intValue("NUM_TERMINATE")) |value| result.terminate = value;

        if (item.floatValue("VOLUME")) |value| result.volume = value;

        if (try item.stringValue(
            "MASTER",
        )) |value| result.enabled = !std.ascii.eqlIgnoreCase(value, "OFF");

        if (try item.stringValue(
            "LOS",
        )) |value| result.los = !std.ascii.eqlIgnoreCase(value, "FALSE");

        if (!std.math.isFinite(
            result.minimum_distance,
        ) or !std.math.isFinite(
            result.maximum_distance,
        ) or !std.math.isFinite(result.volume)) return error.InvalidGeneratorNumber;

        if (@intFromEnum(
            result.kind,
        ) >= 2) result.sound_resource = .{ .name = result.generatee, .created_at = now };

        result.deadline = now +% (random.randomNext(rng) & 0x1ff) +% result.delay;

        return result;
    }

    fn reschedule(self: *Record, now: u32, rng: *u32) void {
        self.deadline = now +% self.frequency;

        if (self.variation != 0) {
            const value: f32 = @floatCast(random.randomFloat(rng, @floatFromInt(self.variation)));
            var offset = perception.nearest(value);
            if (now & 0x100 != 0) offset = -%offset;
            self.deadline +%= @bitCast(offset);
        }
    }
};

pub const State = struct {
    records: std.ArrayList(Record) = .empty,
    enabled: bool = false,
    deadline: u32 = 0,
    respawn_sound: bool = false,
    silent_instances: engine.Engine = .{},
    // Plain arrays rather than lists borrowing a buffer, because a state is
    // copied when it is saved and restored. Both keep the order children
    // were made in.
    actor_children: [max_actor_children]ActorChild = undefined,
    actor_child_count: usize = 0,
    playing_sounds: [max_playing_sounds]PlayingSound = undefined,
    playing_sound_count: usize = 0,

    pub fn append(
        self: *State,
        a: std.mem.Allocator,
        item: *const Item,
        object: level.Object,
        sector: usize,
        now: u32,
        rng: *u32,
    ) !void {
        try self.records.append(a, try Record.init(a, item, object, sector, now, rng));
    }

    pub fn start(self: *State, now: u32) void {
        for (self.records.items) |*record| record.deadline = now +% record.delay;
        self.deadline = 0;
        self.enabled = true;
    }

    pub fn actorChildren(self: *const State) []const ActorChild {
        return self.actor_children[0..self.actor_child_count];
    }

    pub fn addActorChild(
        self: *State,
        record: usize,
        source: usize,
    ) error{TooManyGeneratorActors}!void {
        if (self.actor_child_count == max_actor_children) return error.TooManyGeneratorActors;
        self.actor_children[self.actor_child_count] = .{ .record = record, .source = source };
        self.actor_child_count += 1;
    }

    fn addPlayingSound(self: *State, sound: PlayingSound) error{TooManyGeneratorSounds}!void {
        if (self.playing_sound_count == max_playing_sounds) return error.TooManyGeneratorSounds;
        self.playing_sounds[self.playing_sound_count] = sound;
        self.playing_sound_count += 1;
    }

    /// How many children a saved game lists for the generator at `index`.
    pub fn childCount(self: *const State, index: usize) u32 {
        const record = self.records.items[index];
        if (@intFromEnum(record.kind) >= 2) return record.sound_children;

        var count: u32 = 0;

        for (self.actorChildren()) |child| count += @intFromBool(child.record == index);

        return count;
    }

    /// Drops the children of a generator that is being removed and moves
    /// the later generators' children down with their records.
    fn forgetRecord(self: *State, index: usize) void {
        var kept: usize = 0;

        for (self.actorChildren()) |child| {
            if (child.record == index) continue;

            self.actor_children[kept] = .{
                .record = if (child.record > index) child.record - 1 else child.record,
                .source = child.source,
            };

            kept += 1;
        }

        self.actor_child_count = kept;
        kept = 0;

        for (self.playing_sounds[0..self.playing_sound_count]) |sound| {
            if (sound.record == index) continue;
            self.playing_sounds[kept] = sound;
            if (sound.record > index) self.playing_sounds[kept].record -= 1;
            kept += 1;
        }

        self.playing_sound_count = kept;
    }

    pub fn removed(self: *State, source: usize, now: u32, rng: *u32) void {
        // The first generator in list order that holds the actor gives it up.
        var found: ?usize = null;

        for (self.actorChildren(), 0..) |child, position| {
            if (child.source != source) continue;
            if (found == null or child.record < self.actor_children[found.?].record) found = position;
        }

        const position = found orelse return;
        const record = &self.records.items[self.actor_children[position].record];

        std.mem.copyForwards(
            ActorChild,
            self.actor_children[position .. self.actor_child_count - 1],
            self.actor_children[position + 1 .. self.actor_child_count],
        );

        self.actor_child_count -= 1;
        record.live -%= 1;

        if (record.kind == .item and record.live < record.maximum) record.reschedule(now, rng);
    }
};

pub fn milliseconds(value: f32) !u32 {
    const converted = (if (@as(
        u32,
        @bitCast(value),
    ) > 0x80000000) @abs(@as(f64, value)) else @as(f64, value) * 60) * 1000;

    if (!std.math.isFinite(
        converted,
    ) or converted < 0 or converted >= 4294967296) return error.InvalidGeneratorTime;

    return @intFromFloat(converted);
}

pub fn releaseSounds(session: anytype) void {
    for (session.generators.records.items) |*record| releaseRecordSound(session, record);
    session.releaseSound("get.wav");
}

pub fn removeSector(session: anytype, sector: usize) void {
    var index: usize = 0;

    while (index < session.generators.records.items.len) {
        const record = &session.generators.records.items[index];

        if (record.sector == sector) {
            releaseRecordSound(session, record);
            session.generators.forgetRecord(index);
            _ = session.generators.records.orderedRemove(index);
            if (index == 0) return;
        } else index += 1;
    }
}

pub fn message(
    session: anytype,
    allocator: std.mem.Allocator,
    effects: *inventory.Effects,
    id: u32,
    code: MessageCode,
) !bool {
    for (session.generators.records.items, 0..) |*record, index| if (record.id == id) {
        if (code == .trigger) {
            try generate(session, allocator, effects, index);
        } else if (code == .master_on) {
            record.enabled = true;
        } else if (code == .master_off) {
            record.enabled = false;
        }

        session.generators.deadline = 0;
        return true;
    };

    return false;
}

pub fn tick(session: anytype, allocator: std.mem.Allocator, effects: *inventory.Effects) !void {
    updateSounds(session);

    const now = session.animation_time;
    const system = &session.generators;
    if (system.deadline > now) return;

    system.respawn_sound = false;
    var delay: u32 = 5000;

    if (system.enabled) {
        var index: usize = 0;

        while (index < system.records.items.len) : (index += 1) {
            var record = &system.records.items[index];

            if (!record.enabled) continue;

            if (record.deadline < now) {
                if (record.live < record.maximum) {
                    record.reschedule(now, &session.contact_state.random);

                    const player = enemy_session.playerSubject(session);
                    const distance: f32 = if (player.secondary_flags.waiting_for_start) record.minimum_distance else @floatCast(perception.distance(perception.point(record.position), perception.point(player.position)) + @abs(@as(f64, player.position.y) - record.position.y));

                    if (distance <= record.maximum_distance and record.minimum_distance <= distance) {
                        var allowed = !record.los;

                        if (record.los) {
                            var eye = player.position;
                            eye.y = @floatCast(@as(f64, eye.y) + player.height);

                            if (record.kind == .point_sound) {
                                allowed = try session.enemy_visibility.connected(
                                    &session.level,
                                    &session.scene,
                                    &session.angles,
                                    record.sector,
                                    player.sector,
                                );

                                if (allowed) {
                                    record.resource_volume = if (try visible(
                                        session,
                                        record.*,
                                        player.sector,
                                        eye,
                                    )) 127 else 63;

                                    if (session.active_audio) |runtime| {
                                        const registered = runtime.lookup(
                                            record.sound_resource.?.name,
                                        ) orelse return error.MissingGeneratorSoundRegistration;

                                        runtime.registrations.items[registered].volume = @bitCast(
                                            record.resource_volume,
                                        );
                                    }
                                }
                            } else {
                                allowed = !try visible(session, record.*, player.sector, eye);

                                if (allowed) {
                                    eye.y = @floatCast(@as(f64, eye.y) + 3);
                                    allowed = !try visible(session, record.*, player.sector, eye);
                                }

                                if (allowed) {
                                    eye.y = @floatCast(@as(f64, eye.y) + 3);
                                    allowed = !try visible(session, record.*, player.sector, eye);
                                }
                            }
                        }

                        if (allowed) try generate(session, allocator, effects, index);

                        record = &system.records.items[index];
                    }
                } else delay = 0;

                if (record.total >= record.terminate) record.enabled = false;
            }

            delay = @min(delay, record.deadline -% now);
        }
    }

    system.deadline = now +% delay;
}

pub fn updateSounds(session: anytype) void {
    const sound: *audio.Runtime = session.active_audio orelse return;
    const system = &session.generators;
    var kept: usize = 0;

    for (system.playing_sounds[0..system.playing_sound_count]) |child| {
        const playing = if (sound.engine.find(
            child.id,
        )) |voice| voice.generation == child.generation else false;

        if (playing) {
            system.playing_sounds[kept] = child;
            kept += 1;
        } else system.records.items[child.record].live -%= 1;
    }

    system.playing_sound_count = kept;
}

fn releaseRecordSound(session: anytype, record: *Record) void {
    if (record.sound_resource) |resource| session.releaseSound(resource.name);
    record.sound_resource = null;
}

fn visible(session: anytype, record: Record, sector: usize, endpoint: level.Vec3) !bool {
    return session.enemy_visibility.visible(
        &session.level,
        &session.scene,
        &session.angles,
        record.sector,
        sector,
        record.position,
        endpoint,
        session.animation_time,
    );
}

fn generate(
    session: anytype,
    allocator: std.mem.Allocator,
    effects: *inventory.Effects,
    index: usize,
) !void {
    _ = allocator;

    const record = session.generators.records.items[index];
    const Child = union(enum) { actor: usize, sound: ?PlayingSound };
    const child: Child = switch (record.kind) {
        .item, .enemy => blk: {
            const network = session.game_type.isNetwork();
            if (network and !std.ascii.eqlIgnoreCase(
                record.generatee,
                "NULL",
            ) and session.router.own_client != 1 and session.router.clientCount() > 1) {
                try @import("../network/database.zig").requestServerCreate(session.router, .{
                    .sector = @intCast(record.sector),
                    .position = .{
                        @bitCast(record.position.x),
                        @bitCast(record.position.y),
                        @bitCast(record.position.z),
                    },
                    .kind = 0,
                    .name = record.generatee,
                });

                return;
            }

            const source = try enemy_session.spawnItem(
                session,
                record.generatee,
                .{ .position = record.position, .sector = record.sector },
            ) orelse return;

            if (network and session.router.clientCount() > 1) try @import(
                "../render/network_actors.zig",
            ).sendActor(session, source, 0);

            const actor = &session.actor_slots[source].?;

            if (record.kind == .enemy and actor.secondary_flags.enemy) session.enemy_shared.total_enemies -= 1;

            if (record.generatee_flags.physics) actor.flags = bits.with(actor.flags, .{ .physics = true, .changed = true });

            if (record.total > 0 and record.kind == .item and !session.generators.respawn_sound) {
                try effects.append(.{
                    .sound = .{
                        .basename = "get",
                        .sector = record.sector,
                        .position = record.position,
                        .priority = 32,
                        .volume = 127,
                        .flags = .{},
                    },
                });

                session.generators.respawn_sound = true;
            }

            session.syncActor(source);
            break :blk .{ .actor = source };
        },
        .point_sound, .ambient_sound, .indoor_sound => blk: {
            const sound: ?*audio.Runtime = session.active_audio;
            const instances = if (sound) |runtime| &runtime.engine else &session.generators.silent_instances;
            const registration = if (sound) |runtime| runtime.lookup(
                record.sound_resource.?.name,
            ) orelse return error.MissingGeneratorSoundRegistration else null;

            const instance_id = (if (sound) |runtime| runtime.allocateInstance(
                registration.?,
            ) else instances.allocateInstance()) orelse return;

            const outside = session.scene.sectors[session.player.sector].flags.sky_ceiling;
            if (record.kind == .indoor_sound and outside) return;

            var params: engine.Params = if (sound) |runtime| .{
                .priority = @bitCast(runtime.registrations.items[registration.?].priority),
                .flags = runtime.registrations.items[registration.?].flags,
                .volume = @bitCast(runtime.registrations.items[registration.?].volume),
            } else .{ .priority = 1 };

            if (record.kind == .point_sound) {
                params.position = .{ record.position.x, record.position.y, record.position.z };
                params.flags = bits.with(params.flags, .{ .spatial = true, .ambient = true });
                params.frequency_factor = @floatCast(
                    random.randomFloat(&session.contact_state.random, 0.2) + @as(f32, 0.9),
                );
            } else params.frequency_factor = @floatCast(
                random.randomFloat(&session.contact_state.random, 0.4) + @as(f32, 0.8),
            );

            const volume = if (record.kind == .ambient_sound and !outside) record.volume * 0.5 else record.volume;
            params.volume = @bitCast(
                @as(u8, @truncate(@as(u32, @bitCast(@as(i32, @intFromFloat(volume)))))),
            );

            const handle = if (sound) |runtime| admitted: {
                const resource = runtime.registerAt(
                    record.generatee,
                    0x57415644,
                    1,
                    record.sound_resource.?.created_at,
                ) catch |err| switch (err) {
                    error.SoundResourceNotFound => {
                        instances.stop(instance_id);
                        break :admitted null;
                    },
                    else => return err,
                };

                break :admitted try instances.admit(
                    instance_id,
                    resource,
                    runtime.waves.items[resource].sample_rate,
                    params,
                    session.animation_time,
                );
            } else admitted: {
                instances.stop(instance_id);
                break :admitted null;
            };

            break :blk .{
                .sound = if (handle) |id| .{
                    .record = index,
                    .id = id,
                    .generation = sound.?.engine.find(id).?.generation,
                } else null,
            };
        },
    };

    const updated = &session.generators.records.items[index];

    updated.total +%= 1;
    updated.live +%= 1;

    switch (child) {
        .actor => |source| try session.generators.addActorChild(index, source),
        .sound => |playing| {
            updated.sound_children +%= 1;
            if (playing) |value| try session.generators.addPlayingSound(value);
        },
    }
}

test "generator sound release keeps sector iterator and close order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/actor-audio-ownership-reference.json",
        a,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        generators: struct { sector_releases: [][]const u8, releases: [][]const u8 },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        bytes,
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

    const archive = try @import(
        "../assets/lab.zig",
    ).Archive.init(
        try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB",
            a,
            .limited(64 * 1024 * 1024),
        ),
    );

    const FixtureSession = struct {
        generators: State = .{},
        released: std.ArrayList([]const u8) = .empty,
        allocator: std.mem.Allocator,

        pub fn releaseSound(self: *@This(), name: []const u8) void {
            self.released.append(self.allocator, name) catch unreachable;
        }
    };

    var session: FixtureSession = .{ .allocator = a };
    var rng: u32 = 0x742389ac;
    var object = std.mem.zeroes(level.Object);

    object.id = 42;
    object.position = .{ .x = 3, .y = 4, .z = 5 };

    for ([_][]const u8{ "SDOG.ITM", "SHAWK.ITM", "SDOG.ITM" }) |name| {
        var definition = try Item.parse(a, try archive.find(name, 0));
        defer definition.deinit();
        try session.generators.append(a, &definition, object, 0, 1000, &rng);
    }

    removeSector(&session, 0);
    try std.testing.expectEqualDeep(corpus.generators.sector_releases, session.released.items);

    var definition = try Item.parse(a, try archive.find("SMINE.ITM", 0));
    defer definition.deinit();

    try session.generators.append(a, &definition, object, 0, 1000, &rng);
    releaseSounds(&session);

    try std.testing.expectEqualDeep(corpus.generators.releases, session.released.items);
}

test "all shipped generator constructors match the reference" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        "testdata/generator-reference.json",
        a,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Fixture = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct {
            name: []const u8,
            constructor: struct {
                id: u32,
                kind: u32,
                generatee: []const u8,
                position: [3]u32,
                yaw: i16,
                fields: [14]u32,
                random: u32,
            },
        },
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer fixture.deinit();

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        fixture.value.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "0857a6e8102dc5a7db98473dd0dae3a55c77154e25ecb6c8fe9f7c048d04466a",
        fixture.value.results_sha256,
    );

    const archive_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB",
        a,
        .limited(128 * 1024 * 1024),
    );

    defer a.free(archive_bytes);
    const archive = try @import("../assets/lab.zig").Archive.init(archive_bytes);

    for (fixture.value.cases) |case| {
        errdefer std.debug.print("reference generator {s}\n", .{case.name});
        const item_bytes = try archive.find(case.name, 0);
        var item = try Item.parse(a, item_bytes);
        defer item.deinit();
        var object = std.mem.zeroes(level.Object);

        object.id = 42;
        object.position = .{ .x = 3, .y = 4, .z = 5 };

        var rng: u32 = 0x742389ac;
        const result = try Record.init(a, &item, object, 0, 1000, &rng);
        defer a.free(result.generatee);
        const fields = [13]u32{
            result.frequency,
            result.variation,
            result.delay,
            result.deadline,
            bits.word(result.generatee_flags),
            @bitCast(result.maximum),
            @bitCast(result.minimum_distance),
            @bitCast(result.maximum_distance),
            @bitCast(result.volume),
            @bitCast(result.terminate),
            @bitCast(result.total),
            @bitCast(result.live),
            @as(u32, @intFromBool(result.enabled)) | (@as(u32, @intFromBool(result.los)) << 1),
        };

        try std.testing.expectEqual(case.constructor.id, result.id);
        try std.testing.expectEqual(case.constructor.kind, @intFromEnum(result.kind));
        try std.testing.expectEqualStrings(case.constructor.generatee, result.generatee);
        try std.testing.expectEqual(case.constructor.yaw, result.yaw);
        try std.testing.expectEqualSlices(u32, case.constructor.fields[0..13], &fields);
        try std.testing.expectEqual(case.constructor.random, rng);
    }
}

test "generator sound allocation and driver failure match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/generator-audio-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Fixture = struct {
        results_sha256: []const u8,
        cases: []const struct {
            name: []const u8,
            outside: bool,
            frames: []const struct {
                total: i32,
                live: i32,
                random: u32,
                next_id: u32,
                allocated: usize,
            },
        },
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer fixture.deinit();

    try std.testing.expectEqualStrings(
        "426549c63d4cd3084f661f6672994d0ea581e564699ab5edcdfeb344dfd8779d",
        fixture.value.results_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const system_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(128 * 1024 * 1024),
    );

    defer a.free(system_bytes);
    const system = try @import("../assets/lab.zig").Archive.init(system_bytes);
    var startup = try @import("../campaign.zig").Startup.prepare(a, system, .good);
    defer startup.deinit(a);

    _ = try startup.levelForDiagnostics();

    const session = try @import(
        "../render/session.zig",
    ).Session.open(
        a,
        @import("../render/test_workspace.zig").get(),
        std.testing.io,
        path,
        system,
        &startup,
    );

    defer session.deinit(a);

    for (fixture.value.cases) |case| {
        const name = try std.fmt.allocPrint(session.arena.allocator(), "{s}.ITM", .{case.name});
        var item = try Item.parse(a, try session.object_archive.find(name, 0));
        defer item.deinit();
        var object = std.mem.zeroes(level.Object);

        object.id = 42;
        object.position = .{ .x = 3, .y = 4, .z = 5 };
        session.generators = .{};
        session.contact_state.random = 0x742389ac;
        session.animation_time = 1000;
        session.scene.sectors[session.player.sector].flags = .{ .sky_ceiling = case.outside };

        try session.generators.append(
            session.arena.allocator(),
            &item,
            object,
            0,
            1000,
            &session.contact_state.random,
        );

        var effects_buffer: inventory.EffectBuffer = undefined;
        var effects = inventory.Effects.init(&effects_buffer);

        for (case.frames) |expected| {
            try generate(session, a, &effects, 0);
            const record = session.generators.records.items[0];

            try std.testing.expectEqual(expected.total, record.total);
            try std.testing.expectEqual(expected.live, record.live);
            try std.testing.expectEqual(expected.random, session.contact_state.random);
            try std.testing.expectEqual(
                expected.next_id,
                session.generators.silent_instances.next_id,
            );

            var allocated: usize = 0;

            for (session.generators.silent_instances.allocated) |value| allocated += @intFromBool(
                value,
            );

            try std.testing.expectEqual(expected.allocated, allocated);
        }
    }
}

test "generator children keep their order, follow removed generators and report when full" {
    var state: State = .{};
    defer state.records.deinit(std.testing.allocator);
    const record: Record = .{
        .id = 1,
        .generatee = "x",
        .position = .{ .x = 0, .y = 0, .z = 0 },
        .sector = 0,
        .yaw = 0,
        .live = 2,
    };

    for (0..3) |_| try state.records.append(std.testing.allocator, record);

    state.records.items[2].kind = .ambient_sound;
    state.records.items[2].sound_children = 7;

    try state.addActorChild(1, 10);
    try state.addActorChild(0, 11);
    try state.addActorChild(1, 12);
    try state.addActorChild(0, 10);

    try std.testing.expectEqual(@as(u32, 2), state.childCount(0));
    try std.testing.expectEqual(@as(u32, 7), state.childCount(2));

    // The first generator in list order gives the actor up, not the first child.
    var rng: u32 = 1;
    state.removed(10, 0, &rng);

    try std.testing.expectEqual(@as(i32, 1), state.records.items[0].live);
    try std.testing.expectEqualSlices(
        ActorChild,
        &.{
            .{ .record = 1, .source = 10 },
            .{ .record = 0, .source = 11 },
            .{ .record = 1, .source = 12 },
        },
        state.actorChildren(),
    );

    state.forgetRecord(0);
    try std.testing.expectEqualSlices(
        ActorChild,
        &.{ .{ .record = 0, .source = 10 }, .{ .record = 0, .source = 12 } },
        state.actorChildren(),
    );

    state.actor_child_count = max_actor_children;
    try std.testing.expectError(error.TooManyGeneratorActors, state.addActorChild(0, 1));
}
