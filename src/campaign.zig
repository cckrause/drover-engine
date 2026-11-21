//! A campaign in progress: the start request, the story to play, the level
//! it selects next, and the network router, server and object database that
//! belong to the running game.
//!
//! The start request is a fixed 44-byte record. It is also what a host sends
//! other machines as the game record, so its layout is wire format: clear
//! all 44 bytes before filling it, and keep the field order.

const std = @import("std");
const lab = @import("assets/lab.zig");
const rcp = @import("assets/rcp.zig");
const network_message = @import("network/message.zig");
const network_router = @import("network/router.zig");
const network_server = @import("network/server.zig");
const network_database = @import("network/database.zig");
const network_layer = @import("network/network.zig");
const network_dead_reckoning = @import("network/dead_reckoning.zig");
const messages_module = @import("assets/messages.zig");
const loading_display = @import("ui/loading_display.zig");
pub const KeyQueue = @import("ui/dialog.zig").KeyQueue;
pub const CompletionGate = @import("network/server.zig").CompletionGate;

pub const Difficulty = enum(u32) {
    good = 0x100000,
    bad = 0x200000,
    ugly = 0x800000,

    pub fn fromSelection(index: i32) !Difficulty {
        return switch (index) {
            0 => .good,
            1 => .bad,
            2 => .ugly,
            else => error.InvalidDifficulty,
        };
    }
};

pub const StartRequest = extern struct {
    reserved: u32 = 0,
    flags: u32 = 0,
    game_type: u32 = 1,
    mode: u32 = 0,
    parameter: u32 = 0,
    filename: [24]u8 = [_]u8{0} ** 24,

    pub fn init(basename: []const u8) !StartRequest {
        if (basename.len + 4 >= 24) return error.CampaignFilenameTooLong;
        var request: StartRequest = .{};
        @memcpy(request.filename[0..basename.len], basename);
        @memcpy(request.filename[basename.len..][0..4], ".rcs");
        return request;
    }

    pub fn initHost(basename: []const u8, mode: u32, friendly_fire: bool) !StartRequest {
        const mode_flags = [_]u32{ 0, 1, 2, 2, 1, 1, 0 };
        if (mode == 0 or mode >= mode_flags.len) return error.InvalidMultiplayerMode;
        if (basename.len + 4 >= 24) return error.MultiplayerFilenameTooLong;
        var request: StartRequest = .{};
        request.game_type = 5;
        request.mode = mode;
        if (friendly_fire or mode_flags[mode] & 3 == 0) request.flags |= 0x80000000;
        @memcpy(request.filename[0..basename.len], basename);
        @memcpy(request.filename[basename.len..][0..4], ".RCM");
        return request;
    }

    pub fn path(self: *const StartRequest) []const u8 {
        return std.mem.sliceTo(&self.filename, 0);
    }
};

pub const HostChoice = struct {
    basename: []const u8,
    location: []const u8,
    mode: u32,
    mode_name: []const u8,
    game_name: []const u8,
    password: []const u8 = "",
    player_limit: u32 = 8,
    kill_limit: i32 = 0,
    minute_limit: i32 = 0,
    options: [7]bool = @splat(false),
    team: u8 = 1,
};

pub const JoinChoice = struct {
    session_name: []const u8,
    password: []const u8 = "",
};

pub const FrameHost = struct {
    context: *anyopaque,
    pump: *const fn (context: *anyopaque) anyerror!void,
    sound: *const fn (context: *anyopaque) anyerror!void,
    clock: *const fn (context: *anyopaque) u32,
    screen: loading_display.Screen,
    archive: lab.Archive,
};

pub const Timeout = struct {
    depth: u32 = 0,
    game_state: u32 = 0,
    scenario: u32 = 0,
    deadline: u32 = 0,
};

pub const HostSettings = struct {
    game_name: [14]u8 = @splat(0),
    location: [0x200]u8 = @splat(0),
    mode_name: [32]u8 = @splat(0),
    kill_limit: i32 = 0,
    minute_limit: i32 = 0,

    fn set(self: *HostSettings, choice: HostChoice) !void {
        if (choice.game_name.len >= self.game_name.len or choice.location.len >= self.location.len or choice.mode_name.len >= self.mode_name.len)
            return error.MultiplayerSettingTooLong;
        @memcpy(self.game_name[0..choice.game_name.len], choice.game_name);
        @memcpy(self.location[0..choice.location.len], choice.location);
        @memcpy(self.mode_name[0..choice.mode_name.len], choice.mode_name);
        self.kill_limit = choice.kill_limit;
        self.minute_limit = choice.minute_limit;
    }
};

pub const Startup = struct {
    request: StartRequest,
    difficulty: Difficulty,
    recipe: rcp.Recipe,
    recipe_data: ?[]u8 = null,
    recipe_loaded: bool = false,
    first_event: rcp.Entry,
    selected_level: ?rcp.Entry = null,
    story_index: ?usize = 0,
    skipped_movies: usize = 0,
    completed_movies: usize = 0,
    cancelled_movies: usize = 0,
    engine: @import("save/header.zig").EngineState = .{ .difficulty = 0, .mode_mask = 0x200000, .badge = 1, .game_860 = 0, .game_864 = 0, .game_type = 1, .game_state = 0, .previous_game_state = 0, .scenario = 1, .previous_scenario = 0 },
    mode: u32 = 0,
    accumulated_stats: [15]u32 = @splat(0),
    character: u32 = 0,
    player_definition: []const u8 = "cidjames.itm",
    character_code: u8 = 'J',
    router: network_router.Router,
    server: network_server.Server = .{},
    database: network_database.Database,
    messages: []const u8 = "",
    host: HostSettings = .{},
    team: u8 = 0,
    maintenance: network_message.Maintenance = .{},
    server_on: bool = false,
    loading: loading_display.LoadingDisplay = .{},
    frame_host: ?FrameHost = null,
    timeout: Timeout = .{},
    costume: u32 = 2,
    architecture_skip: u32 = 0,
    architecture: network_dead_reckoning.ArchitectureQueue = .{},
    architecture_due: u32 = 0,

    pub const NetworkLevel = struct {
        context: *anyopaque,
        dead_reckoning: *const fn (context: *anyopaque) anyerror!void,
        player: *const fn (context: *anyopaque, now: u32) anyerror!bool,
        architecture: *const fn (context: *anyopaque) anyerror!void,
        loaded: bool,
        server: ?network_server.Level = null,
    };

    const MaintenanceTasks = struct {
        startup: *Startup,
        level: ?NetworkLevel,

        fn tasks(self: *MaintenanceTasks) network_message.Maintenance.Tasks {
            return .{ .context = self, .player = player, .announce = announce, .critical = critical, .object_list = objectList, .architecture = architecture, .scores = scores, .configuration = configuration };
        }

        fn of(context: *anyopaque) *MaintenanceTasks {
            return @ptrCast(@alignCast(context));
        }

        fn player(context: *anyopaque, now: u32) anyerror!bool {
            const level = of(context).level orelse return false;
            return level.player(level.context, now);
        }

        fn announce(context: *anyopaque) anyerror!void {
            try of(context).startup.router.announce();
        }

        fn critical(context: *anyopaque) anyerror!void {
            const startup = of(context).startup;
            var bytes = try network_message.serverCritical(startup.router.own_client, startup.mode);
            try startup.router.postHereAndEveryone(0, 0x423, &bytes);
        }

        fn objectList(context: *anyopaque) anyerror!void {
            const startup = of(context).startup;
            try startup.database.sendObjectList(&startup.router);
        }

        fn architecture(context: *anyopaque) anyerror!void {
            const level = of(context).level orelse return error.ArchitectureWithoutLevel;
            try level.architecture(level.context);
        }

        fn scores(context: *anyopaque) anyerror!void {
            try of(context).startup.sendScores();
        }

        fn configuration(context: *anyopaque) anyerror!void {
            const startup = of(context).startup;
            try network_database.sendConfiguration(&startup.router, startup.server.configuration.bits());
        }
    };

    pub const ScenarioResult = enum {
        pass,
        story,
    };

    pub fn prepare(allocator: std.mem.Allocator, archive: lab.Archive, difficulty: Difficulty) !Startup {
        const filename = try singleStory(archive);
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return error.InvalidCampaignFilename;
        var self: Startup = .{ .request = try StartRequest.init(filename[0..dot]), .difficulty = difficulty, .recipe = undefined, .first_event = undefined, .router = network_router.Router.init(allocator), .database = network_database.Database.init(allocator) };
        errdefer self.router.deinit();
        errdefer self.database.deinit();
        try self.database.reset(&self.router);
        self.server.reset();
        self.router.reset();
        self.setScenario(0);
        self.server.configuration.options[2] = true;
        const record: network_message.GameRecord = @bitCast(self.request);
        try network_server.postGameInfo(&self.router, &record);
        self.engine.game_type = self.request.game_type;
        self.setScenario(3);
        try self.serverDrain(allocator);
        try network_server.requestGameInfo(&self.router);
        self.setScenario(4);
        if (try self.database.next(&self.router, false, 0) != null) return error.UnexpectedStartupMessage;
        try self.serverDrain(allocator);
        const request = try self.database.next(&self.router, false, 0) orelse return error.MissingGameInfoReply;
        if (request != .game_info) return error.UnexpectedStartupMessage;
        if (try self.database.next(&self.router, false, 0) != null) return error.UnexpectedStartupMessage;
        try self.loadGameInfo(allocator, archive, &request.game_info);
        return self;
    }

    pub fn initHost(allocator: std.mem.Allocator, choice: HostChoice) !Startup {
        var self: Startup = .{
            .request = try StartRequest.initHost(choice.basename, choice.mode, choice.options[1]),
            .difficulty = .bad,
            .recipe = undefined,
            .first_event = undefined,
            .router = network_router.Router.init(allocator),
            .database = network_database.Database.init(allocator),
            .mode = choice.mode,
            .team = choice.team,
        };
        errdefer self.router.deinit();
        errdefer self.database.deinit();
        try self.database.reset(&self.router);
        self.server.reset();
        self.router.reset();
        try self.host.set(choice);
        if (choice.password.len >= self.server.password.len) return error.MultiplayerPasswordTooLong;
        @memcpy(self.server.password[0..choice.password.len], choice.password);
        self.server.player_limit = choice.player_limit;
        self.server.configuration.options = choice.options;
        return self;
    }

    pub fn bindRouterParts(self: *Startup, messages: []const u8) void {
        self.messages = messages;
        self.router.game = .{
            .context = self,
            .players = routerPlayers,
            .addClient = routerAddClient,
            .removeClient = routerRemoveClient,
            .describe = routerDescribe,
            .scores = routerScores,
            .departed = routerDeparted,
            .connecting = routerConnecting,
            .leave = routerLeave,
            .local = routerLocal,
            .text = routerText,
            .forget = routerForget,
        };
    }

    pub fn loadingStep(self: *Startup, text: u32, from: i32, to: i32, at: i32) !void {
        const host = self.frame_host orelse {
            if (self.loading.isOpen()) return error.LoadingDisplayWithoutScreen;
            return self.networkStep(self.router.allocator, self.router.now, null);
        };
        try host.pump(host.context);
        try self.networkStep(self.router.allocator, host.clock(host.context), null);
        try host.sound(host.context);
        try self.loading.show(self.messages, host.screen, text, from, to, at);
    }

    pub fn frameStep(self: *Startup) !void {
        const host = self.frame_host orelse return error.FrameStepWithoutWindow;
        try host.pump(host.context);
        try self.networkStep(self.router.allocator, host.clock(host.context), null);
        try host.sound(host.context);
    }

    pub fn openLoading(self: *Startup, total: i32) !void {
        const host = self.frame_host orelse return error.LoadingDisplayWithoutScreen;
        try self.loading.open(self.router.allocator, host.archive, host.screen, total);
    }

    pub fn closeLoading(self: *Startup) !void {
        if (self.loading.depth == 0) return;
        const host = self.frame_host orelse return error.LoadingDisplayWithoutScreen;
        try self.loading.close(self.router.allocator, host.screen);
    }

    pub fn closeLoadingAll(self: *Startup) !void {
        if (self.loading.depth == 0) return;
        self.loading.depth = 1;
        try self.closeLoading();
    }

    pub fn connectHost(self: *Startup, provider: network_layer.Provider) !bool {
        self.router.network.load(provider);
        var name: [1 + 14]u8 = undefined;
        name[0] = if (self.server.password[0] != 0) '*' else ' ';
        const game = std.mem.sliceTo(&self.host.game_name, 0);
        @memcpy(name[1..][0..game.len], game);
        if (!try self.router.connect(true, name[0 .. 1 + game.len])) {
            self.router.network.unload();
            return false;
        }
        try self.describe();
        return true;
    }

    pub fn describe(self: *Startup) !void {
        var location: [0x14]u8 = @splat(0);
        var started_by: [0x14]u8 = @splat(0);
        var players: [0x14]u8 = @splat(0);
        @memcpy(players[0..8], "Players:");
        try self.textInto(0x13f3, &location);
        try self.textInto(0x13d2, &started_by);
        try self.textInto(0x1c8e, &players);
        var chicken: [0x50]u8 = @splat(0);
        const mode_name = if (self.mode == 3) blk: {
            try self.textInto(0x140f, &chicken);
            break :blk std.mem.sliceTo(&chicken, 0);
        } else std.mem.sliceTo(&self.host.mode_name, 0);
        var buffer: [0x400]u8 = undefined;
        buffer[0] = @truncate(self.mode);
        const args = .{ std.mem.sliceTo(&location, 0), std.mem.sliceTo(&self.host.location, 0), mode_name, std.mem.sliceTo(&players, 0) };
        const text = if (self.server.player_limit == 0)
            std.fmt.bufPrint(buffer[1 .. buffer.len - 1], "{s}\n   {s}\n{s}\n{s} {d}\n{s}\n   {s}", args ++ .{ self.router.clientCount(), std.mem.sliceTo(&started_by, 0), std.mem.sliceTo(&self.router.player_name, 0) })
        else
            std.fmt.bufPrint(buffer[1 .. buffer.len - 1], "{s}\n   {s}\n{s}\n{s} ({d} / {d})\n{s}\n   {s}", args ++ .{ self.router.clientCount(), self.server.player_limit, std.mem.sliceTo(&started_by, 0), std.mem.sliceTo(&self.router.player_name, 0) });
        const written = text catch return error.SessionDescriptionTooLong;
        buffer[1 + written.len] = 0;
        try self.router.network.describe(buffer[0 .. written.len + 2]);
    }

    pub fn applyFragDelta(self: *Startup, value: network_message.FragDelta) !void {
        try self.database.applyFragDelta(&self.router, value, .{ .now = self.router.now, .game_type = self.engine.game_type, .mode = self.mode, .game_state = self.engine.game_state });
        try self.sendScores();
    }

    pub fn sendScores(self: *Startup) !void {
        try self.database.sendScores(&self.router, .{
            .now = self.router.now,
            .game_type = self.engine.game_type,
            .mode = self.mode,
            .game_state = self.engine.game_state,
            .holder = self.holder(),
            .kill_limit = self.host.kill_limit,
            .minute_limit = self.host.minute_limit,
            .first_start = self.server.first_start_request,
        });
    }

    pub fn holder(self: *const Startup) u32 {
        return switch (self.mode) {
            3 => self.server.critical[0],
            2 => self.server.critical[11],
            else => 0,
        };
    }

    pub fn networkStep(self: *Startup, allocator: std.mem.Allocator, now: u32, level: ?NetworkLevel) !void {
        var user_messages: std.ArrayList(i32) = .empty;
        defer user_messages.deinit(allocator);
        try self.networkStepWith(allocator, now, level, self.server_on, &user_messages);
        if (user_messages.items.len != 0) return error.UnexpectedUserMessage;
    }

    pub fn networkStepWith(self: *Startup, allocator: std.mem.Allocator, now: u32, level: ?NetworkLevel, server_on: bool, user_messages: *std.ArrayList(i32)) !void {
        self.router.now = now;
        try self.router.process();
        if (level) |found| if (self.router.session_open) try found.dead_reckoning(found.context);
        const loaded = if (level) |found| found.loaded else false;
        if (server_on)
            try network_server.processRequests(&self.server, &self.router, .{ .now = now, .game_type = self.engine.game_type, .mode = self.mode, .level_loaded = loaded, .allocator = allocator, .user_messages = user_messages, .level = if (level) |found| found.server else null })
        else
            try network_server.dropRequests(&self.router);
        var tasks: MaintenanceTasks = .{ .startup = self, .level = level };
        try self.maintenance.run(now, self.engine.game_type, loaded, tasks.tasks());
        self.router.network.countFrame();
    }

    pub fn beginHost(self: *Startup, allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, archive: lab.Archive) !void {
        if (!self.router.session_open or self.router.own_client != 1) return error.NetworkHostSessionNotOpen;
        self.server_on = true;
        const record: network_message.GameRecord = @bitCast(self.request);
        try network_server.postGameInfo(&self.router, &record);
        self.setScenario(3);
        try self.networkStep(allocator, self.router.now, null);
        try network_server.requestGameInfo(&self.router);
        self.setScenario(4);
        if (try self.database.next(&self.router, false, 0) != null) return error.UnexpectedStartupMessage;
        try self.networkStep(allocator, self.router.now, null);
        const response = try self.database.next(&self.router, false, 0) orelse return error.MissingGameInfoReply;
        if (response != .game_info) return error.UnexpectedStartupMessage;
        if (try self.database.next(&self.router, false, 0) != null) return error.UnexpectedStartupMessage;
        self.recipe_data = try readNetworkRecipe(allocator, io, data_path, response.game_info.name());
        errdefer {
            allocator.free(self.recipe_data.?);
            self.recipe_data = null;
        }
        try self.loadGameInfo(allocator, archive, &response.game_info);
    }

    pub fn initJoin(allocator: std.mem.Allocator, choice: JoinChoice) !Startup {
        var self: Startup = .{
            .difficulty = .bad,
            .request = .{},
            .recipe = undefined,
            .first_event = undefined,
            .router = network_router.Router.init(allocator),
            .database = network_database.Database.init(allocator),
        };
        errdefer self.router.deinit();
        errdefer self.database.deinit();
        try self.database.reset(&self.router);
        self.server.reset();
        self.router.reset();
        if (choice.password.len >= self.router.join_password.len) return error.MultiplayerPasswordTooLong;
        @memcpy(self.router.join_password[0..choice.password.len], choice.password);
        return self;
    }

    pub fn beginJoin(self: *Startup, provider: network_layer.Provider, session_name: []const u8) !bool {
        try self.openLoading(100);
        try self.loadingStep(0x389, 0, 1, 0);
        self.router.network.load(provider);
        const opened = self.router.connect(false, session_name) catch |err| {
            try self.closeLoading();
            self.router.network.unload();
            return err;
        };
        if (opened) return true;
        try self.closeLoading();
        self.router.network.unload();
        return false;
    }

    pub fn stepJoin(self: *Startup, keys: *KeyQueue) !?network_router.JoinEnd {
        const cancelled = escapePressed(keys);
        if (self.frame_host) |host| self.router.now = host.clock(host.context);
        const end = try self.router.stepJoin(cancelled) orelse {
            try self.frameStep();
            return null;
        };
        switch (end) {
            .joined => {
                try self.loadingStep(0x38c, 0, 1, 0);
                self.request.filename[0..4].* = .{ '!', 0, 0, 0 };
                self.setScenario(3);
            },
            .failed => {
                try self.closeLoading();
                self.router.network.unload();
            },
        }
        return end;
    }

    pub fn scenarioStep(self: *Startup, keys: *KeyQueue) !ScenarioResult {
        if (self.engine.game_state != 0) return error.JoinGameStateNotPorted;
        const host = self.frame_host orelse return error.FrameStepWithoutWindow;
        switch (self.engine.scenario) {
            1 => {
                if (!self.recipe_loaded) return error.JoinStoryWithoutRecipe;
                return .story;
            },
            3 => {
                try network_server.requestGameInfo(&self.router);
                try self.loadingStep(0x38a, 0, 1, 0);
                self.keepForTimeout(4, host.clock(host.context));
                return .pass;
            },
            4 => {
                _ = self.checkTimeout(host.clock(host.context), 5000);
                if (!escapePressed(keys)) return .pass;
                return error.JoinWaitCancelNotPorted;
            },
            else => return error.JoinScenarioNotPorted,
        }
    }

    pub fn joinPass(self: *Startup, allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, archive: lab.Archive, keys: *KeyQueue) !ScenarioResult {
        const host = self.frame_host orelse return error.FrameStepWithoutWindow;
        try host.pump(host.context);
        try self.networkStep(allocator, host.clock(host.context), null);
        try host.sound(host.context);
        if (try self.scenarioStep(keys) == .story) return .story;
        try self.drainDatabase(allocator, io, data_path, archive);
        try host.pump(host.context);
        return .pass;
    }

    pub fn beginJoinedLevel(self: *Startup) !void {
        try self.openLoading(60);
        try self.loadingStep(900, 0, 1, 0);
    }

    pub fn endJoinedLevel(self: *Startup) !void {
        try self.closeLoadingAll();
        const host = self.frame_host orelse return error.FrameStepWithoutWindow;
        @memset(host.screen.pixels, 0);
        try host.screen.present(host.screen.context, host.screen.pixels, host.screen.palette);
        @memset(host.screen.pixels, 0);
    }

    pub fn drainDatabase(self: *Startup, allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, archive: lab.Archive) !void {
        const now = self.router.now;
        const context: network_database.LevelContext = .{ .now = now, .game_type = self.engine.game_type, .mode = self.mode, .game_state = self.engine.game_state };
        while (try self.database.next(&self.router, false, now)) |request| switch (request) {
            .game_info => |record| try self.loadJoinedGameInfo(allocator, io, data_path, archive, &record),
            .frag_update => |bytes| try self.database.applyFragUpdate(&self.router, bytes, context),
            .frag_delta => |value| try self.applyFragDelta(value),
            .configuration => |bits| self.server.configuration.fromDatabase(bits),
            .critical => if (self.mode >= 1 and self.mode <= 3) return error.ServerCriticalModeNotPorted,
            .comment => return error.CommentBeforeLevelNotPorted,
            .end_level => return error.EndLevelBeforeLevelNotPorted,
            .start_here, .link, .bits, .actor, .generator, .object_request, .actor_create, .corpse, .shatter_wall => return error.UnexpectedStartupMessage,
        };
        try self.database.drained(&self.router, .{ .now = now, .game_type = self.engine.game_type, .mode = self.mode, .game_state = self.engine.game_state }, self.holder());
    }

    pub fn restore(allocator: std.mem.Allocator, archive: lab.Archive, difficulty: Difficulty, filename: []const u8, ordinal: u32) !Startup {
        if (filename.len >= 24) return error.CampaignFilenameTooLong;
        const data = try archive.find(filename, 0x52435042);
        const recipe = try rcp.Recipe.parse(allocator, data);
        errdefer recipe.deinit(allocator);
        if (ordinal == 0 or ordinal > recipe.story.len) return error.InvalidSaveCampaignPosition;
        const index = ordinal - 1;
        if (recipe.story[index].kind != .level) return error.InvalidSaveCampaignPosition;
        var request: StartRequest = .{};
        @memcpy(request.filename[0..filename.len], filename);
        var self: Startup = .{ .request = request, .difficulty = difficulty, .recipe = recipe, .recipe_loaded = true, .first_event = recipe.story[0], .story_index = index, .router = network_router.Router.init(allocator), .database = network_database.Database.init(allocator) };
        errdefer self.database.deinit();
        try self.database.reset(&self.router);
        self.server.reset();
        self.router.reset();
        return self;
    }

    pub fn deinit(self: *Startup, allocator: std.mem.Allocator) void {
        self.loading.release(self.router.allocator);
        if (self.recipe_loaded) self.recipe.deinit(allocator);
        if (self.recipe_data) |data| allocator.free(data);
        self.architecture.deinit(self.router.allocator);
        self.router.deinit();
        self.database.deinit();
    }

    pub fn currentEvent(self: *const Startup) ?rcp.Entry {
        const index = self.story_index orelse return null;
        return self.recipe.story[index];
    }

    pub fn finishMovie(self: *Startup, cancelled: bool) !void {
        const event = self.currentEvent() orelse return error.CampaignExhausted;
        if (event.kind != .movie) return error.CurrentEventIsNotMovie;
        if (cancelled) self.cancelled_movies += 1 else self.completed_movies += 1;
        const next = self.story_index.? + 1;
        self.story_index = if (next < self.recipe.story.len) next else null;
    }

    pub fn selectLevel(self: *Startup) !rcp.Entry {
        if (self.selected_level != null) return error.LevelAlreadySelected;
        const event = self.currentEvent() orelse return error.CampaignHasNoLevel;
        if (event.kind == .movie) return error.MoviePlaybackPending;
        if (event.kind != .level) return error.UnsupportedStoryEventBeforeLevel;
        self.selected_level = event;
        if (self.engine.game_type >= 4 and self.engine.game_type <= 6) {
            self.engine.mode_mask = @intFromEnum(self.difficulty);
            self.engine.game_860 = 0;
            self.engine.game_864 = 0;
        } else self.bindLevel();
        return event;
    }

    pub fn networkLevelLoaded(self: *Startup) void {
        self.setScenario(7);
    }

    pub fn enterLobby(self: *Startup) !void {
        if (self.engine.scenario != 7) return error.LobbyOutsideScenario7;
        self.startedAtRecord();
        self.setScenario(8);
    }

    pub fn startedAtRecord(self: *Startup) void {
        self.setGameState(1);
        self.setScenario(2);
    }

    pub fn revived(self: *Startup) void {
        self.setGameState(3);
    }

    pub fn restartInLevel(self: *Startup) !void {
        if (self.engine.game_state != 3) return error.NoRevivedPlayer;
        self.setGameState(0);
        self.setScenario(5);
    }

    pub fn leaveLobby(self: *Startup, result: i32) !void {
        if (self.engine.game_state != 1 or self.engine.scenario != 8) return error.LobbyNotOpen;
        const mode_words = @import("ui/network_lobby.zig").mode_words;
        if (self.mode >= mode_words.len) return error.InvalidMultiplayerMode;
        self.team = switch (result) {
            1 => if (mode_words[self.mode] & 2 == 0) 1 else 2,
            2 => 1,
            3 => 2,
            else => return error.InvalidLobbyResult,
        };
        self.setScenario(6);
        self.setGameState(0);
        self.setScenario(5);
    }

    pub fn startStep(self: *Startup, now: u32) !void {
        if (self.engine.game_state != 0) return error.StartStepOutsideState0;
        switch (self.engine.scenario) {
            5 => {
                try network_server.requestStartPosition(&self.router, self.team);
                self.keepForTimeout(6, now);
            },
            6 => _ = self.checkTimeout(now, 5000),
            else => return error.StartStepScenarioNotPorted,
        }
    }

    pub fn bindLevel(self: *Startup) void {
        self.engine.mode_mask = @intFromEnum(self.difficulty);
        self.engine.game_860 = 0;
        self.engine.game_864 = 0;
        self.engine.previous_scenario = self.engine.scenario;
        self.engine.scenario = 5;
        self.engine.previous_game_state = self.engine.game_state;
        self.engine.game_state = 0;
        self.engine.previous_scenario = self.engine.scenario;
        self.engine.scenario = 6;
        self.engine.previous_game_state = self.engine.game_state;
        self.engine.game_state = 1;
        self.engine.previous_scenario = self.engine.scenario;
        self.engine.scenario = 2;
    }

    pub fn finishLevel(self: *Startup) !void {
        const event = self.currentEvent() orelse return error.CampaignExhausted;
        if (event.kind != .level) return error.CurrentEventIsNotLevel;
        const selected = self.selected_level orelse return error.LevelNotSelected;
        if (selected.disc != event.disc or !std.mem.eql(u8, selected.name, event.name))
            return error.CampaignLevelMismatch;
        self.engine.previous_game_state = self.engine.game_state;
        self.engine.game_state = 2;
        self.engine.previous_game_state = self.engine.game_state;
        self.engine.game_state = 0;
        self.engine.previous_scenario = self.engine.scenario;
        self.engine.scenario = 1;
        self.selected_level = null;
        const next = self.story_index.? + 1;
        self.story_index = if (next < self.recipe.story.len) next else null;
    }

    pub fn levelForDiagnostics(self: *Startup) !rcp.Entry {
        if (self.selected_level != null) return error.LevelAlreadySelected;
        while (self.currentEvent()) |event| {
            switch (event.kind) {
                .movie => {
                    self.skipped_movies += 1;
                    const next = self.story_index.? + 1;
                    self.story_index = if (next < self.recipe.story.len) next else null;
                },
                .level => return self.selectLevel(),
                .credits, .text => return error.UnsupportedStoryEventBeforeLevel,
            }
        }
        return error.CampaignHasNoLevel;
    }

    fn routerPlayers(context: *anyopaque) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        try self.database.rebuildPlayers(&self.router, self.mode, self.engine.game_type, self.router.now);
    }

    fn routerAddClient(context: *anyopaque, number: u32) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        if (number >= network_router.client_slots) return error.InvalidNetworkClientNumber;
        try self.database.addClient(@intCast(number));
    }

    fn routerRemoveClient(context: *anyopaque, number: u32) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        if (number >= network_router.client_slots) return error.InvalidNetworkClientNumber;
        try self.database.removeClient(@intCast(number));
    }

    fn routerDescribe(context: *anyopaque) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        try self.describe();
    }

    fn routerScores(context: *anyopaque) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        try self.sendScores();
    }

    fn routerDeparted(context: *anyopaque, name: []const u8, destination: u32) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        const template = messages_module.lookup(self.messages, 0x1403) catch |err| switch (err) {
            error.MessageNotFound => return error.DepartureTextNotFound,
            else => return err,
        };
        if (template.len >= 0x50) return error.DepartureTextTooLong;
        var buffer: [0x50]u8 = undefined;
        const text = try printName(template, name, &buffer);
        try network_database.comment(&self.router, text, destination);
    }

    fn routerConnecting(context: *anyopaque) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        try self.loadingStep(0x38c, 0, 1, 0);
    }

    fn routerLeave(context: *anyopaque) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        self.router.close();
        self.server.close();
        self.database.close();
        self.router.network.unload();
        self.router.dropQueued();
    }

    fn routerLocal(context: *anyopaque) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        try self.database.reset(&self.router);
        self.server.reset();
        self.router.reset();
    }

    fn routerText(context: *anyopaque, id: u32, buffer: []u8) void {
        const self: *Startup = @ptrCast(@alignCast(context));
        const text = messages_module.lookup(self.messages, id) catch return;
        const length = @min(text.len, buffer.len);
        @memcpy(buffer[0..length], text[0..length]);
        @memset(buffer[length..], 0);
    }

    fn routerForget(context: *anyopaque, number: u32) anyerror!void {
        const self: *Startup = @ptrCast(@alignCast(context));
        self.server.forget(number);
    }

    fn textInto(self: *Startup, id: u32, buffer: []u8) !void {
        const text = messages_module.lookup(self.messages, id) catch |err| switch (err) {
            error.MessageNotFound => return,
            else => return err,
        };
        if (text.len >= buffer.len) return error.NetworkTextTooLong;
        @memcpy(buffer[0..text.len], text);
        @memset(buffer[text.len..], 0);
    }

    fn escapePressed(keys: *KeyQueue) bool {
        while (true) switch (keys.next()) {
            0 => return false,
            1 => return true,
            else => {},
        };
    }

    fn checkTimeout(self: *Startup, now: u32, wait: u32) bool {
        if (now < self.timeout.deadline) return true;
        if (self.timeout.depth > 0) {
            self.timeout.depth -= 1;
            self.setGameState(self.timeout.game_state);
            self.setScenario(self.timeout.scenario);
            self.timeout.deadline = now +% wait;
            return false;
        }
        self.setGameState(0);
        self.setScenario(0);
        return true;
    }

    fn keepForTimeout(self: *Startup, wait_scenario: u32, now: u32) void {
        self.timeout = .{ .depth = 1, .game_state = self.engine.game_state, .scenario = self.engine.scenario, .deadline = 0 };
        self.engine.previous_game_state = self.engine.game_state;
        self.engine.previous_scenario = self.engine.scenario;
        self.engine.scenario = wait_scenario;
        self.timeout.deadline = now +% 5000;
    }

    fn setGameState(self: *Startup, state: u32) void {
        self.engine.previous_game_state = self.engine.game_state;
        self.engine.game_state = state;
    }

    fn loadJoinedGameInfo(self: *Startup, allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, archive: lab.Archive, record: *const network_message.GameRecord) !void {
        if (self.recipe_loaded) return error.SecondGameInfoNotPorted;
        self.recipe_data = try readNetworkRecipe(allocator, io, data_path, record.name());
        errdefer {
            allocator.free(self.recipe_data.?);
            self.recipe_data = null;
        }
        try self.loadGameInfo(allocator, archive, record);
    }

    fn readNetworkRecipe(allocator: std.mem.Allocator, io: std.Io, data_path: []const u8, filename: []const u8) ![]u8 {
        if (filename.len < 5 or !std.ascii.endsWithIgnoreCase(filename, ".RCM") or std.mem.indexOfAny(u8, filename, "/\\:") != null)
            return error.InvalidMultiplayerRecipeName;
        const directory = std.fs.path.dirname(data_path) orelse ".";
        var dir = try std.Io.Dir.cwd().openDir(io, directory, .{});
        defer dir.close(io);
        return dir.readFileAlloc(io, filename, allocator, .limited(64 * 1024));
    }

    fn serverDrain(self: *Startup, allocator: std.mem.Allocator) !void {
        var user_messages: std.ArrayList(i32) = .empty;
        defer user_messages.deinit(allocator);
        try network_server.processRequests(&self.server, &self.router, .{ .now = null, .game_type = self.engine.game_type, .mode = self.mode, .level_loaded = false, .allocator = allocator, .user_messages = &user_messages });
        if (user_messages.items.len != 0) return error.UnexpectedStartupMessage;
    }

    fn setScenario(self: *Startup, scenario: u32) void {
        self.engine.previous_scenario = self.engine.scenario;
        self.engine.scenario = scenario;
    }

    fn loadGameInfo(self: *Startup, allocator: std.mem.Allocator, archive: lab.Archive, record: *const network_message.GameRecord) !void {
        self.mode = record.mode;
        const data = if (self.recipe_data) |external| external else archive.find(record.name(), 0x52435042) catch |err| switch (err) {
            error.ResourceNotFound => return error.CampaignNotFoundNotPorted,
            else => return err,
        };
        self.recipe = try rcp.Recipe.parse(allocator, data);
        errdefer self.recipe.deinit(allocator);
        self.setScenario(1);
        self.engine.game_type = if (record.game_type < 4 or record.game_type > 5) record.game_type else if (self.router.own_client == 1) 5 else 4;
        self.router.game_type = self.engine.game_type;
        if (self.engine.game_type == 4 or self.engine.game_type == 5) {
            const character = networkCharacter(self.costume);
            self.player_definition = character.definition;
            self.character_code = character.code;
        }
        var sequence = rcp.Sequence{ .recipe = &self.recipe };
        self.first_event = sequence.advance() orelse return error.EmptyCampaign;
        self.recipe_loaded = true;
    }
};

pub const DeathRestart = struct {
    queued: bool = false,
    deadline: u32 = 0,

    pub fn input(self: *DeathRestart, dead_grounded: bool, fire_pressed: bool, now: u32) bool {
        if (!dead_grounded or (!fire_pressed and !self.queued)) return false;
        if (self.deadline < now) {
            self.queued = false;
            return true;
        }
        self.queued = true;
        return false;
    }
};

pub fn networkCharacter(costume: u32) struct { definition: []const u8, code: u8 } {
    return switch (costume) {
        1 => .{ .definition = "cidsanch.itm", .code = 'S' },
        3 => .{ .definition = "cidfeath.itm", .code = 'F' },
        4 => .{ .definition = "ciddeath.itm", .code = 'D' },
        5 => .{ .definition = "cidbob.itm", .code = 'B' },
        6 => .{ .definition = "cidmary.itm", .code = 'M' },
        else => .{ .definition = "cidmjame.itm", .code = 'J' },
    };
}

pub fn printName(template: []const u8, name: []const u8, out: []u8) ![]const u8 {
    return printStrings(template, &.{name}, out);
}

pub fn printStrings(template: []const u8, arguments: []const []const u8, out: []u8) ![]const u8 {
    var length: usize = 0;
    var next: usize = 0;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        var piece = template[i .. i + 1];
        if (template[i] == '%') {
            if (i + 1 == template.len) return error.UnsupportedNetworkText;
            i += 1;
            switch (template[i]) {
                '%' => piece = "%",
                's' => {
                    if (next == arguments.len) return error.UnsupportedNetworkText;
                    piece = arguments[next];
                    next += 1;
                },
                else => return error.UnsupportedNetworkText,
            }
        }
        if (length + piece.len >= out.len) return error.NetworkTextTooLong;
        @memcpy(out[length..][0..piece.len], piece);
        length += piece.len;
    }
    return out[0..length];
}

pub fn inventoryLevelFlags(flags: u32) u32 {
    var result: u32 = 0;
    for ([_]u32{ 1, 2, 4, 8, 0x10, 0x40 }, [_]u32{ 0x8000, 0x4000, 0x10000, 0x20000, 0x40000, 0x80000 }) |source, destination| {
        if (flags & source != 0) result |= destination;
    }
    return result;
}

fn singleStory(archive: lab.Archive) ![]const u8 {
    var selected: ?[]const u8 = null;
    for (archive.front) |patch| try storyCandidates(patch, &selected);
    try storyCandidates(archive, &selected);
    return selected orelse error.NoStoryCampaign;
}

fn storyCandidates(archive: lab.Archive, selected: *?[]const u8) !void {
    var entries = archive.iterator();
    while (try entries.next()) |entry| {
        if (entry.name.len < 4 or !std.ascii.eqlIgnoreCase(entry.name[entry.name.len - 4 ..], ".rcs")) continue;
        if (selected.* != null) return error.MultipleCampaignChooserNotImplemented;
        selected.* = entry.name;
    }
}

test "main-game launch record layout and difficulty masks" {
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(StartRequest));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(StartRequest, "filename"));
    const request = try StartRequest.init("OUTLAWS");
    try std.testing.expectEqualStrings("OUTLAWS.rcs", request.path());
    try std.testing.expectEqual(@as(u32, 1), request.game_type);
    try std.testing.expectEqual(@as(u32, 0), request.mode | request.flags | request.parameter | request.reserved);
    try std.testing.expectEqual(@as(u32, 0x800000), @intFromEnum(try Difficulty.fromSelection(2)));
    try std.testing.expectError(error.InvalidDifficulty, Difficulty.fromSelection(3));
    try std.testing.expectError(error.CampaignFilenameTooLong, StartRequest.init("12345678901234567890"));
}

test "v1.1.1 host request uses the reference mode table and RCM name" {
    for (1..7) |index| {
        const mode: u32 = @intCast(index);
        const request = try StartRequest.initHost("DRYGULCH", mode, false);
        try std.testing.expectEqual(@as(u32, 5), request.game_type);
        try std.testing.expectEqual(mode, request.mode);
        try std.testing.expectEqualStrings("DRYGULCH.RCM", request.path());
        try std.testing.expectEqual(@as(u32, if (mode == 6) 0x80000000 else 0), request.flags);
        const friendly = try StartRequest.initHost("DRYGULCH", mode, true);
        try std.testing.expectEqual(@as(u32, 0x80000000), friendly.flags);
    }
    try std.testing.expectError(error.InvalidMultiplayerMode, StartRequest.initHost("DRYGULCH", 0, false));
    try std.testing.expectError(error.MultiplayerFilenameTooLong, StartRequest.initHost("12345678901234567890", 6, false));

    var router = network_router.Router.init(std.testing.allocator);
    defer router.deinit();
    router.reset();
    const request = try StartRequest.initHost("DRYGULCH", 6, false);
    const record: network_message.GameRecord = @bitCast(request);
    try network_server.postGameInfo(&router, &record);
    const bytes = try router.read(network_message.Queue.server) orelse return error.MissingHostGameInfo;
    defer router.release(bytes);
    try std.testing.expectEqualSlices(u8, "\x00\x08\x10\x00\x00\x08\x10\x00\x00\x08\x00\x00\xec\x03\x00\x00" ++
        "\x00\x00\x00\x80\x00\x00\x00\x00\x05\x00\x06\x00DRYGULCH.RCM\x00", bytes);
}

test "Dry Gulch multiplayer recipe is loaded beside the game archive" {
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = try Startup.readNetworkRecipe(std.testing.allocator, std.testing.io, path, "DRYGULCH.RCM");
    defer std.testing.allocator.free(bytes);
    const recipe = try rcp.Recipe.parse(std.testing.allocator, bytes);
    defer recipe.deinit(std.testing.allocator);
    try std.testing.expect(recipe.modes & (1 << 5) != 0);
    try std.testing.expectEqual(@as(usize, 1), recipe.story.len);
    try std.testing.expectEqualStrings("drygulch", recipe.story[0].name);
    try std.testing.expectError(error.InvalidMultiplayerRecipeName, Startup.readNetworkRecipe(std.testing.allocator, std.testing.io, path, "../OTHER.RCM"));
}

test "host router binds the ported player list and client number tables" {
    var startup = try Startup.initHost(std.testing.allocator, .{ .basename = "DRYGULCH", .location = "Dry Gulch", .mode = 6, .mode_name = "Death Match", .game_name = "Outlaws" });
    defer startup.deinit(std.testing.allocator);
    startup.bindRouterParts("");
    try startup.router.game.addClient(startup.router.game.context, 3);
    try std.testing.expect(startup.database.tables[3] != null);
    try startup.router.game.players(startup.router.game.context);
    try std.testing.expectEqual(@as(usize, 0), startup.database.player_count);
    try startup.router.game.removeClient(startup.router.game.context, 3);
    try std.testing.expect(startup.database.tables[3] == null);
}

test "host game record opens the Dry Gulch multiplayer story" {
    const path = "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 * 1024 * 1024));
    defer std.testing.allocator.free(bytes);
    const archive = try lab.Archive.init(bytes);
    var startup = try Startup.initHost(std.testing.allocator, .{ .basename = "DRYGULCH", .location = "Dry Gulch", .mode = 6, .mode_name = "Death Match", .game_name = "Outlaws" });
    defer startup.deinit(std.testing.allocator);
    startup.router.session_open = true;
    try startup.beginHost(std.testing.allocator, std.testing.io, path, archive);
    try std.testing.expectEqual(@as(u32, 5), startup.engine.game_type);
    try std.testing.expectEqual(@as(u32, 6), startup.mode);
    try std.testing.expectEqualStrings("DRYGULCH.RCM", startup.request.path());
    try std.testing.expectEqualStrings("drygulch", startup.currentEvent().?.name);
}

test "the reference END_LEVEL clock admission and unsigned wrapping" {
    const Case = struct {
        last: u32,
        now: u32,
        accepted: bool,
    };
    for ([_]Case{
        .{ .last = 0, .now = 0, .accepted = false },
        .{ .last = 0, .now = 9999, .accepted = false },
        .{ .last = 0, .now = 10000, .accepted = false },
        .{ .last = 0, .now = 10001, .accepted = true },
        .{ .last = 10001, .now = 20001, .accepted = false },
        .{ .last = 10001, .now = 20002, .accepted = true },
        .{ .last = 0xfffffff0, .now = 9983, .accepted = false },
        .{ .last = 0xfffffff0, .now = 9984, .accepted = false },
        .{ .last = 0xfffffff0, .now = 9985, .accepted = true },
    }) |case| {
        var gate = CompletionGate{ .last = case.last };
        try std.testing.expectEqual(case.accepted, gate.accept(case.now));
        try std.testing.expectEqual(if (case.accepted) case.now else case.last, gate.last);
    }
}

test "CD1 campaign completion preserves all level and movie entries across discs" {
    const allocator = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(bytes);
    var startup = try Startup.prepare(allocator, try lab.Archive.init(bytes), .good);
    defer startup.deinit(allocator);
    const levels = [_][]const u8{ "hideout", "town", "train", "canyon", "mill", "simms", "miner", "cliff", "ranch" };
    const movies = [_][]const u8{ "in_shb.san", "she_tob.san", "toe_trb.san", "tre_cab.san", "cae_sab.san", "sae_hib.san", "hie_mnb.san", "mne_clb.san", "cle_rab.san" };
    for (levels, movies, 0..) |level_name, movie_name, index| {
        try std.testing.expectEqualStrings(movie_name, startup.currentEvent().?.name);
        try std.testing.expectEqual(@as(u8, if (index < 5) 1 else 2), startup.currentEvent().?.disc);
        try std.testing.expectError(error.CurrentEventIsNotLevel, startup.finishLevel());
        try startup.finishMovie(index & 1 != 0);
        try std.testing.expectError(error.LevelNotSelected, startup.finishLevel());
        const level = try startup.selectLevel();
        try std.testing.expectEqualStrings(level_name, level.name);
        try std.testing.expectEqual(@as(u8, if (index < 4) 1 else 2), level.disc);
        try startup.finishLevel();
        try std.testing.expect(startup.selected_level == null);
    }
    try std.testing.expectEqual(rcp.Kind.credits, startup.currentEvent().?.kind);
    try std.testing.expectEqualStrings("rae.san", startup.currentEvent().?.name);
    try std.testing.expectEqual(@as(u8, 2), startup.currentEvent().?.disc);
    try std.testing.expectEqual(@as(usize, 5), startup.completed_movies);
    try std.testing.expectEqual(@as(usize, 4), startup.cancelled_movies);
    try std.testing.expectEqual(@as(usize, 0), startup.skipped_movies);
}
