const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const childproc = @import("child.zig");

pub const max_copy_bytes = 64 * 1024;
const native_timeout_ms = 750;
const native_guard =
    \\if [ -n "${SSH_CONNECTION+x}${SSH_CLIENT+x}${SSH_TTY+x}" ]; then exit 1; fi
    \\exec "$@"
;

/// True means a native clipboard helper accepted the text. False asks the
/// caller to use writeOsc52 through its protected terminal writer. Clipboard
/// commands share one deadline and never register with foreground cancellation.
pub fn copy(gpa: std.mem.Allocator, io: Io, text: []const u8) !bool {
    _ = gpa;
    if (text.len > max_copy_bytes) return error.ClipboardTooLarge;
    const commands: []const []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{&.{ "/bin/sh", "-c", native_guard, "xaq-clipboard", "pbcopy" }},
        .linux => &.{
            &.{ "/bin/sh", "-c", native_guard, "xaq-clipboard", "wl-copy", "--type", "text/plain;charset=utf-8" },
            &.{ "/bin/sh", "-c", native_guard, "xaq-clipboard", "xclip", "-selection", "clipboard", "-t", "UTF8_STRING" },
            &.{ "/bin/sh", "-c", native_guard, "xaq-clipboard", "xsel", "--clipboard", "--input" },
        },
        else => return false,
    };
    return copyUsing(io, text, commands, .fromMilliseconds(native_timeout_ms));
}

/// OSC 52 selects the clipboard with `c` and encodes its contents as RFC 4648
/// base64. The caller owns terminal serialization and flushing. No clipboard
/// query is sent, and text cannot inject terminal controls through the payload.
/// https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
pub fn writeOsc52(writer: *Io.Writer, text: []const u8) !void {
    if (text.len > max_copy_bytes) return error.ClipboardTooLarge;
    try writer.writeAll("\x1b]52;c;");
    var encoded: [4096]u8 = undefined;
    var remaining = text;
    while (remaining.len != 0) {
        // Full chunks must divide by three so only the last chunk pads.
        const count = @min(remaining.len, encoded.len / 4 * 3);
        try writer.writeAll(std.base64.standard.Encoder.encode(&encoded, remaining[0..count]));
        remaining = remaining[count..];
    }
    try writer.writeAll("\x1b\\");
}

fn copyUsing(io: Io, text: []const u8, commands: []const []const []const u8, timeout: Io.Duration) !bool {
    const deadline = Io.Clock.now(.awake, io).addDuration(timeout);
    for (commands) |argv| {
        const remaining = Io.Clock.now(.awake, io).durationTo(deadline);
        if (remaining.nanoseconds <= 0) return false;
        if (try runCommand(io, text, argv, remaining, null)) return true;
    }
    return false;
}

fn runCommand(io: Io, text: []const u8, argv: []const []const u8, timeout: Io.Duration, environ: ?*const std.process.Environ.Map) !bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => return false,
    };
    const pid = child.id.?;
    var accepted = false;
    defer {
        // Successful X11/Wayland helpers may leave a clipboard owner running.
        if (!accepted) std.posix.kill(-pid, .KILL) catch {};
        if (child.id != null) child.kill(io);
    }
    // One deadline covers blocked stdin writes and waiting for exit. It is
    // polled here rather than on a watchdog task: a saturated Io pool runs
    // `Io.async` inline, which would stall the copy for the whole timeout.
    const deadline = Io.Clock.now(.awake, io).addDuration(timeout);
    var timed_out = false;
    const stdin = child.stdin.?.handle;
    var remaining = text;
    while (remaining.len != 0) {
        const events = childproc.poll(stdin, std.posix.POLL.OUT, childproc.millisUntil(io, deadline, std.math.maxInt(i32))) catch return false;
        if (events == 0) {
            timed_out = true;
            break;
        }
        // The helper closed its stdin early; let its exit status decide.
        if (events & std.posix.POLL.OUT == 0) break;
        const written = childproc.writeSome(stdin, remaining) catch |err| switch (err) {
            error.BrokenPipe => break,
            else => return false,
        };
        remaining = remaining[written..];
    }
    child.stdin.?.close(io);
    child.stdin = null;
    if (timed_out) std.posix.kill(-pid, .KILL) catch {};
    const term = while (true) {
        const reaped = childproc.reap(&child) catch return false;
        if (reaped) |term| break term;
        if (!timed_out and Io.Clock.now(.awake, io).durationTo(deadline).nanoseconds <= 0) {
            timed_out = true;
            std.posix.kill(-pid, .KILL) catch {};
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    };
    accepted = !timed_out and remaining.len == 0 and switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    return accepted;
}

test "native clipboard helpers receive exact text and failures fall through" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/copied", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const text = "quoted '$HOME' and `command`\nUnicode: €\n";
    const commands: []const []const []const u8 = &.{
        &.{"/nonexistent/xaq-clipboard-helper"},
        &.{ "/bin/sh", "-c", "exit 7" },
        &.{ "/bin/sh", "-c", "/bin/cat > \"$1\"", "clipboard-test", path },
    };
    try std.testing.expect(try copyUsing(std.testing.io, text, commands, .fromSeconds(1)));
    const contents = try temporary.dir.readFileAlloc(std.testing.io, "copied", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(text, contents);
    try std.testing.expect(!try copyUsing(std.testing.io, text, commands[0..2], .fromSeconds(1)));
}

test "clipboard helper timeout covers blocked input and prevents later attempts" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const pid_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/pid", .{temporary.sub_path});
    defer std.testing.allocator.free(pid_path);
    const unexpected_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/unexpected", .{temporary.sub_path});
    defer std.testing.allocator.free(unexpected_path);
    const text = try std.testing.allocator.alloc(u8, max_copy_bytes);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    const started = Io.Clock.now(.awake, std.testing.io);
    try std.testing.expect(!try copyUsing(std.testing.io, text, &.{
        &.{ "/bin/sh", "-c", "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec sleep 30", "clipboard-test", pid_path },
        &.{ "/bin/sh", "-c", "/bin/cat > \"$1\"", "clipboard-test", unexpected_path },
    }, .fromMilliseconds(150)));
    try std.testing.expect(started.durationTo(Io.Clock.now(.awake, std.testing.io)).nanoseconds < 2 * std.time.ns_per_s);
    const pid_text = try temporary.dir.readFileAlloc(std.testing.io, "pid", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(-pid, @enumFromInt(0)));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "unexpected", .{}));
}

test "SSH variable presence prevents native clipboard writes" {
    for ([_][]const u8{ "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY" }) |variable| {
        var environ: std.process.Environ.Map = .init(std.testing.allocator);
        defer environ.deinit();
        try environ.put(variable, "");
        try std.testing.expect(!try runCommand(std.testing.io, "private selection", &.{ "/bin/sh", "-c", native_guard, "clipboard-test", "/bin/sh", "-c", "exit 0" }, .fromSeconds(1), &environ));
    }
}

test "successful clipboard owners survive after their launcher exits" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/owner", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    try std.testing.expect(try runCommand(std.testing.io, "copied text", &.{
        "/bin/sh", "-c", "/bin/cat >/dev/null; (sleep 0.25; printf served > \"$1\") & exit 0", "clipboard-test", path,
    }, .fromMilliseconds(150), null));
    for (0..100) |_| {
        const marker = temporary.dir.readFileAlloc(std.testing.io, "owner", std.testing.allocator, .limited(64)) catch |err| switch (err) {
            error.FileNotFound => {
                try std.testing.io.sleep(.fromMilliseconds(10), .awake);
                continue;
            },
            else => return err,
        };
        defer std.testing.allocator.free(marker);
        if (marker.len == 0) {
            try std.testing.io.sleep(.fromMilliseconds(10), .awake);
            continue;
        }
        try std.testing.expectEqualStrings("served", marker);
        return;
    }
    return error.ClipboardOwnerWasStopped;
}

test "OSC52 encodes control bytes across chunk boundaries" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeOsc52(&output.writer, "hello");
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", output.written());
    output.clearRetainingCapacity();
    const text = try std.testing.allocator.alloc(u8, max_copy_bytes);
    defer std.testing.allocator.free(text);
    for (text, 0..) |*byte, index| byte.* = @intCast(index % 256);
    try writeOsc52(&output.writer, text);
    const encoded = output.written()["\x1b]52;c;".len .. output.written().len - 2];
    const decoded = try std.testing.allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    defer std.testing.allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    try std.testing.expectEqualSlices(u8, text, decoded);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "\x1b\\"));
}

test "oversized clipboard text is rejected before any output or native access" {
    const text = try std.testing.allocator.alloc(u8, max_copy_bytes + 1);
    defer std.testing.allocator.free(text);
    var buffer: [32]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.ClipboardTooLarge, writeOsc52(&writer, text));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try std.testing.expectError(error.ClipboardTooLarge, copy(std.testing.failing_allocator, std.testing.io, text));
}
