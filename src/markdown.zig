//! Streaming terminal markdown for assistant text.
//!
//! The renderer covers the constructs coding agents use most while staying
//! append-only: headings, quotes, lists, emphasis, code spans, links, and
//! fenced code. Raw markdown remains the canonical conversation text. Pipes
//! receive that raw text, filtered only for terminal control sequences.

const std = @import("std");
const Io = std.Io;
const term = @import("term.zig");

const EscapeState = enum { text, escape, csi, osc, osc_escape };
const LineState = enum { prefix, body, fence_open, code_prefix, code_body };
const LinkState = enum { none, label, after_label, url };

pub const Writer = struct {
    output: *Io.Writer,
    render: bool,
    escape_state: EscapeState = .text,
    line_state: LineState = .prefix,
    prefix: [2048]u8 = undefined,
    prefix_len: usize = 0,
    fence_char: u8 = 0,
    fence_len: usize = 0,
    heading: u8 = 0,
    quote: bool = false,
    skip_leading_space: bool = false,
    strong: bool = false,
    emphasis: bool = false,
    strike: bool = false,
    code_span: bool = false,
    code_ticks: usize = 0,
    marker: u8 = 0,
    marker_len: usize = 0,
    table_row: bool = false,
    escaped: bool = false,
    last_visible: ?u8 = null,
    link_state: LinkState = .none,
    link_label: [512]u8 = undefined,
    link_label_len: usize = 0,
    link_url: [1024]u8 = undefined,
    link_url_len: usize = 0,
    finished: bool = false,

    pub fn init(output: *Io.Writer) Writer {
        return .{ .output = output, .render = term.presentation };
    }

    /// Strip terminal controls before interpreting markdown. ANSI produced by
    /// the renderer never passes through this untrusted-input path.
    pub fn write(self: *Writer, bytes: []const u8) !void {
        if (self.finished) return;
        for (bytes) |byte| switch (self.escape_state) {
            .text => switch (byte) {
                0x1b => self.escape_state = .escape,
                '\n', '\t' => try self.visible(byte),
                // Preserve the existing raw-output contract for pipes. On a
                // rendered terminal, drop CR so model text cannot overwrite
                // content already displayed.
                '\r' => if (!self.render) try self.output.writeByte('\r'),
                0x00...0x08, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
                else => try self.visible(byte),
            },
            .escape => switch (byte) {
                '[' => self.escape_state = .csi,
                ']' => self.escape_state = .osc,
                else => self.escape_state = .text,
            },
            .csi => if (byte >= 0x40 and byte <= 0x7e) {
                self.escape_state = .text;
            },
            .osc => switch (byte) {
                0x07 => self.escape_state = .text,
                0x1b => self.escape_state = .osc_escape,
                else => {},
            },
            .osc_escape => if (byte == '\\') {
                self.escape_state = .text;
            } else if (byte != 0x1b) {
                self.escape_state = .osc;
            },
        };
    }

    pub fn finish(self: *Writer) !void {
        if (self.finished) return;
        self.finished = true;
        if (!self.render) return;
        switch (self.line_state) {
            .prefix => if (self.isTableSeparator()) try self.writeTableSeparator() else try self.flushPrefix(),
            .fence_open => try self.openFence(false),
            .code_prefix => if (self.prefix_len == 0) {} else if (self.isClosingFence())
                try self.closeFence(false)
            else
                try self.flushCodePrefix(),
            else => {},
        }
        try self.flushLink();
        try self.resolveMarker(null);
        if (self.escaped) try self.output.writeByte('\\');
        if (term.enabled and self.anyStyle()) try self.output.writeAll(term.reset());
    }

    fn visible(self: *Writer, byte: u8) Io.Writer.Error!void {
        if (!self.render) {
            try self.output.writeByte(byte);
            return;
        }
        switch (self.line_state) {
            .prefix => try self.prefixByte(byte),
            .body => if (byte == '\n') {
                try self.endLine();
            } else if (self.skip_leading_space and (byte == ' ' or byte == '\t')) {
                self.skip_leading_space = false;
            } else {
                self.skip_leading_space = false;
                try self.inlineByte(byte);
            },
            .fence_open => if (byte == '\n') try self.openFence(true) else try self.appendPrefix(byte),
            .code_prefix => try self.codePrefixByte(byte),
            .code_body => if (byte == '\n') try self.endCodeLine() else try self.output.writeByte(byte),
        }
    }

    fn prefixByte(self: *Writer, byte: u8) !void {
        if (byte == '\n') {
            if (self.isTableSeparator()) {
                try self.writeTableSeparator();
            } else if (self.prefix_len > 0) {
                try self.flushPrefix();
            }
            try self.output.writeByte('\n');
            self.startLine();
            return;
        }
        if (self.prefix_len == self.prefix.len) {
            try self.flushPrefix();
            try self.inlineByte(byte);
            return;
        }
        self.prefix[self.prefix_len] = byte;
        self.prefix_len += 1;
        try self.resolvePrefix();
    }

    fn appendPrefix(self: *Writer, byte: u8) Io.Writer.Error!void {
        if (self.prefix_len == self.prefix.len) {
            if (self.line_state == .fence_open) try self.openFence(false) else try self.flushCodePrefix();
            try self.visible(byte);
            return;
        }
        self.prefix[self.prefix_len] = byte;
        self.prefix_len += 1;
    }

    fn indentEnd(self: *Writer) usize {
        var i: usize = 0;
        while (i < self.prefix_len and i < 3 and self.prefix[i] == ' ') : (i += 1) {}
        return i;
    }

    fn resolvePrefix(self: *Writer) !void {
        const indent = self.indentEnd();
        if (indent == self.prefix_len) return;
        const first = self.prefix[indent];
        const rest = self.prefix[indent..self.prefix_len];

        if (first == '#') {
            var count: usize = 0;
            while (count < rest.len and rest[count] == '#') : (count += 1) {}
            if (count == rest.len and count <= 6) return;
            if (count >= 1 and count <= 6 and rest[count] == ' ') {
                if (indent > 0) try self.output.writeAll(self.prefix[0..indent]);
                // Keep dim hashes on h2 and deeper so heading levels stay
                // distinguishable; h1 alone renders bold underlined.
                if (count >= 2) {
                    if (term.enabled) try self.output.writeAll(term.dim());
                    var written: usize = 0;
                    while (written < count) : (written += 1) try self.output.writeByte('#');
                    try self.output.writeByte(' ');
                    if (term.enabled) try self.output.writeAll(term.reset());
                }
                self.heading = @intCast(count);
                self.prefix_len = 0;
                self.line_state = .body;
                try self.applyStyle();
                return;
            }
            try self.flushPrefix();
            return;
        }

        if (first == '>') {
            if (indent > 0) try self.output.writeAll(self.prefix[0..indent]);
            self.quote = true;
            self.skip_leading_space = true;
            try self.output.writeAll("\u{2502} ");
            self.prefix_len = 0;
            self.line_state = .body;
            try self.applyStyle();
            return;
        }

        if (first == '-' or first == '+' or first == '*') {
            if (rest.len == 1) return;
            if (rest[1] == ' ' or rest[1] == '\t') {
                if (indent > 0) try self.output.writeAll(self.prefix[0..indent]);
                try self.output.writeAll("\u{2022} ");
                self.prefix_len = 0;
                self.line_state = .body;
                return;
            }
            try self.flushPrefix();
            return;
        }

        if (first >= '0' and first <= '9') {
            var count: usize = 0;
            while (count < rest.len and count < 9 and rest[count] >= '0' and rest[count] <= '9') : (count += 1) {}
            if (count == rest.len and count <= 9) return;
            if (count > 0 and count < rest.len and (rest[count] == '.' or rest[count] == ')')) {
                if (count + 1 == rest.len) return;
                if (rest[count + 1] == ' ' or rest[count + 1] == '\t') {
                    try self.output.writeAll(self.prefix[0..self.prefix_len]);
                    self.prefix_len = 0;
                    self.line_state = .body;
                    return;
                }
            }
            try self.flushPrefix();
            return;
        }

        if (first == '|') {
            // Keep buffering while the line could still be a table
            // separator row (`|---|---|`); the first other character
            // makes it an ordinary table row with dimmed cell borders.
            for (rest) |byte| {
                if (byte != '|' and byte != '-' and byte != ':' and byte != ' ' and byte != '\t') {
                    self.table_row = true;
                    try self.flushPrefix();
                    return;
                }
            }
            return;
        }

        if (first == '`' or first == '~') {
            var count: usize = 0;
            while (count < rest.len and rest[count] == first) : (count += 1) {}
            if (count == rest.len) {
                if (count >= 3) {
                    self.fence_char = first;
                    self.fence_len = count;
                    self.line_state = .fence_open;
                }
                return;
            }
            if (count >= 3) {
                self.fence_char = first;
                self.fence_len = count;
                self.line_state = .fence_open;
                return;
            }
            try self.flushPrefix();
            return;
        }

        try self.flushPrefix();
    }

    /// A buffered prefix line like `|---|:---:|` under a pipe-led line.
    fn isTableSeparator(self: *Writer) bool {
        const indent = self.indentEnd();
        if (indent == self.prefix_len) return false;
        if (self.prefix[indent] != '|') return false;
        var dashes: usize = 0;
        for (self.prefix[indent..self.prefix_len]) |byte| switch (byte) {
            '-' => dashes += 1,
            '|', ':', ' ', '\t' => {},
            else => return false,
        };
        return dashes > 0;
    }

    /// Render a table separator row as a dim rule: `┼───┼───┼`.
    fn writeTableSeparator(self: *Writer) !void {
        const indent = self.indentEnd();
        if (indent > 0) try self.output.writeAll(self.prefix[0..indent]);
        if (term.enabled) try self.output.writeAll(term.dim());
        for (self.prefix[indent..self.prefix_len]) |byte| switch (byte) {
            '|' => try self.output.writeAll("\u{253c}"),
            '-', ':' => try self.output.writeAll("\u{2500}"),
            else => try self.output.writeByte(byte),
        };
        if (term.enabled) try self.output.writeAll(term.reset());
        self.prefix_len = 0;
        self.line_state = .body;
    }

    fn flushPrefix(self: *Writer) !void {
        const bytes = self.prefix[0..self.prefix_len];
        self.prefix_len = 0;
        self.line_state = .body;
        for (bytes) |byte| try self.inlineByte(byte);
    }

    fn openFence(self: *Writer, newline: bool) !void {
        const indent = self.indentEnd();
        var marker_end = indent;
        while (marker_end < self.prefix_len and self.prefix[marker_end] == self.fence_char) : (marker_end += 1) {}
        self.fence_len = marker_end - indent;
        const language = std.mem.trim(u8, self.prefix[marker_end..self.prefix_len], " \t");
        if (indent > 0) try self.output.writeAll(self.prefix[0..indent]);
        if (term.enabled) try self.output.writeAll(term.dim());
        try self.output.writeAll("\u{250c}\u{2500}");
        if (language.len > 0) try self.output.print(" {s}", .{language});
        if (term.enabled) try self.output.writeAll(term.reset());
        if (newline) try self.output.writeByte('\n');
        self.prefix_len = 0;
        self.line_state = .code_prefix;
        self.clearInlineStyles();
    }

    fn codePrefixByte(self: *Writer, byte: u8) !void {
        if (byte == '\n') {
            if (self.isClosingFence()) {
                try self.closeFence(true);
            } else {
                try self.flushCodePrefix();
                try self.endCodeLine();
            }
            return;
        }
        try self.appendPrefix(byte);
        if (!self.couldBeClosingFence()) try self.flushCodePrefix();
    }

    fn couldBeClosingFence(self: *Writer) bool {
        const indent = self.indentEnd();
        if (indent == self.prefix_len) return true;
        var i = indent;
        while (i < self.prefix_len and self.prefix[i] == self.fence_char) : (i += 1) {}
        if (i - indent < self.fence_len) return i == self.prefix_len;
        while (i < self.prefix_len and (self.prefix[i] == ' ' or self.prefix[i] == '\t')) : (i += 1) {}
        return i == self.prefix_len;
    }

    fn isClosingFence(self: *Writer) bool {
        const indent = self.indentEnd();
        var i = indent;
        while (i < self.prefix_len and self.prefix[i] == self.fence_char) : (i += 1) {}
        if (i - indent < self.fence_len) return false;
        while (i < self.prefix_len and (self.prefix[i] == ' ' or self.prefix[i] == '\t')) : (i += 1) {}
        return i == self.prefix_len;
    }

    fn flushCodePrefix(self: *Writer) !void {
        if (term.enabled) try self.output.writeAll(term.dim());
        try self.output.writeAll("\u{2502} ");
        if (term.enabled) try self.output.writeAll(term.reset());
        try self.output.writeAll(self.prefix[0..self.prefix_len]);
        self.prefix_len = 0;
        self.line_state = .code_body;
    }

    fn endCodeLine(self: *Writer) !void {
        try self.output.writeByte('\n');
        self.prefix_len = 0;
        self.line_state = .code_prefix;
    }

    fn closeFence(self: *Writer, newline: bool) !void {
        if (term.enabled) try self.output.writeAll(term.dim());
        try self.output.writeAll("\u{2514}\u{2500}");
        if (term.enabled) try self.output.writeAll(term.reset());
        if (newline) try self.output.writeByte('\n');
        self.prefix_len = 0;
        self.fence_char = 0;
        self.fence_len = 0;
        self.startLine();
    }

    fn inlineByte(self: *Writer, byte: u8) Io.Writer.Error!void {
        if (self.link_state != .none) {
            try self.linkByte(byte);
            return;
        }
        if (self.escaped) {
            try self.resolveMarker(byte);
            try self.output.writeByte(byte);
            self.last_visible = byte;
            self.escaped = false;
            return;
        }
        if (byte == '\\' and !self.code_span) {
            try self.resolveMarker(byte);
            self.escaped = true;
            return;
        }
        if (byte == '[' and !self.code_span) {
            try self.resolveMarker(byte);
            self.link_state = .label;
            self.link_label_len = 0;
            self.link_url_len = 0;
            return;
        }
        if (byte == '|' and self.table_row and !self.code_span) {
            try self.resolveMarker(byte);
            if (term.enabled) try self.output.writeAll(term.reset());
            if (term.enabled) try self.output.writeAll(term.dim());
            try self.output.writeAll("\u{2502}");
            try self.applyStyle();
            self.last_visible = '|';
            return;
        }
        if (byte == '*' or byte == '_' or byte == '~' or byte == '`') {
            if (self.marker == 0 or self.marker == byte) {
                if (self.marker_len < 16) {
                    self.marker = byte;
                    self.marker_len += 1;
                    return;
                }
            }
        }
        try self.resolveMarker(byte);
        try self.output.writeByte(byte);
        self.last_visible = byte;
    }

    fn resolveMarker(self: *Writer, next: ?u8) !void {
        if (self.marker_len == 0) return;
        const marker = self.marker;
        const count = self.marker_len;
        self.marker = 0;
        self.marker_len = 0;

        const previous_space = self.last_visible == null or isSpace(self.last_visible.?);
        const next_space = next == null or isSpace(next.?);
        if (marker == '`') {
            if (self.code_span and count == self.code_ticks) {
                self.code_span = false;
                self.code_ticks = 0;
                try self.applyStyle();
            } else if (!self.code_span and !next_space) {
                self.code_span = true;
                self.code_ticks = count;
                try self.applyStyle();
            } else {
                try self.repeatByte(marker, count);
            }
            return;
        }
        if (self.code_span) {
            try self.repeatByte(marker, count);
            return;
        }
        if (marker == '~') {
            var pairs = count / 2;
            while (pairs > 0) : (pairs -= 1) {
                if ((self.strike and !previous_space) or (!self.strike and !next_space)) {
                    self.strike = !self.strike;
                    try self.applyStyle();
                } else {
                    try self.output.writeAll("~~");
                    self.last_visible = '~';
                }
            }
            if (count % 2 == 1) {
                try self.output.writeByte('~');
                self.last_visible = '~';
            }
            return;
        }

        // Underscores inside identifiers are code much more often than
        // emphasis. Keep those literal.
        if (marker == '_' and self.last_visible != null and next != null and
            isAlphaNumeric(self.last_visible.?) and isAlphaNumeric(next.?))
        {
            try self.repeatByte(marker, count);
            return;
        }
        var remaining = count;
        while (remaining >= 2) : (remaining -= 2) {
            if ((self.strong and !previous_space) or (!self.strong and !next_space)) {
                self.strong = !self.strong;
                try self.applyStyle();
            } else {
                try self.output.writeAll(if (marker == '*') "**" else "__");
                self.last_visible = marker;
            }
        }
        if (remaining == 1) {
            if ((self.emphasis and !previous_space) or (!self.emphasis and !next_space)) {
                self.emphasis = !self.emphasis;
                try self.applyStyle();
            } else {
                try self.output.writeByte(marker);
                self.last_visible = marker;
            }
        }
    }

    fn linkByte(self: *Writer, byte: u8) Io.Writer.Error!void {
        switch (self.link_state) {
            .none => unreachable,
            .label => {
                if (byte == '\n' or self.link_label_len == self.link_label.len) {
                    try self.flushLink();
                    try self.inlineByte(byte);
                } else if (byte == ']') {
                    self.link_state = .after_label;
                } else {
                    self.link_label[self.link_label_len] = byte;
                    self.link_label_len += 1;
                }
            },
            .after_label => if (byte == '(') {
                self.link_state = .url;
            } else {
                try self.flushLink();
                try self.inlineByte(byte);
            },
            .url => {
                if (byte == ')' and self.link_url_len > 0) {
                    if (term.enabled) try self.output.writeAll(term.underline());
                    try self.output.writeAll(self.link_label[0..self.link_label_len]);
                    if (term.enabled) try self.applyStyle();
                    const url = self.link_url[0..self.link_url_len];
                    if (!std.mem.eql(u8, self.link_label[0..self.link_label_len], url)) {
                        if (term.enabled) try self.output.writeAll(term.dim());
                        try self.output.print(" ({s})", .{url});
                        if (term.enabled) try self.applyStyle();
                    }
                    self.last_visible = ')';
                    self.link_state = .none;
                    self.link_label_len = 0;
                    self.link_url_len = 0;
                } else if (byte == '\n' or self.link_url_len == self.link_url.len) {
                    try self.flushLink();
                    try self.inlineByte(byte);
                } else {
                    self.link_url[self.link_url_len] = byte;
                    self.link_url_len += 1;
                }
            },
        }
    }

    fn flushLink(self: *Writer) !void {
        switch (self.link_state) {
            .none => return,
            .label => {
                try self.output.writeByte('[');
                try self.output.writeAll(self.link_label[0..self.link_label_len]);
            },
            .after_label => {
                try self.output.writeByte('[');
                try self.output.writeAll(self.link_label[0..self.link_label_len]);
                try self.output.writeByte(']');
            },
            .url => {
                try self.output.writeByte('[');
                try self.output.writeAll(self.link_label[0..self.link_label_len]);
                try self.output.writeAll("](");
                try self.output.writeAll(self.link_url[0..self.link_url_len]);
            },
        }
        self.last_visible = if (self.link_url_len > 0)
            self.link_url[self.link_url_len - 1]
        else if (self.link_label_len > 0)
            self.link_label[self.link_label_len - 1]
        else
            '[';
        self.link_state = .none;
        self.link_label_len = 0;
        self.link_url_len = 0;
    }

    fn endLine(self: *Writer) !void {
        try self.flushLink();
        try self.resolveMarker('\n');
        if (self.escaped) {
            try self.output.writeByte('\\');
            self.escaped = false;
        }
        if (self.heading != 0 or self.quote) {
            self.heading = 0;
            self.quote = false;
            try self.applyStyle();
        }
        try self.output.writeByte('\n');
        self.startLine();
    }

    fn startLine(self: *Writer) void {
        self.line_state = .prefix;
        self.prefix_len = 0;
        self.last_visible = null;
        self.skip_leading_space = false;
        self.table_row = false;
    }

    fn clearInlineStyles(self: *Writer) void {
        self.heading = 0;
        self.quote = false;
        self.strong = false;
        self.emphasis = false;
        self.strike = false;
        self.code_span = false;
        self.code_ticks = 0;
        self.marker = 0;
        self.marker_len = 0;
        self.link_state = .none;
        self.escaped = false;
    }

    fn anyStyle(self: *Writer) bool {
        return self.heading != 0 or self.quote or self.strong or self.emphasis or self.strike or self.code_span;
    }

    fn applyStyle(self: *Writer) !void {
        if (!term.enabled) return;
        try self.output.writeAll(term.reset());
        if (self.quote) {
            try self.output.writeAll(term.dim());
            try self.output.writeAll(term.italic());
        }
        // Inline code must stay theme-neutral. Reverse video makes the
        // terminal's background become the foreground, which often produces
        // glaring white boxes on light palettes. Bold keeps the terminal's
        // chosen foreground and never paints a background.
        if (self.heading != 0 or self.strong or self.code_span) try self.output.writeAll(term.bold());
        if (self.heading == 1) try self.output.writeAll(term.underline());
        if (self.emphasis) try self.output.writeAll(term.italic());
        if (self.strike) try self.output.writeAll(term.strikethrough());
    }

    fn repeatByte(self: *Writer, byte: u8, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) try self.output.writeByte(byte);
        self.last_visible = byte;
    }
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn isAlphaNumeric(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9');
}

test "non-terminal markdown remains raw and terminal-safe" {
    const previous_presentation = term.presentation;
    defer term.presentation = previous_presentation;
    term.presentation = false;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var markdown = Writer.init(&output.writer);
    try markdown.write("# raw **text**\x1b[31m!\x1b[0m");
    try markdown.finish();
    try std.testing.expectEqualStrings("# raw **text**!", output.written());
}

test "renders common markdown across arbitrary chunks" {
    const previous_enabled = term.enabled;
    const previous_presentation = term.presentation;
    defer {
        term.enabled = previous_enabled;
        term.presentation = previous_presentation;
    }
    term.enabled = false;
    term.presentation = true;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var markdown = Writer.init(&output.writer);
    try markdown.write("# He");
    try markdown.write("ading\n- **bold** and `code`\n> quote\n```zig\nconst x = 1;\n```");
    try markdown.finish();
    try std.testing.expectEqualStrings(
        "Heading\n\u{2022} bold and code\n\u{2502} quote\n\u{250c}\u{2500} zig\n\u{2502} const x = 1;\n\u{2514}\u{2500}",
        output.written(),
    );
}

test "renders links and preserves non-links" {
    const previous_enabled = term.enabled;
    const previous_presentation = term.presentation;
    defer {
        term.enabled = previous_enabled;
        term.presentation = previous_presentation;
    }
    term.enabled = false;
    term.presentation = true;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var markdown = Writer.init(&output.writer);
    try markdown.write("see [docs](https://example.com) and [literal]\n");
    try markdown.finish();
    try std.testing.expectEqualStrings("see docs (https://example.com) and [literal]\n", output.written());
}

test "rendering is independent of stream chunk boundaries" {
    const previous_enabled = term.enabled;
    const previous_presentation = term.presentation;
    defer {
        term.enabled = previous_enabled;
        term.presentation = previous_presentation;
    }
    term.enabled = true;
    term.presentation = true;
    const source = "## Result\n- *one* and **two**\n```sh\nprintf ok\n```\n[docs](https://example.com)";

    var baseline_output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer baseline_output.deinit();
    var baseline_renderer = Writer.init(&baseline_output.writer);
    try baseline_renderer.write(source);
    try baseline_renderer.finish();
    const baseline = try std.testing.allocator.dupe(u8, baseline_output.written());
    defer std.testing.allocator.free(baseline);

    var split: usize = 0;
    while (split <= source.len) : (split += 1) {
        var output: Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        var renderer = Writer.init(&output.writer);
        try renderer.write(source[0..split]);
        try renderer.write(source[split..]);
        try renderer.finish();
        try std.testing.expectEqualStrings(baseline, output.written());
    }
}

test "tables render dim borders and separator rules" {
    const previous_enabled = term.enabled;
    const previous_presentation = term.presentation;
    defer {
        term.enabled = previous_enabled;
        term.presentation = previous_presentation;
    }
    term.enabled = false;
    term.presentation = true;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = Writer.init(&output.writer);
    try renderer.write("| a | b |\n|---|:-:|\n| 1 | 2 |\n");
    try renderer.finish();
    try std.testing.expectEqualStrings(
        "\u{2502} a \u{2502} b \u{2502}\n\u{253c}\u{2500}\u{2500}\u{2500}\u{253c}\u{2500}\u{2500}\u{2500}\u{253c}\n\u{2502} 1 \u{2502} 2 \u{2502}\n",
        output.written(),
    );
}

test "heading levels beyond one keep dim hash markers" {
    const previous_enabled = term.enabled;
    const previous_presentation = term.presentation;
    defer {
        term.enabled = previous_enabled;
        term.presentation = previous_presentation;
    }
    term.enabled = false;
    term.presentation = true;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = Writer.init(&output.writer);
    try renderer.write("# One\n## Two\n### Three\n");
    try renderer.finish();
    try std.testing.expectEqualStrings("One\n## Two\n### Three\n", output.written());
}

test "inline code does not paint a background" {
    const previous_enabled = term.enabled;
    const previous_presentation = term.presentation;
    defer {
        term.enabled = previous_enabled;
        term.presentation = previous_presentation;
    }
    term.enabled = true;
    term.presentation = true;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = Writer.init(&output.writer);
    try renderer.write("use `zig build test` here");
    try renderer.finish();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[7m") == null);
}
