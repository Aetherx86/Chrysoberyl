const std = @import("std");
pub const column = @import("column.zig");

pub const Table = struct {
    allocator: std.mem.Allocator,
    row_count: usize,
    int_columns: [8]?column.Int32Column,
    col_count: usize,

    pub fn init(allocator: std.mem.Allocator, row_count: usize) Table {
        return .{
            .allocator = allocator,
            .row_count = row_count,
            .int_columns = @splat(null),
            .col_count = 0,
        };
    }

    pub fn deinit(self: *Table) void {
        for (0..self.col_count) |i| {
            if (self.int_columns[i]) |*c| {
                c.deinit();
            }
        }
    }

    pub fn addColumn(self: *Table, col: column.Int32Column) !void {
        if (self.col_count >= 8) return error.MaxColumnsExceeded;
        self.int_columns[self.col_count] = col;
        self.col_count += 1;
    }

    pub fn serialize(self: *const Table, allocator: std.mem.Allocator) ![]align(64) u8 {
        const header_size = @sizeOf(column.TableHeader);
        const col_headers_size = self.col_count * @sizeOf(column.ColumnHeader);
        const data_bytes_per_col = self.row_count * @sizeOf(i32);
        const total_size = header_size + col_headers_size + (self.col_count * data_bytes_per_col);

        const aligned_size = (total_size + 63) & ~@as(usize, 63);
        const buffer = try allocator.alignedAlloc(u8, .fromByteUnits(64), aligned_size);
        @memset(buffer, 0);

        // 1. Table Header
        const th = column.TableHeader{
            .magic = [_]u8{ 'C', 'H', 'R', 'Y' },
            .version = 1,
            .row_count = @intCast(self.row_count),
            .column_count = @intCast(self.col_count),
        };
        const th_bytes: *align(1) const [@sizeOf(column.TableHeader)]u8 = @ptrCast(&th);
        @memcpy(buffer[0..header_size], th_bytes);

        // 2. Column Headers and Data Payloads
        var data_offset = header_size + col_headers_size;
        for (0..self.col_count) |i| {
            if (self.int_columns[i]) |*c| {
                const ch = column.ColumnHeader{
                    .col_type = .int32,
                    .length = @intCast(self.row_count),
                    .data_offset = @intCast(data_offset),
                    .null_count = 0,
                };
                const ch_offset = header_size + (i * @sizeOf(column.ColumnHeader));
                const ch_bytes: *align(1) const [@sizeOf(column.ColumnHeader)]u8 = @ptrCast(&ch);
                @memcpy(buffer[ch_offset .. ch_offset + @sizeOf(column.ColumnHeader)], ch_bytes);

                const data_slice: []const u8 = std.mem.sliceAsBytes(c.data);
                @memcpy(buffer[data_offset .. data_offset + data_slice.len], data_slice);
                data_offset += data_slice.len;
            }
        }

        return buffer;
    }
};

pub const TableView = struct {
    row_count: usize,
    col_count: usize,
    buffer: []const u8,

    pub fn fromBytes(buf: []align(64) const u8) !TableView {
        if (buf.len < @sizeOf(column.TableHeader)) return error.BufferTooSmall;

        const th: *const column.TableHeader = @ptrCast(@alignCast(buf.ptr));
        if (!std.mem.eql(u8, &th.magic, "CHRY")) return error.InvalidMagic;

        return TableView{
            .row_count = th.row_count,
            .col_count = th.column_count,
            .buffer = buf,
        };
    }

    pub fn getInt32Column(self: *const TableView, col_idx: usize) ?[]align(4) const i32 {
        if (col_idx >= self.col_count) return null;

        const ch_offset = @sizeOf(column.TableHeader) + (col_idx * @sizeOf(column.ColumnHeader));
        const ch: *align(1) const column.ColumnHeader = @ptrCast(self.buffer.ptr + ch_offset);

        const data_ptr = self.buffer.ptr + ch.data_offset;
        const slice_bytes = data_ptr[0 .. ch.length * @sizeOf(i32)];
        return @alignCast(std.mem.bytesAsSlice(i32, slice_bytes));
    }
};

test "Table Serialization and Zero-Copy Deserialization" {
    const allocator = std.testing.allocator;
    var table = Table.init(allocator, 100);
    defer table.deinit();

    var col = try column.Int32Column.init(allocator, 100);
    for (0..100) |i| {
        col.data[i] = @intCast(i * 10);
    }
    try table.addColumn(col);

    const serialized = try table.serialize(allocator);
    defer allocator.free(serialized);

    const view = try TableView.fromBytes(serialized);
    try std.testing.expectEqual(@as(usize, 100), view.row_count);
    try std.testing.expectEqual(@as(usize, 1), view.col_count);

    const recovered_col = view.getInt32Column(0).?;
    try std.testing.expectEqual(@as(i32, 0), recovered_col[0]);
    try std.testing.expectEqual(@as(i32, 420), recovered_col[42]);
    try std.testing.expectEqual(@as(i32, 990), recovered_col[99]);
}
