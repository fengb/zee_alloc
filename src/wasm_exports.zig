const builtin = @import("builtin");
const std = @import("std");
const zee_alloc = @import("slab.zig");

// Pull in for documentation
usingnamespace zee_alloc;

comptime {
    zee_alloc.ExportC.run(.{
        .allocator = zee_alloc.ZeeAllocDefaults.wasm_allocator,
        .malloc = true,
        .free = true,
        .realloc = true,
        .calloc = true,
    });
}
