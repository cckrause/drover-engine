//! What kind of game is running. Saves, the start request and the game
//! record carry the number; the values without a name are only ever met
//! through `isSinglePlayer` and `isMultiplayer`.

pub const GameType = enum(u32) {
    campaign = 1,
    joined = 4,
    hosting = 5,
    _,

    pub fn isNetwork(self: GameType) bool {
        return self == .joined or self == .hosting;
    }

    pub fn isSinglePlayer(self: GameType) bool {
        return @intFromEnum(self) >= 1 and @intFromEnum(self) <= 3;
    }

    pub fn isMultiplayer(self: GameType) bool {
        return @intFromEnum(self) >= 4 and @intFromEnum(self) <= 6;
    }
};
