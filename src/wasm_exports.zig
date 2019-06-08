const builtin = @import("builtin");
const zee_alloc = @import("main.zig");

export fn malloc(size: usize) ?*c_void {
    const result = zee_alloc.wasm_allocator.alloc(u8, size) catch return null;
    return result.ptr;
}

export fn realloc(c_ptr: *c_void, new_size: usize) ?*c_void {
    // Use a synthetic slice
    const ptr = @ptrCast([*]u8, c_ptr);
    // Optimize: find frame size instead of assuming 1 and always resizing
    const result = zee_alloc.wasm_allocator.realloc(ptr[0..1], new_size) catch return null;
    return result.ptr;
}

export fn free(c_ptr: *c_void) void {
    // Use a synthetic slice. zee_alloc will free via corresponding metadata.
    const ptr = @ptrCast([*]u8, c_ptr);
    zee_alloc.wasm_allocator.free(ptr[0..1]);
}
