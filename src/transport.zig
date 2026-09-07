const std = @import("std");
const Io = std.Io;
const cancel = @import("cancel.zig");

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Response = struct { status: u16, body: []u8, retry_after_seconds: ?u64 = null };
pub const StreamFn = *const fn (context: ?*anyopaque, line: []const u8) anyerror!void;

const response_read_buffer_bytes = 16 * 1024;
const max_response_line_bytes = 8 * 1024 * 1024;

/// Extract a display-safe candidate from the common JSON error shapes used by
/// providers. Callers still need to filter terminal control sequences.
pub fn errorMessage(gpa: std.mem.Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    const text = errorMessageValue(parsed.value) orelse return null;
    return gpa.dupe(u8, text) catch null;
}

fn errorMessageValue(root: std.json.Value) ?[]const u8 {
    const object = switch (root) {
        .object => |object_value| object_value,
        else => return null,
    };
    for ([_][]const u8{ "error_description", "detail", "message", "error" }) |key| {
        const value = object.get(key) orelse continue;
        switch (value) {
            .string => |text| return text,
            .object => if (errorMessageValue(value)) |text| return text,
            else => {},
        }
    }
    if (object.get("response")) |response| return errorMessageValue(response);
    return null;
}

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
    if (token.isRequested()) return error.Cancelled;
    return postStreamRequest(gpa, io, url, content_type, headers, body, callback_context, callback, token) catch |err| {
        // Cancellation can also close curl's stdin during config writes.
        // Preserve the cancellation result throughout request setup and I/O.
        if (token.isRequested()) return error.Cancelled;
        return err;
    };
}

fn postStreamRequest(
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
    if (token.isRequested()) return error.Cancelled;

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

    // Most SSE lines fit in the read buffer. Borrow those directly and grow
    // a retained line buffer only for large events such as tool arguments.
    var read_buffer: [response_read_buffer_bytes]u8 = undefined;
    var file_reader: Io.File.Reader = .init(child.stdout.?, io, &read_buffer);
    const reader = &file_reader.interface;
    var response_line: Io.Writer.Allocating = .init(gpa);
    defer response_line.deinit();
    var status: u16 = 0;
    var retry_after: ?u64 = null;
    var in_headers = true;
    var error_body: Io.Writer.Allocating = .init(gpa);
    defer error_body.deinit();

    while (nextResponseLine(reader, &response_line) catch |err| {
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

fn nextResponseLine(reader: *Io.Reader, line: *Io.Writer.Allocating) !?[]const u8 {
    line.clearRetainingCapacity();
    if (reader.takeDelimiter('\n')) |maybe_line| {
        const buffered = maybe_line orelse return null;
        if (buffered.len > max_response_line_bytes) return error.StreamTooLong;
        return buffered;
    } else |err| switch (err) {
        error.StreamTooLong => {},
        else => return err,
    }

    _ = try reader.streamDelimiterLimit(&line.writer, '\n', .limited(max_response_line_bytes + 1));
    if (line.written().len > max_response_line_bytes) return error.StreamTooLong;
    const delimiter = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return if (line.written().len == 0) null else line.written(),
        else => return err,
    };
    std.debug.assert(delimiter == '\n');
    return line.written();
}

fn requestFile(gpa: std.mem.Allocator, io: Io, body: []const u8) ![]u8 {
    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    var encoded: [16]u8 = undefined;
    const suffix = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random);
    const path = try std.fmt.allocPrint(gpa, "/tmp/xaq-request-{s}", .{suffix});
    errdefer gpa.free(path);
    var file = try Io.Dir.cwd().createFile(io, path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    // Only remove files this request created. A name collision belongs to
    // another request, which may still need its body file for curl.
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, body);
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

test "cancelled requests stop before allocating or spawning curl" {
    var token: cancel.Token = .{};
    token.request();
    const Sink = struct {
        fn line(_: ?*anyopaque, _: []const u8) !void {
            return error.UnexpectedResponse;
        }
    };
    try std.testing.expectError(error.Cancelled, postStreamWithToken(std.testing.failing_allocator, std.testing.io, "https://example.invalid", "application/json", &.{}, "{}", null, Sink.line, &token));
}

test "cancellation during request setup takes precedence over its failure" {
    var token: cancel.Token = .{};
    const Setup = struct {
        fn alloc(raw: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            const cancellation: *cancel.Token = @ptrCast(@alignCast(raw));
            cancellation.request();
            return null;
        }

        fn line(_: ?*anyopaque, _: []const u8) !void {
            return error.UnexpectedResponse;
        }
    };
    var vtable = std.testing.failing_allocator.vtable.*;
    vtable.alloc = Setup.alloc;
    const allocator: std.mem.Allocator = .{ .ptr = &token, .vtable = &vtable };
    try std.testing.expectError(error.Cancelled, postStreamWithToken(allocator, std.testing.io, "https://example.invalid", "application/json", &.{}, "{}", null, Setup.line, &token));
}

test "HTTP response helpers" {
    try std.testing.expectEqual(@as(?u16, 429), parseStatus("HTTP/2 429 Too Many Requests"));
    try std.testing.expectEqualStrings(" 7", headerValue("Retry-After: 7", "retry-after").?);
    try std.testing.expectEqual(@as(?[]const u8, null), headerValue("Content-Type: text/plain", "retry-after"));
}

test "provider error messages handle OAuth and nested API errors" {
    const oauth = errorMessage(std.testing.allocator, "{\"error\":\"invalid_grant\",\"error_description\":\"Authorization code expired\"}").?;
    defer std.testing.allocator.free(oauth);
    try std.testing.expectEqualStrings("Authorization code expired", oauth);

    const nested = errorMessage(std.testing.allocator, "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Try again later\"}}").?;
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("Try again later", nested);

    const streamed = errorMessage(std.testing.allocator, "{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Model unavailable\"}}}").?;
    defer std.testing.allocator.free(streamed);
    try std.testing.expectEqualStrings("Model unavailable", streamed);
}

test "curl config rejects header injection" {
    try std.testing.expectError(error.InvalidHeader, tryHeader(std.testing.allocator, "Authorization", "x\ny"));
}

test "buffered response lines need no allocation and include an unterminated tail" {
    var reader: Io.Reader = .fixed("one\ntwo\n\ntail");
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var line: Io.Writer.Allocating = .init(failing.allocator());
    defer line.deinit();

    try std.testing.expectEqualStrings("one", (try nextResponseLine(&reader, &line)).?);
    try std.testing.expectEqualStrings("two", (try nextResponseLine(&reader, &line)).?);
    try std.testing.expectEqualStrings("", (try nextResponseLine(&reader, &line)).?);
    try std.testing.expectEqualStrings("tail", (try nextResponseLine(&reader, &line)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try nextResponseLine(&reader, &line));
}

test "response lines grow beyond the read buffer and reuse their allocation" {
    const input = try std.testing.allocator.alloc(u8, response_read_buffer_bytes * 2 + 1);
    defer std.testing.allocator.free(input);
    @memset(input, 'x');
    input[input.len - 1] = '\n';
    var read_buffer: [response_read_buffer_bytes]u8 = undefined;
    var reader: std.testing.Reader = .init(&read_buffer, &.{
        .{ .buffer = input },
        .{ .buffer = "short\n" },
        .{ .buffer = input[0 .. input.len - 1] },
    });
    var line: Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();

    const result = (try nextResponseLine(&reader.interface, &line)).?;
    try std.testing.expectEqual(input.len - 1, result.len);
    try std.testing.expectEqualSlices(u8, input[0 .. input.len - 1], result);
    const capacity = line.writer.buffer.len;
    try std.testing.expect(capacity >= result.len);
    try std.testing.expectEqualStrings("short", (try nextResponseLine(&reader.interface, &line)).?);
    try std.testing.expectEqualSlices(u8, input[0 .. input.len - 1], (try nextResponseLine(&reader.interface, &line)).?);
    try std.testing.expectEqual(capacity, line.writer.buffer.len);
    try std.testing.expectEqual(@as(?[]const u8, null), try nextResponseLine(&reader.interface, &line));
}

test "response lines handle fragmented reads and buffer rebasing" {
    var read_buffer: [8]u8 = undefined;
    var reader: std.testing.Reader = .init(&read_buffer, &.{.{ .buffer = "one\ntwo\nthree\n\ntail" }});
    reader.artificial_limit = .limited(2);
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var line: Io.Writer.Allocating = .init(failing.allocator());
    defer line.deinit();
    for ([_][]const u8{ "one", "two", "three", "", "tail" }) |expected| {
        try std.testing.expectEqualStrings(expected, (try nextResponseLine(&reader.interface, &line)).?);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), try nextResponseLine(&reader.interface, &line));
}

test "response lines enforce the size limit for buffered and streamed input" {
    const input = try std.testing.allocator.alloc(u8, max_response_line_bytes + 2);
    defer std.testing.allocator.free(input);
    @memset(input, 'x');
    input[max_response_line_bytes] = '\n';
    input[max_response_line_bytes + 1] = '\n';
    var line: Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();
    var read_buffer: [response_read_buffer_bytes]u8 = undefined;

    var fixed: Io.Reader = .fixed(input);
    try std.testing.expectEqual(max_response_line_bytes, (try nextResponseLine(&fixed, &line)).?.len);
    var streamed: std.testing.Reader = .init(&read_buffer, &.{.{ .buffer = input }});
    try std.testing.expectEqual(max_response_line_bytes, (try nextResponseLine(&streamed.interface, &line)).?.len);

    input[max_response_line_bytes] = 'x';
    fixed = .fixed(input);
    try std.testing.expectError(error.StreamTooLong, nextResponseLine(&fixed, &line));
    streamed = .init(&read_buffer, &.{.{ .buffer = input }});
    try std.testing.expectError(error.StreamTooLong, nextResponseLine(&streamed.interface, &line));

    const unterminated = input[0 .. max_response_line_bytes + 1];
    fixed = .fixed(unterminated);
    try std.testing.expectError(error.StreamTooLong, nextResponseLine(&fixed, &line));
    streamed = .init(&read_buffer, &.{.{ .buffer = unterminated }});
    try std.testing.expectError(error.StreamTooLong, nextResponseLine(&streamed.interface, &line));
}

test "request body files survive name collisions and failed writes clean up" {
    const Fault = struct {
        threadlocal var bytes: [12]u8 = undefined;
        fn random(_: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
            @memcpy(buffer, &bytes);
        }
        fn partial(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
            if (operation == .file_write_streaming) {
                var write = operation.file_write_streaming;
                const body = write.data[0];
                if (!std.mem.startsWith(u8, body, "request")) return .{ .file_write_streaming = error.NoSpaceLeft };
                write.data = &.{body[0..3]};
                return std.testing.io.vtable.operate(userdata, .{ .file_write_streaming = write });
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    const gpa = std.testing.allocator;
    // Repeat a fresh random name within this test without colliding with
    // another test process that is running the same regression concurrently.
    try std.testing.io.randomSecure(&Fault.bytes);
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = Fault.random;
    const io: Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const path = try requestFile(gpa, io, "original request body");
    defer gpa.free(path);
    defer Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.testing.expectError(error.PathAlreadyExists, requestFile(gpa, io, "replacement body"));
    const retained = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1024));
    defer gpa.free(retained);
    try std.testing.expectEqualStrings("original request body", retained);

    try Io.Dir.cwd().deleteFile(std.testing.io, path);
    vtable.operate = Fault.partial;
    try std.testing.expectError(error.NoSpaceLeft, requestFile(gpa, io, "request body interrupted"));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(std.testing.io, path, .{}));
    vtable.operate = std.testing.io.vtable.operate;
    const retried = try requestFile(gpa, io, "retry request body");
    defer gpa.free(retried);
    const saved = try Io.Dir.cwd().readFileAlloc(std.testing.io, retried, gpa, .limited(1024));
    defer gpa.free(saved);
    try std.testing.expectEqualStrings("retry request body", saved);
}
