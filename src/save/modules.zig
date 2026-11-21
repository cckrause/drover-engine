//! The registration order the save modules are visited in.
//!
//! The order is part of the file format, and a module that writes nothing
//! still keeps its place. Database records come before the database's own.

const stream = @import("stream.zig");

pub const order = [_]Entry{
    .{ .module = .list, .save_address = 0x00493d00, .restore_address = 0x00493d70, .tag = 0x4274734c },
    .{ .module = .file_util, .save_address = 0x0049cc40, .restore_address = 0x0049ccb0, .tag = 0x42545546 },
    .{ .module = .kbd, .save_address = 0x0048bb40, .restore_address = 0x0048bbb0, .tag = 0x4264624b },
    .{ .module = .platform, .save_address = 0x00435de0, .restore_address = 0x00435e50, .tag = 0x42746c50 },
    .{ .module = .text, .save_address = 0x0048d520, .restore_address = 0x0048d590, .tag = 0x42747854 },
    .{ .module = .term, .save_address = 0x00445820, .restore_address = 0x00445890, .tag = 0x426d7254 },
    .{ .module = .dll, .save_address = 0x0049c880, .restore_address = 0x0049c8f0, .tag = 0x426c6c44 },
    .{ .module = .sound, .save_address = 0x004882d0, .restore_address = 0x00488340, .tag = 0x42646e53 },
    .{ .module = .cmm, .save_address = 0x004d3b80, .restore_address = 0x004d3bb0, .tag = null },
    .{ .module = .symbol, .save_address = 0x004d3580, .restore_address = 0x004d35a0, .tag = null },
    .{ .module = .wax, .save_address = 0x00448660, .restore_address = 0x004486d0, .tag = 0x42786157 },
    .{ .module = .obj3do, .save_address = 0x00433da0, .restore_address = 0x00433e10, .tag = 0x42786157 },
    .{ .module = .info, .save_address = 0x00474f90, .restore_address = 0x00475000, .tag = 0x426f6649 },
    .{ .module = .player, .save_address = 0x00438570, .restore_address = 0x004386a0, .tag = 0x42796c50, .has_state = true },
    .{ .module = .jedi, .save_address = 0x004a59e0, .restore_address = 0x004a5a50, .tag = 0x4264654a },
    .{ .module = .item, .save_address = 0x00419370, .restore_address = 0x004193e0, .tag = 0x426d7449 },
    .{ .module = .network, .save_address = 0x0048ade0, .restore_address = 0x0048ae50, .tag = 0x4274654e },
    .{ .module = .physics, .save_address = 0x004cb100, .restore_address = 0x004cb170, .tag = 0x42796850 },
    .{ .module = .router, .save_address = 0x0045ce90, .restore_address = 0x0045cf00, .tag = 0x42727452 },
    .{ .module = .collide, .save_address = 0x004d09c0, .restore_address = 0x004d0a30, .tag = 0x42646c43 },
    .{ .module = .iface, .save_address = 0x00406dc0, .restore_address = 0x00406e30, .tag = 0x42636649 },
    .{ .module = .enemy, .save_address = 0x004715b0, .restore_address = 0x004715d0, .tag = null },
    .{ .module = .shot, .save_address = 0x00453b70, .restore_address = 0x00453be0, .tag = 0x426f6853 },
    .{ .module = .inf, .save_address = 0x0044cc00, .restore_address = 0x0044cc70, .tag = 0x42666e49 },
    .{ .module = .control, .save_address = 0x0044af50, .restore_address = 0x0044afc0, .tag = 0x42727443 },
    .{ .module = .inv, .save_address = 0x004145b0, .restore_address = 0x00414620, .tag = 0x42766e49, .minor = 1 },
    .{ .module = .weapon, .save_address = 0x004666e0, .restore_address = 0x00466750, .tag = 0x426e7057 },
    .{ .module = .dead_reck, .save_address = 0x00497180, .restore_address = 0x004971f0, .tag = 0x426b7244 },
    .{ .module = .screen, .save_address = 0x00460e80, .restore_address = 0x00460ef0, .tag = 0x42726353 },
    .{ .module = .server, .save_address = 0x0045eff0, .restore_address = 0x0045f090, .tag = 0x42727653, .has_state = true },
    .{ .module = .slope, .save_address = 0x004a2900, .restore_address = 0x004a2920, .tag = null },
    .{ .module = .config, .save_address = 0x00492f70, .restore_address = 0x00492fe0, .tag = 0x42474643 },
    .{ .module = .misc, .save_address = 0x0046c160, .restore_address = 0x0046c1d0, .tag = 0x4263734d },
    .{ .module = .fx, .save_address = 0x00476580, .restore_address = 0x004765f0, .tag = 0x426d7846 },
    .{ .module = .mu_script, .save_address = 0x0047b1b0, .restore_address = 0x0047b220, .tag = 0x4263734d },
    .{ .module = .rcp, .save_address = 0x00444010, .restore_address = 0x00444080, .tag = 0x42706352 },
    .{ .module = .level, .save_address = 0x0041a500, .restore_address = 0x0041a780, .tag = 0x4276654c, .has_state = true },
    .{ .module = .task, .save_address = 0x00496b80, .restore_address = 0x00496bf0, .tag = 0x426b7354 },
    .{ .module = .gen, .save_address = 0x00473260, .restore_address = 0x00473380, .tag = 0x426e6547, .minor = 1, .has_state = true },
    .{ .module = .db, .save_address = 0x004c6a20, .restore_address = 0x004c6d40, .tag = null, .has_state = true },
    .{ .module = .elevator, .save_address = 0x004588e0, .restore_address = 0x00458960, .tag = 0x42766c45, .has_state = true },
    .{ .module = .trigger, .save_address = 0x00456de0, .restore_address = 0x00456e50, .tag = 0x42677254 },
    .{ .module = .atx, .save_address = 0x004027b0, .restore_address = 0x00402820, .tag = 0x42787441 },
    .{ .module = .logic, .save_address = 0x0041f610, .restore_address = 0x0041f7e0, .tag = 0x42676f4c, .has_state = true },
    .{ .module = .node, .save_address = 0x00475910, .restore_address = 0x00475980, .tag = 0x42646f4e },
};

pub const Module = enum {
    list,
    file_util,
    kbd,
    platform,
    text,
    term,
    dll,
    sound,
    cmm,
    symbol,
    wax,
    obj3do,
    info,
    player,
    jedi,
    item,
    network,
    physics,
    router,
    collide,
    iface,
    enemy,
    shot,
    inf,
    control,
    inv,
    weapon,
    dead_reck,
    screen,
    server,
    slope,
    config,
    misc,
    fx,
    mu_script,
    rcp,
    level,
    task,
    gen,
    db,
    elevator,
    trigger,
    atx,
    logic,
    node,
};

pub const Entry = struct {
    module: Module,
    save_address: u32,
    restore_address: u32,
    tag: ?u32,
    major: u32 = 1,
    minor: u32 = 0,
    has_state: bool = false,

    pub fn writeMarker(self: Entry, writer: *stream.Writer) !void {
        if (self.tag) |tag| try writer.marker(tag, self.major, self.minor);
    }

    pub fn readMarker(self: Entry, reader: *stream.Reader) !void {
        if (self.tag) |tag| try reader.marker(tag, self.major, self.minor);
    }
};

pub fn entry(module: Module) Entry {
    return order[@intFromEnum(module)];
}
