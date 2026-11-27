//! A loaded level in play: the archives, the geometry, the actors, the
//! scripts, the player, the HUD and the per-frame work that advances them.
//!
//! This is the engine's central object and it owns memory only - the window,
//! the events and presentation stay in src/platform. A frame advances the
//! scripts and actors first and renders afterwards, so anything the scripts
//! changed is visible in the same frame.

const std = @import("std");
const title = @import("../game/title.zig");
const lab = @import("../assets/lab.zig");
const level_module = @import("../assets/level.zig");
const texture = @import("../assets/texture.zig");
const texture_animation = @import("texture_animation.zig");
const item = @import("../assets/item.zig");
const campaign = @import("../campaign.zig");
const scene_module = @import("scene.zig");
const inf_module = @import("../script/inf.zig");
const network_router = @import("../network/router.zig");
const network_server = @import("../network/server.zig");
const network_database = @import("../network/database.zig");
const object_numbers = @import("object_numbers.zig");
const network_level = @import("network_level.zig");
const network_actors = @import("network_actors.zig");
const network_combat = @import("network_combat.zig");
const network_message = @import("../network/message.zig");
const network_dead_reckoning = @import("../network/dead_reckoning.zig");
const interaction = @import("../script/interaction.zig");
const inf_geometry = @import("../script/inf_geometry.zig");
const camera = @import("backends/software/camera.zig");
const world = @import("backends/software/world.zig");
const walls = @import("backends/software/walls.zig");
const shades = @import("backends/software/shades.zig");
const nwx = @import("../assets/nwx.zig");
const model_asset = @import("../assets/model.zig");
const model_state = @import("model_state.zig");
const object_state = @import("object_state.zig");
const object_logic = @import("../script/object.zig");
const object_render = @import("objects.zig");
const player_input = @import("../player/input.zig");
const movement = @import("../player/movement.zig");
const player_choreography = @import("../player/choreography.zig");
const secrets_module = @import("../player/secrets.zig");
const inventory_module = @import("../player/inventory.zig");
const script_runtime = @import("../script/runtime.zig");
const cmm = @import("../script/cmm.zig");
const hud_module = @import("hud.zig");
const hud_messages = @import("hud_messages.zig");
const automap_module = @import("automap.zig");
const audio_runtime = @import("../audio/runtime.zig");
const sound_registration = @import("../audio/registration.zig");
const level_sound_ownership = @import("../audio/level_ownership.zig");
const audio_engine = @import("../audio/engine.zig");
const player_audio = @import("../audio/player.zig");
const player_damage = @import("../player/damage.zig");
const player_lamp = @import("../player/lamp.zig");
const damage_flash = @import("damage_flash.zig");
const weapon_module = @import("../player/weapon.zig");
const weapon_render = @import("weapon.zig");
const weapon_pose = @import("weapon_pose.zig");
const shooting = @import("../player/shooting.zig");
const target_module = @import("../player/target.zig");
const enemy = @import("../enemy/controller.zig");
const sanchez = @import("../enemy/sanchez.zig");
const enemy_lifecycle = @import("../enemy/lifecycle.zig");
const occlusion = @import("../audio/occlusion.zig");
const enemy_session = @import("../enemy/session.zig");
const shot_damage = @import("../player/shot_damage.zig");
const blood = @import("../enemy/blood.zig");
const shot_impact = @import("../enemy/impact.zig");
const bubble = @import("../enemy/bubble.zig");
const rail_audio = @import("../audio/rail.zig");
const enemy_dynamic = @import("../enemy/dynamic.zig");
const actor_links = @import("actor_links.zig");
const collision = @import("../player/collision.zig");
const projectile = @import("../projectile/runtime.zig");
const projectile_session = @import("../projectile/session.zig");
const generator = @import("../enemy/generator.zig");
const initial = @import("initial_state.zig");

const session_queues = @import("session_queues.zig");

comptime {
    // Each user message becomes one effect of the frame.
    std.debug.assert(network_server.max_user_messages == inventory_module.max_effects);
}

pub const Session = struct {
    active_audio: ?*audio_runtime.Runtime = null,
    map_covers: bool = false,
    frames_since_load: u32 = 0,
    v111_program: bool = false,
    movie_host: ?inf_module.MovieHost = null,
    sound_ledger: sound_registration.Ledger = .{},
    inherited_sound_ledgers: []sound_registration.Ledger = &.{},
    level_sound_ownership: level_sound_ownership.Ownership = .{},
    player_sound_names: [22]?[]const u8 = @splat(null),
    sounds_closed: bool = false,
    active_effects: ?*inventory_module.Effects = null,
    enemy_native_effects: inventory_module.Effects = .init(&.{}),
    rail_audio_state: rail_audio.State = .{},
    impact_state: shot_impact.State = .{},
    arena: std.heap.ArenaAllocator,
    level: level_module.Level,
    objects: level_module.Objects,
    inf: inf_module.Runtime,
    scene: scene_module.Scene,
    textures: []texture.Texture,
    texture_animations: texture_animation.Runtime,
    angles: camera.Angles,
    view: camera.View,
    spawn: level_module.Spawn,
    player: movement.Player,
    secrets: secrets_module.State,
    player_audio_config: player_audio.Config,
    player_audio_state: player_audio.State,
    player_damage_config: player_damage.Config,
    lamp_config: player_lamp.Config,
    lamp_state: player_lamp.State,
    shot_damage_config: shot_damage.Config,
    damage_flash: damage_flash.State,
    pending_player_death: ?i32,
    campaign_completion_requested: bool = false,
    player_bind_flags: u32 = 0,
    death_restart_requested: bool = false,
    death_restart: campaign.DeathRestart = .{},
    inventory: inventory_module.Inventory,
    weapon_state: weapon_module.State,
    aim_candidates: [512]weapon_module.AutoAimCandidate,
    aim_count: usize,
    targets: []?target_module.Target,
    enemy_visibility: occlusion.Cache,
    enemy_shared: enemy.Shared,
    enemy_nodes: []enemy.Node,
    sanchez_sites: ?[]sanchez.Site,
    enemy_effects: enemy.Effects,
    enemies_loaded: bool,
    corpse_pool: enemy_lifecycle.CorpsePool,
    corpse_sources: [30]?usize,
    enemy_selection_serial: u64,
    object_logic: object_logic.Runtime,
    blood_slots: []?blood.State,
    general_slots: []?blood.State,
    splash_slots: []?enemy_dynamic.SplashState,
    actor_link_serial: u64,
    player_link_order: u64,
    pending_hits: session_queues.PendingHits,
    queued_hits: session_queues.PendingHits,
    actor_messages: session_queues.ActorMessages,
    projectile_slots: []?projectile.State,
    projectile_configs: std.StringHashMap(*const projectile.Config),
    projectile_blast_sender: ?usize,
    explosion_flash: i32 = 0,
    scope_explosion_flash: i32 = 0,
    generators: generator.State,
    scope_view: camera.View,
    /// Borrowed from whoever opened the session; it outlives the session.
    /// The main and scope views share it, drawn one after the other.
    render_workspace: *world.Workspace,
    scope_pixels: []u8,
    frame_seconds: f32,
    actor_time: u32,
    frame_aim_weight: i32,
    main_presented: ?Presentation,
    scope_presented: ?Presentation,
    lamp_presented: [2]?LampPresentation,
    hud: hud_module.Hud,
    messages: hud_messages.HudMessages,
    automap: automap_module.State,
    automap_input: automap_module.Input,
    automap_background: ?texture.Texture,
    automap_was_separate: bool,
    framebuffer_initialized: bool,
    pickup_slots: []?inventory_module.Pickup,
    removed_actors: []bool,
    actor_numbers: []u32 = &.{},
    contact_state: cmm.ContactState,
    collision_diameter: f32 = 0,
    actor_next_update: []i32,
    pickup_effects: inventory_module.Effects,
    /// Backs the hit, actor message and effect lists above; never moves.
    queue_storage: session_queues.Storage,
    look: player_input.LookState,
    palette: [256]u32,
    palette_index: u8 = 0,
    saved_music: ?@import("../save/level.zig").Music = null,
    next_actor_id: u32 = 0,
    next_actor_order: u64 = 0,
    next_object_id: u32 = 0x87654321,
    server_enabled: bool = true,
    startup: *campaign.Startup,
    player_dead_reckoning: ?network_dead_reckoning.Record = null,
    network_player_bound: bool = false,
    stand_in: bool = false,
    joined_text_pending: bool = true,
    player_wax: []const u8 = "",
    player_choreographies: player_choreography.Table = .{},
    player_animation: u32 = 0,
    lobby: ?*@import("../ui/dialog.zig").Dialog = null,
    remote_players: session_queues.RemotePlayers,
    start_keys_cleared: bool = false,
    router: *network_router.Router,
    server: *network_server.Server,
    database: *network_database.Database,
    game_type: u32,
    mode: u32,
    map_actor_ids: []u32,
    player_actor: object_render.Actor,
    player_number: u32 = 0,
    color_map: []u8,
    depth_map: [128]u8,
    blend_table: [4096]u8,
    actors: []object_render.Actor,
    actor_capacity: usize,
    actor_storage: []object_render.Actor,
    /// The object pass's view-space position of each live actor, kept with
    /// the actor arrays so drawing a frame allocates nothing.
    actor_transformed: []level_module.Vec3,
    actor_slots: []?object_render.Actor,
    source_to_entry: []?usize,
    actor_links: actor_links.Links,
    allocator: std.mem.Allocator,
    loaded_actor_sectors: []bool,
    costumes: std.StringHashMap(*nwx.Costume),
    models: std.StringHashMap(*model_asset.Model),
    difficulty_mask: u32,
    object_mode_mask: u32,
    object_option0: bool,
    level_name: []const u8,
    system_archive: lab.Archive,
    geometry_archive: lab.Archive,
    object_archive: lab.Archive,
    texture_archive: lab.Archive,
    weapon_archive: lab.Archive,
    rendered_sector_visits: usize = 0,
    started_at: u32,
    animation_time: u32,
    /// Simulation updates since the level opened, saturating.
    animation_tick_count: u32,

    const Presentation = struct { time: u32, kick: f32, flash: i32, explosion_flash: i32 };

    const LampPresentation = struct { time: u32, force_depth: bool, depth_bias: i32 };

    pub const PersistentState = struct {
        base_palette: [256]u32 = @splat(0),
        native: cmm.ContactState = .{},
        next_object_id: u32 = 0x87654321,
        default_pickup: [128]u8 = @splat(0),
        default_pickup_length: u8 = 0,
        crt_random: u32 = 1,
        actor_time: u32 = 0,
        frame_seconds: f32 = 0,
        enemy_next_shot: u32 = 0,
        enemy_next_taunt: u32 = 0,
        enemy_now: u32 = 0,
        enemy_entry_random: u32 = 0,
        enemy_next_tick: u32 = 0,
        enemy_animation_message: u32 = 0,
        weapon_held: [4]bool = @splat(false),
        fire_noise_due: u32 = 0,
        weapon_player_choreography: i32 = 0,
        flash: i32 = 0,
        kick: f32 = 0,
        scope_flash: i32 = 0,
        scope_kick: f32 = 0,
        impact_count: u32 = 0,
        impact_noise_due: u32 = 0,
        damage_last_ms: u32 = 0,
        lamp_fuel_elapsed: f32 = 0,
        lamp_flicker_time: u32 = 0,
        player_audio: player_audio.State = .{},
        look: player_input.LookState = .{},
        auto_pitch: bool = true,
        stride_side: bool = false,
        automap: automap_module.State = .{},
        map_covers: bool = false,
        messages: [10]hud_messages.Entry = @splat(.{}),
        message_parameter: i32 = 0,
        message_restore_frames: u32 = 2,
        v111_program: bool = false,
    };

    pub const CampaignState = struct {
        arena: std.heap.ArenaAllocator,
        inventory: inventory_module.Inventory,
        pending_sound_ledgers: []sound_registration.Ledger = &.{},
        retained_audio: ?*audio_runtime.Runtime = null,

        pub fn deinit(self: *CampaignState) void {
            self.arena.deinit();
        }
    };

    const ViewPass = struct {
        scope: bool,
        previous: ?Presentation,
        presented: Presentation,
        sector: usize,
        lighting: walls.Lighting,
    };

    const PendingAudio = struct {
        session: *Session,
        effects: *inventory_module.Effects,

        fn drain(raw: *anyopaque) anyerror!void {
            const self: *PendingAudio = @ptrCast(@alignCast(raw));
            try self.session.drainSounds(self.effects);
        }
    };

    pub const Drop = struct {
        report: bool = false,
        offset: i32 = 0,
        held_back: bool = false,
    };

    pub fn persistentState(self: *const Session) PersistentState {
        var default_pickup: [128]u8 = @splat(0);
        const pickup_name = self.inventory.default_sound orelse "";
        std.debug.assert(pickup_name.len < default_pickup.len);
        @memcpy(default_pickup[0..pickup_name.len], pickup_name);
        return .{
            .base_palette = self.palette,
            .default_pickup = default_pickup,
            .default_pickup_length = @intCast(pickup_name.len),
            .native = self.contact_state,
            .next_object_id = self.next_object_id,
            .crt_random = self.enemy_shared.crt_random,
            .actor_time = self.actor_time,
            .frame_seconds = self.frame_seconds,
            .enemy_next_shot = self.enemy_shared.next_shot,
            .enemy_next_taunt = self.enemy_shared.next_taunt,
            .enemy_now = self.enemy_shared.now,
            .enemy_entry_random = self.enemy_shared.entry_random,
            .enemy_next_tick = self.enemy_shared.next_tick,
            .enemy_animation_message = self.enemy_shared.animation_message,
            .weapon_held = self.weapon_state.held,
            .fire_noise_due = self.weapon_state.fire_noise_due,
            .weapon_player_choreography = self.weapon_state.player_choreography,
            .flash = self.weapon_state.flash,
            .kick = self.weapon_state.kick,
            .scope_flash = self.weapon_state.scope_flash,
            .scope_kick = self.weapon_state.scope_kick,
            .impact_count = self.impact_state.count,
            .impact_noise_due = self.impact_state.noise_due,
            .damage_last_ms = self.damage_flash.last_ms,
            .lamp_fuel_elapsed = self.lamp_state.fuel_elapsed,
            .lamp_flicker_time = self.lamp_state.flicker_time,
            .player_audio = self.player_audio_state,
            .look = self.look,
            .auto_pitch = self.player.auto_pitch,
            .stride_side = self.player.stride_side,
            .automap = self.automap,
            .map_covers = self.map_covers,
            .messages = self.messages.entries,
            .message_parameter = self.messages.first_parameter,
            .message_restore_frames = self.messages.restore_frames,
            .v111_program = self.v111_program,
        };
    }

    pub fn open(allocator: std.mem.Allocator, render_workspace: *world.Workspace, io: std.Io, data_path: []const u8, system: lab.Archive, startup: *campaign.Startup) !*Session {
        return openWithState(allocator, render_workspace, io, data_path, system, startup, 0, .{});
    }

    pub fn campaignState(self: *Session, allocator: std.mem.Allocator) !CampaignState {
        var result = CampaignState{ .arena = std.heap.ArenaAllocator.init(allocator), .inventory = undefined };
        errdefer result.arena.deinit();
        try self.closeSounds();
        result.inventory = try self.inventory.clone(result.arena.allocator());
        result.retained_audio = self.sound_ledger.audio;
        if (self.sound_ledger.audio == null) {
            const a = result.arena.allocator();
            result.pending_sound_ledgers = try a.alloc(sound_registration.Ledger, self.inherited_sound_ledgers.len + 1);
            for (self.inherited_sound_ledgers, result.pending_sound_ledgers[0..self.inherited_sound_ledgers.len]) |*inherited, *pending| pending.* = try inherited.clone(a);
            result.pending_sound_ledgers[self.inherited_sound_ledgers.len] = try self.sound_ledger.clone(a);
        }
        result.inventory.player_flags &= ~@as(u32, 0x20000000);
        result.inventory.sheriff_active = false;
        result.inventory.sheriff_visible = false;
        result.inventory.sheriff_due = null;
        result.inventory.sheriff_task_linked = false;
        result.inventory.cloak_active = false;
        result.inventory.cloak_visible = false;
        result.inventory.cloak_due = null;
        result.inventory.cloak_task_linked = false;
        return result;
    }

    pub fn openWithCampaignState(allocator: std.mem.Allocator, render_workspace: *world.Workspace, io: std.Io, data_path: []const u8, system: lab.Archive, startup: *campaign.Startup, now: u32, persistent: PersistentState, carry: *const CampaignState) !*Session {
        return openImpl(allocator, render_workspace, io, data_path, system, startup, now, persistent, true, carry, false);
    }

    pub fn restart(self: *Session, allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, system: lab.Archive, startup: *campaign.Startup, now: u32) !*Session {
        if (self.game_type == 4 or self.game_type == 5) return error.NetworkRespawnNotPorted;
        const request = startup.selected_level orelse return error.MissingRestartLevel;
        if (!std.ascii.eqlIgnoreCase(request.name, self.level_name)) return error.RestartLevelMismatch;
        const persistent = self.persistentState();
        if (self.sound_ledger.audio) |audio| audio.stopAll();
        self.inventory.clock = now;
        try self.inventory.releaseAllSounds();
        const cid_bytes = for ([_]lab.Archive{ self.object_archive, self.weapon_archive, self.geometry_archive, self.system_archive }) |archive| {
            break archive.find(self.inventory.player_definition, 0) catch |err| switch (err) {
                error.ResourceNotFound => continue,
                else => return err,
            };
        } else return error.MissingInventoryConfiguration;
        var cid = try item.Item.parse(self.arena.allocator(), cid_bytes);
        defer cid.deinit();
        try self.inventory.startItems(self.arena.allocator(), &.{ self.object_archive, self.weapon_archive, self.geometry_archive, self.system_archive }, &cid);
        var carry = try self.campaignState(allocator);
        defer carry.deinit();
        return openImpl(allocator, self.render_workspace, io, data_path, system, startup, now, persistent, true, &carry, false);
    }

    pub fn openWithState(allocator: std.mem.Allocator, render_workspace: *world.Workspace, io: std.Io, data_path: []const u8, system: lab.Archive, startup: *campaign.Startup, now: u32, persistent: PersistentState) !*Session {
        return openImpl(allocator, render_workspace, io, data_path, system, startup, now, persistent, false, null, false);
    }

    pub fn openForRestore(allocator: std.mem.Allocator, render_workspace: *world.Workspace, io: std.Io, data_path: []const u8, system: lab.Archive, startup: *campaign.Startup, now: u32, persistent: PersistentState) !*Session {
        return openImpl(allocator, render_workspace, io, data_path, system, startup, now, persistent, false, null, true);
    }

    pub fn closeSounds(self: *Session) !void {
        if (self.sounds_closed) return;
        try self.unbindForLevelClose();
        if (self.sound_ledger.audio) |audio| audio.endLevel();
        self.level_sound_ownership.release(self);
        sound_registration.closeHud(self);
        sound_registration.closeProjectiles(self);
        generator.releaseSounds(self);
        sound_registration.closeFx(self);
        self.sounds_closed = true;
    }

    pub fn closeSectorSoundOwners(self: *Session, sector: usize) void {
        generator.removeSector(self, sector);
        enemy_session.releaseSectorPickupSounds(self, sector);
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        object_numbers.close(self, self.animation_time);
        self.database.stopLinks();
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn render(self: *Session, pixels: []u8, ticks: u32) ![256]u32 {
        if (pixels.len != 640 * 480) return error.InvalidFramebuffer;
        if (!self.framebuffer_initialized) @memset(pixels, 0);
        try self.hud.update(&self.inventory, self.player.energy, self.player.underwater_elapsed, self.animation_time);
        const palette = try self.renderWorld(pixels, ticks);
        self.hud.blend_table = self.blend();
        self.hud.color_map = self.color_map;
        var weapon_options: weapon_render.Options = .{
            .sector_light = self.level.sectors[self.player.sector].ambient,
            .lighting = self.lighting(),
            .movement_offset = self.player.weapon_offset,
            .aim_offset = .{ self.weapon_state.aim_x, self.weapon_state.aim_y },
            .aim_weight = self.frame_aim_weight,
            .scope = self.weapon_state.scope,
            .reloading = self.weapon_state.action == 3,
        };
        self.player.scope_active = false;
        if (self.inventory.slots[self.inventory.selected_weapon]) |owned| if (owned.definition.weapon) |config| {
            if (try weapon_render.scopeRect(&self.hud, weapon_options, .{ config.scope_x, config.scope_y })) |rect| {
                self.player.scope_active = true;
                self.weapon_state.aim_x = 0;
                self.weapon_state.aim_y = 0;
                _ = try self.renderView(&self.scope_view, self.scope_pixels, ticks);
                try weapon_render.composeScope(pixels, self.scope_pixels, rect);
            }
        };
        weapon_options.lighting.force_depth = @intFromBool(self.lamp_state.force_depth);
        weapon_options.lighting.depth_bias = self.lamp_state.depth_bias;
        if (self.automap_was_separate) {
            if (self.automap_background == null) self.automap_background = try texture.loadInitial(self.arena.allocator(), self.texture_archive, "MAPBACK.PCX");
            automap_module.background(pixels, 640, 480, self.automap_background.?);
        }
        self.automap_was_separate = self.automap.separate();
        const map_rect: automap_module.Rect = if (self.automap.separate()) .{ .width = 640, .height = 480 } else .{
            .left = self.view.left,
            .top = self.view.top,
            .width = self.view.right - self.view.left + 1,
            .height = self.view.bottom - self.view.top + 1,
        };
        try self.automap.draw(&self.level, &self.scene, &self.angles, .{
            .position = .{ .x = self.player.position.x, .z = self.player.position.z },
            .layer = self.level.sectors[self.player.sector].layer,
            .yaw = self.player.yaw,
            .head_yaw = self.player.head_yaw,
        }, &self.automap_input, self.frame_seconds, .{ .pixels = pixels, .stride = 640 }, 640, 480, map_rect, &self.messages, self.animation_time, .{ .found = self.secrets.found, .total = self.secrets.total });
        if (!self.automap.separate()) {
            try weapon_render.draw(pixels, &self.hud, weapon_options);
            try self.hud.draw(pixels);
        }
        try self.hud.browser.draw(&self.hud, &self.inventory, pixels);
        try self.messages.render(pixels, 640, 480, self.animation_time);
        self.framebuffer_initialized = true;
        return self.damage_flash.palette(palette);
    }

    /// Drawing the world allocates nothing.
    pub fn renderWorld(self: *Session, pixels: []u8, ticks: u32) ![256]u32 {
        return self.renderView(&self.view, pixels, ticks);
    }

    pub fn advance(self: *Session, allocator: std.mem.Allocator, packet: *const player_input.Packet, elapsed_ms: u32) !void {
        return self.advanceWithAudio(allocator, packet, elapsed_ms, null);
    }

    pub fn registerSound(self: *Session, name: []const u8, priority: u8, now: u32) !void {
        try self.sound_ledger.append(self.arena.allocator(), name, priority, now, 0);
    }

    pub fn releaseSound(self: *Session, name: []const u8) void {
        if (self.sound_ledger.releaseIfOwned(name)) return;
        var index = self.inherited_sound_ledgers.len;
        while (index != 0) {
            index -= 1;
            if (self.inherited_sound_ledgers[index].releaseIfOwned(name)) return;
        }
        self.sound_ledger.release(name);
    }

    pub fn releasePickupSound(self: *Session, source: usize) void {
        const pickup = if (self.pickup_slots[source]) |*value| value else return;
        const name = pickup.sound orelse return;
        var buffer: [256]u8 = undefined;
        const full = if (pickup.sound_names_resolved) name else std.fmt.bufPrint(&buffer, "{s}.wav", .{name}) catch @panic("invalid native pickup sound name");
        self.releaseSound(full);
        pickup.sound = null;
    }

    pub fn releaseTouchedPickup(host: *anyopaque, source: usize) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(host));
        if (self.active_effects) |effects| try self.drainSounds(effects);
        self.releasePickupSound(source);
        try object_numbers.freeActor(self, source);
    }

    pub fn registerInventorySound(self: *Session, definition: inventory_module.Definition, now: u32) !void {
        try sound_registration.ownedItem(&self.sound_ledger, self.arena.allocator(), definition, now);
    }

    pub fn bindInventorySounds(self: *Session) void {
        self.inventory.sound_host = .{ .context = self, .acquire = acquireInventorySounds, .release = releaseInventorySounds, .resolve = resolveInventoryItem };
    }

    pub fn applyPlayerBindFlags(self: *Session, cid: *const item.Item) !void {
        try self.inventory.applyLevelFlags(self.arena.allocator(), &.{ self.object_archive, self.weapon_archive, self.geometry_archive, self.system_archive }, cid, self.player_bind_flags);
    }

    pub fn unbindPlayerSounds(self: *Session) void {
        for (&self.player_sound_names) |*entry| if (entry.*) |name| {
            self.releaseSound(name);
            entry.* = null;
        };
    }

    pub fn bindAudio(self: *Session, audio: *audio_runtime.Runtime) !void {
        for (self.inherited_sound_ledgers) |*inherited| try inherited.bind(audio);
        try self.sound_ledger.bind(audio);
    }

    pub fn prepareMenu(self: *Session, allocator: std.mem.Allocator, audio: ?*audio_runtime.Runtime) !void {
        if (audio) |value| try self.bindAudio(value);
        const previous_audio = self.active_audio;
        self.active_audio = audio;
        defer self.active_audio = previous_audio;
        const previous_effects = self.active_effects;
        defer self.active_effects = previous_effects;
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        self.active_effects = &effects;
        var shots_buffer: weapon_module.ShotBuffer = undefined;
        var shots = weapon_module.Shots.init(&shots_buffer);
        if (self.hud.weaponAnimation()) |animation| {
            var context = self.weaponContext(&effects, &shots, animation.ready);
            context.animation_slot = animation.slot;
            try context.reset(animation.playback, animation.costume);
        } else self.weapon_state.reset();
        try self.castShots(allocator, shots.items, &effects);
        try self.drainSounds(&effects);
    }

    pub fn networkPass(self: *Session, allocator: std.mem.Allocator, elapsed_ms: u32, audio: ?*audio_runtime.Runtime) !void {
        if (audio) |value| try self.bindAudio(value);
        const previous_audio = self.active_audio;
        self.active_audio = audio;
        defer self.active_audio = previous_audio;
        self.animation_time +%= elapsed_ms;
        var user_messages_buffer: network_server.UserMessageBuffer = undefined;
        var user_messages = network_server.UserMessages.init(&user_messages_buffer);
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        const previous_effects = self.active_effects;
        self.active_effects = &effects;
        defer self.active_effects = previous_effects;
        try self.startup.networkStepWith(allocator, self.animation_time, network_level.level(self), self.server_enabled, &user_messages);
        if (user_messages.items.len != 0) return error.UserMessageOutsideLevelFrame;
        try self.drainDatabase(&effects);
        self.pickup_effects.clearRetainingCapacity();
        try self.pickup_effects.appendSlice(effects.items);
    }

    pub fn advanceWithAudio(self: *Session, allocator: std.mem.Allocator, packet: *const player_input.Packet, elapsed_ms: u32, audio: ?*audio_runtime.Runtime) !void {
        if (audio) |value| try self.bindAudio(value);
        if (elapsed_ms == 0) return;
        const previous_audio = self.active_audio;
        self.active_audio = audio;
        defer self.active_audio = previous_audio;
        const previous_effects = self.active_effects;
        defer self.active_effects = previous_effects;
        try self.loadEnemies(allocator);
        self.inf.effects.clearRetainingCapacity();
        var animation_effects_buffer: inventory_module.EffectBuffer = undefined;
        var animation_effects = inventory_module.Effects.init(&animation_effects_buffer);
        self.active_effects = &animation_effects;
        var shots_buffer: weapon_module.ShotBuffer = undefined;
        var shots = weapon_module.Shots.init(&shots_buffer);
        try self.deliverHits(allocator, audio, &animation_effects);
        try enemy_session.deliverSelections(self, allocator, audio);
        self.animation_time +%= elapsed_ms;
        self.inf.audio = try self.infAudioContext(audio);
        defer self.inf.audio = null;
        self.inf.inventory = &self.inventory;
        defer self.inf.inventory = null;
        self.inf.object_host = .{ .context = self, .send = dispatchInfObject };
        defer self.inf.object_host = null;
        self.inf.unlink_host = .{ .context = self, .unlinked = infUnlinked };
        defer self.inf.unlink_host = null;
        self.inf.movie_host = if (self.movie_host != null) .{ .context = self, .play = playInfMovie } else null;
        defer self.inf.movie_host = null;
        var incoming_ids: [26]u32 = undefined;
        var incoming_count: usize = 0;
        for (self.inventory.slots[1..]) |slot| if (slot) |owned| {
            incoming_ids[incoming_count] = @bitCast(owned.definition.use_id);
            incoming_count += 1;
        };
        var user_messages_buffer: network_server.UserMessageBuffer = undefined;
        var user_messages = network_server.UserMessages.init(&user_messages_buffer);
        try self.startup.networkStepWith(allocator, self.animation_time, network_level.level(self), self.server_enabled, &user_messages);
        try self.inf.flushQueued(&self.level, &self.scene, self.animation_time, incoming_ids[0..incoming_count], self.difficulty_mask >> 8);
        try self.drainDatabase(&animation_effects);
        for (self.inf.effects.items) |effect| switch (effect) {
            .actor_impulse => |impulse| {
                if (impulse.contact.actor != null) {
                    const source = impulse.contact.source_index orelse return error.MissingInfActorIdentity;
                    if (source >= self.actor_slots.len or self.removed_actors[source]) continue;
                    if (self.targets[source]) |*target| {
                        var context = enemy_session.context(self, allocator, audio, null);
                        enemy.impulseMessage(target, impulse.velocity, &context);
                        enemy_session.syncSchedule(self);
                    } else if (self.actor_slots[source]) |actor| {
                        if (actor.logic_name.len != 0) switch (try cmm.resolve(actor.logic_name)) {
                            .object, .ground_object, .instant_ground_object, .ground_sheriff_star, .ground_vanishing_cream, .projectile_dispatch, .explosive_projectile_dispatch => {},
                            else => return error.UnsupportedInfNativeImpulse,
                        };
                    }
                    continue;
                }
                self.player.velocity.x += impulse.velocity.x;
                self.player.velocity.y += impulse.velocity.y;
                self.player.velocity.z += impulse.velocity.z;
            },
            .wall_frame => |request| {
                if (request.instance) |index|
                    try self.texture_animations.messageInstance(&self.level, &self.scene, index, request.code, request.arg1, self.animation_time, &animation_effects)
                else
                    try self.texture_animations.message(&self.level, &self.scene, .{ .sector = request.sector, .wall = request.wall }, request.code, request.arg1, self.animation_time, &animation_effects);
            },
            .inventory_use => {},
            .sound => |sound| if (!sound.delivered) {
                try animation_effects.append(.{ .sound = soundRequest(sound) });
            },
        };
        try self.texture_animations.tick(&self.level, &self.scene, self.animation_time, &animation_effects);
        if (self.inf.audio) |context| for (animation_effects.items) |*effect| if (effect.* == .sound) {
            const request = &effect.sound;
            if (request.occlusion_applied or request.sector == null or request.position == null) continue;
            request.volume = try context.cache.volume(&self.level, &self.scene, &self.angles, request.sector.?, context.listener_sector, request.position.?, context.listener_eye, request.volume.?, request.flags.?, self.animation_time);
            request.occlusion_applied = true;
            request.listener = context.listener;
        };
        try enemy_dynamic.animations(self);
        if (self.hud.weaponAnimation()) |animation| {
            if (self.inventory.slots[animation.slot] != null) {
                var context = self.weaponContext(&animation_effects, &shots, animation.ready and animation.slot == self.inventory.selected_weapon);
                context.animation_slot = animation.slot;
                try animation.playback.advanceWithContext(animation.costume, 0, self.animation_time, &context);
            }
        }
        try @import("../player/inventory_wax.zig").advance(self, self.animation_time);
        try self.castShots(allocator, shots.items, &animation_effects);
        shots.clearRetainingCapacity();
        self.animation_tick_count +|= 1;
        try enemy_session.animations(self, allocator, audio, &animation_effects);
        try self.castEnemyEffects(allocator, &animation_effects);
        const elapsed: f32 = @floatFromInt(self.animation_time -% self.actor_time);
        self.actor_time = self.animation_time;
        const seconds: f32 = @min(@as(f32, @floatCast(@as(f64, elapsed) * @as(f32, 0.001))), 0.25);
        self.frame_seconds = seconds;
        try enemy_session.tick(self, allocator, audio, &animation_effects);
        try self.castEnemyEffects(allocator, &animation_effects);
        try enemy_dynamic.tickBeforePlayer(self, allocator, &animation_effects);
        const dynamic_next = enemy_dynamic.firstAfterPlayer(self);
        var look = self.look;
        const logic = !self.stand_in;
        const alive = logic and @as(i32, @bitCast(self.inventory.health)) > 0;
        if (logic) self.automap.packet(packet);
        if (alive) self.inventory.browseInput(packet.get(.weapon));
        if (alive) {
            var context = self.weaponContext(&animation_effects, &shots, false);
            try context.selectInput(packet.get(.weapon));
        }
        const control = look.controlForLife(packet, alive);
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        enemy_session.syncSchedule(self);
        self.inventory.player_flags = self.player.flags;
        if (logic) self.player.dead = !alive;
        if (logic and !alive and self.player.flags & 4 != 0 and self.player.flags & 0x10000000 == 0) {
            self.lamp_state.hardOff();
            self.player.flags = (self.player.flags | 0x10000000) & ~@as(u32, 0x20000000);
            self.player.head_bob = 0;
            self.inventory.player_flags = self.player.flags;
            self.inventory.selected = 0;
            self.inventory.selected_weapon = 0;
            if (self.game_type == 4 or self.game_type == 5)
                try network_combat.killPlayer(self, self.animation_time, &effects, &shots)
            else
                try self.inventory.releaseAllSounds();
        }
        if (logic and self.death_restart.input(!alive and self.player.flags & 4 != 0, packet.get(.fire).flags & player_input.pressed != 0, self.animation_time)) self.death_restart_requested = true;
        if (logic) self.player.gatling_active = self.inventory.selected_weapon == 9;
        if (self.pending_player_death) |message| {
            try effects.append(.{ .message = .{ .index = message, .routed = true } });
            try effects.append(.{ .sound = .{ .basename = "riflout.wav", .priority = 32, .volume = 50, .flags = 4 } });
        }
        for (user_messages.items) |index| try effects.append(.{ .message = .{ .index = index } });
        for (self.inf.effects.items) |effect| switch (effect) {
            .inventory_use => |request| {
                for (self.inventory.slots[1..]) |slot| if (slot) |owned| {
                    if (@as(u32, @bitCast(owned.definition.use_id)) != request.object_id) continue;
                    const name = if (request.success) owned.definition.use_success_sound else owned.definition.use_failure_sound;
                    if (name) |basename| try effects.append(.{ .sound = .{ .basename = basename, .priority = 0x40, .volume = 0x7f, .flags = 4 } });
                    break;
                };
            },
            .sound => {},
            else => {},
        };
        try effects.appendSlice(animation_effects.items);
        self.active_effects = &effects;
        var runtime = script_runtime.Context{
            .sector_messages = self.router.own_client == 1,
            .inventory = &self.inventory,
            .pickups = self.pickup_slots,
            .removed = self.removed_actors,
            .now_ms = self.animation_time,
            .effects = &effects,
            .contact_state = &self.contact_state,
            .actor_next_update = self.actor_next_update,
            .inf = &self.inf,
            .level = &self.level,
            .collision_diameter = &self.collision_diameter,
            .links = &self.actor_links,
            .linked_actor = actor_links.player_id,
            .link_order = &self.player_link_order,
            .link_serial = &self.actor_link_serial,
        };
        var bodies = self.collisionActors();
        runtime.bubble_host = .{ .context = self, .spawn = spawnBubbles };
        runtime.actor_host = .{ .context = self, .activate = enqueueActorActivation };
        runtime.solid_host = .{ .context = self, .touch = receiveActorContact };
        runtime.pickup_release = .{ .context = self, .emit = releaseTouchedPickup };
        runtime.palette_host = .{ .context = self, .enter = enterPlayerSector };
        bodies.runtime = &runtime;
        bodies.allow_pickups = alive;
        if (alive and packet.get(.drop).flags & player_input.pressed != 0) {
            try self.dropSelected(&effects, &shots);
            runtime.pickups = self.pickup_slots;
            runtime.removed = self.removed_actors;
            runtime.actor_next_update = self.actor_next_update;
            bodies = self.collisionActors();
            bodies.runtime = &runtime;
            bodies.allow_pickups = true;
        }
        if (alive) try self.activatePlayer(packet, bodies, &runtime);
        if (alive and seconds != 0 and packet.get(.lamp).flags & player_input.pressed != 0)
            try self.lamp_state.toggle(&self.inventory, &self.lamp_config, &effects);
        if (alive) {
            if (self.hud.weaponAnimation()) |animation| {
                var context = self.weaponContext(&effects, &shots, animation.ready and animation.slot == self.inventory.selected_weapon);
                context.animation_slot = animation.slot;
                try context.fireInput(animation.playback, animation.costume, packet);
            } else try self.weapon_state.fireInput(&self.inventory, packet, self.animation_time);
            // Throwing adds an actor and can move the actor tables; re-read them before moving.
            runtime.pickups = self.pickup_slots;
            runtime.removed = self.removed_actors;
            runtime.actor_next_update = self.actor_next_update;
            bodies = self.collisionActors();
            bodies.runtime = &runtime;
            bodies.allow_pickups = alive;
        }
        var rail_pending = PendingAudio{ .session = self, .effects = &effects };
        var rail_context: ?rail_audio.Context = if (audio) |sound| .{ .state = &self.rail_audio_state, .runtime = sound, .now = self.animation_time, .before = .{ .context = &rail_pending, .drain = PendingAudio.drain } } else null;
        var player_audio_context = player_audio.Context{
            .config = &self.player_audio_config,
            .state = &self.player_audio_state,
            .effects = &effects,
            .rail = if (rail_context) |*context| context else null,
        };
        if (logic) {
            if (self.secrets.discover(&self.scene, self.player.sector))
                try self.messages.post(0x13, null, self.animation_time);
            if (seconds != 0) try self.lamp_state.consume(&self.inventory, seconds);
            self.player.flags = self.inventory.player_flags;
            try self.player.tickWithAudio(&self.level, &self.scene, bodies, &self.angles, control, &look, seconds, &player_audio_context);
            if (self.player.flags & 0x8000 != 0) self.lamp_state.hardOff();
            self.inventory.player_flags = self.player.flags;
            self.pending_player_death = try player_damage.applyMovementWithEnvironment(self.player_damage_config, &self.inventory, self.player.impact, self.player.sector_damage, seconds, &self.damage_flash, &player_audio_context, self.animation_time, .{ .elapsed = self.player.drowning, .crush_required = self.player.crush_required, .crush_body = self.player.crush_body, .runtime = &runtime, .player = &self.player, .angles = &self.angles });
            if (self.game_type == 4 or self.game_type == 5) if (self.pending_player_death) |text| {
                self.pending_player_death = null;
                try network_combat.deathTexts(self, @intCast(text - 1), @truncate(self.router.own_client));
            };
            if (self.player.rail_step) |step| {
                const context = player_audio_context.rail orelse return error.MissingRailAudio;
                try context.update(step.distance, step.speed, self.player.position);
            }
            try self.choosePlayerChoreography();
            try network_level.sendChangedPlayer(self, self.animation_time);
        }
        for (self.targets, self.actor_next_update) |*target, next| {
            if (target.*) |*value| value.next_tick = @bitCast(next);
        }
        if (logic) self.actor_links.move(actor_links.player_id, self.player.sector);
        self.compactRemovedActors();
        self.look = look;
        try enemy_dynamic.tick(self, allocator, &effects, dynamic_next);
        try projectile_session.flushExplosions(self, allocator, &effects);
        try projectile_session.flushContacts(self, &effects);
        std.mem.swap(session_queues.PendingHits, &self.pending_hits, &self.queued_hits);
        self.weapon_state.reconcileSelection(&self.inventory);
        if (self.hud.weaponAnimation()) |animation| {
            if (self.inventory.slots[self.inventory.selected_weapon] != null) {
                var context = self.weaponContext(&effects, &shots, animation.ready and animation.slot == self.inventory.selected_weapon);
                try context.tick(animation.playback, animation.costume);
            }
        }
        try self.castShots(allocator, shots.items, &effects);
        self.inf.audio = try self.infAudioContext(audio);
        var ids: [26]u32 = undefined;
        var id_count: usize = 0;
        for (self.inventory.slots[1..]) |slot| if (slot) |owned| {
            ids[id_count] = @bitCast(owned.definition.use_id);
            id_count += 1;
        };
        const before_tasks = self.inf.effects.items.len;
        var geometry = inf_geometry.World{
            .level = &self.level,
            .scene = &self.scene,
            .angles = &self.angles,
            .actors = self.actors,
            .links = &self.actor_links,
            .source_to_entry = self.source_to_entry,
            .live_entries = &self.actors,
            .live_slots = &self.actor_slots,
            .loader = .{ .context = self, .load = loadActorSector },
            .player = &self.player,
            .loaded_sectors = self.loaded_actor_sectors,
            .collision_diameter = self.collision_diameter,
            .marks = self.networkMarks(),
            .actor_messages = .{ .context = self, .send = enqueueNativeActorMessage },
            .reshaped = null,
        };
        try self.inf.advance(&self.level, self.animation_time, seconds, .{ .random = &self.contact_state.random, .textures = self.textures, .world = &geometry, .inventory_ids = ids[0..id_count], .game_mode_mask = self.difficulty_mask >> 8 });
        for (self.inf.effects.items[before_tasks..]) |effect| switch (effect) {
            .sound => |sound| try effects.append(.{ .sound = soundRequest(sound) }),
            else => {},
        };
        try generator.tick(self, allocator, &effects);
        try self.inventory.advance(self.animation_time, &effects);
        try self.damage_flash.advance(self.inventory.health == 0, self.animation_time);
        self.frame_aim_weight = self.weapon_state.aim_weight;
        self.weapon_state.advanceAim(self.animation_time);
        self.pickup_effects.clearRetainingCapacity();
        try self.pickup_effects.appendSlice(effects.items);
        var messages = self.messages;
        for (effects.items) |effect| switch (effect) {
            .message => |message| if (message.routed)
                try messages.postRouted(message.index, self.animation_time)
            else
                try messages.post(message.index, message.parameter, self.animation_time),
            .sound => {},
        };
        self.messages = messages;
        self.inf.geometry_dirty = false;
        const eye = self.player.eyePosition();
        self.view.setPose(&self.angles, eye.x, eye.y, eye.z, self.player.viewYaw(), self.player.pitch);
    }

    pub fn drainSounds(self: *Session, effects: *inventory_module.Effects) !void {
        const sound = self.active_audio orelse return;
        try self.bindAudio(sound);
        for (effects.items) |*effect| if (effect.* == .sound and !effect.sound.delivered) {
            _ = try sound.play(effect.sound, self.audioWorld(), self.animation_time);
            effect.sound.delivered = true;
        };
    }

    pub fn drainActiveSounds(context: *anyopaque) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        if (self.active_effects) |effects| {
            try self.drainSounds(effects);
            for (self.inf.effects.items) |*effect| if (effect.* == .sound and !effect.sound.delivered) {
                try effects.append(.{ .sound = soundRequest(effect.sound) });
                effect.sound.delivered = true;
            };
            try self.drainSounds(effects);
        }
    }

    pub fn weaponContext(self: *Session, effects: *inventory_module.Effects, shots: *weapon_module.Shots, ready: bool) weapon_module.Context {
        var runtime = enemy_session.scriptContext(self, effects, 0x10);
        runtime.bubble_host = .{ .context = self, .spawn = spawnBubbles };
        return .{
            .aim_horizontal = self.inventory.aim_angles[0],
            .aim_vertical = self.inventory.aim_angles[1],
            .state = &self.weapon_state,
            .inventory = &self.inventory,
            .player = &self.player,
            .random = &self.contact_state.random,
            .crt_random = &self.enemy_shared.crt_random,
            .effects = effects,
            .shots = shots,
            .shot_sink = .{ .context = self, .emit = emitPlayerShot },
            .noise_sink = .{ .context = self, .emit = emitWeaponNoise },
            .projectile_sink = .{ .context = self, .create = createProjectile, .launch = launchProjectile },
            .now = self.animation_time,
            .ready = ready,
            .angles = &self.angles,
            .underwater = self.scene.sectors[self.player.sector].flags & 0x80 != 0,
            .bubble_context = runtime,
            .candidates = self.aim_candidates[0..self.aim_count],
            .player_choreography = .{ .context = self, .table = self.player_choreographies, .animation = &self.player_animation, .has_actor = (self.game_type != 4 and self.game_type != 5) or self.network_player_bound, .set = setWeaponPlayerChoreography },
        };
    }

    pub fn castShots(self: *Session, a: std.mem.Allocator, shots: []const weapon_module.Shot, effects: *inventory_module.Effects) !void {
        return self.castShotsFrom(a, shots, effects, null);
    }

    pub fn emitEnemyShot(context: *anyopaque, target: *target_module.Target, actor: *object_render.Actor, ctx: *enemy.Context, shot: weapon_module.Shot) !void {
        const self: *Session = @ptrCast(@alignCast(context));
        const source = actor.source_index orelse return error.MissingEnemyActorId;
        self.actor_slots[source] = actor.*;
        self.targets[source] = target.*;
        self.syncActor(source);
        var local_buffer: inventory_module.EffectBuffer = undefined;
        var local = inventory_module.Effects.init(&local_buffer);
        const effects = self.active_effects orelse &local;
        if (ctx.actors.runtime) |runtime| if (runtime.effects != effects) {
            try effects.appendSlice(runtime.effects.items);
            runtime.effects.clearRetainingCapacity();
        };
        try self.castShotsFrom(self.allocator, &.{shot}, effects, source);
        try self.drainSounds(effects);
        if (self.active_effects == null) try self.enemy_native_effects.appendSlice(local.items);
        actor.* = self.actor_slots[source].?;
        target.* = self.targets[source].?;
        const runtime = ctx.actors.runtime;
        const required = ctx.actors.required_sectors;
        ctx.* = enemy_session.context(self, ctx.allocator, ctx.audio, required);
        if (runtime) |native| {
            const script_effects = native.effects;
            const entity_mask = native.entity_mask;
            native.* = enemy_session.scriptContext(self, script_effects, entity_mask);
            native.linked_actor = source;
            native.link_order = &actor.sector_link_order;
            ctx.actors.runtime = native;
        }
    }

    pub fn castEnemyEffects(self: *Session, a: std.mem.Allocator, effects: *inventory_module.Effects) !void {
        try effects.appendSlice(self.enemy_native_effects.items);
        self.enemy_native_effects.clearRetainingCapacity();
        for (self.enemy_effects.items) |effect| switch (effect) {
            .fire => |fire| try self.castShotsFrom(a, &.{fire.shot}, effects, fire.source),
        };
        self.enemy_effects.clearRetainingCapacity();
    }

    pub fn deliverHits(self: *Session, allocator: std.mem.Allocator, audio: ?*audio_runtime.Runtime, effects: *inventory_module.Effects) !void {
        for (self.queued_hits.items) |*hit| if (hit.queue_serial == null) {
            hit.queue_serial = self.enemy_selection_serial;
            self.enemy_selection_serial += 1;
        };
        var hit_index: usize = 0;
        var actor_index: usize = 0;
        while (hit_index < self.queued_hits.items.len or actor_index < self.actor_messages.items.len) {
            if (actor_index < self.actor_messages.items.len and (hit_index == self.queued_hits.items.len or self.actor_messages.items[actor_index].serial < self.queued_hits.items[hit_index].queue_serial.?)) {
                const message = self.actor_messages.items[actor_index];
                actor_index += 1;
                try enemy_session.deliverSelectionsBefore(self, allocator, audio, message.serial);
                try self.castEnemyEffects(allocator, effects);
                try self.deliverActorMessage(allocator, audio, message);
                continue;
            }
            const pending = self.queued_hits.items[hit_index];
            hit_index += 1;
            try enemy_session.deliverSelectionsBefore(self, allocator, audio, pending.queue_serial.?);
            try self.castEnemyEffects(allocator, effects);
            if (pending.target == shooting.local_player and (self.game_type == 4 or self.game_type == 5)) {
                try network_combat.localShot(self, pending);
                continue;
            }
            if (pending.target == shooting.local_player) {
                var player_sound = player_audio.Context{ .config = &self.player_audio_config, .state = &self.player_audio_state, .effects = effects };
                self.inventory.player_flags = self.player.flags;
                const was_alive = self.inventory.health > 0;
                if (try shot_damage.apply(&self.shot_damage_config, &self.angles, &self.player, &self.inventory, pending.damageInput(), &self.damage_flash, &player_sound, self.animation_time)) |position| {
                    try self.spawnBlood(position);
                }
                if (was_alive and self.inventory.health == 0) self.pending_player_death = null;
                if (pending.sender) |source| try enqueueNativeActorMessage(self, source, if (self.inventory.health <= 0) 0x7e3 else 0x7e4);
                continue;
            }
            if (pending.target >= self.actor_slots.len or self.removed_actors[pending.target]) continue;
            const actor = if (self.actor_slots[pending.target]) |*value| value else return error.MissingShotActor;
            var damage = pending.damageInput();
            const sender = self.hitSender(pending.sender);
            damage.shooter_position = if (sender) |subject| .{ .x = subject.position.x, .z = subject.position.z } else null;
            if (self.targets[pending.target]) |*target| {
                var context = enemy_session.context(self, allocator, audio, null);
                context.hit_sender = sender;
                context.hit_sender_id = if (sender == null) null else if (pending.sender.? == shooting.local_player) .player else .{ .actor = pending.sender.? };
                try enemy.hitMessage(target, actor, damage, &context);
                self.actor_next_update[pending.target] = 0;
            } else if (actor.logic_name.len != 0) {
                switch (try cmm.resolve(actor.logic_name)) {
                    .ground_object, .instant_ground_object, .ground_sheriff_star, .ground_vanishing_cream => {},
                    .projectile_dispatch, .explosive_projectile_dispatch => {
                        try projectile_session.ignite(self, pending.target, damage.damage, pending.sender);
                    },
                    .object => try object_logic.hit(self, pending.target),
                    else => return error.UnsupportedShotActorNative,
                }
            }
            self.syncActor(pending.target);
        }
        self.queued_hits.clearRetainingCapacity();
        self.actor_messages.clearRetainingCapacity();
        enemy_session.syncSchedule(self);
    }

    pub fn enqueueActorActivation(host: *anyopaque, source: usize) !void {
        return enqueueNativeActorMessage(host, source, 0x7d3);
    }

    pub fn receiveActorContact(host: *anyopaque, source: usize) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(host));
        const actor = if (self.actor_slots[source]) |*value| value else return error.MissingScriptActor;
        if (self.targets[source]) |*target| {
            const common = !target.sanchez or self.enemy_shared.sanchez_enabled;
            var context = enemy_session.context(self, self.allocator, self.active_audio, null);
            try enemy.message(target, actor, 0x74, &.{}, &context);
            if (common) self.contact_state.last_enemy_random = self.enemy_shared.entry_random;
            self.actor_next_update[source] = @bitCast(target.next_tick);
        } else {
            const result = try cmm.touchSolid(try cmm.resolve(actor.logic_name), &self.contact_state, self.enemy_shared.sanchez_enabled);
            if (result.next_tick) |tick| self.actor_next_update[source] = @bitCast(tick);
        }
        self.syncActor(source);
    }

    pub fn enqueueHitResult(host: *anyopaque, receiver: ?enemy.TargetId, code: u32) !void {
        const target = receiver orelse return;
        return enqueueNativeActorMessage(host, switch (target) {
            .player => shooting.local_player,
            .actor => |source| source,
        }, code);
    }

    pub fn enqueueNativeActorMessage(host: *anyopaque, source: usize, code: u32) !void {
        const self: *Session = @ptrCast(@alignCast(host));
        try self.actor_messages.append(.{ .target = source, .code = code, .serial = self.enemy_selection_serial });
        self.enemy_selection_serial += 1;
    }

    pub fn emitEnemyProjectile(host: *anyopaque, target: *target_module.Target, actor: *object_render.Actor, context: *enemy.Context) !void {
        const self: *Session = @ptrCast(@alignCast(host));
        try projectile_session.emitEnemyProjectile(self, target, actor, context);
    }

    pub fn enqueueReflectedHit(host: *anyopaque, source: ?usize, damage: shooting.DamageInput) !void {
        const self: *Session = @ptrCast(@alignCast(host));
        try self.queued_hits.append(.{ .target = shooting.local_player, .sender = source, .queue_serial = self.enemy_selection_serial, .count = 1, .input = damage });
        self.enemy_selection_serial += 1;
    }

    pub fn removeStandIn(self: *Session, now: u32) !void {
        if (!self.stand_in or !self.network_player_bound) return error.NoStandInPlayer;
        try self.removePlayer(now);
    }

    pub fn revive(self: *Session, now: u32) !void {
        if (self.game_type != 4 and self.game_type != 5) return error.NotANetworkGame;
        if (self.mode == 2) return error.TagPlayerNotPorted;
        if (self.stand_in or !self.network_player_bound) return error.NoNetworkPlayer;
        if (self.player_wax.len >= 0x20) return error.PlayerWaxTooLong;
        if (self.player.sector >= self.level.sectors.len) return error.InvalidPlayerSector;
        try self.damage_flash.clear();
        const router = self.router;
        var buffer: [network_message.corpse_capacity]u8 = undefined;
        const p = self.player.position;
        const bytes = try network_message.corpse(&buffer, 0x3f6, router.own_client, .{
            .choreography = @bitCast(self.player_choreographies.die),
            .sector = @intCast(self.player.sector),
            .position = .{ @bitCast(p.x), @bitCast(p.y), @bitCast(p.z) },
            .costume = self.player_wax,
        });
        network_message.set(bytes, network_message.reply_offset, self.player_number);
        network_message.set(bytes, network_message.sender_offset, network_message.addressWord(network_message.Queue.server, @truncate(router.own_client)));
        _ = try router.post(0x100800, 0x3f6, bytes);
        if (self.sound_ledger.audio) |audio| audio.stopAll();
        self.inventory.clock = now;
        try self.inventory.releaseAllSounds();
        const a = self.arena.allocator();
        const definition = try item.Item.parse(a, try self.object_archive.find(self.startup.player_definition, 0x4954454d));
        try self.inventory.startItems(a, &.{ self.object_archive, self.weapon_archive, self.system_archive }, &definition);
        self.startup.revived();
    }

    pub fn removePlayer(self: *Session, now: u32) !void {
        if (!self.network_player_bound) return error.NoNetworkPlayer;
        const router = self.router;
        if (router.own_client == 0 or router.own_client >= router.clients.len) return error.InvalidNetworkClientNumber;
        router.clients[router.own_client].player = null;
        const number = self.player_number;
        if (number != 0) {
            self.database.free(number, now);
            var bytes = network_message.request(0x3ff, router.own_client);
            network_message.set(&bytes, network_message.sender_offset, (router.own_client & 0xff) << 11);
            network_message.set(&bytes, network_message.reply_offset, number);
            _ = try router.post(0, 0x3ff | 0x80000000, &bytes);
        }
        self.player_number = 0;
        self.player_dead_reckoning = null;
        self.network_player_bound = false;
    }

    pub fn placeAtStart(self: *Session, record: [7]u32, now: u32) !void {
        if (self.network_player_bound) return error.StartHereWhilePlayerBoundNotPorted;
        const a = self.arena.allocator();
        const spawn = try level_module.Spawn.fromStart(&self.level, record);
        const definition = try item.Item.parse(a, try self.object_archive.find(self.startup.player_definition, 0x4954454d));
        const physics = try movement.Physics.parse(try self.system_archive.find("AIR.PHY", 0));
        const previous = self.player;
        self.spawn = spawn;
        self.player = try movement.Player.init(&definition, physics, spawn);
        self.player.stride_side = previous.stride_side;
        self.player.auto_pitch = previous.auto_pitch;
        self.player.water_physics = previous.water_physics;
        const logic_id = self.allocateActorId();
        self.player_actor = .{ .logic_id = logic_id, .sector = self.player.sector, .position = self.player.position, .yaw = self.player.yaw, .pitch = self.player.pitch, .roll = (try initial.PlayerEye.actorAngles(spawn))[2], .flags = 0x8000006f, .secondary_flags = 0x90, .scale_x = 1, .scale_y = 1, .height = self.player.body_height, .eye_height = self.player.eye_height, .collision_radius = self.player.radius, .logic_name = "Player_InputFunc", .choreography = 0, .frame = 0, .angle_offset = 0 };
        self.player_actor.birth_order = logic_id;
        self.next_actor_order = self.next_actor_id + 1;
        self.inventory.health = 10;
        self.inventory.player_flags = 4;
        self.inventory.statistics = .{};
        self.inventory.clock = now;
        try self.inventory.startItems(a, &.{ self.object_archive, self.weapon_archive, self.system_archive }, &definition);
        self.player.flags = self.inventory.player_flags;
        if (self.look.pitch_active) {
            self.look.pitch_accumulator = 0;
            self.player.pitch = 0;
        } else self.player.auto_pitch = true;
        self.actor_links.move(actor_links.player_id, self.player.sector);
        const eye = self.player.eyePosition();
        self.view.setPose(&self.angles, eye.x, eye.y, eye.z, self.player.viewYaw(), self.player.pitch);
        self.scope_view.setPose(&self.angles, eye.x, eye.y, eye.z, self.player.viewYaw(), self.player.pitch);
        self.player_number = try object_numbers.giveActor(self, @import("../player/shooting.zig").local_player);
        self.stand_in = false;
        try network_level.bindPlayer(self, now);
    }

    pub fn bindStandIn(self: *Session, now: u32) !void {
        if (!self.stand_in) return error.NoStandInPlayer;
        try network_level.bindPlayer(self, now);
    }

    pub fn enqueueLevelCompletion(host: *anyopaque) !void {
        const self: *Session = @ptrCast(@alignCast(host));
        try network_server.requestEndLevel(self.router);
    }

    pub fn seedStartRequest(self: *Session, clock: u32) void {
        self.enemy_shared.crt_random = clock;
    }

    pub fn dropSelected(self: *Session, effects: *inventory_module.Effects, shots: *weapon_module.Shots) !void {
        const slot = if (self.inventory.browsing) self.inventory.browse_cursor else self.inventory.selected;
        if (slot >= self.inventory.slots.len) return error.InvalidInventorySlot;
        try self.dropItem(slot, .{ .report = true, .held_back = true }, effects, shots);
    }

    pub fn dropItem(self: *Session, slot: usize, drop: Drop, effects: *inventory_module.Effects, shots: *weapon_module.Shots) !void {
        const owned = self.inventory.slots[slot] orelse return;
        if (owned.definition.no_drop) {
            if (drop.report) try effects.append(.{ .message = .{ .index = 0x44a } });
            return;
        }
        if (owned.definition.ground_item.len == 0) return;
        var position = self.player.position;
        const sector = self.level.sectors[self.player.sector];
        if (position.y < sector.floor.height) position.y = @floatCast(@as(f64, sector.floor.height) + 0.1);
        if (sector.ceiling.height < position.y) position.y = @floatCast(@as(f64, sector.ceiling.height) - 0.1);
        const shifted: f32 = @floatCast(@as(f64, @floatFromInt(drop.offset)) + position.x);
        var destination = self.player.sector;
        if (try weapon_pose.locate(&self.level, &self.scene, self.player.sector, .{ .x = shifted, .y = position.y, .z = position.z })) |found| {
            destination = found;
            position.x = shifted;
        }
        if (try network_actors.createItem(self, owned.definition.ground_item, .{ .position = position, .sector = destination })) |source| {
            if (self.pickup_slots[source]) |*pickup| {
                if (pickup.entries.len == 0) return error.InvalidDroppedPickup;
                const entries = try self.arena.allocator().dupe(inventory_module.Entry, pickup.entries);
                entries[0].count +%= @as(i16, @truncate(owned.count));
                pickup.entries = entries;
                pickup.flags |= 1;
                if (drop.held_back) {
                    pickup.enabled = false;
                    self.actor_slots[source].?.flags |= 0x80000040;
                }
            }
            self.syncActor(source);
        }
        if (self.inventory.selected_weapon == slot) {
            var context = self.weaponContext(effects, shots, false);
            try context.dropHeld();
            self.weapon_state.reset();
        }
        try self.inventory.remove(slot);
    }

    pub fn audioListener(self: *const Session) audio_engine.Listener {
        const p = self.player.position;
        const v = self.player.velocity;
        return audio_engine.gameListener(.{ p.x, p.y, p.z }, .{ v.x, v.y, v.z }, self.player.yaw);
    }

    pub fn changePalette(self: *Session, index: u8) !bool {
        if (self.palette_index == index) return false;
        const palette = try texture.decodePalette(try self.system_archive.find(self.level.palettes[index], 0x50435850));
        self.palette = texture.levelPalette(self.palette, palette);
        self.palette_index = index;
        return true;
    }

    pub fn audioWorld(self: *Session) audio_runtime.World {
        return .{
            .level = &self.level,
            .scene = &self.scene,
            .angles = &self.angles,
            .listener_sector = self.player.sector,
            .listener_eye = .{ .x = self.player.position.x, .y = @floatCast(@as(f64, self.player.position.y) + self.player.eye_height), .z = self.player.position.z },
            .visibility = &self.enemy_visibility,
        };
    }

    pub fn loadActorsInSectors(self: *Session, visited_sectors: []const bool) !bool {
        return self.loadActors(visited_sectors, false);
    }

    pub fn loadActors(self: *Session, visited_sectors: []const bool, all_enemies: bool) !bool {
        if (visited_sectors.len != self.level.sectors.len or visited_sectors.len > world.max_level_sectors) return error.InvalidActorSectorSet;
        const a = self.arena.allocator();
        var visible_storage: [world.max_level_sectors]bool = undefined;
        const visible = visible_storage[0..visited_sectors.len];
        @memcpy(visible, visited_sectors);
        for (visited_sectors, self.level.sectors, self.scene.sectors) |visited, sector, state| {
            if (visited and sector.vadjoin >= 0 and state.flags & 0x80 == 0) visible[@intCast(sector.vadjoin)] = true;
        }
        var any_new = false;
        for (visible, self.loaded_actor_sectors) |shown, loaded| {
            if (shown and !loaded) any_new = true;
        }
        if (!any_new and !all_enemies) return false;
        var added = false;
        for (self.objects.entries, self.actor_slots[0..self.objects.entries.len], 0..) |object, *slot, source_index| {
            if (self.removed_actors[source_index]) continue;
            if (!self.acceptObject(object) or object.flags[0] & 1 != 0 or self.startMarker(object.name)) continue;
            const sector = self.level.sectorIndex(object.sector_id) orelse {
                std.log.warn("object {s} ({x}) has no sector {x}; it is discarded, as the data expects", .{ object.name, object.id, object.sector_id });
                continue;
            };
            if (slot.* != null) continue;
            const sector_requested = visible[sector] and !self.loaded_actor_sectors[sector];
            if (!sector_requested and !all_enemies) continue;
            var name_buffer: lab.NameBuffer = undefined;
            const name = try lab.printName(&name_buffer, "{s}.ITM", .{std.fs.path.stem(object.name)});
            const definition_bytes = try self.objectResource(self.system_archive, name);
            if (!sector_requested and definition_bytes == null) continue;
            const definition = if (definition_bytes) |bytes| item.Item.parse(a, bytes) catch |err| {
                std.log.err("cannot parse object definition {s}: {s}", .{ name, @errorName(err) });
                return err;
            } else null;
            const definition_ptr = if (definition) |*value| value else null;
            if (definition_ptr) |value| if (std.mem.eql(u8, value.function, "Gen_New")) {
                try self.generators.append(a, value, object, sector, self.animation_time, &self.contact_state.random);
                self.removed_actors[source_index] = true;
                continue;
            };
            if (definition_ptr) |value| if (std.mem.eql(u8, value.function, "Sanchez_New") or std.mem.eql(u8, value.function, "TwoFeathers_New")) {
                if (self.sanchez_sites == null) self.sanchez_sites = try sanchez.placements(a, &self.level, &self.objects, &.{ self.object_archive, self.system_archive }, self.difficulty_mask);
                const sites = self.sanchez_sites.?;
                if (sites.len == 0) return error.MissingSanchezPlacement;
                if (source_index != sites[0].source) {
                    self.removed_actors[source_index] = true;
                    continue;
                }
            };
            if (!sector_requested) {
                const value = definition_ptr orelse continue;
                if (value.function.len == 0) continue;
                const native = cmm.resolve(value.function) catch |err| switch (err) {
                    error.CmmFunctionNotFound => continue,
                    else => return err,
                };
                switch (native) {
                    .enemy,
                    .chicken,
                    .slim,
                    .sanchez,
                    .farmer,
                    .bob,
                    .dynamite,
                    .marshal,
                    .civilian,
                    .object,
                    => {},
                    else => continue,
                }
            }
            const uses_model = if (definition_ptr) |value|
                value.function.len != 0 and std.ascii.endsWithIgnoreCase(value.animation, ".3DO")
            else
                object.flags[0] & 8 != 0;
            if (uses_model) {
                const animation = if (definition_ptr) |value| value.animation else try std.fmt.allocPrint(a, "{s}.3DO", .{std.fs.path.stem(object.name)});
                const key = try std.ascii.allocUpperString(a, animation);
                const model = self.models.get(key) orelse blk: {
                    const bytes = try self.objectResource(self.system_archive, animation) orelse {
                        if (definition_ptr == null) continue;
                        return error.ResourceNotFound;
                    };
                    const loaded = try a.create(model_asset.Model);
                    loaded.* = try model_asset.Model.parse(a, bytes, &.{ self.object_archive, self.texture_archive, self.system_archive });
                    try self.models.put(key, loaded);
                    break :blk loaded;
                };
                const constructed = try model_state.init(a, &.{ self.object_archive, self.weapon_archive, self.system_archive }, object, sector, definition_ptr, model, self.difficulty_mask >> 8, self.game_type);
                slot.* = constructed.actor;
                slot.*.?.logic_id = self.map_actor_ids[source_index];
                slot.*.?.birth_order = self.map_actor_ids[source_index];
                slot.*.?.object_id = object.id;
                slot.*.?.source_index = source_index;
                slot.*.?.sector_link_order = source_index + 1;
                if (definition_ptr != null and (self.game_type == 4 or self.game_type == 5)) slot.*.?.network_item = object.name;
                self.pickup_slots[source_index] = constructed.pickup;
                if (definition_ptr) |value| if (std.ascii.eqlIgnoreCase(value.function, "shot_ProjectileDispatch")) try projectile_session.initializeMap(self, source_index, value);
                self.syncActor(source_index);
                added = true;
                continue;
            }
            var animation_buffer: [64]u8 = undefined;
            const animation = (object_state.animationName(&animation_buffer, object.name, definition_ptr) catch |err| {
                std.log.err("cannot construct object {s}: {s}", .{ object.name, @errorName(err) });
                return err;
            }) orelse continue;
            var key_buffer: lab.NameBuffer = undefined;
            const key = try lab.upperName(&key_buffer, animation);
            const costume = self.costumes.get(key) orelse blk: {
                const bytes = try self.objectResource(self.system_archive, animation) orelse {
                    if (definition == null) {
                        std.log.warn("object {s} has neither an item definition nor {s}; no actor is created", .{ object.name, animation });
                        continue;
                    }
                    std.log.err("missing object costume {s}", .{animation});
                    return error.ResourceNotFound;
                };
                const loaded = try a.create(nwx.Costume);
                loaded.* = try nwx.Costume.parse(a, bytes);
                try self.costumes.put(try a.dupe(u8, key), loaded);
                break :blk loaded;
            };
            const state = try object_state.State.init(object, sector, definition_ptr, costume);
            slot.* = state.actor(costume);
            slot.*.?.logic_id = self.map_actor_ids[source_index];
            slot.*.?.birth_order = self.map_actor_ids[source_index];
            slot.*.?.object_id = object.id;
            if (slot.*.?.playback) |*playback| playback.last_time = self.started_at;
            slot.*.?.source_index = source_index;
            slot.*.?.sector_link_order = source_index + 1;
            if (definition_ptr != null and (self.game_type == 4 or self.game_type == 5)) slot.*.?.network_item = object.name;
            if (definition_ptr) |value| {
                slot.*.?.logic_name = object_state.nativeName(value.function);
                switch (try object_state.classify(value)) {
                    .ground, .instant => self.pickup_slots[source_index] = try inventory_module.Pickup.parse(a, &.{ self.object_archive, self.weapon_archive, self.system_archive }, value, self.difficulty_mask >> 8, self.game_type),
                    .enemy, .chicken, .civilian, .slim, .sanchez => {
                        self.targets[source_index] = try target_module.Target.load(a, &.{ self.object_archive, self.weapon_archive, self.system_archive }, value, self.difficulty_mask >> 8);
                        if (self.targets[source_index].?.native != .civilian and self.targets[source_index].?.native != .marshal) self.enemy_shared.total_enemies += 1;
                    },
                    else => {},
                }
            }
            if (self.targets[source_index]) |*target| {
                target.playback.last_time = self.started_at;
                target.selection_serial = &self.enemy_selection_serial;
            }
            if (!object_logic.bound(slot.*.?)) {
                // Every decoration is built when the level opens, before the
                // first tick, as in the original, so its animation has run from
                // the start. One built later would have missed updates.
                if (self.animation_tick_count != 0) return error.DecorationBuiltAfterPlayStarted;
            }
            self.syncActor(source_index);
            added = true;
        }
        for (visible, self.loaded_actor_sectors) |shown, *loaded| loaded.* = loaded.* or shown;
        return added;
    }

    pub fn allocateActorId(self: *Session) u32 {
        self.next_actor_id +%= 1;
        return self.next_actor_id;
    }

    pub fn writeSaved(self: *Session, writer: *@import("../save/stream.zig").Writer, audio: *audio_runtime.Runtime) !void {
        return @import("../save/session.zig").write(self, writer, audio);
    }

    pub fn restoreSaved(self: *Session, reader: *@import("../save/stream.zig").Reader, audio: *audio_runtime.Runtime) !void {
        return @import("../save/session.zig").read(self, reader, audio);
    }

    pub fn allocateObjectId(self: *Session) u32 {
        const id = self.next_object_id;
        self.next_object_id +%= 1;
        return id;
    }

    pub fn savedActorId(self: *const Session, source: ?usize) !u32 {
        const index = source orelse return 0xffffffff;
        if (index == shooting.local_player) return self.player_actor.logic_id;
        if (index >= self.actor_slots.len or self.removed_actors[index]) return 0xffffffff;
        return if (self.actor_slots[index]) |actor| actor.logic_id else 0xffffffff;
    }

    pub fn sourceForSavedActorId(self: *const Session, id: u32) !?usize {
        if (id == 0xffffffff) return null;
        var selected: ?usize = if (self.player_actor.logic_id == id) shooting.local_player else null;
        var order: u64 = if (selected != null) self.player_actor.birth_order else std.math.maxInt(u64);
        for (self.actor_slots, self.removed_actors, 0..) |slot, removed, source| {
            if (removed) continue;
            if (slot) |actor| if (actor.logic_id == id and actor.birth_order < order) {
                selected = source;
                order = actor.birth_order;
            };
        }
        return selected;
    }

    pub fn syncActor(self: *Session, source: usize) void {
        if (self.removed_actors[source] or self.actor_slots[source] == null) {
            self.actor_links.remove(source);
            if (self.source_to_entry[source]) |index| {
                const last = self.actors.len - 1;
                if (index != last) {
                    self.actor_storage[index] = self.actor_storage[last];
                    self.source_to_entry[self.actor_storage[index].source_index.?] = index;
                }
                self.actors = self.actor_storage[0..last];
                self.source_to_entry[source] = null;
            }
            return;
        }
        const actor = self.actor_slots[source].?;
        if (self.source_to_entry[source]) |index| {
            self.actor_storage[index] = actor;
            self.actor_links.move(source, actor.sector);
        } else {
            const index = self.actors.len;
            self.actor_storage[index] = actor;
            self.actors = self.actor_storage[0 .. index + 1];
            self.source_to_entry[source] = index;
            var before = self.actor_links.first(actor.sector);
            while (before) |other| {
                const order = if (other == actor_links.player_id) self.player_link_order else self.actor_slots[other].?.sector_link_order;
                if (order <= actor.sector_link_order) break;
                before = self.actor_links.next(other);
            }
            self.actor_links.insertBefore(source, actor.sector, before);
        }
    }

    pub fn collisionActors(self: *Session) collision.Actors {
        return .{
            .entries = self.actors,
            .links = &self.actor_links,
            .source_to_entry = self.source_to_entry,
            .live_source_to_entry = &self.source_to_entry,
            .live_entries = &self.actors,
            .live_slots = &self.actor_slots,
            .loaded_sectors = self.loaded_actor_sectors,
            .loader = .{ .context = self, .load = loadActorSector },
        };
    }

    pub fn spawnBlood(self: *Session, position: level_module.Vec3) !void {
        const costume = try enemy_session.costume(self, "BLOOD.NWX");
        const spawned = try blood.spawn(costume, &self.contact_state.random, self.player.sector, position, self.animation_time);
        const index = try enemy_session.appendActor(self, spawned.actor, null);
        self.blood_slots[index] = spawned.state;
    }

    fn openImpl(allocator: std.mem.Allocator, render_workspace: *world.Workspace, io: std.Io, data_path: []const u8, system: lab.Archive, startup: *campaign.Startup, now: u32, persistent: PersistentState, retain_player: bool, carry: ?*const CampaignState, restoring: bool) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.allocator = allocator;
        self.active_audio = null;
        self.movie_host = null;
        self.sound_ledger = .{};
        self.inherited_sound_ledgers = &.{};
        self.level_sound_ownership = .{};
        self.player_sound_names = @splat(null);
        self.sounds_closed = false;
        self.active_effects = null;
        self.enemy_native_effects = .init(&self.queue_storage.enemy_native_effects);
        self.campaign_completion_requested = false;
        self.player_bind_flags = 0;
        self.death_restart_requested = false;
        self.death_restart = .{};
        self.actor_messages = .init(&self.queue_storage.actor_messages);
        self.projectile_blast_sender = null;
        self.explosion_flash = 0;
        self.scope_explosion_flash = 0;
        self.generators = .{};
        self.palette_index = 0;
        self.saved_music = null;
        self.next_actor_id = 0;
        self.next_actor_order = 0;
        self.next_object_id = persistent.next_object_id;
        self.server_enabled = startup.router.own_client == 1;
        self.startup = startup;
        self.player_dead_reckoning = null;
        self.network_player_bound = false;
        self.stand_in = false;
        self.joined_text_pending = true;
        self.player_wax = "";
        self.player_choreographies = .{};
        self.player_animation = 0;
        self.lobby = null;
        self.remote_players = .init(&self.queue_storage.remote_players);
        self.start_keys_cleared = false;
        self.router = &startup.router;
        self.server = &startup.server;
        self.database = &startup.database;
        self.database.startLinks();
        errdefer self.database.stopLinks();
        self.game_type = startup.engine.game_type;
        self.mode = startup.mode;
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        if (carry) |previous| {
            self.inherited_sound_ledgers = try a.alloc(sound_registration.Ledger, previous.pending_sound_ledgers.len);
            for (previous.pending_sound_ledgers, self.inherited_sound_ledgers) |*pending, *inherited| inherited.* = try pending.clone(a);
        }
        const request = startup.selected_level orelse try startup.selectLevel();
        if (request.disc != 0 and request.disc != 1 and request.disc != 2) return error.UnsupportedLevelDisc;
        self.level_name = try a.dupe(u8, request.name);
        const directory = std.fs.path.dirname(data_path) orelse ".";
        const archives = title.current.level_archives;
        const geometry = try loadArchive(a, io, directory, archives.geometry, system.front);
        self.geometry_archive = geometry;
        self.texture_archive = try loadArchive(a, io, directory, archives.textures, system.front);
        self.object_archive = try loadArchive(a, io, directory, archives.objects, system.front);
        self.weapon_archive = try loadArchive(a, io, directory, archives.weapons, system.front);
        const level_path = try std.fmt.allocPrint(a, "{s}.lvb", .{request.name});
        const object_path = try std.fmt.allocPrint(a, "{s}.obb", .{request.name});
        const inf_path = try std.fmt.allocPrint(a, "{s}.inf", .{request.name});
        self.level = try level_module.Level.parse(a, try preferredGeometryResource(a, geometry, level_path, "lvt"));
        try world.Workspace.checkLevel(&self.level);
        if (self.game_type == 4 or self.game_type == 5) {
            const item_path = try std.fmt.allocPrint(a, "{s}.itm", .{request.name});
            const item_bytes = try geometry.find(item_path, 0x4954454d);
            if (item_bytes.len < 8) return error.TruncatedLevelItem;
            const item_word = std.mem.readInt(u32, item_bytes[4..8], .little);
            const checksum = self.level.token_checksum ^ item_word;
            if (self.game_type == 5) {
                self.server.record.parameter = checksum;
                self.server.record.checksum = checksum;
            } else if (self.database.record.parameter != 0 and checksum != self.database.record.parameter) {
                return error.LevelChecksumMismatchNotPorted;
            }
        }
        const loads_objects = self.game_type != 4;
        self.objects = if (loads_objects)
            try level_module.Objects.parse(a, try preferredGeometryResource(a, geometry, object_path, "obt"))
        else
            .{ .arena = std.heap.ArenaAllocator.init(a), .name = "", .entries = &.{} };
        const network = self.game_type == 4 or self.game_type == 5;
        if (network and loads_objects and !restoring) try self.postStartRecords(a, startup);
        self.stand_in = network and !restoring;
        self.spawn = if (restoring)
            try self.provisionalSpawn(a, startup)
        else if (network)
            standInSpawn()
        else
            try self.requestStart(a, startup, now);
        self.contact_state = persistent.native;
        self.impact_state = .{ .count = persistent.impact_count, .noise_due = persistent.impact_noise_due };
        self.angles = camera.Angles.init();
        self.scene = try scene_module.Scene.init(a, &self.level, &self.angles);
        self.difficulty_mask = @intFromEnum(startup.difficulty) << 8;
        const mode_masks = [_]u32{ 0, 0x800000, 0x1000000, 0x2000000, 0x4000000, 0x8000000, 0x400000 };
        if (self.mode >= mode_masks.len) return error.InvalidMultiplayerMode;
        self.object_mode_mask = self.difficulty_mask | mode_masks[self.mode];
        self.object_option0 = self.server.configuration.options[0];
        self.map_actor_ids = try a.alloc(u32, self.objects.entries.len);
        @memset(self.map_actor_ids, 0);
        const map_kinds = try a.alloc(?object_numbers.Kind, self.objects.entries.len);
        @memset(map_kinds, null);
        if (!restoring) for (self.objects.entries, 0..) |object, source| {
            if (!self.acceptObject(object) or object.flags[0] & 1 != 0 or self.level.sectorIndex(object.sector_id) == null) continue;
            var special = false;
            for ([_][]const u8{ "PLAYER", "STARTPOS", "FLAGSTAR", "DOCSTART", "BALLSTAR" }) |name| if (std.ascii.eqlIgnoreCase(object.name, name)) {
                special = true;
                break;
            };
            if (special) continue;
            const name = try std.fmt.allocPrint(a, "{s}.ITM", .{std.fs.path.stem(object.name)});
            if (try self.objectResource(system, name)) |bytes| {
                var definition = try item.Item.parse(a, bytes);
                defer definition.deinit();
                map_kinds[source] = object_numbers.Kind.of(&definition);
            } else {
                const resource = try std.fmt.allocPrint(a, "{s}.{s}", .{ std.fs.path.stem(object.name), if (object.flags[0] & 8 != 0) @as([]const u8, "3DO") else "NWX" });
                if (try self.objectResource(system, resource) == null) continue;
                _ = self.allocateObjectId();
                map_kinds[source] = .actor;
            }
            self.map_actor_ids[source] = self.allocateActorId();
        };
        const geometry_classes = try inf_module.Runtime.prepareGeometry(a, &self.level, &self.contact_state.random, &self.scene, &self.angles, now);
        const geometry_class_count = geometry_classes.classes.items.len;
        self.removed_actors = try a.alloc(bool, self.objects.entries.len);
        @memset(self.removed_actors, restoring);
        if (!restoring) for (self.objects.entries, 0..) |object, source| {
            if (!self.acceptObject(object) or object.flags[0] & 1 != 0) continue;
            const sector = self.level.sectorIndex(object.sector_id) orelse continue;
            const name = try std.fmt.allocPrint(a, "{s}.ITM", .{std.fs.path.stem(object.name)});
            const bytes = try self.objectResource(system, name) orelse continue;
            var definition = try item.Item.parse(a, bytes);
            defer definition.deinit();
            if (!std.mem.eql(u8, definition.function, "Gen_New")) continue;
            try self.generators.append(a, &definition, object, sector, now, &self.contact_state.random);
            self.removed_actors[source] = true;
        };
        self.secrets = secrets_module.State.init(&self.level);
        self.textures = try a.alloc(texture.Texture, self.level.textures.len);
        for (self.textures, self.level.textures) |*destination, name|
            destination.* = try texture.loadLevelInitial(a, self.texture_archive, name);
        self.texture_animations = try texture_animation.Runtime.init(a, &self.level, &self.textures, self.texture_archive, now);

        const definition = try item.Item.parse(a, try self.object_archive.find(startup.player_definition, 0x4954454d));
        const physics = try movement.Physics.parse(try system.find("AIR.PHY", 0));
        self.player = try movement.Player.init(&definition, physics, self.spawn);
        self.player_choreographies = player_choreography.Table.fromItem(&definition);
        self.player_actor = .{ .logic_id = if (restoring) 0 else self.allocateActorId(), .sector = self.player.sector, .position = self.player.position, .yaw = self.player.yaw, .pitch = self.player.pitch, .roll = (try initial.PlayerEye.actorAngles(self.spawn))[2], .flags = 0x8000006f, .secondary_flags = 0x90, .scale_x = 1, .scale_y = 1, .height = self.player.body_height, .eye_height = self.player.eye_height, .collision_radius = self.player.radius, .logic_name = "Player_InputFunc", .choreography = 0, .frame = 0, .angle_offset = 0 };
        self.player_actor.birth_order = self.player_actor.logic_id;
        self.next_actor_order = self.next_actor_id + 1;
        self.player.stride_side = persistent.stride_side;
        if (retain_player) self.player.auto_pitch = persistent.auto_pitch;
        self.player.water_physics = (try movement.Physics.parse(try system.find("WATER.PHY", 0))).withWaterItem(&definition);
        self.player_audio_config = try player_audio.Config.fromItem(&definition);
        self.player_audio_state = persistent.player_audio;
        self.rail_audio_state = .{};
        self.player_damage_config = try player_damage.Config.fromItem(&definition);
        self.lamp_config = try player_lamp.Config.fromItem(&definition);
        self.lamp_state = .{ .fuel_elapsed = persistent.lamp_fuel_elapsed, .flicker_time = persistent.lamp_flicker_time };
        self.shot_damage_config = try shot_damage.Config.fromItem(&definition);
        self.damage_flash = .{ .last_ms = persistent.damage_last_ms };
        self.pending_player_death = null;
        self.inventory = if (restoring) .{ .clock = now } else if (carry) |previous| try previous.inventory.clone(a) else try inventory_module.Inventory.initAt(a, &.{ self.object_archive, self.weapon_archive, system }, &definition, now);
        if (persistent.default_pickup_length != 0) self.inventory.default_sound = try a.dupe(u8, persistent.default_pickup[0..persistent.default_pickup_length]);
        const level_item_path = try std.fmt.allocPrint(a, "{s}.ITM", .{self.level_name});
        const level_item_bytes: ?[]const u8 = for ([_]lab.Archive{ self.object_archive, self.weapon_archive, self.geometry_archive, system }) |archive| {
            const found = archive.find(level_item_path, 0) catch |err| switch (err) {
                error.ResourceNotFound => continue,
                else => return err,
            };
            break found;
        } else null;
        var level_definition = if (level_item_bytes) |bytes| try item.Item.parse(a, bytes) else null;
        defer if (level_definition) |*value| value.deinit();
        if (level_definition) |*value| self.player_bind_flags = campaign.inventoryLevelFlags(@bitCast(value.intValue("FLAGS") orelse 0));
        try self.inventory.configureDefaultSound(a, &.{ self.object_archive, self.weapon_archive, system }, if (level_definition) |*value| value else null);
        if (self.inventory.default_sound) |name| if (name.len >= 128) return error.InvalidDefaultPickupSound;
        self.inventory.character = startup.character_code;
        self.inventory.player_definition = try a.dupe(u8, startup.player_definition);
        self.inventory.player_flags = self.player.flags;
        if (carry != null) {
            self.inventory.health = 10;
            self.inventory.player_flags = 4;
            self.inventory.statistics = .{};
            self.inventory.clock = now;
            try self.inventory.startItems(a, &.{ self.object_archive, self.weapon_archive, system }, &definition);
        }
        self.weapon_state = .{ .held = persistent.weapon_held, .last_press = now, .fire_noise_due = persistent.fire_noise_due, .player_choreography = persistent.weapon_player_choreography, .crt_random = persistent.crt_random, .flash = persistent.flash, .kick = persistent.kick, .scope_flash = persistent.scope_flash, .scope_kick = persistent.scope_kick };
        self.aim_count = 0;
        self.targets = try a.alloc(?target_module.Target, self.objects.entries.len);
        @memset(self.targets, null);
        self.enemy_visibility = try occlusion.Cache.init(a, &self.level);
        self.enemy_shared = .{ .next_shot = persistent.enemy_next_shot, .next_taunt = persistent.enemy_next_taunt, .crt_random = persistent.crt_random, .now = persistent.enemy_now, .entry_random = persistent.enemy_entry_random, .next_tick = persistent.enemy_next_tick, .animation_message = persistent.enemy_animation_message };
        self.enemy_nodes = &.{};
        self.sanchez_sites = null;
        self.enemy_effects = .init(&self.queue_storage.enemy_effects);
        self.enemies_loaded = false;
        self.corpse_pool = .{};
        self.corpse_sources = @splat(null);
        self.enemy_selection_serial = 0;
        self.blood_slots = try a.alloc(?blood.State, self.objects.entries.len);
        @memset(self.blood_slots, null);
        self.general_slots = try a.alloc(?blood.State, self.objects.entries.len);
        @memset(self.general_slots, null);
        self.splash_slots = try a.alloc(?enemy_dynamic.SplashState, self.objects.entries.len);
        @memset(self.splash_slots, null);
        self.player_link_order = self.objects.entries.len + 1;
        self.actor_link_serial = self.player_link_order + 1;
        self.pending_hits = .init(&self.queue_storage.hits[0]);
        self.queued_hits = .init(&self.queue_storage.hits[1]);
        self.actor_time = persistent.actor_time;
        self.frame_seconds = persistent.frame_seconds;
        self.frame_aim_weight = 0;
        self.main_presented = null;
        self.scope_presented = null;
        self.lamp_presented = @splat(null);
        self.v111_program = persistent.v111_program;
        self.hud = try hud_module.Hud.init(a, &.{ system, self.object_archive, self.weapon_archive }, now, persistent.v111_program);
        self.hud.weapon_animation_external = true;
        self.messages = try hud_messages.HudMessages.init(system, 640);
        self.messages.entries = persistent.messages;
        self.messages.first_parameter = persistent.message_parameter;
        self.messages.restore_frames = persistent.message_restore_frames;
        self.automap = persistent.automap;
        self.map_covers = persistent.map_covers;
        self.frames_since_load = 0;
        self.automap.setMode(0);
        self.automap.reveal = false;
        self.automap_input = .{};
        self.automap_background = null;
        self.automap_was_separate = false;
        self.framebuffer_initialized = false;
        self.collision_diameter = 0;
        self.pickup_effects = .init(&self.queue_storage.pickup_effects);
        self.look = persistent.look;
        if (self.look.pitch_active) {
            self.look.pitch_accumulator = 0;
            self.player.pitch = 0;
        } else self.player.auto_pitch = true;
        const eye = self.player.eyePosition();
        self.view = try camera.View.init(a, &self.angles, 640, 480);
        self.scope_view = try camera.View.initFov(a, &self.angles, weapon_render.scope_size, weapon_render.scope_size, weapon_render.scope_fov);
        self.scope_pixels = try a.alloc(u8, weapon_render.scope_size * weapon_render.scope_size);
        @memset(self.scope_pixels, 0);
        self.render_workspace = render_workspace;
        self.view.bottom = 439;
        self.view.setParallax(self.level.parallax.x, self.level.parallax.z);
        self.scope_view.setParallax(self.level.parallax.x, self.level.parallax.z);
        self.view.setPose(&self.angles, eye.x, eye.y, eye.z, self.player.viewYaw(), self.player.pitch);
        self.scope_view.setPose(&self.angles, eye.x, eye.y, eye.z, self.player.viewYaw(), self.player.pitch);

        if (self.level.cmaps.len == 0) return error.MissingLevelColorMap;
        const system_palette = if (system.find("SYSPAL.PCX", 0x50435850)) |data|
            try texture.decodePalette(data)
        else |err| switch (err) {
            error.ResourceNotFound => persistent.base_palette,
            else => return err,
        };
        const palette = try texture.decodePalette(try system.find(self.level.palettes[0], 0x50435850));
        self.palette = texture.levelPalette(system_palette, palette);
        self.color_map = try texture.decodeColorMap(a, try system.find(self.level.cmaps[0], 0));
        self.depth_map = texture.defaultDepthMap();
        self.blend_table = shades.build(self.palette, self.level.shades);
        self.system_archive = system;
        self.object_logic = try object_logic.Runtime.init(a, system, &self.queue_storage.object_selections);
        self.difficulty_mask = @intFromEnum(startup.difficulty) << 8;
        self.actor_capacity = self.objects.entries.len;
        self.actor_storage = try a.alloc(object_render.Actor, self.actor_capacity);
        self.actor_transformed = try a.alloc(level_module.Vec3, self.actor_capacity);
        self.actors = self.actor_storage[0..0];
        self.actor_slots = try a.alloc(?object_render.Actor, self.objects.entries.len);
        @memset(self.actor_slots, null);
        self.actor_numbers = try a.alloc(u32, self.objects.entries.len);
        @memset(self.actor_numbers, 0);
        self.player_number = 0;
        self.source_to_entry = try a.alloc(?usize, self.objects.entries.len);
        @memset(self.source_to_entry, null);
        self.actor_links = try actor_links.Links.init(a, self.level.sectors.len, self.objects.entries.len);
        self.pickup_slots = try a.alloc(?inventory_module.Pickup, self.objects.entries.len);
        self.projectile_slots = try a.alloc(?projectile.State, self.objects.entries.len);
        @memset(self.projectile_slots, null);
        @memset(self.pickup_slots, null);
        self.actor_next_update = try a.alloc(i32, self.objects.entries.len);
        @memset(self.actor_next_update, 0);
        self.loaded_actor_sectors = try a.alloc(bool, self.level.sectors.len);
        @memset(self.loaded_actor_sectors, false);
        self.costumes = std.StringHashMap(*nwx.Costume).init(a);
        self.models = std.StringHashMap(*model_asset.Model).init(a);
        self.projectile_configs = std.StringHashMap(*const projectile.Config).init(a);
        self.started_at = now;
        self.animation_time = now;
        self.animation_tick_count = 0;
        if (!restoring and !loads_objects) {
            self.inf = try inf_module.Runtime.fromGeometry(now, geometry_classes);
            self.inf.router = self.router;
            self.inf.marks = self.networkMarks();
            try object_numbers.level(self, geometry_class_count, map_kinds, now);
            self.enemies_loaded = true;
            @memset(self.loaded_actor_sectors, true);
            self.actor_links.move(actor_links.player_id, self.player.sector);
            self.player_wax = try a.dupe(u8, (try definition.stringValue("PLAYER_WAX")) orelse "james.nwx");
            try sound_registration.initial(self, &definition, now, if (carry) |previous| previous.retained_audio else null);
        } else if (restoring) {
            self.inf = try inf_module.Runtime.fromGeometry(now, geometry_classes);
            self.inf.router = self.router;
            self.inf.marks = self.networkMarks();
            try object_numbers.geometry(self, geometry_class_count);
            self.enemies_loaded = true;
            @memset(self.loaded_actor_sectors, true);
            try sound_registration.restoreOpen(self, now);
        } else {
            const every_sector = try allocator.alloc(bool, self.level.sectors.len);
            defer allocator.free(every_sector);
            @memset(every_sector, true);
            _ = try self.loadActors(every_sector, true);
            try self.loadEnemies(allocator);
            var startup_world: inf_geometry.World = .{ .level = &self.level, .scene = &self.scene, .angles = &self.angles, .actors = self.actors, .links = &self.actor_links, .source_to_entry = self.source_to_entry, .live_entries = &self.actors, .live_slots = &self.actor_slots, .collision_diameter = 0, .marks = self.networkMarks(), .reshaped = null };
            self.inf = try inf_module.Runtime.loadPreparedWithWorld(a, &self.level, try geometry.find(inf_path, 0x494e4646), &self.scene, &self.angles, now, geometry_classes, .{ .world = &startup_world, .textures = self.textures, .seconds = if (@as(u32, @bitCast(self.frame_seconds)) & 0x7fffffff == 0) 1 else self.frame_seconds });
            self.inf.router = self.router;
            self.inf.marks = self.networkMarks();
            self.actor_links.move(actor_links.player_id, self.player.sector);
            self.generators.start(now);
            try object_numbers.level(self, geometry_class_count, map_kinds, now);
            if (self.game_type == 4 or self.game_type == 5) {
                self.player_wax = try a.dupe(u8, (try definition.stringValue("PLAYER_WAX")) orelse "james.nwx");
            }
            try sound_registration.initial(self, &definition, now, if (carry) |previous| previous.retained_audio else null);
        }
        self.bindInventorySounds();
        try self.level_sound_ownership.init(self, restoring);
        try self.scene.refreshWallHeights(&self.level);
        self.inf.applyScene(&self.level, &self.scene);
        if (@as(u32, @bitCast(self.frame_seconds)) & 0x7fffffff == 0) {
            for (self.inf.elevators) |elevator| if (elevator.stops.items.len != 0) {
                self.frame_seconds = 1;
                break;
            };
        }

        if (self.game_type == 4 and !restoring) try network_level.requestObjects(self.router);
        self.rendered_sector_visits = 0;
        return self;
    }

    fn preferredGeometryResource(a: std.mem.Allocator, archive: lab.Archive, binary: []const u8, text_extension: []const u8) ![]const u8 {
        return archive.find(binary, 0) catch |err| switch (err) {
            error.ResourceNotFound => archive.find(try std.fmt.allocPrint(a, "{s}.{s}", .{ std.fs.path.stem(binary), text_extension }), 0),
            else => err,
        };
    }

    fn unbindForLevelClose(self: *Session) !void {
        if (self.player_bind_flags & 0x80000 != 0) try self.inventory.releaseAllSounds();
        self.unbindPlayerSounds();
        for ([_]u32{ 0x4b455900, 0x50555a5a }) |class| {
            for (self.inventory.slots[1..], 1..) |slot, index| if (slot) |owned| {
                if (owned.definition.item_class == class) try self.inventory.remove(index);
            };
        }
    }

    fn beginView(self: *Session, view: *camera.View) !ViewPass {
        const scope = view == &self.scope_view;
        const lamp_index: usize = @intFromBool(scope);
        if (self.lamp_presented[lamp_index] == null or self.lamp_presented[lamp_index].?.time != self.animation_time) {
            self.lamp_state.advancePresentation(self.frame_seconds, self.animation_time, &self.contact_state.random);
            self.lamp_presented[lamp_index] = .{ .time = self.animation_time, .force_depth = self.lamp_state.force_depth, .depth_bias = self.lamp_state.depth_bias };
        }
        const lamp_presentation = self.lamp_presented[lamp_index].?;
        const previous = if (scope) self.scope_presented else self.main_presented;
        const presented = if (previous != null and previous.?.time == self.animation_time) previous.? else Presentation{
            .time = self.animation_time,
            .kick = if (scope) self.weapon_state.scope_kick else self.weapon_state.kick,
            .flash = if (scope) self.weapon_state.scope_flash else self.weapon_state.flash,
            .explosion_flash = if (scope) self.scope_explosion_flash else self.explosion_flash,
        };
        const pose = try weapon_pose.pose(&self.level, &self.scene, &self.angles, &self.player, presented.kick);
        view.setPose(&self.angles, pose.eye.x, pose.eye.y, pose.eye.z, self.player.viewYaw(), pose.pitch);
        var view_lighting = self.lighting();
        view_lighting.force_depth = @intFromBool(lamp_presentation.force_depth);
        view_lighting.depth_bias = lamp_presentation.depth_bias;
        view_lighting.depth_strength = presented.flash;
        view_lighting.ambient_bias = presented.explosion_flash;
        self.player_actor.position = self.player.position;
        self.player_actor.sector = self.player.sector;
        self.player_actor.flags = enemy_session.playerSubject(self).flags;
        return .{ .scope = scope, .previous = previous, .presented = presented, .sector = pose.sector, .lighting = view_lighting };
    }

    fn endView(self: *Session, pass: ViewPass) void {
        if (pass.scope) {
            if (pass.previous == null or pass.previous.?.time != self.animation_time) self.weapon_state.advanceScopePresentation(self.frame_seconds);
            self.scope_explosion_flash = 0;
            self.scope_presented = pass.presented;
        } else {
            if (pass.previous == null or pass.previous.?.time != self.animation_time) self.weapon_state.advancePresentation(self.frame_seconds);
            self.explosion_flash = 0;
            self.main_presented = pass.presented;
        }
    }

    fn renderView(self: *Session, view: *camera.View, pixels: []u8, ticks: u32) anyerror![256]u32 {
        // Drawing can reveal sectors whose actors are not loaded yet; they are
        // loaded and the whole view is drawn again until nothing new shows.
        // Each pass loads at least one sector, so this ends.
        while (true) {
            const pass = try self.beginView(view);
            var objects = try object_render.Objects.initWith(.{
                .native_slots = self.actor_slots,
                .native_player = &self.player_actor,
                .view = view,
                .level = &self.level,
                .scene = &self.scene,
                .camera_sector = pass.sector,
                .pixels = pixels,
                .lighting = pass.lighting,
                .blend_table = self.blend(),
                .links = &self.actor_links,
                .source_to_entry = self.source_to_entry,
                .angles = &self.angles,
            }, self.actors, self.actor_transformed, &self.render_workspace.object_sectors);
            defer objects.deinit();
            var frame = try world.Frame.init(self.render_workspace, view, &self.angles, &self.level, &self.scene, self.textures, pixels, pass.lighting, .scalar, ticks);
            defer frame.deinit();
            frame.blend_table = self.blend();
            frame.objects = &objects;
            try frame.draw(pass.sector);
            if (try self.loadActorsInSectors(frame.visited)) continue;
            self.aim_count = 0;
            for ([_][]const usize{ objects.aim_static[0..objects.aim_static_count], objects.aim_dynamic[0..objects.aim_dynamic_count] }) |list| {
                for (list) |i| {
                    const point = objects.transformed[i];
                    self.aim_candidates[self.aim_count] = .{ .flags = self.actors[i].secondary_flags, .x = point.x, .y = point.y, .z = point.z, .height = self.actors[i].height };
                    self.aim_count += 1;
                }
            }
            self.rendered_sector_visits = frame.sector_visits;
            self.endView(pass);
            return self.palette;
        }
    }

    fn acquireInventorySounds(context: *anyopaque, definition: inventory_module.Definition, now: u32) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        try self.registerInventorySound(definition, now);
    }

    fn resolveInventoryItem(context: *anyopaque, name: []const u8) anyerror!inventory_module.Definition {
        const self: *Session = @ptrCast(@alignCast(context));
        return inventory_module.Definition.load(self.arena.allocator(), &.{ self.object_archive, self.weapon_archive, self.geometry_archive, self.system_archive }, name);
    }

    fn releaseInventorySounds(context: *anyopaque, definition: inventory_module.Definition, phase: inventory_module.ReleasePhase) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        if (phase == .native) try drainActiveSounds(self);
        inventory_module.releaseSounds(definition, phase, self, releaseInventorySound);
    }

    fn releaseInventorySound(self: *Session, name: []const u8, resolved: bool) void {
        if (resolved) return self.releaseSound(name);
        var buffer: [256]u8 = undefined;
        const filename = std.fmt.bufPrint(&buffer, "{s}.wav", .{name}) catch unreachable;
        self.releaseSound(filename);
    }

    fn choosePlayerChoreography(self: *Session) !void {
        const input = self.player.choreography_input orelse return;
        if (player_choreography.select(&self.player.flags, self.player_choreographies, input)) |value| try self.setPlayerChoreography(value);
        self.inventory.player_flags = self.player.flags;
    }

    fn setPlayerChoreography(self: *Session, value: i16) !void {
        if (network_message.client(self.player_number) != self.router.own_client) return;
        self.player_animation = @bitCast(@as(i32, value));
        var bytes = network_message.choreography(self.router.own_client, self.player_animation);
        network_message.set(&bytes, network_message.reply_offset, self.player_number);
        _ = try self.router.post(self.player_number, 0x403, &bytes);
    }

    fn drainDatabase(self: *Session, effects: *inventory_module.Effects) !void {
        while (try self.database.next(self.router, true, self.animation_time)) |request| switch (request) {
            .end_level => self.campaign_completion_requested = true,
            .game_info => return error.GameInfoDuringLevelNotPorted,
            .start_here => |record| {
                if (self.network_player_bound) return error.StartHereWhilePlayerBoundNotPorted;
                try self.placeAtStart(record, self.animation_time);
                self.database.start_clock = self.animation_time;
                self.startup.startedAtRecord();
                self.start_keys_cleared = true;
            },
            .frag_update => |bytes| try self.database.applyFragUpdate(self.router, bytes, .{ .now = self.animation_time, .game_type = self.game_type, .mode = self.mode, .game_state = self.startup.engine.game_state }),
            .frag_delta => |value| try self.startup.applyFragDelta(value),
            .corpse => |value| try network_actors.createCorpse(self, value),
            .shatter_wall => |value| try network_level.shatterWall(self, value.sector, value.wall),
            .comment => |raw| {
                var text: [network_database.comment_text_limit]u8 = undefined;
                const shown = try network_database.commentText(self.startup.messages, raw, &text);
                try self.messages.postComment(shown, self.animation_time);
                if (self.lobby) |lobby| try @import("../ui/network_lobby.zig").addChat(lobby, shown);
                try effects.append(.{ .sound = .{ .basename = "riflout.wav", .priority = 0x40, .volume = 0x7f, .flags = 4 } });
            },
            .configuration => |bits| self.server.configuration.fromDatabase(bits),
            .critical => if (self.mode >= 1 and self.mode <= 3) return error.ServerCriticalModeNotPorted,
            .object_request => |asked| try network_actors.answerObjectRequest(self, asked.sender),
            .actor_create => |value| try network_actors.receiveActorCreate(self, value),
            .actor => |target| try network_actors.actorMessage(self, target.index, target.bytes),
            .link, .bits, .generator => return error.DatabaseObjectMessageNotPorted,
        };
        try self.database.drained(self.router, .{ .now = self.animation_time, .game_type = self.game_type, .mode = self.mode, .game_state = self.startup.engine.game_state }, self.startup.holder());
    }

    fn playInfMovie(context: *anyopaque, name: []const u8, flags: u32) anyerror!u32 {
        const self: *Session = @ptrCast(@alignCast(context));
        const host = self.movie_host orelse return error.MissingInfMovieHost;
        if (self.active_effects == null) return error.MissingNativeEffects;
        try drainActiveSounds(self);
        const elapsed = try host.play(host.context, name, flags);
        self.animation_time +%= elapsed;
        self.framebuffer_initialized = false;
        return elapsed;
    }

    fn setWeaponPlayerChoreography(context: *anyopaque, value: i16) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        try self.setPlayerChoreography(value);
    }

    fn emitPlayerShot(context: *anyopaque, shot: weapon_module.Shot, effects: *inventory_module.Effects) !void {
        const self: *Session = @ptrCast(@alignCast(context));
        try self.castShots(self.allocator, &.{shot}, effects);
        try self.drainSounds(effects);
    }

    fn emitWeaponNoise(context: *anyopaque, radius: f32, code: u32, effects: *inventory_module.Effects) !void {
        const self: *Session = @ptrCast(@alignCast(context));
        try enemy_session.playerNoise(self, self.arena.allocator(), effects, radius, code);
    }

    fn castShotsFrom(self: *Session, a: std.mem.Allocator, shots: []const weapon_module.Shot, effects: *inventory_module.Effects, source: ?usize) !void {
        if (shots.len == 0) return;
        var inserted_sounds: usize = 0;
        for (shots) |shot| {
            const ray = shooting.Ray{ .sector = shot.sector, .origin = shot.origin, .range = shot.range, .pitch = shot.pitch, .yaw = shot.yaw, .kind = @intFromEnum(shot.kind), .exclude_source = source };
            var actors = self.collisionActors();
            if (source != null) actors.player = enemy_session.playerBody(self);
            var events_buffer: interaction.RayEventBuffer = undefined;
            var events = interaction.RayEvents.init(&events_buffer);
            const result = try shooting.trace(&events, &self.level, &self.scene, &self.angles, actors, self.textures, ray);
            for (result.events) |event| try self.inf.event(&self.level, .{ .sector = event.sector, .wall = event.wall, .mask = event.mask, .object_id = event.object_id, .now_ms = self.animation_time });
            if (result.hit) |hit| {
                switch (hit) {
                    .wall => |wall| try shot_impact.apply(self, a, shot, wall, effects),
                    .actor => |victim| {
                        const source_index = if (victim.index == shooting.local_player) shooting.local_player else self.actors[victim.index].source_index orelse return error.MissingShotActor;
                        const damage = shooting.DamageInput{ .kind = @intFromEnum(shot.kind), .damage = shot.damage, .mass = shot.mass, .speed = shot.rate, .yaw = shot.yaw, .pitch = shot.pitch, .lateral = victim.lateral, .height = victim.height };
                        var found = false;
                        for (self.pending_hits.items) |*pending| if (pending.matchesFrom(source_index, damage.kind, source orelse shooting.local_player)) {
                            pending.add(&self.angles, damage, victim);
                            found = true;
                            break;
                        };
                        if (!found) try self.pending_hits.append(shooting.PendingHit.initFrom(source_index, source orelse shooting.local_player, &self.angles, damage, victim));
                    },
                }
                if (shot.hit_sound) |sound| {
                    try effects.insert(sound.effect_index + inserted_sounds, .{ .sound = sound.request });
                    inserted_sounds += 1;
                    try enemy_session.playerNoise(self, a, effects, 100, 0x82);
                }
            }
        }
    }

    fn deliverActorMessage(self: *Session, allocator: std.mem.Allocator, audio: ?*audio_runtime.Runtime, message: session_queues.ActorMessage) !void {
        if (message.target == shooting.local_player) return;
        if (message.target >= self.actor_slots.len or self.removed_actors[message.target]) return;
        const actor = self.actor_slots[message.target] orelse return error.MissingScriptActor;
        if (message.code == 0x66) {
            if (self.targets[message.target] == null and actor.logic_name.len != 0) switch (try cmm.resolve(actor.logic_name)) {
                .object, .ground_object, .instant_ground_object, .ground_sheriff_star, .ground_vanishing_cream, .projectile_dispatch, .explosive_projectile_dispatch => {},
                else => return error.UnsupportedActorDestructionNative,
            };
            try enemy_session.removeActor(self, message.target);
            return;
        }
        if (self.targets[message.target]) |*target| {
            var context = enemy_session.context(self, allocator, audio, null);
            try enemy.packetMessage(target, &self.actor_slots[message.target].?, message.code, &context);
        } else if (actor.logic_name.len != 0) switch (try cmm.resolve(actor.logic_name)) {
            .object => try object_logic.receive(self, message.target, message.code),
            .ground_object, .instant_ground_object, .ground_sheriff_star, .ground_vanishing_cream, .projectile_dispatch, .explosive_projectile_dispatch => {},
            else => return error.UnsupportedActorActivationNative,
        };
        self.syncActor(message.target);
    }

    fn createProjectile(host: *anyopaque, descriptor: projectile.Descriptor, effects: *inventory_module.Effects) !usize {
        const self: *Session = @ptrCast(@alignCast(host));
        return projectile_session.create(self, descriptor, effects);
    }

    fn launchProjectile(host: *anyopaque, source: usize, owner: projectile.Owner, fraction: f32) !void {
        const self: *Session = @ptrCast(@alignCast(host));
        try projectile_session.launch(self, source, owner, fraction);
    }

    fn infUnlinked(host: *anyopaque, target: inf_module.Target) void {
        const self: *Session = @ptrCast(@alignCast(host));
        object_numbers.unlink(self, target.sector orelse return, target.wall, self.animation_time);
    }

    fn dispatchInfObject(host: *anyopaque, id: u32, code: u32) !void {
        const self: *Session = @ptrCast(@alignCast(host));
        for (self.objects.entries, 0..) |object, source| {
            if (object.id != id or self.actor_slots[source] != null or self.removed_actors[source]) continue;
            const sector = self.level.sectorIndex(object.sector_id) orelse continue;
            try loadActorSector(self, sector);
        }
        var selected: ?usize = if (self.player_actor.object_id == id) shooting.local_player else null;
        var order: u64 = if (selected != null) self.player_actor.birth_order else std.math.maxInt(u64);
        for (self.actor_slots, self.removed_actors, 0..) |slot, removed, source| {
            if (removed) continue;
            if (slot) |actor| if (actor.object_id == id and actor.birth_order < order) {
                selected = source;
                order = actor.birth_order;
            };
        }
        if (selected) |source| {
            try self.deliverActorMessage(self.allocator, self.active_audio, .{ .target = source, .code = code, .serial = self.enemy_selection_serial });
            return;
        }
        if (!((code >= 0x7d4 and code <= 0x7de) or code == 0x7e1 or code == 0x7e2)) return error.UnsupportedGeneratorMessage;
        _ = try generator.message(self, self.allocator, self.active_effects orelse return error.MissingNativeEffects, id, code);
    }

    fn hitSender(self: *const Session, source: ?usize) ?enemy.Subject {
        const index = source orelse return null;
        if (index == shooting.local_player) return enemy_session.playerSubject(self);
        if (index >= self.actor_slots.len or self.removed_actors[index]) return null;
        const actor = self.actor_slots[index] orelse return null;
        return enemy.Subject.fromActor(actor);
    }

    fn postStartRecords(self: *Session, allocator: std.mem.Allocator, startup: *const campaign.Startup) !void {
        if (startup.mode != 6) return error.MultiplayerModeNotPorted;
        const starts = try self.objects.multiplayerStarts(allocator, &self.level, startup.mode, @intFromEnum(startup.difficulty), self.server.configuration.options[0]);
        defer allocator.free(starts);
        for (starts) |record| try network_server.addStartPosition(self.router, record);
    }

    fn requestStart(self: *Session, allocator: std.mem.Allocator, startup: *const campaign.Startup, now: u32) !level_module.Spawn {
        if (startup.mode != 0) return error.UnexpectedStartRequest;
        const starts = try self.objects.playerStarts(allocator, &self.level, @intFromEnum(startup.difficulty));
        defer allocator.free(starts);
        for (starts) |record| try network_server.setStartPosition(self.router, record);
        try self.startDrain(allocator, now);
        try network_server.requestStartPosition(self.router, 0);
        if (try self.database.next(self.router, true, now) != null) return error.UnexpectedStartupMessage;
        try self.startDrain(allocator, now);
        const request = try self.database.next(self.router, true, now) orelse return error.MissingStartReply;
        if (request != .start_here) return error.UnexpectedStartupMessage;
        if (try self.database.next(self.router, true, now) != null) return error.UnexpectedStartupMessage;
        return level_module.Spawn.fromStart(&self.level, request.start_here);
    }

    fn startDrain(self: *Session, allocator: std.mem.Allocator, now: u32) !void {
        var user_messages_buffer: network_server.UserMessageBuffer = undefined;
        var user_messages = network_server.UserMessages.init(&user_messages_buffer);
        try network_server.processRequests(self.server, self.router, .{ .now = now, .game_type = self.game_type, .mode = self.mode, .level_loaded = true, .allocator = allocator, .user_messages = &user_messages });
        if (user_messages.items.len != 0) return error.UnexpectedStartupMessage;
    }

    fn standInSpawn() level_module.Spawn {
        return .{ .sector = 0, .position = .{ .x = 0, .y = -10000.0, .z = 0 }, .rotation = .{ .x = 0, .y = 0, .z = 0 } };
    }

    fn provisionalSpawn(self: *Session, allocator: std.mem.Allocator, startup: *const campaign.Startup) !level_module.Spawn {
        const starts = try self.objects.playerStarts(allocator, &self.level, @intFromEnum(startup.difficulty));
        defer allocator.free(starts);
        if (starts.len == 0) return error.PlayerStartNotFound;
        return level_module.Spawn.fromStart(&self.level, starts[starts.len - 1]);
    }

    fn activatePlayer(self: *Session, packet: *const player_input.Packet, actors: @import("../player/collision.zig").Actors, runtime: *script_runtime.Context) !void {
        for ([_]player_input.Slot{ .use, .nudge }) |slot| {
            if (packet.get(slot).flags & player_input.pressed == 0) continue;
            const id: u32 = if (slot == .use) (try self.inventory.useSelected(runtime.effects) orelse continue) else 0;
            var events_buffer: interaction.RayEventBuffer = undefined;
            var events = interaction.RayEvents.init(&events_buffer);
            try interaction.activate(&events, &self.level, &self.scene, &self.angles, self.textures, &self.player, actors, id);
            for (events.items) |event| try runtime.infEvent(event);
        }
    }

    fn enterPlayerSector(context: *anyopaque, sector: usize) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        _ = try self.changePalette(self.level.sectors[sector].palette);
    }

    fn networkMarks(self: *Session) ?inf_geometry.Marks {
        if (self.game_type != 4 and self.game_type != 5) return null;
        return network_level.marks(self);
    }

    fn infAudioContext(self: *Session, audio: ?*audio_runtime.Runtime) !?inf_module.AudioContext {
        _ = audio orelse return null;
        const cache = &self.enemy_visibility;
        const world_context = self.audioWorld();
        return .{ .cache = cache, .scene = world_context.scene, .angles = world_context.angles, .listener_eye = world_context.listener_eye, .listener_sector = world_context.listener_sector, .listener = self.audioListener(), .now_ms = self.animation_time };
    }

    fn lighting(self: *const Session) walls.Lighting {
        return .{ .force_depth = @intFromBool(self.lamp_state.force_depth), .depth_bias = self.lamp_state.depth_bias, .depth_strength = self.weapon_state.flash, .ambient_bias = 0, .ambient = 0, .ambient_min = 0, .color_map = self.color_map, .depth_map = &self.depth_map };
    }

    fn blend(self: *const Session) ?[]const u8 {
        for (self.level.shades[1..]) |shade| if (shade != null) return &self.blend_table;
        return null;
    }

    fn acceptObject(self: *const Session, object: level_module.Object) bool {
        return object.flags[1] & self.object_mode_mask != 0 and
            (self.mode == 0 or self.object_option0 or object.flags[1] & 0x200000 == 0);
    }

    fn startMarker(_: *const Session, name: []const u8) bool {
        for ([_][]const u8{ "PLAYER", "STARTPOS", "FLAGSTAR", "DOCSTART", "BALLSTAR" }) |marker| {
            if (std.ascii.eqlIgnoreCase(name, marker)) return true;
        }
        return false;
    }

    fn compactRemovedActors(self: *Session) void {
        var index: usize = 0;
        while (index < self.actors.len) {
            const source = self.actors[index].source_index.?;
            if (self.removed_actors[source]) self.syncActor(source) else index += 1;
        }
    }

    fn spawnBubbles(raw: *anyopaque, runtime: *script_runtime.Context, sector: usize, position: level_module.Vec3, count: i32) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw));
        try runtime.effects.append(.{ .sound = bubble.sound(&self.contact_state.random, sector, position) });
        if (count <= 0) return;
        const costume = try enemy_session.costume(self, bubble.costume_name);
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            const actor = bubble.spawn(costume, &self.contact_state.random, sector, position, self.animation_time);
            const index = try enemy_session.appendActor(self, actor, null);
            self.general_slots[index] = .{ .velocity = .{ .x = 0, .y = 0, .z = 0 } };
        }
        runtime.pickups = self.pickup_slots;
        runtime.removed = self.removed_actors;
        runtime.actor_next_update = self.actor_next_update;
    }

    fn loadActorSector(raw: *anyopaque, sector: usize) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(raw));
        const sectors = try self.allocator.alloc(bool, self.level.sectors.len);
        defer self.allocator.free(sectors);
        @memset(sectors, false);
        sectors[sector] = true;
        _ = try self.loadActorsInSectors(sectors);
    }

    fn loadEnemies(self: *Session, allocator: std.mem.Allocator) !void {
        try enemy_session.preload(self, allocator);
    }

    fn objectResource(self: *const Session, system: lab.Archive, name: []const u8) !?[]const u8 {
        return self.object_archive.find(name, 0) catch |err| switch (err) {
            error.ResourceNotFound => system.find(name, 0) catch |second| switch (second) {
                error.ResourceNotFound => null,
                else => return second,
            },
            else => return err,
        };
    }
};

fn soundRequest(sound: @FieldType(inf_module.Effect, "sound")) @import("../audio/request.zig").Request {
    return .{ .basename = sound.name, .priority = sound.priority, .volume = sound.volume, .flags = sound.flags, .sector = sound.sector, .position = sound.position, .source = sound.source, .occlusion_applied = sound.occlusion_applied, .listener = sound.listener, .mode = switch (sound.mode) {
        .once => .once,
        .loop => .loop,
        .stop => .stop,
        .update => .update,
    } };
}

fn loadArchive(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, basename: []const u8, front: []const lab.Archive) !lab.Archive {
    const path = try std.fs.path.join(allocator, &.{ directory, basename });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(128 * 1024 * 1024)) catch |err| {
        std.log.err("cannot load renderer archive {s}: {s}; {s} belongs next to the game data", .{ path, @errorName(err), basename });
        return err;
    };
    var archive = try lab.Archive.init(bytes);
    archive.front = front;
    return archive;
}

test "Death Match host receives a Dry Gulch start from its server" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.initHost(a, .{ .basename = "DRYGULCH", .location = "Dry Gulch", .mode = 6, .mode_name = "Death Match", .game_name = "Outlaws" });
    defer startup.deinit(a);
    startup.bindRouterParts(try system.find("LOCAL.MSG", 0));
    const reference = @import("../network/reference_driver.zig");
    const message = @import("../network/message.zig");
    var driver: reference.Driver = .{ .allocator = a };
    defer driver.deinit();
    var notes: reference.Game = .{ .allocator = a };
    defer notes.deinit();
    var opener: reference.Opener = .{ .driver = &driver, .game = &notes, .address = @splat(0x11) };
    try std.testing.expect(try startup.connectHost(opener.provider()));
    try std.testing.expectEqual(@as(u32, 1), startup.router.own_client);
    try std.testing.expectEqualStrings("open 1  (1.1) Outlaws|Player", notes.calls.items[0]);
    try std.testing.expectEqualSlices(u8, "\x06LOCATION\n   Dry Gulch\nDeath Match\nPlayers: (1 / 8)\nStarted By:\n   Player\x00", driver.description.items);
    try startup.beginHost(a, std.testing.io, path, system);
    const audio = try audio_runtime.Runtime.open(a, std.testing.io, path, system);
    defer audio.deinit();
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    try std.testing.expectEqualStrings("drygulch", session.level_name);
    try std.testing.expectEqualStrings("NULL", session.level.music);
    try std.testing.expectEqual(@as(u32, 0x0738ace6), session.level.token_checksum);
    try std.testing.expectEqual(@as(u32, 0x37169dc6), startup.server.record.parameter);
    try std.testing.expectEqual(startup.server.record.parameter, startup.server.record.checksum);
    try session.bindAudio(audio);
    try audio.engine.updateListener(session.audioListener());
    try audio.beginLevel(std.testing.io, &session.level, session.geometry_archive, 0);
    try std.testing.expect(audio.script == null);
    try audio.beginAmbient(&session.level, &session.objects, startup.difficulty);
    const pixels = try a.alloc(u8, 640 * 480);
    defer a.free(pixels);
    _ = try session.render(pixels, 0);
    try std.testing.expect(!startup.server.started);
    try std.testing.expect(session.stand_in);
    try std.testing.expectEqual(@as(usize, 0), session.player.sector);
    try std.testing.expectEqual(@as(f32, -10000.0), session.player.position.y);
    startup.networkLevelLoaded();
    try session.bindStandIn(session.animation_time);
    try startup.enterLobby();
    try std.testing.expectEqual(@as(u32, 1), startup.engine.game_state);
    try std.testing.expectEqual(@as(u32, 8), startup.engine.scenario);
    try std.testing.expectEqual(@as(?network_router.Player, .{ .code = 'J', .flags = 0x1000090 }), startup.router.clients[1].player);
    try std.testing.expect(startup.router.clients[1].in_level);
    try std.testing.expectEqual(@as(usize, 1), startup.database.player_count);
    try std.testing.expectEqual(@as(usize, 2), driver.sends.items.len);
    for (driver.sends.items, [_]u32{ 0x3f7, 0x3fd }) |sent, number| {
        try std.testing.expectEqual(@as(?message.Address, null), sent.to);
        try std.testing.expectEqual(@as(u8, 'G'), sent.bytes[0]);
        try std.testing.expectEqual(number, message.get(sent.bytes[1..], message.number_offset));
    }
    var packet: player_input.Packet = .{};
    for (0..64) |_| try session.advance(a, &packet, 16);
    try std.testing.expectEqual(@as(f32, -10000.0), session.player.position.y);
    try std.testing.expect(!startup.server.started);
    try std.testing.expect(startup.server.start_count > 0);
    const stand_in_number = session.player_number;
    try std.testing.expect(startup.database.find(stand_in_number) != null);
    try session.removeStandIn(session.animation_time);
    try std.testing.expect(startup.database.find(stand_in_number) == null);
    try startup.leaveLobby(1);
    try std.testing.expectEqual(@as(u8, 1), startup.team);
    for (0..4) |_| {
        try session.networkPass(a, 16, null);
        if (startup.engine.game_state == 1) break;
        try startup.startStep(session.animation_time);
    }
    try std.testing.expectEqual(@as(u32, 1), startup.engine.game_state);
    try std.testing.expectEqual(@as(u32, 2), startup.engine.scenario);
    try std.testing.expect(startup.server.started);
    try std.testing.expect(!session.stand_in);
    try std.testing.expect(session.player.position.y != -10000.0);
    try std.testing.expectEqual(@as(?network_router.Player, .{ .code = 'J', .flags = 0x90 }), startup.router.clients[1].player);
    const before = driver.sends.items.len;
    for (0..64) |_| try session.advance(a, &packet, 16);
    try std.testing.expect(driver.sends.items.len > before);
    var sent_player_record = false;
    for (driver.sends.items[before..]) |sent| if (sent.bytes[0] == 'G' and message.get(sent.bytes[1..], message.number_offset) == 0x418) {
        sent_player_record = true;
    };
    try std.testing.expect(sent_player_record);
    try std.testing.expectEqual(@as(u32, 0), startup.router.rejected);
}

test "mission restart restores the current level with retained globals and constructor clocks" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const old = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer old.deinit(a);
    try std.testing.expect(startup.server.started);
    try std.testing.expectEqual(@as(u32, 0x36a11), startup.server.starts[0][0]);
    for (startup.router.queues) |queue| try std.testing.expectEqual(@as(usize, 0), queue.count);
    const selected = old.inventory.selected_weapon;
    const loaded = old.inventory.slots[selected].?.loaded;
    old.inventory.health = 2;
    old.inventory.slots[selected].?.loaded = 0;
    old.player.energy = 13;
    old.player.position.x += 20;
    old.player.auto_pitch = false;
    old.player.stride = 11;
    old.player.stride_side = true;
    old.actor_time = 1000;
    old.animation_time = 1000;
    old.frame_seconds = 0.016;
    old.look = .{ .pitch_active = true, .pitch_accumulator = 1234, .yaw_active = true, .yaw_accumulator = -123 };
    old.contact_state = .{ .random = 0x12345678, .last_enemy_random = 0xdeadbeef };
    old.enemy_shared.crt_random = 0x11223344;
    old.enemy_shared.next_shot = 90050;
    old.enemy_shared.next_taunt = 93000;
    old.enemy_shared.killed_enemies = 17;
    old.weapon_state = .{ .action = 2, .pending = 3, .scope = true, .held = .{ true, false, true, true }, .last_press = 12345, .shot_count = 99, .fire_noise_due = 90500, .flash = 11, .kick = 0.5, .scope_flash = 9, .scope_kick = 0.25, .aim_x = 23, .aim_y = 9, .aim_weight = 85, .aim_due = 92000 };
    old.impact_state.noise_due = 90200;
    old.damage_flash = .{ .strength = 100, .alpha = 100, .active = true, .last_ms = 89500 };
    old.player_audio_state.tired_elapsed = 1.25;
    old.automap.setMode(4);
    old.automap.zoom = 1.25;
    old.automap.reveal = true;
    try old.messages.post(200, 18, 89000);

    const fresh = try old.restart(a, std.testing.io, path, system, &startup, 90000);
    defer fresh.deinit(a);
    try std.testing.expectEqualStrings(old.level_name, fresh.level_name);
    try std.testing.expectEqual(@as(u32, 90000), fresh.animation_time);
    try std.testing.expectEqual(@as(u32, 1000), fresh.actor_time);
    try std.testing.expectEqual(@as(f32, 0.016), fresh.frame_seconds);
    try std.testing.expectEqual(@as(u32, 90000), fresh.inf.task_time);
    try std.testing.expectEqual(@as(u32, 90000), fresh.hud.badge.playback.last_time);
    try std.testing.expectEqual(@as(f32, 10), fresh.inventory.health);
    try std.testing.expectEqual(@as(f32, 100), fresh.player.energy);
    try std.testing.expectEqual(selected, fresh.inventory.selected_weapon);
    try std.testing.expectEqual(loaded, fresh.inventory.slots[selected].?.loaded);
    try std.testing.expectEqualDeep(fresh.spawn.position, fresh.player.position);
    try std.testing.expectEqual(@as(f32, 0), fresh.player.stride);
    try std.testing.expect(fresh.player.stride_side);
    try std.testing.expect(!fresh.player.auto_pitch);
    try std.testing.expectEqual(player_input.LookState{ .pitch_active = true, .yaw_active = true, .yaw_accumulator = -123 }, fresh.look);
    try std.testing.expectEqual(@as(i16, 0), fresh.player.pitch);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), fresh.contact_state.last_enemy_random);
    try std.testing.expectEqual(@as(u32, 0x11223344), fresh.enemy_shared.crt_random);
    try std.testing.expectEqual(@as(u32, 90050), fresh.enemy_shared.next_shot);
    try std.testing.expectEqual(@as(u32, 93000), fresh.enemy_shared.next_taunt);
    try std.testing.expectEqual(@as(f32, 0), fresh.enemy_shared.killed_enemies);
    try std.testing.expectEqual(@as(i32, -1), fresh.weapon_state.action);
    try std.testing.expectEqual(@as(i32, -1), fresh.weapon_state.pending);
    try std.testing.expect(!fresh.weapon_state.scope);
    try std.testing.expectEqual(@as(u32, 90000), fresh.weapon_state.last_press);
    try std.testing.expectEqual([4]bool{ true, false, true, true }, fresh.weapon_state.held);
    try std.testing.expectEqual(@as(u32, 90500), fresh.weapon_state.fire_noise_due);
    try std.testing.expectEqual(@as(u32, 0), fresh.weapon_state.shot_count);
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, [3]i32{ fresh.weapon_state.aim_x, fresh.weapon_state.aim_y, fresh.weapon_state.aim_weight });
    try std.testing.expectEqual(@as(?u32, null), fresh.weapon_state.aim_due);
    try std.testing.expectEqual([2]i32{ 11, 9 }, [2]i32{ fresh.weapon_state.flash, fresh.weapon_state.scope_flash });
    try std.testing.expectEqual([2]f32{ 0.5, 0.25 }, [2]f32{ fresh.weapon_state.kick, fresh.weapon_state.scope_kick });
    try std.testing.expectEqual(@as(u32, 90200), fresh.impact_state.noise_due);
    try std.testing.expectEqual(damage_flash.State{ .last_ms = 89500 }, fresh.damage_flash);
    try std.testing.expectEqual(@as(f32, 1.25), fresh.player_audio_state.tired_elapsed);
    try std.testing.expectEqual(@as(u32, 0), fresh.automap.mode);
    try std.testing.expectEqual(@as(f32, 1.25), fresh.automap.zoom);
    try std.testing.expect(!fresh.automap.reveal);
    try std.testing.expectEqualDeep(old.messages.entries, fresh.messages.entries);
    try std.testing.expectEqual(old.messages.first_parameter, fresh.messages.first_parameter);

    const sounds = [_][]const u8{ "door2.wav", "door1.wav", "door4.wav", "door2.wav", "door4.wav", "door5.wav", "door3.wav", "door2.wav", "door2.wav", "door4.wav", "door2.wav", "door2.wav", "door1.wav", "door1.wav", "door1.wav" };
    var door: usize = 0;
    for (fresh.inf.elevators) |elevator| if (elevator.automatic_door) {
        try std.testing.expect(door < sounds.len);
        try std.testing.expect(std.ascii.eqlIgnoreCase(sounds[door], elevator.sounds[0].?));
        door += 1;
    };
    try std.testing.expectEqual(sounds.len, door);
    try std.testing.expectEqual(@as(u32, 0x2b5fa130), fresh.contact_state.random);
    for (fresh.texture_animations.instances) |instance| try std.testing.expectEqual(@as(u32, 90000), instance.state.last_tick);
    try fresh.loadEnemies(a);
    for (fresh.actor_slots) |maybe_actor| if (maybe_actor) |actor| if (actor.playback) |playback| try std.testing.expectEqual(@as(u32, 90000), playback.last_time);
    for (fresh.targets) |target| if (target) |enemy_target| try std.testing.expectEqual(@as(u32, 90000), enemy_target.playback.last_time);
    try std.testing.expectEqual(@as(f32, 2), old.inventory.health);
    try std.testing.expectEqual(@as(u32, 0x12345678), old.contact_state.random);
    try fresh.advance(a, &.{}, 16);
    try std.testing.expectEqual(@as(u32, 90016), fresh.animation_time);
    try std.testing.expectEqual(@as(u32, 90016), fresh.actor_time);
    try std.testing.expectEqual(@as(f32, 0.25), fresh.frame_seconds);
}

test "bound campaign carry releases Ranch weapons through the retained sound service" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    const mission = @import("../platform/mission.zig");
    var mounts = mission.Mounts.init(a, path, system);
    defer mounts.deinit();
    const audio = try audio_runtime.Runtime.open(a, io, path, system);
    defer audio.deinit();
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();

    const departed = block: {
        const old = try Session.openWithState(a, @import("test_workspace.zig").get(), io, path, system, &startup, 90000, .{});
        defer old.deinit(a);
        try old.bindAudio(audio);
        try audio.beginLevel(io, &old.level, old.geometry_archive, 90000);
        old.inventory.clock = 91000;
        const health_slot = try old.inventory.acquire(try inventory_module.Definition.load(old.arena.allocator(), &.{ old.object_archive, old.weapon_archive, old.geometry_archive, system }, "IDOCBAG"), 0);
        try std.testing.expect(health_slot != 0);
        const health_id = audio.lookup("COOL.wav") orelse return error.MissingCarriedHealthSound;
        const pistol_id = audio.lookup("PRELOAD.wav") orelse return error.MissingCarriedPistolSound;
        const rifle_id = audio.lookup("RRELOAD.wav") orelse return error.MissingCarriedRifleSound;
        const state = try old.campaignState(a);
        try std.testing.expectEqual(audio, state.retained_audio.?);
        try std.testing.expectEqual(@as(usize, 0), state.pending_sound_ledgers.len);
        try std.testing.expectEqual(pistol_id, audio.lookup("PRELOAD.wav").?);
        try std.testing.expectEqual(rifle_id, audio.lookup("RRELOAD.wav").?);
        break :block .{
            .carry = state,
            .persistent = old.persistentState(),
            .health_id = health_id,
            .health_record = audio.registrations.items[health_id],
            .health_refs = audio.registration_refs.items[health_id].count,
            .pistol_id = pistol_id,
            .rifle_id = rifle_id,
        };
    };
    var carry = departed.carry;
    defer carry.deinit();
    var ranch = try campaign.Startup.prepare(a, system, .good);
    defer ranch.deinit(a);
    try mission.select(&ranch, "ranch");
    const event = try ranch.levelForDiagnostics();
    try mounts.selectDisc(io, event.disc);
    try audio.remount(io, mounts.path(), mounts.system());
    const fresh = try Session.openWithCampaignState(a, @import("test_workspace.zig").get(), io, mounts.path(), mounts.system(), &ranch, 180000, departed.persistent, &carry);
    defer fresh.deinit(a);

    try std.testing.expectEqual(@as(u32, 0xc000), fresh.player_bind_flags);
    try std.testing.expectEqual(@as(usize, 0), fresh.inventory.find("IPISTOL"));
    try std.testing.expectEqual(@as(usize, 0), fresh.inventory.find("IRIFLE"));
    try std.testing.expectEqual(@as(usize, 1), fresh.inventory.selected_weapon);
    try std.testing.expectEqualStrings("IFIST", fresh.inventory.slots[1].?.definition.name);
    try std.testing.expectEqual(@as(i32, 6), fresh.inventory.slots[fresh.inventory.find("IBULLIT")].?.count);
    try std.testing.expectEqual(@as(i32, 12), fresh.inventory.slots[fresh.inventory.find("ICART")].?.count);
    try std.testing.expect(fresh.inventory.find("IOIL") != 0);
    try std.testing.expect(fresh.inventory.find("IDOCBAG") != 0);
    try std.testing.expect(!audio.registration_refs.items[departed.pistol_id].active);
    try std.testing.expect(!audio.registration_refs.items[departed.rifle_id].active);

    try std.testing.expectEqual(audio, fresh.sound_ledger.audio.?);
    try std.testing.expectEqual(departed.health_id, audio.lookup("COOL.wav").?);
    try std.testing.expectEqualDeep(departed.health_record, audio.registrations.items[departed.health_id]);
    const ranch_health_refs = departed.health_refs + 6;
    try std.testing.expectEqual(ranch_health_refs, audio.registration_refs.items[departed.health_id].count);
    const registered = audio.registrations.items.len;
    try fresh.bindAudio(audio);
    try std.testing.expectEqual(registered, audio.registrations.items.len);
    try std.testing.expectEqual(ranch_health_refs, audio.registration_refs.items[departed.health_id].count);
    try fresh.closeSounds();
    try std.testing.expectEqual(departed.health_id, audio.lookup("COOL.wav").?);
    try std.testing.expectEqual(departed.health_refs, audio.registration_refs.items[departed.health_id].count);
}

test "bound Train restart registers its missing doubled door sound again" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    const audio = try audio_runtime.Runtime.open(a, io, path, system);
    defer audio.deinit();
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    try @import("../platform/mission.zig").select(&startup, "train");
    try startup.finishMovie(true);
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    const old = try Session.open(a, @import("test_workspace.zig").get(), io, path, system, &startup);
    defer old.deinit(a);
    try old.bindAudio(audio);
    const fresh = try old.restart(a, io, path, system, &startup, 90000);
    defer fresh.deinit(a);
    var records: usize = 0;
    for (audio.registrations.items, audio.registration_refs.items) |record, refs| {
        if (!refs.active or !std.ascii.eqlIgnoreCase(record.name, "TRAINDR2.WAV.WAV")) continue;
        try std.testing.expectEqual(@as(i32, 1), refs.count);
        records += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), records);
}

test "campaign completion admits at SYS drain and retains its final frame" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fixture = std.Io.Dir.cwd().readFileAlloc(io, "testdata/campaign-phase-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(fixture);
    const Sample = struct {
        previous: u32,
        now: u32,
        frame_elapsed: u32,
        last: u32,
        state: u32,
    };
    const parsed = try std.json.parseFromSlice(struct { results_sha256: []const u8, samples: []const Sample }, a, fixture, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("201756f1bedd4d97934aa933cde557ded0f2b6d23ecd5e69d2f932e3525d5e01", parsed.value.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    for (parsed.value.samples) |sample| {
        var startup = try campaign.Startup.prepare(a, system, .good);
        defer startup.deinit(a);
        startup.server.completion_gate.last = sample.previous;
        _ = try startup.levelForDiagnostics();
        const session = try Session.openWithState(a, @import("test_workspace.zig").get(), io, path, system, &startup, sample.now -% 1, .{});
        defer session.deinit(a);
        try network_server.requestEndLevel(session.router);
        try session.advance(a, &.{}, 1);
        try std.testing.expectEqual(sample.state == 2, session.campaign_completion_requested);
        try std.testing.expectEqual(sample.last, session.server.completion_gate.last);
        try std.testing.expectEqual(sample.now, session.actor_time);
        if (sample.state == 1) {
            try session.advance(a, &.{}, sample.frame_elapsed);
            try std.testing.expect(!session.campaign_completion_requested);
            try std.testing.expectEqual(sample.last, session.server.completion_gate.last);
        }
    }
}

test "SYS drain skips Train LAST_DOOR's TRIGGER and still admits END_LEVEL" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.openWithState(a, @import("test_workspace.zig").get(), io, path, system, &startup, 20000, .{});
    defer session.deinit(a);
    try session.inf.postSystem(.{ .code = 0x7d6 });
    try network_server.requestEndLevel(session.router);
    try session.advance(a, &.{}, 1);
    try std.testing.expect(session.campaign_completion_requested);
}

test "INF audio captures pre-player message and post-player task listener phases" {
    const a = std.testing.allocator;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    const audio = audio_runtime.Runtime.open(a, std.testing.io, path, system) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer audio.deinit();
    audio.visibility = try @import("../audio/occlusion.zig").Cache.init(a, &session.level);
    session.player.sector = 337;
    session.player.position = .{ .x = 429.5, .y = 0, .z = 211.5 };
    session.player.yaw = 0;
    session.player.floor_cache = 0;
    var packet: player_input.Packet = .{};
    packet.entries[@intFromEnum(player_input.Slot.nudge)].flags = player_input.pressed;
    try session.advanceWithAudio(a, &packet, 16, audio);
    session.player.velocity.x = 10;
    const before_player = session.audioListener();
    try session.advanceWithAudio(a, &.{}, 16, audio);
    var early: usize = 0;
    for (session.pickup_effects.items) |effect| if (effect == .sound and effect.sound.sector == 20) {
        try std.testing.expect(effect.sound.occlusion_applied);
        try std.testing.expectEqual(before_player, effect.sound.listener.?);
        early += 1;
    };
    try std.testing.expect(early != 0);
    try std.testing.expect(!std.meta.eql(before_player, session.audioListener()));
    try std.testing.expect(session.inf.audio == null);
    try std.testing.expect(session.active_audio == null);
    try session.advanceWithAudio(a, &.{}, 16, audio);
    var late: usize = 0;
    for (session.pickup_effects.items) |effect| if (effect == .sound and effect.sound.sector == 20 and effect.sound.mode == .update) {
        try std.testing.expect(effect.sound.occlusion_applied);
        try std.testing.expectEqual(session.audioListener(), effect.sound.listener.?);
        late += 1;
    };
    try std.testing.expect(late != 0);
    try std.testing.expect(session.inf.audio == null);
    try std.testing.expect(session.active_audio == null);
}

test "queued sounds precede handcar admission and retain their captured listener" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/audio-order-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        results_sha256: []const u8,
        rail: u32,
        queued: u32,
        pull: u32,
        next_id: u32,
        active: []u32,
    };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("1d4f24a7cee2b2373af7b2248ae2cebca0a074b1d8b2b117951c3fd1559a949c", fixture.value.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const archive_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(archive_bytes);
    const system = try lab.Archive.init(archive_bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    const sound = try audio_runtime.Runtime.open(a, std.testing.io, path, system);
    defer sound.deinit();
    session.active_audio = sound;
    defer session.active_audio = null;
    sound.engine.effects_volume = 127;
    const resource = try sound.register("thunk.wav");
    for (0..7) |_| _ = try sound.engine.start(resource, sound.waves.items[resource].sample_rate, .{ .priority = 64 }, 0);
    var effects_buffer: inventory_module.EffectBuffer = undefined;
    var effects = inventory_module.Effects.init(&effects_buffer);
    var pending = Session.PendingAudio{ .session = session, .effects = &effects };
    var context = rail_audio.Context{ .state = &session.rail_audio_state, .runtime = sound, .now = 0, .before = .{ .context = &pending, .drain = Session.PendingAudio.drain } };
    const position: level_module.Vec3 = .{ .x = 0, .y = 0, .z = 0 };
    try context.start(position);
    try effects.append(.{ .sound = .{
        .basename = "thunk.wav",
        .priority = 64,
        .volume = 127,
        .position = .{ .x = 200, .y = 0, .z = 0 },
        .sector = 0,
        .occlusion_applied = true,
        .listener = .{ .position = .{ 200, 0, 0 } },
    } });
    try context.pull(position);
    try std.testing.expectEqual(fixture.value.rail, session.rail_audio_state.rail_handle);
    try std.testing.expectEqual(fixture.value.pull, session.rail_audio_state.pull_handle);
    try std.testing.expect(sound.engine.find(fixture.value.pull) == null);
    const queued = sound.engine.find(fixture.value.queued).?;
    try std.testing.expectEqual(@as(i32, 127), queued.effective_volume);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, sound.engine.listener.position);
    try std.testing.expect(effects.items[0].sound.delivered);
    try context.pull(position);
    try session.drainSounds(&effects);
    try std.testing.expectEqual(fixture.value.next_id, sound.engine.next_id);
    var active: usize = 0;
    for (sound.engine.voices) |voice| if (voice.active) {
        try std.testing.expect(std.mem.indexOfScalar(u32, fixture.value.active, voice.id) != null);
        active += 1;
    };
    try std.testing.expectEqual(fixture.value.active.len, active);
    try enemy_session.preload(session, a);
    const victim = for (session.targets, 0..) |target, source| {
        if (target) |value| if (!value.sanchez and value.config.die_sound.len != 0) break source;
    } else return error.MissingOriginalEnemyPlacement;
    for (session.actor_slots, 0..) |*slot, source| if (slot.*) |*actor| {
        if (source != victim) actor.secondary_flags &= ~@as(u32, 0x100);
        session.syncActor(source);
    };
    session.player.sector = session.actor_slots[victim].?.sector;
    session.player.position = session.actor_slots[victim].?.position;
    sound.engine.listener.position = .{ session.player.position.x, session.player.position.y, session.player.position.z };
    session.active_effects = &effects;
    defer session.active_effects = null;
    for ([_]bool{ false, true }) |impact| {
        sound.stopAll();
        effects.clearRetainingCapacity();
        try effects.append(.{ .sound = .{ .basename = "thunk.wav", .priority = 64 } });
        const next_id = sound.engine.next_id;
        const target = &session.targets[victim].?;
        target.mode = 0x800003c0;
        target.dead = false;
        if (impact) {
            try enemy_session.impactNoise(session, a, &effects);
        } else {
            var native = enemy_session.context(session, a, sound, null);
            try enemy.message(target, &session.actor_slots[victim].?, 0x83, &.{}, &native);
        }
        try std.testing.expect(target.dead);
        try std.testing.expectEqual(@as(u32, 0x3c0), target.mode);
        try std.testing.expect(effects.items[0].sound.delivered);
        try std.testing.expectEqual(resource, sound.engine.find(next_id + 1).?.asset);
        try std.testing.expectEqual(try sound.register(target.config.die_sound), sound.engine.find(next_id + 2).?.asset);
        try std.testing.expectEqual(next_id + 2, sound.engine.next_id);
    }
}

test "live vertical tasks retain double-mirror wall heights" {
    const a = std.testing.allocator;
    const State = struct {
        sectors: []const struct {
            index: usize,
            floor_bits: u32,
            ceiling_bits: u32,
            walls: []const struct { index: usize, offset_bits: [4]u32, height_bits: [3]u32, render_flags: u32, runtime_flags: u32 },
        },
    };
    const Fixture = struct { results_sha256: []const u8, cases: []const struct {
        name: []const u8,
        primary: usize,
        slaves: []const usize,
        wall_flags: []const struct { sector: usize, index: usize, flags: u32 },
        initial: State,
        samples: []const struct { delta_bits: u32, state: State },
    } };
    const fixture_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-vertical-reference.json", a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(fixture_bytes);
    const fixture = try std.json.parseFromSlice(Fixture, a, fixture_bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("a43de6ac2a1a1f6971e74983dd6276fc7f46706e98b5ae1c7e8f2f7aa703cc4b", fixture.value.results_sha256);
    const case = for (fixture.value.cases) |value| {
        if (std.mem.eql(u8, value.name, "controlled_9")) break value;
    } else return error.MissingVerticalReference;
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024));
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    try @import("../platform/mission.zig").select(&startup, "train");
    try startup.finishMovie(true);
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    const owned = session.arena.allocator();
    session.level = try level_module.Level.parse(owned, try session.geometry_archive.find("TRAIN.LVB", 0));
    session.scene = try scene_module.Scene.init(owned, &session.level, &session.angles);
    session.inf = .{ .arena = std.heap.ArenaAllocator.init(owned), .router = session.router, .elevators = try owned.dupe(inf_module.Elevator, &.{.{
        .sector = case.primary,
        .kind = .floor_ceiling,
        .speed = 0,
        .value = 0,
        .runtime_flags = 3,
    }}), .classes = &.{}, .triggers = &.{} };
    try session.inf.reserveLists();
    for (case.slaves) |slave| try session.inf.elevators[0].slaves.append(owned, .{ .sector = slave });
    session.enemies_loaded = true;
    @memset(session.loaded_actor_sectors, true);
    for (session.removed_actors, 0..) |*removed, source| {
        removed.* = true;
        session.syncActor(source);
    }
    for (case.wall_flags) |wall| session.scene.sectors[wall.sector].walls[wall.index].flags = wall.flags;
    for (case.initial.sectors) |sector| for (sector.walls) |wall| {
        session.scene.sectors[sector.index].walls[wall.index].runtime_flags = wall.runtime_flags;
    };
    try std.testing.expectEqual(@as(i32, 643), session.level.sectors[502].walls[0].dadjoin);
    try std.testing.expectEqual(@as(i32, 5), session.level.sectors[502].walls[0].dmirror);
    const untouched = session.scene.sectors[643].walls[5];
    for (case.samples) |sample| {
        const delta: f32 = @bitCast(sample.delta_bits);
        session.inf.elevators[0].speed = delta * 8;
        try session.advance(a, &.{}, 125);
        try std.testing.expect(!session.inf.geometry_dirty);
        for (sample.state.sectors) |sector| {
            const actual = session.level.sectors[sector.index];
            try std.testing.expectEqual(sector.floor_bits, @as(u32, @bitCast(actual.floor.height)));
            try std.testing.expectEqual(sector.ceiling_bits, @as(u32, @bitCast(actual.ceiling.height)));
            for (sector.walls) |wall| {
                const raw = actual.walls[wall.index];
                const state = session.scene.sectors[sector.index].walls[wall.index];
                try std.testing.expectEqual(wall.offset_bits, [_]u32{ @bitCast(raw.top.offset.z), @bitCast(raw.mid.offset.z), @bitCast(raw.bottom.offset.z), @bitCast(raw.overlay.offset.z) });
                try std.testing.expectEqual(wall.height_bits, [_]u32{ @bitCast(state.top_height), @bitCast(state.mid_height), @bitCast(state.bottom_height) });
                try std.testing.expectEqual(wall.render_flags, state.render_flags);
                try std.testing.expectEqual(wall.runtime_flags, state.runtime_flags);
            }
        }
        const mirror = session.scene.sectors[643].walls[5];
        try std.testing.expectEqual(untouched.mid_height, mirror.mid_height);
        try std.testing.expectEqual(untouched.render_flags, mirror.render_flags);
    }
}

test "live runtime flag clears survive unrelated light tasks" {
    const a = std.testing.allocator;
    const State = struct {
        wall: u32,
        flags: [3]u32,
        ambient: [3]i32,
        trigger: u32,
    };
    const Fixture = struct { results_sha256: []const u8, initial: State, samples: []const struct {
        now: u32,
        speed: f32,
        enabled: bool,
        after: State,
    } };
    const fixture_bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/inf-runtime-flags-reference.json", a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(fixture_bytes);
    const fixture = try std.json.parseFromSlice(Fixture, a, fixture_bytes, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("0832abaf5ccd976f8830173b2cfea712190c4a24ea541bf7e3805f32713d2814", fixture.value.results_sha256);
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024));
    defer a.free(bytes);
    const system = try lab.Archive.init(bytes);
    var startup = try campaign.Startup.prepare(a, system, .good);
    defer startup.deinit(a);
    _ = try startup.levelForDiagnostics();
    const session = try Session.open(a, @import("test_workspace.zig").get(), std.testing.io, path, system, &startup);
    defer session.deinit(a);
    const owned = session.arena.allocator();
    var held = for (session.inf.elevators) |elevator| {
        if (elevator.automatic_door) break elevator;
    } else return error.MissingOriginalAutomaticDoor;
    held.runtime_flags = 0;
    var sectors: [4]usize = undefined;
    var count: usize = 0;
    for (session.level.sectors, 0..) |_, index| {
        if (index == held.sector) continue;
        sectors[count] = index;
        count += 1;
        if (count == sectors.len) break;
    }
    session.inf = .{ .arena = std.heap.ArenaAllocator.init(owned), .router = session.router, .elevators = try owned.dupe(inf_module.Elevator, &.{
        held,
        .{ .sector = sectors[0], .kind = .light, .speed = 8, .value = 10, .runtime_flags = 3 },
        .{ .sector = sectors[2], .kind = .light, .speed = 32, .value = 30, .next_time = 0xffffffff },
    }), .classes = &.{}, .triggers = try owned.dupe(inf_module.Trigger, &.{
        .{ .target = .{ .sector = held.sector, .wall = 0 }, .flags = 0x04f00001 },
        .{ .target = .{ .sector = sectors[3] }, .flags = 0x04f00001 },
    }) };
    try session.inf.reserveLists();
    try session.inf.elevators[1].slaves.append(owned, .{ .sector = sectors[1] });
    session.enemies_loaded = true;
    @memset(session.loaded_actor_sectors, true);
    for (session.removed_actors, 0..) |*removed, source| {
        removed.* = true;
        session.syncActor(source);
    }
    for (sectors[0..3], fixture.value.initial.ambient) |sector, ambient| {
        session.level.sectors[sector].ambient = ambient;
        session.scene.sectors[sector].runtime_flags = 0;
    }
    session.scene.sectors[sectors[3]].runtime_flags = 0;
    session.scene.sectors[held.sector].walls[0].runtime_flags = 0;
    session.inf.applyScene(&session.level, &session.scene);
    const Check = struct {
        fn state(s: *const Session, owner: usize, lights: [4]usize, expected: State) !void {
            try std.testing.expectEqual(expected.wall, s.scene.sectors[owner].walls[0].runtime_flags);
            for (lights[0..3], expected.flags, expected.ambient) |sector, flags, ambient| {
                try std.testing.expectEqual(flags, s.scene.sectors[sector].runtime_flags);
                try std.testing.expectEqual(ambient, s.level.sectors[sector].ambient);
            }
            try std.testing.expectEqual(expected.trigger, s.scene.sectors[lights[3]].runtime_flags);
        }
    };
    try Check.state(session, held.sector, sectors, fixture.value.initial);
    for (fixture.value.samples) |sample| {
        try session.inf.pending.append(.{ .message = .{ .value = .{ .target = .{ .sector = held.sector, .wall = 0 }, .code = 0x7e0, .arg1 = 2, .arg2 = -1 }, .entity_mask = 0 } });
        for (sectors) |sector| try session.inf.pending.append(.{ .message = .{ .value = .{ .target = .{ .sector = sector }, .code = 0x7e0, .arg1 = 2, .arg2 = -1 }, .entity_mask = 0 } });
        session.inf.elevators[1].speed = sample.speed;
        session.inf.elevators[1].runtime_flags = if (sample.enabled) 3 else 0;
        try session.advance(a, &.{}, sample.now - session.animation_time);
        try Check.state(session, held.sector, sectors, sample.after);
        try std.testing.expect(!session.inf.geometry_dirty);
    }
}
