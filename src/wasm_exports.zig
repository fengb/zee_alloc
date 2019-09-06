const builtin = @import("builtin");
const zee_alloc = @import("main.zig");

comptime {
    const c_exports = (zee_alloc.CExports{
        .malloc = true,
        .realloc = true,
        .free = true,
    }).using(zee_alloc.ZeeAllocDefaults.wasm_allocator);
}
