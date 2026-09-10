const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const models = @import("models.zig");
const providers = @import("providers.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

/// Current Claude models require at least this client version. Share it
/// across the CLI and embedded transports, including compaction requests.
pub const claude_user_agent = "claude-cli/2.1.251";

/// The providers spell fast mode differently. ChatGPT takes the Responses
/// `service_tier` field, and Codex's "fast" tier is the wire value
/// "priority" (sending "fast" is rejected). Anthropic takes a top-level
/// `speed: "fast"` field that only works with the beta header below.
const chatgpt_fast_service_tier = "priority";

/// Anthropic ignores `speed` unless the fast-mode beta is requested.
pub fn claudeBetaHeader(fast: bool) []const u8 {
    return if (fast)
        "claude-code-20250219,oauth-2025-04-20,fast-mode-2026-02-01"
    else
        "claude-code-20250219,oauth-2025-04-20";
}

/// Codex sends `x-codex-routing-hint` on every ChatGPT-backend request
/// (rounds and compaction alike) so the backend can route to the tier
/// before parsing the body. The tier is the same wire value as the body's
/// `service_tier`; standard requests carry only the model.
pub fn chatgptRoutingHint(gpa: std.mem.Allocator, model: []const u8, fast: bool) ![]u8 {
    return if (fast)
        std.fmt.allocPrint(gpa, "model={s};tier={s}", .{ model, chatgpt_fast_service_tier })
    else
        std.fmt.allocPrint(gpa, "model={s}", .{model});
}

pub fn build(gpa: std.mem.Allocator, target: providers.Target, model: []const u8, effort: ?models.Effort, fast: bool, tool_options: tools.SchemaOptions, cwd: []const u8, instructions: []const u8, entries: []const types.Entry) ![]u8 {
    const write_instructions = if (!tool_options.include_builtin)
        ""
    else if (tool_options.write_enabled)
        " Use read, bash, edit, and write to inspect and modify the host directly."
    else
        " Use read and bash to inspect the host. This is a read-only role: do not modify files.";
    const web_instructions = if (tool_options.web_enabled) " Use web_search to find current information and web_fetch to read a specific public URL." else "";
    const subagent_instructions = if (tool_options.subagents_enabled) " Agent launches separate-process subagents in the same working directory. Background is the default: launch independent work together, then use get_subagent_result with wait true before relying on it. Give each subagent a self-contained brief and verify any claimed edits." else "";
    const custom_instructions = if (tool_options.custom.len > 0) " Use host-provided tools when they help with the request." else "";
    const permission_instructions = if (tool_options.include_builtin) " Built-in tools have full user permissions; do not ask for tool approval." else "";
    const system = try std.fmt.allocPrint(gpa, "You are a concise coding agent in {s}. Runtime: provider={s}, model={s}.{s}{s}{s}{s}{s} Verify material changes.{s}", .{ cwd, target.name, model, write_instructions, web_instructions, subagent_instructions, custom_instructions, permission_instructions, instructions });
    defer gpa.free(system);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("model");
    try js.write(model);
    switch (target.api) {
        .messages => {
            try js.objectField("max_tokens");
            try js.write(32768);
            try js.objectField("stream");
            try js.write(true);
            if (fast) {
                try js.objectField("speed");
                try js.write("fast");
            }
            if (effort) |value| try writeClaudeEffort(&js, value);
            try js.objectField("system");
            try js.beginArray();
            // The subscription requires the Claude Code identity block;
            // Anthropic-compatible endpoints get only the agent prompt.
            if (target.provider == .claude) {
                try js.beginObject();
                try js.objectField("type");
                try js.write("text");
                try js.objectField("text");
                try js.write("You are Claude Code, Anthropic's official CLI for Claude.");
                try js.endObject();
            }
            try js.beginObject();
            try js.objectField("type");
            try js.write("text");
            try js.objectField("text");
            try js.write(system);
            try js.endObject();
            try js.endArray();
            try js.objectField("messages");
            try writeClaudeMessages(&js, entries, null);
            try js.objectField("tools");
            try tools.schemasForApi(&js, .messages, tool_options);
        },
        .chat_completions => {
            try js.objectField("stream");
            try js.write(true);
            try writeChatStreamOptions(&js);
            if (effort) |value| {
                try js.objectField("reasoning_effort");
                try js.write(@tagName(value));
            }
            try js.objectField("messages");
            try writeChatMessages(&js, entries, system, null);
            if (tools.anySchemas(tool_options)) {
                try js.objectField("tools");
                try tools.schemasForApi(&js, .chat_completions, tool_options);
                try js.objectField("tool_choice");
                try js.write("auto");
            }
        },
        .responses => {
            try js.objectField("store");
            try js.write(false);
            try js.objectField("stream");
            try js.write(true);
            if (effort) |value| {
                try js.objectField("reasoning");
                try js.beginObject();
                try js.objectField("effort");
                try js.write(@tagName(value));
                try js.endObject();
            }
            if (target.provider == .chatgpt) {
                if (fast) {
                    try js.objectField("service_tier");
                    try js.write(chatgpt_fast_service_tier);
                }
                try js.objectField("instructions");
                try js.write(system);
                try js.objectField("text");
                try js.beginObject();
                try js.objectField("verbosity");
                try js.write("low");
                try js.endObject();
            }
            try js.objectField("input");
            try writeResponsesInput(&js, entries, if (target.provider != .chatgpt) system else null, null);
            try js.objectField("tools");
            try tools.schemasForApi(&js, .responses, tool_options);
            try js.objectField("tool_choice");
            try js.write("auto");
            try js.objectField("parallel_tool_calls");
            try js.write(true);
            if (target.provider == .chatgpt) {
                try js.objectField("include");
                try js.beginArray();
                try js.write("reasoning.encrypted_content");
                try js.endArray();
            }
        },
    }
    try js.endObject();
    return out.toOwnedSlice();
}

pub const compact_system = "Summarize the supplied coding-agent history for continuation. Preserve the active goal, user requirements, decisions, files and symbols changed, commands and test results, unresolved errors, and exact identifiers needed to continue. Drop repetition and obsolete exploration. Output only a concise factual handoff; do not call tools.";
pub const compact_prompt = "Create the continuation handoff now.";

pub fn buildCompact(gpa: std.mem.Allocator, target: providers.Target, model: []const u8, effort: ?models.Effort, fast: bool, entries: []const types.Entry) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("model");
    try js.write(model);
    try js.objectField("stream");
    try js.write(true);
    switch (target.api) {
        .messages => {
            try js.objectField("max_tokens");
            try js.write(8192);
            if (fast) {
                try js.objectField("speed");
                try js.write("fast");
            }
            if (effort) |value| try writeClaudeEffort(&js, value);
            try js.objectField("system");
            try js.write(compact_system);
            try js.objectField("messages");
            try writeClaudeMessages(&js, entries, compact_prompt);
        },
        .chat_completions => {
            try writeChatStreamOptions(&js);
            if (effort) |value| {
                try js.objectField("reasoning_effort");
                try js.write(@tagName(value));
            }
            try js.objectField("messages");
            try writeChatMessages(&js, entries, compact_system, compact_prompt);
        },
        .responses => {
            try js.objectField("store");
            try js.write(false);
            if (target.provider != .chatgpt) {
                try js.objectField("max_output_tokens");
                try js.write(8192);
            }
            if (effort) |value| {
                try js.objectField("reasoning");
                try js.beginObject();
                try js.objectField("effort");
                try js.write(@tagName(value));
                try js.endObject();
            }
            if (target.provider == .chatgpt) {
                if (fast) {
                    try js.objectField("service_tier");
                    try js.write(chatgpt_fast_service_tier);
                }
                try js.objectField("instructions");
                try js.write(compact_system);
                try js.objectField("text");
                try js.beginObject();
                try js.objectField("verbosity");
                try js.write("low");
                try js.endObject();
            }
            try js.objectField("input");
            try writeResponsesInput(&js, entries, if (target.provider != .chatgpt) compact_system else null, compact_prompt);
        },
    }
    try js.endObject();
    return out.toOwnedSlice();
}

fn writeClaudeEffort(js: *std.json.Stringify, value: models.Effort) !void {
    try js.objectField("thinking");
    try js.beginObject();
    try js.objectField("type");
    try js.write("adaptive");
    try js.endObject();
    try js.objectField("output_config");
    try js.beginObject();
    try js.objectField("effort");
    try js.write(@tagName(value));
    try js.endObject();
}

/// Ask for the usage chunk that OpenAI-compatible servers otherwise omit.
fn writeChatStreamOptions(js: *std.json.Stringify) !void {
    try js.objectField("stream_options");
    try js.beginObject();
    try js.objectField("include_usage");
    try js.write(true);
    try js.endObject();
}

/// Chat Completions history: a system message, user turns with optional
/// image parts, assistant turns with `tool_calls`, and one `tool` message
/// per result. Responses-native replay items never apply here.
fn writeChatMessages(js: *std.json.Stringify, entries: []const types.Entry, system: []const u8, final_user: ?[]const u8) !void {
    try js.beginArray();
    try js.beginObject();
    try js.objectField("role");
    try js.write("system");
    try js.objectField("content");
    try js.write(system);
    try js.endObject();
    for (entries) |entry| switch (entry) {
        .user => |user| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("user");
            try js.objectField("content");
            if (user.images.len == 0) {
                try js.write(user.text);
            } else {
                try js.beginArray();
                if (user.text.len > 0) {
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("text");
                    try js.objectField("text");
                    try js.write(user.text);
                    try js.endObject();
                }
                for (user.images) |image| {
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("image_url");
                    try js.objectField("image_url");
                    try js.beginObject();
                    try js.objectField("url");
                    try js.beginWriteRaw();
                    try js.writer.writeAll("\"data:");
                    try std.json.Stringify.encodeJsonStringChars(image.media_type, js.options, js.writer);
                    try js.writer.writeAll(";base64,");
                    try std.json.Stringify.encodeJsonStringChars(image.data, js.options, js.writer);
                    try js.writer.writeByte('"');
                    js.endWriteRaw();
                    try js.endObject();
                    try js.endObject();
                }
                try js.endArray();
            }
            try js.endObject();
        },
        .assistant => |answer| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("assistant");
            try js.objectField("content");
            if (answer.text.len > 0 or answer.calls.len == 0) try js.write(answer.text) else try js.write(null);
            if (answer.calls.len > 0) {
                try js.objectField("tool_calls");
                try js.beginArray();
                for (answer.calls) |call| {
                    try js.beginObject();
                    try js.objectField("id");
                    try js.write(call.id);
                    try js.objectField("type");
                    try js.write("function");
                    try js.objectField("function");
                    try js.beginObject();
                    try js.objectField("name");
                    try js.write(call.name);
                    try js.objectField("arguments");
                    try js.write(call.arguments);
                    try js.endObject();
                    try js.endObject();
                }
                try js.endArray();
            }
            try js.endObject();
        },
        .results => |results| for (results) |result| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("tool");
            try js.objectField("tool_call_id");
            try js.write(result.id);
            try js.objectField("content");
            try js.write(result.text);
            try js.endObject();
        },
    };
    if (final_user) |text| {
        try js.beginObject();
        try js.objectField("role");
        try js.write("user");
        try js.objectField("content");
        try js.write(text);
        try js.endObject();
    }
    try js.endArray();
}

fn writeResponsesInput(js: *std.json.Stringify, entries: []const types.Entry, system: ?[]const u8, final_user: ?[]const u8) !void {
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
        .user => |user| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("user");
            try js.objectField("content");
            try js.beginArray();
            for (user.images) |image| {
                try js.beginObject();
                try js.objectField("type");
                try js.write("input_image");
                try js.objectField("image_url");
                try js.beginWriteRaw();
                try js.writer.writeAll("\"data:");
                try std.json.Stringify.encodeJsonStringChars(image.media_type, js.options, js.writer);
                try js.writer.writeAll(";base64,");
                try std.json.Stringify.encodeJsonStringChars(image.data, js.options, js.writer);
                try js.writer.writeByte('"');
                js.endWriteRaw();
                try js.objectField("detail");
                try js.write("auto");
                try js.endObject();
            }
            if (user.text.len > 0 or user.images.len == 0) {
                try js.beginObject();
                try js.objectField("type");
                try js.write("input_text");
                try js.objectField("text");
                try js.write(user.text);
                try js.endObject();
            }
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
    if (final_user) |text| {
        try js.beginObject();
        try js.objectField("role");
        try js.write("user");
        try js.objectField("content");
        try js.write(text);
        try js.endObject();
    }
    try js.endArray();
}

fn writeClaudeMessages(js: *std.json.Stringify, entries: []const types.Entry, final_user: ?[]const u8) !void {
    try js.beginArray();
    for (entries) |entry| switch (entry) {
        .user => |user| {
            try js.beginObject();
            try js.objectField("role");
            try js.write("user");
            try js.objectField("content");
            if (user.images.len == 0) {
                try js.write(user.text);
            } else {
                try js.beginArray();
                for (user.images) |image| {
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("image");
                    try js.objectField("source");
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("base64");
                    try js.objectField("media_type");
                    try js.write(image.media_type);
                    try js.objectField("data");
                    try js.write(image.data);
                    try js.endObject();
                    try js.endObject();
                }
                if (user.text.len > 0) {
                    try js.beginObject();
                    try js.objectField("type");
                    try js.write("text");
                    try js.objectField("text");
                    try js.write(user.text);
                    try js.endObject();
                }
                try js.endArray();
            }
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
    if (final_user) |text| {
        try js.beginObject();
        try js.objectField("role");
        try js.write("user");
        try js.objectField("content");
        try js.write(text);
        try js.endObject();
    }
    try js.endArray();
}

fn rawValue(js: *std.json.Stringify, value: []const u8) !void {
    try js.beginWriteRaw();
    try js.writer.writeAll(value);
    js.endWriteRaw();
}

test "system prompt includes runtime provider and model" {
    const chatgpt = try build(std.testing.allocator, .builtin(.chatgpt), "gpt-5.6-sol", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(chatgpt);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt, "Runtime: provider=chatgpt, model=gpt-5.6-sol.") != null);

    const claude = try build(std.testing.allocator, .builtin(.claude), "claude-opus-5", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(claude);
    try std.testing.expect(std.mem.indexOf(u8, claude, "Runtime: provider=claude, model=claude-opus-5.") != null);

    const grok = try build(std.testing.allocator, .builtin(.grok), "grok-4.6", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(grok);
    try std.testing.expect(std.mem.indexOf(u8, grok, "Runtime: provider=grok, model=grok-4.6.") != null);
}

test "custom tools are serialized for both provider contracts" {
    const definitions = &.{tools.Definition{
        .name = "lookup",
        .description = "Look up a value.",
        .parameters_json = "{\"type\":\"object\"}",
    }};
    const responses = try build(std.testing.allocator, .builtin(.chatgpt), "gpt-5.6-sol", null, false, .{ .include_builtin = false, .custom = definitions }, "/work", "", &.{});
    defer std.testing.allocator.free(responses);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"name\":\"lookup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"name\":\"read\"") == null);

    const claude = try build(std.testing.allocator, .builtin(.claude), "claude-opus-5", null, false, .{ .include_builtin = false, .custom = definitions }, "/work", "", &.{});
    defer std.testing.allocator.free(claude);
    try std.testing.expect(std.mem.indexOf(u8, claude, "\"name\":\"lookup\"") != null);
}

test "images use each provider's multimodal content blocks" {
    const image: types.Image = .{ .name = "shot.png", .media_type = "image/png", .data = "aGVsbG8=" };
    const entries = &.{types.Entry{ .user = .{ .text = "inspect this", .images = &.{image} } }};

    const responses = try build(std.testing.allocator, .builtin(.chatgpt), "gpt-5.6-sol", null, false, .{ .include_builtin = false }, "/work", "", entries);
    defer std.testing.allocator.free(responses);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"type\":\"input_image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"image_url\":\"data:image/png;base64,aGVsbG8=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"text\":\"inspect this\"") != null);

    const grok = try build(std.testing.allocator, .builtin(.grok), "grok-4.6", null, false, .{ .include_builtin = false }, "/work", "", entries);
    defer std.testing.allocator.free(grok);
    try std.testing.expect(std.mem.indexOf(u8, grok, "\"type\":\"input_image\"") != null);

    const claude = try build(std.testing.allocator, .builtin(.claude), "claude-opus-5", null, false, .{ .include_builtin = false }, "/work", "", entries);
    defer std.testing.allocator.free(claude);
    try std.testing.expect(std.mem.indexOf(u8, claude, "\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"aGVsbG8=\"}") != null);
}

test "fast mode headers follow each provider's contract" {
    try std.testing.expectEqualStrings("claude-code-20250219,oauth-2025-04-20,fast-mode-2026-02-01", claudeBetaHeader(true));
    try std.testing.expectEqualStrings("claude-code-20250219,oauth-2025-04-20", claudeBetaHeader(false));

    const fast_hint = try chatgptRoutingHint(std.testing.allocator, "gpt-5.6-sol", true);
    defer std.testing.allocator.free(fast_hint);
    try std.testing.expectEqualStrings("model=gpt-5.6-sol;tier=priority", fast_hint);

    const standard_hint = try chatgptRoutingHint(std.testing.allocator, "gpt-5.4-mini", false);
    defer std.testing.allocator.free(standard_hint);
    try std.testing.expectEqualStrings("model=gpt-5.4-mini", standard_hint);
}

fn customTarget(api: auth.Api) providers.Target {
    return .{ .provider = .custom, .api = api, .name = "local" };
}

test "Chat Completions requests carry system, tools, history, and results" {
    const entries = &.{
        types.Entry{ .user = .{ .text = "find it" } },
        types.Entry{ .assistant = .{ .text = "", .calls = &.{.{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a\"}" }}, .raw_items = &.{"never sent"} } },
        types.Entry{ .results = &.{.{ .id = "call_1", .text = "contents" }} },
        types.Entry{ .assistant = .{ .text = "done", .calls = &.{} } },
    };
    const body = try build(std.testing.allocator, customTarget(.chat_completions), "qwen3-coder", .high, false, .{}, "/work", "", entries);
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("qwen3-coder", root.get("model").?.string);
    try std.testing.expect(root.get("stream").?.bool);
    try std.testing.expect(root.get("stream_options").?.object.get("include_usage").?.bool);
    try std.testing.expectEqualStrings("high", root.get("reasoning_effort").?.string);
    try std.testing.expectEqualStrings("auto", root.get("tool_choice").?.string);
    try std.testing.expect(root.get("input") == null);
    try std.testing.expect(root.get("store") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "never sent") == null);
    const messages = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), messages.len);
    try std.testing.expectEqualStrings("system", messages[0].object.get("role").?.string);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].object.get("content").?.string, "provider=local, model=qwen3-coder") != null);
    try std.testing.expectEqualStrings("find it", messages[1].object.get("content").?.string);
    const call = messages[2].object.get("tool_calls").?.array.items[0].object;
    try std.testing.expect(messages[2].object.get("content").? == .null);
    try std.testing.expectEqualStrings("call_1", call.get("id").?.string);
    try std.testing.expectEqualStrings("read", call.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", call.get("function").?.object.get("arguments").?.string);
    try std.testing.expectEqualStrings("tool", messages[3].object.get("role").?.string);
    try std.testing.expectEqualStrings("call_1", messages[3].object.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("contents", messages[3].object.get("content").?.string);
    try std.testing.expectEqualStrings("done", messages[4].object.get("content").?.string);
    const first_tool = root.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("function", first_tool.get("type").?.string);
    try std.testing.expectEqualStrings("read", first_tool.get("function").?.object.get("name").?.string);

    const without_tools = try build(std.testing.allocator, customTarget(.chat_completions), "m", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(without_tools);
    try std.testing.expect(std.mem.indexOf(u8, without_tools, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, without_tools, "reasoning_effort") == null);
}

test "Chat Completions images use data URLs and compaction ends with the handoff prompt" {
    const image: types.Image = .{ .name = "shot.png", .media_type = "image/png", .data = "aGVsbG8=" };
    const entries = &.{types.Entry{ .user = .{ .text = "inspect", .images = &.{image} } }};
    const body = try build(std.testing.allocator, customTarget(.chat_completions), "m", null, false, .{ .include_builtin = false }, "/work", "", entries);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGVsbG8=\"}") != null);

    const compact = try buildCompact(std.testing.allocator, customTarget(.chat_completions), "m", .low, false, entries);
    defer std.testing.allocator.free(compact);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, compact, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqualStrings(compact_system, messages[0].object.get("content").?.string);
    try std.testing.expectEqualStrings(compact_prompt, messages[messages.len - 1].object.get("content").?.string);
    try std.testing.expectEqualStrings("low", parsed.value.object.get("reasoning_effort").?.string);
}

test "custom Messages and Responses endpoints omit subscription-only fields" {
    const messages = try build(std.testing.allocator, customTarget(.messages), "claude-compatible", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(messages);
    try std.testing.expect(std.mem.indexOf(u8, messages, "Claude Code") == null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "\"max_tokens\":32768") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "provider=local") != null);
    const claude = try build(std.testing.allocator, .builtin(.claude), "claude-opus-5", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(claude);
    try std.testing.expect(std.mem.indexOf(u8, claude, "Claude Code") != null);

    const responses = try build(std.testing.allocator, customTarget(.responses), "gpt-compatible", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(responses);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"role\":\"developer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"instructions\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "reasoning.encrypted_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "service_tier") == null);
    const compact = try buildCompact(std.testing.allocator, customTarget(.responses), "gpt-compatible", null, false, &.{});
    defer std.testing.allocator.free(compact);
    try std.testing.expect(std.mem.indexOf(u8, compact, "\"max_output_tokens\":8192") != null);
}
