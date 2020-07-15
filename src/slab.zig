const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// ZeeAlloc will request a multiple of `slab_size` from the backing allocator.
    /// **Must** be a power of two.
    slab_size: usize = std.math.max(std.mem.page_size, 65536), // 64K ought to be enough for everybody

    /// **Must** be a power of two.
    min_element_size: usize = 4,

    fn maxElementSize(conf: Config) usize {
        // Scientifically derived value
        return conf.slab_size / 4;
    }
};

pub const ZeeAllocDefaults = ZeeAlloc(Config{});

pub fn ZeeAlloc(comptime conf: Config) type {
    const min_shift_size = @ctz(usize, conf.min_element_size);
    const max_shift_size = @ctz(usize, conf.maxElementSize());
    const total_slabs = max_shift_size - min_shift_size + 1;

    return struct {
        const Self = @This();

        slabs: [total_slabs]?*Slab = [_]?*Slab{null} ** total_slabs,
        backing_allocator: *std.mem.Allocator,

        allocator: Allocator = Allocator{
            .allocFn = alloc,
            .resizeFn = resize,
        },

        const Slab = extern struct {
            const header_size = 2 * @sizeOf(usize);

            next: ?*Slab align(conf.slab_size),
            element_size: usize,
            pad: [conf.slab_size - header_size]u8 align(8),

            fn init(element_size: usize) Slab {
                var result = Slab{
                    .next = null,
                    .element_size = element_size,
                    .pad = undefined,
                };

                const blocks = result.freeBlocks();
                for (blocks[0 .. blocks.len - 1]) |*block| {
                    block.* = std.math.maxInt(u64);
                }

                const remaining_bits = @truncate(u6, (result.elementCount() - result.dataOffset()) % 64);
                // TODO: detect overflow
                blocks[blocks.len - 1] = (@as(u64, 1) << remaining_bits) - 1;

                return result;
            }

            fn fromMemPtr(ptr: [*]u8) *Slab {
                const addr = std.mem.alignBackward(@ptrToInt(ptr), conf.slab_size);
                return @intToPtr(*Slab, addr);
            }

            fn freeBlocks(self: *Slab) []u64 {
                const count = divCeil(usize, self.elementCount(), 64);
                const ptr = @ptrCast([*]u64, &self.pad);
                return ptr[0..count];
            }

            fn totalFree(self: *Slab) usize {
                var i: usize = 0;
                for (self.freeBlocks()) |block| {
                    i += @popCount(u64, block);
                }
                return i;
            }

            const UsizeShift = std.meta.Int(false, std.math.Log2Int(usize).bit_count - 1);
            fn elementSizeShift(self: Slab) UsizeShift {
                return @truncate(UsizeShift, @ctz(usize, self.element_size));
            }

            fn elementCount(self: Slab) usize {
                return conf.slab_size >> self.elementSizeShift();
            }

            fn dataOffset(self: Slab) usize {
                const BITS_PER_BYTE = 8;
                return 1 + ((conf.slab_size / BITS_PER_BYTE) >> self.elementSizeShift() >> self.elementSizeShift());
            }

            fn elementAt(self: *Slab, idx: usize) []u8 {
                std.debug.assert(idx >= self.dataOffset());
                std.debug.assert(idx < self.elementCount());

                const bytes = std.mem.asBytes(self);
                return bytes[idx << self.elementSizeShift() ..][0..self.element_size];
            }

            fn elementIdx(self: *Slab, element: []u8) usize {
                std.debug.assert(element.len <= self.element_size);
                const diff = @ptrToInt(element.ptr) - @ptrToInt(self);
                std.debug.assert(diff % self.element_size == 0);

                return diff >> self.elementSizeShift();
            }

            fn alloc(self: *Slab) ![]u8 {
                for (self.freeBlocks()) |*block, i| {
                    if (block.* != 0) {
                        const bit = @ctz(u64, block.*);

                        const index = 64 * i + bit;

                        const mask = @as(u64, 1) << @intCast(u6, bit);
                        block.* &= ~mask;

                        return self.elementAt(index + self.dataOffset());
                    }
                }

                return error.OutOfMemory;
            }

            fn free(self: *Slab, element: []u8) void {
                const index = self.elementIdx(element) - self.dataOffset();

                const block = &self.freeBlocks()[index / 64];
                const mask = @as(u64, 1) << @truncate(u6, index);
                std.debug.assert(mask & block.* == 0);
                block.* |= mask;
            }

            fn jumboPayload(self: *const Slab) ![]u8 {
                return self.pad.ptr[0..size];
            }
        };

        const full_signal = @intToPtr(*align(1) Slab, 1);

        pub fn init(allocator: *std.mem.Allocator) Self {
            return .{ .backing_allocator = allocator };
        }

        fn padToSlabSize(memsize: usize) usize {
            if (memsize <= conf.min_element_size) {
                return conf.min_element_size;
            } else if (memsize <= conf.slab_size / 4) {
                return ceilPowerOfTwo(usize, memsize);
            } else {
                unreachable;
                // const frame_size = std.mem.alignForward(memsize + Slab.header_size, conf.slab_size);
                // return frame_size - Slab.header_size;
            }
        }

        fn unsafeLog2(comptime T: type, val: T) T {
            std.debug.assert(ceilPowerOfTwo(T, val) == val);
            return @ctz(T, val);
        }

        fn findSlabIndex(padded_size: usize) usize {
            return unsafeLog2(usize, padded_size) - min_shift_size;
        }

        fn alloc(allocator: *Allocator, n: usize, ptr_align: u29, len_align: u29) Allocator.Error![]u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);

            const is_jumbo = n > conf.slab_size / 4;
            if (is_jumbo) {
                // TODO: handle jumbo
                return error.OutOfMemory;
            } else {
                const padded_size = padToSlabSize(n);
                const idx = findSlabIndex(padded_size);
                const slab = self.slabs[idx] orelse blk: {
                    const new_slab = try self.backing_allocator.create(Slab);
                    new_slab.* = Slab.init(padded_size);
                    self.slabs[idx] = new_slab;
                    break :blk new_slab;
                };

                const result = slab.alloc() catch unreachable;
                if (slab.totalFree() == 0) {
                    self.slabs[idx] = slab.next;
                    // Salt the earth
                    std.mem.copy(
                        u8,
                        std.mem.asBytes(&slab.next),
                        std.mem.asBytes(&full_signal),
                    );
                }

                return result[0..std.mem.alignAllocLen(padded_size, n, len_align)];
            }
        }

        fn resize(allocator: *Allocator, buf: []u8, new_size: usize, len_align: u29) Allocator.Error!usize {
            const self = @fieldParentPtr(Self, "allocator", allocator);

            const slab = Slab.fromMemPtr(buf.ptr);
            if (new_size == 0) {
                slab.free(buf);
                if (slab.next == full_signal) {
                    const idx = findSlabIndex(slab.element_size);
                    slab.next = self.slabs[idx];
                    self.slabs[idx] = slab;
                }
                return 0;
            }

            const padded_new_size = padToSlabSize(new_size);
            if (padded_new_size > slab.element_size) {
                return error.OutOfMemory;
            }

            return std.mem.alignAllocLen(padded_new_size, new_size, len_align);
        }
    };
}

fn divCeil(comptime T: type, numerator: T, denominator: T) T {
    return (numerator + denominator - 1) / denominator;
}

// https://github.com/ziglang/zig/issues/2426
fn ceilPowerOfTwo(comptime T: type, value: T) T {
    if (value <= 2) return value;
    const Shift = comptime std.math.Log2Int(T);
    return @as(T, 1) << @intCast(Shift, T.bit_count - @clz(T, value - 1));
}

test "divCeil" {
    std.testing.expectEqual(@as(u32, 0), divCeil(u32, 0, 64));
    std.testing.expectEqual(@as(u32, 1), divCeil(u32, 1, 64));
    std.testing.expectEqual(@as(u32, 1), divCeil(u32, 64, 64));
    std.testing.expectEqual(@as(u32, 2), divCeil(u32, 65, 64));
}

test "Slab.init" {
    {
        const slab = ZeeAllocDefaults.Slab.init(16384);
        std.testing.expectEqual(@as(usize, 16384), slab.element_size);
        std.testing.expectEqual(@as(?*ZeeAllocDefaults.Slab, null), slab.next);

        const raw_ptr = @ptrCast(*const u64, &slab.pad);
        std.testing.expectEqual((@as(u64, 1) << 3) - 1, raw_ptr.*);
    }

    {
        const slab = ZeeAllocDefaults.Slab.init(2048);
        std.testing.expectEqual(@as(usize, 2048), slab.element_size);
        std.testing.expectEqual(@as(?*ZeeAllocDefaults.Slab, null), slab.next);

        const raw_ptr = @ptrCast(*const u64, &slab.pad);
        std.testing.expectEqual((@as(u64, 1) << 31) - 1, raw_ptr.*);
    }

    const u64_max: u64 = std.math.maxInt(u64);

    {
        const slab = ZeeAllocDefaults.Slab.init(256);
        std.testing.expectEqual(@as(usize, 256), slab.element_size);
        std.testing.expectEqual(@as(?*ZeeAllocDefaults.Slab, null), slab.next);

        const raw_ptr = @ptrCast([*]const u64, &slab.pad);
        std.testing.expectEqual(u64_max, raw_ptr[0]);
        std.testing.expectEqual(u64_max, raw_ptr[1]);
        std.testing.expectEqual(u64_max, raw_ptr[2]);
        std.testing.expectEqual((@as(u64, 1) << 63) - 1, raw_ptr[3]);
    }
}

test "Slab.elementAt" {
    {
        var slab = ZeeAllocDefaults.Slab.init(16384);

        var element = slab.elementAt(1);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(1 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));

        element = slab.elementAt(2);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(2 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));

        element = slab.elementAt(3);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(3 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));
    }
    {
        var slab = ZeeAllocDefaults.Slab.init(128);

        var element = slab.elementAt(1);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(1 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));

        element = slab.elementAt(2);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(2 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));

        element = slab.elementAt(3);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(3 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));
    }
    {
        var slab = ZeeAllocDefaults.Slab.init(64);
        std.testing.expectEqual(@as(usize, 3), slab.dataOffset());

        var element = slab.elementAt(3);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(3 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));

        element = slab.elementAt(5);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(5 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));
    }
    {
        var slab = ZeeAllocDefaults.Slab.init(4);
        std.testing.expectEqual(@as(usize, 513), slab.dataOffset());

        var element = slab.elementAt(513);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(513 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));

        element = slab.elementAt(1023);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(1023 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));
    }
}

test "Slab.elementIdx" {
    var slab = ZeeAllocDefaults.Slab.init(128);

    var element = slab.elementAt(1);
    std.testing.expectEqual(@as(usize, 1), slab.elementIdx(element));
}

test "Slab.freeBlocks" {
    {
        var slab = ZeeAllocDefaults.Slab.init(16384);

        const blocks = slab.freeBlocks();
        std.testing.expectEqual(@as(usize, 1), blocks.len);
        std.testing.expectEqual(@ptrToInt(&slab.pad), @ptrToInt(blocks.ptr));
    }
    {
        var slab = ZeeAllocDefaults.Slab.init(128);

        const blocks = slab.freeBlocks();
        std.testing.expectEqual(@as(usize, 8), blocks.len);
        std.testing.expectEqual(@ptrToInt(&slab.pad), @ptrToInt(blocks.ptr));
    }
}

test "Slab.alloc + free" {
    var slab = ZeeAllocDefaults.Slab.init(16384);

    std.testing.expectEqual(@as(usize, 3), slab.totalFree());

    const data0 = try slab.alloc();
    std.testing.expectEqual(@as(usize, 2), slab.totalFree());
    std.testing.expectEqual(@as(usize, 16384), data0.len);

    const data1 = try slab.alloc();
    std.testing.expectEqual(@as(usize, 1), slab.totalFree());
    std.testing.expectEqual(@as(usize, 16384), data1.len);
    std.testing.expectEqual(@as(usize, 16384), @ptrToInt(data1.ptr) - @ptrToInt(data0.ptr));

    const data2 = try slab.alloc();
    std.testing.expectEqual(@as(usize, 0), slab.totalFree());
    std.testing.expectEqual(@as(usize, 16384), data2.len);
    std.testing.expectEqual(@as(usize, 16384), @ptrToInt(data2.ptr) - @ptrToInt(data1.ptr));

    std.testing.expectError(error.OutOfMemory, slab.alloc());

    {
        slab.free(data2);
        std.testing.expectEqual(@as(usize, 1), slab.totalFree());
        slab.free(data1);
        std.testing.expectEqual(@as(usize, 2), slab.totalFree());
        slab.free(data0);
        std.testing.expectEqual(@as(usize, 3), slab.totalFree());
    }
}

test "padToSlabSize" {
    const page_size = 65536;
    const header_size = 2 * @sizeOf(usize);

    std.testing.expectEqual(@as(usize, 4), ZeeAllocDefaults.padToSlabSize(1));
    std.testing.expectEqual(@as(usize, 4), ZeeAllocDefaults.padToSlabSize(4));
    std.testing.expectEqual(@as(usize, 8), ZeeAllocDefaults.padToSlabSize(8));
    std.testing.expectEqual(@as(usize, 16), ZeeAllocDefaults.padToSlabSize(9));
    std.testing.expectEqual(@as(usize, 16384), ZeeAllocDefaults.padToSlabSize(16384));
}

test "alloc slab list" {
    var zee_alloc = ZeeAllocDefaults.init(std.heap.page_allocator);

    for (zee_alloc.slabs) |root| {
        std.testing.expect(root == null);
    }

    std.testing.expect(zee_alloc.slabs[0] == null);
    const small = try zee_alloc.allocator.alloc(u8, 4);
    std.testing.expect(zee_alloc.slabs[0] != null);
    const smalls_before_free = zee_alloc.slabs[0].?.totalFree();
    zee_alloc.allocator.free(small);
    std.testing.expectEqual(smalls_before_free + 1, zee_alloc.slabs[0].?.totalFree());

    std.testing.expect(zee_alloc.slabs[12] == null);
    const large = try zee_alloc.allocator.alloc(u8, 16384);
    std.testing.expect(zee_alloc.slabs[12] != null);
    const larges_before_free = zee_alloc.slabs[12].?.totalFree();
    zee_alloc.allocator.free(large);
    std.testing.expectEqual(larges_before_free + 1, zee_alloc.slabs[12].?.totalFree());
}
