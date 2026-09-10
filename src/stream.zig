//! Provider SSE decoding shared by the CLI and the in-process API.

const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const transport = @import("transport.zig");
const types = @import("types.zig");

pub const Hooks = struct {
    context: ?*anyopaque = null,
    on_output: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    on_delta: ?*const fn (context: ?*anyopaque, delta: []const u8) anyerror!void = null,
};

/// The processing class reported by the provider, not measured latency.
/// Anthropic echoes `usage.speed`; the Responses API echoes the applied
/// `service_tier`. Missing or unfamiliar values stay unknown.
pub const ServedSpeed = enum { unknown, standard, fast };

/// A tool call assembled from fragments: Anthropic `input_json_delta` or
/// Chat Completions `tool_calls[].function.arguments` chunks keyed by index.
const StreamingCall = struct {
    index: i64,
    id: []const u8,
    name: []const u8,
    args: Io.Writer.Allocating,
};

pub const Decoder = struct {
    api: auth.Api,
    parse_arena: std.heap.ArenaAllocator,
    persist: std.mem.Allocator,
    hooks: Hooks,
    text: Io.Writer.Allocating,
    calls: std.ArrayList(types.ToolCall) = .empty,
    raw: std.ArrayList([]const u8) = .empty,
    streamed_calls: std.ArrayList(StreamingCall) = .empty,
    usage: types.Usage = .{},
    speed: ServedSpeed = .unknown,
    service_tier_buffer: [64]u8 = undefined,
    service_tier_len: ?usize = null,
    service_tier_truncated: bool = false,
    completed: bool = false,
    provider_error: ?[]const u8 = null,

    pub fn init(api: auth.Api, parse_gpa: std.mem.Allocator, persist: std.mem.Allocator, hooks: Hooks) Decoder {
        return .{
            .api = api,
            .parse_arena = .init(parse_gpa),
            .persist = persist,
            .hooks = hooks,
            .text = .init(persist),
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.parse_arena.deinit();
    }

    fn beforeOutput(self: *Decoder) !void {
        if (self.hooks.on_output) |callback| try callback(self.hooks.context);
    }

    fn writeDelta(self: *Decoder, delta: []const u8) !void {
        try self.beforeOutput();
        try self.text.writer.writeAll(delta);
        if (self.hooks.on_delta) |callback| try callback(self.hooks.context, delta);
    }

    fn captureProviderError(self: *Decoder, data: []const u8) !void {
        if (self.provider_error != null) return;
        self.provider_error = if (transport.errorMessage(self.persist, data)) |message|
            message
        else
            try self.persist.dupe(u8, data[0..@min(data.len, 128 * 1024)]);
    }

    pub fn providerError(self: *const Decoder) ?[]const u8 {
        return self.provider_error;
    }

    /// A bounded copy survives reuse of the event parser's arena. Callers
    /// must escape this provider-controlled value when displaying it.
    pub fn reportedServiceTier(self: *const Decoder) ?[]const u8 {
        return self.service_tier_buffer[0 .. self.service_tier_len orelse return null];
    }

    pub fn feed(self: *Decoder, raw_line: []const u8) !void {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const data = std.mem.trimStart(u8, line[5..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) {
            // Chat Completions has no completion event of its own; the
            // terminal sentinel is the contract, alongside finish_reason.
            if (self.api == .chat_completions) self.completed = true;
            return;
        }
        if (data.len == 0) return;
        // Event values are only borrowed for this call. Reusing the arena
        // avoids allocator churn across the many events in one response.
        _ = self.parse_arena.reset(.{ .retain_with_limit = 256 * 1024 });
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.parse_arena.allocator(), data, .{}) catch return;
        switch (self.api) {
            .messages => try self.feedClaude(parsed, data),
            .responses => try self.feedResponses(parsed, data),
            .chat_completions => try self.feedChat(parsed, data),
        }
    }

    /// OpenAI-style chunks: `choices[0].delta` carries text and tool call
    /// fragments, `finish_reason` closes the choice, and the final chunk
    /// may carry `usage` when `stream_options.include_usage` is on.
    fn feedChat(self: *Decoder, value: std.json.Value, data: []const u8) !void {
        if (value != .object) return;
        if (value.object.get("error")) |err| if (err != .null) return self.captureProviderError(data);
        if (eventObject(value, "usage")) |usage_value| if (usage_value == .object) {
            if (eventInteger(usage_value, "prompt_tokens")) |number| self.usage.input = number;
            if (eventInteger(usage_value, "completion_tokens")) |number| self.usage.output = number;
            if (eventObject(usage_value, "prompt_tokens_details")) |details| {
                if (eventInteger(details, "cached_tokens")) |number| self.usage.cached = number;
            }
        };
        const choices = value.object.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (eventObject(choice, "delta")) |delta| {
            if (eventString(delta, "content")) |text| if (text.len > 0) try self.writeDelta(text);
            if (eventObject(delta, "tool_calls")) |calls| if (calls == .array) {
                for (calls.array.items) |call| try self.noteChatToolCall(call);
            };
        }
        if (eventString(choice, "finish_reason") != null) self.completed = true;
    }

    fn noteChatToolCall(self: *Decoder, call: std.json.Value) !void {
        try self.beforeOutput();
        const function = eventObject(call, "function");
        const index: i64 = if (eventInteger(call, "index")) |number| @intCast(number) else @intCast(self.streamed_calls.items.len);
        const fragment = if (function) |value| eventString(value, "arguments") else null;
        for (self.streamed_calls.items) |*existing| if (existing.index == index) {
            // Some servers repeat the name on later fragments; only fill a gap.
            if (existing.name.len == 0) if (function) |value| if (eventString(value, "name")) |name| {
                existing.name = try self.persist.dupe(u8, name);
            };
            if (fragment) |part| try existing.args.writer.writeAll(part);
            return;
        };
        const id = eventString(call, "id") orelse "";
        try self.streamed_calls.append(self.persist, .{
            .index = index,
            .id = if (id.len > 0) try self.persist.dupe(u8, id) else try std.fmt.allocPrint(self.persist, "call_{d}", .{index}),
            .name = try self.persist.dupe(u8, if (function) |value| eventString(value, "name") orelse "" else ""),
            .args = .init(self.persist),
        });
        if (fragment) |part| try self.streamed_calls.items[self.streamed_calls.items.len - 1].args.writer.writeAll(part);
    }

    fn feedResponses(self: *Decoder, value: std.json.Value, data: []const u8) !void {
        const kind = eventString(value, "type") orelse return;
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            try self.writeDelta(eventString(value, "delta") orelse return);
        } else if (std.mem.eql(u8, kind, "response.output_item.done")) {
            try self.beforeOutput();
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
        } else if (std.mem.eql(u8, kind, "response.completed") or std.mem.eql(u8, kind, "response.incomplete")) {
            const response = eventObject(value, "response") orelse return;
            self.completed = std.mem.eql(u8, kind, "response.completed");
            self.noteResponsesTier(eventString(response, "service_tier"));
            const usage_value = eventObject(response, "usage") orelse return;
            if (eventInteger(usage_value, "input_tokens")) |number| self.usage.input = number;
            if (eventInteger(usage_value, "output_tokens")) |number| self.usage.output = number;
            if (eventObject(usage_value, "input_tokens_details")) |details| {
                if (eventInteger(details, "cached_tokens")) |number| self.usage.cached = number;
            }
        } else if (std.mem.eql(u8, kind, "response.failed") or std.mem.eql(u8, kind, "error")) {
            try self.captureProviderError(data);
        }
    }

    fn feedClaude(self: *Decoder, value: std.json.Value, data: []const u8) !void {
        const kind = eventString(value, "type") orelse return;
        if (std.mem.eql(u8, kind, "content_block_start")) {
            try self.beforeOutput();
            const index = switch (value.object.get("index") orelse return) {
                .integer => |number| number,
                else => return,
            };
            const block = value.object.get("content_block") orelse return;
            if (eventString(block, "type")) |block_type| if (std.mem.eql(u8, block_type, "tool_use")) {
                try self.streamed_calls.append(self.persist, .{
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
                for (self.streamed_calls.items) |*call| if (call.index == index) {
                    try call.args.writer.writeAll(part);
                    break;
                };
            }
        } else if (std.mem.eql(u8, kind, "message_start")) {
            const usage_value = eventObject(eventObject(value, "message") orelse return, "usage") orelse return;
            if (eventInteger(usage_value, "input_tokens")) |number| self.usage.input = number;
            if (eventInteger(usage_value, "cache_read_input_tokens")) |number| self.usage.cached = number;
            self.noteClaudeSpeed(usage_value);
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            const usage_value = eventObject(value, "usage") orelse return;
            if (eventInteger(usage_value, "input_tokens")) |number| self.usage.input = number;
            if (eventInteger(usage_value, "output_tokens")) |number| self.usage.output = number;
            self.noteClaudeSpeed(usage_value);
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            self.completed = true;
        } else if (std.mem.eql(u8, kind, "error")) {
            try self.captureProviderError(data);
        }
    }

    fn noteResponsesTier(self: *Decoder, value: ?[]const u8) void {
        self.speed = .unknown;
        self.service_tier_len = null;
        self.service_tier_truncated = false;
        const tier = value orelse return;
        var len = @min(tier.len, self.service_tier_buffer.len);
        // A bounded diagnostic must not end inside a UTF-8 character.
        while (len < tier.len and tier[len] & 0xc0 == 0x80) len -= 1;
        @memcpy(self.service_tier_buffer[0..len], tier[0..len]);
        self.service_tier_len = len;
        self.service_tier_truncated = len < tier.len;
        if (std.mem.eql(u8, tier, "priority") or std.mem.eql(u8, tier, "fast") or std.mem.eql(u8, tier, "ultrafast")) {
            self.speed = .fast;
        } else if (std.mem.eql(u8, tier, "default")) {
            self.speed = .standard;
        }
    }

    /// Anthropic reports `usage.speed` as "fast" or "standard" on models
    /// that know the field; older models omit it and stay unknown.
    fn noteClaudeSpeed(self: *Decoder, usage_value: std.json.Value) void {
        const speed = eventString(usage_value, "speed") orelse return;
        if (std.mem.eql(u8, speed, "fast")) {
            self.speed = .fast;
        } else if (std.mem.eql(u8, speed, "standard")) {
            self.speed = .standard;
        }
    }

    pub fn validateComplete(self: *const Decoder) !void {
        if (self.provider_error != null) return error.ProviderRequestFailed;
        if (!self.completed) return error.IncompleteProviderResponse;
    }

    /// Interrupted responses retain visible text only. Tool calls and private
    /// replay items belong to an unfinished exchange and must not be executed
    /// or sent back to the provider on the next turn.
    pub fn finishPartial(self: *Decoder) !types.Assistant {
        if (self.provider_error != null) return error.ProviderRequestFailed;
        return .{
            .text = try self.text.toOwnedSlice(),
            .calls = &.{},
            .usage = self.usage,
        };
    }

    pub fn finish(self: *Decoder) !types.Assistant {
        try self.validateComplete();
        if (self.api != .responses) {
            for (self.streamed_calls.items) |*call| {
                if (call.name.len == 0) return error.InvalidProviderResponse;
                try self.calls.append(self.persist, .{
                    .id = call.id,
                    .name = call.name,
                    .arguments = if (call.args.written().len == 0)
                        try self.persist.dupe(u8, "{}")
                    else
                        try call.args.toOwnedSlice(),
                });
            }
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
    var decoder = Decoder.init(.responses, std.testing.allocator, arena.allocator(), .{});
    defer decoder.deinit();
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

test "classifies only recognized returned service tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { tier: []const u8, speed: ServedSpeed }{
        .{ .tier = "priority", .speed = .fast },
        .{ .tier = "fast", .speed = .fast },
        .{ .tier = "ultrafast", .speed = .fast },
        .{ .tier = "default", .speed = .standard },
        .{ .tier = "flex", .speed = .unknown },
        .{ .tier = "auto", .speed = .unknown },
        .{ .tier = "future-tier", .speed = .unknown },
        .{ .tier = "", .speed = .unknown },
    };
    for (cases) |case| {
        var decoder = Decoder.init(.responses, std.testing.allocator, arena.allocator(), .{});
        defer decoder.deinit();
        const event = try std.fmt.allocPrint(std.testing.allocator, "data: {{\"type\":\"response.completed\",\"response\":{{\"service_tier\":{f}}}}}", .{std.json.fmt(case.tier, .{})});
        defer std.testing.allocator.free(event);
        try decoder.feed(event);
        try std.testing.expectEqual(case.speed, decoder.speed);
        try std.testing.expectEqualStrings(case.tier, decoder.reportedServiceTier().?);
        try std.testing.expect(!decoder.service_tier_truncated);
    }

    var responses_silent = Decoder.init(.responses, std.testing.allocator, arena.allocator(), .{});
    defer responses_silent.deinit();
    try responses_silent.feed("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}");
    try std.testing.expectEqual(ServedSpeed.unknown, responses_silent.speed);
    try std.testing.expectEqual(null, responses_silent.reportedServiceTier());
    // Missing or malformed final metadata must not reuse an earlier value.
    for ([_][]const u8{ "null", "42" }) |value| {
        try responses_silent.feed("data: {\"type\":\"response.incomplete\",\"response\":{\"service_tier\":\"default\"}}");
        const event = try std.fmt.allocPrint(std.testing.allocator, "data: {{\"type\":\"response.completed\",\"response\":{{\"service_tier\":{s}}}}}", .{value});
        defer std.testing.allocator.free(event);
        try responses_silent.feed(event);
        try std.testing.expectEqual(ServedSpeed.unknown, responses_silent.speed);
        try std.testing.expectEqual(null, responses_silent.reportedServiceTier());
    }
}

test "returned service tier diagnostics survive parser reuse and stay bounded" {
    var decoder = Decoder.init(.responses, std.testing.allocator, std.testing.allocator, .{});
    defer decoder.deinit();
    const tier = "x" ** 63 ++ "界\n\x1b[31m";
    const event = try std.fmt.allocPrint(std.testing.allocator, "data: {{\"type\":\"response.completed\",\"response\":{{\"service_tier\":{f}}}}}", .{std.json.fmt(tier, .{})});
    defer std.testing.allocator.free(event);
    try decoder.feed(event);
    @memset(event, 'x');
    try decoder.feed("data: {\"type\":\"ignored\",\"payload\":\"overwrite parser storage\"}");
    try std.testing.expectEqualStrings("x" ** 63, decoder.reportedServiceTier().?);
    try std.testing.expect(decoder.service_tier_truncated);
    try std.testing.expectEqual(ServedSpeed.unknown, decoder.speed);

    try decoder.feed("data: {\"type\":\"response.completed\",\"response\":{\"service_tier\":\"future\\n\\u001b[31m\\\"\"}}");
    try std.testing.expect(!decoder.service_tier_truncated);
    const diagnostic = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{std.json.fmt(decoder.reportedServiceTier(), .{ .escape_unicode = true })});
    defer std.testing.allocator.free(diagnostic);
    try std.testing.expectEqualStrings("\"future\\n\\u001b[31m\\\"\"", diagnostic);
    try std.testing.expectEqual(ServedSpeed.unknown, decoder.speed);
}

test "reports explicit Anthropic speed metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var claude_fast = Decoder.init(.messages, std.testing.allocator, arena.allocator(), .{});
    defer claude_fast.deinit();
    try claude_fast.feed("data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1,\"speed\":\"fast\"}}}");
    try std.testing.expectEqual(ServedSpeed.fast, claude_fast.speed);

    var claude_standard = Decoder.init(.messages, std.testing.allocator, arena.allocator(), .{});
    defer claude_standard.deinit();
    try claude_standard.feed("data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1}}}");
    try std.testing.expectEqual(ServedSpeed.unknown, claude_standard.speed);
    try claude_standard.feed("data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":2,\"speed\":\"standard\"}}");
    try std.testing.expectEqual(ServedSpeed.standard, claude_standard.speed);
}

test "decodes Anthropic fragmented tool input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.messages, std.testing.allocator, arena.allocator(), .{});
    defer decoder.deinit();
    try decoder.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}");
    try decoder.feed("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"bash\",\"input\":{}}}");
    try decoder.feed("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}");
    try decoder.feed("data: {\"type\":\"message_stop\"}");
    const result = try decoder.finish();
    try std.testing.expectEqualStrings("ok", result.text);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", result.calls[0].arguments);
}

test "finishing Anthropic calls does not duplicate large argument buffers" {
    const Feed = struct {
        fn delta(decoder: *Decoder, index: u8, partial: []const u8) !void {
            var event: Io.Writer.Allocating = .init(std.testing.allocator);
            defer event.deinit();
            try event.writer.writeAll("data: ");
            try std.json.Stringify.value(.{
                .type = "content_block_delta",
                .index = index,
                .delta = .{ .type = "input_json_delta", .partial_json = partial },
            }, .{}, &event.writer);
            try decoder.feed(event.written());
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counted: std.testing.FailingAllocator = .init(arena.allocator(), .{});
    var decoder = Decoder.init(.messages, std.testing.allocator, counted.allocator(), .{});
    defer decoder.deinit();
    try decoder.feed("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"write\",\"input\":{}}}");
    try decoder.feed("data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_2\",\"name\":\"edit\",\"input\":{}}}");
    try decoder.feed("data: {\"type\":\"content_block_start\",\"index\":3,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_3\",\"name\":\"bash\",\"input\":{}}}");
    const chunk = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'x');
    const prefix = "{\"text\":\"";
    const suffix = "\"}";
    for ([_]u8{ 1, 2 }) |index| try Feed.delta(&decoder, index, prefix);
    for (0..4) |_| {
        for ([_]u8{ 1, 2 }) |index| try Feed.delta(&decoder, index, chunk);
    }
    for ([_]u8{ 1, 2 }) |index| try Feed.delta(&decoder, index, suffix);
    try decoder.feed("data: {\"type\":\"message_stop\"}");

    const allocated_before_finish = counted.allocated_bytes;
    const result = try decoder.finish();
    // Finalization needs only call metadata and the empty-input default,
    // regardless of how much source text the tool arguments contain.
    try std.testing.expect(counted.allocated_bytes - allocated_before_finish < chunk.len);
    try std.testing.expectEqual(@as(usize, 3), result.calls.len);
    try std.testing.expectEqualStrings("write", result.calls[0].name);
    try std.testing.expectEqualStrings("edit", result.calls[1].name);
    for (result.calls[0..2]) |call| {
        try std.testing.expectEqual(prefix.len + 4 * chunk.len + suffix.len, call.arguments.len);
        try std.testing.expectEqualStrings(prefix, call.arguments[0..prefix.len]);
        for (0..4) |i| try std.testing.expectEqualSlices(u8, chunk, call.arguments[prefix.len + i * chunk.len ..][0..chunk.len]);
        try std.testing.expectEqualStrings(suffix, call.arguments[call.arguments.len - suffix.len ..]);
    }
    try std.testing.expectEqualStrings("{}", result.calls[2].arguments);
}

test "preserves Anthropic streaming errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.messages, std.testing.allocator, arena.allocator(), .{});
    defer decoder.deinit();
    try decoder.feed("data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Claude is overloaded\"}}");
    try std.testing.expectEqualStrings("Claude is overloaded", decoder.providerError().?);
    try std.testing.expectError(error.ProviderRequestFailed, decoder.finish());
}

test "preserves Responses streaming errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.responses, std.testing.allocator, arena.allocator(), .{});
    defer decoder.deinit();
    try decoder.feed("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Model unavailable\"}}}");
    try std.testing.expectEqualStrings("Model unavailable", decoder.providerError().?);
    try std.testing.expectError(error.ProviderRequestFailed, decoder.finish());
}

test "requires a provider completion event before accepting an answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]auth.Api{ .responses, .messages, .chat_completions }) |api| {
        var decoder = Decoder.init(api, std.testing.allocator, arena.allocator(), .{});
        defer decoder.deinit();
        try std.testing.expectError(error.IncompleteProviderResponse, decoder.finish());
        if (api != .chat_completions) {
            try decoder.feed("data: [DONE]");
            try std.testing.expectError(error.IncompleteProviderResponse, decoder.finish());
        }
        try decoder.feed(switch (api) {
            .messages => "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}",
            .responses => "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}",
            .chat_completions => "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}",
        });
        try std.testing.expectError(error.IncompleteProviderResponse, decoder.finish());
        try decoder.feed(switch (api) {
            .messages => "data: {\"type\":\"message_stop\"}",
            .responses => "data: {\"type\":\"response.completed\",\"response\":{}}",
            .chat_completions => "data: [DONE]",
        });
        const result = try decoder.finish();
        try std.testing.expectEqualStrings("partial", result.text);
    }
}

test "incomplete Responses preserve usage without accepting tool calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.responses, std.testing.allocator, arena.allocator(), .{});
    defer decoder.deinit();
    try decoder.feed("data: {\"type\":\"response.incomplete\",\"response\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}");
    try std.testing.expectError(error.IncompleteProviderResponse, decoder.finish());
    const result = try decoder.finishPartial();
    try std.testing.expectEqual(@as(u64, 10), result.usage.input);
    try std.testing.expectEqual(@as(u64, 5), result.usage.output);
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "decodes Chat Completions text, fragmented tool calls, usage, and finish" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.chat_completions, std.testing.allocator, arena.allocator(), .{});
    defer decoder.deinit();
    try decoder.feed("data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}");
    try decoder.feed("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"look\"},\"finish_reason\":null}]}");
    try decoder.feed("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]},\"finish_reason\":null}]}");
    try decoder.feed("data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a\\\"}\"}},{\"index\":1,\"id\":\"call_b\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}");
    try std.testing.expectError(error.IncompleteProviderResponse, decoder.finish());
    try decoder.feed("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}");
    try decoder.feed("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":7,\"prompt_tokens_details\":{\"cached_tokens\":5}}}");
    try decoder.feed("data: [DONE]");
    const result = try decoder.finish();
    try std.testing.expectEqualStrings("look", result.text);
    try std.testing.expectEqual(@as(usize, 2), result.calls.len);
    try std.testing.expectEqualStrings("call_a", result.calls[0].id);
    try std.testing.expectEqualStrings("read", result.calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", result.calls[0].arguments);
    try std.testing.expectEqualStrings("bash", result.calls[1].name);
    try std.testing.expectEqualStrings("{}", result.calls[1].arguments);
    try std.testing.expectEqual(@as(usize, 0), result.raw_items.len);
    try std.testing.expectEqual(@as(u64, 20), result.usage.input);
    try std.testing.expectEqual(@as(u64, 5), result.usage.cached);
    try std.testing.expectEqual(@as(u64, 7), result.usage.output);
}

test "Chat Completions tool calls without ids or indexes still assemble" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.chat_completions, std.testing.allocator, arena.allocator(), .{});
    defer decoder.deinit();
    try decoder.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    const result = try decoder.finish();
    try std.testing.expectEqualStrings("call_0", result.calls[0].id);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", result.calls[0].arguments);

    var nameless = Decoder.init(.chat_completions, std.testing.allocator, arena.allocator(), .{});
    defer nameless.deinit();
    try nameless.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try std.testing.expectError(error.InvalidProviderResponse, nameless.finish());
}

test "preserves Chat Completions streaming errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoder = Decoder.init(.chat_completions, std.testing.allocator, arena.allocator(), .{});
    defer decoder.deinit();
    try decoder.feed("data: {\"error\":{\"message\":\"model not found\",\"type\":\"invalid_request_error\"}}");
    try std.testing.expectEqualStrings("model not found", decoder.providerError().?);
    try std.testing.expectError(error.ProviderRequestFailed, decoder.finish());
}
