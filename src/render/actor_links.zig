//! Which actors are in which sector: a doubly linked membership list per
//! sector, by stable actor index.
//!
//! Indices rather than pointers, so the links stay valid wherever the actor
//! storage lives. The player is created after the level's actors but its
//! state lives in src/player, not in an actor slot.

const std = @import("std");

pub const player_id = std.math.maxInt(usize);

pub const Node = struct {
    sector: ?usize = null,
    previous: ?usize = null,
    next: ?usize = null,
};

pub const Links = struct {
    /// Set when `init` made the arrays; null when they are borrowed.
    allocator: ?std.mem.Allocator,
    heads: []?usize,
    /// One node per actor slot. The owner may lengthen the slice within its
    /// storage as slots are handed out.
    nodes: []Node,
    player: Node = .{},

    pub fn init(allocator: std.mem.Allocator, sector_count: usize, actor_count: usize) !Links {
        const heads = try allocator.alloc(?usize, sector_count);
        errdefer allocator.free(heads);

        const nodes = try allocator.alloc(Node, actor_count);

        @memset(heads, null);
        @memset(nodes, .{});

        return .{ .allocator = allocator, .heads = heads, .nodes = nodes };
    }

    /// Links over arrays the caller owns and keeps in place.
    pub fn initBorrowed(heads: []?usize, nodes: []Node) Links {
        @memset(heads, null);
        @memset(nodes, .{});

        return .{ .allocator = null, .heads = heads, .nodes = nodes };
    }

    pub fn deinit(self: *Links) void {
        if (self.allocator) |allocator| {
            allocator.free(self.heads);
            allocator.free(self.nodes);
        }

        self.* = undefined;
    }

    pub fn first(self: *const Links, sector: usize) ?usize {
        return self.heads[sector];
    }

    pub fn next(self: *const Links, source: usize) ?usize {
        return if (source == player_id) self.player.next else self.nodes[source].next;
    }

    pub fn move(self: *Links, source: usize, sector: usize) void {
        const entry = self.node(source);
        if (entry.sector == sector) return;

        self.remove(source);
        const head = self.heads[sector];

        entry.sector = sector;
        entry.next = head;

        if (head) |following| self.node(following).previous = source;

        self.heads[sector] = source;
    }

    pub fn insertBefore(self: *Links, source: usize, sector: usize, before: ?usize) void {
        std.debug.assert(before != source);
        self.remove(source);

        var previous: ?usize = null;

        if (before) |following| {
            std.debug.assert(self.node(following).sector == sector);
            previous = self.node(following).previous;
        } else {
            var cursor = self.heads[sector];

            while (cursor) |id| {
                previous = id;
                cursor = self.next(id);
            }
        }

        self.node(source).* = .{ .sector = sector, .previous = previous, .next = before };

        if (previous) |id| self.node(id).next = source else self.heads[sector] = source;

        if (before) |id| self.node(id).previous = source;
    }

    pub fn remove(self: *Links, source: usize) void {
        const entry = self.node(source);

        if (entry.sector) |sector| {
            if (self.heads[sector] == source) self.heads[sector] = entry.next;
            if (entry.previous) |previous| self.node(previous).next = entry.next;
            if (entry.next) |following| self.node(following).previous = entry.previous;
        }

        entry.* = .{};
    }

    fn node(self: *Links, source: usize) *Node {
        return if (source == player_id) &self.player else &self.nodes[source];
    }
};

test "sector links retain reference equal-distance ray winners" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "testdata/actor-order-reference.json",
        a,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };

    defer a.free(bytes);
    const Corpus = struct {
        executable_sha256: []const u8,
        results_sha256: []const u8,
        cases: []struct {
            sector: usize,
            actors: []struct { sector: usize },
            relinks: []usize,
            hit: struct { actor: usize },
        },
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
        "29cbfffe17e1d44d366eac794025ed75afc3e5e42f523e5b93b504fbb10dd655",
        parsed.value.results_sha256,
    );

    for (parsed.value.cases) |case| {
        for (0..case.actors.len + 1) |player_source| {
            const temporary_sector = case.sector + 1;
            var links = try Links.init(a, temporary_sector + 1, case.actors.len);
            defer links.deinit();

            for (case.actors, 0..) |actor, source| links.move(
                if (source == player_source) player_id else source,
                actor.sector,
            );

            for (case.relinks) |source| {
                const id = if (source == player_source) player_id else source;
                links.move(id, temporary_sector);
                links.move(id, case.actors[source].sector);
            }

            const winner = links.first(case.sector).?;
            try std.testing.expectEqual(
                case.hit.actor,
                if (winner == player_id) player_source else winner,
            );

            for (case.actors, 0..) |actor, source| links.move(
                if (source == player_source) player_id else source,
                actor.sector,
            );

            try std.testing.expectEqual(winner, links.first(case.sector).?);
        }
    }
}

test "actor removal preserves both sector links and dynamic source identity" {
    var links = try Links.init(std.testing.allocator, 2, 4);
    defer links.deinit();

    for (0..3) |source| links.move(source, 0);

    links.move(player_id, 0);
    links.remove(1);

    try std.testing.expectEqual(@as(?usize, 0), links.next(2));
    try std.testing.expectEqual(@as(?usize, 2), links.nodes[0].previous);

    links.remove(0);
    try std.testing.expectEqual(@as(?usize, null), links.next(2));
    links.remove(player_id);
    try std.testing.expectEqual(@as(?usize, 2), links.first(0));
    const dynamic: usize = 3;

    links.move(dynamic, 0);
    links.move(2, 1);

    try std.testing.expectEqual(@as(?usize, dynamic), links.first(0));
    try std.testing.expectEqual(@as(?usize, null), links.next(dynamic));
    try std.testing.expectEqual(@as(?usize, 2), links.first(1));
    try std.testing.expectEqual(@as(?usize, null), links.nodes[2].previous);
}

test "deferred resource construction restores sector insertion order" {
    var links = try Links.init(std.testing.allocator, 1, 4);
    defer links.deinit();

    links.move(2, 0);
    links.move(player_id, 0);
    links.insertBefore(0, 0, null);
    links.insertBefore(3, 0, 2);
    links.insertBefore(1, 0, 0);

    var cursor = links.first(0);

    for ([_]usize{ player_id, 3, 2, 1, 0 }) |expected| {
        try std.testing.expectEqual(@as(?usize, expected), cursor);
        cursor = links.next(expected);
    }

    try std.testing.expectEqual(@as(?usize, null), cursor);
}
