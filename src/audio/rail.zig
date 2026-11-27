//! The sounds of riding a rail: the loop, the pull and the stop.
//!
//! Looping is set on the shared resource rather than on the current
//! instance, so every instance of it loops.

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const sound = @import("engine.zig");
const Vec3 = @import("../assets/level.zig").Vec3;

pub const State = struct {
    distance: f32 = 0,
    rail_handle: u32 = 0,
    pull_handle: u32 = 0,
    rail_resource: ?u32 = null,
    thunk_resource: ?u32 = null,
    pull_resource: ?u32 = null,
};

pub const Context = struct {
    state: *State,
    runtime: *Runtime,
    now: u32,
    before: ?struct { context: *anyopaque, drain: *const fn (*anyopaque) anyerror!void } = null,

    pub fn start(self: *Context, position: Vec3) !void {
        try self.begin();

        self.state.distance = 0;
        self.state.pull_handle = 0;

        const rail = try self.retain("rail.wav");

        self.state.rail_resource = rail;
        self.runtime.resource_flags.items[rail] |= sound.Flags.loop;
        self.runtime.registrations.items[self.runtime.registration_ids.items[rail]].flags |= sound.Flags.loop;

        if (try self.create(rail, 0, position)) |id| self.state.rail_handle = id;

        self.state.thunk_resource = try self.retain("thunk.wav");
        const pull_resource = try self.retain("pull.wav");

        self.state.pull_resource = pull_resource;
        self.runtime.resource_flags.items[pull_resource] |= sound.Flags.loop;
        self.runtime.registrations.items[self.runtime.registration_ids.items[pull_resource]].flags |= sound.Flags.loop;
    }

    pub fn stop(self: *Context) !void {
        try self.begin();
        self.state.distance = 0;
        self.runtime.engine.stop(self.state.pull_handle);
        self.state.pull_handle = 0;
        self.runtime.engine.stop(self.state.rail_handle);
        self.state.rail_handle = 0;

        for ([_]*?u32{
            &self.state.thunk_resource,
            &self.state.pull_resource,
            &self.state.rail_resource,
        }) |resource| if (resource.*) |wave| {
            self.runtime.releaseRegistration(self.runtime.registration_ids.items[wave]);
            resource.* = null;
        };
    }

    pub fn pull(self: *Context, position: Vec3) !void {
        try self.begin();

        if (self.state.pull_handle == 0) {
            self.state.pull_handle = (try self.create(
                self.state.pull_resource orelse return error.MissingRailResources,
                30,
                position,
            )) orelse 0;
        } else try self.setPosition(self.state.pull_handle, position);
    }

    pub fn stopPull(self: *Context) !void {
        try self.begin();
        self.runtime.engine.stop(self.state.pull_handle);
        self.state.pull_handle = 0;
    }

    pub fn update(self: *Context, distance: f32, speed: f32, position: Vec3) !void {
        try self.begin();
        const full = @as(f64, self.state.distance) + distance;
        self.state.distance = @floatCast(full);

        if (full > 10) {
            self.state.distance = 0;
            _ = try self.runtime.play(
                .{
                    .basename = "thunk.wav",
                    .priority = 64,
                    .volume = 127,
                    .flags = 4,
                    .position = position,
                },
                null,
                self.now,
            );
        }

        if (self.runtime.engine.find(self.state.rail_handle)) |voice| {
            var params = voice.params;
            params.volume = @truncate(@min(nearest(speed), 127));
            try self.runtime.engine.adjust(self.state.rail_handle, params);
        }

        try self.setPosition(self.state.rail_handle, position);
    }

    fn begin(self: *Context) !void {
        if (self.before) |pending| try pending.drain(pending.context);
    }

    fn retain(self: *Context, name: []const u8) !u32 {
        _ = try self.runtime.declare(name, 0x57415644, 1, self.now);

        return self.runtime.registerAt(name, 0x57415644, 1, self.now);
    }

    fn create(self: *Context, resource: u32, volume: i8, position: Vec3) !?u32 {
        const registration = self.runtime.registration_ids.items[resource];
        const id = self.runtime.allocateInstance(registration) orelse return null;

        _ = try self.runtime.engine.admit(id, resource, self.runtime.waves.items[resource].sample_rate, .{
            .flags = sound.Flags.spatial | self.runtime.registrations.items[registration].flags,
            .volume = volume,
            .priority = @bitCast(self.runtime.registrations.items[registration].priority),
            .position = .{ position.x, position.y, position.z },
        }, self.now);

        return id;
    }

    fn setPosition(self: *Context, handle: u32, point: Vec3) !void {
        const voice = self.runtime.engine.find(handle) orelse return;
        var params = voice.params;

        params.position = .{ point.x, point.y, point.z };
        params.flags |= sound.Flags.spatial;

        try self.runtime.engine.adjust(handle, params);
    }
};

fn nearest(value: f32) i32 {
    const lower = @floor(@as(f64, value));
    const fraction = @as(f64, value) - lower;
    const rounded = lower + @as(
        f64,
        if (fraction > 0.5 or (fraction == 0.5 and @mod(lower, 2) != 0)) 1 else 0,
    );

    if (!std.math.isFinite(
        rounded,
    ) or rounded < -2147483648.0 or rounded >= 2147483648.0) return std.math.minInt(i32);

    return @intFromFloat(rounded);
}

test "rail audio matches instance ownership and threshold operations" {
    const a = std.testing.allocator;
    const fixture_bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/rail-audio-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(fixture_bytes);
    const Step = struct {
        operation: []const u8,
        position: [3]f32,
        distance: f32,
        speed: f32,
        state: [3]u32,
        next_id: u32,
        starts: []const struct {
            source: usize,
            flags: u32,
            volume: i8,
            priority: i8,
            position: [3]f32,
            result: i32,
        },
        adjusts: []const struct { id: u32, volume: i8, position: [3]f32 },
        stops: []const struct { id: u32 },
    };

    const Fixture = struct {
        results_sha256: []const u8,
        steps: []const Step,
        reuse_steps: []const Step,
    };

    const parsed = try std.json.parseFromSlice(
        Fixture,
        a,
        fixture_bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "cbec8af2aa614ad30dcaeb6839f5dfd7ac9c057035727b4ab7d5f87fd8210641",
        parsed.value.results_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(128 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(data);

    for ([_][]const Step{ parsed.value.steps, parsed.value.reuse_steps }) |steps| {
        const runtime = try Runtime.open(
            a,
            std.testing.io,
            path,
            try @import("../assets/lab.zig").Archive.init(data),
        );

        defer runtime.deinit();

        runtime.engine.effects_volume = 127;

        var state: State = .{};
        var context: Context = .{ .state = &state, .runtime = runtime, .now = 0 };

        for (steps) |step| {
            const point: Vec3 = .{
                .x = step.position[0],
                .y = step.position[1],
                .z = step.position[2],
            };

            if (std.mem.eql(
                u8,
                step.operation,
                "start",
            )) try context.start(
                point,
            ) else if (std.mem.eql(
                u8,
                step.operation,
                "pull",
            )) try context.pull(
                point,
            ) else if (std.mem.eql(
                u8,
                step.operation,
                "stop_pull",
            )) try context.stopPull() else if (std.mem.eql(
                u8,
                step.operation,
                "update",
            )) try context.update(
                step.distance,
                step.speed,
                point,
            ) else if (std.mem.eql(
                u8,
                step.operation,
                "stop",
            )) try context.stop() else if (std.mem.eql(u8, step.operation, "reuse")) {
                const resource = state.thunk_resource.?;

                for (0..198) |_| {
                    const id = (try runtime.engine.start(
                        resource,
                        runtime.waves.items[resource].sample_rate,
                        .{ .priority = 1 },
                        0,
                    )).?;

                    runtime.engine.stop(id);
                }

                _ = try runtime.engine.start(
                    resource,
                    runtime.waves.items[resource].sample_rate,
                    .{ .priority = 1 },
                    0,
                );
            } else return error.InvalidRailReference;

            try std.testing.expectEqual(
                step.state,
                [3]u32{ state.rail_handle, @bitCast(state.distance), state.pull_handle },
            );

            try std.testing.expectEqual(step.next_id, runtime.engine.next_id);

            for (step.starts) |expected| {
                if (expected.result != 0) continue;

                const voice = runtime.engine.find(
                    step.next_id,
                ) orelse return error.MissingRailVoice;

                try std.testing.expectEqual(expected.flags, voice.params.flags);
                try std.testing.expectEqual(expected.volume, voice.params.volume);
                try std.testing.expectEqual(expected.priority, voice.params.priority);
                try std.testing.expectEqual(expected.position, voice.params.position);

                const names = [_][]const u8{ "rail.wav", "thunk.wav", "pull.wav" };
                try std.testing.expectEqual(
                    try runtime.register(names[expected.source]),
                    voice.asset,
                );
            }

            if (step.adjusts.len != 0) {
                const expected = step.adjusts[step.adjusts.len - 1];
                const voice = runtime.engine.find(expected.id) orelse return error.MissingRailVoice;
                try std.testing.expectEqual(expected.volume, voice.params.volume);
                try std.testing.expectEqual(expected.position, voice.params.position);
            }

            for (step.stops) |expected| try std.testing.expect(
                runtime.engine.find(expected.id) == null,
            );
        }
    }
}

test "rail and ambient ownership survives instance reuse and exhaustion" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/rail-lifetime-reference.json",
        a,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Operation = struct {
        kind: []const u8,
        now: u32,
        name: ?[]const u8 = null,
        priority: u8 = 0,
        count: u32 = 0,
        layer: f32 = 0,
        flags: ?u32 = null,
        volume: ?u8 = null,
    };

    const Record = struct {
        name: []const u8,
        priority: u8,
        flags: u32,
        registered_at: u32,
        references: i32,
        instances: u32,
    };

    const Voice = struct {
        id: u32,
        name: []const u8,
        flags: u32,
        priority: i8,
        volume: i8,
        position: [3]f32,
    };

    const Step = struct {
        records: []Record,
        state: [3]u32,
        resources: [3]?[]const u8,
        next_id: u32,
        ambient_handle: ?u32,
        ambient_deadline: ?u32,
        voices: []Voice,
    };

    const Corpus = struct {
        executable_sha256: []const u8,
        driver_dll_sha256: []const u8,
        results_sha256: []const u8,
        assets: struct {
            @"RAIL.WAV": []const u8,
            @"THUNK.WAV": []const u8,
            @"PULL.WAV": []const u8,
        },
        cases: []struct { name: []const u8, operations: []Operation, steps: []Step },
    };

    const parsed = try std.json.parseFromSlice(
        Corpus,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        parsed.value.executable_sha256,
    );

    try std.testing.expectEqualStrings(
        "d935c2ec32c4883141d54ce78cf638e3400ceb9f3767584d4d87757672de3f86",
        parsed.value.driver_dll_sha256,
    );

    try std.testing.expectEqualStrings(
        "10d169c0841fc2e6de1850f5a118c08f8aad33a82a5fbe65822e8cd2ace036d3",
        parsed.value.results_sha256,
    );

    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        a,
        .limited(128 * 1024 * 1024),
    );

    defer a.free(data);

    for (parsed.value.cases, 0..) |case, case_index| {
        const runtime = try Runtime.open(
            a,
            std.testing.io,
            path,
            try @import("../assets/lab.zig").Archive.init(data),
        );

        defer runtime.deinit();

        if (case_index == 0) inline for (.{ "RAIL.WAV", "THUNK.WAV", "PULL.WAV" }) |name| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(try runtime.archives[1].find(name, 0), &digest, .{});
            try std.testing.expectEqualStrings(
                @field(parsed.value.assets, name),
                &std.fmt.bytesToHex(digest, .lower),
            );
        };

        var state: State = .{};
        var context: Context = .{ .state = &state, .runtime = runtime, .now = 0 };

        try std.testing.expectEqual(case.operations.len, case.steps.len);

        for (case.operations, case.steps, 0..) |op, expected, step| {
            errdefer std.debug.print(
                "reference lifetime {s} step{d} {s}\n",
                .{ case.name, step, op.kind },
            );

            context.now = op.now;
            const point: Vec3 = .{ .x = 1, .y = 2, .z = 3 };

            if (std.mem.eql(u8, op.kind, "declare")) {
                const registration = try runtime.declare(
                    op.name.?,
                    0x57415644,
                    op.priority,
                    op.now,
                );

                if (op.flags != null or op.volume != null) _ = try runtime.registerAt(
                    op.name.?,
                    0x57415644,
                    op.priority,
                    op.now,
                );

                if (op.flags) |flags| runtime.registrations.items[registration].flags = flags;

                if (op.volume) |volume| runtime.registrations.items[registration].volume = volume;
            } else if (std.mem.eql(u8, op.kind, "release")) {
                runtime.releaseRegistration(runtime.lookup(op.name.?).?);
            } else if (std.mem.eql(u8, op.kind, "start")) {
                try context.start(point);
            } else if (std.mem.eql(u8, op.kind, "pull")) {
                try context.pull(point);
            } else if (std.mem.eql(u8, op.kind, "stop")) {
                try context.stop();
            } else if (std.mem.eql(u8, op.kind, "stop_all")) {
                runtime.stopAll();
            } else if (std.mem.eql(u8, op.kind, "fill") or std.mem.eql(u8, op.kind, "rotate")) {
                const registration = runtime.lookup(op.name.?).?;

                for (0..op.count) |_| {
                    const id = runtime.allocateInstance(
                        registration,
                    ) orelse return error.UnexpectedNativeInstanceExhaustion;

                    if (std.mem.eql(u8, op.kind, "rotate")) runtime.engine.stop(id);
                }
            } else if (std.mem.eql(u8, op.kind, "ambient")) {
                const registration = try runtime.declare(op.name.?, 0x57415644, 64, op.now);
                runtime.registrations.items[registration].flags |= sound.Flags.loop;
                const resource = try runtime.registerAt(op.name.?, 0x57415644, 64, op.now);
                runtime.resource_flags.items[resource] |= sound.Flags.loop;
                try runtime.beginEmptyAmbient();

                runtime.ambient.?.sources = try a.alloc(@import("ambient.zig").Source, 1);
                runtime.ambient.?.actions = try a.alloc(@import("ambient.zig").Action, 1);
                runtime.ambient.?.sources[0] = .{
                    .basename = op.name.?,
                    .position = point,
                    .layer = 0,
                };

                runtime.ambient_resources = try a.alloc(u32, 1);
                runtime.ambient_resources[0] = resource;
            } else if (std.mem.eql(u8, op.kind, "poll")) {
                try runtime.advanceAmbient(op.now, op.layer);
            } else return error.InvalidNativeLifetimeOperation;

            try std.testing.expectEqual(
                expected.state,
                [3]u32{ state.rail_handle, @bitCast(state.distance), state.pull_handle },
            );

            try std.testing.expectEqual(expected.next_id, runtime.engine.next_id);

            for (expected.resources, [_]?u32{
                state.rail_resource,
                state.thunk_resource,
                state.pull_resource,
            }) |name, wave| {
                const actual = if (wave) |resource| runtime.registrations.items[runtime.registration_ids.items[resource]].name else null;
                try std.testing.expectEqualDeep(name, actual);
            }

            try std.testing.expectEqual(
                expected.ambient_handle,
                if (runtime.ambient) |ambient| ambient.sources[0].handle else null,
            );

            try std.testing.expectEqual(
                expected.ambient_deadline,
                if (runtime.ambient) |ambient| ambient.deadline else null,
            );

            var index: usize = 0;

            for (runtime.registrations.items, runtime.registration_refs.items, 0..) |record, refs, id| {
                if (!refs.active) continue;

                try std.testing.expect(index < expected.records.len);
                try std.testing.expectEqualDeep(
                    expected.records[index],
                    Record{
                        .name = record.name,
                        .priority = record.priority,
                        .flags = record.flags,
                        .registered_at = record.registered_at,
                        .references = refs.count,
                        .instances = runtime.instanceCount(@intCast(id)),
                    },
                );

                index += 1;
            }

            try std.testing.expectEqual(expected.records.len, index);
            var voice_count: usize = 0;

            for (runtime.engine.voices) |voice| if (voice.active) {
                voice_count += 1;
            };

            try std.testing.expectEqual(expected.voices.len, voice_count);

            for (expected.voices) |voice| {
                const actual = runtime.engine.find(
                    voice.id,
                ) orelse return error.MissingNativeSoundVoice;

                try std.testing.expectEqualStrings(
                    voice.name,
                    runtime.registrations.items[runtime.registration_ids.items[actual.asset]].name,
                );

                try std.testing.expectEqual(voice.flags, actual.params.flags);
                try std.testing.expectEqual(voice.priority, actual.params.priority);
                try std.testing.expectEqual(voice.volume, actual.params.volume);
                try std.testing.expectEqual(voice.position, actual.params.position);
            }
        }
    }
}
