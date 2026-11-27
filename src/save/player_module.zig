//! Saving the player's scheduled tasks: absolute due time, then the task's
//! parameter.
//!
//! The function to call is supplied by whichever subsystem restores the
//! task, not stored in the file.

const std = @import("std");

const stream = @import("stream.zig");

pub const Task = struct {
    due: u32,
    parameter: u32,

    pub fn write(self: Task, writer: *stream.Writer) !void {
        try writer.integer(u32, self.due);
        try writer.integer(u32, self.parameter);
    }

    pub fn read(reader: *stream.Reader) !Task {
        return .{ .due = try reader.integer(u32), .parameter = try reader.integer(u32) };
    }
};

pub const State = struct {
    star: ?Task = null,
    cloak: ?Task = null,
    star_remaining: u32 = 0,
    cloak_remaining: u32 = 0,

    pub fn write(self: *State, writer: *stream.Writer) !void {
        try writer.marker(0x42796c50, 1, 0);
        try writer.boolean(self.star != null);

        if (self.star) |task| try task.write(writer);

        self.star = null;
        try writer.boolean(self.cloak != null);

        if (self.cloak) |task| try task.write(writer);

        self.cloak = null;

        try writer.integer(u32, self.star_remaining);
        try writer.integer(u32, self.cloak_remaining);
    }

    pub fn read(reader: *stream.Reader) !State {
        try reader.marker(0x42796c50, 1, 0);
        var state: State = .{};

        if (try reader.boolean()) state.star = try Task.read(reader);

        if (try reader.boolean()) state.cloak = try Task.read(reader);

        state.star_remaining = try reader.integer(u32);
        state.cloak_remaining = try reader.integer(u32);

        return state;
    }
};

pub fn capture(inventory: anytype) State {
    return .{
        .star = if (inventory.sheriff_task_linked) (if (inventory.sheriff_due) |due| .{
            .due = due,
            .parameter = inventory.sheriff_task_parameter,
        } else null) else null,
        .cloak = if (inventory.cloak_task_linked) (if (inventory.cloak_due) |due| .{
            .due = due,
            .parameter = inventory.cloak_task_parameter,
        } else null) else null,
        .star_remaining = @bitCast(inventory.sheriff_remaining),
        .cloak_remaining = @bitCast(inventory.cloak_remaining),
    };
}

/// The task-link flags a successful save clears, kept so a failed save can
/// put them back.
pub const TaskLinks = struct {
    sheriff: bool,
    cloak: bool,

    pub fn of(inventory: anytype) TaskLinks {
        return .{ .sheriff = inventory.sheriff_task_linked, .cloak = inventory.cloak_task_linked };
    }

    pub fn restore(self: TaskLinks, inventory: anytype) void {
        inventory.sheriff_task_linked = self.sheriff;
        inventory.cloak_task_linked = self.cloak;
    }
};

pub fn writeInventory(inventory: anytype, writer: *stream.Writer) !void {
    var state = capture(inventory);
    try state.write(writer);
    inventory.sheriff_task_linked = false;
    inventory.cloak_task_linked = false;
}

pub fn apply(inventory: anytype, value: State) void {
    inventory.sheriff_due = if (value.star) |task| task.due else null;
    inventory.sheriff_task_linked = value.star != null;
    inventory.sheriff_task_parameter = if (value.star) |task| task.parameter else 0;
    inventory.cloak_due = if (value.cloak) |task| task.due else null;
    inventory.cloak_task_linked = value.cloak != null;
    inventory.cloak_task_parameter = if (value.cloak) |task| task.parameter else 0;
    inventory.sheriff_remaining = @bitCast(value.star_remaining);
    inventory.cloak_remaining = @bitCast(value.cloak_remaining);
}

test "Player module saves tasks and clears only global handles" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/save-player-module-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Fixture = struct {
        executable_sha256: []const u8,
        cases: []struct { linked: bool, bytes: []const u8, handles: [2]u32 },
    };

    const fixture = try std.json.parseFromSlice(Fixture, a, bytes, .{});
    defer fixture.deinit();

    for (fixture.value.cases) |case| {
        var inventory: @import("../player/inventory.zig").Inventory = .{
            .sheriff_due = 120000,
            .sheriff_task_linked = case.linked,
            .sheriff_task_parameter = 3,
            .sheriff_remaining = 5,
            .cloak_due = 120800,
            .cloak_task_linked = case.linked,
            .cloak_task_parameter = 4,
            .cloak_remaining = 6,
        };

        var writer: stream.Writer = .{ .allocator = a };
        defer writer.deinit();

        try writeInventory(&inventory, &writer);

        const encoded = try writer.finish();
        defer a.free(encoded);
        const expected = try a.alloc(u8, case.bytes.len / 2);
        defer a.free(expected);

        _ = try std.fmt.hexToBytes(expected, case.bytes);

        try std.testing.expectEqualSlices(u8, expected, encoded);
        try std.testing.expect(!inventory.sheriff_task_linked and !inventory.cloak_task_linked);
        try std.testing.expectEqual(@as(?u32, 120000), inventory.sheriff_due);
        try std.testing.expectEqual(@as(?u32, 120800), inventory.cloak_due);

        var reader: stream.Reader = .{ .bytes = expected };
        const restored = try State.read(&reader);

        try reader.end();
        apply(&inventory, restored);

        try std.testing.expectEqual(case.linked, inventory.sheriff_task_linked);
        try std.testing.expectEqual(@as(i32, 5), inventory.sheriff_remaining);
        try std.testing.expectEqual(@as(i32, 6), inventory.cloak_remaining);
    }
}

test "a failed save can put the task links back" {
    var inventory: struct {
        sheriff_task_linked: bool = true,
        cloak_task_linked: bool = false,
        sheriff_due: ?u32 = 5,
        sheriff_task_parameter: u32 = 0,
        cloak_due: ?u32 = null,
        cloak_task_parameter: u32 = 0,
        sheriff_remaining: i32 = 0,
        cloak_remaining: i32 = 0,
    } = .{};

    const links = TaskLinks.of(&inventory);
    var writer: stream.Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try writeInventory(&inventory, &writer);
    try std.testing.expect(!inventory.sheriff_task_linked);
    links.restore(&inventory);

    try std.testing.expect(inventory.sheriff_task_linked);
    try std.testing.expect(!inventory.cloak_task_linked);
}
