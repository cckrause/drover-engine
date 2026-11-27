//! Network messages: the address word every message starts with, the
//! 16-byte header, and the message numbers.
//!
//! Messages are byte buffers, exactly as the router copies them and the
//! driver sends them, so layout is wire format. An address of all 0xff
//! means "no address".

const std = @import("std");

pub const Address = [16]u8;

pub const no_address: Address = @splat(0xff);

pub const header_size = 0x10;

pub const destination_offset = 0;

pub const sender_offset = 4;

pub const reply_offset = 8;

pub const number_offset = 0xc;

pub const words_size = 0x1c;

pub const word_offsets = [3]usize{ 0x10, 0x14, 0x18 };

pub const damage_size = 0x36;

pub const corpse_capacity = 0x20 + 0x100;

pub const comment_capacity = header_size + 0x180;

pub const frag_update_capacity = 0x18 + 4 * 256;

pub const configuration_size = 0x14;

pub const server_critical_size = 0x18;

pub const object_list_capacity = 0x12 + 2 * 200;

pub const end_level_capacity = header_size + 8;

pub const game_info_capacity = 0x1c + 24;

pub const Start = [7]u32;

pub const start_size = 0x2c;

pub const start_request_size = 0x11;

pub const join_capacity = 0x34 + 0x80;

pub const client_name_limit = 99;

pub const client_address_capacity = 0x24 + client_name_limit + 1;

pub const reject_text_limit = 0x28 - 1;

pub const reject_capacity = header_size + 0x40;

pub const names = [_][]const u8{
    "NULL",                      "RequestClientID",         "FreeClientID",         "RequestGameInfo",
    "SetGameInfo",               "RequestRedWonLevel",      "RequestBlueWonLevel",  "RequestEndLevel",
    "RequestEndGame",            "RequestStartPosition",    "SetStartPosition",     "AddStartPosition",
    "RequestNewIt",              "RequestNewChickenHolder", "MakeMeACorpse",        "SetClientAddress",
    "MultiplexPacket",           "HealthPacket",            "GetClientData",        "RejectJoin",
    "ActorSetPos",               "ActorCreateNew",          "ActorRequestCreate",   "ActorDelete",
    "WallSetNID",                "SectorSetNID",            "ObjectRequest",        "ActorSetChor",
    "EndLevel",                  "EndGame",                 "SetClientGameInfo",    "StartHere",
    "PostFragDelta",             "PostFragUpdate",          "PostComment",          "PostCheat",
    "ActorUseObject",            "InstantActor",            "FXSpawn",              "SetNewIt",
    "SetNewChickenHolder",       "AskForLogicPermission",   "GrantLogicPermission", "CreateCorpse",
    "ObjectList",                "HaveServerCreateObject",  "QueryLagTime",         "ResponseLagTime",
    "PostNewLinearDeadReckInfo", "PostArchitectureChanges", "WallMessage",          "SetAtxState100",
    "PlaySoundActor",            "PlaySoundPosition",       "StopSound",            "SetGameConfiguration",
    "ResetCTFGame",              "Explosion",               "ShatterWall",          "ServerCritical",
};

pub const actor_create_capacity = 0x68 + 3 * 0x100;

pub const Queue = struct {
    pub const database: u4 = 0;

    pub const server: u4 = 2;

    pub const router: u4 = 3;

    pub const dead_reckoning: u4 = 4;
};

pub const HaveServerCreate = struct {
    sector: u16,
    position: [3]u32,
    kind: u32,
    name: []const u8,
};

pub const Damage = struct {
    kind: u32,
    damage: f32,
    mass: f32,
    speed: f32,
    yaw: i16,
    pitch: i16,
    position: [3]f32,
    lateral: f32,
    height: f32,
};

pub const FragDelta = struct { client: u32, team: u32, points: u32 };

pub const Corpse = struct {
    choreography: u16,
    sector: u16,
    position: [3]u32,
    costume: []const u8,
};

pub const WallIndex = struct { sector: u16, wall: u16 };

pub const Score = struct { points: i16 = 0, seconds: i16 = 0 };

pub const GameRecord = extern struct {
    checksum: u32 = 0,
    flags: u32 = 0,
    game_type: u32 = 0,
    mode: u32 = 0,
    parameter: u32 = 0,
    filename: [24]u8 = @splat(0),

    pub fn name(self: *const GameRecord) []const u8 {
        return std.mem.sliceTo(&self.filename, 0);
    }
};

pub const Join = struct {
    address: Address,
    name: []const u8,
    tag_and_password: []const u8,
};

pub const ClientAddress = struct {
    client: u32,
    address: Address,
    name: []const u8,
};

pub const Maintenance = struct {
    last: u32 = 0,
    announce: u32 = 0,
    critical: u32 = 0,
    object_list: u32 = 0,
    architecture: u32 = 0,
    scores: u32 = 0,
    configuration: u32 = 0,

    pub const Tasks = struct {
        context: *anyopaque,
        player: *const fn (context: *anyopaque, now: u32) anyerror!bool,
        announce: *const fn (context: *anyopaque) anyerror!void,
        critical: *const fn (context: *anyopaque) anyerror!void,
        object_list: *const fn (context: *anyopaque) anyerror!void,
        architecture: *const fn (context: *anyopaque) anyerror!void,
        scores: *const fn (context: *anyopaque) anyerror!void,
        configuration: *const fn (context: *anyopaque) anyerror!void,
    };

    pub fn run(
        self: *Maintenance,
        now: u32,
        game_type: u32,
        level_loaded: bool,
        tasks: Tasks,
    ) !void {
        if (game_type != 4 and game_type != 5) return;
        if (now < self.last +% 0x14d) return;
        if (try tasks.player(tasks.context, now)) {
            self.last = now;
            return;
        }

        if (self.announce < now) {
            self.announce = now +% 5000;
            try tasks.announce(tasks.context);
            self.last = now;
            return;
        }

        if (game_type == 4 or !level_loaded) return;

        for ([_]struct { *u32, u32, *const fn (*anyopaque) anyerror!void }{
            .{ &self.critical, 0xdac, tasks.critical },
            .{ &self.object_list, 0x1d4c, tasks.object_list },
            .{ &self.architecture, 15000, tasks.architecture },
            .{ &self.scores, 5000, tasks.scores },
            .{ &self.configuration, 10000, tasks.configuration },
        }) |task| {
            if (task[0].* < now) {
                task[0].* = now +% task[1];
                try task[2](tasks.context);
                self.last = now;
                return;
            }
        }
    }
};

pub const ActorCreate = struct {
    sector: u16,
    animation: u16,
    number: u32,
    flags: u32,
    position: [3]u32,
    angles: [3]i16,
    kind: u16,
    short_70: u16,
    short_72: u16,
    word_74: u32,
    words_7c: [6]u32,
    word_3c: u32,
    word_94: u32,
    words_40: [3]u32,
    entity: u32,
    costume: []const u8,
    logic: []const u8,
    item: []const u8,
};

pub fn isNone(address: *const Address) bool {
    for (address) |byte| if (byte != 0xff) return false;

    return true;
}

pub fn client(word: u32) u8 {
    return @truncate((word & 0x7f800) >> 11);
}

pub fn queue(word: u32) u4 {
    return @truncate((word & 0x780000) >> 19);
}

pub fn addressWord(queue_index: u4, client_number: u8) u32 {
    return (@as(u32, queue_index) << 8 | client_number) << 11;
}

pub fn get(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn set(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

pub fn request(number: u32, own_client: u32) [header_size]u8 {
    var bytes: [header_size]u8 = @splat(0);
    set(&bytes, sender_offset, addressWord(Queue.router, @truncate(own_client)));
    set(&bytes, number_offset, number);

    return bytes;
}

pub fn words(number: u32, own_client: u32, values: [3]u32) [words_size]u8 {
    var bytes: [words_size]u8 = @splat(0);
    @memcpy(bytes[0..header_size], &request(number, own_client));
    for (word_offsets, values) |offset, value| set(&bytes, offset, value);

    return bytes;
}

pub fn objectRequest(number: u32, own_client: u32) [header_size]u8 {
    var bytes = request(number, own_client);
    set(&bytes, sender_offset, addressWord(Queue.database, @truncate(own_client)));

    return bytes;
}

pub fn haveServerCreate(buffer: []u8, own_client: u32, value: HaveServerCreate) ![]u8 {
    if (value.name.len > std.math.maxInt(usize) - 0x23 or
        buffer.len < value.name.len + 0x23 or
        std.mem.indexOfScalar(u8, value.name, 0) != null) return error.MalformedNetworkMessage;

    const bytes = buffer[0 .. value.name.len + 0x23];

    @memcpy(bytes[0..header_size], &objectRequest(0x415, own_client));
    std.mem.writeInt(u16, bytes[0x10..0x12], value.sector, .little);

    for (value.position, 0..) |word, index| set(bytes, 0x12 + 4 * index, word);

    set(bytes, 0x1e, value.kind);
    @memcpy(bytes[0x22..][0..value.name.len], value.name);
    bytes[0x22 + value.name.len] = 0;

    return bytes;
}

pub fn readHaveServerCreate(bytes: []const u8) !HaveServerCreate {
    if (bytes.len < 0x23) return error.MalformedNetworkMessage;

    const end = std.mem.indexOfScalar(
        u8,
        bytes[0x22..],
        0,
    ) orelse return error.MalformedNetworkMessage;

    return .{
        .sector = std.mem.readInt(u16, bytes[0x10..0x12], .little),
        .position = .{ get(bytes, 0x12), get(bytes, 0x16), get(bytes, 0x1a) },
        .kind = get(bytes, 0x1e),
        .name = bytes[0x22 .. 0x22 + end],
    };
}

pub fn damage(own_client: u32, value: Damage) [damage_size]u8 {
    var bytes: [damage_size]u8 = @splat(0);
    @memcpy(bytes[0..header_size], &objectRequest(0x7d1, own_client));
    std.mem.writeInt(u16, bytes[0x10..0x12], @truncate(value.kind), .little);

    for ([_]usize{
        0x12,
        0x16,
        0x1a,
        0x22,
        0x26,
        0x2a,
        0x2e,
        0x32,
    }, [_]f32{
        value.damage,
        value.mass,
        value.speed,
        value.position[0],
        value.position[1],
        value.position[2],
        value.lateral,
        value.height,
    }) |offset, word| set(&bytes, offset, @bitCast(word));

    std.mem.writeInt(i16, bytes[0x1e..0x20], value.yaw, .little);
    std.mem.writeInt(i16, bytes[0x20..0x22], value.pitch, .little);

    return bytes;
}

pub fn readDamage(bytes: []const u8) !Damage {
    if (bytes.len < damage_size) return error.MalformedNetworkMessage;

    return .{
        .kind = std.mem.readInt(u16, bytes[0x10..0x12], .little),
        .damage = @bitCast(get(bytes, 0x12)),
        .mass = @bitCast(get(bytes, 0x16)),
        .speed = @bitCast(get(bytes, 0x1a)),
        .yaw = std.mem.readInt(i16, bytes[0x1e..0x20], .little),
        .pitch = std.mem.readInt(i16, bytes[0x20..0x22], .little),
        .position = .{
            @bitCast(get(bytes, 0x22)),
            @bitCast(get(bytes, 0x26)),
            @bitCast(get(bytes, 0x2a)),
        },
        .lateral = @bitCast(get(bytes, 0x2e)),
        .height = @bitCast(get(bytes, 0x32)),
    };
}

pub fn fragDelta(own_client: u32, value: FragDelta) [words_size]u8 {
    var bytes = words(0x408, own_client, .{ value.client, value.team, value.points });
    @memcpy(bytes[0..header_size], &objectRequest(0x408, own_client));

    return bytes;
}

pub fn readFragDelta(bytes: []const u8) !FragDelta {
    if (bytes.len < words_size) return error.MalformedNetworkMessage;

    return .{ .client = get(bytes, 0x10), .team = get(bytes, 0x14), .points = get(bytes, 0x18) };
}

pub fn corpse(buffer: *[corpse_capacity]u8, number: u32, own_client: u32, value: Corpse) ![]u8 {
    if (value.costume.len >= 0x100 or std.mem.indexOfScalar(
        u8,
        value.costume,
        0,
    ) != null) return error.MalformedNetworkMessage;

    const bytes = buffer[0 .. 0x21 + value.costume.len];

    @memset(bytes, 0);
    @memcpy(bytes[0..header_size], &request(number, own_client));

    std.mem.writeInt(u16, bytes[0x10..0x12], value.choreography, .little);
    std.mem.writeInt(u16, bytes[0x12..0x14], value.sector, .little);

    for (value.position, 0..) |word, index| set(bytes, 0x14 + 4 * index, word);

    @memcpy(bytes[0x20..][0..value.costume.len], value.costume);

    return bytes;
}

pub fn readCorpse(bytes: []const u8) !Corpse {
    if (bytes.len < 0x21) return error.MalformedNetworkMessage;

    const end = std.mem.indexOfScalar(
        u8,
        bytes[0x20..],
        0,
    ) orelse return error.MalformedNetworkMessage;

    if (end >= 0x100) return error.MalformedNetworkMessage;

    return .{
        .choreography = std.mem.readInt(u16, bytes[0x10..0x12], .little),
        .sector = std.mem.readInt(u16, bytes[0x12..0x14], .little),
        .position = .{ get(bytes, 0x14), get(bytes, 0x18), get(bytes, 0x1c) },
        .costume = bytes[0x20 .. 0x20 + end],
    };
}

pub fn impulse(own_client: u32, velocity: [3]f32) [words_size]u8 {
    var bytes = words(
        0x7d2,
        own_client,
        .{ @bitCast(velocity[0]), @bitCast(velocity[1]), @bitCast(velocity[2]) },
    );

    @memcpy(bytes[0..header_size], &objectRequest(0x7d2, own_client));

    return bytes;
}

pub fn choreography(own_client: u32, value: u32) [0x12]u8 {
    var bytes: [0x12]u8 = @splat(0);
    @memcpy(bytes[0..header_size], &objectRequest(0x403, own_client));
    std.mem.writeInt(u16, bytes[0x10..0x12], @truncate(value), .little);

    return bytes;
}

pub fn shatterWall(own_client: u32, sector: u16, wall: u16) [0x14]u8 {
    var bytes: [0x14]u8 = @splat(0);
    @memcpy(bytes[0..header_size], &objectRequest(0x422, own_client));

    std.mem.writeInt(u16, bytes[0x10..0x12], sector, .little);
    std.mem.writeInt(u16, bytes[0x12..0x14], wall, .little);

    return bytes;
}

pub fn readShatterWall(bytes: []const u8) !WallIndex {
    if (bytes.len < 0x14) return error.MalformedNetworkMessage;

    return .{
        .sector = std.mem.readInt(u16, bytes[0x10..0x12], .little),
        .wall = std.mem.readInt(u16, bytes[0x12..0x14], .little),
    };
}

pub fn readChoreography(bytes: []const u8) !u32 {
    if (bytes.len < 0x12) return error.MalformedNetworkMessage;

    return std.mem.readInt(u16, bytes[0x10..0x12], .little);
}

pub fn fragUpdate(
    buffer: *[frag_update_capacity]u8,
    own_client: u32,
    teams: *const [2]i16,
    scores: []const Score,
) []u8 {
    std.debug.assert(scores.len <= 256);
    @memcpy(buffer[0..header_size], &objectRequest(0x409, own_client));

    std.mem.writeInt(u16, buffer[0x10..0x12], teams.len, .little);
    std.mem.writeInt(u16, buffer[0x12..0x14], @intCast(scores.len), .little);

    for (teams, 0..) |team, index| std.mem.writeInt(
        i16,
        buffer[0x14 + 2 * index ..][0..2],
        team,
        .little,
    );

    for (scores, 0..) |score, index| {
        std.mem.writeInt(i16, buffer[0x18 + 4 * index ..][0..2], score.points, .little);
        std.mem.writeInt(i16, buffer[0x1a + 4 * index ..][0..2], score.seconds, .little);
    }

    return buffer[0 .. (teams.len + scores.len) * 4 + 0x10];
}

pub fn configuration(own_client: u32, bits: u32) [configuration_size]u8 {
    var bytes: [configuration_size]u8 = @splat(0);
    @memcpy(bytes[0..header_size], &request(0x41f, own_client));
    set(&bytes, 0x10, bits);

    return bytes;
}

pub fn readConfiguration(bytes: []const u8) !u32 {
    if (bytes.len < configuration_size) return error.MalformedNetworkMessage;

    return get(bytes, 0x10);
}

pub fn serverCritical(own_client: u32, mode: u32) ![server_critical_size]u8 {
    if (mode >= 1 and mode <= 3) return error.ServerCriticalModeNotPorted;
    var bytes: [server_critical_size]u8 = @splat(0);
    @memcpy(bytes[0..header_size], &request(0x423, own_client));

    return bytes;
}

pub fn objectList(buffer: *[object_list_capacity]u8, own_client: u32, entries: []const u16) []u8 {
    std.debug.assert(entries.len <= 200);
    @memcpy(buffer[0..header_size], &objectRequest(0x414, own_client));
    std.mem.writeInt(u16, buffer[0x10..0x12], @intCast(entries.len), .little);

    for (entries, 0..) |entry, index| std.mem.writeInt(
        u16,
        buffer[0x12 + 2 * index ..][0..2],
        entry,
        .little,
    );

    return buffer[0 .. entries.len * 2 + 0x12];
}

pub fn comment(buffer: []u8, own_client: u32, value: []const u8) ![]u8 {
    if (buffer.len < header_size + value.len + 1 or std.mem.indexOfScalar(
        u8,
        value,
        0,
    ) != null) return error.MalformedNetworkMessage;

    @memcpy(buffer[0..header_size], &objectRequest(0x40a, own_client));
    @memcpy(buffer[header_size..][0..value.len], value);

    buffer[header_size + value.len] = 0;

    return buffer[0 .. header_size + value.len + 1];
}

pub fn readComment(bytes: []const u8) ![]const u8 {
    if (bytes.len <= header_size) return error.MalformedNetworkMessage;

    const length = std.mem.indexOfScalar(
        u8,
        bytes[header_size..],
        0,
    ) orelse return error.MalformedNetworkMessage;

    return bytes[header_size..][0..length];
}

pub fn endLevel(buffer: *[end_level_capacity]u8, own_client: u32, text: []const u8) []u8 {
    std.debug.assert(text.len < end_level_capacity - header_size);
    @memcpy(buffer[0..header_size], &request(0x404, own_client));
    set(buffer, sender_offset, addressWord(Queue.database, @truncate(own_client)));
    @memcpy(buffer[header_size..][0..text.len], text);
    buffer[header_size + text.len] = 0;

    return buffer[0 .. header_size + text.len + 1];
}

pub fn gameInfo(
    buffer: *[game_info_capacity]u8,
    number: u32,
    own_client: u32,
    record: *const GameRecord,
) ![]u8 {
    const text = std.mem.indexOfScalar(
        u8,
        &record.filename,
        0,
    ) orelse return error.MalformedNetworkMessage;

    @memset(buffer, 0);
    @memcpy(buffer[0..header_size], &request(number, own_client));

    set(buffer, 0x10, record.flags);
    set(buffer, 0x14, record.parameter);
    std.mem.writeInt(u16, buffer[0x18..0x1a], @truncate(record.game_type), .little);
    std.mem.writeInt(u16, buffer[0x1a..0x1c], @truncate(record.mode), .little);

    @memcpy(buffer[0x1c..][0 .. text + 1], record.filename[0 .. text + 1]);

    return buffer[0 .. 0x1c + text + 1];
}

pub fn readGameInfo(bytes: []const u8, record: *GameRecord) !void {
    if (bytes.len < 0x1d) return error.MalformedNetworkMessage;

    const text = std.mem.indexOfScalar(
        u8,
        bytes[0x1c..],
        0,
    ) orelse return error.MalformedNetworkMessage;

    if (text >= record.filename.len) return error.MalformedNetworkMessage;

    record.flags = get(bytes, 0x10);
    record.parameter = get(bytes, 0x14);
    record.game_type = std.mem.readInt(u16, bytes[0x18..0x1a], .little);
    record.mode = std.mem.readInt(u16, bytes[0x1a..0x1c], .little);

    @memcpy(record.filename[0 .. text + 1], bytes[0x1c..][0 .. text + 1]);
}

pub fn start(number: u32, own_client: u32, record: Start) [start_size]u8 {
    var bytes: [start_size]u8 = @splat(0);
    @memcpy(bytes[0..header_size], &request(number, own_client));
    for (record, 0..) |value, index| set(&bytes, header_size + 4 * index, value);

    return bytes;
}

pub fn readStart(bytes: []const u8) !Start {
    if (bytes.len < start_size) return error.MalformedNetworkMessage;

    var record: Start = undefined;

    for (&record, 0..) |*value, index| value.* = get(bytes, header_size + 4 * index);

    for (record[1..]) |word| if (!std.math.isFinite(
        @as(f32, @bitCast(word)),
    )) return error.MalformedNetworkMessage;

    return record;
}

pub fn startRequest(own_client: u32, team: u8) [start_request_size]u8 {
    var bytes: [start_request_size]u8 = @splat(0);
    @memcpy(bytes[0..header_size], &request(0x3f1, own_client));
    bytes[header_size] = team;

    return bytes;
}

pub fn readJoin(bytes: []const u8) !Join {
    if (bytes.len < 0x35) return error.MalformedNetworkMessage;

    const name_length = std.mem.indexOfScalar(
        u8,
        bytes[0x20..],
        0,
    ) orelse return error.MalformedNetworkMessage;

    const tag_length = std.mem.indexOfScalar(
        u8,
        bytes[0x34..],
        0,
    ) orelse return error.MalformedNetworkMessage;

    return .{
        .address = bytes[0x10..0x20].*,
        .name = bytes[0x20..][0..name_length],
        .tag_and_password = bytes[0x34..][0..tag_length],
    };
}

pub fn join(
    buffer: *[join_capacity]u8,
    own_client: u32,
    address: *const Address,
    player: []const u8,
    tag_and_password: []const u8,
) ![]u8 {
    if (0x20 + player.len + 1 > join_capacity or 0x34 + tag_and_password.len + 1 > join_capacity) return error.MalformedNetworkMessage;

    @memset(buffer, 0);
    @memcpy(buffer[0..header_size], &request(0x3e9, own_client));

    buffer[0x10..0x20].* = address.*;
    @memcpy(buffer[0x20..][0..player.len], player);
    buffer[0x20 + player.len] = 0;
    @memcpy(buffer[0x34..][0..tag_and_password.len], tag_and_password);
    buffer[0x34 + tag_and_password.len] = 0;

    return buffer[0 .. 0x34 + tag_and_password.len + 1];
}

pub fn clientAddress(
    buffer: *[client_address_capacity]u8,
    own_client: u32,
    value: ClientAddress,
) ![]u8 {
    if (value.name.len > client_name_limit) return error.MalformedNetworkMessage;

    @memcpy(buffer[0..header_size], &request(0x3f7, own_client));
    set(buffer, 0x10, value.client);
    buffer[0x14..0x24].* = value.address;
    @memcpy(buffer[0x24..][0..value.name.len], value.name);
    buffer[0x24 + value.name.len] = 0;

    return buffer[0 .. 0x24 + value.name.len + 1];
}

pub fn readClientAddress(bytes: []const u8) !ClientAddress {
    if (bytes.len < 0x25) return error.MalformedNetworkMessage;

    const length = std.mem.indexOfScalar(
        u8,
        bytes[0x24..],
        0,
    ) orelse return error.MalformedNetworkMessage;

    const number = get(bytes, 0x10);
    if (number > 0xff) return error.MalformedNetworkMessage;

    return .{ .client = number, .address = bytes[0x14..0x24].*, .name = bytes[0x24..][0..length] };
}

pub fn rejectJoin(buffer: *[reject_capacity]u8, own_client: u32, text: []const u8) ![]u8 {
    if (header_size + text.len + 1 > reject_capacity) return error.MalformedNetworkMessage;

    @memcpy(buffer[0..header_size], &request(0x3fb, own_client));
    @memcpy(buffer[header_size..][0..text.len], text);

    buffer[header_size + text.len] = 0;

    return buffer[0 .. header_size + text.len + 1];
}

pub fn readRejectJoin(bytes: []const u8) ![]const u8 {
    if (bytes.len <= header_size) return error.MalformedNetworkMessage;

    const length = std.mem.indexOfScalar(
        u8,
        bytes[header_size..],
        0,
    ) orelse return error.MalformedNetworkMessage;

    if (length > reject_text_limit) return error.MalformedNetworkMessage;

    return bytes[header_size..][0..length];
}

pub fn name(number: u32, buffer: *[16]u8) []const u8 {
    const signed: i32 = @bitCast(number);
    if (1000 < signed and signed < 0x424) return names[@intCast(signed - 1000)];

    return std.fmt.bufPrint(buffer, "(#{d})", .{signed}) catch unreachable;
}

pub fn actorCreate(buffer: *[actor_create_capacity]u8, own_client: u32, value: ActorCreate) ![]u8 {
    for ([_][]const u8{ value.costume, value.logic, value.item }) |text| {
        if (text.len >= 0x100 or std.mem.indexOfScalar(
            u8,
            text,
            0,
        ) != null) return error.MalformedNetworkMessage;
    }

    @memset(buffer[0..0x68], 0);
    @memcpy(buffer[0..header_size], &objectRequest(0x3fd, own_client));

    std.mem.writeInt(u16, buffer[0x10..0x12], value.sector, .little);
    std.mem.writeInt(u16, buffer[0x12..0x14], value.animation, .little);
    set(buffer, 0x14, value.number);
    set(buffer, 0x18, value.flags);

    for (value.position, 0..) |word, index| set(buffer, 0x1c + 4 * index, word);

    for (value.angles, 0..) |angle, index| std.mem.writeInt(
        i16,
        buffer[0x28 + 2 * index ..][0..2],
        angle,
        .little,
    );

    std.mem.writeInt(u16, buffer[0x2e..0x30], value.kind, .little);
    std.mem.writeInt(u16, buffer[0x30..0x32], value.short_70, .little);
    std.mem.writeInt(u16, buffer[0x32..0x34], value.short_72, .little);
    set(buffer, 0x34, value.word_74);

    for (value.words_7c, 0..) |word, index| set(buffer, 0x38 + 4 * index, word);

    set(buffer, 0x50, value.word_3c);
    set(buffer, 0x54, value.word_94);

    for (value.words_40, 0..) |word, index| set(buffer, 0x58 + 4 * index, word);

    set(buffer, 0x64, value.entity);
    var length: usize = 0x68;

    for ([_][]const u8{ value.costume, value.logic, value.item }) |text| {
        @memcpy(buffer[length..][0..text.len], text);
        buffer[length + text.len] = 0;
        length += text.len + 1;
    }

    return buffer[0..length];
}

pub fn readActorCreate(bytes: []const u8) !ActorCreate {
    if (bytes.len < 0x68) return error.MalformedNetworkMessage;

    var texts: [3][]const u8 = undefined;
    var offset: usize = 0x68;

    for (&texts) |*text| {
        const end = std.mem.indexOfScalarPos(
            u8,
            bytes,
            offset,
            0,
        ) orelse return error.MalformedNetworkMessage;

        text.* = bytes[offset..end];
        offset = end + 1;
    }

    var value: ActorCreate = .{
        .sector = std.mem.readInt(u16, bytes[0x10..0x12], .little),
        .animation = std.mem.readInt(u16, bytes[0x12..0x14], .little),
        .number = get(bytes, 0x14),
        .flags = get(bytes, 0x18),
        .position = .{ get(bytes, 0x1c), get(bytes, 0x20), get(bytes, 0x24) },
        .angles = .{
            std.mem.readInt(i16, bytes[0x28..0x2a], .little),
            std.mem.readInt(i16, bytes[0x2a..0x2c], .little),
            std.mem.readInt(i16, bytes[0x2c..0x2e], .little),
        },
        .kind = std.mem.readInt(u16, bytes[0x2e..0x30], .little),
        .short_70 = std.mem.readInt(u16, bytes[0x30..0x32], .little),
        .short_72 = std.mem.readInt(u16, bytes[0x32..0x34], .little),
        .word_74 = get(bytes, 0x34),
        .words_7c = undefined,
        .word_3c = get(bytes, 0x50),
        .word_94 = get(bytes, 0x54),
        .words_40 = .{ get(bytes, 0x58), get(bytes, 0x5c), get(bytes, 0x60) },
        .entity = get(bytes, 0x64),
        .costume = texts[0],
        .logic = texts[1],
        .item = texts[2],
    };

    for (&value.words_7c, 0..) |*word, index| word.* = get(bytes, 0x38 + 4 * index);

    return value;
}

test "corpse and frag delta wire layouts" {
    var buffer: [corpse_capacity]u8 = undefined;
    const bytes = try corpse(
        &buffer,
        0x3f6,
        3,
        .{
            .choreography = 0x15,
            .sector = 0x1234,
            .position = .{ 1, 2, 3 },
            .costume = "JAMES.NWX",
        },
    );

    try std.testing.expectEqual(@as(usize, 0x20 + 10), bytes.len);
    try std.testing.expectEqual(@as(u32, 0x3f6), get(bytes, number_offset));
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x15, 0, 0x34, 0x12, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0 },
        bytes[0x10..0x20],
    );

    try std.testing.expectEqualSlices(u8, "JAMES.NWX\x00", bytes[0x20..]);
    try std.testing.expectEqualStrings("JAMES.NWX", (try readCorpse(bytes)).costume);
    try std.testing.expectError(
        error.MalformedNetworkMessage,
        readCorpse(bytes[0 .. bytes.len - 1]),
    );

    try std.testing.expectError(
        error.MalformedNetworkMessage,
        corpse(
            &buffer,
            0x3f6,
            3,
            .{
                .choreography = 0,
                .sector = 0,
                .position = @splat(0),
                .costume = &([_]u8{'A'} ** 0x100),
            },
        ),
    );

    const delta = fragDelta(3, .{ .client = 1, .team = 0xffffffff, .points = 1 });

    try std.testing.expectEqual(addressWord(Queue.database, 3), get(&delta, sender_offset));
    try std.testing.expectEqual(@as(u32, 0x408), get(&delta, number_offset));
    try std.testing.expectEqual(
        FragDelta{ .client = 1, .team = 0xffffffff, .points = 1 },
        try readFragDelta(&delta),
    );
}

test "HaveServerCreateObject wire layout" {
    var buffer: [0x26]u8 = undefined;
    const packet = try haveServerCreate(&buffer, 3, .{
        .sector = 0x1234,
        .position = .{ 0x3f800000, 0xc0000000, 0x40500000 },
        .kind = 0x78563412,
        .name = "BOX",
    });

    const expected = [_]u8{
        0,    0,    0,   0,   0,    0x18, 0, 0, 0, 0,    0, 0, 0x15, 4,    0,    0,
        0x34, 0x12, 0,   0,   0x80, 0x3f, 0, 0, 0, 0xc0, 0, 0, 0x50, 0x40, 0x12, 0x34,
        0x56, 0x78, 'B', 'O', 'X',  0,
    };

    try std.testing.expectEqualSlices(u8, &expected, packet);
    const parsed = try readHaveServerCreate(packet);

    try std.testing.expectEqual(@as(u16, 0x1234), parsed.sector);
    try std.testing.expectEqualSlices(u8, "BOX", parsed.name);
    try std.testing.expectError(
        error.MalformedNetworkMessage,
        readHaveServerCreate(packet[0 .. packet.len - 1]),
    );
}

test "network start records reject nonfinite coordinates" {
    var bytes = start(0x407, 1, .{ 1, 0x7fc00000, 0, 0, 0, 0, 0 });
    try std.testing.expectError(error.MalformedNetworkMessage, readStart(&bytes));
}

test "message address word fields" {
    try std.testing.expectEqual(@as(u32, 0x100800), addressWord(Queue.server, 1));
    try std.testing.expectEqual(@as(u32, 0x180800), addressWord(Queue.router, 1));
    try std.testing.expectEqual(@as(u8, 1), client(0x100800));
    try std.testing.expectEqual(@as(u4, 2), queue(0x100800));
    try std.testing.expect(isNone(&no_address));

    var other = no_address;
    other[15] = 0;
    try std.testing.expect(!isNone(&other));
}

test "maintenance runs one task per pass, 333 ms apart, in the documented order" {
    const Log = struct {
        calls: [16]u8 = undefined,
        count: usize = 0,
        player_due: bool = true,

        fn of(context: *anyopaque) *@This() {
            return @ptrCast(@alignCast(context));
        }

        fn note(context: *anyopaque, code: u8) void {
            const self = of(context);
            self.calls[self.count] = code;
            self.count += 1;
        }

        fn player(context: *anyopaque, _: u32) anyerror!bool {
            if (!of(context).player_due) return false;
            of(context).player_due = false;
            note(context, 'p');

            return true;
        }

        fn announce(context: *anyopaque) anyerror!void {
            note(context, 'a');
        }

        fn critical(context: *anyopaque) anyerror!void {
            note(context, 'c');
        }

        fn objectList(context: *anyopaque) anyerror!void {
            note(context, 'o');
        }

        fn architecture(context: *anyopaque) anyerror!void {
            note(context, 'r');
        }

        fn scores(context: *anyopaque) anyerror!void {
            note(context, 's');
        }

        fn configuration(context: *anyopaque) anyerror!void {
            note(context, 'g');
        }
    };

    var log: Log = .{};
    const tasks: Maintenance.Tasks = .{
        .context = &log,
        .player = Log.player,
        .announce = Log.announce,
        .critical = Log.critical,
        .object_list = Log.objectList,
        .architecture = Log.architecture,
        .scores = Log.scores,
        .configuration = Log.configuration,
    };

    var maintenance: Maintenance = .{};

    try maintenance.run(1000, 1, true, tasks);
    try std.testing.expectEqual(@as(usize, 0), log.count);
    var now: u32 = 1000;

    while (now < 4000) : (now += 16) try maintenance.run(now, 5, true, tasks);

    try std.testing.expectEqualStrings("pacorsg", log.calls[0..log.count]);
    var joiner: Maintenance = .{};

    log = .{};
    now = 1000;

    while (now < 4000) : (now += 16) try joiner.run(now, 4, true, tasks);

    try std.testing.expectEqualStrings("pa", log.calls[0..log.count]);
}
