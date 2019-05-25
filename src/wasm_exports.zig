const builtin = @import("builtin");
const zee_alloc = @import("main.zig");

export fn malloc(size: usize) ?[*]u8 {
    var result = zee_alloc.wasm_allocator.alloc(u8, size) catch {
        return null;
    };
    return result.ptr;
}

export fn free(ptr: [*]u8) void {
    // TODO: can't free without metadata
    zee_alloc.wasm_allocator.free(ptr[0..4]); // Make something up to prevent "unreachable" optimization
}
