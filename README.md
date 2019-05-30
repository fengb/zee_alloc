# zee_alloc — *zig wee allocator*

A tiny general purpose allocator targeting WebAssembly.

This allocator has not been well tested. Use at your own peril.

### Goals

_inspired by Rust's [wee_alloc](https://github.com/rustwasm/wee_alloc)_

1. Tiny compiled output
2. Tiny compiled output x2
3. Avoid long-term fragmentation
4. Reasonably fast alloc and free
5. Code simplicity — probably goes in hand with tiny output

**Non-goals**

- Debugging — this library probably will never do a good job identifying errors.
  Zig has a great [debug allocator](https://github.com/andrewrk/zig-general-purpose-allocator)
  in the works, and any program should be able to swap allocations
- Compact memory — fixed allocation blocks are used for speed and simplicity.
  Memory usage will never be optimum unless the underlying algorithm completely changes

### Benchmarks

```
Benchmark                                   Mean(ns)
----------------------------------------------------
DirectAllocator.0                              49826
DirectAllocator.1                              94288
DirectAllocator.2                             187607
DirectAllocator.3                              47901
DirectAllocator.4                              94792
DirectAllocator.5                             190626
DirectAllocator.6                              48282
DirectAllocator.7                              94981
DirectAllocator.8                             188808
Arena_DirectAllocator.0                        12570
Arena_DirectAllocator.1                        21287
Arena_DirectAllocator.2                        33345
Arena_DirectAllocator.3                        31358
Arena_DirectAllocator.4                        49282
Arena_DirectAllocator.5                        72057
Arena_DirectAllocator.6                        43083
Arena_DirectAllocator.7                        66272
Arena_DirectAllocator.8                        99620
ZeeAlloc_DirectAllocator.0                     15479
ZeeAlloc_DirectAllocator.1                     24774
ZeeAlloc_DirectAllocator.2                     46282
ZeeAlloc_DirectAllocator.3                     24442
ZeeAlloc_DirectAllocator.4                     43567
ZeeAlloc_DirectAllocator.5                     82898
ZeeAlloc_DirectAllocator.6                     38162
ZeeAlloc_DirectAllocator.7                     77623
ZeeAlloc_DirectAllocator.8                    158367
FixedBufferAllocator.0                           768
FixedBufferAllocator.1                          1555
FixedBufferAllocator.2                          3382
FixedBufferAllocator.3                           980
FixedBufferAllocator.4                          2034
FixedBufferAllocator.5                          3965
FixedBufferAllocator.6                          1334
FixedBufferAllocator.7                          2668
FixedBufferAllocator.8                          4997
Arena_FixedBufferAllocator.0                    1237
Arena_FixedBufferAllocator.1                    2299
Arena_FixedBufferAllocator.2                    4190
Arena_FixedBufferAllocator.3                    2036
Arena_FixedBufferAllocator.4                    6210
Arena_FixedBufferAllocator.5                    6485
Arena_FixedBufferAllocator.6                    2754
Arena_FixedBufferAllocator.7                    5002
Arena_FixedBufferAllocator.8                    8905
ZeeAlloc_FixedBufferAllocator.0                 2831
ZeeAlloc_FixedBufferAllocator.1                 4857
ZeeAlloc_FixedBufferAllocator.2                 8864
ZeeAlloc_FixedBufferAllocator.3                 3023
ZeeAlloc_FixedBufferAllocator.4                 5488
ZeeAlloc_FixedBufferAllocator.5                 9809
ZeeAlloc_FixedBufferAllocator.6                 2696
ZeeAlloc_FixedBufferAllocator.7                 5722
ZeeAlloc_FixedBufferAllocator.8                10091
```

### Architecture — [Buddy memory allocation](https://en.wikipedia.org/wiki/Buddy_memory_allocation)

```
idx block_size
 0  >64K  oversized
 1   64K  wasm page size
 2   32K
 3   16K
 4    8K
 5    4K
 6    2K
 7    1K
 8   512
 9   256
10   128
11    64
12    32
13    16
14     8
15     4  smallest block

-- unused nodes
```

Size order is reversed because 0 and 1 are special.  I believe counting down had
slightly better semantics than counting up but I haven't actually tested it.

Wasm only allows for allocating entire pages (64K) at a time. Current architecture is
heavily influenced by this behavior.

Upon initialization, we allocate an entire page for unused nodes (~5400). This is
rather extreme and we should tune the first page to have some actual usage space.

For allocations <=64K in size, we find the smallest usable free block.  If it's
bigger than necessary, we grab the smallest power of 2 we need and resize the rest
to toss back as free nodes. This is O(log k) which is O(1).

For allocations >64K, we iterate through list 0 to find a matching size, O(n).
Free oversized blocks are never used and divided by smaller allocations.

This only supports alignment up to a page size — 64K in wasm.  This ought to be
enough for anybody™.  Free nodes remember alignment but don't necessary preserve it,
so subsequent aligned allocations might trigger extra page allocations.  Since we use
the buddy system, blocks should be automatically aligned pretty well.

Currently, when a block is allocated, it "disappears" from the allocator entirely
and its node returns back to the "unused" pool.  In theory this is more efficient
since we can get away with fewer nodes, but it also means we can't track allocations.

In a real OS, the page size is much smaller at 4K. Everything should work as expected
even if it's not as efficient as possible.
