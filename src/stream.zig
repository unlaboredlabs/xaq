//! Provider SSE decoding shared by the CLI and the in-process API.

const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const types = @import("types.zig");

pub const Hooks = struct {
    context: ?*anyopaque = null,
    on_first_text: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    on_delta: ?*const fn (context: ?*anyopaque, delta: []const u8) anyerror!void = null,
};

const StreamingClaudeCall = struct {
    index: i64,
    id: []const u8,
    name: []const u8,
    args: Io.Writer.Allocating,
};

pub const Decoder = struct {
    provider: auth.Provider,
    parse_gpa: std.mem.Allocator,
    persist: std.mem.Allocator,
    hooks: Hooks,
    text: Io.Writer.Allocating,
    calls: std.ArrayList(types.ToolCall) = .empty,
    raw: std.ArrayList([]const u8) = .empty,
    claude_calls: std.ArrayList(StreamingClaudeCall) = .empty,
    usage: types.Usage = .{},
    received: bool = false,
    received_text: bool = false,

    pub fn init(provider: auth.Provider, parse_gpa: std.mem.Allocator, persist: std.mem.Allocator, hooks: Hooks) Decoder {
        return .{
            .provider = provider,
            .parse_gpa = parse_gpa,
            .persist = persist,
            .hooks = hooks,
            .text = .init(persist),
        };
    }

    fn noteOutput(self: *Decoder) void {
        self.received = true;
    }

    fn writeDelta(self: *Decoder, delta: []const u8) !void {
        self.noteOutput();
        if (delta.len > 0 and !self.received_text) {
            self.received_text = true;
            if (self.hooks.on_first_text) |callback| try callback(self.hooks.context);
        }
        try self.text.writer.writeAll(delta);
        if (self.hooks.on_delta) |callback| try callback(self.hooks.context, delta);
    }

    pub fn feed(self: *Decoder, raw_line: []const u8) !void {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const data = std.mem.trimStart(u8, line[5..], " ");
        if (std.mem.eql(u8, data, "[DONE]") or data.len == 0) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.parse_gpa, data, .{}) catch return;
        defer parsed.deinit();
        if (self.provider == .claude) {
            try self.feedClaude(parsed.value, data);
        } else {
            try self.feedResponses(parsed.value, data);
        }
    }

    fn feedResponses(self: *Decoder, value: std.json.Value, data: []const u8) !void {
        const kind = eventString(value, "type") orelse return;
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            try self.writeDelta(eventString(value, "delta") orelse return);
        } else if (std.mem.eql(u8, kind, "response.output_item.done")) {
            self.noteOutput();
            const item = switch (value) {
                .object => |object| object.get("item") orelse return,
                else => return,
            };
            var item_out: Io.Writer.Allocating = .init(self.persist);
            try std.json.Stringify.value(item, .{}, &item_out.writer);
            try self.raw.append(self.persist, try item_out.toOwnedSlice());
            if (eventString(item, "type")) |item_type| if (std.mem.eql(u8, item_type, "function_call")) {
                try self.calls.append(self.persist, .{
                    .id = try self.persist.dupe(u8, eventString(item, "call_id") orelse return error.InvalidProviderResponse),
                    .name = try self.persist.dupe(u8, eventString(item, "name") orelse return error.InvalidProviderResponse),
                    .arguments = try self.persist.dupe(u8, eventString(item, "arguments") orelse "{}"),
                });
            };
        } else if (std.mem.eql(u8, kind, "response.completed")) {
            const usage_value = eventObject(eventObject(value, "response") orelse return, "usage") orelse return;
            if (eventInteger(usage_value, "input_tokens")) |number| self.usage.input = number;
            if (eventInteger(usage_value, "output_tokens")) |number| self.usage.output = number;
            if (eventObject(usage_value, "input_tokens_details")) |details| {
                if (eventInteger(details, "cached_tokens")) |number| self.usage.cached = number;
            }
        } else if (std.mem.eql(u8, kind, "response.failed") or std.mem.eql(u8, kind, "error")) {
            _ = data;
            return error.ProviderRequestFailed;
        }
    }

    fn feedClaude(self: *Decoder, value: std.json.Value, data: []const u8) !void {
        const kind = eventString(value, "type") orelse return;
        if (std.mem.eql(u8, kind, "content_block_start")) {
            self.noteOutput();
            const index = switch (value.object.get("index") orelse return) {
                .integer => |number| number,
                else => return,
            };
            const block = value.object.get("content_block") orelse return;
            if (eventString(block, "type")) |block_type| if (std.mem.eql(u8, block_type, "tool_use")) {
                try self.claude_calls.append(self.persist, .{
                    .index = index,
                    .id = try self.persist.dupe(u8, eventString(block, "id") orelse return error.InvalidProviderResponse),
                    .name = try self.persist.dupe(u8, eventString(block, "name") orelse return error.InvalidProviderResponse),
                    .args = .init(self.persist),
                });
            };
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const delta = value.object.get("delta") orelse return;
            const delta_type = eventString(delta, "type") orelse return;
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                try self.writeDelta(eventString(delta, "text") orelse return);
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const index = switch (value.object.get("index") orelse return) {
                    .integer => |number| number,
                    else => return,
                };
                const part = eventString(delta, "partial_json") orelse return;
                for (self.claude_calls.items) |*call| if (call.index == index) {
                    try call.args.writer.writeAll(part);
                    break;
                };
            }
        } else if (std.mem.eql(u8, kind, "message_start")) {
            const usage_value = eventObject(eventObject(value, "message") orelse return, "usage") orelse return;
            if (eventInteger(usage_value, "input_tokens")) |number| self.usage.input = number;
            if (eventInteger(usage_value, "cache_read_input_tokens")) |number| self.usage.cached = number;
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            const usage_value = eventObject(value, "usage") orelse return;
            if (eventInteger(usage_value, "input_tokens")) |number| self.usage.input = number;
            if (eventInteger(usage_value, "output_tokens")) |number| self.usage.output = number;
        } else if (std.mem.eql(u8, kind, "error")) {
            _ = data;
            return error.ProviderRequestFailed;
        }
    }

    pub fn finish(self: *Decoder) !types.Assistant {
        if (self.provider == .claude) {
            for (self.claude_calls.items) |*call| try self.calls.append(self.persist, .{
                .id = call.id,
                .name = call.name,
                .arguments = if (call.args.written().len == 0)
                    try self.persist.dupe(u8, "{}")
                else
                    try self.persist.dupe(u8, call.args.written()),
            });
        }
        return .{
            .text = try self.text.toOwnedSlice(),
            .calls = try self.calls.toOwnedSlice(self.persist),
            .raw_items = try self.raw.toOwnedSlice(self.persist),
            .usage = self.usage,
        };
    }
};

fn eventString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const child = switch (value) {
        .object => |object| object.get(key) orelse return null,
        else => return null,
    };
    return switch (child) {
        .string => |text| text,
        else => null,
    };
}

fn eventObject(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn eventInteger(value: std.json.Value, key: []const u8) ?u64 {
    const child = switch (value) {
        .object => |object| object.get(key) orelse return null,
        else => return null,
    };
    return switch (child) {
        .integer => |number| if (number < 0) null else @intCast(number),
        else => null,
    };
}

test "decodes Responses text, calls, and usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.chatgpt, std.testing.allocator, arena.allocator(), .{});
    try decoder.feed("data: {\"type\":\"response.output_text.delta\",\"delta\":\"done\"}");
    try decoder.feed("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{}\"}}");
    try decoder.feed("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":3},\"output_tokens\":5}}}");
    const result = try decoder.finish();
    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expectEqualStrings("read", result.calls[0].name);
    try std.testing.expectEqual(@as(u64, 10), result.usage.input);
    try std.testing.expectEqual(@as(u64, 3), result.usage.cached);
    try std.testing.expectEqual(@as(u64, 5), result.usage.output);
}

test "decodes Anthropic fragmented tool input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.claude, std.testing.allocator, arena.allocator(), .{});
    try decoder.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}");
    try decoder.feed("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"bash\",\"input\":{}}}");
    try decoder.feed("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}");
    const result = try decoder.finish();
    try std.testing.expectEqualStrings("ok", result.text);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", result.calls[0].arguments);
}

const TextProbe = struct {
    calls: usize = 0,

    fn onFirstText(raw: ?*anyopaque) !void {
        const self: *TextProbe = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
    }
};

test "Responses hidden output does not announce visible text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var probe: TextProbe = .{};
    var decoder = Decoder.init(.chatgpt, std.testing.allocator, arena.allocator(), .{
        .context = &probe,
        .on_first_text = TextProbe.onFirstText,
    });

    try decoder.feed("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"encrypted_content\":\"hidden\"}}");
    try decoder.feed("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{}\"}}");
    try std.testing.expect(decoder.received);
    try std.testing.expect(!decoder.received_text);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);

    try decoder.feed("data: {\"type\":\"response.output_text.delta\",\"delta\":\"\"}");
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try decoder.feed("data: {\"type\":\"response.output_text.delta\",\"delta\":\"visible\"}");
    try decoder.feed("data: {\"type\":\"response.output_text.delta\",\"delta\":\" text\"}");
    try std.testing.expect(decoder.received_text);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "Anthropic hidden blocks do not announce visible text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var probe: TextProbe = .{};
    var decoder = Decoder.init(.claude, std.testing.allocator, arena.allocator(), .{
        .context = &probe,
        .on_first_text = TextProbe.onFirstText,
    });

    try decoder.feed("data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}");
    try decoder.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hidden\"}}");
    try decoder.feed("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"bash\",\"input\":{}}}");
    try std.testing.expect(decoder.received);
    try std.testing.expect(!decoder.received_text);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);

    try decoder.feed("data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"visible\"}}");
    try std.testing.expect(decoder.received_text);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}
