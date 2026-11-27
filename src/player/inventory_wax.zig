//! Binding inventory items to the sprite sets their definitions name, so a
//! selected item animates in the strip.

const std = @import("std");

const lab = @import("../assets/lab.zig");
const nwx = @import("../assets/nwx.zig");
const cmm = @import("../script/cmm.zig");

const Context = struct {
    function: cmm.Native,

    pub fn event(
        self: @This(),
        _: *nwx.Playback,
        _: *const nwx.Costume,
        message: u32,
        _: []const u32,
        _: u32,
    ) !void {
        switch (self.function) {
            .generic_object, .health_object => switch (message) {
                2, 0x5f...0x63 => {},
                else => return error.UnsupportedInventoryWaxMessage,
            },
            else => return error.UnsupportedInventoryWaxBinding,
        }
    }
};

pub fn advance(session: anytype, now: u32) !void {
    const a = session.arena.allocator();

    for (&session.inventory.slots) |*slot| if (slot.*) |*owned| {
        if (owned.playback) |*playback| {
            var key_buffer: [255]u8 = undefined;
            const name = owned.definition.costume;
            if (name.len > key_buffer.len) return error.InvalidInventoryCostume;

            const key = key_buffer[0..name.len];

            for (name, key) |source, *target| target.* = std.ascii.toUpper(source);

            const costume = session.costumes.get(key) orelse blk: {
                var bytes: ?[]const u8 = null;

                for ([_]lab.Archive{
                    session.object_archive,
                    session.weapon_archive,
                    session.system_archive,
                }) |archive| {
                    bytes = archive.find(key, 0x57415846) catch |err| switch (err) {
                        error.ResourceNotFound => continue,
                        else => return err,
                    };

                    break;
                }

                const asset = try a.create(nwx.Costume);
                asset.* = try nwx.Costume.parse(
                    a,
                    bytes orelse return error.MissingInventoryCostume,
                );

                try session.costumes.put(try a.dupe(u8, key), asset);
                break :blk asset;
            };

            try playback.advanceWithContext(
                costume,
                0,
                now,
                Context{ .function = owned.definition.function },
            );
        }
    };
}
