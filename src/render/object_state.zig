//! Creating actors from the level's object records: looking up the item
//! definition, calling its registered factory, and the state the actor
//! starts with.
//!
//! Factory lookup is by exact registered spelling; case is only folded to
//! pick the bucket. An object with no item definition takes the costume-only
//! path and still becomes an actor - nothing is substituted for it.

const std = @import("std");
const level = @import("../assets/level.zig");
const item_module = @import("../assets/item.zig");
const nwx = @import("../assets/nwx.zig");
const objects = @import("objects.zig");

pub const Kind = enum {
    decoration,
    enemy,
    chicken,
    civilian,
    slim,
    sanchez,
    inventory_object,
    ground,
    instant,
    node,
    generator,
};

pub const State = struct {
    sector: usize,
    position: level.Vec3,
    yaw: i16,
    flags: u32,
    secondary_flags: u32,
    scale_x: f32,
    scale_y: f32,
    height: f32,
    collision_radius: f32,
    choreography: u32,
    frame: u32,
    angle_offset: i16,
    playback: ?nwx.Playback,

    pub fn init(object: level.Object, sector: usize, item: ?*const item_module.Item, costume: *const nwx.Costume) !State {
        const kind = try classify(item);
        if (kind == .node or kind == .generator) return error.ObjectFactoryHasNoActor;
        if (costume.frames.len == 0 or costume.frames[0].parts.len == 0) return error.ObjectCostumeHasNoDimensions;
        var result: State = .{
            .sector = sector,
            .position = object.position,
            .yaw = object.angles[1],
            .flags = 0x8000000f,
            .secondary_flags = 0,
            .scale_x = 1,
            .scale_y = 1,
            .height = costume.frames[0].parts[0].height,
            .collision_radius = costume.frames[0].parts[0].width * 0.5,
            .choreography = 0,
            .frame = 0,
            .angle_offset = 0,
            .playback = if (kind == .decoration or kind == .ground or kind == .instant or kind == .inventory_object) .{} else null,
        };
        switch (kind) {
            .decoration => {},
            .enemy, .chicken, .civilian, .slim, .sanchez => {
                const selected = try costume.select(0, 0, 0, 0);
                if (selected.parts.len == 0) return error.ObjectCostumeHasNoDimensions;
                result.height = selected.parts[0].height;
                result.collision_radius = selected.parts[0].width * 0.5;
                result.flags |= 0x40;
                result.secondary_flags = 0x140;
                if (try item.?.stringValue("BOSS") != null) result.secondary_flags |= 0x200000;
                const native = try @import("../script/cmm.zig").resolve(item.?.function);
                if (native == .slim or native == .farmer or native == .dynamite or native == .bob) result.secondary_flags |= 0x200000;
                if (kind == .chicken) result.secondary_flags = 0x4040;
                if (kind == .civilian) result.secondary_flags = 0x04004040;
                if (native == .marshal) result.secondary_flags = 0xc0;
                if (kind == .sanchez) {
                    result.flags = (result.flags & ~@as(u32, 4)) | 0x100;
                    result.secondary_flags |= 0x200000;
                }
            },
            .inventory_object => {
                result.flags |= 0x40;
                result.secondary_flags = 0x400;
                if (try item.?.stringValue("TYPE")) |object_type|
                    result.secondary_flags = if (std.ascii.eqlIgnoreCase(object_type, "SHOOT")) 0x2000 else 0x1000;
            },
            .ground => {
                result.flags |= 0x440;
                result.secondary_flags = 0x400;
            },
            .instant => {
                result.flags |= 0x400;
                result.secondary_flags = 0x400;
            },
            .node, .generator => unreachable,
        }
        if (item) |definition| {
            if (definition.floatValue("HEIGHT")) |height| result.height = height;
            if (definition.floatValue("RADIUS")) |radius| result.collision_radius = radius;
        }
        if (object.flags[0] & 0x10 != 0) result.flags |= 0x400;
        return result;
    }

    pub fn actor(self: State, costume: *const nwx.Costume) objects.Actor {
        return .{
            .costume = costume,
            .sector = self.sector,
            .position = self.position,
            .yaw = self.yaw,
            .flags = self.flags,
            .secondary_flags = self.secondary_flags,
            .scale_x = self.scale_x,
            .scale_y = self.scale_y,
            .height = self.height,
            .collision_radius = self.collision_radius,
            .choreography = self.choreography,
            .frame = self.frame,
            .angle_offset = self.angle_offset,
            .playback = self.playback,
        };
    }
};

pub fn classify(item: ?*const item_module.Item) !Kind {
    const definition = item orelse return .decoration;
    const function = definition.function;
    if (function.len == 0) return .decoration;
    _ = try @import("../script/cmm.zig").resolve(function);
    if (std.mem.eql(u8, function, "Generic_New")) return error.OriginalGenericNullLogic;
    const names = .{
        .{ "BGY_New", Kind.enemy },
        .{ "Bloodeye_New", Kind.enemy },
        .{ "Farmer_New", Kind.enemy },
        .{ "Simms_New", Kind.enemy },
        .{ "Mary_New", Kind.enemy },
        .{ "Bob_New", Kind.enemy },
        .{ "Dynamite_New", Kind.enemy },
        .{ "Marshal_New", Kind.enemy },
        .{ "ShBill_New", Kind.enemy },
        .{ "ShBlood_New", Kind.enemy },
        .{ "ShChez_New", Kind.enemy },
        .{ "ShDick_New", Kind.enemy },
        .{ "ShMary_New", Kind.enemy },
        .{ "Buckshot_New", Kind.enemy },
        .{ "Chicken_New", Kind.chicken },
        .{ "Civilian_New", Kind.civilian },
        .{ "Slim_New", Kind.slim },
        .{ "Bowers_New", Kind.slim },
        .{ "DrDeath_New", Kind.slim },
        .{ "Sanchez_New", Kind.sanchez },
        .{ "TwoFeathers_New", Kind.sanchez },
        .{ "Inv_Object", Kind.inventory_object },
        .{ "Inv_GroundObject", Kind.ground },
        .{ "Inv_GSheriffStar", Kind.ground },
        .{ "Inv_GVanishingCream", Kind.ground },
        .{ "Inv_InstantGroundObject", Kind.instant },
        .{ "Node_New", Kind.node },
        .{ "Gen_New", Kind.generator },
    };
    inline for (names) |pair| {
        if (std.mem.eql(u8, function, pair[0])) return pair[1];
    }
    return error.UnsupportedObjectFactory;
}

pub fn animationName(buffer: []u8, object_name: []const u8, item: ?*const item_module.Item) !?[]const u8 {
    switch (try classify(item)) {
        .node, .generator => return null,
        .decoration => {
            const basename = std.fs.path.stem(std.fs.path.basename(object_name));
            return try std.fmt.bufPrint(buffer, "{s}.NWX", .{basename});
        },
        else => {
            const animation = item.?.animation;
            if (animation.len == 0) return error.MissingObjectAnimation;
            if (!std.ascii.endsWithIgnoreCase(animation, ".NWX")) return error.UnsupportedObjectAnimation;
            return animation;
        },
    }
}

pub fn nativeName(name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "Bowers_New")) return "BGY_New";
    if (std.ascii.eqlIgnoreCase(name, "Simms_New")) return "Farmer_New";
    return name;
}

fn testResource(archives: []const @import("../assets/lab.zig").Archive, name: []const u8) !?[]const u8 {
    for (archives) |archive| {
        const bytes = archive.find(name, 0) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };
        return bytes;
    }
    return null;
}

test "Hideout visible object constructors match the reference factory execution" {
    const lab = @import("../assets/lab.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var archives: [3]lab.Archive = undefined;
    for ([_][]const u8{ "OLGEO", "OLOBJ", "OUTLAWS" }, &archives) |name, *destination| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        destination.* = try lab.Archive.init(bytes);
    }
    const geometry = try level.Level.parse(a, try archives[0].find("HIDEOUT.LVB", 0));
    const source = try level.Objects.parse(a, try archives[0].find("HIDEOUT.OBB", 0));
    const visible_ids = [_]u32{
        0x1d00f, 0x1cffa, 0x15272, 0x214cb, 0x1cf55, 0x22982, 0x33eee,
        0x367bc, 0x1d27e, 0x2489f, 0x33fca, 0x31d6a, 0x342a8, 0x341e9,
        0x367d8, 0x3fba3, 0x36a11, 0x3fc6a, 0x3fbcb, 0x36764,
    };
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var radius_digest = std.crypto.hash.sha2.Sha256.init(.{});
    var count: usize = 0;
    for (source.entries) |object| {
        if (std.mem.indexOfScalar(u32, &visible_ids, object.sector_id) == null or
            object.flags[0] & 1 != 0 or std.ascii.eqlIgnoreCase(object.name, "PLAYER")) continue;
        const path = try std.fmt.allocPrint(a, "{s}.ITM", .{object.name});
        const bytes = try testResource(archives[1..], path);
        const definition = if (bytes) |value| try item_module.Item.parse(a, value) else null;
        const pointer = if (definition) |*value| value else null;
        if (std.ascii.eqlIgnoreCase(object.name, "BGY4D")) {
            try std.testing.expectEqual(@as(usize, 8), pointer.?.fields.len);
            try std.testing.expectEqual(@as(usize, 2), pointer.?.ignored_directives.len);
            try std.testing.expectEqual(@as(?item_module.Value, null), pointer.?.get("HIT_SOUND"));
        }
        var name_buffer: [64]u8 = undefined;
        const animation = try animationName(&name_buffer, object.name, pointer) orelse continue;
        const costume_bytes = try testResource(archives[1..], animation) orelse {
            try std.testing.expect(definition == null);
            try std.testing.expectEqualStrings("SWIND", object.name);
            continue;
        };
        const costume = try nwx.Costume.parse(a, costume_bytes);
        const state = try State.init(object, geometry.sectorIndex(object.sector_id).?, pointer, &costume);
        const words = [_]u32{
            object.id,                              state.flags,             state.secondary_flags,
            @bitCast(state.scale_x),                @bitCast(state.scale_y), @bitCast(state.height),
            state.choreography,                     state.frame,             @as(u16, @bitCast(state.yaw)),
            @as(u16, @bitCast(state.angle_offset)),
        };
        for (words) |word| {
            var encoded: [4]u8 = undefined;
            std.mem.writeInt(u32, &encoded, word, .little);
            digest.update(&encoded);
        }
        var radius_bytes: [8]u8 = undefined;
        std.mem.writeInt(u32, radius_bytes[0..4], object.id, .little);
        std.mem.writeInt(u32, radius_bytes[4..8], @bitCast(state.collision_radius), .little);
        radius_digest.update(&radius_bytes);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 41), count);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "f9fff375fdb1b821b4c41a01940cf0f765d1f0d009f1a620b4c40dcefb1389ca");
    try std.testing.expectEqualSlices(u8, &expected, &digest.finalResult());
    _ = try std.fmt.hexToBytes(&expected, "df3eee37a8fa08d456436fee0f6e7fc64bc0564f53394939c7271ad202ac94c5");
    try std.testing.expectEqualSlices(u8, &expected, &radius_digest.finalResult());
}

test "Train WOMAN1 civilian constructor and target match the reference" {
    const lab = @import("../assets/lab.zig");
    const Target = @import("../player/target.zig").Target;
    const camera = @import("backends/software/camera.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var archives: [2]lab.Archive = undefined;
    for ([_][]const u8{ "OLOBJ", "OLWEAP" }, &archives) |name, *destination| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        destination.* = try lab.Archive.init(bytes);
    }
    const definition = try item_module.Item.parse(a, try archives[0].find("WOMAN1.ITM", 0));
    const costume = try nwx.Costume.parse(a, try archives[0].find("WOMAN1.NWX", 0));
    const object = level.Object{ .name = "WOMAN1", .id = 2, .sector_id = 0, .position = .{ .x = 0, .y = 0, .z = 0 }, .rotation = .{ .x = 0, .y = 0, .z = 0 }, .angles = .{ 0, 0, 0 }, .flags = .{ 0, 0 } };
    const state = try State.init(object, 0, &definition, &costume);
    try std.testing.expectEqual(Kind.civilian, try classify(&definition));
    try std.testing.expectEqual(@as(u32, 0x8000004f), state.flags);
    try std.testing.expectEqual(@as(u32, 0x04004040), state.secondary_flags);
    try std.testing.expectEqual(@as(u32, 0x40e92492), @as(u32, @bitCast(state.height)));
    try std.testing.expectEqual(@as(f32, 1), state.collision_radius);
    try std.testing.expectEqual(@as(u32, 0), state.choreography | state.frame);
    try std.testing.expect(state.playback == null);
    const angles = camera.Angles.init();
    for ([_]u32{ 0x100000, 0x200000, 0x800000 }, [_]u32{ 0x40000000, 0x3fc00000, 0x40000000 }, [_]u32{ 0x40cccccd, 0x41000000, 0x41333333 }) |difficulty, health, walk_speed| {
        var target = (try Target.load(a, &archives, &definition, difficulty)) orelse return error.MissingCivilianTarget;
        try std.testing.expectEqual(health, @as(u32, @bitCast(target.damage.health)));
        try std.testing.expectEqual(walk_speed, @as(u32, @bitCast(target.config.walk_speed)));
        try std.testing.expectEqual(@as(u32, 0xffffffff), target.config.shoot_chor);
        try std.testing.expectEqualStrings("", target.drop_item);
        try std.testing.expectEqual(@as(u32, 0x80000001), target.mode);
        var actor = state.actor(&costume);
        var random: u32 = 0x742389ac;
        try std.testing.expectError(error.UnsupportedEnemyReflectedDamage, target.hit(&angles, &actor, .{ .kind = 1, .damage = 0.01, .mass = 0, .speed = 1000, .pitch = 0, .yaw = 0, .lateral = 0, .height = 4 }, &random, 1000));
    }
}
