//! The player against the world: walls, floors, ceilings, portals and other
//! actors.
//!
//! Actors are tested in sector-membership order, and actors created after
//! the level loaded come before the player in that order. The order decides
//! which of two touching actors wins, so it is part of the behaviour.

const std = @import("std");

const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");
const Actor = @import("../render/objects.zig").Actor;
const actor_links = @import("../render/actor_links.zig");
const script_runtime = @import("../script/runtime.zig");
const bits = @import("../util/bits.zig");
const ActorFlags = @import("../actor_flags.zig").ActorFlags;
const ActorKind = @import("../actor_flags.zig").ActorKind;
const Vec2 = level_module.Vec2;
const Vec3 = level_module.Vec3;

pub const Body = struct {
    position: Vec3,
    sector: usize,
    height: f32,
    radius: f32,
    flags: ActorFlags,
    secondary_flags: ActorKind,
    sector_link_order: u64 = std.math.maxInt(u64),
};

pub const ActorLoader = struct {
    context: *anyopaque,
    load: *const fn (*anyopaque, usize) anyerror!void,
};

pub const Actors = struct {
    entries: []const Actor,
    links: ?*const actor_links.Links = null,
    source_to_entry: ?[]const ?usize = null,
    live_source_to_entry: ?*const []?usize = null,
    live_entries: ?*const []Actor = null,
    live_slots: ?*const []?Actor = null,
    loader: ?ActorLoader = null,
    player: ?Body = null,
    player_before_source: ?usize = null,
    loaded_sectors: ?[]const bool = null,
    required_sectors: ?[]bool = null,
    runtime: ?*script_runtime.Context = null,
    allow_pickups: bool = true,

    pub const SectorIterator = struct {
        actors: Actors,
        sector: usize,
        source: ?usize,
        advance_pending: bool = false,
        remaining: usize,
        player_index: usize,

        pub fn next(self: *SectorIterator) ?usize {
            if (self.actors.links) |links| {
                if (self.advance_pending) {
                    self.source = links.next(self.source.?);
                    self.advance_pending = false;
                }

                while (self.source) |source| {
                    if (source == actor_links.player_id) {
                        if (self.actors.player != null) {
                            self.advance_pending = true;
                            return actor_links.player_id;
                        }
                    } else if ((if (self.actors.live_source_to_entry) |map| map.* else self.actors.source_to_entry.?)[source]) |index| {
                        self.advance_pending = true;
                        return index;
                    }

                    self.source = links.next(source);
                }

                return null;
            }

            const entries = self.actors.all();

            while (self.remaining != 0) {
                self.remaining -= 1;
                const index = self.remaining;

                if (self.actors.player) |player| {
                    if (index == self.player_index) {
                        if (player.sector == self.sector) return actor_links.player_id;
                        continue;
                    }
                }

                const entry = if (self.actors.player != null and index > self.player_index) index - 1 else index;
                if (entries[entry].sector == self.sector) return entry;
            }

            return null;
        }
    };

    pub fn all(self: Actors) []const Actor {
        return if (self.live_entries) |entries| entries.* else self.entries;
    }

    pub fn get(self: Actors, index: usize) Actor {
        const entry = self.all()[index];
        if (self.live_slots) |slots| if (entry.source_index) |source| return slots.*[source].?;

        return entry;
    }

    pub fn requireSector(self: Actors, sector: usize) !void {
        if (self.required_sectors) |required| required[sector] = true;

        if (self.loaded_sectors) |loaded| if (!loaded[sector]) {
            if (self.loader) |loader| {
                try loader.load(loader.context, sector);
                if (loaded[sector]) return;
            }

            return error.CollisionActorsNotLoaded;
        };
    }

    pub fn inSector(self: Actors, sector: usize) !SectorIterator {
        try self.requireSector(sector);

        return self.inLoadedSector(sector);
    }

    pub fn inLoadedSector(self: Actors, sector: usize) SectorIterator {
        return .{
            .actors = self,
            .sector = sector,
            .source = if (self.links) |links| links.first(sector) else null,
            .remaining = self.all().len + @as(usize, if (self.player != null) 1 else 0),
            .player_index = if (self.links == null) self.playerIndex() else 0,
        };
    }

    pub fn playerIndex(self: Actors) usize {
        const entries = self.all();
        const body = self.player orelse return entries.len;
        if (body.sector_link_order == std.math.maxInt(u64)) {
            if (self.player_before_source) |threshold| {
                for (entries, 0..) |entry, index| {
                    if (entry.source_index) |source| if (source >= threshold) return index;
                }
            }

            return entries.len;
        }

        for (entries, 0..) |entry, index| {
            if (entry.sector_link_order > body.sector_link_order) return index;
        }

        return entries.len;
    }
};

pub const Result = struct {
    sector: ?usize,
    actor_sector: usize,
    position: Vec3,
    contact_kind: ContactKind = .none,
    actor_flags_dirty: bool = false,
};

pub const ContactKind = enum { none, wall, actor, slope };

pub const Options = struct {
    exclude_source: ?usize = null,
    exclude_owner: ?usize = null,
    contact_sink: ?ContactSink = null,
    query_observer: ?QueryObserver = null,
    projection: ?*@import("../projectile/contact.zig").Projection = null,
    drop_height: f32 = 0x1p31,
    /// Walls with any of these flags block too.
    wall_block_mask: level_module.WallFlags = .{},
    impassable_walls: bool = true,
    slide_walls: bool = true,
    rail_mode: bool = false,
    wall_memory: ?*WallMemory = null,
};

pub const WallMemory = struct {
    last: ?Line = null,

    pub const Line = struct { direction: Vec2, origin: Vec2 };
};

pub const Wall = struct { sector: usize, index: usize };

pub const ContactEvent = struct {
    kind: ContactKind,
    wall: ?Wall = null,
    actor: ?usize = null,
    origin: Vec2 = .{ .x = 0, .z = 0 },
    crossed: bool = false,
};

pub const ContactSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, ContactEvent) anyerror!void,
};

pub const QueryObservation = struct {
    position: Vec3,
    delta: Vec2,
    height: f32,
    radius: f32,
    step: f32,
    drop: f32,
    moving: bool,
    initial_velocity: Vec3,
};

pub const QueryObserver = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, QueryEvent) void,
};

pub const QueryEvent = union(enum) {
    query: QueryObservation,
    subdivision: struct { rounded: i32, reciprocal: f32 },
    halted: bool,
    contact: struct {
        kind: ContactKind,
        actor_written: bool = false,
        actor: ?usize = null,
        direction: ?Vec2 = null,
        height: ?f32 = null,
    },
};

const Contacts = struct { indices: [20]usize = undefined, count: usize = 0 };

const Contact = struct {
    kind: ContactKind = .none,
    wall: ?Wall = null,
    direction: Vec2 = .{ .x = 0, .z = 0 },
    direction_known: bool = false,
    origin: Vec2 = .{ .x = 0, .z = 0 },
    ceiling: f32 = 0x1p31,
    floor: f32 = -0x1p31,
    gap: f32 = 0x1p31,
    actor: ?usize = null,
};

const Query = struct {
    position: Vec3,
    radius: f32,
    height: f32,
    sector: usize,
    delta: Vec2,
    step: f32,
    drop: f32,
};

const Context = struct {
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    actors: Actors,
    options: Options,
    actor_position: Vec3,
    actor_sector: usize,
    height: f32,
    radius: f32,
    step: f32,
    contact: Contact = .{},
    last_wall: ?Wall = null,
    last_sector: ?usize = null,
    actor_flags_dirty: bool = false,
    rail_wall_filter: bool = false,

    fn result(self: *const Context, sector: ?usize) Result {
        return .{
            .sector = sector,
            .actor_sector = self.actor_sector,
            .position = self.actor_position,
            .contact_kind = self.contact.kind,
            .actor_flags_dirty = self.actor_flags_dirty,
        };
    }

    fn query(self: *const Context, sector: usize, point: Vec3) Query {
        return .{
            .position = point,
            .radius = self.radius,
            .height = self.height,
            .sector = sector,
            .delta = .{
                .x = point.x - self.actor_position.x,
                .z = point.z - self.actor_position.z,
            },
            .step = self.step,
            .drop = self.options.drop_height,
        };
    }

    fn observeQuery(self: *const Context, value: Query, moving: bool, initial_velocity: Vec3) void {
        if (self.options.query_observer) |observer| observer.emit(observer.context, .{ .query = .{
            .position = value.position,
            .delta = value.delta,
            .height = value.height,
            .radius = value.radius,
            .step = value.step,
            .drop = value.drop,
            .moving = moving,
            .initial_velocity = initial_velocity,
        } });
    }

    fn slide(self: *Context, sector: usize, old: Vec3, desired: *Vec3, velocity: *Vec3) !?usize {
        var delta = Vec3{ .x = desired.x - old.x, .y = 0, .z = desired.z - old.z };
        var current: ?usize = sector;
        var pickup_filter = true;

        for (0..10) |_| {
            if (@abs(delta.x) == 0 and @abs(delta.z) == 0) return current;

            desired.x = f(@as(f64, old.x) + delta.x);
            desired.z = f(@as(f64, old.z) + delta.z);
            current = try self.cross(sector, old, desired, &delta, velocity);

            const next = current orelse continue;
            var q = self.query(next, desired.*);

            q.radius = f(@as(f64, self.radius) + 1.0);

            if (self.actors.allow_pickups) if (self.actors.runtime) |runtime| {
                const contacts = try self.actorContacts(q, pickup_filter);
                for (contacts.indices[0..contacts.count]) |index| {
                    if (index != actor_links.player_id) try runtime.touch(self.actors.get(index));
                }
            };

            q.radius = self.radius;
            self.actor_flags_dirty = true;
            pickup_filter = false;

            if ((try self.actorContacts(q, false)).count != 0) {
                try self.project(&delta);
                try self.contactEvent(false);
                continue;
            }

            if (self.options.rail_mode) self.rail_wall_filter = true;

            if (!try self.geometry(q)) {
                self.actor_position.x = desired.x;
                self.actor_position.z = desired.z;

                if (self.actors.runtime) |runtime| try runtime.changeSector(
                    self.actor_sector,
                    next,
                );

                self.actor_sector = next;
                return next;
            }

            if (!self.options.slide_walls) return next;

            if (self.contact.kind == .wall or self.contact.kind == .slope) {
                if (!self.contact.direction_known) {
                    const line = (if (self.options.wall_memory) |memory| memory.last else null) orelse return next;
                    self.contact.direction = line.direction;
                    self.contact.origin = line.origin;
                    self.contact.direction_known = true;
                }

                try self.project(&delta);

                if (self.contact.kind == .wall) _ = self.bounce(
                    velocity,
                    self.contact.wall.?,
                    self.level.sectors[next].elasticity,
                );

                try self.contactEvent(false);
            }
        }

        return current;
    }

    fn contactEvent(self: *const Context, crossed: bool) !void {
        if (self.options.contact_sink) |sink| try sink.emit(
            sink.context,
            .{
                .kind = self.contact.kind,
                .wall = self.contact.wall,
                .actor = self.contact.actor,
                .origin = self.contact.origin,
                .crossed = crossed,
            },
        );
    }

    fn crossEvent(self: *const Context, wall: Wall) !void {
        if (self.options.contact_sink) |sink| try sink.emit(
            sink.context,
            .{ .kind = .wall, .wall = wall, .crossed = true },
        );
    }

    fn project(self: *const Context, delta: *Vec3) !void {
        if (!self.contact.direction_known) return error.UnsupportedSectorCollisionContact;

        const d = self.contact.direction;
        const tangent = f(@as(f64, d.x) * delta.x + @as(f64, d.z) * delta.z);
        const push = f(
            (@as(
                f64,
                self.radius,
            ) + 0.001) - ((@as(
                f64,
                self.actor_position.x,
            ) - self.contact.origin.x) * d.z - (@as(
                f64,
                self.actor_position.z,
            ) - self.contact.origin.z) * d.x),
        );

        delta.x = f(@as(f64, d.z) * push + @as(f64, d.x) * tangent);
        delta.z = f(@as(f64, tangent) * d.z - @as(f64, d.x) * push);
    }

    fn cross(
        self: *Context,
        start: usize,
        old: Vec3,
        point: *Vec3,
        delta: *Vec3,
        velocity: ?*Vec3,
    ) !?usize {
        self.scene.startCollisionCheck();

        var previous_distance: f32 = -0x1p31;
        var sector = start;
        var first = true;

        while (self.nextWall(sector, old, point.*, &previous_distance)) |wall| {
            const source = self.level.sectors[wall.sector].walls[wall.index];
            const state = self.scene.sectors[wall.sector].walls[wall.index];
            if (state.flags.impassable and (self.options.rail_mode or !state.runtime_flags.rail_guide)) {
                self.cut(old, point, delta, wall);
                try self.crossEvent(wall);
                if (first) {
                    if (velocity) |value| _ = self.bounce(
                        value,
                        wall,
                        self.level.sectors[sector].elasticity,
                    );

                    delta.x = 0;
                    delta.z = 0;
                    return null;
                }

                return sector;
            }

            first = false;

            if (self.actors.runtime) |runtime| try runtime.crossWall(
                self.level,
                wall.sector,
                wall.index,
            );

            var next: ?usize = null;

            if (source.dadjoin >= 0 and try self.fits(
                @intCast(source.dadjoin),
                point.*,
            )) next = @intCast(source.dadjoin);

            if (next == null and source.adjoin >= 0 and try self.fits(
                @intCast(source.adjoin),
                point.*,
            )) next = @intCast(source.adjoin);

            if (next == null) {
                if (velocity) |value| _ = self.bounce(
                    value,
                    wall,
                    self.level.sectors[sector].elasticity,
                );

                try self.crossEvent(wall);

                delta.x = 0;
                delta.z = 0;
                return null;
            }

            sector = next.?;
        }

        return sector;
    }

    fn nextWall(self: *Context, sector: usize, old: Vec3, point: Vec3, previous: *f32) ?Wall {
        if (point.x - old.x == 0 and point.z - old.z == 0) return null;

        var best: ?Wall = null;
        var distance: f32 = 0x1p31;
        const source = self.level.sectors[sector];

        for (source.walls, self.scene.sectors[sector].walls, 0..) |wall, state, index| {
            if (state.last_collision_check == self.scene.collision_check.*) continue;

            const hit = intersection(
                .{ .x = old.x, .z = old.z },
                .{ .x = point.x, .z = point.z },
                source.vertices[wall.v1],
                source.vertices[wall.v2],
            ) orelse continue;

            if (old.x == hit.x and old.z == hit.z and 0 <= (@as(
                f64,
                point.x,
            ) - old.x) * state.direction.z - (@as(
                f64,
                point.z,
            ) - old.z) * state.direction.x) continue;

            const dx = @abs(f(hit.x - @as(f64, old.x)));
            const dz = @abs(f(hit.z - @as(f64, old.z)));
            const exact_distance = (@as(f64, dx) - @as(f64, @min(dx, dz)) * 0.25 * 2.0) + dz;
            const stored_distance = f(exact_distance);

            if (exact_distance < distance and previous.* < stored_distance) {
                distance = stored_distance;
                best = .{ .sector = sector, .index = index };
            }
        }

        if (best) |wall| {
            self.markWall(wall);

            for (mirrors(source.walls[wall.index])) |mirror| if (mirror) |m| {
                self.markWall(m);
                for (mirrors(
                    self.level.sectors[m.sector].walls[m.index],
                )) |second| if (second) |s| self.markWall(s);
            };

            previous.* = distance;
        }

        return best;
    }

    fn mirrors(wall: level_module.Wall) [2]?Wall {
        return .{
            if (wall.adjoin < 0) null else .{
                .sector = @intCast(wall.adjoin),
                .index = @intCast(wall.mirror),
            },
            if (wall.dadjoin < 0) null else .{
                .sector = @intCast(wall.dadjoin),
                .index = @intCast(wall.dmirror),
            },
        };
    }

    fn markWall(self: *Context, wall: Wall) void {
        self.scene.sectors[wall.sector].walls[wall.index].last_collision_check = self.scene.collision_check.*;
    }

    fn fits(self: *const Context, sector: usize, point: Vec3) !bool {
        const limits = try self.bounds(sector, point, true);
        if (self.step != -1 and self.step < @as(f64, limits.floor) - point.y) return false;

        return !(limits.ceiling < f(@as(f64, point.y) + self.height));
    }

    fn bounds(
        self: *const Context,
        sector: usize,
        point: Vec3,
        x_first: bool,
    ) error{MissingCollisionSlope}!struct { floor: f32, ceiling: f32 } {
        const source = self.level.sectors[sector];
        var lower = sector;
        var upper = sector;

        if (source.vadjoin >= 0) {
            const other: usize = @intCast(source.vadjoin);
            if (source.floor.height < self.level.sectors[other].floor.height) upper = other else lower = other;
        }

        const upper_state = self.scene.sectors[upper];
        const lower_state = self.scene.sectors[lower];
        const ceiling_flags = if (x_first) self.scene.sectors[sector].flags else upper_state.flags;
        const floor_flags = if (x_first) self.scene.sectors[sector].flags else lower_state.flags;
        const ceiling = if (ceiling_flags.sky_ceiling) @as(
            f32,
            0x1p31,
        ) else if (ceiling_flags.sloped_ceiling) slopeHeight(
            upper_state.ceiling_slope orelse return error.MissingCollisionSlope,
            point,
            x_first,
        ) else self.level.sectors[upper].ceiling.height;

        const floor = if (floor_flags.sloped_floor) slopeHeight(
            lower_state.floor_slope orelse return error.MissingCollisionSlope,
            point,
            x_first,
        ) else self.level.sectors[lower].floor.height;

        return .{ .floor = floor, .ceiling = ceiling };
    }

    fn geometry(self: *Context, q: Query) !bool {
        if (self.actors.runtime) |runtime| if (runtime.collision_diameter) |diameter| {
            diameter.* = f(@as(f64, q.radius) * 2.0);
        };

        self.scene.startCollisionCheck();

        self.last_wall = null;
        self.last_sector = null;
        self.contact.ceiling = 0x1p31;
        self.contact.floor = -0x1p31;
        self.contact.gap = 0x1p31;
        if (!try self.geometrySector(q, q.sector)) return false;

        if (self.last_wall) |wall| {
            self.contact.kind = .wall;
            self.contact.wall = wall;
            self.contact.direction = self.scene.sectors[wall.sector].walls[wall.index].direction;
            self.contact.direction_known = true;
            self.contact.origin = self.level.sectors[wall.sector].vertices[self.level.sectors[wall.sector].walls[wall.index].v1];

            self.recordProjection();

            if (self.options.wall_memory) |memory| memory.last = .{
                .direction = self.contact.direction,
                .origin = self.contact.origin,
            };

            if (self.options.query_observer) |observer| observer.emit(
                observer.context,
                .{
                    .contact = .{
                        .kind = .wall,
                        .direction = self.contact.direction,
                        .height = self.level.sectors[wall.sector].floor.height,
                    },
                },
            );
        } else if (self.last_sector) |sector| {
            self.contact.kind = .slope;

            const definition = if (self.scene.sectors[sector].ceiling_slope != null) self.level.sectors[sector].ceiling.slope else null;
            const hinge = definition orelse {
                if (self.options.query_observer) |observer| observer.emit(
                    observer.context,
                    .{ .contact = .{ .kind = .slope } },
                );

                return true;
            };

            self.contact.wall = .{ .sector = hinge.sector, .index = hinge.wall };
            self.contact.direction = self.scene.sectors[hinge.sector].walls[hinge.wall].direction;
            self.contact.direction_known = true;
            self.contact.origin = .{ .x = q.position.x, .z = q.position.z };

            self.recordProjection();

            if (self.options.query_observer) |observer| observer.emit(
                observer.context,
                .{
                    .contact = .{
                        .kind = .slope,
                        .direction = self.contact.direction,
                        .height = q.height,
                    },
                },
            );
        }

        return true;
    }

    fn recordProjection(self: *const Context) void {
        if (self.options.projection) |projection| projection.write(
            self.contact.direction,
            self.contact.origin,
        );
    }

    fn geometrySector(self: *Context, q: Query, sector: usize) error{MissingCollisionSlope}!bool {
        self.last_sector = sector;

        const limits = try self.bounds(sector, q.position, false);
        if (@as(
            f64,
            q.step,
        ) + q.position.y < limits.floor or limits.floor < @as(
            f64,
            q.position.y,
        ) - q.drop or limits.ceiling < @as(f64, q.height) + q.position.y) return true;

        self.contact.ceiling = @min(self.contact.ceiling, limits.ceiling);
        self.contact.floor = @max(self.contact.floor, limits.floor);
        self.contact.gap = @min(self.contact.gap, f(@as(f64, limits.ceiling) - limits.floor));
        if (self.contact.gap < q.height) return true;

        self.scene.sectors[sector].last_collision_check = self.scene.collision_check.*;

        for (self.level.sectors[sector].walls, self.scene.sectors[sector].walls, 0..) |wall, state, index| {
            self.last_wall = .{ .sector = sector, .index = index };

            const blocked = self.options.impassable_walls and state.flags.impassable;
            const has_adjoin = wall.adjoin >= 0 and !blocked;
            const has_double = wall.dadjoin >= 0 and !blocked;

            if (!touches(q, self.level.sectors[sector].vertices[wall.v1], state)) continue;

            if (self.rail_wall_filter and !state.runtime_flags.rail_guide) return true;

            if (bits.any(state.flags, self.options.wall_block_mask)) return true;

            if (has_adjoin or has_double) {
                var collision = false;

                if (has_adjoin and self.scene.sectors[
                    @intCast(
                        wall.adjoin,
                    )
                ].last_collision_check != self.scene.collision_check.*) collision = try self.geometrySector(q, @intCast(wall.adjoin));

                if (collision) {
                    if (has_double) collision = try self.geometrySector(q, @intCast(wall.dadjoin));
                    if (collision) return true;
                }
            } else if (0 <= -@as(
                f64,
                q.delta.x,
            ) * state.direction.z - -@as(f64, q.delta.z) * state.direction.x and
                @as(
                    f64,
                    q.delta.x,
                ) * state.direction.z - @as(f64, q.delta.z) * state.direction.x <= 0) return true;
        }

        return false;
    }

    fn actorContacts(self: *Context, q: Query, pickups: bool) !Contacts {
        var contacts: Contacts = .{};
        try self.actorsInSector(q, q.sector, pickups, &contacts.indices, &contacts.count);
        const sector = self.level.sectors[q.sector];

        for (sector.walls) |wall| {
            const adjoining = if (wall.dadjoin >= 0) wall.dadjoin else wall.adjoin;

            if (adjoining < 0) continue;

            const first = sector.vertices[wall.v1];
            const last = sector.vertices[wall.v2];
            const dx = f(@as(f64, q.position.x) - first.x);
            const dz = f(@as(f64, q.position.z) - first.z);

            if (@as(
                f64,
                dx,
            ) * dx + ((@as(
                f64,
                dz,
            ) * dz - (@as(
                f64,
                last.z,
            ) - first.z) * dz) - (@as(
                f64,
                last.x,
            ) - first.x) * dx) <= @as(f64, q.radius) * q.radius)
                try self.actorsInSector(
                    q,
                    @intCast(adjoining),
                    pickups,
                    &contacts.indices,
                    &contacts.count,
                );
        }

        return contacts;
    }

    fn actorsInSector(
        self: *Context,
        q: Query,
        sector: usize,
        pickups: bool,
        seen: *[20]usize,
        count: *usize,
    ) !void {
        var iterator = try self.actors.inSector(sector);

        while (count.* < 20) {
            const body_index = iterator.next() orelse break;
            const is_player = body_index == actor_links.player_id;

            if (is_player and (self.options.exclude_source == actor_links.player_id or self.options.exclude_owner == actor_links.player_id)) continue;

            const actor: Body = if (is_player) self.actors.player.? else actor: {
                const entry = self.actors.get(body_index);

                if (self.options.exclude_source) |source| if (entry.source_index == source) continue;

                if (self.options.exclude_owner) |source| if (entry.source_index == source) continue;

                if (self.actors.runtime) |runtime| if (runtime.isRemoved(entry)) continue;

                break :actor .{
                    .position = entry.position,
                    .sector = entry.sector,
                    .height = entry.height,
                    .radius = entry.collision_radius,
                    .flags = entry.flags,
                    .secondary_flags = entry.secondary_flags,
                };
            };

            if (actor.sector != sector or actor.flags.not_solid) continue;

            if (pickups) {
                if (!actor.secondary_flags.item) continue;
            } else if (actor.secondary_flags.item or @as(
                u32,
                @bitCast(actor.radius),
            ) > 0x80000000) continue;

            const radius = @abs(actor.radius);
            var body_height = actor.height;
            var bottom = actor.position.y;

            if (@as(u32, @bitCast(body_height)) > 0x80000000) {
                body_height = -body_height;

                const state = self.scene.sectors[sector];
                const ceiling = if (state.flags.sloped_ceiling)
                    slopeHeight(
                        state.ceiling_slope orelse return error.MissingCollisionSlope,
                        actor.position,
                        true,
                    )
                else
                    self.level.sectors[sector].ceiling.height;

                bottom = f(@as(f64, ceiling) - body_height);
            }

            const span = f(@as(f64, q.radius) + radius);

            if (radius == 0 or body_height == 0 or !(@abs(
                f(@as(f64, actor.position.x) - q.position.x),
            ) < span and @abs(
                f(@as(f64, actor.position.z) - q.position.z),
            ) < span and q.position.y < @as(
                f64,
                body_height,
            ) + bottom and bottom < @as(f64, q.height) + q.position.y)) continue;

            if (std.mem.indexOfScalar(usize, seen[0..count.*], body_index) != null) continue;

            const magnitude = length(q.delta.x, q.delta.z);
            const nx: f32 = if (magnitude == 0) 0 else f(@as(f64, q.delta.x) / magnitude);
            const nz: f32 = if (magnitude == 0) 0 else f(@as(f64, q.delta.z) / magnitude);
            const sx: i32 = if (@as(u32, @bitCast(q.delta.x)) > 0x80000000) -1 else 1;
            const sz: i32 = if (@as(u32, @bitCast(q.delta.z)) > 0x80000000) -1 else 1;
            const edge_x = f(
                @as(f64, actor.position.x) + (if (sx < 0) @as(f64, radius) else -@as(f64, radius)),
            );

            const edge_z = f(
                @as(f64, actor.position.z) + (if (sz < 0) @as(f64, radius) else -@as(f64, radius)),
            );

            const along_x = (@as(f64, edge_x) - q.position.x) * nz;
            const along_z = (@as(f64, edge_z) - q.position.z) * nx;

            self.contact.kind = .actor;
            self.contact.actor = body_index;

            const side: i32 = if (along_x - along_z < 0) -1 else 1;

            if ((side ^ sz ^ sx) < 0) {
                self.contact.direction = .{ .x = if (sz < 0) -1 else 1, .z = 0 };
                self.contact.origin = .{
                    .x = f(
                        @as(
                            f64,
                            actor.position.x,
                        ) + (if (sz < 0) @as(f64, radius) else -@as(f64, radius)),
                    ),
                    .z = edge_z,
                };
            } else {
                self.contact.direction = .{ .x = 0, .z = if (sx < 0) 1 else -1 };
                self.contact.origin = .{
                    .x = edge_x,
                    .z = f(
                        @as(
                            f64,
                            actor.position.z,
                        ) + (if (sx < 0) -@as(f64, radius) else @as(f64, radius)),
                    ),
                };
            }

            seen[count.*] = body_index;

            if (self.options.query_observer) |observer| observer.emit(
                observer.context,
                .{
                    .contact = .{
                        .kind = .actor,
                        .actor_written = true,
                        .actor = body_index,
                        .direction = self.contact.direction,
                    },
                },
            );

            self.contact.direction_known = true;
            self.recordProjection();
            count.* += 1;
        }
    }

    fn bounce(self: *const Context, velocity: *Vec3, wall: Wall, elasticity: f32) f32 {
        const d = self.scene.sectors[wall.sector].walls[wall.index].direction;
        const tangent = f(@as(f64, velocity.z) * d.z + @as(f64, velocity.x) * d.x);
        const exact_normal = @as(f64, velocity.z) * d.x - @as(f64, velocity.x) * d.z;
        const normal = f(exact_normal);
        const damping: f32 = if (exact_normal < 30) 0 else if (@as(
            i32,
            @bitCast(normal),
        ) < 0x42700001) f((@as(f64, normal) - 30.0) * @as(f32, 0.03)) else 0.9;

        const rebound = ((1.0 - @as(
            f64,
            damping,
        )) * normal) * -@as(f64, if (self.options.rail_mode) @as(f32, 0.2) else elasticity);

        velocity.x = f(@as(f64, d.x) * tangent - @as(f64, d.z) * rebound);
        velocity.z = f(@as(f64, d.z) * tangent + @as(f64, d.x) * rebound);

        return @abs(normal);
    }

    fn cut(self: *const Context, old: Vec3, point: *Vec3, delta: *Vec3, wall: Wall) void {
        const source = self.level.sectors[wall.sector];
        const first = source.vertices[source.walls[wall.index].v1];
        const last = source.vertices[source.walls[wall.index].v2];
        const dx = f(@as(f64, last.x) - first.x);
        const dz = f(@as(f64, last.z) - first.z);
        const t = f(
            ((@as(
                f64,
                first.x,
            ) - old.x) * dz - (@as(
                f64,
                first.z,
            ) - old.z) * dx) / ((@as(
                f64,
                point.x,
            ) - old.x) * dz - (@as(f64, point.z) - old.z) * dx),
        );

        point.x = f(@as(f64, t) * (@as(f64, point.x) - old.x) + old.x);
        point.z = f(@as(f64, t) * (@as(f64, point.z) - old.z) + old.z);
        delta.x = point.x - old.x;
        delta.z = point.z - old.z;
    }
};

pub fn resolve(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    actors: Actors,
    sector: usize,
    old: Vec3,
    desired: *Vec3,
    velocity: *Vec3,
    height: f32,
    radius: f32,
    step_height: f32,
    floor_cache: *f32,
) !Result {
    return resolveWithOptions(
        level,
        scene,
        actors,
        sector,
        old,
        desired,
        velocity,
        height,
        radius,
        step_height,
        floor_cache,
        .{},
    );
}

pub fn resolveWithOptions(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    actors: Actors,
    sector: usize,
    old: Vec3,
    desired: *Vec3,
    velocity: *Vec3,
    height: f32,
    radius: f32,
    step_height: f32,
    floor_cache: *f32,
    options: Options,
) !Result {
    if (sector >= level.sectors.len or radius <= 0 or !std.math.isFinite(
        radius,
    )) return error.InvalidPlayerCollision;

    var context = Context{
        .level = level,
        .scene = scene,
        .actors = actors,
        .options = options,
        .actor_position = old,
        .actor_sector = sector,
        .height = height,
        .radius = radius,
        .step = step_height,
        .contact = .{ .floor = floor_cache.* },
    };

    if (options.projection) |projection| if (projection.values()) |values| {
        context.contact.direction = values.direction;
        context.contact.origin = values.origin;
        context.contact.direction_known = true;
    };

    if (options.query_observer) |observer| observer.emit(
        observer.context,
        .{ .contact = .{ .kind = .none, .actor_written = true } },
    );

    const delta = sub(desired.*, old);
    if (@abs(delta.x) == 0 and @abs(delta.z) == 0) {
        context.observeQuery(context.query(sector, desired.*), false, velocity.*);

        if (try context.geometry(context.query(sector, desired.*))) {
            if (context.contact.kind == .wall) {
                velocity.x = f(@as(f64, context.contact.direction.z) * -5.0 + velocity.x);
                velocity.z = f(@as(f64, context.contact.direction.x) * 5.0 + velocity.z);
            }
        }

        floor_cache.* = context.contact.floor;
        return context.result(sector);
    }

    const count = nearest(f(@as(f64, length(delta.x, delta.z)) / radius)) * 2 + 1;
    if (count <= 0 or count > 1000000) return error.InvalidPlayerDisplacement;

    const full_reciprocal = 1.0 / @as(f64, @floatFromInt(count));
    const reciprocal = f(full_reciprocal);

    if (options.query_observer) |observer| {
        observer.emit(
            observer.context,
            .{ .subdivision = .{ .rounded = @divTrunc(count - 1, 2), .reciprocal = reciprocal } },
        );

        observer.emit(observer.context, .{ .halted = false });
    }

    const increment = Vec3{
        .x = f(full_reciprocal * delta.x),
        .y = f(@as(f64, reciprocal) * delta.y),
        .z = f(@as(f64, reciprocal) * delta.z),
    };

    var point = old;
    var accumulated = Vec3{ .x = 0, .y = 0, .z = 0 };
    var collided = false;
    var halted = false;
    const saved_velocity = velocity.*;
    var i: i32 = 0;

    while (i < count and !halted) : (i += 1) {
        point = add(point, increment);
        accumulated = add(accumulated, increment);
        desired.* = point;

        var q = context.query(sector, desired.*);
        context.observeQuery(q, true, saved_velocity);
        const next = try context.cross(sector, old, &point, &accumulated, velocity);

        if (next) |next_sector| q.sector = next_sector;

        if (count > 1) {
            if (next == null) {
                if (collided) desired.* = sub(desired.*, increment);

                halted = true;

                if (options.query_observer) |observer| observer.emit(
                    observer.context,
                    .{ .halted = true },
                );
            } else if (try context.geometry(q)) {
                collided = true;
            } else if (collided) {
                desired.* = sub(desired.*, increment);
                halted = true;

                if (options.query_observer) |observer| observer.emit(
                    observer.context,
                    .{ .halted = true },
                );
            }
        }

        velocity.* = saved_velocity;
    }

    const result = try context.slide(sector, old, desired, velocity);
    floor_cache.* = context.contact.floor;

    return context.result(result);
}

/// The most steps a path check may take. The longest check the game makes is
/// 10 units (a network player update), and the smallest collision radius in
/// the shipped data is half a bullet-hole sprite, 0.0357; that is 281 steps.
pub const max_path_check_steps = 281;

/// A radius of 0 counts as clear without walking, as in the original: the step
/// count comes out negative. So does a radius so small the step count doesn't
/// fit in 32 bits. Anything that would take more than `max_path_check_steps`
/// is refused.
pub fn pathClear(
    level: *const level_module.Level,
    scene: *const scene_module.Scene,
    actors: Actors,
    sector: usize,
    height: f32,
    radius: f32,
    from: Vec3,
    to: *Vec3,
) !bool {
    if (sector >= level.sectors.len) return error.InvalidPlayerCollision;

    for ([_]f32{
        height,
        radius,
        from.x,
        from.y,
        from.z,
        to.x,
        to.y,
        to.z,
    }) |value| if (!std.math.isFinite(value)) return error.InvalidPlayerCollision;

    const difference = Vec3{
        .x = f(@as(f64, to.x) - from.x),
        .y = f(@as(f64, to.y) - from.y),
        .z = f(@as(f64, to.z) - from.z),
    };

    if (@as(
        u32,
        @bitCast(difference.x),
    ) & 0x7fffffff == 0 and @as(u32, @bitCast(difference.z)) & 0x7fffffff == 0) return true;

    const width = @abs(radius);
    const steps = fistp(f(@as(f64, length(difference.x, difference.z)) / width)) +% 1;
    if (steps <= 0) return true;
    if (steps > max_path_check_steps) return error.UnsupportedPathCheck;

    const full_reciprocal = 1.0 / @as(f64, @floatFromInt(steps));
    const reciprocal = f(full_reciprocal);
    const increment = Vec3{
        .x = f(full_reciprocal * difference.x),
        .y = f(@as(f64, reciprocal) * difference.y),
        .z = f(@as(f64, reciprocal) * difference.z),
    };

    var context = Context{
        .level = level,
        .scene = scene,
        .actors = actors,
        .options = .{},
        .actor_position = from,
        .actor_sector = sector,
        .height = height,
        .radius = width,
        .step = 3.0,
    };

    const saved = to.*;
    defer to.* = saved;
    var point = from;
    var walked = Vec3{ .x = 0, .y = 0, .z = 0 };
    var i: i32 = 0;

    while (i < steps) : (i += 1) {
        point = add(increment, point);
        walked = add(walked, increment);
        to.* = point;

        var probe: Query = .{
            .position = point,
            .radius = width,
            .height = height,
            .sector = sector,
            .delta = .{ .x = point.x - from.x, .z = point.z - from.z },
            .step = 2.0,
            .drop = 0x1p31,
        };

        probe.sector = (try context.cross(sector, from, &point, &walked, null)) orelse return false;
        if (try context.geometry(probe)) return false;
    }

    return true;
}

pub fn intersection(a: Vec2, b: Vec2, c: Vec2, d: Vec2) ?Vec2 {
    const dx = f(@as(f64, b.x) - a.x);
    const dz = f(@as(f64, b.z) - a.z);
    const wx = f(@as(f64, c.x) - d.x);
    const wz = f(@as(f64, c.z) - d.z);
    const xmin = if (@as(u32, @bitCast(dx)) > 0x80000000) b.x else a.x;
    const xmax = if (@as(u32, @bitCast(dx)) > 0x80000000) a.x else b.x;

    if (@as(i32, @bitCast(wx)) < 1) {
        if (xmax < c.x or d.x < xmin) return null;
    } else if (xmax < d.x or c.x < xmin) return null;

    const zmin = if (@as(u32, @bitCast(dz)) > 0x80000000) b.z else a.z;
    const zmax = if (@as(u32, @bitCast(dz)) > 0x80000000) a.z else b.z;

    if (@as(i32, @bitCast(wz)) < 1) {
        if (zmax < c.z or d.z < zmin) return null;
    } else if (zmax < d.z or c.z < zmin) return null;

    const ox = f(@as(f64, a.x) - c.x);
    const oz = f(@as(f64, a.z) - c.z);
    const numerator = f(@as(f64, wz) * ox - @as(f64, oz) * wx);
    const denominator = f(@as(f64, dz) * wx - @as(f64, wz) * dx);

    if (denominator <= 0) {
        if (@as(i32, @bitCast(numerator)) > 0 or numerator < denominator) return null;
    } else if (@as(u32, @bitCast(numerator)) > 0x80000000 or denominator < numerator) return null;

    const other = f(@as(f64, oz) * dx - @as(f64, dz) * ox);

    if (@as(i32, @bitCast(denominator)) < 1) {
        if (@as(i32, @bitCast(other)) > 0 or other < denominator) return null;
    } else if (@as(u32, @bitCast(other)) > 0x80000000 or denominator < other) return null;

    if (@abs(denominator) == 0) return null;

    const t = @as(f64, numerator) / denominator;

    return .{ .x = f(@as(f64, dx) * t + a.x), .z = f(t * dz + a.z) };
}

pub fn length(x: f32, z: f32) f32 {
    const squared = f(@as(f64, x) * 0.5 * x * 0.5 + @as(f64, z) * 0.5 * z * 0.5);

    return f(@sqrt(@as(f64, squared)) * 2.0);
}

fn fistp(value: f32) i32 {
    if (!(value >= -0x1p31 and value < 0x1p31)) return std.math.minInt(i32);

    return nearest(value);
}

fn touches(q: Query, first: Vec2, wall: scene_module.WallState) bool {
    const x = f(@as(f64, q.position.x) - first.x);
    const z = f(@as(f64, q.position.z) - first.z);
    const normal = f(@as(f64, x) * wall.direction.z - @as(f64, wall.direction.x) * z);
    if (normal < 0 or q.radius < normal) return false;

    const along = f(@as(f64, wall.direction.z) * z + @as(f64, x) * wall.direction.x);
    if (0 <= along and along <= wall.length) return true;

    return 0 <= @as(
        f64,
        q.radius,
    ) + along and @as(f64, q.radius) + along <= @as(f64, wall.length) + f(@as(f64, q.radius) * 2.0);
}

fn slopeHeight(s: scene_module.Slope, p: Vec3, x_first: bool) f32 {
    return if (x_first) f(
        (@as(f64, s.constant) - @as(f64, s.coeff_x) * p.x) - @as(f64, s.coeff_z) * p.z,
    ) else f((@as(f64, s.constant) - @as(f64, p.z) * s.coeff_z) - @as(f64, s.coeff_x) * p.x);
}

fn nearest(value: f32) i32 {
    const lower = @floor(value);
    const integer: i32 = @intFromFloat(lower);
    const fraction = value - lower;

    return integer + @as(
        i32,
        if (fraction > 0.5 or (fraction == 0.5 and integer & 1 != 0)) 1 else 0,
    );
}

fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}

fn f(value: f64) f32 {
    return @floatCast(value);
}
