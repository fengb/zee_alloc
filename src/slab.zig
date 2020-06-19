const std = @import("std");

pub const Config = struct {
    /// ZeeAlloc will request a multiple of `page_size` from the backing allocator.
    /// **Must** be a power of two.
    page_size: usize = std.math.max(std.mem.page_size, 65536), // 64K ought to be enough for everybody
};

pub fn ZeeAlloc(comptime conf: Config) type {
    const Slab = extern struct {
        const alignment = std.mem.page_size;

        next: ?*Slab align(alignment) = null,
        size: usize,
        data: [conf.page_size - 2 * @sizeOf(usize)]u8,

        fn fromMemPtr(ptr: *u8) *Slab {
            return @intToPtr(*Slab, @ptrToInt(ptr));
        }
    };

    return struct {
        const Self = @This();

        slabs: [8]?*Slab, // slab[0] = 4 bytes, slab[1] = 8 bytes, etc.
        backing_allocator: *std.mem.Allocator,

        allocator: Allocator = Allocator{
            .allocFn = alloc,
            .resizeFn = resize,
        },

        pub fn init(allocator: *std.mem.Allocator) Self {
            return .{
                .slabs = [_]?*Slab{null} ** 8,
                .backing_allocator = allocator,
            };
        }

        fn alloc(allocator: *Allocator, n: usize, ptr_align: u29, len_align: u29) Allocator.Error![]u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            const padded_size = self.padToSize(n);

            const result = self.findFreeMem(padded_size) orelse blk: {
                const new_slab = try self.allocSlab(padded_size);
                break :blk new_slab.alloc() catch unreachable;
            };

            return result[0..std.mem.alignAllocLen(padded_size, n, len_align)];
        }

        fn resize(allocator: *Allocator, buf: []u8, new_size: usize, len_align: u29) Allocator.Error!usize {
            const self = @fieldParentPtr(Self, "allocator", allocator);

            const slab = Slab.fromMemPtr(buf.ptr);
            if (new_size == 0) {
                slab.free(buf);
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
