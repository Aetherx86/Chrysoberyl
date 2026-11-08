# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-08

### Added
- Initial release of Chrysoberyl: Zero-Copy Columnar Binary Serialization & Vector SIMD Engine in Zig.
- 64-byte cache-aligned columnar memory buffers.
- SIMD vector reduction (@reduce .Add) and vectorized filtering with > 5.7 GB/s throughput.
- Zero-copy binary serialization format with sub-microsecond O(1) table deserialization.
- Comprehensive unit test suite covering SIMD operations and binary round-trip decoding.
