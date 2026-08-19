//! Minimal ANSI styling: dim for meta lines, bold for the prompt marker.
//! Styling is enabled only for interactive terminals and honors NO_COLOR
//! and TERM=dumb. When disabled every helper returns an empty string, so
//! call sites stay branch-free.

const std = @import("std");
const Io = std.Io;

pub var enabled = false;

pub fn detect(is_tty: bool, no_color: ?[]const u8, term_name: ?[]const u8) void {
    enabled = is_tty;
    if (no_color) |value| if (value.len > 0) {
        enabled = false;
    };
    if (term_name) |value| if (std.mem.eql(u8, value, "dumb")) {
        enabled = false;
    };
}

pub fn bold() []const u8 {
    return if (enabled) "\x1b[1m" else "";
}

pub fn dim() []const u8 {
    return if (enabled) "\x1b[2m" else "";
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

test "detect respects tty, NO_COLOR, and TERM" {
    defer enabled = false;
    detect(false, null, null);
    try std.testing.expect(!enabled);
    detect(true, null, null);
    try std.testing.expect(enabled);
    detect(true, "1", null);
    try std.testing.expect(!enabled);
    detect(true, "", null);
    try std.testing.expect(enabled);
    detect(true, null, "dumb");
    try std.testing.expect(!enabled);
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
