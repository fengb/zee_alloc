const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const FreeList = std.LinkedList([]u8);

export const default_min_size = @typeInfo(usize).Int.bits;

export const wasm_allocator = &ZeeAlloc.init(std.heap.wasm_allocator, std.os.page_size, default_min_size).allocator;

const ZeeAlloc = struct {
    pub allocator: Allocator,

    backing_allocator: *Allocator,
    page_size: usize,

    free_smalls: []FreeList,
    free_large: FreeList,
    unused_nodes: FreeList,

    pub fn init(backing_allocator: *Allocator, comptime page_size: usize, comptime min_size: usize) @This() {
        const total_lists = std.math.log2_int_ceil(usize, page_size) - std.math.log2_int_ceil(usize, min_size);
        var free_smalls = []FreeList{FreeList.init()} ** total_lists;

        return ZeeAlloc{
            .allocator = Allocator{
                .reallocFn = realloc,
                .shrinkFn = shrink,
            },
            .backing_allocator = backing_allocator,
            .page_size = page_size,

            .free_smalls = free_smalls[0..],
            .free_large = FreeList.init(),
            .unused_nodes = FreeList.init(),
        };
    }

    fn replenishUnused(self: *ZeeAlloc) !void {
        var buffer = try self.backing_allocator.alloc(FreeList.Node, self.page_size / @sizeOf(FreeList.Node));
        for (buffer) |*node| {
            self.unused_nodes.append(node);
        }
    }

    fn allocSmall(self: *ZeeAlloc, inv_bitsize: usize) Allocator.Error![]u8 {
        var free_list = self.free_smalls[inv_bitsize];
        if (free_list.pop()) |node| {
            self.unused_nodes.append(node);
            return node.data;
        }

        if (inv_bitsize == 0) {
            return self.backing_allocator.alloc(u8, self.page_size);
        }

        if (self.unused_nodes.first == null) {
            try self.replenishUnused();
        }

        const chunk = try self.allocSmall(inv_bitsize - 1);
        const memsize = chunk.len / 2;

        if (self.unused_nodes.pop()) |free_node| {
            free_node.data = chunk[memsize..];
            free_list.append(free_node);
        } else {
            std.debug.assert(false); // Not sure how we got here... replenishUnused() didn't get enough?
        }
        return chunk[0..memsize];
    }

    fn allocLarge(self: *ZeeAlloc, memsize: usize) ![]u8 {
        var it = self.free_large.first;
        while (it) |node| : (it = node.next) {
            if (node.data.len == memsize) {
                self.free_large.remove(node);
                self.unused_nodes.append(node);
                return node.data;
            }
        }
        return self.backing_allocator.alloc(u8, memsize);
    }

    fn alloc(self: *ZeeAlloc, memsize: usize) ![]u8 {
        if (memsize <= self.page_size) {
            const inv_bitsize = std.math.log2_int_ceil(usize, self.page_size) - std.math.log2_int_ceil(usize, memsize);
            return try self.allocSmall(std.math.min(inv_bitsize, self.free_smalls.len - 1));
        } else {
            return self.allocLarge(memsize);
        }
    }

    fn free(self: *ZeeAlloc, old_mem: []u8) []u8 {
        if (self.unused_nodes.first == null) {
            self.replenishUnused() catch {
                // Can't allocate to process freed memory. Leak!
                return old_mem;
            };
        }

        if (old_mem.len <= self.page_size) {
            return self.freeSmall(old_mem);
        } else {
            return self.freeLarge(old_mem);
        }
    }

    fn freeSmall(self: *ZeeAlloc, old_mem: []u8) []u8 {
        const inv_bitsize = std.math.log2_int_ceil(usize, self.page_size) - std.math.log2_int_ceil(usize, old_mem.len);
        var free_list = self.free_smalls[inv_bitsize];
        if (self.unused_nodes.pop()) |node| {
            node.data = old_mem;
            free_list.append(node);
            return []u8{};
        } else {
            std.debug.assert(false); // Not sure how we got here...
            return old_mem;
        }
    }

    fn freeLarge(self: *ZeeAlloc, old_mem: []u8) []u8 {
        if (self.unused_nodes.pop()) |node| {
            node.data = old_mem;
            self.free_large.append(node);
            return []u8{};
        } else {
            std.debug.assert(false); // Not sure how we got here...
            return old_mem;
        }
    }

    fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
        if (new_size <= old_mem.len and new_align <= new_size) {
            // TODO: maybe intelligently shrink?
            // We can't do anything with the memory, so tell the client to keep it.
            return error.OutOfMemory;
        } else {
            const self = @fieldParentPtr(ZeeAlloc, "allocator", allocator);
            const result = try self.alloc(new_size + new_align);
            std.mem.copy(u8, result, old_mem);
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

// -- tests from std/heap.zig

fn testAllocator(allocator: *std.mem.Allocator) !void {
    var slice = try allocator.alloc(*i32, 100);
    testing.expect(slice.len == 100);
    for (slice) |*item, i| {
        item.* = try allocator.create(i32);
        item.*.* = @intCast(i32, i);
    }

    slice = try allocator.realloc(slice, 20000);
    testing.expect(slice.len == 20000);

    for (slice[0..100]) |item, i| {
        testing.expect(item.* == @intCast(i32, i));
        allocator.destroy(item);
    }

    slice = allocator.shrink(slice, 50);
    testing.expect(slice.len == 50);
    slice = allocator.shrink(slice, 25);
    testing.expect(slice.len == 25);
    slice = allocator.shrink(slice, 0);
    testing.expect(slice.len == 0);
    slice = try allocator.realloc(slice, 10);
    testing.expect(slice.len == 10);

    allocator.free(slice);
}

test "DirectAllocator" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var zee_alloc = ZeeAlloc.init(&direct_allocator.allocator, std.os.page_size, default_min_size);
    try testAllocator(&zee_alloc.allocator);
}
