//! Registering the sounds a level's actors and scripts will ask for.
//!
//! Constructors register before anything is ever played, and a session can
//! exist before the host audio device is attached - so registrations are
//! kept with their clocks and replayed once the device arrives.

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const Registration = @import("runtime.zig").Registration;
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const inventory = @import("../player/inventory.zig");
const object_state = @import("../render/object_state.zig");
const enemy = @import("../enemy/config.zig");

const fx_sounds = [_]struct { name: []const u8, priority: u8 }{
    .{ .name = "bubbles1.wav", .priority = 1 }, .{ .name = "bubbles2.wav", .priority = 1 },
    .{ .name = "bubbles3.wav", .priority = 1 }, .{ .name = "bubbles4.wav", .priority = 1 },
    .{ .name = "bubbles5.wav", .priority = 1 }, .{ .name = "smsplash.wav", .priority = 64 },
    .{ .name = "splash.wav", .priority = 64 },  .{ .name = "explode.wav", .priority = 107 },
    .{ .name = "ricochet.wav", .priority = 1 },
};

pub const Ledger = struct {
    records: std.ArrayList(Registration) = .empty,
    enemy_templates: std.ArrayList([]const u8) = .empty,
    enemy_sound_templates: std.ArrayList([]const u8) = .empty,
    projectile_templates: std.ArrayList([]const u8) = .empty,
    projectile_sounds: std.ArrayList([2]?[]const u8) = .empty,
    audio: ?*Runtime = null,
    flushed: usize = 0,
    allocator: ?std.mem.Allocator = null,
    phase: enum { level, startup, doors } = .level,
    handles: std.ArrayList(Handle) = .empty,
    operations: std.ArrayList(union(enum) { register: usize, replace_pickup: usize, release: usize }) = .empty,

    const Handle = struct {
        id: ?u32 = null,
        released: bool = false,
        default_pickup: bool = false,
        phase: @FieldType(Ledger, "phase"),
    };

    pub fn append(self: *Ledger, a: std.mem.Allocator, name: []const u8, priority: u8, now: u32, flags: u32) !void {
        return self.appendRegistration(a, name, priority, now, flags, false);
    }

    pub fn replaceDefaultPickup(self: *Ledger, a: std.mem.Allocator, name: []const u8, now: u32) !void {
        return self.appendRegistration(a, name, 64, now, 0, true);
    }

    pub fn bind(self: *Ledger, audio: *Runtime) !void {
        if (self.audio != audio) self.flushed = 0;
        self.audio = audio;
        const skip_startup = audio.startup_registered;
        const skip_doors = audio.doors_registered;
        var startup_seen = false;
        var doors_seen = false;
        while (self.flushed < self.operations.items.len) : (self.flushed += 1) switch (self.operations.items[self.flushed]) {
            .register, .replace_pickup => |index| {
                const handle = &self.handles.items[index];
                switch (handle.phase) {
                    .startup => {
                        startup_seen = true;
                        if (skip_startup) continue;
                    },
                    .doors => {
                        doors_seen = true;
                        if (skip_doors) continue;
                    },
                    .level => {},
                }
                const record = self.records.items[index];
                const id = if (self.operations.items[self.flushed] == .replace_pickup)
                    try audio.replaceDefaultPickup(record.name, record.registered_at)
                else
                    try audio.declare(record.name, record.resource_type, record.priority, record.registered_at);
                handle.id = id;
                audio.registrations.items[id].flags |= record.flags & ~@as(u32, 0x10000);
            },
            .release => |index| if (self.handles.items[index].id) |id| audio.releaseRegistration(id),
        };
        audio.startup_registered = audio.startup_registered or startup_seen;
        audio.doors_registered = audio.doors_registered or doors_seen;
    }

    pub fn releaseIfOwned(self: *Ledger, name: []const u8) bool {
        var index = self.records.items.len;
        while (index != 0) {
            index -= 1;
            if (self.handles.items[index].phase != .level or self.handles.items[index].default_pickup or self.handles.items[index].released or !std.ascii.eqlIgnoreCase(self.records.items[index].name, name)) continue;
            self.handles.items[index].released = true;
            self.operations.append(self.allocator.?, .{ .release = index }) catch @panic("sound ownership ledger allocation failed");
            if (self.audio) |audio| {
                if (self.flushed + 1 == self.operations.items.len) {
                    if (self.handles.items[index].id orelse audio.lookup(name)) |id| audio.releaseRegistration(id);
                    self.flushed += 1;
                }
            }
            return true;
        }
        return false;
    }

    pub fn release(self: *Ledger, name: []const u8) void {
        if (self.releaseIfOwned(name)) return;
        if (self.audio) |audio| if (audio.lookup(name)) |id| {
            audio.releaseRegistration(id);
            return;
        };
        @panic("release without an original sound constructor");
    }

    pub fn clone(self: Ledger, a: std.mem.Allocator) !Ledger {
        var copy: Ledger = .{ .allocator = a, .phase = self.phase };
        errdefer copy.deinit(a);
        for (self.records.items) |record| {
            var owned = record;
            owned.name = try a.dupe(u8, record.name);
            try copy.records.append(a, owned);
        }
        try copy.handles.appendSlice(a, self.handles.items);
        for (copy.handles.items) |*handle| handle.id = null;
        try copy.operations.appendSlice(a, self.operations.items);
        return copy;
    }

    pub fn deinit(self: *Ledger, a: std.mem.Allocator) void {
        for (self.records.items) |record| a.free(record.name);
        self.records.deinit(a);
        self.handles.deinit(a);
        self.operations.deinit(a);
    }

    fn appendRegistration(self: *Ledger, a: std.mem.Allocator, name: []const u8, priority: u8, now: u32, flags: u32, default_pickup: bool) !void {
        self.allocator = a;
        try self.handles.ensureUnusedCapacity(a, 1);
        try self.operations.ensureUnusedCapacity(a, 1);
        try self.records.append(a, .{ .name = try a.dupe(u8, name), .priority = priority, .registered_at = now, .flags = 0x10000 | flags });
        self.handles.appendAssumeCapacity(.{ .phase = self.phase, .default_pickup = default_pickup });
        const index = self.records.items.len - 1;
        self.operations.appendAssumeCapacity(if (default_pickup) .{ .replace_pickup = index } else .{ .register = index });
        if (self.audio) |audio| try self.bind(audio);
    }
};

pub fn startup(ledger: *Ledger, a: std.mem.Allocator, system: lab.Archive, now: u32) !void {
    const bytes = try system.find("SOUNDS.LST", 0);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const index = tokens.next() orelse continue;
        _ = std.fmt.parseInt(i32, index, 10) catch continue;
        const priority = tokens.next() orelse return error.InvalidIndexedSounds;
        const name = tokens.next() orelse return error.InvalidIndexedSounds;
        if (priority.len != 1) return error.InvalidIndexedSounds;
        try ledger.append(a, name, switch (priority[0]) {
            'H' => 107,
            'M' => 64,
            else => 1,
        }, now, 0);
    }
    var global = try Item.parse(a, try system.find("OUTLAWS.ITM", 0));
    defer global.deinit();
    try defaultPickup(ledger, a, &global, now);
}

pub fn initial(session: anytype, cid: *const Item, now: u32, retained_audio: ?*Runtime) !void {
    const a = session.arena.allocator();
    const ledger = &session.sound_ledger;
    try restoreOpen(session, now);
    const archives = [_]lab.Archive{ session.object_archive, session.weapon_archive, session.geometry_archive, session.system_archive };
    const level_name = try std.fmt.allocPrint(a, "{s}.ITM", .{session.level_name});
    if (try find(&archives, level_name)) |bytes| {
        var level_item = try Item.parse(a, bytes);
        defer level_item.deinit();
        try defaultPickup(ledger, a, &level_item, now);
        if (try level_item.stringValue("SND_REDWON")) |name| try basename(ledger, a, name, 107, now) else try ledger.append(a, "hornblo4.wav", 107, now, 0);
        if (try level_item.stringValue("SND_BLUEWON")) |name| try basename(ledger, a, name, 107, now) else try ledger.append(a, "hornblo1.wav", 107, now, 0);
        try field(ledger, a, &level_item, "SND_DOCWON", 107, now);
        try field(ledger, a, &level_item, "SND_TAGTRANS", 107, now);
    } else {
        try ledger.append(a, "hornblo4.wav", 107, now, 0);
        try ledger.append(a, "hornblo1.wav", 107, now, 0);
    }
    var sanchez_created = false;
    for (session.objects.entries) |object| {
        if (object.flags[1] & session.difficulty_mask == 0 or session.level.sectorIndex(object.sector_id) == null) continue;
        if (object.flags[0] & 1 != 0) {
            const name = try std.fmt.allocPrint(a, "{s}.wav", .{object.name});
            try ledger.append(a, name, 64, now, 1);
            continue;
        }
        const name = try std.fmt.allocPrint(a, "{s}.ITM", .{std.fs.path.stem(object.name)});
        var definition = try Item.parse(a, try find(&archives, name) orelse continue);
        defer definition.deinit();
        if (std.mem.eql(u8, definition.function, "Sanchez_New") or std.mem.eql(u8, definition.function, "TwoFeathers_New")) {
            if (sanchez_created) continue;
            sanchez_created = true;
        }
        try actor(ledger, a, &archives, &definition, session.difficulty_mask >> 8, now);
    }
    const inf_name = try std.fmt.allocPrint(a, "{s}.INF", .{session.level_name});
    try infSounds(ledger, a, try session.geometry_archive.find(inf_name, 0), now);
    try player(session, cid, now);
    {
        if (session.inventory.slots[1]) |*owned| if (!owned.sounds_registered) {
            try ownedItem(ledger, a, owned.definition, owned.acquired_at);
            owned.sounds_registered = true;
        };
        var buffer: [32]u8 = undefined;
        for (1..20) |i| {
            const name = (try cid.stringValue(try std.fmt.bufPrint(&buffer, "START_ITEM_{d}", .{i}))) orelse break;
            const slot = session.inventory.find(name);
            if (slot != 0) {
                const owned = &session.inventory.slots[slot].?;
                if (!owned.sounds_registered) {
                    try ownedItem(ledger, a, owned.definition, owned.acquired_at);
                    owned.sounds_registered = true;
                }
            }
        }
    }
    if (retained_audio) |audio| try session.bindAudio(audio);
    session.bindInventorySounds();
    try session.applyPlayerBindFlags(cid);
    try playerBlips(session, now);
}

pub fn player(session: anytype, cid: *const Item, now: u32) !void {
    const a = session.arena.allocator();
    const ledger = &session.sound_ledger;
    const voices = .{
        .{ "SND_JUMP", "jajump.wav" },       .{ "SND_LAND", "land.wav" },        .{ "SND_LANDLT", "landlite.wav" },
        .{ "SND_HITHEAD", "hithead.wav" },   .{ "SND_CRUSH", "crush.wav" },      .{ "SND_SPLAT", "splat.wav" },
        .{ "SND_CRUNCH", "crunch.wav" },     .{ "SND_DIE", "jadie.wav" },        .{ "SND_CHOKE", "choke.wav" },
        .{ "SND_WATERDIE", "waterdie.wav" }, .{ "SND_LIGHTLAMP", "light.wav" },  .{ "SND_ARMOR1HIT", "armor1.wav" },
        .{ "SND_ARMOR2HIT", "armor2.wav" },  .{ "SND_ARMOR3HIT", "armor3.wav" }, .{ "SND_TIRED", "tired.wav" },
        .{ "SND_GASP", "gasp.wav" },         .{ "SND_SHRIEK", "shriek.wav" },    .{ "SND_SPLASH", "smsplash.wav" },
        .{ "SND_GOTSHOT", "gotshot.wav" },
    };
    inline for (voices, 0..) |voice, index| {
        const name = try a.dupe(u8, (try cid.stringValue(voice[0])) orelse voice[1]);
        session.player_sound_names[index] = name;
        try ledger.append(a, name, 107, now, 0);
    }
    session.player_sound_names[19] = "jetpack.wav";
    try ledger.append(a, "jetpack.wav", 107, now, 1);
}

pub fn playerBlips(session: anytype, now: u32) !void {
    for (20..22) |index| {
        session.player_sound_names[index] = "blip.wav";
        try session.registerSound("blip.wav", 64, now);
    }
}

pub fn restoreOpen(session: anytype, now: u32) !void {
    const a = session.arena.allocator();
    const ledger = &session.sound_ledger;
    ledger.* = .{};
    ledger.phase = .startup;
    try startup(ledger, a, session.system_archive, now);
    ledger.phase = .level;
    for (fx_sounds) |entry| try ledger.append(a, entry.name, entry.priority, now, 0);
    try ledger.append(a, "get.wav", 1, now, 0);
    try ledger.append(a, "cashopen.wav", 30, now, 0);
    try ledger.append(a, "cashcls.wav", 30, now, 0);
    for (session.texture_animations.programs, 0..) |program, index| if (program) |value| {
        if (!@import("level_ownership.zig").firstTextureUse(session.level.textures, index)) continue;
        for (value.animation.instructions) |instruction| if (instruction == .start_sound) {
            const sound = instruction.start_sound;
            try basename(ledger, a, sound.name, sound.priority, now);
        };
    };
    var doors_seen = false;
    for (session.level.sectors) |sector| {
        if (sector.floor_sound.len != 0 and !std.mem.eql(u8, sector.floor_sound, "NULL")) try basename(ledger, a, sector.floor_sound, 1, now);
        if (sector.flags & 0x100 != 0 and !doors_seen) {
            doors_seen = true;
            ledger.phase = .doors;
            for ([_][]const u8{ "door1.wav", "door2.wav", "door3.wav", "door4.wav", "door5.wav", "doorcls.wav", "locked.wav" }) |name| try ledger.append(a, name, 12, now, 0);
            ledger.phase = .level;
        }
    }
}

pub fn closeFx(session: anytype) void {
    for (fx_sounds) |entry| session.releaseSound(entry.name);
}

pub fn closeHud(session: anytype) void {
    session.releaseSound("cashopen.wav");
    session.releaseSound("cashcls.wav");
}

pub fn actor(ledger: *Ledger, a: std.mem.Allocator, archives: []const lab.Archive, item: *const Item, difficulty: u32, now: u32) !void {
    if (std.mem.eql(u8, item.function, "shot_ProjectileDispatch")) {
        const name = try item.stringValue("PROJECTILE") orelse return error.MissingProjectileConfiguration;
        const path = try std.fmt.allocPrint(a, "{s}.ITM", .{std.fs.path.stem(name)});
        var projectile = try Item.parse(a, try find(archives, path) orelse return error.MissingProjectileConfiguration);
        defer projectile.deinit();
        try projectileTemplate(ledger, a, &projectile, name, now);
        if (try projectile.stringValue("DEAD_ITEM")) |dead_name| {
            var dead = try Item.parse(a, try find(archives, dead_name) orelse return error.MissingInventoryItem);
            defer dead.deinit();
            try field(ledger, a, &dead, "PICKUP_SOUND", 64, now);
        }
        return;
    }
    switch (try object_state.classify(item)) {
        .ground, .instant => try field(ledger, a, item, "PICKUP_SOUND", 64, now),
        .enemy, .chicken, .civilian, .slim, .sanchez => {
            try enemyTemplate(ledger, a, archives, item, now);
            try enemySounds(ledger, a, item.name, try enemy.Config.load(a, archives, item, difficulty), now);
        },
        .generator => {
            const kind = (try item.stringValue("TYPE")) orelse "";
            if (std.ascii.eqlIgnoreCase(kind, "POINT_SOUND") or std.ascii.eqlIgnoreCase(kind, "AMB_SOUND") or std.ascii.eqlIgnoreCase(kind, "AMB_SOUND_INDOOR")) {
                const name = try item.stringValue("GENERATE") orelse return error.GeneratorMissingGeneratee;
                try ledger.append(a, name[0..@min(name.len, 14)], 1, now, 0);
            }
        },
        else => {},
    }
}

pub fn enemyTemplate(ledger: *Ledger, a: std.mem.Allocator, archives: []const lab.Archive, item: *const Item, now: u32) !void {
    for (ledger.enemy_templates.items) |name| if (std.ascii.eqlIgnoreCase(name, item.name)) return;
    try ledger.enemy_templates.append(a, try a.dupe(u8, item.name));
    try taunts(ledger, a, archives, item, now, 0);
}

pub fn enemySounds(ledger: *Ledger, a: std.mem.Allocator, template_name: []const u8, configuration: enemy.Config, now: u32) !void {
    for (ledger.enemy_sound_templates.items) |name| if (std.ascii.eqlIgnoreCase(name, template_name)) return;
    try ledger.enemy_sound_templates.append(a, try a.dupe(u8, template_name));
    for ([_][]const u8{ configuration.shoot_sound, configuration.hit_sound, configuration.die_sound }) |name|
        if (name.len != 0) try ledger.append(a, name, 107, now, 0);
}

pub fn projectileTemplate(ledger: *Ledger, a: std.mem.Allocator, item: *const Item, name: []const u8, now: u32) !void {
    const canonical = try @import("../projectile/runtime.zig").configName(a, name);
    for (ledger.projectile_templates.items) |existing| if (std.mem.eql(u8, existing, canonical)) return;
    try ledger.projectile_templates.append(a, canonical);
    var sounds: [2]?[]const u8 = @splat(null);
    for ([_][]const u8{ "FUSE_SOUND", "EXPLODE_SOUND" }, 0..) |key, index| if (try item.stringValue(key)) |value| {
        sounds[index] = try std.fmt.allocPrint(a, "{s}.wav", .{value});
        try ledger.append(a, sounds[index].?, 0, now, 0);
    };
    try ledger.projectile_sounds.append(a, sounds);
}

pub fn closeProjectiles(session: anytype) void {
    for (session.sound_ledger.projectile_sounds.items) |sounds| for (sounds) |name| if (name) |value| session.releaseSound(value);
    for (session.projectile_slots, 0..) |state, source| if (state != null) session.releasePickupSound(source);
}

pub fn ownedItem(ledger: *Ledger, a: std.mem.Allocator, definition: inventory.Definition, now: u32) !void {
    if (definition.weapon) |weapon| {
        for (0..3) |i| for ([_]?[]const u8{ weapon.fire_sound[i], weapon.empty_sound[i], weapon.action_sound[i] }) |entry|
            if (entry) |name| try basename(ledger, a, name, 0, now);
        if (weapon.reload_sound) |name| try basename(ledger, a, name, 0, now);
        if (weapon.extra_sound) |name| try basename(ledger, a, name, 0, now);
    } else {
        if (definition.use_success_sound) |name| try basename(ledger, a, name, 0, now);
        if (definition.use_failure_sound) |name| try basename(ledger, a, name, 0, now);
        if (definition.health_sound) |name| try basename(ledger, a, name, 0, now);
    }
}

pub fn basename(ledger: *Ledger, a: std.mem.Allocator, name: []const u8, priority: u8, now: u32) !void {
    var buffer: [256]u8 = undefined;
    try ledger.append(a, try std.fmt.bufPrint(&buffer, "{s}.wav", .{name}), priority, now, 0);
}

fn infSounds(ledger: *Ledger, a: std.mem.Allocator, bytes: []const u8, now: u32) !void {
    var lines: @import("../assets/item.zig").Lines = .{ .bytes = bytes };
    var elevator = false;
    while (try lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const key = words.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(key, "CLASS:")) {
            elevator = std.ascii.eqlIgnoreCase(words.next() orelse return error.MissingInfClass, "ELEVATOR");
        } else if (std.ascii.eqlIgnoreCase(key, "SOUND:")) {
            if (elevator) _ = words.next() orelse return error.MissingInfSound;
            const name = words.next() orelse return error.MissingInfSound;
            if (!std.ascii.isDigit(name[0])) try ledger.append(a, name, 12, now, 0);
        } else if (elevator and std.ascii.eqlIgnoreCase(key, "PAGE:")) {
            _ = words.next() orelse return error.MissingInfSound;
            try ledger.append(a, words.next() orelse return error.MissingInfSound, 127, now, 0);
        }
    }
}

fn taunts(ledger: *Ledger, a: std.mem.Allocator, archives: []const lab.Archive, item: *const Item, now: u32, depth: usize) !void {
    if (depth >= 32) return error.InvalidEnemyInheritance;
    if (try item.stringValue("INHERIT")) |name| if (try find(archives, name)) |bytes| {
        var parent = try Item.parse(a, bytes);
        defer parent.deinit();
        try taunts(ledger, a, archives, &parent, now, depth + 1);
    };
    for ([_][]const u8{ "LOS_TAUNTS", "NO_LOS_TAUNTS", "ALERT_TAUNTS" }) |field_name| if (try item.stringValue(field_name)) |list| {
        var tokens = std.mem.tokenizeAny(u8, list, ", ");
        while (tokens.next()) |name| try ledger.append(a, name, 1, now, 0);
    };
}

fn field(ledger: *Ledger, a: std.mem.Allocator, item: *const Item, key: []const u8, priority: u8, now: u32) !void {
    if (try item.stringValue(key)) |name| try basename(ledger, a, name, priority, now);
}

fn defaultPickup(ledger: *Ledger, a: std.mem.Allocator, item: *const Item, now: u32) !void {
    if (try item.stringValue("DEFSND_PICKUP")) |name| {
        var buffer: [256]u8 = undefined;
        try ledger.replaceDefaultPickup(a, try std.fmt.bufPrint(&buffer, "{s}.wav", .{name}), now);
    }
}

fn find(archives: []const lab.Archive, name: []const u8) !?[]const u8 {
    for (archives) |archive| return archive.find(name, 0) catch |err| switch (err) {
        error.ResourceNotFound => continue,
        else => return err,
    };
    return null;
}

test "default pickup replacement survives headless replay and runs startup once" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/sound-lifetime-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Snapshot = struct {
        name: []const u8,
        priority: u8,
        registered_at: u32,
        references: i32,
        instances: u32,
    };
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []struct {
        operations: []struct { op: []const u8, name: []const u8, now: u32 = 0, priority: u8 = 0 },
        snapshots: [][]Snapshot,
        defaults: []?[]const u8,
    } };
    const parsed = try std.json.parseFromSlice(Corpus, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", parsed.value.executable_sha256);
    try std.testing.expectEqualStrings("5c8aa903e8c9c00a9cabd62765417bc32f4fc1e3cc16138361b5a76efc086c68", parsed.value.results_sha256);
    const runtime = try a.create(Runtime);
    runtime.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .archives = undefined, .directory = "", .music_directory = "", .loops = .init(a) };
    defer runtime.deinit();
    const case = parsed.value.cases[3];
    for (case.operations, case.snapshots, case.defaults, 0..) |op, expected, default, index| {
        try std.testing.expectEqualStrings("replace", op.op);
        var ledger: Ledger = .{ .phase = .startup };
        try ledger.replaceDefaultPickup(a, case.operations[0].name, case.operations[0].now);
        if (index != 0) {
            ledger.phase = .level;
            try ledger.replaceDefaultPickup(a, op.name, op.now);
        }
        var retained = try ledger.clone(a);
        ledger.deinit(a);
        defer retained.deinit(a);
        try retained.bind(runtime);
        try std.testing.expect(!retained.releaseIfOwned(op.name));
        var position: usize = 0;
        for (runtime.registrations.items, runtime.registration_refs.items) |record, refs| {
            if (!refs.active) continue;
            try std.testing.expect(position < expected.len);
            try std.testing.expectEqualDeep(expected[position], Snapshot{ .name = record.name, .priority = record.priority, .registered_at = record.registered_at, .references = refs.count, .instances = 0 });
            position += 1;
        }
        try std.testing.expectEqual(expected.len, position);
        try std.testing.expectEqualStrings(default.?, runtime.registrations.items[runtime.default_pickup_registration.?].name);
    }
}

test "constructor sound registrations preserve order priority and names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/audio-registration-reference.json", a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { kind: []const u8, name: []const u8, sounds: []Registration },
    };
    const corpus = (try std.json.parseFromSlice(Corpus, a, json, .{})).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("5eaa9d8b7a18bc06c6beee41791907a60cc02237a68c152886f949b49fcabc9a", corpus.results_sha256);
    var archives: [3]lab.Archive = undefined;
    for ([_][]const u8{ "OLOBJ", "OLWEAP", "OUTLAWS" }, &archives) |name, *archive| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        archive.* = try lab.Archive.init(try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)));
    }
    for (corpus.cases) |case| {
        errdefer std.debug.print("reference sound constructor {s} {s}\n", .{ case.kind, case.name });
        var ledger: Ledger = .{};
        if (std.mem.eql(u8, case.kind, "owned")) {
            try ownedItem(&ledger, a, try inventory.Definition.load(a, &archives, case.name), 1000);
        } else {
            const path = try std.fmt.allocPrint(a, "{s}.ITM", .{case.name});
            var definition = try Item.parse(a, (try find(&archives, path)).?);
            defer definition.deinit();
            try actor(&ledger, a, &archives, &definition, 0x100000, 1000);
        }
        var unique: std.ArrayList(Registration) = .empty;
        for (ledger.records.items) |record| {
            for (unique.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.name, record.name)) break;
            } else {
                try unique.append(a, record);
            }
        }
        try std.testing.expectEqualDeep(case.sounds, unique.items);
    }
}

test "enemy template sound ownership is cached across repeated constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/actor-audio-ownership-reference.json", a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Sound = struct {
        name: []const u8,
        resource_type: u32,
        priority: u8,
    };
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, enemies: []struct { name: []const u8, calls: []Sound, stage_counts: []usize, releases: [][]const u8 }, fx: struct { calls: []Sound, releases: [][]const u8 } };
    const corpus = (try std.json.parseFromSlice(Corpus, a, bytes, .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("26ee1180d4cddf03dc7c4bdd3a7f0088faf4ac6af64f160ebbba2a3adc5e0f2b", corpus.results_sha256);
    var archives: [3]lab.Archive = undefined;
    for ([_][]const u8{ "OLOBJ", "OLWEAP", "OUTLAWS" }, &archives) |name, *resource| {
        resource.* = try lab.Archive.init(try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name}), a, .limited(64 * 1024 * 1024)));
    }
    for (corpus.enemies) |case| {
        errdefer std.debug.print("reference cached sound template {s}\n", .{case.name});
        var definition = try Item.parse(a, (try find(&archives, try std.fmt.allocPrint(a, "{s}.ITM", .{case.name}))).?);
        defer definition.deinit();
        var ledger: Ledger = .{};
        for (case.stage_counts, 0..) |count, stage| {
            try actor(&ledger, a, &archives, &definition, 0x100000, 1000 + @as(u32, @intCast(stage)));
            try std.testing.expectEqual(count, ledger.records.items.len);
        }
        for (case.calls, ledger.records.items) |expected, actual| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            try std.testing.expectEqual(expected.resource_type, actual.resource_type);
            try std.testing.expectEqual(expected.priority, actual.priority);
            try std.testing.expectEqual(@as(u32, 1000), actual.registered_at);
        }
        try std.testing.expectEqual(@as(usize, 0), case.releases.len);
    }
    try std.testing.expectEqual(fx_sounds.len, corpus.fx.calls.len);
    for (corpus.fx.calls, fx_sounds) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.priority, actual.priority);
    }
    const Capture = struct {
        allocator: std.mem.Allocator,
        released: std.ArrayList([]const u8) = .empty,

        pub fn releaseSound(self: *@This(), name: []const u8) void {
            self.released.append(self.allocator, name) catch unreachable;
        }
    };
    var capture: Capture = .{ .allocator = a };
    closeFx(&capture);
    try std.testing.expectEqualDeep(corpus.fx.releases, capture.released.items);
}
