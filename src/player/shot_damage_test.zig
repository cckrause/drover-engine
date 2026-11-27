//! Bullets and projectiles hitting the player: armour, impulse, blood and health feedback.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const shot_damage = @import("shot_damage.zig");
const shooting = @import("shooting.zig");
const inventory_module = @import("inventory.zig");
const movement = @import("movement.zig");
const player_audio = @import("../audio/player.zig");
const flash_module = @import("../render/damage_flash.zig");
const Item = @import("../assets/item.zig").Item;
const lab = @import("../assets/lab.zig");
const camera = @import("../render/backends/software/camera.zig");

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "player bullets projectiles armor impulse blood and health feedback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const State = struct {
        health_bits: u32,
        damage_stat: i32,
        flash: i32,
        flash_time: u32,
        flash_red: u8,
        velocity_bits: [3]u32,
        yaw: i16,
        armor: ?i32,
        selected: usize,
        blood: []const [3]u32,
        events: []const [4]u32,
    };
    const Config = struct { velocity: [3]f32, position: [3]f32, yaw: i16, mass: f32 = 150, health: f32 = 10, flags: u32 = 0, sheriff: u8 = 0, damage_multiplier: f32 = 1, armor: ?i32 = null };
    const Case = struct { name: []const u8, config: Config, shot: shooting.DamageInput, state: State };
    const Corpus = struct { executable_sha256: []const u8, sha256: []const u8, cases: []const Case };
    const corpus = (try std.json.parseFromSlice(Corpus, a, try read(a, "testdata/player-shot-damage-reference.json"), .{ .ignore_unknown_fields = true })).value;
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", corpus.executable_sha256);
    try std.testing.expectEqualStrings("abcc540cc9b2ab5d3a5ba2350d0c13a9884b3ef1576f58bf86f7f3c7d5757ef9", corpus.sha256);
    const system = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB"));
    const objects = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/OLOBJ.LAB"));
    var item = try Item.parse(a, try objects.find("CIDJAMES.ITM", 0));
    defer item.deinit();
    const physics = try movement.Physics.parse(try system.find("AIR.PHY", 0));
    const audio_config = try player_audio.Config.fromItem(&item);
    const angles = camera.Angles.init();
    var effects_buffer: inventory_module.EffectBuffer = undefined;
    var effects = inventory_module.Effects.init(&effects_buffer);
    for (corpus.cases) |case| {
        errdefer std.debug.print("reference player shot case {s}\n", .{case.name});
        const config = case.config;
        var player = try movement.Player.init(&item, physics, .{ .sector = 0, .position = .{ .x = config.position[0], .y = config.position[1], .z = config.position[2] }, .rotation = .{ .x = 0, .y = 0, .z = 0 } });
        player.yaw = config.yaw;
        player.velocity = .{ .x = config.velocity[0], .y = config.velocity[1], .z = config.velocity[2] };
        player.flags = config.flags;
        var inventory = inventory_module.Inventory{ .health = config.health, .player_flags = config.flags, .sheriff_active = config.sheriff != 0 };
        if (config.armor) |count| {
            inventory.slots[1] = .{ .definition = std.mem.zeroInit(inventory_module.Definition, .{ .function = .generic_object, .item_class = @as(u32, 0x41524d52) }), .count = count };
            inventory.selected = 1;
        }
        var flash: flash_module.State = .{};
        var audio_state: player_audio.State = .{};
        var audio = player_audio.Context{ .config = &audio_config, .state = &audio_state, .effects = &effects };
        effects.clearRetainingCapacity();
        var shot_config = try shot_damage.Config.fromItem(&item);
        shot_config.mass = config.mass;
        shot_config.multiplier = config.damage_multiplier;
        const blood = try shot_damage.apply(&shot_config, &angles, &player, &inventory, case.shot, &flash, &audio, 1000);
        var blood_bits: [1][3]u32 = undefined;
        if (blood) |position| blood_bits[0] = .{ @bitCast(position.x), @bitCast(position.y), @bitCast(position.z) };
        var events: [4][4]u32 = undefined;
        var event_count: usize = 0;
        var message_count: usize = 0;
        for (effects.items) |effect| switch (effect) {
            .message => |message| {
                try std.testing.expectEqual(@as(i32, if (case.shot.kind >= 3) 58 else 54), message.index);
                try std.testing.expect(message.routed);
                message_count += 1;
            },
            .sound => |sound| {
                const id: u32 = if (std.ascii.eqlIgnoreCase(sound.basename, "jadie.wav")) 8 else if (std.ascii.eqlIgnoreCase(sound.basename, "gotshot.wav")) 9 else if (std.ascii.eqlIgnoreCase(sound.basename, "armor1.wav")) 10 else if (std.ascii.eqlIgnoreCase(sound.basename, "armor2.wav")) 11 else if (std.ascii.eqlIgnoreCase(sound.basename, "armor3.wav")) 12 else return error.UnexpectedPlayerShotSound;
                events[event_count] = .{ id, @bitCast(sound.priority.?), @bitCast(sound.volume.?), sound.flags.? };
                event_count += 1;
            },
        };
        try std.testing.expectEqual(@as(usize, if (inventory.health == 0 and case.shot.kind != 2) 1 else 0), message_count);
        const actual = State{ .health_bits = @bitCast(inventory.health), .damage_stat = inventory.statistics.damage, .flash = flash.strength, .flash_time = flash.last_ms, .flash_red = flash.alpha, .velocity_bits = .{ @bitCast(player.velocity.x), @bitCast(player.velocity.y), @bitCast(player.velocity.z) }, .yaw = player.yaw, .armor = if (inventory.slots[1]) |armor| armor.count else null, .selected = inventory.selected, .blood = blood_bits[0..@as(usize, if (blood != null) 1 else 0)], .events = events[0..event_count] };
        try std.testing.expectEqualDeep(case.state, actual);
    }
}
