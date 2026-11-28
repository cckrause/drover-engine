//! The messages actors, level scripts, generators and wall animations send
//! each other. Network packets carry the same numbers.

pub const MessageCode = enum(u32) {
    remove = 0x66,
    /// A one-shot switch flips its wall back and can be used again.
    reset_switch = 0x7a,
    damage = 0x7d1,
    push = 0x7d2,
    activate = 0x7d3,
    trigger = 0x7d6,
    next_stop = 0x7d7,
    previous_stop = 0x7d8,
    goto_stop = 0x7da,
    master_on = 0x7dd,
    master_off = 0x7de,
    set_bits = 0x7df,
    clear_bits = 0x7e0,
    /// The answers to a hit.
    hit_killed = 0x7e3,
    hit_survived = 0x7e4,
    user = 0x7e5,
    next_frame = 0x7e7,
    goto_frame = 0x7e8,
    previous_frame = 0x7e9,
    switch_frame = 0x7ea,
    _,

    /// The codes a generator takes, including some nothing names.
    pub fn reachesGenerators(self: MessageCode) bool {
        const value = @intFromEnum(self);

        return (value >= 0x7d4 and value <= 0x7de) or value == 0x7e1 or value == 0x7e2;
    }

    pub fn movesWallFrame(self: MessageCode) bool {
        return switch (self) {
            .next_stop, .previous_stop, .goto_stop, .next_frame, .goto_frame, .previous_frame, .switch_frame => true,
            else => false,
        };
    }
};
