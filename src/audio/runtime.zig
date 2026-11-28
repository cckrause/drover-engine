//! The audio runtime: the mounted sound archives, the registrations a level
//! made, and the requests that turn into playing instances.
//!
//! A registration is matched by name against a 13-byte field that is not
//! terminated for longer names, so two sounds whose names share that prefix
//! are the same registration as far as this layer is concerned.

const std = @import("std");
const bits = @import("../util/bits.zig");

const lab = @import("../assets/lab.zig");
const level = @import("../assets/level.zig");
const campaign = @import("../campaign.zig");
const title = @import("../game/title.zig");
const camera = @import("../render/backends/software/camera.zig");
const scene = @import("../render/scene.zig");
const ambient_module = @import("ambient.zig");
const asset = @import("asset.zig");
const sound = @import("engine.zig");
const music = @import("music.zig");
const occlusion = @import("occlusion.zig");
pub const Request = @import("request.zig").Request;

pub const Registration = struct {
    name: []const u8,
    resource_type: u32 = 0x57415644,
    priority: u8 = 64,
    flags: sound.Flags = .{ .effects = true },
    registered_at: u32,
    volume: u8 = 127,
};

pub const World = struct {
    level: *const level.Level,
    scene: *const scene.Scene,
    angles: *const camera.Angles,
    listener_sector: usize,
    listener_eye: level.Vec3,
    visibility: ?*occlusion.Cache = null,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    archives: [3]lab.Archive,
    directory: []const u8,
    music_directory: []const u8,
    engine: sound.Engine = .{ .effects_volume = 58, .speech_volume = 58 },
    waves: std.ArrayList(asset.Wave) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    resource_flags: std.ArrayList(sound.Flags) = .empty,
    registrations: std.ArrayList(Registration) = .empty,
    registration_refs: std.ArrayList(
        struct { count: i32 = 1, active: bool = true, stop_all_instances: u32 = 0 },
    ) = .empty,
    instance_registrations: [sound.instance_count]?u32 = @splat(null),
    startup_registered: bool = false,
    doors_registered: bool = false,
    default_pickup_registration: ?u32 = null,
    registration_ids: std.ArrayList(u32) = .empty,
    loops: std.AutoHashMap(usize, Handle),
    visibility: ?occlusion.Cache = null,
    script: ?music.Script = null,
    music_resources: ?lab.Archive = null,
    music_name: []const u8 = "",
    player: ?music.Player = null,
    music_bytes: ?[]u8 = null,
    music_wave: ?asset.Wave = null,
    music_generation: u64 = 0,
    music_deadline: ?u32 = null,
    music_pause_depth: u32 = 0,
    music_pause_remaining: ?u32 = null,
    ambient: ?ambient_module.Scheduler = null,
    ambient_resources: []u32 = &.{},

    const Handle = struct { id: u32, generation: u64 };

    pub fn open(
        a: std.mem.Allocator,
        io: std.Io,
        data_path: []const u8,
        system: lab.Archive,
    ) !*Runtime {
        const self = try a.create(Runtime);
        errdefer a.destroy(self);

        self.* = .{
            .allocator = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .archives = undefined,
            .directory = undefined,
            .music_directory = undefined,
            .loops = std.AutoHashMap(usize, Handle).init(a),
        };

        errdefer self.arena.deinit();

        const arena = self.arena.allocator();

        self.directory = try arena.dupe(u8, std.fs.path.dirname(data_path) orelse ".");
        self.music_directory = self.directory;
        self.archives[0] = system;

        for (title.current.sound_archives, self.archives[1..]) |name, *archive| {
            const path = try std.fs.path.join(arena, &.{ self.directory, name });
            const bytes = std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                arena,
                .limited(64 * 1024 * 1024),
            ) catch |err| {
                std.log.err("cannot load sound archive {s}: {s}", .{ path, @errorName(err) });
                return err;
            };

            archive.* = try lab.Archive.init(bytes);
            archive.front = system.front;
        }

        return self;
    }

    pub fn remount(self: *Runtime, io: std.Io, data_path: []const u8, system: lab.Archive) !void {
        if (self.visibility != null or self.script != null) return error.AudioLevelAlreadyLoaded;

        const directory = std.fs.path.dirname(data_path) orelse ".";
        if (std.mem.eql(u8, directory, self.directory)) return;

        const a = self.arena.allocator();
        var archives: [3]lab.Archive = undefined;

        archives[0] = try lab.Archive.init(try a.dupe(u8, system.data));
        archives[0].front = system.front;

        for (title.current.sound_archives, archives[1..]) |name, *archive| {
            const path = try std.fs.path.join(a, &.{ directory, name });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                a,
                .limited(64 * 1024 * 1024),
            );

            archive.* = try lab.Archive.init(bytes);
            archive.front = system.front;
        }

        self.archives = archives;
        self.directory = try a.dupe(u8, directory);
    }

    pub fn deinit(self: *Runtime) void {
        self.endLevel();
        self.loops.deinit();
        self.waves.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.resource_flags.deinit(self.allocator);
        self.registrations.deinit(self.allocator);
        self.registration_refs.deinit(self.allocator);
        self.registration_ids.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn register(self: *Runtime, name: []const u8) !u32 {
        return self.registerAt(name, 0x57415644, 64, 0);
    }

    pub fn declare(
        self: *Runtime,
        name: []const u8,
        resource_type: u32,
        priority: u8,
        now: u32,
    ) !u32 {
        if (resource_type != 0x57415644) return error.UnsupportedSoundResourceType;
        if (name.len == 0) return error.UnsupportedSoundName;

        for (self.registrations.items, 0..) |stored, index| if (self.registration_refs.items[index].active and try self.nameMatches(stored.name, name)) {
            self.registration_refs.items[index].count +%= 1;
            return @intCast(index);
        };

        const registered_name = try self.arena.allocator().dupe(u8, name);

        try self.registration_refs.ensureUnusedCapacity(self.allocator, 1);
        try self.registrations.append(
            self.allocator,
            .{
                .name = registered_name,
                .resource_type = resource_type,
                .priority = priority,
                .registered_at = now,
            },
        );

        self.registration_refs.appendAssumeCapacity(.{});

        return @intCast(self.registrations.items.len - 1);
    }

    pub fn soundStartsWith(self: *const Runtime, prefix: []const u8) !bool {
        for (self.archives) |archive| {
            for (archive.front) |patch| if (try archiveStartsWith(patch, prefix)) return true;
            if (try archiveStartsWith(archive, prefix)) return true;
        }

        return false;
    }

    pub fn lookup(self: *const Runtime, name: []const u8) ?u32 {
        for (self.registrations.items, 0..) |stored, index| if (self.registration_refs.items[index].active and std.ascii.eqlIgnoreCase(stored.name, name)) return @intCast(index);

        return null;
    }

    pub fn replaceDefaultPickup(self: *Runtime, name: []const u8, now: u32) !u32 {
        if (self.default_pickup_registration) |previous| {
            self.releaseRegistration(previous);
            self.default_pickup_registration = null;
        }

        const id = try self.declare(name, 0x57415644, 64, now);
        self.default_pickup_registration = id;

        return id;
    }

    pub fn releaseRegistration(self: *Runtime, id: u32) void {
        const refs = &self.registration_refs.items[id];
        if (!refs.active) return;

        refs.count -%= 1;
        if (refs.count != 0) return;
        if (self.instanceCount(id) != 0) return;

        for (self.engine.voices) |voice| if (voice.active and voice.asset < self.registration_ids.items.len and self.registration_ids.items[voice.asset] == id) return;

        refs.active = false;
    }

    pub fn allocateInstance(self: *Runtime, registration: u32) ?u32 {
        const id = self.engine.allocateInstance() orelse return null;
        self.instance_registrations[id] = registration;

        return id;
    }

    pub fn instanceCount(self: *const Runtime, registration: u32) u32 {
        var count = self.registration_refs.items[registration].stop_all_instances;

        for (self.engine.allocated, self.instance_registrations) |allocated, owner| if (allocated and owner == registration) {
            count +%= 1;
        };

        return count;
    }

    pub fn stopAll(self: *Runtime) void {
        for (self.engine.allocated, self.instance_registrations) |allocated, owner| if (allocated) {
            if (owner) |registration| self.registration_refs.items[registration].stop_all_instances +%= 1;
        };
        self.engine.stopAll();
    }

    pub fn registerAt(
        self: *Runtime,
        name: []const u8,
        resource_type: u32,
        priority: u8,
        now: u32,
    ) !u32 {
        var name_buffer: lab.NameBuffer = undefined;
        const native_name = if (std.fs.path.extension(
            name,
        ).len == 0) try lab.printName(&name_buffer, "{s}.wav", .{name}) else name;

        const registration = self.lookup(
            native_name,
        ) orelse try self.declare(native_name, resource_type, priority, now);

        const wanted = native_name;

        for (self.names.items, 0..) |stored, i| if (self.registration_ids.items[i] == registration and std.ascii.eqlIgnoreCase(stored, wanted)) return @intCast(i);

        const wave = try asset.decode(
            try self.findSound(wanted) orelse return error.SoundResourceNotFound,
        );

        try self.names.ensureUnusedCapacity(self.allocator, 1);
        try self.waves.ensureUnusedCapacity(self.allocator, 1);
        try self.resource_flags.ensureUnusedCapacity(self.allocator, 1);
        try self.registration_ids.ensureUnusedCapacity(self.allocator, 1);
        self.names.appendAssumeCapacity(try self.arena.allocator().dupe(u8, wanted));
        self.waves.appendAssumeCapacity(wave);
        self.resource_flags.appendAssumeCapacity(self.registrations.items[registration].flags);
        self.registration_ids.appendAssumeCapacity(registration);

        return @intCast(self.waves.items.len - 1);
    }

    pub fn beginLevel(
        self: *Runtime,
        io: std.Io,
        geometry: *const level.Level,
        resources: lab.Archive,
        now: u32,
    ) !void {
        if (self.visibility != null or self.script != null) return error.AudioLevelAlreadyLoaded;

        self.visibility = try occlusion.Cache.init(self.allocator, geometry);
        self.music_resources = resources;
        self.music_name = geometry.music;
        if (geometry.music.len == 0) return;

        const bytes = resources.find(geometry.music, 0x4d534342) catch |err| switch (err) {
            error.ResourceNotFound => self.archives[0].find(
                geometry.music,
                0x4d534342,
            ) catch |fallback_err| switch (fallback_err) {
                error.ResourceNotFound => return,
                else => return fallback_err,
            },
            else => return err,
        };

        self.script = try music.Script.parse(self.allocator, bytes);
        self.player = .{ .script = &self.script.? };

        try self.selectMusic(io, try self.player.?.start(), now);
    }

    pub fn restoreMusic(self: *Runtime, io: std.Io, name: []const u8, cue: i32, now: u32) !void {
        const resources = self.music_resources orelse return error.MusicLevelNotLoaded;
        const bytes = resources.find(name, 0x4d534342) catch |err| switch (err) {
            error.ResourceNotFound => try self.archives[0].find(name, 0x4d534342),
            else => return err,
        };

        if (self.script) |script| script.deinit(self.allocator);

        self.script = null;
        self.player = null;
        self.script = try music.Script.parse(self.allocator, bytes);
        self.music_name = try self.arena.allocator().dupe(u8, name);
        self.player = .{ .script = &self.script.? };

        try self.selectMusic(io, try self.player.?.restore(cue), now);
    }

    pub fn endLevel(self: *Runtime) void {
        if (self.player) |*player| player.stop();

        self.player = null;

        if (self.music_bytes) |bytes| self.allocator.free(bytes);

        self.music_bytes = null;
        self.music_wave = null;
        self.music_deadline = null;
        self.music_pause_remaining = null;
        self.music_pause_depth = 0;
        self.music_generation +%= 1;

        self.stopAll();
        self.loops.clearRetainingCapacity();

        if (self.visibility) |*cache| cache.deinit();

        self.visibility = null;

        if (self.script) |script| script.deinit(self.allocator);

        self.script = null;
        self.music_resources = null;
        self.music_name = "";

        if (self.ambient) |scheduler| scheduler.deinit(self.allocator);

        self.ambient = null;
        self.allocator.free(self.ambient_resources);
        self.ambient_resources = &.{};
    }

    pub fn pauseMusic(self: *Runtime, now: u32) void {
        if (self.music_pause_depth == 0) {
            if (self.music_deadline) |deadline| self.music_pause_remaining = deadline -% now;
        }
        self.music_pause_depth +%= 1;
    }

    pub fn resumeMusic(self: *Runtime, now: u32) void {
        if (self.music_pause_depth == 0) return;

        self.music_pause_depth -= 1;

        if (self.music_pause_depth == 0) {
            if (self.music_pause_remaining) |remaining| self.music_deadline = remaining +% now +% 1000;
            self.music_pause_remaining = null;
        }
    }

    pub fn musicPaused(self: *const Runtime) bool {
        return self.music_pause_remaining != null;
    }

    pub fn advanceMusic(self: *Runtime, io: std.Io, now: u32) !void {
        if (self.musicPaused()) return;
        if (self.music_deadline) |deadline| if (music.due(deadline, now)) {
            try self.selectMusic(io, try self.player.?.finished(), now);
        };
    }

    pub fn musicStarted(self: *Runtime, now: u32) void {
        if (self.music_wave) |wave| {
            const duration = music.completionDelay(@intCast(wave.pcm.len / 2352));
            self.music_deadline = now +% duration;
            if (self.musicPaused()) self.music_pause_remaining = duration;
        }
    }

    pub fn beginAmbient(
        self: *Runtime,
        geometry: *const level.Level,
        objects: *const level.Objects,
        difficulty: campaign.Difficulty,
    ) !void {
        if (self.ambient != null) return error.AmbientAlreadyInitialized;

        var scheduler = try ambient_module.Scheduler.init(
            self.allocator,
            geometry,
            objects,
            difficulty,
        );

        errdefer scheduler.deinit(self.allocator);
        const resources = try self.allocator.alloc(u32, scheduler.sources.len);
        errdefer self.allocator.free(resources);

        for (scheduler.sources, resources) |source, *resource| resource.* = try self.register(
            source.basename,
        );

        self.ambient = scheduler;
        self.ambient_resources = resources;
    }

    pub fn beginEmptyAmbient(self: *Runtime) !void {
        if (self.ambient != null) return error.AmbientAlreadyInitialized;
        self.ambient = .{ .sources = &.{}, .actions = &.{} };
        self.ambient_resources = &.{};
    }

    pub fn advanceAmbient(self: *Runtime, now: u32, listener_layer: f32) !void {
        const scheduler = if (self.ambient) |*value| value else return error.AmbientNotInitialized;

        for (try scheduler.poll(now, listener_layer)) |action| switch (action.kind) {
            .start => {
                const resource = self.ambient_resources[action.source];
                const source = &scheduler.sources[action.source];
                const registration = self.registration_ids.items[resource];
                const id = self.allocateInstance(registration) orelse {
                    source.handle = 0;
                    source.entered = false;
                    continue;
                };

                source.handle = id;

                const record = self.registrations.items[registration];
                var params = source.params();

                params.flags = bits.with(record.flags, .{ .spatial = true, .loop = true, .ambient = true });
                params.priority = @bitCast(record.priority);
                params.volume = @bitCast(record.volume);
                _ = try self.engine.admit(
                    id,
                    resource,
                    self.waves.items[resource].sample_rate,
                    params,
                    now,
                );
            },
            .stop => {
                self.engine.stop(action.handle);
            },
        };
    }

    pub fn play(self: *Runtime, request: Request, world: ?World, now: u32) anyerror!?u32 {
        if (request.mode == .loop and request.source == null) return error.MissingSoundInstanceOwner;

        const current_listener = self.engine.listener;

        if (request.listener) |listener| self.engine.listener = listener;

        defer self.engine.listener = current_listener;

        if (request.mode == .stop or request.mode == .update) {
            const key = request.source orelse return error.MissingSoundInstanceOwner;
            const handle = self.loops.get(key) orelse {
                if (request.mode == .stop) return null;
                var retry = request;
                retry.mode = .loop;
                return self.play(retry, world, now);
            };

            if (request.mode == .stop) {
                if (self.engine.find(
                    handle.id,
                )) |voice| if (voice.generation == handle.generation) self.engine.stop(handle.id);

                _ = self.loops.remove(key);
                return null;
            }

            const voice = self.engine.find(handle.id) orelse return null;
            if (voice.generation != handle.generation) return null;

            const position = request.position orelse return error.MissingSoundPosition;
            var params = voice.params;

            params.position = .{ position.x, position.y, position.z };
            try self.engine.adjust(handle.id, params);
            return handle.id;
        }

        const priority = request.priority orelse 64;
        if (priority < -128 or priority > 127) return error.InvalidAudioPriority;

        const resource = self.registerAt(
            request.basename,
            0x57415644,
            @bitCast(@as(i8, @intCast(priority))),
            now,
        ) catch |err| switch (err) {
            error.SoundResourceNotFound => return null,
            else => return err,
        };

        var volume = request.volume orelse 127;
        const flags = request.flags orelse sound.RequestFlags.default;

        if (!request.occlusion_applied) if (request.sector) |sector| {
            const context = world orelse return error.MissingAudioWorld;
            const position = request.position orelse return error.MissingSoundPosition;
            const cache = context.visibility orelse (if (self.visibility) |*value| value else return error.MissingAudioWorld);

            volume = try cache.volume(
                context.level,
                context.scene,
                context.angles,
                sector,
                context.listener_sector,
                position,
                context.listener_eye,
                volume,
                flags,
                now,
            );
        };

        if (volume < -128 or volume > 127) return error.InvalidAudioVolume;

        var params = try sound.gameParams(
            @intCast(priority),
            @intCast(volume),
            flags,
            if (request.position) |p| .{ p.x, p.y, p.z } else null,
        );

        params.flags = bits.with(params.flags, self.resource_flags.items[resource]);
        params.flags = bits.with(params.flags, self.registrations.items[self.registration_ids.items[resource]].flags);

        for (self.ambient_resources) |registered| if (registered == resource) {
            params.flags.loop = true;
            break;
        };

        const instance_id = self.allocateInstance(
            self.registration_ids.items[resource],
        ) orelse return null;

        const id = try self.engine.admit(
            instance_id,
            resource,
            self.waves.items[resource].sample_rate,
            params,
            now,
        );

        if (request.mode == .loop) {
            const key = request.source orelse return error.MissingSoundInstanceOwner;

            if (id) |instance| try self.loops.put(
                key,
                .{ .id = instance, .generation = self.engine.find(instance).?.generation },
            ) else _ = self.loops.remove(key);
        }

        return id;
    }

    fn nameMatches(self: *const Runtime, registered: []const u8, requested: []const u8) !bool {
        return nativeNameMatches(registered, requested) catch |err| {
            if (try self.findSound(
                registered,
            ) != null or try self.findSound(requested) != null) return err;

            return false;
        };
    }

    fn findSound(self: *const Runtime, name: []const u8) !?[]const u8 {
        for (self.archives) |archive| return archive.find(
            name,
            asset.resource_type,
        ) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };

        return null;
    }

    fn archiveStartsWith(archive: lab.Archive, prefix: []const u8) !bool {
        var entries = archive.iterator();

        while (try entries.next()) |entry| {
            if (entry.resource_type != 0 and entry.resource_type != asset.resource_type) continue;
            if (std.ascii.startsWithIgnoreCase(entry.name, prefix)) return true;
        }

        return false;
    }

    fn selectMusic(self: *Runtime, io: std.Io, track: ?music.Track, now: u32) !void {
        var bytes: ?[]u8 = null;
        var wave: ?asset.Wave = null;
        var deadline: ?u32 = null;

        if (track) |selected| {
            const name = try std.fmt.allocPrint(
                self.allocator,
                "TRACK{d:0>2}.WAV",
                .{selected.number},
            );

            defer self.allocator.free(name);
            const path = if (std.ascii.eqlIgnoreCase(selected.disc, "OUTLAWS_1"))
                try std.fs.path.join(
                    self.allocator,
                    &.{ self.music_directory, "..", "AUDIO", name },
                )
            else if (std.ascii.eqlIgnoreCase(selected.disc, "OUTLAWS_2"))
                try std.fs.path.join(
                    self.allocator,
                    &.{ self.music_directory, "..", "..", "OUTLAWS_CD2", "AUDIO", name },
                )
            else
                return error.UnsupportedMusicDisc;

            defer self.allocator.free(path);

            bytes = std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                self.allocator,
                .limited(256 * 1024 * 1024),
            ) catch |err| {
                std.log.err(
                    "cannot load music track {s}: {s}; the ripped audio tracks belong next to the game data",
                    .{ path, @errorName(err) },
                );

                return err;
            };

            errdefer self.allocator.free(bytes.?);
            wave = try asset.decode(bytes.?);

            const value = wave.?;
            if (value.channels != 2 or value.sample_rate != 44100 or value.bits_per_sample != 16 or value.pcm.len % 2352 != 0)
                return error.InvalidCdAudioTrack;

            deadline = now +% music.completionDelay(@intCast(value.pcm.len / 2352));
        }

        if (self.music_bytes) |old| self.allocator.free(old);

        self.music_bytes = bytes;
        self.music_wave = wave;
        self.music_generation +%= 1;
        self.music_deadline = deadline;
        self.music_pause_remaining = null;
    }
};

pub fn nativeNameMatches(registered: []const u8, requested: []const u8) !bool {
    if (registered.len < 13) return std.ascii.eqlIgnoreCase(registered, requested);

    const count = @min(requested.len, 13);
    if (!std.ascii.eqlIgnoreCase(registered[0..count], requested[0..count])) return false;
    if (requested.len < 13) return false;

    return error.UnresolvedOriginalSoundNameTail;
}

test "sound ownership frees only an unreferenced registration without instances" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/sound-lifetime-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Operation = struct {
        op: []const u8,
        name: []const u8,
        priority: u8 = 0,
        now: u32 = 0,
    };

    const Snapshot = struct {
        name: []const u8,
        priority: u8,
        registered_at: u32,
        references: i32,
        instances: u32,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct {
            operations: []Operation,
            snapshots: [][]Snapshot,
            defaults: []?[]const u8,
        },
    };

    const parsed = try std.json.parseFromSlice(Corpus, a, bytes, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "5c8aa903e8c9c00a9cabd62765417bc32f4fc1e3cc16138361b5a76efc086c68",
        parsed.value.results_sha256,
    );

    for (parsed.value.cases) |case| {
        const runtime = try a.create(Runtime);

        runtime.* = .{
            .allocator = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .archives = undefined,
            .directory = "",
            .music_directory = "",
            .loops = std.AutoHashMap(usize, Runtime.Handle).init(a),
        };

        defer runtime.deinit();

        var instance: u32 = 0;

        for (case.operations, case.snapshots, case.defaults) |op, expected, default| {
            if (std.mem.eql(u8, op.op, "declare")) {
                _ = try runtime.declare(op.name, 0x57415644, op.priority, op.now);
            } else if (std.mem.eql(u8, op.op, "replace")) {
                _ = try runtime.replaceDefaultPickup(op.name, op.now);
            } else if (std.mem.eql(u8, op.op, "release")) {
                runtime.releaseRegistration(runtime.lookup(op.name).?);
            } else if (std.mem.eql(u8, op.op, "allocate")) {
                instance = runtime.allocateInstance(runtime.lookup(op.name).?).?;
            } else if (std.mem.eql(
                u8,
                op.op,
                "stop",
            )) runtime.engine.stop(instance) else return error.InvalidReferenceOperation;

            var position: usize = 0;

            for (runtime.registrations.items, runtime.registration_refs.items, 0..) |record, refs, id| {
                if (!refs.active) continue;

                var instances: u32 = 0;

                for (runtime.engine.allocated, runtime.instance_registrations) |allocated, registration| if (allocated and registration == @as(u32, @intCast(id))) {
                    instances += 1;
                };

                try std.testing.expect(position < expected.len);
                try std.testing.expectEqualDeep(
                    expected[position],
                    Snapshot{
                        .name = record.name,
                        .priority = record.priority,
                        .registered_at = record.registered_at,
                        .references = refs.count,
                        .instances = instances,
                    },
                );

                position += 1;
            }

            try std.testing.expectEqual(expected.len, position);
            const default_name = if (runtime.default_pickup_registration) |id| runtime.registrations.items[id].name else null;
            try std.testing.expectEqualDeep(default, default_name);
        }
    }
}

test "default pickup replacement preserves unresolved name comparisons" {
    const a = std.testing.allocator;
    const name = "TRAINDR2.WAV.WAV";
    var data = [_]u8{0} ** 49;

    @memcpy(data[0..4], "LABN");

    std.mem.writeInt(u32, data[4..8], 0x10000, .little);
    std.mem.writeInt(u32, data[8..12], 1, .little);
    std.mem.writeInt(u32, data[12..16], name.len + 1, .little);
    std.mem.writeInt(u32, data[28..32], 0x57415644, .little);

    @memcpy(data[32..][0..name.len], name);
    const empty: lab.Archive = .{ .data = "", .entries = "", .strings = "" };

    for ([_]bool{ true, false }) |shipped| {
        const runtime = try a.create(Runtime);

        runtime.* = .{
            .allocator = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .archives = .{ if (shipped) try lab.Archive.init(&data) else empty, empty, empty },
            .directory = "",
            .music_directory = "",
            .loops = .init(a),
        };

        defer runtime.deinit();
        _ = try runtime.replaceDefaultPickup(name, 100);

        const replacement = try runtime.replaceDefaultPickup(name, 200);
        try std.testing.expectEqual(
            @as(u32, 200),
            runtime.registrations.items[replacement].registered_at,
        );

        _ = runtime.allocateInstance(replacement).?;

        if (shipped) {
            try std.testing.expectError(
                error.UnresolvedOriginalSoundNameTail,
                runtime.replaceDefaultPickup(name, 300),
            );

            try std.testing.expectEqual(@as(?u32, null), runtime.default_pickup_registration);
        } else {
            const third = try runtime.replaceDefaultPickup(name, 300);

            try std.testing.expect(third != replacement);
            try std.testing.expectEqual(
                @as(u32, 300),
                runtime.registrations.items[third].registered_at,
            );

            try std.testing.expectEqual(@as(?u32, third), runtime.default_pickup_registration);
        }

        try std.testing.expect(runtime.registration_refs.items[replacement].active);
        try std.testing.expectEqual(
            @as(i32, 0),
            runtime.registration_refs.items[replacement].count,
        );
    }
}

test "mission popup music pause preserves the reference CD deadline and nested calls" {
    const a = std.testing.allocator;
    var runtime: Runtime = .{
        .allocator = a,
        .arena = std.heap.ArenaAllocator.init(a),
        .archives = undefined,
        .directory = "",
        .music_directory = "",
        .loops = std.AutoHashMap(usize, Runtime.Handle).init(a),
    };

    defer runtime.arena.deinit();
    defer runtime.loops.deinit();

    runtime.music_deadline = 201882;
    const effect = (try runtime.engine.start(0, 11025, .{ .flags = .{ .effects = true } }, 1000)).?;
    runtime.pauseMusic(6000);

    try std.testing.expectEqual(@as(?u32, 195882), runtime.music_pause_remaining);
    try std.testing.expect(runtime.engine.find(effect).?.playing);

    runtime.pauseMusic(7000);
    try runtime.advanceMusic(std.testing.io, 300000);

    try std.testing.expectEqual(@as(u64, 0), runtime.music_generation);
    runtime.resumeMusic(299999);
    try std.testing.expect(runtime.musicPaused());
    runtime.resumeMusic(300000);

    try std.testing.expect(!runtime.musicPaused());
    try std.testing.expectEqual(@as(?u32, 496882), runtime.music_deadline);

    runtime.resumeMusic(400000);
    try std.testing.expectEqual(@as(?u32, 496882), runtime.music_deadline);
    runtime.endLevel();

    try std.testing.expect(runtime.engine.find(effect) == null);
    try std.testing.expect(runtime.music_deadline == null);

    runtime.pauseMusic(0);
    runtime.resumeMusic(10000);

    try std.testing.expect(runtime.music_deadline == null);
}

test "cancelled campaign starts Hideout ambient with each campaign difficulty" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";

    inline for (.{ "OUTLAWS.LAB", "OLGEO.LAB", "OLSFX.LAB", "OLTAUNT.LAB" }) |name| {
        std.Io.Dir.cwd().access(
            io,
            "inputs/OUTLAWS_CD1/OUTLAWS/" ++ name,
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
    }

    const system_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        a,
        .limited(64 * 1024 * 1024),
    );

    defer a.free(system_bytes);
    const system = try lab.Archive.init(system_bytes);
    const geometry_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(64 * 1024 * 1024),
    );

    defer a.free(geometry_bytes);
    const resources = try lab.Archive.init(geometry_bytes);
    var geometry = try level.Level.parse(a, try resources.find("HIDEOUT.LVB", 0));
    defer geometry.deinit();
    var objects = try level.Objects.parse(a, try resources.find("HIDEOUT.OBB", 0));
    defer objects.deinit();

    for ([_]campaign.Difficulty{ .good, .bad, .ugly }) |difficulty| {
        var startup = try campaign.Startup.prepare(a, system, difficulty);
        defer startup.deinit(a);

        try std.testing.expect(startup.currentEvent().?.kind == .movie);
        try startup.finishMovie(true);
        const selected = try startup.selectLevel();

        try std.testing.expect(std.ascii.eqlIgnoreCase(selected.name, "hideout"));
        try std.testing.expectEqual(@as(usize, 1), startup.cancelled_movies);

        const runtime = try Runtime.open(a, io, path, system);
        defer runtime.deinit();

        try runtime.beginAmbient(&geometry, &objects, startup.difficulty);
        try runtime.advanceAmbient(1, geometry.sectors[0].layer);

        try std.testing.expectEqual(@as(usize, 0), runtime.ambient.?.sources.len);
    }
}

test "queued audio uses emission state and retries only never-started loops" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const runtime = Runtime.open(
        a,
        std.testing.io,
        path,
        try lab.Archive.init(bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer runtime.deinit();

    try std.testing.expectError(
        error.MissingSoundInstanceOwner,
        runtime.play(.{ .basename = "RIFLOUT", .mode = .loop }, null, 99),
    );

    try std.testing.expectEqual(@as(u32, 0), runtime.engine.next_id);

    const current: sound.Listener = .{};
    var request: Request = .{
        .basename = "RIFLOUT",
        .position = .{ .x = 200, .y = 0, .z = 0 },
        .sector = 0,
        .volume = 63,
        .flags = .{ .loop = true },
        .source = 0,
        .mode = .loop,
        .occlusion_applied = true,
        .listener = .{ .position = .{ 200, 0, 0 } },
    };

    const captured = (try runtime.play(request, null, 100)).?;

    try std.testing.expectEqual(@as(i32, 28), runtime.engine.find(captured).?.effective_volume);
    try std.testing.expectEqual(current, runtime.engine.listener);

    try runtime.engine.updateListener(current);

    try std.testing.expectEqual(@as(i32, 1), runtime.engine.find(captured).?.effective_volume);
    try std.testing.expectEqual(@as(i8, 63), runtime.engine.find(captured).?.params.volume);

    request.source = 1;
    request.listener = current;

    try std.testing.expectEqual(@as(?u32, null), try runtime.play(request, null, 101));
    try std.testing.expect(!runtime.loops.contains(1));

    request.mode = .update;
    request.position = .{ .x = 0, .y = 0, .z = 0 };

    const retry = (try runtime.play(request, null, 102)).?;
    try std.testing.expectEqual(@as(u32, 3), retry);
    runtime.engine.stop(retry);

    try std.testing.expectEqual(@as(?u32, null), try runtime.play(request, null, 103));
    try std.testing.expectEqual(@as(u32, 3), runtime.engine.next_id);

    request.mode = .stop;
    _ = try runtime.play(request, null, 104);

    try std.testing.expect(!runtime.loops.contains(1));
}

test "ambient runtime preserves failed admission and shared resource loop state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        a,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const runtime = Runtime.open(
        a,
        io,
        path,
        try lab.Archive.init(bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer runtime.deinit();
    const geometry_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(128 * 1024 * 1024),
    );

    defer a.free(geometry_bytes);
    const archive = try lab.Archive.init(geometry_bytes);
    var geometry = try level.Level.parse(a, try archive.find("HIDEOUT.LVB", 0));
    defer geometry.deinit();
    var objects = try level.Objects.parse(a, try archive.find("HIDEOUT.OBB", 0));
    defer objects.deinit();

    geometry.sectors[0].layer = 0;
    objects.entries[0].name = "BELL";
    objects.entries[0].sector_id = geometry.sectors[0].id;
    objects.entries[0].position = .{ .x = 0, .y = 0, .z = 0 };
    objects.entries[0].flags = .{ .sound_only = true };
    objects.entries[0].availability = .{ .difficulties = .{ .bad = true } };

    try runtime.beginAmbient(&geometry, &objects, .bad);
    try std.testing.expectEqual(@as(usize, 1), runtime.ambient.?.sources.len);
    runtime.engine.effects_volume = 0;
    try runtime.advanceAmbient(1, 0);

    try std.testing.expect(runtime.ambient.?.sources[0].entered);
    try std.testing.expectEqual(@as(u32, 1), runtime.ambient.?.sources[0].handle);

    runtime.engine.effects_volume = 58;
    try runtime.advanceAmbient(502, 0);

    try std.testing.expectEqual(@as(u32, 1), runtime.ambient.?.sources[0].handle);
    try std.testing.expectEqual(@as(u32, 1), runtime.engine.next_id);

    try runtime.advanceAmbient(1003, 1);
    try runtime.advanceAmbient(1504, 0);

    const ambient_handle = runtime.ambient.?.sources[0].handle;
    try std.testing.expectEqual(
        @as(u32, 0x10015),
        bits.word(runtime.engine.find(ambient_handle).?.params.flags),
    );

    const second = (try runtime.play(.{ .basename = "BELL" }, null, 1505)).?;
    try std.testing.expect(runtime.engine.find(second).?.params.flags.loop);

    runtime.ambient.?.sources[0].handle = second;
    try runtime.advanceAmbient(2005, 1);

    try std.testing.expect(runtime.engine.find(second) == null);
    try std.testing.expect(!runtime.ambient.?.sources[0].entered);
}
