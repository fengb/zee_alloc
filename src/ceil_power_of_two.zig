// Source: https://github.com/ziglang/zig/issues/2426

const std = @import("std");

// naive implementation
// this can overflow (i.e. ceilPowerOfTwo(u4, 9))
export fn ceilPowerOfTwo0(value: usize) usize {
    if (value <= 2) return value;
    var power: usize = 1;
    while (power < value)
        power *= 2;
    return power;
}

// using log2_int_ceil
// this can overflow (i.e. ceilPowerOfTwo(u4, 9))
export fn ceilPowerOfTwo1(value: usize) usize {
    if (value <= 2) return value;
    const log2_val = std.math.log2_int_ceil(usize, value);
    return usize(1) << log2_val;
}

// using bit shifting with special case for value <= 2
// this can overflow (i.e. ceilPowerOfTwo(u4, 9))
export fn ceilPowerOfTwo2(value: usize) usize {
    if (value <= 2) return value;

    var x = value - 1;

    comptime var i = 1;
    inline while (usize.bit_count > i) : (i *= 2) {
        x |= (x >> i);
    }

    return x + 1;
}

// using bit shifting with wrapping arithmetic operators to avoid special case
// ceilPowerOfTwo(u4, 9) will erroneously return 0 due to wrapping
export fn ceilPowerOfTwo3(value: usize) usize {
    var x = value -% 1;

    comptime var i = 1;
    inline while (usize.bit_count > i) : (i *= 2) {
        x |= (x >> i);
    }

    return x +% 1;
}

// using @clz
// this can overflow (i.e. ceilPowerOfTwo(u4, 9)) with "integer cast truncated bits"
export fn ceilPowerOfTwo4(value: usize) usize {
    if (value <= 2) return value;
    const Shift = comptime std.math.Log2Int(usize);
    return usize(1) << @intCast(Shift, usize.bit_count - @clz(usize, value - 1));
}
