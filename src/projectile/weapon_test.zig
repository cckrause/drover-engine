//! A charged weapon: the callbacks while charging and what release does.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const lab = @import("../assets/lab.zig");
const inventory_module = @import("../player/inventory.zig");
const weapon = @import("../player/weapon.zig");
const runtime = @import("runtime.zig");
const Item = @import("../assets/item.zig").Item;
const nwx = @import("../assets/nwx.zig");
const input = @import("../player/input.zig");
const movement = @import("../player/movement.zig");
const camera = @import("../render/backends/software/camera.zig");
const Actor = @import("../render/objects.zig").Actor;
const Vec3 = @import("../assets/level.zig").Vec3;
const script = @import("../script/runtime.zig");

const Bubble = struct { sector: usize, position: [3]u32, count: i32 };

const Capture = struct {
    a: std.mem.Allocator,
    configs: [2]*const runtime.Config,
    random: *u32,
    angles: *const camera.Angles,
    actors: std.ArrayList(struct { actor: Actor, state: runtime.State }) = .empty,
    creates: std.ArrayList([10]u32) = .empty,
    launches: std.ArrayList([2]u32) = .empty,
    bubbles: std.ArrayList(Bubble) = .empty,

    fn create(
        raw: *anyopaque,
        descriptor: runtime.Descriptor,
        _: *inventory_module.Effects,
    ) anyerror!usize {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const config = self.configs[
            if (std.ascii.eqlIgnoreCase(
                descriptor.item,
                "PKNIFE",
            )) @as(usize, 0) else 1
        ];

        var actor: Actor = .{
            .position = descriptor.origin,
            .sector = descriptor.sector,
            .yaw = 0,
            .flags = 0x8000000f,
            .secondary_flags = 0x420,
            .scale_x = 1,
            .scale_y = 1,
            .height = 0,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
        };

        const state = runtime.initialize(&actor, config, descriptor, 0);
        const source = self.actors.items.len;

        try self.actors.append(self.a, .{ .actor = actor, .state = state });
        try self.creates.append(
            self.a,
            .{
                @intFromEnum(descriptor.kind),
                0,
                @bitCast(descriptor.damage),
                @bitCast(descriptor.mass),
                @bitCast(descriptor.rate),
                @bitCast(descriptor.range),
                @bitCast(descriptor.origin.x),
                @bitCast(descriptor.origin.y),
                @bitCast(descriptor.origin.z),
                @as(
                    u32,
                    @as(u16, @bitCast(descriptor.pitch)),
                ) | (@as(u32, @as(u16, @bitCast(descriptor.yaw))) << 16),
            },
        );

        return source;
    }

    fn launch(raw: *anyopaque, source: usize, owner: runtime.Owner, fraction: f32) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const value = &self.actors.items[source];
        try runtime.launch(&value.actor, &value.state, owner, fraction, self.angles, self.random);
        try self.launches.append(self.a, .{ @intCast(source), @bitCast(fraction) });
    }

    fn bubble(
        raw: *anyopaque,
        _: *script.Context,
        sector: usize,
        position: Vec3,
        count: i32,
    ) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        try self.bubbles.append(
            self.a,
            .{
                .sector = sector,
                .position = .{ @bitCast(position.x), @bitCast(position.y), @bitCast(position.z) },
                .count = count,
            },
        );
    }
};

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

test "projectile charged weapon callbacks and release match 400 reference frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Frame = struct {
        now: u32,
        messages: []u32,
        state: [7]i32,
        playback: [7]u32,
        loaded: i32,
        random: u32,
        crt_random: u32,
        shots: [][11]u32,
        sounds: [][]const u8,
        count: i32,
        held: ?usize,
        fraction: u32,
        charge_started: u32,
        creates: [][10]u32,
        launches: [][2]u32,
        bubbles: []Bubble,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct { slot: usize, underwater: bool, frames: []Frame },
    };

    const corpus = (try std.json.parseFromSlice(
        Corpus,
        a,
        try read(a, "testdata/projectile-weapons-reference.json"),
        .{ .ignore_unknown_fields = true },
    )).value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        corpus.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "8e30ad98a8bb5077f74db5918ffd13cf1812348c3be5f63f4e6bf35b16a34ece",
        corpus.results_sha256,
    );

    var archives: [3]lab.Archive = undefined;

    for ([_][]const u8{
        "OUTLAWS",
        "OLOBJ",
        "OLWEAP",
    }, &archives) |name, *archive| archive.* = try lab.Archive.init(
        try read(a, try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name})),
    );

    var cid = try Item.parse(a, try archives[1].find("CIDJAMES.ITM", 0));
    const physics = try movement.Physics.parse(try archives[0].find("AIR.PHY", 0));
    var player = try movement.Player.init(
        &cid,
        physics,
        .{
            .sector = 0,
            .position = .{ .x = 322.36, .y = 0, .z = 271.88 },
            .rotation = .{ .x = 0, .y = 0, .z = 0 },
        },
    );

    player.yaw = 8035;

    const angles = camera.Angles.init();
    var configs: [2]*const runtime.Config = undefined;

    for ([_][]const u8{ "PKNIFE", "PDYNAM" }, &configs) |name, *config| {
        var item = try Item.parse(
            a,
            try archives[2].find(try std.fmt.allocPrint(a, "{s}.ITM", .{name}), 0),
        );

        const value = try a.create(runtime.Config);

        value.* = try runtime.Config.load(a, &item, name);
        config.* = value;
    }

    for (corpus.cases) |case| {
        var inventory = try inventory_module.Inventory.init(a, &archives, &cid);

        _ = try inventory.acquire(
            try inventory_module.Definition.load(
                a,
                &archives,
                if (case.slot == 7) "IDYNAM" else "IKNIFE",
            ),
            0,
        );

        inventory.selected_weapon = case.slot;
        inventory.slots[case.slot].?.count = 8;

        var costume = try nwx.Costume.parse(
            a,
            try archives[2].find(inventory.slots[case.slot].?.definition.costume, 0),
        );

        var state: weapon.State = .{};
        var random: u32 = 0x742389ac;
        var effects_buffer: inventory_module.EffectBuffer = undefined;
        var effects = inventory_module.Effects.init(&effects_buffer);
        var shots_buffer: weapon.ShotBuffer = undefined;
        var shots = weapon.Shots.init(&shots_buffer);
        var capture: Capture = .{
            .a = a,
            .configs = configs,
            .random = &random,
            .angles = &angles,
        };

        var contact_state: @import("../script/cmm.zig").ContactState = .{};
        const native: script.Context = .{
            .inventory = &inventory,
            .pickups = &.{},
            .removed = &.{},
            .now_ms = 0,
            .effects = &effects,
            .contact_state = &contact_state,
            .bubble_host = .{ .context = &capture, .spawn = Capture.bubble },
        };

        var context: weapon.Context = .{
            .state = &state,
            .inventory = &inventory,
            .player = &player,
            .random = &random,
            .effects = &effects,
            .shots = &shots,
            .now = 0,
            .ready = true,
            .angles = &angles,
            .underwater = case.underwater,
            .projectile_sink = .{
                .context = &capture,
                .create = Capture.create,
                .launch = Capture.launch,
            },
            .bubble_context = native,
        };

        var playback: nwx.Playback = .{};

        try playback.select(&costume, 0, 0, &context);
        try context.tick(&playback, &costume);

        for (case.frames) |frame| {
            errdefer std.debug.print(
                "charged slot{d} underwater{} time{d}\n",
                .{ case.slot, case.underwater, frame.now },
            );

            effects.clearRetainingCapacity();
            shots.clearRetainingCapacity();
            capture.creates.clearRetainingCapacity();
            capture.launches.clearRetainingCapacity();
            capture.bubbles.clearRetainingCapacity();

            context.now = frame.now;
            try playback.advanceWithContext(&costume, 0, frame.now, &context);
            var packet: input.Packet = .{};

            for (frame.messages) |message| packet.entries[
                @intFromEnum(
                    if (message == 0x69 or message == 0x6a) input.Slot.fire else input.Slot.fire_big,
                )
            ].flags = if (message & 1 != 0) input.pressed else input.released;

            try context.inputPacket(&playback, &costume, &packet);
            try context.tick(&playback, &costume);

            try std.testing.expectEqualDeep(
                frame.state,
                [7]i32{
                    state.action,
                    state.pending,
                    @intFromBool(state.ended),
                    @intFromBool(state.released),
                    @intFromBool(state.did_fire),
                    @intFromBool(state.did_finish),
                    @intFromBool(state.scope),
                },
            );

            try std.testing.expectEqualDeep(
                frame.playback,
                [7]u32{
                    playback.last_time,
                    @bitCast(@as(i32, playback.angle_offset)),
                    playback.direction,
                    playback.choreography,
                    playback.next_frame,
                    playback.frame,
                    playback.flags,
                },
            );

            try std.testing.expectEqual(frame.loaded, inventory.slots[case.slot].?.loaded);
            try std.testing.expectEqual(frame.count, inventory.slots[case.slot].?.count);
            try std.testing.expectEqual(frame.held, state.held_projectile);
            try std.testing.expectEqual(frame.fraction, @as(u32, @bitCast(state.throw_fraction)));
            try std.testing.expectEqual(frame.charge_started, state.charge_started);
            try std.testing.expectEqual(frame.random, random);
            try std.testing.expectEqual(frame.crt_random, state.crt_random);
            try std.testing.expectEqualDeep(frame.creates, capture.creates.items);
            try std.testing.expectEqualDeep(frame.launches, capture.launches.items);
            try std.testing.expectEqualDeep(frame.bubbles, capture.bubbles.items);
            try std.testing.expectEqual(frame.shots.len, shots.items.len);

            var inserted: usize = 0;

            for (shots.items) |shot| if (shot.hit_sound) |sound| {
                try effects.insert(sound.effect_index + inserted, .{ .sound = sound.request });
                inserted += 1;
            };

            try std.testing.expectEqual(frame.sounds.len, effects.items.len);

            for (frame.sounds, effects.items) |sound, effect| try std.testing.expect(
                std.ascii.eqlIgnoreCase(
                    std.fs.path.stem(sound),
                    std.fs.path.stem(effect.sound.basename),
                ),
            );
        }
    }
}
