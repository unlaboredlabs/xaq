const std = @import("std");
const Io = std.Io;
const cancel = @import("cancel.zig");
const transport = @import("transport.zig");

pub const names = [_][]const u8{ "read", "bash", "edit", "write" };
pub const web_names = [_][]const u8{ "web_fetch", "web_search" };
pub const max_output = 50 * 1024;
const output_payload = max_output - 512;
const firecrawl_base_url = "https://api.firecrawl.dev/v2";

/// A host-defined tool. `parameters_json` must be a JSON Schema object.
/// The embedding API validates it before the first request.
pub const Definition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const SchemaOptions = struct {
    include_builtin: bool = true,
    web_enabled: bool = false,
    write_enabled: bool = true,
    /// Reserved for the process-manager integration added in the next layer.
    subagents_enabled: bool = false,
    custom: []const Definition = &.{},
};

pub const ExecuteContext = struct {
    /// Base for built-in relative paths and shell commands. Null inherits the
    /// process working directory for CLI compatibility.
    cwd: ?[]const u8 = null,
    firecrawl_api_key: ?[]const u8 = null,
    write_enabled: bool = true,
    cancellation: ?*cancel.Token = null,
};

pub fn schemas(s: *std.json.Stringify) !void {
    return schemasWithOptions(s, .{});
}

pub fn schemasWithOptions(s: *std.json.Stringify, options: SchemaOptions) !void {
    try s.beginArray();
    if (options.include_builtin) {
        try schema(s, "read", "Read a text file. Paths may be relative or absolute.",
            \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}
        );
        try schema(s, "bash", "Run a shell command in the current directory with full host permissions.",
            \\{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"integer","minimum":1,"maximum":3600}},"required":["command"],"additionalProperties":false}
        );
    }
    if (options.include_builtin and options.write_enabled) {
        try schema(s, "edit", "Apply exact, non-overlapping text replacements to a file.",
            \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"oldText":{"type":"string"},"newText":{"type":"string"}},"required":["oldText","newText"],"additionalProperties":false},"minItems":1}},"required":["path","edits"],"additionalProperties":false}
        );
        try schema(s, "write", "Create or overwrite a text file, creating parent directories.",
            \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}
        );
    }
    if (options.include_builtin and options.web_enabled) {
        try schema(s, "web_fetch", "Fetch a public URL and return its main content as Markdown.",
            \\{"type":"object","properties":{"url":{"type":"string","maxLength":8192}},"required":["url"],"additionalProperties":false}
        );
        try schema(s, "web_search", "Search the web and return result titles, URLs, and descriptions.",
            \\{"type":"object","properties":{"query":{"type":"string","maxLength":500},"limit":{"type":"integer","minimum":1,"maximum":10}},"required":["query"],"additionalProperties":false}
        );
    }
    for (options.custom) |definition| try schema(s, definition.name, definition.description, definition.parameters_json);
    try s.endArray();
}

pub fn claudeSchemas(s: *std.json.Stringify) !void {
    return claudeSchemasWithOptions(s, .{});
}

pub fn claudeSchemasWithOptions(s: *std.json.Stringify, options: SchemaOptions) !void {
    try s.beginArray();
    if (options.include_builtin) {
        try claudeSchema(s, "read", "Read a text file. Paths may be relative or absolute.",
            \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}
        );
        try claudeSchema(s, "bash", "Run a shell command in the current directory with full host permissions.",
            \\{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"integer","minimum":1,"maximum":3600}},"required":["command"],"additionalProperties":false}
        );
    }
    if (options.include_builtin and options.write_enabled) {
        try claudeSchema(s, "edit", "Apply exact, non-overlapping text replacements to a file.",
            \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"oldText":{"type":"string"},"newText":{"type":"string"}},"required":["oldText","newText"],"additionalProperties":false},"minItems":1}},"required":["path","edits"],"additionalProperties":false}
        );
        try claudeSchema(s, "write", "Create or overwrite a text file, creating parent directories.",
            \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}
        );
    }
    if (options.include_builtin and options.web_enabled) {
        try claudeSchema(s, "web_fetch", "Fetch a public URL and return its main content as Markdown.",
            \\{"type":"object","properties":{"url":{"type":"string","maxLength":8192}},"required":["url"],"additionalProperties":false}
        );
        try claudeSchema(s, "web_search", "Search the web and return result titles, URLs, and descriptions.",
            \\{"type":"object","properties":{"query":{"type":"string","maxLength":500},"limit":{"type":"integer","minimum":1,"maximum":10}},"required":["query"],"additionalProperties":false}
        );
    }
    for (options.custom) |definition| try claudeSchema(s, definition.name, definition.description, definition.parameters_json);
    try s.endArray();
}

fn schema(s: *std.json.Stringify, name: []const u8, description: []const u8, parameters: []const u8) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("function");
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("parameters");
    try rawValue(s, parameters);
    try s.endObject();
}

fn claudeSchema(s: *std.json.Stringify, name: []const u8, description: []const u8, parameters: []const u8) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("input_schema");
    try rawValue(s, parameters);
    try s.endObject();
}

fn rawValue(s: *std.json.Stringify, value: []const u8) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll(value);
    s.endWriteRaw();
}

pub fn execute(gpa: std.mem.Allocator, io: Io, name: []const u8, args: std.json.Value) ![]u8 {
    return executeWithContext(gpa, io, name, args, .{});
}

pub fn executeWithContext(gpa: std.mem.Allocator, io: Io, name: []const u8, args: std.json.Value, context: ExecuteContext) ![]u8 {
    if (std.mem.eql(u8, name, "read")) return read(gpa, io, args, context.cwd);
    if (std.mem.eql(u8, name, "bash")) return bash(gpa, io, args, context.cancellation orelse cancel.processToken(), context.cwd);
    if (std.mem.eql(u8, name, "edit")) return if (context.write_enabled) edit(gpa, io, args, context.cwd) else gpa.dupe(u8, "edit is disabled");
    if (std.mem.eql(u8, name, "write")) return if (context.write_enabled) write(gpa, io, args, context.cwd) else gpa.dupe(u8, "write is disabled");
    if (std.mem.eql(u8, name, "web_fetch")) return webFetch(gpa, io, context.firecrawl_api_key orelse return gpa.dupe(u8, "web_fetch is not configured"), args);
    if (std.mem.eql(u8, name, "web_search")) return webSearch(gpa, io, context.firecrawl_api_key orelse return gpa.dupe(u8, "web_search is not configured"), args);
    return std.fmt.allocPrint(gpa, "unknown tool: {s}", .{name});
}

fn fieldString(args: std.json.Value, key: []const u8) ![]const u8 {
    const value = switch (args) {
        .object => |o| o.get(key) orelse return error.MissingField,
        else => return error.InvalidArguments,
    };
    return switch (value) {
        .string => |v| v,
        else => error.InvalidArguments,
    };
}

fn optionalInt(args: std.json.Value, key: []const u8) ?i64 {
    const value = switch (args) {
        .object => |o| o.get(key) orelse return null,
        else => return null,
    };
    return switch (value) {
        .integer => |v| v,
        else => null,
    };
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn objectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .string => |text| text,
        else => null,
    };
}

fn objectBool(value: std.json.Value, key: []const u8) ?bool {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .bool => |flag| flag,
        else => null,
    };
}

fn validPublicUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://");
}

fn firecrawlPost(gpa: std.mem.Allocator, io: Io, api_key: []const u8, endpoint: []const u8, body: []const u8) !transport.Response {
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});
    defer gpa.free(authorization);
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ firecrawl_base_url, endpoint });
    defer gpa.free(url);
    return transport.post(gpa, io, url, "application/json", &.{.{ .name = "Authorization", .value = authorization }}, body);
}

fn firecrawlFailure(gpa: std.mem.Allocator, status: u16, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return std.fmt.allocPrint(gpa, "Firecrawl request failed (HTTP {d})", .{status});
    defer parsed.deinit();
    const message = objectString(parsed.value, "error") orelse objectString(parsed.value, "message") orelse "request failed";
    return std.fmt.allocPrint(gpa, "Firecrawl request failed (HTTP {d}): {s}", .{ status, message[0..@min(message.len, 4096)] });
}

fn boundedDocument(gpa: std.mem.Allocator, title: ?[]const u8, url: []const u8, markdown_text: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (title) |value| try out.writer.print("Title: {s}\n", .{value[0..@min(value.len, 4096)]});
    try out.writer.print("URL: {s}\n\n", .{url[0..@min(url.len, 8192)]});
    const suffix = "\n\n[content truncated]";
    const available = output_payload -| out.written().len;
    if (markdown_text.len <= available) {
        try out.writer.writeAll(markdown_text);
    } else {
        const keep = available -| suffix.len;
        try out.writer.writeAll(markdown_text[0..keep]);
        try out.writer.writeAll(suffix);
    }
    return out.toOwnedSlice();
}

fn webFetch(gpa: std.mem.Allocator, io: Io, api_key: []const u8, args: std.json.Value) ![]u8 {
    const url = try fieldString(args, "url");
    if (url.len == 0 or url.len > 8192 or !validPublicUrl(url)) return error.InvalidUrl;

    var request: Io.Writer.Allocating = .init(gpa);
    defer request.deinit();
    var js: std.json.Stringify = .{ .writer = &request.writer };
    try js.beginObject();
    try js.objectField("url");
    try js.write(url);
    try js.objectField("formats");
    try js.beginArray();
    try js.write("markdown");
    try js.endArray();
    try js.objectField("onlyMainContent");
    try js.write(true);
    try js.endObject();

    const response = try firecrawlPost(gpa, io, api_key, "scrape", request.written());
    defer gpa.free(response.body);
    if (response.status < 200 or response.status >= 300) return firecrawlFailure(gpa, response.status, response.body);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, response.body, .{}) catch return error.InvalidFirecrawlResponse;
    defer parsed.deinit();
    if (objectBool(parsed.value, "success") != true) return firecrawlFailure(gpa, response.status, response.body);
    const data = objectField(parsed.value, "data") orelse return error.InvalidFirecrawlResponse;
    const markdown_text = objectString(data, "markdown") orelse return error.InvalidFirecrawlResponse;
    const metadata = objectField(data, "metadata");
    const title = if (metadata) |value| objectString(value, "title") else null;
    const source_url = if (metadata) |value| objectString(value, "sourceURL") orelse objectString(value, "url") orelse url else url;
    return boundedDocument(gpa, title, source_url, markdown_text);
}

fn appendSearchResult(writer: *Io.Writer, index: usize, value: std.json.Value) !bool {
    var url_value = objectString(value, "url");
    if (url_value == null) {
        if (objectField(value, "metadata")) |metadata| url_value = objectString(metadata, "sourceURL");
    }
    const url = url_value orelse return false;
    const title = objectString(value, "title") orelse url;
    const description = objectString(value, "description");
    try writer.print("{d}. {s}\n   {s}\n", .{ index, title[0..@min(title.len, 4096)], url[0..@min(url.len, 8192)] });
    if (description) |text| if (text.len > 0) try writer.print("   {s}\n", .{text[0..@min(text.len, 8192)]});
    return true;
}

fn formatSearchResults(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    if (objectBool(parsed.value, "success") != true) return error.InvalidFirecrawlResponse;
    const data = objectField(parsed.value, "data") orelse return error.InvalidFirecrawlResponse;
    const web = objectField(data, "web") orelse return error.InvalidFirecrawlResponse;
    const results = switch (web) {
        .array => |array| array.items,
        else => return error.InvalidFirecrawlResponse,
    };
    if (results.len == 0) return gpa.dupe(u8, "No web results found.");

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var rendered: usize = 0;
    for (results) |result| {
        var item: Io.Writer.Allocating = .init(gpa);
        defer item.deinit();
        if (!try appendSearchResult(&item.writer, rendered + 1, result)) continue;
        if (out.written().len + item.written().len > output_payload) {
            try out.writer.writeAll("[results truncated]\n");
            break;
        }
        try out.writer.writeAll(item.written());
        rendered += 1;
    }
    if (rendered == 0) return gpa.dupe(u8, "No valid web results found.");
    return out.toOwnedSlice();
}

fn webSearch(gpa: std.mem.Allocator, io: Io, api_key: []const u8, args: std.json.Value) ![]u8 {
    const query = try fieldString(args, "query");
    if (query.len == 0 or query.len > 500) return error.InvalidArguments;
    const limit: i64 = @min(@max(optionalInt(args, "limit") orelse 5, 1), 10);

    var request: Io.Writer.Allocating = .init(gpa);
    defer request.deinit();
    var js: std.json.Stringify = .{ .writer = &request.writer };
    try js.beginObject();
    try js.objectField("query");
    try js.write(query);
    try js.objectField("limit");
    try js.write(limit);
    try js.objectField("sources");
    try js.beginArray();
    try js.write("web");
    try js.endArray();
    try js.endObject();

    const response = try firecrawlPost(gpa, io, api_key, "search", request.written());
    defer gpa.free(response.body);
    if (response.status < 200 or response.status >= 300) return firecrawlFailure(gpa, response.status, response.body);
    return formatSearchResults(gpa, response.body);
}

fn read(gpa: std.mem.Allocator, io: Io, args: std.json.Value, cwd: ?[]const u8) ![]u8 {
    const requested_path = try fieldString(args, "path");
    const resolved = try resolvePath(gpa, cwd, requested_path);
    defer resolved.deinit(gpa);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, resolved.value, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);
    const offset: usize = @intCast(@max(optionalInt(args, "offset") orelse 1, 1));
    const limit: usize = @intCast(@max(optionalInt(args, "limit") orelse 2000, 1));

    if (bytes.len == 0) return gpa.dupe(u8, "");
    var line: usize = 1;
    var start: usize = 0;
    while (line < offset and start < bytes.len) : (line += 1) {
        start = (std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len - 1) + 1;
    }
    var end = start;
    var taken: usize = 0;
    while (taken < limit and end < bytes.len) : (taken += 1) {
        end = (std.mem.indexOfScalarPos(u8, bytes, end, '\n') orelse bytes.len - 1) + 1;
    }
    const logical_end = @min(end, bytes.len);
    end = @min(logical_end, @min(bytes.len, start + output_payload));
    if (end == bytes.len and logical_end == bytes.len) return gpa.dupe(u8, bytes[start..end]);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(bytes[start..end]);
    const consumed_lines = std.mem.count(u8, bytes[start..end], "\n");
    if (consumed_lines == 0) {
        // A single line larger than the output budget: advancing by zero
        // would make every continuation return the same prefix forever.
        try out.writer.print("\n[truncated: line {d} exceeds the output budget; offset={d} skips its remainder]", .{ offset, offset + 1 });
    } else {
        try out.writer.print("\n[truncated: continue with offset={d}]", .{offset + consumed_lines});
    }
    return out.toOwnedSlice();
}

fn bash(gpa: std.mem.Allocator, io: Io, args: std.json.Value, token: *cancel.Token, cwd: ?[]const u8) ![]u8 {
    const command = try fieldString(args, "command");
    const seconds: u64 = @intCast(@min(@max(optionalInt(args, "timeout") orelse 600, 1), 3600));
    const script = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{command});
    defer gpa.free(script);
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/bash", "-lc", script },
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
        .pgid = 0,
    });
    defer if (child.id != null) child.kill(io);
    token.setChild(child.id.?);
    defer token.clearChild();

    var timed_out = std.atomic.Value(bool).init(false);
    var timer = Io.async(io, killAfter, .{ io, child.id.?, seconds, &timed_out });
    defer timer.cancel(io) catch {};

    var capture = Capture.init(gpa, io);
    defer capture.deinit();
    // On error paths the spill file would never be reported; remove it
    // rather than leaking 0600 temp files with partial output.
    errdefer capture.discardSpill();
    var read_buffer: [8192]u8 = undefined;
    var file_reader: Io.File.Reader = .init(child.stdout.?, io, &read_buffer);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const count = try file_reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        try capture.write(chunk[0..count]);
    }
    child.stdout.?.close(io);
    child.stdout = null;
    const term = try child.wait(io);
    // Unregister promptly: after wait the pid may be recycled, and the
    // SIGINT handler must not TERM an unrelated process group.
    token.clearChild();
    timer.cancel(io) catch {};

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (capture.spill_path) |path| {
        try out.writer.print("[output truncated: full output saved at {s}; showing last {d} bytes]\n", .{ path, capture.tail.items.len });
    }
    try out.writer.writeAll(capture.tail.items);
    if (timed_out.load(.seq_cst)) {
        try out.writer.print("\n[timeout after {d}s]", .{seconds});
    } else if (token.isRequested()) {
        try out.writer.writeAll("\n[interrupted]");
    }
    switch (term) {
        .exited => |code| if (code != 0) try out.writer.print("\n[exit {d}]", .{code}),
        .signal => |sig| try out.writer.print("\n[signal {d}]", .{@intFromEnum(sig)}),
        else => try out.writer.writeAll("\n[process terminated]"),
    }
    return out.toOwnedSlice();
}

fn killAfter(io: Io, pid: std.posix.pid_t, seconds: u64, timed_out: *std.atomic.Value(bool)) Io.Cancelable!void {
    try io.sleep(.fromSeconds(@intCast(seconds)), .awake);
    timed_out.store(true, .seq_cst);
    std.posix.kill(-pid, .TERM) catch return;
    // Once TERM is sent the KILL follow-up must not be skippable: a
    // descendant that ignores TERM but lets the leader exit would
    // otherwise survive when this task is cancelled during the grace
    // sleep. Swallow cancellation for the final escalation.
    io.sleep(.fromSeconds(2), .awake) catch {};
    std.posix.kill(-pid, .KILL) catch {};
}

const Capture = struct {
    gpa: std.mem.Allocator,
    io: Io,
    tail: std.ArrayList(u8) = .empty,
    spill: ?Io.File = null,
    spill_path: ?[]u8 = null,

    fn init(gpa: std.mem.Allocator, io: Io) Capture {
        return .{ .gpa = gpa, .io = io };
    }

    fn deinit(self: *Capture) void {
        if (self.spill) |file| file.close(self.io);
        self.tail.deinit(self.gpa);
        if (self.spill_path) |path| self.gpa.free(path);
    }

    /// Delete the spill file on tool error paths, where its path would
    /// never be reported to anyone.
    fn discardSpill(self: *Capture) void {
        const path = self.spill_path orelse return;
        if (self.spill) |file| file.close(self.io);
        self.spill = null;
        Io.Dir.cwd().deleteFile(self.io, path) catch {};
        self.gpa.free(path);
        self.spill_path = null;
    }

    fn write(self: *Capture, bytes: []const u8) !void {
        if (self.spill == null and self.tail.items.len + bytes.len > output_payload) try self.startSpill();
        if (self.spill) |file| try file.writeStreamingAll(self.io, bytes);
        if (bytes.len >= output_payload) {
            self.tail.clearRetainingCapacity();
            try self.tail.appendSlice(self.gpa, bytes[bytes.len - output_payload ..]);
            return;
        }
        const overflow = (self.tail.items.len + bytes.len) -| output_payload;
        if (overflow > 0) {
            std.mem.copyForwards(u8, self.tail.items[0 .. self.tail.items.len - overflow], self.tail.items[overflow..]);
            self.tail.items.len -= overflow;
        }
        try self.tail.appendSlice(self.gpa, bytes);
    }

    fn startSpill(self: *Capture) !void {
        var random: [8]u8 = undefined;
        try self.io.randomSecure(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const path = try std.fmt.allocPrint(self.gpa, "/tmp/xaq-tool-output-{s}.log", .{&hex});
        errdefer self.gpa.free(path);
        const file = try Io.Dir.cwd().createFile(self.io, path, .{
            .exclusive = true,
            .permissions = @enumFromInt(0o600),
        });
        errdefer file.close(self.io);
        try file.writeStreamingAll(self.io, self.tail.items);
        self.spill = file;
        self.spill_path = path;
    }
};

fn ensureParent(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try Io.Dir.cwd().createDirPath(io, parent);
    }
}

/// Write via a same-directory temp file plus rename so ENOSPC or a kill
/// mid-write can never leave the destination truncated.
fn atomicWrite(gpa: std.mem.Allocator, io: Io, path: []const u8, data: []const u8) !void {
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(gpa, "{s}.xaq-tmp-{s}", .{ path, &hex });
    defer gpa.free(temporary);
    errdefer Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = temporary,
        .data = data,
        .flags = .{ .exclusive = true },
    });
    try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), path, io);
}

fn write(gpa: std.mem.Allocator, io: Io, args: std.json.Value, cwd: ?[]const u8) ![]u8 {
    const requested_path = try fieldString(args, "path");
    const resolved = try resolvePath(gpa, cwd, requested_path);
    defer resolved.deinit(gpa);
    const content = try fieldString(args, "content");
    try ensureParent(io, resolved.value);
    try atomicWrite(gpa, io, resolved.value, content);
    return std.fmt.allocPrint(gpa, "wrote {d} bytes to {s}", .{ content.len, requested_path });
}

const Replacement = struct { start: usize, end: usize, text: []const u8 };

fn lessThan(_: void, a: Replacement, b: Replacement) bool {
    return a.start < b.start;
}

fn edit(gpa: std.mem.Allocator, io: Io, args: std.json.Value, cwd: ?[]const u8) ![]u8 {
    const requested_path = try fieldString(args, "path");
    const resolved = try resolvePath(gpa, cwd, requested_path);
    defer resolved.deinit(gpa);
    const values = switch (args) {
        .object => |o| switch (o.get("edits") orelse return error.MissingField) {
            .array => |a| a.items,
            else => return error.InvalidArguments,
        },
        else => return error.InvalidArguments,
    };
    if (values.len == 0) return error.InvalidArguments;
    const original = try Io.Dir.cwd().readFileAlloc(io, resolved.value, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(original);
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(gpa);

    for (values) |value| {
        const old = try fieldString(value, "oldText");
        const new = try fieldString(value, "newText");
        if (old.len == 0) return error.EmptyOldText;
        const start = std.mem.indexOf(u8, original, old) orelse return error.TextNotFound;
        // Search from start + 1, not start + old.len: overlapping
        // occurrences ("aaa" in "aaaa") are ambiguous too.
        if (std.mem.indexOfPos(u8, original, start + 1, old) != null) return error.TextNotUnique;
        try replacements.append(gpa, .{ .start = start, .end = start + old.len, .text = new });
    }
    std.mem.sort(Replacement, replacements.items, {}, lessThan);
    for (replacements.items[1..], replacements.items[0 .. replacements.items.len - 1]) |next, prev| {
        if (next.start < prev.end) return error.OverlappingEdits;
    }

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var cursor: usize = 0;
    for (replacements.items) |replacement| {
        try out.writer.writeAll(original[cursor..replacement.start]);
        try out.writer.writeAll(replacement.text);
        cursor = replacement.end;
    }
    try out.writer.writeAll(original[cursor..]);
    try atomicWrite(gpa, io, resolved.value, out.written());
    return std.fmt.allocPrint(gpa, "applied {d} edit(s) to {s}", .{ replacements.items.len, requested_path });
}

const ResolvedPath = struct {
    value: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: ResolvedPath, gpa: std.mem.Allocator) void {
        if (self.owned) |path| gpa.free(path);
    }
};

fn resolvePath(gpa: std.mem.Allocator, cwd: ?[]const u8, path: []const u8) !ResolvedPath {
    if (cwd == null or std.fs.path.isAbsolute(path)) return .{ .value = path };
    const joined = try std.fs.path.join(gpa, &.{ cwd.?, path });
    return .{ .value = joined, .owned = joined };
}

test "tool names match pi defaults" {
    try std.testing.expectEqualStrings("read", names[0]);
    try std.testing.expectEqualStrings("bash", names[1]);
    try std.testing.expectEqualStrings("edit", names[2]);
    try std.testing.expectEqualStrings("write", names[3]);
}

test "write tools can be omitted" {
    var worker: Io.Writer.Allocating = .init(std.testing.allocator);
    defer worker.deinit();
    var worker_json: std.json.Stringify = .{ .writer = &worker.writer };
    try schemasWithOptions(&worker_json, .{ .write_enabled = false });
    try std.testing.expect(std.mem.indexOf(u8, worker.written(), "\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, worker.written(), "\"name\":\"edit\"") == null);
}

test "bash combines stdout and stderr in production order" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"command":"printf 'one\\n'; printf 'two\\n' >&2","timeout":5}
    , .{});
    defer parsed.deinit();
    const result = try execute(std.testing.allocator, std.testing.io, "bash", parsed.value);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("one\ntwo\n", result);
}

test "tool context anchors relative files and commands to its cwd" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "inside" });
    const cwd = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(cwd);

    var read_args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"path\":\"note.txt\"}", .{});
    defer read_args.deinit();
    const contents = try executeWithContext(std.testing.allocator, std.testing.io, "read", read_args.value, .{ .cwd = cwd });
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("inside", contents);

    var bash_args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"command\":\"pwd\"}", .{});
    defer bash_args.deinit();
    const location = try executeWithContext(std.testing.allocator, std.testing.io, "bash", bash_args.value, .{ .cwd = cwd });
    defer std.testing.allocator.free(location);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trim(u8, location, "\n"), cwd));
}

test "Firecrawl search results are formatted for the model" {
    const result = try formatSearchResults(std.testing.allocator,
        \\{"success":true,"data":{"web":[{"title":"Example","url":"https://example.com","description":"A test page."}]}}
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1. Example\n   https://example.com\n   A test page.\n", result);
}

test "Firecrawl documents are capped to the tool output budget" {
    const markdown_text = try std.testing.allocator.alloc(u8, max_output * 2);
    defer std.testing.allocator.free(markdown_text);
    @memset(markdown_text, 'x');
    const result = try boundedDocument(std.testing.allocator, "Example", "https://example.com", markdown_text);
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len <= max_output);
    try std.testing.expect(std.mem.endsWith(u8, result, "[content truncated]"));
}
