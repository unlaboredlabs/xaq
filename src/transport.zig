const std = @import("std");
const Io = std.Io;

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Response = struct { status: u16, body: []u8 };

/// Deliberately tiny HTTPS transport. curl supplies the mature platform TLS
/// stack; the provider and agent protocols remain native Zig code.
pub fn post(gpa: std.mem.Allocator, io: Io, url: []const u8, content_type: []const u8, headers: []const Header, body: []const u8) !Response {
    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    var encoded: [24]u8 = undefined;
    const suffix = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random);
    const path = try std.fmt.allocPrint(gpa, "/tmp/xaq-request-{s}", .{suffix});
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body, .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o600) } });
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var owned_headers: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_headers.items) |header| gpa.free(header);
        owned_headers.deinit(gpa);
    }
    try argv.appendSlice(gpa, &.{ "curl", "-sS", "--no-buffer", "-X", "POST", "-H" });
    const ct = try std.fmt.allocPrint(gpa, "Content-Type: {s}", .{content_type});
    defer gpa.free(ct);
    try argv.append(gpa, ct);
    for (headers) |header| {
        try argv.append(gpa, "-H");
        const owned = try std.fmt.allocPrint(gpa, "{s}: {s}", .{ header.name, header.value });
        try owned_headers.append(gpa, owned);
        try argv.append(gpa, owned);
    }
    const data_arg = try std.fmt.allocPrint(gpa, "@{s}", .{path});
    defer gpa.free(data_arg);
    try argv.appendSlice(gpa, &.{ "--data-binary", data_arg, "--write-out", "\n%{http_code}", url });

    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(600), .clock = .awake } },
    });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    const code = switch (result.term) {
        .exited => |v| v,
        else => 255,
    };
    if (code != 0) {
        std.debug.print("curl: {s}\n", .{result.stderr});
        return error.TransportFailed;
    }
    const split = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse return error.InvalidHttpResponse;
    const status = std.fmt.parseInt(u16, result.stdout[split + 1 ..], 10) catch return error.InvalidHttpResponse;
    const response_body = try gpa.dupe(u8, result.stdout[0..split]);
    gpa.free(result.stdout);
    return .{ .status = status, .body = response_body };
}

pub fn formEncode(gpa: std.mem.Allocator, fields: []const struct { []const u8, []const u8 }) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (fields, 0..) |field, i| {
        if (i != 0) try out.writer.writeByte('&');
        try percent(&out.writer, field[0]);
        try out.writer.writeByte('=');
        try percent(&out.writer, field[1]);
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
