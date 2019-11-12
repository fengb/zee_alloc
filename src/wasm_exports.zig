const builtin = @import("builtin");
const std = @import("std");
const zee_alloc = @import("main.zig");

// Pull in for documentation
usingnamespace zee_alloc;

comptime {
    (zee_alloc.ExportC{
        .allocator = zee_alloc.ZeeAllocDefaults.wasm_allocator,
        .malloc = true,
        .free = true,
        .realloc = true,
        .calloc = true,
    }).run();

    // TODO: use this once we get inferred struct initializers -- https://github.com/ziglang/zig/issues/685
    // zee_alloc.ExportC.run(.{
    //     .allocator = zee_alloc.ZeeAllocDefaults.wasm_allocator,
    //     .malloc = true,
    //     .free = true,
    //     .realloc = true,
    //     .calloc = true,
    // });
}
