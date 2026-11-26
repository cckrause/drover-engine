//! SDL uses the same fixed reservation as Zig and ENet. The hooks must be
//! installed before SDL creates any allocations, and remain installed until
//! every SDL subsystem, TLS entry, and network session has been released.

const std = @import("std");
const c = @import("sdl.zig").c;
const c_memory = @import("c_memory.zig");

pub const Hooks = struct {
    malloc: c.SDL_malloc_func,
    calloc: c.SDL_calloc_func,
    realloc: c.SDL_realloc_func,
    free: c.SDL_free_func,

    /// False means foreign process globals still own memory. Keep both the
    /// allocator owner and its reservation alive until process termination.
    pub fn restore(self: Hooks) bool {
        c.SDL_TLSCleanup();
        if (c.SDL_WasInit(0) != 0 or c.SDL_GetNumAllocations() > 0 or c_memory.count() != 0)
            return false;
        if (c.SDL_SetMemoryFunctions(self.malloc, self.calloc, self.realloc, self.free) != 0)
            return false;
        c_memory.uninstall();
        return true;
    }
};

pub fn install(allocator: std.mem.Allocator) !Hooks {
    // SDL3 (also used by sdl2-compat) returns -1 when counting is disabled:
    // https://wiki.libsdl.org/SDL3/SDL_GetNumAllocations
    // Our callbacks track every allocation made after installation.
    if (c.SDL_WasInit(0) != 0 or c.SDL_GetNumAllocations() > 0)
        return error.ForeignMemoryStillInUse;
    var saved: Hooks = undefined;
    c.SDL_GetMemoryFunctions(&saved.malloc, &saved.calloc, &saved.realloc, &saved.free);
    try c_memory.install(allocator);
    errdefer c_memory.uninstall();
    if (c.SDL_SetMemoryFunctions(c_memory.malloc, c_memory.calloc, c_memory.realloc, c_memory.free) != 0)
        return error.CannotSetMemoryFunctions;
    return saved;
}

test "memory budget SDL hooks use and release the startup reservation" {
    const MemoryBudget = @import("MemoryBudget.zig");
    var budget = try MemoryBudget.init(std.testing.allocator, std.testing.io, 16384);
    defer budget.deinit(std.testing.allocator);
    const hooks = try install(budget.allocator());
    defer if (!hooks.restore()) @panic("SDL test retained foreign memory");
    const memory = c.SDL_calloc(17, 9) orelse return error.OutOfMemory;
    try std.testing.expect(budget.stats().used > 0);
    const grown = c.SDL_realloc(memory, 1024) orelse return error.OutOfMemory;
    c.SDL_free(grown);
    try std.testing.expectEqual(@as(usize, 0), c_memory.count());
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
}
