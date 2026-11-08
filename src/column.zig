const std = @import("std");

pub const ColumnType = enum(u32) {
    int32 = 1,
    int64 = 2,
    float64 = 3,
};

pub const ColumnHeader = extern struct {
    col_type: ColumnType,
    length: u32,
    data_offset: u64,
    null_count: u32,
    reserved: u32 = 0,
};

pub const TableHeader = extern struct {
    magic: [4]u8 = [_]u8{ 'C', 'H', 'R', 'Y' },
    version: u32 = 1,
    row_count: u32,
    column_count: u32,
};

pub const Int32Column = struct {
    allocator: std.mem.Allocator,
    data: []align(64) i32,

    pub fn init(allocator: std.mem.Allocator, count: usize) !Int32Column {
        const mem = try allocator.alignedAlloc(i32, .fromByteUnits(64), count);
        @memset(mem, 0);
        return Int32Column{
            .allocator = allocator,
            .data = mem,
        };
    }

    pub fn deinit(self: *Int32Column) void {
        self.allocator.free(self.data);
    }

    pub fn sumSimd(self: *const Int32Column) i64 {
        const VEC_SIZE = 16;
        var vec_sum: @Vector(VEC_SIZE, i32) = @splat(0);
        var i: usize = 0;

        while (i + VEC_SIZE <= self.data.len) : (i += VEC_SIZE) {
            const chunk: @Vector(VEC_SIZE, i32) = self.data[i..][0..VEC_SIZE].*;
            vec_sum += chunk;
        }

        var total: i64 = @reduce(.Add, vec_sum);
        while (i < self.data.len) : (i += 1) {
            total += self.data[i];
        }
        return total;
    }

    pub fn filterGreaterThan(self: *const Int32Column, threshold: i32, out_indices: []usize) usize {
        const VEC_SIZE = 16;
        var out_count: usize = 0;
        var i: usize = 0;
        const thresh_vec: @Vector(VEC_SIZE, i32) = @splat(threshold);

        while (i + VEC_SIZE <= self.data.len and out_count + VEC_SIZE <= out_indices.len) : (i += VEC_SIZE) {
            const chunk: @Vector(VEC_SIZE, i32) = self.data[i..][0..VEC_SIZE].*;
            const mask = chunk > thresh_vec;

            inline for (0..VEC_SIZE) |idx| {
                if (mask[idx]) {
                    out_indices[out_count] = i + idx;
                    out_count += 1;
                }
            }
        }

        while (i < self.data.len and out_count < out_indices.len) : (i += 1) {
            if (self.data[i] > threshold) {
                out_indices[out_count] = i;
                out_count += 1;
            }
        }

        return out_count;
    }
};

test "Int32Column SIMD Reduction & Filter" {
    const allocator = std.testing.allocator;
    var col = try Int32Column.init(allocator, 64);
    defer col.deinit();

    // Populate with 1..64
    for (0..64) |i| {
        col.data[i] = @intCast(i + 1);
    }

    // Expected sum: (64 * 65) / 2 = 2080
    const sum = col.sumSimd();
    try std.testing.expectEqual(@as(i64, 2080), sum);

    // Filter > 60: should return 61, 62, 63, 64
    var indices: [64]usize = undefined;
    const count = col.filterGreaterThan(60, &indices);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(usize, 60), indices[0]);
    try std.testing.expectEqual(@as(usize, 63), indices[3]);
}
