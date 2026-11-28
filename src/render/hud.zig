//! The HUD: a tree of nodes with their own sprite playback, the panel that
//! slides, and the values the gauges show.
//!
//! Coordinates are fixed-point fractions of the 640x480 screen the HUD was
//! laid out for. Parents multiply their children's slide values rather than
//! their coordinates. A timed node moves one unit before its update, so the
//! first step is visible immediately.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const inventory_module = @import("../player/inventory.zig");
const Inventory = inventory_module.Inventory;
const OwnedItem = inventory_module.OwnedItem;

pub const scale: i32 = 0x10000;

pub const Rect = struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };

pub const Node = struct {
    costume: ?*const nwx.Costume = null,
    playback: nwx.Playback = .{},
    rect: Rect = .{},
    clip: Rect = .{},
    clear: bool = false,
    slide: i32 = 0,
    minimum: i32 = 0,
    maximum: i32 = 0x10000,
    velocity: i32 = 0,
    last_time: u32 = 0,
    combined: i32 = 0,
    value: i32 = -1,
    parent: ?*Node = null,
    first_child: ?*Node = null,
    next: ?*Node = null,

    fn show(self: *Node, duration: i32) void {
        if (self.slide == self.maximum) return;

        if (duration == 0) self.slide = self.maximum else {
            self.slide +%= 1;
            self.velocity = @divTrunc(self.maximum -% self.minimum, duration);
        }
    }

    fn hide(self: *Node, duration: i32) void {
        if (self.slide == self.minimum) return;

        if (duration == 0) self.slide = self.minimum else {
            self.slide -%= 1;
            self.velocity = @divTrunc(-0x10000, duration);
        }
    }

    fn update(self: *Node, parent_slide: i32, now: u32) void {
        self.slide +%= @as(i32, @bitCast(now -% self.last_time)) *% self.velocity;

        if (self.slide < self.minimum) {
            self.slide = self.minimum;
            self.velocity = 0;
        } else if (self.slide > self.maximum) {
            self.slide = self.maximum;
            self.velocity = 0;
        }

        self.combined = @as(
            i32,
            @bitCast(@as(u32, @bitCast(parent_slide)) >> 8),
        ) *% (self.slide >> 8);

        self.last_time = now;

        var child = self.first_child;

        while (child) |node| : (child = node.next) node.update(self.combined, now);
    }

    fn select(self: *Node, sequence: u32, now: u32) !void {
        const costume = self.costume orelse return error.MissingHudCostume;
        if (sequence >= costume.choreographies.len) return;

        self.playback.last_time = now;
        self.playback.choreography = sequence;
        self.playback.next_frame = 0;
        self.playback.frame = 0;
        self.playback.direction = costume.choreographies[sequence].directions -% 1;

        self.playback.flags.start();

        try self.playback.advance(costume, 1, now);
    }

    fn frame(self: *const Node) !*const nwx.Frame {
        const costume = self.costume orelse return error.MissingHudCostume;

        return costume.select(self.playback.choreography, self.playback.frame, 0, 0);
    }

    fn animate(self: *Node, now: u32) anyerror!void {
        if (self.costume) |costume| try self.playback.advance(costume, 0, now);
        var child = self.first_child;
        while (child) |node| : (child = node.next) try node.animate(now);
    }
};

const Resource = struct { name: []const u8, costume: nwx.Costume };

pub const PanelTree = struct {
    panel: *Node,
    gauge_background: *Node,
    stamina_gauge: *Node,
    air_gauge: *Node,
};

pub const WeaponAnimation = struct {
    costume: *const nwx.Costume,
    playback: *nwx.Playback,
    ready: bool,
    slot: usize,
};

pub const Hud = struct {
    allocator: std.mem.Allocator,
    archives: []lab.Archive,
    resources: std.array_list.Managed(*Resource),
    panel: *Node,
    gauge_background: *Node,
    stamina_gauge: *Node,
    air_gauge: *Node,
    status: *Node,
    health_group: *Node,
    hearts: [10]*Node,
    dead_heart: *Node,
    weapon_group: *Node,
    digits_group: *Node,
    digits: [3]*Node,
    weapon: ?*Node = null,
    loaded_group: ?*Node = null,
    cartridges: [12]?*Node = [_]?*Node{null} ** 12,
    cartridge_unit: i32 = 1,
    selected_group: ?*Node = null,
    selected_icon: ?*Node = null,
    fuel_group: ?*Node = null,
    fuel_icon: ?*Node = null,
    armor_group: ?*Node = null,
    armor_icon: ?*Node = null,
    badge: *Node,
    sheriff_visible: bool = false,
    panel_shown: bool = true,
    second: ?PanelTree = null,
    placed_3d: bool = false,
    sound_request: ?inventory_module.Effect = null,
    blend_table: ?[]const u8 = null,
    color_map: ?[]const u8 = null,
    status_pixels: []u8,
    status_height: i32,
    status_y: i32,
    gauge_width: i32,
    now: u32,
    weapon_animation_external: bool = false,
    browser: @import("inventory_browser.zig").Browser = .{},

    pub fn init(a: std.mem.Allocator, archives: []const lab.Archive, now: u32, v111: bool) !Hud {
        var result: Hud = undefined;

        result.allocator = a;
        result.archives = try a.dupe(lab.Archive, archives);
        errdefer a.free(result.archives);
        result.resources = std.array_list.Managed(*Resource).init(a);
        errdefer {
            for (result.resources.items) |res| {
                res.costume.deinit();
                a.free(res.name);
                a.destroy(res);
            }

            result.resources.deinit();
        }

        result.now = now;
        result.weapon_animation_external = false;
        result.browser = .{};
        result.weapon = null;
        result.loaded_group = null;
        result.cartridges = [_]?*Node{null} ** 12;
        result.cartridge_unit = 1;
        result.selected_group = null;
        result.selected_icon = null;
        result.fuel_group = null;
        result.fuel_icon = null;
        result.armor_group = null;
        result.armor_icon = null;
        result.sheriff_visible = false;
        result.second = null;
        result.placed_3d = false;
        result.panel_shown = true;
        result.sound_request = null;
        result.blend_table = null;
        result.color_map = null;

        const interface = try result.resource("interfac.nwx");

        result.panel = try result.create(null, interface, 0, true);
        errdefer result.destroy(result.panel);

        result.panel.show(0);

        result.panel.rect.x = 320;
        result.panel.rect.y = 480;
        result.panel.rect.height = (480 - nearest(480.0 * @as(f64, @as(f32, 0.9166667)))) + 1;

        const thermometer = if (v111) try result.optionalResource("thermom.nwx") else null;
        var second_panel: ?*Node = null;
        errdefer if (second_panel) |node| result.destroy(node);

        if (thermometer) |costume| {
            const node = try result.create(null, costume, 0, true);
            second_panel = node;
            node.show(0);

            node.rect.x = 320;
            node.rect.y = 480;
            node.rect.height = result.panel.rect.height;
        }

        result.gauge_background = try result.create(result.panel, interface, 2, false);
        result.gauge_background.show(0);
        var gauge_clip = result.gauge_background.rect;

        gauge_clip.x += 320;
        gauge_clip.y += 480;
        result.gauge_width = gauge_clip.width;
        result.gauge_background.rect.x = 320;
        result.gauge_background.rect.y = 480;

        var second_background: ?*Node = null;

        if (second_panel) |panel| {
            const node = try result.create(panel, thermometer.?, 2, false);
            second_background = node;
            node.show(0);

            node.rect.x = 320;
            node.rect.y = 480;
        }

        result.stamina_gauge = try result.create(result.gauge_background, interface, 1, false);
        result.stamina_gauge.minimum = -0x50000;

        result.stamina_gauge.show(0);

        result.stamina_gauge.rect.x = 320;
        result.stamina_gauge.rect.y = 480;
        result.stamina_gauge.clip = gauge_clip;

        var second_stamina: ?*Node = null;

        if (second_background) |background| {
            const node = try result.create(background, thermometer.?, 1, false);

            second_stamina = node;
            node.minimum = -0x50000;

            node.show(0);

            node.rect.x = 320;
            node.rect.y = 480;
            node.clip = gauge_clip;
        }

        result.air_gauge = try result.create(result.gauge_background, interface, 3, false);
        result.air_gauge.minimum = -0x50000;

        result.air_gauge.hide(0);

        result.air_gauge.rect.x = 320;
        result.air_gauge.rect.y = 480;
        result.air_gauge.clip = gauge_clip;

        if (second_background) |background| {
            const node = try result.create(background, thermometer.?, 3, false);
            node.minimum = -0x50000;
            node.hide(0);

            node.rect.x = 320;
            node.rect.y = 480;
            node.clip = gauge_clip;
            result.second = .{
                .panel = second_panel.?,
                .gauge_background = background,
                .stamina_gauge = second_stamina.?,
                .air_gauge = node,
            };
        }

        result.status = try result.create(null, null, 0, false);
        errdefer result.destroy(result.status);

        result.status.show(0);
        result.health_group = try result.create(result.status, null, 0, true);
        result.health_group.hide(0);
        const heart = try result.resource("intheart.nwx");

        for (&result.hearts) |*node| {
            node.* = try result.create(result.health_group, heart, 0, false);
            node.*.minimum = 0x8000;
            node.*.slide = 0x8000;
            node.*.show(0);
        }

        result.dead_heart = try result.create(result.status, heart, 2, false);
        result.status_height = 2 - result.hearts[0].rect.y;

        const heart_width = result.hearts[0].rect.width;
        const heart_step = (heart_width *% 0x4000) >> 16;
        var x = 0x222 + @divTrunc(@divTrunc(heart_width, 2) + heart_step * 9, 2);

        for (result.hearts) |node| {
            node.rect.x = x;
            node.rect.y = result.status_height;
            x -= heart_step;
        }

        const half_heart_width = @divTrunc(
            heart_width,
            2,
        );

        result.dead_heart.rect.x = 0x22e;
        result.dead_heart.rect.y = result.status_height;
        result.health_group.rect = .{
            .x = result.hearts[9].rect.x - half_heart_width - 1,
            .width = -(result.hearts[9].rect.x - half_heart_width - 1) + result.hearts[0].rect.x + 2,
            .height = result.status_height,
        };

        result.weapon_group = try result.create(result.status, null, 0, false);

        result.weapon_group.hide(0);
        result.digits_group = try result.create(result.weapon_group, null, 0, true);
        result.digits_group.show(0);
        const numbers = try result.resource("numbers.nwx");

        for (&result.digits) |*node| {
            node.* = try result.create(result.digits_group, numbers, 0, false);
            node.*.hide(0);
        }

        const digit_width = result.digits[0].rect.width;
        const digit_step = (digit_width *% 0xc000) >> 16;

        x = 0xc4 + @divTrunc(@divTrunc(digit_width, 2) + digit_step * 2, 2);

        for (result.digits) |node| {
            node.rect.x = x;
            node.rect.y = result.status_height;
            x -= digit_step;
        }

        const half_digit_width = @divTrunc(digit_width, 2);

        result.digits_group.rect = .{
            .x = result.digits[2].rect.x - half_digit_width,
            .width = result.digits[0].rect.x - (result.digits[2].rect.x - half_digit_width) + half_digit_width + 1,
            .height = result.status_height,
        };

        result.status_y = result.panel.rect.y - result.panel.rect.height - result.status_height + 1;
        if (result.status_height < 1 or result.status_height > 480) return error.InvalidHudLayout;

        result.status_pixels = try a.alloc(u8, @as(usize, @intCast(result.status_height)) * 640);
        errdefer a.free(result.status_pixels);

        @memset(result.status_pixels, 0);

        result.badge = try result.create(null, try result.resource("hbadge.nwx"), 0, false);
        result.badge.playback = .{ .last_time = now };

        return result;
    }

    pub fn deinit(self: *Hud) void {
        if (self.weapon) |node| self.destroy(node);

        self.destroy(self.panel);

        if (self.second) |tree| self.destroy(tree.panel);

        self.destroy(self.status);
        self.destroy(self.badge);
        self.allocator.free(self.status_pixels);

        for (self.resources.items) |res| {
            res.costume.deinit();
            self.allocator.free(res.name);
            self.allocator.destroy(res);
        }

        self.resources.deinit();
        self.allocator.free(self.archives);

        self.* = undefined;
    }

    pub fn resource(self: *Hud, name: []const u8) !*const nwx.Costume {
        return try self.optionalResource(name) orelse error.MissingHudCostume;
    }

    pub fn update(
        self: *Hud,
        inventory: *const Inventory,
        stamina: f32,
        breath: f32,
        now: u32,
    ) !void {
        self.now = now;
        self.sound_request = null;

        try self.panel.animate(now);
        try self.status.animate(now);
        try self.badge.animate(now);
        try self.browser.advance(now);

        if (!self.weapon_animation_external) if (self.weapon) |node| try node.animate(now);

        var heart_index = nearest(inventory.health);

        if (@as(f32, @floatFromInt(heart_index)) == inventory.health) heart_index -%= 1;

        if (self.health_group.value != heart_index) {
            self.health_group.value = heart_index;

            for (self.hearts, 0..) |node, i| {
                const index: i32 = @intCast(i);

                if (index < heart_index and i != 9) {
                    try node.select(1, now);
                    node.show(150);
                } else if (index == heart_index or (i == 9 and heart_index > 9)) {
                    try node.select(0, now);
                    node.show(150);
                } else {
                    try node.select(0, now);
                    node.hide(150);
                }
            }
        }

        if (@as(i32, @bitCast(inventory.health)) < 1) {
            if (self.dead_heart.slide == self.dead_heart.minimum) {
                self.dead_heart.show(150);
                self.sound_request = .{
                    .sound = .{
                        .basename = "cashopen.wav",
                        .priority = 64,
                        .volume = 127,
                        .flags = .default,
                    },
                };
            }

            self.health_group.hide(150);
        } else {
            if (self.dead_heart.slide == self.dead_heart.maximum) {
                self.dead_heart.hide(150);
                self.sound_request = .{
                    .sound = .{
                        .basename = "cashcls.wav",
                        .priority = 64,
                        .volume = 127,
                        .flags = .default,
                    },
                };
            }

            self.health_group.show(150);
        }

        if (!inventory.player_flags.dead) {
            if (@as(u32, @bitCast(breath)) & 0x7fffffff == 0) {
                self.air_gauge.hide(0);
                self.stamina_gauge.show(0);
                setGauge(self.stamina_gauge, self.gauge_width, stamina);
            } else {
                const remaining = 100 - @as(f64, breath) / 30 * 100;
                const air: f32 = if (remaining <= 0) 0 else @floatCast(remaining);

                self.air_gauge.show(0);
                self.stamina_gauge.hide(0);
                setGauge(self.air_gauge, self.gauge_width, air);
            }
        }

        try self.updateWeapon(inventory);
        try self.updateItems(inventory);
        self.panel.update(0x10000, now);
        self.status.update(0x10000, now);

        if (self.weapon) |node| node.update(0x10000, now);

        self.sheriff_visible = inventory.sheriff_visible;
    }

    pub fn weaponAnimation(self: *Hud) ?WeaponAnimation {
        const node = self.weapon orelse return null;

        return .{
            .costume = node.costume orelse return null,
            .playback = &node.playback,
            .ready = node.slide == node.maximum,
            .slot = @intCast(node.value),
        };
    }

    pub fn draw(self: *Hud, pixels: []u8) !void {
        if (pixels.len != 640 * 480) return error.InvalidHudFramebuffer;

        if (self.panel.slide != self.panel.minimum) {
            @memset(self.status_pixels, 0);
            try drawNode(
                self.status_pixels,
                640,
                self.status_height,
                self.status,
                self.blend_table,
            );

            const y = self.status_y + ((self.panel.rect.height *% (0x10000 -% self.panel.slide) *% 2) >> 16);

            for (0..@intCast(self.status_height)) |row| {
                const destination_y = y + @as(i32, @intCast(row));

                if (destination_y < 0 or destination_y >= 480) continue;

                for (self.status_pixels[row * 640 ..][0..640], 0..) |color, x| {
                    if (color != 0) pixels[@as(usize, @intCast(destination_y)) * 640 + x] = color;
                }
            }
        }

        if (self.panel.slide == self.panel.maximum) try drawNode(
            pixels,
            640,
            480,
            self.panel,
            self.blend_table,
        );

        if (self.sheriff_visible) {
            const frame = try self.badge.frame();
            if (frame.parts.len == 0) return error.MissingHudFramePart;

            const cell = self.badge.costume.?.cells[frame.parts[0].cell];

            try blitMapped(
                pixels,
                640,
                480,
                self.badge.costume.?,
                frame,
                .{
                    .x = 590,
                    .y = 80,
                    .width = @intCast(cell.width),
                    .height = @intCast(cell.height),
                },
                .{ .width = 640, .height = 480 },
                self.color_map,
                null,
            );
        }
    }

    fn optionalResource(self: *Hud, name: []const u8) !?*const nwx.Costume {
        if (name.len == 0) return error.MissingHudCostume;

        for (self.resources.items) |value| if (std.ascii.eqlIgnoreCase(
            value.name,
            name,
        )) return &value.costume;

        var bytes: ?[]const u8 = null;

        for (self.archives) |archive| {
            bytes = archive.find(name, 0x57415846) catch |err| switch (err) {
                error.ResourceNotFound => continue,
                else => return err,
            };

            break;
        }

        const found = bytes orelse return null;
        const value = try self.allocator.create(Resource);
        errdefer self.allocator.destroy(value);

        value.name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(value.name);
        value.costume = try nwx.Costume.parse(self.allocator, found);
        errdefer value.costume.deinit();

        try self.resources.append(value);

        return &value.costume;
    }

    fn create(
        self: *Hud,
        parent: ?*Node,
        costume: ?*const nwx.Costume,
        sequence: u32,
        clear: bool,
    ) !*Node {
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);

        node.* = .{ .costume = costume, .parent = parent, .last_time = self.now, .clear = clear };

        if (costume) |asset| {
            try node.select(sequence, self.now);

            const frame = try node.frame();
            if (frame.parts.len == 0) return error.MissingHudFramePart;

            const part = frame.parts[0];
            const cell = asset.cells[part.cell];

            node.rect = .{
                .x = part.raw_x,
                .y = part.raw_y,
                .width = @intCast(cell.width),
                .height = @intCast(cell.height),
            };
        }

        if (parent) |owner| {
            var slot = &owner.first_child;
            while (slot.*) |child| slot = &child.next;
            slot.* = node;
        }

        return node;
    }

    fn destroy(self: *Hud, node: *Node) void {
        while (node.first_child) |child| self.destroy(child);

        if (node.parent) |parent| {
            var slot = &parent.first_child;

            while (slot.*) |child| {
                if (child == node) {
                    slot.* = node.next;
                    break;
                }

                slot = &child.next;
            }
        }

        self.allocator.destroy(node);
    }

    fn installWeapon(self: *Hud, slot: usize, owned: ?*const OwnedItem) !void {
        if (self.weapon) |node| self.destroy(node);

        self.weapon = null;

        if (self.loaded_group) |node| self.destroy(node);

        self.loaded_group = null;
        self.cartridges = [_]?*Node{null} ** 12;

        const item = owned orelse return;
        const costume = try self.resource(item.definition.costume);

        self.weapon = try self.create(null, costume, 0, false);
        self.weapon.?.value = @intCast(slot);

        self.weapon.?.hide(0);

        if (!item.definition.infinite) {
            self.loaded_group = try self.create(self.weapon_group, null, 0, true);
            self.loaded_group.?.show(0);
            self.cartridge_unit = if (item.definition.capacity < 13) 1 else 10;

            const count = @divTrunc(item.definition.capacity, self.cartridge_unit);
            if (count < 1 or count > 12) return error.UnsupportedHudWeaponCapacity;

            for (self.cartridges[0..@intCast(count)]) |*node| {
                node.* = try self.create(self.loaded_group, costume, 11, false);
                node.*.?.minimum = 0x8000;
                node.*.?.slide = 0x8000;
            }

            const width = self.cartridges[0].?.rect.width;
            var step: i32 = 0;

            if (count > 1) step = @divTrunc(128 - width, count - 1);

            step = @min(step, (width *% 0xc000) >> 16);
            var x = 74 + @divTrunc(@divTrunc(width, 2) + (count - 1) * step, 2);

            for (self.cartridges[0..@intCast(count)]) |node| {
                node.?.rect.x = x;
                node.?.rect.y = self.hearts[0].rect.y;
                x -= step;
            }

            self.loaded_group.?.rect = .{
                .x = self.cartridges[@intCast(count - 1)].?.rect.x - width,
                .width = self.cartridges[0].?.rect.x - (self.cartridges[
                    @intCast(
                        count - 1,
                    )
                ].?.rect.x - width) + width + 1,
                .height = self.hearts[0].rect.y,
            };
        }
    }

    fn updateWeapon(self: *Hud, inventory: *const Inventory) !void {
        const slot = inventory.selected_weapon;
        if (slot >= inventory.slots.len) return error.InvalidInventorySlot;

        const owned: ?*const OwnedItem = if (inventory.slots[slot]) |*value| value else null;
        var installed = false;
        var moving = false;
        const must_change = if (owned != null)
            (self.weapon == null or self.weapon.?.slide == self.weapon.?.minimum or self.weapon.?.value != slot)
        else
            (self.weapon != null and self.weapon.?.slide == self.weapon.?.maximum);

        if (must_change) {
            if (self.weapon != null and self.weapon.?.slide != self.weapon.?.minimum) {
                if (self.weapon.?.slide == self.weapon.?.maximum) {
                    self.weapon.?.hide(500);
                    self.weapon_group.hide(500);
                }
            } else {
                try self.installWeapon(slot, owned);
                installed = true;

                if (self.weapon) |node| {
                    node.show(500);
                    self.weapon_group.show(500);
                }
            }
        }

        if (self.weapon) |node| moving = !installed and node.velocity != 0;

        const item = owned orelse return;
        if (self.weapon == null) return;

        if (self.loaded_group) |group| {
            const loaded = @divTrunc(
                item.loaded - 1 + self.cartridge_unit,
                self.cartridge_unit,
            ) - 1;

            if (group.value != loaded and !moving) {
                group.value = loaded;

                for (self.cartridges, 0..) |optional, i| if (optional) |node| {
                    const index: i32 = @intCast(i);
                    try node.select(if (index < loaded) 12 else 11, self.now);

                    if (index <= loaded) node.show(
                        if (installed) 0 else 150,
                    ) else node.hide(if (installed) 0 else 150);
                };
            }
        }

        const ammo_slot = inventory.find(item.definition.ammo);
        const reserve = if (ammo_slot != 0) inventory.slots[ammo_slot].?.count else 0;
        if (self.digits_group.value == reserve or moving) return;
        if (self.digits_group.slide != self.digits_group.minimum and !installed) {
            if (self.digits_group.slide == self.digits_group.maximum) self.digits_group.hide(150);
            return;
        }

        self.digits_group.value = reserve;

        for (self.digits) |node| node.hide(0);

        if (reserve > 0 and reserve < 10) {
            try self.digits[0].select(@intCast(reserve), self.now);
            self.digits[0].show(0);
        } else if (reserve >= 10 and reserve < 100) {
            try self.digits[0].select(@intCast(@rem(reserve, 10) + 10), self.now);
            try self.digits[1].select(@intCast(@divTrunc(reserve, 10)), self.now);
            self.digits[0].show(0);
            self.digits[1].show(0);
        } else if (reserve >= 100 and reserve < 1000) {
            try self.digits[0].select(@intCast(@rem(reserve, 10) + 10), self.now);
            try self.digits[1].select(@intCast(@rem(@divTrunc(reserve, 10), 10) + 10), self.now);
            try self.digits[2].select(@intCast(@divTrunc(reserve, 100)), self.now);
            for (self.digits) |node| node.show(0);
        }

        self.digits_group.show(if (installed) 0 else 150);
    }

    fn installIcon(
        self: *Hud,
        group: *?*Node,
        icon: *?*Node,
        item: *const OwnedItem,
        x: i32,
    ) !void {
        if (group.*) |old| self.destroy(old);

        group.* = null;
        icon.* = null;

        const costume = try self.resource(item.definition.costume);

        group.* = try self.create(self.status, null, 0, true);
        icon.* = try self.create(group.*, costume, 1, false);

        icon.*.?.show(0);
        const original_x = icon.*.?.rect.x;

        icon.*.?.rect.x = x;
        icon.*.?.rect.y = self.hearts[0].rect.y;
        group.*.?.rect = .{
            .x = x + original_x,
            .width = icon.*.?.rect.width + 1,
            .height = self.hearts[0].rect.y,
        };

        group.*.?.show(500);
    }

    fn updateItems(self: *Hud, inventory: *const Inventory) !void {
        if (inventory.selected >= inventory.slots.len) return error.InvalidInventorySlot;

        const selected: ?*const OwnedItem = if (inventory.slots[inventory.selected]) |*value| (if (value.definition.no_show) null else value) else null;
        const next_costume = if (selected) |item| try self.resource(
            item.definition.costume,
        ) else null;

        const previous_costume = if (self.selected_icon) |node| node.costume else null;
        const change = if (selected != null)
            (self.selected_group == null or self.selected_group.?.slide == self.selected_group.?.minimum or previous_costume != next_costume)
        else
            (self.selected_group != null and self.selected_group.?.slide == self.selected_group.?.maximum);

        if (change) {
            if (self.selected_group != null and self.selected_group.?.slide != self.selected_group.?.minimum) {
                if (self.selected_group.?.slide == self.selected_group.?.maximum) self.selected_group.?.hide(500);
            } else if (selected) |item| {
                try self.installIcon(&self.selected_group, &self.selected_icon, item, 435);
            } else {
                if (self.selected_group) |node| self.destroy(node);
                self.selected_group = null;
                self.selected_icon = null;
            }
        }

        const fuel = if (inventory.player_flags.lamp_on) classItem(
            inventory,
            0x4655454c,
        ) else null;

        try self.updateMeter(&self.fuel_group, &self.fuel_icon, fuel, 400);
        try self.updateMeter(
            &self.armor_group,
            &self.armor_icon,
            classItem(inventory, 0x41524d52),
            470,
        );
    }

    fn updateMeter(
        self: *Hud,
        group: *?*Node,
        icon: *?*Node,
        owned: ?*const OwnedItem,
        x: i32,
    ) !void {
        const amount = if (owned) |item| item.count else 0;

        if (group.* == null) {
            if (amount != 0) try self.installIcon(group, icon, owned.?, x);
        } else if (amount == 0) {
            group.*.?.hide(500);

            if (group.*.?.slide == group.*.?.minimum) {
                self.destroy(group.*.?);
                group.* = null;
                icon.* = null;
            }
        }

        if (group.*) |node| if (node.value != amount) {
            if (owned) |item| {
                if (item.definition.max_count == 0) return error.InvalidHudMaximumCount;
                node.maximum = @divTrunc(amount *% 0x8000, item.definition.max_count) +% 0x8000;
                node.slide = @min(node.slide, node.maximum);
            }

            node.show(150);
            node.value = amount;
        };
    }
};

pub fn blit(
    pixels: []u8,
    width: i32,
    height: i32,
    costume: *const nwx.Costume,
    frame: *const nwx.Frame,
    destination: Rect,
    clip: Rect,
) !void {
    return blitMapped(pixels, width, height, costume, frame, destination, clip, null, null);
}

pub fn blitMapped(
    pixels: []u8,
    width: i32,
    height: i32,
    costume: *const nwx.Costume,
    frame: *const nwx.Frame,
    destination: Rect,
    clip: Rect,
    translation: ?[]const u8,
    blend: ?[]const u8,
) !void {
    if (width < 1 or height < 1 or @as(
        u64,
        @intCast(width),
    ) * @as(u64, @intCast(height)) != pixels.len) return error.InvalidHudFramebuffer;

    if (frame.parts.len == 0) return error.MissingHudFramePart;

    const part = frame.parts[0];
    if (part.cell >= costume.cells.len) return error.InvalidNwxCellIndex;

    const cell = costume.cells[part.cell];

    if (translation) |table| if (table.len < 256) return error.ColorMapBounds;

    if (blend) |table| if (table.len < 4096) return error.ColorMapBounds;

    if (cell.width == 0 or cell.height == 0) return;

    if (cell.flags.columns) return error.UnsupportedHudColumnCell;

    const source_width: i32 = @intCast(cell.width);
    const source_height: i32 = @intCast(cell.height);
    var rect = destination;

    if (rect.width == 0) rect.width = source_width;

    if (rect.height == 0) rect.height = source_height;

    if (rect.width < 0 or rect.height < 0) return error.InvalidHudDimensions;

    const mirror = part.flags.mirrored;

    rect.x +%= @divTrunc(
        (if (mirror) 1 -% part.raw_x -% source_width else part.raw_x) *% rect.width,
        source_width,
    );

    rect.y +%= @divTrunc(part.raw_y *% rect.height, source_height);

    const left = @max(0, @max(rect.x, clip.x));
    const top = @max(0, @max(rect.y, clip.y));
    const right = @min(width, @min(rect.x +% rect.width, clip.x +% clip.width));
    const bottom = @min(height, @min(rect.y +% rect.height, clip.y +% clip.height));
    if (right <= left or bottom <= top) return;

    var du = nearest(
        (@as(f64, @floatFromInt(source_width)) / @as(f64, @floatFromInt(rect.width))) * 65536.0,
    );

    const dv = nearest(
        (@as(f64, @floatFromInt(source_height)) / @as(f64, @floatFromInt(rect.height))) * 65536.0,
    );

    if (mirror) du = -%du;

    var initial_u = fixedMultiply((left -% rect.x) *% 0x10000 +% 0x8000, du);

    if (mirror) initial_u +%= source_width *% 0x10000 -% 1;

    var v = fixedMultiply((top -% rect.y) *% 0x10000, dv);
    var y = top;

    while (y < bottom) : (y += 1) {
        const sy = v >> 16;
        if (sy < 0 or sy >= source_height) return error.HudSourceBounds;

        var u = initial_u;
        var x = left;

        while (x < right) : (x += 1) {
            const sx = u >> 16;
            if (sx < 0 or sx >= source_width) return error.HudSourceBounds;

            const color = cell.pixels[@intCast(sx * source_height + source_height - 1 - sy)];
            const target = &pixels[@intCast(y * width + x)];

            if (blend != null and cell.flags.translucent) {
                if (color != 0) {
                    if (color < 16) target.* = blend.?[
                        @as(
                            usize,
                            color,
                        ) * 256 + target.*
                    ] else target.* = if (translation) |table| table[color] else color;
                }
            } else if (!cell.flags.transparent) {
                target.* = color;
            } else if (color != 0) target.* = if (translation) |table| table[color] else color;

            u +%= du;
        }

        v +%= dv;
    }
}

pub fn fixedMultiply(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * @as(i64, b)) >> 16);
}

pub fn nearest(value: f64) i32 {
    if (!std.math.isFinite(
        value,
    ) or value < -2147483648 or value >= 2147483648) return std.math.minInt(i32);

    const floor = @floor(value);
    const fraction = value - floor;
    var result: i32 = @intFromFloat(floor);

    if (fraction > 0.5 or (fraction == 0.5 and result & 1 != 0)) result += 1;

    return result;
}

fn setGauge(gauge: *Node, width: i32, percent: f32) void {
    const amount = @divTrunc(
        width *% 15,
        100,
    ) +% @divTrunc(@divTrunc(width *% 85, 100) *% nearest(percent), 100);

    if (gauge.clip.width != amount) gauge.clip.width = @max(1, amount);
}

fn classItem(inventory: *const Inventory, class: u32) ?*const OwnedItem {
    for (inventory.slots[1..]) |*slot| if (slot.*) |*owned| if (owned.definition.item_class == class) return owned;

    return null;
}

fn drawNode(
    pixels: []u8,
    width: i32,
    height: i32,
    node: *const Node,
    blend: ?[]const u8,
) anyerror!void {
    const clip: Rect = .{ .width = width, .height = height };

    if (node.clear) {
        const left = @max(0, node.rect.x);
        const top = @max(0, node.rect.y);
        const right = @min(width, node.rect.x +% node.rect.width);
        const bottom = @min(height, node.rect.y +% node.rect.height);

        if (right > left and bottom > top) {
            var y = top;

            while (y < bottom) : (y += 1) @memset(
                pixels[@intCast(y * width + left)..@intCast(y * width + right)],
                0,
            );
        }
    }

    if (node.costume) |costume| {
        var rect = node.rect;
        rect.y +%= ((0x10000 -% node.combined) *% rect.height) >> 16;
        try blitMapped(
            pixels,
            width,
            height,
            costume,
            try node.frame(),
            rect,
            if (node.clip.width == 0 or node.clip.height == 0) clip else node.clip,
            null,
            blend,
        );
    }

    var child = node.first_child;

    while (child) |value| : (child = value.next) try drawNode(pixels, width, height, value, blend);
}
