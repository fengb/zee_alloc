const builtin = @import("builtin");
const zee_alloc = @import("intrusive.zig");

export fn malloc(size: usize) ?[*]u8 {
    var result = zee_alloc.wasm_allocator.alloc(u8, size) catch return null;
    return result.ptr;
}

export fn free(ptr: [*]u8) void {
    // Use a synthetic slice. zee_alloc should free via metadata.
    zee_alloc.wasm_allocator.free(ptr[0..1]);
}
