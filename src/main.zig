const std = @import("std");
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const FreeList = std.LinkedList([]u8);

pub const total_lists = 16;

const ZeeAlloc = struct {
    pub allocator: Allocator,

    backing_allocator: *Allocator,
    page_size: usize,

    unused_nodes: FreeList,
    free_lists: []FreeList,

    pub fn init(backing_allocator: *Allocator, page_size: usize) @This() {
        var free_lists = []FreeList{FreeList.init()} ** total_lists;

        return ZeeAlloc{
            .allocator = Allocator{
                .reallocFn = realloc,
                .shrinkFn = shrink,
            },
            .backing_allocator = backing_allocator,
            .page_size = page_size,

            .unused_nodes = FreeList.init(),
            .free_lists = free_lists[0..],
        };
    }

    fn replenishFree(self: *ZeeAlloc) !void {
        var buffer = try self.backing_allocator.alloc(FreeList.Node, @sizeOf(FreeList) / self.page_size);
        for (buffer) |*node| {
            self.unused_nodes.append(node);
        }
    }

    fn allocSmall(self: *ZeeAlloc, inv_bitsize: usize) Error![]u8 {
        var free_list = self.free_lists[inv_bitsize];
        if (free_list.pop()) |node| {
            return node.data;
        }

        if (inv_bitsize == 0) {
            return self.backing_allocator.alloc(u8, self.page_size);
        }

        if (self.unused_nodes.first == null) {
            try self.replenishFree();
        }

        const chunk = try self.allocSmall(inv_bitsize - 1);
        const memsize = chunk.len / 2;

        if (self.unused_nodes.pop()) |free_node| {
            free_node.data = chunk[memsize..];
            free_list.append(free_node);
        } else {
            std.debug.assert(false); // Not sure how we got here... replenishFree() didn't get enough?
        }
        return chunk[0..memsize];
    }

    fn allocLarge(self: *ZeeAlloc, memsize: usize) ![]u8 {
        return self.backing_allocator.alloc(u8, memsize);
    }

    fn alloc(self: *ZeeAlloc, memsize: usize) ![]u8 {
        if (memsize < self.page_size) {
            const inv_bitsize = std.math.log2(self.page_size / memsize);
            return self.allocSmall(std.math.min(inv_bitsize, total_lists - 1));
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
            @memcpy(result.ptr, old_mem.ptr, std.math.min(old_mem.len, result.len));
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
