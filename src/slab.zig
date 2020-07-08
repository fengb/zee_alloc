const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    /// ZeeAlloc will request a multiple of `slab_size` from the backing allocator.
    /// **Must** be a power of two.
    slab_size: usize = std.math.max(std.mem.page_size, 65536), // 64K ought to be enough for everybody
};

pub const ZeeAllocDefaults = ZeeAlloc(Config{});

pub fn ZeeAlloc(comptime conf: Config) type {
    return struct {
        const Self = @This();

        slabs: [13]?*Slab, // slab[0] = 4 bytes, slab[1] = 8 bytes, etc.
        backing_allocator: *std.mem.Allocator,

        allocator: Allocator = Allocator{
            .allocFn = alloc,
            .resizeFn = resize,
        },

        const Slab = extern struct {
            // TODO: fix Zig alignment bug
            // next: ?*Slab align(conf.slab_size) = null,
            next: ?*Slab align(32768) = null,
            element_size: usize,
            pad: [conf.slab_size - 2 * @sizeOf(usize)]u8 align(8) = undefined,

            fn fromMemPtr(ptr: [*]u8) *Slab {
                const addr = std.mem.alignBackward(@ptrToInt(ptr), conf.slab_size);
                return @intToPtr(*Slab, addr);
            }

            fn freeBlocks(self: *Slab) []u64 {
                const count = divCeil(usize, self.elementCount(), 64);
                const ptr = @ptrCast([*]u64, &self.pad);
                return ptr[0..count];
            }

            fn elementCount(self: Slab) usize {
                // TODO: convert into bit shifts
                return conf.slab_size / self.element_size;
            }

            fn headerElements(self: Slab) usize {
                const BITS_PER_BYTE = 8;
                // TODO: convert into bit shifts
                return 1 + conf.slab_size / BITS_PER_BYTE / self.element_size / self.element_size;
            }

            fn elementAt(self: *Slab, idx: usize) []u8 {
                std.debug.assert(idx >= self.headerElements());
                std.debug.assert(idx < self.elementCount());

                const bytes = std.mem.asBytes(self);
                // TODO: convert into bit shifts
                return bytes[self.element_size * idx ..][0..self.element_size];
            }

            fn alloc(self: *Slab) ![]u64 {
                for (self.meta) |*chunk, i| {
                    if (chunk.* != 0) {
                        const free = @ctz(chunk.*);

                        const index = 64 * i + free;

                        const mask = @as(u64, 1) << free;
                        chunk.* &= ~mask;

                        return self.data(index);
                    }
                }

                return error.OutOfMemory;
            }

            fn data(self: *Slab, item_idx: usize) []u8 {
                const raw_bytes = std.mem.asBytes(self);
                const meta_offset = self.meta().len;
                const index = (meta_offset + raw_bytes) * self.size;
                return raw_bytes[index..][0..self.size];
            }

            fn jumboPayload(self: *const Slab) ![]u8 {
                return self.pad.ptr[0..size];
            }
        };

        const full_signal = @intToPtr(*Slab, std.math.maxInt(usize));

        pub fn init(allocator: *std.mem.Allocator) Self {
            return .{
                .slabs = [_]?*Slab{null} ** 8,
                .backing_allocator = allocator,
            };
        }

        fn alloc(allocator: *Allocator, n: usize, ptr_align: u29, len_align: u29) Allocator.Error![]u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            const padded_size = self.padToSize(n);

            // TODO: handle jumbo
            const idx = self.findSlabIndex(padded_size);
            const slab = self.slabs[idx] orelse blk: {
                const new_slab = self.backing_allocator.create(Slab);
                new_slab.next = null;
                new_slab.size = padded_size;
                self.slabs[idx] = new_slab;
                break :blk new_slab;
            };
            const result = slab.alloc() catch unreachable;
            if (slab.isFull()) {
                self.slabs[idx] = slab.next;
                slab.next = full_signal;
            }

            return result[0..std.mem.alignAllocLen(padded_size, n, len_align)];
        }

        fn resize(allocator: *Allocator, buf: []u8, new_size: usize, len_align: u29) Allocator.Error!usize {
            const self = @fieldParentPtr(Self, "allocator", allocator);

            const slab = Slab.fromMemPtr(buf.ptr);
            if (new_size == 0) {
                slab.free(buf.ptr);
                if (slab.next == full_signal) {
                    const idx = self.findSlabIndex(slab.size);
                    slab.next = self.slabs[idx];
                    self.slabs[idx] = slab;
                }
                return 0;
            }

            const padded_new_size = self.padToSize(new_size);
            if (padded_new_size > slab.size) {
                return error.OutOfMemory;
            }

            return result[0..std.mem.alignAllocLen(padded_new_size, n, len_align)];
        }
    };
}

fn divCeil(comptime T: type, numerator: T, denominator: T) T {
    return (numerator + denominator - 1) / denominator;
}

test "divCeil" {
    std.testing.expectEqual(@as(u32, 0), divCeil(u32, 0, 64));
    std.testing.expectEqual(@as(u32, 1), divCeil(u32, 1, 64));
    std.testing.expectEqual(@as(u32, 1), divCeil(u32, 64, 64));
    std.testing.expectEqual(@as(u32, 2), divCeil(u32, 65, 64));
}

test "Slab.elementAt" {
    {
        var slab = ZeeAllocDefaults.Slab{ .element_size = 16384 };

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
        var slab = ZeeAllocDefaults.Slab{ .element_size = 128 };

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
        var slab = ZeeAllocDefaults.Slab{ .element_size = 64 };
        std.testing.expectEqual(@as(usize, 3), slab.headerElements());

        var element = slab.elementAt(3);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(3 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));

        element = slab.elementAt(5);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(5 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));
    }
    {
        var slab = ZeeAllocDefaults.Slab{ .element_size = 4 };
        std.testing.expectEqual(@as(usize, 513), slab.headerElements());

        var element = slab.elementAt(513);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(513 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));

        element = slab.elementAt(1023);
        std.testing.expectEqual(slab.element_size, element.len);
        std.testing.expectEqual(1023 * slab.element_size, @ptrToInt(element.ptr) - @ptrToInt(&slab));
    }
}

test "Slab.freeBlocks" {
    {
        var slab = ZeeAllocDefaults.Slab{ .element_size = 16384 };

        const blocks = slab.freeBlocks();
        std.testing.expectEqual(@as(usize, 1), blocks.len);
        std.testing.expectEqual(@ptrToInt(&slab.pad), @ptrToInt(blocks.ptr));
    }
    {
        var slab = ZeeAllocDefaults.Slab{ .element_size = 128 };

        const blocks = slab.freeBlocks();
        std.testing.expectEqual(@as(usize, 8), blocks.len);
        std.testing.expectEqual(@ptrToInt(&slab.pad), @ptrToInt(blocks.ptr));
    }
}
