//! The player's inventory: slots, ammunition, health and the items that can
//! be selected or used.
//!
//! Inventory changes are messages, and the presentation arguments they carry
//! are consumed separately by the HUD and the audio side. The order of those
//! messages is visible to scripts, so keep it.

const std = @import("std");
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const cmm = @import("../script/cmm.zig");

pub const Effects = std.array_list.Managed(Effect);

pub const Effect = union(enum) {
    message: struct { index: i32, parameter: ?i32 = null, routed: bool = false },
    sound: @import("../audio/request.zig").Request,
};

pub const ReleasePhase = enum { native, common };

pub const Definition = struct {
    name: []const u8,
    function: cmm.Native,
    item_class: u32,
    count: i32,
    max_count: i32,
    slot: ?usize,
    no_show: bool,
    no_drop: bool,
    flags: i32,
    use_id: i32,
    use_success_sound: ?[]const u8 = null,
    use_failure_sound: ?[]const u8 = null,
    health_sound: ?[]const u8 = null,
    sound_names_resolved: bool = false,
    native_name: []const u8 = "",
    wax_available: bool = false,
    ground_item: []const u8 = "",
    ammo: []const u8 = "",
    capacity: i32 = 0,
    infinite: bool = false,
    costume: []const u8 = "",
    weapon: ?@import("weapon_config.zig").Config = null,

    pub fn load(a: std.mem.Allocator, archives: []const lab.Archive, name: []const u8) !Definition {
        var path: [128]u8 = undefined;
        var item = try Item.parse(a, try resource(archives, try std.fmt.bufPrint(&path, "{s}.ITM", .{name})) orelse return error.MissingInventoryItem);
        defer item.deinit();
        if (try item.stringValue("P_MSG_TO") != null) return error.UnsupportedInventoryPickupMessage;
        const native = try cmm.inventoryFunction(item.function);
        const weapon = switch (native) {
            .weapon_fist_handler, .weapon_pistol_handler, .weapon_rifle_handler, .weapon_shotgun_handler, .weapon_db_shotgun_handler, .weapon_sawed_shotgun_handler, .weapon_gatling_handler, .weapon_tnt_handler, .weapon_knife_handler => true,
            .generic_object, .health_object => false,
            else => return error.UnsupportedInventoryConstructor,
        };
        const requested_slot = item.intValue("SLOT");
        if (requested_slot) |slot| if (slot < 1 or slot >= 26) return error.InvalidInventorySlot;
        var variant: ?Item = null;
        defer if (variant) |*value| value.deinit();
        if (weapon) {
            if (name.len == 0) return error.InvalidInventoryName;
            const variant_name = try std.fmt.bufPrint(&path, "{c}J{s}.ITM", .{ name[0], name[1..] });
            if (try resource(archives, variant_name)) |data| variant = try Item.parse(a, data);
        }
        const fields = if (variant) |*value| value else &item;
        const stem = try costumeBasename(fields.animation);
        var costume_name = try a.dupe(u8, try std.fmt.bufPrint(&path, "{s}.NWX", .{stem}));
        errdefer a.free(costume_name);
        if (weapon) {
            if (stem.len == 0) return error.InvalidInventoryCostume;
            const character_name = try std.fmt.bufPrint(&path, "{c}J{s}.NWX", .{ stem[0], stem[1..] });
            if (try resource(archives, character_name) != null) {
                const replacement = try a.dupe(u8, character_name);
                a.free(costume_name);
                costume_name = replacement;
            }
        }
        var no_show = false;
        var wax_available = false;
        if (!weapon) {
            if (try resource(archives, costume_name)) |bytes| {
                wax_available = true;
                var costume = try nwx.Costume.parse(a, bytes);
                costume.deinit();
            } else no_show = true;
            if (fields.intValue("NO_SHOW")) |value| no_show = @as(u8, @truncate(@as(u32, @bitCast(value)))) != 0;
        }
        var class: u32 = if (weapon) 0x57454150 else 0;
        if (!weapon) if (try fields.stringValue("ITEM_CLASS")) |value| {
            if (value.len > 4) return error.InvalidInventoryClass;
            for (0..4) |i| class = (class << 8) | (if (i < value.len) @as(u32, value[i]) else 0);
        };
        const use_success_sound = if (weapon) null else try fields.stringValue("SND_USE_S");
        const use_failure_sound = if (weapon) null else try fields.stringValue("SND_USE_F");
        var result: Definition = .{
            .name = "",
            .function = native,
            .wax_available = wax_available,
            .item_class = class,
            .count = if (weapon) 1 else fields.intValue("COUNT") orelse 0,
            .max_count = fields.intValue("MAX_COUNT") orelse 1,
            .slot = if (requested_slot) |slot| @intCast(slot) else null,
            .no_show = no_show,
            .no_drop = !weapon and @as(u8, @truncate(@as(u32, @bitCast(fields.intValue("NO_DROP") orelse 0)))) != 0,
            .flags = if (weapon) 0 else short(fields.intValue("FLAGS") orelse 0),
            .use_id = if (weapon) 0 else fields.intValue("USE_ID") orelse 0,
            .capacity = if (weapon) fields.intValue("SHOT_CAPACITY") orelse 0 else 0,
            .infinite = native == .weapon_fist_handler or native == .weapon_tnt_handler or native == .weapon_knife_handler,
        };
        // The costume name stays with its own cleanup until the end.
        errdefer result.deinit(a);
        result.name = try a.dupe(u8, item.name);
        result.native_name = try a.dupe(u8, item.function);
        if (native == .health_object) if (try fields.stringValue("SOUND_0")) |value| {
            result.health_sound = try a.dupe(u8, value);
        };
        if (use_success_sound) |name_value| result.use_success_sound = try a.dupe(u8, name_value);
        if (use_failure_sound) |name_value| result.use_failure_sound = try a.dupe(u8, name_value);
        if (try fields.stringValue("GROUND_ITEM")) |name_value| result.ground_item = try a.dupe(u8, try costumeBasename(name_value));
        if (weapon) result.ammo = try a.dupe(u8, (try fields.stringValue("AMMO")) orelse "");
        if (weapon) result.weapon = try @import("weapon_config.zig").Config.load(a, fields);
        result.costume = costume_name;
        return result;
    }

    /// Frees the strings `load` made with the same allocator.
    pub fn deinit(self: *Definition, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.native_name);
        inline for (.{ "health_sound", "use_success_sound", "use_failure_sound" }) |field| {
            if (@field(self, field)) |value| a.free(value);
        }
        a.free(self.ground_item);
        a.free(self.ammo);
        a.free(self.costume);
        if (self.weapon) |*config| config.deinit(a);
        self.* = .{ .name = "", .function = self.function, .item_class = 0, .count = 0, .max_count = 0, .slot = null, .no_show = false, .no_drop = false, .flags = 0, .use_id = 0 };
    }
};

pub const Entry = struct {
    name: []const u8,
    count: i16,
    slot: i16,
    message: i16,
};

pub const Pickup = struct {
    function: cmm.Native,
    entries: []const Entry = &.{},
    allocator: std.mem.Allocator = undefined,
    archives: []const lab.Archive = &.{},
    game_type: u32 = 1,
    flags: i16 = 0,
    health_bonus: u8 = 0,
    message: i32 = -1,
    sound: ?[]const u8 = null,
    sound_names_resolved: bool = false,
    enabled: bool = true,

    pub fn tick(self: *Pickup, actor: *@import("../render/objects.zig").Actor, player_position: @import("../assets/level.zig").Vec3) void {
        if (!self.enabled) self.enabled = 10.0 < @abs(@as(f64, player_position.x) - actor.position.x) + @abs(@as(f64, player_position.z) - actor.position.z);
        actor.flags = if (self.enabled) (actor.flags & ~@as(u32, 0x40)) | 0x80000000 else actor.flags | 0x80000040;
    }

    pub fn parse(a: std.mem.Allocator, archives: []const lab.Archive, item: *const Item, difficulty: u32, game_type: u32) !Pickup {
        const native = try cmm.inventoryFunction(item.function);
        var result: Pickup = .{ .function = native, .allocator = a, .game_type = game_type };
        if (try item.stringValue("PICKUP_SOUND")) |sound| result.sound = try a.dupe(u8, sound);
        if (native == .instant_ground_object) {
            result.health_bonus = @truncate(@as(u32, @bitCast(item.intValue("HEALTH_B") orelse 0)));
            result.message = item.intValue("PICKUP_MSG") orelse -1;
            return result;
        }
        if (native != .ground_object and native != .ground_sheriff_star and native != .ground_vanishing_cream and native != .projectile_dispatch) return error.UnsupportedPickupConstructor;
        result.flags = short(item.intValue("FLAGS") orelse 0);
        const count = item.intValue("PICKUP_COUNT") orelse @as(i32, if (try item.stringValue("PICKUP") != null) 1 else 0);
        if (count < 0 or count > std.math.maxInt(i16)) return error.InvalidPickupCount;
        const entries = try a.alloc(Entry, @intCast(count));
        errdefer a.free(entries);
        for (entries, 0..) |*entry, i| {
            var buffer: [48]u8 = undefined;
            const name = (try item.stringValue(try fieldName(&buffer, "PICKUP", i))) orelse return error.MissingPickupItem;
            const raw_amount = item.intValue(try fieldName(&buffer, "COUNT", i)) orelse 0;
            var amount = if (raw_amount == 0) @as(i16, 1) else short(raw_amount);
            if (game_type != 4 and game_type != 5 and game_type != 6 and difficulty == 0x200000 and std.ascii.eqlIgnoreCase(name, "ICART")) amount = @max(1, amount >> 1);
            const slot = short(item.intValue(try fieldName(&buffer, "SLOT", i)) orelse 0);
            if (slot < 0 or slot >= 26) return error.InvalidInventorySlot;
            entry.* = .{
                .name = try a.dupe(u8, name),
                .count = amount,
                .slot = slot,
                .message = short(item.intValue(try fieldName(&buffer, "PICKUP_MSG", i)) orelse -1),
            };
        }
        result.entries = entries;
        result.archives = try a.dupe(lab.Archive, archives);
        return result;
    }
};

pub const OwnedItem = struct {
    definition: Definition,
    count: i32,
    loaded: i32 = 0,
    playback: ?nwx.Playback = null,
    acquired_at: u32 = 0,
    sounds_registered: bool = false,
};

pub const Statistics = struct {
    items: i32 = 0,
    gold: i32 = 0,
    health: i32 = 0,
    damage: i32 = 0,
    hits: u32 = 0,
    kills: u32 = 0,
    native_words: [15]u32 = @splat(0),
};

pub const Inventory = struct {
    slots: [26]?OwnedItem = [_]?OwnedItem{null} ** 26,
    sound_host: ?SoundHost = null,
    health: f32 = 10,
    player_flags: u32 = 0,
    selected: usize = 0,
    selected_weapon: usize = 0,
    browse_cursor: usize = 0,
    browsing: bool = false,
    statistics: Statistics = .{},
    default_sound: ?[]const u8 = null,
    sheriff_active: bool = false,
    sheriff_visible: bool = false,
    sheriff_remaining: i32 = 0,
    sheriff_due: ?u32 = null,
    sheriff_task_linked: bool = false,
    sheriff_task_parameter: u32 = 0,
    cloak_active: bool = false,
    cloak_visible: bool = false,
    cloak_remaining: i32 = 0,
    cloak_due: ?u32 = null,
    cloak_task_linked: bool = false,
    cloak_task_parameter: u32 = 0,
    character: u8 = 'J',
    player_definition: []const u8 = "cidjames.itm",
    player_name: []const u8 = "",
    aim_angles: [2]i16 = .{ 182, 182 },
    clock: u32 = 0,

    pub const SoundHost = struct {
        context: *anyopaque,
        acquire: *const fn (*anyopaque, Definition, u32) anyerror!void,
        release: *const fn (*anyopaque, Definition, ReleasePhase) anyerror!void,
        resolve: ?*const fn (*anyopaque, []const u8) anyerror!Definition = null,
    };

    pub fn init(a: std.mem.Allocator, archives: []const lab.Archive, cid: *const Item) !Inventory {
        return initAt(a, archives, cid, 0);
    }

    pub fn initAt(a: std.mem.Allocator, archives: []const lab.Archive, cid: *const Item, now: u32) !Inventory {
        var result: Inventory = .{ .clock = now };
        try result.configureDefaultSound(a, archives, null);
        try result.startItems(a, archives, cid);
        return result;
    }

    pub fn configureDefaultSound(self: *Inventory, a: std.mem.Allocator, archives: []const lab.Archive, level_item: ?*const Item) !void {
        if (self.default_sound == null) {
            var config = try Item.parse(a, try resource(archives, "OUTLAWS.ITM") orelse return error.MissingInventoryConfiguration);
            defer config.deinit();
            if (try config.stringValue("DEFSND_PICKUP")) |sound| self.default_sound = try a.dupe(u8, sound);
        }
        if (level_item) |definition| if (try definition.stringValue("DEFSND_PICKUP")) |sound| {
            self.default_sound = try a.dupe(u8, sound);
        };
    }

    pub fn startItems(self: *Inventory, a: std.mem.Allocator, archives: []const lab.Archive, cid: *const Item) !void {
        if (self.slots[1] == null) {
            var config = try Item.parse(a, try resource(archives, "OUTLAWS.ITM") orelse return error.MissingInventoryConfiguration);
            defer config.deinit();
            const fist = try Definition.load(a, archives, (try config.stringValue("WEAPON_1")) orelse return error.MissingInitialWeapon);
            _ = try self.acquire(fist, 1);
        }
        for (1..20) |i| {
            var buffer: [48]u8 = undefined;
            const name = (try cid.stringValue(try std.fmt.bufPrint(&buffer, "START_ITEM_{d}", .{i}))) orelse break;
            const wanted = cid.intValue(try std.fmt.bufPrint(&buffer, "START_COUNT_{d}", .{i})) orelse 1;
            const existing = self.find(name);
            const reserve = if (existing != 0) self.slots[existing].?.count else 0;
            var loaded: i32 = 0;
            for (self.slots[1..10]) |slot| if (slot) |owned| {
                if (!owned.definition.infinite and std.ascii.eqlIgnoreCase(owned.definition.ammo, name)) loaded +%= owned.loaded;
            };
            if (reserve +% loaded < wanted) {
                if (existing != 0) try self.remove(existing);
                const index = try self.acquire(try Definition.load(a, archives, name), 0);
                if (index != 0) {
                    const owned = &self.slots[index].?;
                    owned.count = @min(owned.definition.max_count, owned.count +% (wanted -% loaded));
                }
            }
        }
        for (1..10) |i| try self.reload(i);
        const selected = cid.intValue("START_WEAPON") orelse 1;
        if (selected < 0 or selected >= 26) return error.InvalidInventorySlot;
        if (self.selected_weapon == 0 or self.slots[self.selected_weapon] == null) {
            if (selected == 0) self.selected_weapon = 0 else if (self.slots[@intCast(selected)]) |owned| {
                if (owned.definition.item_class == 0x57454150) self.selected_weapon = @intCast(selected);
            }
        }
    }

    pub fn clone(self: *const Inventory, a: std.mem.Allocator) !Inventory {
        var result = self.*;
        result.sound_host = null;
        result.player_definition = try a.dupe(u8, self.player_definition);
        result.player_name = try a.dupe(u8, self.player_name);
        if (self.default_sound) |name| result.default_sound = try a.dupe(u8, name);
        for (&result.slots) |*slot| if (slot.*) |*owned| {
            inline for (.{ "name", "ground_item", "ammo", "costume", "native_name" }) |field| {
                @field(owned.definition, field) = try a.dupe(u8, @field(owned.definition, field));
            }
            inline for (.{ "use_success_sound", "use_failure_sound", "health_sound" }) |field| {
                if (@field(owned.definition, field)) |name| @field(owned.definition, field) = try a.dupe(u8, name);
            }
            if (owned.definition.weapon) |config| owned.definition.weapon = try config.clone(a);
        };
        return result;
    }

    pub fn find(self: *const Inventory, name: []const u8) usize {
        for (self.slots[1..], 1..) |slot, i| if (slot) |owned| {
            if (std.ascii.eqlIgnoreCase(owned.definition.name, name)) return i;
        };
        return 0;
    }

    pub fn acquire(self: *Inventory, definition: Definition, requested_slot: usize) !usize {
        if (self.player_flags & 0x10000000 != 0) return 0;
        const existing = self.find(definition.name);
        if (existing != 0) return existing;
        var slot = requested_slot;
        if (slot == 0) {
            slot = 11;
            while (slot < 26 and self.slots[slot] != null) : (slot += 1) {}
        }
        if (slot >= 26) return 0;
        if (definition.slot) |override| slot = override;
        if (slot == 0) return error.InvalidInventorySlot;
        self.slots[slot] = .{ .definition = definition, .count = definition.count, .loaded = if (definition.function == .weapon_fist_handler) std.math.maxInt(i32) else 0, .playback = if (definition.wax_available) .{ .last_time = self.clock } else null, .acquired_at = self.clock };
        if (self.sound_host) |host| {
            try host.acquire(host.context, definition, self.clock);
            self.slots[slot].?.sounds_registered = true;
        }
        if ((self.selected == 0 or self.slots[self.selected] == null) and !definition.no_show and definition.item_class != 0x57454150) self.selected = slot;
        return slot;
    }

    pub fn reload(self: *Inventory, slot: usize) !void {
        if (self.slots[slot] == null) return;
        const owned = &self.slots[slot].?;
        const ammo = self.find(owned.definition.ammo);
        const missing = owned.definition.capacity -% owned.loaded;
        if (ammo == 0 or missing == 0) return;
        const count = self.slots[ammo].?.count;
        if (count <= 0) return;
        const transferred = @min(count, missing);
        owned.loaded +%= transferred;
        if (!owned.definition.infinite) {
            if (transferred == count) try self.remove(ammo) else self.slots[ammo].?.count = count -% transferred;
        }
    }

    pub fn remove(self: *Inventory, slot: usize) !void {
        if (self.selected == slot) self.selected = 0;
        if (self.selected_weapon == slot) self.selected_weapon = 0;
        if (self.slots[slot]) |owned| {
            if (self.sound_host) |host| try host.release(host.context, owned.definition, .native);
            if (owned.definition.weapon != null and owned.loaded != 0 and !owned.definition.infinite) try self.returnAmmunition(owned);
            if (self.sound_host) |host| try host.release(host.context, owned.definition, .common);
        }
        self.slots[slot] = null;
    }

    pub fn releaseAllSounds(self: *Inventory) !void {
        for (1..self.slots.len) |slot| if (self.slots[slot] != null) try self.remove(slot);
    }

    pub fn applyLevelFlags(self: *Inventory, a: std.mem.Allocator, archives: []const lab.Archive, cid: *const Item, flags: u32) !void {
        if (flags & 0x40000 != 0) {
            try self.releaseAllSounds();
            try self.restoreFist(a, archives);
        } else {
            for ([_]u32{ 0x4000, 0x8000, 0x10000, 0x20000 }, [_]u32{ 0x414d4d4f, 0x57454150, 0x4845414c, 0x4655454c }) |mask, class| {
                if (flags & mask == 0) continue;
                for (1..self.slots.len) |slot| if (self.slots[slot]) |owned| {
                    if (owned.definition.item_class == class) try self.remove(slot);
                };
                if (mask == 0x8000) try self.restoreFist(a, archives);
            }
        }
        if (self.selected_weapon == 0 or self.slots[self.selected_weapon] == null) {
            const desired = cid.intValue("START_WEAPON") orelse 1;
            if (desired < 0 or desired >= 26) return error.InvalidInventorySlot;
            if (desired == 0) self.selected_weapon = 0 else if (self.slots[@intCast(desired)]) |owned| {
                if (owned.definition.item_class == 0x57454150) self.selected_weapon = @intCast(desired);
            }
        }
    }

    pub fn itemCount(self: *const Inventory) i32 {
        var count: i32 = 0;
        for (self.slots[1..]) |slot| if (slot) |owned| {
            if (owned.definition.item_class != 0x57454150) count += 1;
        };
        return count;
    }

    pub fn adjacentItem(self: *const Inventory, start: usize, direction: i32) ?usize {
        var slot: i32 = @intCast(start);
        while (true) {
            slot += direction;
            if (slot < 1 or slot >= self.slots.len) return null;
            if (self.slots[@intCast(slot)]) |owned| {
                if (owned.definition.item_class != 0x57454150 and !owned.definition.no_show) return @intCast(slot);
            }
        }
    }

    pub fn browseInput(self: *Inventory, entry: @import("input.zig").Entry) void {
        const input = @import("input.zig");
        if (entry.flags & input.pressed == 0) return;
        if (entry.flags & input.absolute == 0) {
            if (entry.value == 0) return;
            if (!self.browsing) {
                if (self.itemCount() > 0) self.browsing = true;
            } else if (self.adjacentItem(self.browse_cursor, if (entry.value < 0) -1 else 1)) |slot| {
                self.browse_cursor = slot;
            }
        } else if (entry.value == -1) {
            if (!self.browsing) {
                if (self.itemCount() > 0) {
                    self.browsing = true;
                    self.browse_cursor = self.selected;
                }
            } else self.confirmBrowse();
        }
    }

    pub fn confirmBrowse(self: *Inventory) void {
        if (self.browse_cursor == 0) {
            self.selected = 0;
        } else if (self.browse_cursor < self.slots.len) {
            if (self.slots[self.browse_cursor]) |owned| {
                if (owned.definition.item_class != 0x57454150 and !owned.definition.no_show) self.selected = self.browse_cursor;
            }
        }
        self.browsing = false;
    }

    pub fn useSelected(self: *Inventory, effects: *Effects) !?u32 {
        if (self.browsing) {
            self.confirmBrowse();
            return null;
        }
        if (self.selected == 0) return 0;
        const slot = self.selected;
        const owned = self.slots[slot] orelse return error.InvalidInventorySelection;
        const object_id: u32 = @bitCast(owned.definition.use_id);
        switch (owned.definition.function) {
            .generic_object => {},
            .health_object => {
                const accepted = @as(i32, @bitCast(self.health)) < 0x41200000;
                if (accepted) {
                    const gain = self.addHealth(@floatFromInt(owned.count));
                    const consumed: f32 = @floatCast(@as(f64, gain) + 0.5);
                    self.slots[slot].?.count -%= nearest(consumed);
                }
                const sound = if (accepted) owned.definition.use_success_sound else owned.definition.use_failure_sound;
                if (sound) |basename| try effects.append(.{ .sound = .{ .basename = basename, .priority = 64, .volume = 127, .flags = 4 } });
                if (accepted and self.slots[slot].?.count < 1) try self.remove(slot);
            },
            else => return error.UnsupportedInventoryUseNative,
        }
        return object_id;
    }

    pub fn take(self: *Inventory, pickup: *const Pickup, now_ms: u32, effects: *Effects) !bool {
        self.clock = now_ms;
        switch (pickup.function) {
            .ground_object, .projectile_dispatch => return self.takeGround(pickup, effects),
            .instant_ground_object => {
                if (@as(i32, @bitCast(self.health)) >= 0x41200000) return false;
                _ = self.addHealth(@floatCast(@as(f64, @floatFromInt(pickup.health_bonus)) * @as(f32, 0.1)));
                try self.pickupSound(pickup, effects);
                if (pickup.message != -1) try effects.append(.{ .message = .{ .index = pickup.message } });
                return true;
            },
            .ground_sheriff_star => {
                for (pickup.entries) |entry| if (entry.message != -1) try effects.append(.{ .message = .{ .index = entry.message } });
                self.statistics.items +%= 1;
                if (!self.sheriff_active) self.sheriff_task_linked = true;
                self.sheriff_active = true;
                self.sheriff_visible = true;
                self.sheriff_remaining = 6;
                self.sheriff_due = now_ms +% 30000;
                try self.pickupSound(pickup, effects);
                return true;
            },
            .ground_vanishing_cream => {
                for (pickup.entries) |entry| if (entry.message != -1) try effects.append(.{ .message = .{ .index = entry.message } });
                self.statistics.items +%= 1;
                if (!self.cloak_active) self.cloak_task_linked = true;
                self.cloak_active = true;
                self.cloak_visible = true;
                self.cloak_remaining = 6;
                self.cloak_due = now_ms +% 30000;
                try self.pickupSound(pickup, effects);
                return true;
            },
            else => return error.UnsupportedPickupMessage,
        }
    }

    pub fn addHealth(self: *Inventory, amount: f32) f32 {
        const sum: f32 = @floatCast(@as(f64, self.health) + amount);
        const health: f32 = @min(10, sum);
        const delta: f32 = @floatCast(@as(f64, health) - self.health);
        const lower = @floor(delta);
        var rounded: i32 = @intFromFloat(lower);
        if (delta - lower > 0.5 or (delta - lower == 0.5 and rounded & 1 != 0)) rounded +%= 1;
        self.statistics.health +%= rounded;
        self.health = health;
        return delta;
    }

    pub fn advance(self: *Inventory, now_ms: u32, effects: *Effects) !void {
        if (self.sheriff_due) |due| {
            if (!(due < now_ms)) return;
            self.sheriff_active = true;
            const previous = self.sheriff_remaining;
            self.sheriff_remaining -%= 1;
            if (previous != 0) {
                self.sheriff_visible = !self.sheriff_visible;
                self.sheriff_due = now_ms +% 800;
                try effects.append(.{ .sound = .{ .basename = "BLIP" } });
            } else {
                self.sheriff_active = false;
                self.sheriff_visible = false;
                self.sheriff_due = null;
                self.sheriff_task_linked = false;
            }
        }
        if (self.cloak_due) |due| {
            if (!(due < now_ms)) return;
            self.cloak_active = true;
            const previous = self.cloak_remaining;
            self.cloak_remaining -%= 1;
            if (previous != 0) {
                self.cloak_visible = !self.cloak_visible;
                self.cloak_due = now_ms +% 800;
                try effects.append(.{ .sound = .{ .basename = "BLIP" } });
            } else {
                self.cloak_active = false;
                self.cloak_visible = false;
                self.cloak_due = null;
                self.cloak_task_linked = false;
            }
        }
    }

    fn returnAmmunition(self: *Inventory, owned: OwnedItem) !void {
        if (self.player_flags & 0x10000000 != 0) return;
        const existing = self.find(owned.definition.ammo);
        const definition = if (existing != 0) self.slots[existing].?.definition else definition: {
            var available: usize = 11;
            while (available < 26 and self.slots[available] != null) : (available += 1) {}
            if (available == 26) return;
            const host = self.sound_host orelse return error.MissingInventoryResourceHost;
            const resolve = host.resolve orelse return error.MissingInventoryResourceHost;
            break :definition try resolve(host.context, owned.definition.ammo);
        };
        const ammo = try self.acquire(definition, 0);
        if (ammo != 0) {
            const returned = &self.slots[ammo].?;
            returned.count = @min(returned.definition.max_count, returned.count +% owned.loaded);
        }
    }

    fn restoreFist(self: *Inventory, a: std.mem.Allocator, archives: []const lab.Archive) !void {
        var config = try Item.parse(a, try resource(archives, "OUTLAWS.ITM") orelse return error.MissingInventoryConfiguration);
        defer config.deinit();
        _ = try self.acquire(try Definition.load(a, archives, (try config.stringValue("WEAPON_1")) orelse return error.MissingInitialWeapon), 1);
        if (self.slots[1]) |fist| if (fist.definition.item_class == 0x57454150) {
            self.selected_weapon = 1;
        };
    }

    fn takeGround(self: *Inventory, pickup: *const Pickup, effects: *Effects) !bool {
        if (!pickup.enabled) return false;
        var accepted = false;
        var reload_slots = [_]bool{false} ** 10;
        for (pickup.entries) |entry| {
            var index = self.find(entry.name);
            var changed = false;
            if (index == 0) {
                var can_acquire = self.player_flags & 0x10000000 == 0;
                if (entry.slot == 0) {
                    var free: usize = 11;
                    while (free < 26 and self.slots[free] != null) : (free += 1) {}
                    can_acquire = can_acquire and free < 26;
                }
                if (can_acquire) {
                    const definition = try Definition.load(pickup.allocator, pickup.archives, entry.name);
                    index = try self.acquire(definition, @intCast(entry.slot));
                }
                if (index != 0) {
                    if (index < 10) reload_slots[index] = true;
                    self.slots[index].?.count = @min(self.slots[index].?.definition.max_count, entry.count);
                    changed = true;
                }
            } else {
                const owned = &self.slots[index].?;
                if (owned.definition.item_class == 0x41524d52) {
                    if (owned.count < entry.count) {
                        owned.count = @min(owned.definition.max_count, entry.count);
                        changed = true;
                    }
                } else if (owned.count < owned.definition.max_count) {
                    owned.count = @min(owned.definition.max_count, owned.count +% entry.count);
                    changed = true;
                }
            }
            if (index != 0 and index < 10 and (pickup.game_type == 4 or pickup.game_type == 5)) changed = true;
            if (changed and index != 0) {
                if (@as(u16, @bitCast(pickup.flags)) & 1 == 0) {
                    switch (self.slots[index].?.definition.item_class) {
                        0x444f4355, 0x42414c4c, 0x464c4147 => {},
                        0x47424152 => {
                            self.statistics.gold +%= 1;
                            self.statistics.items +%= 1;
                        },
                        0x4753414b => {
                            self.statistics.gold +%= 5;
                            self.statistics.items +%= 1;
                        },
                        else => self.statistics.items +%= 1,
                    }
                }
                if (entry.message != -1) try effects.append(.{ .message = .{ .index = entry.message, .parameter = entry.count } });
                accepted = true;
            }
            for (reload_slots[1..], 1..) |needed, slot| if (needed) try self.reload(slot);
        }
        if (accepted) try self.pickupSound(pickup, effects) else if (pickup.entries.len == 0) try effects.append(.{ .message = .{ .index = 0x12 } });
        return accepted;
    }

    fn pickupSound(self: *const Inventory, pickup: *const Pickup, effects: *Effects) !void {
        if (pickup.sound orelse self.default_sound) |sound| try effects.append(.{ .sound = .{ .basename = sound } });
    }
};

pub fn releaseSounds(definition: Definition, phase: ReleasePhase, context: anytype, comptime release: anytype) void {
    if (phase == .common) {
        if (definition.use_success_sound) |name| release(context, name, definition.sound_names_resolved);
        if (definition.use_failure_sound) |name| release(context, name, definition.sound_names_resolved);
    } else if (definition.weapon) |weapon| {
        for (0..3) |i| {
            for ([_]?[]const u8{ weapon.fire_sound[i], weapon.empty_sound[i], weapon.action_sound[i] }) |entry|
                if (entry) |name| release(context, name, definition.sound_names_resolved);
        }
        if (weapon.reload_sound) |name| release(context, name, definition.sound_names_resolved);
        if (weapon.extra_sound) |name| release(context, name, definition.sound_names_resolved);
    } else if (definition.function == .health_object) {
        if (definition.health_sound) |name| release(context, name, definition.sound_names_resolved);
    }
}

fn short(value: i32) i16 {
    return @truncate(value);
}

fn nearest(value: f32) i32 {
    const lower = @floor(value);
    var rounded: i32 = @intFromFloat(lower);
    if (value - lower > 0.5 or (value - lower == 0.5 and rounded & 1 != 0)) rounded +%= 1;
    return rounded;
}

fn costumeBasename(path: []const u8) ![]const u8 {
    const source = path[0 .. std.mem.indexOfScalar(u8, path, 0) orelse path.len];
    var start: usize = 0;
    for (source, 0..) |character, i| if (character == '\\' or character == ':') {
        start = i + 1;
    };
    const name = source[start..];
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        if (dot + 1 == name.len) return error.InvalidInventoryCostume;
        return name[0..dot];
    }
    return name;
}

fn fieldName(buffer: []u8, stem: []const u8, index: usize) ![]const u8 {
    return if (index == 0) stem else std.fmt.bufPrint(buffer, "{s}{d}", .{ stem, index });
}

fn resource(archives: []const lab.Archive, name: []const u8) !?[]const u8 {
    for (archives) |archive| return archive.find(name, 0) catch |err| switch (err) {
        error.ResourceNotFound => continue,
        else => return err,
    };
    return null;
}

fn testArchives(a: std.mem.Allocator) ![3]lab.Archive {
    var archives: [3]lab.Archive = undefined;
    for ([_][]const u8{ "OUTLAWS", "OLOBJ", "OLWEAP" }, &archives) |name, *destination| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        destination.* = try lab.Archive.init(data);
    }
    return archives;
}

fn digestState(digest: *std.crypto.hash.sha2.Sha256, inventory: *const Inventory, result: u32) void {
    for (inventory.slots[1..], 1..) |slot, i| if (slot) |owned| {
        const words = [_]u32{ @intCast(i), owned.definition.item_class, @bitCast(owned.count), @bitCast(owned.definition.max_count), @bitCast(owned.loaded), @intFromBool(owned.definition.no_show) };
        for (words) |word| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, word, .little);
            digest.update(&bytes);
        }
        digest.update(owned.definition.name);
        digest.update(&.{0});
    };
    for ([_]u32{ 0, @bitCast(inventory.health), @bitCast(inventory.statistics.items), @bitCast(inventory.statistics.gold), @bitCast(inventory.statistics.health), @intCast(inventory.selected), result }) |word| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        digest.update(&bytes);
    }
}

test "inventory costume basename matches Windows path and first-dot rules" {
    const cases = [_][2][]const u8{
        .{ "IPISTOL.NWX", "IPISTOL" },
        .{ "IJPistol", "IJPistol" },
        .{ "C:\\ART\\IPISTOL.NWX", "IPISTOL" },
        .{ "C:IPISTOL.NWX", "IPISTOL" },
        .{ "ART\\", "" },
        .{ "C:", "" },
        .{ "", "" },
        .{ "ART/IPISTOL.NWX", "ART/IPISTOL" },
        .{ "ART.V1\\IPISTOL.V2.NWX", "IPISTOL" },
        .{ ".NWX", "" },
        .{ "A..NWX", "A" },
        .{ "A:B:C.NWX", "C" },
        .{ "A\\B:C\\D.NWX", "D" },
        .{ "A\\B/C.NWX", "B/C" },
        .{ "IPISTOL.NWX\x00IGNORED", "IPISTOL" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], try costumeBasename(case[0]));
    try std.testing.expectError(error.InvalidInventoryCostume, costumeBasename("IPISTOL."));
}

test "player bind flags and restart preparation preserve inventory branch order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/player-bind-inventory-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const NativeSlot = struct {
        slot: usize,
        name: []const u8,
        class: u32,
        count: i32,
        max_count: i32,
        loaded: i32,
        no_show: u8,
    };
    const Corpus = struct { executable_sha256: []const u8, results_sha256: []const u8, cases: []struct { kind: []const u8, flags: u32, dead: bool, state: struct { slots: []NativeSlot, selected: usize, selected_weapon: usize } } };
    const corpus = (try std.json.parseFromSlice(Corpus, a, bytes, .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("165dd8ea86c5e50c18f7f7d6f75d662efbcaff68d2d38503a01c41c0d63a69f2", corpus.results_sha256);
    const archives = try testArchives(a);
    var cid = try Item.parse(a, (try resource(&archives, "CIDJAMES.ITM")).?);
    defer cid.deinit();
    const Resources = struct {
        allocator: std.mem.Allocator,
        archives: []const lab.Archive,
        acquisitions: usize = 0,
        releases: usize = 0,

        fn acquire(raw: *anyopaque, _: Definition, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.acquisitions += 1;
        }

        fn release(raw: *anyopaque, _: Definition, _: ReleasePhase) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }

        fn resolve(raw: *anyopaque, name: []const u8) !Definition {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return Definition.load(self.allocator, self.archives, name);
        }
    };
    for (corpus.cases) |case| {
        var resources: Resources = .{ .allocator = a, .archives = &archives };
        var inventory: Inventory = .{ .clock = 1000, .sound_host = .{ .context = &resources, .acquire = Resources.acquire, .release = Resources.release, .resolve = Resources.resolve } };
        for ([_][]const u8{ "IDOCBAG", "IBRSSKEY" }, [_]i32{ 3, 1 }) |name, count| {
            const slot = try inventory.acquire(try Definition.load(a, &archives, name), 0);
            inventory.slots[slot].?.count = count;
        }
        try inventory.startItems(a, &archives, &cid);
        if (std.mem.eql(u8, case.kind, "bind")) {
            inventory.player_flags = 4;
            try inventory.applyLevelFlags(a, &archives, &cid, case.flags);
        } else {
            try std.testing.expectEqualStrings("restart", case.kind);
            inventory.selected_weapon = 2;
            inventory.player_flags = if (case.dead) 0x10000000 else 4;
            try inventory.releaseAllSounds();
            try inventory.startItems(a, &archives, &cid);
        }
        try std.testing.expectEqual(case.state.selected, inventory.selected);
        try std.testing.expectEqual(case.state.selected_weapon, inventory.selected_weapon);
        var actual_count: usize = 0;
        for (inventory.slots) |slot| if (slot != null) {
            actual_count += 1;
        };
        try std.testing.expectEqual(case.state.slots.len, actual_count);
        for (case.state.slots) |expected| {
            const actual = inventory.slots[expected.slot] orelse return error.MissingNativeInventorySlot;
            try std.testing.expectEqualStrings(expected.name, actual.definition.name);
            try std.testing.expectEqual(expected.class, actual.definition.item_class);
            try std.testing.expectEqual(expected.count, actual.count);
            try std.testing.expectEqual(expected.max_count, actual.definition.max_count);
            try std.testing.expectEqual(expected.loaded, actual.loaded);
            try std.testing.expectEqual(expected.no_show != 0, actual.definition.no_show);
        }
    }
}

test "inventory destruction releases sounds and returns loaded ammunition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inventory-sound-release-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { name: []const u8, loaded: i32, prior_ammo: ?i32, dead: bool, ammo_count: ?i32, releases: [][]const u8 },
    };
    const corpus = (try std.json.parseFromSlice(Corpus, a, bytes, .{})).value;
    try std.testing.expectEqualStrings("f356ac06019a6b75c829aea9f7d19828b40e9e3e6d27a0acc194567845d6621b", corpus.results_sha256);
    const archives = try testArchives(a);
    const Capture = struct {
        allocator: std.mem.Allocator,
        archives: []const lab.Archive,
        names: [32][256]u8 = undefined,
        lengths: [32]usize = undefined,
        count: usize = 0,
        acquired: usize = 0,

        fn acquire(raw: *anyopaque, _: Definition, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.acquired += 1;
        }

        fn resolve(raw: *anyopaque, name: []const u8) !Definition {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return Definition.load(self.allocator, self.archives, name);
        }

        fn release(raw: *anyopaque, definition: Definition, phase: ReleasePhase) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            releaseSounds(definition, phase, self, emit);
        }

        fn emit(self: *@This(), name: []const u8, resolved: bool) void {
            const value = if (resolved) std.fmt.bufPrint(&self.names[self.count], "{s}", .{name}) catch unreachable else std.fmt.bufPrint(&self.names[self.count], "{s}.wav", .{name}) catch unreachable;
            self.lengths[self.count] = value.len;
            self.count += 1;
        }
    };
    for (corpus.cases) |case| {
        var inventory: Inventory = .{};
        const definition = try Definition.load(a, &archives, case.name);
        const slot = try inventory.acquire(definition, 0);
        inventory.slots[slot].?.loaded = case.loaded;
        if (case.prior_ammo) |count| {
            const ammo = try inventory.acquire(try Definition.load(a, &archives, definition.ammo), 0);
            inventory.slots[ammo].?.count = count;
        }
        var captured: Capture = .{ .allocator = a, .archives = &archives };
        inventory.sound_host = .{ .context = &captured, .acquire = Capture.acquire, .release = Capture.release, .resolve = Capture.resolve };
        inventory.player_flags = if (case.dead) 0x10000000 else 0;
        try inventory.remove(slot);
        try std.testing.expect(inventory.slots[slot] == null);
        try std.testing.expectEqual(case.releases.len, captured.count);
        for (case.releases, 0..) |name, index| try std.testing.expectEqualStrings(name, captured.names[index][0..captured.lengths[index]]);
        const ammo = inventory.find(definition.ammo);
        try std.testing.expectEqual(case.ammo_count, if (ammo != 0) inventory.slots[ammo].?.count else null);
        try std.testing.expectEqual(@as(usize, if (case.prior_ammo == null and case.ammo_count != null) 1 else 0), captured.acquired);
    }
}

test "inventory startup and twenty pickups match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archives = try testArchives(a);
    var cid = try Item.parse(a, (try resource(&archives, "CIDJAMES.ITM")).?);
    defer cid.deinit();
    var inventory = try Inventory.init(a, &archives, &cid);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digestState(&digest, &inventory, @intCast(inventory.selected_weapon));
    try std.testing.expectEqual(@as(i32, 60), inventory.slots[inventory.find("IOIL")].?.count);
    const names = [_][]const u8{
        "GAMBOXB", "GAMBOXB", "GAMBOXB", "GAMBOXB",  "GAMBOXB",  "GAMBOXB",  "GAMBOXB",  "GAMBOXB", "GAMBOXB",
        "GAMBOXC", "GAMBOXC", "GAMBELT", "GBRSSKEY", "GBRSSKEY", "GIRONKEY", "GSTEEKEY", "GDOCBAG", "GSATCHEL",
        "GOIL",    "GRIFLE",
    };
    var effects = Effects.init(a);
    for (names, 0..) |name, i| {
        effects.clearRetainingCapacity();
        const path = try std.fmt.allocPrint(a, "{s}.ITM", .{name});
        var definition = try Item.parse(a, (try resource(&archives, path)).?);
        defer definition.deinit();
        const pickup = try Pickup.parse(a, &archives, &definition, if (i == 9 or i == 10) 0x200000 else 0x100000, 1);
        const accepted = try inventory.take(&pickup, 0, &effects);
        digestState(&digest, &inventory, @intFromBool(accepted));
        if (i == 7 or i == 8 or i == 13) {
            try std.testing.expect(!accepted);
            try std.testing.expectEqual(@as(usize, 0), effects.items.len);
        }
        if (i == names.len - 1) {
            try std.testing.expectEqual(@as(usize, 2), effects.items.len);
            try std.testing.expectEqual(@as(i32, 201), effects.items[0].message.index);
            try std.testing.expectEqual(@as(?i32, 12), effects.items[0].message.parameter);
            try std.testing.expectEqualStrings("WEAPGRAB", effects.items[1].sound.basename);
        }
    }
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "88b47919d8103e3ea54a3ca5afa82249ee7ba8f775cbb3d26fe731328e2773cf");
    try std.testing.expectEqualSlices(u8, &expected, &digest.finalResult());
}

test "Death Match accepts an existing full weapon pickup as in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archives = try testArchives(a);
    var cid = try Item.parse(a, (try resource(&archives, "CIDJAMES.ITM")).?);
    defer cid.deinit();
    var inventory = try Inventory.init(a, &archives, &cid);
    const slot: usize = 1;
    const weapon_name = inventory.slots[slot].?.definition.name;
    const item_bytes = try std.fmt.allocPrint(a, "ITEM 1.0\nFUNC Inv_GroundObject\nDATA 2\nSTR PICKUP {s}\nINT COUNT 1\n", .{weapon_name});
    var weapon_pickup = try Item.parse(a, item_bytes);
    defer weapon_pickup.deinit();
    const campaign_pickup = try Pickup.parse(a, &archives, &weapon_pickup, 0x200000, 1);
    const network_pickup = try Pickup.parse(a, &archives, &weapon_pickup, 0x200000, 5);
    const maximum = inventory.slots[slot].?.definition.max_count;
    inventory.slots[slot].?.count = maximum;
    var effects = Effects.init(a);
    try std.testing.expect(!try inventory.take(&campaign_pickup, 0, &effects));
    try std.testing.expect(try inventory.take(&network_pickup, 0, &effects));
    try std.testing.expectEqual(maximum, inventory.slots[slot].?.count);
}

test "inventory health cap and statistic retain x87 rounding" {
    const cases = [_]struct { initial: f32, amount: f32, result: f32, statistic: i32 }{
        .{ .initial = 0, .amount = 0.1, .result = 0.1, .statistic = 0 },
        .{ .initial = 9, .amount = 1, .result = 10, .statistic = 1 },
        .{ .initial = 9.5, .amount = 1, .result = 10, .statistic = 0 },
        .{ .initial = 8.5, .amount = 1, .result = 9.5, .statistic = 1 },
        .{ .initial = -1, .amount = 10, .result = 9, .statistic = 10 },
        .{ .initial = 10, .amount = 1, .result = 10, .statistic = 0 },
    };
    for (cases) |case| {
        var inventory: Inventory = .{ .health = case.initial };
        _ = inventory.addHealth(case.amount);
        try std.testing.expectEqual(case.result, inventory.health);
        try std.testing.expectEqual(case.statistic, inventory.statistics.health);
    }
}

test "inventory instant pickup and sheriff task match handlers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archives = try testArchives(a);
    var canteen_item = try Item.parse(a, (try resource(&archives, "GCANTEEN.ITM")).?);
    defer canteen_item.deinit();
    var elixir_item = try Item.parse(a, (try resource(&archives, "GELIXIR.ITM")).?);
    defer elixir_item.deinit();
    var badge_item = try Item.parse(a, (try resource(&archives, "GBADGE.ITM")).?);
    defer badge_item.deinit();
    const canteen = try Pickup.parse(a, &archives, &canteen_item, 0x100000, 1);
    const elixir = try Pickup.parse(a, &archives, &elixir_item, 0x100000, 1);
    const badge = try Pickup.parse(a, &archives, &badge_item, 0x100000, 1);
    var inventory: Inventory = .{};
    var effects = Effects.init(a);
    try std.testing.expect(!try inventory.take(&canteen, 0, &effects));
    try std.testing.expectEqual(@as(usize, 0), effects.items.len);
    inventory.health = 9.5;
    try std.testing.expect(try inventory.take(&canteen, 0, &effects));
    try std.testing.expectEqual(@as(f32, 10), inventory.health);
    try std.testing.expectEqual(@as(i32, 0), inventory.statistics.health);
    try std.testing.expectEqualStrings("GULP", effects.items[0].sound.basename);
    try std.testing.expectEqual(@as(i32, 303), effects.items[1].message.index);
    effects.clearRetainingCapacity();
    inventory.health = 3;
    try std.testing.expect(try inventory.take(&elixir, 0, &effects));
    try std.testing.expectEqual(@as(f32, 10), inventory.health);
    try std.testing.expectEqual(@as(i32, 7), inventory.statistics.health);
    effects.clearRetainingCapacity();
    try std.testing.expect(try inventory.take(&badge, 1000, &effects));
    try std.testing.expectEqual(@as(i32, 310), effects.items[0].message.index);
    try std.testing.expectEqualStrings("TWIRL", effects.items[1].sound.basename);
    try std.testing.expectEqual(@as(i32, 1), inventory.statistics.items);
    const Timer = struct {
        now: u32,
        active: bool,
        visible: bool,
        remaining: i32,
        due: ?u32,
        sound: bool,
    };
    const sequence = [_]Timer{
        .{ .now = 31000, .active = true, .visible = true, .remaining = 6, .due = 31000, .sound = false },
        .{ .now = 31001, .active = true, .visible = false, .remaining = 5, .due = 31801, .sound = true },
        .{ .now = 31801, .active = true, .visible = false, .remaining = 5, .due = 31801, .sound = false },
        .{ .now = 31802, .active = true, .visible = true, .remaining = 4, .due = 32602, .sound = true },
        .{ .now = 32603, .active = true, .visible = false, .remaining = 3, .due = 33403, .sound = true },
        .{ .now = 33404, .active = true, .visible = true, .remaining = 2, .due = 34204, .sound = true },
        .{ .now = 34205, .active = true, .visible = false, .remaining = 1, .due = 35005, .sound = true },
        .{ .now = 35006, .active = true, .visible = true, .remaining = 0, .due = 35806, .sound = true },
        .{ .now = 35807, .active = false, .visible = false, .remaining = -1, .due = null, .sound = false },
    };
    for (sequence) |expected| {
        effects.clearRetainingCapacity();
        try inventory.advance(expected.now, &effects);
        try std.testing.expectEqual(expected.active, inventory.sheriff_active);
        try std.testing.expectEqual(expected.visible, inventory.sheriff_visible);
        try std.testing.expectEqual(expected.remaining, inventory.sheriff_remaining);
        try std.testing.expectEqual(expected.due, inventory.sheriff_due);
        try std.testing.expectEqual(@as(usize, @intFromBool(expected.sound)), effects.items.len);
        if (expected.sound) try std.testing.expectEqualStrings("BLIP", effects.items[0].sound.basename);
    }
    _ = try inventory.take(&badge, 40000, &effects);
    try inventory.advance(70001, &effects);
    try std.testing.expect(!inventory.sheriff_visible);
    _ = try inventory.take(&badge, 70500, &effects);
    try std.testing.expect(inventory.sheriff_visible);
    try std.testing.expectEqual(@as(?u32, 100500), inventory.sheriff_due);
    effects.clearRetainingCapacity();
    try inventory.advance(70801, &effects);
    try inventory.advance(100500, &effects);
    try std.testing.expectEqual(@as(usize, 0), effects.items.len);
    try inventory.advance(100501, &effects);
    try std.testing.expectEqual(@as(i32, 5), inventory.sheriff_remaining);
    try std.testing.expectEqual(@as(?u32, 101301), inventory.sheriff_due);
    try std.testing.expectEqual(@as(usize, 1), effects.items.len);
}

test "inventory validates negative pickup allocation and invalid signed slots" {
    const a = std.testing.allocator;
    var negative = try Item.parse(a, "ITEM 1.0\nFUNC Inv_GroundObject\nDATA 1\nINT PICKUP_COUNT -1\n");
    defer negative.deinit();
    try std.testing.expectError(error.InvalidPickupCount, Pickup.parse(a, &.{}, &negative, 0x100000, 1));
    var bad_slot = try Item.parse(a, "ITEM 1.0\nFUNC Inv_GroundObject\nDATA 2\nSTR PICKUP IKEY\nINT SLOT -1\n");
    defer bad_slot.deinit();
    try std.testing.expectError(error.InvalidInventorySlot, Pickup.parse(a, &.{}, &bad_slot, 0x100000, 1));
    try std.testing.expectError(error.MissingInventoryItem, Definition.load(a, &.{}, "IKEY"));
}

test "inventory missing numeric fields clear scratch and count default precedes truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const archives = try testArchives(a);
    var absent = try Item.parse(a, "ITEM 1.0\nFUNC Inv_GroundObject\nDATA 2\nINT FLAGS 99\nSTR PICKUP ICART\n");
    defer absent.deinit();
    const defaulted = try Pickup.parse(a, &archives, &absent, 0x100000, 1);
    try std.testing.expectEqual(@as(i16, 99), defaulted.flags);
    try std.testing.expectEqual(@as(i16, 1), defaulted.entries[0].count);
    try std.testing.expectEqual(@as(i16, 0), defaulted.entries[0].slot);
    try std.testing.expectEqual(@as(i16, -1), defaulted.entries[0].message);
    var truncated = try Item.parse(a, "ITEM 1.0\nFUNC Inv_GroundObject\nDATA 3\nINT FLAGS 99\nSTR PICKUP ICART\nINT COUNT 65536\n");
    defer truncated.deinit();
    const wrapped = try Pickup.parse(a, &archives, &truncated, 0x100000, 1);
    try std.testing.expectEqual(@as(i16, 0), wrapped.entries[0].count);
    var cartridges = try Item.parse(a, "ITEM 1.0\nFUNC Inv_GroundObject\nDATA 2\nSTR PICKUP ICART\nINT COUNT 7\n");
    defer cartridges.deinit();
    const campaign_cartridges = try Pickup.parse(a, &archives, &cartridges, 0x200000, 1);
    const death_match_cartridges = try Pickup.parse(a, &archives, &cartridges, 0x200000, 5);
    try std.testing.expectEqual(@as(i16, 3), campaign_cartridges.entries[0].count);
    try std.testing.expectEqual(@as(i16, 7), death_match_cartridges.entries[0].count);
    var health = try Item.parse(a, "ITEM 1.0\nFUNC Inv_InstantGroundObject\nDATA 1\nINT FLAGS 37\n");
    defer health.deinit();
    const instant = try Pickup.parse(a, &archives, &health, 0x100000, 1);
    try std.testing.expectEqual(@as(u8, 0), instant.health_bonus);
    var inventory: Inventory = .{ .health = 9 };
    var effects = Effects.init(a);
    try std.testing.expect(try inventory.take(&instant, 0, &effects));
    try std.testing.expectEqual(@as(f32, 9), inventory.health);
    var fractional = try Item.parse(a, "ITEM 1.0\nFUNC Inv_InstantGroundObject\nDATA 1\nINT HEALTH_B 9\n");
    defer fractional.deinit();
    const fractional_pickup = try Pickup.parse(a, &archives, &fractional, 0x100000, 1);
    inventory.health = 0;
    try std.testing.expect(try inventory.take(&fractional_pickup, 0, &effects));
    try std.testing.expectEqual(@as(u32, 0x3f666667), @as(u32, @bitCast(inventory.health)));
}

test "a definition that fails part way through keeps none of its strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const archives = try testArchives(arena.allocator());
    const Load = struct {
        fn run(a: std.mem.Allocator, sources: []const lab.Archive, name: []const u8) !void {
            var definition = try Definition.load(a, sources, name);
            definition.deinit(a);
        }
    };
    for ([_][]const u8{ "IRIFLE", "IDOCBAG", "IDYNAM" }) |name| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Load.run, .{ @as([]const lab.Archive, &archives), name });
    }
}
