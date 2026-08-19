const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const tools = @import("tools.zig");
const transport = @import("transport.zig");

pub const ToolCall = struct { id: []const u8, name: []const u8, arguments: []const u8 };
const ToolResult = struct { id: []const u8, text: []const u8 };
const Assistant = struct {
    text: []const u8,
    calls: []const ToolCall,
    raw_items: []const []const u8 = &.{},
};
const Entry = union(enum) {
    user: []const u8,
    assistant: Assistant,
    results: []const ToolResult,
};

pub fn defaultModel(provider: auth.Provider) []const u8 {
    return switch (provider) {
        .chatgpt => "gpt-5.5",
        .claude => "claude-opus-4-8",
        .grok => "grok-4.6",
    };
}

pub fn run(gpa: std.mem.Allocator, io: Io, provider: auth.Provider, credential: auth.Credential, model: []const u8, first_prompt: []const u8, input: ?*Io.Reader, output: *Io.Writer) !void {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    try entries.append(gpa, .{ .user = try gpa.dupe(u8, first_prompt) });

    while (true) {
        const body = try buildRequest(gpa, io, provider, model, entries.items);
        defer gpa.free(body);
        const response = try request(gpa, io, provider, credential, body);
        defer gpa.free(response.body);
        if (response.status < 200 or response.status >= 300) {
            std.debug.print("provider HTTP {d}: {s}\n", .{ response.status, response.body });
            return error.ProviderRequestFailed;
        }
        const answer = if (provider == .claude)
            try parseClaude(gpa, response.body, output)
        else
            try parseResponses(gpa, response.body, output);
        try entries.append(gpa, .{ .assistant = answer });
        if (answer.calls.len == 0) {
            try output.writeByte('\n');
            try output.flush();
            if (input) |reader| {
                try output.writeAll("> ");
                try output.flush();
                const line = (try reader.takeDelimiter('\n')) orelse return;
                const prompt = std.mem.trim(u8, line, " \r\n");
                if (prompt.len == 0 or std.mem.eql(u8, prompt, "/exit")) return;
                try entries.append(gpa, .{ .user = try gpa.dupe(u8, prompt) });
                continue;
            }
            return;
        }

        var results = try gpa.alloc(ToolResult, answer.calls.len);
        for (answer.calls, 0..) |call, i| {
            try output.print("\n[{s}]\n", .{call.name});
            try output.flush();
            var parsed = std.json.parseFromSlice(std.json.Value, gpa, call.arguments, .{}) catch |err| {
                results[i] = .{ .id = call.id, .text = try std.fmt.allocPrint(gpa, "invalid tool arguments: {s}", .{@errorName(err)}) };
                continue;
            };
            defer parsed.deinit();
            const result = tools.execute(gpa, io, call.name, parsed.value) catch |err|
                try std.fmt.allocPrint(gpa, "tool error: {s}", .{@errorName(err)});
            results[i] = .{ .id = call.id, .text = result };
        }
        try entries.append(gpa, .{ .results = results });
    }
}

fn buildRequest(gpa: std.mem.Allocator, io: Io, provider: auth.Provider, model: []const u8, entries: []const Entry) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const system = try std.fmt.allocPrint(gpa, "You are a concise coding agent in {s}. Use read, bash, edit, and write to inspect and modify the host directly. Tools have full user permissions; do not ask for tool approval. Verify material changes.", .{cwd_buf[0..cwd_len]});
    defer gpa.free(system);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("model");
    try js.write(model);
    if (provider == .claude) {
        try js.objectField("max_tokens");
        try js.write(32768);
        try js.objectField("stream");
        try js.write(true);
        try js.objectField("system");
        try js.beginArray();
        try js.beginObject();
        try js.objectField("type");
        try js.write("text");
        try js.objectField("text");
        try js.write("You are Claude Code, Anthropic's official CLI for Claude.");
        try js.endObject();
        try js.beginObject();
        try js.objectField("type");
        try js.write("text");
        try js.objectField("text");
        try js.write(system);
        try js.endObject();
        try js.endArray();
        try js.objectField("messages");
        try writeClaudeMessages(&js, entries);
        try js.objectField("tools");
        try tools.claudeSchemas(&js);
    } else {
        try js.objectField("store");
        try js.write(false);
        try js.objectField("stream");
        try js.write(true);
        if (provider == .chatgpt) {
            try js.objectField("instructions");
            try js.write(system);
            try js.objectField("text");
            try js.beginObject();
            try js.objectField("verbosity");
            try js.write("low");
            try js.endObject();
        }
        try js.objectField("input");
        try writeResponsesInput(&js, entries, if (provider == .grok) system else null);
        try js.objectField("tools");
        try tools.schemas(&js);
        try js.objectField("tool_choice");
        try js.write("auto");
        try js.objectField("parallel_tool_calls");
        try js.write(true);
        if (provider == .chatgpt) {
            try js.objectField("include");
            try js.beginArray();
            try js.write("reasoning.encrypted_content");
            try js.endArray();
        }
    }
    try js.endObject();
    return out.toOwnedSlice();
}

fn writeResponsesInput(js: *std.json.Stringify, entries: []const Entry, system: ?[]const u8) !void {
    try js.beginArray();
    if (system) |text| {
        try js.beginObject();
        try js.objectField("role");
        try js.write("developer");
        try js.objectField("content");
        try js.write(text);
        try js.endObject();
    }
    for (entries) |entry| switch (entry) {
        .user => |text| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("user");
            try js.objectField("content");
            try js.beginArray();
            try js.beginObject();
            try js.objectField("type");
            try js.write("input_text");
            try js.objectField("text");
            try js.write(text);
            try js.endObject();
            try js.endArray();
            try js.endObject();
        },
        .assistant => |answer| {
            if (answer.raw_items.len > 0) {
                for (answer.raw_items) |raw| try rawValue(js, raw);
            } else {
                if (answer.text.len > 0) {
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("message");
                    try js.objectField("role");
                    try js.write("assistant");
                    try js.objectField("content");
                    try js.beginArray();
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("output_text");
                    try js.objectField("text");
                    try js.write(answer.text);
                    try js.objectField("annotations");
                    try js.beginArray();
                    try js.endArray();
                    try js.endObject();
                    try js.endArray();
                    try js.objectField("status");
                    try js.write("completed");
                    try js.endObject();
                }
                for (answer.calls) |call| {
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("function_call");
                    try js.objectField("call_id");
                    try js.write(call.id);
                    try js.objectField("name");
                    try js.write(call.name);
                    try js.objectField("arguments");
                    try js.write(call.arguments);
                    try js.endObject();
                }
            }
        },
        .results => |results| for (results) |result| {
            try js.beginObject();
            try js.objectField("type");
            try js.write("function_call_output");
            try js.objectField("call_id");
            try js.write(result.id);
            try js.objectField("output");
            try js.write(result.text);
            try js.endObject();
        },
    };
    try js.endArray();
}

fn writeClaudeMessages(js: *std.json.Stringify, entries: []const Entry) !void {
    try js.beginArray();
    for (entries) |entry| switch (entry) {
        .user => |text| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("user");
            try js.objectField("content");
            try js.write(text);
            try js.endObject();
        },
        .assistant => |answer| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("assistant");
            try js.objectField("content");
            try js.beginArray();
            if (answer.text.len > 0) {
                try js.beginObject();
                try js.objectField("type");
                try js.write("text");
                try js.objectField("text");
                try js.write(answer.text);
                try js.endObject();
            }
            for (answer.calls) |call| {
                try js.beginObject();
                try js.objectField("type");
                try js.write("tool_use");
                try js.objectField("id");
                try js.write(call.id);
                try js.objectField("name");
                try js.write(call.name);
                try js.objectField("input");
                try rawValue(js, call.arguments);
                try js.endObject();
            }
            try js.endArray();
            try js.endObject();
        },
        .results => |results| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("user");
            try js.objectField("content");
            try js.beginArray();
            for (results) |result| {
                try js.beginObject();
                try js.objectField("type");
                try js.write("tool_result");
                try js.objectField("tool_use_id");
                try js.write(result.id);
                try js.objectField("content");
                try js.write(result.text);
                try js.endObject();
            }
            try js.endArray();
            try js.endObject();
        },
    };
    try js.endArray();
}

fn rawValue(js: *std.json.Stringify, value: []const u8) !void {
    try js.beginWriteRaw();
    try js.writer.writeAll(value);
    js.endWriteRaw();
}

fn request(gpa: std.mem.Allocator, io: Io, provider: auth.Provider, credential: auth.Credential, body: []const u8) !transport.Response {
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{credential.access});
    defer gpa.free(authorization);
    return switch (provider) {
        .chatgpt => transport.post(gpa, io, "https://chatgpt.com/backend-api/codex/responses", "application/json", &.{
            .{ .name = "Authorization", .value = authorization },
            .{ .name = "chatgpt-account-id", .value = credential.account_id orelse return error.InvalidAccessToken },
            .{ .name = "originator", .value = "xaq" },
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
            .{ .name = "User-Agent", .value = "xaq/0.1" },
        }, body),
        .claude => transport.post(gpa, io, "https://api.anthropic.com/v1/messages", "application/json", &.{
            .{ .name = "Authorization", .value = authorization },                            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20" }, .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" },
            .{ .name = "User-Agent", .value = "claude-cli/2.1.75" },                         .{ .name = "x-app", .value = "cli" },
        }, body),
        .grok => transport.post(gpa, io, "https://api.x.ai/v1/responses", "application/json", &.{
            .{ .name = "Authorization", .value = authorization }, .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "User-Agent", .value = "xaq/0.1" },
        }, body),
    };
}

fn eventString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const child = switch (value) {
        .object => |o| o.get(key) orelse return null,
        else => return null,
    };
    return switch (child) {
        .string => |s| s,
        else => null,
    };
}

fn parseResponses(gpa: std.mem.Allocator, body: []const u8, output: *Io.Writer) !Assistant {
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    var calls: std.ArrayList(ToolCall) = .empty;
    defer calls.deinit(gpa);
    var raw: std.ArrayList([]const u8) = .empty;
    defer raw.deinit(gpa);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trimStart(u8, line[5..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch continue;
        defer parsed.deinit();
        const kind = eventString(parsed.value, "type") orelse continue;
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            const delta = eventString(parsed.value, "delta") orelse continue;
            try text.writer.writeAll(delta);
            try output.writeAll(delta);
            try output.flush();
        } else if (std.mem.eql(u8, kind, "response.output_item.done")) {
            const item = switch (parsed.value) {
                .object => |o| o.get("item") orelse continue,
                else => continue,
            };
            var item_out: Io.Writer.Allocating = .init(gpa);
            defer item_out.deinit();
            try std.json.Stringify.value(item, .{}, &item_out.writer);
            try raw.append(gpa, try item_out.toOwnedSlice());
            if (eventString(item, "type")) |item_type| if (std.mem.eql(u8, item_type, "function_call")) {
                try calls.append(gpa, .{
                    .id = try gpa.dupe(u8, eventString(item, "call_id") orelse return error.InvalidProviderResponse),
                    .name = try gpa.dupe(u8, eventString(item, "name") orelse return error.InvalidProviderResponse),
                    .arguments = try gpa.dupe(u8, eventString(item, "arguments") orelse "{}"),
                });
            };
        } else if (std.mem.eql(u8, kind, "response.failed") or std.mem.eql(u8, kind, "error")) {
            std.debug.print("provider event: {s}\n", .{data});
            return error.ProviderRequestFailed;
        }
    }
    return .{ .text = try text.toOwnedSlice(), .calls = try calls.toOwnedSlice(gpa), .raw_items = try raw.toOwnedSlice(gpa) };
}

const ClaudeCall = struct { index: i64, id: []const u8, name: []const u8, args: Io.Writer.Allocating };

fn parseClaude(gpa: std.mem.Allocator, body: []const u8, output: *Io.Writer) !Assistant {
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    var building: std.ArrayList(ClaudeCall) = .empty;
    defer {
        for (building.items) |*call| call.args.deinit();
        building.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trimStart(u8, line[5..], " ");
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch continue;
        defer parsed.deinit();
        const kind = eventString(parsed.value, "type") orelse continue;
        if (std.mem.eql(u8, kind, "content_block_start")) {
            const index = switch (parsed.value.object.get("index") orelse continue) {
                .integer => |n| n,
                else => continue,
            };
            const block = parsed.value.object.get("content_block") orelse continue;
            if (eventString(block, "type")) |block_type| if (std.mem.eql(u8, block_type, "tool_use")) {
                try building.append(gpa, .{
                    .index = index,
                    .id = try gpa.dupe(u8, eventString(block, "id") orelse return error.InvalidProviderResponse),
                    .name = try gpa.dupe(u8, eventString(block, "name") orelse return error.InvalidProviderResponse),
                    .args = .init(gpa),
                });
            };
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const delta = parsed.value.object.get("delta") orelse continue;
            const delta_type = eventString(delta, "type") orelse continue;
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                const part = eventString(delta, "text") orelse continue;
                try text.writer.writeAll(part);
                try output.writeAll(part);
                try output.flush();
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const index = switch (parsed.value.object.get("index") orelse continue) {
                    .integer => |n| n,
                    else => continue,
                };
                const part = eventString(delta, "partial_json") orelse continue;
                for (building.items) |*call| if (call.index == index) {
                    try call.args.writer.writeAll(part);
                    break;
                };
            }
        } else if (std.mem.eql(u8, kind, "error")) {
            std.debug.print("provider event: {s}\n", .{data});
            return error.ProviderRequestFailed;
        }
    }
    const calls = try gpa.alloc(ToolCall, building.items.len);
    for (building.items, 0..) |*call, i| calls[i] = .{
        .id = call.id,
        .name = call.name,
        .arguments = if (call.args.written().len == 0) try gpa.dupe(u8, "{}") else try gpa.dupe(u8, call.args.written()),
    };
    return .{ .text = try text.toOwnedSlice(), .calls = calls };
}

test "provider defaults" {
    try std.testing.expectEqualStrings("gpt-5.5", defaultModel(.chatgpt));
    try std.testing.expectEqualStrings("claude-opus-4-8", defaultModel(.claude));
    try std.testing.expectEqualStrings("grok-4.6", defaultModel(.grok));
}

test "parse Responses SSE" {
    const body =
        \\data: {"type":"response.output_text.delta","delta":"done"}
        \\data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"read","arguments":"{\"path\":\"README.md\"}"}}
        \\data: [DONE]
    ;
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    const result = try parseResponses(std.testing.allocator, body, &writer);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |call| {
            std.testing.allocator.free(call.id);
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments);
        }
        std.testing.allocator.free(result.calls);
        for (result.raw_items) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(result.raw_items);
    }
    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expectEqualStrings("read", result.calls[0].name);
    try std.testing.expectEqualStrings("done", writer.buffered());
}

test "parse Anthropic SSE" {
    const body =
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool_1","name":"bash","input":{}}}
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"pwd\"}"}}
    ;
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    const result = try parseClaude(std.testing.allocator, body, &writer);
    defer std.testing.allocator.free(result.text);
    defer {
        for (result.calls) |call| {
            std.testing.allocator.free(call.id);
            std.testing.allocator.free(call.name);
            std.testing.allocator.free(call.arguments);
        }
        std.testing.allocator.free(result.calls);
    }
    try std.testing.expectEqualStrings("ok", result.text);
    try std.testing.expectEqualStrings("bash", result.calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", result.calls[0].arguments);
}
