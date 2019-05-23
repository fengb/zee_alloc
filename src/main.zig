const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const FreeList = std.LinkedList([]u8);

// export const wasm_allocator = &ZeeAllocDefaults.init(std.heap.wasm_allocator).allocator;
export const fake_allocator = &ZeeAllocDefaults.init(&NoopAllocator).allocator;

fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
    return old_mem;
}
fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
    return old_mem;
}
var NoopAllocator = Allocator{
    .reallocFn = realloc,
    .shrinkFn = shrink,
};

const large_index = 0;
const page_index = 1;

pub const ZeeAllocDefaults = ZeeAlloc(std.os.page_size, @typeInfo(usize).Int.bits);

fn invBitsize(ref: usize, target: usize) usize {
    return std.math.log2_int_ceil(usize, ref) - std.math.log2_int_ceil(usize, target);
}

fn ceilPowerOfTwo(comptime T: type, value: T) T {
    const transformed = std.math.floorPowerOfTwo(T, value);
    if (transformed == value) {
        return transformed;
    } else {
        return transformed * 2;
    }
}

fn ceilToMultiple(comptime target: comptime_int, value: usize) usize {
    return value + (value + target - 1) % target;
}

pub fn ZeeAlloc(comptime page_size: usize, comptime min_block_size: usize) type {
    const size_buckets = invBitsize(page_size * 2, min_block_size);

    return struct {
        const Self = @This();

        pub allocator: Allocator,

        backing_allocator: *Allocator,
        page_size: usize,

        free_lists: [size_buckets]FreeList,
        unused_nodes: FreeList,

        pub fn init(backing_allocator: *Allocator) @This() {
            return Self{
                .allocator = Allocator{
                    .reallocFn = realloc,
                    .shrinkFn = shrink,
                },
                .backing_allocator = backing_allocator,
                .page_size = page_size,

                .free_lists = []FreeList{FreeList.init()} ** size_buckets,
                .unused_nodes = FreeList.init(),
            };
        }

        fn consumeUnusedNode(self: *Self) !*FreeList.Node {
            if (self.unused_nodes.first == null) {
                var buffer = try self.backing_allocator.alloc(FreeList.Node, self.page_size / @sizeOf(FreeList.Node));
                for (buffer) |*node| {
                    self.unused_nodes.append(node);
                }
            }
            return self.unused_nodes.pop() orelse error.OutOfMemory;
        }

        fn allocBlock(self: *Self, memsize: usize) Allocator.Error![]u8 {
            var block_size = self.padToBlockSize(memsize);

            while (true) : (block_size *= 2) {
                var i = self.freeListIndex(block_size);
                var free_list = self.free_lists[i];
                var it = free_list.first;
                while (it) |node| : (it = node.next) {
                    if (node.data.len == block_size) {
                        free_list.remove(node);
                        self.unused_nodes.append(node);
                        return node.data;
                    }
                }

                if (i <= page_size) {
                    break;
                }
            }

            return self.backing_allocator.alloc(u8, block_size);
        }

        fn extractFromBlock(self: *Self, block: []u8, memsize: usize) ![]u8 {
            std.debug.assert(memsize <= block.len);

            const target_block_size = self.padToBlockSize(memsize);

            var sub_block = block;
            var sub_block_size = std.math.max(block.len / 2, page_index);
            while (sub_block_size > target_block_size) : (sub_block_size /= 2) {
                const node = try self.consumeUnusedNode();

                var i = self.freeListIndex(sub_block_size);
                node.data = sub_block[sub_block_size..];
                self.free_lists[i].append(node);
                sub_block = sub_block[0..sub_block_size];
            }
            return sub_block[0..memsize];
        }

        fn free(self: *Self, old_mem: []u8) []u8 {
            const block_size = self.padToBlockSize(old_mem.len);
            const i = self.freeListIndex(block_size);
            const node = self.consumeUnusedNode() catch self.findLessImportantNode(std.math.max(i, page_index));
            if (node) |aNode| {
                // Need to bump this back to the fixed block
                // We're not storing this metadata; let's hope we did everything right!
                aNode.data = old_mem.ptr[0..block_size];
                self.free_lists[i].append(aNode);
            }

            return old_mem[0..0];
        }

        fn padToBlockSize(self: *Self, memsize: usize) usize {
            if (memsize <= self.page_size) {
                return ceilPowerOfTwo(usize, memsize);
            } else {
                return ceilToMultiple(page_size, memsize);
            }
        }

        fn freeListIndex(self: *Self, memsize: usize) usize {
            if (memsize > self.page_size) {
                return 0;
            } else if (memsize <= min_block_size) {
                return self.free_lists.len - 1;
            } else {
                return invBitsize(page_size * 2, memsize);
            }
        }

        fn findLessImportantNode(self: *Self, target_index: usize) ?*FreeList.Node {
            var i = self.free_lists.len - 1;
            while (i > target_index) : (i -= 1) {
                if (self.free_lists[i].pop()) |node| {
                    //std.debug.warn("ZeeAlloc: using free_lists[{}]\n", i);
                    return node;
                }
            }

            return null;
        }

        fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
            if (new_size <= old_mem.len and new_align <= new_size) {
                return shrink(allocator, old_mem, old_align, new_size, new_align);
            } else {
                const self = @fieldParentPtr(Self, "allocator", allocator);
                const block = try self.allocBlock(new_size);
                const result = try self.extractFromBlock(block, new_size);
                std.mem.copy(u8, result, old_mem);
                _ = self.free(old_mem);
                return result[0..new_size];
            }
        }

        fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            if (new_size == 0) {
                return self.free(old_mem);
            } else {
                return self.extractFromBlock(old_mem, new_size) catch |err| switch (err) {
                    // TODO: memory leak
                    error.OutOfMemory => old_mem[0..new_size],
                };
            }
        }
    };
}

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

test "ZeeAlloc with FixedBufferAllocator" {
    var buf: [1000000]u8 = undefined;
    var allocator = &std.heap.FixedBufferAllocator.init(buf[0..]).allocator;

    var zee_alloc = ZeeAllocDefaults.init(allocator);
    try testAllocator(&zee_alloc.allocator);
}
