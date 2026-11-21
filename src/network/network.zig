//! The network layer between the router and a driver: listing sessions,
//! opening and closing one, and sending and receiving buffers.
//!
//! The driver is looked up by name and bound by entry point, so the game
//! calls the same list of functions whatever the driver is. An error from a
//! driver call stands for whatever the driver reported.

const std = @import("std");
const message = @import("message.zig");

pub const Provider = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, hosting: bool, name: []const u8, player: []const u8, address: *message.Address) anyerror!Driver,
};

pub const Driver = struct {
    context: *anyopaque,
    send: *const fn (context: *anyopaque, data: []const u8, to: ?*const message.Address, flags: u32) void,
    get: *const fn (context: *anyopaque, buffer: []u8, sender: *message.Address) anyerror!usize,
    close: *const fn (context: *anyopaque) void = closeNothing,
    describe: *const fn (context: *anyopaque, data: []const u8) anyerror!void = noDescription,
    host_address: message.Address = message.no_address,

    fn closeNothing(_: *anyopaque) void {}

    fn noDescription(_: *anyopaque, _: []const u8) anyerror!void {
        return error.DriverHasNoSessionDescription;
    }
};

pub const Network = struct {
    session: ?Driver = null,
    provider: ?Provider = null,
    sent_count: u32 = 0,
    sent_bytes: u32 = 0,
    received_count: u32 = 0,
    received_bytes: u32 = 0,
    total_received: u32 = 0,
    last_received: u32 = 0,
    total_sent: u32 = 0,
    last_sent: u32 = 0,
    frames: u32 = 0,
    loads: u32 = 0,

    pub fn countFrame(self: *Network) void {
        self.total_received +%= self.received_bytes;
        self.last_received = self.received_bytes;
        self.received_bytes = 0;
        self.received_count = 0;
        self.total_sent +%= self.sent_bytes;
        self.last_sent = self.sent_bytes;
        self.sent_bytes = 0;
        self.sent_count = 0;
        self.frames +%= 1;
    }

    pub fn load(self: *Network, provider: Provider) void {
        self.loads += 1;
        if (self.loads == 1) self.provider = provider;
    }

    pub fn unload(self: *Network) void {
        if (self.loads == 0) return;
        self.loads -= 1;
        if (self.loads == 0) self.provider = null;
    }

    pub fn open(self: *Network, hosting: bool, name: []const u8, player: []const u8, address: *message.Address) !void {
        const provider = self.provider orelse return error.NetworkDriverNotLoaded;
        self.session = try provider.open(provider.context, hosting, name, player, address);
    }

    pub fn close(self: *Network) void {
        const driver = self.session orelse return;
        driver.close(driver.context);
        self.session = null;
    }

    pub fn send(self: *Network, data: []const u8, to: ?*const message.Address, flags: u32) void {
        const driver = self.session orelse return;
        self.sent_count +%= 1;
        self.sent_bytes +%= @as(u16, @intCast(data.len));
        driver.send(driver.context, data, to, flags);
    }

    pub fn describe(self: *Network, data: []const u8) !void {
        if (self.provider == null) return;
        const driver = self.session orelse return error.NetworkSessionNotOpen;
        try driver.describe(driver.context, data);
    }

    pub fn get(self: *Network, buffer: []u8, sender: *message.Address) usize {
        const driver = self.session orelse return 0;
        const length = driver.get(driver.context, buffer, sender) catch |err| {
            std.log.debug("Network GetBuffer: {t}", .{err});
            return 0;
        };
        if (length == 0) return 0;
        self.received_bytes +%= @as(u16, @intCast(length));
        self.received_count +%= 1;
        return length;
    }
};
