//! Secret areas: counting them at load and discovering them in play.
//!
//! A sector is a secret by a flag in the level data and gets a separate
//! runtime marker when the scene is built. Discovery tests the sector the
//! player is leaving, clears only the runtime marker, and counts up - so a
//! secret can be found once.

const level_module = @import("../assets/level.zig");
const scene_module = @import("../render/scene.zig");

pub const State = struct {
    total: u32 = 0,
    found: u32 = 0,

    pub fn init(level: *const level_module.Level) State {
        var state = State{};

        for (level.sectors) |sector| if (sector.flags & 0x02000000 != 0) {
            state.total +%= 1;
        };

        return state;
    }

    pub fn discover(self: *State, scene: *scene_module.Scene, sector: usize) bool {
        const flags = &scene.sectors[sector].runtime_flags;
        if (flags.* & 0x10000000 == 0) return false;

        flags.* &= ~@as(u32, 0x10000000);
        self.found +%= 1;

        return true;
    }
};
