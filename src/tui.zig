//! Optional fullscreen layer over the inline session. The alternate
//! screen hosts a pinned status bar on row 1 and a terminal-managed
//! scroll region below it; the unmodified inline engine (composer,
//! completion popup, pickers, streaming) runs inside that region.
//!
//! The layer adds only what a bare pipe cannot give: a live stats bar
//! (state, context pressure, token counts), best-effort transcript
//! paging with PgUp/PgDn at the prompt, and a clean restore on exit.
//! It borrows deliberately: claude code's always-visible stats, codex's
//! transcript paging, grok build's single-bar minimal chrome, and pi's
//! inline engine as the default fallback (`--plain`, `XAQ_PLAIN=1`, or
//! any non-terminal stream).
//!
//! No cell grid, no themes, no mouse. Transcript history is captured by
//! reassembling the byte stream (carriage returns overwrite, escapes are
//! dropped), so paged history is unstyled and approximate by design.

const std = @import("std");
const Io = std.Io;
const term = @import("term.zig");

pub var active = false;

pub const State = enum { idle, thinking, tooling };

const max_lines = 2000;
const max_line_bytes = 512;

var gpa_state: std.mem.Allocator = undefined;
var sink: *Io.Writer = undefined;
var tee: Io.Writer = undefined;
var tee_buffer: [4096]u8 = undefined;

var rows: usize = 24;
var cols: usize = 80;

// Status bar model. Fixed buffers: the bar never allocates.
var provider_buffer: [16]u8 = undefined;
var provider_len: usize = 0;
var model_buffer: [96]u8 = undefined;
var model_len: usize = 0;
var thread_buffer: [20]u8 = undefined;
var thread_len: usize = 0;
var state: State = .idle;
var detail_buffer: [48]u8 = undefined;
var detail_len: usize = 0;
var tokens_in: u64 = 0;
var tokens_out: u64 = 0;
var context_percent: u8 = 0;

// Committed transcript lines, a ring of owned unstyled strings.
var lines: [max_lines][]u8 = undefined;
var line_start: usize = 0;
var line_count: usize = 0;
var current: [max_line_bytes]u8 = undefined;
var current_len: usize = 0;
var scroll_offset: usize = 0;
var suppressed = false;
var esc_state: enum { text, escape, csi, osc, osc_escape } = .text;

/// Switch to the alternate screen and return the writer the agent should
/// use; all agent output flows through it onto the screen and into the
/// transcript ring. Fails (leaving the terminal untouched) when the
/// window is too small.
pub fn enter(gpa: std.mem.Allocator, out: *Io.Writer) !*Io.Writer {
    gpa_state = gpa;
    sink = out;
    measure();
    if (rows < 6 or cols < 40) return error.TerminalTooSmall;
    try out.writeAll("\x1b[?1049h\x1b[2J");
    try out.print("\x1b[2;{d}r\x1b[{d};1H", .{ rows, 2 });
    active = true;
    renderBar();
    try out.flush();
    tee = .{ .vtable = &.{ .drain = drain }, .buffer = &tee_buffer };
    return &tee;
}

/// Restore the primary screen. Safe to call twice; must run before the
/// process exits, including error paths.
pub fn exit() void {
    if (!active) return;
    active = false;
    sink.writeAll("\x1b[r\x1b[?1049l") catch {};
    sink.flush() catch {};
    var i: usize = 0;
    while (i < line_count) : (i += 1) gpa_state.free(lines[(line_start + i) % max_lines]);
    line_start = 0;
    line_count = 0;
    current_len = 0;
    scroll_offset = 0;
}

pub fn noteIdentity(provider: []const u8, model: []const u8, thread: ?[]const u8) void {
    if (!active) return;
    provider_len = copyInto(&provider_buffer, provider);
    model_len = copyInto(&model_buffer, model);
    thread_len = if (thread) |id| copyInto(&thread_buffer, id) else 0;
    renderBar();
}

pub fn noteState(next: State, detail: []const u8) void {
    if (!active) return;
    state = next;
    detail_len = copyInto(&detail_buffer, detail);
    renderBar();
}

pub fn noteUsage(input_tokens: u64, output_tokens: u64, percent: u8) void {
    if (!active) return;
    tokens_in = input_tokens;
    tokens_out = output_tokens;
    context_percent = @min(percent, 100);
    renderBar();
}

/// The editor calls this around redraw churn (popup rows, pickers) so
/// only genuinely displayed lines are committed to the transcript ring.
pub fn setSuppress(on: bool) void {
    if (!active) return;
    suppressed = on;
    current_len = 0;
    esc_state = .text;
}

/// Page the transcript at the prompt. Returns whether the caller should
/// redraw its input line (the region content changed underneath it).
pub fn pageUp() bool {
    return page(true);
}

pub fn pageDown() bool {
    return page(false);
}

fn page(up: bool) bool {
    if (!active) return false;
    const region = rows -| 1;
    const step = @max(region -| 2, 1);
    const max_offset = line_count -| (region - 1);
    const previous = scroll_offset;
    scroll_offset = if (up) @min(scroll_offset + step, max_offset) else scroll_offset -| step;
    if (scroll_offset == previous) return false;
    repaint() catch {};
    return true;
}

fn repaint() !void {
    const region = rows -| 1;
    const end = line_count - scroll_offset;
    const begin = end -| (region - 1);
    try sink.writeAll("\x1b[2;1H\x1b[J");
    var row: usize = 2;
    var index = begin;
    while (index < end) : (index += 1) {
        const line = lines[(line_start + index) % max_lines];
        try sink.print("\x1b[{d};1H", .{row});
        try sink.writeAll(line[0..@min(line.len, cols)]);
        row += 1;
    }
    try sink.print("\x1b[{d};1H", .{row});
    try sink.flush();
}

fn copyInto(buffer: []u8, text: []const u8) usize {
    const count = @min(text.len, buffer.len);
    @memcpy(buffer[0..count], text[0..count]);
    return count;
}

fn measure() void {
    if (@import("builtin").os.tag == .linux) {
        var window: std.posix.winsize = undefined;
        const rc = std.os.linux.ioctl(Io.File.stdout().handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&window));
        if (rc == 0) {
            if (window.row > 0) rows = window.row;
            if (window.col > 0) cols = window.col;
        }
    }
}

/// Redraw row 1 in place; re-arms the scroll region after a resize.
fn renderBar() void {
    const previous_rows = rows;
    measure();
    if (rows != previous_rows) {
        sink.print("\x1b[2;{d}r", .{rows}) catch return;
    }
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    writeBarText(&writer) catch {};
    const text = writer.buffered();
    const shown = @min(text.len, cols);
    sink.writeAll("\x1b7\x1b[1;1H") catch return;
    if (term.enabled) sink.writeAll("\x1b[7m") catch return;
    sink.writeAll(text[0..shown]) catch return;
    sink.writeAll("\x1b[K") catch return;
    if (term.enabled) sink.writeAll("\x1b[27m") catch return;
    sink.writeAll("\x1b8") catch return;
    sink.flush() catch return;
}

fn writeBarText(writer: *Io.Writer) !void {
    try writer.print(" xaq \u{b7} {s}/{s}", .{ provider_buffer[0..provider_len], model_buffer[0..model_len] });
    if (thread_len > 0) try writer.print(" \u{b7} {s}", .{thread_buffer[0..@min(thread_len, 8)]});
    try writer.print(" \u{b7} ctx {d}% \u{b7} \u{2191}", .{context_percent});
    try writeCount(writer, tokens_in);
    try writer.writeAll(" \u{2193}");
    try writeCount(writer, tokens_out);
    switch (state) {
        .idle => try writer.writeAll(" \u{b7} ready"),
        .thinking => try writer.writeAll(" \u{b7} thinking\u{2026}"),
        .tooling => try writer.print(" \u{b7} [{s}]", .{detail_buffer[0..detail_len]}),
    }
    if (state == .idle) try writer.writeAll(" \u{b7} pgup/pgdn history");
}

fn writeCount(writer: *Io.Writer, count: u64) !void {
    if (count < 1000) {
        try writer.print("{d}", .{count});
    } else if (count < 1_000_000) {
        const tenths = (count + 50) / 100;
        try writer.print("{d}.{d}k", .{ tenths / 10, tenths % 10 });
    } else {
        const tenths = (count + 50_000) / 100_000;
        try writer.print("{d}.{d}m", .{ tenths / 10, tenths % 10 });
    }
}

fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const buffered = w.buffer[0..w.end];
    if (buffered.len > 0) {
        forward(buffered) catch return error.WriteFailed;
        w.end = 0;
    }
    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |slice| {
        forward(slice) catch return error.WriteFailed;
        consumed += slice.len;
    }
    var repeat: usize = 0;
    while (repeat < splat) : (repeat += 1) {
        forward(data[data.len - 1]) catch return error.WriteFailed;
        consumed += data[data.len - 1].len;
    }
    sink.flush() catch return error.WriteFailed;
    return consumed;
}

fn forward(bytes: []const u8) !void {
    try sink.writeAll(bytes);
    ingest(bytes);
}

/// Reassemble displayed lines from the raw byte stream: carriage return
/// rewinds the line, newline commits it, escape sequences are dropped.
fn ingest(bytes: []const u8) void {
    if (suppressed) return;
    for (bytes) |byte| switch (esc_state) {
        .text => switch (byte) {
            0x1b => esc_state = .escape,
            '\r' => current_len = 0,
            '\n' => commit(),
            '\t' => appendByte(' '),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
            else => appendByte(byte),
        },
        .escape => esc_state = switch (byte) {
            '[' => .csi,
            ']' => .osc,
            else => .text,
        },
        .csi => if (byte >= 0x40 and byte <= 0x7e) {
            esc_state = .text;
        },
        .osc => switch (byte) {
            0x07 => esc_state = .text,
            0x1b => esc_state = .osc_escape,
            else => {},
        },
        .osc_escape => esc_state = if (byte == '\\') .text else .osc,
    };
}

fn appendByte(byte: u8) void {
    if (current_len < current.len) {
        current[current_len] = byte;
        current_len += 1;
    }
}

fn commit() void {
    // New output always snaps the view back to live.
    scroll_offset = 0;
    const copy = gpa_state.dupe(u8, current[0..current_len]) catch {
        current_len = 0;
        return;
    };
    current_len = 0;
    if (line_count == max_lines) {
        gpa_state.free(lines[line_start]);
        line_start = (line_start + 1) % max_lines;
        line_count -= 1;
    }
    lines[(line_start + line_count) % max_lines] = copy;
    line_count += 1;
}

test "bar text stays within its buffer and shows state" {
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    provider_len = copyInto(&provider_buffer, "chatgpt");
    model_len = copyInto(&model_buffer, "gpt-5.6-sol");
    thread_len = copyInto(&thread_buffer, "AbCdEfGh12345678");
    tokens_in = 12_345;
    tokens_out = 678;
    context_percent = 42;
    state = .tooling;
    detail_len = copyInto(&detail_buffer, "bash");
    try writeBarText(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.find(u8, text, "chatgpt/gpt-5.6-sol") != null);
    try std.testing.expect(std.mem.find(u8, text, "AbCdEfGh") != null);
    try std.testing.expect(std.mem.find(u8, text, "ctx 42%") != null);
    try std.testing.expect(std.mem.find(u8, text, "12.3k") != null);
    try std.testing.expect(std.mem.find(u8, text, "[bash]") != null);
    state = .idle;
    detail_len = 0;
    thread_len = 0;
}

test "ingest reassembles overwritten lines and drops escapes" {
    const gpa = std.testing.allocator;
    gpa_state = gpa;
    suppressed = false;
    ingest("\x1b[2mhello\r\x1b[1mworld\x1b[0m\nplain\ttext\n");
    try std.testing.expectEqual(2, line_count);
    try std.testing.expectEqualStrings("world", lines[0]);
    try std.testing.expectEqualStrings("plain text", lines[1]);
    var i: usize = 0;
    while (i < line_count) : (i += 1) gpa.free(lines[(line_start + i) % max_lines]);
    line_count = 0;
    line_start = 0;
    current_len = 0;
}
