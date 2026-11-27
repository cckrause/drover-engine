//! Saving actors: identity, sector membership, transform and the records
//! that hang off them.
//!
//! A transform is written as matrix columns while keeping the row-major
//! word order of its allocation, so the three trailing words are not in
//! their obvious places.

const std = @import("std");
const lab = @import("../assets/lab.zig");
const stream = @import("stream.zig");
const costume = @import("costume.zig");
const Vec3 = @import("../assets/level.zig").Vec3;
const Actor = @import("../render/objects.zig").Actor;
const nwx = @import("../assets/nwx.zig");
const model_asset = @import("../assets/model.zig");

pub const Model = struct {
    resource: []const u8,
    matrix: [9]f32,
    flags: u32,
    value_2c: u32,
    value_34: u32,

    pub fn write(self: Model, writer: *stream.Writer) !void {
        try writer.string(self.resource);
        for ([_]usize{ 0, 3, 6, 1, 4, 7, 2, 5, 8 }) |index| try writer.float(self.matrix[index]);
        try writer.integer(u32, self.flags);
        try writer.integer(u32, self.value_2c);
        try writer.integer(u32, self.value_34);
    }

    pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !Model {
        var value: Model = undefined;
        value.resource = try string(reader, a, 255);
        for ([_]usize{ 0, 3, 6, 1, 4, 7, 2, 5, 8 }) |index| value.matrix[index] = try reader.float();
        value.flags = try reader.integer(u32);
        value.value_2c = try reader.integer(u32);
        value.value_34 = try reader.integer(u32);
        return value;
    }
};

pub const Record = struct {
    id: u32,
    object_id: u32,
    flags: u32,
    position: Vec3,
    angles: [3]i16,
    sector: ?u32,
    height: f32,
    velocity: Vec3,
    last_time: u32,
    kind: u32,
    child: ?*Record,
    resource: []const u8,
    model: ?Model = null,
    wax: ?costume.Instance = null,
    scale_x: f32,
    scale_y: f32,
    angle_70: i16,
    head_yaw: i16,
    eye_height: f32,
    secondary_flags: u32,
    vector_7c: Vec3,
    vector_88: Vec3,
    radius: f32,
    next_update: u32,
    native: []const u8,

    pub fn write(self: Record, writer: *stream.Writer) !void {
        try writer.integer(u32, self.id);
        try writer.integer(u32, self.object_id);
        try writer.integer(u32, self.flags);
        try vector(writer, self.position);
        for (self.angles) |value| try writer.integer(i16, value);
        try writer.integer(u32, self.sector orelse 0xffffffff);
        try writer.float(self.height);
        try vector(writer, self.velocity);
        try writer.integer(u32, self.last_time);
        try writer.integer(u32, self.kind);
        try writer.boolean(self.child != null);
        if (self.child) |child| try child.write(writer);
        try writer.string(self.resource);
        if (self.kind == 2) {
            if (self.wax != null) return error.InvalidSavedActorInstance;
            try writer.boolean(self.model != null);
            if (self.model) |model| try model.write(writer);
        } else {
            if (self.model != null) return error.InvalidSavedActorInstance;
            try costume.write(writer, self.wax);
        }
        try writer.float(self.scale_x);
        try writer.float(self.scale_y);
        try writer.integer(i16, self.angle_70);
        try writer.integer(i16, self.head_yaw);
        try writer.float(self.eye_height);
        try writer.integer(u32, self.secondary_flags);
        try vector(writer, self.vector_7c);
        try vector(writer, self.vector_88);
        try writer.float(self.radius);
        try writer.integer(u32, self.next_update);
        try writer.string(self.native);
    }

    pub fn read(reader: *stream.Reader, a: std.mem.Allocator) !Record {
        return readDepth(reader, a, 0);
    }

    fn readDepth(reader: *stream.Reader, a: std.mem.Allocator, depth: usize) anyerror!Record {
        if (depth >= 64) return error.UnsupportedSavedActorNesting;
        var value: Record = undefined;
        value.id = try reader.integer(u32);
        value.object_id = try reader.integer(u32);
        value.flags = try reader.integer(u32);
        value.position = try readVector(reader);
        for (&value.angles) |*angle| angle.* = try reader.integer(i16);
        const sector = try reader.integer(u32);
        value.sector = if (sector == 0xffffffff) null else sector;
        value.height = try reader.float();
        value.velocity = try readVector(reader);
        value.last_time = try reader.integer(u32);
        value.kind = try reader.integer(u32);
        value.child = null;
        if (try reader.boolean()) {
            const child = try a.create(Record);
            child.* = try readDepth(reader, a, depth + 1);
            value.child = child;
        }
        value.resource = try string(reader, a, 255);
        value.model = null;
        value.wax = null;
        if (value.kind == 2) {
            if (try reader.boolean()) value.model = try Model.read(reader, a);
        } else value.wax = try costume.read(reader, a);
        value.scale_x = try reader.float();
        value.scale_y = try reader.float();
        value.angle_70 = try reader.integer(i16);
        value.head_yaw = try reader.integer(i16);
        value.eye_height = try reader.float();
        value.secondary_flags = try reader.integer(u32);
        value.vector_7c = try readVector(reader);
        value.vector_88 = try readVector(reader);
        value.radius = try reader.float();
        value.next_update = try reader.integer(u32);
        value.native = try string(reader, a, 31);
        return value;
    }
};

pub fn capture(session: anytype, actor: Actor, next_update: u32) !Record {
    const instance_resource = if (actor.model) |model| try resourceName(session.models, model) else if (actor.costume) |wax| try resourceName(session.costumes, wax) else "";
    var playback = actor.playback;
    var binding: []const u8 = "";
    if (actor.source_index) |source| {
        if (source < session.targets.len) if (session.targets[source]) |target| {
            playback = target.playback;
            binding = actor.logic_name;
        };
        if (source < session.splash_slots.len and session.splash_slots[source] != null) binding = "Actor_Dispatch";
    }
    if (std.mem.eql(u8, actor.logic_name, "Inv_Object")) binding = "Inv_Object";
    if (actor.wax_binding) |saved_binding| binding = saved_binding;
    return .{
        .id = actor.logic_id,
        .object_id = actor.object_id,
        .flags = actor.flags,
        .position = actor.position,
        .angles = .{ actor.pitch, actor.yaw, actor.roll },
        .sector = @intCast(actor.sector),
        .height = actor.height,
        .velocity = actor.transformed,
        .last_time = actor.palette_time,
        .kind = actor.logic_kind orelse if (actor.model != null) @as(u32, 2) else if (actor.costume != null) @as(u32, 1) else 0,
        .child = null,
        .resource = actor.logic_resource orelse instance_resource,
        .model = if (actor.model != null and actor.model_instance_present) .{
            .resource = instance_resource,
            .matrix = actor.model_matrix,
            .flags = @bitCast(actor.model_rotation.x),
            .value_2c = @bitCast(actor.model_rotation.y),
            .value_34 = @bitCast(actor.model_rotation.z),
        } else null,
        .wax = if (playback) |value| .{ .resource = instance_resource, .playback = value, .native = binding } else null,
        .scale_x = actor.scale_x,
        .scale_y = actor.scale_y,
        .angle_70 = actor.head_angles[0],
        .head_yaw = actor.head_angles[1],
        .eye_height = actor.eye_height,
        .secondary_flags = actor.secondary_flags,
        .vector_7c = actor.velocity,
        .vector_88 = actor.angular_velocity,
        .radius = actor.collision_radius,
        .next_update = next_update,
        .native = actor.logic_name,
    };
}

pub fn hydrate(session: anytype, record: Record) !Actor {
    const sector = record.sector orelse return error.UnsupportedSavedDetachedActor;
    if (sector >= session.level.sectors.len) return error.InvalidSavedActorSector;
    var sprite: ?*const nwx.Costume = null;
    var model: ?*const model_asset.Model = null;
    if (record.resource.len != 0) {
        if (record.kind == 2) model = try loadModel(session, record.resource) else sprite = try loadCostume(session, record.resource);
    }
    if (record.model) |instance| {
        if (record.kind != 2 or record.wax != null) return error.InvalidSavedActorInstance;
        model = try loadModel(session, instance.resource);
    }
    if (record.wax) |instance| {
        if (record.kind == 2) return error.InvalidSavedActorInstance;
        sprite = try loadCostume(session, instance.resource);
    }
    const playback: ?nwx.Playback = if (record.wax) |instance| instance.playback else null;
    return .{
        .logic_id = record.id,
        .object_id = record.object_id,
        .transformed = record.velocity,
        .palette_time = record.last_time,
        .head_angles = .{ record.angle_70, record.head_yaw },
        .eye_height = record.eye_height,
        .velocity = record.vector_7c,
        .angular_velocity = record.vector_88,
        .model_matrix = if (record.model) |instance| instance.matrix else @splat(0),
        .model_rotation = if (record.model) |instance| .{ .x = @bitCast(instance.flags), .y = @bitCast(instance.value_2c), .z = @bitCast(instance.value_34) } else .{ .x = 0, .y = 0, .z = 0 },
        .logic_name = record.native,
        .logic_resource = record.resource,
        .logic_kind = record.kind,
        .wax_binding = if (record.wax) |instance| instance.native else null,
        .model_instance_present = record.model != null,
        .costume = sprite,
        .model = model,
        .sector = sector,
        .position = record.position,
        .pitch = record.angles[0],
        .yaw = record.angles[1],
        .roll = record.angles[2],
        .flags = record.flags,
        .secondary_flags = record.secondary_flags,
        .scale_x = record.scale_x,
        .scale_y = record.scale_y,
        .height = record.height,
        .collision_radius = record.radius,
        .choreography = if (playback) |value| value.choreography else 0,
        .frame = if (playback) |value| value.frame else 0,
        .angle_offset = if (playback) |value| value.angle_offset else 0,
        .playback = playback,
    };
}

fn resourceName(map: anytype, pointer: anytype) ![]const u8 {
    var entries = map.iterator();
    while (entries.next()) |entry| if (entry.value_ptr.* == pointer) return entry.key_ptr.*;
    return error.UnregisteredSavedActorResource;
}

fn asset(session: anytype, name: []const u8) ![]const u8 {
    for ([_]@import("../assets/lab.zig").Archive{ session.object_archive, session.weapon_archive, session.system_archive }) |archive| {
        return archive.find(name, 0) catch |err| switch (err) {
            error.ResourceNotFound => continue,
            else => return err,
        };
    }
    return error.ResourceNotFound;
}

fn loadCostume(session: anytype, name: []const u8) !*nwx.Costume {
    const a = session.arena.allocator();
    var key_buffer: lab.NameBuffer = undefined;
    const key = try lab.upperName(&key_buffer, name);
    if (session.costumes.get(key)) |existing| return existing;
    const loaded = try a.create(nwx.Costume);
    loaded.* = try nwx.Costume.parse(a, try asset(session, name));
    try session.costumes.put(try a.dupe(u8, key), loaded);
    return loaded;
}

fn loadModel(session: anytype, name: []const u8) !*model_asset.Model {
    const a = session.arena.allocator();
    var key_buffer: lab.NameBuffer = undefined;
    const key = try lab.upperName(&key_buffer, name);
    if (session.models.get(key)) |existing| return existing;
    const loaded = try a.create(model_asset.Model);
    loaded.* = try model_asset.Model.parse(a, try asset(session, name), &.{ session.object_archive, session.texture_archive, session.system_archive });
    try session.models.put(try a.dupe(u8, key), loaded);
    return loaded;
}

fn string(reader: *stream.Reader, a: std.mem.Allocator, maximum: usize) ![]const u8 {
    var buffer: [255]u8 = undefined;
    const value = try reader.string(&buffer);
    if (value.len > maximum) return error.InvalidSavedActorString;
    return a.dupe(u8, value);
}

fn vector(writer: *stream.Writer, value: Vec3) !void {
    try writer.float(value.x);
    try writer.float(value.y);
    try writer.float(value.z);
}

fn readVector(reader: *stream.Reader) !Vec3 {
    return .{ .x = try reader.float(), .y = try reader.float(), .z = try reader.float() };
}

test "Actor WAX Model and nested records match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/save-actor-record-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        executable_sha256: []const u8,
        cases: []struct { kind: []const u8, child: bool, bytes: []const u8, sha256: []const u8 },
    };
    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{});
    defer fixture.deinit();
    for (fixture.value.cases) |case| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const raw = try arena.allocator().alloc(u8, case.bytes.len / 2);
        _ = try std.fmt.hexToBytes(raw, case.bytes);
        var reader: stream.Reader = .{ .bytes = raw };
        const value = try Record.read(&reader, arena.allocator());
        try reader.end();
        try std.testing.expectEqual(@as(u32, 0x12340002), value.id);
        try std.testing.expectEqual(@as(?u32, 9), value.sector);
        try std.testing.expectEqual(Vec3{ .x = 1.25, .y = -2.5, .z = 3.75 }, value.position);
        try std.testing.expectEqual(case.child, value.child != null);
        if (value.model) |model| {
            for (model.matrix, 0..) |number, index| try std.testing.expectEqual(@as(f32, @floatFromInt(index)) * 0.25, number);
            try std.testing.expectEqual(@as(u32, 27), model.value_2c);
            try std.testing.expectEqual(@as(u32, 28), model.flags);
            try std.testing.expectEqual(@as(u32, 29), model.value_34);
        }
        var writer: stream.Writer = .{ .allocator = a };
        defer writer.deinit();
        try value.write(&writer);
        const encoded = try writer.finish();
        defer a.free(encoded);
        try std.testing.expectEqualSlices(u8, raw, encoded);
    }
}
