const std = @import("std");
const builtin = @import("builtin");
const linked_list = @import("linked_list.zig");
const Allocator = std.mem.Allocator;

const FreeList = linked_list.SinglyLinkedList([]u8);

const oversized_index = 0;
const page_index = 1;

pub const ZeeAllocDefaults = ZeeAlloc(std.os.page_size, 4);

// https://github.com/ziglang/zig/issues/2426
fn ceilPowerOfTwo(comptime T: type, value: T) T {
    if (value <= 2) return value;
    const Shift = comptime std.math.Log2Int(T);
    return T(1) << @intCast(Shift, T.bit_count - @clz(T, value - 1));
}

fn ceilToMultiple(comptime target: comptime_int, value: usize) usize {
    const remainder = value % target;
    return value + (target - remainder) % target;
}

fn isAligned(addr: usize, alignment: u29) bool {
    const mask = alignment - 1;
    return mask & addr == 0;
}

pub fn ZeeAlloc(comptime page_size: usize, comptime min_block_size: usize) type {
    const inv_bitsize_ref = page_index + std.math.log2_int(usize, page_size);
    const size_buckets = inv_bitsize_ref - std.math.log2_int(usize, min_block_size) + 1; // + 1 oversized list

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
                var bytes = try self.backing_allocator.alignedAlloc(u8, page_size, self.page_size);
                const node_memsize = bytes.len - (bytes.len % @sizeOf(FreeList.Node));

                // Small leak due to misalignment. Can't do anything about it...
                bytes = bytes[0..node_memsize];
                const buffer = @bytesToSlice(FreeList.Node, bytes);

                std.debug.assert(buffer.len > 0);
                for (buffer) |*node| {
                    self.unused_nodes.prepend(node);
                }
            }
            return self.unused_nodes.popFirst() orelse unreachable;
        }

        fn allocBlock(self: *Self, memsize: usize, alignment: u29) ![]u8 {
            var block_size = self.padToBlockSize(memsize);

            while (true) : (block_size *= 2) {
                var i = self.freeListIndex(block_size);

                var prev: ?*FreeList.Node = null;
                var iter = self.free_lists[i].first;
                while (iter) |node| : ({
                    prev = iter;
                    iter = node.next;
                }) {
                    if (node.data.len == block_size and isAligned(@ptrToInt(node.data.ptr), alignment)) {
                        if (prev != null) {
                            const removed = prev.?.removeNext();
                            std.debug.assert(removed == node);
                        } else {
                            const popped = self.free_lists[i].popFirst();
                            std.debug.assert(popped == node);
                        }
                        self.unused_nodes.prepend(node);
                        return node.data;
                    }
                }

                if (i <= page_index) {
                    return try self.backing_allocator.alignedAlloc(u8, page_size, block_size);
                }
            }
        }

        fn realignToBlock(self: *Self, mem: []u8) []u8 {
            // Need to expand this back to the allocated block
            // We're not storing this metadata; let's hope we did everything right!
            var block_size = self.padToBlockSize(mem.len);
            return mem.ptr[0..block_size];
        }

        fn extractFromBlock(self: *Self, block: []u8, memsize: usize) ![]u8 {
            std.debug.assert(block.len == self.padToBlockSize(block.len));
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
                    aNode.data = self.realignToBlock(old_mem);
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

        fn freeListIndex(self: *Self, block_size: usize) usize {
            std.debug.assert(block_size == self.padToBlockSize(block_size));
            if (block_size > self.page_size) {
                return oversized_index;
            } else if (block_size <= min_block_size) {
                return self.free_lists.len - 1;
            } else {
                return inv_bitsize_ref - std.math.log2_int(usize, block_size);
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
            if (new_align > page_size) {
                return error.OutOfMemory;
            } else if (new_size <= old_mem.len and new_align <= new_size) {
                return shrink(allocator, old_mem, old_align, new_size, new_align);
            } else {
                const self = @fieldParentPtr(Self, "allocator", allocator);

                const block = try self.allocBlock(new_size, new_align);
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
            } else if (old_mem.len <= self.padToBlockSize(new_size)) {
                return old_mem[0..new_size];
            } else {
                return self.extractFromBlock(self.realignToBlock(old_mem), new_size) catch |err| switch (err) {
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
            std.debug.assert(old_mem.len == 0); // Shouldn't be actually reallocating
            std.debug.assert(new_size % std.os.page_size == 0); // Should only be allocating page size chunks
            std.debug.assert(new_align == std.os.page_size); // Should only align to page_size

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
        testing.expectEqual(usize(page_index + 1), zee_alloc.freeListIndex(zee_alloc.page_size / 2));
        testing.expectEqual(usize(page_index + 2), zee_alloc.freeListIndex(zee_alloc.page_size / 4));
    }

    @"padToBlockSize": {
        testing.expectEqual(usize(zee_alloc.page_size), zee_alloc.padToBlockSize(zee_alloc.page_size));
        testing.expectEqual(usize(2 * zee_alloc.page_size), zee_alloc.padToBlockSize(zee_alloc.page_size + 1));
        testing.expectEqual(usize(2 * zee_alloc.page_size), zee_alloc.padToBlockSize(2 * zee_alloc.page_size));
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

fn testAllocatorAligned(allocator: *Allocator, comptime alignment: u29) !void {
    // initial
    var slice = try allocator.alignedAlloc(u8, alignment, 10);
    testing.expectEqual(slice.len, 10);
    // grow
    slice = try allocator.realloc(slice, 100);
    testing.expectEqual(slice.len, 100);
    // shrink
    slice = allocator.shrink(slice, 10);
    testing.expectEqual(slice.len, 10);
    // go to zero
    slice = allocator.shrink(slice, 0);
    testing.expectEqual(slice.len, 0);
    // realloc from zero
    slice = try allocator.realloc(slice, 100);
    testing.expectEqual(slice.len, 100);
    // shrink with shrink
    slice = allocator.shrink(slice, 10);
    testing.expectEqual(slice.len, 10);
    // shrink to zero
    slice = allocator.shrink(slice, 0);
    testing.expectEqual(slice.len, 0);
}

fn testAllocatorLargeAlignment(allocator: *Allocator) Allocator.Error!void {
    //Maybe a platform's page_size is actually the same as or
    //  very near usize?

    // TODO: support ultra wide alignment (bigger than page_size)
    //if (std.os.page_size << 2 > std.math.maxInt(usize)) return;

    //const USizeShift = @IntType(false, std.math.log2(usize.bit_count));
    //const large_align = u29(std.os.page_size << 2);
    const USizeShift = @IntType(false, std.math.log2(usize.bit_count));
    const large_align = u29(std.os.page_size);

    var align_mask: usize = undefined;
    _ = @shlWithOverflow(usize, ~usize(0), USizeShift(@ctz(usize, large_align)), &align_mask);

    var slice = try allocator.alignedAlloc(u8, large_align, 500);
    testing.expectEqual(@ptrToInt(slice.ptr) & align_mask, @ptrToInt(slice.ptr));

    slice = allocator.shrink(slice, 100);
    testing.expectEqual(@ptrToInt(slice.ptr) & align_mask, @ptrToInt(slice.ptr));

    slice = try allocator.realloc(slice, 5000);
    testing.expectEqual(@ptrToInt(slice.ptr) & align_mask, @ptrToInt(slice.ptr));

    slice = allocator.shrink(slice, 10);
    testing.expectEqual(@ptrToInt(slice.ptr) & align_mask, @ptrToInt(slice.ptr));

    slice = try allocator.realloc(slice, 20000);
    testing.expectEqual(@ptrToInt(slice.ptr) & align_mask, @ptrToInt(slice.ptr));

    allocator.free(slice);
}

fn testAllocatorAlignedShrink(allocator: *Allocator) Allocator.Error!void {
    var debug_buffer: [1000]u8 = undefined;
    const debug_allocator = &std.heap.FixedBufferAllocator.init(&debug_buffer).allocator;

    const alloc_size = std.os.page_size * 2 + 50;
    var slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    defer allocator.free(slice);

    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    // On Windows, VirtualAlloc returns addresses aligned to a 64K boundary,
    // which is 16 pages, hence the 32. This test may require to increase
    // the size of the allocations feeding the `allocator` parameter if they
    // fail, because of this high over-alignment we want to have.
    while (@ptrToInt(slice.ptr) == std.mem.alignForward(@ptrToInt(slice.ptr), std.os.page_size * 32)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[60] = 0x34;

    // realloc to a smaller size but with a larger alignment
    slice = try allocator.alignedRealloc(slice, std.os.page_size, alloc_size / 2);
    testing.expectEqual(slice[0], 0x12);
    testing.expectEqual(slice[60], 0x34);
}

test "ZeeAlloc with DirectAllocator" {
    var direct_allocator = std.heap.DirectAllocator.init();
    defer direct_allocator.deinit();

    var zee_alloc = ZeeAllocDefaults.init(&direct_allocator.allocator);

    try testAllocator(&zee_alloc.allocator);
    try testAllocatorAligned(&zee_alloc.allocator, 16);
    try testAllocatorLargeAlignment(&zee_alloc.allocator);
    try testAllocatorAlignedShrink(&zee_alloc.allocator);
}

test "ZeeAlloc with FixedBufferAllocator" {
    var buf: [1000000]u8 = undefined;
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buf[0..]);
    var zee_alloc = ZeeAllocDefaults.init(&fixed_buffer_allocator.allocator);

    try testAllocator(&zee_alloc.allocator);
    try testAllocatorAligned(&zee_alloc.allocator, 16);
    try testAllocatorLargeAlignment(&zee_alloc.allocator);
    try testAllocatorAlignedShrink(&zee_alloc.allocator);
}

const bench = @import("bench.zig");
var test_buf: [1024 * 1024]u8 = undefined;
test "gc.benchmark" {
    try bench.benchmark(struct {
        const Arg = struct {
            num: usize,
            size: usize,

            fn benchAllocator(a: Arg, allocator: *Allocator, comptime free: bool) !void {
                var i: usize = 0;
                while (i < a.num) : (i += 1) {
                    const bytes = try allocator.alloc(u8, a.size);
                    defer if (free) allocator.free(bytes);
                }
            }
        };

        pub const args = []Arg{
            Arg{ .num = 10 * 1, .size = 1024 * 1 },
            Arg{ .num = 10 * 2, .size = 1024 * 1 },
            Arg{ .num = 10 * 4, .size = 1024 * 1 },
            Arg{ .num = 10 * 1, .size = 1024 * 2 },
            Arg{ .num = 10 * 2, .size = 1024 * 2 },
            Arg{ .num = 10 * 4, .size = 1024 * 2 },
            Arg{ .num = 10 * 1, .size = 1024 * 4 },
            Arg{ .num = 10 * 2, .size = 1024 * 4 },
            Arg{ .num = 10 * 4, .size = 1024 * 4 },
        };

        pub const iterations = 10000;

        pub fn FixedBufferAllocator(a: Arg) void {
            var fba = std.heap.FixedBufferAllocator.init(test_buf[0..]);
            a.benchAllocator(&fba.allocator, false) catch unreachable;
        }

        pub fn Arena_FixedBufferAllocator(a: Arg) void {
            var fba = std.heap.FixedBufferAllocator.init(test_buf[0..]);
            var arena = std.heap.ArenaAllocator.init(&fba.allocator);
            defer arena.deinit();

            a.benchAllocator(&arena.allocator, false) catch unreachable;
        }

        pub fn ZeeAlloc_FixedBufferAllocator(a: Arg) void {
            var fba = std.heap.FixedBufferAllocator.init(test_buf[0..]);
            var zee_alloc = ZeeAllocDefaults.init(&fba.allocator);

            a.benchAllocator(&zee_alloc.allocator, false) catch unreachable;
        }

        pub fn DirectAllocator(a: Arg) void {
            var da = std.heap.DirectAllocator.init();
            defer da.deinit();

            a.benchAllocator(&da.allocator, true) catch unreachable;
        }

        pub fn Arena_DirectAllocator(a: Arg) void {
            var da = std.heap.DirectAllocator.init();
            defer da.deinit();

            var arena = std.heap.ArenaAllocator.init(&da.allocator);
            defer arena.deinit();

            a.benchAllocator(&arena.allocator, false) catch unreachable;
        }

        pub fn ZeeAlloc_DirectAllocator(a: Arg) void {
            var da = std.heap.DirectAllocator.init();
            defer da.deinit();

            var zee_alloc = ZeeAllocDefaults.init(&da.allocator);

            a.benchAllocator(&zee_alloc.allocator, false) catch unreachable;
        }
    });
}
