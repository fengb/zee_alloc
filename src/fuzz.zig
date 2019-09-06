// https://github.com/andrewrk/zig-general-purpose-allocator/blob/520b396/test/fuzz.zig

const std = @import("std");
const zee_alloc = @import("main.zig");

const test_config = zee_alloc.Config{};

test "fuzz testing" {
    var za = zee_alloc.ZeeAllocDefaults.init(std.heap.direct_allocator);
    const allocator = &za.allocator;

    const seed = 0x1234;
    var prng = std.rand.DefaultPrng.init(seed);
    const rand = &prng.random;

    var allocated_n: usize = 0;
    var freed_n: usize = 0;

    const Free = struct {
        slice: []u8,
        it_index: usize,
    };

    var free_queue = std.ArrayList(Free).init(allocator);
    var it_index: usize = 0;

    while (true) : (it_index += 1) {
        const is_small = rand.boolean();
        const size = if (is_small)
            rand.uintLessThanBiased(usize, std.mem.page_size)
        else
            std.mem.page_size + rand.uintLessThanBiased(usize, 10 * 1024 * 1024);

        const iterations_until_free = rand.uintLessThanBiased(usize, 100);
        const slice = allocator.alloc(u8, size) catch unreachable;
        allocated_n += size;
        free_queue.append(Free{
            .slice = slice,
            .it_index = it_index + iterations_until_free,
        }) catch unreachable;

        var free_i: usize = 0;
        while (free_i < free_queue.len) {
            const item = &free_queue.toSlice()[free_i];
            if (item.it_index <= it_index) {
                // free time
                allocator.free(item.slice);
                freed_n += item.slice.len;
                _ = free_queue.swapRemove(free_i);
                continue;
            }
            free_i += 1;
        }
        std.debug.warn("index={} allocated: {Bi:2} freed: {Bi:2}\n", it_index, allocated_n, freed_n);
        //za.debugDump();
    }
}
