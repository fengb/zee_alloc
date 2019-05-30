# zee_alloc — *zig wee allocator*

A tiny allocator primarily for use in WebAssembly.

Inspired by Rust's [wee_alloc](https://github.com/rustwasm/wee_alloc) design goals.

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
