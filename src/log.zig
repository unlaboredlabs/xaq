//! Opt-in trace log patterned after fx's `debug_trace`: timestamped
//! `[scope] event=... key=value` lines in a single size-capped file,
//! disabled unless requested through the environment, and best-effort
//! throughout—logging failures never disturb the agent.
//!
//! Disk pressure is kept low on purpose. The file is opened once per
//! process; lines accumulate in a fixed buffer and reach the disk as
//! large batched appends (buffer full, `flush`, or `shutdown`), never
//! per line and never fsynced. Rotation renames the file, which moves
//! metadata only and copies no data.
//!
//! Environment:
//!   XAQ_LOG=1          log to ~/.config/xaq/trace.log
//!   XAQ_LOG=PATH       log to PATH
//!   XAQ_LOG_SCOPES=a,b only emit the listed scopes

const std = @import("std");
const Io = std.Io;

const max_log_bytes: u64 = 2 * 1024 * 1024;

var active = false;
var log_io: Io = undefined;
var file: Io.File = undefined;
var writer: Io.File.Writer = undefined;
var write_buffer: [16 * 1024]u8 = undefined;
var filter_buffer: [128]u8 = undefined;
var filter: ?[]const u8 = null;
var path_buffer: [1024]u8 = undefined;
var path_len: usize = 0;

/// Best effort: any failure leaves logging disabled. `gpa` is used only for
/// short-lived path strings.
pub fn init(gpa: std.mem.Allocator, io: Io, home: []const u8, env_value: ?[]const u8, env_scopes: ?[]const u8) void {
    if (active) return;
    const path = (choosePath(gpa, home, env_value) catch return) orelse return;
    defer gpa.free(path);
    open(gpa, io, path) catch return;
    // An over-long path cannot be reported truthfully by activePath();
    // store nothing rather than lying about where the log lives.
    path_len = if (path.len <= path_buffer.len) path.len else 0;
    @memcpy(path_buffer[0..path_len], path[0..path_len]);
    if (env_scopes) |scopes| {
        const trimmed = std.mem.trim(u8, scopes, " \t\r\n");
        if (trimmed.len > 0 and trimmed.len <= filter_buffer.len) {
            @memcpy(filter_buffer[0..trimmed.len], trimmed);
            filter = filter_buffer[0..trimmed.len];
        }
    }
    active = true;
}

/// Append one line: `<unix-millis> [scope] <formatted message>`. The line
/// stays in memory until a batched flush; callers must not log secrets or
/// message content—stick to names, counts, and sizes.
pub fn logf(scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!enabledFor(scope)) return;
    writer.interface.print("{d} [{s}] " ++ fmt ++ "\n", .{ timestampMillis(), scope } ++ args) catch disable();
}

/// The log file path while logging is active, for `/status`.
pub fn activePath() ?[]const u8 {
    if (!active or path_len == 0) return null;
    return path_buffer[0..path_len];
}

/// Write buffered lines in one append. Call at natural boundaries (once per
/// provider round), not per line.
pub fn flush() void {
    if (!active) return;
    writer.interface.flush() catch return disable();
    // The startup-time size cap also applies to long-running sessions:
    // rotate in place once the file outgrows it.
    if (writer.pos < max_log_bytes) return;
    if (path_len == 0) return disable();
    const path = path_buffer[0..path_len];
    file.close(log_io);
    active = false;
    var old_buffer: [path_buffer.len + 4]u8 = undefined;
    const old = std.fmt.bufPrint(&old_buffer, "{s}.old", .{path}) catch return;
    Io.Dir.cwd().rename(path, Io.Dir.cwd(), old, log_io) catch return;
    file = Io.Dir.cwd().createFile(log_io, path, .{ .truncate = true, .permissions = @enumFromInt(0o600) }) catch return;
    writer = .init(file, log_io, &write_buffer);
    active = true;
}

pub fn shutdown() void {
    if (!active) return;
    writer.interface.flush() catch {};
    file.close(log_io);
    active = false;
    filter = null;
}

fn disable() void {
    file.close(log_io);
    active = false;
}

fn enabledFor(scope: []const u8) bool {
    if (!active) return false;
    return scopeAllowed(filter orelse return true, scope);
}

fn scopeAllowed(list: []const u8, scope: []const u8) bool {
    var parts = std.mem.splitScalar(u8, list, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t"), scope)) return true;
    }
    return false;
}

/// Returns the owned log path, or null when logging stays disabled.
fn choosePath(gpa: std.mem.Allocator, home: []const u8, env_value: ?[]const u8) !?[]u8 {
    if (!requested(env_value)) return null;
    const raw = std.mem.trim(u8, env_value.?, " \t\r\n");
    if (isTruthy(raw)) return try std.fs.path.join(gpa, &.{ home, ".config", "xaq", "trace.log" });
    return try gpa.dupe(u8, raw);
}

/// Whether XAQ_LOG activates logging. Startup uses this to keep the help and
/// version fast path behavior-identical when logging is explicitly enabled.
pub fn requested(env_value: ?[]const u8) bool {
    const raw = std.mem.trim(u8, env_value orelse return false, " \t\r\n");
    return raw.len > 0 and !isFalsy(raw);
}

/// Shared by other environment toggles such as XAQ_PLAIN.
pub fn isTruthy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "on");
}

fn isFalsy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "0") or std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "off");
}

fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    rotateIfTooLarge(gpa, io, path);
    file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = @enumFromInt(0o600) });
    errdefer file.close(io);
    const len = try file.length(io);
    log_io = io;
    writer = .init(file, io, &write_buffer);
    writer.pos = len;
}

fn rotateIfTooLarge(gpa: std.mem.Allocator, io: Io, path: []const u8) void {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return;
    if (stat.size < max_log_bytes) return;
    const old = std.fmt.allocPrint(gpa, "{s}.old", .{path}) catch return;
    defer gpa.free(old);
    Io.Dir.cwd().rename(path, Io.Dir.cwd(), old, io) catch {};
}

fn timestampMillis() i64 {
    const now = Io.Clock.now(.real, log_io);
    return @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
}

test "choosePath honors truthy, falsy, and explicit values" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(null, try choosePath(gpa, "/home/u", null));
    try std.testing.expectEqual(null, try choosePath(gpa, "/home/u", " \t"));
    try std.testing.expectEqual(null, try choosePath(gpa, "/home/u", "off"));

    const default_path = (try choosePath(gpa, "/home/u", "1")).?;
    defer gpa.free(default_path);
    try std.testing.expectEqualStrings("/home/u/.config/xaq/trace.log", default_path);

    const explicit = (try choosePath(gpa, "/home/u", " /tmp/xaq.log\n")).?;
    defer gpa.free(explicit);
    try std.testing.expectEqualStrings("/tmp/xaq.log", explicit);
}

test "requested matches logging activation" {
    try std.testing.expect(!requested(null));
    try std.testing.expect(!requested(" \t"));
    try std.testing.expect(!requested("off"));
    try std.testing.expect(requested("1"));
    try std.testing.expect(requested(" /tmp/xaq.log\n"));
}

test "scope filter matches trimmed comma-separated entries" {
    try std.testing.expect(scopeAllowed("agent, tool", "agent"));
    try std.testing.expect(scopeAllowed("agent, tool", "tool"));
    try std.testing.expect(!scopeAllowed("agent, tool", "usage"));
    try std.testing.expect(!scopeAllowed("", "agent"));
}
