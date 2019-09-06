const builtin = @import("builtin");
const zee_alloc = @import("main.zig");

comptime {
    zee_alloc.exportC(zee_alloc.ZeeAllocDefaults.wasm_allocator);
}
