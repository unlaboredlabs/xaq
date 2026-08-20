//! Fullscreen session view. Fixed chrome, scrolling middle:
//!
//!   row 1        outer margin
//!   row 2        top bar: identity (xaq · provider/model · thread)
//!   rows 3..H-6  scroll region: the conversation transcript
//!   row H-5      input box top border
//!   row H-4      input box content:  │ > prompt text │
//!   row H-3      input box bottom border
//!   row H-2      gap above the info bar
//!   row H-1      info bar: context %, tokens, activity, key hints
//!   row H        outer margin
//!
//! The transcript is the only place the agent writes: its output flows
//! through a tee writer that repositions to a tracked region cursor,
//! paints the screen, and reassembles committed lines (SGR styling kept,
//! other escapes dropped) into a ring that powers PgUp/PgDn paging and
//! repainting under the completion popup overlay. The editor draws the
//! input row and popup through explicit chrome calls—never `ESC[J`—so
//! the borders and bars are safe by construction.
//!
//! Activity comes from the spinner facade: in fullscreen its frames are
//! routed through the live transcript row (`spinnerFrame`/`spinnerClear`)
//! under the render mutex, and the label also shows statically in the
//! info bar. `--plain`, pipes, one-shots, and small terminals keep the
//! inline flow on the raw fd.

const std = @import("std");
const Io = std.Io;
const term = @import("term.zig");

pub var active = false;

pub const State = enum { idle, thinking, tooling };

const max_lines = 2000;
const max_line_bytes = 512;
const min_rows = 10;
const min_cols = 40;
const edge_margin = 1;
const status_gap = 1;
const startup_hint_duration_ns: i96 = 1500 * std.time.ns_per_ms;

var gpa_state: std.mem.Allocator = undefined;
var sink: *Io.Writer = undefined;
var tee: Io.Writer = undefined;
var tee_buffer: [4096]u8 = undefined;
var io_state: Io = undefined;
var render_mutex: Io.Mutex = .init;
var resize_event: Io.Event = .unset;
var resize_future: ?Io.Future(void) = null;
var old_winch: std.posix.Sigaction = undefined;
var winch_installed = false;
var input_active = false;
var startup_hint_buffer: [48]u8 = undefined;
var startup_hint_len: usize = 0;
var startup_hint_deadline_ns: i96 = 0;

var rows: usize = 24;
var cols: usize = 80;
var layout_ready = false;
var layout_dirty = false;

// Bars' model; fixed buffers so rendering never allocates.
var provider_buffer: [16]u8 = undefined;
var provider_len: usize = 0;
var model_buffer: [96]u8 = undefined;
var model_len: usize = 0;
var effort_buffer: [16]u8 = undefined;
var effort_len: usize = 0;
var fast_enabled = false;
var thread_buffer: [20]u8 = undefined;
var thread_len: usize = 0;
var git_present = false;
var worktree_buffer: [128]u8 = undefined;
var worktree_len: usize = 0;
var branch_buffer: [128]u8 = undefined;
var branch_len: usize = 0;
var git_dirty = false;
var state: State = .idle;
var detail_buffer: [48]u8 = undefined;
var detail_len: usize = 0;
var activity_buffer: [48]u8 = undefined;
var activity_len: usize = 0;
var tokens_in: u64 = 0;
var tokens_out: u64 = 0;
var context_percent: u8 = 0;
var agents_running: u8 = 0;
var agents_queued: u8 = 0;
var steering_queued: u8 = 0;
var follow_ups_queued: u8 = 0;

// Transcript writes restore this cursor while the concurrent editor owns the
// fixed input row.
var input_cursor_row: usize = 0;
var input_cursor_col: usize = 0;

// Transcript ring of committed lines plus the in-progress partial line.
// `truncated` marks lines that overflowed the per-line byte budget, so
// repaints can show an ellipsis instead of pretending the line is whole.
var lines: [max_lines][]u8 = undefined;
var lines_truncated: [max_lines]bool = undefined;
var line_start: usize = 0;
var line_count: usize = 0;
var current: [max_line_bytes]u8 = undefined;
var current_len: usize = 0;
var current_truncated = false;
var pending_cr = false;
var live_repaint_pending = false;
var scroll_offset: usize = 0;

// Partial UTF-8 code point being ingested, for width tracking.
var cp_pending: u21 = 0;
var cp_remaining: u3 = 0;

// Tracked cursor inside the scroll region, in screen coordinates.
var region_row: usize = 3;
var region_col: usize = 2;

// Incremental terminal renderer state. Control sequences and UTF-8 code
// points are held until complete, so resize repaint cannot split either one
// on the physical terminal.
var display_state: enum { text, escape, csi, osc, osc_escape } = .text;
var display_control: [1024]u8 = undefined;
var display_control_len: usize = 0;
var display_utf8: [4]u8 = undefined;
var display_utf8_len: usize = 0;
var display_utf8_expected: usize = 0;
var display_joined = false;
var display_cluster_width: usize = 0;
var display_regional_pending = false;

var popup_rows: usize = 0;

var esc_state: enum { text, escape, csi, osc, osc_escape } = .text;
var csi_buffer: [24]u8 = undefined;
var csi_len: usize = 0;

pub const InputArea = struct { row: usize, col: usize, width: usize };

fn initialSize(measured: ?term.WindowSize) !term.WindowSize {
    const size = measured orelse return error.TerminalSizeUnavailable;
    if (size.rows < min_rows or size.cols < min_cols) return error.TerminalTooSmall;
    return size;
}

/// Switch to the alternate screen, draw the chrome, and return the writer
/// used for session output. Startup requires a real, usable measurement;
/// guessing can address rows that do not exist on a zero-sized PTY.
pub fn enter(gpa: std.mem.Allocator, io: Io, out: *Io.Writer) !*Io.Writer {
    return enterMeasured(gpa, io, out, term.windowSizeRaw(), true);
}

fn enterMeasured(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, measured: ?term.WindowSize, watch_resize: bool) !*Io.Writer {
    gpa_state = gpa;
    io_state = io;
    sink = out;
    const size = try initialSize(measured);
    rows = size.rows;
    cols = size.cols;
    active = true;
    layout_ready = true;
    layout_dirty = false;
    startup_hint_len = 0;
    errdefer rollbackEnter();
    try out.writeAll("\x1b[?1049h\x1b[2J");
    try armRegion(out);
    try drawChrome(out);
    region_row = regionTop();
    region_col = contentLeft();
    try out.print("\x1b[{d};{d}H", .{ region_row, region_col });
    try out.flush();
    tee = .{ .vtable = &.{ .drain = drain }, .buffer = &tee_buffer };
    if (watch_resize) startResizeWatcher(io);
    return &tee;
}

/// Restore the primary screen. Safe to call twice; must run before every
/// process exit, including the error paths that skip defers.
pub fn exit() void {
    if (!active) return;
    stopResizeWatcher();
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    active = false;
    // Also restore paste mode here because process.exit paths skip the
    // editor's defer and call this cleanup directly.
    sink.writeAll("\x1b[?2004l\x1b[r\x1b[?1049l") catch {};
    sink.flush() catch {};
    resetTranscriptLocked();
    activity_len = 0;
    agents_running = 0;
    agents_queued = 0;
    steering_queued = 0;
    follow_ups_queued = 0;
    input_active = false;
    startup_hint_len = 0;
    layout_ready = false;
    layout_dirty = false;
}

fn resetTranscriptLocked() void {
    var i: usize = 0;
    while (i < line_count) : (i += 1) gpa_state.free(lines[(line_start + i) % max_lines]);
    line_start = 0;
    line_count = 0;
    current_len = 0;
    current_truncated = false;
    cp_pending = 0;
    cp_remaining = 0;
    scroll_offset = 0;
    popup_rows = 0;
    pending_cr = false;
    live_repaint_pending = false;
    esc_state = .text;
    csi_len = 0;
    display_state = .text;
    display_control_len = 0;
    display_utf8_len = 0;
    display_utf8_expected = 0;
    display_joined = false;
    display_cluster_width = 0;
    display_regional_pending = false;
}

/// Drop the conversation while keeping the fullscreen chrome and status.
/// Resume calls this before replaying another thread.
pub fn clearTranscript() void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    resetTranscriptLocked();
    startup_hint_len = 0;
    if (layout_ready) repaint() catch {};
}

fn rollbackEnter() void {
    active = false;
    layout_ready = false;
    sink.writeAll("\x1b[?2004l\x1b[r\x1b[?1049l") catch {};
    sink.flush() catch {};
}

fn handleWinch(_: std.posix.SIG) callconv(.c) void {
    // Io.Event.set is the same async-signal-safe wakeup used by std.Progress.
    // Rendering stays on the watcher task and is serialized with foreground
    // transcript writes.
    resize_event.set(io_state);
}

fn startResizeWatcher(io: Io) void {
    resize_event.reset();
    resize_future = io.concurrent(resizeLoop, .{io}) catch null;
    if (resize_future == null) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleWinch },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &action, &old_winch);
    winch_installed = true;
}

fn stopResizeWatcher() void {
    if (winch_installed) {
        std.posix.sigaction(.WINCH, &old_winch, null);
        winch_installed = false;
    }
    var future = resize_future orelse return;
    resize_future = null;
    future.cancel(io_state);
    resize_event.reset();
}

fn resizeLoop(io: Io) void {
    while (true) {
        resize_event.wait(io) catch return;
        resize_event.reset();
        render_mutex.lock(io) catch return;
        if (!active) {
            render_mutex.unlock(io);
            return;
        }
        if (!input_active) _ = resizeIfNeededLocked();
        render_mutex.unlock(io);
    }
}

/// Mark editor and picker phases. The resize worker leaves their cursor
/// alone; foreground input polling redraws with the real line contents.
pub fn beginInput() void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    _ = resizeIfNeededLocked();
    input_active = true;
    if (layout_ready) {
        const area = inputArea();
        input_cursor_row = area.row;
        input_cursor_col = area.col;
    }
}

pub fn endInput() void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    input_active = false;
    _ = resizeIfNeededLocked();
}

/// Re-measure and repaint. True means the foreground editor should redraw
/// its line after the chrome changed.
pub fn checkResize() bool {
    if (!active) return false;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    return resizeIfNeededLocked();
}

pub fn drawable() bool {
    return active and layout_ready;
}

/// Serialize a complete editor repaint with transcript and resize rendering.
/// The returned value says whether terminal coordinates are currently usable.
pub fn beginInputFrame() bool {
    std.debug.assert(active);
    render_mutex.lockUncancelable(io_state);
    _ = resizeIfNeededLocked();
    return layout_ready;
}

pub fn endInputFrame(row: usize, col: usize) void {
    if (layout_ready) {
        input_cursor_row = row;
        input_cursor_col = col;
    }
    render_mutex.unlock(io_state);
}

/// Editor text area inside the input box: `│ > text │`.
pub fn inputArea() InputArea {
    std.debug.assert(layout_ready);
    return .{
        .row = inputContentRow(),
        .col = contentLeft() + 4,
        .width = contentWidth() -| 6,
    };
}

/// Direct chrome writer for the editor's fixed-row drawing.
pub fn chromeSink() *Io.Writer {
    return sink;
}

pub fn setPasteMode(enabled: bool) !void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    try sink.writeAll(if (enabled) "\x1b[?2004h" else "\x1b[?2004l");
    try sink.flush();
}

/// Show a short-lived message where the editor text normally appears.
/// The foreground editor owns expiry and dismissal once input begins.
pub fn showStartupHint(text: []const u8) void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    if (!layout_ready) return;
    startup_hint_len = copyInto(&startup_hint_buffer, text);
    startup_hint_deadline_ns = Io.Clock.now(.awake, io_state).nanoseconds + startup_hint_duration_ns;
    const area = inputArea();
    sink.print("\x1b7\x1b[{d};{d}H{s}", .{ area.row, area.col, term.dim() }) catch return;
    writeClipped(sink, startup_hint_buffer[0..startup_hint_len], area.width) catch return;
    var used = @min(visibleColumns(startup_hint_buffer[0..startup_hint_len]), area.width);
    while (used < area.width) : (used += 1) sink.writeByte(' ') catch return;
    sink.print("{s}\x1b8", .{term.reset()}) catch return;
    sink.flush() catch {};
}

/// Return the startup message while its display window is open.
pub fn startupHint() ?[]const u8 {
    if (expireStartupHint()) return null;
    return if (startup_hint_len > 0) startup_hint_buffer[0..startup_hint_len] else null;
}

/// Clear an expired message. True tells the editor to repaint its row.
pub fn expireStartupHint() bool {
    if (startup_hint_len == 0) return false;
    if (Io.Clock.now(.awake, io_state).nanoseconds < startup_hint_deadline_ns) return false;
    startup_hint_len = 0;
    return true;
}

/// Clear the message on the first keypress. The editor repaints afterward.
pub fn dismissStartupHint() bool {
    const visible = startup_hint_len > 0;
    startup_hint_len = 0;
    return visible;
}

/// Reposition the physical cursor to the transcript insertion point;
/// the editor calls this before echoing a submitted prompt.
pub fn focusRegion() void {
    if (!active or !layout_ready) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    sink.print("\x1b[{d};{d}H", .{ region_row, region_col }) catch {};
    sink.flush() catch {};
}

pub const GitIdentity = struct {
    worktree: []const u8,
    branch: []const u8,
    dirty: bool,
};

pub fn noteIdentity(provider: []const u8, model: []const u8, effort: ?[]const u8, fast: bool, thread: ?[]const u8, git: ?GitIdentity) void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    provider_len = copyInto(&provider_buffer, provider);
    model_len = copyInto(&model_buffer, model);
    effort_len = if (effort) |value| copyInto(&effort_buffer, value) else 0;
    fast_enabled = fast;
    thread_len = if (thread) |id| copyInto(&thread_buffer, id) else 0;
    if (git) |value| {
        git_present = true;
        worktree_len = copyInto(&worktree_buffer, value.worktree);
        branch_len = copyInto(&branch_buffer, value.branch);
        git_dirty = value.dirty;
    } else {
        git_present = false;
        worktree_len = 0;
        branch_len = 0;
        git_dirty = false;
    }
    renderTopLocked();
}

pub fn noteState(next: State, detail: []const u8) void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    state = next;
    detail_len = copyInto(&detail_buffer, detail);
    renderInfoLocked();
}

pub fn noteUsage(input_tokens: u64, output_tokens: u64, percent: u8) void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    tokens_in = input_tokens;
    tokens_out = output_tokens;
    context_percent = @min(percent, 100);
    renderInfoLocked();
}

pub fn noteAgents(running: usize, queued: usize) void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    agents_running = @intCast(@min(running, std.math.maxInt(u8)));
    agents_queued = @intCast(@min(queued, std.math.maxInt(u8)));
    renderInfoLocked();
}

pub fn noteQueue(steering: usize, follow_ups: usize) void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    steering_queued = @intCast(@min(steering, std.math.maxInt(u8)));
    follow_ups_queued = @intCast(@min(follow_ups, std.math.maxInt(u8)));
    renderInfoLocked();
}

/// Static activity label from the spinner facade (`thinking`,
/// `compacting`, `retrying`, ...); null clears it.
pub fn setActivity(label: ?[]const u8) void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    activity_len = if (label) |text| copyInto(&activity_buffer, text) else 0;
    renderInfoLocked();
}

/// One spinner frame at the live insertion row of the transcript: a
/// carriage return rewinds the previous frame, then the dim glyph and
/// label, clipped to one content row so the rewind never spans a wrap.
/// Skipped while scrolled back — the live row is off-screen there, and
/// every forwarded write would trigger a full repaint.
pub fn spinnerFrame(glyph: []const u8, label: []const u8) void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    _ = resizeIfNeededLocked();
    if (!layout_ready or scroll_offset != 0) return;
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    writer.writeByte('\r') catch return;
    writer.writeAll(term.dim()) catch return;
    writer.writeAll(glyph) catch return;
    writer.writeByte(' ') catch return;
    writeClipped(&writer, label, contentWidth() -| 2) catch return;
    writer.writeAll(term.reset()) catch return;
    writeLiveLocked(writer.buffered());
}

/// Erase the spinner from the live row and the in-progress ring line.
/// Unlike frames this runs even while scrolled back, so both planes are
/// consistent when the next output lands.
pub fn spinnerClear() void {
    if (!active) return;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    _ = resizeIfNeededLocked();
    if (!layout_ready) return;
    writeLiveLocked("\r\x1b[K");
}

/// Draw a completion popup overlaying the bottom of the transcript,
/// `count` rows tall. Rows are then filled with `popupLine`. When the
/// popup shrinks or closes, the transcript is repainted from the ring.
pub fn beginPopup(count: usize) usize {
    if (!active or !layout_ready) return 0;
    const capacity = regionHeight() -| 1;
    const clamped = @min(count, @min(capacity, 9));
    if (clamped != popup_rows) {
        popup_rows = clamped;
        repaint() catch {};
    }
    return clamped;
}

pub fn popupLine(index: usize, text: []const u8) void {
    if (!active or !layout_ready or index >= popup_rows) return;
    const row = regionBottom() - popup_rows + 1 + index;
    sink.print("\x1b[{d};{d}H", .{ row, contentLeft() }) catch return;
    writeClipped(sink, text, contentWidth()) catch return;
    sink.writeAll("\x1b[K") catch return;
}

pub fn closePopup() void {
    if (!active or popup_rows == 0) return;
    popup_rows = 0;
    if (layout_ready) repaint() catch {};
}

/// Page the transcript. The input box is untouched; the region is
/// repainted from the ring (unstyled history is by design).
pub fn pageUp() bool {
    return page(true);
}

pub fn pageDown() bool {
    return page(false);
}

fn page(up: bool) bool {
    if (!active) return false;
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    if (!layout_ready) return false;
    const visible = viewportHeight();
    const step = @max(visible -| 1, 1);
    const max_offset = visualRowCount() -| visible;
    const previous = scroll_offset;
    scroll_offset = if (up) @min(scroll_offset + step, max_offset) else scroll_offset -| step;
    if (scroll_offset == previous) return false;
    repaint() catch {};
    return true;
}

fn contentLeft() usize {
    return edge_margin + 1;
}

fn contentWidth() usize {
    return cols -| (edge_margin * 2);
}

fn topBarRow() usize {
    return edge_margin + 1;
}

fn regionTop() usize {
    return topBarRow() + 1;
}

fn inputTopRow() usize {
    return inputContentRow() - 1;
}

fn inputContentRow() usize {
    return inputBottomRow() - 1;
}

fn inputBottomRow() usize {
    return infoBarRow() - status_gap - 1;
}

fn infoBarRow() usize {
    return rows - edge_margin;
}

fn regionBottom() usize {
    return inputTopRow() - 1;
}

fn regionHeight() usize {
    return regionBottom() - regionTop() + 1;
}

fn armRegion(out: *Io.Writer) !void {
    try out.print("\x1b[{d};{d}r", .{ regionTop(), regionBottom() });
}

fn drawChrome(out: *Io.Writer) !void {
    try renderTopTo(out);
    try renderBoxTo(out);
    try renderInfoTo(out);
}

fn viewportHeight() usize {
    return regionHeight() -| popup_rows;
}

const LineLayout = struct { rows: usize, column: usize };

/// Layout a logical transcript line into visual rows using the same content
/// boundary as the live renderer. A line always owns at least one row.
fn lineLayout(text: []const u8) LineLayout {
    const width = contentWidth();
    var result: LineLayout = .{ .rows = 1, .column = 0 };
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i = sgrEnd(text, i) orelse break;
            continue;
        }
        const cell = term.nextCell(text, i);
        const glyph_width = cell.width;
        if (glyph_width > 0 and result.column + glyph_width > width) {
            result.rows += 1;
            result.column = 0;
        }
        result.column += @min(glyph_width, width);
        i = cell.end;
    }
    return result;
}

fn visualRowCount() usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        count += lineLayout(lines[(line_start + i) % max_lines]).rows;
    }
    // The live insertion line remains part of the viewport when empty. This
    // prevents the next streamed byte from overwriting the last committed row.
    count += lineLayout(current[0..current_len]).rows;
    return count;
}

fn clampViewState() void {
    if (!layout_ready) {
        popup_rows = 0;
        scroll_offset = 0;
        return;
    }
    popup_rows = @min(popup_rows, regionHeight() -| 1);
    const visible = viewportHeight();
    scroll_offset = @min(scroll_offset, visualRowCount() -| visible);
}

/// Render one logical line into the requested visual-row window. Stored
/// history contains only SGR escapes, so forwarding them while skipped keeps
/// style state correct when the viewport begins in the middle of a wrap.
fn renderLogicalLine(out: *Io.Writer, text: []const u8, truncated: bool, base_row: usize, first_row: usize, end_row: usize) !usize {
    const width = contentWidth();
    const layout = lineLayout(text);
    var row_offset: usize = 0;
    var column: usize = 0;
    var positioned = false;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = sgrEnd(text, i) orelse break;
            try out.writeAll(text[i..end]);
            i = end;
            continue;
        }
        const cell = term.nextCell(text, i);
        const token_end = cell.end;
        const glyph_width = cell.width;
        if (glyph_width > 0 and column + glyph_width > width) {
            row_offset += 1;
            column = 0;
            positioned = false;
        }
        const virtual_row = base_row + row_offset;
        if (virtual_row >= first_row and virtual_row < end_row) {
            if (!positioned) {
                const screen_row = regionTop() + virtual_row - first_row;
                try out.print("\x1b[{d};{d}H", .{ screen_row, contentLeft() + column });
                positioned = true;
            }
            try out.writeAll(text[i..token_end]);
        }
        column += @min(glyph_width, width);
        i = token_end;
    }
    if (truncated) {
        const virtual_row = base_row + layout.rows - 1;
        if (virtual_row >= first_row and virtual_row < end_row) {
            const marker_column = if (layout.column < width) layout.column else width -| 1;
            const screen_row = regionTop() + virtual_row - first_row;
            try out.print("\x1b[{d};{d}H{s}…{s}", .{ screen_row, contentLeft() + marker_column, term.dim(), term.reset() });
        }
    }
    try out.writeAll("\x1b[0m");
    return base_row + layout.rows;
}

/// Reflow the retained logical transcript into the current visual viewport,
/// leaving room for an overlay and preserving a blank live insertion row.
fn repaint() !void {
    if (!layout_ready) return;
    clampViewState();
    const capacity = viewportHeight();
    const total = visualRowCount();
    const end = total - scroll_offset;
    const begin = end -| capacity;
    // Absolute positioning ignores the scroll region, so rows are
    // cleared one by one: [J would erase the input box and info bar.
    var row = regionTop();
    while (row <= regionBottom()) : (row += 1) {
        try sink.print("\x1b[{d};1H\x1b[2K", .{row});
    }
    var virtual_row: usize = 0;
    var index: usize = 0;
    while (index < line_count) : (index += 1) {
        const slot = (line_start + index) % max_lines;
        virtual_row = try renderLogicalLine(sink, lines[slot], lines_truncated[slot], virtual_row, begin, end);
    }
    _ = try renderLogicalLine(sink, current[0..current_len], current_truncated, virtual_row, begin, end);
    if (scroll_offset == 0) {
        const current_layout = lineLayout(current[0..current_len]);
        region_row = regionTop() + @min(total - 1 - begin, capacity - 1);
        region_col = contentLeft() + current_layout.column;
    } else {
        region_row = regionTop();
        region_col = contentLeft();
    }
    try sink.print("\x1b[{d};{d}H", .{ region_row, region_col });
    try sink.flush();
}

fn copyInto(buffer: []u8, text: []const u8) usize {
    var count = @min(text.len, buffer.len);
    while (count > 0 and !std.unicode.utf8ValidateSlice(text[0..count])) count -= 1;
    @memcpy(buffer[0..count], text[0..count]);
    return count;
}

fn drawSuspended() !void {
    try sink.writeAll("\x1b[r\x1b[2J\x1b[H");
    try writeClipped(sink, "xaq: terminal too small (40x10 minimum)", cols);
    try sink.flush();
}

fn resizeMeasured(size: ?term.WindowSize) bool {
    var changed = false;
    if (size) |measured| {
        if (rows != measured.rows or cols != measured.cols) {
            rows = measured.rows;
            cols = measured.cols;
            layout_dirty = true;
            changed = true;
        }
    }
    if (!layout_dirty) return false;

    layout_ready = rows >= min_rows and cols >= min_cols;
    clampViewState();
    if (!layout_ready) {
        drawSuspended() catch return changed;
    } else {
        // Clearing first removes stale cells exposed by a grow and stale
        // chrome from the old coordinates after a shrink.
        sink.writeAll("\x1b[r\x1b[2J") catch return changed;
        armRegion(sink) catch return changed;
        drawChrome(sink) catch return changed;
        repaint() catch return changed;
    }
    layout_dirty = false;
    return true;
}

fn resizeIfNeededLocked() bool {
    return resizeMeasured(term.windowSizeRaw());
}

fn renderTopLocked() void {
    _ = resizeIfNeededLocked();
    if (!layout_ready) return;
    renderTopTo(sink) catch {};
    sink.flush() catch {};
}

fn renderInfoLocked() void {
    _ = resizeIfNeededLocked();
    if (!layout_ready) return;
    renderInfoTo(sink) catch {};
    sink.flush() catch {};
}

fn renderTopTo(out: *Io.Writer) !void {
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeTopBar(&writer, contentWidth());
    try clearRow(out, 1);
    try renderBar(out, topBarRow(), writer.buffered());
}

fn writeTopBar(writer: *Io.Writer, width: usize) !void {
    var full_left_buffer: [256]u8 = undefined;
    var full_left: Io.Writer = .fixed(&full_left_buffer);
    try writeTopLeft(&full_left, true);
    var compact_left_buffer: [192]u8 = undefined;
    var compact_left: Io.Writer = .fixed(&compact_left_buffer);
    try writeTopLeft(&compact_left, false);

    var full_right_buffer: [320]u8 = undefined;
    var full_right: Io.Writer = .fixed(&full_right_buffer);
    try writeTopRight(&full_right, .full);
    var compact_right_buffer: [256]u8 = undefined;
    var compact_right: Io.Writer = .fixed(&compact_right_buffer);
    try writeTopRight(&compact_right, .compact);
    var minimal_right_buffer: [160]u8 = undefined;
    var minimal_right: Io.Writer = .fixed(&minimal_right_buffer);
    try writeTopRight(&minimal_right, .minimal);

    const full_l = full_left.buffered();
    const compact_l = compact_left.buffered();
    const full_r = full_right.buffered();
    const compact_r = compact_right.buffered();
    const minimal_r = minimal_right.buffered();
    if (topPairFits(full_l, full_r, width)) return writeTopPair(writer, full_l, full_r, width);
    if (topPairFits(compact_l, full_r, width)) return writeTopPair(writer, compact_l, full_r, width);
    if (topPairFits(compact_l, compact_r, width)) return writeTopPair(writer, compact_l, compact_r, width);
    return writeTopPair(writer, compact_l, minimal_r, width);
}

fn writeTopLeft(writer: *Io.Writer, full: bool) !void {
    if (full) {
        try writer.writeAll(" xaq");
        if (provider_len > 0 or model_len > 0) {
            try writer.writeAll(" \u{b7} ");
            if (provider_len > 0) try writer.print("{s}/", .{provider_buffer[0..provider_len]});
            try writer.writeAll(model_buffer[0..model_len]);
        }
    } else if (model_len > 0) {
        try writer.print(" {s}", .{model_buffer[0..model_len]});
    } else {
        try writer.writeAll(" xaq");
    }
    if (effort_len > 0) try writer.print(" \u{b7} {s}", .{effort_buffer[0..effort_len]});
    if (fast_enabled) try writer.writeAll(" \u{b7} fast");
}

const TopRightDetail = enum { full, compact, minimal };

fn writeTopRight(writer: *Io.Writer, detail: TopRightDetail) !void {
    var wrote = false;
    if (git_present) {
        if (detail == .full and worktree_len > 0) {
            try writer.writeAll(worktree_buffer[0..worktree_len]);
            wrote = true;
        }
        if (detail != .minimal and branch_len > 0) {
            if (wrote) try writer.writeAll(" \u{b7} ");
            try writer.writeAll(branch_buffer[0..branch_len]);
            wrote = true;
        } else if (detail == .minimal and branch_len > 0) {
            try writer.writeAll(branch_buffer[0..branch_len]);
            wrote = true;
        } else if (!wrote and worktree_len > 0) {
            try writer.writeAll(worktree_buffer[0..worktree_len]);
            wrote = true;
        }
        if (git_dirty and wrote) try writer.writeByte('*');
    }
    if (thread_len > 0 and detail != .minimal) {
        if (wrote) try writer.writeAll(" \u{b7} ");
        try writer.print("#{s}", .{thread_buffer[0..@min(thread_len, 8)]});
        wrote = true;
    } else if (thread_len > 0 and !wrote) {
        try writer.print("#{s}", .{thread_buffer[0..@min(thread_len, 8)]});
        wrote = true;
    }
    if (wrote) try writer.writeByte(' ');
}

fn topPairFits(left: []const u8, right: []const u8, width: usize) bool {
    const gap: usize = if (right.len > 0) 2 else 0;
    return visibleColumns(left) + gap + visibleColumns(right) <= width;
}

fn writeTopPair(writer: *Io.Writer, left: []const u8, right: []const u8, width: usize) !void {
    if (right.len == 0) return writeClipped(writer, left, width);
    const left_width = visibleColumns(left);
    const right_width = visibleColumns(right);
    if (left_width + 2 + right_width <= width) {
        try writer.writeAll(left);
        var spaces = width - left_width - right_width;
        while (spaces > 0) : (spaces -= 1) try writer.writeByte(' ');
        return writer.writeAll(right);
    }

    const right_limit = @min(right_width, @max(width / 3, 8));
    const left_limit = width -| (right_limit + 2);
    const shown_left = @min(left_width, left_limit);
    const shown_right = @min(right_width, right_limit);
    try writeClipped(writer, left, shown_left);
    var spaces = width -| (shown_left + shown_right);
    while (spaces > 0) : (spaces -= 1) try writer.writeByte(' ');
    try writeClipped(writer, right, shown_right);
}

fn renderInfoTo(out: *Io.Writer) !void {
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    writer.print(" ctx {d}% \u{b7} \u{2191}", .{context_percent}) catch {};
    writeCount(&writer, tokens_in) catch {};
    writer.writeAll(" \u{2193}") catch {};
    writeCount(&writer, tokens_out) catch {};
    if (agents_running > 0) {
        writer.print(" \u{b7} agents {d}", .{agents_running}) catch {};
        if (agents_queued > 0) writer.print(" + {d} queued", .{agents_queued}) catch {};
    } else if (agents_queued > 0) {
        writer.print(" \u{b7} {d} agents queued", .{agents_queued}) catch {};
    }
    if (steering_queued > 0) writer.print(" \u{b7} steer {d}", .{steering_queued}) catch {};
    if (follow_ups_queued > 0) writer.print(" \u{b7} next {d}", .{follow_ups_queued}) catch {};
    if (activity_len > 0) {
        writer.print(" \u{b7} {s}\u{2026}", .{activity_buffer[0..activity_len]}) catch {};
    } else switch (state) {
        .idle => writer.writeAll(" \u{b7} ready") catch {},
        .thinking => writer.writeAll(" \u{b7} thinking\u{2026}") catch {},
        .tooling => if (detail_len > 0)
            writer.print(" \u{b7} {s}\u{2026}", .{detail_buffer[0..detail_len]}) catch {}
        else
            writer.writeAll(" \u{b7} working\u{2026}") catch {},
    }
    if (state == .idle) {
        writer.writeAll(" \u{b7} pgup/pgdn history \u{b7} ctrl-d exits") catch {};
    } else {
        writer.writeAll(" \u{b7} enter steers \u{b7} alt-enter next \u{b7} ctrl-c stops") catch {};
    }
    try clearRow(out, infoBarRow() - 1);
    try renderBar(out, infoBarRow(), writer.buffered());
    try clearRow(out, rows);
}

fn renderBar(out: *Io.Writer, row: usize, text: []const u8) !void {
    try out.print("\x1b7\x1b[{d};1H\x1b[2K\x1b[{d};{d}H{s}", .{ row, row, contentLeft(), term.dim() });
    try writeClipped(out, text, contentWidth());
    try out.print("\x1b[K{s}\x1b8", .{term.reset()});
}

fn renderBoxTo(out: *Io.Writer) !void {
    const width = contentWidth();
    var column: usize = 0;
    try out.writeAll("\x1b7");
    try out.print("\x1b[{d};1H\x1b[2K\x1b[{d};{d}H{s}\u{250c}", .{ inputTopRow(), inputTopRow(), contentLeft(), term.dim() });
    column = 2;
    while (column < width) : (column += 1) try out.writeAll("\u{2500}");
    try out.print("\u{2510}\x1b[{d};1H\x1b[2K\x1b[{d};{d}H\u{2502}{s} {s}>{s} ", .{ inputContentRow(), inputContentRow(), contentLeft(), term.reset(), term.bold(), term.reset() });
    column = 5;
    while (column < width) : (column += 1) try out.writeByte(' ');
    try out.print("{s}\u{2502}\x1b[{d};1H\x1b[2K\x1b[{d};{d}H\u{2514}", .{ term.dim(), inputBottomRow(), inputBottomRow(), contentLeft() });
    column = 2;
    while (column < width) : (column += 1) try out.writeAll("\u{2500}");
    try out.print("\u{2518}{s}\x1b8", .{term.reset()});
}

fn clearRow(out: *Io.Writer, row: usize) !void {
    try out.print("\x1b7\x1b[{d};1H\x1b[2K\x1b8", .{row});
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

/// Write `text`, passing SGR sequences through unchanged, until
/// `max_cols` visible columns have been printed. Wide characters that
/// would straddle the limit are dropped whole. Ends with a reset when
/// any styling was forwarded.
fn writeClipped(out: *Io.Writer, text: []const u8, max_cols: usize) !void {
    var shown: usize = 0;
    var styled = false;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte == 0x1b) {
            const end = sgrEnd(text, i) orelse break;
            try out.writeAll(text[i..end]);
            styled = true;
            i = end;
            continue;
        }
        const cell = term.nextCell(text, i);
        if (shown + cell.width > max_cols) break;
        try out.writeAll(text[i..cell.end]);
        shown += cell.width;
        i = cell.end;
    }
    if (styled) try out.writeAll("\x1b[0m");
}

fn sgrEnd(text: []const u8, start: usize) ?usize {
    var i = start + 1;
    if (i >= text.len or text[i] != '[') return null;
    i += 1;
    while (i < text.len) : (i += 1) {
        if (text[i] >= 0x40 and text[i] <= 0x7e) return i + 1;
    }
    return null;
}

fn visibleColumns(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i = sgrEnd(text, i) orelse break;
            continue;
        }
        const cell = term.nextCell(text, i);
        count += cell.width;
        i = cell.end;
    }
    return count;
}

/// Position at the tracked region cursor. Explicit wrapping keeps this
/// coordinate valid even when the prior flush ended exactly at the
/// content boundary.
fn seekLiveRow() !void {
    if (layout_ready) try sink.print("\x1b[{d};{d}H", .{ region_row, region_col });
}

fn restoreEditorCursor() !void {
    if (input_active and layout_ready) {
        try sink.print("\x1b[{d};{d}H", .{ input_cursor_row, input_cursor_col });
        try sink.flush();
    }
}

/// Forward spinner-facade bytes to the live row with the same positioning
/// and editor-cursor discipline as `drain`. Caller holds `render_mutex`.
fn writeLiveLocked(bytes: []const u8) void {
    seekLiveRow() catch return;
    forward(bytes) catch return;
    sink.flush() catch return;
    restoreEditorCursor() catch return;
}

fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    render_mutex.lockUncancelable(io_state);
    defer render_mutex.unlock(io_state);
    _ = resizeIfNeededLocked();
    seekLiveRow() catch return error.WriteFailed;
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
    restoreEditorCursor() catch return error.WriteFailed;
    return consumed;
}

fn forward(bytes: []const u8) !void {
    const was_scrolled = scroll_offset != 0;
    if (layout_ready and !was_scrolled) try writeRegionBytes(bytes);
    ingest(bytes);
    if (layout_ready and (was_scrolled or live_repaint_pending)) {
        live_repaint_pending = false;
        try repaint();
    }
}

fn advanceDisplayRow() !void {
    try sink.writeByte('\n');
    try sink.print("\x1b[{d}G", .{contentLeft()});
    region_row = @min(region_row + 1, regionBottom());
    region_col = contentLeft();
}

fn writeDisplayGlyph(glyph: []const u8, width: usize) !void {
    if (width > 0 and region_col - contentLeft() + width > contentWidth()) {
        try advanceDisplayRow();
    }
    try sink.writeAll(glyph);
    region_col += @min(width, contentWidth());
}

fn appendDisplayControl(byte: u8) void {
    if (display_control_len < display_control.len) {
        display_control[display_control_len] = byte;
        display_control_len += 1;
    }
}

fn finishDisplayControl() !void {
    try sink.writeAll(display_control[0..display_control_len]);
    display_control_len = 0;
    display_state = .text;
}

fn flushInvalidDisplayUtf8() !void {
    for (display_utf8[0..display_utf8_len]) |byte| {
        try writeDisplayGlyph(&.{byte}, 1);
        display_cluster_width = 1;
        display_joined = false;
        display_regional_pending = false;
    }
    display_utf8_len = 0;
    display_utf8_expected = 0;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1f1e6 and cp <= 0x1f1ff;
}

fn displayCellWidth(cp: u21) usize {
    const raw_width: usize = term.codePointWidth(cp);
    if (cp == 0x200d) {
        display_joined = true;
        display_regional_pending = false;
        return 0;
    }
    if (cp == 0xfe0f) {
        const extra = 2 -| display_cluster_width;
        display_cluster_width = @max(display_cluster_width, 2);
        return extra;
    }
    if (raw_width == 0) return 0;
    if (display_joined) {
        display_joined = false;
        const extra = raw_width -| display_cluster_width;
        display_cluster_width = @max(display_cluster_width, raw_width);
        return extra;
    }
    if (isRegionalIndicator(cp)) {
        if (display_regional_pending) {
            display_regional_pending = false;
            return 0;
        }
        display_regional_pending = true;
    } else {
        display_regional_pending = false;
    }
    display_cluster_width = raw_width;
    return raw_width;
}

fn writeDisplayTextByte(byte: u8) !void {
    if (display_utf8_expected > 0) {
        if (byte & 0xc0 != 0x80) {
            try flushInvalidDisplayUtf8();
            return writeDisplayTextByte(byte);
        }
        display_utf8[display_utf8_len] = byte;
        display_utf8_len += 1;
        if (display_utf8_len == display_utf8_expected) {
            const glyph = display_utf8[0..display_utf8_len];
            const width: usize = if (std.unicode.utf8Decode(glyph)) |cp| displayCellWidth(cp) else |_| 1;
            try writeDisplayGlyph(glyph, width);
            display_utf8_len = 0;
            display_utf8_expected = 0;
        }
        return;
    }
    if (byte & 0x80 == 0) return writeDisplayGlyph(&.{byte}, displayCellWidth(byte));
    display_utf8_expected = std.unicode.utf8ByteSequenceLength(byte) catch {
        return writeDisplayGlyph(&.{byte}, 1);
    };
    display_utf8[0] = byte;
    display_utf8_len = 1;
}

fn processDisplayByte(byte: u8) !void {
    switch (display_state) {
        .text => switch (byte) {
            0x1b => {
                try flushInvalidDisplayUtf8();
                display_control_len = 0;
                appendDisplayControl(byte);
                display_state = .escape;
            },
            '\n' => {
                try flushInvalidDisplayUtf8();
                try advanceDisplayRow();
                display_joined = false;
                display_cluster_width = 0;
                display_regional_pending = false;
            },
            '\r' => {
                try flushInvalidDisplayUtf8();
                try sink.writeByte('\r');
                try sink.print("\x1b[{d}G", .{contentLeft()});
                region_col = contentLeft();
                display_joined = false;
                display_cluster_width = 0;
                display_regional_pending = false;
            },
            '\t' => {
                try flushInvalidDisplayUtf8();
                const next_stop = ((region_col - 1) / 8 + 1) * 8 + 1;
                var spaces = @max(next_stop -| region_col, 1);
                while (spaces > 0) : (spaces -= 1) try writeDisplayGlyph(" ", 1);
                display_joined = false;
                display_cluster_width = 1;
                display_regional_pending = false;
            },
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
            else => try writeDisplayTextByte(byte),
        },
        .escape => {
            appendDisplayControl(byte);
            if (byte == '[') {
                display_state = .csi;
            } else if (byte == ']') {
                display_state = .osc;
            } else {
                try finishDisplayControl();
            }
        },
        .csi => {
            appendDisplayControl(byte);
            if (byte >= 0x40 and byte <= 0x7e) try finishDisplayControl();
        },
        .osc => {
            appendDisplayControl(byte);
            if (byte == 0x07) {
                try finishDisplayControl();
            } else if (byte == 0x1b) {
                display_state = .osc_escape;
            }
        },
        .osc_escape => {
            appendDisplayControl(byte);
            if (byte == '\\') {
                try finishDisplayControl();
            } else if (byte != 0x1b) {
                display_state = .osc;
            }
        },
    }
}

/// Stream through the same explicit content-width wrapping used by repaint.
/// This preserves both outer margins and pre-wraps wide glyphs.
fn writeRegionBytes(bytes: []const u8) !void {
    for (bytes) |byte| try processDisplayByte(byte);
}

/// Reassemble the displayed transcript and track the region cursor:
/// carriage return rewinds, newline commits, SGR is kept, every other
/// escape sequence is dropped.
fn ingest(bytes: []const u8) void {
    for (bytes) |byte| switch (esc_state) {
        .text => switch (byte) {
            0x1b => {
                // CR before styled overwrites (spinner-style redraws)
                // must land before the SGR is captured.
                applyPendingCr();
                esc_state = .escape;
                csi_len = 0;
            },
            '\r' => {
                // Deferred: a CR immediately followed by LF is a plain
                // line ending, and wiping eagerly would commit an empty
                // ring line for every CRLF in the stream.
                pending_cr = true;
            },
            '\n' => {
                pending_cr = false;
                commit();
            },
            '\t' => {
                applyPendingCr();
                // Terminals jump to the next 8-column stop; pad the ring
                // to match so reflowed history lines up with live output.
                const column = contentLeft() + lineLayout(current[0..current_len]).column;
                const target = ((column - 1) / 8 + 1) * 8 + 1;
                var spaces = @max(target -| column, 1);
                while (spaces > 0) : (spaces -= 1) appendByte(' ');
            },
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
            else => {
                applyPendingCr();
                appendByte(byte);
            },
        },
        .escape => esc_state = switch (byte) {
            '[' => .csi,
            ']' => .osc,
            else => .text,
        },
        .csi => {
            if (csi_len < csi_buffer.len) {
                csi_buffer[csi_len] = byte;
                csi_len += 1;
            }
            if (byte >= 0x40 and byte <= 0x7e) {
                if (byte == 'm' and csi_len <= csi_buffer.len and current_len + csi_len + 2 <= current.len) {
                    // A carriage return before this SGR rewinds the line
                    // first, or the styling would be wiped with the text.
                    applyPendingCr();
                    current[current_len] = 0x1b;
                    current[current_len + 1] = '[';
                    @memcpy(current[current_len + 2 .. current_len + 2 + csi_len], csi_buffer[0..csi_len]);
                    current_len += csi_len + 2;
                }
                esc_state = .text;
            }
        },
        .osc => switch (byte) {
            0x07 => esc_state = .text,
            0x1b => esc_state = .osc_escape,
            else => {},
        },
        .osc_escape => esc_state = if (byte == '\\') .text else .osc,
    };
}

fn applyPendingCr() void {
    if (!pending_cr) return;
    pending_cr = false;
    current_len = 0;
    current_truncated = false;
    cp_remaining = 0;
}

fn appendByte(byte: u8) void {
    if (current_len < current.len) {
        current[current_len] = byte;
        current_len += 1;
    } else {
        current_truncated = true;
    }
    // Complete code-point tracking prevents a later truncation cleanup from
    // mistaking a split multi-byte sequence for valid stored history.
    if (byte & 0x80 == 0) {
        cp_remaining = 0;
    } else if (byte & 0xc0 == 0xc0) {
        if (byte & 0xe0 == 0xc0) {
            cp_pending = byte & 0x1f;
            cp_remaining = 1;
        } else if (byte & 0xf0 == 0xe0) {
            cp_pending = byte & 0x0f;
            cp_remaining = 2;
        } else {
            cp_pending = byte & 0x07;
            cp_remaining = 3;
        }
    } else if (cp_remaining > 0) {
        cp_pending = (cp_pending << 6) | (byte & 0x3f);
        cp_remaining -= 1;
    }
}

fn commit() void {
    if (scroll_offset != 0) {
        // New output snaps the view back to live; the screen still shows
        // the old page, so schedule a repaint once this burst is ingested.
        scroll_offset = 0;
        live_repaint_pending = true;
    }
    var stored_len = current_len;
    while (stored_len > 0 and !std.unicode.utf8ValidateSlice(current[0..stored_len])) stored_len -= 1;
    if (stored_len != current_len) current_truncated = true;
    const copy = gpa_state.dupe(u8, current[0..stored_len]) catch {
        current_len = 0;
        current_truncated = false;
        return;
    };
    current_len = 0;
    if (line_count == max_lines) {
        gpa_state.free(lines[line_start]);
        line_start = (line_start + 1) % max_lines;
        line_count -= 1;
    }
    const slot = (line_start + line_count) % max_lines;
    lines[slot] = copy;
    lines_truncated[slot] = current_truncated;
    current_truncated = false;
    line_count += 1;
}

test "info bar text shows usage, activity, and hints" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    tokens_in = 12_345;
    tokens_out = 678;
    context_percent = 42;
    state = .tooling;
    detail_len = copyInto(&detail_buffer, "Running zig build test");
    activity_len = 0;
    rows = 24;
    cols = 120;
    try renderInfoTo(&output.writer);
    const text = output.written();
    try std.testing.expect(std.mem.find(u8, text, "ctx 42%") != null);
    try std.testing.expect(std.mem.find(u8, text, "12.3k") != null);
    try std.testing.expect(std.mem.find(u8, text, "Running zig build test…") != null);
    try std.testing.expect(std.mem.find(u8, text, "[Running zig build test]") == null);
    state = .idle;
    detail_len = 0;
}

test "top bar aligns git identity and collapses on narrow terminals" {
    provider_len = copyInto(&provider_buffer, "chatgpt");
    model_len = copyInto(&model_buffer, "gpt-5.6-sol");
    effort_len = copyInto(&effort_buffer, "high");
    fast_enabled = true;
    thread_len = copyInto(&thread_buffer, "AbCdEfGh12345678");
    git_present = true;
    worktree_len = copyInto(&worktree_buffer, "xaq");
    branch_len = copyInto(&branch_buffer, "main");
    git_dirty = true;

    var wide_buffer: [256]u8 = undefined;
    var wide: Io.Writer = .fixed(&wide_buffer);
    try writeTopBar(&wide, 100);
    try std.testing.expectEqual(100, visibleColumns(wide.buffered()));
    try std.testing.expect(std.mem.indexOf(u8, wide.buffered(), "xaq \u{b7} chatgpt/gpt-5.6-sol \u{b7} high \u{b7} fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, wide.buffered(), "xaq \u{b7} main* \u{b7} #AbCdEfGh") != null);

    var narrow_buffer: [128]u8 = undefined;
    var narrow: Io.Writer = .fixed(&narrow_buffer);
    try writeTopBar(&narrow, 38);
    try std.testing.expectEqual(38, visibleColumns(narrow.buffered()));
    try std.testing.expect(std.mem.indexOf(u8, narrow.buffered(), "gpt-5.6-sol \u{b7} high \u{b7} fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow.buffered(), "main*") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow.buffered(), "#AbCdEfGh") == null);
}

test "clipping counts visible columns and keeps styling" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeClipped(&out.writer, "\x1b[2mabcdef\x1b[0m", 3);
    try std.testing.expectEqualStrings("\x1b[2mabc\x1b[0m", out.written());
    try std.testing.expectEqual(3, visibleColumns("a\u{e9}b"));
    try std.testing.expectEqual(2, visibleColumns("\x1b[1mab\x1b[0m"));
}

test "ingest reassembles overwritten lines, keeps SGR, drops movement" {
    const gpa = std.testing.allocator;
    gpa_state = gpa;
    rows = 24;
    cols = 80;
    ingest("\x1b[2mhello\r\x1b[1mworld\x1b[0m\nplain\ttext\n");
    try std.testing.expectEqual(2, line_count);
    try std.testing.expectEqualStrings("\x1b[1mworld\x1b[0m", lines[0]);
    try std.testing.expectEqualStrings("plain  text", lines[1]);
    var i: usize = 0;
    while (i < line_count) : (i += 1) gpa.free(lines[(line_start + i) % max_lines]);
    line_count = 0;
    line_start = 0;
    current_len = 0;
}

test "fullscreen layout leaves margins around chrome and status" {
    rows = 24;
    cols = 80;
    layout_ready = true;
    defer layout_ready = false;
    try std.testing.expectEqual(2, topBarRow());
    try std.testing.expectEqual(3, regionTop());
    try std.testing.expectEqual(18, regionBottom());
    try std.testing.expectEqual(19, inputTopRow());
    try std.testing.expectEqual(20, inputContentRow());
    try std.testing.expectEqual(21, inputBottomRow());
    try std.testing.expectEqual(23, infoBarRow());
    try std.testing.expectEqual(InputArea{ .row = 20, .col = 6, .width = 72 }, inputArea());
}

test "startup hint is drawn in the input box and can be dismissed" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    io_state = threaded.io();
    sink = &output.writer;
    rows = 24;
    cols = 80;
    active = true;
    layout_ready = true;
    startup_hint_len = 0;
    defer {
        active = false;
        layout_ready = false;
        startup_hint_len = 0;
    }

    showStartupHint("startup 12.34 ms");

    try std.testing.expectEqualStrings("startup 12.34 ms", startupHint().?);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[20;6H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "startup 12.34 ms") != null);
    try std.testing.expect(dismissStartupHint());
    try std.testing.expect(startupHint() == null);
}

test "spinner frames rewind in place and clear erases the live row" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    io_state = threaded.io();
    sink = &output.writer;
    gpa_state = std.testing.allocator;
    rows = 24;
    cols = 80;
    active = true;
    layout_ready = true;
    defer {
        active = false;
        layout_ready = false;
        current_len = 0;
        pending_cr = false;
        scroll_offset = 0;
        region_row = regionTop();
        region_col = contentLeft();
    }

    spinnerFrame("⠋", "thinking");
    try std.testing.expect(std.mem.indexOf(u8, current[0..current_len], "⠋ thinking") != null);
    spinnerFrame("⠙", "thinking");
    try std.testing.expect(std.mem.indexOf(u8, current[0..current_len], "⠙ thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, current[0..current_len], "⠋") == null);
    // Frames rewind the in-progress line; nothing is ever committed.
    try std.testing.expectEqual(0, line_count);

    // Scrolled back, the live row is off-screen: the frame is skipped.
    const drawn = output.written().len;
    scroll_offset = 1;
    spinnerFrame("⠹", "thinking");
    try std.testing.expectEqual(drawn, output.written().len);
    scroll_offset = 0;

    spinnerClear();
    try std.testing.expectEqual(0, current_len);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "\x1b[K"));
}

test "fullscreen startup requires a measured minimum size" {
    try std.testing.expectError(error.TerminalSizeUnavailable, initialSize(null));
    try std.testing.expectError(error.TerminalTooSmall, initialSize(.{ .rows = 0, .cols = 80 }));
    try std.testing.expectError(error.TerminalTooSmall, initialSize(.{ .rows = 24, .cols = 0 }));
    try std.testing.expectError(error.TerminalTooSmall, initialSize(.{ .rows = 9, .cols = 39 }));
    try std.testing.expectEqual(term.WindowSize{ .rows = 10, .cols = 40 }, try initialSize(.{ .rows = 10, .cols = 40 }));
}

test "enter failure rolls back fullscreen state" {
    var storage: [0]u8 = .{};
    var output: Io.Writer = .fixed(&storage);
    try std.testing.expectError(error.WriteFailed, enterMeasured(std.testing.allocator, undefined, &output, .{ .rows = 24, .cols = 80 }, false));
    try std.testing.expect(!active);
    try std.testing.expect(!layout_ready);
}

test "exit restores terminal modes once" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    io_state = threaded.io();
    sink = &output.writer;
    gpa_state = std.testing.allocator;
    active = true;
    layout_ready = true;
    resize_future = null;
    winch_installed = false;
    line_count = 0;
    current_len = 0;

    exit();
    exit();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "\x1b[?2004l\x1b[r\x1b[?1049l"));
    try std.testing.expect(!active);
}

test "clearing a fullscreen transcript releases history and parser state" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_state = threaded.io();
    gpa_state = std.testing.allocator;
    active = true;
    layout_ready = false;
    line_start = 0;
    line_count = 2;
    lines[0] = try std.testing.allocator.dupe(u8, "old one");
    lines[1] = try std.testing.allocator.dupe(u8, "old two");
    current_len = 3;
    scroll_offset = 1;
    popup_rows = 2;
    esc_state = .csi;
    display_state = .osc;
    defer active = false;

    clearTranscript();

    try std.testing.expectEqual(@as(usize, 0), line_count);
    try std.testing.expectEqual(@as(usize, 0), current_len);
    try std.testing.expectEqual(@as(usize, 0), scroll_offset);
    try std.testing.expectEqual(@as(usize, 0), popup_rows);
    try std.testing.expectEqual(.text, esc_state);
    try std.testing.expectEqual(.text, display_state);
}

test "resize reclamps popup and suspends tiny layouts" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    sink = &output.writer;
    gpa_state = std.testing.allocator;
    active = true;
    layout_ready = true;
    layout_dirty = false;
    rows = 24;
    cols = 80;
    popup_rows = 9;
    scroll_offset = 0;
    line_count = 0;
    line_start = 0;
    current_len = 0;
    defer {
        active = false;
        layout_ready = false;
        layout_dirty = false;
        popup_rows = 0;
    }

    try std.testing.expect(resizeMeasured(.{ .rows = 10, .cols = 40 }));
    try std.testing.expect(layout_ready);
    try std.testing.expectEqual(1, popup_rows);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[3;4r") != null);

    try std.testing.expect(resizeMeasured(.{ .rows = 5, .cols = 20 }));
    try std.testing.expect(!layout_ready);
    try std.testing.expectEqual(0, popup_rows);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "terminal too") != null);

    try std.testing.expect(resizeMeasured(.{ .rows = 10, .cols = 40 }));
    try std.testing.expect(layout_ready);
    try std.testing.expectEqual(@as(usize, 10), rows);
    try std.testing.expectEqual(@as(usize, 40), cols);
}

test "repaint reserves an empty live insertion row" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    sink = &output.writer;
    gpa_state = std.testing.allocator;
    rows = 10;
    cols = 40;
    layout_ready = true;
    popup_rows = 0;
    scroll_offset = 0;
    line_start = 0;
    line_count = 2;
    current_len = 0;
    lines[0] = try std.testing.allocator.dupe(u8, "one");
    lines[1] = try std.testing.allocator.dupe(u8, "two");
    lines_truncated[0] = false;
    lines_truncated[1] = false;
    defer {
        std.testing.allocator.free(lines[0]);
        std.testing.allocator.free(lines[1]);
        line_count = 0;
        line_start = 0;
        layout_ready = false;
    }

    try repaint();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[3;2Htwo") != null);
    try std.testing.expectEqual(@as(usize, 4), region_row);
    try std.testing.expectEqual(@as(usize, 2), region_col);
}

test "growing a paged viewport clamps visual scroll offset" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    sink = &output.writer;
    gpa_state = std.testing.allocator;
    rows = 10;
    cols = 40;
    layout_ready = true;
    layout_dirty = false;
    popup_rows = 0;
    line_start = 0;
    line_count = 20;
    current_len = 0;
    for (0..line_count) |i| {
        lines[i] = try std.fmt.allocPrint(std.testing.allocator, "line {d}", .{i});
        lines_truncated[i] = false;
    }
    scroll_offset = visualRowCount() - viewportHeight();
    defer {
        for (lines[0..line_count]) |line| std.testing.allocator.free(line);
        line_count = 0;
        line_start = 0;
        scroll_offset = 0;
        layout_ready = false;
        layout_dirty = false;
    }

    try std.testing.expect(resizeMeasured(.{ .rows = 24, .cols = 80 }));
    try std.testing.expectEqual(visualRowCount() -| viewportHeight(), scroll_offset);
    try std.testing.expectEqual(@as(usize, 5), scroll_offset);
}

test "paging is serialized with transcript rollover" {
    const Race = struct {
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn write(self: *@This(), transcript: *Io.Writer) void {
            for (0..max_lines + 64) |index| {
                transcript.print("line {d}\n", .{index}) catch {
                    self.failed.store(true, .release);
                    break;
                };
                transcript.flush() catch {
                    self.failed.store(true, .release);
                    break;
                };
            }
            self.done.store(true, .release);
        }

        fn page(self: *@This()) void {
            for (0..512) |_| {
                _ = pageUp();
                _ = pageDown();
                if (self.done.load(.acquire)) break;
            }
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const transcript = try enterMeasured(std.testing.allocator, threaded.io(), &output.writer, .{ .rows = 12, .cols = 40 }, false);
    defer exit();
    var race: Race = .{};
    var writer_future = try threaded.io().concurrent(Race.write, .{ &race, transcript });
    var pager_future = try threaded.io().concurrent(Race.page, .{&race});
    writer_future.await(threaded.io());
    pager_future.await(threaded.io());

    try std.testing.expect(!race.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, max_lines), line_count);
}

test "live renderer wraps at content margins across flushes" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    sink = &output.writer;
    rows = 24;
    cols = 40;
    layout_ready = true;
    region_row = regionTop();
    region_col = 39;
    display_state = .text;
    display_control_len = 0;
    display_utf8_len = 0;
    display_utf8_expected = 0;
    defer layout_ready = false;

    try writeRegionBytes("a");
    try std.testing.expectEqual(@as(usize, 40), region_col);
    try writeRegionBytes("中");
    try std.testing.expectEqual(@as(usize, 4), region_col);
    try std.testing.expectEqual(@as(usize, 4), region_row);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\n\x1b[2G") != null);
}

test "visual row layout reflows narrow and wide glyphs" {
    rows = 24;
    cols = 40;
    layout_ready = true;
    defer layout_ready = false;
    try std.testing.expectEqual(LineLayout{ .rows = 2, .column = 2 }, lineLayout("a" ** 40));
    try std.testing.expectEqual(LineLayout{ .rows = 2, .column = 2 }, lineLayout(("中" ** 20)));
    try std.testing.expectEqual(LineLayout{ .rows = 1, .column = 2 }, lineLayout("👩‍💻"));
    try std.testing.expectEqual(LineLayout{ .rows = 1, .column = 2 }, lineLayout("❤️"));
}

test "live renderer keeps emoji clusters in one cell pair" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    sink = &output.writer;
    rows = 24;
    cols = 40;
    layout_ready = true;
    region_row = regionTop();
    region_col = contentLeft();
    display_state = .text;
    display_control_len = 0;
    display_utf8_len = 0;
    display_utf8_expected = 0;
    display_joined = false;
    display_cluster_width = 0;
    display_regional_pending = false;
    defer layout_ready = false;

    try writeRegionBytes("👩‍💻");
    try std.testing.expectEqual(@as(usize, 4), region_col);
    region_col = contentLeft();
    display_cluster_width = 0;
    try writeRegionBytes("❤️");
    try std.testing.expectEqual(@as(usize, 4), region_col);
}
