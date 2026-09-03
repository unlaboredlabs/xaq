const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const cancel = @import("cancel.zig");
const models = @import("models.zig");
const subagents = @import("subagents.zig");
const transport = @import("transport.zig");

pub const names = [_][]const u8{ "read", "bash", "edit", "write" };
pub const web_names = [_][]const u8{ "web_fetch", "web_search" };
pub const max_output = 50 * 1024;
const output_payload = max_output - 512;
const max_read_file_bytes = 16 * 1024 * 1024;
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
    subagents_enabled: bool = false,
    subagent_launch: ?subagents.Launch = null,
    subagent_max_concurrent: u8 = subagents.default_max_concurrent,
    custom: []const Definition = &.{},
};

pub const ExecuteContext = struct {
    /// Base for built-in relative paths and shell commands. Null inherits the
    /// process working directory for CLI compatibility.
    cwd: ?[]const u8 = null,
    firecrawl_api_key: ?[]const u8 = null,
    write_enabled: bool = true,
    subagent_manager: ?*subagents.Manager = null,
    subagent_launch: ?subagents.Launch = null,
    cancellation: ?*cancel.Token = null,
};

pub fn schemas(s: *std.json.Stringify, web_enabled: bool) !void {
    return schemasWithOptions(s, .{ .web_enabled = web_enabled });
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
            \\{"type":"object","properties":{"url":{"type":"string","minLength":1,"maxLength":8192}},"required":["url"],"additionalProperties":false}
        );
        try schema(s, "web_search", "Search the web and return result titles, URLs, and descriptions.",
            \\{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":500},"limit":{"type":"integer","minimum":1,"maximum":10,"description":"Number of results to return; defaults to 5."}},"required":["query"],"additionalProperties":false}
        );
    }
    if (options.include_builtin and options.subagents_enabled) try subagentSchemas(s, false, options);
    for (options.custom) |definition| try schema(s, definition.name, definition.description, definition.parameters_json);
    try s.endArray();
}

pub fn claudeSchemas(s: *std.json.Stringify, web_enabled: bool) !void {
    return claudeSchemasWithOptions(s, .{ .web_enabled = web_enabled });
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
            \\{"type":"object","properties":{"url":{"type":"string","minLength":1,"maxLength":8192}},"required":["url"],"additionalProperties":false}
        );
        try claudeSchema(s, "web_search", "Search the web and return result titles, URLs, and descriptions.",
            \\{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":500},"limit":{"type":"integer","minimum":1,"maximum":10,"description":"Number of results to return; defaults to 5."}},"required":["query"],"additionalProperties":false}
        );
    }
    if (options.include_builtin and options.subagents_enabled) try subagentSchemas(s, true, options);
    for (options.custom) |definition| try claudeSchema(s, definition.name, definition.description, definition.parameters_json);
    try s.endArray();
}

fn subagentSchemas(s: *std.json.Stringify, claude: bool, options: SchemaOptions) !void {
    var description_buffer: [1024]u8 = undefined;
    const description = if (options.subagent_launch) |launch|
        std.fmt.bufPrint(&description_buffer, "Launch an autonomous subagent for a self-contained, multi-step task. Workers use provider={s} and cannot switch providers. Omit model to inherit {s}; valid overrides are listed in model.enum. Omit effort to inherit {s} when the model is inherited. Never guess or probe model IDs. Workers have workspace_write access with full host permissions; read_only is unavailable. At most {d} workers run at once and extra workers queue. Background is the default. Use get_subagent_result with wait true before relying on a result. Prompts must contain all context the worker needs.", .{ launch.provider, launch.model, launch.effort orelse "provider-default", options.subagent_max_concurrent }) catch unreachable
    else
        "Launch an autonomous subagent for a self-contained, multi-step task. Background is the default. Use get_subagent_result with wait true before relying on a result. Prompts must contain all context the worker needs.";
    const get_parameters =
        \\{"type":"object","properties":{"agent_id":{"type":"string"},"wait":{"type":"boolean","description":"Wait for completion. Defaults to false."}},"required":["agent_id"],"additionalProperties":false}
    ;
    const steer_parameters =
        \\{"type":"object","properties":{"agent_id":{"type":"string"},"message":{"type":"string","maxLength":65536}},"required":["agent_id","message"],"additionalProperties":false}
    ;
    if (claude) {
        try dynamicAgentSchema(s, true, description, options.subagent_launch);
        try claudeSchema(s, "get_subagent_result", "Check a background subagent's status and retrieve its result. Use wait true when the result gates your next action.", get_parameters);
        try claudeSchema(s, "steer_subagent", "Send a message that redirects a running or queued subagent before its next model turn.", steer_parameters);
    } else {
        try dynamicAgentSchema(s, false, description, options.subagent_launch);
        try schema(s, "get_subagent_result", "Check a background subagent's status and retrieve its result. Use wait true when the result gates your next action.", get_parameters);
        try schema(s, "steer_subagent", "Send a message that redirects a running or queued subagent before its next model turn.", steer_parameters);
    }
}

fn dynamicAgentSchema(s: *std.json.Stringify, claude: bool, description: []const u8, launch: ?subagents.Launch) !void {
    try s.beginObject();
    if (!claude) {
        try s.objectField("type");
        try s.write("function");
    }
    try s.objectField("name");
    try s.write("Agent");
    try s.objectField("description");
    try s.write(description);
    try s.objectField(if (claude) "input_schema" else "parameters");
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
    try s.objectField("prompt");
    try rawValue(s, "{\"type\":\"string\",\"maxLength\":4193280}");
    try s.objectField("description");
    try rawValue(s, "{\"type\":\"string\",\"maxLength\":120,\"description\":\"Short task label shown in the UI.\"}");
    try s.objectField("model");
    try s.beginObject();
    try s.objectField("type");
    try s.write("string");
    try s.objectField("maxLength");
    try s.write(256);
    if (launch) |runtime| {
        try s.objectField("description");
        try s.write("Optional model ID for the active provider. Omit it to inherit the parent model.");
        try s.objectField("enum");
        try s.beginArray();
        const provider = auth.Provider.parse(runtime.provider);
        if (provider) |value| {
            for (models.choices(value)) |model| try s.write(model);
            if (models.find(value, runtime.model) == null) try s.write(runtime.model);
        } else {
            try s.write(runtime.model);
        }
        try s.endArray();
    }
    try s.endObject();
    try s.objectField("effort");
    try s.beginObject();
    try s.objectField("type");
    try s.write("string");
    try s.objectField("description");
    try s.write("Optional reasoning effort. Omit it to inherit the parent effort when the model is inherited, or to use the provider default for a model override.");
    try s.objectField("enum");
    try s.beginArray();
    inline for (@typeInfo(models.Effort).@"enum".fields) |field| try s.write(field.name);
    try s.endArray();
    try s.endObject();
    try s.objectField("access");
    try s.beginObject();
    try s.objectField("type");
    try s.write("string");
    try s.objectField("description");
    try s.write("Effective worker access. Only workspace_write is available; workers receive bash, edit, and write tools with full host permissions.");
    try s.objectField("enum");
    try s.beginArray();
    try s.write("workspace_write");
    try s.endArray();
    try s.endObject();
    try s.objectField("run_in_background");
    try rawValue(s, "{\"type\":\"boolean\",\"description\":\"Defaults to true. Set false only when the next action depends on this result.\"}");
    try s.endObject();
    try s.objectField("required");
    try s.beginArray();
    try s.write("prompt");
    try s.write("description");
    try s.endArray();
    try s.objectField("additionalProperties");
    try s.write(false);
    try s.endObject();
    try s.endObject();
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

pub fn execute(gpa: std.mem.Allocator, io: Io, name: []const u8, args: std.json.Value, firecrawl_api_key: ?[]const u8) ![]u8 {
    return executeWithContext(gpa, io, name, args, .{ .firecrawl_api_key = firecrawl_api_key });
}

pub fn executeWithContext(gpa: std.mem.Allocator, io: Io, name: []const u8, args: std.json.Value, context: ExecuteContext) ![]u8 {
    if (std.mem.eql(u8, name, "read")) return read(gpa, io, args, context.cwd);
    if (std.mem.eql(u8, name, "bash")) return bash(gpa, io, args, context.cancellation orelse cancel.processToken(), context.cwd);
    if (std.mem.eql(u8, name, "edit")) return if (context.write_enabled) edit(gpa, io, args, context.cwd) else gpa.dupe(u8, "edit is disabled");
    if (std.mem.eql(u8, name, "write")) return if (context.write_enabled) write(gpa, io, args, context.cwd) else gpa.dupe(u8, "write is disabled");
    if (std.mem.eql(u8, name, "web_fetch")) return webFetch(gpa, io, context.firecrawl_api_key orelse return gpa.dupe(u8, "web_fetch is not configured"), args);
    if (std.mem.eql(u8, name, "web_search")) return webSearch(gpa, io, context.firecrawl_api_key orelse return gpa.dupe(u8, "web_search is not configured"), args);
    if (std.mem.eql(u8, name, "Agent") or std.mem.eql(u8, name, "get_subagent_result") or std.mem.eql(u8, name, "steer_subagent")) {
        const manager = context.subagent_manager orelse return gpa.dupe(u8, "subagents are disabled inside subagents");
        const launch = context.subagent_launch orelse return gpa.dupe(u8, "subagent launch context is unavailable");
        return manager.execute(gpa, name, args, launch);
    }
    return std.fmt.allocPrint(gpa, "unknown tool: {s}", .{name});
}

/// Run a user-entered shell escape through the same bounded runner as the
/// model's bash tool.
pub fn runShell(gpa: std.mem.Allocator, io: Io, command: []const u8, cwd: []const u8) ![]u8 {
    return runBash(gpa, io, command, 600, cancel.processToken(), cwd);
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

fn boundedUtf8(value: []const u8, limit: usize) []const u8 {
    const maximum = @min(value.len, limit);
    var length: usize = 0;
    while (length < maximum) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(value[length]) catch break;
        if (length + sequence_length > maximum) break;
        _ = std.unicode.utf8Decode(value[length .. length + sequence_length]) catch break;
        length += sequence_length;
    }
    return value[0..length];
}

fn writeSingleLine(writer: *Io.Writer, value: []const u8, limit: usize) !void {
    const bounded = boundedUtf8(value, limit);
    for (bounded) |byte| try writer.writeByte(if (byte < 0x20 or byte == 0x7f) ' ' else byte);
}

fn validUrlPort(value: []const u8) bool {
    if (value.len == 0) return false;
    _ = std.fmt.parseUnsigned(u16, value, 10) catch return false;
    return true;
}

fn validPublicUrl(url: []const u8) bool {
    for (url) |byte| if (byte <= ' ' or byte == 0x7f) return false;
    const scheme_end = std.mem.findScalar(u8, url, ':') orelse return false;
    const scheme = url[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "https") and !std.ascii.eqlIgnoreCase(scheme, "http")) return false;
    const rest = url[scheme_end + 1 ..];
    if (!std.mem.startsWith(u8, rest, "//")) return false;
    const authority_and_tail = rest[2..];
    const authority_end = std.mem.findAny(u8, authority_and_tail, "/?#") orelse authority_and_tail.len;
    var host_and_port = authority_and_tail[0..authority_end];
    if (std.mem.findScalarLast(u8, host_and_port, '@')) |at| host_and_port = host_and_port[at + 1 ..];
    if (host_and_port.len == 0) return false;
    if (host_and_port[0] == '[') {
        const close = std.mem.findScalar(u8, host_and_port, ']') orelse return false;
        if (close <= 1) return false;
        const tail = host_and_port[close + 1 ..];
        return tail.len == 0 or (tail[0] == ':' and validUrlPort(tail[1..]));
    }
    const colon = std.mem.findScalar(u8, host_and_port, ':') orelse return host_and_port.len > 0;
    return colon > 0 and validUrlPort(host_and_port[colon + 1 ..]);
}

fn firecrawlPost(gpa: std.mem.Allocator, io: Io, api_key: []const u8, endpoint: []const u8, body: []const u8) !transport.Response {
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});
    defer gpa.free(authorization);
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ firecrawl_base_url, endpoint });
    defer gpa.free(url);
    return transport.post(gpa, io, url, "application/json", &.{.{ .name = "Authorization", .value = authorization }}, body);
}

fn firecrawlFailure(gpa: std.mem.Allocator, tool_name: []const u8, status: u16, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return if (status >= 200 and status < 300)
            std.fmt.allocPrint(gpa, "{s} failed: Firecrawl returned an invalid response", .{tool_name})
        else
            std.fmt.allocPrint(gpa, "{s} failed: Firecrawl HTTP {d}", .{ tool_name, status });
    defer parsed.deinit();
    const error_value = objectField(parsed.value, "error");
    const message = objectString(parsed.value, "error") orelse
        objectString(parsed.value, "message") orelse
        if (error_value) |value| objectString(value, "message") else null;
    if (message) |text| {
        const bounded = boundedUtf8(text, 4096);
        return if (status >= 200 and status < 300)
            std.fmt.allocPrint(gpa, "{s} failed: {s}", .{ tool_name, bounded })
        else
            std.fmt.allocPrint(gpa, "{s} failed: Firecrawl HTTP {d}: {s}", .{ tool_name, status, bounded });
    }
    return if (status >= 200 and status < 300)
        std.fmt.allocPrint(gpa, "{s} failed: Firecrawl rejected the request", .{tool_name})
    else
        std.fmt.allocPrint(gpa, "{s} failed: Firecrawl HTTP {d}", .{ tool_name, status });
}

fn boundedDocument(gpa: std.mem.Allocator, title: ?[]const u8, url: []const u8, markdown_text: []const u8, warning: ?[]const u8) ![]u8 {
    var warning_text: Io.Writer.Allocating = .init(gpa);
    defer warning_text.deinit();
    if (warning) |message| if (message.len > 0) {
        try warning_text.writer.writeAll("[Firecrawl warning: ");
        try writeSingleLine(&warning_text.writer, message, 4096);
        try warning_text.writer.writeByte(']');
    };

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (title) |value| {
        try out.writer.writeAll("Title: ");
        try writeSingleLine(&out.writer, value, 4096);
        try out.writer.writeByte('\n');
    }
    try out.writer.writeAll("URL: ");
    try writeSingleLine(&out.writer, url, 8192);
    try out.writer.writeAll("\n\n");
    const suffix = "\n\n[content truncated]";
    const warning_separator = if (warning_text.written().len == 0 or markdown_text.len == 0) "" else "\n\n";
    const document_budget = output_payload -| warning_separator.len -| warning_text.written().len;
    const available = document_budget -| out.written().len;
    if (markdown_text.len <= available) {
        try out.writer.writeAll(markdown_text);
    } else {
        const keep = available -| suffix.len;
        try out.writer.writeAll(boundedUtf8(markdown_text, keep));
        try out.writer.writeAll(suffix);
    }
    try out.writer.writeAll(warning_separator);
    try out.writer.writeAll(warning_text.written());
    return out.toOwnedSlice();
}

fn formatFetchedDocument(gpa: std.mem.Allocator, requested_url: []const u8, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return firecrawlFailure(gpa, "web_fetch", 200, body);
    defer parsed.deinit();
    if (objectBool(parsed.value, "success") != true) return firecrawlFailure(gpa, "web_fetch", 200, body);
    const data = objectField(parsed.value, "data") orelse return gpa.dupe(u8, "web_fetch failed: Firecrawl response did not contain page data");
    const metadata = objectField(data, "metadata");
    if (metadata) |value| if (objectString(value, "error")) |message| if (message.len > 0)
        return std.fmt.allocPrint(gpa, "web_fetch failed: {s}", .{boundedUtf8(message, 4096)});
    const markdown_text = objectString(data, "markdown") orelse return gpa.dupe(u8, "web_fetch failed: Firecrawl response did not contain Markdown");
    const title = if (metadata) |value| objectString(value, "title") else null;
    const source_url = if (metadata) |value| objectString(value, "sourceURL") orelse objectString(value, "url") orelse requested_url else requested_url;
    return boundedDocument(gpa, title, source_url, markdown_text, objectString(data, "warning"));
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
    if (response.status < 200 or response.status >= 300) return firecrawlFailure(gpa, "web_fetch", response.status, response.body);
    return formatFetchedDocument(gpa, url, response.body);
}

fn appendSearchResult(writer: *Io.Writer, index: usize, value: std.json.Value) !bool {
    const metadata = objectField(value, "metadata");
    var url_value = objectString(value, "url");
    if (url_value == null) {
        if (metadata) |item| url_value = objectString(item, "sourceURL") orelse objectString(item, "url");
    }
    const url = url_value orelse return false;
    const title = objectString(value, "title") orelse if (metadata) |item| objectString(item, "title") orelse url else url;
    const description = objectString(value, "description") orelse if (metadata) |item| objectString(item, "description") else null;
    try writer.print("{d}. ", .{index});
    try writeSingleLine(writer, title, 4096);
    try writer.writeAll("\n   ");
    try writeSingleLine(writer, url, 8192);
    try writer.writeByte('\n');
    if (description) |text| if (text.len > 0) {
        try writer.writeAll("   ");
        try writeSingleLine(writer, text, 8192);
        try writer.writeByte('\n');
    };
    return true;
}

fn formatSearchResults(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch
        return firecrawlFailure(gpa, "web_search", 200, body);
    defer parsed.deinit();
    if (objectBool(parsed.value, "success") != true) return firecrawlFailure(gpa, "web_search", 200, body);
    const data = objectField(parsed.value, "data") orelse return gpa.dupe(u8, "web_search failed: Firecrawl response did not contain results");
    const web = objectField(data, "web") orelse return gpa.dupe(u8, "web_search failed: Firecrawl response did not contain web results");
    const results = switch (web) {
        .array => |array| array.items,
        else => return gpa.dupe(u8, "web_search failed: Firecrawl returned malformed web results"),
    };

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var warning: Io.Writer.Allocating = .init(gpa);
    defer warning.deinit();
    if (objectString(parsed.value, "warning")) |message| if (message.len > 0) {
        try warning.writer.writeAll("\n[Firecrawl warning: ");
        try writeSingleLine(&warning.writer, message, 4096);
        try warning.writer.writeAll("]\n");
    };
    const result_budget = output_payload -| warning.written().len;
    var rendered: usize = 0;
    for (results) |result| {
        var item: Io.Writer.Allocating = .init(gpa);
        defer item.deinit();
        if (!try appendSearchResult(&item.writer, rendered + 1, result)) continue;
        if (out.written().len + item.written().len > result_budget) {
            const notice = "[results truncated]\n";
            if (out.written().len + notice.len <= result_budget) try out.writer.writeAll(notice);
            break;
        }
        try out.writer.writeAll(item.written());
        rendered += 1;
    }
    if (rendered == 0) try out.writer.writeAll(if (results.len == 0) "No web results found.\n" else "No valid web results found.\n");
    try out.writer.writeAll(warning.written());
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
    try js.objectField("ignoreInvalidURLs");
    try js.write(true);
    try js.endObject();

    const response = try firecrawlPost(gpa, io, api_key, "search", request.written());
    defer gpa.free(response.body);
    if (response.status < 200 or response.status >= 300) return firecrawlFailure(gpa, "web_search", response.status, response.body);
    return formatSearchResults(gpa, response.body);
}

fn read(gpa: std.mem.Allocator, io: Io, args: std.json.Value, cwd: ?[]const u8) ![]u8 {
    const requested_path = try fieldString(args, "path");
    const resolved = try resolvePath(gpa, cwd, requested_path);
    defer resolved.deinit(gpa);
    const offset: usize = @intCast(@max(optionalInt(args, "offset") orelse 1, 1));
    const limit: usize = @intCast(@max(optionalInt(args, "limit") orelse 2000, 1));

    var file = try Io.Dir.cwd().openFile(io, resolved.value, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_read_file_bytes) return error.StreamTooLong;

    var read_buffer: [16 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);
    var chunk: [16 * 1024]u8 = undefined;
    const initial_capacity: usize = @min(@as(usize, @intCast(stat.size)), output_payload);
    var out: Io.Writer.Allocating = try .initCapacity(gpa, initial_capacity);
    defer out.deinit();
    var source_line: usize = 1;
    var selected_lines: usize = 0;
    var selection_complete = false;
    var truncated = false;

    read_chunks: while (true) {
        const count = try file_reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        for (chunk[0..count]) |byte| {
            if (selection_complete) {
                truncated = true;
                break :read_chunks;
            }
            if (source_line < offset) {
                if (byte == '\n') source_line += 1;
                continue;
            }
            if (out.written().len == output_payload) {
                truncated = true;
                break :read_chunks;
            }
            try out.writer.writeByte(byte);
            if (byte == '\n') {
                source_line += 1;
                selected_lines += 1;
                if (selected_lines == limit) selection_complete = true;
            }
        }
    }

    if (!truncated) return out.toOwnedSlice();
    const consumed_lines = std.mem.count(u8, out.written(), "\n");
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
    return runBash(gpa, io, command, seconds, token, cwd);
}

fn runBash(gpa: std.mem.Allocator, io: Io, command: []const u8, seconds: u64, token: *cancel.Token, cwd: ?[]const u8) ![]u8 {
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
        try out.writer.print("[output truncated: full output saved at {s}; showing last {d} bytes]\n", .{ path, capture.tailLen() });
    }
    try capture.writeTail(&out.writer);
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
    tail_start: usize = 0,
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
            self.tail_start = 0;
            return;
        }

        const append_len = @min(output_payload - self.tail.items.len, bytes.len);
        try self.tail.appendSlice(self.gpa, bytes[0..append_len]);
        var remaining = bytes[append_len..];
        while (remaining.len > 0) {
            const copy_len = @min(remaining.len, output_payload - self.tail_start);
            @memcpy(self.tail.items[self.tail_start..][0..copy_len], remaining[0..copy_len]);
            self.tail_start = (self.tail_start + copy_len) % output_payload;
            remaining = remaining[copy_len..];
        }
    }

    fn tailLen(self: *const Capture) usize {
        return self.tail.items.len;
    }

    fn writeTail(self: *const Capture, writer: *Io.Writer) !void {
        if (self.tail_start == 0) return writer.writeAll(self.tail.items);
        try writer.writeAll(self.tail.items[self.tail_start..]);
        try writer.writeAll(self.tail.items[0..self.tail_start]);
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
        if (self.tail_start == 0) {
            try file.writeStreamingAll(self.io, self.tail.items);
        } else {
            try file.writeStreamingAll(self.io, self.tail.items[self.tail_start..]);
            try file.writeStreamingAll(self.io, self.tail.items[0..self.tail_start]);
        }
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

test "subagent schemas are parent-only and write tools can be omitted" {
    var parent: Io.Writer.Allocating = .init(std.testing.allocator);
    defer parent.deinit();
    var parent_json: std.json.Stringify = .{ .writer = &parent.writer };
    const subagent_options: SchemaOptions = .{
        .subagents_enabled = true,
        .subagent_launch = .{ .provider = "claude", .model = "claude-fable-5", .effort = "high", .fast = false },
        .subagent_max_concurrent = 2,
    };
    try schemasWithOptions(&parent_json, subagent_options);
    var parsed_parent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, parent.written(), .{});
    defer parsed_parent.deinit();
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "\"name\":\"Agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "get_subagent_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "steer_subagent") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "subagent_type") == null);
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "provider=claude and cannot switch providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "At most 2 workers run at once") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "\"enum\":[\"claude-opus-5\",\"claude-sonnet-5\",\"claude-fable-5-1\",\"claude-fable-5\",\"claude-haiku-4-5\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "gpt-5.6-sol") == null);
    try std.testing.expect(std.mem.indexOf(u8, parent.written(), "\"enum\":[\"workspace_write\"]") != null);

    var claude_parent: Io.Writer.Allocating = .init(std.testing.allocator);
    defer claude_parent.deinit();
    var claude_parent_json: std.json.Stringify = .{ .writer = &claude_parent.writer };
    try claudeSchemasWithOptions(&claude_parent_json, subagent_options);
    var parsed_claude = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, claude_parent.written(), .{});
    defer parsed_claude.deinit();
    try std.testing.expect(std.mem.indexOf(u8, claude_parent.written(), "\"input_schema\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_parent.written(), "claude-fable-5") != null);

    var worker: Io.Writer.Allocating = .init(std.testing.allocator);
    defer worker.deinit();
    var worker_json: std.json.Stringify = .{ .writer = &worker.writer };
    try schemasWithOptions(&worker_json, .{ .write_enabled = false });
    try std.testing.expect(std.mem.indexOf(u8, worker.written(), "\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, worker.written(), "\"name\":\"edit\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, worker.written(), "\"name\":\"Agent\"") == null);
}

test "bash combines stdout and stderr in production order" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"command":"printf 'one\\n'; printf 'two\\n' >&2","timeout":5}
    , .{});
    defer parsed.deinit();
    const result = try execute(std.testing.allocator, std.testing.io, "bash", parsed.value, null);
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

test "read streams line windows without loading the whole file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "lines.txt",
        .data = "one\ntwo\nthree\nfour\n",
    });
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/lines.txt", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const arguments = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\",\"offset\":2,\"limit\":2}}", .{path});
    defer std.testing.allocator.free(arguments);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, arguments, .{});
    defer parsed.deinit();

    const result = try execute(std.testing.allocator, std.testing.io, "read", parsed.value, null);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("two\nthree\n\n[truncated: continue with offset=4]", result);
}

test "read advances past a line larger than its output budget" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const contents = try std.testing.allocator.alloc(u8, output_payload + 31);
    defer std.testing.allocator.free(contents);
    @memset(contents, 'x');
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = contents });
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/long.txt", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const arguments = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(arguments);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, arguments, .{});
    defer parsed.deinit();

    const result = try execute(std.testing.allocator, std.testing.io, "read", parsed.value, null);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, contents[0..output_payload], result[0..output_payload]);
    try std.testing.expect(std.mem.endsWith(u8, result, "[truncated: line 1 exceeds the output budget; offset=2 skips its remainder]"));
}

test "command capture retains its tail without shifting on every chunk" {
    const contents = try std.testing.allocator.alloc(u8, output_payload + 19_321);
    defer std.testing.allocator.free(contents);
    for (contents, 0..) |*byte, index| byte.* = @intCast(index % 251);

    var capture = Capture.init(std.testing.allocator, std.testing.io);
    defer capture.deinit();
    defer capture.discardSpill();
    var cursor: usize = 0;
    while (cursor < contents.len) {
        const end = @min(contents.len, cursor + 997);
        try capture.write(contents[cursor..end]);
        cursor = end;
    }
    var tail: Io.Writer.Allocating = .init(std.testing.allocator);
    defer tail.deinit();
    try capture.writeTail(&tail.writer);
    try std.testing.expectEqualSlices(u8, contents[contents.len - output_payload ..], tail.written());
}

test "Firecrawl search results are formatted for the model" {
    const result = try formatSearchResults(std.testing.allocator,
        \\{"success":true,"data":{"web":[{"title":"Example","url":"https://example.com","description":"A test page."}]}}
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1. Example\n   https://example.com\n   A test page.\n", result);
}

test "Firecrawl fetched documents use response metadata" {
    const result = try formatFetchedDocument(std.testing.allocator, "https://requested.example",
        \\{"success":true,"data":{"markdown":"# Page\n\nBody","metadata":{"title":"Fetched title","sourceURL":"https://canonical.example/page"}}}
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Title: Fetched title\nURL: https://canonical.example/page\n\n# Page\n\nBody", result);

    const failed = try formatFetchedDocument(std.testing.allocator, "https://requested.example",
        \\{"success":true,"data":{"markdown":"","metadata":{"error":"Robots denied this page."}}}
    );
    defer std.testing.allocator.free(failed);
    try std.testing.expectEqualStrings("web_fetch failed: Robots denied this page.", failed);
}

test "Firecrawl fetched documents preserve data warnings" {
    const result = try formatFetchedDocument(std.testing.allocator, "https://requested.example",
        \\{"success":true,"data":{"markdown":"Page body","warning":"Cached\ncopy\u007fused."}}
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "URL: https://requested.example\n\nPage body\n\n[Firecrawl warning: Cached copy used.]",
        result,
    );
}

test "Firecrawl search metadata fallbacks and warnings remain visible" {
    const result = try formatSearchResults(std.testing.allocator,
        \\{"success":true,"data":{"web":[{"metadata":{"title":"Metadata title","description":"two\nlines","sourceURL":"https://example.com/from-metadata"}}]},"warning":"Some results timed out."}
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "1. Metadata title\n   https://example.com/from-metadata\n   two lines\n\n[Firecrawl warning: Some results timed out.]\n",
        result,
    );
}

test "Firecrawl failures preserve useful messages" {
    const rejected = try formatSearchResults(std.testing.allocator,
        \\{"success":false,"error":{"message":"Search quota exhausted."}}
    );
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqualStrings("web_search failed: Search quota exhausted.", rejected);

    const limited = try firecrawlFailure(std.testing.allocator, "web_fetch", 429,
        \\{"success":false,"error":"Rate limit exceeded."}
    );
    defer std.testing.allocator.free(limited);
    try std.testing.expectEqualStrings("web_fetch failed: Firecrawl HTTP 429: Rate limit exceeded.", limited);
}

test "web fetch URL validation requires an HTTP host" {
    try std.testing.expect(validPublicUrl("https://example.com/path?q=1"));
    try std.testing.expect(validPublicUrl("HTTPS://example.com"));
    try std.testing.expect(validPublicUrl("http://[::1]:8080/path"));
    try std.testing.expect(!validPublicUrl("https:///missing-host"));
    try std.testing.expect(!validPublicUrl("https://"));
    try std.testing.expect(!validPublicUrl("https://example.com:not-a-port"));
    try std.testing.expect(!validPublicUrl("https://example.com/path\nnext"));
    try std.testing.expect(!validPublicUrl("file:///tmp/page.html"));
}

test "web output bounds preserve UTF-8 boundaries" {
    try std.testing.expectEqualStrings("a", boundedUtf8("a€", 2));
    try std.testing.expectEqualStrings("a€", boundedUtf8("a€", 4));

    const markdown_text = try std.testing.allocator.alloc(u8, max_output * 2);
    defer std.testing.allocator.free(markdown_text);
    var index: usize = 0;
    while (index + "€".len <= markdown_text.len) : (index += "€".len) @memcpy(markdown_text[index .. index + "€".len], "€");
    @memset(markdown_text[index..], 'x');
    const result = try boundedDocument(std.testing.allocator, "Unicode", "https://example.com", markdown_text, null);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result));
    try std.testing.expect(std.mem.endsWith(u8, result, "[content truncated]"));
}

test "Firecrawl documents are capped to the tool output budget" {
    const markdown_text = try std.testing.allocator.alloc(u8, max_output * 2);
    defer std.testing.allocator.free(markdown_text);
    @memset(markdown_text, 'x');
    const result = try boundedDocument(std.testing.allocator, "Example", "https://example.com", markdown_text, null);
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len <= max_output);
    try std.testing.expect(std.mem.endsWith(u8, result, "[content truncated]"));

    const warning = try std.testing.allocator.alloc(u8, max_output * 2);
    defer std.testing.allocator.free(warning);
    @memset(warning, 'w');
    const warned = try boundedDocument(std.testing.allocator, "Example", "https://example.com", markdown_text, warning);
    defer std.testing.allocator.free(warned);
    try std.testing.expect(warned.len <= max_output);
    try std.testing.expect(std.mem.indexOf(u8, warned, "[content truncated]") != null);
    try std.testing.expect(std.mem.endsWith(u8, warned, "w]"));
}
