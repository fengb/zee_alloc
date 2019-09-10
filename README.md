# zee_alloc — *zig wee allocator*

A tiny general purpose allocator targeting WebAssembly.

This allocator has not been well tested. Use at your own peril.

### Getting Started

In zig:

```zig
const zee_alloc = @import("zee_alloc");

pub fn foo() void {
    var mem = zee_alloc.ZeeAllocDefaults.wasm_allocator.alloc(u8, 1000);
    defer zee_alloc.ZeeAllocDefaults.wasm_allocator.free(mem);
}
```

Exporting into wasm:

```zig
const zee_alloc = @import("zee_alloc");

comptime {
    (zee_alloc.ExportC{
        .allocator = zee_alloc.ZeeAllocDefaults.wasm_allocator,
        .malloc = true,
        .free = true,
        .realloc = false,
        .calloc = false,
    }).run();
  }
```

### Goals

_(inspired by Rust's [wee_alloc](https://github.com/rustwasm/wee_alloc))_

1. Tiny compiled output
2. Tiny compiled output x2
3. Malloc/free compatibility
4. Avoid long-term fragmentation
5. Reasonably fast alloc and free
6. Code simplicity — probably goes in hand with tiny output

**Non-goals**

- Debugging — this library probably will never do a good job identifying errors.
  Zig has a great [debug allocator](https://github.com/andrewrk/zig-general-purpose-allocator)
  in the works, and zig programs should be able to easily swap allocators.
- Compact memory — fixed allocation frames are used for speed and simplicity.
  Memory usage will never be optimum unless the underlying algorithm completely changes
- Thread performance — wasm is single-threaded

### Benchmarks

```
Benchmark                                   Mean(ns)
----------------------------------------------------
DirectAllocator.0                              50842
DirectAllocator.1                              98343
DirectAllocator.2                             203980
DirectAllocator.3                              49908
DirectAllocator.4                             103635
DirectAllocator.5                             195941
DirectAllocator.6                              47367
DirectAllocator.7                             101733
DirectAllocator.8                             202697
Arena_DirectAllocator.0                        11837
Arena_DirectAllocator.1                        19591
Arena_DirectAllocator.2                        30689
Arena_DirectAllocator.3                        30916
Arena_DirectAllocator.4                        52425
Arena_DirectAllocator.5                        75673
Arena_DirectAllocator.6                        44874
Arena_DirectAllocator.7                        67557
Arena_DirectAllocator.8                        96276
ZeeAlloc_DirectAllocator.0                     15892
ZeeAlloc_DirectAllocator.1                     24435
ZeeAlloc_DirectAllocator.2                     49564
ZeeAlloc_DirectAllocator.3                     26656
ZeeAlloc_DirectAllocator.4                     52462
ZeeAlloc_DirectAllocator.5                     93854
ZeeAlloc_DirectAllocator.6                     51493
ZeeAlloc_DirectAllocator.7                     95223
ZeeAlloc_DirectAllocator.8                    250187
FixedBufferAllocator.0                           177
FixedBufferAllocator.1                           412
FixedBufferAllocator.2                          1006
FixedBufferAllocator.3                           296
FixedBufferAllocator.4                           785
FixedBufferAllocator.5                          1721
FixedBufferAllocator.6                           848
FixedBufferAllocator.7                          1546
FixedBufferAllocator.8                          3331
Arena_FixedBufferAllocator.0                     299
Arena_FixedBufferAllocator.1                     573
Arena_FixedBufferAllocator.2                    1624
Arena_FixedBufferAllocator.3                    1115
Arena_FixedBufferAllocator.4                    1868
Arena_FixedBufferAllocator.5                    4422
Arena_FixedBufferAllocator.6                    1706
Arena_FixedBufferAllocator.7                    3389
Arena_FixedBufferAllocator.8                    8430
ZeeAlloc_FixedBufferAllocator.0                  232
ZeeAlloc_FixedBufferAllocator.1                  577
ZeeAlloc_FixedBufferAllocator.2                 1165
ZeeAlloc_FixedBufferAllocator.3                  443
ZeeAlloc_FixedBufferAllocator.4                  907
ZeeAlloc_FixedBufferAllocator.5                 1848
ZeeAlloc_FixedBufferAllocator.6                  907
ZeeAlloc_FixedBufferAllocator.7                 1721
ZeeAlloc_FixedBufferAllocator.8                 3836
```

### Architecture — [Buddy memory allocation](https://en.wikipedia.org/wiki/Buddy_memory_allocation)

_Caveat: I knew **nothing** about memory allocation when starting this project.
Any semblence of competence is merely a coincidence._

```
idx frame_size
 0  >65536  jumbo
 1   65536  wasm page size
 2   32768
 3   16384
 4    8192
 5    4096
 6    2048
 7    1024
 8     512
 9     256
10     128
11      64
12      32
13      16  smallest frame
```

Size order is reversed because 0 and 1 are special.  I believe counting down had
slightly better semantics than counting up but I haven't actually tested it.

Wasm only allows for allocating entire pages (64K) at a time. Current architecture is
heavily influenced by this behavior. In a real OS, the page size is much smaller at 4K.
Everything should work as expected even if it does not run as efficient as possible.

Each allocation frame consists of 2 usizes of metadata: the frame size and a pointer to
the next free node. This enables some rudimentary debugging as well as a simple lookup
when we only have the allocated data-block (especially important for C compatibility).

For allocations <=64K in size, we find the smallest usable free frame.  If it's
bigger than necessary, we grab the smallest power of 2 we need and resize the rest
to toss back as free nodes. This is O(log k) which is O(1).

For allocations >64K, we iterate through list 0 to find a matching size, O(n).
Free jumbo frames are never divided into smaller allocations.

ZeeAlloc only supports pointer alignment at 2x usize — 8 bytes in wasm. There
are a few ideas to expand this to up-to half page_size but nothing concrete yet.
