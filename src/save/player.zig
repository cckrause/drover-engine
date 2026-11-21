//! Saving the player: inventory, weapons, and the sound and sprite records
//! that belong to them.
//!
//! The shared inventory allocation and its records come before the extended
//! weapon block. A restore reads every field before it applies any of them,
//! so a short file cannot leave the player half-updated.

const std = @import("std");
const stream = @import("stream.zig");
const costume = @import("costume.zig");
const sound = @import("sound.zig");
const cmm = @import("../script/cmm.zig");
const Mode = @import("../player/weapon_config.zig").Mode;
const inventory_module = @import("../player/inventory.zig");
const weapon_config = @import("../player/weapon_config.zig");

pub const Weapon = struct {
    native_88: []const u8,
    costume_name: []const u8,
    native_e8: []const u8,
    scope_item: []const u8,
    has_scope: bool,
    scope_x: i32,
    scope_y: i32,
    rest: i16,
    fire: [3]i16,
    empty: [3]i16,
    reload: i16,
    extra: i16,
    scope_rest: i16,
    scope_fire: [3]i16,
    scope_empty: [3]i16,
    fire_sound: [3]?sound.Record,
    empty_sound: [3]?sound.Record,
    action_sound: [3]?sound.Record,
    reload_sound: ?sound.Record,
    extra_sound: ?sound.Record,
    modes: [3]Mode,
    flash: i32,
    kick: f32,
    infinite: bool,
    auto_reload: bool,
    loaded: i32,
    capacity: i32,
    multiples: i32,
    projectile: []const u8,
    ammo: []const u8,

    pub fn write(self: Weapon, writer: *stream.Writer) !void {
        inline for (.{ "native_88", "costume_name", "native_e8", "scope_item" }) |field| try writer.string(@field(self, field));
        try writer.boolean(self.has_scope);
        try writer.integer(i32, self.scope_x);
        try writer.integer(i32, self.scope_y);
        try writer.integer(i16, self.rest);
        for (self.fire) |value| try writer.integer(i16, value);
        for (self.empty) |value| try writer.integer(i16, value);
        try writer.integer(i16, self.reload);
        try writer.integer(i16, self.extra);
        try writer.integer(i16, self.scope_rest);
        for (self.scope_fire) |value| try writer.integer(i16, value);
        for (self.scope_empty) |value| try writer.integer(i16, value);
        for (self.fire_sound) |value| try sound.write(writer, value);
        for (self.empty_sound) |value| try sound.write(writer, value);
        for (self.action_sound) |value| try sound.write(writer, value);
        try sound.write(writer, self.reload_sound);
        try sound.write(writer, self.extra_sound);
        for (self.modes) |mode| inline for (std.meta.fields(Mode)) |field| try writer.float(@field(mode, field.name));
        try writer.integer(i32, self.flash);
        try writer.float(self.kick);
        try writer.boolean(self.infinite);
        try writer.boolean(self.auto_reload);
        try writer.integer(i32, self.loaded);
        try writer.integer(i32, self.capacity);
        try writer.integer(i32, self.multiples);
        try writer.string(self.projectile);
        try writer.string(self.ammo);
    }

    pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !Weapon {
        var result: Weapon = undefined;
        inline for (.{ "native_88", "costume_name", "native_e8", "scope_item" }) |field| @field(result, field) = try readString(reader, a, if (std.mem.eql(u8, field, "native_88") or std.mem.eql(u8, field, "native_e8")) 63 else 31);
        result.has_scope = try reader.boolean();
        result.scope_x = try reader.integer(i32);
        result.scope_y = try reader.integer(i32);
        result.rest = try reader.integer(i16);
        for (&result.fire) |*value| value.* = try reader.integer(i16);
        for (&result.empty) |*value| value.* = try reader.integer(i16);
        result.reload = try reader.integer(i16);
        result.extra = try reader.integer(i16);
        result.scope_rest = try reader.integer(i16);
        for (&result.scope_fire) |*value| value.* = try reader.integer(i16);
        for (&result.scope_empty) |*value| value.* = try reader.integer(i16);
        for (&result.fire_sound) |*value| value.* = try sound.read(reader, a);
        for (&result.empty_sound) |*value| value.* = try sound.read(reader, a);
        for (&result.action_sound) |*value| value.* = try sound.read(reader, a);
        result.reload_sound = try sound.read(reader, a);
        result.extra_sound = try sound.read(reader, a);
        for (&result.modes) |*mode| {
            inline for (std.meta.fields(Mode)) |field| @field(mode, field.name) = try reader.float();
        }
        result.flash = try reader.integer(i32);
        result.kick = try reader.float();
        result.infinite = try reader.boolean();
        result.auto_reload = try reader.boolean();
        result.loaded = try reader.integer(i32);
        result.capacity = try reader.integer(i32);
        result.multiples = try reader.integer(i32);
        result.projectile = try readString(reader, a, 31);
        result.ammo = try readString(reader, a, 31);
        return result;
    }
};

pub const Inventory = struct {
    allocation_size: u32,
    item_class: u32,
    name: []const u8,
    ground_item: []const u8,
    native: []const u8,
    no_show: bool,
    no_drop: bool,
    wax_resource: []const u8,
    instance: ?costume.Instance,
    success_sound: ?sound.Record,
    failure_sound: ?sound.Record,
    flags: i32,
    count: i32,
    maximum: i32,
    use_id: i32,
    health_sound: ?sound.Record = null,
    weapon: ?Weapon = null,

    pub fn write(self: Inventory, writer: *stream.Writer) !void {
        const function = try cmm.inventoryFunction(self.native);
        try validateSize(self.allocation_size, function);
        try writer.integer(u32, self.allocation_size);
        try writer.integer(u32, self.item_class);
        try writer.string(self.name);
        try writer.string(self.ground_item);
        try writer.string(self.native);
        try writer.boolean(self.no_show);
        try writer.boolean(self.no_drop);
        try writer.string(self.wax_resource);
        try costume.write(writer, self.instance);
        try sound.write(writer, self.success_sound);
        try sound.write(writer, self.failure_sound);
        try writer.integer(i32, self.flags);
        try writer.integer(i32, self.count);
        try writer.integer(i32, self.maximum);
        try writer.integer(i32, self.use_id);
        switch (function) {
            .generic_object => {},
            .health_object => try sound.write(writer, self.health_sound),
            else => try (self.weapon orelse return error.MissingSavedWeapon).write(writer),
        }
    }

    pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !Inventory {
        var result: Inventory = .{
            .allocation_size = try reader.integer(u32),
            .item_class = try reader.integer(u32),
            .name = try readString(reader, a, 31),
            .ground_item = try readString(reader, a, 31),
            .native = try readString(reader, a, 31),
            .no_show = try reader.boolean(),
            .no_drop = try reader.boolean(),
            .wax_resource = try readString(reader, a, 255),
            .instance = try costume.read(reader, a),
            .success_sound = try sound.read(reader, a),
            .failure_sound = try sound.read(reader, a),
            .flags = try reader.integer(i32),
            .count = try reader.integer(i32),
            .maximum = try reader.integer(i32),
            .use_id = try reader.integer(i32),
        };
        const function = try cmm.inventoryFunction(result.native);
        try validateSize(result.allocation_size, function);
        switch (function) {
            .generic_object => {},
            .health_object => result.health_sound = try sound.read(reader, a),
            else => result.weapon = try Weapon.read(reader, a),
        }
        return result;
    }
};

pub const State = struct {
    character: u8,
    definition: []const u8,
    word_1c: u32,
    health: f32,
    energy: f32,
    angles_64: [2]i16,
    words_8c: [3]u32,
    flags: u32,
    short_9c: u16,
    booleans_a4: [4]bool,
    selected: u32,
    selected_weapon: u32,
    browse_cursor: u32,
    browsing: bool,
    inventory: [25]?Inventory,
    name_138: []const u8,

    pub fn write(self: State, writer: *stream.Writer) !void {
        try writer.integer(u8, self.character);
        try writer.string(self.definition);
        try writer.integer(u32, self.word_1c);
        try writer.float(self.health);
        try writer.float(self.energy);
        for (self.angles_64) |value| try writer.integer(i16, value);
        for (self.words_8c) |value| try writer.integer(u32, value);
        try writer.integer(u32, self.flags);
        try writer.integer(u16, self.short_9c);
        for (self.booleans_a4) |value| try writer.boolean(value);
        try writer.integer(u32, self.selected);
        try writer.integer(u32, self.selected_weapon);
        try writer.integer(u32, self.browse_cursor);
        try writer.boolean(self.browsing);
        for (self.inventory) |item| {
            try writer.boolean(item != null);
            if (item) |value| try value.write(writer);
        }
        try writer.string(self.name_138);
    }

    pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !State {
        var result: State = undefined;
        result.character = try reader.integer(u8);
        result.definition = try readString(reader, a, 31);
        result.word_1c = try reader.integer(u32);
        result.health = try reader.float();
        result.energy = try reader.float();
        for (&result.angles_64) |*value| value.* = try reader.integer(i16);
        for (&result.words_8c) |*value| value.* = try reader.integer(u32);
        result.flags = try reader.integer(u32);
        result.short_9c = try reader.integer(u16);
        for (&result.booleans_a4) |*value| value.* = try reader.boolean();
        result.selected = try reader.integer(u32);
        result.selected_weapon = try reader.integer(u32);
        result.browse_cursor = try reader.integer(u32);
        result.browsing = try reader.boolean();
        for (&result.inventory) |*item| item.* = if (try reader.boolean()) try Inventory.read(reader, a) else null;
        result.name_138 = try readString(reader, a, 31);
        if (result.selected >= 26 or result.selected_weapon >= 26 or result.browse_cursor >= 26) return error.InvalidSavedInventorySlot;
        return result;
    }
};

pub fn captureInventory(owned: inventory_module.OwnedItem, audio: anytype) !Inventory {
    const definition = owned.definition;
    if (definition.native_name.len == 0) return error.MissingSavedInventoryBinding;
    var result: Inventory = .{
        .allocation_size = if (definition.weapon != null) 0x250 else if (definition.function == .health_object) 0x8c else 0x88,
        .item_class = definition.item_class,
        .name = definition.name,
        .ground_item = definition.ground_item,
        .native = definition.native_name,
        .no_show = definition.no_show,
        .no_drop = definition.no_drop,
        .wax_resource = if (definition.wax_available) definition.costume else "",
        .instance = if (owned.playback) |playback| .{ .resource = definition.costume, .playback = playback, .native = definition.native_name } else null,
        .success_sound = try sound.capture(audio, definition.use_success_sound),
        .failure_sound = try sound.capture(audio, definition.use_failure_sound),
        .flags = definition.flags,
        .count = owned.count,
        .maximum = definition.max_count,
        .use_id = definition.use_id,
        .health_sound = try sound.capture(audio, definition.health_sound),
    };
    if (definition.weapon) |config| {
        const bindings = try weaponBindings(definition.function);
        var weapon: Weapon = .{
            .native_88 = bindings.handler,
            .costume_name = definition.costume,
            .native_e8 = bindings.logic,
            .scope_item = config.scope_item orelse "",
            .has_scope = config.scope_item != null,
            .scope_x = config.scope_x,
            .scope_y = config.scope_y,
            .rest = config.rest,
            .fire = config.fire,
            .empty = config.empty,
            .reload = config.reload,
            .extra = config.extra,
            .scope_rest = config.scope_rest,
            .scope_fire = config.scope_fire,
            .scope_empty = config.scope_empty,
            .fire_sound = undefined,
            .empty_sound = undefined,
            .action_sound = undefined,
            .reload_sound = try sound.capture(audio, config.reload_sound),
            .extra_sound = try sound.capture(audio, config.extra_sound),
            .modes = config.modes,
            .flash = config.flash,
            .kick = config.kick,
            .infinite = definition.infinite,
            .auto_reload = config.auto_reload,
            .loaded = owned.loaded,
            .capacity = definition.capacity,
            .multiples = config.multiples,
            .projectile = config.projectile orelse "",
            .ammo = definition.ammo,
        };
        for (0..3) |i| {
            weapon.fire_sound[i] = try sound.capture(audio, config.fire_sound[i]);
            weapon.empty_sound[i] = try sound.capture(audio, config.empty_sound[i]);
            weapon.action_sound[i] = try sound.capture(audio, config.action_sound[i]);
        }
        result.weapon = weapon;
    }
    return result;
}

pub fn restoreInventory(value: Inventory, audio: anytype) !inventory_module.OwnedItem {
    const function = try cmm.inventoryFunction(value.native);
    try validateSize(value.allocation_size, function);
    var definition: inventory_module.Definition = .{
        .name = value.name,
        .function = function,
        .native_name = value.native,
        .item_class = value.item_class,
        .count = value.count,
        .max_count = value.maximum,
        .slot = null,
        .no_show = value.no_show,
        .no_drop = value.no_drop,
        .flags = value.flags,
        .use_id = value.use_id,
        .use_success_sound = try sound.restore(audio, value.success_sound),
        .use_failure_sound = try sound.restore(audio, value.failure_sound),
        .health_sound = try sound.restore(audio, value.health_sound),
        .sound_names_resolved = true,
        .ground_item = value.ground_item,
        .costume = value.wax_resource,
        .wax_available = value.wax_resource.len != 0,
    };
    var loaded: i32 = 0;
    if (value.instance) |instance| {
        if (!std.ascii.eqlIgnoreCase(instance.native, value.native) or !std.ascii.eqlIgnoreCase(instance.resource, value.wax_resource)) return error.InvalidSavedInventoryWaxBinding;
    }
    if (value.weapon) |weapon| {
        const bindings = try weaponBindings(function);
        if (!std.ascii.eqlIgnoreCase(weapon.native_88, bindings.handler) or !std.ascii.eqlIgnoreCase(weapon.native_e8, bindings.logic)) return error.UnsupportedSavedWeaponBinding;
        definition.costume = weapon.costume_name;
        definition.ammo = weapon.ammo;
        definition.capacity = weapon.capacity;
        definition.infinite = weapon.infinite;
        loaded = weapon.loaded;
        var config: weapon_config.Config = .{
            .rest = weapon.rest,
            .fire = weapon.fire,
            .empty = weapon.empty,
            .reload = weapon.reload,
            .extra = weapon.extra,
            .scope_item = if (weapon.has_scope) weapon.scope_item else null,
            .scope_rest = weapon.scope_rest,
            .scope_fire = weapon.scope_fire,
            .scope_empty = weapon.scope_empty,
            .scope_x = weapon.scope_x,
            .scope_y = weapon.scope_y,
            .modes = weapon.modes,
            .flash = weapon.flash,
            .kick = weapon.kick,
            .multiples = weapon.multiples,
            .auto_reload = weapon.auto_reload,
            .projectile = if (weapon.projectile.len != 0) weapon.projectile else null,
            .reload_sound = try sound.restore(audio, weapon.reload_sound),
            .extra_sound = try sound.restore(audio, weapon.extra_sound),
        };
        for (0..3) |i| {
            config.fire_sound[i] = try sound.restore(audio, weapon.fire_sound[i]);
            config.empty_sound[i] = try sound.restore(audio, weapon.empty_sound[i]);
            config.action_sound[i] = try sound.restore(audio, weapon.action_sound[i]);
        }
        definition.weapon = config;
    }
    return .{ .definition = definition, .count = value.count, .loaded = loaded, .playback = if (value.instance) |instance| instance.playback else null, .sounds_registered = true };
}

pub fn capture(session: anytype, audio: anytype) !State {
    const inventory = &session.inventory;
    var result: State = .{
        .character = inventory.character,
        .definition = inventory.player_definition,
        .word_1c = @bitCast(session.player.jump_peak),
        .health = inventory.health,
        .energy = session.player.energy,
        .angles_64 = inventory.aim_angles,
        .words_8c = .{ @bitCast(session.player.auto_pitch_elapsed), @bitCast(session.player.underwater_elapsed), @bitCast(session.player.slope_velocity) },
        .flags = inventory.player_flags,
        .short_9c = @bitCast(session.player.normal_yaw),
        .booleans_a4 = .{ inventory.cloak_active, inventory.cloak_visible, inventory.sheriff_active, inventory.sheriff_visible },
        .selected = @intCast(inventory.selected),
        .selected_weapon = @intCast(inventory.selected_weapon),
        .browse_cursor = @intCast(inventory.browse_cursor),
        .browsing = inventory.browsing,
        .inventory = @splat(null),
        .name_138 = inventory.player_name,
    };
    for (inventory.slots[1..], 0..) |owned, index| {
        if (owned) |item| result.inventory[index] = try captureInventory(item, audio);
    }
    return result;
}

pub fn apply(session: anytype, audio: anytype, value: State) !void {
    const inventory = &session.inventory;
    if (value.character != inventory.character or !std.ascii.eqlIgnoreCase(value.definition, inventory.player_definition)) return error.UnsupportedSavedPlayerCharacter;
    const a = session.arena.allocator();
    const archives = [_]@import("../assets/lab.zig").Archive{ session.object_archive, session.weapon_archive, session.geometry_archive, session.system_archive };
    const cid_bytes = for (archives) |archive| {
        break archive.find(value.definition, 0) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };
    } else return error.MissingSavedPlayerDefinition;
    var cid = try @import("../assets/item.zig").Item.parse(a, cid_bytes);
    defer cid.deinit();
    try @import("../audio/registration.zig").player(session, &cid, session.animation_time);
    inventory.clock = session.animation_time;
    try inventory.startItems(a, &archives, &cid);
    try session.applyPlayerBindFlags(&cid);
    try @import("../audio/registration.zig").playerBlips(session, session.animation_time);
    try inventory.releaseAllSounds();
    inventory.health = value.health;
    session.player.jump_peak = @bitCast(value.word_1c);
    session.player.energy = value.energy;
    inventory.aim_angles = value.angles_64;
    session.player.auto_pitch_elapsed = @bitCast(value.words_8c[0]);
    session.player.underwater_elapsed = @bitCast(value.words_8c[1]);
    session.player.slope_velocity = @bitCast(value.words_8c[2]);
    session.player.normal_yaw = @bitCast(value.short_9c);
    inventory.player_flags = value.flags;
    session.player.flags = value.flags;
    session.player.dead = !(@as(i32, @bitCast(value.health)) > 0);
    if (value.flags & 8 != 0) {
        var rail: @import("../audio/rail.zig").Context = .{ .state = &session.rail_audio_state, .runtime = audio, .now = session.animation_time };
        try rail.start(session.player.position);
    }
    inventory.cloak_active = value.booleans_a4[0];
    inventory.cloak_visible = value.booleans_a4[1];
    inventory.sheriff_active = value.booleans_a4[2];
    inventory.sheriff_visible = value.booleans_a4[3];
    inventory.selected = value.selected;
    inventory.selected_weapon = value.selected_weapon;
    inventory.browse_cursor = value.browse_cursor;
    inventory.browsing = value.browsing;
    inventory.player_name = value.name_138;
    for (value.inventory, 1..) |item, index| inventory.slots[index] = if (item) |owned| try restoreInventory(owned, audio) else null;
    if (value.flags & 0x20000000 != 0) {
        inventory.player_flags &= ~@as(u32, 0x20000000);
        var effects = inventory_module.Effects.init(session.arena.allocator());
        defer effects.deinit();
        try session.lamp_state.toggle(inventory, &session.lamp_config, &effects);
        try session.pickup_effects.appendSlice(session.arena.allocator(), effects.items);
        session.player.flags = inventory.player_flags;
    }
}

fn validateSize(size: u32, function: cmm.Native) !void {
    const expected: u32 = switch (function) {
        .generic_object => 0x88,
        .health_object => 0x8c,
        .weapon_fist_handler, .weapon_pistol_handler, .weapon_rifle_handler, .weapon_shotgun_handler, .weapon_db_shotgun_handler, .weapon_sawed_shotgun_handler, .weapon_gatling_handler, .weapon_tnt_handler, .weapon_knife_handler => 0x250,
        else => return error.UnsupportedSavedInventoryHandler,
    };
    if (size != expected) return error.InvalidSavedInventorySize;
}

fn readString(reader: *stream.Reader, a: std.mem.Allocator, maximum: usize) ![]const u8 {
    var buffer: [255]u8 = undefined;
    const value = try reader.string(&buffer);
    if (value.len > maximum) return error.InvalidSavedPlayerString;
    return a.dupe(u8, value);
}

fn weaponBindings(function: cmm.Native) !struct { handler: []const u8, logic: []const u8 } {
    return switch (function) {
        .weapon_fist_handler => .{ .handler = "Weapon_FistHandler", .logic = "Weapon_FistWaxLogic" },
        .weapon_pistol_handler => .{ .handler = "Weapon_PistolHandler", .logic = "Weapon_PistolWaxLogic" },
        .weapon_rifle_handler => .{ .handler = "Weapon_RifleHandler", .logic = "Weapon_RifleWaxLogic" },
        .weapon_shotgun_handler => .{ .handler = "Weapon_ShotgunHandler", .logic = "Weapon_ShotgunWaxLogic" },
        .weapon_db_shotgun_handler => .{ .handler = "Weapon_DBShotgunHandler", .logic = "Weapon_DBShotgunWaxLogic" },
        .weapon_sawed_shotgun_handler => .{ .handler = "Weapon_SawedShotgunHandler", .logic = "Weapon_SawedShotgunWaxLogic" },
        .weapon_gatling_handler => .{ .handler = "Weapon_GatlingHandler", .logic = "Weapon_GatlingWaxLogic" },
        .weapon_tnt_handler => .{ .handler = "Weapon_TNTHandler", .logic = "Weapon_TNTWaxLogic" },
        .weapon_knife_handler => .{ .handler = "Weapon_KnifeHandler", .logic = "Weapon_KnifeWaxLogic" },
        else => error.UnsupportedSavedWeaponBinding,
    };
}

test "player and inventory save payloads match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/save-player-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        executable_sha256: []const u8,
        cases: []struct { items: [][]const u8, bytes: []const u8, sha256: []const u8 },
    };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{});
    defer fixture.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", fixture.value.executable_sha256);
    for (fixture.value.cases) |case| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const raw = try arena.allocator().alloc(u8, case.bytes.len / 2);
        _ = try std.fmt.hexToBytes(raw, case.bytes);
        var reader: stream.Reader = .{ .bytes = raw };
        const value = try State.read(&reader, arena.allocator());
        try reader.end();
        try std.testing.expectEqual(@as(u8, 'J'), value.character);
        try std.testing.expectEqual(@as(f32, 4.25), value.health);
        try std.testing.expectEqual(@as(u32, 0x2000000c), value.flags);
        try std.testing.expectEqual(@as(i16, -123), value.angles_64[0]);
        var writer: stream.Writer = .{ .allocator = a };
        defer writer.deinit();
        try value.write(&writer);
        const encoded = try writer.finish();
        defer a.free(encoded);
        try std.testing.expectEqualSlices(u8, raw, encoded);
    }
}
