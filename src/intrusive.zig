const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Frame = @OpaqueType();
// Memory layout (mirrored in Node):
//     next: *Frame
//     payload_size: usize
//     payload: [n]u8

const meta_size = @sizeOf(*Frame) + @sizeOf(usize);
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

const Node = packed struct {
    next: *?*Frame,
    payload_size: *usize,
    payload: [*]u8,

    pub fn init(raw_bytes: []u8) Node {
        const node = Node.cast(@ptrCast(*Frame, raw_bytes.ptr));
        node.next.* = null;
        node.payload_size.* = raw_bytes.len - meta_size;
        return node;
    }

    pub fn cast(frame: *Frame) Node {
        // Here be dragons
        const base_addr = @ptrToInt(frame);
        return Node{
            .next = @intToPtr(*?*Frame, base_addr + @byteOffsetOf(Node, "next")),
            .payload_size = @intToPtr(*usize, base_addr + @byteOffsetOf(Node, "payload_size")),
            .payload = @intToPtr([*]u8, base_addr + @byteOffsetOf(Node, "payload")),
        };
    }

    pub fn toSlice(self: Node, target_size: usize) []u8 {
        return self.payload[0..target_size];
    }

    pub fn nextNode(self: Node) ?Node {
        if (self.next) |frame| {
            return Node.initRaw(frame);
        } else {
            return null;
        }
    }

    pub fn removeNext(self: Node) ?*Frame {
        const frame = self.next.*;
        self.next.* = null;
        return frame;
    }
};

const FreeList = struct {
    first: ?*Frame,

    pub fn init() FreeList {
        return FreeList{ .first = null };
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

        fn allocNode(self: *Self, size: usize) !Node {
            const rawData = try self.backing_allocator.alignedAlloc(u8, page_size, size);
            return Node.init(rawData);
        }

        fn findFreeNode(self: *Self, memsize: usize) ?Node {
            return null;
        }

        fn asMinimumData(self: *Self, node: Node, target_size: usize) []u8 {
            return node.toSlice(target_size);
        }

        fn free(self: *Self, old_mem: []u8) []u8 {
            // Actually return to a freelist
            return old_mem[0..0];
        }

        fn padToPayloadSize(self: *Self, memsize: usize) usize {
            if (memsize <= min_payload_size) {
                return min_payload_size;
            } else if (memsize <= page_size) {
                return ceilPowerOfTwo(usize, memsize);
            } else {
                return ceilToMultiple(page_size, memsize);
            }
        }

        fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
            if (new_align > page_size) {
                return error.OutOfMemory;
            } else if (new_size <= old_mem.len and new_align <= new_size) {
                return shrink(allocator, old_mem, old_align, new_size, new_align);
            } else {
                const self = @fieldParentPtr(Self, "allocator", allocator);

                const payload_size = self.padToPayloadSize(new_size);
                const node = self.findFreeNode(payload_size) orelse
                    try self.allocNode(payload_size);

                const result = self.asMinimumData(node, new_size);

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
                return old_mem[0..new_size];
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
