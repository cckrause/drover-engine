//! HUD node transitions and the pixels they produce.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const PlayerFlags = @import("../player/flags.zig").PlayerFlags;
const bits = @import("../util/bits.zig");

const fixtures = @import("../testing/fixtures.zig");
const read = fixtures.read;
const lab = @import("../assets/lab.zig");
const inventory_module = @import("../player/inventory.zig");
const hud_module = @import("hud.zig");
const Hud = hud_module.Hud;

const ReferenceNode = struct {
    parent: ?usize,
    asset: ?[]const u8,
    choreography: ?u32,
    frame_cursor: ?u32,
    rect: [4]i32,
    clip: [4]i32,
    clear: i32,
    effective: i32,
    value: i32,
    minimum: i32,
    maximum: i32,
    velocity: i32,
    last_time: u32,
    cached: i32,
};

const Slot = struct { slot: usize, name: []const u8, count: i32, loaded: i32 };

const Case = struct {
    name: []const u8,
    group: []const u8,
    now: u32,
    health: f32,
    stamina: f32,
    breath: f32,
    selected_weapon: usize,
    selected_item: usize,
    player_flags: u32,
    sheriff_visible: bool,
    slots: []Slot,
    background: u8,
    nodes: []ReferenceNode,
    pixels_file: []const u8,
    pixels_sha256: []const u8,
    blend_file: ?[]const u8 = null,
    color_map_file: ?[]const u8 = null,
    sound_requests: []const []const u8 = &.{},
};

fn compareTree(
    hud: *const Hud,
    node: anytype,
    expected: []const ReferenceNode,
    cursor: *usize,
    parent: ?usize,
) anyerror!void {
    try std.testing.expect(cursor.* < expected.len);
    const index = cursor.*;
    cursor.* += 1;

    const reference = expected[index];
    errdefer std.debug.print(
        "HUD node {d}, asset={s}, sequence={any}\n",
        .{ index, reference.asset orelse "container", reference.choreography },
    );

    try std.testing.expectEqual(reference.parent, parent);

    if (reference.asset) |name| {
        const costume = node.costume orelse return error.MissingHudReferenceCostume;
        var found = false;

        for (hud.resources.items) |resource| if (&resource.costume == costume) {
            try std.testing.expect(std.ascii.eqlIgnoreCase(name, resource.name));
            found = true;
            break;
        };

        try std.testing.expect(found);
        try std.testing.expectEqual(reference.choreography.?, node.playback.choreography);
        try std.testing.expectEqual(reference.frame_cursor.?, node.playback.frame);
    } else try std.testing.expect(node.costume == null);

    try std.testing.expectEqual(reference.rect, rectValues(node.rect));
    try std.testing.expectEqual(reference.clip, rectValues(node.clip));
    try std.testing.expectEqual(reference.clear != 0, node.clear);
    try std.testing.expectEqual(reference.effective, node.combined);
    try std.testing.expectEqual(reference.value, node.slide);
    try std.testing.expectEqual(reference.minimum, node.minimum);
    try std.testing.expectEqual(reference.maximum, node.maximum);
    try std.testing.expectEqual(reference.velocity, node.velocity);
    try std.testing.expectEqual(reference.last_time, node.last_time);
    try std.testing.expectEqual(reference.cached, node.value);

    var child = node.first_child;

    while (child) |value| : (child = value.next) try compareTree(
        hud,
        value,
        expected,
        cursor,
        index,
    );
}

fn rectValues(rect: hud_module.Rect) [4]i32 {
    return .{ rect.x, rect.y, rect.width, rect.height };
}

test "HUD node transitions and indexed pixels match the reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const document = try std.json.parseFromSlice(
        struct { executable_sha256: []const u8, width: usize, height: usize, cases: []Case },
        a,
        try read(a, "testdata/hud-reference.json"),
        .{ .ignore_unknown_fields = true },
    );

    const fixture = document.value;

    try std.testing.expectEqualStrings(
        "d2946541c007d5cf72f13c5b049e5a822768c064b6a1ebdb791881b187d44a4f",
        fixture.executable_sha256,
    );

    try std.testing.expectEqual(@as(usize, 640), fixture.width);
    try std.testing.expectEqual(@as(usize, 480), fixture.height);

    var archives: [3]lab.Archive = undefined;

    inline for (.{ "OUTLAWS.LAB", "OLOBJ.LAB", "OLWEAP.LAB" }, 0..) |name, i|
        archives[i] = try lab.Archive.init(try read(a, "inputs/OUTLAWS_CD1/OUTLAWS/" ++ name));

    var group: []const u8 = "";
    var hud: ?Hud = null;
    defer if (hud) |*value| value.deinit();
    var inventory: inventory_module.Inventory = .{};
    const pixels = try a.alloc(u8, fixture.width * fixture.height);

    for (fixture.cases) |case| {
        errdefer std.debug.print("HUD case {s}, now={d}\n", .{ case.name, case.now });

        if (!std.mem.eql(u8, group, case.group)) {
            if (hud) |*value| value.deinit();

            hud = null;
            hud = try Hud.init(a, &archives, 0, false);
            inventory = .{};
            group = case.group;
        }

        inventory.health = case.health;
        inventory.selected = case.selected_item;
        inventory.selected_weapon = case.selected_weapon;
        inventory.player_flags = bits.from(PlayerFlags, case.player_flags);
        inventory.sheriff_visible = case.sheriff_visible;
        hud.?.blend_table = if (case.blend_file) |path| try read(a, path) else null;
        hud.?.color_map = if (case.color_map_file) |path| try read(a, path) else null;

        var present = [_]bool{false} ** 26;

        for (case.slots) |slot| {
            try std.testing.expect(slot.slot < present.len);
            present[slot.slot] = true;

            if (inventory.slots[slot.slot] == null or !std.ascii.eqlIgnoreCase(
                inventory.slots[slot.slot].?.definition.name,
                slot.name,
            ))
                inventory.slots[slot.slot] = .{
                    .definition = try inventory_module.Definition.load(a, &archives, slot.name),
                    .count = slot.count,
                };

            inventory.slots[slot.slot].?.count = slot.count;
            inventory.slots[slot.slot].?.loaded = slot.loaded;
        }

        for (&inventory.slots, present) |*slot, exists| if (!exists) {
            slot.* = null;
        };

        try hud.?.update(&inventory, case.stamina, case.breath, case.now);
        try std.testing.expectEqual(
            case.sound_requests.len,
            @as(usize, if (hud.?.sound_request != null) 1 else 0),
        );

        if (hud.?.sound_request) |request| switch (request) {
            .sound => |sound| try std.testing.expectEqualStrings(
                case.sound_requests[0],
                sound.basename,
            ),
            else => return error.UnexpectedHudMessageRequest,
        };

        var cursor: usize = 0;

        try compareTree(&hud.?, hud.?.panel, case.nodes, &cursor, null);
        try compareTree(&hud.?, hud.?.status, case.nodes, &cursor, null);

        try std.testing.expectEqual(case.nodes.len, cursor);
        @memset(pixels, case.background);
        try hud.?.draw(pixels);
        const expected = try read(a, case.pixels_file);
        try std.testing.expectEqual(pixels.len, expected.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(expected, &digest, .{});

        try std.testing.expectEqualStrings(case.pixels_sha256, &std.fmt.bytesToHex(digest, .lower));
        if (!std.mem.eql(u8, expected, pixels)) {
            var count: usize = 0;
            var first: ?usize = null;

            for (pixels, expected, 0..) |actual, wanted, i| if (actual != wanted) {
                count += 1;
                if (first == null) first = i;
            };

            const offset = first.?;
            std.debug.print(
                "HUD pixel ({d},{d}): expected {d}, found {d}; {d} mismatches\n",
                .{ offset % 640, offset / 640, expected[offset], pixels[offset], count },
            );

            return error.HudReferencePixelMismatch;
        }
    }
}
