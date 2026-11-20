# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-20

### Added
- Format v2: named multi-type schemas (`int32`, `int64`, `float64`), more than eight columns, per-column validity bitmaps for nulls, and a CRC32 checksum. v1 files still load.
- Column codecs: run-length encoding and delta plus ZigZag encoding, with automatic per-column selection. Decoding uses a SIMD Hillis-Steele prefix sum.
- Compressed-domain aggregation (`rleSum`) that sums RLE columns without decoding them.
- Query engine (`src/query.zig`): SIMD predicate evaluation with `==`, `!=`, `<`, `<=`, `>`, `>=`, inclusive ranges and null tests, AND/OR combination, and filtered aggregation. It runs transparently over compressed columns.
- `MappedTable`: true `mmap` zero-copy file opening.
- Slicing-by-8 CRC32, verified bit-identical to `std.hash.Crc32`.
- CLI subcommands `generate`, `inspect --verify`, `query`, `verify` and `bench`, with `--json` output.
- `Int64Column` and `Float64Column` SIMD kernels with NaN handling and dot product. `Int32Column.sumSimd` widens to avoid 32-bit overflow.
- Hardening: `TableView` rejects malformed, truncated, unaligned and invalid-enum buffers, and header corruption fuzzing never panics.
- Differential tests that check every SIMD kernel and the query engine against scalar references across row counts and null densities.

## [0.1.0] - 2026-11-08

### Added
- Initial release of Chrysoberyl: Zero-Copy Columnar Binary Serialization & Vector SIMD Engine in Zig.
- 64-byte cache-aligned columnar memory buffers.
- SIMD vector reduction (@reduce .Add) and vectorized filtering with > 5.7 GB/s throughput.
- Zero-copy binary serialization format with sub-microsecond O(1) table deserialization.
- Comprehensive unit test suite covering SIMD operations and binary round-trip decoding.
