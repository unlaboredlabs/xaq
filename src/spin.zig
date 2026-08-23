//! One continuously animating spinner for the whole process. It runs as a
//! concurrent Io task at a fixed cadence, independent of stream events, so
//! it never freezes while a provider is silent. Inline, frames bypass the
//! shared Io.Writer and go straight to the stdout fd; in fullscreen they
//! go through the TUI's live transcript row, which serializes them with
//! the chrome under the render mutex. Either way the foreground flushes
//! before `start`, and `stop` awaits the task before anything else prints,
//! so frames and output never interleave. Everything is a no-op when
//! styling is disabled or the Io implementation cannot provide
//! concurrency.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const term = @import("term.zig");
const tui = @import("tui.zig");

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const frame_interval_ms = 80;

var out_fd: std.posix.fd_t = std.posix.STDOUT_FILENO;
var future: ?Io.Future(void) = null;
var io_handle: Io = undefined;
var label: []const u8 = "";
var fallback_visible = false;

/// Begin animating a dim `⠙ label`, redrawn in place. The label must
/// outlive the spinner (pass a literal). No-op when styling is disabled
/// or a spinner is already running.
pub fn start(io: Io, text: []const u8) void {
    if (future != null) return;
    if (!tui.active and !term.enabled) return;
    label = text;
    io_handle = io;
    future = io.concurrent(loop, .{io}) catch {
        // Keep the activity visible even when this Io implementation cannot
        // animate it. `stop` clears the fallback frame with the normal path.
        if (tui.active) {
            tui.spinnerFrame(frames[0], label);
            fallback_visible = true;
        }
        return;
    };
}

/// Stop and erase the spinner line. Cancels and awaits the task, so no
/// frame can land after this returns. Safe to call when nothing runs.
pub fn stop() void {
    var running = future orelse {
        if (fallback_visible and tui.active) tui.spinnerClear();
        fallback_visible = false;
        return;
    };
    future = null;
    running.cancel(io_handle);
    fallback_visible = false;
    if (tui.active) {
        tui.spinnerClear();
    } else {
        write("\r\x1b[K");
    }
}

fn loop(io: Io) void {
    var frame: usize = 0;
    while (true) {
        if (tui.active) {
            tui.spinnerFrame(frames[frame], label);
        } else {
            var buffer: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "\r{s}{s} {s}{s}", .{ term.dim(), frames[frame], label, term.reset() }) catch return;
            write(line);
        }
        frame = (frame + 1) % frames.len;
        io.sleep(.fromMilliseconds(frame_interval_ms), .awake) catch return;
    }
}

/// Direct synchronous fd write: std.posix no longer carries write();
/// the raw syscall (libc on non-Linux) is the whole point here, since
/// frames must bypass the shared buffered writer.
fn write(bytes: []const u8) void {
    var index: usize = 0;
    while (index < bytes.len) {
        if (builtin.os.tag == .linux) {
            const rc = std.os.linux.write(out_fd, bytes.ptr + index, bytes.len - index);
            if (std.os.linux.errno(rc) != .SUCCESS) return;
            index += rc;
        } else {
            const rc = std.c.write(out_fd, bytes.ptr + index, bytes.len - index);
            if (rc <= 0) return;
            index += @intCast(rc);
        }
    }
}

test "spinner draws at least one frame and erases on stop" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "spin.log", .{ .read = true });
    defer file.close(io);
    out_fd = file.handle;
    defer out_fd = std.posix.STDOUT_FILENO;
    term.enabled = true;
    defer term.enabled = false;

    start(io, "testing");
    try std.testing.expect(future != null);
    io.sleep(.fromMilliseconds(2 * frame_interval_ms), .awake) catch {};
    stop();
    try std.testing.expect(future == null);

    var read_buffer: [4096]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);
    var written_buffer: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < written_buffer.len) {
        const count = file_reader.interface.readSliceShort(written_buffer[total..]) catch break;
        if (count == 0) break;
        total += count;
    }
    const written = written_buffer[0..total];
    try std.testing.expect(std.mem.find(u8, written, "⠋ testing") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\x1b[K"));
}

test "start is a no-op when styling is disabled" {
    start(undefined, "nope");
    try std.testing.expect(future == null);
    stop();
}
