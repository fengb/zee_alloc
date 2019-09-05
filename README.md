# zee_alloc — *zig wee allocator*

A tiny general purpose allocator targeting WebAssembly.

This allocator has not been well tested. Use at your own peril.

### Goals

_(inspired by Rust's [wee_alloc](https://github.com/rustwasm/wee_alloc))_

1. Tiny compiled output
2. Tiny compiled output x2
3. Avoid long-term fragmentation
4. Reasonably fast alloc and free
5. Code simplicity — probably goes in hand with tiny output

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
DirectAllocator.0                              48554
DirectAllocator.1                              95779
DirectAllocator.2                             190130
DirectAllocator.3                              47516
DirectAllocator.4                              95769
DirectAllocator.5                             194154
DirectAllocator.6                              48379
DirectAllocator.7                              96468
DirectAllocator.8                             197277
Arena_DirectAllocator.0                        12720
Arena_DirectAllocator.1                        21424
Arena_DirectAllocator.2                        32831
Arena_DirectAllocator.3                        29824
Arena_DirectAllocator.4                        48563
Arena_DirectAllocator.5                        71561
Arena_DirectAllocator.6                        41373
Arena_DirectAllocator.7                        64670
Arena_DirectAllocator.8                       100955
ZeeAlloc_DirectAllocator.0                     18631
ZeeAlloc_DirectAllocator.1                     37117
ZeeAlloc_DirectAllocator.2                     79334
ZeeAlloc_DirectAllocator.3                     36779
ZeeAlloc_DirectAllocator.4                     72324
ZeeAlloc_DirectAllocator.5                    148178
ZeeAlloc_DirectAllocator.6                     55344
ZeeAlloc_DirectAllocator.7                    113971
ZeeAlloc_DirectAllocator.8                    226724
FixedBufferAllocator.0                           725
FixedBufferAllocator.1                          1470
FixedBufferAllocator.2                          3186
FixedBufferAllocator.3                           904
FixedBufferAllocator.4                          1972
FixedBufferAllocator.5                          3770
FixedBufferAllocator.6                          1280
FixedBufferAllocator.7                          2532
FixedBufferAllocator.8                          4989
Arena_FixedBufferAllocator.0                    1185
Arena_FixedBufferAllocator.1                    2165
Arena_FixedBufferAllocator.2                    4423
Arena_FixedBufferAllocator.3                    2076
Arena_FixedBufferAllocator.4                    3701
Arena_FixedBufferAllocator.5                    7778
Arena_FixedBufferAllocator.6                    2693
Arena_FixedBufferAllocator.7                    4982
Arena_FixedBufferAllocator.8                    8757
ZeeAlloc_FixedBufferAllocator.0                 2190
ZeeAlloc_FixedBufferAllocator.1                 5087
ZeeAlloc_FixedBufferAllocator.2                 9136
ZeeAlloc_FixedBufferAllocator.3                 2619
ZeeAlloc_FixedBufferAllocator.4                 5169
ZeeAlloc_FixedBufferAllocator.5                10025
ZeeAlloc_FixedBufferAllocator.6                 3124
ZeeAlloc_FixedBufferAllocator.7                 6378
ZeeAlloc_FixedBufferAllocator.8                14989
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

ZeeAlloc only supports pointer alignment up to 2x usize — 8 bytes in wasm. There
are a few ideas to expand this to up-to half page_size but nothing concrete yet.
