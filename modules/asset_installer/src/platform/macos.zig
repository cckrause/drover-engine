//! macOS host boundary, written in Zig. Calls public AppKit/WebKit APIs via
//! the system Objective-C ABI; no Objective-C source or game dependencies.
const std = @import("std");
const Store = @import("../store.zig").Store;
const Kind = @import("../store.zig").Kind;
const Id = ?*anyopaque;

extern "objc" fn objc_getClass([*:0]const u8) Id;
extern "objc" fn sel_registerName([*:0]const u8) *anyopaque;
extern "objc" fn objc_msgSend() void;
extern "objc" fn objc_allocateClassPair(Id, [*:0]const u8, usize) Id;
extern "objc" fn objc_registerClassPair(Id) void;
extern "objc" fn class_addMethod(Id, *anyopaque, *const anyopaque, [*:0]const u8) bool;

fn m0(comptime R: type, obj: Id, sel: [:0]const u8) R {
    return @as(
        *const fn (Id, *anyopaque) callconv(.c) R,
        @ptrCast(&objc_msgSend),
    )(obj, sel_registerName(sel));
}

fn m1(comptime R: type, obj: Id, sel: [:0]const u8, a: anytype) R {
    return @as(
        *const fn (Id, *anyopaque, @TypeOf(a)) callconv(.c) R,
        @ptrCast(&objc_msgSend),
    )(obj, sel_registerName(sel), a);
}

fn m2(comptime R: type, obj: Id, sel: [:0]const u8, a: anytype, b: anytype) R {
    return @as(
        *const fn (Id, *anyopaque, @TypeOf(a), @TypeOf(b)) callconv(.c) R,
        @ptrCast(&objc_msgSend),
    )(obj, sel_registerName(sel), a, b);
}

const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };

fn string(a: std.mem.Allocator, text: []const u8) !Id {
    const z = try a.dupeZ(u8, text);
    defer a.free(z);

    return m1(Id, objc_getClass("NSString"), "stringWithUTF8String:", @as([*:0]const u8, z));
}

fn bytes(obj: Id) []const u8 {
    return std.mem.span(m0([*:0]const u8, obj, "UTF8String"));
}

pub const Host = struct {
    /// Existing NSWindow owned by the game, never a second window.
    window: *anyopaque,
    context: *anyopaque,
    pump: *const fn (*anyopaque) bool,
};

const Action = enum { none, choose, demo };
var active: ?*Screen = null;

fn receive(_: Id, _: *anyopaque, _: Id, message: Id) callconv(.c) void {
    const s = active orelse return;
    if (s.worker != null) return;

    const body = m0(Id, message, "body");
    if (!m1(bool, body, "isKindOfClass:", objc_getClass("NSString"))) return;

    const value = bytes(body);

    if (std.mem.eql(u8, value, "choose")) s.action = .choose;

    if (std.mem.eql(u8, value, "demo")) s.action = .demo;
}

fn entered(_: Id, _: *anyopaque, _: Id) callconv(.c) usize {
    const s = active orelse return 0;

    return if (s.worker == null) 1 else 0;
}

fn prepare(_: Id, _: *anyopaque, _: Id) callconv(.c) bool {
    const s = active orelse return false;

    return s.worker == null;
}

fn dropped(_: Id, _: *anyopaque, info: Id) callconv(.c) bool {
    const s = active orelse return false;
    if (s.worker != null) return false;

    const board = m0(Id, info, "draggingPasteboard");
    const urls = m2(
        Id,
        board,
        "readObjectsForClasses:options:",
        m1(Id, objc_getClass("NSArray"), "arrayWithObject:", objc_getClass("NSURL")),
        m0(Id, objc_getClass("NSDictionary"), "dictionary"),
    );

    const legacy = m0(usize, urls, "count") == 0;
    const names = if (legacy) m1(
        Id,
        board,
        "propertyListForType:",
        string(s.a, "NSFilenamesPboardType") catch return false,
    ) else urls;

    const count = m0(usize, names, "count");
    if (count == 0 or count + s.files.items.len > 16) return false;

    for (0..count) |i| {
        const name = m1(Id, names, "objectAtIndex:", i);
        if (!legacy and !m0(bool, name, "isFileURL")) return false;

        const path = s.a.dupe(
            u8,
            bytes(if (legacy) name else m0(Id, name, "path")),
        ) catch return false;

        s.files.append(s.a, path) catch {
            s.a.free(path);
            return false;
        };
    }

    return true;
}

const Work = struct {
    store: *Store,
    files: []const []u8,
    download: bool,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,
    result: Store.ImportResult = .demo,

    fn run(self: *Work) void {
        self.perform() catch |err| {
            self.err = err;
        };
        self.done.store(true, .release);
    }

    fn perform(self: *Work) !void {
        if (self.download) {
            try self.store.downloadDemo();
            return;
        }

        for (self.files) |path| self.result = try self.store.importFile(path);
    }
};

const Screen = struct {
    a: std.mem.Allocator,
    store: *Store,
    web: Id,
    handler: Id,
    controller: Id,
    action: Action = .none,
    files: std.ArrayList([]u8) = .empty,
    work: Work,
    worker: ?std.Io.Future(void) = null,
    demo: bool = false,

    fn clearFiles(self: *Screen) void {
        for (self.files.items) |file| self.a.free(file);
        self.files.clearRetainingCapacity();
    }

    fn state(self: *Screen, message: []const u8) !void {
        const json = try std.json.Stringify.valueAlloc(
            self.a,
            .{ .busy = self.worker != null, .demo = self.demo, .message = message },
            .{},
        );

        defer self.a.free(json);
        const script = try std.fmt.allocPrint(
            self.a,
            "window.installerState && window.installerState({s})",
            .{json},
        );

        defer self.a.free(script);

        m2(
            void,
            self.web,
            "evaluateJavaScript:completionHandler:",
            try string(self.a, script),
            @as(Id, null),
        );
    }

    fn choose(self: *Screen) !void {
        const panel = m0(Id, objc_getClass("NSOpenPanel"), "openPanel");

        m1(void, panel, "setCanChooseDirectories:", false);
        m1(void, panel, "setAllowsMultipleSelection:", true);
        m1(
            void,
            panel,
            "setMessage:",
            try string(self.a, "Choose your original Outlaws disc images or outdemo_v2.exe."),
        );

        if (m0(isize, panel, "runModal") != 1) return;

        const urls = m0(Id, panel, "URLs");
        const count = m0(usize, urls, "count");
        if (count > 16) return error.TooManyFiles;

        for (0..count) |i| {
            const url = m1(Id, urls, "objectAtIndex:", i);
            const path = try self.a.dupe(u8, bytes(m0(Id, url, "path")));
            errdefer self.a.free(path);
            try self.files.append(self.a, path);
        }
    }

    fn start(self: *Screen, download: bool) !void {
        self.work = .{ .store = self.store, .files = self.files.items, .download = download };
        self.worker = try std.Io.concurrent(self.store.io, Work.run, .{&self.work});

        try self.state(
            if (download) "Downloading the original demo from Internet Archive…" else "Checking and installing your game assets…",
        );
    }
};

fn classes() !struct { view: Id, handler: Id } {
    const handler = objc_getClass("OLAssetInstallerHandler") orelse blk: {
        const cls = objc_allocateClassPair(
            objc_getClass("NSObject"),
            "OLAssetInstallerHandler",
            0,
        ) orelse return error.NativeClassFailed;

        if (!class_addMethod(
            cls,
            sel_registerName("userContentController:didReceiveScriptMessage:"),
            @ptrCast(&receive),
            "v@:@@",
        )) return error.NativeClassFailed;

        objc_registerClassPair(cls);
        break :blk cls;
    };

    const view = objc_getClass("OLAssetInstallerView") orelse blk: {
        const cls = objc_allocateClassPair(
            objc_getClass("WKWebView"),
            "OLAssetInstallerView",
            0,
        ) orelse return error.NativeClassFailed;

        if (!class_addMethod(
            cls,
            sel_registerName("draggingEntered:"),
            @ptrCast(&entered),
            "Q@:@",
        ) or
            !class_addMethod(
                cls,
                sel_registerName("draggingUpdated:"),
                @ptrCast(&entered),
                "Q@:@",
            ) or
            !class_addMethod(
                cls,
                sel_registerName("prepareForDragOperation:"),
                @ptrCast(&prepare),
                "B@:@",
            ) or
            !class_addMethod(
                cls,
                sel_registerName("performDragOperation:"),
                @ptrCast(&dropped),
                "B@:@",
            )) return error.NativeClassFailed;

        objc_registerClassPair(cls);
        break :blk cls;
    };

    return .{ .view = view, .handler = handler };
}

pub fn run(a: std.mem.Allocator, store: *Store, host: Host) !?Kind {
    if (active != null) return error.InstallerAlreadyOpen;

    const pool = m0(Id, m0(Id, objc_getClass("NSAutoreleasePool"), "alloc"), "init");
    defer m0(void, pool, "drain");
    const cls = try classes();
    const config = m0(Id, m0(Id, objc_getClass("WKWebViewConfiguration"), "alloc"), "init");
    defer m0(void, config, "release");
    const controller = m0(Id, config, "userContentController");
    const handler = m0(Id, m0(Id, cls.handler, "alloc"), "init");
    defer m0(void, handler, "release");
    const channel = try string(a, "installer");

    m2(void, controller, "addScriptMessageHandler:name:", handler, channel);
    defer m1(void, controller, "removeScriptMessageHandlerForName:", channel);
    // Website data is ephemeral. The screen has no external resources, links,
    // navigation, or network access; only the Zig worker downloads the demo.
    m1(
        void,
        config,
        "setWebsiteDataStore:",
        m0(Id, objc_getClass("WKWebsiteDataStore"), "nonPersistentDataStore"),
    );

    const web = m2(
        Id,
        m0(Id, cls.view, "alloc"),
        "initWithFrame:configuration:",
        Rect{ .x = 0, .y = 0, .w = 640, .h = 480 },
        config,
    );

    if (web == null) return error.NativeViewFailed;

    defer m0(void, web, "release");
    var screen = Screen{
        .a = a,
        .store = store,
        .web = web,
        .handler = handler,
        .controller = controller,
        .demo = try store.installed(.demo),
        .work = undefined,
    };

    defer {
        if (screen.worker) |*future| future.cancel(store.io);
        screen.clearFiles();
        screen.files.deinit(a);
    }

    active = &screen;
    defer active = null;

    m1(void, web, "setAutoresizingMask:", @as(usize, 18));
    const types = [_]Id{ try string(a, "public.file-url"), try string(a, "NSFilenamesPboardType") };
    m1(
        void,
        web,
        "registerForDraggedTypes:",
        m2(
            Id,
            objc_getClass("NSArray"),
            "arrayWithObjects:count:",
            @as([*]const Id, &types),
            types.len,
        ),
    );

    const content = m0(Id, host.window, "contentView");
    const previous_responder = m0(Id, host.window, "firstResponder");

    m1(void, content, "addSubview:", web);
    defer {
        _ = m1(bool, host.window, "makeFirstResponder:", previous_responder);
        m0(void, web, "removeFromSuperview");
    }

    _ = m1(bool, host.window, "makeFirstResponder:", web);
    _ = m2(
        Id,
        web,
        "loadHTMLString:baseURL:",
        try string(a, @embedFile("../screen.html")),
        @as(Id, null),
    );

    var initial = false;

    while (true) {
        if (!host.pump(host.context)) return null;

        if (!initial and !m0(bool, web, "isLoading")) {
            initial = true;
            try screen.state("");
        }

        if (screen.worker) |*future| {
            if (!screen.work.done.load(.acquire)) continue;

            future.await(store.io);
            screen.worker = null;
            screen.clearFiles();

            if (screen.work.err) |err| {
                const message = try std.fmt.allocPrint(
                    a,
                    "Installation failed: {s}. Your existing installation is unchanged. Choose your files or try the download again.",
                    .{@errorName(err)},
                );

                defer a.free(message);

                try screen.state(message);
            } else {
                if (screen.work.result == .complete) return .retail;

                if (screen.work.result == .demo) screen.demo = true;

                try screen.state(switch (screen.work.result) {
                    .need_disc_1 => "Disc 2 installed. Add disc 1 to finish.",
                    .need_disc_2 => "Disc 1 installed. Add disc 2 to finish.",
                    .demo => "Demo installed. Choose Play Demo when you’re ready.",
                    .complete => unreachable,
                });
            }
        }

        const action = screen.action;

        screen.action = .none;
        if (action == .demo and screen.demo) return .demo;

        if (action == .choose) screen.choose() catch |err| {
            try screen.state(@errorName(err));
        };

        if (action == .demo or screen.files.items.len > 0) try screen.start(action == .demo);
    }
}

// Opt-in native integration check. It exercises the actual WebKit view, script
// bridge and worker in one caller-owned window, including a second demo launch.
test "native installer reuses its window and changes Download to Play Demo" {
    const Probe = struct {
        const Self = @This();
        extern "System" var _NSConcreteStackBlock: anyopaque;
        const Descriptor = extern struct { reserved: usize = 0, size: usize = @sizeOf(Block) };
        const descriptor = Descriptor{};

        const Block = extern struct {
            isa: *anyopaque = &_NSConcreteStackBlock,
            flags: i32 = 0,
            reserved: i32 = 0,
            invoke: *const fn (*const Block, Id, Id) callconv(.c) void = completed,
            descriptor: *const Descriptor = &descriptor,
            probe: *ThisProbe,
            // @This() inside Block denotes Block, so name the outer type.
            const ThisProbe = Self;
        };

        var pasteboard: Id = null;

        fn draggingPasteboard(_: Id, _: *anyopaque) callconv(.c) Id {
            return pasteboard;
        }

        fn dropFile(s: *Screen, path: []const u8) !void {
            pasteboard = m0(Id, objc_getClass("NSPasteboard"), "pasteboardWithUniqueName");
            defer m0(void, pasteboard, "releaseGlobally");

            const url = m1(Id, objc_getClass("NSURL"), "fileURLWithPath:", try string(s.a, path));
            if (!m1(
                bool,
                pasteboard,
                "writeObjects:",
                m1(Id, objc_getClass("NSArray"), "arrayWithObject:", url),
            )) return error.PasteboardFailed;

            const cls = objc_getClass("OLAssetInstallerTestDrag") orelse blk: {
                const new = objc_allocateClassPair(
                    objc_getClass("NSObject"),
                    "OLAssetInstallerTestDrag",
                    0,
                ) orelse return error.NativeClassFailed;

                if (!class_addMethod(
                    new,
                    sel_registerName("draggingPasteboard"),
                    @ptrCast(&draggingPasteboard),
                    "@@:",
                )) return error.NativeClassFailed;

                objc_registerClassPair(new);
                break :blk new;
            };

            const info = m0(Id, m0(Id, cls, "alloc"), "init");
            defer m0(void, info, "release");
            if (m1(
                usize,
                s.web,
                "draggingEntered:",
                info,
            ) != 1 or !m1(
                bool,
                s.web,
                "prepareForDragOperation:",
                info,
            ) or !m1(bool, s.web, "performDragOperation:", info)) return error.DropRejected;
        }

        ticks: usize = 0,
        stage: u8 = 0,
        pending: bool = false,
        response: ?[]u8 = null,
        failed: bool = false,
        expected_demo: bool = false,
        exe: []const u8,
        block: Block = undefined,

        fn completed(block: *const Block, result: Id, err: Id) callconv(.c) void {
            const p = block.probe;

            p.pending = false;
            if (err != null or result == null) {
                p.failed = true;
                return;
            }

            p.response = std.testing.allocator.dupe(u8, bytes(result)) catch {
                p.failed = true;
                return;
            };
        }

        fn pump(context: *anyopaque) bool {
            const p: *Self = @ptrCast(@alignCast(context));
            const until = m1(
                Id,
                objc_getClass("NSDate"),
                "dateWithTimeIntervalSinceNow:",
                @as(f64, 0.01),
            );

            m1(void, m0(Id, objc_getClass("NSRunLoop"), "currentRunLoop"), "runUntilDate:", until);

            p.ticks += 1;
            if (p.failed or p.ticks > 3000) return false;

            const s = active orelse return true;
            if (p.ticks < 10 or p.pending or m0(bool, s.web, "isLoading")) return true;
            if (p.response) |response| {
                defer std.testing.allocator.free(response);
                p.response = null;

                const expected = if (p.expected_demo or p.stage == 1) "Play Demo|fits" else "Download Outlaws Demo|fits";
                if (!std.mem.eql(u8, response, expected)) {
                    std.debug.print(
                        "native screen stage {d}, replay {any}, installed {any}: {s}\n",
                        .{ p.stage, p.expected_demo, s.demo, response },
                    );

                    p.failed = true;
                    return false;
                }

                if (p.expected_demo or p.stage == 1) {
                    m2(void, s.web, "evaluateJavaScript:completionHandler:", string(
                        s.a,
                        "document.getElementById('demo').click()",
                    ) catch {
                        p.failed = true;
                        return false;
                    }, @as(Id, null));

                    p.stage = 2;
                    return true;
                }

                dropFile(s, p.exe) catch {
                    p.failed = true;
                    return false;
                };

                p.stage = 1;
                return true;
            }

            if (p.stage == 2 or (p.stage == 1 and (!s.demo or s.worker != null))) return true;

            p.block = .{ .probe = p };
            p.pending = true;

            const js = "document.getElementById('demo').textContent+'|'+(document.documentElement.scrollHeight<=innerHeight?'fits':'overflows')";
            m2(void, s.web, "evaluateJavaScript:completionHandler:", string(s.a, js) catch {
                p.failed = true;
                return false;
            }, &p.block);

            return true;
        }
    };

    const a = std.testing.allocator;
    const io = std.testing.io;
    const exe = std.Io.Dir.cwd().realPathFileAlloc(
        io,
        "bin/outdemo_v2.exe",
        a,
    ) catch return error.SkipZigTest;

    defer a.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var store = try Store.init(a, io, root);
    defer store.deinit();
    const pool = m0(Id, m0(Id, objc_getClass("NSAutoreleasePool"), "alloc"), "init");
    defer m0(void, pool, "drain");
    const app = m0(Id, objc_getClass("NSApplication"), "sharedApplication");

    m0(void, app, "finishLaunching");

    const create: *const fn (
        Id,
        *anyopaque,
        Rect,
        usize,
        usize,
        bool,
    ) callconv(.c) Id = @ptrCast(&objc_msgSend);

    const window = create(
        m0(Id, objc_getClass("NSWindow"), "alloc"),
        sel_registerName("initWithContentRect:styleMask:backing:defer:"),
        Rect{ .x = 0, .y = 0, .w = 640, .h = 480 },
        15,
        2,
        false,
    );

    try std.testing.expect(window != null);
    defer m0(void, window, "release");

    const original_count = m0(usize, m0(Id, m0(Id, window, "contentView"), "subviews"), "count");
    const original_responder = m0(Id, window, "firstResponder");

    for ([_]bool{ false, true }) |again| {
        var probe = Probe{ .exe = exe, .expected_demo = again };
        const result = try run(
            a,
            &store,
            .{ .window = window.?, .context = &probe, .pump = Probe.pump },
        );

        try std.testing.expect(!probe.failed and probe.stage == 2);
        try std.testing.expectEqual(Kind.demo, result.?);
        try std.testing.expectEqual(
            original_count,
            m0(usize, m0(Id, m0(Id, window, "contentView"), "subviews"), "count"),
        );

        try std.testing.expectEqual(original_responder, m0(Id, window, "firstResponder"));
        try std.testing.expect(!try store.installed(.retail));
    }
}
