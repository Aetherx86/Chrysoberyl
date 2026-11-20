const std = @import("std");
const builtin = @import("builtin");

pub const FORMAT_MAGIC = [4]u8{ 'C', 'H', 'R', 'Y' };
pub const FORMAT_VERSION_V1: u32 = 1;
pub const FORMAT_VERSION_V2: u32 = 2;
pub const CACHE_LINE_BYTES: usize = 64;

pub const FLAG_HAS_CHECKSUM: u32 = 1 << 0;
pub const FLAG_HAS_SCHEMA: u32 = 1 << 1;

pub const ColumnType = enum(u32) {
    int32 = 1,
    int64 = 2,
    float64 = 3,

    pub fn fromRaw(raw: u32) !ColumnType {
        return switch (raw) {
            1 => .int32,
            2 => .int64,
            3 => .float64,
            else => error.InvalidColumnType,
        };
    }

    pub fn elementSize(self: ColumnType) usize {
        return switch (self) {
            .int32 => @sizeOf(i32),
            .int64 => @sizeOf(i64),
            .float64 => @sizeOf(f64),
        };
    }

    pub fn elementAlign(self: ColumnType) usize {
        return switch (self) {
            .int32 => @alignOf(i32),
            .int64 => @alignOf(i64),
            .float64 => @alignOf(f64),
        };
    }

    pub fn name(self: ColumnType) []const u8 {
        return switch (self) {
            .int32 => "int32",
            .int64 => "int64",
            .float64 => "float64",
        };
    }
};

pub const ColumnEncoding = enum(u32) {
    plain = 0,
    rle = 1,
    delta = 2,

    pub fn fromRaw(raw: u32) !ColumnEncoding {
        return switch (raw) {
            0 => .plain,
            1 => .rle,
            2 => .delta,
            else => error.InvalidColumnEncoding,
        };
    }

    pub fn name(self: ColumnEncoding) []const u8 {
        return switch (self) {
            .plain => "plain",
            .rle => "rle",
            .delta => "delta",
        };
    }
};

/// Legacy v1 per-column header (24 bytes). Preserved for wire compatibility.
pub const ColumnHeader = extern struct {
    col_type: ColumnType,
    length: u32,
    data_offset: u64,
    null_count: u32,
    reserved: u32 = 0,
};

/// Fixed 16-byte file prefix shared by v1 and v2 formats.
pub const TableHeader = extern struct {
    magic: [4]u8 = FORMAT_MAGIC,
    version: u32 = FORMAT_VERSION_V1,
    row_count: u32,
    column_count: u32,
};

/// 48-byte v2 extension immediately following TableHeader (combined header = 64 bytes).
pub const TableHeaderExt = extern struct {
    flags: u32 = 0,
    checksum_crc32: u32 = 0,
    total_bytes: u64 = 0,
    schema_offset: u64 = 0,
    schema_size: u64 = 0,
    reserved: [16]u8 = @splat(0),
};

/// 48-byte v2 per-column header supporting 64-byte aligned payloads, validity bitmaps,
/// schema names, and columnar encodings.
pub const ColumnHeaderV2 = extern struct {
    col_type_raw: u32,
    encoding_raw: u32,
    length: u32,
    null_count: u32,
    data_offset: u64,
    data_byte_len: u64,
    validity_offset: u64,
    name_offset: u32,
    name_len: u32,
};

comptime {
    std.debug.assert(@sizeOf(TableHeader) == 16);
    std.debug.assert(@sizeOf(TableHeaderExt) == 48);
    std.debug.assert(@sizeOf(TableHeader) + @sizeOf(TableHeaderExt) == CACHE_LINE_BYTES);
    std.debug.assert(@sizeOf(ColumnHeader) == 24);
    std.debug.assert(@sizeOf(ColumnHeaderV2) == 48);
}

pub const CompareOp = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    pub fn symbol(self: CompareOp) []const u8 {
        return switch (self) {
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
        };
    }

    pub inline fn evalScalar(comptime T: type, op: CompareOp, lhs: T, rhs: T) bool {
        return switch (op) {
            .eq => lhs == rhs,
            .ne => lhs != rhs,
            .lt => lhs < rhs,
            .le => lhs <= rhs,
            .gt => lhs > rhs,
            .ge => lhs >= rhs,
        };
    }

    pub inline fn evalVec(
        comptime VEC_SIZE: usize,
        comptime T: type,
        op: CompareOp,
        lhs: @Vector(VEC_SIZE, T),
        rhs: @Vector(VEC_SIZE, T),
    ) @Vector(VEC_SIZE, bool) {
        return switch (op) {
            .eq => lhs == rhs,
            .ne => lhs != rhs,
            .lt => lhs < rhs,
            .le => lhs <= rhs,
            .gt => lhs > rhs,
            .ge => lhs >= rhs,
        };
    }
};

pub fn SumType(comptime T: type) type {
    return switch (T) {
        i32 => i64,
        i64 => i128,
        f64 => f64,
        else => @compileError("Unsupported Chrysoberyl column element type"),
    };
}

pub fn columnTypeFor(comptime T: type) ColumnType {
    return switch (T) {
        i32 => .int32,
        i64 => .int64,
        f64 => .float64,
        else => @compileError("Unsupported Chrysoberyl column element type"),
    };
}

pub fn VectorWidth(comptime T: type) comptime_int {
    return switch (T) {
        i32 => 16,
        i64 => 8,
        f64 => 8,
        else => @compileError("Unsupported Chrysoberyl column element type"),
    };
}

pub fn MinMax(comptime T: type) type {
    return struct {
        min: T,
        max: T,
    };
}

pub fn ColumnStats(comptime T: type) type {
    return struct {
        count: usize,
        valid_count: usize,
        null_count: usize,
        sum: SumType(T),
        min: ?T,
        max: ?T,
        mean: ?f64,
    };
}

pub inline fn alignUp64(value: usize) usize {
    return (value + (CACHE_LINE_BYTES - 1)) & ~@as(usize, CACHE_LINE_BYTES - 1);
}

pub inline fn validityByteLen(row_count: usize) usize {
    return (row_count + 7) / 8;
}

pub inline fn isBitValid(bitmap: []const u8, index: usize) bool {
    const byte = bitmap[index >> 3];
    const bit: u3 = @intCast(index & 7);
    return ((byte >> bit) & 1) != 0;
}

/// Counts zero (null) bits across `row_count` entries of an Arrow-style validity bitmap.
pub fn countNullBits(bitmap: []const u8, row_count: usize) usize {
    if (row_count == 0) return 0;
    const full_bytes = row_count >> 3;
    var valid_count: usize = 0;
    for (bitmap[0..full_bytes]) |b| {
        valid_count += @popCount(b);
    }
    const rem_bits: u3 = @intCast(row_count & 7);
    if (rem_bits != 0) {
        const mask: u8 = (@as(u8, 1) << rem_bits) - 1;
        valid_count += @popCount(bitmap[full_bytes] & mask);
    }
    return row_count - valid_count;
}

pub inline fn MaskInt(comptime VEC_SIZE: usize) type {
    return switch (VEC_SIZE) {
        8 => u8,
        16 => u16,
        else => @compileError("Unsupported SIMD mask width"),
    };
}

inline fn maskToBits(comptime VEC_SIZE: usize, mask: @Vector(VEC_SIZE, bool)) MaskInt(VEC_SIZE) {
    if (comptime builtin.cpu.arch.endian() == .little) {
        return @bitCast(mask);
    }
    var bits: MaskInt(VEC_SIZE) = 0;
    inline for (0..VEC_SIZE) |lane| {
        if (mask[lane]) {
            bits |= @as(MaskInt(VEC_SIZE), 1) << @intCast(lane);
        }
    }
    return bits;
}

inline fn bitsToMask(comptime VEC_SIZE: usize, bits: MaskInt(VEC_SIZE)) @Vector(VEC_SIZE, bool) {
    if (comptime builtin.cpu.arch.endian() == .little) {
        return @bitCast(bits);
    }
    var mask: @Vector(VEC_SIZE, bool) = @splat(false);
    inline for (0..VEC_SIZE) |lane| {
        mask[lane] = ((bits >> @intCast(lane)) & 1) != 0;
    }
    return mask;
}

inline fn loadValidBits(comptime VEC_SIZE: usize, bitmap: []const u8, row_start: usize) MaskInt(VEC_SIZE) {
    const byte_idx = row_start >> 3;
    return switch (VEC_SIZE) {
        16 => std.mem.readInt(u16, bitmap[byte_idx..][0..2], .little),
        8 => bitmap[byte_idx],
        else => @compileError("Unsupported SIMD vector width for validity bitmap"),
    };
}

/// Zero-copy typed column view supporting hardware SIMD reductions, filters, and joins
/// directly over memory-mapped or in-memory buffers.
pub fn ColumnSlice(comptime T: type) type {
    return struct {
        const Self = @This();
        const VEC_SIZE = VectorWidth(T);
        const S = SumType(T);
        const M = MaskInt(VEC_SIZE);

        data: []align(@alignOf(T)) const T,
        validity: ?[]const u8 = null,
        null_count: usize = 0,

        pub inline fn len(self: Self) usize {
            return self.data.len;
        }

        pub inline fn isValid(self: Self, index: usize) bool {
            if (index >= self.data.len) return false;
            if (self.validity) |bm| {
                return isBitValid(bm, index);
            }
            return true;
        }

        pub inline fn isNull(self: Self, index: usize) bool {
            if (index >= self.data.len) return true;
            return !self.isValid(index);
        }

        pub inline fn get(self: Self, index: usize) ?T {
            if (index >= self.data.len) return null;
            if (!self.isValid(index)) return null;
            return self.data[index];
        }

        /// Overflow-safe SIMD sum reduction (widening i32->i64, i64->i128; dual-lane f64).
        pub fn sumSimd(self: Self) S {
            var i: usize = 0;

            if (comptime T == i32) {
                var acc_lo: @Vector(8, i64) = @splat(0);
                var acc_hi: @Vector(8, i64) = @splat(0);

                if (self.validity) |bm| {
                    const zero_vec: @Vector(16, i32) = @splat(0);
                    while (i + 16 <= self.data.len) : (i += 16) {
                        const raw: @Vector(16, i32) = self.data[i..][0..16].*;
                        const valid_mask = bitsToMask(16, loadValidBits(16, bm, i));
                        const masked = @select(i32, valid_mask, raw, zero_vec);
                        const arr: [16]i32 = masked;
                        const lo: @Vector(8, i32) = arr[0..8].*;
                        const hi: @Vector(8, i32) = arr[8..16].*;
                        acc_lo += @as(@Vector(8, i64), lo);
                        acc_hi += @as(@Vector(8, i64), hi);
                    }
                    var total: i64 = @reduce(.Add, acc_lo + acc_hi);
                    while (i < self.data.len) : (i += 1) {
                        if (isBitValid(bm, i)) total += self.data[i];
                    }
                    return total;
                } else {
                    while (i + 16 <= self.data.len) : (i += 16) {
                        const lo: @Vector(8, i32) = self.data[i..][0..8].*;
                        const hi: @Vector(8, i32) = self.data[i + 8 ..][0..8].*;
                        acc_lo += @as(@Vector(8, i64), lo);
                        acc_hi += @as(@Vector(8, i64), hi);
                    }
                    var total: i64 = @reduce(.Add, acc_lo + acc_hi);
                    while (i < self.data.len) : (i += 1) {
                        total += self.data[i];
                    }
                    return total;
                }
            } else if (comptime T == i64) {
                var acc_lo: @Vector(4, i128) = @splat(0);
                var acc_hi: @Vector(4, i128) = @splat(0);

                if (self.validity) |bm| {
                    const zero_vec: @Vector(8, i64) = @splat(0);
                    while (i + 8 <= self.data.len) : (i += 8) {
                        const raw: @Vector(8, i64) = self.data[i..][0..8].*;
                        const valid_mask = bitsToMask(8, loadValidBits(8, bm, i));
                        const masked = @select(i64, valid_mask, raw, zero_vec);
                        const arr: [8]i64 = masked;
                        const lo: @Vector(4, i64) = arr[0..4].*;
                        const hi: @Vector(4, i64) = arr[4..8].*;
                        acc_lo += @as(@Vector(4, i128), lo);
                        acc_hi += @as(@Vector(4, i128), hi);
                    }
                    var total: i128 = @reduce(.Add, acc_lo + acc_hi);
                    while (i < self.data.len) : (i += 1) {
                        if (isBitValid(bm, i)) total += self.data[i];
                    }
                    return total;
                } else {
                    while (i + 8 <= self.data.len) : (i += 8) {
                        const lo: @Vector(4, i64) = self.data[i..][0..4].*;
                        const hi: @Vector(4, i64) = self.data[i + 4 ..][0..4].*;
                        acc_lo += @as(@Vector(4, i128), lo);
                        acc_hi += @as(@Vector(4, i128), hi);
                    }
                    var total: i128 = @reduce(.Add, acc_lo + acc_hi);
                    while (i < self.data.len) : (i += 1) {
                        total += self.data[i];
                    }
                    return total;
                }
            } else {
                var acc_lo: @Vector(4, f64) = @splat(0.0);
                var acc_hi: @Vector(4, f64) = @splat(0.0);

                if (self.validity) |bm| {
                    const zero_vec: @Vector(8, f64) = @splat(0.0);
                    while (i + 8 <= self.data.len) : (i += 8) {
                        const raw: @Vector(8, f64) = self.data[i..][0..8].*;
                        const valid_mask = bitsToMask(8, loadValidBits(8, bm, i));
                        const masked = @select(f64, valid_mask, raw, zero_vec);
                        const arr: [8]f64 = masked;
                        const lo: @Vector(4, f64) = arr[0..4].*;
                        const hi: @Vector(4, f64) = arr[4..8].*;
                        acc_lo += lo;
                        acc_hi += hi;
                    }
                    var total: f64 = @reduce(.Add, acc_lo + acc_hi);
                    while (i < self.data.len) : (i += 1) {
                        if (isBitValid(bm, i)) total += self.data[i];
                    }
                    return total;
                } else {
                    while (i + 8 <= self.data.len) : (i += 8) {
                        const lo: @Vector(4, f64) = self.data[i..][0..4].*;
                        const hi: @Vector(4, f64) = self.data[i + 4 ..][0..4].*;
                        acc_lo += lo;
                        acc_hi += hi;
                    }
                    var total: f64 = @reduce(.Add, acc_lo + acc_hi);
                    while (i < self.data.len) : (i += 1) {
                        total += self.data[i];
                    }
                    return total;
                }
            }
        }

        /// Single-pass SIMD minimum and maximum reduction.
        /// Skips null rows (and NaN values for float64); returns null if no valid value exists.
        pub fn minMaxSimd(self: Self) ?MinMax(T) {
            if (self.data.len == 0 or self.null_count >= self.data.len) return null;

            const min_identity: T = if (comptime T == f64) std.math.inf(f64) else std.math.maxInt(T);
            const max_identity: T = if (comptime T == f64) -std.math.inf(f64) else std.math.minInt(T);
            const min_id_vec: @Vector(VEC_SIZE, T) = @splat(min_identity);
            const max_id_vec: @Vector(VEC_SIZE, T) = @splat(max_identity);

            var min_vec: @Vector(VEC_SIZE, T) = min_id_vec;
            var max_vec: @Vector(VEC_SIZE, T) = max_id_vec;
            var has_valid = false;
            var i: usize = 0;

            if (comptime T == f64) {
                while (i + VEC_SIZE <= self.data.len) : (i += VEC_SIZE) {
                    const chunk: @Vector(VEC_SIZE, f64) = self.data[i..][0..VEC_SIZE].*;
                    var active_bits = maskToBits(VEC_SIZE, chunk == chunk);
                    if (self.validity) |bm| {
                        active_bits &= loadValidBits(VEC_SIZE, bm, i);
                    }
                    if (active_bits != 0) {
                        has_valid = true;
                        const active_mask = bitsToMask(VEC_SIZE, active_bits);
                        min_vec = @min(min_vec, @select(f64, active_mask, chunk, min_id_vec));
                        max_vec = @max(max_vec, @select(f64, active_mask, chunk, max_id_vec));
                    }
                }
            } else if (self.validity) |bm| {
                while (i + VEC_SIZE <= self.data.len) : (i += VEC_SIZE) {
                    const valid_bits = loadValidBits(VEC_SIZE, bm, i);
                    if (valid_bits != 0) {
                        has_valid = true;
                        const chunk: @Vector(VEC_SIZE, T) = self.data[i..][0..VEC_SIZE].*;
                        const valid_mask = bitsToMask(VEC_SIZE, valid_bits);
                        min_vec = @min(min_vec, @select(T, valid_mask, chunk, min_id_vec));
                        max_vec = @max(max_vec, @select(T, valid_mask, chunk, max_id_vec));
                    }
                }
            } else {
                while (i + VEC_SIZE <= self.data.len) : (i += VEC_SIZE) {
                    const chunk: @Vector(VEC_SIZE, T) = self.data[i..][0..VEC_SIZE].*;
                    min_vec = @min(min_vec, chunk);
                    max_vec = @max(max_vec, chunk);
                    has_valid = true;
                }
            }

            var min_val: T = @reduce(.Min, min_vec);
            var max_val: T = @reduce(.Max, max_vec);

            while (i < self.data.len) : (i += 1) {
                if (self.validity) |bm| {
                    if (!isBitValid(bm, i)) continue;
                }
                const v = self.data[i];
                if (comptime T == f64) {
                    if (std.math.isNan(v)) continue;
                }
                if (!has_valid) {
                    min_val = v;
                    max_val = v;
                    has_valid = true;
                } else {
                    if (v < min_val) min_val = v;
                    if (v > max_val) max_val = v;
                }
            }

            if (!has_valid) return null;
            return .{ .min = min_val, .max = max_val };
        }

        /// Vectorized predicate filter returning matching row indices using bitmask @ctz extraction.
        pub fn filterSimd(self: Self, op: CompareOp, threshold: T, out_indices: []usize) usize {
            var out_count: usize = 0;
            var i: usize = 0;
            const thresh_vec: @Vector(VEC_SIZE, T) = @splat(threshold);

            while (i + VEC_SIZE <= self.data.len and out_count + VEC_SIZE <= out_indices.len) : (i += VEC_SIZE) {
                const chunk: @Vector(VEC_SIZE, T) = self.data[i..][0..VEC_SIZE].*;
                var bits: M = maskToBits(VEC_SIZE, CompareOp.evalVec(VEC_SIZE, T, op, chunk, thresh_vec));
                if (self.validity) |bm| {
                    bits &= loadValidBits(VEC_SIZE, bm, i);
                }
                while (bits != 0) : (bits &= bits - 1) {
                    const lane: usize = @ctz(bits);
                    out_indices[out_count] = i + lane;
                    out_count += 1;
                }
            }

            while (i < self.data.len and out_count < out_indices.len) : (i += 1) {
                if (self.validity) |bm| {
                    if (!isBitValid(bm, i)) continue;
                }
                if (CompareOp.evalScalar(T, op, self.data[i], threshold)) {
                    out_indices[out_count] = i;
                    out_count += 1;
                }
            }

            return out_count;
        }

        pub fn filterGreaterThan(self: Self, threshold: T, out_indices: []usize) usize {
            return self.filterSimd(.gt, threshold, out_indices);
        }

        /// Vectorized inclusive range filter [low, high] in a single SIMD pass.
        pub fn filterRangeSimd(self: Self, low: T, high: T, out_indices: []usize) usize {
            if (comptime T == f64) {
                if (std.math.isNan(low) or std.math.isNan(high)) return 0;
            }
            if (low > high) return 0;

            var out_count: usize = 0;
            var i: usize = 0;
            const low_vec: @Vector(VEC_SIZE, T) = @splat(low);
            const high_vec: @Vector(VEC_SIZE, T) = @splat(high);

            while (i + VEC_SIZE <= self.data.len and out_count + VEC_SIZE <= out_indices.len) : (i += VEC_SIZE) {
                const chunk: @Vector(VEC_SIZE, T) = self.data[i..][0..VEC_SIZE].*;
                var bits: M = maskToBits(VEC_SIZE, chunk >= low_vec) & maskToBits(VEC_SIZE, chunk <= high_vec);
                if (self.validity) |bm| {
                    bits &= loadValidBits(VEC_SIZE, bm, i);
                }
                while (bits != 0) : (bits &= bits - 1) {
                    const lane: usize = @ctz(bits);
                    out_indices[out_count] = i + lane;
                    out_count += 1;
                }
            }

            while (i < self.data.len and out_count < out_indices.len) : (i += 1) {
                if (self.validity) |bm| {
                    if (!isBitValid(bm, i)) continue;
                }
                const v = self.data[i];
                if (v >= low and v <= high) {
                    out_indices[out_count] = i;
                    out_count += 1;
                }
            }

            return out_count;
        }

        /// Allocation-free SIMD predicate counter using hardware @popCount on comparison bitmasks.
        pub fn countMatchingSimd(self: Self, op: CompareOp, threshold: T) usize {
            var count: usize = 0;
            var i: usize = 0;
            const thresh_vec: @Vector(VEC_SIZE, T) = @splat(threshold);

            while (i + VEC_SIZE <= self.data.len) : (i += VEC_SIZE) {
                const chunk: @Vector(VEC_SIZE, T) = self.data[i..][0..VEC_SIZE].*;
                var bits: M = maskToBits(VEC_SIZE, CompareOp.evalVec(VEC_SIZE, T, op, chunk, thresh_vec));
                if (self.validity) |bm| {
                    bits &= loadValidBits(VEC_SIZE, bm, i);
                }
                count += @popCount(bits);
            }

            while (i < self.data.len) : (i += 1) {
                if (self.validity) |bm| {
                    if (!isBitValid(bm, i)) continue;
                }
                if (CompareOp.evalScalar(T, op, self.data[i], threshold)) {
                    count += 1;
                }
            }

            return count;
        }

        /// Fused SIMD predicate filter and widening sum without materializing index buffers.
        pub fn sumWhereSimd(self: Self, op: CompareOp, threshold: T) S {
            var i: usize = 0;
            const thresh_vec: @Vector(VEC_SIZE, T) = @splat(threshold);
            const zero_vec: @Vector(VEC_SIZE, T) = @splat(0);

            if (comptime T == i32) {
                var acc_lo: @Vector(8, i64) = @splat(0);
                var acc_hi: @Vector(8, i64) = @splat(0);
                while (i + 16 <= self.data.len) : (i += 16) {
                    const chunk: @Vector(16, i32) = self.data[i..][0..16].*;
                    var bits: u16 = maskToBits(16, CompareOp.evalVec(16, i32, op, chunk, thresh_vec));
                    if (self.validity) |bm| bits &= loadValidBits(16, bm, i);
                    const masked = @select(i32, bitsToMask(16, bits), chunk, zero_vec);
                    const arr: [16]i32 = masked;
                    const lo: @Vector(8, i32) = arr[0..8].*;
                    const hi: @Vector(8, i32) = arr[8..16].*;
                    acc_lo += @as(@Vector(8, i64), lo);
                    acc_hi += @as(@Vector(8, i64), hi);
                }
                var total: i64 = @reduce(.Add, acc_lo + acc_hi);
                while (i < self.data.len) : (i += 1) {
                    if (self.validity) |bm| {
                        if (!isBitValid(bm, i)) continue;
                    }
                    if (CompareOp.evalScalar(i32, op, self.data[i], threshold)) total += self.data[i];
                }
                return total;
            } else if (comptime T == i64) {
                var acc_lo: @Vector(4, i128) = @splat(0);
                var acc_hi: @Vector(4, i128) = @splat(0);
                while (i + 8 <= self.data.len) : (i += 8) {
                    const chunk: @Vector(8, i64) = self.data[i..][0..8].*;
                    var bits: u8 = maskToBits(8, CompareOp.evalVec(8, i64, op, chunk, thresh_vec));
                    if (self.validity) |bm| bits &= loadValidBits(8, bm, i);
                    const masked = @select(i64, bitsToMask(8, bits), chunk, zero_vec);
                    const arr: [8]i64 = masked;
                    const lo: @Vector(4, i64) = arr[0..4].*;
                    const hi: @Vector(4, i64) = arr[4..8].*;
                    acc_lo += @as(@Vector(4, i128), lo);
                    acc_hi += @as(@Vector(4, i128), hi);
                }
                var total: i128 = @reduce(.Add, acc_lo + acc_hi);
                while (i < self.data.len) : (i += 1) {
                    if (self.validity) |bm| {
                        if (!isBitValid(bm, i)) continue;
                    }
                    if (CompareOp.evalScalar(i64, op, self.data[i], threshold)) total += self.data[i];
                }
                return total;
            } else {
                var acc_lo: @Vector(4, f64) = @splat(0.0);
                var acc_hi: @Vector(4, f64) = @splat(0.0);
                while (i + 8 <= self.data.len) : (i += 8) {
                    const chunk: @Vector(8, f64) = self.data[i..][0..8].*;
                    var bits: u8 = maskToBits(8, CompareOp.evalVec(8, f64, op, chunk, thresh_vec));
                    if (self.validity) |bm| bits &= loadValidBits(8, bm, i);
                    const masked = @select(f64, bitsToMask(8, bits), chunk, zero_vec);
                    const arr: [8]f64 = masked;
                    const lo: @Vector(4, f64) = arr[0..4].*;
                    const hi: @Vector(4, f64) = arr[4..8].*;
                    acc_lo += lo;
                    acc_hi += hi;
                }
                var total: f64 = @reduce(.Add, acc_lo + acc_hi);
                while (i < self.data.len) : (i += 1) {
                    if (self.validity) |bm| {
                        if (!isBitValid(bm, i)) continue;
                    }
                    if (CompareOp.evalScalar(f64, op, self.data[i], threshold)) total += self.data[i];
                }
                return total;
            }
        }

        /// Vector-vector SIMD dot product across two equal-length columns.
        /// Widens integer operands before multiplication to avoid overflow.
        pub fn dotProductSimd(self: Self, other: Self) !S {
            if (self.data.len != other.data.len) return error.LengthMismatch;
            var i: usize = 0;

            if (comptime T == i32) {
                var acc_lo: @Vector(8, i64) = @splat(0);
                var acc_hi: @Vector(8, i64) = @splat(0);
                const zero_vec: @Vector(16, i32) = @splat(0);

                while (i + 16 <= self.data.len) : (i += 16) {
                    var a: @Vector(16, i32) = self.data[i..][0..16].*;
                    const b: @Vector(16, i32) = other.data[i..][0..16].*;
                    if (self.validity != null or other.validity != null) {
                        var bits: u16 = std.math.maxInt(u16);
                        if (self.validity) |bm| bits &= loadValidBits(16, bm, i);
                        if (other.validity) |bm| bits &= loadValidBits(16, bm, i);
                        a = @select(i32, bitsToMask(16, bits), a, zero_vec);
                    }
                    const a_arr: [16]i32 = a;
                    const b_arr: [16]i32 = b;
                    const a_lo: @Vector(8, i32) = a_arr[0..8].*;
                    const a_hi: @Vector(8, i32) = a_arr[8..16].*;
                    const b_lo: @Vector(8, i32) = b_arr[0..8].*;
                    const b_hi: @Vector(8, i32) = b_arr[8..16].*;
                    acc_lo += @as(@Vector(8, i64), a_lo) * @as(@Vector(8, i64), b_lo);
                    acc_hi += @as(@Vector(8, i64), a_hi) * @as(@Vector(8, i64), b_hi);
                }
                var total: i64 = @reduce(.Add, acc_lo + acc_hi);
                while (i < self.data.len) : (i += 1) {
                    if (self.isValid(i) and other.isValid(i)) {
                        total += @as(i64, self.data[i]) * @as(i64, other.data[i]);
                    }
                }
                return total;
            } else if (comptime T == i64) {
                var acc_lo: @Vector(4, i128) = @splat(0);
                var acc_hi: @Vector(4, i128) = @splat(0);
                const zero_vec: @Vector(8, i64) = @splat(0);

                while (i + 8 <= self.data.len) : (i += 8) {
                    var a: @Vector(8, i64) = self.data[i..][0..8].*;
                    const b: @Vector(8, i64) = other.data[i..][0..8].*;
                    if (self.validity != null or other.validity != null) {
                        var bits: u8 = std.math.maxInt(u8);
                        if (self.validity) |bm| bits &= loadValidBits(8, bm, i);
                        if (other.validity) |bm| bits &= loadValidBits(8, bm, i);
                        a = @select(i64, bitsToMask(8, bits), a, zero_vec);
                    }
                    const a_arr: [8]i64 = a;
                    const b_arr: [8]i64 = b;
                    const a_lo: @Vector(4, i64) = a_arr[0..4].*;
                    const a_hi: @Vector(4, i64) = a_arr[4..8].*;
                    const b_lo: @Vector(4, i64) = b_arr[0..4].*;
                    const b_hi: @Vector(4, i64) = b_arr[4..8].*;
                    acc_lo += @as(@Vector(4, i128), a_lo) * @as(@Vector(4, i128), b_lo);
                    acc_hi += @as(@Vector(4, i128), a_hi) * @as(@Vector(4, i128), b_hi);
                }
                var total: i128 = @reduce(.Add, acc_lo + acc_hi);
                while (i < self.data.len) : (i += 1) {
                    if (self.isValid(i) and other.isValid(i)) {
                        total += @as(i128, self.data[i]) * @as(i128, other.data[i]);
                    }
                }
                return total;
            } else {
                var acc_lo: @Vector(4, f64) = @splat(0.0);
                var acc_hi: @Vector(4, f64) = @splat(0.0);
                const zero_vec: @Vector(8, f64) = @splat(0.0);

                while (i + 8 <= self.data.len) : (i += 8) {
                    const a: @Vector(8, f64) = self.data[i..][0..8].*;
                    const b: @Vector(8, f64) = other.data[i..][0..8].*;
                    var prod = a * b;
                    if (self.validity != null or other.validity != null) {
                        var bits: u8 = std.math.maxInt(u8);
                        if (self.validity) |bm| bits &= loadValidBits(8, bm, i);
                        if (other.validity) |bm| bits &= loadValidBits(8, bm, i);
                        prod = @select(f64, bitsToMask(8, bits), prod, zero_vec);
                    }
                    const p_arr: [8]f64 = prod;
                    const p_lo: @Vector(4, f64) = p_arr[0..4].*;
                    const p_hi: @Vector(4, f64) = p_arr[4..8].*;
                    acc_lo += p_lo;
                    acc_hi += p_hi;
                }
                var total: f64 = @reduce(.Add, acc_lo + acc_hi);
                while (i < self.data.len) : (i += 1) {
                    if (self.isValid(i) and other.isValid(i)) {
                        total += self.data[i] * other.data[i];
                    }
                }
                return total;
            }
        }

        /// Computes summary statistics (count, valid_count, null_count, sum, min, max, mean).
        pub fn statsSimd(self: Self) ColumnStats(T) {
            const valid_count = self.data.len - @min(self.null_count, self.data.len);
            const sum_val = self.sumSimd();
            const mm = self.minMaxSimd();
            const mean_val: ?f64 = if (valid_count == 0)
                null
            else if (comptime T == f64)
                sum_val / @as(f64, @floatFromInt(valid_count))
            else
                @as(f64, @floatFromInt(sum_val)) / @as(f64, @floatFromInt(valid_count));

            return .{
                .count = self.data.len,
                .valid_count = valid_count,
                .null_count = self.data.len - valid_count,
                .sum = sum_val,
                .min = if (mm) |m| m.min else null,
                .max = if (mm) |m| m.max else null,
                .mean = mean_val,
            };
        }
    };
}

/// 64-byte cache-line aligned typed columnar buffer with optional Arrow-compatible validity bitmap.
pub fn NumericColumn(comptime T: type) type {
    return struct {
        const Self = @This();
        const S = SumType(T);

        allocator: std.mem.Allocator,
        data: []align(64) T,
        validity: ?[]align(64) u8 = null,
        null_count: usize = 0,

        pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
            const mem = try allocator.alignedAlloc(T, .fromByteUnits(64), count);
            @memset(mem, 0);
            return Self{
                .allocator = allocator,
                .data = mem,
                .validity = null,
                .null_count = 0,
            };
        }

        pub fn initFromSlice(allocator: std.mem.Allocator, values: []const T) !Self {
            const mem = try allocator.alignedAlloc(T, .fromByteUnits(64), values.len);
            @memcpy(mem, values);
            return Self{
                .allocator = allocator,
                .data = mem,
                .validity = null,
                .null_count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.validity) |bm| {
                self.allocator.free(bm);
                self.validity = null;
            }
            self.allocator.free(self.data);
        }

        pub fn ensureValidity(self: *Self) ![]align(64) u8 {
            if (self.validity) |bm| return bm;
            const byte_len = validityByteLen(self.data.len);
            const bm = try self.allocator.alignedAlloc(u8, .fromByteUnits(64), byte_len);
            if (byte_len > 0) {
                @memset(bm, 0xFF);
                const rem_bits: u3 = @intCast(self.data.len & 7);
                if (rem_bits != 0) {
                    bm[byte_len - 1] = (@as(u8, 1) << rem_bits) - 1;
                }
            }
            self.validity = bm;
            return bm;
        }

        pub fn setNull(self: *Self, index: usize) !void {
            if (index >= self.data.len) return error.IndexOutOfBounds;
            const bm = try self.ensureValidity();
            const mask: u8 = @as(u8, 1) << @intCast(index & 7);
            if ((bm[index >> 3] & mask) != 0) {
                bm[index >> 3] &= ~mask;
                self.null_count += 1;
            }
        }

        pub fn setValid(self: *Self, index: usize, value: T) !void {
            if (index >= self.data.len) return error.IndexOutOfBounds;
            self.data[index] = value;
            if (self.validity) |bm| {
                const mask: u8 = @as(u8, 1) << @intCast(index & 7);
                if ((bm[index >> 3] & mask) == 0) {
                    bm[index >> 3] |= mask;
                    self.null_count -= 1;
                }
            }
        }

        pub inline fn isNull(self: *const Self, index: usize) bool {
            return self.asSlice().isNull(index);
        }

        pub inline fn isValid(self: *const Self, index: usize) bool {
            return self.asSlice().isValid(index);
        }

        pub inline fn get(self: *const Self, index: usize) ?T {
            return self.asSlice().get(index);
        }

        pub inline fn nullCount(self: *const Self) usize {
            return self.null_count;
        }

        pub inline fn asSlice(self: *const Self) ColumnSlice(T) {
            return .{
                .data = self.data,
                .validity = if (self.validity) |bm| bm else null,
                .null_count = self.null_count,
            };
        }

        pub fn sumSimd(self: *const Self) S {
            return self.asSlice().sumSimd();
        }

        pub fn minMaxSimd(self: *const Self) ?MinMax(T) {
            return self.asSlice().minMaxSimd();
        }

        pub fn filterSimd(self: *const Self, op: CompareOp, threshold: T, out_indices: []usize) usize {
            return self.asSlice().filterSimd(op, threshold, out_indices);
        }

        pub fn filterGreaterThan(self: *const Self, threshold: T, out_indices: []usize) usize {
            return self.asSlice().filterGreaterThan(threshold, out_indices);
        }

        pub fn filterRangeSimd(self: *const Self, low: T, high: T, out_indices: []usize) usize {
            return self.asSlice().filterRangeSimd(low, high, out_indices);
        }

        pub fn countMatchingSimd(self: *const Self, op: CompareOp, threshold: T) usize {
            return self.asSlice().countMatchingSimd(op, threshold);
        }

        pub fn sumWhereSimd(self: *const Self, op: CompareOp, threshold: T) S {
            return self.asSlice().sumWhereSimd(op, threshold);
        }

        pub fn dotProductSimd(self: *const Self, other: *const Self) !S {
            return self.asSlice().dotProductSimd(other.asSlice());
        }

        pub fn statsSimd(self: *const Self) ColumnStats(T) {
            return self.asSlice().statsSimd();
        }
    };
}

pub const Int32Column = NumericColumn(i32);
pub const Int64Column = NumericColumn(i64);
pub const Float64Column = NumericColumn(f64);

test "Int32Column SIMD Reduction & Filter" {
    const allocator = std.testing.allocator;
    var col = try Int32Column.init(allocator, 64);
    defer col.deinit();

    for (0..64) |i| {
        col.data[i] = @intCast(i + 1);
    }

    try std.testing.expectEqual(@as(i64, 2080), col.sumSimd());

    var indices: [64]usize = undefined;
    const count = col.filterGreaterThan(60, &indices);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(usize, 60), indices[0]);
    try std.testing.expectEqual(@as(usize, 63), indices[3]);
}

test "Int32Column widening sumSimd prevents 32-bit overflow" {
    const allocator = std.testing.allocator;
    const n: usize = 103; // non-multiple of 16 to exercise both SIMD and scalar tail
    var col = try Int32Column.init(allocator, n);
    defer col.deinit();

    for (0..n) |i| {
        col.data[i] = std.math.maxInt(i32);
    }

    const expected: i64 = @as(i64, n) * @as(i64, std.math.maxInt(i32));
    try std.testing.expectEqual(expected, col.sumSimd());

    // Negative extreme overflow check
    for (0..n) |i| {
        col.data[i] = std.math.minInt(i32);
    }
    const expected_min: i64 = @as(i64, n) * @as(i64, std.math.minInt(i32));
    try std.testing.expectEqual(expected_min, col.sumSimd());
}

test "Int64Column and Float64Column SIMD kernels, NaN handling, and dot product" {
    const allocator = std.testing.allocator;

    // Int64 extreme overflow safety (accumulates in i128)
    var i64_a = try Int64Column.init(allocator, 19);
    defer i64_a.deinit();
    var i64_b = try Int64Column.init(allocator, 19);
    defer i64_b.deinit();
    for (0..19) |i| {
        i64_a.data[i] = std.math.maxInt(i64);
        i64_b.data[i] = 2;
    }
    try std.testing.expectEqual(@as(i128, 19) * @as(i128, std.math.maxInt(i64)), i64_a.sumSimd());
    try std.testing.expectEqual(@as(i128, 38) * @as(i128, std.math.maxInt(i64)), try i64_a.dotProductSimd(&i64_b));

    const mm_i64 = i64_a.minMaxSimd().?;
    try std.testing.expectEqual(std.math.maxInt(i64), mm_i64.min);
    try std.testing.expectEqual(std.math.maxInt(i64), mm_i64.max);

    // Float64 with NaN, -inf, +inf, range filter, and fused sumWhere
    var fcol = try Float64Column.init(allocator, 21);
    defer fcol.deinit();
    for (0..21) |i| {
        fcol.data[i] = @as(f64, @floatFromInt(i)) * 1.5;
    }
    fcol.data[3] = std.math.nan(f64);
    fcol.data[17] = std.math.nan(f64);

    const mm_f64 = fcol.minMaxSimd().?;
    try std.testing.expectEqual(@as(f64, 0.0), mm_f64.min);
    try std.testing.expectEqual(@as(f64, 30.0), mm_f64.max);

    // Range filter [6.0, 15.0] -> indices 4..10 (7 values)
    var out: [21]usize = undefined;
    const range_cnt = fcol.filterRangeSimd(6.0, 15.0, &out);
    try std.testing.expectEqual(@as(usize, 7), range_cnt);
    try std.testing.expectEqual(@as(usize, 4), out[0]);
    try std.testing.expectEqual(@as(usize, 10), out[6]);

    // All-NaN float column returns null minMax
    var all_nan = try Float64Column.init(allocator, 10);
    defer all_nan.deinit();
    for (0..10) |i| all_nan.data[i] = std.math.nan(f64);
    try std.testing.expect(all_nan.minMaxSimd() == null);
}

test "Validity bitmap null semantics across SIMD aggregations and filters" {
    const allocator = std.testing.allocator;
    const n: usize = 37; // 2 SIMD chunks (32) + 5 scalar tail
    var col = try Int32Column.init(allocator, n);
    defer col.deinit();

    for (0..n) |i| {
        col.data[i] = @intCast(i + 1);
    }

    // Mark specific rows null across chunk boundaries and tail
    try col.setNull(0); // value 1
    try col.setNull(15); // value 16
    try col.setNull(16); // value 17
    try col.setNull(35); // value 36
    try col.setNull(36); // value 37
    // Repeated setNull is idempotent
    try col.setNull(15);

    try std.testing.expectEqual(@as(usize, 5), col.nullCount());
    try std.testing.expectEqual(@as(usize, 5), countNullBits(col.validity.?, n));
    try std.testing.expect(col.get(0) == null);
    try std.testing.expectEqual(@as(?i32, 2), col.get(1));

    // Total 1..37 = 703; minus (1 + 16 + 17 + 36 + 37 = 107) = 596
    try std.testing.expectEqual(@as(i64, 596), col.sumSimd());

    const mm = col.minMaxSimd().?;
    try std.testing.expectEqual(@as(i32, 2), mm.min);
    try std.testing.expectEqual(@as(i32, 35), mm.max);

    // Filter > 30: values 31..35 (36 and 37 are null)
    try std.testing.expectEqual(@as(usize, 5), col.countMatchingSimd(.gt, 30));
    try std.testing.expectEqual(@as(i64, 31 + 32 + 33 + 34 + 35), col.sumWhereSimd(.gt, 30));

    var buf: [3]usize = undefined; // intentionally smaller output capacity
    const truncated = col.filterSimd(.gt, 30, &buf);
    try std.testing.expectEqual(@as(usize, 3), truncated);
    try std.testing.expectEqualSlices(usize, &.{ 30, 31, 32 }, buf[0..truncated]);

    // Restore index 0 to valid value 100
    try col.setValid(0, 100);
    try std.testing.expectEqual(@as(usize, 4), col.nullCount());
    try std.testing.expectEqual(@as(i64, 696), col.sumSimd());
    try std.testing.expectEqual(@as(i32, 100), col.minMaxSimd().?.max);

    const stats = col.statsSimd();
    try std.testing.expectEqual(@as(usize, n), stats.count);
    try std.testing.expectEqual(@as(usize, n - 4), stats.valid_count);
    try std.testing.expectEqual(@as(usize, 4), stats.null_count);
    try std.testing.expectApproxEqAbs(@as(f64, 696.0) / 33.0, stats.mean.?, 1e-12);
}

test "Empty and all-null edge cases" {
    const allocator = std.testing.allocator;
    var empty = try Int32Column.init(allocator, 0);
    defer empty.deinit();
    try std.testing.expectEqual(@as(i64, 0), empty.sumSimd());
    try std.testing.expect(empty.minMaxSimd() == null);
    try std.testing.expectEqual(@as(usize, 0), empty.countMatchingSimd(.ge, 0));
    try std.testing.expect(empty.statsSimd().mean == null);

    var all_null = try Int64Column.init(allocator, 12);
    defer all_null.deinit();
    for (0..12) |i| {
        all_null.data[i] = 999;
        try all_null.setNull(i);
    }
    try std.testing.expectEqual(@as(i128, 0), all_null.sumSimd());
    try std.testing.expect(all_null.minMaxSimd() == null);
    try std.testing.expectEqual(@as(usize, 0), all_null.countMatchingSimd(.eq, 999));
    try std.testing.expect(all_null.statsSimd().mean == null);
}

fn verifySimdAgainstScalar(comptime T: type, allocator: std.mem.Allocator, seed: u64) !void {
    const sizes = [_]usize{ 0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 129 };
    const null_pcts = [_]u8{ 0, 30, 95, 100 };
    const all_ops = [_]CompareOp{ .eq, .ne, .lt, .le, .gt, .ge };

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    for (sizes) |n| {
        for (null_pcts) |null_pct| {
            var col_a = try NumericColumn(T).init(allocator, n);
            defer col_a.deinit();
            var col_b = try NumericColumn(T).init(allocator, n);
            defer col_b.deinit();

            for (0..n) |i| {
                col_a.data[i] = switch (T) {
                    i32 => rand.intRangeAtMost(i32, -500, 500),
                    i64 => rand.intRangeAtMost(i64, -50_000, 50_000),
                    f64 => @as(f64, @floatFromInt(rand.intRangeAtMost(i32, -200, 200))) * 0.5,
                    else => unreachable,
                };
                col_b.data[i] = switch (T) {
                    i32 => rand.intRangeAtMost(i32, -50, 50),
                    i64 => rand.intRangeAtMost(i64, -500, 500),
                    f64 => @as(f64, @floatFromInt(rand.intRangeAtMost(i32, -20, 20))) * 0.25,
                    else => unreachable,
                };
                if (null_pct > 0 and rand.intRangeLessThan(u8, 0, 100) < null_pct) {
                    try col_a.setNull(i);
                }
                if (null_pct > 0 and rand.intRangeLessThan(u8, 0, 100) < null_pct) {
                    try col_b.setNull(i);
                }
            }

            // 1. Differential sumSimd
            var ref_sum: SumType(T) = 0;
            var ref_min: ?T = null;
            var ref_max: ?T = null;
            var ref_dot: SumType(T) = 0;
            for (0..n) |i| {
                if (col_a.isValid(i)) {
                    const v = col_a.data[i];
                    ref_sum += v;
                    if (ref_min == null or v < ref_min.?) ref_min = v;
                    if (ref_max == null or v > ref_max.?) ref_max = v;
                    if (col_b.isValid(i)) {
                        if (comptime T == f64) {
                            ref_dot += v * col_b.data[i];
                        } else {
                            ref_dot += @as(SumType(T), v) * @as(SumType(T), col_b.data[i]);
                        }
                    }
                }
            }

            if (comptime T == f64) {
                try std.testing.expectApproxEqAbs(ref_sum, col_a.sumSimd(), 1e-6);
                try std.testing.expectApproxEqAbs(ref_dot, try col_a.dotProductSimd(&col_b), 1e-6);
            } else {
                try std.testing.expectEqual(ref_sum, col_a.sumSimd());
                try std.testing.expectEqual(ref_dot, try col_a.dotProductSimd(&col_b));
            }

            // 2. Differential minMaxSimd
            const got_mm = col_a.minMaxSimd();
            if (ref_min == null) {
                try std.testing.expect(got_mm == null);
            } else {
                try std.testing.expect(got_mm != null);
                try std.testing.expectEqual(ref_min.?, got_mm.?.min);
                try std.testing.expectEqual(ref_max.?, got_mm.?.max);
            }

            // 3. Differential filterSimd, countMatchingSimd, sumWhereSimd for all 6 ops
            const threshold: T = switch (T) {
                i32 => 17,
                i64 => -1234,
                f64 => 12.5,
                else => unreachable,
            };
            const simd_out = try allocator.alloc(usize, n);
            defer allocator.free(simd_out);
            const ref_out = try allocator.alloc(usize, n);
            defer allocator.free(ref_out);

            for (all_ops) |op| {
                var ref_cnt: usize = 0;
                var ref_wsum: SumType(T) = 0;
                for (0..n) |i| {
                    if (col_a.isValid(i) and CompareOp.evalScalar(T, op, col_a.data[i], threshold)) {
                        ref_out[ref_cnt] = i;
                        ref_cnt += 1;
                        ref_wsum += col_a.data[i];
                    }
                }

                const got_cnt = col_a.filterSimd(op, threshold, simd_out);
                try std.testing.expectEqual(ref_cnt, got_cnt);
                try std.testing.expectEqualSlices(usize, ref_out[0..ref_cnt], simd_out[0..got_cnt]);
                try std.testing.expectEqual(ref_cnt, col_a.countMatchingSimd(op, threshold));
                if (comptime T == f64) {
                    try std.testing.expectApproxEqAbs(ref_wsum, col_a.sumWhereSimd(op, threshold), 1e-6);
                } else {
                    try std.testing.expectEqual(ref_wsum, col_a.sumWhereSimd(op, threshold));
                }
            }

            // 4. Differential filterRangeSimd
            const low: T = switch (T) {
                i32 => -100,
                i64 => -10_000,
                f64 => -25.0,
                else => unreachable,
            };
            const high: T = switch (T) {
                i32 => 150,
                i64 => 15_000,
                f64 => 35.0,
                else => unreachable,
            };
            var ref_rcnt: usize = 0;
            for (0..n) |i| {
                if (col_a.isValid(i) and col_a.data[i] >= low and col_a.data[i] <= high) {
                    ref_out[ref_rcnt] = i;
                    ref_rcnt += 1;
                }
            }
            const got_rcnt = col_a.filterRangeSimd(low, high, simd_out);
            try std.testing.expectEqual(ref_rcnt, got_rcnt);
            try std.testing.expectEqualSlices(usize, ref_out[0..ref_rcnt], simd_out[0..got_rcnt]);
        }
    }
}

test "Differential verification of SIMD kernels against scalar reference across all types and null densities" {
    try verifySimdAgainstScalar(i32, std.testing.allocator, 0xD1FF_0032);
    try verifySimdAgainstScalar(i64, std.testing.allocator, 0xD1FF_0064);
    try verifySimdAgainstScalar(f64, std.testing.allocator, 0xD1FF_0F64);
}
