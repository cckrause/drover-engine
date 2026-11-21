//! Exploding objects: the burning fragments they throw.
//!
//! Five random values are consumed per burst, including one that is not
//! used. The sprite instance is unbound and starts from its first frame.

const nwx = @import("../assets/nwx.zig");
const level = @import("../assets/level.zig");
const blood = @import("blood.zig");
const weapon = @import("../player/weapon.zig");
const inventory = @import("../player/inventory.zig");
const enemy_session = @import("session.zig");

pub const costume_name = "FIRE01.NWX";

pub fn spawn(costume: *const nwx.Costume, random: *u32, sector: usize, position: level.Vec3, now: u32) blood.Spawn {
    const vx = @as(f32, @floatFromInt(weapon.randomNext(random) & 7)) - 3.5;
    const vy: f32 = @floatFromInt(weapon.randomNext(random) & 0x15);
    const vz = @as(f32, @floatFromInt(weapon.randomNext(random) & 7)) - 3.5;
    _ = weapon.randomNext(random);
    const scale = @as(f32, @floatFromInt(@as(u16, @truncate(weapon.randomNext(random))))) * 0x1p-16;
    return .{
        .actor = .{ .logic_name = "FX_ExplosionFragment", .costume = costume, .sector = sector, .position = position, .yaw = 0, .flags = 0x8000014f, .secondary_flags = 0x800000, .scale_x = scale, .scale_y = scale, .height = 1, .collision_radius = 1, .choreography = 0, .frame = 0, .angle_offset = 0, .playback = .{ .last_time = now } },
        .state = .{ .velocity = .{ .x = vx, .y = vy, .z = vz } },
    };
}

pub fn burst(session: anytype, effects: *inventory.Effects, sector: usize, position: level.Vec3, now: u32) !void {
    const count = (weapon.randomNext(&session.contact_state.random) & 3) * 2 + 2;
    var request = @import("../audio/request.zig").Request{ .basename = "explode.wav", .priority = 64, .volume = 127, .flags = 4, .sector = sector, .position = position };
    if (session.active_audio) |audio| {
        if (session.active_effects) |pending| try session.drainSounds(pending);
        try session.drainSounds(effects);
        _ = try audio.play(request, session.audioWorld(), now);
        request.delivered = true;
    }
    try effects.append(.{ .sound = request });
    const costume = try enemy_session.costume(session, costume_name);
    for (0..count) |_| {
        const fragment = spawn(costume, &session.contact_state.random, sector, position, now);
        const source = try enemy_session.appendActor(session, fragment.actor, null);
        session.general_slots[source] = fragment.state;
    }
}
