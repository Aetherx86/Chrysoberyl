const std = @import("std");
pub const column = @import("column.zig");
pub const codec = @import("codec.zig");
pub const table = @import("table.zig");
pub const query = @import("query.zig");

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const io = init.io;

    var out_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout_writer.interface;

    var err_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err_out = &stderr_writer.interface;

    var args = init.minimal.args.iterate();
    _ = args.next(); // program name

    const cmd = args.next() orelse {
        try printUsage(out);
        try out.flush();
        return 0;
    };

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        try printUsage(out);
        try out.flush();
        return 0;
    }

    if (std.mem.eql(u8, cmd, "bench")) {
        const rc = try runBench(allocator, io, &args, out, err_out);
        try out.flush();
        try err_out.flush();
        return rc;
    } else if (std.mem.eql(u8, cmd, "generate")) {
        const rc = try runGenerate(allocator, io, &args, out, err_out);
        try out.flush();
        try err_out.flush();
        return rc;
    } else if (std.mem.eql(u8, cmd, "inspect")) {
        const rc = try runInspect(allocator, io, &args, out, err_out);
        try out.flush();
        try err_out.flush();
        return rc;
    } else if (std.mem.eql(u8, cmd, "query")) {
        const rc = try runQuery(allocator, io, &args, out, err_out);
        try out.flush();
        try err_out.flush();
        return rc;
    } else if (std.mem.eql(u8, cmd, "verify")) {
        const rc = try runVerify(io, &args, out, err_out);
        try out.flush();
        try err_out.flush();
        return rc;
    } else {
        try err_out.print("error: unknown command '{s}'\n", .{cmd});
        try printUsage(err_out);
        try err_out.flush();
        return 1;
    }
}

fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Chrysoberyl: Zero-Copy Columnar Binary Serialization & SIMD Vector Engine
        \\
        \\Usage:
        \\  chrysoberyl bench [--rows N] [--json]
        \\  chrysoberyl generate <output.chry> [--rows N] [--encoding plain|rle|delta|auto] [--null-pct P]
        \\  chrysoberyl inspect <file.chry> [--verify] [--json]
        \\  chrysoberyl query <file.chry> [--where <expr>]... [--agg <col>] [--or] [--limit N] [--json]
        \\  chrysoberyl verify <file.chry>
        \\  chrysoberyl --help
        \\
        \\Predicate syntax for --where:
        \\  col==val, col!=val, col<val, col<=val, col>val, col>=val
        \\  col[low..high]   (inclusive range)
        \\  col:null, col:notnull
        \\
    );
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeJsonFloatOrNull(w: *std.Io.Writer, val: ?f64) !void {
    if (val) |v| {
        if (std.math.isNan(v) or std.math.isInf(v)) {
            try w.writeAll("null");
        } else {
            try w.print("{d:.6}", .{v});
        }
    } else {
        try w.writeAll("null");
    }
}

fn elapsedNsSafe(t0: std.Io.Clock.Timestamp, t1: std.Io.Clock.Timestamp) u64 {
    const raw = t0.durationTo(t1).raw.nanoseconds;
    if (raw <= 1) return 1;
    return @intCast(raw);
}

fn gbPerSec(bytes: usize, ns: u64) f64 {
    const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    const secs = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    return gb / secs;
}

fn runBench(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !u8 {
    var row_count: usize = 1_000_000;
    var json_mode = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--rows")) {
            const val = args.next() orelse {
                try err_out.writeAll("error: --rows requires an integer argument\n");
                return 1;
            };
            row_count = std.fmt.parseInt(usize, val, 10) catch {
                try err_out.print("error: invalid --rows value '{s}'\n", .{val});
                return 1;
            };
        } else {
            try err_out.print("error: unknown bench option '{s}'\n", .{arg});
            return 1;
        }
    }

    var i32_a = try column.Int32Column.init(allocator, row_count);
    defer i32_a.deinit();
    var i32_b = try column.Int32Column.init(allocator, row_count);
    defer i32_b.deinit();
    var f64_col = try column.Float64Column.init(allocator, row_count);
    defer f64_col.deinit();
    var ts_col = try column.Int64Column.init(allocator, row_count);
    defer ts_col.deinit();

    for (0..row_count) |i| {
        i32_a.data[i] = @intCast(@as(u32, @truncate(i)) % 100);
        i32_b.data[i] = @intCast((@as(u32, @truncate(i)) % 17) + 1);
        f64_col.data[i] = @as(f64, @floatFromInt(i % 1000)) * 0.25;
        ts_col.data[i] = 1_700_000_000 + @as(i64, @intCast(i * 4));
    }

    // 1. Widening Int32 SIMD sum
    const sum_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const i32_sum = i32_a.sumSimd();
    std.mem.doNotOptimizeAway(&i32_sum);
    const sum_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const sum_ns = elapsedNsSafe(sum_t0, sum_t1);

    // 2. Int32 SIMD Min/Max
    const mm_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const mm = i32_a.minMaxSimd();
    std.mem.doNotOptimizeAway(&mm);
    const mm_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const mm_ns = elapsedNsSafe(mm_t0, mm_t1);

    // 3. Allocation-free SIMD predicate count (popcount)
    const cnt_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const matched = i32_a.countMatchingSimd(.ge, 75);
    std.mem.doNotOptimizeAway(&matched);
    const cnt_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const cnt_ns = elapsedNsSafe(cnt_t0, cnt_t1);

    // 4. Vector-vector SIMD dot product (widening i32*i32 -> i64)
    const dot_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const dot = try i32_a.dotProductSimd(&i32_b);
    std.mem.doNotOptimizeAway(&dot);
    const dot_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const dot_ns = elapsedNsSafe(dot_t0, dot_t1);

    // 5. Float64 fused filter + sum (sumWhereSimd)
    const fsum_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const f64_sum_where = f64_col.sumWhereSimd(.ge, 125.0);
    std.mem.doNotOptimizeAway(&f64_sum_where);
    const fsum_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const fsum_ns = elapsedNsSafe(fsum_t0, fsum_t1);

    // 6. SIMD Hillis-Steele parallel prefix-sum decode
    const deltas = try allocator.alignedAlloc(i32, .fromByteUnits(64), row_count);
    defer allocator.free(deltas);
    const decoded = try allocator.alignedAlloc(i32, .fromByteUnits(64), row_count);
    defer allocator.free(decoded);
    try codec.simdDeltaEncode(i32, i32_a.data, deltas);
    const psum_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    try codec.simdPrefixSumDecode(i32, deltas, decoded);
    std.mem.doNotOptimizeAway(decoded.ptr);
    const psum_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const psum_ns = elapsedNsSafe(psum_t0, psum_t1);

    // 7. Zero-copy v2 table serialization, O(1) view init, CRC32 verify, & auto compression
    var tbl = table.Table.init(allocator, row_count);
    defer tbl.deinit();

    const col_ts = try column.Int64Column.initFromSlice(allocator, ts_col.data);
    try tbl.addNamedInt64Column("timestamp", col_ts);
    const col_i32 = try column.Int32Column.initFromSlice(allocator, i32_a.data);
    try tbl.addNamedInt32Column("metric", col_i32);
    const col_f64 = try column.Float64Column.initFromSlice(allocator, f64_col.data);
    try tbl.addNamedFloat64Column("value", col_f64);

    const ser_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const serialized = try tbl.serialize(allocator);
    defer allocator.free(serialized);
    const ser_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const ser_ns = elapsedNsSafe(ser_t0, ser_t1);

    const view_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const view = try table.TableView.fromBytes(serialized);
    std.mem.doNotOptimizeAway(&view);
    const view_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const view_ns = elapsedNsSafe(view_t0, view_t1);

    const crc_t0 = std.Io.Clock.Timestamp.now(io, .awake);
    try view.verifyChecksum();
    const crc_t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const crc_ns = elapsedNsSafe(crc_t0, crc_t1);

    const auto_bytes = try tbl.serializeWithOptions(allocator, .{ .encoding = .auto });
    defer allocator.free(auto_bytes);

    const i32_bytes = row_count * @sizeOf(i32);
    const f64_bytes = row_count * @sizeOf(f64);
    const compression_ratio = @as(f64, @floatFromInt(serialized.len)) / @as(f64, @floatFromInt(@max(auto_bytes.len, 1)));

    if (json_mode) {
        try out.print(
            \\{{
            \\  "rows": {d},
            \\  "kernels": {{
            \\    "i32_sum_simd": {{ "result": {d}, "elapsed_ns": {d}, "throughput_gb_s": {d:.3} }},
            \\    "i32_minmax_simd": {{ "min": {d}, "max": {d}, "elapsed_ns": {d}, "throughput_gb_s": {d:.3} }},
            \\    "i32_count_ge_75": {{ "matched": {d}, "elapsed_ns": {d}, "throughput_gb_s": {d:.3} }},
            \\    "i32_dot_product": {{ "result": {d}, "elapsed_ns": {d}, "throughput_gb_s": {d:.3} }},
            \\    "f64_sum_where_ge_125": {{ "result": {d:.4}, "elapsed_ns": {d}, "throughput_gb_s": {d:.3} }},
            \\    "simd_prefix_sum_decode": {{ "elapsed_ns": {d}, "throughput_gb_s": {d:.3} }}
            \\  }},
            \\  "serialization_v2": {{
            \\    "columns": {d},
            \\    "plain_bytes": {d},
            \\    "auto_compressed_bytes": {d},
            \\    "compression_ratio": {d:.3},
            \\    "serialize_ns": {d},
            \\    "view_init_ns": {d},
            \\    "crc32_verify_ns": {d},
            \\    "recovered_rows": {d}
            \\  }}
            \\}}
            \\
        , .{
            row_count,
            i32_sum,
            sum_ns,
            gbPerSec(i32_bytes, sum_ns),
            if (mm) |m| m.min else 0,
            if (mm) |m| m.max else 0,
            mm_ns,
            gbPerSec(i32_bytes, mm_ns),
            matched,
            cnt_ns,
            gbPerSec(i32_bytes, cnt_ns),
            dot,
            dot_ns,
            gbPerSec(i32_bytes * 2, dot_ns),
            f64_sum_where,
            fsum_ns,
            gbPerSec(f64_bytes, fsum_ns),
            psum_ns,
            gbPerSec(i32_bytes, psum_ns),
            view.col_count,
            serialized.len,
            auto_bytes.len,
            compression_ratio,
            ser_ns,
            view_ns,
            crc_ns,
            view.row_count,
        });
    } else {
        try out.print("Chrysoberyl SIMD & Zero-Copy Benchmark ({d} rows)\n\n", .{row_count});
        try out.print(
            \\SIMD Vector Kernels:
            \\  i32 widening sum:      {d} ({d:.2} ms, {d:.2} GB/s)
            \\  i32 min/max:           [{d}, {d}] ({d:.2} ms, {d:.2} GB/s)
            \\  i32 count (>= 75):     {d} ({d:.2} ms, {d:.2} GB/s)
            \\  i32 dot product:       {d} ({d:.2} ms, {d:.2} GB/s)
            \\  f64 fused sumWhere:    {d:.2} ({d:.2} ms, {d:.2} GB/s)
            \\  SIMD prefix-sum dec:   {d:.2} ms ({d:.2} GB/s)
            \\
            \\Zero-Copy Format v2 ({d} columns, 64B cache-line aligned, CRC32):
            \\  Plain Table Size:      {d} bytes
            \\  Auto-Encoded Size:     {d} bytes ({d:.2}x ratio)
            \\  Serialization Time:    {d:.2} ms
            \\  Zero-Copy View Init:   {d} ns (O(1) overlay)
            \\  CRC32 Integrity Check: {d:.2} ms ({d:.2} GB/s)
            \\  Recovered Rows:        {d}
            \\
        , .{
            i32_sum,
            @as(f64, @floatFromInt(sum_ns)) / 1_000_000.0,
            gbPerSec(i32_bytes, sum_ns),
            if (mm) |m| m.min else 0,
            if (mm) |m| m.max else 0,
            @as(f64, @floatFromInt(mm_ns)) / 1_000_000.0,
            gbPerSec(i32_bytes, mm_ns),
            matched,
            @as(f64, @floatFromInt(cnt_ns)) / 1_000_000.0,
            gbPerSec(i32_bytes, cnt_ns),
            dot,
            @as(f64, @floatFromInt(dot_ns)) / 1_000_000.0,
            gbPerSec(i32_bytes * 2, dot_ns),
            f64_sum_where,
            @as(f64, @floatFromInt(fsum_ns)) / 1_000_000.0,
            gbPerSec(f64_bytes, fsum_ns),
            @as(f64, @floatFromInt(psum_ns)) / 1_000_000.0,
            gbPerSec(i32_bytes, psum_ns),
            view.col_count,
            serialized.len,
            auto_bytes.len,
            compression_ratio,
            @as(f64, @floatFromInt(ser_ns)) / 1_000_000.0,
            view_ns,
            @as(f64, @floatFromInt(crc_ns)) / 1_000_000.0,
            gbPerSec(serialized.len, crc_ns),
            view.row_count,
        });
    }

    return 0;
}

fn runGenerate(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !u8 {
    var out_path: ?[]const u8 = null;
    var row_count: usize = 100_000;
    var encoding: table.EncodingPolicy = .plain;
    var null_pct: u8 = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--rows")) {
            const val = args.next() orelse {
                try err_out.writeAll("error: --rows requires an integer argument\n");
                return 1;
            };
            row_count = std.fmt.parseInt(usize, val, 10) catch {
                try err_out.print("error: invalid --rows value '{s}'\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--encoding")) {
            const val = args.next() orelse {
                try err_out.writeAll("error: --encoding requires plain|rle|delta|auto\n");
                return 1;
            };
            if (std.mem.eql(u8, val, "plain")) {
                encoding = .plain;
            } else if (std.mem.eql(u8, val, "rle")) {
                encoding = .rle;
            } else if (std.mem.eql(u8, val, "delta")) {
                encoding = .delta;
            } else if (std.mem.eql(u8, val, "auto")) {
                encoding = .auto;
            } else {
                try err_out.print("error: invalid encoding '{s}' (expected plain|rle|delta|auto)\n", .{val});
                return 1;
            }
        } else if (std.mem.eql(u8, arg, "--null-pct")) {
            const val = args.next() orelse {
                try err_out.writeAll("error: --null-pct requires an integer 0..100\n");
                return 1;
            };
            null_pct = std.fmt.parseInt(u8, val, 10) catch {
                try err_out.print("error: invalid --null-pct value '{s}'\n", .{val});
                return 1;
            };
            if (null_pct > 100) {
                try err_out.writeAll("error: --null-pct must be between 0 and 100\n");
                return 1;
            }
        } else if (out_path == null and !std.mem.startsWith(u8, arg, "--")) {
            out_path = arg;
        } else {
            try err_out.print("error: unexpected argument '{s}'\n", .{arg});
            return 1;
        }
    }

    const path = out_path orelse {
        try err_out.writeAll("error: generate requires an output file path\n");
        return 1;
    };

    var tbl = table.Table.init(allocator, row_count);
    defer tbl.deinit();

    var ids = try column.Int64Column.init(allocator, row_count);
    var category = try column.Int32Column.init(allocator, row_count);
    var quantity = try column.Int32Column.init(allocator, row_count);
    var price = try column.Float64Column.init(allocator, row_count);
    var score = try column.Float64Column.init(allocator, row_count);

    var prng = std.Random.DefaultPrng.init(0xC4B0_2026);
    const rand = prng.random();

    for (0..row_count) |i| {
        ids.data[i] = 1_000_000 + @as(i64, @intCast(i));
        category.data[i] = @intCast((i / 64) % 8);
        quantity.data[i] = @intCast(rand.intRangeAtMost(i32, 1, 50));
        price.data[i] = @as(f64, @floatFromInt(rand.intRangeAtMost(u32, 500, 50_000))) / 100.0;
        score.data[i] = @as(f64, @floatFromInt(rand.intRangeAtMost(u32, 0, 1000))) / 1000.0;

        if (null_pct > 0 and rand.intRangeLessThan(u8, 0, 100) < null_pct) {
            try price.setNull(i);
        }
    }

    try tbl.addNamedInt64Column("id", ids);
    try tbl.addNamedInt32Column("category", category);
    try tbl.addNamedInt32Column("quantity", quantity);
    try tbl.addNamedFloat64Column("price", price);
    try tbl.addNamedFloat64Column("score", score);

    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    const written = try tbl.writeToFile(io, std.Io.Dir.cwd(), path, .{
        .encoding = encoding,
        .compute_checksum = true,
    });
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const elapsed_ms = @as(f64, @floatFromInt(elapsedNsSafe(t0, t1))) / 1_000_000.0;

    try out.print(
        "Generated '{s}': {d} rows, {d} columns, {d} bytes ({d:.2} ms)\n",
        .{ path, row_count, tbl.columnCount(), written, elapsed_ms },
    );
    return 0;
}

fn runInspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !u8 {
    var path_opt: ?[]const u8 = null;
    var verify_crc = false;
    var json_mode = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verify")) {
            verify_crc = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (path_opt == null and !std.mem.startsWith(u8, arg, "--")) {
            path_opt = arg;
        } else {
            try err_out.print("error: unexpected argument '{s}'\n", .{arg});
            return 1;
        }
    }

    const path = path_opt orelse {
        try err_out.writeAll("error: inspect requires a .chry file path\n");
        return 1;
    };

    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    var mapped = table.MappedTable.open(io, std.Io.Dir.cwd(), path, .{
        .verify_checksum = verify_crc,
    }) catch |e| {
        try err_out.print("error: failed to open '{s}': {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer mapped.close(io);
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const map_ns = elapsedNsSafe(t0, t1);
    const view = &mapped.view;

    if (json_mode) {
        try out.writeAll("{\n");
        try out.writeAll("  \"file\": ");
        try writeJsonString(out, path);
        try out.print(",\n  \"version\": {d},\n", .{view.version});
        try out.print("  \"rows\": {d},\n", .{view.row_count});
        try out.print("  \"columns_count\": {d},\n", .{view.col_count});
        try out.print("  \"total_bytes\": {d},\n", .{view.total_bytes});
        try out.print("  \"has_checksum\": {},\n", .{view.hasChecksum()});
        try out.print("  \"checksum_verified\": {},\n", .{verify_crc});
        try out.print("  \"mmap_open_ns\": {d},\n", .{map_ns});
        try out.writeAll("  \"columns\": [\n");

        for (0..view.col_count) |i| {
            const info = view.getColumnInfo(i).?;
            const agg = try query.aggregate(allocator, view, i, null);
            if (i > 0) try out.writeAll(",\n");
            try out.writeAll("    {\n");
            try out.print("      \"index\": {d},\n", .{info.index});
            try out.writeAll("      \"name\": ");
            if (info.name) |n| try writeJsonString(out, n) else try out.writeAll("null");
            try out.print(",\n      \"type\": \"{s}\",\n", .{info.col_type.name()});
            try out.print("      \"encoding\": \"{s}\",\n", .{info.encoding.name()});
            try out.print("      \"null_count\": {d},\n", .{info.null_count});
            try out.print("      \"data_offset\": {d},\n", .{info.data_offset});
            try out.print("      \"data_bytes\": {d},\n", .{info.data_byte_len});
            try out.print("      \"cache_line_aligned\": {},\n", .{info.is_cache_line_aligned});
            switch (agg) {
                .int32 => |s| {
                    try out.print("      \"sum\": {d},\n", .{s.sum});
                    if (s.min) |v| try out.print("      \"min\": {d},\n", .{v}) else try out.writeAll("      \"min\": null,\n");
                    if (s.max) |v| try out.print("      \"max\": {d},\n", .{v}) else try out.writeAll("      \"max\": null,\n");
                    try out.writeAll("      \"mean\": ");
                    try writeJsonFloatOrNull(out, s.mean);
                    try out.writeAll("\n");
                },
                .int64 => |s| {
                    try out.print("      \"sum\": {d},\n", .{s.sum});
                    if (s.min) |v| try out.print("      \"min\": {d},\n", .{v}) else try out.writeAll("      \"min\": null,\n");
                    if (s.max) |v| try out.print("      \"max\": {d},\n", .{v}) else try out.writeAll("      \"max\": null,\n");
                    try out.writeAll("      \"mean\": ");
                    try writeJsonFloatOrNull(out, s.mean);
                    try out.writeAll("\n");
                },
                .float64 => |s| {
                    try out.writeAll("      \"sum\": ");
                    try writeJsonFloatOrNull(out, s.sum);
                    try out.writeAll(",\n      \"min\": ");
                    try writeJsonFloatOrNull(out, s.min);
                    try out.writeAll(",\n      \"max\": ");
                    try writeJsonFloatOrNull(out, s.max);
                    try out.writeAll(",\n      \"mean\": ");
                    try writeJsonFloatOrNull(out, s.mean);
                    try out.writeAll("\n");
                },
            }
            try out.writeAll("    }");
        }
        try out.writeAll("\n  ]\n}\n");
    } else {
        try out.print(
            \\File:        {s}
            \\Format:      Chrysoberyl v{d}
            \\Rows:        {d}
            \\Columns:     {d}
            \\Total Bytes: {d}
            \\Checksum:    {s}
            \\mmap Open:   {d} ns
            \\
            \\Columns:
            \\
        , .{
            path,
            view.version,
            view.row_count,
            view.col_count,
            view.total_bytes,
            if (!view.hasChecksum()) "none" else if (verify_crc) "CRC32 verified" else "CRC32 present (use --verify)",
            map_ns,
        });

        for (0..view.col_count) |i| {
            const info = view.getColumnInfo(i).?;
            const agg = try query.aggregate(allocator, view, i, null);
            const col_name = info.name orelse "(unnamed)";
            try out.print("  [{d}] {s} ({s}, {s}, {d}B, nulls={d}, 64B-aligned={})", .{
                info.index,
                col_name,
                info.col_type.name(),
                info.encoding.name(),
                info.data_byte_len,
                info.null_count,
                info.is_cache_line_aligned,
            });
            switch (agg) {
                .int32 => |s| {
                    if (s.min != null and s.max != null) {
                        try out.print(" | min={d} max={d} sum={d} mean={d:.2}\n", .{ s.min.?, s.max.?, s.sum, s.mean.? });
                    } else {
                        try out.writeAll(" | all-null/empty\n");
                    }
                },
                .int64 => |s| {
                    if (s.min != null and s.max != null) {
                        try out.print(" | min={d} max={d} sum={d} mean={d:.2}\n", .{ s.min.?, s.max.?, s.sum, s.mean.? });
                    } else {
                        try out.writeAll(" | all-null/empty\n");
                    }
                },
                .float64 => |s| {
                    if (s.min != null and s.max != null) {
                        try out.print(" | min={d:.4} max={d:.4} sum={d:.4} mean={d:.4}\n", .{ s.min.?, s.max.?, s.sum, s.mean.? });
                    } else {
                        try out.writeAll(" | all-null/empty\n");
                    }
                },
            }
        }
    }

    return 0;
}

fn runQuery(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !u8 {
    var path_opt: ?[]const u8 = null;
    var where_specs: std.ArrayList([]const u8) = .empty;
    defer where_specs.deinit(allocator);
    var agg_col_ref: ?[]const u8 = null;
    var mode: query.CompoundMode = .and_all;
    var limit: usize = 10;
    var json_mode = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--where") or std.mem.eql(u8, arg, "-w")) {
            const expr = args.next() orelse {
                try err_out.writeAll("error: --where requires a predicate expression\n");
                return 1;
            };
            try where_specs.append(allocator, expr);
        } else if (std.mem.eql(u8, arg, "--agg")) {
            agg_col_ref = args.next() orelse {
                try err_out.writeAll("error: --agg requires a column name or index\n");
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--or")) {
            mode = .or_any;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const val = args.next() orelse {
                try err_out.writeAll("error: --limit requires an integer\n");
                return 1;
            };
            limit = std.fmt.parseInt(usize, val, 10) catch {
                try err_out.print("error: invalid --limit '{s}'\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (path_opt == null and !std.mem.startsWith(u8, arg, "--")) {
            path_opt = arg;
        } else {
            try err_out.print("error: unexpected argument '{s}'\n", .{arg});
            return 1;
        }
    }

    const path = path_opt orelse {
        try err_out.writeAll("error: query requires a .chry file path\n");
        return 1;
    };

    var mapped = table.MappedTable.open(io, std.Io.Dir.cwd(), path, .{}) catch |e| {
        try err_out.print("error: failed to open '{s}': {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer mapped.close(io);
    const view = &mapped.view;

    var predicates: std.ArrayList(query.Predicate) = .empty;
    defer predicates.deinit(allocator);
    for (where_specs.items) |spec| {
        const pred = query.parsePredicate(view, spec) catch |e| {
            try err_out.print("error: invalid predicate '{s}': {s}\n", .{ spec, @errorName(e) });
            return 1;
        };
        try predicates.append(allocator, pred);
    }

    const agg_col_idx: ?usize = if (agg_col_ref) |ref|
        query.resolveColumn(view, ref) catch |e| {
            try err_out.print("error: invalid --agg column '{s}': {s}\n", .{ ref, @errorName(e) });
            return 1;
        }
    else
        null;

    const t0 = std.Io.Clock.Timestamp.now(io, .awake);
    var mask = try query.evaluate(allocator, view, predicates.items, mode);
    defer mask.deinit(allocator);
    const matched_count = mask.count();
    const agg_result: ?query.AggregateResult = if (agg_col_idx) |cidx|
        try query.aggregate(allocator, view, cidx, &mask)
    else
        null;
    const t1 = std.Io.Clock.Timestamp.now(io, .awake);
    const query_ns = elapsedNsSafe(t0, t1);

    const sample_rows = try mask.collectIndices(allocator, limit);
    defer allocator.free(sample_rows);

    if (json_mode) {
        try out.writeAll("{\n");
        try out.print("  \"total_rows\": {d},\n", .{view.row_count});
        try out.print("  \"matched_rows\": {d},\n", .{matched_count});
        try out.print("  \"elapsed_ns\": {d},\n", .{query_ns});
        try out.writeAll("  \"sample_row_indices\": [");
        for (sample_rows, 0..) |r, idx| {
            if (idx > 0) try out.writeAll(", ");
            try out.print("{d}", .{r});
        }
        try out.writeAll("]");
        if (agg_result) |agg| {
            const info = view.getColumnInfo(agg_col_idx.?).?;
            try out.writeAll(",\n  \"aggregate\": {\n");
            try out.writeAll("    \"column\": ");
            if (info.name) |n| try writeJsonString(out, n) else try out.print("{d}", .{info.index});
            try out.writeAll(",\n");
            switch (agg) {
                .int32 => |s| {
                    try out.print("    \"valid_count\": {d},\n    \"null_count\": {d},\n    \"sum\": {d},\n", .{ s.valid_count, s.null_count, s.sum });
                    if (s.min) |v| try out.print("    \"min\": {d},\n", .{v}) else try out.writeAll("    \"min\": null,\n");
                    if (s.max) |v| try out.print("    \"max\": {d},\n", .{v}) else try out.writeAll("    \"max\": null,\n");
                    try out.writeAll("    \"mean\": ");
                    try writeJsonFloatOrNull(out, s.mean);
                    try out.writeAll("\n");
                },
                .int64 => |s| {
                    try out.print("    \"valid_count\": {d},\n    \"null_count\": {d},\n    \"sum\": {d},\n", .{ s.valid_count, s.null_count, s.sum });
                    if (s.min) |v| try out.print("    \"min\": {d},\n", .{v}) else try out.writeAll("    \"min\": null,\n");
                    if (s.max) |v| try out.print("    \"max\": {d},\n", .{v}) else try out.writeAll("    \"max\": null,\n");
                    try out.writeAll("    \"mean\": ");
                    try writeJsonFloatOrNull(out, s.mean);
                    try out.writeAll("\n");
                },
                .float64 => |s| {
                    try out.print("    \"valid_count\": {d},\n    \"null_count\": {d},\n    \"sum\": ", .{ s.valid_count, s.null_count });
                    try writeJsonFloatOrNull(out, s.sum);
                    try out.writeAll(",\n    \"min\": ");
                    try writeJsonFloatOrNull(out, s.min);
                    try out.writeAll(",\n    \"max\": ");
                    try writeJsonFloatOrNull(out, s.max);
                    try out.writeAll(",\n    \"mean\": ");
                    try writeJsonFloatOrNull(out, s.mean);
                    try out.writeAll("\n");
                },
            }
            try out.writeAll("  }\n");
        } else {
            try out.writeByte('\n');
        }
        try out.writeAll("}\n");
    } else {
        try out.print(
            "Matched {d} / {d} rows ({d:.3} ms)\n",
            .{ matched_count, view.row_count, @as(f64, @floatFromInt(query_ns)) / 1_000_000.0 },
        );
        if (agg_result) |agg| {
            const info = view.getColumnInfo(agg_col_idx.?).?;
            try out.print("Aggregate [{s}]: ", .{info.name orelse "(unnamed)"});
            switch (agg) {
                .int32 => |s| {
                    if (s.min != null and s.max != null) {
                        try out.print("valid={d} nulls={d} sum={d} min={d} max={d} mean={d:.4}\n", .{ s.valid_count, s.null_count, s.sum, s.min.?, s.max.?, s.mean.? });
                    } else {
                        try out.print("valid={d} nulls={d} (no valid values)\n", .{ s.valid_count, s.null_count });
                    }
                },
                .int64 => |s| {
                    if (s.min != null and s.max != null) {
                        try out.print("valid={d} nulls={d} sum={d} min={d} max={d} mean={d:.4}\n", .{ s.valid_count, s.null_count, s.sum, s.min.?, s.max.?, s.mean.? });
                    } else {
                        try out.print("valid={d} nulls={d} (no valid values)\n", .{ s.valid_count, s.null_count });
                    }
                },
                .float64 => |s| {
                    if (s.min != null and s.max != null) {
                        try out.print("valid={d} nulls={d} sum={d:.4} min={d:.4} max={d:.4} mean={d:.4}\n", .{ s.valid_count, s.null_count, s.sum, s.min.?, s.max.?, s.mean.? });
                    } else {
                        try out.print("valid={d} nulls={d} (no valid values)\n", .{ s.valid_count, s.null_count });
                    }
                },
            }
        }
        if (sample_rows.len > 0) {
            try out.print("Sample matching row indices (up to {d}): ", .{limit});
            for (sample_rows, 0..) |r, idx| {
                if (idx > 0) try out.writeAll(", ");
                try out.print("{d}", .{r});
            }
            try out.writeByte('\n');
        }
    }

    return 0;
}

fn runVerify(
    io: std.Io,
    args: *std.process.Args.Iterator,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !u8 {
    const path = args.next() orelse {
        try err_out.writeAll("error: verify requires a .chry file path\n");
        return 1;
    };

    var mapped = table.MappedTable.open(io, std.Io.Dir.cwd(), path, .{
        .verify_checksum = true,
    }) catch |e| {
        try err_out.print("INVALID '{s}': {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    defer mapped.close(io);

    try out.print(
        "OK '{s}': v{d}, {d} rows, {d} columns, {d} bytes, CRC32=0x{x:0>8}\n",
        .{ path, mapped.view.version, mapped.view.row_count, mapped.view.col_count, mapped.view.total_bytes, mapped.view.checksum_crc32 },
    );
    return 0;
}

test {
    _ = @import("column.zig");
    _ = @import("codec.zig");
    _ = @import("table.zig");
    _ = @import("query.zig");
}
