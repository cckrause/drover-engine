//! Which parts of a wall are visible: the half-plane tests for a wall being
//! entered, and the resolution of overlapping projected intervals.
//!
//! Intervals are resolved in source order and a piece that gets split is
//! revisited, so a wall can contribute several spans. The comparisons
//! include equality on purpose - two walls that project onto the exact same
//! interval have a defined winner.

const std = @import("std");
const projection = @import("projection.zig");
const m = @import("math.zig");
const Vec2 = projection.Vec2;

pub const Wall = struct {
    projected: projection.ProjectedWall,
    first: Vec2,
    second: Vec2,
    active: bool = false,
};

pub const Window = struct { left: i32, right: i32, minimum_z: f32 };

pub fn filter(source: []const Wall, output: []Wall, window: Window, entrance: ?Wall) usize {
    if (source.len == 0 or output.len == 0) return 0;
    var splits: [40]Wall = undefined;
    var split_count: usize = 0;
    var count: usize = 0;
    var cursor: usize = 0;
    const origin: Vec2 = .{ .x = 0, .z = 0 };
    while (cursor < source.len + split_count) : (cursor += 1) {
        var new = if (cursor < source.len) source[cursor] else splits[cursor - source.len];
        if (new.active or !(window.minimum_z < new.projected.z1 or window.minimum_z < new.projected.z2) or
            new.projected.visible_left > window.right or window.left > new.projected.visible_right or
            !throughEntrance(new, entrance)) continue;
        new.projected.visible_left = @max(new.projected.visible_left, window.left);
        new.projected.visible_right = @min(new.projected.visible_right, window.right);
        var discard = false;
        var i: usize = 0;
        while (i < count and !discard) {
            const old = &output[i];
            const nl = new.projected.visible_left;
            const nr = new.projected.visible_right;
            const ol = old.projected.visible_left;
            const oright = old.projected.visible_right;
            if (nl > oright or ol > nr) {
                i += 1;
                continue;
            }
            if (ol < nl or nr < oright) {
                if (nl < ol or oright < nr) {
                    if (nr < ol or oright <= nr) {
                        var old_in_front: bool = undefined;
                        if (@min(old.first.z, old.second.z) <= @max(new.first.z, new.second.z) and
                            @min(new.first.z, new.second.z) <= @max(old.first.z, old.second.z))
                        {
                            old_in_front = projection.sameSide(old.first, old.second, new.first, origin) == 0 or
                                projection.sameSide(new.first, new.second, old.second, origin) != 0;
                        } else {
                            old_in_front = old.second.z <= new.first.z;
                        }
                        if (old_in_front) new.projected.visible_left = oright + 1 else old.projected.visible_right = nl - 1;
                    } else {
                        var old_in_front: bool = undefined;
                        if (@min(old.first.z, old.second.z) <= @max(new.first.z, new.second.z) and
                            @min(new.first.z, new.second.z) <= @max(old.first.z, old.second.z))
                        {
                            old_in_front = projection.sameSide(old.first, old.second, new.second, origin) == 0 or
                                projection.sameSide(new.first, new.second, old.first, origin) != 0;
                        } else {
                            old_in_front = old.first.z <= new.second.z;
                        }
                        if (old_in_front) new.projected.visible_right = ol - 1 else old.projected.visible_left = nr + 1;
                    }
                } else if (newInFront(new, old.*)) {
                    if (ol < nl) {
                        if (nr < oright) {
                            if (split_count == 40) {
                                discard = true;
                            } else {
                                splits[split_count] = old.*;
                                splits[split_count].projected.visible_left = nr + 1;
                                split_count += 1;
                            }
                        }
                        old.projected.visible_right = nl - 1;
                    } else {
                        old.projected.visible_left = nr + 1;
                    }
                } else {
                    discard = true;
                }
            } else if (newInFront(new, old.*)) {
                count -= 1;
                output[i] = output[count];
                continue;
            } else if (nl < ol) {
                if (oright < nr) {
                    if (split_count == 40) {
                        discard = true;
                    } else {
                        splits[split_count] = new;
                        splits[split_count].projected.visible_left = oright + 1;
                        split_count += 1;
                    }
                }
                new.projected.visible_right = ol - 1;
            } else {
                new.projected.visible_left = oright + 1;
            }
            i += 1;
        }
        if (!discard and new.projected.visible_left <= new.projected.visible_right) {
            output[count] = new;
            count += 1;
            if (count == output.len) break;
        }
    }
    return count;
}

pub fn convex(source: []const Wall, output: []Wall, window: Window, entrance: ?Wall) usize {
    if (source.len == 0 or output.len == 0) return 0;
    var start: usize = 0;
    if (source.len != 1 and source[source.len - 1].projected.visible_left < source[0].projected.visible_left) {
        start = source.len - 1;
        while (start > 0 and source[start - 1].projected.visible_left <= source[start].projected.visible_left) start -= 1;
    }
    var count: usize = 0;
    for (0..source.len) |i| {
        var wall = source[(start + i) % source.len];
        if (wall.active or !(window.minimum_z < wall.projected.z1 or window.minimum_z < wall.projected.z2) or
            wall.projected.visible_left > window.right or window.left > wall.projected.visible_right or
            !throughEntrance(wall, entrance) or wall.projected.visible_left > wall.projected.visible_right) continue;
        wall.projected.visible_left = @max(wall.projected.visible_left, window.left);
        wall.projected.visible_right = @min(wall.projected.visible_right, window.right);
        output[count] = wall;
        count += 1;
        if (count == output.len) break;
    }
    return count;
}

fn throughEntrance(wall: Wall, entrance: ?Wall) bool {
    const e = entrance orelse return true;
    const dx = m.sub(e.second.x, e.first.x);
    const dz = m.sub(e.second.z, e.first.z);
    const base = m.sub(m.mul(e.first.z, dx), m.mul(e.first.x, dz));
    const c1 = m.add(base, m.sub(m.mul(dz, wall.first.x), m.mul(wall.first.z, dx)));
    const c2 = m.add(m.sub(m.mul(wall.second.x, dz), m.mul(wall.second.z, dx)), base);
    if (c1 > -0.001 and m.unsignedBits(c2) < 0xba83126f) return false;
    const wx = m.sub(wall.second.x, wall.first.x);
    const wz = m.sub(wall.second.z, wall.first.z);
    const wb = m.sub(m.mul(wall.first.z, wx), m.mul(wall.first.x, wz));
    const d1 = m.add(wb, m.sub(m.mul(wz, e.first.x), m.mul(e.first.z, wx)));
    const d2 = m.add(m.sub(m.mul(e.second.x, wz), m.mul(e.second.z, wx)), wb);
    return !(d1 < 0.001 and m.signedBits(d2) < 0x3a83126f);
}

fn newInFront(new: Wall, old: Wall) bool {
    const n1 = new.first.z;
    const n2 = new.second.z;
    const o1 = old.first.z;
    const o2 = old.second.z;
    const origin: Vec2 = .{ .x = 0, .z = 0 };
    if (@max(n1, n2) < @min(o1, o2) or @max(o1, o2) < @min(n1, n2)) return o1 > n1;
    if (n1 < o1) {
        if ((projection.sameSide(new.first, new.second, old.first, origin) == 0 and
            projection.sameSide(new.first, new.second, old.second, origin) == 0) or
            (projection.sameSide(old.first, old.second, new.first, origin) != 0 and
                projection.sameSide(old.first, old.second, new.second, origin) != 0)) return true;
        return false;
    }
    return (projection.sameSide(old.first, old.second, new.first, origin) != 0 or
        projection.sameSide(old.first, old.second, new.second, origin) != 0) and
        (projection.sameSide(new.first, new.second, old.first, origin) == 0 or
            projection.sameSide(new.first, new.second, old.second, origin) == 0);
}

test "visibility interval and convex paths match the reference" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/visibility-reference.json", allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);
    const Sample = struct {
        first: [2]f32,
        second: [2]f32,
        projection: [16]u32,
        active: bool,
    };
    const Case = struct { seed: u32, convex: bool, source: []Sample, entrance: ?usize, left: i32, right: i32, minimum_z: f32, capacity: usize, expected: [][17]u32 };
    const parsed = try std.json.parseFromSlice(struct { executable_sha256: []const u8, cases: []Case }, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f", parsed.value.executable_sha256);
    for (parsed.value.cases) |case| {
        const source = try allocator.alloc(Wall, case.source.len);
        defer allocator.free(source);
        for (case.source, source, 0..) |sample, *wall, index| {
            const b = sample.projection;
            wall.* = .{ .first = .{ .x = sample.first[0], .z = sample.first[1] }, .second = .{ .x = sample.second[0], .z = sample.second[1] }, .active = sample.active, .projected = .{ .wall_index = index, .left = @bitCast(b[0]), .right = @bitCast(b[1]), .z1 = @bitCast(b[2]), .z2 = @bitCast(b[3]), .u1 = @bitCast(b[4]), .x1 = @bitCast(b[5]), .x2 = @bitCast(b[6]), .visible_left = @bitCast(b[7]), .visible_right = @bitCast(b[8]), .axis = @bitCast(b[9]), .slope = @bitCast(b[10]), .u_scale = @bitCast(b[11]), .world_x1 = @bitCast(b[12]), .world_z1 = @bitCast(b[13]), .world_x2 = @bitCast(b[14]), .world_z2 = @bitCast(b[15]) } };
        }
        const output = try allocator.alloc(Wall, case.capacity);
        defer allocator.free(output);
        const window = Window{ .left = case.left, .right = case.right, .minimum_z = case.minimum_z };
        const entrance = if (case.entrance) |i| source[i] else null;
        const count = if (case.convex) convex(source, output, window, entrance) else filter(source, output, window, entrance);
        if (count != case.expected.len) std.debug.print("\nvisibility seed{} convex{} count{} expected{}\n", .{ case.seed, case.convex, count, case.expected.len });
        try std.testing.expectEqual(case.expected.len, count);
        for (output[0..count], case.expected) |wall, expected| {
            const p = wall.projected;
            const actual = [_]u32{ @intCast(p.wall_index), @bitCast(p.left), @bitCast(p.right), @bitCast(p.z1), @bitCast(p.z2), @bitCast(p.u1), @bitCast(p.x1), @bitCast(p.x2), @bitCast(p.visible_left), @bitCast(p.visible_right), @bitCast(p.axis), @bitCast(p.slope), @bitCast(p.u_scale), @bitCast(p.world_x1), @bitCast(p.world_z1), @bitCast(p.world_x2), @bitCast(p.world_z2) };
            if (!std.mem.eql(u32, &expected, &actual)) std.debug.print("\nvisibility seed{} convex{}\n", .{ case.seed, case.convex });
            try std.testing.expectEqualSlices(u32, &expected, &actual);
        }
    }
}
