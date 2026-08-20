//! Development-only process-startup benchmark.

const std = @import("std");
const Io = std.Io;

const default_runs = 200;
const warmup_runs = 10;
const max_runs = 10_000;
const mean_budget_ns = 2 * std.time.ns_per_ms;
const p95_budget_ns = 5 * std.time.ns_per_ms;

const Options = struct {
    runs: usize = default_runs,
    check: bool = true,
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const output = &stdout_file.interface;
    defer output.flush() catch {};
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const errout = &stderr_file.interface;
    defer errout.flush() catch {};

    if (args.len < 2) fail(errout, "missing xaq executable", .{});
    const options = parseOptions(args[2..]) catch
        fail(errout, "usage: zig build perf -- [--runs N] [--no-check]", .{});
    if (options.help) {
        try output.writeAll(
            \\usage: zig build perf -- [--runs N] [--no-check]
            \\
            \\Builds a host ReleaseSmall xaq and measures process startup.
            \\The default 200-run test checks help and version paths against
            \\a 2 ms mean and 5 ms p95 latency ceiling. Size is reported only.
            \\
        );
        return;
    }

    const binary = args[1];
    const binary_size = size: {
        var file = Io.Dir.cwd().openFile(io, binary, .{}) catch |err|
            fail(errout, "cannot open benchmark binary: {s}", .{@errorName(err)});
        defer file.close(io);
        break :size (file.stat(io) catch |err|
            fail(errout, "cannot stat benchmark binary: {s}", .{@errorName(err)})).size;
    };

    var warmup: usize = 0;
    while (warmup < warmup_runs) : (warmup += 1) {
        _ = runOnce(io, binary, "--help") catch |err|
            fail(errout, "warmup failed: {s}", .{@errorName(err)});
        _ = runOnce(io, binary, "--version") catch |err|
            fail(errout, "version warmup failed: {s}", .{@errorName(err)});
    }

    const help_timings = try gpa.alloc(u64, options.runs);
    defer gpa.free(help_timings);
    const version_timings = try gpa.alloc(u64, options.runs);
    defer gpa.free(version_timings);
    const rss_samples = try gpa.alloc(u64, options.runs);
    defer gpa.free(rss_samples);
    var rss_count: usize = 0;
    var help_total_ns: u64 = 0;
    var version_total_ns: u64 = 0;

    for (help_timings) |*elapsed| {
        const start = Io.Clock.now(.awake, io);
        const rss = runOnce(io, binary, "--help") catch |err|
            fail(errout, "benchmark run failed: {s}", .{@errorName(err)});
        elapsed.* = @intCast(@max(0, Io.Clock.now(.awake, io).nanoseconds - start.nanoseconds));
        help_total_ns += elapsed.*;
        if (rss) |bytes| {
            rss_samples[rss_count] = @intCast(bytes);
            rss_count += 1;
        }
    }
    for (version_timings) |*elapsed| {
        const start = Io.Clock.now(.awake, io);
        _ = runOnce(io, binary, "--version") catch |err|
            fail(errout, "version benchmark run failed: {s}", .{@errorName(err)});
        elapsed.* = @intCast(@max(0, Io.Clock.now(.awake, io).nanoseconds - start.nanoseconds));
        version_total_ns += elapsed.*;
    }

    std.mem.sort(u64, help_timings, {}, std.sort.asc(u64));
    std.mem.sort(u64, version_timings, {}, std.sort.asc(u64));
    if (rss_count > 0) std.mem.sort(u64, rss_samples[0..rss_count], {}, std.sort.asc(u64));
    const help_mean_ns = help_total_ns / options.runs;
    const version_mean_ns = version_total_ns / options.runs;
    const help_p95_ns = percentile(help_timings, 95);
    const version_p95_ns = percentile(version_timings, 95);

    try output.writeAll("xaq perf\n  binary   ");
    try writeKib(output, binary_size);
    try output.print("\n  startup  {d} runs, {d} warmups per command\n  help     p50 ", .{ options.runs, warmup_runs });
    try writeMs(output, percentile(help_timings, 50));
    try output.writeAll(", p95 ");
    try writeMs(output, help_p95_ns);
    try output.writeAll(", mean ");
    try writeMs(output, help_mean_ns);
    try output.writeAll("\n  version  p50 ");
    try writeMs(output, percentile(version_timings, 50));
    try output.writeAll(", p95 ");
    try writeMs(output, version_p95_ns);
    try output.writeAll(", mean ");
    try writeMs(output, version_mean_ns);
    try output.writeByte('\n');
    if (rss_count > 0) {
        try output.writeAll("  peak RSS p50 ");
        try writeMib(output, percentile(rss_samples[0..rss_count], 50));
        try output.writeAll(", max ");
        try writeMib(output, rss_samples[rss_count - 1]);
        try output.writeByte('\n');
    }

    if (!options.check) {
        try output.writeAll("  budget   skipped\n");
        return;
    }
    const help_ok = help_mean_ns <= mean_budget_ns and help_p95_ns <= p95_budget_ns;
    const version_ok = version_mean_ns <= mean_budget_ns and version_p95_ns <= p95_budget_ns;
    if (help_ok and version_ok) {
        try output.writeAll("  budget   pass\n");
        return;
    }
    try output.writeAll("  budget   fail");
    if (!help_ok) try output.writeAll(" (help exceeds 2 ms mean or 5 ms p95)");
    if (!version_ok) try output.writeAll(" (version exceeds 2 ms mean or 5 ms p95)");
    try output.writeByte('\n');
    try output.flush();
    std.process.exit(1);
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const argument = args[i];
        if (std.mem.eql(u8, argument, "--runs")) {
            i += 1;
            if (i == args.len) return error.MissingRunCount;
            options.runs = try std.fmt.parseUnsigned(usize, args[i], 10);
            if (options.runs == 0 or options.runs > max_runs) return error.InvalidRunCount;
        } else if (std.mem.eql(u8, argument, "--no-check")) {
            options.check = false;
        } else if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) {
            options.help = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn runOnce(io: Io, binary: []const u8, argument: []const u8) !?usize {
    var child = try std.process.spawn(io, .{
        .argv = &.{ binary, argument },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .request_resource_usage_statistics = true,
    });
    defer if (child.id != null) child.kill(io);
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.TargetFailed,
        else => return error.TargetFailed,
    }
    return child.resource_usage_statistics.getMaxRss();
}

/// Nearest-rank percentile for a non-empty sorted sample.
fn percentile(sorted: []const u64, percent: usize) u64 {
    const rank = (sorted.len * percent + 99) / 100;
    return sorted[@max(rank, 1) - 1];
}

fn writeMs(output: *Io.Writer, ns: u64) !void {
    const tenths = ns * 10 / std.time.ns_per_ms;
    try output.print("{d}.{d} ms", .{ tenths / 10, tenths % 10 });
}

fn writeKib(output: *Io.Writer, bytes: u64) !void {
    const tenths = bytes * 10 / 1024;
    try output.print("{d}.{d} KiB", .{ tenths / 10, tenths % 10 });
}

fn writeMib(output: *Io.Writer, bytes: u64) !void {
    const tenths = bytes * 10 / (1024 * 1024);
    try output.print("{d}.{d} MiB", .{ tenths / 10, tenths % 10 });
}

fn fail(output: *Io.Writer, comptime format: []const u8, args: anytype) noreturn {
    output.print("xaq perf: " ++ format ++ "\n", args) catch {};
    output.flush() catch {};
    std.process.exit(2);
}

test "options accept bounded run counts and report-only mode" {
    const options = try parseOptions(&.{ "--runs", "400", "--no-check" });
    try std.testing.expectEqual(400, options.runs);
    try std.testing.expect(!options.check);
    try std.testing.expectError(error.InvalidRunCount, parseOptions(&.{ "--runs", "0" }));
    try std.testing.expectError(error.InvalidRunCount, parseOptions(&.{ "--runs", "10001" }));
    try std.testing.expectError(error.UnknownArgument, parseOptions(&.{"--wat"}));
}

test "percentile uses nearest rank" {
    const samples = [_]u64{ 10, 20, 30, 40, 50 };
    try std.testing.expectEqual(30, percentile(&samples, 50));
    try std.testing.expectEqual(50, percentile(&samples, 95));
}
