const std = @import("std");
pub const column = @import("column.zig");
pub const table = @import("table.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.next(); // skip prog name

    const cmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "bench")) {
        const row_count: usize = 1_000_000;
        std.debug.print("Chrysoberyl: Benchmarking SIMD Vector Reduction over {d} rows...\n", .{row_count});

        var col = try column.Int32Column.init(allocator, row_count);
        defer col.deinit();

        for (0..row_count) |i| {
            col.data[i] = @intCast(@as(u32, @truncate(i)) % 100);
        }

        const t0 = std.Io.Clock.Timestamp.now(init.io, .awake);
        const sum = col.sumSimd();
        const t1 = std.Io.Clock.Timestamp.now(init.io, .awake);

        const duration_ns = t0.durationTo(t1).raw.nanoseconds;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        const total_bytes = row_count * @sizeOf(i32);
        const gb_per_sec = (@as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0 * 1024.0)) / (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

        std.debug.print(
            \\SIMD Reduction Result:
            \\  Accumulated Sum: {d}
            \\  Elapsed Time:    {d:.2} ms
            \\  Throughput:      {d:.2} GB/s
            \\
        , .{ sum, duration_ms, gb_per_sec });

        // Zero-copy serialization benchmark
        std.debug.print("Benchmarking Zero-Copy Table Serialization...\n", .{});
        var tbl = table.Table.init(allocator, row_count);
        defer tbl.deinit();

        const col2 = try column.Int32Column.init(allocator, row_count);
        @memcpy(col2.data, col.data);
        try tbl.addColumn(col2);

        const s0 = std.Io.Clock.Timestamp.now(init.io, .awake);
        const serialized = try tbl.serialize(allocator);
        const s1 = std.Io.Clock.Timestamp.now(init.io, .awake);

        const ser_ns = s0.durationTo(s1).raw.nanoseconds;
        const ser_ms = @as(f64, @floatFromInt(ser_ns)) / 1_000_000.0;

        // Zero-copy deserialization (instantaneous pointer overlay)
        const d0 = std.Io.Clock.Timestamp.now(init.io, .awake);
        const view = try table.TableView.fromBytes(serialized);
        const d1 = std.Io.Clock.Timestamp.now(init.io, .awake);
        const de_ns = d0.durationTo(d1).raw.nanoseconds;

        std.debug.print(
            \\Zero-Copy Performance:
            \\  Serialized Bytes:   {d} bytes
            \\  Serialization Time: {d:.2} ms
            \\  Zero-Copy View Time:{d} ns (O(1) memory mapping)
            \\  Recovered Rows:     {d}
            \\
        , .{ serialized.len, ser_ms, de_ns, view.row_count });
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Chrysoberyl: Zero-Copy Columnar Binary Serialization & SIMD Engine
        \\Usage:
        \\  chrysoberyl bench
        \\  chrysoberyl --help
        \\
    , .{});
}

test {
    _ = @import("column.zig");
    _ = @import("table.zig");
}
