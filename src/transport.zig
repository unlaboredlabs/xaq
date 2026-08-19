const std = @import("std");
const Io = std.Io;
const cancel = @import("cancel.zig");

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Response = struct { status: u16, body: []u8, retry_after_seconds: ?u64 = null };
pub const StreamFn = *const fn (context: ?*anyopaque, line: []const u8) anyerror!void;

/// Small HTTPS transport. curl supplies platform TLS, but all sensitive
/// headers travel through its stdin config rather than process arguments.
pub fn post(gpa: std.mem.Allocator, io: Io, url: []const u8, content_type: []const u8, headers: []const Header, body: []const u8) !Response {
    var collected: Io.Writer.Allocating = .init(gpa);
    defer collected.deinit();
    const Sink = struct {
        fn line(raw: ?*anyopaque, value: []const u8) !void {
            const writer: *Io.Writer.Allocating = @ptrCast(@alignCast(raw.?));
            if (writer.written().len + value.len + 1 > 32 * 1024 * 1024) return error.StreamTooLong;
            try writer.writer.writeAll(value);
            try writer.writer.writeByte('\n');
        }
    };
    var response = try postStream(gpa, io, url, content_type, headers, body, &collected, Sink.line);
    if (response.status >= 200 and response.status < 300) {
        gpa.free(response.body);
        response.body = try collected.toOwnedSlice();
    }
    return response;
}

/// Invoke `callback` for each response-body line as curl receives it. Error
/// bodies are captured (bounded) and returned instead of being streamed.
pub fn postStream(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    content_type: []const u8,
    headers: []const Header,
    body: []const u8,
    callback_context: ?*anyopaque,
    callback: StreamFn,
) !Response {
    return postStreamWithToken(gpa, io, url, content_type, headers, body, callback_context, callback, cancel.processToken());
}

/// `postStream` with caller-owned cancellation. This is the transport entry
/// point used by embedded agents; it does not touch the CLI's process token.
pub fn postStreamWithToken(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    content_type: []const u8,
    headers: []const Header,
    body: []const u8,
    callback_context: ?*anyopaque,
    callback: StreamFn,
    token: *cancel.Token,
) !Response {
    const path = try requestFile(gpa, io, body);
    defer {
        Io.Dir.cwd().deleteFile(io, path) catch {};
        gpa.free(path);
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ "curl", "--config", "-", "--url", url },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .pgid = 0,
    });
    defer if (child.id != null) child.kill(io);
    token.setChild(child.id.?);
    defer token.clearChild();

    var config_buffer: [4096]u8 = undefined;
    var config: Io.File.Writer = .init(child.stdin.?, io, &config_buffer);
    try config.interface.writeAll(
        \\silent
        \\show-error
        \\no-buffer
        \\include
        \\request = "POST"
        \\max-time = 600
        \\
    );
    const content_header = try tryHeader(gpa, "Content-Type", content_type);
    defer gpa.free(content_header);
    try configLine(&config.interface, "header", content_header);
    for (headers) |header| {
        const value = try tryHeader(gpa, header.name, header.value);
        defer gpa.free(value);
        try configLine(&config.interface, "header", value);
    }
    const data = try std.fmt.allocPrint(gpa, "@{s}", .{path});
    defer gpa.free(data);
    try configLine(&config.interface, "data-binary", data);
    try config.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;

    // Heap buffer: a single SSE line carries whole tool-call items, so a
    // large write/edit argument payload can far exceed 64 KiB; a line
    // that cannot fit still fails, but only past this bound.
    const read_buffer = try gpa.alloc(u8, 8 * 1024 * 1024);
    defer gpa.free(read_buffer);
    var file_reader: Io.File.Reader = .init(child.stdout.?, io, read_buffer);
    const reader = &file_reader.interface;
    var status: u16 = 0;
    var retry_after: ?u64 = null;
    var in_headers = true;
    var error_body: Io.Writer.Allocating = .init(gpa);
    defer error_body.deinit();

    while (reader.takeDelimiter('\n') catch |err| {
        // SIGINT terminates curl and can make its stdout pipe report a read
        // failure rather than EOF. Cancellation must win over that transport
        // detail so the interactive loop can restore the prompt.
        if (token.isRequested()) return error.Cancelled;
        return err;
    }) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (in_headers) {
            if (std.mem.startsWith(u8, line, "HTTP/")) {
                status = parseStatus(line) orelse return error.InvalidHttpResponse;
                retry_after = null;
            } else if (line.len == 0) {
                if (status == 0) return error.InvalidHttpResponse;
                if (status >= 100 and status < 200) {
                    // 1xx (e.g. 100-continue): the real header block
                    // follows. Only here may a new HTTP/ line appear;
                    // treating body lines that start with "HTTP/" as new
                    // blocks would corrupt legitimate payloads.
                    status = 0;
                    continue;
                }
                in_headers = false;
            } else if (headerValue(line, "retry-after")) |value| {
                retry_after = std.fmt.parseInt(u64, std.mem.trim(u8, value, " \t"), 10) catch null;
            }
            continue;
        }
        if (status >= 200 and status < 300) {
            try callback(callback_context, line);
        } else if (error_body.written().len < 128 * 1024) {
            const remaining = 128 * 1024 - error_body.written().len;
            try error_body.writer.writeAll(line[0..@min(line.len, remaining)]);
            if (remaining > line.len) try error_body.writer.writeByte('\n');
        }
    }
    child.stdout.?.close(io);
    child.stdout = null;
    if (token.isRequested()) return error.Cancelled;
    const term = child.wait(io) catch |err| {
        if (token.isRequested()) return error.Cancelled;
        return err;
    };
    if (token.isRequested()) return error.Cancelled;
    switch (term) {
        .exited => |code| if (code != 0) return error.TransportFailed,
        else => return error.TransportFailed,
    }
    if (status == 0) return error.InvalidHttpResponse;
    return .{
        .status = status,
        .body = try error_body.toOwnedSlice(),
        .retry_after_seconds = retry_after,
    };
}

fn requestFile(gpa: std.mem.Allocator, io: Io, body: []const u8) ![]u8 {
    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    var encoded: [16]u8 = undefined;
    const suffix = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random);
    const path = try std.fmt.allocPrint(gpa, "/tmp/xaq-request-{s}", .{suffix});
    errdefer gpa.free(path);
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = body,
        .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o600) },
    });
    return path;
}

fn configLine(writer: *Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print("{s} = \"", .{name});
    for (value) |byte| switch (byte) {
        '\\', '"' => try writer.writeAll(&.{ '\\', byte }),
        '\r', '\n', 0 => return error.InvalidHeader,
        else => try writer.writeByte(byte),
    };
    try writer.writeAll("\"\n");
}

fn tryHeader(gpa: std.mem.Allocator, name: []const u8, value: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, name, "\r\n:") != null or std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidHeader;
    return std.fmt.allocPrint(gpa, "{s}: {s}", .{ name, value });
}

fn parseStatus(line: []const u8) ?u16 {
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const tail = std.mem.trimStart(u8, line[first_space + 1 ..], " ");
    const end = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    return std.fmt.parseInt(u16, tail[0..end], 10) catch null;
}

fn headerValue(line: []const u8, expected: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (!std.ascii.eqlIgnoreCase(line[0..colon], expected)) return null;
    return line[colon + 1 ..];
}

pub fn formEncode(gpa: std.mem.Allocator, fields: []const struct { []const u8, []const u8 }) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (fields, 0..) |item, i| {
        if (i != 0) try out.writer.writeByte('&');
        try percent(&out.writer, item[0]);
        try out.writer.writeByte('=');
        try percent(&out.writer, item[1]);
    }
    return out.toOwnedSlice();
}

pub fn percent(writer: *Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(c),
        ' ' => try writer.writeByte('+'),
        else => try writer.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] }),
    };
}

test "form encoding" {
    const value = try formEncode(std.testing.allocator, &.{ .{ "scope", "a b" }, .{ "x", "+" } });
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("scope=a+b&x=%2B", value);
}

test "HTTP response helpers" {
    try std.testing.expectEqual(@as(?u16, 429), parseStatus("HTTP/2 429 Too Many Requests"));
    try std.testing.expectEqualStrings(" 7", headerValue("Retry-After: 7", "retry-after").?);
    try std.testing.expectEqual(@as(?[]const u8, null), headerValue("Content-Type: text/plain", "retry-after"));
}

test "curl config rejects header injection" {
    try std.testing.expectError(error.InvalidHeader, tryHeader(std.testing.allocator, "Authorization", "x\ny"));
}
