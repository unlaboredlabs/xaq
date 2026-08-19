//! Interactive terminal input: a raw-mode line editor with a live
//! slash-command popup, and a small list picker for choices such as the
//! model switcher. Inline only—drawing stays at the prompt, never a
//! fullscreen UI. When stdin is not a terminal every call falls back to
//! plain line reads, so pipes and scripts behave exactly as before.
//!
//! Editing covers insert and delete at a movable cursor (left/right,
//! home/end, ctrl-a/e, alt-b/f by word), ctrl-u kills to line start,
//! ctrl-k kills to line end, ctrl-w and alt-backspace delete the
//! previous word, ctrl-c abandons the line (and pressed twice on an
//! empty line, ends the session), ctrl-d on an empty line ends the
//! session. Up/down walk the history, which persists across sessions.
//! While the line is a slash command, matching commands render dimmed
//! below the cursor; up/down selects, tab completes, enter runs.
//! Arrow keys are recognized in both CSI (`ESC [ A`) and SS3
//! (`ESC O A`) encodings.

const std = @import("std");
const Io = std.Io;
const term = @import("term.zig");
const tui = @import("tui.zig");

/// Set by main when both stdin and stdout are terminals.
pub var interactive = false;

pub const Suggestion = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    args: []const u8 = "",
    help: []const u8,
};

const popup_line_max = 60;
/// Column where suggestion and /help descriptions start; wide enough
/// for the longest name-plus-args (`/firecrawl [status|clear]`).
pub const help_column = 28;
const popup_rows_max = 9;
pub const max_input_bytes = 4 * 1024 * 1024;
const full_echo_max = 4 * 1024;

/// Read one logical line, trimmed and owned by `gpa`. A trailing unescaped
/// backslash removes itself and continues on the next physical line.
/// `initial` prefills the editor (for example a cancelled prompt).
pub fn readLine(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer, suggestions: []const Suggestion, initial: ?[]const u8) !?[]const u8 {
    defer continuation_line = false;
    var first = (try physicalLine(gpa, reader, output, suggestions, initial)) orelse return null;
    if (!continues(first)) {
        historyPush(gpa, first);
        return first;
    }
    var result: Io.Writer.Allocating = .init(gpa);
    defer result.deinit();
    while (true) {
        const more = continues(first);
        try result.writer.writeAll(if (more) first[0 .. first.len - 1] else first);
        gpa.free(first);
        if (!more) break;
        try result.writer.writeByte('\n');
        continuation_line = true;
        first = (try physicalLine(gpa, reader, output, suggestions, null)) orelse break;
    }
    const line = try result.toOwnedSlice();
    historyPush(gpa, line);
    return line;
}

/// Read a short secret without echoing it or adding it to prompt history.
/// Bracketed paste works, which is the usual way API keys enter this prompt.
pub fn readSecret(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer, label: []const u8) !?[]const u8 {
    const raw = RawMode.enter() catch {
        if (interactive) return error.SecretInputUnavailable;
        return plainSecret(gpa, reader, output, label);
    };
    defer raw.exit();
    if (tui.active) tui.beginInput();
    defer if (tui.active) tui.endInput();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var resize_wait = ResizeWait.init();
    try drawSecret(output, label, 0);
    try secretPasteMode(output, true);
    defer secretPasteMode(output, false) catch {};

    while (true) {
        const byte = switch (try resize_wait.next(reader)) {
            .byte => |byte| byte,
            .resize => {
                try drawSecret(output, label, buffer.items.len);
                continue;
            },
            .end => {
                try finishSecret(output);
                return null;
            },
        };
        switch (byte) {
            '\r', '\n' => {
                try finishSecret(output);
                const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
                return try gpa.dupe(u8, trimmed);
            },
            0x03, 0x04 => {
                try finishSecret(output);
                return null;
            },
            0x7f, 0x08 => if (buffer.items.len > 0) {
                buffer.items.len = prevBoundary(buffer.items, buffer.items.len);
                try drawSecret(output, label, buffer.items.len);
            },
            0x1b => {
                const second = (try takeByteOrNull(reader)) orelse continue;
                if (second != '[') continue;
                var parameter: usize = 0;
                var final: u8 = 0;
                while (true) {
                    const next = (try takeByteOrNull(reader)) orelse break;
                    if (next >= '0' and next <= '9') {
                        if (parameter < 100_000) parameter = parameter * 10 + next - '0';
                    } else if (next >= 0x40 and next <= 0x7e) {
                        final = next;
                        break;
                    }
                }
                if (final == '~' and parameter == 200) {
                    var cursor = buffer.items.len;
                    _ = try pasteInto(gpa, &buffer, &cursor, reader);
                    try drawSecret(output, label, buffer.items.len);
                }
            },
            else => if (byte >= 0x21 and byte <= 0x7e and buffer.items.len < 1024) {
                try buffer.append(gpa, byte);
                try drawSecret(output, label, buffer.items.len);
            },
        }
    }
}

fn secretPasteMode(output: *Io.Writer, enabled: bool) !void {
    const target = if (tui.active) tui.chromeSink() else output;
    try target.writeAll(if (enabled) "\x1b[?2004h" else "\x1b[?2004l");
    try target.flush();
}

fn drawSecret(output: *Io.Writer, label: []const u8, length: usize) !void {
    if (tui.active) {
        _ = tui.checkResize();
        if (!tui.drawable()) return;
    }
    const target = if (tui.active) tui.chromeSink() else output;
    const width = if (tui.active) tui.inputArea().width else terminalWidth() -| 1;
    const row = if (tui.active) tui.inputArea().row else 0;
    const column = if (tui.active) tui.inputArea().col else 1;
    if (tui.active) try target.print("\x1b[{d};{d}H", .{ row, column }) else try target.writeByte('\r');
    const label_len = @min(label.len, width);
    try target.writeAll(label[0..label_len]);
    var used = label_len;
    const stars = @min(length, width -| used);
    for (0..stars) |_| try target.writeByte('*');
    used += stars;
    while (used < width) : (used += 1) try target.writeByte(' ');
    if (tui.active) {
        try target.print("\x1b[{d};{d}H", .{ row, column + label_len + stars });
    } else {
        try target.print("\r\x1b[{d}C", .{label_len + stars});
    }
    try target.flush();
}

fn finishSecret(output: *Io.Writer) !void {
    if (tui.active) {
        _ = tui.checkResize();
        tui.closePopup();
        _ = try redrawTui(&.{}, "", 0, 0);
        tui.focusRegion();
    } else {
        try output.writeAll("\r\x1b[J\n");
        try output.flush();
    }
}

fn plainSecret(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer, label: []const u8) !?[]const u8 {
    try output.writeAll(label);
    try output.flush();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    while (try takeByteOrNull(reader)) |byte| {
        if (byte == '\r' or byte == '\n') break;
        if (line.items.len < 1024) try line.append(gpa, byte);
    }
    try output.writeByte('\n');
    try output.flush();
    return try gpa.dupe(u8, std.mem.trim(u8, line.items, " \t\r\n"));
}

fn physicalLine(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer, suggestions: []const Suggestion, initial: ?[]const u8) !?[]const u8 {
    if (!interactive) return plainLine(gpa, reader, output);
    const raw = RawMode.enter() catch return plainLine(gpa, reader, output);
    defer raw.exit();
    if (tui.active) tui.beginInput();
    defer if (tui.active) tui.endInput();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var cursor: usize = 0;
    var selected: usize = 0;
    var popup_shown = false;
    var pending: ?u8 = null;
    var interrupt_armed = false;
    var hist_pos: ?usize = null;
    var stash: std.ArrayList(u8) = .empty;
    defer stash.deinit(gpa);
    var stash_truncated = false;
    var dirty_after_hint = false;
    var input_truncated = false;
    var utf8_dropping = false;
    var resize_wait = ResizeWait.init();

    if (initial) |text| {
        input_truncated = !(try load(gpa, &buffer, text));
        cursor = buffer.items.len;
    }

    // Bracketed paste keeps multi-line pastes from submitting line by line.
    // In fullscreen mode `output` is the buffered transcript tee, while the
    // editor draws through the chrome sink. Send terminal controls through
    // that same direct sink and flush before reading; otherwise the enable
    // sequence can sit in the tee until the first pasted newline submits.
    const terminal_output = if (tui.active) tui.chromeSink() else output;
    try terminal_output.writeAll("\x1b[?2004h");
    try terminal_output.flush();
    defer {
        terminal_output.writeAll("\x1b[?2004l") catch {};
        terminal_output.flush() catch {};
    }
    popup_shown = try renderEditor(output, suggestions, buffer.items, selected, cursor);

    while (true) {
        const byte = blk: {
            if (pending) |p| {
                pending = null;
                break :blk p;
            }
            break :blk switch (try resize_wait.next(reader)) {
                .byte => |byte| byte,
                .resize => {
                    popup_shown = try renderEditor(output, suggestions, buffer.items, selected, cursor);
                    continue;
                },
                .end => {
                    try endEditor(output);
                    return null;
                },
            };
        };
        if (interrupt_armed and byte != 0x03) {
            // Any other key withdraws the pending exit and clears the hint.
            interrupt_armed = false;
            dirty_after_hint = true;
        }
        var dirty = dirty_after_hint;
        dirty_after_hint = false;
        switch (byte) {
            '\r', '\n' => {
                const line = buffer.items;
                const chosen = if (popupActive(line))
                    nthMatch(suggestions, line[1..], selected)
                else
                    null;
                if (chosen) |suggestion| {
                    try fill(gpa, &buffer, suggestion.name, false);
                    input_truncated = false;
                }
                if (tui.active) {
                    tui.closePopup();
                    _ = try redrawTui(suggestions, "", 0, 0);
                    tui.focusRegion();
                    // The submitted prompt echoes into the transcript as
                    // its own block, blank-line separated on both sides.
                    try output.print("\n{s}> ", .{term.dim()});
                    try writeSubmittedVisible(output, buffer.items);
                    try output.print("{s}\n\n", .{term.reset()});
                    try output.flush();
                } else {
                    try prompt(output, buffer.items);
                    try output.writeAll("\x1b[J\r\n");
                    try output.flush();
                }
                if (input_truncated) {
                    try output.print("{s}[input limited to 4 MiB]{s}\n", .{ term.dim(), term.reset() });
                    try output.flush();
                }
                const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
                return try gpa.dupe(u8, trimmed);
            },
            0x7f, 0x08 => if (cursor > 0) {
                const previous = prevBoundary(buffer.items, cursor);
                std.mem.copyForwards(u8, buffer.items[previous..], buffer.items[cursor..]);
                buffer.items.len -= cursor - previous;
                cursor = previous;
                selected = 0;
                hist_pos = null;
                dirty = true;
            },
            0x03 => if (buffer.items.len > 0) {
                buffer.clearRetainingCapacity();
                input_truncated = false;
                cursor = 0;
                selected = 0;
                hist_pos = null;
                dirty = true;
            } else if (interrupt_armed) {
                try endEditor(output);
                return null;
            } else {
                interrupt_armed = true;
                if (tui.active) {
                    if (!tui.drawable()) continue;
                    const chrome = tui.chromeSink();
                    const area = tui.inputArea();
                    try chrome.print("\x1b[{d};{d}H{s}ctrl-c again to exit{s}", .{ area.row, area.col, term.dim(), term.reset() });
                    var column: usize = "ctrl-c again to exit".len;
                    while (column < area.width) : (column += 1) try chrome.writeByte(' ');
                    try chrome.print("\x1b[{d};{d}H", .{ area.row, area.col });
                    try chrome.flush();
                } else {
                    try prompt(output, "");
                    try output.print("\x1b[J{s}ctrl-c again to exit{s}", .{ term.dim(), term.reset() });
                    try output.flush();
                }
            },
            0x15 => if (cursor > 0) { // ctrl-u: kill to line start
                std.mem.copyForwards(u8, buffer.items[0..], buffer.items[cursor..]);
                buffer.items.len -= cursor;
                if (buffer.items.len == 0) input_truncated = false;
                cursor = 0;
                selected = 0;
                hist_pos = null;
                dirty = true;
            },
            0x0b => if (cursor < buffer.items.len) { // ctrl-k: kill to line end
                buffer.items.len = cursor;
                selected = 0;
                hist_pos = null;
                dirty = true;
            },
            0x17 => if (cursor > 0) { // ctrl-w: delete the previous word
                const start = prevWord(buffer.items, cursor);
                std.mem.copyForwards(u8, buffer.items[start..], buffer.items[cursor..]);
                buffer.items.len -= cursor - start;
                cursor = start;
                selected = 0;
                hist_pos = null;
                dirty = true;
            },
            0x01 => {
                cursor = 0;
                dirty = true;
            },
            0x05 => {
                cursor = buffer.items.len;
                dirty = true;
            },
            0x04 => if (buffer.items.len == 0) {
                try endEditor(output);
                return null;
            },
            '\t' => if (popupActive(buffer.items)) {
                if (nthMatch(suggestions, buffer.items[1..], selected)) |suggestion| {
                    try fill(gpa, &buffer, suggestion.name, suggestion.args.len > 0);
                    input_truncated = false;
                    cursor = buffer.items.len;
                    selected = 0;
                    hist_pos = null;
                    dirty = true;
                }
            },
            0x1b => {
                const second = (try takeByteOrNull(reader)) orelse continue;
                var final: u8 = 0;
                var param: usize = 0;
                if (second == '[') {
                    var param_done = false;
                    var next = (try takeByteOrNull(reader)) orelse continue;
                    while (next < 0x40 or next > 0x7e) {
                        if (!param_done and next >= '0' and next <= '9') {
                            // Clamp: an adversarial digit run must not
                            // overflow (no CSI parameter we act on exceeds
                            // four digits).
                            if (param < 100_000) param = param * 10 + (next - '0');
                        } else {
                            param_done = true;
                        }
                        next = (try takeByteOrNull(reader)) orelse break;
                    }
                    if (next >= 0x40 and next <= 0x7e) final = next;
                } else if (second == 'O') {
                    final = (try takeByteOrNull(reader)) orelse 0;
                } else if (second == 'b') { // alt-b: word left
                    cursor = prevWord(buffer.items, cursor);
                    dirty = true;
                } else if (second == 'f') { // alt-f: word right
                    cursor = nextWord(buffer.items, cursor);
                    dirty = true;
                } else if (second == 0x7f or second == 0x08) { // alt-backspace
                    if (cursor > 0) {
                        const start = prevWord(buffer.items, cursor);
                        std.mem.copyForwards(u8, buffer.items[start..], buffer.items[cursor..]);
                        buffer.items.len -= cursor - start;
                        cursor = start;
                        selected = 0;
                        hist_pos = null;
                        dirty = true;
                    }
                } else {
                    pending = second;
                    continue;
                }
                switch (final) {
                    'A' => if (popup_shown) {
                        if (selected > 0) {
                            selected -= 1;
                            dirty = true;
                        }
                    } else if (history_count > 0) {
                        if (hist_pos == null) {
                            _ = try load(gpa, &stash, buffer.items);
                            stash_truncated = input_truncated;
                            hist_pos = history_count;
                        }
                        if (hist_pos.? > 0) {
                            hist_pos = hist_pos.? - 1;
                            _ = try load(gpa, &buffer, history_items[hist_pos.?]);
                            input_truncated = false;
                            cursor = buffer.items.len;
                            selected = 0;
                            dirty = true;
                        }
                    },
                    'B' => if (popup_shown) {
                        const rows = countMatches(suggestions, buffer.items[1..]);
                        if (rows > 0 and selected + 1 < rows) {
                            selected += 1;
                            dirty = true;
                        }
                    } else if (hist_pos) |position| {
                        if (position + 1 < history_count) {
                            hist_pos = position + 1;
                            _ = try load(gpa, &buffer, history_items[position + 1]);
                            input_truncated = false;
                        } else {
                            hist_pos = null;
                            _ = try load(gpa, &buffer, stash.items);
                            input_truncated = stash_truncated;
                        }
                        cursor = buffer.items.len;
                        selected = 0;
                        dirty = true;
                    },
                    'C' => if (cursor < buffer.items.len) {
                        cursor = nextBoundary(buffer.items, cursor);
                        dirty = true;
                    },
                    'D' => if (cursor > 0) {
                        cursor = prevBoundary(buffer.items, cursor);
                        dirty = true;
                    },
                    'H' => {
                        cursor = 0;
                        dirty = true;
                    },
                    'F' => {
                        cursor = buffer.items.len;
                        dirty = true;
                    },
                    '~' => switch (param) {
                        1, 7 => {
                            cursor = 0;
                            dirty = true;
                        },
                        4, 8 => {
                            cursor = buffer.items.len;
                            dirty = true;
                        },
                        3 => if (cursor < buffer.items.len) {
                            const next = nextBoundary(buffer.items, cursor);
                            std.mem.copyForwards(u8, buffer.items[cursor..], buffer.items[next..]);
                            buffer.items.len -= next - cursor;
                            selected = 0;
                            hist_pos = null;
                            dirty = true;
                        },
                        200 => {
                            input_truncated = !(try pasteInto(gpa, &buffer, &cursor, reader)) or input_truncated;
                            selected = 0;
                            hist_pos = null;
                            dirty = true;
                        },
                        5 => if (tui.pageUp()) {
                            dirty = true;
                        },
                        6 => if (tui.pageDown()) {
                            dirty = true;
                        },
                        else => {},
                    },
                    else => {},
                }
            },
            else => if (byte >= 0x20) {
                // Admit whole code points only: a lead byte reserves room
                // for its full sequence, so the limit can never split a
                // multibyte character into invalid UTF-8.
                const continuation = byte & 0xc0 == 0x80;
                if (continuation) {
                    if (utf8_dropping) {
                        input_truncated = true;
                    } else {
                        try buffer.insert(gpa, cursor, byte);
                        cursor += 1;
                        dirty = true;
                    }
                } else {
                    const needed: usize = if (byte < 0x80) 1 else if (byte & 0xe0 == 0xc0) 2 else if (byte & 0xf0 == 0xe0) 3 else 4;
                    if (buffer.items.len + needed <= max_input_bytes) {
                        utf8_dropping = false;
                        try buffer.insert(gpa, cursor, byte);
                        cursor += 1;
                        selected = 0;
                        hist_pos = null;
                        dirty = true;
                    } else {
                        utf8_dropping = true;
                        input_truncated = true;
                    }
                }
            },
        }
        if (dirty) {
            popup_shown = try renderEditor(output, suggestions, buffer.items, selected, cursor);
        }
    }
}

fn renderEditor(output: *Io.Writer, suggestions: []const Suggestion, line: []const u8, selected: usize, cursor: usize) !bool {
    if (tui.active) {
        _ = tui.checkResize();
        if (!tui.drawable()) return false;
        return redrawTui(suggestions, line, selected, cursor);
    }
    return redraw(output, suggestions, line, selected, cursor);
}

/// Leave the editor cleanly on EOF or double ctrl-c.
fn endEditor(output: *Io.Writer) !void {
    if (tui.active) {
        _ = tui.checkResize();
        if (!tui.drawable()) return;
        tui.closePopup();
        _ = try redrawTui(&.{}, "", 0, 0);
        tui.focusRegion();
        return;
    }
    try output.writeAll("\x1b[J\r\n");
    try output.flush();
}

/// Fullscreen editor rendering: the input line lives in the fixed box
/// row, and the completion popup overlays the bottom of the transcript
/// region instead of drawing below the prompt.
fn redrawTui(suggestions: []const Suggestion, line: []const u8, selected: usize, cursor: usize) !bool {
    if (!tui.drawable()) return false;
    const chrome = tui.chromeSink();
    const area = tui.inputArea();
    const cursor_cols = columns(line[0..cursor]);
    const avail = area.width;
    try chrome.print("\x1b[{d};{d}H", .{ area.row, area.col });
    const window = try writeWindow(chrome, line, cursor_cols, avail);
    var used = window.used;
    while (used < area.width) : (used += 1) try chrome.writeByte(' ');
    var shown: usize = 0;
    if (popupActive(line)) {
        const word = line[1..];
        const matched = countMatches(suggestions, word);
        const granted = tui.beginPopup(matched);
        // Keep the selected row visible when the popup is clamped.
        const first = if (selected >= granted) selected + 1 - granted else 0;
        var index: usize = 0;
        var row: usize = 0;
        for (suggestions) |suggestion| {
            if (!matches(suggestion, word)) continue;
            defer index += 1;
            if (index < first) continue;
            if (row == granted) break;
            var row_buffer: [160]u8 = undefined;
            var writer: Io.Writer = .fixed(&row_buffer);
            const is_selected = index == selected;
            writer.print("{s}{s}/{s}{s}", .{
                if (is_selected) term.bold() else term.dim(),
                if (is_selected) "> " else "  ",
                suggestion.name,
                suggestion.args,
            }) catch {};
            var column = 1 + suggestion.name.len + suggestion.args.len;
            while (column < help_column) : (column += 1) writer.writeByte(' ') catch {};
            writer.print("{s}{s}", .{ suggestion.help, term.reset() }) catch {};
            tui.popupLine(row, writer.buffered());
            row += 1;
        }
        shown = granted;
    } else {
        tui.closePopup();
    }
    try chrome.print("\x1b[{d};{d}H", .{ area.row, area.col + window.cursor });
    try chrome.flush();
    return shown > 0;
}

/// Replace the editor contents. False means the source exceeded the input
/// limit and was clipped (on a UTF-8 code-point boundary).
fn load(gpa: std.mem.Allocator, buffer: *std.ArrayList(u8), text: []const u8) !bool {
    buffer.clearRetainingCapacity();
    var count = @min(text.len, max_input_bytes);
    while (count > 0 and count < text.len and text[count] & 0xc0 == 0x80) count -= 1;
    try buffer.appendSlice(gpa, text[0..count]);
    return count == text.len;
}

/// Consume a bracketed paste, inserting sanitized bytes at the cursor:
/// CR and CRLF become LF, other control bytes are dropped, tabs become
/// spaces. The paste is collected and inserted in one operation so inserting
/// a large block in the middle of a prompt remains linear. False means the
/// input limit was reached; the rest is still consumed through the terminator.
fn pasteInto(gpa: std.mem.Allocator, buffer: *std.ArrayList(u8), cursor: *usize, reader: *Io.Reader) !bool {
    const terminator = "\x1b[201~";
    var pasted: std.ArrayList(u8) = .empty;
    defer pasted.deinit(gpa);
    var matched: usize = 0;
    var previous: u8 = 0;
    var complete = true;
    const available = max_input_bytes - buffer.items.len;
    while (true) {
        const byte = (try takeByteOrNull(reader)) orelse {
            for (terminator[0..matched]) |held| try appendPasteByte(gpa, &pasted, held, &previous, available, &complete);
            break;
        };
        if (byte == terminator[matched]) {
            matched += 1;
            if (matched == terminator.len) break;
            continue;
        }
        if (matched > 0) {
            for (terminator[0..matched]) |held| try appendPasteByte(gpa, &pasted, held, &previous, available, &complete);
            matched = 0;
            if (byte == terminator[0]) {
                matched = 1;
                continue;
            }
        }
        try appendPasteByte(gpa, &pasted, byte, &previous, available, &complete);
    }
    // When clipped at the cap, land on a code-point boundary; the byte
    // cap alone could split a multibyte character into invalid UTF-8.
    var keep = pasted.items.len;
    if (!complete) {
        while (keep > 0 and pasted.items[keep - 1] & 0xc0 == 0x80) keep -= 1;
        if (keep > 0 and pasted.items[keep - 1] >= 0xc0) keep -= 1;
    }
    try buffer.insertSlice(gpa, cursor.*, pasted.items[0..keep]);
    cursor.* += keep;
    return complete;
}

fn appendPasteByte(gpa: std.mem.Allocator, pasted: *std.ArrayList(u8), byte_in: u8, previous: *u8, available: usize, complete: *bool) !void {
    const raw = byte_in;
    defer previous.* = raw;
    var byte = byte_in;
    if (byte == '\n' and previous.* == '\r') return; // CRLF already inserted as LF
    if (byte == '\r') byte = '\n';
    if (byte == '\t') byte = ' ';
    if ((byte < 0x20 and byte != '\n') or byte == 0x7f) return;
    if (pasted.items.len == available) {
        complete.* = false;
        return;
    }
    try pasted.append(gpa, byte);
}

fn continues(line: []const u8) bool {
    var count: usize = 0;
    var i = line.len;
    while (i > 0 and line[i - 1] == '\\') : (i -= 1) count += 1;
    return count % 2 == 1;
}

/// Inline single-column picker: up/down or j/k moves, enter confirms,
/// ctrl-c or q cancels. Returns the chosen index. The drawn list is
/// erased before returning.
pub fn pick(reader: *Io.Reader, output: *Io.Writer, items: []const []const u8, initial: usize) !?usize {
    if (!interactive or items.len == 0) return null;
    const raw = RawMode.enter() catch return null;
    defer raw.exit();
    if (tui.active) tui.beginInput();
    defer if (tui.active) tui.endInput();

    var selected = @min(initial, items.len - 1);
    var resize_wait = ResizeWait.init();
    while (true) {
        if (tui.active) {
            _ = tui.checkResize();
            try drawPickOverlay(items, selected);
        } else {
            const granted = @min(items.len, @min(terminalHeight() -| 1, popup_rows_max));
            const first = if (selected >= granted and granted > 0) selected + 1 - granted else 0;
            for (0..granted) |row| {
                const index = first + row;
                const style = if (index == selected) term.bold() else term.dim();
                const marker: []const u8 = if (index == selected) "\u{258c} " else "  ";
                try output.print("{s}{s}", .{ style, marker });
                try writePlainClipped(output, items[index], terminalWidth() -| 2);
                try output.print("{s}\x1b[K\r\n", .{term.reset()});
            }
            try output.writeAll("\x1b[J");
            if (granted > 0) try output.print("\x1b[{d}A\r", .{granted});
            try output.flush();
        }

        const byte = switch (try resize_wait.next(reader)) {
            .byte => |byte| byte,
            .resize => continue,
            .end => break,
        };
        switch (byte) {
            '\r', '\n' => {
                try endPick(output);
                return selected;
            },
            0x03, 0x04, 'q' => break,
            'k' => selected -|= 1,
            'j' => selected = @min(selected + 1, items.len - 1),
            0x1b => {
                const second = (try takeByteOrNull(reader)) orelse break;
                var final: u8 = 0;
                if (second == '[') {
                    var next = (try takeByteOrNull(reader)) orelse break;
                    while (next < 0x40 or next > 0x7e) {
                        next = (try takeByteOrNull(reader)) orelse break;
                    }
                    if (next >= 0x40 and next <= 0x7e) final = next;
                } else if (second == 'O') {
                    final = (try takeByteOrNull(reader)) orelse 0;
                } else continue;
                switch (final) {
                    'A' => selected -|= 1,
                    'B' => selected = @min(selected + 1, items.len - 1),
                    else => {},
                }
            },
            else => {},
        }
    }
    try endPick(output);
    return null;
}

/// Fullscreen picker rendering: rows overlay the transcript bottom,
/// windowed so the selection stays visible.
fn drawPickOverlay(items: []const []const u8, selected: usize) !void {
    const granted = tui.beginPopup(items.len);
    if (granted == 0) return;
    const first = if (selected >= granted) selected + 1 - granted else 0;
    var row: usize = 0;
    while (row < granted) : (row += 1) {
        const index = first + row;
        var row_buffer: [160]u8 = undefined;
        var writer: Io.Writer = .fixed(&row_buffer);
        if (index == selected) {
            writer.print("{s}\u{258c} {s}{s}", .{ term.bold(), items[index], term.reset() }) catch {};
        } else {
            writer.print("{s}  {s}{s}", .{ term.dim(), items[index], term.reset() }) catch {};
        }
        tui.popupLine(row, writer.buffered());
    }
    try tui.chromeSink().flush();
}

fn endPick(output: *Io.Writer) !void {
    if (tui.active) {
        tui.closePopup();
        return;
    }
    try output.writeAll("\x1b[J");
    try output.flush();
}

fn plainLine(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer) !?[]const u8 {
    try prompt(output, "");
    try output.flush();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var truncated = false;
    var saw_byte = false;
    while (try takeByteOrNull(reader)) |byte| {
        saw_byte = true;
        if (byte == '\n') break;
        if (line.items.len < max_input_bytes) {
            try line.append(gpa, byte);
        } else {
            truncated = true;
        }
    }
    if (!saw_byte and line.items.len == 0) {
        try output.writeByte('\n');
        try output.flush();
        return null;
    }
    if (truncated) {
        try output.print("{s}[input limited to 4 MiB]{s}\n", .{ term.dim(), term.reset() });
        try output.flush();
    }
    return try gpa.dupe(u8, std.mem.trim(u8, line.items, " \t\r\n"));
}

/// True while reading the second and later physical lines of a
/// backslash-continued prompt; the marker changes so continuation lines
/// do not look like fresh prompts.
var continuation_line = false;

fn prompt(output: *Io.Writer, line: []const u8) !void {
    if (continuation_line) {
        try output.print("\r{s}\u{21b3}{s}", .{ term.dim(), term.reset() });
    } else {
        try output.print("\r{s}\u{258c}{s}", .{ term.bold(), term.reset() });
    }
    try writeSubmittedVisible(output, line);
}

/// Avoid replaying megabytes into the terminal and fullscreen transcript.
/// The returned prompt still contains every byte; this only changes its echo.
fn writeSubmittedVisible(output: *Io.Writer, text: []const u8) !void {
    if (text.len <= full_echo_max) return writeVisible(output, text);
    var lines = 1 + std.mem.count(u8, text, "\n");
    if (text[text.len - 1] == '\n' and lines > 1) lines -= 1;
    try output.print("[prompt: {d} bytes, {d} {s}]", .{ text.len, lines, if (lines == 1) "line" else "lines" });
}

/// Buffer bytes are printable plus embedded newlines (from pastes and
/// prefills); newlines render as a return symbol so the edit line stays
/// single-row.
fn writeVisible(output: *Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        if (byte == '\n') {
            try output.writeAll("\u{23ce}");
        } else {
            try output.writeByte(byte);
        }
    }
}

/// The popup follows the line while a short slash-command word is being
/// typed; a space (arguments) or a long line hides it.
fn popupActive(line: []const u8) bool {
    if (line.len == 0 or line[0] != '/' or line.len > popup_line_max) return false;
    return std.mem.findAny(u8, line, " \t\n") == null;
}

fn matches(suggestion: Suggestion, word: []const u8) bool {
    if (std.mem.startsWith(u8, suggestion.name, word)) return true;
    if (suggestion.alias) |alias| return std.mem.startsWith(u8, alias, word);
    return false;
}

fn countMatches(suggestions: []const Suggestion, word: []const u8) usize {
    var count: usize = 0;
    for (suggestions) |suggestion| {
        if (matches(suggestion, word)) count += 1;
    }
    return count;
}

fn nthMatch(suggestions: []const Suggestion, word: []const u8, n: usize) ?Suggestion {
    var index: usize = 0;
    for (suggestions) |suggestion| {
        if (!matches(suggestion, word)) continue;
        if (index == n) return suggestion;
        index += 1;
    }
    return null;
}

fn fill(gpa: std.mem.Allocator, buffer: *std.ArrayList(u8), name: []const u8, trailing_space: bool) !void {
    buffer.clearRetainingCapacity();
    try buffer.ensureUnusedCapacity(gpa, 1 + name.len + @intFromBool(trailing_space));
    buffer.appendAssumeCapacity('/');
    buffer.appendSliceAssumeCapacity(name);
    if (trailing_space) buffer.appendAssumeCapacity(' ');
}

/// Reprint the input line, clear below, draw matching commands, and park
/// the cursor at its position within the line. Lines wider than the
/// terminal render a scrolling window around the cursor, marked with an
/// ellipsis on the clipped side. Returns whether popup rows remain.
fn redraw(output: *Io.Writer, suggestions: []const Suggestion, line: []const u8, selected: usize, cursor: usize) !bool {
    const cursor_cols = columns(line[0..cursor]);
    const avail = terminalWidth() -| 4;

    try output.print("\r{s}\u{258c}{s}", .{ term.bold(), term.reset() });
    const window = try writeWindow(output, line, cursor_cols, avail);
    try output.writeAll("\x1b[J");
    var rows: usize = 0;
    if (popupActive(line)) {
        // Clamp the popup so it cannot scroll a short terminal; the
        // window follows the selection like the fullscreen overlay.
        const word = line[1..];
        const matched = countMatches(suggestions, word);
        const granted = @min(matched, @min(terminalHeight() -| 2, popup_rows_max));
        const first = if (selected >= granted) selected + 1 - granted else 0;
        var index: usize = 0;
        for (suggestions) |suggestion| {
            if (!matches(suggestion, word)) continue;
            defer index += 1;
            if (index < first) continue;
            if (rows == granted) break;
            const is_selected = index == selected;
            const style = if (is_selected) term.bold() else term.dim();
            const marker: []const u8 = if (is_selected) "\u{258c} " else "  ";
            var row_buffer: [256]u8 = undefined;
            var row_writer: Io.Writer = .fixed(&row_buffer);
            row_writer.print("{s}/{s}{s}", .{ marker, suggestion.name, suggestion.args }) catch {};
            var column = 1 + suggestion.name.len + suggestion.args.len;
            while (column < help_column) : (column += 1) row_writer.writeByte(' ') catch {};
            row_writer.writeAll(suggestion.help) catch {};
            try output.print("\r\n{s}", .{style});
            try writePlainClipped(output, row_writer.buffered(), terminalWidth());
            try output.writeAll(term.reset());
            rows += 1;
        }
        if (rows > 0) try output.print("\x1b[{d}A", .{rows});
    }
    try output.print("\r\x1b[{d}C", .{1 + window.cursor});
    try output.flush();
    return rows > 0;
}

/// First visible column when the line is wider than the window: keep the
/// cursor inside, preferring to show text before it.
fn windowStart(total: usize, cursor_cols: usize, avail: usize) usize {
    if (avail == 0 or total <= avail) return 0;
    return if (cursor_cols > avail) cursor_cols - avail else 0;
}

const ColumnBoundary = struct { byte: usize, column: usize };

fn boundaryAtOrAfter(line: []const u8, column: usize) ColumnBoundary {
    var result: ColumnBoundary = .{ .byte = 0, .column = 0 };
    while (result.byte < line.len and result.column < column) {
        const next = nextBoundary(line, result.byte);
        result.column += term.displayWidth(line[result.byte..next]);
        result.byte = next;
    }
    return result;
}

fn boundaryWithin(line: []const u8, start: usize, max_cols: usize) ColumnBoundary {
    var result: ColumnBoundary = .{ .byte = start, .column = 0 };
    while (result.byte < line.len) {
        const next = nextBoundary(line, result.byte);
        const width = term.displayWidth(line[result.byte..next]);
        if (result.column + width > max_cols) break;
        result.column += width;
        result.byte = next;
    }
    return result;
}

const WindowRender = struct { used: usize, cursor: usize };

/// Draw one editor row without splitting a wide code point or consuming the
/// cell reserved for a clipping marker.
fn writeWindow(output: *Io.Writer, line: []const u8, cursor_cols: usize, avail: usize) !WindowRender {
    if (avail == 0) return .{ .used = 0, .cursor = 0 };
    const total = columns(line);
    if (total <= avail) {
        try writeVisible(output, line);
        return .{ .used = total, .cursor = @min(cursor_cols, avail - 1) };
    }

    const requested_start = windowStart(total, cursor_cols, avail -| 2);
    const start = boundaryAtOrAfter(line, requested_start);
    const left_marker: usize = @intFromBool(start.byte > 0);
    var budget = avail -| left_marker;
    var end = boundaryWithin(line, start.byte, budget);
    const needs_right = end.byte < line.len;
    if (needs_right) {
        budget -|= 1;
        end = boundaryWithin(line, start.byte, budget);
    }

    if (left_marker > 0) try output.print("{s}…{s}", .{ term.dim(), term.reset() });
    try writeVisible(output, line[start.byte..end.byte]);
    if (needs_right) try output.print("{s}…{s}", .{ term.dim(), term.reset() });
    const used = left_marker + end.column + @as(usize, @intFromBool(needs_right));
    const cursor = left_marker + (cursor_cols -| start.column);
    return .{ .used = used, .cursor = @min(cursor, avail - 1) };
}

fn writePlainClipped(output: *Io.Writer, text: []const u8, max_cols: usize) !void {
    if (max_cols == 0) return;
    var end = boundaryWithin(text, 0, max_cols);
    if (end.byte < text.len) {
        end = boundaryWithin(text, 0, max_cols - 1);
        try writeVisible(output, text[0..end.byte]);
        try output.print("{s}…{s}", .{ term.dim(), term.reset() });
    } else {
        try writeVisible(output, text);
    }
}

/// First byte of the code point at or after `column` display columns.
fn byteAtColumn(line: []const u8, column: usize) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (count >= column) return i;
        const next = nextBoundary(line, i);
        count += term.displayWidth(line[i..next]);
        i = next;
    }
    return line.len;
}

fn terminalWidth() usize {
    if (term.windowSizeRaw()) |size| return size.cols;
    return 80;
}

fn terminalHeight() usize {
    if (term.windowSizeRaw()) |size| return size.rows;
    return 24;
}

/// Display columns of the text, wide- and zero-width-aware.
fn columns(text: []const u8) usize {
    return term.displayWidth(text);
}

fn prevWord(line: []const u8, index: usize) usize {
    var i = index;
    while (i > 0 and (line[i - 1] == ' ' or line[i - 1] == '\n')) i -= 1;
    while (i > 0 and line[i - 1] != ' ' and line[i - 1] != '\n') i -= 1;
    return i;
}

fn nextWord(line: []const u8, index: usize) usize {
    var i = index;
    while (i < line.len and (line[i] == ' ' or line[i] == '\n')) i += 1;
    while (i < line.len and line[i] != ' ' and line[i] != '\n') i += 1;
    return i;
}

fn prevBoundary(line: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var previous: usize = 0;
    var i: usize = 0;
    while (i < index) {
        previous = i;
        i = term.nextCell(line, i).end;
    }
    return previous;
}

fn nextBoundary(line: []const u8, index: usize) usize {
    if (index >= line.len) return line.len;
    return term.nextCell(line, index).end;
}

const history_max = 64;
const history_bytes_max = max_input_bytes;
var history_items: [history_max][]const u8 = undefined;
var history_count: usize = 0;
var history_bytes: usize = 0;
var history_io: ?Io = null;
var history_path_buffer: [1024]u8 = undefined;
var history_path_len: usize = 0;

/// Load persisted prompt history (JSON string per line) and enable
/// appends for this session. Best-effort: any failure leaves history
/// in-memory only.
pub fn initHistory(gpa: std.mem.Allocator, io: Io, home: []const u8) void {
    const path = std.fs.path.join(gpa, &.{ home, ".config", "xaq", "history.jsonl" }) catch return;
    defer gpa.free(path);
    if (path.len > history_path_buffer.len) return;
    @memcpy(history_path_buffer[0..path.len], path);
    history_path_len = path.len;
    history_io = io;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        else => {
            if (err != error.FileNotFound) history_io = null;
            return;
        },
    };
    defer gpa.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch continue;
        defer parsed.deinit();
        switch (parsed.value) {
            .string => |text| pushInMemory(gpa, text),
            else => {},
        }
    }
    // Rewrite compacted so the file stays near the in-memory cap.
    compactHistoryFile(gpa) catch {};
}

fn historyPath() ?[]const u8 {
    if (history_io == null or history_path_len == 0) return null;
    return history_path_buffer[0..history_path_len];
}

fn compactHistoryFile(gpa: std.mem.Allocator) !void {
    const io = history_io orelse return;
    const path = historyPath() orelse return;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (history_items[0..history_count]) |item| {
        try std.json.Stringify.value(item, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = out.written(),
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
}

fn appendHistoryFile(gpa: std.mem.Allocator, line: []const u8) !void {
    const io = history_io orelse return;
    const path = historyPath() orelse return;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(line, .{}, &out.writer);
    try out.writer.writeByte('\n');
    var file = try Io.Dir.cwd().createFile(io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(io);
    const stat = try file.stat(io);
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buffer);
    try writer.seekTo(stat.size);
    try writer.interface.writeAll(out.written());
    try writer.interface.flush();
}

fn historyPush(gpa: std.mem.Allocator, line: []const u8) void {
    if (line.len == 0) return;
    // Never persist an API key if someone supplies it as an accidental
    // `/firecrawl KEY` argument instead of using the hidden setup prompt.
    if (std.mem.startsWith(u8, line, "/firecrawl ")) return;
    if (history_count > 0 and std.mem.eql(u8, history_items[history_count - 1], line)) return;
    if (line.len > history_bytes_max) return;
    pushInMemory(gpa, line);
    appendHistoryFile(gpa, line) catch {};
}

fn pushInMemory(gpa: std.mem.Allocator, line: []const u8) void {
    if (line.len == 0) return;
    if (history_count > 0 and std.mem.eql(u8, history_items[history_count - 1], line)) return;
    if (line.len > history_bytes_max) return;
    const copy = gpa.dupe(u8, line) catch return;
    while (history_count > 0 and (history_count == history_max or history_bytes + line.len > history_bytes_max)) {
        history_bytes -= history_items[0].len;
        gpa.free(history_items[0]);
        std.mem.copyForwards([]const u8, history_items[0 .. history_count - 1], history_items[1..history_count]);
        history_count -= 1;
    }
    history_items[history_count] = copy;
    history_count += 1;
    history_bytes += copy.len;
}

fn historyClear(gpa: std.mem.Allocator) void {
    for (history_items[0..history_count]) |item| gpa.free(item);
    history_count = 0;
    history_bytes = 0;
}

fn takeByteOrNull(reader: *Io.Reader) !?u8 {
    var retries: usize = 0;
    while (true) {
        return reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => {
                // A signal-interrupted read (EINTR) recovers on retry; a
                // genuinely dead stdin ends the session cleanly instead
                // of crashing out with a trace.
                retries += 1;
                if (retries >= 3) return null;
                continue;
            },
        };
    }
}

const InputEvent = union(enum) {
    byte: u8,
    resize,
    end,
};

const ResizeWait = struct {
    size: ?term.WindowSize,

    fn init() ResizeWait {
        return .{ .size = term.windowSizeRaw() };
    }

    fn sameSize(a: ?term.WindowSize, b: ?term.WindowSize) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.?.rows == b.?.rows and a.?.cols == b.?.cols;
    }

    /// Polling gives resize-only activity a foreground wakeup without ever
    /// drawing from a signal handler. The SIGWINCH worker handles silent
    /// provider and tool waits; input owns its line contents and redraws here.
    fn next(self: *ResizeWait, reader: *Io.Reader) !InputEvent {
        if (!interactive) return if (try takeByteOrNull(reader)) |byte| .{ .byte = byte } else .end;
        while (true) {
            if (reader.bufferedLen() > 0) return .{ .byte = (try takeByteOrNull(reader)).? };
            var descriptors = [_]std.posix.pollfd{.{
                .fd = Io.File.stdin().handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            }};
            if (try std.posix.poll(&descriptors, 100) > 0) {
                return if (try takeByteOrNull(reader)) |byte| .{ .byte = byte } else .end;
            }
            const next_size = term.windowSizeRaw();
            if (!sameSize(self.size, next_size)) {
                self.size = next_size;
                _ = tui.checkResize();
                return .resize;
            }
        }
    }
};

pub const EchoGuard = struct {
    fd: std.posix.fd_t,
    saved: std.posix.termios,

    pub fn restore(self: EchoGuard) void {
        std.posix.tcsetattr(self.fd, .NOW, self.saved) catch {};
    }
};

/// Keep the terminal from echoing type-ahead (arrow keys, stray input)
/// while the agent is busy between prompts; without this the tty prints
/// `^[[A`-style junk into the streamed answer. Queued printable input is
/// re-echoed by the editor once the next prompt appears.
var echo_saved: ?std.posix.termios = null;
var echo_fd: std.posix.fd_t = 0;

pub fn muteEcho() ?EchoGuard {
    if (!interactive) return null;
    const fd = Io.File.stdin().handle;
    const saved = std.posix.tcgetattr(fd) catch return null;
    var quiet = saved;
    quiet.lflag.ECHO = false;
    std.posix.tcsetattr(fd, .NOW, quiet) catch return null;
    echo_saved = saved;
    echo_fd = fd;
    return .{ .fd = fd, .saved = saved };
}

/// Idempotent terminal restore for `process.exit` paths, which skip the
/// EchoGuard defer. Leaving echo off would corrupt the parent shell.
pub fn restoreEcho() void {
    const saved = echo_saved orelse return;
    std.posix.tcsetattr(echo_fd, .NOW, saved) catch {};
}

const RawMode = struct {
    fd: std.posix.fd_t,
    saved: std.posix.termios,

    fn enter() !RawMode {
        const fd = Io.File.stdin().handle;
        const saved = try std.posix.tcgetattr(fd);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .NOW, raw);
        return .{ .fd = fd, .saved = saved };
    }

    fn exit(self: RawMode) void {
        std.posix.tcsetattr(self.fd, .NOW, self.saved) catch {};
    }
};

test "popup follows a short slash word only" {
    try std.testing.expect(popupActive("/"));
    try std.testing.expect(popupActive("/mo"));
    try std.testing.expect(!popupActive(""));
    try std.testing.expect(!popupActive("hello"));
    try std.testing.expect(!popupActive("/model x"));
    try std.testing.expect(!popupActive("/" ++ "a" ** popup_line_max));
}

test "suggestion matching walks names and aliases in order" {
    const specs = [_]Suggestion{
        .{ .name = "help", .help = "" },
        .{ .name = "model", .help = "" },
        .{ .name = "clear", .alias = "new", .help = "" },
    };
    try std.testing.expectEqual(3, countMatches(&specs, ""));
    try std.testing.expectEqual(1, countMatches(&specs, "m"));
    try std.testing.expectEqual(1, countMatches(&specs, "new"));
    try std.testing.expectEqualStrings("model", nthMatch(&specs, "", 1).?.name);
    try std.testing.expectEqualStrings("clear", nthMatch(&specs, "n", 0).?.name);
    try std.testing.expectEqual(null, nthMatch(&specs, "z", 0));
}

test "fill writes the command word" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try fill(std.testing.allocator, &buffer, "model", true);
    try std.testing.expectEqualStrings("/model ", buffer.items);
    try fill(std.testing.allocator, &buffer, "exit", false);
    try std.testing.expectEqualStrings("/exit", buffer.items);
}

test "bracketed paste grows beyond the old editor buffer and inserts once" {
    const paste_len = 64 * 1024;
    const terminator = "\x1b[201~";
    const source = try std.testing.allocator.alloc(u8, paste_len + terminator.len);
    defer std.testing.allocator.free(source);
    @memset(source[0..paste_len], 'x');
    @memcpy(source[paste_len..], terminator);
    var reader = Io.Reader.fixed(source);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try buffer.appendSlice(std.testing.allocator, "tail");
    var cursor: usize = 0;

    try std.testing.expect(try pasteInto(std.testing.allocator, &buffer, &cursor, &reader));
    try std.testing.expectEqual(paste_len, cursor);
    try std.testing.expectEqual(paste_len + "tail".len, buffer.items.len);
    try std.testing.expectEqualStrings("tail", buffer.items[paste_len..]);
}

test "bracketed paste normalizes line endings and control bytes" {
    var reader = Io.Reader.fixed("a\r\nb\tc\x01\x1b[201~");
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var cursor: usize = 0;

    try std.testing.expect(try pasteInto(std.testing.allocator, &buffer, &cursor, &reader));
    try std.testing.expectEqualStrings("a\nb c", buffer.items);
}

test "bracketed paste consumes excess input and reports the hard limit" {
    const source = "abcd\x1b[201~";
    var reader = Io.Reader.fixed(source);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try buffer.resize(std.testing.allocator, max_input_bytes - 2);
    @memset(buffer.items, 'z');
    var cursor = buffer.items.len;

    try std.testing.expect(!try pasteInto(std.testing.allocator, &buffer, &cursor, &reader));
    try std.testing.expectEqual(max_input_bytes, buffer.items.len);
    try std.testing.expectEqualStrings("ab", buffer.items[buffer.items.len - 2 ..]);
    try std.testing.expectEqual(source.len, reader.seek);
}

test "large submitted prompts use a compact terminal echo" {
    var storage: [128]u8 = undefined;
    var output: Io.Writer = .fixed(&storage);
    try writeSubmittedVisible(&output, "x" ** (full_echo_max + 1));
    try std.testing.expectEqualStrings("[prompt: 4097 bytes, 1 line]", output.buffered());

    var multiline_storage: [128]u8 = undefined;
    var multiline: Io.Writer = .fixed(&multiline_storage);
    try writeSubmittedVisible(&multiline, ("x" ** full_echo_max) ++ "\n");
    try std.testing.expectEqualStrings("[prompt: 4097 bytes, 1 line]", multiline.buffered());
}

test "window start keeps the cursor visible" {
    try std.testing.expectEqual(0, windowStart(10, 5, 20));
    try std.testing.expectEqual(0, windowStart(100, 20, 40));
    try std.testing.expectEqual(60, windowStart(100, 100, 40));
    try std.testing.expectEqual(10, windowStart(100, 50, 40));
    try std.testing.expectEqual(0, windowStart(100, 50, 0));
}

test "byteAtColumn walks code points" {
    const text = "a\u{e9}b";
    try std.testing.expectEqual(0, byteAtColumn(text, 0));
    try std.testing.expectEqual(1, byteAtColumn(text, 1));
    try std.testing.expectEqual(3, byteAtColumn(text, 2));
    try std.testing.expectEqual(4, byteAtColumn(text, 3));
    try std.testing.expectEqual(4, byteAtColumn(text, 9));
}

test "columns are display-width aware" {
    try std.testing.expectEqual(4, columns("\u{4e2d}\u{6587}")); // 中文: two wide chars
    try std.testing.expectEqual(3, byteAtColumn("\u{4e2d}\u{6587}", 1)); // mid-char snaps forward
    try std.testing.expectEqual(3, byteAtColumn("\u{4e2d}a", 2));
}

test "editor window never exceeds odd budgets with wide text" {
    const text = "\u{4e2d}" ** 17;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const rendered = try writeWindow(&output.writer, text, columns(text), 31);
    try std.testing.expect(rendered.used <= 31);
    try std.testing.expect(rendered.cursor < 31);

    var zero: Io.Writer.Allocating = .init(std.testing.allocator);
    defer zero.deinit();
    const hidden = try writeWindow(&zero.writer, text, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), hidden.used);
    try std.testing.expectEqualStrings("", zero.written());
}

test "word boundaries for ctrl-w and alt-b/f" {
    try std.testing.expectEqual(4, prevWord("one two", 7));
    try std.testing.expectEqual(0, prevWord("one two", 4));
    try std.testing.expectEqual(0, prevWord("one", 0));
    try std.testing.expectEqual(3, nextWord("one two", 0));
    try std.testing.expectEqual(7, nextWord("one two", 3));
    try std.testing.expectEqual(7, nextWord("one two", 7));
}

test "utf-8 boundaries and columns" {
    const text = "a\u{e9}b"; // 'a', two-byte 'é', 'b'
    try std.testing.expectEqual(3, columns(text));
    try std.testing.expectEqual(1, prevBoundary(text, 3));
    try std.testing.expectEqual(3, nextBoundary(text, 1));
    try std.testing.expectEqual(0, prevBoundary(text, 0));
    try std.testing.expectEqual(4, nextBoundary(text, 3));

    const emoji = "a👩‍💻b";
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(emoji, 12));
    try std.testing.expectEqual(@as(usize, 12), nextBoundary(emoji, 1));
}

test "history stores, dedupes, and caps" {
    const gpa = std.testing.allocator;
    defer historyClear(gpa);
    historyPush(gpa, "one");
    historyPush(gpa, "one");
    historyPush(gpa, "two");
    try std.testing.expectEqual(2, history_count);
    try std.testing.expectEqualStrings("one", history_items[0]);
    try std.testing.expectEqualStrings("two", history_items[1]);
    historyPush(gpa, "");
    try std.testing.expectEqual(2, history_count);
    var i: usize = 0;
    while (i < history_max + 8) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        historyPush(gpa, std.fmt.bufPrint(&name_buf, "line-{d}", .{i}) catch unreachable);
    }
    try std.testing.expectEqual(history_max, history_count);
}

test "odd trailing backslash continues" {
    try std.testing.expect(continues("one\\"));
    try std.testing.expect(!continues("one\\\\"));
    try std.testing.expect(!continues("one"));
}
