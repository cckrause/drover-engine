//! The native symbol dispatcher the item definitions call into: a
//! registered name, resolved to a function, called with its arguments.
//!
//! This is the interface the data uses, not a bytecode format. Names are
//! registered with their type and resolved by exact spelling.

const std = @import("std");
pub const parser = @import("cmm_parser.zig");

pub const inventory_bindings = [_]Binding{
    .{ .name = "Inv_GroundObject", .native = .ground_object },
    .{ .name = "Inv_InstantGroundObject", .native = .instant_ground_object },
    .{ .name = "Inv_GenericObject", .native = .generic_object },
    .{ .name = "Inv_HealthObject", .native = .health_object },
    .{ .name = "Inv_Object", .native = .object },
    .{ .name = "Inv_GRFlagObject", .native = .ground_red_flag },
    .{ .name = "Inv_IRFlagObject", .native = .inventory_red_flag },
    .{ .name = "Inv_GBFlagObject", .native = .ground_blue_flag },
    .{ .name = "Inv_IBFlagObject", .native = .inventory_blue_flag },
    .{ .name = "Inv_GBallObject", .native = .ground_ball },
    .{ .name = "Inv_IBallObject", .native = .inventory_ball },
    .{ .name = "Inv_GDocObject", .native = .ground_document },
    .{ .name = "Inv_IDocObject", .native = .inventory_document },
    .{ .name = "Inv_GRFlagBaseObject", .native = .ground_red_flag_base },
    .{ .name = "Inv_GBFlagBaseObject", .native = .ground_blue_flag_base },
    .{ .name = "Inv_GSafeObject", .native = .ground_safe },
    .{ .name = "Inv_GSheriffStar", .native = .ground_sheriff_star },
    .{ .name = "Inv_GVanishingCream", .native = .ground_vanishing_cream },
};

pub const object_bindings = [_]Binding{
    .{ .name = "Slim_New", .native = .slim },
    .{ .name = "Sanchez_New", .native = .sanchez },
    .{ .name = "Bloodeye_New", .native = .enemy },
    .{ .name = "Farmer_New", .native = .farmer },
    .{ .name = "Bowers_New", .native = .slim },
    .{ .name = "Simms_New", .native = .farmer },
    .{ .name = "Mary_New", .native = .enemy },
    .{ .name = "DrDeath_New", .native = .slim },
    .{ .name = "TwoFeathers_New", .native = .sanchez },
    .{ .name = "Bob_New", .native = .bob },
    .{ .name = "ShBill_New", .native = .enemy },
    .{ .name = "ShBlood_New", .native = .enemy },
    .{ .name = "ShChez_New", .native = .enemy },
    .{ .name = "ShDick_New", .native = .dynamite },
    .{ .name = "ShMary_New", .native = .enemy },
    .{ .name = "Buckshot_New", .native = .enemy },
    .{ .name = "Dynamite_New", .native = .dynamite },
    .{ .name = "BGY_New", .native = .enemy },
    .{ .name = "Chicken_New", .native = .chicken },
    .{ .name = "Marshal_New", .native = .marshal },
    .{ .name = "Civilian_New", .native = .civilian },
    .{ .name = "Generic_New", .native = .generic_enemy },
    .{ .name = "Gen_New", .native = .generator },
    .{ .name = "Node_New", .native = .node },
};

pub const weapon_bindings = [_]Binding{
    .{ .name = "Weapon_FistHandler", .native = .weapon_fist_handler },
    .{ .name = "Weapon_PistolHandler", .native = .weapon_pistol_handler },
    .{ .name = "Weapon_RifleHandler", .native = .weapon_rifle_handler },
    .{ .name = "Weapon_ShotgunHandler", .native = .weapon_shotgun_handler },
    .{ .name = "Weapon_DBShotgunHandler", .native = .weapon_db_shotgun_handler },
    .{ .name = "Weapon_SawedShotgunHandler", .native = .weapon_sawed_shotgun_handler },
    .{ .name = "Weapon_GatlingHandler", .native = .weapon_gatling_handler },
    .{ .name = "Weapon_TNTHandler", .native = .weapon_tnt_handler },
    .{ .name = "Weapon_KnifeHandler", .native = .weapon_knife_handler },
    .{ .name = "Weapon_FistWaxLogic", .native = .weapon_fist_wax_logic },
    .{ .name = "Weapon_PistolWaxLogic", .native = .weapon_pistol_wax_logic },
    .{ .name = "Weapon_RifleWaxLogic", .native = .weapon_rifle_wax_logic },
    .{ .name = "Weapon_ShotgunWaxLogic", .native = .weapon_shotgun_wax_logic },
    .{ .name = "Weapon_DBShotgunWaxLogic", .native = .weapon_db_shotgun_wax_logic },
    .{ .name = "Weapon_SawedShotgunWaxLogic", .native = .weapon_sawed_shotgun_wax_logic },
    .{ .name = "Weapon_GatlingWaxLogic", .native = .weapon_gatling_wax_logic },
    .{ .name = "Weapon_TNTWaxLogic", .native = .weapon_tnt_wax_logic },
    .{ .name = "Weapon_KnifeWaxLogic", .native = .weapon_knife_wax_logic },
};

pub const projectile_bindings = [_]Binding{
    .{ .name = "shot_ProjectileDispatch", .native = .projectile_dispatch },
    .{ .name = "shot_ExpProjectileDispatch", .native = .explosive_projectile_dispatch },
};

pub const bindings = inventory_bindings ++ object_bindings ++ weapon_bindings ++ projectile_bindings;

pub const inventoryFunction = resolve;

pub const objectFunction = resolve;

pub const Native = enum(u32) {
    ground_object = 0x00416250,
    instant_ground_object = 0x00415690,
    generic_object = 0x004155b0,
    health_object = 0x004152c0,
    object = 0x00418310,
    ground_red_flag = 0x004165b0,
    inventory_red_flag = 0x004169b0,
    ground_blue_flag = 0x00416a90,
    inventory_blue_flag = 0x00416e90,
    ground_ball = 0x00416f70,
    inventory_ball = 0x00417340,
    ground_document = 0x00417420,
    inventory_document = 0x004177f0,
    ground_red_flag_base = 0x004178d0,
    ground_blue_flag_base = 0x00417c80,
    ground_safe = 0x00418030,
    ground_sheriff_star = 0x00415af0,
    ground_vanishing_cream = 0x00415ea0,
    slim = 0x004724e0,
    sanchez = 0x00472c50,
    enemy = 0x00472240,
    farmer = 0x00472350,
    bob = 0x00472620,
    dynamite = 0x00472450,
    chicken = 0x004722b0,
    marshal = 0x00472b10,
    civilian = 0x00472bb0,
    generic_enemy = 0x00471880,
    generator = 0x00473db0,
    node = 0x00475d30,
    projectile_dispatch = 0x004554b0,
    explosive_projectile_dispatch = 0x00455c20,
    weapon_fist_handler = 0x00466df0,
    weapon_pistol_handler = 0x00466fa0,
    weapon_rifle_handler = 0x00467130,
    weapon_shotgun_handler = 0x00467340,
    weapon_db_shotgun_handler = 0x004674d0,
    weapon_sawed_shotgun_handler = 0x00467690,
    weapon_gatling_handler = 0x00468210,
    weapon_tnt_handler = 0x00467850,
    weapon_knife_handler = 0x00467d80,
    weapon_fist_wax_logic = 0x00466e90,
    weapon_pistol_wax_logic = 0x00467010,
    weapon_rifle_wax_logic = 0x00467220,
    weapon_shotgun_wax_logic = 0x004673b0,
    weapon_db_shotgun_wax_logic = 0x00467540,
    weapon_sawed_shotgun_wax_logic = 0x00467700,
    weapon_gatling_wax_logic = 0x00468280,
    weapon_tnt_wax_logic = 0x004679d0,
    weapon_knife_wax_logic = 0x00467f00,
};

pub const Binding = struct { name: []const u8, native: Native };

pub const ContactState = struct {
    random: u32 = 0x742389ac,
    last_enemy_random: u32 = 0,
};

pub const ContactResult = struct {
    return_value: u32,
    next_tick: ?u32,
};

pub fn resolve(name: []const u8) !Native {
    if (name.len == 0) return error.CmmFunctionNotFound;
    if (!std.ascii.isAlphabetic(name[0]) or std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidCmmSymbol;
    const bucket = std.ascii.toUpper(name[0]);
    var i = bindings.len;
    while (i != 0) {
        i -= 1;
        const binding = bindings[i];
        if (std.ascii.toUpper(binding.name[0]) == bucket and std.mem.eql(u8, name, binding.name))
            return binding.native;
    }
    return error.CmmFunctionNotFound;
}

pub fn touchSolid(native: Native, state: *ContactState, sanchez_enabled: bool) !ContactResult {
    if (native == .sanchez and !sanchez_enabled) return .{ .return_value = 0, .next_tick = null };
    return switch (native) {
        .object => .{ .return_value = 1, .next_tick = null },
        .enemy, .chicken, .civilian, .slim, .farmer, .bob, .dynamite, .marshal, .sanchez => blk: {
            state.random = randomNext(state.random);
            state.last_enemy_random = state.random;
            break :blk .{ .return_value = 0, .next_tick = 0 };
        },
        .explosive_projectile_dispatch => .{ .return_value = 0, .next_tick = null },
        else => error.UnsupportedNativeContact,
    };
}

fn randomNext(state: u32) u32 {
    return if (state & 1 != 0) ~((state ^ 0xb9ffffff) >> 1) else state >> 1;
}

test "CMM registration preserves names, aliases and exact lookup" {
    try std.testing.expectEqual(Native.ground_object, try resolve("Inv_GroundObject"));
    try std.testing.expectEqual(Native.weapon_pistol_handler, try resolve("Weapon_PistolHandler"));
    try std.testing.expectEqual(try resolve("BGY_New"), try resolve("Bloodeye_New"));
    try std.testing.expectEqual(try resolve("Slim_New"), try resolve("DrDeath_New"));
    try std.testing.expectError(error.CmmFunctionNotFound, resolve("inv_GroundObject"));
    try std.testing.expectError(error.CmmFunctionNotFound, resolve("Inv_groundobject"));
    try std.testing.expectError(error.CmmFunctionNotFound, resolve(""));
    try std.testing.expectError(error.CmmFunctionNotFound, resolve("UnregisteredFunction"));
    try std.testing.expectError(error.InvalidCmmSymbol, resolve("_Inv_Object"));
    try std.testing.expectError(error.InvalidCmmSymbol, resolve("Inv_Object\x00suffix"));
}

test "CMM registrations and contact dispatch reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/cmm-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const Fixture = struct {
        registrations: []const struct { name: []const u8, address: u32, symbol_type: u32 },
        contacts: []const struct { name: []const u8, seed: u32, last_random: u32, next_tick_before: u32, result: u32, next_tick: u32, random: u32, enemy_random: u32, sanchez_enabled: bool = false },
    };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(bindings.len, parsed.value.registrations.len);
    for (parsed.value.registrations) |entry| {
        try std.testing.expectEqual(@as(u32, 0x80), entry.symbol_type);
        try std.testing.expectEqual(entry.address, @intFromEnum(try resolve(entry.name)));
    }
    for (parsed.value.contacts) |entry| {
        var state: ContactState = .{ .random = entry.seed, .last_enemy_random = entry.last_random };
        const result = try touchSolid(try resolve(entry.name), &state, entry.sanchez_enabled);
        try std.testing.expectEqual(entry.result, result.return_value);
        try std.testing.expectEqual(entry.next_tick, result.next_tick orelse entry.next_tick_before);
        try std.testing.expectEqual(entry.random, state.random);
        try std.testing.expectEqual(entry.enemy_random, state.last_enemy_random);
    }
}
