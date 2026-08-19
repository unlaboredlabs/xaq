//! Interactive terminal input: a raw-mode line editor with a live
//! slash-command popup, and a small list picker for choices such as the
//! model switcher. Inline only—drawing stays at the prompt, never a
//! fullscreen UI. When stdin is not a terminal every call falls back to
//! plain line reads, so pipes and scripts behave exactly as before.
//!
//! Editing covers insert and delete at a movable cursor (left/right,
//! home/end, ctrl-a/e), ctrl-u clears, ctrl-c abandons the line (and
//! pressed twice on an empty line, ends the session), ctrl-d on an
//! empty line ends the session. Up/down walk the in-session history.
//! While the line is a slash command, matching commands render dimmed
//! below the cursor; up/down selects, tab completes, enter runs.
//! Arrow keys are recognized in both CSI (`ESC [ A`) and SS3
//! (`ESC O A`) encodings.

const std = @import("std");
const Io = std.Io;
const term = @import("term.zig");

/// Set by main when both stdin and stdout are terminals.
pub var interactive = false;

pub const Suggestion = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    args: []const u8 = "",
    help: []const u8,
};

const popup_line_max = 60;
const help_column = 18;

/// Read one logical line, trimmed and owned by `gpa`. A trailing unescaped
/// backslash removes itself and continues on the next physical line.
/// `initial` prefills the editor (for example a cancelled prompt).
pub fn readLine(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer, suggestions: []const Suggestion, initial: ?[]const u8) !?[]const u8 {
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
        first = (try physicalLine(gpa, reader, output, suggestions, null)) orelse break;
    }
    const line = try result.toOwnedSlice();
    historyPush(gpa, line);
    return line;
}

fn physicalLine(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer, suggestions: []const Suggestion, initial: ?[]const u8) !?[]const u8 {
    if (!interactive) return plainLine(gpa, reader, output);
    const raw = RawMode.enter() catch return plainLine(gpa, reader, output);
    defer raw.exit();

    var buffer: [4096]u8 = undefined;
    var len: usize = 0;
    var cursor: usize = 0;
    var selected: usize = 0;
    var popup_shown = false;
    var pending: ?u8 = null;
    var interrupt_armed = false;
    var hist_pos: ?usize = null;
    var stash: [4096]u8 = undefined;
    var stash_len: usize = 0;

    if (initial) |text| {
        len = load(&buffer, text);
        cursor = len;
    }

    // Bracketed paste keeps multi-line pastes from submitting line by line;
    // unsupporting terminals simply never send the guards.
    try output.writeAll("\x1b[?2004h");
    defer {
        output.writeAll("\x1b[?2004l") catch {};
        output.flush() catch {};
    }
    popup_shown = try redraw(output, suggestions, buffer[0..len], selected, cursor);

    while (true) {
        const byte = blk: {
            if (pending) |p| {
                pending = null;
                break :blk p;
            }
            break :blk (try takeByteOrNull(reader)) orelse {
                try output.writeAll("\x1b[J\r\n");
                try output.flush();
                return null;
            };
        };
        if (interrupt_armed and byte != 0x03) {
            // Any other key withdraws the pending exit and clears the hint.
            interrupt_armed = false;
            try prompt(output, buffer[0..len]);
            try output.writeAll("\x1b[J");
        }
        var dirty = false;
        switch (byte) {
            '\r', '\n' => {
                const line = buffer[0..len];
                const chosen = if (popupActive(line))
                    nthMatch(suggestions, line[1..], selected)
                else
                    null;
                if (chosen) |suggestion| {
                    len = fill(&buffer, suggestion.name, false);
                }
                try prompt(output, buffer[0..len]);
                try output.writeAll("\x1b[J\r\n");
                try output.flush();
                const trimmed = std.mem.trim(u8, buffer[0..len], " \t\r\n");
                return try gpa.dupe(u8, trimmed);
            },
            0x7f, 0x08 => if (cursor > 0) {
                const previous = prevBoundary(buffer[0..len], cursor);
                std.mem.copyForwards(u8, buffer[previous..], buffer[cursor..len]);
                len -= cursor - previous;
                cursor = previous;
                selected = 0;
                hist_pos = null;
                dirty = true;
            },
            0x03 => if (len > 0) {
                len = 0;
                cursor = 0;
                selected = 0;
                hist_pos = null;
                dirty = true;
            } else if (interrupt_armed) {
                try prompt(output, "");
                try output.writeAll("\x1b[J\r\n");
                try output.flush();
                return null;
            } else {
                interrupt_armed = true;
                try prompt(output, "");
                try output.print("\x1b[J{s}ctrl-c again to exit{s}", .{ term.dim(), term.reset() });
                try output.flush();
            },
            0x15 => {
                len = 0;
                cursor = 0;
                selected = 0;
                hist_pos = null;
                dirty = true;
            },
            0x01 => {
                cursor = 0;
                dirty = true;
            },
            0x05 => {
                cursor = len;
                dirty = true;
            },
            0x04 => if (len == 0) {
                try output.writeAll("\x1b[J\r\n");
                try output.flush();
                return null;
            },
            '\t' => if (popupActive(buffer[0..len])) {
                if (nthMatch(suggestions, buffer[1..len], selected)) |suggestion| {
                    len = fill(&buffer, suggestion.name, suggestion.args.len > 0);
                    cursor = len;
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
                            param = param * 10 + (next - '0');
                        } else {
                            param_done = true;
                        }
                        next = (try takeByteOrNull(reader)) orelse break;
                    }
                    if (next >= 0x40 and next <= 0x7e) final = next;
                } else if (second == 'O') {
                    final = (try takeByteOrNull(reader)) orelse 0;
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
                            @memcpy(stash[0..len], buffer[0..len]);
                            stash_len = len;
                            hist_pos = history_count;
                        }
                        if (hist_pos.? > 0) {
                            hist_pos = hist_pos.? - 1;
                            len = load(&buffer, history_items[hist_pos.?]);
                            cursor = len;
                            selected = 0;
                            dirty = true;
                        }
                    },
                    'B' => if (popup_shown) {
                        const rows = countMatches(suggestions, buffer[1..len]);
                        if (rows > 0 and selected + 1 < rows) {
                            selected += 1;
                            dirty = true;
                        }
                    } else if (hist_pos) |position| {
                        if (position + 1 < history_count) {
                            hist_pos = position + 1;
                            len = load(&buffer, history_items[position + 1]);
                        } else {
                            hist_pos = null;
                            @memcpy(buffer[0..stash_len], stash[0..stash_len]);
                            len = stash_len;
                        }
                        cursor = len;
                        selected = 0;
                        dirty = true;
                    },
                    'C' => if (cursor < len) {
                        cursor = nextBoundary(buffer[0..len], cursor);
                        dirty = true;
                    },
                    'D' => if (cursor > 0) {
                        cursor = prevBoundary(buffer[0..len], cursor);
                        dirty = true;
                    },
                    'H' => {
                        cursor = 0;
                        dirty = true;
                    },
                    'F' => {
                        cursor = len;
                        dirty = true;
                    },
                    '~' => switch (param) {
                        1, 7 => {
                            cursor = 0;
                            dirty = true;
                        },
                        4, 8 => {
                            cursor = len;
                            dirty = true;
                        },
                        3 => if (cursor < len) {
                            const next = nextBoundary(buffer[0..len], cursor);
                            std.mem.copyForwards(u8, buffer[cursor..], buffer[next..len]);
                            len -= next - cursor;
                            selected = 0;
                            hist_pos = null;
                            dirty = true;
                        },
                        200 => {
                            try pasteInto(&buffer, &len, &cursor, reader);
                            selected = 0;
                            hist_pos = null;
                            dirty = true;
                        },
                        else => {},
                    },
                    else => {},
                }
            },
            else => if (byte >= 0x20 and len < buffer.len) {
                std.mem.copyBackwards(u8, buffer[cursor + 1 .. len + 1], buffer[cursor..len]);
                buffer[cursor] = byte;
                len += 1;
                cursor += 1;
                selected = 0;
                hist_pos = null;
                dirty = true;
            },
        }
        if (dirty) {
            popup_shown = try redraw(output, suggestions, buffer[0..len], selected, cursor);
        }
    }
}

fn load(buffer: []u8, text: []const u8) usize {
    const count = @min(text.len, buffer.len);
    @memcpy(buffer[0..count], text[0..count]);
    return count;
}

/// Consume a bracketed paste, inserting sanitized bytes at the cursor:
/// CR and CRLF become LF, other control bytes are dropped, tabs become
/// spaces. Stops at the `ESC [ 201 ~` terminator or end of input.
fn pasteInto(buffer: []u8, len: *usize, cursor: *usize, reader: *Io.Reader) !void {
    const terminator = "\x1b[201~";
    var matched: usize = 0;
    var previous: u8 = 0;
    while (true) {
        const byte = (try takeByteOrNull(reader)) orelse return;
        if (byte == terminator[matched]) {
            matched += 1;
            if (matched == terminator.len) return;
            continue;
        }
        if (matched > 0) {
            for (terminator[0..matched]) |held| insertPasteByte(buffer, len, cursor, held, &previous);
            matched = 0;
            if (byte == terminator[0]) {
                matched = 1;
                continue;
            }
        }
        insertPasteByte(buffer, len, cursor, byte, &previous);
    }
}

fn insertPasteByte(buffer: []u8, len: *usize, cursor: *usize, byte_in: u8, previous: *u8) void {
    const raw = byte_in;
    defer previous.* = raw;
    var byte = byte_in;
    if (byte == '\n' and previous.* == '\r') return; // CRLF already inserted as LF
    if (byte == '\r') byte = '\n';
    if (byte == '\t') byte = ' ';
    if ((byte < 0x20 and byte != '\n') or byte == 0x7f) return;
    if (len.* >= buffer.len) return;
    std.mem.copyBackwards(u8, buffer[cursor.* + 1 .. len.* + 1], buffer[cursor.*..len.*]);
    buffer[cursor.*] = byte;
    len.* += 1;
    cursor.* += 1;
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

    var selected = @min(initial, items.len - 1);
    while (true) {
        for (items, 0..) |item, i| {
            if (i == selected) {
                try output.print("{s}\u{258c} {s}{s}\x1b[K\r\n", .{ term.bold(), item, term.reset() });
            } else {
                try output.print("{s}  {s}{s}\x1b[K\r\n", .{ term.dim(), item, term.reset() });
            }
        }
        try output.print("\x1b[{d}A\r", .{items.len});
        try output.flush();

        const byte = (try takeByteOrNull(reader)) orelse break;
        switch (byte) {
            '\r', '\n' => {
                try output.writeAll("\x1b[J");
                try output.flush();
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
    try output.writeAll("\x1b[J");
    try output.flush();
    return null;
}

fn plainLine(gpa: std.mem.Allocator, reader: *Io.Reader, output: *Io.Writer) !?[]const u8 {
    try prompt(output, "");
    try output.flush();
    const line = (try reader.takeDelimiter('\n')) orelse {
        try output.writeByte('\n');
        try output.flush();
        return null;
    };
    return try gpa.dupe(u8, std.mem.trim(u8, line, " \t\r\n"));
}

fn prompt(output: *Io.Writer, line: []const u8) !void {
    try output.print("\r{s}\u{258c}{s}", .{ term.bold(), term.reset() });
    try writeVisible(output, line);
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

fn fill(buffer: []u8, name: []const u8, trailing_space: bool) usize {
    buffer[0] = '/';
    @memcpy(buffer[1 .. 1 + name.len], name);
    var len = 1 + name.len;
    if (trailing_space) {
        buffer[len] = ' ';
        len += 1;
    }
    return len;
}

/// Reprint the input line, clear below, draw matching commands, and park
/// the cursor at its position within the line. Lines wider than the
/// terminal render a scrolling window around the cursor, marked with an
/// ellipsis on the clipped side. Returns whether popup rows remain.
fn redraw(output: *Io.Writer, suggestions: []const Suggestion, line: []const u8, selected: usize, cursor: usize) !bool {
    const total = columns(line);
    const cursor_cols = columns(line[0..cursor]);
    const avail = terminalWidth() -| 4;
    const window_start = windowStart(total, cursor_cols, avail);

    try output.print("\r{s}\u{258c}{s}", .{ term.bold(), term.reset() });
    var cursor_screen = 1 + cursor_cols;
    if (total <= avail or avail == 0) {
        try writeVisible(output, line);
    } else {
        if (window_start > 0) try output.print("{s}\u{2026}{s}", .{ term.dim(), term.reset() });
        const start_byte = byteAtColumn(line, window_start);
        const end_byte = byteAtColumn(line, @min(total, window_start + avail));
        try writeVisible(output, line[start_byte..end_byte]);
        if (window_start + avail < total) try output.print("{s}\u{2026}{s}", .{ term.dim(), term.reset() });
        cursor_screen = 1 + @as(usize, @intFromBool(window_start > 0)) + (cursor_cols - window_start);
    }
    try output.writeAll("\x1b[J");
    var rows: usize = 0;
    if (popupActive(line)) {
        const word = line[1..];
        for (suggestions) |suggestion| {
            if (!matches(suggestion, word)) continue;
            const is_selected = rows == selected;
            const style = if (is_selected) term.bold() else term.dim();
            const marker: []const u8 = if (is_selected) "\u{258c} " else "  ";
            try output.print("\r\n{s}{s}/{s}{s}", .{ style, marker, suggestion.name, suggestion.args });
            var column = 1 + suggestion.name.len + suggestion.args.len;
            while (column < help_column) : (column += 1) try output.writeByte(' ');
            try output.print("{s}{s}", .{ suggestion.help, term.reset() });
            rows += 1;
        }
        if (rows > 0) try output.print("\x1b[{d}A", .{rows});
    }
    try output.print("\r\x1b[{d}C", .{cursor_screen});
    try output.flush();
    return rows > 0;
}

/// First visible column when the line is wider than the window: keep the
/// cursor inside, preferring to show text before it.
fn windowStart(total: usize, cursor_cols: usize, avail: usize) usize {
    if (avail == 0 or total <= avail) return 0;
    return if (cursor_cols > avail) cursor_cols - avail else 0;
}

fn byteAtColumn(line: []const u8, column: usize) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (count == column) return i;
        i = nextBoundary(line, i);
        count += 1;
    }
    return line.len;
}

fn terminalWidth() usize {
    if (@import("builtin").os.tag == .linux) {
        var window: std.posix.winsize = undefined;
        const rc = std.os.linux.ioctl(Io.File.stdout().handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&window));
        if (rc == 0 and window.col > 0) return window.col;
    }
    return 80;
}

/// Display columns before the cursor, counted as UTF-8 code points.
fn columns(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) count += 1;
    }
    return count;
}

fn prevBoundary(line: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var i = index - 1;
    while (i > 0 and line[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

fn nextBoundary(line: []const u8, index: usize) usize {
    if (index >= line.len) return line.len;
    var i = index + 1;
    while (i < line.len and line[i] & 0xc0 == 0x80) i += 1;
    return i;
}

const history_max = 64;
var history_items: [history_max][]const u8 = undefined;
var history_count: usize = 0;

fn historyPush(gpa: std.mem.Allocator, line: []const u8) void {
    if (line.len == 0) return;
    if (history_count > 0 and std.mem.eql(u8, history_items[history_count - 1], line)) return;
    const copy = gpa.dupe(u8, line) catch return;
    if (history_count == history_max) {
        gpa.free(history_items[0]);
        std.mem.copyForwards([]const u8, history_items[0 .. history_max - 1], history_items[1..history_max]);
        history_count -= 1;
    }
    history_items[history_count] = copy;
    history_count += 1;
}

fn historyClear(gpa: std.mem.Allocator) void {
    for (history_items[0..history_count]) |item| gpa.free(item);
    history_count = 0;
}

fn takeByteOrNull(reader: *Io.Reader) !?u8 {
    return reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => null,
        else => |other| other,
    };
}

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
pub fn muteEcho() ?EchoGuard {
    if (!interactive) return null;
    const fd = Io.File.stdin().handle;
    const saved = std.posix.tcgetattr(fd) catch return null;
    var quiet = saved;
    quiet.lflag.ECHO = false;
    std.posix.tcsetattr(fd, .NOW, quiet) catch return null;
    return .{ .fd = fd, .saved = saved };
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
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("/model ", buffer[0..fill(&buffer, "model", true)]);
    try std.testing.expectEqualStrings("/exit", buffer[0..fill(&buffer, "exit", false)]);
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

test "utf-8 boundaries and columns" {
    const text = "a\u{e9}b"; // 'a', two-byte 'é', 'b'
    try std.testing.expectEqual(3, columns(text));
    try std.testing.expectEqual(1, prevBoundary(text, 3));
    try std.testing.expectEqual(3, nextBoundary(text, 1));
    try std.testing.expectEqual(0, prevBoundary(text, 0));
    try std.testing.expectEqual(4, nextBoundary(text, 3));
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
