//! Saving the mission statistics: plain integer counters, written in a
//! fixed order, and added to the campaign totals as integers.

const Statistics = @import("header.zig").Statistics;

pub fn level(session: anytype) [15]u32 {
    const stats = session.inventory.statistics;
    var values = stats.native_words;
    values[1] = @bitCast(stats.gold);
    values[3] = session.weapon_state.shot_count;
    values[4] = stats.hits;
    values[5] = stats.kills;
    values[7] = @bitCast(stats.damage);
    values[8] = @bitCast(stats.health);
    values[9] = @bitCast(stats.items);
    values[11] = session.secrets.found;
    values[12] = session.secrets.total;
    return values;
}

pub fn apply(session: anytype, state: Statistics) void {
    const values = state.level;
    const stats = &session.inventory.statistics;
    stats.native_words = values;
    stats.gold = @bitCast(values[1]);
    session.weapon_state.shot_count = values[3];
    stats.hits = values[4];
    stats.kills = values[5];
    stats.damage = @bitCast(values[7]);
    stats.health = @bitCast(values[8]);
    stats.items = @bitCast(values[9]);
    session.secrets.found = values[11];
    session.secrets.total = values[12];
}
