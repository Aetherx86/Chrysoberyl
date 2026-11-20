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

## File Format, Codecs and Queries (0.2.0)

```bash
# Generate a sample table with automatic per-column codec selection and 5% nulls
./zig-out/bin/chrysoberyl generate sales.chry --rows 1000000 --encoding auto --null-pct 5

# Schema, codecs, null counts and column statistics, with checksum verification
./zig-out/bin/chrysoberyl inspect sales.chry --verify

# Vectorized filter and aggregate, evaluated directly on compressed columns
./zig-out/bin/chrysoberyl query sales.chry --where 'category==3' --where 'quantity[10..20]' --agg quantity --json
./zig-out/bin/chrysoberyl query sales.chry --where 'price:null' --where 'category<2' --or --limit 10
```

Format v2 stores a named schema, a validity bitmap per column, 64-byte aligned column payloads and a CRC32 checksum. Each column is stored as plain, run-length or delta plus ZigZag data. Files open through `mmap` without copying, and `TableView` validates every offset and enum before it exposes a column.

## License

MIT License. Copyright (c) 2026 Jeong Hoon Kim.
