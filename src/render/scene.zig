//! The derived geometry a loaded level needs: sector planes, slope hinges
//! and the UV axes that go with them.
//!
//! Built once at load. Hinge endpoints come from the level data, the plane
//! and UV axes are derived from them, and the result is bounded over the
//! sector's vertices. A slope the level data could not express properly is
//! dropped here rather than rendered wrong.

const std = @import("std");

const level_asset = @import("../assets/level.zig");
const camera = @import("backends/software/camera.zig");
const bits = @import("../util/bits.zig");
pub const Vec2 = level_asset.Vec2;
pub const Vec3 = level_asset.Vec3;
pub const SectorFlags = level_asset.SectorFlags;
pub const WallFlags = level_asset.WallFlags;

/// What changed in a sector while the level ran, plus a few facts worked out
/// at load. The "changed" bits tell saves what to write and the network what
/// to send. The word starts as the level file's second sector word.
pub const SectorRuntimeFlags = packed struct(u32) {
    changed: bool = false,
    slopes_changed: bool = false,
    heights_changed: bool = false,
    flags_changed: bool = false,
    number_changed: bool = false,
    light_changed: bool = false,
    unused_6: u18 = 0,
    /// Saves write the sector below or above.
    has_vertical_adjoin: bool = false,
    /// Saves write the velocity the sector started with.
    has_base_velocity: bool = false,
    /// Saves write the sector's current velocity.
    has_velocity: bool = false,
    unused_27: bool = false,
    /// A secret sector the player hasn't found yet.
    secret_unfound: bool = false,
    unused_29: bool = false,
    /// The walls form one closed outline that always turns the same way.
    convex: bool = false,
    /// The sector doesn't hand its finished depth window back to the sector
    /// it was seen through.
    keeps_depth: bool = false,
};

/// What changed in a wall while the level ran, plus facts worked out at
/// load. Same idea as `SectorRuntimeFlags`.
pub const WallRuntimeFlags = packed struct(u32) {
    changed: bool = false,
    corners_changed: bool = false,
    flags_changed: bool = false,
    number_changed: bool = false,
    unused_4: u22 = 0,
    /// An elevator moves this wall.
    moved_by_elevator: bool = false,
    /// Breakable glass that has been made impassable and shootable.
    glass_ready: bool = false,
    /// A sloped plane in some sector hinges on this wall.
    slope_hinge: bool = false,
    /// A side wall of a rail; the cart turns to follow it.
    rail_guide: bool = false,
    /// The player has seen the wall, so the map shows it.
    seen: bool = false,
    unused_31: bool = false,
};

pub const Slope = struct {
    angle: i16 = 0,
    hinge_first: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    coeff_x: f32,
    coeff_z: f32,
    constant: f32,
    min_y: f32,
    max_y: f32,
    origin: Vec3,
    u_axis: Vec3,
    v_axis: Vec3,
    u_offset: f32,
    v_offset: f32,

    pub fn height(self: Slope, point: Vec2) f32 {
        return f32store(
            (@as(
                f64,
                self.constant,
            ) - @as(f64, point.z) * self.coeff_z) - @as(f64, point.x) * self.coeff_x,
        );
    }

    pub fn init(
        level: *const level_asset.Level,
        sector_index: usize,
        plane: level_asset.Plane,
        angles: *const camera.Angles,
    ) !Slope {
        return make(level, sector_index, plane, angles, normalize);
    }

    pub fn initV111(
        level: *const level_asset.Level,
        sector_index: usize,
        plane: level_asset.Plane,
        angles: *const camera.Angles,
    ) !Slope {
        return make(level, sector_index, plane, angles, normalizeV111);
    }

    fn make(
        level: *const level_asset.Level,
        sector_index: usize,
        plane: level_asset.Plane,
        angles: *const camera.Angles,
        comptime unit: fn (Vec3) Vec3,
    ) !Slope {
        const definition = plane.slope orelse return error.MissingSlope;
        const hinge_sector = level.sectors[definition.sector];
        const hinge = hinge_sector.walls[definition.wall];
        const first = hinge_sector.vertices[hinge.v1];
        const last = hinge_sector.vertices[hinge.v2];
        const origin = Vec3{ .x = last.x, .y = plane.height, .z = last.z };
        const delta = Vec3{ .x = first.x - last.x, .y = 0, .z = first.z - last.z };
        const squared = f32store(@as(f64, delta.z) * delta.z + @as(f64, delta.x) * delta.x);
        const distance = f32store(@sqrt(@as(f64, squared)));
        if (distance == 0) return error.DegenerateSlopeHinge;

        const projected_x = f32store(-@as(f64, delta.z) + origin.x);
        const projected_y = f32store(@as(f64, angles.tan(definition.angle)) * distance + origin.y);
        const perpendicular = Vec3{
            .x = projected_x - origin.x,
            .y = projected_y - origin.y,
            .z = f32store((@as(f64, origin.z) + delta.x) - origin.z),
        };

        const inverse = 1.0 / (@as(
            f64,
            perpendicular.z,
        ) * delta.x - @as(f64, perpendicular.x) * delta.z);

        const coeff_x = (@as(
            f64,
            perpendicular.y,
        ) * delta.z - @as(f64, perpendicular.z) * delta.y) * inverse;

        const coeff_z = (@as(
            f64,
            perpendicular.x,
        ) * delta.y - @as(f64, perpendicular.y) * delta.x) * inverse;

        const u_axis = unit(delta);
        const v_axis = unit(perpendicular);
        var result = Slope{
            .angle = definition.angle,
            .hinge_first = .{ .x = first.x, .y = plane.height, .z = first.z },
            .coeff_x = f32store(coeff_x),
            .coeff_z = f32store(coeff_z),
            .constant = f32store(coeff_z * origin.z + @as(f64, origin.x) * coeff_x + origin.y),
            .min_y = 0,
            .max_y = 0,
            .origin = origin,
            .u_axis = u_axis,
            .v_axis = v_axis,
            .u_offset = dotOrigin(origin, u_axis),
            .v_offset = dotOrigin(origin, v_axis),
        };

        const vertices = level.sectors[sector_index].vertices;

        result.min_y = result.height(vertices[0]);
        result.max_y = result.min_y;

        for (vertices[1..]) |vertex| {
            const y = result.height(vertex);
            if (y < result.min_y) result.min_y = y;
            if (result.max_y < y) result.max_y = y;
        }

        return result;
    }
};

/// Which parts of a wall around an opening get drawn, worked out from the
/// heights on both sides. The renderer also uses it to say which half of a
/// double opening it's drawing.
pub const WallParts = packed struct(u32) {
    /// The neighbour's ceiling is lower, so there's wall above the opening.
    top: bool = false,
    /// The neighbour's floor is higher, so there's wall below the opening.
    bottom: bool = false,
    /// Two openings, one above the other.
    double_adjoin: bool = false,
    /// Drawing the lower of the two openings.
    lower_opening: bool = false,
    unused_4: u28 = 0,
};

pub const WallState = struct {
    original_start: Vec2 = .{ .x = 0, .z = 0 },
    base_vertices: [2]u32 = .{ 0, 0 },
    light: i32 = 0,
    flags: WallFlags,
    runtime_flags: WallRuntimeFlags,
    number: u32 = 0,
    render_flags: WallParts,
    top_height: f32,
    mid_height: f32,
    bottom_height: f32,
    length: f32,
    angle: i16,
    direction: Vec2,
    last_collision_check: u32 = 0,
};

pub const SectorState = struct {
    bounds: [4]f32 = @splat(0),
    original_velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    velocity_present: bool = false,
    flags: SectorFlags,
    runtime_flags: SectorRuntimeFlags,
    number: u32 = 0,
    outline_in_order: bool = false,
    floor_slope: ?Slope,
    ceiling_slope: ?Slope,
    walls: []WallState,
    last_collision_check: u32 = 0,

    pub fn validateSlopes(self: SectorState) !void {
        if ((self.flags.sloped_floor and self.floor_slope == null) or
            (self.flags.sloped_ceiling and self.ceiling_slope == null)) return error.MissingSceneSlope;
    }
};

pub const Scene = struct {
    arena: std.heap.ArenaAllocator,
    sectors: []SectorState,
    /// A pointer so collision code can bump it through a read-only scene.
    /// Copies of a scene share it.
    collision_check: *u32,

    pub fn init(
        allocator: std.mem.Allocator,
        level: *const level_asset.Level,
        angles: *const camera.Angles,
    ) !Scene {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const sectors = try a.alloc(SectorState, level.sectors.len);

        for (level.sectors, sectors) |source, *sector| {
            sector.* = .{
                .original_velocity = source.velocity,
                .velocity_present = source.velocity.x != 0 or source.velocity.y != 0 or source.velocity.z != 0,
                .flags = source.flags,
                .runtime_flags = bits.with(bits.from(SectorRuntimeFlags, source.flags2), .{ .changed = true }),
                .floor_slope = null,
                .ceiling_slope = null,
                .walls = try a.alloc(WallState, source.walls.len),
            };

            if (source.vertices.len != 0) {
                const first_vertex = source.vertices[0];
                sector.bounds = .{ first_vertex.x, first_vertex.x, first_vertex.z, first_vertex.z };

                for (source.vertices[1..]) |vertex| {
                    if (vertex.x <= sector.bounds[0]) sector.bounds[0] = vertex.x;
                    if (sector.bounds[1] <= vertex.x) sector.bounds[1] = vertex.x;
                    if (vertex.z <= sector.bounds[2]) sector.bounds[2] = vertex.z;
                    if (sector.bounds[3] < vertex.z) sector.bounds[3] = vertex.z;
                }
            }

            for (source.walls, sector.walls) |wall, *state| {
                const first = source.vertices[wall.v1];
                const last = source.vertices[wall.v2];
                const dx = last.x - first.x;
                const dz = last.z - first.z;
                const half_squared = f32store(
                    @as(f64, dx) * 0.5 * dx * 0.5 + @as(f64, dz) * 0.5 * dz * 0.5,
                );

                const length = f32store(@sqrt(@as(f64, half_squared)) * 2.0);
                const norm_squared = f32store(@as(f64, dx) * dx + @as(f64, dz) * dz);
                const norm = f32store(@sqrt(@as(f64, norm_squared)));

                state.* = .{
                    .original_start = first,
                    .base_vertices = .{ wall.v1, wall.v2 },
                    .flags = wall.flags,
                    .runtime_flags = .{},
                    .render_flags = .{},
                    .top_height = 0,
                    .mid_height = 0,
                    .bottom_height = 0,
                    .length = length,
                    .angle = wallAngle(dx, dz),
                    .direction = if (norm == 0) .{
                        .x = 0,
                        .z = 0,
                    } else .{ .x = dx / norm, .z = dz / norm },
                };
            }

            if (source.flags.secret) sector.runtime_flags.secret_unfound = true;
        }

        const collision_check = try a.create(u32);
        collision_check.* = 0;
        var result = Scene{
            .arena = arena,
            .sectors = sectors,
            .collision_check = collision_check,
        };

        for (level.sectors, 0..) |source, sector_index| {
            const sector = &sectors[sector_index];

            for (source.walls, sector.walls) |wall, *state| {
                if (!state.flags.not_rail_guide and sector.flags.rail) {
                    state.runtime_flags.rail_guide = true;

                    if (wall.adjoin >= 0 and sectors[@intCast(wall.adjoin)].flags.rail)
                        state.runtime_flags.rail_guide = false;

                    if (wall.dadjoin >= 0 and sectors[@intCast(wall.dadjoin)].flags.rail)
                        state.runtime_flags.rail_guide = false;
                }

                if (sector.flags.rail and sector.flags.sloped_floor) {
                    sector.flags.rail_slope = true;
                    sector.runtime_flags.flags_changed = true;
                }

                if (state.flags.shatters) {
                    if (!state.runtime_flags.glass_ready) makeGlass(state);

                    if (wall.adjoin < 0) return error.DoorWallMissingMirror;

                    const mirror = &sectors[@intCast(wall.adjoin)].walls[@intCast(wall.mirror)];

                    if (!mirror.runtime_flags.glass_ready) makeGlass(mirror);
                }

                if (wall.adjoin >= 0) {
                    const mirror = &sectors[@intCast(wall.adjoin)].walls[@intCast(wall.mirror)];

                    if (state.flags.moves_with_sector) {
                        mirror.flags.moves_with_sector = true;
                        mirror.runtime_flags.flags_changed = true;
                    }

                    if (state.runtime_flags.moved_by_elevator) mirror.runtime_flags.moved_by_elevator = true;
                }
            }

            for ([_]level_asset.Plane{
                source.floor,
                source.ceiling,
            }, [_]SectorFlags{
                .{ .sloped_floor = true },
                .{ .sloped_ceiling = true },
            }, [_]*?Slope{
                &sector.floor_slope,
                &sector.ceiling_slope,
            }) |plane, flag, destination| {
                if (!bits.any(sector.flags, flag)) continue;

                if (plane.slope) |slope| {
                    if (slope.sector >= sectors.len or slope.wall >= sectors[slope.sector].walls.len) {
                        sector.flags = bits.without(sector.flags, flag);
                        sector.runtime_flags.changed = true;
                        sector.runtime_flags.flags_changed = true;
                        continue;
                    }

                    destination.* = try Slope.init(level, sector_index, plane, angles);
                    sectors[slope.sector].walls[slope.wall].runtime_flags.slope_hinge = true;
                }
            }
        }

        for (level.sectors, 0..) |source, sector_index| {
            for (source.walls, 0..) |_, wall_index| try result.prepareWall(
                level,
                sector_index,
                wall_index,
            );

            switch (chain(source, sectors[sector_index])) {
                2 => sectors[sector_index].runtime_flags.convex = true,
                1 => sectors[sector_index].outline_in_order = true,
                else => {},
            }
        }

        return result;
    }

    pub fn startCollisionCheck(self: *const Scene) void {
        self.collision_check.* +%= 1;
    }

    pub fn deinit(self: *Scene) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn floorHeight(
        self: *const Scene,
        level: *const level_asset.Level,
        sector_index: usize,
        point: Vec2,
    ) !f32 {
        if (self.sectors[sector_index].flags.sloped_floor) {
            const slope = self.sectors[sector_index].floor_slope orelse return error.MissingSceneSlope;
            return slope.height(point);
        }

        return level.sectors[sector_index].floor.height;
    }

    pub fn ceilingHeight(
        self: *const Scene,
        level: *const level_asset.Level,
        sector_index: usize,
        point: Vec2,
    ) !f32 {
        if (self.sectors[sector_index].flags.sloped_ceiling) {
            const slope = self.sectors[sector_index].ceiling_slope orelse return error.MissingSceneSlope;
            return slope.height(point);
        }

        return level.sectors[sector_index].ceiling.height;
    }

    pub fn refreshWallHeights(self: *Scene, level: *const level_asset.Level) !void {
        for (level.sectors, 0..) |sector, sector_index| {
            for (sector.walls, 0..) |_, wall_index| try self.prepareWall(
                level,
                sector_index,
                wall_index,
            );
        }
    }

    pub fn prepareWall(
        self: *Scene,
        level: *const level_asset.Level,
        sector_index: usize,
        wall_index: usize,
    ) !void {
        const sector = level.sectors[sector_index];
        const wall = sector.walls[wall_index];
        const state = &self.sectors[sector_index].walls[wall_index];

        state.render_flags = .{};
        state.runtime_flags.changed = true;

        if (wall.adjoin >= 0) {
            const first = sector.vertices[wall.v1];
            const last = sector.vertices[wall.v2];
            const upper: usize = @intCast(wall.adjoin);
            const lower: usize = @intCast(if (wall.dadjoin >= 0) wall.dadjoin else wall.adjoin);
            const own_floor_first = try self.floorHeight(level, sector_index, first);
            const own_floor_last = try self.floorHeight(level, sector_index, last);
            const own_ceiling_first = try self.ceilingHeight(level, sector_index, first);
            const own_ceiling_last = try self.ceilingHeight(level, sector_index, last);
            const other_ceiling_first = snapHeight(
                try self.ceilingHeight(level, upper, first),
                own_ceiling_first,
            );

            const other_ceiling_last = snapHeight(
                try self.ceilingHeight(level, upper, last),
                own_ceiling_last,
            );

            const other_floor_first = snapHeight(
                try self.floorHeight(level, lower, first),
                own_floor_first,
            );

            const other_floor_last = snapHeight(
                try self.floorHeight(level, lower, last),
                own_floor_last,
            );

            state.render_flags = .{ .double_adjoin = wall.dadjoin >= 0 };

            if ((other_ceiling_first <= own_ceiling_first and other_ceiling_last < own_ceiling_last) or
                (other_ceiling_first < own_ceiling_first and other_ceiling_last <= own_ceiling_last)) state.render_flags.top = true;

            if ((own_floor_first <= other_floor_first and own_floor_last < other_floor_last) or
                (own_floor_first < other_floor_first and own_floor_last <= other_floor_last)) state.render_flags.bottom = true;

            if (state.render_flags.top) state.top_height = f32store(
                (@as(f64, sector.ceiling.height) - level.sectors[upper].ceiling.height) * 8.0,
            );

            if (state.render_flags.bottom) state.bottom_height = f32store(
                (@as(f64, level.sectors[lower].floor.height) - sector.floor.height) * 8.0,
            );

            if (wall.dadjoin >= 0) {
                state.mid_height = f32store(
                    (@as(
                        f64,
                        level.sectors[upper].floor.height,
                    ) - level.sectors[lower].ceiling.height) * 8.0,
                );
            } else {
                const ceiling = if (state.render_flags.top) level.sectors[upper].ceiling.height else sector.ceiling.height;
                const floor = if (state.render_flags.bottom) level.sectors[upper].floor.height else sector.floor.height;
                state.mid_height = f32store((@as(f64, ceiling) - floor) * 8.0);
            }
        } else {
            state.mid_height = f32store(
                (@as(f64, sector.ceiling.height) - sector.floor.height) * 8.0,
            );
        }
    }
};

fn snapHeight(value: f32, own: f32) f32 {
    return if (@abs(@as(f64, value) - own) < 0.0001) own else value;
}

fn wallAngle(dx: f32, dz: f32) i16 {
    const radians: f32 = @floatCast(std.math.atan2(@as(f64, dx), @as(f64, dz)));
    const value: i32 = @intFromFloat(@as(f64, radians) * 0.15915494309644432 * 16384.0);

    return @intCast(value & 0x3fff);
}

/// Breakable glass stops walkers and fires its triggers when shot.
fn makeGlass(wall: *WallState) void {
    wall.flags.impassable = true;
    wall.flags.triggers_on_shot = true;
    wall.runtime_flags.flags_changed = true;
    wall.runtime_flags.glass_ready = true;
}

fn chain(sector: level_asset.Sector, state: SectorState) u32 {
    var result: u32 = 2;

    for (sector.walls, 0..) |wall, index| {
        const next = if (index + 1 == sector.walls.len) 0 else index + 1;
        if (wall.v2 != sector.walls[next].v1) return 0;
        const difference: i32 = @as(i32, state.walls[next].angle) - state.walls[index].angle;
        if (result == 2 and difference & 0x3fff > 0x2000) result = 1;
    }

    return result;
}

fn normalize(value: Vec3) Vec3 {
    var sum: f32 = 0;

    if (@abs(value.x) != 0) sum = f32store(@as(f64, value.x) * value.x);

    if (@abs(value.y) != 0) sum = f32store(@as(f64, value.y) * value.y + sum);

    if (@abs(value.z) != 0) sum = f32store(@as(f64, value.z) * value.z + sum);

    const length = @sqrt(@as(f64, sum));
    if (length <= 0) return .{ .x = 0, .y = 0, .z = 0 };

    const inverse: f32 = f32store(1.0 / @as(f64, f32store(length)));

    return .{
        .x = if (@abs(value.x) == 0) 0 else value.x * inverse,
        .y = if (@abs(value.y) == 0) 0 else inverse * value.y,
        .z = if (@abs(value.z) == 0) 0 else inverse * value.z,
    };
}

fn normalizeV111(value: Vec3) Vec3 {
    var sum: f32 = 0;

    if (@abs(value.x) != 0) sum = f32store(@as(f64, value.x) * value.x);

    if (@abs(value.y) != 0) sum = f32store(@as(f64, value.y) * value.y + sum);

    if (@abs(value.z) != 0) sum = f32store(@as(f64, value.z) * value.z + sum);

    const root = @sqrt(@as(f64, sum));
    if (!(root > 0)) return .{ .x = 0, .y = 0, .z = 0 };

    const inverse = 1.0 / @as(f64, f32store(root));
    const stored: f32 = f32store(inverse);

    return .{
        .x = if (@abs(value.x) == 0) 0 else f32store(inverse * value.x),
        .y = if (@abs(value.y) == 0) 0 else stored * value.y,
        .z = if (@abs(value.z) == 0) 0 else stored * value.z,
    };
}

fn dotOrigin(origin: Vec3, axis: Vec3) f32 {
    return f32store(
        @as(f64, origin.x) * axis.x + @as(f64, origin.z) * axis.z + @as(f64, origin.y) * axis.y,
    );
}

fn f32store(value: f64) f32 {
    return @floatCast(value);
}

/// The bits a dropped slope leaves on its sector.
const slope_dropped = SectorRuntimeFlags{ .changed = true, .flags_changed = true };

/// Puts a raw flag word on a sector or wall and returns the old one.
fn swapFlags(level: *level_asset.Level, sector: usize, wall: ?usize, value: u32) u32 {
    if (wall) |index| {
        const flags = &level.sectors[sector].walls[index].flags;
        defer flags.* = bits.from(WallFlags, value);
        return bits.word(flags.*);
    }

    const flags = &level.sectors[sector].flags;
    defer flags.* = bits.from(SectorFlags, value);
    return bits.word(flags.*);
}

fn hashWord(hash: *std.crypto.hash.sha2.Sha256, word: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    hash.update(&bytes);
}

test "CD1 scene prepares every slope and first-sector portal wall" {
    const allocator = std.testing.allocator;
    const archive_module = @import("../assets/lab.zig");
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        allocator,
        .limited(32 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer allocator.free(data);
    const archive = try archive_module.Archive.init(data);
    var level = try level_asset.Level.parse(allocator, try archive.find("hideout.lvb", 0x4c565446));
    defer level.deinit();
    const angles = camera.Angles.init();
    var scene = try Scene.init(allocator, &level, &angles);
    defer scene.deinit();

    try std.testing.expectEqual(@as(usize, 416), scene.sectors.len);
    try std.testing.expectEqual(WallParts{ .double_adjoin = true }, scene.sectors[410].walls[1].render_flags);
    try std.testing.expectEqual(@as(f32, 0), scene.sectors[410].walls[1].top_height);

    for (level.sectors, scene.sectors) |source, state| {
        for ([_]?Slope{ state.floor_slope, state.ceiling_slope }) |maybe_slope| {
            if (maybe_slope) |slope| {
                try std.testing.expect(std.math.isFinite(slope.coeff_x));
                try std.testing.expect(std.math.isFinite(slope.coeff_z));

                for (source.vertices) |point| {
                    const y = slope.height(point);
                    try std.testing.expect(y >= slope.min_y and y <= slope.max_y);
                }
            }
        }
    }

    var slope_hash = std.crypto.hash.sha2.Sha256.init(.{});
    var wall_hash = std.crypto.hash.sha2.Sha256.init(.{});

    for (level.sectors, scene.sectors) |source, state| {
        for ([_]level_asset.Plane{
            source.floor,
            source.ceiling,
        }, [_]?Slope{ state.floor_slope, state.ceiling_slope }) |plane, maybe_slope| {
            if (maybe_slope) |slope| {
                const hinge_sector = level.sectors[plane.slope.?.sector];
                const first = hinge_sector.vertices[hinge_sector.walls[plane.slope.?.wall].v1];
                const values = [_]f32{
                    slope.min_y,
                    slope.max_y,
                    slope.coeff_x,
                    slope.coeff_z,
                    first.x,
                    plane.height,
                    first.z,
                    slope.origin.x,
                    slope.origin.y,
                    slope.origin.z,
                    slope.constant,
                    slope.u_axis.x,
                    slope.u_axis.y,
                    slope.u_axis.z,
                    slope.v_axis.x,
                    slope.v_axis.y,
                    slope.v_axis.z,
                    slope.u_offset,
                    slope.v_offset,
                };

                for (values) |value| hashWord(&slope_hash, @bitCast(value));
            }
        }

        for (state.walls) |wall| {
            hashWord(&wall_hash, bits.word(wall.render_flags));
            hashWord(&wall_hash, @bitCast(wall.top_height));
            hashWord(&wall_hash, @bitCast(wall.mid_height));
            hashWord(&wall_hash, @bitCast(wall.bottom_height));
        }
    }

    var digest: [32]u8 = undefined;
    wall_hash.final(&digest);
    try std.testing.expectEqualStrings(
        "8c98123e3ef937d8736abd59fb8fca91ac1a41dd0067bfef2dd13eea42882d26",
        &std.fmt.bytesToHex(digest, .lower),
    );

    slope_hash.final(&digest);
    try std.testing.expectEqualStrings(
        "0531e1aa89d451ffe41291b886969a808c7f6a00880886756c840c6d06356cfa",
        &std.fmt.bytesToHex(digest, .lower),
    );
}

test "all shipped slope hinges match loader normalization and planes" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/loader-slopes-reference.json",
        a,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Fixture = struct {
        maps: []const struct {
            name: []const u8,
            sectors: []const struct { flags: u32, runtime: u32, planes: [2]?[19]u32 },
        },
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer fixture.deinit();
    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(128 * 1024 * 1024),
    );

    defer a.free(data);
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    const angles = camera.Angles.init();
    var discarded: usize = 0;

    for (fixture.value.maps) |map| {
        errdefer std.debug.print("slope normalization failed: {s}\n", .{map.name});
        var level = try level_asset.Level.parse(a, try archive.find(map.name, 0));
        defer level.deinit();
        var scene = try Scene.init(a, &level, &angles);
        defer scene.deinit();

        try std.testing.expectEqual(map.sectors.len, scene.sectors.len);

        for (level.sectors, scene.sectors, map.sectors) |source, state, expected| {
            const expected_flags = bits.from(SectorFlags, expected.flags);

            try std.testing.expectEqual(expected_flags.sloped_floor, state.flags.sloped_floor);
            try std.testing.expectEqual(expected_flags.sloped_ceiling, state.flags.sloped_ceiling);

            for ([_]level_asset.Plane{
                source.floor,
                source.ceiling,
            }, [_]?Slope{
                state.floor_slope,
                state.ceiling_slope,
            }, expected.planes) |plane, slope, original| {
                if (original) |words| {
                    const actual = slope orelse return error.MissingOriginalSlope;
                    const hinge_sector = level.sectors[plane.slope.?.sector];
                    const first = hinge_sector.vertices[hinge_sector.walls[plane.slope.?.wall].v1];
                    const values = [_]f32{
                        actual.min_y,
                        actual.max_y,
                        actual.coeff_x,
                        actual.coeff_z,
                        first.x,
                        plane.height,
                        first.z,
                        actual.origin.x,
                        actual.origin.y,
                        actual.origin.z,
                        actual.constant,
                        actual.u_axis.x,
                        actual.u_axis.y,
                        actual.u_axis.z,
                        actual.v_axis.x,
                        actual.v_axis.y,
                        actual.v_axis.z,
                        actual.u_offset,
                        actual.v_offset,
                    };

                    for (words, values) |word, value| try std.testing.expectEqual(
                        word,
                        @as(u32, @bitCast(value)),
                    );
                } else {
                    try std.testing.expect(slope == null);

                    if (plane.slope != null) {
                        discarded += 1;
                        try std.testing.expectEqual(
                            bits.only(bits.from(SectorRuntimeFlags, expected.runtime), slope_dropped),
                            bits.only(state.runtime_flags, slope_dropped),
                        );
                    }
                }
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 11), discarded);
}

test "CD1 loader flags and runtime slope changes match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/scene-flags-reference.json",
        a,
        .limited(2 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Change = struct {
        sector: usize,
        wall: ?usize = null,
        flags: u32,
    };

    const Fixture = struct {
        loader: []struct { changes: []Change, sha256: []const u8 },
        preparation: []struct {
            sector: usize,
            flags: u32,
            walls: []struct {
                sector: usize,
                wall: usize,
                render_flags: u32,
                runtime_flags: u32,
                heights: [3]u32,
            },
        },
    };

    const fixture = try std.json.parseFromSlice(
        Fixture,
        a,
        bytes,
        .{ .ignore_unknown_fields = true },
    );

    defer fixture.deinit();
    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "inputs/OUTLAWS_CD1/OUTLAWS/OLGEO.LAB",
        a,
        .limited(32 * 1024 * 1024),
    );

    defer a.free(data);
    const archive = try @import("../assets/lab.zig").Archive.init(data);
    var level = try level_asset.Level.parse(a, try archive.find("hideout.lvb", 0x4c565446));
    defer level.deinit();
    const angles = camera.Angles.init();

    for (fixture.value.loader) |case| {
        const saved = try a.alloc(u32, case.changes.len);
        defer a.free(saved);

        for (case.changes, saved) |change, *original| original.* = swapFlags(&level, change.sector, change.wall, change.flags);

        defer for (case.changes, saved) |change, original| {
            _ = swapFlags(&level, change.sector, change.wall, original);
        };

        var scene = try Scene.init(a, &level, &angles);
        defer scene.deinit();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});

        for (scene.sectors) |sector| {
            hashWord(&hash, bits.word(sector.flags));
            hashWord(&hash, bits.word(bits.only(sector.runtime_flags, slope_dropped)));

            for (sector.walls) |wall| {
                hashWord(&hash, bits.word(wall.flags));
                hashWord(&hash, bits.word(bits.only(wall.runtime_flags, .{
                    .changed = true,
                    .flags_changed = true,
                    .glass_ready = true,
                    .rail_guide = true,
                })));
            }
        }

        var digest: [32]u8 = undefined;
        hash.final(&digest);
        try std.testing.expectEqualStrings(case.sha256, &std.fmt.bytesToHex(digest, .lower));
    }

    var scene = try Scene.init(a, &level, &angles);
    defer scene.deinit();

    for (fixture.value.preparation) |case| {
        const saved = scene.sectors[case.sector].flags;
        defer scene.sectors[case.sector].flags = saved;

        scene.sectors[case.sector].flags = bits.from(SectorFlags, case.flags);

        for (case.walls) |expected| {
            const wall = &scene.sectors[expected.sector].walls[expected.wall];

            wall.top_height = 1;
            wall.mid_height = 2;
            wall.bottom_height = 3;
            wall.render_flags = .{ .top = true, .bottom = true, .double_adjoin = true };
            wall.runtime_flags = .{ .flags_changed = true, .rail_guide = true, .seen = true };

            try scene.prepareWall(&level, expected.sector, expected.wall);

            try std.testing.expectEqual(expected.render_flags, bits.word(wall.render_flags));
            try std.testing.expectEqual(expected.runtime_flags, bits.word(wall.runtime_flags));
            try std.testing.expectEqual(
                expected.heights,
                [_]u32{
                    @bitCast(wall.top_height),
                    @bitCast(wall.mid_height),
                    @bitCast(wall.bottom_height),
                },
            );
        }
    }

    const invalid = find: {
        for (level.sectors, scene.sectors, 0..) |source, state, sector| {
            if (state.floor_slope != null or state.ceiling_slope != null) continue;
            for (source.walls, 0..) |wall, index| if (wall.adjoin >= 0)
                break :find .{ .sector = sector, .wall = index };
        }

        return error.MissingOriginalFlatPortal;
    };

    const state = &scene.sectors[invalid.sector];
    const flags = state.flags;
    defer state.flags = flags;

    for ([_]bool{ true, false }) |floor| {
        state.flags = flags;
        if (floor) state.flags.sloped_floor = true else state.flags.sloped_ceiling = true;
        const point = level.sectors[invalid.sector].vertices[0];

        if (floor)
            try std.testing.expectError(
                error.MissingSceneSlope,
                scene.floorHeight(&level, invalid.sector, point),
            )
        else
            try std.testing.expectError(
                error.MissingSceneSlope,
                scene.ceilingHeight(&level, invalid.sector, point),
            );

        try std.testing.expectError(
            error.MissingSceneSlope,
            scene.prepareWall(&level, invalid.sector, invalid.wall),
        );

        try std.testing.expectError(error.MissingSceneSlope, scene.refreshWallHeights(&level));
    }
}

test "collision check number goes up by one and wraps at the 32-bit limit" {
    var collision_check: u32 = 41;
    const scene = Scene{ .arena = undefined, .sectors = &.{}, .collision_check = &collision_check };

    scene.startCollisionCheck();
    try std.testing.expectEqual(@as(u32, 42), collision_check);
    collision_check = std.math.maxInt(u32);
    scene.startCollisionCheck();
    try std.testing.expectEqual(@as(u32, 0), collision_check);
}
