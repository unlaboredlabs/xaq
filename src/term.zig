//! Minimal ANSI capabilities for terminal chrome and rendered markdown.
//! Styling is enabled only for capable terminals and honors NO_COLOR and
//! TERM=dumb. When disabled every helper returns an empty string, so call
//! sites stay branch-free.

const std = @import("std");
const Io = std.Io;

pub const WindowSize = struct { rows: u16, cols: u16 };

/// Query the terminal size of stdout. A successful ioctl may report zero
/// during PTY setup or teardown; callers that manage fullscreen state need
/// to distinguish that from an ioctl failure.
pub fn windowSizeRaw() ?WindowSize {
    var window: std.posix.winsize = undefined;
    const fd = Io.File.stdout().handle;
    if (@import("builtin").os.tag == .linux) {
        const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&window));
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
    } else {
        if (std.c.ioctl(fd, @as(c_int, @intCast(std.c.T.IOCGWINSZ)), &window) != 0) return null;
    }
    return .{ .rows = window.row, .cols = window.col };
}

/// Query a usable terminal size. Inline callers retain their conservative
/// fallback when a PTY temporarily reports a zero dimension.
pub fn windowSize() ?WindowSize {
    const size = windowSizeRaw() orelse return null;
    if (size.rows == 0 or size.cols == 0) return null;
    return size;
}

/// Display width of a code point: 0 for combining marks and other
/// zero-width characters, 2 for East Asian wide characters and emoji,
/// otherwise 1. Covers the common ranges, not the full Unicode tables.
pub fn codePointWidth(cp: u21) u2 {
    if (cp == 0x200b or cp == 0x200c or cp == 0x200d or cp == 0xfeff) return 0;
    if (cp >= 0x1f3fb and cp <= 0x1f3ff) return 0; // emoji skin-tone modifiers
    if ((cp >= 0x0300 and cp <= 0x036f) or // combining diacritics
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe00 and cp <= 0xfe0f) or // variation selectors
        (cp >= 0xfe20 and cp <= 0xfe2f)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or // Hangul jamo
        (cp >= 0x2e80 and cp <= 0x303e) or // CJK radicals and punctuation
        (cp >= 0x3041 and cp <= 0x33ff) or // kana through CJK compatibility
        (cp >= 0x3400 and cp <= 0x4dbf) or
        (cp >= 0x4e00 and cp <= 0x9fff) or // unified ideographs
        (cp >= 0xa000 and cp <= 0xa4cf) or
        (cp >= 0xac00 and cp <= 0xd7a3) or // Hangul syllables
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe30 and cp <= 0xfe4f) or
        (cp >= 0xff00 and cp <= 0xff60) or // fullwidth forms
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f1e6 and cp <= 0x1f1ff) or // regional indicators
        (cp >= 0x1f300 and cp <= 0x1f64f) or // emoji
        (cp >= 0x1f680 and cp <= 0x1f6ff) or
        (cp >= 0x1f900 and cp <= 0x1f9ff) or
        (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

pub const Cell = struct { end: usize, width: usize };

fn decodedAt(text: []const u8, start: usize) struct { end: usize, cp: ?u21 } {
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch return .{ .end = start + 1, .cp = null };
    const end = @min(start + len, text.len);
    if (end - start != len) return .{ .end = start + 1, .cp = null };
    return .{ .end = end, .cp = std.unicode.utf8Decode(text[start..end]) catch null };
}

fn isRegional(cp: u21) bool {
    return cp >= 0x1f1e6 and cp <= 0x1f1ff;
}

fn isClusterExtend(cp: u21) bool {
    return codePointWidth(cp) == 0 and cp != 0x200d;
}

/// Return one terminal cell cluster. This compact iterator handles the
/// sequences that most often break cursor placement: combining marks,
/// emoji modifiers, variation selectors, ZWJ emoji, and flag pairs.
pub fn nextCell(text: []const u8, start: usize) Cell {
    std.debug.assert(start < text.len);
    const first = decodedAt(text, start);
    const first_cp = first.cp orelse return .{ .end = first.end, .width = 1 };
    var end = first.end;
    var width: usize = codePointWidth(first_cp);

    if (isRegional(first_cp) and end < text.len) {
        const second = decodedAt(text, end);
        if (second.cp) |cp| if (isRegional(cp)) {
            return .{ .end = second.end, .width = 2 };
        };
    }

    while (end < text.len) {
        const next = decodedAt(text, end);
        const cp = next.cp orelse break;
        if (isClusterExtend(cp)) {
            if (cp == 0xfe0f) width = @max(width, 2);
            end = next.end;
            continue;
        }
        if (cp != 0x200d) break;

        // A trailing ZWJ is retained with the cluster. If the next code point
        // arrives in a later stream chunk, incremental rendering can extend it
        // without advancing the cursor twice.
        end = next.end;
        if (end >= text.len) break;
        const joined = decodedAt(text, end);
        const joined_cp = joined.cp orelse break;
        width = @max(width, codePointWidth(joined_cp));
        end = joined.end;
    }
    return .{ .end = end, .width = width };
}

/// Display columns of UTF-8 text. Malformed sequences count one column
/// per lead byte, matching how terminals render replacement glyphs.
pub fn displayWidth(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cell = nextCell(text, i);
        count += cell.width;
        i = cell.end;
    }
    return count;
}

pub var enabled = false;
/// True when stdout is a capable terminal, even when NO_COLOR disables ANSI
/// styles. Markdown uses this to keep structural rendering available without
/// color.
pub var presentation = false;

pub fn detect(is_tty: bool, no_color: ?[]const u8, term_name: ?[]const u8) void {
    presentation = is_tty;
    if (term_name) |value| if (std.mem.eql(u8, value, "dumb")) {
        presentation = false;
    };
    enabled = presentation;
    if (no_color) |value| if (value.len > 0) {
        enabled = false;
    };
}

pub fn bold() []const u8 {
    return if (enabled) "\x1b[1m" else "";
}

pub fn dim() []const u8 {
    return if (enabled) "\x1b[2m" else "";
}

pub fn italic() []const u8 {
    return if (enabled) "\x1b[3m" else "";
}

pub fn underline() []const u8 {
    return if (enabled) "\x1b[4m" else "";
}

pub fn strikethrough() []const u8 {
    return if (enabled) "\x1b[9m" else "";
}

pub fn reset() []const u8 {
    return if (enabled) "\x1b[0m" else "";
}

/// Set the terminal window title (OSC 0); no-op when styling is disabled,
/// so pipes and dumb terminals never see the escape.
pub fn title(output: *Io.Writer, comptime format: []const u8, args: anytype) !void {
    if (!enabled) return;
    try output.print("\x1b]0;" ++ format ++ "\x07", args);
}

/// Stateful terminal-safe rendering for untrusted model text. Conversation
/// storage keeps the original bytes; only display drops ANSI/OSC sequences and
/// C0 controls other than newline, carriage return, and tab.
pub const SafeWriter = struct {
    output: *Io.Writer,
    state: enum { text, escape, csi, osc, osc_escape } = .text,

    pub fn write(self: *SafeWriter, bytes: []const u8) !void {
        for (bytes) |byte| switch (self.state) {
            .text => switch (byte) {
                0x1b => self.state = .escape,
                '\n', '\r', '\t' => try self.output.writeByte(byte),
                0x00...0x08, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
                else => try self.output.writeByte(byte),
            },
            .escape => switch (byte) {
                '[' => self.state = .csi,
                ']' => self.state = .osc,
                else => self.state = .text,
            },
            .csi => if (byte >= 0x40 and byte <= 0x7e) {
                self.state = .text;
            },
            .osc => switch (byte) {
                0x07 => self.state = .text,
                0x1b => self.state = .osc_escape,
                else => {},
            },
            .osc_escape => if (byte == '\\') {
                self.state = .text;
            } else if (byte != 0x1b) {
                self.state = .osc;
            },
        };
    }
};

test "code point widths cover zero, narrow, and wide" {
    try std.testing.expectEqual(@as(u2, 1), codePointWidth('a'));
    try std.testing.expectEqual(@as(u2, 1), codePointWidth(0xe9)); // é
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x4e2d)); // 中
    try std.testing.expectEqual(@as(u2, 2), codePointWidth(0x1f600)); // emoji
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u2, 0), codePointWidth(0x200d)); // ZWJ
}

test "display width counts columns, not code points" {
    try std.testing.expectEqual(@as(usize, 3), displayWidth("abc"));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("a\u{e9}b"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("\u{4e2d}\u{6587}")); // 中文
    try std.testing.expectEqual(@as(usize, 1), displayWidth("e\u{0301}")); // e + combining
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{2764}\u{fe0f}")); // red heart
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1f44d}\u{1f3fd}")); // emoji modifier
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1f469}\u{200d}\u{1f4bb}")); // ZWJ emoji
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1f1fa}\u{1f1f8}")); // flag pair
}

test "detect respects tty, NO_COLOR, and TERM" {
    defer {
        enabled = false;
        presentation = false;
    }
    detect(false, null, null);
    try std.testing.expect(!enabled);
    try std.testing.expect(!presentation);
    detect(true, null, null);
    try std.testing.expect(enabled);
    try std.testing.expect(presentation);
    detect(true, "1", null);
    try std.testing.expect(!enabled);
    try std.testing.expect(presentation);
    detect(true, "", null);
    try std.testing.expect(enabled);
    detect(true, null, "dumb");
    try std.testing.expect(!enabled);
    try std.testing.expect(!presentation);
    detect(true, null, "xterm-256color");
    try std.testing.expect(enabled);
}

test "title writes OSC 0 only when enabled" {
    defer enabled = false;
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    enabled = false;
    try title(&writer, "xaq \u{b7} {s}", .{"dir"});
    try std.testing.expectEqualStrings("", writer.buffered());
    enabled = true;
    try title(&writer, "xaq \u{b7} {s}", .{"dir"});
    try std.testing.expectEqualStrings("\x1b]0;xaq \u{b7} dir\x07", writer.buffered());
}

test "safe writer strips terminal control sequences across chunks" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var safe: SafeWriter = .{ .output = &output.writer };
    try safe.write("ok\x1b[31");
    try safe.write("mred\x1b[0m\n\x1b]0;title\x07done\x03");
    try std.testing.expectEqualStrings("okred\ndone", output.written());
}
