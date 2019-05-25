const std = @import("std");
const builtin = @import("builtin");
const linked_list = @import("linked_list.zig");
const Allocator = std.mem.Allocator;

const FreeList = linked_list.SinglyLinkedList([]u8);

const large_index = 0;
const page_index = 1;

pub const ZeeAllocDefaults = ZeeAlloc(std.os.page_size, 4);

fn invBitsize(ref: usize, target: usize) usize {
    return std.math.log2_int_ceil(usize, ref) - std.math.log2_int_ceil(usize, target);
}

// https://github.com/ziglang/zig/issues/2426
fn ceilPowerOfTwo(comptime T: type, value: T) T {
    if (value <= 2) return value;
    const Shift = comptime std.math.Log2Int(T);
    return T(1) << @intCast(Shift, T.bit_count - @clz(value - 1));
}

fn ceilToMultiple(comptime target: comptime_int, value: usize) usize {
    const remainder = value % target;
    return value + (target - remainder) % target;
}

pub fn ZeeAlloc(comptime page_size: usize, comptime min_block_size: usize) type {
    const size_buckets = invBitsize(page_size, min_block_size) + 2; // large + page = 2 additional slots

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
                std.debug.assert(buffer.len > 0);
                for (buffer) |*node| {
                    self.unused_nodes.prepend(node);
                }
            }
            return self.unused_nodes.popFirst() orelse unreachable;
        }

        fn allocBlock(self: *Self, memsize: usize) ![]u8 {
            var block_size = self.padToBlockSize(memsize);

            while (true) : (block_size *= 2) {
                var i = self.freeListIndex(block_size);
                var iter = self.free_lists[i].first;
                while (iter) |node| : (iter = node.next) {
                    if (node.data.len == block_size) {
                        // TODO: optimize using back ref
                        self.free_lists[i].remove(node);
                        self.unused_nodes.prepend(node);
                        return node.data;
                    }
                }

                if (i <= page_index) {
                    return self.backing_allocator.alloc(u8, block_size);
                }
            }
        }

        fn extractFromBlock(self: *Self, block: []u8, memsize: usize) ![]u8 {
            std.debug.assert(memsize <= block.len);

            const target_block_size = self.padToBlockSize(memsize);

            var sub_block = block;
            var sub_block_size = std.math.min(block.len / 2, page_size);
            while (sub_block_size >= target_block_size) : (sub_block_size /= 2) {
                const node = try self.consumeUnusedNode();

                var i = self.freeListIndex(sub_block_size);
                node.data = sub_block[sub_block_size..];
                self.free_lists[i].prepend(node);
                sub_block = sub_block[0..sub_block_size];
            }
            return sub_block[0..memsize];
        }

        fn free(self: *Self, old_mem: []u8) []u8 {
            if (old_mem.len != 0) {
                const block_size = self.padToBlockSize(old_mem.len);
                const i = self.freeListIndex(block_size);
                const node = self.consumeUnusedNode() catch self.consumeLessImportantNode(std.math.max(i, page_index));
                if (node) |aNode| {
                    // Need to bump this back to the fixed block
                    // We're not storing this metadata; let's hope we did everything right!
                    aNode.data = old_mem.ptr[0..block_size];
                    self.free_lists[i].prepend(aNode);
                }
            }

            return old_mem[0..0];
        }

        fn padToBlockSize(self: *Self, memsize: usize) usize {
            if (memsize <= min_block_size) {
                return min_block_size;
            } else if (memsize <= self.page_size) {
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
                return invBitsize(page_size, memsize) + page_index;
            }
        }

        fn consumeLessImportantNode(self: *Self, target_index: usize) ?*FreeList.Node {
            var i = self.free_lists.len - 1;
            while (i > target_index) : (i -= 1) {
                if (self.free_lists[i].popFirst()) |node| {
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

        fn debugCount(self: *Self, free_list: FreeList) usize {
            var count = usize(0);
            var iter = free_list.first;
            while (iter) |node| : (iter = node.next) {
                count += 1;
            }
            return count;
        }

        fn debugCountUnused(self: *Self) usize {
            return self.debugCount(self.unused_nodes);
        }

        fn debugCountAll(self: *Self) usize {
            var count = self.debugCountUnused();
            for (self.free_lists) |list| {
                count += self.debugCount(list);
            }
            return count;
        }

        fn debugDump(self: *Self) void {
            std.debug.warn("unused: {}\n", self.debugCount(self.unused_nodes));
            for (self.free_lists) |list, i| {
                std.debug.warn("{}: {}\n", i, self.debugCount(list));
            }
        }
    };
}

// https://github.com/ziglang/zig/issues/2291
extern fn @"llvm.wasm.memory.size.i32"(u32) u32;
extern fn @"llvm.wasm.memory.grow.i32"(u32, u32) i32;
comptime {
    if (builtin.arch == .wasm32) {
        @export("malloc", wasm_malloc, .Strong);
        @export("free", wasm_free, .Strong);
    }
}

extern fn wasm_malloc(size: usize) ?[*]u8 {
    var result = wasm_allocator.alloc(u8, size) catch {
        return null;
    };
    return @ptrCast([*]u8, &result[0]);
}

extern fn wasm_free(ptr: [*]u8) void {
    // TODO: can't free without metadata
    wasm_allocator.free(ptr[0..4]); // Make something up to prevent "unreachable" optimization
}

pub const wasm_allocator = init: {
    if (builtin.arch != .wasm32) {
        @compileError("WasmAllocator is only available for wasm32 arch");
    }

    // std.heap.wasm_allocator is designed for arbitrary sizing
    // We only need page sizing, and this lets us stay super small
    const WasmPageAllocator = struct {
        const Self = @This();

        start_ptr: [*]u8,
        mem_tail: usize,
        allocator: Allocator,

        fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
            if (old_mem.len > 0) {
                unreachable; // Shouldn't be actually reallocating
            } else if (new_size % std.os.page_size != 0) {
                unreachable; // Should only be allocating page size chunks
            } else {
                // TODO: assert alignment
            }

            const self = @fieldParentPtr(Self, "allocator", allocator);
            if (self.mem_tail == 0) {
                self.start_ptr = @intToPtr([*]u8, @intCast(usize, @"llvm.wasm.memory.size.i32"(0)) * std.os.page_size);
            }

            const requested_page_count = @intCast(u32, new_size / std.os.page_size);
            const prev_page_count = @"llvm.wasm.memory.grow.i32"(0, requested_page_count);
            if (prev_page_count < 0) {
                return error.OutOfMemory;
            }

            var result = self.start_ptr[self.mem_tail..(self.mem_tail + new_size)];
            self.mem_tail += new_size;
            return result;
        }

        fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
            unreachable; // Shouldn't be shrinking / freeing
        }

        pub fn init() Self {
            return Self{
                .start_ptr = undefined,
                .mem_tail = 0,

                .allocator = Allocator{
                    .reallocFn = realloc,
                    .shrinkFn = shrink,
                },
            };
        }
    };

    var wasm_page_allocator = WasmPageAllocator.init();
    var zee_allocator = ZeeAllocDefaults.init(&wasm_page_allocator.allocator);
    break :init &zee_allocator.allocator;
};

// Tests

const testing = std.testing;

test "ZeeAlloc helpers" {
    var buf: [0]u8 = undefined;
    var allocator = &std.heap.FixedBufferAllocator.init(buf[0..]).allocator;
    var zee_alloc = ZeeAllocDefaults.init(allocator);

    @"freeListIndex": {
        testing.expectEqual(usize(page_index), zee_alloc.freeListIndex(zee_alloc.page_size));
        testing.expectEqual(usize(large_index), zee_alloc.freeListIndex(zee_alloc.page_size + 1));
        testing.expectEqual(usize(page_index + 1), zee_alloc.freeListIndex(zee_alloc.page_size / 2));
        testing.expectEqual(usize(page_index + 2), zee_alloc.freeListIndex(zee_alloc.page_size / 4));
    }

    @"padToBlockSize": {
        testing.expectEqual(usize(zee_alloc.page_size), zee_alloc.padToBlockSize(zee_alloc.page_size));
        testing.expectEqual(usize(2 * zee_alloc.page_size), zee_alloc.padToBlockSize(zee_alloc.page_size + 1));
        testing.expectEqual(usize(3 * zee_alloc.page_size), zee_alloc.padToBlockSize(2 * zee_alloc.page_size + 1));
    }
}

test "ZeeAlloc internals" {
    var buf: [1000000]u8 = undefined;
    var allocator = &std.heap.FixedBufferAllocator.init(buf[0..]).allocator;
    var zee_alloc = ZeeAllocDefaults.init(allocator);

    testing.expectEqual(zee_alloc.debugCountAll(), 0);

    @"node count makes sense": {
        var mem = zee_alloc.allocator.create(u8);
        const total_nodes = zee_alloc.debugCountAll();
        testing.expect(total_nodes > 0);
        testing.expect(zee_alloc.debugCountUnused() > 0);
        testing.expect(zee_alloc.debugCountUnused() < total_nodes);

        var mem2 = zee_alloc.allocator.create(u8);
        testing.expectEqual(total_nodes, zee_alloc.debugCountAll());
    }
}

// -- functional tests from std/heap.zig

fn testAllocator(allocator: *std.mem.Allocator) !void {
    var slice = try allocator.alloc(*i32, 100);
    testing.expectEqual(slice.len, 100);
    for (slice) |*item, i| {
        item.* = try allocator.create(i32);
        item.*.* = @intCast(i32, i);
    }

    slice = try allocator.realloc(slice, 20000);
    testing.expectEqual(slice.len, 20000);

    for (slice[0..100]) |item, i| {
        testing.expectEqual(item.*, @intCast(i32, i));
        allocator.destroy(item);
    }

    slice = allocator.shrink(slice, 50);
    testing.expectEqual(slice.len, 50);
    slice = allocator.shrink(slice, 25);
    testing.expectEqual(slice.len, 25);
    slice = allocator.shrink(slice, 0);
    testing.expectEqual(slice.len, 0);
    slice = try allocator.realloc(slice, 10);
    testing.expectEqual(slice.len, 10);

    allocator.free(slice);
}

test "ZeeAlloc with FixedBufferAllocator" {
    var buf: [1000000]u8 = undefined;
    var allocator = &std.heap.FixedBufferAllocator.init(buf[0..]).allocator;
    var zee_alloc = ZeeAllocDefaults.init(allocator);

    try testAllocator(&zee_alloc.allocator);
}
