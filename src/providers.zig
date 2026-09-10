//! User-configured LLM endpoints. Settings hold the definitions; this
//! module resolves a provider reference into the URL, headers, credential,
//! and capability catalog the agent needs, and hosts the interactive and
//! command-line configuration flows that write those definitions safely.

const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const builtin_models = @import("models.zig");
const input_mod = @import("input.zig");
const settings = @import("settings.zig");
const term = @import("term.zig");
const transport = @import("transport.zig");

pub const Custom = settings.CustomProvider;
pub const Effort = builtin_models.Effort;

/// Identity of a provider at runtime: a built-in subscription, or the
/// custom tag plus the settings name. `custom` is borrowed.
pub const Ref = struct {
    provider: auth.Provider,
    custom: ?[]const u8 = null,

    pub fn builtin(provider: auth.Provider) Ref {
        std.debug.assert(provider != .custom);
        return .{ .provider = provider };
    }

    /// Built-in tags first, then any well-formed settings name. The name
    /// is not checked against settings here; callers resolve it.
    pub fn parse(value: []const u8) ?Ref {
        if (auth.Provider.parse(value)) |provider| return builtin(provider);
        if (settings.validProviderName(value)) return .{ .provider = .custom, .custom = value };
        return null;
    }

    pub fn name(self: Ref) []const u8 {
        return if (self.provider == .custom) self.custom orelse "custom" else @tagName(self.provider);
    }

    pub fn label(self: Ref) []const u8 {
        return if (self.provider == .custom) self.name() else self.provider.label();
    }

    pub fn eql(a: Ref, b: Ref) bool {
        if (a.provider != b.provider) return false;
        if (a.provider != .custom) return true;
        return std.mem.eql(u8, a.name(), b.name());
    }
};

/// What request.zig needs to shape a request body.
pub const Target = struct {
    provider: auth.Provider,
    api: auth.Api,
    name: []const u8,

    pub fn builtin(provider: auth.Provider) Target {
        return .{ .provider = provider, .api = provider.api().?, .name = @tagName(provider) };
    }
};

/// Capability lookups shared by built-in and custom providers. A custom
/// reference whose settings entry is missing resolves to conservative
/// defaults so the session stays usable until the user switches models.
pub const Catalog = struct {
    ref: Ref,
    definition: ?*const Custom = null,

    pub fn builtin(provider: auth.Provider) Catalog {
        return .{ .ref = Ref.builtin(provider) };
    }

    pub fn resolve(ref: Ref, config: *const settings.Config) Catalog {
        if (ref.provider != .custom) return .{ .ref = ref };
        return .{ .ref = ref, .definition = config.customProvider(ref.name()) };
    }

    pub fn configured(self: Catalog) bool {
        return self.ref.provider != .custom or self.definition != null;
    }

    pub fn name(self: Catalog) []const u8 {
        return self.ref.name();
    }

    pub fn label(self: Catalog) []const u8 {
        return self.ref.label();
    }

    pub fn api(self: Catalog) auth.Api {
        if (self.ref.provider.api()) |value| return value;
        return if (self.definition) |definition| definition.api else .chat_completions;
    }

    pub fn target(self: Catalog) Target {
        return .{ .provider = self.ref.provider, .api = self.api(), .name = self.name() };
    }

    pub fn defaultModel(self: Catalog) []const u8 {
        if (self.ref.provider != .custom) return builtin_models.defaultModel(self.ref.provider);
        return if (self.definition) |definition| definition.defaultModel() else "";
    }

    pub fn choices(self: Catalog) []const []const u8 {
        if (self.ref.provider != .custom) return builtin_models.choices(self.ref.provider);
        return if (self.definition) |definition| definition.models else &.{};
    }

    /// True for catalog (built-in) or listed (custom) model IDs.
    pub fn lists(self: Catalog, id: []const u8) bool {
        if (self.ref.provider != .custom) return builtin_models.find(self.ref.provider, id) != null;
        return if (self.definition) |definition| definition.listsModel(id) else false;
    }

    pub fn contextWindow(self: Catalog, id: []const u8) u32 {
        if (self.ref.provider != .custom) return builtin_models.contextWindow(self.ref.provider, id);
        return if (self.definition) |definition| definition.context_tokens else settings.default_context_tokens;
    }

    pub fn efforts(self: Catalog, id: []const u8) []const Effort {
        if (self.ref.provider != .custom) return builtin_models.efforts(self.ref.provider, id);
        return if (self.definition) |definition| definition.efforts else &.{};
    }

    pub fn supportsEffort(self: Catalog, id: []const u8, effort: Effort) bool {
        if (self.ref.provider != .custom) return builtin_models.supportsEffort(self.ref.provider, id, effort);
        return if (self.definition) |definition| definition.supportsEffort(effort) else false;
    }

    /// Fast mode is a subscription tier; custom endpoints never expose it.
    pub fn supportsFast(self: Catalog, id: []const u8) bool {
        if (self.ref.provider != .custom) return builtin_models.supportsFast(self.ref.provider, id);
        return false;
    }
};

/// Process environment for `api_key_env` lookups. main installs the block
/// it received at startup; tests and embedders may leave it empty.
pub var environ: std.process.Environ = .empty;

pub fn envValue(name: []const u8) ?[]const u8 {
    if (@TypeOf(environ.block) != std.process.Environ.PosixBlock) return null;
    for (environ.block.view().slice) |entry_z| {
        const entry = std.mem.span(entry_z);
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) {
            return entry[name.len + 1 ..];
        }
    }
    return null;
}

pub const KeySource = enum { literal, environment, none };

pub fn keySource(definition: *const Custom) KeySource {
    if (definition.api_key != null) return .literal;
    if (definition.api_key_env != null) return .environment;
    return .none;
}

/// Resolve the API key. Null means the endpoint takes no key. A configured
/// environment variable that is unset or empty is an error the caller
/// reports by name so the user can export it.
pub fn apiKey(definition: *const Custom) error{MissingApiKeyEnv}!?[]const u8 {
    if (definition.api_key) |key| return key;
    if (definition.api_key_env) |name| {
        const value = envValue(name) orelse return error.MissingApiKeyEnv;
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return error.MissingApiKeyEnv;
        return trimmed;
    }
    return null;
}

pub fn credential(definition: *const Custom) error{MissingApiKeyEnv}!auth.Credential {
    return .{
        .access = (try apiKey(definition)) orelse "",
        .refresh = "",
        .expires = std.math.maxInt(i64),
    };
}

pub fn url(gpa: std.mem.Allocator, definition: *const Custom) ![]u8 {
    const base = std.mem.trimEnd(u8, definition.base_url, "/");
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, definition.api.path() });
}

/// Request headers for a custom endpoint. Defaults come first; a user
/// header with the same name (case-insensitive) replaces the default, which
/// lets a proxy that wants its own Authorization scheme opt out of ours.
pub fn headers(arena: std.mem.Allocator, definition: *const Custom, key: []const u8) ![]transport.Header {
    var list: std.ArrayList(transport.Header) = .empty;
    try list.append(arena, .{ .name = "Accept", .value = "text/event-stream" });
    try list.append(arena, .{ .name = "User-Agent", .value = "xaq/0.1" });
    if (definition.api == .messages) try list.append(arena, .{ .name = "anthropic-version", .value = "2023-06-01" });
    if (key.len > 0) switch (definition.authStyle()) {
        .bearer => try list.append(arena, .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{key}) }),
        .@"x-api-key" => try list.append(arena, .{ .name = "x-api-key", .value = key }),
    };
    if (definition.headers) |extra| {
        var iterator = extra.map.iterator();
        while (iterator.next()) |entry| {
            var replaced = false;
            for (list.items) |*header| if (std.ascii.eqlIgnoreCase(header.name, entry.key_ptr.*)) {
                header.value = entry.value_ptr.*;
                replaced = true;
                break;
            };
            if (!replaced) try list.append(arena, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }
    }
    return list.toOwnedSlice(arena);
}

test "provider references parse built-in tags and well-formed custom names" {
    try std.testing.expectEqual(auth.Provider.claude, Ref.parse("claude").?.provider);
    try std.testing.expectEqual(null, Ref.parse("claude").?.custom);
    const custom = Ref.parse("ollama-local").?;
    try std.testing.expectEqual(auth.Provider.custom, custom.provider);
    try std.testing.expectEqualStrings("ollama-local", custom.name());
    try std.testing.expectEqualStrings("ollama-local", custom.label());
    try std.testing.expectEqual(null, Ref.parse("custom"));
    try std.testing.expectEqual(null, Ref.parse("Ollama"));
    try std.testing.expectEqual(null, Ref.parse("has space"));
    try std.testing.expectEqual(null, Ref.parse(""));
    try std.testing.expect(custom.eql(Ref.parse("ollama-local").?));
    try std.testing.expect(!custom.eql(Ref.parse("other").?));
    try std.testing.expect(!custom.eql(Ref.builtin(.grok)));
    try std.testing.expect(Ref.builtin(.grok).eql(Ref.builtin(.grok)));
}

test "custom catalogs use provider-wide limits and never offer fast mode" {
    const definition: Custom = .{
        .api = .chat_completions,
        .base_url = "http://localhost:11434/v1",
        .models = &.{ "qwen3-coder", "llama4" },
        .context_tokens = 64_000,
        .efforts = &.{ .low, .high },
    };
    var config: settings.Config = .{ .providers = .{} };
    try config.providers.?.map.put(std.testing.allocator, "ollama", definition);
    defer config.providers.?.map.deinit(std.testing.allocator);
    const catalog = Catalog.resolve(Ref.parse("ollama").?, &config);
    try std.testing.expect(catalog.configured());
    try std.testing.expectEqual(auth.Api.chat_completions, catalog.api());
    try std.testing.expectEqualStrings("qwen3-coder", catalog.defaultModel());
    try std.testing.expectEqual(@as(usize, 2), catalog.choices().len);
    try std.testing.expect(catalog.lists("llama4"));
    try std.testing.expect(!catalog.lists("mystery"));
    try std.testing.expectEqual(@as(u32, 64_000), catalog.contextWindow("mystery"));
    try std.testing.expect(catalog.supportsEffort("mystery", .high));
    try std.testing.expect(!catalog.supportsEffort("mystery", .medium));
    try std.testing.expect(!catalog.supportsFast("qwen3-coder"));
    try std.testing.expectEqualStrings("ollama", catalog.target().name);

    const missing = Catalog.resolve(Ref.parse("absent").?, &config);
    try std.testing.expect(!missing.configured());
    try std.testing.expectEqualStrings("", missing.defaultModel());
    try std.testing.expectEqual(settings.default_context_tokens, missing.contextWindow("x"));
    try std.testing.expect(!missing.supportsEffort("x", .low));

    const claude = Catalog.builtin(.claude);
    try std.testing.expectEqual(auth.Api.messages, claude.api());
    try std.testing.expectEqualStrings("claude-opus-5", claude.defaultModel());
    try std.testing.expect(claude.supportsFast("claude-opus-5"));
}

test "custom endpoint URLs and headers follow the wire format" {
    const arena_gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(arena_gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const chat: Custom = .{ .api = .chat_completions, .base_url = "https://openrouter.ai/api/v1/" };
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", try url(allocator, &chat));
    const chat_headers = try headers(allocator, &chat, "sk-test");
    try std.testing.expectEqualStrings("Authorization", chat_headers[2].name);
    try std.testing.expectEqualStrings("Bearer sk-test", chat_headers[2].value);

    var extra: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try extra.put(allocator, "authorization", "Basic abc");
    try extra.put(allocator, "X-Title", "xaq");
    const messages: Custom = .{ .api = .messages, .base_url = "http://proxy.internal:8080", .headers = .{ .map = extra } };
    try std.testing.expectEqualStrings("http://proxy.internal:8080/messages", try url(allocator, &messages));
    const message_headers = try headers(allocator, &messages, "key");
    var saw_version = false;
    var saw_key = false;
    var saw_title = false;
    for (message_headers) |header| {
        if (std.mem.eql(u8, header.name, "anthropic-version")) saw_version = true;
        if (std.mem.eql(u8, header.name, "x-api-key")) saw_key = std.mem.eql(u8, header.value, "key");
        if (std.mem.eql(u8, header.name, "X-Title")) saw_title = true;
        try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, "authorization") or std.mem.eql(u8, header.value, "Basic abc"));
    }
    try std.testing.expect(saw_version and saw_key and saw_title);

    const bearer_messages: Custom = .{ .api = .messages, .base_url = "https://x", .auth = .bearer };
    const overridden = try headers(allocator, &bearer_messages, "k");
    var saw_bearer = false;
    for (overridden) |header| if (std.mem.eql(u8, header.name, "Authorization")) {
        saw_bearer = std.mem.eql(u8, header.value, "Bearer k");
    };
    try std.testing.expect(saw_bearer);

    const keyless = try headers(allocator, &chat, "");
    for (keyless) |header| try std.testing.expect(!std.mem.eql(u8, header.name, "Authorization"));
}

test "api keys resolve from literals, environment names, or nothing" {
    const literal: Custom = .{ .api = .responses, .base_url = "https://x", .api_key = "abc" };
    try std.testing.expectEqualStrings("abc", (try apiKey(&literal)).?);
    try std.testing.expectEqual(KeySource.literal, keySource(&literal));
    const none: Custom = .{ .api = .responses, .base_url = "https://x" };
    try std.testing.expectEqual(null, try apiKey(&none));
    try std.testing.expectEqual(KeySource.none, keySource(&none));
    try std.testing.expectEqualStrings("", (try credential(&none)).access);
    const missing: Custom = .{ .api = .responses, .base_url = "https://x", .api_key_env = "XAQ_TEST_KEY_THAT_IS_UNSET" };
    try std.testing.expectEqual(KeySource.environment, keySource(&missing));
    try std.testing.expectError(error.MissingApiKeyEnv, apiKey(&missing));
}

// ---------------------------------------------------------------------------
// Interactive setup and the `xaq provider` command

pub const Added = struct {
    /// Owned by the caller's allocator.
    name: []u8,
    loaded: settings.Loaded,
};

const api_labels = [_][]const u8{
    "chat_completions \u{b7} OpenAI-compatible (Ollama, vLLM, llama.cpp, LM Studio, OpenRouter)",
    "responses \u{b7} OpenAI Responses API",
    "messages \u{b7} Anthropic-compatible",
};
const api_values = [_]auth.Api{ .chat_completions, .responses, .messages };
const context_labels = [_][]const u8{ "32K", "64K", "128K", "200K", "256K", "1M" };
const context_values = [_]u32{ 32_000, 64_000, 128_000, 200_000, 256_000, 1_000_000 };
const effort_labels = [_][]const u8{ "none (model default)", "low, medium, high", "low, medium, high, xhigh, max" };
const effort_values = [_][]const Effort{ &.{}, &.{ .low, .medium, .high }, &.{ .low, .medium, .high, .xhigh, .max } };

fn suggestedBaseUrl(api: auth.Api) []const u8 {
    return switch (api) {
        .chat_completions => "http://localhost:11434/v1",
        .responses => "https://api.openai.com/v1",
        .messages => "https://api.anthropic.com/v1",
    };
}

fn suggestedEnvName(buffer: []u8, name: []const u8) []const u8 {
    const suffix = "_API_KEY";
    const len = @min(name.len, buffer.len - suffix.len);
    for (name[0..len], 0..) |byte, index| buffer[index] = if (byte == '-') '_' else std.ascii.toUpper(byte);
    @memcpy(buffer[len .. len + suffix.len], suffix);
    return buffer[0 .. len + suffix.len];
}

fn note(output: *Io.Writer, text: []const u8) !void {
    try output.print("{s}{s}{s}\n", .{ term.dim(), text, term.reset() });
    try output.flush();
}

/// Guided setup: name, wire format, base URL, key source, models, context
/// window, and reasoning efforts, then a summary to confirm. Nothing is
/// written until the final confirmation; every stage can cancel.
pub fn addInteractive(gpa: std.mem.Allocator, io: Io, home: []const u8, reader: *Io.Reader, output: *Io.Writer, preset_name: ?[]const u8) !?Added {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    try note(output, "custom provider setup \u{b7} enter confirms \u{b7} esc or ctrl-c cancels");

    var initial_name = preset_name;
    const name = while (true) {
        const entered = (try input_mod.readField(gpa, reader, output, "name (for example ollama or openrouter): ", initial_name)) orelse return null;
        defer gpa.free(entered);
        initial_name = null;
        if (settings.validProviderName(entered)) break try scratch.dupe(u8, entered);
        try note(output, "use 1-32 lowercase letters, digits, - or _; chatgpt, claude, grok, and custom are reserved");
    };

    try note(output, "wire format");
    const api = api_values[(try input_mod.pick(reader, output, &api_labels, 0)) orelse return null];

    var initial_url: ?[]const u8 = suggestedBaseUrl(api);
    const base_url = while (true) {
        const entered = (try input_mod.readField(gpa, reader, output, "base URL (without /chat/completions etc.): ", initial_url)) orelse return null;
        defer gpa.free(entered);
        initial_url = null;
        if (settings.validBaseUrl(entered)) break try scratch.dupe(u8, std.mem.trimEnd(u8, entered, "/"));
        try note(output, "use an http:// or https:// URL with a host and no spaces or quotes");
    };

    try note(output, "API key");
    const key_labels = [_][]const u8{ "read from an environment variable (recommended)", "store the key in settings.json (mode 0600)", "no API key (local server)" };
    var api_key: ?[]const u8 = null;
    var api_key_env: ?[]const u8 = null;
    switch ((try input_mod.pick(reader, output, &key_labels, 0)) orelse return null) {
        0 => {
            var suggestion_buffer: [settings.max_provider_name + 8]u8 = undefined;
            var initial_env: ?[]const u8 = suggestedEnvName(&suggestion_buffer, name);
            api_key_env = while (true) {
                const entered = (try input_mod.readField(gpa, reader, output, "environment variable: ", initial_env)) orelse return null;
                defer gpa.free(entered);
                initial_env = null;
                if (settings.validEnvName(entered)) break try scratch.dupe(u8, entered);
                try note(output, "use letters, digits, and underscores, not starting with a digit");
            };
            if (envValue(api_key_env.?) == null) {
                try output.print("{s}note: {s} is not set in this environment yet; export it before the first request{s}\n", .{ term.dim(), api_key_env.?, term.reset() });
                try output.flush();
            }
        },
        1 => {
            api_key = while (true) {
                const entered = (try input_mod.readSecret(gpa, reader, output, "API key: ")) orelse return null;
                defer gpa.free(entered);
                if (settings.validFirecrawlApiKey(entered)) break try scratch.dupe(u8, entered);
                try note(output, "use a non-empty key with no spaces");
            };
        },
        else => {},
    }

    const model_ids = while (true) {
        const entered = (try input_mod.readField(gpa, reader, output, "model IDs (comma separated, first is the default): ", null)) orelse return null;
        defer gpa.free(entered);
        if (try parseModelList(scratch, entered)) |list| break list;
        try note(output, "list 1-64 model IDs without spaces, separated by commas");
    };

    try note(output, "context window per model");
    const context_tokens = context_values[(try input_mod.pick(reader, output, &context_labels, 2)) orelse return null];
    try note(output, "reasoning efforts the endpoint accepts");
    const efforts = effort_values[(try input_mod.pick(reader, output, &effort_labels, 0)) orelse return null];

    const definition: Custom = .{
        .api = api,
        .base_url = base_url,
        .api_key = api_key,
        .api_key_env = api_key_env,
        .models = model_ids,
        .context_tokens = context_tokens,
        .efforts = efforts,
    };
    try writeSummary(output, name, &definition);
    const confirm = [_][]const u8{ "save to ~/.config/xaq/settings.json", "cancel" };
    if (((try input_mod.pick(reader, output, &confirm, 0)) orelse return null) != 0) return null;
    const loaded = settings.saveProvider(gpa, io, home, name, definition) catch |err| {
        try output.print("cannot save settings: {s}\n", .{if (err == error.SettingsInUse) "another session is saving settings; try again" else @errorName(err)});
        try output.flush();
        return null;
    };
    return .{ .name = try gpa.dupe(u8, name), .loaded = loaded };
}

/// Split "a, b c" into owned IDs; null when empty, too many, or malformed.
fn parseModelList(allocator: std.mem.Allocator, text: []const u8) !?[]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.tokenizeAny(u8, text, ", \t");
    while (iterator.next()) |id| {
        if (!settings.validModelId(id) or list.items.len == settings.max_provider_models) return null;
        try list.append(allocator, try allocator.dupe(u8, id));
    }
    if (list.items.len == 0) return null;
    return try list.toOwnedSlice(allocator);
}

fn writeSummary(output: *Io.Writer, name: []const u8, definition: *const Custom) !void {
    try output.print("  name      {s}\n  api       {s}\n  base URL  {s}\n  key       ", .{ name, @tagName(definition.api), definition.base_url });
    switch (keySource(definition)) {
        .environment => try output.print("${s}\n", .{definition.api_key_env.?}),
        .literal => try output.writeAll("stored in settings.json\n"),
        .none => try output.writeAll("none\n"),
    }
    try output.writeAll("  models    ");
    for (definition.models, 0..) |model, index| {
        if (index > 0) try output.writeAll(", ");
        try output.writeAll(model);
    }
    try output.print("\n  context   {d} tokens\n  efforts   ", .{definition.context_tokens});
    if (definition.efforts.len == 0) try output.writeAll("none");
    for (definition.efforts, 0..) |effort, index| {
        if (index > 0) try output.writeAll(", ");
        try output.writeAll(@tagName(effort));
    }
    if (definition.headers) |extra| try output.print("\n  headers   {d}", .{extra.map.count()});
    try output.writeByte('\n');
    try output.flush();
}

pub fn writeList(output: *Io.Writer, config: *const settings.Config, current: ?[]const u8) !void {
    const names = config.customProviderNames();
    if (names.len == 0) {
        try output.writeAll("no custom providers configured; add one with /provider add or: xaq provider add NAME\n");
        return;
    }
    for (names) |name| {
        const definition = config.customProvider(name) orelse continue;
        try output.print("  {s:<16} {s:<16} {s} \u{b7} {d} model{s} \u{b7} key: ", .{ name, @tagName(definition.api), definition.base_url, definition.models.len, if (definition.models.len == 1) "" else "s" });
        switch (keySource(definition)) {
            .environment => try output.print("${s}", .{definition.api_key_env.?}),
            .literal => try output.writeAll("settings.json"),
            .none => try output.writeAll("none"),
        }
        if (current) |active| if (std.mem.eql(u8, active, name)) try output.writeAll(" \u{b7} current session");
        try output.writeByte('\n');
    }
}

const cli_usage =
    \\usage: xaq provider list
    \\       xaq provider show NAME
    \\       xaq provider add NAME [--api chat_completions|responses|messages] [--base-url URL]
    \\                             [--api-key-env VAR | --api-key-stdin] [--auth bearer|x-api-key]
    \\                             [--model ID]... [--context-tokens N] [--effort LEVEL]...
    \\                             [--header 'Name: value']...
    \\       xaq provider remove NAME
    \\
    \\`xaq provider add NAME` with no other options starts guided setup on a terminal.
    \\Keys never travel on the command line: use --api-key-env, pipe the key to
    \\--api-key-stdin, or paste it into the hidden prompt of guided setup.
    \\
;

/// `xaq provider ...`. Returns the exit code; messages go to `output` and
/// usage errors to `errout`.
pub fn cli(gpa: std.mem.Allocator, io: Io, home: []const u8, args: []const []const u8, input: *Io.Reader, output: *Io.Writer, errout: *Io.Writer) !u8 {
    const verb = if (args.len > 0) args[0] else "list";
    if (std.mem.eql(u8, verb, "--help") or std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "help")) {
        try output.writeAll(cli_usage);
        return 0;
    }
    if (std.mem.eql(u8, verb, "list")) {
        if (args.len != 1 and args.len != 0) return usageError(errout, "list takes no arguments");
        var loaded = settings.load(gpa, io, home) catch |err| return settingsError(errout, err);
        defer loaded.deinit();
        try writeList(output, &loaded.value, null);
        return 0;
    }
    if (std.mem.eql(u8, verb, "show")) {
        if (args.len != 2) return usageError(errout, "show takes exactly one provider name");
        var loaded = settings.load(gpa, io, home) catch |err| return settingsError(errout, err);
        defer loaded.deinit();
        const definition = loaded.value.customProvider(args[1]) orelse {
            try errout.print("xaq: no custom provider named '{s}'\n", .{args[1]});
            return 1;
        };
        try writeSummary(output, args[1], definition);
        return 0;
    }
    if (std.mem.eql(u8, verb, "remove")) {
        if (args.len != 2) return usageError(errout, "remove takes exactly one provider name");
        var result = settings.removeProvider(gpa, io, home, args[1]) catch |err| return settingsError(errout, err);
        defer result.loaded.deinit();
        if (!result.removed) {
            try errout.print("xaq: no custom provider named '{s}'\n", .{args[1]});
            return 1;
        }
        try output.print("provider {s} removed\n", .{args[1]});
        return 0;
    }
    if (std.mem.eql(u8, verb, "add")) {
        if (args.len < 2) return usageError(errout, "add needs a provider name");
        const name = args[1];
        if (!settings.validProviderName(name)) return usageError(errout, "provider names use 1-32 lowercase letters, digits, - or _; chatgpt, claude, grok, and custom are reserved");
        if (args.len == 2) {
            if (!input_mod.interactive) return usageError(errout, "guided setup needs a terminal; pass --api, --base-url, and --model instead");
            var added = (try addInteractive(gpa, io, home, input, output, name)) orelse {
                try output.writeAll("provider setup cancelled\n");
                return 1;
            };
            defer gpa.free(added.name);
            defer added.loaded.deinit();
            try output.print("provider {s} saved to ~/.config/xaq/settings.json\n", .{added.name});
            return 0;
        }
        return addFromFlags(gpa, io, home, name, args[2..], input, output, errout);
    }
    try errout.print("xaq: unknown provider command '{s}'\n", .{verb});
    try errout.writeAll(cli_usage);
    return 2;
}

fn usageError(errout: *Io.Writer, message: []const u8) !u8 {
    try errout.print("xaq: {s}\n", .{message});
    try errout.writeAll(cli_usage);
    return 2;
}

fn settingsError(errout: *Io.Writer, err: anyerror) !u8 {
    try errout.print("xaq: cannot update settings: {s}\n", .{switch (err) {
        error.SettingsInUse => "another session is saving settings; try again",
        error.InvalidSettings => "~/.config/xaq/settings.json is invalid; fix or remove the bad entry",
        else => @errorName(err),
    }});
    return 1;
}

fn addFromFlags(gpa: std.mem.Allocator, io: Io, home: []const u8, name: []const u8, flags: []const []const u8, input: *Io.Reader, output: *Io.Writer, errout: *Io.Writer) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    var api: ?auth.Api = null;
    var base_url: ?[]const u8 = null;
    var api_key_env: ?[]const u8 = null;
    var key_from_stdin = false;
    var auth_style: ?settings.AuthStyle = null;
    var model_ids: std.ArrayList([]const u8) = .empty;
    var context_tokens: u32 = settings.default_context_tokens;
    var efforts: std.ArrayList(Effort) = .empty;
    var extra_headers: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var index: usize = 0;
    while (index < flags.len) : (index += 1) {
        const flag = flags[index];
        if (std.mem.eql(u8, flag, "--api-key-stdin")) {
            key_from_stdin = true;
            continue;
        }
        index += 1;
        if (index >= flags.len) {
            try errout.print("xaq: {s} needs a value\n", .{flag});
            return 2;
        }
        const value = flags[index];
        if (std.mem.eql(u8, flag, "--api")) {
            api = auth.Api.parse(value) orelse return usageError(errout, "--api must be chat_completions, responses, or messages");
        } else if (std.mem.eql(u8, flag, "--base-url")) {
            if (!settings.validBaseUrl(value)) return usageError(errout, "--base-url must be an http:// or https:// URL with a host");
            base_url = std.mem.trimEnd(u8, value, "/");
        } else if (std.mem.eql(u8, flag, "--api-key-env")) {
            if (!settings.validEnvName(value)) return usageError(errout, "--api-key-env must be an environment variable name");
            api_key_env = value;
        } else if (std.mem.eql(u8, flag, "--auth")) {
            auth_style = settings.AuthStyle.parse(value) orelse return usageError(errout, "--auth must be bearer or x-api-key");
        } else if (std.mem.eql(u8, flag, "--model")) {
            if (!settings.validModelId(value)) return usageError(errout, "--model IDs cannot be empty or contain spaces");
            try model_ids.append(scratch, value);
        } else if (std.mem.eql(u8, flag, "--context-tokens")) {
            context_tokens = std.fmt.parseInt(u32, value, 10) catch return usageError(errout, "--context-tokens must be a number");
        } else if (std.mem.eql(u8, flag, "--effort")) {
            try efforts.append(scratch, Effort.parse(value) orelse return usageError(errout, "--effort must be low, medium, high, xhigh, max, or ultra"));
        } else if (std.mem.eql(u8, flag, "--header")) {
            const colon = std.mem.indexOfScalar(u8, value, ':') orelse return usageError(errout, "--header takes 'Name: value'");
            try extra_headers.put(scratch, std.mem.trim(u8, value[0..colon], " "), std.mem.trim(u8, value[colon + 1 ..], " "));
        } else {
            try errout.print("xaq: unknown option '{s}'\n", .{flag});
            try errout.writeAll(cli_usage);
            return 2;
        }
    }
    if (api == null) return usageError(errout, "--api is required");
    if (base_url == null) return usageError(errout, "--base-url is required");
    if (model_ids.items.len == 0) return usageError(errout, "at least one --model is required");
    if (key_from_stdin and api_key_env != null) return usageError(errout, "use either --api-key-env or --api-key-stdin");
    var api_key: ?[]const u8 = null;
    if (key_from_stdin) {
        const line = input.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => "",
            else => return err,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!settings.validFirecrawlApiKey(trimmed)) return usageError(errout, "--api-key-stdin needs a non-empty key with no spaces on stdin");
        api_key = try scratch.dupe(u8, trimmed);
    }
    const definition: Custom = .{
        .api = api.?,
        .base_url = base_url.?,
        .api_key = api_key,
        .api_key_env = api_key_env,
        .auth = auth_style,
        .headers = if (extra_headers.count() > 0) .{ .map = extra_headers } else null,
        .models = model_ids.items,
        .context_tokens = context_tokens,
        .efforts = efforts.items,
    };
    settings.validateProvider(name, definition) catch return usageError(errout, "the provider definition is invalid; check the header values, context size, and model IDs");
    var loaded = settings.saveProvider(gpa, io, home, name, definition) catch |err| return settingsError(errout, err);
    defer loaded.deinit();
    try output.print("provider {s} saved to ~/.config/xaq/settings.json\n", .{name});
    return 0;
}

test "model lists split on commas and spaces and reject bad IDs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const list = (try parseModelList(arena.allocator(), "a, b  c,d")).?;
    try std.testing.expectEqual(@as(usize, 4), list.len);
    try std.testing.expectEqualStrings("d", list[3]);
    try std.testing.expectEqual(null, try parseModelList(arena.allocator(), " , "));
    try std.testing.expectEqual(null, try parseModelList(arena.allocator(), "ok\x01"));
}

test "suggested environment names upper-case the provider name" {
    var buffer: [40]u8 = undefined;
    try std.testing.expectEqualStrings("OPEN_ROUTER_API_KEY", suggestedEnvName(&buffer, "open-router"));
}

test "provider CLI adds, lists, shows, and removes definitions without a terminal" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const home = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/{s}", .{ cwd_buffer[0..cwd_length], temporary.sub_path });
    defer gpa.free(home);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(gpa);
    defer err_out.deinit();
    var stdin: Io.Reader = .fixed("sk-secret\n");

    try std.testing.expectEqual(@as(u8, 2), try cli(gpa, std.testing.io, home, &.{ "add", "ollama", "--base-url", "http://localhost:11434/v1", "--model", "qwen3" }, &stdin, &out.writer, &err_out.writer));
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "--api is required") != null);
    try std.testing.expectEqual(@as(u8, 2), try cli(gpa, std.testing.io, home, &.{ "add", "Claude", "--api", "messages" }, &stdin, &out.writer, &err_out.writer));
    try std.testing.expectEqual(@as(u8, 0), try cli(gpa, std.testing.io, home, &.{ "add", "router", "--api", "chat_completions", "--base-url", "https://openrouter.ai/api/v1/", "--api-key-stdin", "--model", "a/b", "--model", "c", "--effort", "low", "--header", "X-Title: xaq", "--context-tokens", "200000" }, &stdin, &out.writer, &err_out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "provider router saved") != null);

    var loaded = try settings.load(gpa, std.testing.io, home);
    defer loaded.deinit();
    const definition = loaded.value.customProvider("router").?;
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", definition.base_url);
    try std.testing.expectEqualStrings("sk-secret", definition.api_key.?);
    try std.testing.expectEqual(@as(usize, 2), definition.models.len);
    try std.testing.expectEqual(@as(u32, 200_000), definition.context_tokens);
    try std.testing.expectEqualStrings("xaq", definition.headers.?.map.get("X-Title").?);
    try std.testing.expectEqual(Effort.low, definition.efforts[0]);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cli(gpa, std.testing.io, home, &.{"list"}, &stdin, &out.writer, &err_out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "router") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "sk-secret") == null);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cli(gpa, std.testing.io, home, &.{ "show", "router" }, &stdin, &out.writer, &err_out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "stored in settings.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "sk-secret") == null);
    try std.testing.expectEqual(@as(u8, 1), try cli(gpa, std.testing.io, home, &.{ "remove", "missing" }, &stdin, &out.writer, &err_out.writer));
    try std.testing.expectEqual(@as(u8, 0), try cli(gpa, std.testing.io, home, &.{ "remove", "router" }, &stdin, &out.writer, &err_out.writer));
    var emptied = try settings.load(gpa, std.testing.io, home);
    defer emptied.deinit();
    try std.testing.expectEqual(@as(usize, 0), emptied.value.customProviderCount());
}
