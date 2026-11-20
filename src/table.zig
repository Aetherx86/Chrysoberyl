const std = @import("std");
pub const column = @import("column.zig");
pub const codec = @import("codec.zig");

pub const Column = union(column.ColumnType) {
    int32: column.Int32Column,
    int64: column.Int64Column,
    float64: column.Float64Column,

    pub fn deinit(self: *Column) void {
        switch (self.*) {
            .int32 => |*c| c.deinit(),
            .int64 => |*c| c.deinit(),
            .float64 => |*c| c.deinit(),
        }
    }

    pub fn len(self: *const Column) usize {
        return switch (self.*) {
            .int32 => |*c| c.data.len,
            .int64 => |*c| c.data.len,
            .float64 => |*c| c.data.len,
        };
    }

    pub fn nullCount(self: *const Column) usize {
        return switch (self.*) {
            .int32 => |*c| c.nullCount(),
            .int64 => |*c| c.nullCount(),
            .float64 => |*c| c.nullCount(),
        };
    }

    pub fn validityBytes(self: *const Column) ?[]const u8 {
        return switch (self.*) {
            .int32 => |*c| if (c.validity) |bm| bm else null,
            .int64 => |*c| if (c.validity) |bm| bm else null,
            .float64 => |*c| if (c.validity) |bm| bm else null,
        };
    }

    pub fn colType(self: *const Column) column.ColumnType {
        return std.meta.activeTag(self.*);
    }
};

pub const NamedColumn = struct {
    name: ?[]u8 = null,
    col: Column,
};

pub const EncodingPolicy = enum {
    plain,
    rle,
    delta,
    auto,
};

pub const SerializeOptions = struct {
    encoding: EncodingPolicy = .plain,
    compute_checksum: bool = true,
};

pub const ColumnInfo = struct {
    index: usize,
    name: ?[]const u8,
    col_type: column.ColumnType,
    encoding: column.ColumnEncoding,
    length: usize,
    null_count: usize,
    data_offset: usize,
    data_byte_len: usize,
    validity_offset: usize,
    is_cache_line_aligned: bool,
};

pub const TableError = error{
    RowCountMismatch,
    BufferTooSmall,
    InvalidMagic,
    UnsupportedVersion,
    InvalidColumnType,
    InvalidColumnEncoding,
    CorruptedHeader,
    UnalignedColumnData,
    NoChecksum,
    ChecksumMismatch,
    ColumnOutOfBounds,
    ColumnTypeMismatch,
    UnsupportedV1Column,
};

/// Slicing-by-8 IEEE CRC-32/ISO-HDLC implementation (bit-identical to std.hash.Crc32, ~8x faster).
pub const FastCrc32 = struct {
    const tables: [8][256]u32 = blk: {
        @setEvalBranchQuota(20_000);
        var t: [8][256]u32 = undefined;
        for (0..256) |i| {
            var c: u32 = @intCast(i);
            for (0..8) |_| {
                c = if ((c & 1) != 0) (c >> 1) ^ 0xEDB88320 else (c >> 1);
            }
            t[0][i] = c;
        }
        for (1..8) |k| {
            for (0..256) |i| {
                const prev = t[k - 1][i];
                t[k][i] = (prev >> 8) ^ t[0][prev & 0xFF];
            }
        }
        break :blk t;
    };

    crc: u32 = 0xFFFF_FFFF,

    pub fn init() FastCrc32 {
        return .{ .crc = 0xFFFF_FFFF };
    }

    pub fn update(self: *FastCrc32, bytes: []const u8) void {
        var crc = self.crc;
        var i: usize = 0;

        while (i + 8 <= bytes.len) : (i += 8) {
            const lo = std.mem.readInt(u32, bytes[i..][0..4], .little) ^ crc;
            const hi = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
            crc = tables[7][lo & 0xFF] ^
                tables[6][(lo >> 8) & 0xFF] ^
                tables[5][(lo >> 16) & 0xFF] ^
                tables[4][lo >> 24] ^
                tables[3][hi & 0xFF] ^
                tables[2][(hi >> 8) & 0xFF] ^
                tables[1][(hi >> 16) & 0xFF] ^
                tables[0][hi >> 24];
        }

        while (i < bytes.len) : (i += 1) {
            crc = (crc >> 8) ^ tables[0][(crc ^ bytes[i]) & 0xFF];
        }
        self.crc = crc;
    }

    pub fn final(self: FastCrc32) u32 {
        return ~self.crc;
    }

    pub fn hash(bytes: []const u8) u32 {
        var h = FastCrc32.init();
        h.update(bytes);
        return h.final();
    }
};

fn computeTableCrc32(buf: []const u8, total_bytes: usize) u32 {
    // Checksum covers the entire serialized image except the 4-byte checksum field at [20..24].
    var hasher = FastCrc32.init();
    hasher.update(buf[0..20]);
    hasher.update(buf[24..total_bytes]);
    return hasher.final();
}

pub const Table = struct {
    allocator: std.mem.Allocator,
    row_count: usize,
    col_count: usize,
    columns: std.ArrayList(NamedColumn),

    pub fn init(allocator: std.mem.Allocator, row_count: usize) Table {
        return .{
            .allocator = allocator,
            .row_count = row_count,
            .col_count = 0,
            .columns = .empty,
        };
    }

    pub fn deinit(self: *Table) void {
        for (self.columns.items) |*entry| {
            if (entry.name) |n| self.allocator.free(n);
            entry.col.deinit();
        }
        self.columns.deinit(self.allocator);
        self.col_count = 0;
    }

    pub fn addTypedColumn(self: *Table, name: ?[]const u8, col: Column) !void {
        if (col.len() != self.row_count) return error.RowCountMismatch;
        const owned_name: ?[]u8 = if (name) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (owned_name) |n| self.allocator.free(n);

        try self.columns.append(self.allocator, .{
            .name = owned_name,
            .col = col,
        });
        self.col_count = self.columns.items.len;
    }

    /// Backward-compatible Int32 column insertion.
    pub fn addColumn(self: *Table, col: column.Int32Column) !void {
        try self.addTypedColumn(null, .{ .int32 = col });
    }

    pub fn addNamedInt32Column(self: *Table, name: []const u8, col: column.Int32Column) !void {
        try self.addTypedColumn(name, .{ .int32 = col });
    }

    pub fn addInt64Column(self: *Table, col: column.Int64Column) !void {
        try self.addTypedColumn(null, .{ .int64 = col });
    }

    pub fn addNamedInt64Column(self: *Table, name: []const u8, col: column.Int64Column) !void {
        try self.addTypedColumn(name, .{ .int64 = col });
    }

    pub fn addFloat64Column(self: *Table, col: column.Float64Column) !void {
        try self.addTypedColumn(null, .{ .float64 = col });
    }

    pub fn addNamedFloat64Column(self: *Table, name: []const u8, col: column.Float64Column) !void {
        try self.addTypedColumn(name, .{ .float64 = col });
    }

    pub fn columnCount(self: *const Table) usize {
        return self.columns.items.len;
    }

    /// Serializes into Chrysoberyl v2 format with 64-byte aligned column payloads,
    /// schema names, validity bitmaps, and CRC32 integrity checksum.
    pub fn serialize(self: *const Table, allocator: std.mem.Allocator) ![]align(64) u8 {
        return self.serializeWithOptions(allocator, .{});
    }

    pub fn serializeWithOptions(
        self: *const Table,
        allocator: std.mem.Allocator,
        options: SerializeOptions,
    ) ![]align(64) u8 {
        const col_n = self.columns.items.len;

        const PreparedPayload = struct {
            encoding: column.ColumnEncoding,
            bytes: []const u8,
            owned: bool,
        };

        const payloads = try allocator.alloc(PreparedPayload, col_n);
        defer {
            for (payloads) |p| {
                if (p.owned) allocator.free(p.bytes);
            }
            allocator.free(payloads);
        }
        @memset(payloads, .{ .encoding = .plain, .bytes = &.{}, .owned = false });

        var schema_size: usize = 0;
        for (self.columns.items, 0..) |*entry, i| {
            if (entry.name) |n| schema_size += n.len;

            const chosen = resolveEncoding(&entry.col, options.encoding);
            switch (chosen) {
                .plain => {
                    payloads[i] = .{
                        .encoding = .plain,
                        .bytes = rawColumnBytes(&entry.col),
                        .owned = false,
                    };
                },
                .rle => {
                    const encoded = switch (entry.col) {
                        .int32 => |*c| try codec.rleEncode(i32, allocator, c.data),
                        .int64 => |*c| try codec.rleEncode(i64, allocator, c.data),
                        .float64 => |*c| try codec.rleEncode(f64, allocator, c.data),
                    };
                    payloads[i] = .{ .encoding = .rle, .bytes = encoded, .owned = true };
                },
                .delta => {
                    const encoded = switch (entry.col) {
                        .int32 => |*c| try codec.deltaEncode(i32, allocator, c.data),
                        .int64 => |*c| try codec.deltaEncode(i64, allocator, c.data),
                        .float64 => unreachable,
                    };
                    payloads[i] = .{ .encoding = .delta, .bytes = encoded, .owned = true };
                },
            }
        }

        const fixed_header_size = @sizeOf(column.TableHeader) + @sizeOf(column.TableHeaderExt); // 64
        const col_headers_size = col_n * @sizeOf(column.ColumnHeaderV2);
        const schema_offset: usize = if (schema_size > 0) fixed_header_size + col_headers_size else 0;

        // First pass: calculate exact 64-byte aligned offsets and total buffer size.
        var cursor: usize = fixed_header_size + col_headers_size + schema_size;
        const data_offsets = try allocator.alloc(usize, col_n);
        defer allocator.free(data_offsets);
        const validity_offsets = try allocator.alloc(usize, col_n);
        defer allocator.free(validity_offsets);

        for (self.columns.items, 0..) |*entry, i| {
            cursor = column.alignUp64(cursor);
            data_offsets[i] = cursor;
            cursor += payloads[i].bytes.len;

            if (entry.col.validityBytes() != null and entry.col.nullCount() > 0) {
                cursor = column.alignUp64(cursor);
                validity_offsets[i] = cursor;
                cursor += column.validityByteLen(self.row_count);
            } else {
                validity_offsets[i] = 0;
            }
        }

        const total_bytes = column.alignUp64(cursor);
        const buffer = try allocator.alignedAlloc(u8, .fromByteUnits(64), total_bytes);
        errdefer allocator.free(buffer);
        @memset(buffer, 0);

        // 1. Write TableHeader (bytes 0..16)
        const th = column.TableHeader{
            .magic = column.FORMAT_MAGIC,
            .version = column.FORMAT_VERSION_V2,
            .row_count = @intCast(self.row_count),
            .column_count = @intCast(col_n),
        };
        @memcpy(buffer[0..@sizeOf(column.TableHeader)], std.mem.asBytes(&th));

        // 2. Write TableHeaderExt (bytes 16..64)
        var flags: u32 = 0;
        if (options.compute_checksum) flags |= column.FLAG_HAS_CHECKSUM;
        if (schema_size > 0) flags |= column.FLAG_HAS_SCHEMA;

        var ext = column.TableHeaderExt{
            .flags = flags,
            .checksum_crc32 = 0,
            .total_bytes = @intCast(total_bytes),
            .schema_offset = @intCast(schema_offset),
            .schema_size = @intCast(schema_size),
        };
        @memcpy(buffer[16..64], std.mem.asBytes(&ext));

        // 3. Write ColumnHeaderV2[], Schema Blob, Payloads, and Validity Bitmaps
        var name_cursor: u32 = 0;
        for (self.columns.items, 0..) |*entry, i| {
            var name_off: u32 = 0;
            var name_len: u32 = 0;
            if (entry.name) |n| {
                name_off = name_cursor;
                name_len = @intCast(n.len);
                @memcpy(buffer[schema_offset + name_cursor ..][0..n.len], n);
                name_cursor += name_len;
            }

            const ch = column.ColumnHeaderV2{
                .col_type_raw = @backingInt(entry.col.colType()),
                .encoding_raw = @backingInt(payloads[i].encoding),
                .length = @intCast(self.row_count),
                .null_count = @intCast(entry.col.nullCount()),
                .data_offset = @intCast(data_offsets[i]),
                .data_byte_len = @intCast(payloads[i].bytes.len),
                .validity_offset = @intCast(validity_offsets[i]),
                .name_offset = name_off,
                .name_len = name_len,
            };

            const ch_off = fixed_header_size + i * @sizeOf(column.ColumnHeaderV2);
            @memcpy(buffer[ch_off..][0..@sizeOf(column.ColumnHeaderV2)], std.mem.asBytes(&ch));

            if (payloads[i].bytes.len > 0) {
                @memcpy(buffer[data_offsets[i]..][0..payloads[i].bytes.len], payloads[i].bytes);
            }

            if (validity_offsets[i] != 0) {
                const bm = entry.col.validityBytes().?;
                const bm_len = column.validityByteLen(self.row_count);
                @memcpy(buffer[validity_offsets[i]..][0..bm_len], bm[0..bm_len]);
            }
        }

        // 4. Finalize CRC32 checksum over the entire image (excluding bytes 20..24)
        if (options.compute_checksum) {
            ext.checksum_crc32 = computeTableCrc32(buffer, total_bytes);
            @memcpy(buffer[16..64], std.mem.asBytes(&ext));
        }

        return buffer;
    }

    /// Serializes using legacy v1 wire layout (plain columns without validity bitmaps or schema names).
    pub fn serializeV1(self: *const Table, allocator: std.mem.Allocator) ![]align(64) u8 {
        const col_n = self.columns.items.len;
        const header_size = @sizeOf(column.TableHeader);
        const col_headers_size = col_n * @sizeOf(column.ColumnHeader);

        var cursor: usize = header_size + col_headers_size;
        const offsets = try allocator.alloc(usize, col_n);
        defer allocator.free(offsets);

        for (self.columns.items, 0..) |*entry, i| {
            if (entry.col.nullCount() > 0) return error.UnsupportedV1Column;
            const elem_align = entry.col.colType().elementAlign();
            cursor = (cursor + (elem_align - 1)) & ~@as(usize, elem_align - 1);
            offsets[i] = cursor;
            cursor += rawColumnBytes(&entry.col).len;
        }

        const aligned_size = column.alignUp64(cursor);
        const buffer = try allocator.alignedAlloc(u8, .fromByteUnits(64), aligned_size);
        @memset(buffer, 0);

        const th = column.TableHeader{
            .magic = column.FORMAT_MAGIC,
            .version = column.FORMAT_VERSION_V1,
            .row_count = @intCast(self.row_count),
            .column_count = @intCast(col_n),
        };
        @memcpy(buffer[0..header_size], std.mem.asBytes(&th));

        for (self.columns.items, 0..) |*entry, i| {
            const ch = column.ColumnHeader{
                .col_type = entry.col.colType(),
                .length = @intCast(self.row_count),
                .data_offset = @intCast(offsets[i]),
                .null_count = 0,
            };
            const ch_off = header_size + i * @sizeOf(column.ColumnHeader);
            @memcpy(buffer[ch_off..][0..@sizeOf(column.ColumnHeader)], std.mem.asBytes(&ch));

            const raw = rawColumnBytes(&entry.col);
            if (raw.len > 0) {
                @memcpy(buffer[offsets[i]..][0..raw.len], raw);
            }
        }

        return buffer;
    }

    /// Serializes the table and writes it to `sub_path` inside `dir`. Returns bytes written.
    pub fn writeToFile(
        self: *const Table,
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
        options: SerializeOptions,
    ) !usize {
        const buf = try self.serializeWithOptions(self.allocator, options);
        defer self.allocator.free(buf);
        try dir.writeFile(io, .{
            .sub_path = sub_path,
            .data = buf,
        });
        return buf.len;
    }
};

fn rawColumnBytes(col: *const Column) []const u8 {
    return switch (col.*) {
        .int32 => |*c| std.mem.sliceAsBytes(c.data),
        .int64 => |*c| std.mem.sliceAsBytes(c.data),
        .float64 => |*c| std.mem.sliceAsBytes(c.data),
    };
}

fn resolveEncoding(col: *const Column, policy: EncodingPolicy) column.ColumnEncoding {
    return switch (policy) {
        .plain => .plain,
        .rle => .rle,
        .delta => switch (col.*) {
            .int32, .int64 => .delta,
            .float64 => .plain,
        },
        .auto => switch (col.*) {
            .int32 => |*c| codec.selectBestEncoding(i32, c.data),
            .int64 => |*c| codec.selectBestEncoding(i64, c.data),
            .float64 => |*c| codec.selectBestEncoding(f64, c.data),
        },
    };
}

pub const TableView = struct {
    row_count: usize,
    col_count: usize,
    buffer: []align(64) const u8,
    version: u32 = column.FORMAT_VERSION_V1,
    flags: u32 = 0,
    checksum_crc32: u32 = 0,
    total_bytes: usize = 0,
    schema_offset: usize = 0,
    schema_size: usize = 0,

    /// O(N_cols) strictly validated zero-copy view initialization supporting both v1 and v2 buffers.
    pub fn fromBytes(buf: []align(64) const u8) TableError!TableView {
        if (buf.len < @sizeOf(column.TableHeader)) return error.BufferTooSmall;

        const th: *const column.TableHeader = @ptrCast(buf.ptr);
        if (!std.mem.eql(u8, &th.magic, &column.FORMAT_MAGIC)) return error.InvalidMagic;

        const row_count: usize = th.row_count;
        const col_count: usize = th.column_count;

        if (th.version == column.FORMAT_VERSION_V1) {
            const headers_bytes = std.math.mul(usize, col_count, @sizeOf(column.ColumnHeader)) catch
                return error.CorruptedHeader;
            const headers_end = std.math.add(usize, @sizeOf(column.TableHeader), headers_bytes) catch
                return error.CorruptedHeader;
            if (headers_end > buf.len) return error.BufferTooSmall;

            for (0..col_count) |i| {
                const ch_off = @sizeOf(column.TableHeader) + i * @sizeOf(column.ColumnHeader);
                const raw_type = std.mem.readInt(u32, buf[ch_off..][0..4], .little);
                const col_type = column.ColumnType.fromRaw(raw_type) catch return error.InvalidColumnType;
                const length: usize = std.mem.readInt(u32, buf[ch_off + 4 ..][0..4], .little);
                const data_offset_u64 = std.mem.readInt(u64, buf[ch_off + 8 ..][0..8], .little);
                const null_count: usize = std.mem.readInt(u32, buf[ch_off + 16 ..][0..4], .little);

                if (length != row_count) return error.CorruptedHeader;
                if (null_count > length) return error.CorruptedHeader;
                const data_offset = std.math.cast(usize, data_offset_u64) orelse return error.CorruptedHeader;
                if (data_offset < headers_end) return error.CorruptedHeader;
                if (data_offset % col_type.elementAlign() != 0) return error.UnalignedColumnData;

                const byte_len = std.math.mul(usize, length, col_type.elementSize()) catch return error.CorruptedHeader;
                const end_off = std.math.add(usize, data_offset, byte_len) catch return error.CorruptedHeader;
                if (end_off > buf.len) return error.BufferTooSmall;
            }

            return TableView{
                .row_count = row_count,
                .col_count = col_count,
                .buffer = buf,
                .version = column.FORMAT_VERSION_V1,
                .total_bytes = buf.len,
            };
        } else if (th.version == column.FORMAT_VERSION_V2) {
            const fixed_header_size = @sizeOf(column.TableHeader) + @sizeOf(column.TableHeaderExt);
            if (buf.len < fixed_header_size) return error.BufferTooSmall;

            var ext: column.TableHeaderExt = undefined;
            @memcpy(std.mem.asBytes(&ext), buf[16..64]);

            const total_bytes = std.math.cast(usize, ext.total_bytes) orelse return error.CorruptedHeader;
            if (total_bytes < fixed_header_size or total_bytes > buf.len) return error.BufferTooSmall;

            const col_headers_bytes = std.math.mul(usize, col_count, @sizeOf(column.ColumnHeaderV2)) catch
                return error.CorruptedHeader;
            const headers_end = std.math.add(usize, fixed_header_size, col_headers_bytes) catch
                return error.CorruptedHeader;
            if (headers_end > total_bytes) return error.BufferTooSmall;

            const schema_offset = std.math.cast(usize, ext.schema_offset) orelse return error.CorruptedHeader;
            const schema_size = std.math.cast(usize, ext.schema_size) orelse return error.CorruptedHeader;
            if ((ext.flags & column.FLAG_HAS_SCHEMA) != 0) {
                if (schema_offset < headers_end) return error.CorruptedHeader;
                const schema_end = std.math.add(usize, schema_offset, schema_size) catch return error.CorruptedHeader;
                if (schema_end > total_bytes) return error.BufferTooSmall;
            }

            for (0..col_count) |i| {
                const ch_off = fixed_header_size + i * @sizeOf(column.ColumnHeaderV2);
                const ch: *const column.ColumnHeaderV2 = @ptrCast(@alignCast(buf.ptr + ch_off));

                const col_type = column.ColumnType.fromRaw(ch.col_type_raw) catch return error.InvalidColumnType;
                const encoding = column.ColumnEncoding.fromRaw(ch.encoding_raw) catch return error.InvalidColumnEncoding;
                const length: usize = ch.length;
                const null_count: usize = ch.null_count;

                if (length != row_count) return error.CorruptedHeader;
                if (null_count > length) return error.CorruptedHeader;
                if (encoding == .delta and col_type == .float64) return error.InvalidColumnEncoding;

                const data_offset = std.math.cast(usize, ch.data_offset) orelse return error.CorruptedHeader;
                const data_byte_len = std.math.cast(usize, ch.data_byte_len) orelse return error.CorruptedHeader;
                if (data_offset < headers_end) return error.CorruptedHeader;
                const data_end = std.math.add(usize, data_offset, data_byte_len) catch return error.CorruptedHeader;
                if (data_end > total_bytes) return error.BufferTooSmall;

                if (encoding == .plain) {
                    const expected_bytes = std.math.mul(usize, length, col_type.elementSize()) catch
                        return error.CorruptedHeader;
                    if (data_byte_len != expected_bytes) return error.CorruptedHeader;
                    if (data_offset % col_type.elementAlign() != 0) return error.UnalignedColumnData;
                }

                if (ch.validity_offset != 0) {
                    const val_off = std.math.cast(usize, ch.validity_offset) orelse return error.CorruptedHeader;
                    if (val_off < headers_end) return error.CorruptedHeader;
                    const bm_len = column.validityByteLen(length);
                    const bm_end = std.math.add(usize, val_off, bm_len) catch return error.CorruptedHeader;
                    if (bm_end > total_bytes) return error.BufferTooSmall;
                } else if (null_count != 0) {
                    return error.CorruptedHeader;
                }

                if (ch.name_len != 0) {
                    if ((ext.flags & column.FLAG_HAS_SCHEMA) == 0) return error.CorruptedHeader;
                    const name_end = std.math.add(usize, ch.name_offset, ch.name_len) catch return error.CorruptedHeader;
                    if (name_end > schema_size) return error.CorruptedHeader;
                }
            }

            return TableView{
                .row_count = row_count,
                .col_count = col_count,
                .buffer = buf,
                .version = column.FORMAT_VERSION_V2,
                .flags = ext.flags,
                .checksum_crc32 = ext.checksum_crc32,
                .total_bytes = total_bytes,
                .schema_offset = schema_offset,
                .schema_size = schema_size,
            };
        } else {
            return error.UnsupportedVersion;
        }
    }

    /// Initializes a zero-copy view and verifies CRC32 checksum + validity bitmap consistency.
    pub fn fromBytesVerified(buf: []align(64) const u8) TableError!TableView {
        const view = try fromBytes(buf);
        try view.verifyChecksum();
        return view;
    }

    pub fn hasChecksum(self: *const TableView) bool {
        return self.version >= column.FORMAT_VERSION_V2 and (self.flags & column.FLAG_HAS_CHECKSUM) != 0;
    }

    /// Verifies the CRC32 checksum over the entire image and validates validity bitmap null counts.
    pub fn verifyChecksum(self: *const TableView) TableError!void {
        if (!self.hasChecksum()) return error.NoChecksum;
        const computed = computeTableCrc32(self.buffer, self.total_bytes);
        if (computed != self.checksum_crc32) return error.ChecksumMismatch;

        for (0..self.col_count) |i| {
            const info = self.getColumnInfo(i) orelse return error.CorruptedHeader;
            if (self.getValidityBitmap(i)) |bm| {
                if (column.countNullBits(bm, info.length) != info.null_count) {
                    return error.CorruptedHeader;
                }
            }
        }
    }

    pub fn getColumnInfo(self: *const TableView, col_idx: usize) ?ColumnInfo {
        if (col_idx >= self.col_count) return null;

        if (self.version == column.FORMAT_VERSION_V1) {
            const ch_off = @sizeOf(column.TableHeader) + col_idx * @sizeOf(column.ColumnHeader);
            const raw_type = std.mem.readInt(u32, self.buffer[ch_off..][0..4], .little);
            const col_type = column.ColumnType.fromRaw(raw_type) catch return null;
            const length: usize = std.mem.readInt(u32, self.buffer[ch_off + 4 ..][0..4], .little);
            const data_offset: usize = @intCast(std.mem.readInt(u64, self.buffer[ch_off + 8 ..][0..8], .little));
            const null_count: usize = std.mem.readInt(u32, self.buffer[ch_off + 16 ..][0..4], .little);

            return .{
                .index = col_idx,
                .name = null,
                .col_type = col_type,
                .encoding = .plain,
                .length = length,
                .null_count = null_count,
                .data_offset = data_offset,
                .data_byte_len = length * col_type.elementSize(),
                .validity_offset = 0,
                .is_cache_line_aligned = (data_offset % column.CACHE_LINE_BYTES) == 0,
            };
        } else {
            const ch_off = column.CACHE_LINE_BYTES + col_idx * @sizeOf(column.ColumnHeaderV2);
            const ch: *const column.ColumnHeaderV2 = @ptrCast(@alignCast(self.buffer.ptr + ch_off));
            const col_type = column.ColumnType.fromRaw(ch.col_type_raw) catch return null;
            const encoding = column.ColumnEncoding.fromRaw(ch.encoding_raw) catch return null;
            const data_offset: usize = @intCast(ch.data_offset);

            const col_name: ?[]const u8 = if (ch.name_len > 0)
                self.buffer[self.schema_offset + ch.name_offset ..][0..ch.name_len]
            else
                null;

            return .{
                .index = col_idx,
                .name = col_name,
                .col_type = col_type,
                .encoding = encoding,
                .length = ch.length,
                .null_count = ch.null_count,
                .data_offset = data_offset,
                .data_byte_len = @intCast(ch.data_byte_len),
                .validity_offset = @intCast(ch.validity_offset),
                .is_cache_line_aligned = (data_offset % column.CACHE_LINE_BYTES) == 0,
            };
        }
    }

    pub fn getColumnName(self: *const TableView, col_idx: usize) ?[]const u8 {
        const info = self.getColumnInfo(col_idx) orelse return null;
        return info.name;
    }

    pub fn findColumnByName(self: *const TableView, name: []const u8) ?usize {
        for (0..self.col_count) |i| {
            if (self.getColumnName(i)) |n| {
                if (std.mem.eql(u8, n, name)) return i;
            }
        }
        return null;
    }

    pub fn getValidityBitmap(self: *const TableView, col_idx: usize) ?[]const u8 {
        const info = self.getColumnInfo(col_idx) orelse return null;
        if (info.validity_offset == 0) return null;
        return self.buffer[info.validity_offset..][0..column.validityByteLen(info.length)];
    }

    pub fn getRawColumnPayload(self: *const TableView, col_idx: usize) ?[]const u8 {
        const info = self.getColumnInfo(col_idx) orelse return null;
        return self.buffer[info.data_offset..][0..info.data_byte_len];
    }

    pub fn getInt32Column(self: *const TableView, col_idx: usize) ?[]align(4) const i32 {
        const info = self.getColumnInfo(col_idx) orelse return null;
        if (info.col_type != .int32 or info.encoding != .plain) return null;
        const slice_bytes = self.buffer[info.data_offset..][0..info.data_byte_len];
        return @alignCast(std.mem.bytesAsSlice(i32, slice_bytes));
    }

    pub fn getInt64Column(self: *const TableView, col_idx: usize) ?[]align(8) const i64 {
        const info = self.getColumnInfo(col_idx) orelse return null;
        if (info.col_type != .int64 or info.encoding != .plain) return null;
        const slice_bytes = self.buffer[info.data_offset..][0..info.data_byte_len];
        return @alignCast(std.mem.bytesAsSlice(i64, slice_bytes));
    }

    pub fn getFloat64Column(self: *const TableView, col_idx: usize) ?[]align(8) const f64 {
        const info = self.getColumnInfo(col_idx) orelse return null;
        if (info.col_type != .float64 or info.encoding != .plain) return null;
        const slice_bytes = self.buffer[info.data_offset..][0..info.data_byte_len];
        return @alignCast(std.mem.bytesAsSlice(f64, slice_bytes));
    }

    /// Returns a zero-copy typed ColumnSlice (with validity bitmap) ready for SIMD execution.
    /// Returns null if the column is compressed (non-plain) or type mismatches.
    pub fn getColumnSlice(self: *const TableView, comptime T: type, col_idx: usize) ?column.ColumnSlice(T) {
        const info = self.getColumnInfo(col_idx) orelse return null;
        if (info.col_type != column.columnTypeFor(T) or info.encoding != .plain) return null;

        const data = switch (T) {
            i32 => self.getInt32Column(col_idx) orelse return null,
            i64 => self.getInt64Column(col_idx) orelse return null,
            f64 => self.getFloat64Column(col_idx) orelse return null,
            else => @compileError("Unsupported column type"),
        };

        return .{
            .data = data,
            .validity = self.getValidityBitmap(col_idx),
            .null_count = info.null_count,
        };
    }

    /// Materializes a column into a 64-byte aligned owned NumericColumn(T),
    /// transparently decoding `.plain`, `.rle`, and `.delta` encodings.
    pub fn decodeColumn(
        self: *const TableView,
        comptime T: type,
        allocator: std.mem.Allocator,
        col_idx: usize,
    ) !column.NumericColumn(T) {
        const info = self.getColumnInfo(col_idx) orelse return error.ColumnOutOfBounds;
        if (info.col_type != column.columnTypeFor(T)) return error.ColumnTypeMismatch;

        const payload = self.buffer[info.data_offset..][0..info.data_byte_len];
        const decoded_data: []align(64) T = switch (info.encoding) {
            .plain => blk: {
                const mem = try allocator.alignedAlloc(T, .fromByteUnits(64), info.length);
                const src = std.mem.bytesAsSlice(T, payload);
                @memcpy(mem, src);
                break :blk mem;
            },
            .rle => try codec.rleDecode(T, allocator, payload, info.length),
            .delta => switch (T) {
                i32, i64 => try codec.deltaDecode(T, allocator, payload, info.length),
                f64 => return error.InvalidColumnEncoding,
                else => unreachable,
            },
        };
        errdefer allocator.free(decoded_data);

        var owned_validity: ?[]align(64) u8 = null;
        if (self.getValidityBitmap(col_idx)) |bm| {
            const bm_copy = try allocator.alignedAlloc(u8, .fromByteUnits(64), bm.len);
            @memcpy(bm_copy, bm);
            owned_validity = bm_copy;
        }

        return .{
            .allocator = allocator,
            .data = decoded_data,
            .validity = owned_validity,
            .null_count = info.null_count,
        };
    }
};

/// Real zero-copy memory-mapped (`mmap`) table handle backed by an on-disk `.chry` file.
pub const MappedTable = struct {
    file: std.Io.File,
    mmap: std.Io.File.MemoryMap,
    view: TableView,

    pub const OpenOptions = struct {
        verify_checksum: bool = false,
        populate: bool = true,
    };

    pub fn open(
        io: std.Io,
        dir: std.Io.Dir,
        sub_path: []const u8,
        options: OpenOptions,
    ) !MappedTable {
        const file = try dir.openFile(io, sub_path, .{ .mode = .read_only });
        errdefer file.close(io);

        const file_len_u64 = try file.length(io);
        const file_len = std.math.cast(usize, file_len_u64) orelse return error.BufferTooSmall;
        if (file_len < @sizeOf(column.TableHeader)) return error.BufferTooSmall;

        var mm = try file.createMemoryMap(io, .{
            .len = file_len,
            .protection = .{ .read = true, .write = false },
            .populate = options.populate,
        });
        errdefer mm.destroy(io);

        const aligned_bytes: []align(64) const u8 = @alignCast(mm.memory);
        const view = if (options.verify_checksum)
            try TableView.fromBytesVerified(aligned_bytes)
        else
            try TableView.fromBytes(aligned_bytes);

        return .{
            .file = file,
            .mmap = mm,
            .view = view,
        };
    }

    pub fn close(self: *MappedTable, io: std.Io) void {
        self.mmap.destroy(io);
        self.file.close(io);
    }
};

test "Table Serialization and Zero-Copy Deserialization" {
    const allocator = std.testing.allocator;
    var tbl = Table.init(allocator, 100);
    defer tbl.deinit();

    var col = try column.Int32Column.init(allocator, 100);
    for (0..100) |i| {
        col.data[i] = @intCast(i * 10);
    }
    try tbl.addColumn(col);

    const serialized = try tbl.serialize(allocator);
    defer allocator.free(serialized);

    const view = try TableView.fromBytes(serialized);
    try std.testing.expectEqual(@as(usize, 100), view.row_count);
    try std.testing.expectEqual(@as(usize, 1), view.col_count);

    const recovered_col = view.getInt32Column(0).?;
    try std.testing.expectEqual(@as(i32, 0), recovered_col[0]);
    try std.testing.expectEqual(@as(i32, 420), recovered_col[42]);
    try std.testing.expectEqual(@as(i32, 990), recovered_col[99]);

    // Verify 64-byte alignment of column payload in v2
    const info = view.getColumnInfo(0).?;
    try std.testing.expect(info.is_cache_line_aligned);
    try view.verifyChecksum();
}

test "Multi-type named schema, >8 columns, null bitmaps, and v1/v2 compatibility" {
    const allocator = std.testing.allocator;
    const rows: usize = 53;

    var tbl = Table.init(allocator, rows);
    defer tbl.deinit();

    // Add 10 columns (> legacy 8-column cap) across all 3 types
    var ids = try column.Int64Column.init(allocator, rows);
    for (0..rows) |i| ids.data[i] = 10_000 + @as(i64, @intCast(i));
    try tbl.addNamedInt64Column("id", ids);

    var prices = try column.Float64Column.init(allocator, rows);
    for (0..rows) |i| prices.data[i] = @as(f64, @floatFromInt(i)) * 2.25;
    try prices.setNull(0);
    try prices.setNull(25);
    try prices.setNull(52);
    try tbl.addNamedFloat64Column("price", prices);

    for (0..8) |k| {
        var c = try column.Int32Column.init(allocator, rows);
        for (0..rows) |i| c.data[i] = @intCast(i + k);
        if (k == 0) try c.setNull(7);
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "metric_{d}", .{k}) catch unreachable;
        try tbl.addNamedInt32Column(name, c);
    }

    try std.testing.expectEqual(@as(usize, 10), tbl.columnCount());

    const bytes = try tbl.serialize(allocator);
    defer allocator.free(bytes);

    const view = try TableView.fromBytesVerified(bytes);
    try std.testing.expectEqual(@as(u32, column.FORMAT_VERSION_V2), view.version);
    try std.testing.expectEqual(@as(usize, 10), view.col_count);
    try std.testing.expectEqual(@as(?usize, 0), view.findColumnByName("id"));
    try std.testing.expectEqual(@as(?usize, 1), view.findColumnByName("price"));
    try std.testing.expectEqual(@as(?usize, 9), view.findColumnByName("metric_7"));
    try std.testing.expect(view.findColumnByName("nonexistent") == null);

    // Every v2 column payload is 64-byte cache-line aligned
    for (0..view.col_count) |i| {
        try std.testing.expect(view.getColumnInfo(i).?.is_cache_line_aligned);
    }

    // Zero-copy SIMD operations directly on TableView ColumnSlice with nulls
    const price_slice = view.getColumnSlice(f64, 1).?;
    try std.testing.expectEqual(@as(usize, 3), price_slice.null_count);
    try std.testing.expect(price_slice.isNull(0));
    try std.testing.expect(price_slice.isNull(25));
    try std.testing.expect(price_slice.isNull(52));
    try std.testing.expectEqual(@as(?f64, 2.25), price_slice.get(1));

    const mm = price_slice.minMaxSimd().?;
    try std.testing.expectEqual(@as(f64, 2.25), mm.min);
    try std.testing.expectEqual(@as(f64, 51.0 * 2.25), mm.max);

    // Bit-flip detection via CRC32
    var corrupted = try allocator.alignedAlloc(u8, .fromByteUnits(64), bytes.len);
    defer allocator.free(corrupted);
    @memcpy(corrupted, bytes);
    corrupted[corrupted.len - 17] ^= 0x01;
    try std.testing.expectError(error.ChecksumMismatch, TableView.fromBytesVerified(corrupted));
}

test "Legacy v1 serialization backward compatibility" {
    const allocator = std.testing.allocator;
    var tbl = Table.init(allocator, 32);
    defer tbl.deinit();

    var col = try column.Int32Column.init(allocator, 32);
    for (0..32) |i| col.data[i] = @intCast(i * 3);
    try tbl.addColumn(col);

    const v1_bytes = try tbl.serializeV1(allocator);
    defer allocator.free(v1_bytes);

    const view = try TableView.fromBytes(v1_bytes);
    try std.testing.expectEqual(@as(u32, column.FORMAT_VERSION_V1), view.version);
    try std.testing.expect(!view.hasChecksum());
    try std.testing.expectError(error.NoChecksum, view.verifyChecksum());

    const slice = view.getColumnSlice(i32, 0).?;
    try std.testing.expectEqual(@as(i64, 3 * 31 * 32 / 2), slice.sumSimd());
}

test "Compressed table serialization (auto RLE & Delta) and transparent decode" {
    const allocator = std.testing.allocator;
    const rows: usize = 512;
    var tbl = Table.init(allocator, rows);
    defer tbl.deinit();

    // Monotonic timestamps -> auto picks delta
    var ts = try column.Int64Column.init(allocator, rows);
    for (0..rows) |i| ts.data[i] = 1_700_000_000 + @as(i64, @intCast(i * 5));
    try tbl.addNamedInt64Column("ts", ts);

    // Low-cardinality status -> auto picks rle
    var status = try column.Int32Column.init(allocator, rows);
    for (0..rows) |i| status.data[i] = @intCast(i / 128);
    try status.setNull(10);
    try tbl.addNamedInt32Column("status", status);

    const plain_bytes = try tbl.serializeWithOptions(allocator, .{ .encoding = .plain });
    defer allocator.free(plain_bytes);
    const auto_bytes = try tbl.serializeWithOptions(allocator, .{ .encoding = .auto });
    defer allocator.free(auto_bytes);

    // Compressed table must be substantially smaller than plain
    try std.testing.expect(auto_bytes.len < plain_bytes.len / 2);

    const view = try TableView.fromBytesVerified(auto_bytes);
    try std.testing.expectEqual(column.ColumnEncoding.delta, view.getColumnInfo(0).?.encoding);
    try std.testing.expectEqual(column.ColumnEncoding.rle, view.getColumnInfo(1).?.encoding);

    // Plain zero-copy accessor returns null for compressed columns instead of misinterpreting bytes
    try std.testing.expect(view.getInt64Column(0) == null);
    try std.testing.expect(view.getInt32Column(1) == null);

    // Transparent decodeColumn recovers exact values + validity bitmap
    var dec_ts = try view.decodeColumn(i64, allocator, 0);
    defer dec_ts.deinit();
    try std.testing.expectEqual(@as(i64, 1_700_000_000), dec_ts.data[0]);
    try std.testing.expectEqual(@as(i64, 1_700_000_000 + 511 * 5), dec_ts.data[511]);

    var dec_status = try view.decodeColumn(i32, allocator, 1);
    defer dec_status.deinit();
    try std.testing.expectEqual(@as(usize, 1), dec_status.nullCount());
    try std.testing.expect(dec_status.isNull(10));
    try std.testing.expectEqual(@as(?i32, 3), dec_status.get(500));
}

test "TableView rejects malformed, truncated, unaligned, and invalid-enum buffers" {
    const allocator = std.testing.allocator;

    // Buffer too small
    const tiny = try allocator.alignedAlloc(u8, .fromByteUnits(64), 8);
    defer allocator.free(tiny);
    @memset(tiny, 0);
    try std.testing.expectError(error.BufferTooSmall, TableView.fromBytes(tiny));

    // Bad magic
    const bad_magic = try allocator.alignedAlloc(u8, .fromByteUnits(64), 64);
    defer allocator.free(bad_magic);
    @memset(bad_magic, 0);
    @memcpy(bad_magic[0..4], "NOPE");
    try std.testing.expectError(error.InvalidMagic, TableView.fromBytes(bad_magic));

    // Unsupported version
    @memcpy(bad_magic[0..4], "CHRY");
    std.mem.writeInt(u32, bad_magic[4..8], 99, .little);
    try std.testing.expectError(error.UnsupportedVersion, TableView.fromBytes(bad_magic));

    // Invalid column type tag in v1 (must NOT trigger UB!)
    const bad_type = try allocator.alignedAlloc(u8, .fromByteUnits(64), 64);
    defer allocator.free(bad_type);
    @memset(bad_type, 0);
    @memcpy(bad_type[0..4], "CHRY");
    std.mem.writeInt(u32, bad_type[4..8], 1, .little); // v1
    std.mem.writeInt(u32, bad_type[8..12], 4, .little); // 4 rows
    std.mem.writeInt(u32, bad_type[12..16], 1, .little); // 1 col
    std.mem.writeInt(u32, bad_type[16..20], 777, .little); // invalid ColumnType
    try std.testing.expectError(error.InvalidColumnType, TableView.fromBytes(bad_type));

    // Unaligned column offset in v1
    std.mem.writeInt(u32, bad_type[16..20], 1, .little); // int32
    std.mem.writeInt(u32, bad_type[20..24], 4, .little); // length=4
    std.mem.writeInt(u64, bad_type[24..32], 41, .little); // unaligned (41 % 4 != 0)
    try std.testing.expectError(error.UnalignedColumnData, TableView.fromBytes(bad_type));

    // Row count mismatch on addColumn
    var tbl = Table.init(allocator, 10);
    defer tbl.deinit();
    var wrong = try column.Int32Column.init(allocator, 5);
    defer wrong.deinit();
    try std.testing.expectError(error.RowCountMismatch, tbl.addColumn(wrong));
}

test "MappedTable true mmap zero-copy file round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tbl = Table.init(allocator, 256);
    defer tbl.deinit();

    var qty = try column.Int32Column.init(allocator, 256);
    var price = try column.Float64Column.init(allocator, 256);
    for (0..256) |i| {
        qty.data[i] = @intCast(i + 1);
        price.data[i] = @as(f64, @floatFromInt(i + 1)) * 0.5;
    }
    try tbl.addNamedInt32Column("qty", qty);
    try tbl.addNamedFloat64Column("price", price);

    const written = try tbl.writeToFile(io, tmp.dir, "sample.chry", .{});
    try std.testing.expect(written >= 256 * (4 + 8) + 64);

    var mapped = try MappedTable.open(io, tmp.dir, "sample.chry", .{ .verify_checksum = true });
    defer mapped.close(io);

    try std.testing.expectEqual(@as(usize, 256), mapped.view.row_count);
    try std.testing.expectEqual(@as(usize, 2), mapped.view.col_count);

    const qty_slice = mapped.view.getColumnSlice(i32, 0).?;
    const price_slice = mapped.view.getColumnSlice(f64, 1).?;
    try std.testing.expectEqual(@as(i64, 256 * 257 / 2), qty_slice.sumSimd());
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(256 * 257 / 2)) * 0.5, price_slice.sumSimd(), 1e-9);
}

test "FastCrc32 slicing-by-8 is bit-identical to std.hash.Crc32" {
    var prng = std.Random.DefaultPrng.init(0xC3C3_2026);
    const rand = prng.random();

    var data: [515]u8 = undefined;
    rand.bytes(&data);

    // Check every length 0..515 including non-8-byte multiples
    for (0..data.len + 1) |len| {
        const expected = std.hash.Crc32.hash(data[0..len]);
        const actual = FastCrc32.hash(data[0..len]);
        try std.testing.expectEqual(expected, actual);
    }

    // Check multi-chunk streaming updates at odd boundaries
    var fast = FastCrc32.init();
    fast.update(data[0..13]);
    fast.update(data[13..100]);
    fast.update(data[100..515]);
    try std.testing.expectEqual(std.hash.Crc32.hash(&data), fast.final());
}

test "TableView v2 fuzz-like header corruption never panics and detects tampering" {
    const allocator = std.testing.allocator;
    var tbl = Table.init(allocator, 24);
    defer tbl.deinit();

    var col = try column.Int32Column.init(allocator, 24);
    for (0..24) |i| col.data[i] = @intCast(i);
    try col.setNull(3);
    try tbl.addNamedInt32Column("vals", col);

    const valid = try tbl.serialize(allocator);
    defer allocator.free(valid);

    const scratch = try allocator.alignedAlloc(u8, .fromByteUnits(64), valid.len);
    defer allocator.free(scratch);

    // 1. Truncated lengths below total_bytes
    for ([_]usize{ 0, 4, 15, 16, 63, valid.len - 1 }) |trunc| {
        @memcpy(scratch[0..trunc], valid[0..trunc]);
        try std.testing.expectError(error.BufferTooSmall, TableView.fromBytes(scratch[0..trunc]));
    }

    // 2. Corrupt column encoding tag to invalid enum (99)
    @memcpy(scratch, valid);
    std.mem.writeInt(u32, scratch[68..72], 99, .little);
    try std.testing.expectError(error.InvalidColumnEncoding, TableView.fromBytes(scratch));

    // 3. Corrupt data_offset into header area (< headers_end)
    @memcpy(scratch, valid);
    std.mem.writeInt(u64, scratch[80..88], 16, .little);
    try std.testing.expectError(error.CorruptedHeader, TableView.fromBytes(scratch));

    // 4. Corrupt validity_offset to 0 while null_count == 1
    @memcpy(scratch, valid);
    std.mem.writeInt(u64, scratch[96..104], 0, .little);
    try std.testing.expectError(error.CorruptedHeader, TableView.fromBytes(scratch));

    // 5. Corrupt validity bitmap bit AND recompute CRC -> verifyChecksum catches null_count mismatch
    @memcpy(scratch, valid);
    const view0 = try TableView.fromBytes(valid);
    const val_off = view0.getColumnInfo(0).?.validity_offset;
    scratch[val_off] ^= 0x01; // flip bit 0 -> changes null count from 1 to 2
    const recomputed = computeTableCrc32(scratch, scratch.len);
    std.mem.writeInt(u32, scratch[20..24], recomputed, .little);
    try std.testing.expectError(error.CorruptedHeader, TableView.fromBytesVerified(scratch));
}
