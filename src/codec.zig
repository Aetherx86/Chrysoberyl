const std = @import("std");
const column = @import("column.zig");

pub const CodecError = error{
    CorruptedEncoding,
    LengthMismatch,
    UnsupportedEncoding,
    OutOfMemory,
};

fn UnsignedFor(comptime T: type) type {
    return switch (T) {
        i32 => u32,
        i64 => u64,
        else => @compileError("ZigZag/Delta encoding only supports i32 and i64"),
    };
}

inline fn bitEqual(comptime T: type, a: T, b: T) bool {
    return switch (T) {
        f64 => @as(u64, @bitCast(a)) == @as(u64, @bitCast(b)),
        else => a == b,
    };
}

pub inline fn zigzagEncode(comptime T: type, v: T) UnsignedFor(T) {
    const U = UnsignedFor(T);
    const bits = @bitSizeOf(T);
    const u: U = @bitCast(v);
    const sign: U = @bitCast(v >> (bits - 1));
    return (u << 1) ^ sign;
}

pub inline fn zigzagDecode(comptime T: type, zz: UnsignedFor(T)) T {
    const U = UnsignedFor(T);
    const shifted: U = zz >> 1;
    const mask: U = 0 -% (zz & 1);
    return @bitCast(shifted ^ mask);
}

fn appendVarint(comptime U: type, list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: U) !void {
    var v = value;
    while (v >= 0x80) {
        try list.append(allocator, @as(u8, @truncate(v)) | 0x80);
        v >>= 7;
    }
    try list.append(allocator, @as(u8, @truncate(v)));
}

fn readVarint(comptime U: type, bytes: []const u8, pos: *usize) CodecError!U {
    const max_bytes: usize = if (U == u32) 5 else 10;
    const ShiftType = std.math.Log2Int(U);
    var result: U = 0;
    var shift: usize = 0;
    var count: usize = 0;

    while (count < max_bytes) : (count += 1) {
        if (pos.* >= bytes.len) return error.CorruptedEncoding;
        const b = bytes[pos.*];
        pos.* += 1;

        if (count == max_bytes - 1) {
            // Final byte must fit remaining bits and have continuation bit clear.
            const max_final: u8 = if (U == u32) 0x0F else 0x01;
            if (b > max_final) return error.CorruptedEncoding;
            result |= @as(U, b) << @as(ShiftType, @intCast(shift));
            return result;
        }

        result |= @as(U, b & 0x7F) << @as(ShiftType, @intCast(shift));
        if ((b & 0x80) == 0) return result;
        shift += 7;
    }

    return error.CorruptedEncoding;
}

/// Run-Length Encodes a typed column slice into `[run_count: u32][ (run_len: u32, value: T)... ]`.
/// Uses bitwise equality for f64 so -0.0 and NaN payloads round-trip identically.
pub fn rleEncode(comptime T: type, allocator: std.mem.Allocator, data: []const T) ![]u8 {
    if (data.len == 0) {
        const out = try allocator.alloc(u8, 4);
        std.mem.writeInt(u32, out[0..4], 0, .little);
        return out;
    }

    // Count runs first so we perform a single exact allocation.
    var run_count: usize = 1;
    var run_len: u32 = 1;
    var prev = data[0];
    for (data[1..]) |val| {
        if (bitEqual(T, val, prev) and run_len < std.math.maxInt(u32)) {
            run_len += 1;
        } else {
            run_count += 1;
            prev = val;
            run_len = 1;
        }
    }

    const entry_size = @sizeOf(u32) + @sizeOf(T);
    const total_bytes = 4 + run_count * entry_size;
    const out = try allocator.alloc(u8, total_bytes);

    std.mem.writeInt(u32, out[0..4], @intCast(run_count), .little);
    var offset: usize = 4;
    var cur_val = data[0];
    var cur_len: u32 = 1;

    for (data[1..]) |val| {
        if (bitEqual(T, val, cur_val) and cur_len < std.math.maxInt(u32)) {
            cur_len += 1;
        } else {
            std.mem.writeInt(u32, out[offset..][0..4], cur_len, .little);
            offset += 4;
            @memcpy(out[offset..][0..@sizeOf(T)], std.mem.asBytes(&cur_val));
            offset += @sizeOf(T);
            cur_val = val;
            cur_len = 1;
        }
    }

    std.mem.writeInt(u32, out[offset..][0..4], cur_len, .little);
    offset += 4;
    @memcpy(out[offset..][0..@sizeOf(T)], std.mem.asBytes(&cur_val));

    return out;
}

/// Decodes an RLE payload into a 64-byte cache-line aligned buffer, validating bounds and length.
pub fn rleDecode(
    comptime T: type,
    allocator: std.mem.Allocator,
    encoded: []const u8,
    expected_len: usize,
) CodecError![]align(64) T {
    if (encoded.len < 4) return error.CorruptedEncoding;
    const run_count: usize = std.mem.readInt(u32, encoded[0..4], .little);
    const entry_size: usize = @sizeOf(u32) + @sizeOf(T);
    const payload_bytes = std.math.mul(usize, run_count, entry_size) catch return error.CorruptedEncoding;
    const expected_bytes = std.math.add(usize, 4, payload_bytes) catch return error.CorruptedEncoding;
    if (encoded.len != expected_bytes) return error.CorruptedEncoding;

    const out = try allocator.alignedAlloc(T, .fromByteUnits(64), expected_len);
    errdefer allocator.free(out);

    var offset: usize = 4;
    var out_pos: usize = 0;
    for (0..run_count) |_| {
        const run_len: usize = std.mem.readInt(u32, encoded[offset..][0..4], .little);
        offset += 4;
        if (run_len == 0) return error.CorruptedEncoding;

        var val: T = undefined;
        @memcpy(std.mem.asBytes(&val), encoded[offset..][0..@sizeOf(T)]);
        offset += @sizeOf(T);

        const next_pos = std.math.add(usize, out_pos, run_len) catch return error.LengthMismatch;
        if (next_pos > expected_len) return error.LengthMismatch;
        @memset(out[out_pos..next_pos], val);
        out_pos = next_pos;
    }

    if (out_pos != expected_len) return error.LengthMismatch;
    return out;
}

/// Computes the exact sum directly over an RLE-encoded stream without decompressing.
pub fn rleSum(comptime T: type, encoded: []const u8) CodecError!column.SumType(T) {
    if (encoded.len < 4) return error.CorruptedEncoding;
    const run_count: usize = std.mem.readInt(u32, encoded[0..4], .little);
    const entry_size: usize = @sizeOf(u32) + @sizeOf(T);
    const payload_bytes = std.math.mul(usize, run_count, entry_size) catch return error.CorruptedEncoding;
    const expected_bytes = std.math.add(usize, 4, payload_bytes) catch return error.CorruptedEncoding;
    if (encoded.len != expected_bytes) return error.CorruptedEncoding;

    var total: column.SumType(T) = 0;
    var offset: usize = 4;
    for (0..run_count) |_| {
        const run_len: u32 = std.mem.readInt(u32, encoded[offset..][0..4], .little);
        offset += 4;
        if (run_len == 0) return error.CorruptedEncoding;

        var val: T = undefined;
        @memcpy(std.mem.asBytes(&val), encoded[offset..][0..@sizeOf(T)]);
        offset += @sizeOf(T);

        if (comptime T == f64) {
            total += @as(f64, @floatFromInt(run_len)) * val;
        } else {
            total += @as(column.SumType(T), run_len) * @as(column.SumType(T), val);
        }
    }
    return total;
}

/// Delta + ZigZag + LEB128 varint encoding for signed integer columns (i32, i64).
/// Uses wrapping two's-complement differences so full signed range jumps never overflow.
pub fn deltaEncode(comptime T: type, allocator: std.mem.Allocator, data: []const T) ![]u8 {
    const U = UnsignedFor(T);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, 4 + @sizeOf(T) + data.len);
    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, @intCast(data.len), .little);
    try out.appendSlice(allocator, &count_bytes);

    if (data.len == 0) {
        return out.toOwnedSlice(allocator);
    }

    var first_bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &first_bytes, data[0], .little);
    try out.appendSlice(allocator, &first_bytes);

    var prev = data[0];
    for (data[1..]) |val| {
        const diff: T = val -% prev;
        try appendVarint(U, &out, allocator, zigzagEncode(T, diff));
        prev = val;
    }

    return out.toOwnedSlice(allocator);
}

/// Decodes a Delta + ZigZag + LEB128 payload into a 64-byte aligned buffer.
pub fn deltaDecode(
    comptime T: type,
    allocator: std.mem.Allocator,
    encoded: []const u8,
    expected_len: usize,
) CodecError![]align(64) T {
    const U = UnsignedFor(T);
    if (encoded.len < 4) return error.CorruptedEncoding;
    const count: usize = std.mem.readInt(u32, encoded[0..4], .little);
    if (count != expected_len) return error.LengthMismatch;

    const out = try allocator.alignedAlloc(T, .fromByteUnits(64), expected_len);
    errdefer allocator.free(out);

    if (count == 0) {
        if (encoded.len != 4) return error.CorruptedEncoding;
        return out;
    }

    if (encoded.len < 4 + @sizeOf(T)) return error.CorruptedEncoding;
    var pos: usize = 4;
    var acc: T = std.mem.readInt(T, encoded[pos..][0..@sizeOf(T)], .little);
    pos += @sizeOf(T);
    out[0] = acc;

    for (1..count) |i| {
        const zz = try readVarint(U, encoded, &pos);
        acc +%= zigzagDecode(T, zz);
        out[i] = acc;
    }

    if (pos != encoded.len) return error.CorruptedEncoding;
    return out;
}

/// SIMD-accelerated fixed-width delta encoder: `dst[i] = src[i] -% src[i-1]` (with `dst[0] = src[0]`).
pub fn simdDeltaEncode(comptime T: type, src: []const T, dst: []T) !void {
    if (src.len != dst.len) return error.LengthMismatch;
    if (src.len == 0) return;

    dst[0] = src[0];
    var i: usize = 1;
    const VEC_SIZE = column.VectorWidth(T);

    while (i + VEC_SIZE <= src.len) : (i += VEC_SIZE) {
        const curr: @Vector(VEC_SIZE, T) = src[i..][0..VEC_SIZE].*;
        const prev: @Vector(VEC_SIZE, T) = src[i - 1 ..][0..VEC_SIZE].*;
        dst[i..][0..VEC_SIZE].* = curr -% prev;
    }

    while (i < src.len) : (i += 1) {
        dst[i] = src[i] -% src[i - 1];
    }
}

/// SIMD Hillis-Steele parallel prefix-sum decoder for fixed-width delta blocks.
/// Reconstructs `dst[i] = sum_{k=0..i} deltas[k]` using log2(VEC_SIZE) vector shuffles per block.
pub fn simdPrefixSumDecode(comptime T: type, deltas: []const T, dst: []T) !void {
    if (deltas.len != dst.len) return error.LengthMismatch;
    if (deltas.len == 0) return;

    var carry: T = 0;
    var i: usize = 0;

    if (comptime T == i32) {
        const zero: @Vector(16, i32) = @splat(0);
        while (i + 16 <= deltas.len) : (i += 16) {
            var v: @Vector(16, i32) = deltas[i..][0..16].*;
            v +%= @shuffle(i32, v, zero, @Vector(16, i32){ -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 });
            v +%= @shuffle(i32, v, zero, @Vector(16, i32){ -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 });
            v +%= @shuffle(i32, v, zero, @Vector(16, i32){ -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 });
            v +%= @shuffle(i32, v, zero, @Vector(16, i32){ -1, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7 });
            v +%= @as(@Vector(16, i32), @splat(carry));
            dst[i..][0..16].* = v;
            carry = v[15];
        }
    } else if (comptime T == i64) {
        const zero: @Vector(8, i64) = @splat(0);
        while (i + 8 <= deltas.len) : (i += 8) {
            var v: @Vector(8, i64) = deltas[i..][0..8].*;
            v +%= @shuffle(i64, v, zero, @Vector(8, i32){ -1, 0, 1, 2, 3, 4, 5, 6 });
            v +%= @shuffle(i64, v, zero, @Vector(8, i32){ -1, -1, 0, 1, 2, 3, 4, 5 });
            v +%= @shuffle(i64, v, zero, @Vector(8, i32){ -1, -1, -1, -1, 0, 1, 2, 3 });
            v +%= @as(@Vector(8, i64), @splat(carry));
            dst[i..][0..8].* = v;
            carry = v[7];
        }
    } else {
        @compileError("simdPrefixSumDecode only supports i32 and i64");
    }

    while (i < deltas.len) : (i += 1) {
        carry +%= deltas[i];
        dst[i] = carry;
    }
}

/// Estimates the smallest encoding for `data`. Prefers `.plain` unless compression saves >= 10%.
pub fn selectBestEncoding(comptime T: type, data: []const T) column.ColumnEncoding {
    if (data.len < 8) return .plain;
    const plain_bytes = data.len * @sizeOf(T);

    // Estimate RLE size in a single pass
    var runs: usize = 1;
    var prev = data[0];
    for (data[1..]) |val| {
        if (!bitEqual(T, val, prev)) {
            runs += 1;
            prev = val;
        }
    }
    const rle_bytes = 4 + runs * (@sizeOf(u32) + @sizeOf(T));

    var best_encoding: column.ColumnEncoding = .plain;
    var best_bytes: usize = plain_bytes - (plain_bytes / 10); // require >=10% win over plain

    if (rle_bytes < best_bytes) {
        best_encoding = .rle;
        best_bytes = rle_bytes;
    }

    if (comptime T == i32 or T == i64) {
        var delta_bytes: usize = 4 + @sizeOf(T);
        var p = data[0];
        for (data[1..]) |val| {
            const zz = zigzagEncode(T, val -% p);
            var v = zz;
            var nbytes: usize = 1;
            while (v >= 0x80) : (v >>= 7) nbytes += 1;
            delta_bytes += nbytes;
            p = val;
        }
        if (delta_bytes < best_bytes) {
            best_encoding = .delta;
        }
    }

    return best_encoding;
}

test "RLE encode/decode round-trip and compressed-domain rleSum" {
    const allocator = std.testing.allocator;
    const data = [_]i32{ 5, 5, 5, 5, -10, -10, 42, 42, 42, 42, 42 };
    const encoded = try rleEncode(i32, allocator, &data);
    defer allocator.free(encoded);

    // 3 runs * 8 bytes + 4 header = 28 bytes (vs 44 raw)
    try std.testing.expectEqual(@as(usize, 28), encoded.len);
    try std.testing.expectEqual(@as(i64, 5 * 4 + (-10) * 2 + 42 * 5), try rleSum(i32, encoded));

    const decoded = try rleDecode(i32, allocator, encoded, data.len);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, &data, decoded);

    // Float64 bit-exact round-trip including -0.0 and NaN
    const fdata = [_]f64{ -0.0, -0.0, 0.0, 3.14, 3.14, std.math.nan(f64) };
    const fenc = try rleEncode(f64, allocator, &fdata);
    defer allocator.free(fenc);
    const fdec = try rleDecode(f64, allocator, fenc, fdata.len);
    defer allocator.free(fdec);
    for (fdata, fdec) |a, b| {
        try std.testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
    }
}

test "Delta + ZigZag encoding handles extreme signed bounds and monotonic sequences" {
    const allocator = std.testing.allocator;

    // Extreme alternating signed bounds
    const extremes = [_]i64{
        std.math.minInt(i64),
        std.math.maxInt(i64),
        std.math.minInt(i64),
        0,
        -1,
        1,
        std.math.maxInt(i64),
    };
    const enc_ext = try deltaEncode(i64, allocator, &extremes);
    defer allocator.free(enc_ext);
    const dec_ext = try deltaDecode(i64, allocator, enc_ext, extremes.len);
    defer allocator.free(dec_ext);
    try std.testing.expectEqualSlices(i64, &extremes, dec_ext);

    // Monotonic timestamps compress dramatically
    var timestamps: [1000]i64 = undefined;
    for (0..1000) |i| {
        timestamps[i] = 1_700_000_000 + @as(i64, @intCast(i * 10));
    }
    const enc_ts = try deltaEncode(i64, allocator, &timestamps);
    defer allocator.free(enc_ts);
    // 4 + 8 + 999 * 1 = 1011 bytes vs 8000 raw (~7.9x compression)
    try std.testing.expectEqual(@as(usize, 1011), enc_ts.len);
    try std.testing.expectEqual(column.ColumnEncoding.delta, selectBestEncoding(i64, &timestamps));

    const dec_ts = try deltaDecode(i64, allocator, enc_ts, timestamps.len);
    defer allocator.free(dec_ts);
    try std.testing.expectEqualSlices(i64, &timestamps, dec_ts);
}

test "SIMD fixed-width delta and Hillis-Steele parallel prefix-sum decode" {
    const allocator = std.testing.allocator;

    // Non-multiple of 16 and 8 to test both SIMD blocks and scalar tail
    const n32: usize = 71;
    const src32 = try allocator.alignedAlloc(i32, .fromByteUnits(64), n32);
    defer allocator.free(src32);
    const deltas32 = try allocator.alignedAlloc(i32, .fromByteUnits(64), n32);
    defer allocator.free(deltas32);
    const out32 = try allocator.alignedAlloc(i32, .fromByteUnits(64), n32);
    defer allocator.free(out32);

    var prng = std.Random.DefaultPrng.init(0xC0DEC_32);
    const rand = prng.random();
    for (0..n32) |i| src32[i] = rand.int(i32);

    try simdDeltaEncode(i32, src32, deltas32);
    try simdPrefixSumDecode(i32, deltas32, out32);
    try std.testing.expectEqualSlices(i32, src32, out32);

    const n64: usize = 39;
    const src64 = try allocator.alignedAlloc(i64, .fromByteUnits(64), n64);
    defer allocator.free(src64);
    const deltas64 = try allocator.alignedAlloc(i64, .fromByteUnits(64), n64);
    defer allocator.free(deltas64);
    const out64 = try allocator.alignedAlloc(i64, .fromByteUnits(64), n64);
    defer allocator.free(out64);

    for (0..n64) |i| src64[i] = rand.int(i64);
    try simdDeltaEncode(i64, src64, deltas64);
    try simdPrefixSumDecode(i64, deltas64, out64);
    try std.testing.expectEqualSlices(i64, src64, out64);
}

test "Codec rejects malformed and truncated streams safely" {
    const allocator = std.testing.allocator;

    // Truncated header
    try std.testing.expectError(error.CorruptedEncoding, rleDecode(i32, allocator, &.{ 1, 2 }, 1));
    try std.testing.expectError(error.CorruptedEncoding, deltaDecode(i32, allocator, &.{ 1, 2 }, 1));

    // Malicious huge run_count
    const huge_runs = [_]u8{ 0xFF, 0xFF, 0xFF, 0x7F };
    try std.testing.expectError(error.CorruptedEncoding, rleDecode(i32, allocator, &huge_runs, 10));
    try std.testing.expectError(error.CorruptedEncoding, rleSum(i32, &huge_runs));

    // Zero run length
    const zero_run = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0 };
    try std.testing.expectError(error.CorruptedEncoding, rleDecode(i32, allocator, &zero_run, 1));

    // Unterminated varint in delta stream
    const bad_delta = [_]u8{ 2, 0, 0, 0, 1, 0, 0, 0, 0x80, 0x80, 0x80, 0x80, 0x80 };
    try std.testing.expectError(error.CorruptedEncoding, deltaDecode(i32, allocator, &bad_delta, 2));
}

test "Property round-trip for RLE, Delta, and SIMD prefix-sum across sizes and distributions" {
    const allocator = std.testing.allocator;
    const sizes = [_]usize{ 0, 1, 2, 7, 8, 9, 15, 16, 17, 33, 127, 257 };
    var prng = std.Random.DefaultPrng.init(0xC0DE_9999);
    const rand = prng.random();

    for (sizes) |n| {
        const vals32 = try allocator.alignedAlloc(i32, .fromByteUnits(64), n);
        defer allocator.free(vals32);
        const deltas32 = try allocator.alignedAlloc(i32, .fromByteUnits(64), n);
        defer allocator.free(deltas32);
        const restored32 = try allocator.alignedAlloc(i32, .fromByteUnits(64), n);
        defer allocator.free(restored32);

        var expected_sum: i64 = 0;
        for (0..n) |i| {
            // Mix clustered runs and random spikes
            vals32[i] = if (i % 5 < 3) @as(i32, @intCast((i / 5) * 11)) else rand.int(i32);
            expected_sum += vals32[i];
        }

        // RLE round-trip + compressed-domain sum
        const rle = try rleEncode(i32, allocator, vals32);
        defer allocator.free(rle);
        try std.testing.expectEqual(expected_sum, try rleSum(i32, rle));
        const rle_dec = try rleDecode(i32, allocator, rle, n);
        defer allocator.free(rle_dec);
        try std.testing.expectEqualSlices(i32, vals32, rle_dec);

        // Delta + ZigZag round-trip
        const delta = try deltaEncode(i32, allocator, vals32);
        defer allocator.free(delta);
        const delta_dec = try deltaDecode(i32, allocator, delta, n);
        defer allocator.free(delta_dec);
        try std.testing.expectEqualSlices(i32, vals32, delta_dec);

        // SIMD fixed-width delta + Hillis-Steele prefix sum
        try simdDeltaEncode(i32, vals32, deltas32);
        try simdPrefixSumDecode(i32, deltas32, restored32);
        try std.testing.expectEqualSlices(i32, vals32, restored32);
    }
}
