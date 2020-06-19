const builtin = @import("builtin");
const std = @import("std");

const debug = std.debug;
const io = std.io;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const time = std.time;

const Decl = builtin.TypeInfo.Declaration;

pub fn benchmark(comptime B: type) !void {
    const args = if (@hasDecl(B, "args")) B.args else [_]void{{}};
    const iterations: u32 = if (@hasDecl(B, "iterations")) B.iterations else 100000;

    comptime var max_fn_name_len = 0;
    const functions = comptime blk: {
        var res: []const Decl = &[_]Decl{};
        for (meta.declarations(B)) |decl| {
            if (decl.data != Decl.Data.Fn)
                continue;

            if (max_fn_name_len < decl.name.len)
                max_fn_name_len = decl.name.len;
            res = res ++ [_]Decl{decl};
        }

        break :blk res;
    };
    if (functions.len == 0)
        @compileError("No benchmarks to run.");

    const max_name_spaces = comptime math.max(max_fn_name_len + digits(u64, 10, args.len) + 1, "Benchmark".len);

    var timer = try time.Timer.start();
    debug.warn("\n", .{});
    debug.warn("Benchmark", .{});
    nTimes(' ', (max_name_spaces - "Benchmark".len) + 1);
    nTimes(' ', digits(u64, 10, math.maxInt(u64)) - "Mean(ns)".len);
    debug.warn("Mean(ns)\n", .{});
    nTimes('-', max_name_spaces + digits(u64, 10, math.maxInt(u64)) + 1);
    debug.warn("\n", .{});

    inline for (functions) |def| {
        for (args) |arg, index| {
            var runtime_sum: u128 = 0;

            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                timer.reset();

                const res = switch (@TypeOf(arg)) {
                    void => @field(B, def.name)(),
                    else => @field(B, def.name)(arg),
                };

                const runtime = timer.read();
                runtime_sum += runtime;
                doNotOptimize(res);
            }

            const runtime_mean = @intCast(u64, runtime_sum / iterations);

            debug.warn("{}.{}", .{ def.name, index });
            nTimes(' ', (max_name_spaces - (def.name.len + digits(u64, 10, index) + 1)) + 1);
            nTimes(' ', digits(u64, 10, math.maxInt(u64)) - digits(u64, 10, runtime_mean));
            debug.warn("{}\n", .{runtime_mean});
        }
    }
}

/// Pretend to use the value so the optimizer cant optimize it out.
fn doNotOptimize(val: var) void {
    const T = @TypeOf(val);
    var store: T = undefined;
    @ptrCast(*volatile T, &store).* = val;
}

fn digits(comptime N: type, comptime base: comptime_int, n: N) usize {
    comptime var res = 1;
    comptime var check = base;

    inline while (check <= math.maxInt(N)) : ({
        check *= base;
        res += 1;
    }) {
        if (n < check)
            return res;
    }

    return res;
}

fn nTimes(c: u8, times: usize) void {
    var i: usize = 0;
    while (i < times) : (i += 1)
        debug.warn("{c}", .{c});
}

const zee_alloc = @import("main.zig");
var test_buf: [1024 * 1024]u8 = undefined;
test "ZeeAlloc benchmark" {
    try benchmark(struct {
        const Arg = struct {
            num: usize,
            size: usize,

            fn benchAllocator(a: Arg, allocator: *std.mem.Allocator, comptime free: bool) !void {
                var i: usize = 0;
                while (i < a.num) : (i += 1) {
                    const bytes = try allocator.alloc(u8, a.size);
                    defer if (free) allocator.free(bytes);
                }
            }
        };

        pub const args = [_]Arg{
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
            var za = zee_alloc.ZeeAllocDefaults.init(&fba.allocator);

            a.benchAllocator(&za.allocator, false) catch unreachable;
        }

        pub fn PageAllocator(a: Arg) void {
            a.benchAllocator(std.heap.page_allocator, true) catch unreachable;
        }

        pub fn Arena_PageAllocator(a: Arg) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            a.benchAllocator(&arena.allocator, false) catch unreachable;
        }

        pub fn ZeeAlloc_PageAllocator(a: Arg) void {
            var za = zee_alloc.ZeeAllocDefaults.init(std.heap.page_allocator);

            a.benchAllocator(&za.allocator, false) catch unreachable;
        }
    });
}
