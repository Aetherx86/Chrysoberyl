const std = @import("std");
const builtin = @import("builtin");
const column = @import("column.zig");
const table = @import("table.zig");

pub const QueryError = error{
    UnknownColumn,
    ColumnTypeMismatch,
    InvalidPredicateSyntax,
    InvalidValue,
    InvalidRange,
};

pub const ScalarValue = union(column.ColumnType) {
    int32: i32,
    int64: i64,
    float64: f64,
};

pub const PredicateKind = union(enum) {
    compare: struct {
        op: column.CompareOp,
        value: ScalarValue,
    },
    between: struct {
        low: ScalarValue,
        high: ScalarValue,
    },
    is_null,
    is_not_null,
};

pub const Predicate = struct {
    col_idx: usize,
    kind: PredicateKind,
};

pub const CompoundMode = enum {
    and_all,
    or_any,
};

/// 64-byte aligned dense selection bitmask (1 bit per row; 1M rows = 125 KB).
pub const SelectionMask = struct {
    bits: []align(64) u8,
    row_count: usize,

    pub fn initFilled(allocator: std.mem.Allocator, row_count: usize, value: bool) !SelectionMask {
        const byte_len = column.validityByteLen(row_count);
        const bits = try allocator.alignedAlloc(u8, .fromByteUnits(64), byte_len);
        if (byte_len > 0) {
            if (value) {
                @memset(bits, 0xFF);
                maskTrailingBits(bits, row_count);
            } else {
                @memset(bits, 0);
            }
        }
        return .{ .bits = bits, .row_count = row_count };
    }

    pub fn deinit(self: *SelectionMask, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub inline fn isSet(self: *const SelectionMask, idx: usize) bool {
        if (idx >= self.row_count) return false;
        return column.isBitValid(self.bits, idx);
    }

    /// Counts matching rows using SIMD/word-level hardware popcount.
    pub fn count(self: *const SelectionMask) usize {
        var total: usize = 0;
        var i: usize = 0;
        while (i + 8 <= self.bits.len) : (i += 8) {
            const word = std.mem.readInt(u64, self.bits[i..][0..8], .little);
            total += @popCount(word);
        }
        while (i < self.bits.len) : (i += 1) {
            total += @popCount(self.bits[i]);
        }
        return total;
    }

    /// Collects up to `max_rows` (or all if null) matching row indices using `@ctz` bit-scanning.
    pub fn collectIndices(
        self: *const SelectionMask,
        allocator: std.mem.Allocator,
        max_rows: ?usize,
    ) ![]usize {
        const cap = if (max_rows) |m| @min(m, self.count()) else self.count();
        const out = try allocator.alloc(usize, cap);
        var out_idx: usize = 0;

        var byte_idx: usize = 0;
        while (byte_idx + 8 <= self.bits.len and out_idx < cap) : (byte_idx += 8) {
            var word = std.mem.readInt(u64, self.bits[byte_idx..][0..8], .little);
            const base_row = byte_idx << 3;
            while (word != 0 and out_idx < cap) : (word &= word - 1) {
                const bit: usize = @ctz(word);
                out[out_idx] = base_row + bit;
                out_idx += 1;
            }
        }

        while (byte_idx < self.bits.len and out_idx < cap) : (byte_idx += 1) {
            var b = self.bits[byte_idx];
            const base_row = byte_idx << 3;
            while (b != 0 and out_idx < cap) : (b &= b - 1) {
                const bit: usize = @ctz(b);
                out[out_idx] = base_row + bit;
                out_idx += 1;
            }
        }

        return out[0..out_idx];
    }
};

fn maskTrailingBits(bits: []u8, row_count: usize) void {
    if (bits.len == 0) return;
    const rem: u3 = @intCast(row_count & 7);
    if (rem != 0) {
        bits[bits.len - 1] &= (@as(u8, 1) << rem) - 1;
    }
}

inline fn vecMaskToBits(comptime VEC_SIZE: usize, mask: @Vector(VEC_SIZE, bool)) column.MaskInt(VEC_SIZE) {
    if (comptime builtin.cpu.arch.endian() == .little) {
        return @bitCast(mask);
    }
    var bits: column.MaskInt(VEC_SIZE) = 0;
    inline for (0..VEC_SIZE) |lane| {
        if (mask[lane]) {
            bits |= @as(column.MaskInt(VEC_SIZE), 1) << @intCast(lane);
        }
    }
    return bits;
}

fn combineByte(dst: *u8, pred_bits: u8, mode: CompoundMode) void {
    switch (mode) {
        .and_all => dst.* &= pred_bits,
        .or_any => dst.* |= pred_bits,
    }
}

fn combineU16(dst: *[2]u8, pred_bits: u16, mode: CompoundMode) void {
    const cur = std.mem.readInt(u16, dst, .little);
    const next = switch (mode) {
        .and_all => cur & pred_bits,
        .or_any => cur | pred_bits,
    };
    std.mem.writeInt(u16, dst, next, .little);
}

fn applyTypedCompare(
    comptime T: type,
    slice: column.ColumnSlice(T),
    op: column.CompareOp,
    threshold: T,
    mask: *SelectionMask,
    mode: CompoundMode,
) void {
    const VEC_SIZE = column.VectorWidth(T);
    const thresh_vec: @Vector(VEC_SIZE, T) = @splat(threshold);
    var i: usize = 0;

    while (i + VEC_SIZE <= slice.data.len) : (i += VEC_SIZE) {
        const byte_idx = i >> 3;
        // Short-circuit: for AND mode, skip SIMD load/compare if block already has zero candidates.
        if (mode == .and_all) {
            if (comptime VEC_SIZE == 16) {
                if (std.mem.readInt(u16, mask.bits[byte_idx..][0..2], .little) == 0) continue;
            } else {
                if (mask.bits[byte_idx] == 0) continue;
            }
        }

        const chunk: @Vector(VEC_SIZE, T) = slice.data[i..][0..VEC_SIZE].*;
        var bits = vecMaskToBits(VEC_SIZE, column.CompareOp.evalVec(VEC_SIZE, T, op, chunk, thresh_vec));
        if (slice.validity) |bm| {
            if (comptime VEC_SIZE == 16) {
                bits &= std.mem.readInt(u16, bm[byte_idx..][0..2], .little);
            } else {
                bits &= bm[byte_idx];
            }
        }

        if (comptime VEC_SIZE == 16) {
            combineU16(mask.bits[byte_idx..][0..2], bits, mode);
        } else {
            combineByte(&mask.bits[byte_idx], bits, mode);
        }
    }

    while (i < slice.data.len) : (i += 1) {
        const matched = slice.isValid(i) and column.CompareOp.evalScalar(T, op, slice.data[i], threshold);
        const bit_mask: u8 = @as(u8, 1) << @intCast(i & 7);
        switch (mode) {
            .and_all => if (!matched) {
                mask.bits[i >> 3] &= ~bit_mask;
            },
            .or_any => if (matched) {
                mask.bits[i >> 3] |= bit_mask;
            },
        }
    }
}

fn applyTypedBetween(
    comptime T: type,
    slice: column.ColumnSlice(T),
    low: T,
    high: T,
    mask: *SelectionMask,
    mode: CompoundMode,
) void {
    const VEC_SIZE = column.VectorWidth(T);
    const low_vec: @Vector(VEC_SIZE, T) = @splat(low);
    const high_vec: @Vector(VEC_SIZE, T) = @splat(high);
    var i: usize = 0;

    while (i + VEC_SIZE <= slice.data.len) : (i += VEC_SIZE) {
        const byte_idx = i >> 3;
        if (mode == .and_all) {
            if (comptime VEC_SIZE == 16) {
                if (std.mem.readInt(u16, mask.bits[byte_idx..][0..2], .little) == 0) continue;
            } else {
                if (mask.bits[byte_idx] == 0) continue;
            }
        }

        const chunk: @Vector(VEC_SIZE, T) = slice.data[i..][0..VEC_SIZE].*;
        var bits = vecMaskToBits(VEC_SIZE, chunk >= low_vec) & vecMaskToBits(VEC_SIZE, chunk <= high_vec);
        if (slice.validity) |bm| {
            if (comptime VEC_SIZE == 16) {
                bits &= std.mem.readInt(u16, bm[byte_idx..][0..2], .little);
            } else {
                bits &= bm[byte_idx];
            }
        }

        if (comptime VEC_SIZE == 16) {
            combineU16(mask.bits[byte_idx..][0..2], bits, mode);
        } else {
            combineByte(&mask.bits[byte_idx], bits, mode);
        }
    }

    while (i < slice.data.len) : (i += 1) {
        const matched = slice.isValid(i) and slice.data[i] >= low and slice.data[i] <= high;
        const bit_mask: u8 = @as(u8, 1) << @intCast(i & 7);
        switch (mode) {
            .and_all => if (!matched) {
                mask.bits[i >> 3] &= ~bit_mask;
            },
            .or_any => if (matched) {
                mask.bits[i >> 3] |= bit_mask;
            },
        }
    }
}

fn applyNullPredicate(
    validity: ?[]const u8,
    want_null: bool,
    mask: *SelectionMask,
    mode: CompoundMode,
) void {
    if (validity) |bm| {
        for (0..mask.bits.len) |b_idx| {
            const pred_bits = if (want_null) ~bm[b_idx] else bm[b_idx];
            combineByte(&mask.bits[b_idx], pred_bits, mode);
        }
    } else {
        // Column has no nulls at all.
        const fill: u8 = if (want_null) 0x00 else 0xFF;
        for (0..mask.bits.len) |b_idx| {
            combineByte(&mask.bits[b_idx], fill, mode);
        }
    }
    maskTrailingBits(mask.bits, mask.row_count);
}

/// Evaluates a list of multi-column predicates over a zero-copy TableView using SIMD bitmasks.
/// Plain columns execute zero-copy; compressed columns are transparently decoded on demand.
pub fn evaluate(
    allocator: std.mem.Allocator,
    view: *const table.TableView,
    predicates: []const Predicate,
    mode: CompoundMode,
) !SelectionMask {
    if (predicates.len == 0) {
        return SelectionMask.initFilled(allocator, view.row_count, true);
    }

    var mask = try SelectionMask.initFilled(allocator, view.row_count, mode == .and_all);
    errdefer mask.deinit(allocator);

    for (predicates) |pred| {
        const info = view.getColumnInfo(pred.col_idx) orelse return error.UnknownColumn;
        switch (pred.kind) {
            .is_null => applyNullPredicate(view.getValidityBitmap(pred.col_idx), true, &mask, mode),
            .is_not_null => applyNullPredicate(view.getValidityBitmap(pred.col_idx), false, &mask, mode),
            .compare => |cmp| {
                if (std.meta.activeTag(cmp.value) != info.col_type) return error.ColumnTypeMismatch;
                switch (info.col_type) {
                    .int32 => {
                        if (view.getColumnSlice(i32, pred.col_idx)) |slice| {
                            applyTypedCompare(i32, slice, cmp.op, cmp.value.int32, &mask, mode);
                        } else {
                            var dec = try view.decodeColumn(i32, allocator, pred.col_idx);
                            defer dec.deinit();
                            applyTypedCompare(i32, dec.asSlice(), cmp.op, cmp.value.int32, &mask, mode);
                        }
                    },
                    .int64 => {
                        if (view.getColumnSlice(i64, pred.col_idx)) |slice| {
                            applyTypedCompare(i64, slice, cmp.op, cmp.value.int64, &mask, mode);
                        } else {
                            var dec = try view.decodeColumn(i64, allocator, pred.col_idx);
                            defer dec.deinit();
                            applyTypedCompare(i64, dec.asSlice(), cmp.op, cmp.value.int64, &mask, mode);
                        }
                    },
                    .float64 => {
                        if (view.getColumnSlice(f64, pred.col_idx)) |slice| {
                            applyTypedCompare(f64, slice, cmp.op, cmp.value.float64, &mask, mode);
                        } else {
                            var dec = try view.decodeColumn(f64, allocator, pred.col_idx);
                            defer dec.deinit();
                            applyTypedCompare(f64, dec.asSlice(), cmp.op, cmp.value.float64, &mask, mode);
                        }
                    },
                }
            },
            .between => |rng| {
                if (std.meta.activeTag(rng.low) != info.col_type or std.meta.activeTag(rng.high) != info.col_type) {
                    return error.ColumnTypeMismatch;
                }
                switch (info.col_type) {
                    .int32 => {
                        if (view.getColumnSlice(i32, pred.col_idx)) |slice| {
                            applyTypedBetween(i32, slice, rng.low.int32, rng.high.int32, &mask, mode);
                        } else {
                            var dec = try view.decodeColumn(i32, allocator, pred.col_idx);
                            defer dec.deinit();
                            applyTypedBetween(i32, dec.asSlice(), rng.low.int32, rng.high.int32, &mask, mode);
                        }
                    },
                    .int64 => {
                        if (view.getColumnSlice(i64, pred.col_idx)) |slice| {
                            applyTypedBetween(i64, slice, rng.low.int64, rng.high.int64, &mask, mode);
                        } else {
                            var dec = try view.decodeColumn(i64, allocator, pred.col_idx);
                            defer dec.deinit();
                            applyTypedBetween(i64, dec.asSlice(), rng.low.int64, rng.high.int64, &mask, mode);
                        }
                    },
                    .float64 => {
                        if (view.getColumnSlice(f64, pred.col_idx)) |slice| {
                            applyTypedBetween(f64, slice, rng.low.float64, rng.high.float64, &mask, mode);
                        } else {
                            var dec = try view.decodeColumn(f64, allocator, pred.col_idx);
                            defer dec.deinit();
                            applyTypedBetween(f64, dec.asSlice(), rng.low.float64, rng.high.float64, &mask, mode);
                        }
                    },
                }
            },
        }
    }

    maskTrailingBits(mask.bits, mask.row_count);
    return mask;
}

pub const AggregateResult = union(column.ColumnType) {
    int32: column.ColumnStats(i32),
    int64: column.ColumnStats(i64),
    float64: column.ColumnStats(f64),
};

fn aggregateTypedMasked(comptime T: type, slice: column.ColumnSlice(T), mask: *const SelectionMask) column.ColumnStats(T) {
    var matched_count: usize = 0;
    var valid_count: usize = 0;
    var sum_val: column.SumType(T) = 0;
    var min_val: T = undefined;
    var max_val: T = undefined;
    var has_minmax = false;

    var byte_idx: usize = 0;
    while (byte_idx + 8 <= mask.bits.len) : (byte_idx += 8) {
        var word = std.mem.readInt(u64, mask.bits[byte_idx..][0..8], .little);
        if (word == 0) continue;
        const base_row = byte_idx << 3;
        while (word != 0) : (word &= word - 1) {
            const row = base_row + @ctz(word);
            matched_count += 1;
            if (!slice.isValid(row)) continue;
            valid_count += 1;
            const v = slice.data[row];
            sum_val += v;
            if (comptime T == f64) {
                if (std.math.isNan(v)) continue;
            }
            if (!has_minmax) {
                min_val = v;
                max_val = v;
                has_minmax = true;
            } else {
                if (v < min_val) min_val = v;
                if (v > max_val) max_val = v;
            }
        }
    }

    while (byte_idx < mask.bits.len) : (byte_idx += 1) {
        var b = mask.bits[byte_idx];
        if (b == 0) continue;
        const base_row = byte_idx << 3;
        while (b != 0) : (b &= b - 1) {
            const row = base_row + @ctz(b);
            matched_count += 1;
            if (!slice.isValid(row)) continue;
            valid_count += 1;
            const v = slice.data[row];
            sum_val += v;
            if (comptime T == f64) {
                if (std.math.isNan(v)) continue;
            }
            if (!has_minmax) {
                min_val = v;
                max_val = v;
                has_minmax = true;
            } else {
                if (v < min_val) min_val = v;
                if (v > max_val) max_val = v;
            }
        }
    }

    const mean_val: ?f64 = if (valid_count == 0)
        null
    else if (comptime T == f64)
        sum_val / @as(f64, @floatFromInt(valid_count))
    else
        @as(f64, @floatFromInt(sum_val)) / @as(f64, @floatFromInt(valid_count));

    return .{
        .count = matched_count,
        .valid_count = valid_count,
        .null_count = matched_count - valid_count,
        .sum = sum_val,
        .min = if (has_minmax) min_val else null,
        .max = if (has_minmax) max_val else null,
        .mean = mean_val,
    };
}

/// Computes summary aggregation on `target_col_idx`, optionally restricted by `mask`.
pub fn aggregate(
    allocator: std.mem.Allocator,
    view: *const table.TableView,
    target_col_idx: usize,
    mask: ?*const SelectionMask,
) !AggregateResult {
    const info = view.getColumnInfo(target_col_idx) orelse return error.UnknownColumn;

    switch (info.col_type) {
        .int32 => {
            if (view.getColumnSlice(i32, target_col_idx)) |slice| {
                return .{ .int32 = if (mask) |m| aggregateTypedMasked(i32, slice, m) else slice.statsSimd() };
            }
            var dec = try view.decodeColumn(i32, allocator, target_col_idx);
            defer dec.deinit();
            return .{ .int32 = if (mask) |m| aggregateTypedMasked(i32, dec.asSlice(), m) else dec.statsSimd() };
        },
        .int64 => {
            if (view.getColumnSlice(i64, target_col_idx)) |slice| {
                return .{ .int64 = if (mask) |m| aggregateTypedMasked(i64, slice, m) else slice.statsSimd() };
            }
            var dec = try view.decodeColumn(i64, allocator, target_col_idx);
            defer dec.deinit();
            return .{ .int64 = if (mask) |m| aggregateTypedMasked(i64, dec.asSlice(), m) else dec.statsSimd() };
        },
        .float64 => {
            if (view.getColumnSlice(f64, target_col_idx)) |slice| {
                return .{ .float64 = if (mask) |m| aggregateTypedMasked(f64, slice, m) else slice.statsSimd() };
            }
            var dec = try view.decodeColumn(f64, allocator, target_col_idx);
            defer dec.deinit();
            return .{ .float64 = if (mask) |m| aggregateTypedMasked(f64, dec.asSlice(), m) else dec.statsSimd() };
        },
    }
}

pub fn resolveColumn(view: *const table.TableView, col_ref: []const u8) QueryError!usize {
    if (view.findColumnByName(col_ref)) |idx| return idx;
    const parsed = std.fmt.parseInt(usize, col_ref, 10) catch return error.UnknownColumn;
    if (parsed >= view.col_count) return error.UnknownColumn;
    return parsed;
}

fn parseScalar(col_type: column.ColumnType, raw: []const u8) QueryError!ScalarValue {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return error.InvalidValue;
    return switch (col_type) {
        .int32 => .{ .int32 = std.fmt.parseInt(i32, trimmed, 10) catch return error.InvalidValue },
        .int64 => .{ .int64 = std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidValue },
        .float64 => .{ .float64 = std.fmt.parseFloat(f64, trimmed) catch return error.InvalidValue },
    };
}

/// Parses a predicate string against `view`'s schema.
/// Supported forms:
/// - `col==val`, `col!=val`, `col<=val`, `col>=val`, `col<val`, `col>val`, `col=val`
/// - `col[low..high]` (inclusive range)
/// - `col:null`, `col:notnull`
pub fn parsePredicate(view: *const table.TableView, spec: []const u8) QueryError!Predicate {
    const s = std.mem.trim(u8, spec, " \t");
    if (s.len == 0) return error.InvalidPredicateSyntax;

    // 1. Null predicates: col:null / col:notnull
    if (std.mem.endsWith(u8, s, ":notnull")) {
        const col_name = std.mem.trim(u8, s[0 .. s.len - ":notnull".len], " \t");
        const col_idx = try resolveColumn(view, col_name);
        return .{ .col_idx = col_idx, .kind = .is_not_null };
    }
    if (std.mem.endsWith(u8, s, ":null")) {
        const col_name = std.mem.trim(u8, s[0 .. s.len - ":null".len], " \t");
        const col_idx = try resolveColumn(view, col_name);
        return .{ .col_idx = col_idx, .kind = .is_null };
    }

    // 2. Range predicate: col[low..high]
    if (std.mem.indexOfScalar(u8, s, '[')) |open_idx| {
        if (!std.mem.endsWith(u8, s, "]")) return error.InvalidPredicateSyntax;
        const col_name = std.mem.trim(u8, s[0..open_idx], " \t");
        const col_idx = try resolveColumn(view, col_name);
        const info = view.getColumnInfo(col_idx) orelse return error.UnknownColumn;

        const inner = s[open_idx + 1 .. s.len - 1];
        const dots = std.mem.indexOf(u8, inner, "..") orelse return error.InvalidPredicateSyntax;
        const low = try parseScalar(info.col_type, inner[0..dots]);
        const high = try parseScalar(info.col_type, inner[dots + 2 ..]);
        return .{
            .col_idx = col_idx,
            .kind = .{ .between = .{ .low = low, .high = high } },
        };
    }

    // 3. Binary comparison operators (check 2-char operators before 1-char)
    const OpToken = struct { tok: []const u8, op: column.CompareOp };
    const ops = [_]OpToken{
        .{ .tok = ">=", .op = .ge },
        .{ .tok = "<=", .op = .le },
        .{ .tok = "!=", .op = .ne },
        .{ .tok = "==", .op = .eq },
        .{ .tok = ">", .op = .gt },
        .{ .tok = "<", .op = .lt },
        .{ .tok = "=", .op = .eq },
    };

    for (ops) |entry| {
        if (std.mem.indexOf(u8, s, entry.tok)) |pos| {
            const col_name = std.mem.trim(u8, s[0..pos], " \t");
            const val_str = std.mem.trim(u8, s[pos + entry.tok.len ..], " \t");
            if (col_name.len == 0 or val_str.len == 0) return error.InvalidPredicateSyntax;

            const col_idx = try resolveColumn(view, col_name);
            const info = view.getColumnInfo(col_idx) orelse return error.UnknownColumn;
            const value = try parseScalar(info.col_type, val_str);

            return .{
                .col_idx = col_idx,
                .kind = .{ .compare = .{ .op = entry.op, .value = value } },
            };
        }
    }

    return error.InvalidPredicateSyntax;
}

test "Multi-column SIMD query evaluation (AND, OR, range, null) and filtered aggregation" {
    const allocator = std.testing.allocator;
    const rows: usize = 128;

    var tbl = table.Table.init(allocator, rows);
    defer tbl.deinit();

    var ids = try column.Int64Column.init(allocator, rows);
    var cat = try column.Int32Column.init(allocator, rows);
    var price = try column.Float64Column.init(allocator, rows);
    for (0..rows) |i| {
        ids.data[i] = @intCast(i);
        cat.data[i] = @intCast(i % 4);
        price.data[i] = @as(f64, @floatFromInt(i)) * 10.0;
    }
    try price.setNull(4); // cat=0, price=null
    try price.setNull(8); // cat=0, price=null
    try tbl.addNamedInt64Column("id", ids);
    try tbl.addNamedInt32Column("category", cat);
    try tbl.addNamedFloat64Column("price", price);

    const bytes = try tbl.serialize(allocator);
    defer allocator.free(bytes);
    const view = try table.TableView.fromBytesVerified(bytes);

    // Query: category==0 AND price[0..200]
    // Rows with category==0 in [0..20]: 0, 4(null), 8(null), 12, 16, 20 -> 4 valid rows
    const p1 = try parsePredicate(&view, "category==0");
    const p2 = try parsePredicate(&view, "price[0.0..200.0]");
    var mask = try evaluate(allocator, &view, &.{ p1, p2 }, .and_all);
    defer mask.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), mask.count());
    const indices = try mask.collectIndices(allocator, null);
    defer allocator.free(indices);
    try std.testing.expectEqualSlices(usize, &.{ 0, 12, 16, 20 }, indices);

    const agg = try aggregate(allocator, &view, 2, &mask);
    try std.testing.expectEqual(@as(usize, 4), agg.float64.valid_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0 + 120.0 + 160.0 + 200.0), agg.float64.sum, 1e-9);
    try std.testing.expectEqual(@as(?f64, 0.0), agg.float64.min);
    try std.testing.expectEqual(@as(?f64, 200.0), agg.float64.max);

    // Null predicate: price:null -> rows 4, 8
    const p_null = try parsePredicate(&view, "price:null");
    var null_mask = try evaluate(allocator, &view, &.{p_null}, .and_all);
    defer null_mask.deinit(allocator);
    const null_rows = try null_mask.collectIndices(allocator, null);
    defer allocator.free(null_rows);
    try std.testing.expectEqualSlices(usize, &.{ 4, 8 }, null_rows);

    // Disjunction (OR): id<2 OR id>=126 -> 4 rows (0, 1, 126, 127)
    const p_lo = try parsePredicate(&view, "id<2");
    const p_hi = try parsePredicate(&view, "id>=126");
    var or_mask = try evaluate(allocator, &view, &.{ p_lo, p_hi }, .or_any);
    defer or_mask.deinit(allocator);
    const or_rows = try or_mask.collectIndices(allocator, null);
    defer allocator.free(or_rows);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 126, 127 }, or_rows);
}

test "Query executes transparently over RLE/Delta compressed tables" {
    const allocator = std.testing.allocator;
    const rows: usize = 200;
    var tbl = table.Table.init(allocator, rows);
    defer tbl.deinit();

    var ts = try column.Int64Column.init(allocator, rows);
    var grp = try column.Int32Column.init(allocator, rows);
    for (0..rows) |i| {
        ts.data[i] = 1000 + @as(i64, @intCast(i));
        grp.data[i] = @intCast(i / 50); // 4 runs of 50
    }
    try tbl.addNamedInt64Column("ts", ts);
    try tbl.addNamedInt32Column("grp", grp);

    const compressed = try tbl.serializeWithOptions(allocator, .{ .encoding = .auto });
    defer allocator.free(compressed);
    const view = try table.TableView.fromBytesVerified(compressed);

    const p1 = try parsePredicate(&view, "grp==2");
    const p2 = try parsePredicate(&view, "ts>=1125");
    var mask = try evaluate(allocator, &view, &.{ p1, p2 }, .and_all);
    defer mask.deinit(allocator);

    // grp==2 is rows 100..149; ts>=1125 is rows 125..199 -> intersection is 125..149 (25 rows)
    try std.testing.expectEqual(@as(usize, 25), mask.count());
    const agg = try aggregate(allocator, &view, 0, &mask);
    try std.testing.expectEqual(@as(?i64, 1125), agg.int64.min);
    try std.testing.expectEqual(@as(?i64, 1149), agg.int64.max);
}

test "Differential query engine check across row counts, nulls, AND/OR, and parser errors" {
    const allocator = std.testing.allocator;
    const row_counts = [_]usize{ 0, 1, 7, 15, 16, 17, 63, 64, 65, 259 };
    var prng = std.Random.DefaultPrng.init(0x90E7_2026);
    const rand = prng.random();

    for (row_counts) |rows| {
        var tbl = table.Table.init(allocator, rows);
        defer tbl.deinit();

        var a = try column.Int32Column.init(allocator, rows);
        var b = try column.Float64Column.init(allocator, rows);
        for (0..rows) |i| {
            a.data[i] = rand.intRangeAtMost(i32, -50, 50);
            b.data[i] = @as(f64, @floatFromInt(rand.intRangeAtMost(i32, 0, 200))) * 0.5;
            if (rand.intRangeLessThan(u8, 0, 10) == 0) try a.setNull(i);
            if (rand.intRangeLessThan(u8, 0, 10) == 0) try b.setNull(i);
        }
        try tbl.addNamedInt32Column("a", a);
        try tbl.addNamedFloat64Column("b", b);

        const bytes = try tbl.serialize(allocator);
        defer allocator.free(bytes);
        const view = try table.TableView.fromBytesVerified(bytes);

        const p1 = try parsePredicate(&view, "a>=-10");
        const p2 = try parsePredicate(&view, "b[20.0..75.0]");
        const p3 = try parsePredicate(&view, "0:notnull"); // numeric column index syntax

        for ([_]CompoundMode{ .and_all, .or_any }) |mode| {
            var mask = try evaluate(allocator, &view, &.{ p1, p2, p3 }, mode);
            defer mask.deinit(allocator);

            const a_slice = view.getColumnSlice(i32, 0).?;
            const b_slice = view.getColumnSlice(f64, 1).?;

            var ref_matches: usize = 0;
            var ref_valid_b: usize = 0;
            var ref_sum_b: f64 = 0.0;
            for (0..rows) |r| {
                const m1 = a_slice.isValid(r) and a_slice.data[r] >= -10;
                const m2 = b_slice.isValid(r) and b_slice.data[r] >= 20.0 and b_slice.data[r] <= 75.0;
                const m3 = a_slice.isValid(r);
                const expected = switch (mode) {
                    .and_all => m1 and m2 and m3,
                    .or_any => m1 or m2 or m3,
                };
                try std.testing.expectEqual(expected, mask.isSet(r));
                if (expected) {
                    ref_matches += 1;
                    if (b_slice.isValid(r)) {
                        ref_valid_b += 1;
                        ref_sum_b += b_slice.data[r];
                    }
                }
            }

            try std.testing.expectEqual(ref_matches, mask.count());
            const agg = try aggregate(allocator, &view, 1, &mask);
            try std.testing.expectEqual(ref_valid_b, agg.float64.valid_count);
            try std.testing.expectApproxEqAbs(ref_sum_b, agg.float64.sum, 1e-6);
        }

        // Parser error handling checks (once on non-empty table)
        if (rows == 16) {
            try std.testing.expectError(error.UnknownColumn, parsePredicate(&view, "missing==1"));
            try std.testing.expectError(error.InvalidValue, parsePredicate(&view, "a==notanint"));
            try std.testing.expectError(error.InvalidPredicateSyntax, parsePredicate(&view, "a[1..2"));
            try std.testing.expectError(error.InvalidPredicateSyntax, parsePredicate(&view, "no_operator_here"));
        }
    }
}
