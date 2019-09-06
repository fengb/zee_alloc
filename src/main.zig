const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const meta_size = 2 * @sizeOf(usize);
pub const min_payload_size = meta_size;
pub const min_frame_size = meta_size + min_payload_size;

// https://github.com/ziglang/zig/issues/2426
fn ceilPowerOfTwo(comptime T: type, value: T) T {
    if (value <= 2) return value;
    const Shift = comptime std.math.Log2Int(T);
    return T(1) << @intCast(Shift, T.bit_count - @clz(T, value - 1));
}

const jumbo_index = 0;
const page_index = 1;

pub const ZeeAllocDefaults = ZeeAlloc(Config{});

const Config = struct {
    page_size: usize = std.math.max(std.mem.page_size, 65536), // 64K ought to be enough for everybody
    validation: Validation = .External,

    jumbo_match_strategy: JumboMatchStrategy = .Closest,
    free_strategy: FreeStrategy = .Compact,

    const JumboMatchStrategy = enum {
        Exact, // Only exact matches -- better for consistent allocations
        Closest, // Choose the frame that wastes the least space
        First, // Use first frame that fits -- faster but increases fragmentation
    };

    const FreeStrategy = enum {
        Fast,
        Compact,
    };

    const Validation = enum {
        Dev, // Enable all validations, including library internals
        External, // Only validate external boundaries (e.g. realloc or free)
        Unsafe, // Turn off all validations

        fn useInternal(comptime self: Validation) bool {
            if (builtin.mode == .Debug) {
                return true;
            }
            return self == .Dev;
        }

        fn useExternal(comptime self: Validation) bool {
            return switch (builtin.mode) {
                .Debug => true,
                .ReleaseSafe => self == .Dev or self == .External,
                else => false,
            };
        }

        fn assertInternal(comptime self: Validation, ok: bool) void {
            @setRuntimeSafety(comptime self.useInternal());
            if (!ok) unreachable;
        }

        fn assertExternal(comptime self: Validation, ok: bool) void {
            @setRuntimeSafety(comptime self.useExternal());
            if (!ok) unreachable;
        }
    };
};

pub fn ZeeAlloc(comptime config: Config) type {
    std.debug.assert(config.page_size >= std.mem.page_size);
    std.debug.assert(std.math.isPowerOfTwo(config.page_size));

    const inv_bitsize_ref = page_index + std.math.log2_int(usize, config.page_size);
    const size_buckets = inv_bitsize_ref - std.math.log2_int(usize, min_frame_size) + 1; // + 1 jumbo list

    return struct {
        const Self = @This();

        // Synthetic representation -- should not be created directly, but instead carved out of []u8 bytes
        const Frame = packed struct {
            const alignment = 2 * @sizeOf(usize);
            const allocated_signal = @intToPtr(*Frame, std.math.maxInt(usize));

            next: ?*Frame,
            frame_size: usize,
            // We can't embed arbitrarily sized arrays in a struct so stick a placeholder here
            payload: [min_payload_size]u8,

            fn isCorrectSize(memsize: usize) bool {
                return memsize % config.page_size == 0 or std.math.isPowerOfTwo(memsize);
            }

            pub fn init(raw_bytes: []u8) *Frame {
                @setRuntimeSafety(comptime config.validation.useInternal());
                const node = @ptrCast(*Frame, raw_bytes.ptr);
                node.frame_size = raw_bytes.len;
                node.validate() catch unreachable;
                return node;
            }

            pub fn restoreAddr(addr: usize) *Frame {
                @setRuntimeSafety(comptime config.validation.useInternal());
                const node = @intToPtr(*Frame, addr);
                node.validate() catch unreachable;
                return node;
            }

            pub fn restorePayload(payload: [*]u8) !*Frame {
                @setRuntimeSafety(comptime config.validation.useInternal());
                const node = @fieldParentPtr(Frame, "payload", @ptrCast(*[min_payload_size]u8, payload));
                try node.validate();
                return node;
            }

            pub fn validate(self: *Frame) !void {
                if (@ptrToInt(self) % alignment != 0) {
                    return error.UnalignedMemory;
                }
                if (!Frame.isCorrectSize(self.frame_size)) {
                    return error.UnalignedMemory;
                }
            }

            pub fn isAllocated(self: *Frame) bool {
                return self.next == allocated_signal;
            }

            pub fn markAllocated(self: *Frame) void {
                self.next = allocated_signal;
            }

            pub fn payloadSize(self: *Frame) usize {
                @setRuntimeSafety(comptime config.validation.useInternal());
                return self.frame_size - meta_size;
            }

            pub fn payloadSlice(self: *Frame, start: usize, end: usize) []u8 {
                @setRuntimeSafety(comptime config.validation.useInternal());
                config.validation.assertInternal(start <= end);
                config.validation.assertInternal(end <= self.payloadSize());
                const ptr = @ptrCast([*]u8, &self.payload);
                return ptr[start..end];
            }
        };

        const FreeList = packed struct {
            first: ?*Frame,

            pub fn init() FreeList {
                return FreeList{ .first = null };
            }

            pub fn root(self: *FreeList) *Frame {
                // FreeList.first == Frame.next
                // This allows for more graceful iteration without needing a back reference.
                // Since this is not a full frame, accessing any other field will corrupt memory.
                // Thar be dragons 🐉
                return @ptrCast(*Frame, self);
            }

            pub fn prepend(self: *FreeList, node: *Frame) void {
                node.next = self.first;
                self.first = node;
            }

            pub fn remove(self: *FreeList, target: *Frame) void {
                var iter = self.root();
                while (iter.next) |next| : (iter = next) {
                    if (next == target) {
                        _ = self.removeAfter(iter);
                        return;
                    }
                }
            }

            pub fn removeAfter(self: *FreeList, ref: *Frame) *Frame {
                const next_node = ref.next.?;
                ref.next = next_node.next;
                return next_node;
            }
        };

        pub const wasm_allocator = init: {
            var wasm = init(&wasm_page_allocator);
            break :init &wasm.allocator;
        };

        backing_allocator: *Allocator,

        page_size: usize = config.page_size,
        free_lists: [size_buckets]FreeList = [_]FreeList{FreeList.init()} ** size_buckets,
        allocator: Allocator = Allocator{
            .reallocFn = realloc,
            .shrinkFn = shrink,
        },

        pub fn init(backing_allocator: *Allocator) Self {
            return Self{ .backing_allocator = backing_allocator };
        }

        fn allocNode(self: *Self, memsize: usize) !*Frame {
            @setRuntimeSafety(comptime config.validation.useInternal());
            const alloc_size = std.mem.alignForward(memsize + meta_size, config.page_size);
            const rawData = try self.backing_allocator.reallocFn(self.backing_allocator, [_]u8{}, 0, alloc_size, u29(config.page_size));
            return Frame.init(rawData);
        }

        fn findFreeNode(self: *Self, memsize: usize) ?*Frame {
            @setRuntimeSafety(comptime config.validation.useInternal());
            var search_size = self.padToFrameSize(memsize);

            while (true) : (search_size *= 2) {
                @setRuntimeSafety(comptime config.validation.useInternal());
                const i = self.freeListIndex(search_size);
                var free_list = &self.free_lists[i];

                var closest_match_prev: ?*Frame = null;
                var closest_match_size: usize = std.math.maxInt(usize);

                var iter = free_list.root();
                while (iter.next) |next| : (iter = next) {
                    switch (config.jumbo_match_strategy) {
                        .Exact => {
                            if (next.frame_size == search_size) {
                                return free_list.removeAfter(iter);
                            }
                        },
                        .Closest => {
                            if (next.frame_size == search_size) {
                                return free_list.removeAfter(iter);
                            } else if (next.frame_size > search_size and next.frame_size < closest_match_size) {
                                closest_match_prev = iter;
                                closest_match_size = next.frame_size;
                            }
                        },
                        .First => {
                            if (next.frame_size >= search_size) {
                                return free_list.removeAfter(iter);
                            }
                        },
                    }
                }

                if (closest_match_prev) |prev| {
                    return free_list.removeAfter(prev);
                }

                if (i <= page_index) {
                    return null;
                }
            }
        }

        fn asMinimumData(self: *Self, node: *Frame, target_size: usize) []u8 {
            @setRuntimeSafety(comptime config.validation.useInternal());
            config.validation.assertInternal(target_size <= node.payloadSize());

            if (node.frame_size <= config.page_size) {
                const target_frame_size = self.padToFrameSize(target_size);

                var sub_frame_size = node.frame_size / 2;
                while (sub_frame_size >= target_frame_size) : (sub_frame_size /= 2) {
                    const start = node.payloadSize() - sub_frame_size;
                    const sub_frame_data = node.payloadSlice(start, node.payloadSize());
                    const sub_node = Frame.init(sub_frame_data);
                    self.freeListOfSize(sub_frame_size).prepend(sub_node);
                    node.frame_size = sub_frame_size;
                }
            }

            return node.payloadSlice(0, target_size);
        }

        fn free(self: *Self, target: *Frame) void {
            var node = target;
            if (config.free_strategy == .Compact) {
                while (node.frame_size < config.page_size) : (node.frame_size *= 2) {
                    // 16: [0, 16], [32, 48]
                    // 32: [0, 32], [64, 96]
                    const node_addr = @ptrToInt(node);
                    const buddy_addr = node_addr ^ node.frame_size;

                    @setRuntimeSafety(comptime config.validation.useInternal());
                    const buddy = Frame.restoreAddr(buddy_addr);
                    if (buddy.isAllocated() or buddy.frame_size != node.frame_size) {
                        break;
                    }

                    self.freeListOfSize(buddy.frame_size).remove(buddy);

                    // Use the lowest address as the new root
                    node = Frame.restoreAddr(node_addr & buddy_addr);
                }
            }

            self.freeListOfSize(node.frame_size).prepend(node);
        }

        fn padToFrameSize(self: *Self, memsize: usize) usize {
            @setRuntimeSafety(comptime config.validation.useInternal());
            const meta_memsize = memsize + meta_size;
            if (meta_memsize <= min_frame_size) {
                return min_frame_size;
            } else if (meta_memsize < config.page_size) {
                return ceilPowerOfTwo(usize, meta_memsize);
            } else {
                return std.mem.alignForward(meta_memsize, config.page_size);
            }
        }

        fn freeListOfSize(self: *Self, frame_size: usize) *FreeList {
            @setRuntimeSafety(comptime config.validation.useInternal());
            const i = self.freeListIndex(frame_size);
            return &self.free_lists[i];
        }

        fn freeListIndex(self: *Self, frame_size: usize) usize {
            @setRuntimeSafety(comptime config.validation.useInternal());
            config.validation.assertInternal(Frame.isCorrectSize(frame_size));
            if (frame_size > config.page_size) {
                return jumbo_index;
            } else if (frame_size <= min_frame_size) {
                return self.free_lists.len - 1;
            } else {
                return inv_bitsize_ref - std.math.log2_int(usize, frame_size);
            }
        }

        fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            if (new_align > min_frame_size) {
                return error.OutOfMemory;
            }

            const current_node = if (old_mem.len == 0) null else blk: {
                @setRuntimeSafety(comptime config.validation.useExternal());
                const node = Frame.restorePayload(old_mem.ptr) catch unreachable;
                if (new_size <= node.payloadSize()) {
                    return @noInlineCall(self.asMinimumData, node, new_size);
                }
                break :blk node;
            };

            const new_node = self.findFreeNode(new_size) orelse try self.allocNode(new_size);
            new_node.markAllocated();
            const result = @noInlineCall(self.asMinimumData, new_node, new_size);

            if (current_node) |node| {
                std.mem.copy(u8, result, old_mem);
                @noInlineCall(self.free, node);
            }
            return result;
        }

        fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            @setRuntimeSafety(comptime config.validation.useExternal());
            const node = Frame.restorePayload(old_mem.ptr) catch unreachable;
            if (new_size == 0) {
                @setRuntimeSafety(comptime config.validation.useExternal());
                config.validation.assertExternal(node.isAllocated());
                @noInlineCall(self.free, node);
                return [_]u8{};
            } else {
                return @noInlineCall(self.asMinimumData, node, new_size);
            }
        }

        fn debugCount(self: *Self, index: usize) usize {
            var count = usize(0);
            var iter = self.free_lists[index].first;
            while (iter) |node| : (iter = node.next) {
                count += 1;
            }
            return count;
        }

        fn debugCountAll(self: *Self) usize {
            var count = usize(0);
            for (self.free_lists) |_, i| {
                count += self.debugCount(i);
            }
            return count;
        }

        fn debugDump(self: *Self) void {
            for (self.free_lists) |_, i| {
                std.debug.warn("{}: {}\n", i, self.debugCount(i));
            }
        }
    };
}

fn assertIf(comptime run_assert: bool, ok: bool) void {
    @setRuntimeSafety(run_assert);
    if (!ok) unreachable;
}

// https://github.com/ziglang/zig/issues/2291
extern fn @"llvm.wasm.memory.grow.i32"(u32, u32) i32;
var wasm_page_allocator = init: {
    if (builtin.arch != .wasm32) {
        @compileError("wasm allocator is only available for wasm32 arch");
    }

    // std.heap.wasm_allocator is designed for arbitrary sizing
    // We only need page sizing, and this lets us stay super small
    const WasmPageAllocator = struct {
        pub fn realloc(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) Allocator.Error![]u8 {
            const is_debug = builtin.mode == .Debug;
            @setRuntimeSafety(is_debug);
            assertIf(is_debug, old_mem.len == 0); // Shouldn't be actually reallocating
            assertIf(is_debug, new_size % std.mem.page_size == 0); // Should only be allocating page size chunks
            assertIf(is_debug, new_align % std.mem.page_size == 0); // Should only align to page_size increments

            const requested_page_count = @intCast(u32, new_size / std.mem.page_size);
            const prev_page_count = @"llvm.wasm.memory.grow.i32"(0, requested_page_count);
            if (prev_page_count < 0) {
                return error.OutOfMemory;
            }

            const start_ptr = @intToPtr([*]u8, @intCast(usize, prev_page_count) * std.mem.page_size);
            return start_ptr[0..new_size];
        }

        pub fn shrink(allocator: *Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
            @setRuntimeSafety(builtin.mode == .Debug);
            unreachable; // Shouldn't be shrinking / freeing
        }
    };

    break :init Allocator{
        .reallocFn = WasmPageAllocator.realloc,
        .shrinkFn = WasmPageAllocator.shrink,
    };
};

pub const CExports = struct {
    malloc: bool = false,
    realloc: bool = false,
    free: bool = false,

    pub fn using(comptime self: CExports, comptime allocator: *std.mem.Allocator) void {
        if (self.malloc) {
            _ = struct {
                export fn malloc(size: usize) ?*c_void {
                    const result = allocator.alloc(u8, size) catch return null;
                    return result.ptr;
                }
            };
        }

        if (self.realloc) {
            _ = struct {
                export fn realloc(c_ptr: *c_void, new_size: usize) ?*c_void {
                    // Use a synthetic slice
                    const ptr = @ptrCast([*]u8, c_ptr);
                    const result = allocator.realloc(ptr[0..1], new_size) catch return null;
                    return result.ptr;
                }
            };
        }

        if (self.free) {
            _ = struct {
                export fn free(c_ptr: *c_void) void {
                    // Use a synthetic slice. zee_alloc will free via corresponding metadata.
                    const ptr = @ptrCast([*]u8, c_ptr);
                    allocator.free(ptr[0..1]);
                }
            };
        }
    }
};

pub fn exportC(comptime allocator: *std.mem.Allocator) void {
    _ = struct {
        export fn malloc(size: usize) ?*c_void {
            const result = allocator.alloc(u8, size) catch return null;
            return result.ptr;
        }

        export fn realloc(c_ptr: *c_void, new_size: usize) ?*c_void {
            // Use a synthetic slice
            const ptr = @ptrCast([*]u8, c_ptr);
            const result = allocator.realloc(ptr[0..1], new_size) catch return null;
            return result.ptr;
        }

        export fn free(c_ptr: *c_void) void {
            // Use a synthetic slice. zee_alloc will free via corresponding metadata.
            const ptr = @ptrCast([*]u8, c_ptr);
            allocator.free(ptr[0..1]);
        }
    };
}

// Tests

const testing = std.testing;

test "ZeeAlloc helpers" {
    var buf: [0]u8 = undefined;
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buf[0..]);
    var zee_alloc = ZeeAllocDefaults.init(&fixed_buffer_allocator.allocator);

    @"freeListIndex": {
        testing.expectEqual(usize(page_index), zee_alloc.freeListIndex(zee_alloc.page_size));
        testing.expectEqual(usize(page_index + 1), zee_alloc.freeListIndex(zee_alloc.page_size / 2));
        testing.expectEqual(usize(page_index + 2), zee_alloc.freeListIndex(zee_alloc.page_size / 4));
    }

    @"padToFrameSize": {
        testing.expectEqual(usize(zee_alloc.page_size), zee_alloc.padToFrameSize(zee_alloc.page_size - meta_size));
        testing.expectEqual(usize(2 * zee_alloc.page_size), zee_alloc.padToFrameSize(zee_alloc.page_size));
        testing.expectEqual(usize(2 * zee_alloc.page_size), zee_alloc.padToFrameSize(zee_alloc.page_size - meta_size + 1));
        testing.expectEqual(usize(3 * zee_alloc.page_size), zee_alloc.padToFrameSize(2 * zee_alloc.page_size));
    }
}

test "ZeeAlloc internals" {
    var buf: [1000000]u8 = undefined;

    @"node count makes sense": {
        var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buf[0..]);
        var zee_alloc = ZeeAllocDefaults.init(&fixed_buffer_allocator.allocator);

        testing.expectEqual(zee_alloc.debugCountAll(), 0);

        var small1 = try zee_alloc.allocator.create(u8);
        var prev_free_nodes = zee_alloc.debugCountAll();
        testing.expect(prev_free_nodes > 0);

        var small2 = try zee_alloc.allocator.create(u8);
        testing.expectEqual(prev_free_nodes - 1, zee_alloc.debugCountAll());
        prev_free_nodes = zee_alloc.debugCountAll();

        var big1 = try zee_alloc.allocator.alloc(u8, 127 * 1024);
        testing.expectEqual(prev_free_nodes, zee_alloc.debugCountAll());
        zee_alloc.allocator.free(big1);
        testing.expectEqual(prev_free_nodes + 1, zee_alloc.debugCountAll());
        testing.expectEqual(usize(1), zee_alloc.debugCount(jumbo_index));
    }

    @"coalesce": {
        var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buf[0..]);
        var zee_alloc = ZeeAllocDefaults.init(&fixed_buffer_allocator.allocator);

        var small = try zee_alloc.allocator.create(u8);
        testing.expect(zee_alloc.debugCountAll() > 1);
        zee_alloc.allocator.destroy(small);
        testing.expectEqual(usize(1), zee_alloc.debugCountAll());
    }

    @"realloc reuses frame if possible": {
        var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buf[0..]);
        var zee_alloc = ZeeAllocDefaults.init(&fixed_buffer_allocator.allocator);

        const orig = try zee_alloc.allocator.alloc(u8, 1);
        const addr = orig.ptr;

        var i = usize(2);
        while (i <= min_payload_size) : (i += 1) {
            var re = try zee_alloc.allocator.realloc(orig, i);
            testing.expectEqual(re.ptr, addr);
        }
    }

    @"allocated_signal": {
        var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buf[0..]);
        var zee_alloc = ZeeAllocDefaults.init(&fixed_buffer_allocator.allocator);

        const payload = try zee_alloc.allocator.alloc(u8, 1);
        const frame = try ZeeAllocDefaults.Frame.restorePayload(payload.ptr);
        testing.expect(frame.isAllocated());

        zee_alloc.allocator.free(payload);
        testing.expect(!frame.isAllocated());
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
    //if (std.mem.page_size << 2 > std.math.maxInt(usize)) return;

    //const USizeShift = @IntType(false, std.math.log2(usize.bit_count));
    //const large_align = u29(std.mem.page_size << 2);
    const USizeShift = @IntType(false, std.math.log2(usize.bit_count));
    const large_align = u29(std.mem.page_size);

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

    const alloc_size = std.mem.page_size * 2 + 50;
    var slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    defer allocator.free(slice);

    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    // On Windows, VirtualAlloc returns addresses aligned to a 64K boundary,
    // which is 16 pages, hence the 32. This test may require to increase
    // the size of the allocations feeding the `allocator` parameter if they
    // fail, because of this high over-alignment we want to have.
    while (@ptrToInt(slice.ptr) == std.mem.alignForward(@ptrToInt(slice.ptr), std.mem.page_size * 32)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[60] = 0x34;

    // realloc to a smaller size but with a larger alignment
    slice = try allocator.alignedRealloc(slice, std.mem.page_size, alloc_size / 2);
    testing.expectEqual(slice[0], 0x12);
    testing.expectEqual(slice[60], 0x34);
}

test "ZeeAlloc with FixedBufferAllocator" {
    var buf: [1000000]u8 = undefined;
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buf[0..]);
    var zee_alloc = ZeeAllocDefaults.init(&fixed_buffer_allocator.allocator);

    try testAllocator(&zee_alloc.allocator);
    try testAllocatorAligned(&zee_alloc.allocator, 8);
    // try testAllocatorLargeAlignment(&zee_alloc.allocator);
    // try testAllocatorAlignedShrink(&zee_alloc.allocator);
}

test "ZeeAlloc with DirectAllocator" {
    var buf: [1000000]u8 = undefined;
    var zee_alloc = ZeeAllocDefaults.init(std.heap.direct_allocator);

    try testAllocator(&zee_alloc.allocator);
    try testAllocatorAligned(&zee_alloc.allocator, 8);
    // try testAllocatorLargeAlignment(&zee_alloc.allocator);
    // try testAllocatorAlignedShrink(&zee_alloc.allocator);
}
