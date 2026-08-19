//! Interactive terminal input: a raw-mode line editor with live slash-command
//! and project-path popups, plus a small list picker for choices such as the
//! model switcher. The editor can draw inline or in the fullscreen input box.
//! When stdin is not a terminal every call falls back to plain line reads, so
//! pipes and scripts behave exactly as before.
//!
//! Editing covers insert and delete at a movable cursor (left/right,
//! home/end, ctrl-a/e, alt-b/f by word), ctrl-u kills to line start,
//! ctrl-k kills to line end, ctrl-w and alt-backspace delete the
//! previous word, ctrl-c abandons the line (and pressed twice on an
//! empty line, ends the session), ctrl-d on an empty line ends the
//! session. Up/down search the persistent history from the current draft,
//! and Down restores that draft after the newest match.
//! While the line is a slash command, matching commands render dimmed
//! below the cursor; up/down selects, tab completes, enter runs.
//! Arrow keys are recognized in both CSI (`ESC [ A`) and SS3
//! (`ESC O A`) encodings.

const std = @import("std");
const Io = std.Io;
const cancel = @import("cancel.zig");
const image_input = @import("image.zig");
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

pub const PathContext = struct {
    io: Io,
    cwd: []const u8,
};

const popup_line_max = 60;
/// Column where suggestion and /help descriptions start; wide enough
/// for the longest name-plus-args (`/firecrawl [status|clear]`).
pub const help_column = 28;
const popup_rows_max = 9;
const file_index_max = 4096;
const file_index_bytes_max = 512 * 1024;
const file_index_depth_max = 16;
pub const max_input_bytes = 4 * 1024 * 1024;
const full_echo_max = 4 * 1024;

pub const SubmissionKind = enum { steer, follow_up };

pub const Submission = struct {
    kind: SubmissionKind,
    text: []u8,
};

const PhysicalResult = struct {
    kind: SubmissionKind = .steer,
    text: []const u8,
};

const PhysicalOptions = struct {
    busy: bool = false,
    stop: ?*const std.atomic.Value(bool) = null,
    draft: ?*?[]u8 = null,
};

fn submissionText(text: []const u8, allow_empty: bool) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len == 0 and !allow_empty) null else trimmed;
}

/// Read one logical line, trimmed and owned by `gpa`. A trailing unescaped
/// backslash removes itself and continues on the next physical line.
/// `initial` prefills the editor (for example a cancelled prompt).
pub fn readLine(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer, suggestions: []const Suggestion, paths: ?PathContext, initial: ?[]const u8) !?[]const u8 {
    defer continuation_line = false;
    var first_result = (try physicalLine(gpa, reader, output, suggestions, paths, initial, .{})) orelse return null;
    var first = first_result.text;
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
        first_result = (try physicalLine(gpa, reader, output, suggestions, paths, null, .{})) orelse break;
        first = first_result.text;
    }
    const line = try result.toOwnedSlice();
    const trimmed_len = std.mem.trimEnd(u8, line, " \t\r\n").len;
    const trimmed = try gpa.realloc(line, trimmed_len);
    historyPush(gpa, trimmed);
    return trimmed;
}

/// Read a credential without echoing it or adding it to prompt history.
/// Bracketed paste supports API keys and OAuth callback URLs.
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
        const byte = switch (try resize_wait.next(reader, null)) {
            .byte => |byte| byte,
            .resize => {
                try drawSecret(output, label, buffer.items.len);
                continue;
            },
            .end => {
                try finishSecret(output);
                return null;
            },
            .stop => unreachable,
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
                    _ = try pasteInto(gpa, &buffer, &cursor, reader, null);
                    try drawSecret(output, label, buffer.items.len);
                }
            },
            else => if (byte >= 0x21 and byte <= 0x7e and buffer.items.len < 2048) {
                try buffer.append(gpa, byte);
                try drawSecret(output, label, buffer.items.len);
            },
        }
    }
}

fn secretPasteMode(output: *Io.Writer, enabled: bool) !void {
    if (tui.active) return tui.setPasteMode(enabled);
    const target = output;
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
        _ = try redrawTui(&.{}, &.{}, "", 0, 0, "", 0);
        tui.focusRegion();
    } else {
        try output.writeAll("\r\x1b[2K\r\n");
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
        if (line.items.len < 2048) try line.append(gpa, byte);
    }
    try output.writeByte('\n');
    try output.flush();
    return try gpa.dupe(u8, std.mem.trim(u8, line.items, " \t\r\n"));
}

fn physicalLine(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer, suggestions: []const Suggestion, paths: ?PathContext, initial: ?[]const u8, options: PhysicalOptions) !?PhysicalResult {
    if (!interactive) {
        const line = (try plainLine(gpa, reader, output)) orelse return null;
        return .{ .text = line };
    }
    const raw = RawMode.enter() catch {
        const line = (try plainLine(gpa, reader, output)) orelse return null;
        return .{ .text = line };
    };
    defer raw.exit();
    if (tui.active) tui.beginInput();
    defer if (tui.active) tui.endInput();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var files: FileIndex = .{ .gpa = gpa, .context = paths };
    defer files.deinit();
    var pasted_image_paths: std.ArrayList([]u8) = .empty;
    var preserve_clipboard_files = false;
    defer {
        for (pasted_image_paths.items) |path| {
            if (!preserve_clipboard_files) if (files.context) |context| image_input.discardClipboardTemp(context.io, path);
            gpa.free(path);
        }
        pasted_image_paths.deinit(gpa);
    }
    var cursor: usize = 0;
    var selected: usize = 0;
    var popup_rows: usize = 0;
    var pending: ?u8 = null;
    var submission_kind: SubmissionKind = .steer;
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
        try noteClipboardImagePaths(gpa, buffer.items, &pasted_image_paths);
    }

    // Bracketed paste keeps multi-line pastes from submitting line by line.
    // In fullscreen mode `output` is the buffered transcript tee, while the
    // editor draws through the chrome sink. Send terminal controls through
    // that same direct sink and flush before reading; otherwise the enable
    // sequence can sit in the tee until the first pasted newline submits.
    if (tui.active) {
        try tui.setPasteMode(true);
    } else {
        try output.writeAll("\x1b[?2004h");
        try output.flush();
    }
    defer if (tui.active) {
        tui.setPasteMode(false) catch {};
    } else {
        output.writeAll("\x1b[?2004l") catch {};
        output.flush() catch {};
    };
    popup_rows = try renderEditor(output, suggestions, &files, pasted_image_paths.items, buffer.items, selected, cursor, popup_rows);

    while (true) {
        const byte = blk: {
            if (pending) |p| {
                pending = null;
                break :blk p;
            }
            break :blk switch (try resize_wait.next(reader, options.stop)) {
                .byte => |byte| byte,
                .resize => {
                    popup_rows = try renderEditor(output, suggestions, &files, pasted_image_paths.items, buffer.items, selected, cursor, popup_rows);
                    continue;
                },
                .end => {
                    try endEditor(output, popup_rows);
                    return null;
                },
                .stop => {
                    if (options.draft) |draft| {
                        discardUnusedClipboardImages(gpa, files.context, buffer.items, &pasted_image_paths);
                        draft.* = try gpa.dupe(u8, buffer.items);
                        preserve_clipboard_files = true;
                    }
                    try endEditor(output, popup_rows);
                    return null;
                },
            };
        };
        const dismissed_startup_hint = tui.dismissStartupHint();
        if (interrupt_armed and byte != 0x03) {
            // Any other key withdraws the pending exit and clears the hint.
            interrupt_armed = false;
            dirty_after_hint = true;
        }
        var dirty = dirty_after_hint or dismissed_startup_hint;
        dirty_after_hint = false;
        switch (byte) {
            '\r', '\n' => {
                const line = buffer.items;
                const chosen = if (slashPopupActive(line))
                    nthMatch(suggestions, line[1..], selected)
                else
                    null;
                if (chosen) |suggestion| {
                    try fill(gpa, &buffer, suggestion.name, false);
                    input_truncated = false;
                } else if (fileQuery(line, cursor)) |query| {
                    if (query.at) {
                        if (nthFileMatch(files.items.items, query, selected)) |path| {
                            try fillPath(gpa, &buffer, &cursor, query, path);
                            input_truncated = false;
                            selected = 0;
                            hist_pos = null;
                            popup_rows = try renderEditor(output, suggestions, &files, pasted_image_paths.items, buffer.items, selected, cursor, popup_rows);
                            continue;
                        }
                    }
                }
                const trimmed = submissionText(buffer.items, continuation_line) orelse {
                    buffer.clearRetainingCapacity();
                    discardUnusedClipboardImages(gpa, files.context, buffer.items, &pasted_image_paths);
                    input_truncated = false;
                    cursor = 0;
                    selected = 0;
                    hist_pos = null;
                    submission_kind = .steer;
                    popup_rows = try renderEditor(output, suggestions, &files, pasted_image_paths.items, buffer.items, selected, cursor, popup_rows);
                    continue;
                };
                if (options.busy) {
                    _ = try redrawTui(suggestions, &.{}, "", 0, 0, "", 0);
                } else if (tui.active) {
                    tui.closePopup();
                    _ = try redrawTui(suggestions, &.{}, "", 0, 0, "", 0);
                    tui.focusRegion();
                    // The submitted prompt echoes into the transcript as
                    // its own block, blank-line separated on both sides.
                    var displayed = try image_input.displayPlaceholders(gpa, buffer.items, buffer.items.len, pasted_image_paths.items);
                    defer displayed.deinit();
                    try output.print("\n{s}> ", .{term.dim()});
                    try writeSubmittedVisible(output, displayed.text);
                    try output.print("{s}\n\n", .{term.reset()});
                    try output.flush();
                } else {
                    try clearInlinePopup(output, popup_rows);
                    var displayed = try image_input.displayPlaceholders(gpa, buffer.items, buffer.items.len, pasted_image_paths.items);
                    defer displayed.deinit();
                    try prompt(output, displayed.text);
                    try output.writeAll("\x1b[K\r\n");
                    try output.flush();
                }
                if (input_truncated and !options.busy) {
                    try output.print("{s}[input limited to 4 MiB]{s}\n", .{ term.dim(), term.reset() });
                    try output.flush();
                }
                const submitted = try gpa.dupe(u8, trimmed);
                discardUnusedClipboardImages(gpa, files.context, buffer.items, &pasted_image_paths);
                preserve_clipboard_files = submitted.len > 0 and submitted[0] != '/' and submitted[0] != '!';
                return .{ .kind = submission_kind, .text = submitted };
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
            } else if (options.busy) {
                cancel.processToken().request();
            } else if (interrupt_armed) {
                try endEditor(output, popup_rows);
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
                    try clearInlinePopup(output, popup_rows);
                    popup_rows = 0;
                    try prompt(output, "");
                    try output.print("\x1b[K{s}ctrl-c again to exit{s}", .{ term.dim(), term.reset() });
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
                try endEditor(output, popup_rows);
                return null;
            },
            0x16 => { // ctrl-v: paste a bitmap from the desktop clipboard
                if (pasted_image_paths.items.len == image_input.max_images_per_prompt) {
                    try showClipboardHint(output, "at most 4 images");
                    continue;
                }
                const context = files.context orelse {
                    try showClipboardHint(output, "clipboard image paste unavailable");
                    continue;
                };
                insertClipboardImage(gpa, context, &buffer, &cursor, &pasted_image_paths) catch |err| {
                    switch (err) {
                        error.OutOfMemory => return err,
                        error.ImageTooLarge => try showClipboardHint(output, "clipboard image exceeds 5 MiB"),
                        error.InputTooLarge => try showClipboardHint(output, "prompt is full"),
                        else => try showClipboardHint(output, "clipboard has no readable image"),
                    }
                    continue;
                };
                selected = 0;
                hist_pos = null;
                dirty = true;
            },
            '\t' => if (slashPopupActive(buffer.items)) {
                if (nthMatch(suggestions, buffer.items[1..], selected)) |suggestion| {
                    try fill(gpa, &buffer, suggestion.name, suggestion.args.len > 0);
                    input_truncated = false;
                    cursor = buffer.items.len;
                    selected = 0;
                    hist_pos = null;
                    dirty = true;
                }
            } else if (fileQuery(buffer.items, cursor)) |query| {
                try files.ensureLoaded();
                if (nthFileMatch(files.items.items, query, selected)) |path| {
                    try fillPath(gpa, &buffer, &cursor, query, path);
                    input_truncated = false;
                    selected = 0;
                    hist_pos = null;
                    dirty = true;
                }
            },
            0x1b => {
                const second = (try takeSequenceByte(reader, options.stop)) orelse continue;
                if (options.busy and (second == '\r' or second == '\n')) {
                    submission_kind = .follow_up;
                    pending = '\n';
                    continue;
                }
                var final: u8 = 0;
                var param: usize = 0;
                if (second == '[') {
                    var param_done = false;
                    var next = (try takeSequenceByte(reader, options.stop)) orelse continue;
                    while (next < 0x40 or next > 0x7e) {
                        if (!param_done and next >= '0' and next <= '9') {
                            // Clamp: an adversarial digit run must not
                            // overflow (no CSI parameter we act on exceeds
                            // four digits).
                            if (param < 100_000) param = param * 10 + (next - '0');
                        } else {
                            param_done = true;
                        }
                        next = (try takeSequenceByte(reader, options.stop)) orelse break;
                    }
                    if (next >= 0x40 and next <= 0x7e) final = next;
                } else if (second == 'O') {
                    final = (try takeSequenceByte(reader, options.stop)) orelse 0;
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
                    'A' => if (popupHandlesArrows(popup_rows > 0, hist_pos)) {
                        if (selected > 0) {
                            selected -= 1;
                            dirty = true;
                        }
                    } else if (history_count > 0) {
                        const before = hist_pos orelse blk: {
                            _ = try load(gpa, &stash, buffer.items);
                            stash_truncated = input_truncated;
                            break :blk history_count;
                        };
                        if (previousHistoryMatch(stash.items, before)) |position| {
                            hist_pos = position;
                            _ = try load(gpa, &buffer, history_items[position]);
                            input_truncated = false;
                            cursor = buffer.items.len;
                            selected = 0;
                            dirty = true;
                        }
                    },
                    'B' => if (popupHandlesArrows(popup_rows > 0, hist_pos)) {
                        const rows = completionCount(suggestions, files.items.items, buffer.items, cursor);
                        if (rows > 0 and selected + 1 < rows) {
                            selected += 1;
                            dirty = true;
                        }
                    } else if (hist_pos) |position| {
                        if (nextHistoryMatch(stash.items, position)) |next| {
                            hist_pos = next;
                            _ = try load(gpa, &buffer, history_items[next]);
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
                            const paste_start = cursor;
                            input_truncated = !(try pasteInto(gpa, &buffer, &cursor, reader, options.stop)) or input_truncated;
                            try notePastedImagePaths(gpa, paths, buffer.items[paste_start..cursor], &pasted_image_paths);
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
            popup_rows = try renderEditor(output, suggestions, &files, pasted_image_paths.items, buffer.items, selected, cursor, popup_rows);
        }
    }
}

fn renderEditor(output: *Io.Writer, suggestions: []const Suggestion, files: *FileIndex, pasted_image_paths: []const []const u8, line: []const u8, selected: usize, cursor: usize, previous_popup_rows: usize) !usize {
    if (fileQuery(line, cursor) != null) try files.ensureLoaded();
    var displayed = try image_input.displayPlaceholders(files.gpa, line, cursor, pasted_image_paths);
    defer displayed.deinit();
    if (tui.active) {
        return redrawTui(suggestions, files.items.items, line, selected, cursor, displayed.text, displayed.cursor);
    }
    return redraw(output, suggestions, files.items.items, line, selected, cursor, displayed.text, displayed.cursor, previous_popup_rows);
}

/// Leave the editor cleanly on EOF or double ctrl-c.
fn endEditor(output: *Io.Writer, popup_rows: usize) !void {
    if (tui.active) {
        _ = try redrawTui(&.{}, &.{}, "", 0, 0, "", 0);
        tui.focusRegion();
        return;
    }
    try clearInlineBlock(output, popup_rows + 1);
    try output.writeAll("\r\n");
    try output.flush();
}

/// Fullscreen editor rendering: the input line lives in the fixed box
/// row, and the completion popup overlays the bottom of the transcript
/// region instead of drawing below the prompt.
fn redrawTui(suggestions: []const Suggestion, files: []const []const u8, line: []const u8, selected: usize, cursor: usize, displayed_line: []const u8, displayed_cursor: usize) !usize {
    var cursor_row: usize = 0;
    var cursor_col: usize = 0;
    const ready = tui.beginInputFrame();
    defer tui.endInputFrame(cursor_row, cursor_col);
    if (!ready) return 0;
    const chrome = tui.chromeSink();
    const area = tui.inputArea();
    const cursor_cols = columns(displayed_line[0..displayed_cursor]);
    const avail = area.width;
    try chrome.print("\x1b[{d};{d}H", .{ area.row, area.col });
    const hint = if (line.len == 0) tui.startupHint() else null;
    const window = if (hint) |text| hint_window: {
        try chrome.writeAll(term.dim());
        const rendered = try writeWindow(chrome, text, 0, avail);
        try chrome.writeAll(term.reset());
        break :hint_window WindowRender{ .used = rendered.used, .cursor = 0 };
    } else try writeWindow(chrome, displayed_line, cursor_cols, avail);
    var used = window.used;
    while (used < area.width) : (used += 1) try chrome.writeByte(' ');
    var shown: usize = 0;
    const matched = completionCount(suggestions, files, line, cursor);
    if (matched > 0) {
        const granted = tui.beginPopup(matched);
        // Keep the selected row visible when the popup is clamped.
        const first = if (selected >= granted) selected + 1 - granted else 0;
        var index: usize = 0;
        var row: usize = 0;
        if (slashPopupActive(line)) {
            const word = line[1..];
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
        } else if (fileQuery(line, cursor)) |query| {
            for (files) |path| {
                if (!fileMatches(path, query)) continue;
                defer index += 1;
                if (index < first) continue;
                if (row == granted) break;
                var row_buffer: [160]u8 = undefined;
                var writer: Io.Writer = .fixed(&row_buffer);
                const is_selected = index == selected;
                writer.print("{s}{s}{s}{s}{s}", .{
                    if (is_selected) term.bold() else term.dim(),
                    if (is_selected) "> " else "  ",
                    if (query.at) "@" else "",
                    path,
                    term.reset(),
                }) catch {};
                tui.popupLine(row, writer.buffered());
                row += 1;
            }
        }
        shown = granted;
    } else {
        tui.closePopup();
    }
    cursor_row = area.row;
    cursor_col = area.col + window.cursor;
    try chrome.print("\x1b[{d};{d}H", .{ cursor_row, cursor_col });
    try chrome.flush();
    return shown;
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
fn pasteInto(gpa: std.mem.Allocator, buffer: *std.ArrayList(u8), cursor: *usize, reader: *Io.Reader, stop: ?*const std.atomic.Value(bool)) !bool {
    const terminator = "\x1b[201~";
    var pasted: std.ArrayList(u8) = .empty;
    defer pasted.deinit(gpa);
    var matched: usize = 0;
    var previous: u8 = 0;
    var complete = true;
    const available = max_input_bytes - buffer.items.len;
    while (true) {
        const byte = (try takeByteStopping(reader, stop)) orelse {
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

/// Remember image paths from a bracketed paste so the editor can draw the
/// same numbered placeholders that the submitted prompt will contain.
fn notePastedImagePaths(gpa: std.mem.Allocator, paths: ?PathContext, pasted: []const u8, known: *std.ArrayList([]u8)) !void {
    const context = paths orelse return;
    if (pasted.len == 0 or known.items.len == image_input.max_images_per_prompt) return;
    try noteClipboardImagePaths(gpa, pasted, known);
    var parsed = image_input.inspectPrompt(gpa, context.io, context.cwd, try gpa.dupe(u8, pasted)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();
    for (parsed.images) |image| {
        if (pathKnown(known.items, image.name)) continue;
        if (known.items.len == image_input.max_images_per_prompt) break;
        const owned = try gpa.dupe(u8, image.name);
        errdefer gpa.free(owned);
        try known.append(gpa, owned);
    }
}

fn insertClipboardImage(gpa: std.mem.Allocator, context: PathContext, buffer: *std.ArrayList(u8), cursor: *usize, known: *std.ArrayList([]u8)) !void {
    const path = try image_input.clipboardToTemp(gpa, context.io);
    var keep_path = false;
    defer if (!keep_path) {
        image_input.discardClipboardTemp(context.io, path);
        gpa.free(path);
    };

    var token: Io.Writer.Allocating = .init(gpa);
    defer token.deinit();
    if (cursor.* > 0 and !std.ascii.isWhitespace(buffer.items[cursor.* - 1])) try token.writer.writeByte(' ');
    try token.writer.writeByte('@');
    try token.writer.writeAll(path);
    if (cursor.* == buffer.items.len or !std.ascii.isWhitespace(buffer.items[cursor.*])) try token.writer.writeByte(' ');
    if (buffer.items.len + token.written().len > max_input_bytes) return error.InputTooLarge;

    try known.append(gpa, path);
    errdefer _ = known.pop();
    try buffer.insertSlice(gpa, cursor.*, token.written());
    cursor.* += token.written().len;
    keep_path = true;
}

fn showClipboardHint(output: *Io.Writer, message: []const u8) !void {
    if (tui.active) {
        tui.showStartupHint(message);
    } else {
        try output.writeByte('\x07');
        try output.flush();
    }
}

fn pathKnown(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, candidate)) return true;
    return false;
}

const clipboard_temp_prefix = "/tmp/xaq-clipboard-";
const clipboard_temp_path_len = clipboard_temp_prefix.len + 24 + ".png".len;

fn nextClipboardImagePath(text: []const u8, offset: *usize) ?[]const u8 {
    while (std.mem.indexOfPos(u8, text, offset.*, clipboard_temp_prefix)) |start| {
        offset.* = start + 1;
        const end = start + clipboard_temp_path_len;
        if (end > text.len) return null;
        const path = text[start..end];
        const before_ok = start == 0 or std.ascii.isWhitespace(text[start - 1]) or text[start - 1] == '@' or text[start - 1] == '\'' or text[start - 1] == '"';
        const after_ok = end == text.len or std.ascii.isWhitespace(text[end]) or text[end] == '\'' or text[end] == '"';
        if (before_ok and after_ok and image_input.isClipboardTemp(path)) return path;
    }
    return null;
}

fn noteClipboardImagePaths(gpa: std.mem.Allocator, text: []const u8, known: *std.ArrayList([]u8)) !void {
    var offset: usize = 0;
    while (nextClipboardImagePath(text, &offset)) |path| {
        if (pathKnown(known.items, path)) continue;
        if (known.items.len == image_input.max_images_per_prompt) break;
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try known.append(gpa, owned);
    }
}

fn promptContainsClipboardImage(text: []const u8, candidate: []const u8) bool {
    var offset: usize = 0;
    while (nextClipboardImagePath(text, &offset)) |path| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn discardUnusedClipboardImages(gpa: std.mem.Allocator, context: ?PathContext, text: []const u8, known: *std.ArrayList([]u8)) void {
    var index: usize = 0;
    while (index < known.items.len) {
        const path = known.items[index];
        if (promptContainsClipboardImage(text, path)) {
            index += 1;
            continue;
        }
        if (context) |value| image_input.discardClipboardTemp(value.io, path);
        gpa.free(path);
        _ = known.orderedRemove(index);
    }
}

fn discardClipboardImagesInText(context: ?PathContext, text: []const u8) void {
    const value = context orelse return;
    var offset: usize = 0;
    while (nextClipboardImagePath(text, &offset)) |path| image_input.discardClipboardTemp(value.io, path);
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
/// escape, ctrl-c, or q cancels. Returns the chosen index. The drawn list is
/// erased before returning.
pub fn pick(reader: *Io.Reader, output: *Io.Writer, items: []const []const u8, initial: usize) !?usize {
    if (!interactive or items.len == 0) return null;
    const raw = RawMode.enter() catch return null;
    defer raw.exit();
    if (tui.active) tui.beginInput();
    defer if (tui.active) tui.endInput();

    var selected = @min(initial, items.len - 1);
    var drawn_rows: usize = 0;
    var resize_wait = ResizeWait.init();
    while (true) {
        if (tui.active) {
            _ = tui.checkResize();
            try drawPickOverlay(items, selected);
        } else {
            drawn_rows = try drawPickInline(output, items, selected, drawn_rows);
        }

        const byte = switch (try resize_wait.next(reader, null)) {
            .byte => |byte| byte,
            .resize => continue,
            .end => break,
            .stop => unreachable,
        };
        switch (byte) {
            '\r', '\n' => {
                try endPick(output, drawn_rows);
                return selected;
            },
            0x03, 0x04, 'q' => break,
            'k' => selected -|= 1,
            'j' => selected = @min(selected + 1, items.len - 1),
            0x1b => {
                // Escape prefixes arrow-key sequences too. Give the rest of
                // such a sequence a brief chance to arrive; a bare Escape
                // closes the picker.
                const second = (try takeByteWithin(reader, escape_sequence_timeout_ms)) orelse break;
                var final: u8 = 0;
                if (second == '[') {
                    var next = (try takeByteOrNull(reader)) orelse break;
                    while (next < 0x40 or next > 0x7e) {
                        next = (try takeByteOrNull(reader)) orelse break;
                    }
                    if (next >= 0x40 and next <= 0x7e) final = next;
                } else if (second == 'O') {
                    final = (try takeByteOrNull(reader)) orelse 0;
                } else break;
                switch (final) {
                    'A' => selected -|= 1,
                    'B' => selected = @min(selected + 1, items.len - 1),
                    else => {},
                }
            },
            else => {},
        }
    }
    try endPick(output, drawn_rows);
    return null;
}

fn drawPickInline(output: *Io.Writer, items: []const []const u8, selected: usize, previous_rows: usize) !usize {
    const granted = @min(items.len, @min(terminalHeight() -| 1, popup_rows_max));
    if (previous_rows > 0) try clearInlineBlock(output, previous_rows);
    const first = if (selected >= granted and granted > 0) selected + 1 - granted else 0;
    for (0..granted) |row| {
        if (row > 0) try output.writeAll("\r\n");
        try output.writeAll("\r\x1b[2K");
        const index = first + row;
        const style = if (index == selected) term.bold() else term.dim();
        const marker: []const u8 = if (index == selected) "\u{258c} " else "  ";
        try output.print("{s}{s}", .{ style, marker });
        try writePlainClipped(output, items[index], terminalWidth() -| 2);
        try output.writeAll(term.reset());
    }
    if (granted > 1) try output.print("\x1b[{d}A", .{granted - 1});
    if (granted > 0) try output.writeByte('\r');
    try output.flush();
    return granted;
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

fn endPick(output: *Io.Writer, drawn_rows: usize) !void {
    if (tui.active) {
        tui.closePopup();
        return;
    }
    try clearInlineBlock(output, drawn_rows);
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

const FileQuery = struct {
    start: usize,
    end: usize,
    text: []const u8,
    at: bool,
};

const FileIndex = struct {
    gpa: std.mem.Allocator,
    context: ?PathContext,
    items: std.ArrayList([]const u8) = .empty,
    bytes: usize = 0,
    loaded: bool = false,

    fn deinit(self: *FileIndex) void {
        for (self.items.items) |path| self.gpa.free(path);
        self.items.deinit(self.gpa);
    }

    fn ensureLoaded(self: *FileIndex) !void {
        if (self.loaded) return;
        self.loaded = true;
        const context_value = self.context orelse return;
        var root = Io.Dir.cwd().openDir(context_value.io, context_value.cwd, .{ .iterate = true }) catch return;
        defer root.close(context_value.io);
        try self.collect(context_value.io, root, "", 0);
    }

    fn collect(self: *FileIndex, io: Io, dir: Io.Dir, prefix: []const u8, depth: usize) anyerror!void {
        if (depth >= file_index_depth_max or self.items.items.len >= file_index_max or self.bytes >= file_index_bytes_max) return;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (self.items.items.len >= file_index_max or self.bytes >= file_index_bytes_max) return;
            const path = try std.fs.path.join(self.gpa, &.{ prefix, entry.name });
            if (entry.kind == .directory) {
                defer self.gpa.free(path);
                if (skipIndexedDirectory(entry.name)) continue;
                var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(io);
                self.collect(io, child, path, depth + 1) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {},
                };
                continue;
            }
            if (entry.kind != .file or path.len > 1024 or !indexablePath(path)) {
                self.gpa.free(path);
                continue;
            }
            if (self.bytes + path.len > file_index_bytes_max) {
                self.gpa.free(path);
                return;
            }
            try self.items.append(self.gpa, path);
            self.bytes += path.len;
        }
    }
};

fn indexablePath(path: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn skipIndexedDirectory(name: []const u8) bool {
    inline for (.{ ".git", ".zig-cache", "zig-out", "node_modules", "target", ".next" }) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

/// Locate a project path token at the cursor. `@word` searches anywhere in a
/// path. Ordinary tokens complete by prefix once they contain a slash or start
/// with a dot.
fn fileQuery(line: []const u8, cursor: usize) ?FileQuery {
    if (cursor > line.len) return null;
    var start = cursor;
    while (start > 0 and !std.ascii.isWhitespace(line[start - 1])) start -= 1;
    var end = cursor;
    while (end < line.len and !std.ascii.isWhitespace(line[end])) end += 1;
    const token = line[start..cursor];
    if (token.len == 0) return null;
    if (token[0] == '@') return .{ .start = start, .end = end, .text = token[1..], .at = true };
    if (token[0] == '/' or std.mem.indexOf(u8, token, "://") != null) return null;
    if (token[0] != '.' and std.mem.indexOfScalar(u8, token, '/') == null) return null;
    return .{ .start = start, .end = end, .text = token, .at = false };
}

fn fileMatches(path: []const u8, query: FileQuery) bool {
    if (!query.at) return std.mem.startsWith(u8, path, query.text);
    if (query.text.len == 0) return true;
    var matched: usize = 0;
    for (path) |byte| {
        if (std.ascii.toLower(byte) == std.ascii.toLower(query.text[matched])) {
            matched += 1;
            if (matched == query.text.len) return true;
        }
    }
    return false;
}

fn countFileMatches(files: []const []const u8, query: FileQuery) usize {
    var count: usize = 0;
    for (files) |path| if (fileMatches(path, query)) {
        count += 1;
    };
    return count;
}

fn nthFileMatch(files: []const []const u8, query: FileQuery, wanted: usize) ?[]const u8 {
    var index: usize = 0;
    for (files) |path| {
        if (!fileMatches(path, query)) continue;
        if (index == wanted) return path;
        index += 1;
    }
    return null;
}

fn fillPath(gpa: std.mem.Allocator, buffer: *std.ArrayList(u8), cursor: *usize, query: FileQuery, path: []const u8) !void {
    var replacement: Io.Writer.Allocating = .init(gpa);
    defer replacement.deinit();
    if (query.at) try replacement.writer.writeByte('@');
    for (path) |byte| {
        if (byte == '\\' or std.ascii.isWhitespace(byte)) try replacement.writer.writeByte('\\');
        try replacement.writer.writeByte(byte);
    }
    try replacement.writer.writeByte(' ');
    try buffer.replaceRange(gpa, query.start, query.end - query.start, replacement.written());
    cursor.* = query.start + replacement.written().len;
}

fn completionCount(suggestions: []const Suggestion, files: []const []const u8, line: []const u8, cursor: usize) usize {
    if (slashPopupActive(line)) return countMatches(suggestions, line[1..]);
    if (fileQuery(line, cursor)) |query| return countFileMatches(files, query);
    return 0;
}

/// The slash popup follows the line while a short command word is being
/// typed; a space (arguments) or a long line hides it.
fn slashPopupActive(line: []const u8) bool {
    if (line.len == 0 or line[0] != '/' or line.len > popup_line_max) return false;
    return std.mem.findAny(u8, line, " \t\n") == null;
}

/// A recalled slash command can open the completion popup. Keep its arrow
/// keys attached to history until Down returns to the saved draft.
fn popupHandlesArrows(shown: bool, history_position: ?usize) bool {
    return shown and history_position == null;
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

/// Reprint the input line, replace only the popup rows owned by the editor,
/// and park the cursor within the line. Content below that block is untouched.
/// Lines wider than the terminal use a scrolling window around the cursor.
fn redraw(output: *Io.Writer, suggestions: []const Suggestion, files: []const []const u8, line: []const u8, selected: usize, cursor: usize, displayed_line: []const u8, displayed_cursor: usize, previous_popup_rows: usize) !usize {
    const cursor_cols = columns(displayed_line[0..displayed_cursor]);
    const avail = terminalWidth() -| 4;

    if (continuation_line) {
        try output.print("\r\x1b[2K{s}\u{21b3}{s}", .{ term.dim(), term.reset() });
    } else {
        try output.print("\r\x1b[2K{s}\u{258c}{s}", .{ term.bold(), term.reset() });
    }
    const window = try writeWindow(output, displayed_line, cursor_cols, avail);
    var rows: usize = 0;
    const matched = completionCount(suggestions, files, line, cursor);
    if (matched > 0) {
        // Clamp the popup so it cannot scroll a short terminal; the
        // window follows the selection like the fullscreen overlay.
        const granted = @min(matched, @min(terminalHeight() -| 2, popup_rows_max));
        const first = if (selected >= granted) selected + 1 - granted else 0;
        var index: usize = 0;
        if (slashPopupActive(line)) {
            const word = line[1..];
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
                try output.print("\r\n\x1b[2K{s}", .{style});
                try writePlainClipped(output, row_writer.buffered(), terminalWidth());
                try output.writeAll(term.reset());
                rows += 1;
            }
        } else if (fileQuery(line, cursor)) |query| {
            for (files) |path| {
                if (!fileMatches(path, query)) continue;
                defer index += 1;
                if (index < first) continue;
                if (rows == granted) break;
                const is_selected = index == selected;
                const style = if (is_selected) term.bold() else term.dim();
                const marker: []const u8 = if (is_selected) "\u{258c} " else "  ";
                try output.print("\r\n\x1b[2K{s}{s}{s}", .{ style, marker, if (query.at) "@" else "" });
                try writePlainClipped(output, path, terminalWidth() -| 3);
                try output.writeAll(term.reset());
                rows += 1;
            }
        }
    }
    var stale = rows;
    while (stale < previous_popup_rows) : (stale += 1) try output.writeAll("\r\n\x1b[2K");
    const occupied = @max(rows, previous_popup_rows);
    if (occupied > 0) try output.print("\x1b[{d}A", .{occupied});
    try output.print("\r\x1b[{d}C", .{1 + window.cursor});
    try output.flush();
    return rows;
}

/// Clear an inline block starting at the cursor's row and return to its first
/// row. This is used for temporary picker lists and editor shutdown.
fn clearInlineBlock(output: *Io.Writer, rows: usize) !void {
    for (0..rows) |row| {
        if (row > 0) try output.writeAll("\r\n");
        try output.writeAll("\r\x1b[2K");
    }
    if (rows > 1) try output.print("\x1b[{d}A", .{rows - 1});
    if (rows > 0) try output.writeByte('\r');
}

/// Clear popup rows below the prompt and return to the prompt row.
fn clearInlinePopup(output: *Io.Writer, rows: usize) !void {
    for (0..rows) |_| try output.writeAll("\r\n\x1b[2K");
    if (rows > 0) try output.print("\x1b[{d}A\r", .{rows});
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
    if (term.windowSizeRaw()) |size| return usableDimension(size.cols, 80);
    return 80;
}

fn terminalHeight() usize {
    if (term.windowSizeRaw()) |size| return usableDimension(size.rows, 24);
    return 24;
}

fn usableDimension(measured: u16, fallback: usize) usize {
    return if (measured == 0) fallback else measured;
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

fn previousHistoryMatch(prefix: []const u8, before: usize) ?usize {
    var index = @min(before, history_count);
    while (index > 0) {
        index -= 1;
        if (std.mem.startsWith(u8, history_items[index], prefix)) return index;
    }
    return null;
}

fn nextHistoryMatch(prefix: []const u8, after: usize) ?usize {
    var index = after + 1;
    while (index < history_count) : (index += 1) {
        if (std.mem.startsWith(u8, history_items[index], prefix)) return index;
    }
    return null;
}

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

const escape_sequence_timeout_ms = 40;

fn takeByteWithin(reader: *Io.Reader, timeout_ms: i32) !?u8 {
    if (reader.bufferedLen() > 0) return try takeByteOrNull(reader);
    var descriptors = [_]std.posix.pollfd{.{
        .fd = Io.File.stdin().handle,
        .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    if (try std.posix.poll(&descriptors, timeout_ms) == 0) return null;
    return try takeByteOrNull(reader);
}

fn takeSequenceByte(reader: *Io.Reader, stop: ?*const std.atomic.Value(bool)) !?u8 {
    if (stop) |flag| if (flag.load(.acquire)) return null;
    if (!interactive) return takeByteOrNull(reader);
    return takeByteWithin(reader, escape_sequence_timeout_ms);
}

/// Bracketed paste can legitimately arrive in chunks, so it has no short
/// escape timeout. Polling still gives BusyInput.stop() a bounded wakeup and
/// distinguishes an open-but-idle terminal from EOF.
fn takeByteStopping(reader: *Io.Reader, stop: ?*const std.atomic.Value(bool)) !?u8 {
    const flag = stop orelse return takeByteOrNull(reader);
    if (!interactive) {
        if (flag.load(.acquire)) return null;
        return takeByteOrNull(reader);
    }
    while (true) {
        if (flag.load(.acquire)) return null;
        if (reader.bufferedLen() > 0) return takeByteOrNull(reader);
        var descriptors = [_]std.posix.pollfd{.{
            .fd = Io.File.stdin().handle,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        }};
        if (try std.posix.poll(&descriptors, 100) == 0) continue;
        return takeByteOrNull(reader);
    }
}

const InputEvent = union(enum) {
    byte: u8,
    resize,
    end,
    stop,
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
    fn next(self: *ResizeWait, reader: *Io.Reader, stop: ?*const std.atomic.Value(bool)) !InputEvent {
        if (!interactive) return if (try takeByteOrNull(reader)) |byte| .{ .byte = byte } else .end;
        while (true) {
            if (stop) |flag| if (flag.load(.acquire)) return .stop;
            if (reader.bufferedLen() > 0) return .{ .byte = (try takeByteOrNull(reader)).? };
            var descriptors = [_]std.posix.pollfd{.{
                .fd = Io.File.stdin().handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            }};
            if (try std.posix.poll(&descriptors, 100) > 0) {
                return if (try takeByteOrNull(reader)) |byte| .{ .byte = byte } else .end;
            }
            if (tui.expireStartupHint()) return .resize;
            const next_size = term.windowSizeRaw();
            if (!sameSize(self.size, next_size)) {
                self.size = next_size;
                _ = tui.checkResize();
                return .resize;
            }
        }
    }
};

/// Owns the terminal editor while an interactive exchange is running. The
/// agent thread only drains completed lines at protocol-safe boundaries; it
/// never reads a buffer that the editor is still mutating.
pub const BusyInput = struct {
    gpa: std.mem.Allocator,
    io: Io,
    reader: *Io.Reader,
    output: *Io.Writer,
    suggestions: []const Suggestion,
    paths: ?PathContext,
    mutex: Io.Mutex = .init,
    steering: std.ArrayList([]u8) = .empty,
    follow_ups: std.ArrayList([]u8) = .empty,
    draft: ?[]u8 = null,
    failure: ?anyerror = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    eof_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    future: ?Io.Future(void) = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, reader: *Io.Reader, output: *Io.Writer, suggestions: []const Suggestion, paths: ?PathContext) BusyInput {
        return .{
            .gpa = gpa,
            .io = io,
            .reader = reader,
            .output = output,
            .suggestions = suggestions,
            .paths = paths,
        };
    }

    pub fn deinit(self: *BusyInput) void {
        self.stop() catch {};
        for (self.steering.items) |line| {
            discardClipboardImagesInText(self.paths, line);
            self.gpa.free(line);
        }
        for (self.follow_ups.items) |line| {
            discardClipboardImagesInText(self.paths, line);
            self.gpa.free(line);
        }
        self.steering.deinit(self.gpa);
        self.follow_ups.deinit(self.gpa);
        if (self.draft) |draft| {
            discardClipboardImagesInText(self.paths, draft);
            self.gpa.free(draft);
        }
        tui.noteQueue(0, 0);
    }

    pub fn start(self: *BusyInput) !void {
        if (self.future != null or self.eof_flag.load(.acquire)) return;
        self.stop_flag.store(false, .release);
        self.failure = null;
        self.future = try self.io.concurrent(busyLoop, .{self});
    }

    pub fn stop(self: *BusyInput) !void {
        self.stop_flag.store(true, .release);
        var future = self.future orelse return;
        self.future = null;
        future.await(self.io);
        if (self.failure) |err| {
            self.failure = null;
            return err;
        }
    }

    pub fn take(self: *BusyInput, kind: SubmissionKind) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        const line = switch (kind) {
            .steer => if (self.steering.items.len > 0) self.steering.orderedRemove(0) else null,
            .follow_up => if (self.follow_ups.items.len > 0) self.follow_ups.orderedRemove(0) else null,
        };
        const steering_count = self.steering.items.len;
        const follow_up_count = self.follow_ups.items.len;
        self.mutex.unlock(self.io);
        tui.noteQueue(steering_count, follow_up_count);
        return line;
    }

    pub fn takeDraft(self: *BusyInput) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.draft;
        self.draft = null;
        return result;
    }

    pub fn ended(self: *const BusyInput) bool {
        return self.eof_flag.load(.acquire);
    }

    fn busyLoop(self: *BusyInput) void {
        while (!self.stop_flag.load(.acquire)) {
            var stopped_draft: ?[]u8 = null;
            const initial = self.takeDraft();
            const result = physicalLine(self.gpa, self.reader, self.output, self.suggestions, self.paths, initial, .{
                .busy = true,
                .stop = &self.stop_flag,
                .draft = &stopped_draft,
            }) catch |err| {
                if (initial) |draft| self.gpa.free(draft);
                self.setFailure(err);
                return;
            };
            if (initial) |draft| self.gpa.free(draft);
            if (result) |submission| {
                if (submission.text.len == 0) {
                    self.gpa.free(submission.text);
                    continue;
                }
                historyPush(self.gpa, submission.text);
                const kind: SubmissionKind = if (submission.text[0] == '/' or submission.text[0] == '!') .follow_up else submission.kind;
                self.enqueue(kind, @constCast(submission.text)) catch |err| {
                    discardClipboardImagesInText(self.paths, submission.text);
                    self.gpa.free(submission.text);
                    self.setFailure(err);
                    return;
                };
                continue;
            }
            if (stopped_draft) |draft| self.setDraft(draft);
            if (!self.stop_flag.load(.acquire)) self.eof_flag.store(true, .release);
            return;
        }
    }

    fn enqueue(self: *BusyInput, kind: SubmissionKind, line: []u8) !void {
        self.mutex.lockUncancelable(self.io);
        switch (kind) {
            .steer => self.steering.append(self.gpa, line) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            },
            .follow_up => self.follow_ups.append(self.gpa, line) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            },
        }
        const steering_count = self.steering.items.len;
        const follow_up_count = self.follow_ups.items.len;
        self.mutex.unlock(self.io);
        tui.noteQueue(steering_count, follow_up_count);
    }

    fn setDraft(self: *BusyInput, value: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.draft) |old| {
            discardClipboardImagesInText(self.paths, old);
            self.gpa.free(old);
        }
        self.draft = value;
    }

    fn setFailure(self: *BusyInput, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.failure = err;
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
    try std.testing.expect(slashPopupActive("/"));
    try std.testing.expect(slashPopupActive("/mo"));
    try std.testing.expect(!slashPopupActive(""));
    try std.testing.expect(!slashPopupActive("hello"));
    try std.testing.expect(!slashPopupActive("/model x"));
    try std.testing.expect(!slashPopupActive("/" ++ "a" ** popup_line_max));
}

test "history navigation keeps arrows when recall opens the popup" {
    try std.testing.expect(popupHandlesArrows(true, null));
    try std.testing.expect(!popupHandlesArrows(true, 3));
    try std.testing.expect(!popupHandlesArrows(false, null));
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

test "file queries distinguish at search from path prefixes" {
    const at = fileQuery("inspect @src/ag", "inspect @src/ag".len).?;
    try std.testing.expect(at.at);
    try std.testing.expectEqualStrings("src/ag", at.text);

    const path = fileQuery("read src/agent", "read src/agent".len).?;
    try std.testing.expect(!path.at);
    try std.testing.expectEqualStrings("src/agent", path.text);
    try std.testing.expect(fileQuery("visit https://example.com", "visit https://example.com".len) == null);
    try std.testing.expect(fileQuery("ordinary", "ordinary".len) == null);

    try std.testing.expect(fileMatches("src/agent.zig", .{ .start = 0, .end = 4, .text = "agz", .at = true }));
    try std.testing.expect(!fileMatches("src/agent.zig", .{ .start = 0, .end = 3, .text = "za", .at = true }));
}

test "empty editor input does not submit" {
    try std.testing.expect(submissionText("", false) == null);
    try std.testing.expect(submissionText(" \t\r\n", false) == null);
    try std.testing.expectEqualStrings("hello", submissionText("  hello \n", false).?);
    try std.testing.expectEqualStrings("", submissionText("", true).?);
}

test "clipboard temp tracking drops paths removed from a draft" {
    const kept = "/tmp/xaq-clipboard-0123456789abcdef01234567.png";
    const removed = "/tmp/xaq-clipboard-fedcba987654321001234567.jpg";
    var known: std.ArrayList([]u8) = .empty;
    defer {
        for (known.items) |path| std.testing.allocator.free(path);
        known.deinit(std.testing.allocator);
    }

    try noteClipboardImagePaths(std.testing.allocator, "compare @" ++ kept ++ " @" ++ removed, &known);
    try std.testing.expectEqual(@as(usize, 2), known.items.len);
    discardUnusedClipboardImages(std.testing.allocator, null, "compare @" ++ kept, &known);
    try std.testing.expectEqual(@as(usize, 1), known.items.len);
    try std.testing.expectEqualStrings(kept, known.items[0]);
}

test "path completion replaces its token and escapes spaces" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try buffer.appendSlice(std.testing.allocator, "inspect @src/ag");
    var cursor = buffer.items.len;
    const query = fileQuery(buffer.items, cursor).?;

    try fillPath(std.testing.allocator, &buffer, &cursor, query, "src/agent notes.zig");

    try std.testing.expectEqualStrings("inspect @src/agent\\ notes.zig ", buffer.items);
    try std.testing.expectEqual(buffer.items.len, cursor);
}

test "file index is capped to project files and skips build caches" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root);
    const source_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "src" });
    defer std.testing.allocator.free(source_dir);
    const git_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".git" });
    defer std.testing.allocator.free(git_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, source_dir);
    try Io.Dir.cwd().createDirPath(std.testing.io, git_dir);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ source_dir, "main.zig" });
    defer std.testing.allocator.free(source_path);
    const hidden_path = try std.fs.path.join(std.testing.allocator, &.{ git_dir, "config" });
    defer std.testing.allocator.free(hidden_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source_path, .data = "pub fn main() void {}" });
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hidden_path, .data = "secret" });

    var index: FileIndex = .{ .gpa = std.testing.allocator, .context = .{ .io = std.testing.io, .cwd = root } };
    defer index.deinit();
    try index.ensureLoaded();

    try std.testing.expect(indexedPath(index.items.items, "src/main.zig"));
    try std.testing.expect(!indexedPath(index.items.items, ".git/config"));
}

fn indexedPath(paths: []const []const u8, wanted: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, wanted)) return true;
    return false;
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

    try std.testing.expect(try pasteInto(std.testing.allocator, &buffer, &cursor, &reader, null));
    try std.testing.expectEqual(paste_len, cursor);
    try std.testing.expectEqual(paste_len + "tail".len, buffer.items.len);
    try std.testing.expectEqualStrings("tail", buffer.items[paste_len..]);
}

test "bracketed paste normalizes line endings and control bytes" {
    var reader = Io.Reader.fixed("a\r\nb\tc\x01\x1b[201~");
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var cursor: usize = 0;

    try std.testing.expect(try pasteInto(std.testing.allocator, &buffer, &cursor, &reader, null));
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

    try std.testing.expect(!try pasteInto(std.testing.allocator, &buffer, &cursor, &reader, null));
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

test "inline dimensions reject zero-valued tty measurements" {
    try std.testing.expectEqual(@as(usize, 80), usableDimension(0, 80));
    try std.testing.expectEqual(@as(usize, 24), usableDimension(0, 24));
    try std.testing.expectEqual(@as(usize, 132), usableDimension(132, 80));
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

test "inline cleanup erases only its temporary rows" {
    var block_storage: [64]u8 = undefined;
    var block: Io.Writer = .fixed(&block_storage);
    try clearInlineBlock(&block, 3);
    try std.testing.expectEqualStrings("\r\x1b[2K\r\n\r\x1b[2K\r\n\r\x1b[2K\x1b[2A\r", block.buffered());
    try std.testing.expect(std.mem.indexOf(u8, block.buffered(), "\x1b[J") == null);

    var popup_storage: [64]u8 = undefined;
    var popup: Io.Writer = .fixed(&popup_storage);
    try clearInlinePopup(&popup, 2);
    try std.testing.expectEqualStrings("\r\n\x1b[2K\r\n\x1b[2K\x1b[2A\r", popup.buffered());
    try std.testing.expect(std.mem.indexOf(u8, popup.buffered(), "\x1b[J") == null);
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

test "history navigation filters by draft and moves in both directions" {
    const gpa = std.testing.allocator;
    defer historyClear(gpa);
    historyPush(gpa, "build");
    historyPush(gpa, "test input");
    historyPush(gpa, "build release");
    historyPush(gpa, "status");

    try std.testing.expectEqual(@as(?usize, 2), previousHistoryMatch("build", history_count));
    try std.testing.expectEqual(@as(?usize, 0), previousHistoryMatch("build", 2));
    try std.testing.expectEqual(@as(?usize, null), previousHistoryMatch("missing", history_count));
    try std.testing.expectEqual(@as(?usize, 2), nextHistoryMatch("build", 0));
    try std.testing.expectEqual(@as(?usize, null), nextHistoryMatch("build", 2));
    try std.testing.expectEqual(@as(?usize, 1), previousHistoryMatch("", 2));
}

test "odd trailing backslash continues" {
    try std.testing.expect(continues("one\\"));
    try std.testing.expect(!continues("one\\\\"));
    try std.testing.expect(!continues("one"));
}

test "busy input keeps steering and follow-ups in separate FIFO queues" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var reader = Io.Reader.fixed("");
    var output_storage: [1]u8 = undefined;
    var output: Io.Writer = .fixed(&output_storage);
    var busy = BusyInput.init(gpa, io, &reader, &output, &.{}, null);
    defer busy.deinit();

    try busy.enqueue(.steer, try gpa.dupe(u8, "first"));
    try busy.enqueue(.follow_up, try gpa.dupe(u8, "later"));
    try busy.enqueue(.steer, try gpa.dupe(u8, "second"));

    const first = busy.take(.steer).?;
    defer gpa.free(first);
    const second = busy.take(.steer).?;
    defer gpa.free(second);
    const later = busy.take(.follow_up).?;
    defer gpa.free(later);
    try std.testing.expectEqualStrings("first", first);
    try std.testing.expectEqualStrings("second", second);
    try std.testing.expectEqualStrings("later", later);
    try std.testing.expect(busy.take(.steer) == null);
    try std.testing.expect(busy.take(.follow_up) == null);
}

test "busy escape and paste continuations honor stop requests" {
    var stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
    var reader = Io.Reader.fixed("unread");
    try std.testing.expectEqual(@as(?u8, null), try takeSequenceByte(&reader, &stop));

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var cursor: usize = 0;
    try std.testing.expect(try pasteInto(std.testing.allocator, &buffer, &cursor, &reader, &stop));
    try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), cursor);
}
