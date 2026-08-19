//! In-process xaq agent API.
//!
//! This module owns no terminal, signal handler, credential file, settings
//! file, or thread file. A host supplies credentials and may replace HTTP and
//! tool execution. `Turn.text` and nested history payloads remain valid until
//! `reset` or `deinit`; reacquire the top-level `history()` slice after each
//! prompt because appending may move it.

const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const cancel_mod = @import("cancel.zig");
const models = @import("models.zig");
const request_builder = @import("request.zig");
const stream = @import("stream.zig");
const tool_runtime = @import("tools.zig");
const transport_runtime = @import("transport.zig");
const types = @import("types.zig");

pub const api_version = 1;
pub const Provider = auth.Provider;
pub const Credential = auth.Credential;
pub const Effort = models.Effort;
pub const ToolCall = types.ToolCall;
pub const ToolResult = types.ToolResult;
pub const Usage = types.Usage;
pub const Assistant = types.Assistant;
pub const Entry = types.Entry;
pub const ToolDefinition = tool_runtime.Definition;
pub const Header = transport_runtime.Header;
pub const Response = transport_runtime.Response;
pub const Cancellation = cancel_mod.Token;
pub const StreamLineFn = transport_runtime.StreamFn;

pub const Request = struct {
    provider: Provider,
    url: []const u8,
    content_type: []const u8,
    headers: []const Header,
    body: []const u8,
    cancellation: *Cancellation,
};

/// HTTP adapter. The callback must allocate `Response.body` with `gpa`; xaq
/// frees it after the call. SSE body lines must be delivered in order through
/// `on_line`, and no callback may outlive `post_stream`. The default adapter
/// launches curl without process-global state.
pub const Transport = struct {
    context: ?*anyopaque = null,
    post_stream: *const fn (
        context: ?*anyopaque,
        gpa: std.mem.Allocator,
        io: Io,
        request: Request,
        line_context: ?*anyopaque,
        on_line: StreamLineFn,
    ) anyerror!Response = curlPostStream,
};

/// Dynamic credential source. Return stable strings or allocate them with the
/// supplied arena so they remain valid through the provider request.
/// `force_refresh` is true for the single retry after an HTTP 401.
pub const CredentialSource = struct {
    context: ?*anyopaque = null,
    load: *const fn (
        context: ?*anyopaque,
        arena: std.mem.Allocator,
        io: Io,
        provider: Provider,
        force_refresh: bool,
    ) anyerror!Credential,
};

/// Custom tool adapter. Allocate the returned result with `gpa`. `call` and
/// `arguments` are borrowed for the callback only.
pub const ToolHost = struct {
    context: ?*anyopaque = null,
    execute: *const fn (
        context: ?*anyopaque,
        gpa: std.mem.Allocator,
        io: Io,
        call: ToolCall,
        arguments: std.json.Value,
        cancellation: *Cancellation,
    ) anyerror![]u8,
};

pub const PermissionHost = struct {
    context: ?*anyopaque = null,
    authorize: *const fn (
        context: ?*anyopaque,
        call: ToolCall,
        arguments: std.json.Value,
        builtin: bool,
    ) anyerror!bool,
};

pub const RequestStart = struct {
    round: usize,
    attempt: usize,
};

pub const ToolFinished = struct {
    call: ToolCall,
    result: []const u8,
};

/// Event payloads borrow memory. Copy a payload inside the callback if the
/// host needs it after the callback returns.
pub const Event = union(enum) {
    request_start: RequestStart,
    text_delta: []const u8,
    tool_start: ToolCall,
    tool_denied: ToolCall,
    tool_skipped: ToolCall,
    tool_finish: ToolFinished,
    usage: Usage,
    completed: Turn,
    cancelled,
};

pub const EventSink = struct {
    context: ?*anyopaque = null,
    emit: *const fn (context: ?*anyopaque, event: Event) anyerror!void,
};

pub const Options = struct {
    io: Io,
    provider: Provider = .chatgpt,
    model: ?[]const u8 = null,
    effort: ?Effort = null,
    fast: bool = false,
    cwd: []const u8,
    instructions: []const u8 = "",

    /// Use either a fixed credential or a source. A source takes precedence
    /// and supports refresh after a 401. Callback context pointers in these
    /// options must outlive the agent.
    credential: ?Credential = null,
    credential_source: ?CredentialSource = null,
    transport: Transport = .{},

    /// Built-ins are off by default because they run with the host process's
    /// filesystem and shell permissions. Custom definitions require a host.
    local_tools: bool = false,
    write_enabled: bool = true,
    tools: []const ToolDefinition = &.{},
    tool_host: ?ToolHost = null,
    permissions: ?PermissionHost = null,
    events: ?EventSink = null,
    initial_history: []const Entry = &.{},
    /// Provider rounds per prompt. Tool calls requested on the final allowed
    /// round are recorded as skipped and are not executed.
    max_tool_rounds: usize = 64,
};

pub const PromptOptions = struct {
    /// Raw assistant text deltas. No ANSI or Markdown presentation is added.
    /// The writer must remain valid until `prompt` returns.
    output: ?*Io.Writer = null,
};

pub const Turn = struct {
    text: []const u8,
    usage: Usage,
    tool_calls: usize,
    rounds: usize,
    stop_reason: StopReason,
};

pub const StopReason = enum { completed, tool_round_limit };

const OwnedCredential = struct {
    value: Credential,

    fn clone(gpa: std.mem.Allocator, value: Credential) !OwnedCredential {
        const access = try gpa.dupe(u8, value.access);
        errdefer gpa.free(access);
        const refresh = try gpa.dupe(u8, value.refresh);
        errdefer gpa.free(refresh);
        const account_id = if (value.account_id) |id| try gpa.dupe(u8, id) else null;
        errdefer if (account_id) |id| gpa.free(id);
        return .{ .value = .{
            .access = access,
            .refresh = refresh,
            .expires = value.expires,
            .account_id = account_id,
        } };
    }

    fn deinit(self: *OwnedCredential, gpa: std.mem.Allocator) void {
        gpa.free(self.value.access);
        gpa.free(self.value.refresh);
        if (self.value.account_id) |id| gpa.free(id);
    }
};

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: Io,
    provider: Provider,
    model: []u8,
    effort: ?Effort,
    fast: bool,
    cwd: []u8,
    instructions: []u8,
    credential: ?OwnedCredential,
    credential_source: ?CredentialSource,
    transport: Transport,
    local_tools: bool,
    write_enabled: bool,
    tool_definitions: []ToolDefinition,
    tool_host: ?ToolHost,
    permissions: ?PermissionHost,
    events: ?EventSink,
    max_tool_rounds: usize,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    usage_total: Usage = .{},
    cancellation: Cancellation = .{},
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_http_status: ?u16 = null,
    last_error_body: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, options: Options) !Agent {
        if (options.credential == null and options.credential_source == null) return error.CredentialRequired;
        if (options.tools.len > 0 and options.tool_host == null) return error.ToolHostRequired;
        if (options.max_tool_rounds == 0) return error.InvalidToolRoundLimit;
        const model = options.model orelse models.defaultModel(options.provider);
        if (options.effort) |effort| if (!models.supportsEffort(options.provider, model, effort)) return error.InvalidEffortForModel;
        if (options.fast and !models.supportsFast(options.provider, model)) return error.InvalidFastForModel;
        try validateToolDefinitions(gpa, options.tools, options.local_tools);

        var result: Agent = .{
            .gpa = gpa,
            .io = options.io,
            .provider = options.provider,
            .model = try gpa.dupe(u8, model),
            .effort = options.effort,
            .fast = options.fast,
            .cwd = undefined,
            .instructions = undefined,
            .credential = null,
            .credential_source = options.credential_source,
            .transport = options.transport,
            .local_tools = options.local_tools,
            .write_enabled = options.write_enabled,
            .tool_definitions = &.{},
            .tool_host = options.tool_host,
            .permissions = options.permissions,
            .events = options.events,
            .max_tool_rounds = options.max_tool_rounds,
            .arena = .init(gpa),
        };
        errdefer result.arena.deinit();
        errdefer gpa.free(result.model);
        result.cwd = try gpa.dupe(u8, options.cwd);
        errdefer gpa.free(result.cwd);
        result.instructions = try gpa.dupe(u8, options.instructions);
        errdefer gpa.free(result.instructions);
        if (options.credential) |credential| result.credential = try OwnedCredential.clone(gpa, credential);
        errdefer if (result.credential) |*credential| credential.deinit(gpa);
        result.tool_definitions = try cloneToolDefinitions(gpa, options.tools);
        errdefer freeToolDefinitions(gpa, result.tool_definitions);
        for (options.initial_history) |entry| {
            try result.entries.append(result.arena.allocator(), try cloneEntry(result.arena.allocator(), entry));
            if (entry == .assistant) addUsage(&result.usage_total, entry.assistant.usage);
        }
        return result;
    }

    pub fn deinit(self: *Agent) void {
        std.debug.assert(!self.active.load(.acquire));
        self.cancellation.request();
        self.entries.deinit(self.arena.allocator());
        self.arena.deinit();
        freeToolDefinitions(self.gpa, self.tool_definitions);
        if (self.credential) |*credential| credential.deinit(self.gpa);
        if (self.last_error_body) |body| self.gpa.free(body);
        self.gpa.free(self.instructions);
        self.gpa.free(self.cwd);
        self.gpa.free(self.model);
        self.* = undefined;
    }

    pub fn cancel(self: *Agent) void {
        self.cancellation.request();
    }

    pub fn reset(self: *Agent) void {
        std.debug.assert(!self.active.load(.acquire));
        self.entries.deinit(self.arena.allocator());
        self.arena.deinit();
        self.arena = .init(self.gpa);
        self.entries = .empty;
        self.usage_total = .{};
        self.last_http_status = null;
        if (self.last_error_body) |body| self.gpa.free(body);
        self.last_error_body = null;
        self.cancellation.reset();
    }

    /// The returned slice is invalidated by the next prompt. Nested strings
    /// and arrays remain valid until reset or deinit.
    pub fn history(self: *const Agent) []const Entry {
        return self.entries.items;
    }

    pub fn usage(self: *const Agent) Usage {
        return self.usage_total;
    }

    /// Borrowed until the next prompt, reset, or deinit.
    pub fn lastProviderError(self: *const Agent) ?[]const u8 {
        return self.last_error_body;
    }

    pub fn setModel(self: *Agent, model: []const u8) !void {
        if (self.active.load(.acquire)) return error.PromptActive;
        if (self.effort) |effort| if (!models.supportsEffort(self.provider, model, effort)) return error.InvalidEffortForModel;
        if (self.fast and !models.supportsFast(self.provider, model)) return error.InvalidFastForModel;
        const replacement = try self.gpa.dupe(u8, model);
        self.gpa.free(self.model);
        self.model = replacement;
    }

    pub fn setEffort(self: *Agent, effort: ?Effort) !void {
        if (self.active.load(.acquire)) return error.PromptActive;
        if (effort) |value| if (!models.supportsEffort(self.provider, self.model, value)) return error.InvalidEffortForModel;
        self.effort = effort;
    }

    pub fn setFast(self: *Agent, fast: bool) !void {
        if (self.active.load(.acquire)) return error.PromptActive;
        if (fast and !models.supportsFast(self.provider, self.model)) return error.InvalidFastForModel;
        self.fast = fast;
    }

    pub fn prompt(self: *Agent, text: []const u8, options: PromptOptions) !Turn {
        if (self.active.swap(true, .acq_rel)) return error.PromptActive;
        defer self.active.store(false, .release);
        self.cancellation.reset();
        self.last_http_status = null;
        if (self.last_error_body) |body| self.gpa.free(body);
        self.last_error_body = null;
        const history_checkpoint = self.entries.items.len;
        const usage_checkpoint = self.usage_total;
        errdefer self.entries.items.len = history_checkpoint;
        errdefer self.usage_total = usage_checkpoint;
        try self.entries.append(self.arena.allocator(), .{ .user = try self.arena.allocator().dupe(u8, text) });

        var discard_buffer: [1024]u8 = undefined;
        var discard: Io.Writer.Discarding = .init(&discard_buffer);
        const output = options.output orelse &discard.writer;
        var turn_usage: Usage = .{};
        var tool_calls: usize = 0;

        var round: usize = 1;
        while (round <= self.max_tool_rounds) : (round += 1) {
            if (self.cancellation.isRequested()) return self.cancelled();
            const answer = self.performRound(round, output) catch |err| {
                if (err == error.Cancelled) return self.cancelled();
                return err;
            };
            addUsage(&turn_usage, answer.usage);
            addUsage(&self.usage_total, answer.usage);
            try self.emit(.{ .usage = answer.usage });
            try self.entries.append(self.arena.allocator(), .{ .assistant = answer });

            if (answer.calls.len == 0) {
                const turn: Turn = .{
                    .text = answer.text,
                    .usage = turn_usage,
                    .tool_calls = tool_calls,
                    .rounds = round,
                    .stop_reason = .completed,
                };
                try self.emit(.{ .completed = turn });
                return turn;
            }

            tool_calls += answer.calls.len;
            const results = try self.arena.allocator().alloc(ToolResult, answer.calls.len);
            if (round == self.max_tool_rounds) {
                for (answer.calls, 0..) |call, index| {
                    try self.emit(.{ .tool_skipped = call });
                    results[index] = .{
                        .id = call.id,
                        .text = "not executed: tool round limit reached",
                    };
                }
                try self.entries.append(self.arena.allocator(), .{ .results = results });
                const turn: Turn = .{
                    .text = answer.text,
                    .usage = turn_usage,
                    .tool_calls = tool_calls,
                    .rounds = round,
                    .stop_reason = .tool_round_limit,
                };
                try self.emit(.{ .completed = turn });
                return turn;
            }
            for (answer.calls, 0..) |call, index| {
                if (self.cancellation.isRequested()) return self.cancelled();
                try self.emit(.{ .tool_start = call });
                results[index] = .{
                    .id = call.id,
                    .text = try self.executeTool(call),
                };
                try self.emit(.{ .tool_finish = .{ .call = call, .result = results[index].text } });
            }
            try self.entries.append(self.arena.allocator(), .{ .results = results });
        }
        unreachable;
    }

    fn cancelled(self: *Agent) anyerror {
        self.emit(.cancelled) catch {};
        return error.Cancelled;
    }

    fn emit(self: *Agent, event: Event) !void {
        if (self.events) |sink| try sink.emit(sink.context, event);
    }

    fn performRound(self: *Agent, round: usize, output: *Io.Writer) !Assistant {
        var request_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer request_arena.deinit();
        const body = try request_builder.build(
            request_arena.allocator(),
            self.provider,
            self.model,
            self.effort,
            self.fast,
            .{
                .include_builtin = self.local_tools,
                .write_enabled = self.write_enabled,
                .custom = self.tool_definitions,
            },
            self.cwd,
            self.instructions,
            self.entries.items,
        );

        var attempt: usize = 1;
        var force_refresh = false;
        while (attempt <= 2) : (attempt += 1) {
            try self.emit(.{ .request_start = .{ .round = round, .attempt = attempt } });
            const credential = try self.loadCredential(request_arena.allocator(), force_refresh);
            var delta_sink: DeltaSink = .{ .agent = self, .output = output };
            var decoder = stream.Decoder.init(
                self.provider,
                self.gpa,
                self.arena.allocator(),
                .{ .context = &delta_sink, .on_delta = emitDelta },
            );
            const response = try self.send(request_arena.allocator(), credential, body, &decoder);
            defer request_arena.allocator().free(response.body);
            if (self.cancellation.isRequested()) return error.Cancelled;
            self.last_http_status = response.status;
            if (response.status >= 200 and response.status < 300) return decoder.finish();
            if (response.status == 401 and !force_refresh and self.credential_source != null) {
                force_refresh = true;
                continue;
            }
            self.last_error_body = try self.gpa.dupe(u8, response.body[0..@min(response.body.len, 128 * 1024)]);
            return error.ProviderRequestFailed;
        }
        return error.ProviderRequestFailed;
    }

    fn loadCredential(self: *Agent, arena: std.mem.Allocator, force_refresh: bool) !Credential {
        if (self.credential_source) |source| return source.load(source.context, arena, self.io, self.provider, force_refresh);
        return self.credential.?.value;
    }

    fn send(self: *Agent, arena: std.mem.Allocator, credential: Credential, body: []const u8, decoder: *stream.Decoder) !Response {
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{credential.access});
        const common = self.transport;
        return switch (self.provider) {
            .chatgpt => common.post_stream(common.context, arena, self.io, .{
                .provider = self.provider,
                .url = "https://chatgpt.com/backend-api/codex/responses",
                .content_type = "application/json",
                .headers = &.{
                    .{ .name = "Authorization", .value = authorization },
                    .{ .name = "chatgpt-account-id", .value = credential.account_id orelse return error.InvalidAccessToken },
                    .{ .name = "originator", .value = "xaq" },
                    .{ .name = "Accept", .value = "text/event-stream" },
                    .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
                    .{ .name = "User-Agent", .value = "xaq/0.1" },
                },
                .body = body,
                .cancellation = &self.cancellation,
            }, decoder, decodeLine),
            .claude => common.post_stream(common.context, arena, self.io, .{
                .provider = self.provider,
                .url = "https://api.anthropic.com/v1/messages",
                .content_type = "application/json",
                .headers = &.{
                    .{ .name = "Authorization", .value = authorization },
                    .{ .name = "anthropic-version", .value = "2023-06-01" },
                    .{ .name = "anthropic-beta", .value = if (self.fast) "claude-code-20250219,oauth-2025-04-20,fast-mode-2026-02-01" else "claude-code-20250219,oauth-2025-04-20" },
                    .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" },
                    .{ .name = "User-Agent", .value = "claude-cli/2.1.75" },
                    .{ .name = "x-app", .value = "cli" },
                },
                .body = body,
                .cancellation = &self.cancellation,
            }, decoder, decodeLine),
            .grok => common.post_stream(common.context, arena, self.io, .{
                .provider = self.provider,
                .url = "https://api.x.ai/v1/responses",
                .content_type = "application/json",
                .headers = &.{
                    .{ .name = "Authorization", .value = authorization },
                    .{ .name = "Accept", .value = "text/event-stream" },
                    .{ .name = "User-Agent", .value = "xaq/0.1" },
                },
                .body = body,
                .cancellation = &self.cancellation,
            }, decoder, decodeLine),
        };
    }

    fn executeTool(self: *Agent, call: ToolCall) ![]const u8 {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const allocator = scratch.allocator();
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{}) catch |err|
            return self.arena.allocator().dupe(u8, try std.fmt.allocPrint(allocator, "invalid tool arguments: {s}", .{@errorName(err)}));
        defer parsed.deinit();

        const custom = isCustomTool(self.tool_definitions, call.name);
        if (self.permissions) |permissions| {
            if (!try permissions.authorize(permissions.context, call, parsed.value, self.local_tools and isBuiltinTool(call.name))) {
                try self.emit(.{ .tool_denied = call });
                return self.arena.allocator().dupe(u8, "tool denied by host");
            }
        }

        const result = if (custom) blk: {
            const host = self.tool_host orelse return error.ToolHostRequired;
            break :blk host.execute(host.context, allocator, self.io, call, parsed.value, &self.cancellation) catch |err|
                try std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)});
        } else if (self.local_tools)
            tool_runtime.executeWithContext(allocator, self.io, call.name, parsed.value, .{
                .cwd = self.cwd,
                .write_enabled = self.write_enabled,
                .cancellation = &self.cancellation,
            }) catch |err| try std.fmt.allocPrint(allocator, "tool error: {s}", .{@errorName(err)})
        else
            try std.fmt.allocPrint(allocator, "unknown tool: {s}", .{call.name});
        if (result.len <= tool_runtime.max_output) return self.arena.allocator().dupe(u8, result);
        const suffix = "\n[host tool result truncated]";
        const keep = tool_runtime.max_output - suffix.len;
        var bounded: Io.Writer.Allocating = .init(self.arena.allocator());
        try bounded.writer.writeAll(result[0..keep]);
        try bounded.writer.writeAll(suffix);
        return bounded.toOwnedSlice();
    }
};

fn curlPostStream(
    _: ?*anyopaque,
    gpa: std.mem.Allocator,
    io: Io,
    request: Request,
    line_context: ?*anyopaque,
    on_line: StreamLineFn,
) !Response {
    return transport_runtime.postStreamWithToken(
        gpa,
        io,
        request.url,
        request.content_type,
        request.headers,
        request.body,
        line_context,
        on_line,
        request.cancellation,
    );
}

fn decodeLine(context: ?*anyopaque, line: []const u8) !void {
    const decoder: *stream.Decoder = @ptrCast(@alignCast(context.?));
    try decoder.feed(line);
}

const DeltaSink = struct {
    agent: *Agent,
    output: *Io.Writer,
};

fn emitDelta(context: ?*anyopaque, delta: []const u8) !void {
    const sink: *DeltaSink = @ptrCast(@alignCast(context.?));
    try sink.agent.emit(.{ .text_delta = delta });
    try sink.output.writeAll(delta);
    try sink.output.flush();
}

fn addUsage(total: *Usage, value: Usage) void {
    total.input += value.input;
    total.cached += value.cached;
    total.output += value.output;
}

fn isCustomTool(definitions: []const ToolDefinition, name: []const u8) bool {
    for (definitions) |definition| if (std.mem.eql(u8, definition.name, name)) return true;
    return false;
}

fn isBuiltinTool(name: []const u8) bool {
    for (tool_runtime.names) |builtin| if (std.mem.eql(u8, builtin, name)) return true;
    return false;
}

fn validateToolDefinitions(gpa: std.mem.Allocator, definitions: []const ToolDefinition, local_tools: bool) !void {
    for (definitions, 0..) |definition, index| {
        if (definition.name.len == 0 or definition.name.len > 64) return error.InvalidToolName;
        for (definition.name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidToolName;
        if (local_tools) for (tool_runtime.names) |name| if (std.mem.eql(u8, definition.name, name)) return error.DuplicateToolName;
        for (definitions[0..index]) |previous| if (std.mem.eql(u8, definition.name, previous.name)) return error.DuplicateToolName;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, definition.parameters_json, .{}) catch return error.InvalidToolSchema;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidToolSchema;
    }
}

fn cloneToolDefinitions(gpa: std.mem.Allocator, source: []const ToolDefinition) ![]ToolDefinition {
    const result = try gpa.alloc(ToolDefinition, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |definition| freeToolDefinition(gpa, definition);
        gpa.free(result);
    }
    for (source, 0..) |definition, index| {
        result[index] = try cloneToolDefinition(gpa, definition);
        initialized += 1;
    }
    return result;
}

fn cloneToolDefinition(gpa: std.mem.Allocator, definition: ToolDefinition) !ToolDefinition {
    const name = try gpa.dupe(u8, definition.name);
    errdefer gpa.free(name);
    const description = try gpa.dupe(u8, definition.description);
    errdefer gpa.free(description);
    return .{
        .name = name,
        .description = description,
        .parameters_json = try gpa.dupe(u8, definition.parameters_json),
    };
}

fn freeToolDefinitions(gpa: std.mem.Allocator, definitions: []ToolDefinition) void {
    for (definitions) |definition| freeToolDefinition(gpa, definition);
    gpa.free(definitions);
}

fn freeToolDefinition(gpa: std.mem.Allocator, definition: ToolDefinition) void {
    gpa.free(definition.name);
    gpa.free(definition.description);
    gpa.free(definition.parameters_json);
}

fn cloneEntry(gpa: std.mem.Allocator, entry: Entry) !Entry {
    return switch (entry) {
        .user => |text| .{ .user = try gpa.dupe(u8, text) },
        .assistant => |answer| blk: {
            const calls = try gpa.alloc(ToolCall, answer.calls.len);
            for (answer.calls, 0..) |call, index| calls[index] = .{
                .id = try gpa.dupe(u8, call.id),
                .name = try gpa.dupe(u8, call.name),
                .arguments = try gpa.dupe(u8, call.arguments),
            };
            const raw_items = try gpa.alloc([]const u8, answer.raw_items.len);
            for (answer.raw_items, 0..) |item, index| raw_items[index] = try gpa.dupe(u8, item);
            break :blk .{ .assistant = .{
                .text = try gpa.dupe(u8, answer.text),
                .calls = calls,
                .raw_items = raw_items,
                .usage = answer.usage,
            } };
        },
        .results => |old| blk: {
            const results = try gpa.alloc(ToolResult, old.len);
            for (old, 0..) |result, index| results[index] = .{
                .id = try gpa.dupe(u8, result.id),
                .text = try gpa.dupe(u8, result.text),
            };
            break :blk .{ .results = results };
        },
    };
}

test "embedded agent streams, runs a host tool, and keeps history" {
    const Fake = struct {
        calls: usize = 0,

        fn post(raw: ?*anyopaque, gpa: std.mem.Allocator, _: Io, request: Request, line_context: ?*anyopaque, on_line: StreamLineFn) !Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expect(std.mem.indexOf(u8, request.body, "lookup") != null);
            if (self.calls == 0) {
                try on_line(line_context, "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"lookup\",\"arguments\":\"{\\\"key\\\":\\\"answer\\\"}\"}}");
                try on_line(line_context, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}}");
            } else {
                try std.testing.expect(std.mem.indexOf(u8, request.body, "forty-two") != null);
                try on_line(line_context, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"42\"}");
                try on_line(line_context, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":6,\"output_tokens\":1}}}");
            }
            self.calls += 1;
            return .{ .status = 200, .body = try gpa.dupe(u8, "") };
        }

        fn tool(_: ?*anyopaque, gpa: std.mem.Allocator, _: Io, call: ToolCall, arguments: std.json.Value, _: *Cancellation) ![]u8 {
            try std.testing.expectEqualStrings("lookup", call.name);
            try std.testing.expectEqualStrings("answer", arguments.object.get("key").?.string);
            return gpa.dupe(u8, "forty-two");
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    var embedded = try Agent.init(std.testing.allocator, .{
        .io = threaded.io(),
        .cwd = "/workspace",
        .credential = .{ .access = "token", .refresh = "", .expires = 0, .account_id = "account" },
        .transport = .{ .context = &fake, .post_stream = Fake.post },
        .tools = &.{.{
            .name = "lookup",
            .description = "Look up a value.",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"}},\"required\":[\"key\"],\"additionalProperties\":false}",
        }},
        .tool_host = .{ .execute = Fake.tool },
    });
    defer embedded.deinit();

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const turn = try embedded.prompt("find it", .{ .output = &output.writer });
    try std.testing.expectEqualStrings("42", turn.text);
    try std.testing.expectEqualStrings("42", output.written());
    try std.testing.expectEqual(@as(usize, 1), turn.tool_calls);
    try std.testing.expectEqual(@as(usize, 4), embedded.history().len);
    try std.testing.expectEqual(@as(u64, 10), turn.usage.input);
}

test "embedded agent instances cancel independently" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var first = try Agent.init(std.testing.allocator, .{
        .io = threaded.io(),
        .cwd = "/a",
        .credential = .{ .access = "a", .refresh = "", .expires = 0, .account_id = "a" },
    });
    defer first.deinit();
    var second = try Agent.init(std.testing.allocator, .{
        .io = threaded.io(),
        .cwd = "/b",
        .credential = .{ .access = "b", .refresh = "", .expires = 0, .account_id = "b" },
    });
    defer second.deinit();
    first.cancel();
    try std.testing.expect(first.cancellation.isRequested());
    try std.testing.expect(!second.cancellation.isRequested());
}

test "permission hosts can deny a tool without ending the turn" {
    const Fake = struct {
        requests: usize = 0,
        executions: usize = 0,
        denials: usize = 0,

        fn post(raw: ?*anyopaque, gpa: std.mem.Allocator, _: Io, request: Request, line_context: ?*anyopaque, on_line: StreamLineFn) !Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.requests == 0) {
                try on_line(line_context, "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"danger\",\"arguments\":\"{}\"}}");
            } else {
                try std.testing.expect(std.mem.indexOf(u8, request.body, "tool denied by host") != null);
                try on_line(line_context, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"continued\"}");
            }
            try on_line(line_context, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{}}}");
            self.requests += 1;
            return .{ .status = 200, .body = try gpa.dupe(u8, "") };
        }

        fn tool(raw: ?*anyopaque, gpa: std.mem.Allocator, _: Io, _: ToolCall, _: std.json.Value, _: *Cancellation) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.executions += 1;
            return gpa.dupe(u8, "ran");
        }

        fn authorize(_: ?*anyopaque, _: ToolCall, _: std.json.Value, builtin: bool) !bool {
            try std.testing.expect(!builtin);
            return false;
        }

        fn event(raw: ?*anyopaque, value: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (value == .tool_denied) self.denials += 1;
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    var embedded = try Agent.init(std.testing.allocator, .{
        .io = threaded.io(),
        .cwd = "/workspace",
        .credential = .{ .access = "token", .refresh = "", .expires = 0, .account_id = "account" },
        .transport = .{ .context = &fake, .post_stream = Fake.post },
        .tools = &.{.{ .name = "danger", .description = "A denied tool.", .parameters_json = "{\"type\":\"object\"}" }},
        .tool_host = .{ .context = &fake, .execute = Fake.tool },
        .permissions = .{ .authorize = Fake.authorize },
        .events = .{ .context = &fake, .emit = Fake.event },
    });
    defer embedded.deinit();
    const turn = try embedded.prompt("continue after denial", .{});
    try std.testing.expectEqualStrings("continued", turn.text);
    try std.testing.expectEqual(@as(usize, 0), fake.executions);
    try std.testing.expectEqual(@as(usize, 1), fake.denials);
}

test "tool round limits skip the next side effect and keep valid history" {
    const Fake = struct {
        executions: usize = 0,

        fn post(_: ?*anyopaque, gpa: std.mem.Allocator, _: Io, _: Request, line_context: ?*anyopaque, on_line: StreamLineFn) !Response {
            try on_line(line_context, "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"change\",\"arguments\":\"{}\"}}");
            try on_line(line_context, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{}}}");
            return .{ .status = 200, .body = try gpa.dupe(u8, "") };
        }

        fn tool(raw: ?*anyopaque, gpa: std.mem.Allocator, _: Io, _: ToolCall, _: std.json.Value, _: *Cancellation) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.executions += 1;
            return gpa.dupe(u8, "changed");
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    var embedded = try Agent.init(std.testing.allocator, .{
        .io = threaded.io(),
        .cwd = "/workspace",
        .credential = .{ .access = "token", .refresh = "", .expires = 0, .account_id = "account" },
        .transport = .{ .post_stream = Fake.post },
        .tools = &.{.{ .name = "change", .description = "Change state.", .parameters_json = "{\"type\":\"object\"}" }},
        .tool_host = .{ .context = &fake, .execute = Fake.tool },
        .max_tool_rounds = 1,
    });
    defer embedded.deinit();
    const turn = try embedded.prompt("change it", .{});
    try std.testing.expectEqual(StopReason.tool_round_limit, turn.stop_reason);
    try std.testing.expectEqual(@as(usize, 0), fake.executions);
    try std.testing.expectEqual(@as(usize, 3), embedded.history().len);
    try std.testing.expectEqualStrings("not executed: tool round limit reached", embedded.history()[2].results[0].text);
}

test "credential sources receive one forced refresh after 401" {
    const Fake = struct {
        loads: usize = 0,
        refresh_seen: bool = false,
        requests: usize = 0,

        fn load(raw: ?*anyopaque, _: std.mem.Allocator, _: Io, _: Provider, force_refresh: bool) !Credential {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.loads += 1;
            self.refresh_seen = self.refresh_seen or force_refresh;
            return .{ .access = if (force_refresh) "fresh" else "stale", .refresh = "", .expires = 0, .account_id = "account" };
        }

        fn post(raw: ?*anyopaque, gpa: std.mem.Allocator, _: Io, request: Request, line_context: ?*anyopaque, on_line: StreamLineFn) !Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.requests += 1;
            if (self.requests == 1) {
                try std.testing.expectEqualStrings("Bearer stale", request.headers[0].value);
                return .{ .status = 401, .body = try gpa.dupe(u8, "expired") };
            }
            try std.testing.expectEqualStrings("Bearer fresh", request.headers[0].value);
            try on_line(line_context, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ready\"}");
            try on_line(line_context, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}");
            return .{ .status = 200, .body = try gpa.dupe(u8, "") };
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    var embedded = try Agent.init(std.testing.allocator, .{
        .io = threaded.io(),
        .cwd = "/workspace",
        .credential_source = .{ .context = &fake, .load = Fake.load },
        .transport = .{ .context = &fake, .post_stream = Fake.post },
    });
    defer embedded.deinit();
    const turn = try embedded.prompt("go", .{});
    try std.testing.expectEqualStrings("ready", turn.text);
    try std.testing.expectEqual(@as(usize, 2), fake.loads);
    try std.testing.expect(fake.refresh_seen);
    try std.testing.expectEqual(@as(?u16, 200), embedded.last_http_status);
    try std.testing.expectEqual(@as(?[]const u8, null), embedded.lastProviderError());
}

test "provider failures preserve diagnostics and roll back the turn" {
    const Fake = struct {
        fn post(_: ?*anyopaque, gpa: std.mem.Allocator, _: Io, _: Request, _: ?*anyopaque, _: StreamLineFn) !Response {
            return .{ .status = 403, .body = try gpa.dupe(u8, "denied by host") };
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var embedded = try Agent.init(std.testing.allocator, .{
        .io = threaded.io(),
        .cwd = "/workspace",
        .credential = .{ .access = "token", .refresh = "", .expires = 0, .account_id = "account" },
        .transport = .{ .post_stream = Fake.post },
    });
    defer embedded.deinit();
    try std.testing.expectError(error.ProviderRequestFailed, embedded.prompt("do not retain me", .{}));
    try std.testing.expectEqual(@as(usize, 0), embedded.history().len);
    try std.testing.expectEqualStrings("denied by host", embedded.lastProviderError().?);
    try std.testing.expectEqual(@as(?u16, 403), embedded.last_http_status);
}

test "transport cancellation emits an event and rolls back the turn" {
    const Fake = struct {
        cancelled_events: usize = 0,

        fn post(_: ?*anyopaque, _: std.mem.Allocator, _: Io, request: Request, _: ?*anyopaque, _: StreamLineFn) !Response {
            request.cancellation.request();
            return error.Cancelled;
        }

        fn event(raw: ?*anyopaque, value: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (value == .cancelled) self.cancelled_events += 1;
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var fake: Fake = .{};
    var embedded = try Agent.init(std.testing.allocator, .{
        .io = threaded.io(),
        .cwd = "/workspace",
        .credential = .{ .access = "token", .refresh = "", .expires = 0, .account_id = "account" },
        .transport = .{ .post_stream = Fake.post },
        .events = .{ .context = &fake, .emit = Fake.event },
    });
    defer embedded.deinit();
    try std.testing.expectError(error.Cancelled, embedded.prompt("stop", .{}));
    try std.testing.expectEqual(@as(usize, 1), fake.cancelled_events);
    try std.testing.expectEqual(@as(usize, 0), embedded.history().len);
}
