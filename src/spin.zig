//! One continuously animating spinner for the whole process. It runs as a
//! concurrent Io task at a fixed cadence, independent of stream events, so
//! it never freezes while a provider is silent. Inline, frames bypass the
//! shared Io.Writer and go straight to the stdout fd; in fullscreen they
//! animate in the TUI's info bar and, while that row is free, the live
//! transcript row. Transcript frames stop once response text arrives. Both
//! routes serialize with the chrome under the render mutex. Either way the
//! foreground flushes before `start`, and `stop` awaits the task before
//! anything else prints, so frames and output never interleave. Everything
//! is a no-op when styling is disabled or the Io implementation cannot
//! provide concurrency.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const term = @import("term.zig");
const tui = @import("tui.zig");

const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const frame_interval_ms = 80;
const inline_frame_bytes = 256;
const Mode = enum { transcript, status };

var out_fd: std.posix.fd_t = std.posix.STDOUT_FILENO;
var future: ?Io.Future(void) = null;
var io_handle: Io = undefined;
var label: []const u8 = "";
var mode: Mode = .transcript;

/// Begin animating a dim `⠙ label`, redrawn in place. The label must
/// outlive the spinner (pass a literal). No-op when styling is disabled
/// or a spinner is already running.
pub fn start(io: Io, text: []const u8) void {
    if (tui.active) {
        // Fullscreen also shows the label statically in the info bar;
        // frames animate on the transcript's live row.
        tui.setActivity(text);
    } else if (!term.enabled) return;
    if (future != null) return;
    label = text;
    io_handle = io;
    mode = .transcript;
    future = io.concurrent(loop, .{ io, mode }) catch return;
}

/// Move fullscreen animation out of the transcript before streamed text
/// arrives. Inline mode erases its spinner because the text itself becomes
/// the visible activity indicator.
pub fn textStarted() void {
    if (!tui.active) return stop();
    if (future) |running_value| {
        var running = running_value;
        future = null;
        running.cancel(io_handle);
        if (mode == .transcript) tui.spinnerClear();
    }
    mode = .status;
    future = io_handle.concurrent(loop, .{ io_handle, mode }) catch return;
}

/// Stop and erase the spinner line. Cancels and awaits the task, so no
/// frame can land after this returns. Safe to call when nothing runs.
pub fn stop() void {
    var running = future orelse {
        if (tui.active) tui.setActivity(null);
        return;
    };
    future = null;
    running.cancel(io_handle);
    if (tui.active) {
        if (mode == .transcript) tui.spinnerClear();
        tui.setActivity(null);
    } else {
        write("\r\x1b[K");
    }
}

fn loop(io: Io, render_mode: Mode) void {
    var frame: usize = 0;
    while (true) {
        if (tui.active) {
            tui.spinnerStatusFrame(frames[frame]);
            if (render_mode == .transcript) tui.spinnerFrame(frames[frame], label);
        } else {
            var buffer: [inline_frame_bytes]u8 = undefined;
            const max_cols: usize = if (term.windowSize()) |size| size.cols else 80;
            write(formatInlineFrame(&buffer, frames[frame], label, max_cols));
        }
        frame = (frame + 1) % frames.len;
        io.sleep(.fromMilliseconds(frame_interval_ms), .awake) catch return;
    }
}

/// Build one inline frame without allowing a long activity label to terminate
/// the animation or wrap onto another terminal row.
fn formatInlineFrame(buffer: []u8, glyph: []const u8, text: []const u8, max_cols: usize) []const u8 {
    var writer: Io.Writer = .fixed(buffer);
    writer.print("\r{s}{s} ", .{ term.dim(), glyph }) catch return "";
    const suffix = term.reset();
    const available_bytes = buffer.len -| writer.buffered().len -| suffix.len;
    const available_cols = max_cols -| term.displayWidth(glyph) -| 1;
    var shown: usize = 0;
    var columns: usize = 0;
    while (shown < text.len) {
        const cell = term.nextCell(text, shown);
        if (cell.end > available_bytes or columns + cell.width > available_cols) break;
        shown = cell.end;
        columns += cell.width;
    }
    writer.writeAll(text[0..shown]) catch return "";
    writer.writeAll(suffix) catch return "";
    return writer.buffered();
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

    const long_label = "Running a command whose activity description is much longer than the old inline frame buffer";
    start(io, long_label);
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
    try std.testing.expect(std.mem.find(u8, written, "⠋ Running a command") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\x1b[K"));
}

test "inline frames clip oversized labels without disappearing" {
    const was_enabled = term.enabled;
    term.enabled = true;
    defer term.enabled = was_enabled;

    var activity_label: [512]u8 = undefined;
    @memset(&activity_label, 'x');
    var buffer: [inline_frame_bytes]u8 = undefined;
    const line = formatInlineFrame(&buffer, frames[0], &activity_label, std.math.maxInt(usize));

    try std.testing.expectEqual(@as(usize, inline_frame_bytes), line.len);
    try std.testing.expect(std.mem.startsWith(u8, line, "\r\x1b[2m⠋ "));
    try std.testing.expect(std.mem.endsWith(u8, line, "\x1b[0m"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
}

test "inline frames fit the terminal width" {
    const was_enabled = term.enabled;
    term.enabled = true;
    defer term.enabled = was_enabled;

    var buffer: [inline_frame_bytes]u8 = undefined;
    const line = formatInlineFrame(&buffer, frames[0], "abcdefghijklmnopqrstuvwxyz", 12);

    try std.testing.expect(std.mem.indexOf(u8, line, "abcdefghij") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "k") == null);
    try std.testing.expect(std.mem.endsWith(u8, line, "\x1b[0m"));
}

test "start is a no-op when styling is disabled" {
    start(undefined, "nope");
    try std.testing.expect(future == null);
    stop();
}
