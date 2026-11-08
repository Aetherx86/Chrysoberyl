# Chrysoberyl

Chrysoberyl is a zero-copy columnar binary serialization format and SIMD vector execution engine written in pure Zig.

## Overview

Modern data processing requires high memory locality and zero deserialization overhead. Chrysoberyl stores tabular data in contiguous 64-byte cache-line aligned columnar arrays. By decoupling schema definitions from byte layout, Chrysoberyl enables direct memory-mapped access (`mmap`) where deserialization completes in sub-microsecond O(1) time without copying memory buffers.

## Architecture

- **64-Byte Cache Alignment**: Guarantees optimal hardware prefetching and zero unaligned memory access penalties across L1/L2 caches.
- **Hardware SIMD Acceleration**: Uses Zig `@Vector(16, i32)` and `@reduce` primitives to execute columnar filters and aggregations at wire speed.
- **Zero-Copy Binary Format**: Formats columns sequentially behind a fixed-size header (`TableHeader` + `ColumnHeader[]`), allowing consumers to slice directly into raw byte buffers.

## Performance

- **SIMD Reduction Throughput**: > 5.7 GB/s over 1,000,000 rows.
- **Zero-Copy View Initialization**: ~791 nanoseconds for 1,000,000 rows.

## Building

```bash
# Run unit tests
zig build test

# Build optimized binary
zig build -Doptimize=ReleaseFast
```

## Usage

```bash
# Run internal SIMD and zero-copy benchmark
./zig-out/bin/chrysoberyl bench
```

## License

MIT License. Copyright (c) 2026 Jeong Hoon Kim.
