const std = @import("std");
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const FreeNode = struct {
    data: ?[]u8,

    pub fn empty() @This() {
        return FreeNode{ .data = []u8{} };
    }
};

const ZeeAlloc = struct {
    pub allocator: Allocator,

    backing_allocator: *Allocator,
    free_nodes: [16]FreeNode,
    page_size: usize,

    pub fn init(backing_allocator: *Allocator, page_size: usize) ZeeAlloc {
        return ZeeAlloc{
            .allocator = Allocator{
                .reallocFn = realloc,
                .shrinkFn = shrink,
            },
            .backing_allocator = backing_allocator,
            .free_nodes = []FreeNode{FreeNode.empty()} ** 16,
            .page_size = page_size,
        };
    }

    fn allocSmall(self: *ZeeAlloc, bitsize: usize) ![]u8 {
        var free_node = self.free_nodes[bitsize];
        if (free_node.data) |data| {
            return data;
        }

        const chunk = try self.alloc(bitsize + 1);
        const memsize = chunk.len / 2;
        free_node.data = chunk[memsize..];
        return chunk[0..memsize];
    }

    fn allocLarge(self: *ZeeAlloc, memsize: usize) ![]u8 {
        return self.backing_allocator.alloc(u8, memsize);
    }

    fn alloc(self: *ZeeAlloc, memsize: usize) Error![]u8 {
        if (memsize < self.page_size) {
            const bitsize = 4;
            //const bitsize = std.math.log2(memsize);
            return self.allocSmall(bitsize);
        } else {
            return self.allocLarge(memsize);
        }
    }

    fn free(self: *ZeeAlloc, old_mem: []u8) []u8 {
        return old_mem;
    }

    fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Error![]u8 {
        if (new_size <= old_mem.len and new_align <= new_size) {
            // TODO: maybe intelligently shrink?
            // We can't do anything with the memory, so tell the client to keep it.
            return error.OutOfMemory;
        } else {
            const self = @fieldParentPtr(ZeeAlloc, "allocator", allocator);
            const result = try self.alloc(new_size + new_align);
            //@memcpy(result.ptr, old_mem.ptr, std.math.min(old_mem.len, result.len));
            _ = self.free(old_mem);
            return result;
        }
    }

    fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
        if (new_size == 0) {
            const self = @fieldParentPtr(ZeeAlloc, "allocator", allocator);
            return self.free(old_mem);
        } else {
            // TODO: maybe intelligently shrink?
            return old_mem[0..new_size];
        }
    }
};

const wasm_allocator = &ZeeAlloc.init(std.heap.wasm_allocator, std.os.page_size).allocator;

export fn foo() i64 {
    const bar = wasm_allocator.create(i64) catch {
        return -1;
    };
    return bar.*;
}
