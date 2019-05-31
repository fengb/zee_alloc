const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Frame = @OpaqueType();

// Synthetic representation -- we can't embed arbitrarily sized arrays in a struct
const FrameLayout = struct {
    frame_size: usize,
    next: ?*Frame,
    payload: []u8,
};

const meta_size = @byteOffsetOf(FrameLayout, "payload");
pub const min_frame_size = ceilPowerOfTwo(usize, meta_size + 1);
pub const min_payload_size = min_frame_size - meta_size;

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

fn isFrameSize(memsize: usize, comptime page_size: usize) bool {
    return memsize > 0 and
        (memsize % page_size == 0 or memsize == ceilPowerOfTwo(usize, memsize));
}

const Node = packed struct {
    frame: *Frame,
    // Mirroring FrameLayout
    frame_size: *usize,
    next: *?*Frame,
    payload: [*]u8,

    pub fn init(raw_bytes: []u8) Node {
        const node = Node.castUnsafe(@ptrCast(*Frame, raw_bytes.ptr));
        node.frame_size.* = raw_bytes.len;
        node.next.* = null;
        return node;
    }

    fn castUnsafe(frame: *Frame) Node {
        // Here be dragons
        const base_addr = @ptrToInt(frame);
        std.debug.assert(base_addr % 8 == 0);

        return Node{
            .frame = frame,
            .frame_size = @intToPtr(*usize, base_addr + @byteOffsetOf(FrameLayout, "frame_size")),
            .next = @intToPtr(*?*Frame, base_addr + @byteOffsetOf(FrameLayout, "next")),
            .payload = @intToPtr([*]u8, base_addr + @byteOffsetOf(FrameLayout, "payload")),
        };
    }

    pub fn cast(frame: *Frame) !Node {
        const node = castUnsafe(frame);
        if (node.frame_size.* < 4) {
            return error.UnalignedMemory;
        }
        return node;
    }

    pub fn restore(payload: [*]u8) !Node {
        const node = try Node.cast(@ptrCast(*Frame, payload - @byteOffsetOf(FrameLayout, "payload")));
        return node;
    }

    pub fn payloadSize(self: Node) usize {
        return self.frame_size.* - meta_size;
    }

    pub fn toSlice(self: Node, start: usize, end: usize) []u8 {
        std.debug.assert(start <= end);
        std.debug.assert(end <= self.payloadSize());
        return self.payload[start..end];
    }

    pub fn frameMeta(self: Node) FrameMeta {
        return FrameMeta{
            .frame = self.frame,
            .frame_size = self.frame_size.*,
            .next = self.next.*,
            .payload = []u8{},
        };
    }

    pub fn nextNode(self: Node) ?Node {
        const frame = self.next.* orelse return null;
        return Node.cast(frame) catch unreachable;
    }
};

const FreeList = struct {
    first: ?*Frame,

    pub fn init() FreeList {
        return FreeList{ .first = null };
    }

    pub fn firstNode(self: FreeList) ?Node {
        const frame = self.first orelse return null;
        return Node.cast(frame) catch unreachable;
    }

    pub fn prepend(self: *FreeList, node: Node) void {
        node.next.* = self.first;
        self.first = node.frame;
    }

    pub fn removeAfter(self: *FreeList, ref: ?Node) ?*Frame {
        const first_node = self.firstNode() orelse return null;
        if (ref) |ref_node| {
            const next_node = ref_node.nextNode() orelse return null;
            ref_node.next.* = next_node.next.*;
            return next_node.frame;
        } else {
            self.first = first_node.next.*;
            return first_node.frame;
        }
    }
};

const oversized_index = 0;
const page_index = 1;

pub const ZeeAllocDefaults = ZeeAlloc(std.os.page_size);

pub fn ZeeAlloc(comptime page_size: usize) type {
    const inv_bitsize_ref = page_index + std.math.log2_int(usize, page_size);
    const size_buckets = inv_bitsize_ref - std.math.log2_int(usize, min_frame_size) + 1; // + 1 oversized list

    return struct {
        const Self = @This();

        allocator: Allocator,

        backing_allocator: *Allocator,
        free_lists: [size_buckets]FreeList,

        pub fn init(backing_allocator: *Allocator) @This() {
            return Self{
                .allocator = Allocator{
                    .reallocFn = realloc,
                    .shrinkFn = shrink,
                },
                .backing_allocator = backing_allocator,
                .free_lists = []FreeList{FreeList.init()} ** size_buckets,
            };
        }

        fn allocNode(self: *Self, frame_size: usize) !Node {
            std.debug.assert(isFrameSize(frame_size, page_size));
            const rawData = try self.backing_allocator.alignedAlloc(u8, page_size, frame_size);
            return Node.init(rawData);
        }

        fn findFreeNode(self: *Self, frame_size: usize) ?Node {
            std.debug.assert(isFrameSize(frame_size, page_size));

            var search_size = frame_size;
            while (true) : (search_size *= 2) {
                var i = self.freeListIndex(search_size);

                var free_list = &self.free_lists[i];
                var prev: ?Node = null;
                var iter = free_list.firstNode();
                while (iter) |node| : ({
                    prev = iter;
                    iter = node.nextNode();
                }) {
                    if (node.frame_size.* == search_size) {
                        const removed = free_list.removeAfter(prev);
                        std.debug.assert(removed == node.frame);
                        return node;
                    }
                }

                if (i <= page_index) {
                    return null;
                }
            }
        }

        fn asMinimumData(self: *Self, node: Node, target_size: usize) []u8 {
            std.debug.assert(target_size <= node.payloadSize());

            const target_frame_size = self.padToFrameSize(target_size);

            var sub_frame_size = std.math.min(node.frame_size.* / 2, page_size);
            while (sub_frame_size >= target_frame_size) : (sub_frame_size /= 2) {
                var i = self.freeListIndex(sub_frame_size);
                const start = node.payloadSize() - sub_frame_size;
                const sub_frame_data = node.toSlice(start, node.payloadSize());
                const sub_node = Node.init(sub_frame_data);
                self.free_lists[i].prepend(sub_node);
                node.frame_size.* = sub_frame_size;
            }

            return node.toSlice(0, target_size);
        }

        fn free(self: *Self, old_mem: []u8) []u8 {
            const node = Node.restore(old_mem.ptr) catch unreachable;
            const i = self.freeListIndex(node.frame_size.*);
            self.free_lists[i].prepend(node);
            return old_mem[0..0];
        }

        fn padToFrameSize(self: *Self, memsize: usize) usize {
            const meta_memsize = memsize + meta_size;
            if (meta_memsize <= min_frame_size) {
                return min_frame_size;
            } else if (meta_memsize <= page_size) {
                return ceilPowerOfTwo(usize, meta_memsize);
            } else {
                return ceilToMultiple(page_size, meta_memsize);
            }
        }

        fn freeListIndex(self: *Self, frame_size: usize) usize {
            std.debug.assert(isFrameSize(frame_size, page_size));
            if (frame_size > page_size) {
                return oversized_index;
            } else if (frame_size <= min_frame_size) {
                return self.free_lists.len - 1;
            } else {
                return inv_bitsize_ref - std.math.log2_int(usize, frame_size);
            }
        }

        fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
            if (new_align > page_size) {
                return error.OutOfMemory;
            } else if (new_size <= old_mem.len) {
                return shrink(allocator, old_mem, old_align, new_size, new_align);
            } else {
                const self = @fieldParentPtr(Self, "allocator", allocator);

                const frame_size = self.padToFrameSize(new_size);
                const node = self.findFreeNode(frame_size) orelse try self.allocNode(frame_size);

                const result = self.asMinimumData(node, new_size);

                if (old_mem.len > 0) {
                    std.mem.copy(u8, result, old_mem);
                    _ = self.free(old_mem);
                }
                return result[0..new_size];
            }
        }

        fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            if (new_size == 0) {
                return self.free(old_mem);
            } else {
                const node = Node.restore(old_mem.ptr) catch unreachable;
                return self.asMinimumData(node, new_size);
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

// -- functional tests from std/heap.zig

const testing = std.testing;

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
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buf[0..]);
    var zee_alloc = ZeeAllocDefaults.init(&fixed_buffer_allocator.allocator);

    try testAllocator(&zee_alloc.allocator);
}
