const std = @import("std");

pub const Config = struct {
    /// ZeeAlloc will request a multiple of `page_size` from the backing allocator.
    /// **Must** be a power of two.
    page_size: usize = std.math.max(std.mem.page_size, 65536), // 64K ought to be enough for everybody
};

pub fn ZeeAlloc(comptime conf: Config) type {
    const Slab = extern struct {
        next: ?*Slab align(std.mem.page_size) = null,
        size: usize,
        pad: [conf.page_size - 2 * @sizeOf(usize)]u8,

        fn fromMemPtr(ptr: [*]u8) *Slab {
            const addr = std.mem.alignBackward(@ptrToInt(ptr), conf.page_size);
            return @intToPtr(*Slab, addr);
        }

        fn meta(self: *Slab) []u64 {
            return &[0]u64{};
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

    return struct {
        const Self = @This();

        slabs: [13]?*Slab, // slab[0] = 4 bytes, slab[1] = 8 bytes, etc.
        backing_allocator: *std.mem.Allocator,

        allocator: Allocator = Allocator{
            .allocFn = alloc,
            .resizeFn = resize,
        },

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
