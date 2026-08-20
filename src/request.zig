const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const models = @import("models.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

pub fn build(gpa: std.mem.Allocator, provider: auth.Provider, model: []const u8, effort: ?models.Effort, fast: bool, tool_options: tools.SchemaOptions, cwd: []const u8, instructions: []const u8, entries: []const types.Entry) ![]u8 {
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
    const system = try std.fmt.allocPrint(gpa, "You are a concise coding agent in {s}. Runtime: provider={s}, model={s}.{s}{s}{s}{s}{s} Verify material changes.{s}", .{ cwd, @tagName(provider), model, write_instructions, web_instructions, subagent_instructions, custom_instructions, permission_instructions, instructions });
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
        if (fast) {
            try js.objectField("speed");
            try js.write("fast");
        }
        if (effort) |value| {
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
        try writeClaudeMessages(&js, entries, null);
        try js.objectField("tools");
        try tools.claudeSchemasWithOptions(&js, tool_options);
    } else {
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
        if (provider == .chatgpt) {
            if (fast) {
                try js.objectField("service_tier");
                try js.write("fast");
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
        try writeResponsesInput(gpa, &js, entries, if (provider == .grok) system else null, null);
        try js.objectField("tools");
        try tools.schemasWithOptions(&js, tool_options);
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

pub const compact_system = "Summarize the supplied coding-agent history for continuation. Preserve the active goal, user requirements, decisions, files and symbols changed, commands and test results, unresolved errors, and exact identifiers needed to continue. Drop repetition and obsolete exploration. Output only a concise factual handoff; do not call tools.";
pub const compact_prompt = "Create the continuation handoff now.";

pub fn buildCompact(gpa: std.mem.Allocator, provider: auth.Provider, model: []const u8, effort: ?models.Effort, fast: bool, entries: []const types.Entry) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("model");
    try js.write(model);
    try js.objectField("stream");
    try js.write(true);
    if (provider == .claude) {
        try js.objectField("max_tokens");
        try js.write(8192);
        if (fast) {
            try js.objectField("speed");
            try js.write("fast");
        }
        if (effort) |value| {
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
        try js.objectField("system");
        try js.write(compact_system);
        try js.objectField("messages");
        try writeClaudeMessages(&js, entries, compact_prompt);
    } else {
        try js.objectField("store");
        try js.write(false);
        if (provider == .grok) {
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
        if (provider == .chatgpt) {
            if (fast) {
                try js.objectField("service_tier");
                try js.write("fast");
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
        try writeResponsesInput(gpa, &js, entries, if (provider == .grok) compact_system else null, compact_prompt);
    }
    try js.endObject();
    return out.toOwnedSlice();
}

fn writeResponsesInput(gpa: std.mem.Allocator, js: *std.json.Stringify, entries: []const types.Entry, system: ?[]const u8, final_user: ?[]const u8) !void {
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
                const data_url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ image.media_type, image.data });
                defer gpa.free(data_url);
                try js.write(data_url);
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
    const chatgpt = try build(std.testing.allocator, .chatgpt, "gpt-5.6-sol", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(chatgpt);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt, "Runtime: provider=chatgpt, model=gpt-5.6-sol.") != null);

    const claude = try build(std.testing.allocator, .claude, "claude-opus-5", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(claude);
    try std.testing.expect(std.mem.indexOf(u8, claude, "Runtime: provider=claude, model=claude-opus-5.") != null);

    const grok = try build(std.testing.allocator, .grok, "grok-4.6", null, false, .{ .include_builtin = false }, "/work", "", &.{});
    defer std.testing.allocator.free(grok);
    try std.testing.expect(std.mem.indexOf(u8, grok, "Runtime: provider=grok, model=grok-4.6.") != null);
}

test "custom tools are serialized for both provider contracts" {
    const definitions = &.{tools.Definition{
        .name = "lookup",
        .description = "Look up a value.",
        .parameters_json = "{\"type\":\"object\"}",
    }};
    const responses = try build(std.testing.allocator, .chatgpt, "gpt-5.6-sol", null, false, .{ .include_builtin = false, .custom = definitions }, "/work", "", &.{});
    defer std.testing.allocator.free(responses);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"name\":\"lookup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"name\":\"read\"") == null);

    const claude = try build(std.testing.allocator, .claude, "claude-opus-5", null, false, .{ .include_builtin = false, .custom = definitions }, "/work", "", &.{});
    defer std.testing.allocator.free(claude);
    try std.testing.expect(std.mem.indexOf(u8, claude, "\"name\":\"lookup\"") != null);
}

test "images use each provider's multimodal content blocks" {
    const image: types.Image = .{ .name = "shot.png", .media_type = "image/png", .data = "aGVsbG8=" };
    const entries = &.{types.Entry{ .user = .{ .text = "inspect this", .images = &.{image} } }};

    const responses = try build(std.testing.allocator, .chatgpt, "gpt-5.6-sol", null, false, .{ .include_builtin = false }, "/work", "", entries);
    defer std.testing.allocator.free(responses);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"type\":\"input_image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"image_url\":\"data:image/png;base64,aGVsbG8=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, responses, "\"text\":\"inspect this\"") != null);

    const grok = try build(std.testing.allocator, .grok, "grok-4.6", null, false, .{ .include_builtin = false }, "/work", "", entries);
    defer std.testing.allocator.free(grok);
    try std.testing.expect(std.mem.indexOf(u8, grok, "\"type\":\"input_image\"") != null);

    const claude = try build(std.testing.allocator, .claude, "claude-opus-5", null, false, .{ .include_builtin = false }, "/work", "", entries);
    defer std.testing.allocator.free(claude);
    try std.testing.expect(std.mem.indexOf(u8, claude, "\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"aGVsbG8=\"}") != null);
}
