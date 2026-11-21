//! Saving which palette a level is on.
//!
//! It is an index, not a hash of the colours. Changing palette replaces the
//! display entries above the reserved system colours, which survive.

pub fn apply(session: anytype, index: u32) !void {
    if (index > 255 or index >= session.level.palettes.len) return error.InvalidSavedPaletteIndex;
    _ = try session.changePalette(@intCast(index));
}
