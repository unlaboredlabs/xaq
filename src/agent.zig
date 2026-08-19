const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const cancel = @import("cancel.zig");
const context = @import("context.zig");
const git = @import("git.zig");
const input_mod = @import("input.zig");
const log = @import("log.zig");
const markdown = @import("markdown.zig");
const models = @import("models.zig");
const request = @import("request.zig");
const settings_mod = @import("settings.zig");
const spin = @import("spin.zig");
const stream_decoder = @import("stream.zig");
const subagents = @import("subagents.zig");
const term = @import("term.zig");
const threads = @import("threads.zig");
const tools = @import("tools.zig");
const transport = @import("transport.zig");
const tui = @import("tui.zig");
const types = @import("types.zig");

pub const ToolCall = types.ToolCall;
const ToolResult = types.ToolResult;
const Usage = types.Usage;
const Assistant = types.Assistant;
const Entry = types.Entry;

pub const Effort = models.Effort;

pub const Options = struct {
    home: []const u8,
    cwd: []const u8,
    provider: auth.Provider,
    model: []const u8,
    effort: ?Effort = null,
    fast: bool = false,
    first_prompt: ?[]const u8 = null,
    input: ?*Io.Reader = null,
    output: *Io.Writer,
    /// Destination for tool call/aftermath lines and compaction notices.
    /// Piped one-shots point this at stderr so stdout stays clean answer
    /// text; null means they share `output`.
    tool_trace: ?*Io.Writer = null,
    /// Empty means the latest thread for cwd; non-empty is an explicit ID.
    resume_id: ?[]const u8 = null,
    /// Hidden worker controls used by subagent child processes.
    subagent_control: ?[]const u8 = null,
};

pub fn defaultModel(provider: auth.Provider) []const u8 {
    return models.defaultModel(provider);
}

const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    home: []const u8,
    cwd: []const u8,
    provider: auth.Provider,
    model: []u8,
    effort: ?Effort,
    fast: bool,
    output: *Io.Writer,
    trace: *Io.Writer,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    instructions: []u8,
    settings: settings_mod.Loaded,
    thread: ?threads.Thread = null,
    turn: u64 = 0,
    usage: Usage = .{},
    git_status: git.Status = .{},
    /// When on, tool results echo an indented, clamped preview so the
    /// user can audit what commands actually printed.
    verbose: bool = false,
    /// True when a prompt reader exists; failed rounds return to the
    /// prompt instead of ending the process.
    interactive: bool = false,
    subagent_manager: ?subagents.Manager = null,
    subagent_control: ?[]const u8 = null,
    subagent_control_seen: usize = 0,

    fn allocator(self: *Session) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *Session) void {
        if (self.subagent_manager) |*manager| manager.deinit();
        if (self.thread) |*thread| thread.deinit();
        self.arena.deinit();
        self.gpa.free(self.model);
        self.gpa.free(self.instructions);
        self.settings.deinit();
    }

    fn setModel(self: *Session, value: []const u8) !void {
        const next = try self.gpa.dupe(u8, value);
        self.gpa.free(self.model);
        self.model = next;
        if (self.thread) |*thread| try thread.appendModel(value);
        if (self.effort) |effort| {
            if (!models.supportsEffort(self.provider, value, effort)) {
                self.effort = null;
                if (self.thread) |*thread| try thread.appendEffort("default");
            }
        }
        if (self.fast and !models.supportsFast(self.provider, value)) {
            self.fast = false;
            if (self.thread) |*thread| try thread.appendFast(false);
        }
    }

    fn setEffort(self: *Session, value: ?Effort) !void {
        self.effort = value;
        if (self.thread) |*thread| try thread.appendEffort(if (value) |effort| @tagName(effort) else "default");
    }

    fn setFast(self: *Session, enabled: bool) !void {
        self.fast = enabled;
        if (self.thread) |*thread| try thread.appendFast(enabled);
    }

    fn appendEntry(self: *Session, entry: Entry) !void {
        try self.entries.append(self.allocator(), entry);
        if (self.thread) |*thread| try thread.appendEntry(entry);
    }

    fn appendUser(self: *Session, text: []const u8) !void {
        try self.appendEntry(.{ .user = try self.allocator().dupe(u8, text) });
    }

    fn replaceArena(self: *Session) void {
        self.arena.deinit();
        self.arena = .init(self.gpa);
        self.entries = .empty;
    }

    fn clear(self: *Session) !void {
        self.replaceArena();
        // Counters describe the visible conversation; a resumed thread
        // recomputes them from entries, so an empty thread means zero.
        self.turn = 0;
        self.usage = .{};
        if (self.thread) |*thread| try thread.appendReset();
    }

    fn startThread(self: *Session) !void {
        // Null out before deinit: if create fails, teardown must not
        // deinit the poisoned old payload a second time.
        if (self.thread) |*thread| {
            thread.deinit();
            self.thread = null;
        }
        self.thread = try threads.create(self.gpa, self.io, self.home, self.cwd, self.provider, self.model, if (self.effort) |value| @tagName(value) else null, self.fast);
    }

    fn newThread(self: *Session) !void {
        if (self.subagent_manager) |*manager| manager.reset();
        self.replaceArena();
        self.turn = 0;
        self.usage = .{};
        try self.startThread();
    }

    fn resumeThread(self: *Session, requested: ?[]const u8) !void {
        var next_arena: std.heap.ArenaAllocator = .init(self.gpa);
        // The errdefers must disarm once ownership moves into `self`;
        // otherwise a late failure frees the live session's arena,
        // thread, and model while the caller keeps using them.
        var installed = false;
        errdefer if (!installed) next_arena.deinit();
        const excluded = if (requested == null) if (self.thread) |thread| thread.id else null else null;
        var loaded = try threads.load(self.gpa, next_arena.allocator(), self.io, self.home, self.cwd, requested, excluded);
        errdefer if (!installed) loaded.thread.deinit();
        const loaded_model = try self.gpa.dupe(u8, loaded.model);
        errdefer if (!installed) self.gpa.free(loaded_model);

        if (self.subagent_manager) |*manager| manager.reset();
        if (self.thread) |*thread| thread.deinit();
        self.arena.deinit();
        self.gpa.free(self.model);
        self.arena = next_arena;
        self.entries = loaded.entries;
        self.thread = loaded.thread;
        self.provider = loaded.provider;
        self.model = loaded_model;
        installed = true;
        self.effort = if (loaded.effort) |value| Effort.parse(value) else null;
        self.fast = loaded.fast and models.supportsFast(loaded.provider, loaded.model);
        if (self.effort) |effort| {
            if (!models.supportsEffort(self.provider, self.model, effort)) self.effort = null;
        }
        self.turn = 0;
        self.usage = .{};
        for (self.entries.items) |entry| switch (entry) {
            .assistant => |answer| {
                self.turn += 1;
                self.usage.input += answer.usage.input;
                self.usage.cached += answer.usage.cached;
                self.usage.output += answer.usage.output;
            },
            else => {},
        };
        if (self.entries.items.len > 0) switch (self.entries.items[self.entries.items.len - 1]) {
            .assistant => |answer| if (answer.calls.len > 0) {
                const results = try self.allocator().alloc(ToolResult, answer.calls.len);
                for (answer.calls, 0..) |call, i| results[i] = .{
                    .id = call.id,
                    .text = "tool interrupted before its result was saved; inspect current state before retrying",
                };
                try self.appendEntry(.{ .results = results });
            },
            else => {},
        };
    }
};

pub fn run(gpa: std.mem.Allocator, io: Io, options: Options) !void {
    if (options.effort) |effort| {
        if (!models.supportsEffort(options.provider, options.model, effort)) return error.InvalidEffortForModel;
    }
    if (options.fast and options.resume_id == null and !models.supportsFast(options.provider, options.model)) return error.InvalidFastForModel;
    var user_settings = try settings_mod.load(gpa, io, options.home);
    var settings_owned = true;
    errdefer if (settings_owned) user_settings.deinit();
    var session: Session = .{
        .gpa = gpa,
        .io = io,
        .home = options.home,
        .cwd = options.cwd,
        .provider = options.provider,
        .model = try gpa.dupe(u8, options.model),
        .effort = options.effort,
        .fast = options.fast,
        .output = options.output,
        .trace = options.tool_trace orelse options.output,
        .interactive = options.input != null,
        .subagent_manager = if (options.subagent_control == null) try subagents.Manager.init(gpa, io, options.cwd, .{
            .enabled = user_settings.value.subagents_enabled,
            .max_concurrent = user_settings.value.subagent_max_concurrent,
            .background_by_default = user_settings.value.subagent_default_background,
        }) else null,
        .subagent_control = options.subagent_control,
        .arena = .init(gpa),
        .instructions = try context.load(gpa, io, options.home, options.cwd),
        .settings = user_settings,
    };
    settings_owned = false;
    defer session.deinit();
    var signal_scope = cancel.Scope.install();
    defer signal_scope.deinit();

    if (options.resume_id) |id| {
        try session.resumeThread(if (id.len == 0) null else id);
        if (options.fast) {
            if (!models.supportsFast(session.provider, session.model)) return error.InvalidFastForModel;
            try session.setFast(true);
        }
        // Orientation matters most interactively; one-shot output stays clean.
        if (options.input != null) try printResumed(&session);
    } else if (options.input != null) {
        try session.startThread();
    }
    refreshGit(&session);
    syncTui(&session);
    if (options.first_prompt) |prompt| {
        try session.appendUser(prompt);
    } else {
        const reader = options.input orelse return;
        const prompt = (try readPrompt(&session, reader, null)) orelse return;
        defer gpa.free(prompt);
        try session.appendUser(prompt);
    }

    var exchange_start = Io.Clock.now(.awake, io);
    var exchange_base = session.usage;
    while (true) {
        if (session.subagent_manager) |*manager| {
            if (try manager.takeNotifications(session.allocator())) |notification| {
                try session.appendEntry(.{ .user = notification });
                refreshGit(&session);
            }
            syncTui(&session);
        }
        _ = try consumeSteering(&session);
        try setTitle(&session, true);
        _ = try compactIfNeeded(&session, false);
        // A cancel that landed outside a round (during compaction or
        // between spawns) must not silently start the next request.
        if (cancel.requested()) {
            cancel.reset();
            var prefill: ?[]const u8 = null;
            if (session.entries.items.len > 0 and session.entries.items[session.entries.items.len - 1] == .user) {
                const popped = session.entries.pop().?;
                prefill = popped.user;
                try persistSnapshot(&session);
            }
            try options.output.writeAll("\ninterrupted\n");
            try options.output.flush();
            tui.noteState(.idle, "");
            syncTui(&session);
            const reader = options.input orelse return error.Interrupted;
            const prompt = (try readPrompt(&session, reader, prefill)) orelse return;
            defer gpa.free(prompt);
            try session.appendUser(prompt);
            exchange_start = Io.Clock.now(.awake, io);
            exchange_base = session.usage;
            continue;
        }
        session.turn += 1;
        tui.noteState(.thinking, "");
        const answer = performRound(&session) catch |err| switch (err) {
            error.ProviderRequestFailed => {
                // The HTTP error body was already printed to the transcript.
                // Interactively the session survives: the failed prompt is
                // prefilled for editing (a /model fix, a retry). One-shots
                // propagate so the process exits nonzero.
                session.turn -|= 1;
                const reader = options.input orelse return err;
                var prefill: ?[]const u8 = null;
                if (session.entries.items.len > 0 and session.entries.items[session.entries.items.len - 1] == .user) {
                    const popped = session.entries.pop().?;
                    prefill = popped.user; // arena-owned; stays valid until reset
                    try persistSnapshot(&session);
                }
                tui.noteState(.idle, "");
                syncTui(&session);
                const prompt = (try readPrompt(&session, reader, prefill)) orelse return;
                defer gpa.free(prompt);
                try session.appendUser(prompt);
                exchange_start = Io.Clock.now(.awake, io);
                exchange_base = session.usage;
                continue;
            },
            error.Cancelled => {
                session.turn -|= 1;
                cancel.reset();
                var prefill: ?[]const u8 = null;
                if (session.entries.items.len > 0 and session.entries.items[session.entries.items.len - 1] == .user) {
                    const popped = session.entries.pop().?;
                    prefill = popped.user; // arena-owned; stays valid until reset
                    try persistSnapshot(&session);
                }
                const interrupted_ms: u64 = @intCast(@max(0, @divTrunc(Io.Clock.now(.awake, io).nanoseconds - exchange_start.nanoseconds, std.time.ns_per_ms)));
                try options.output.writeAll("\ninterrupted after ");
                try writeDuration(options.output, interrupted_ms);
                try options.output.writeByte('\n');
                try options.output.flush();
                tui.noteState(.idle, "");
                syncTui(&session);
                const reader = options.input orelse return error.Interrupted;
                const prompt = (try readPrompt(&session, reader, prefill)) orelse return;
                defer gpa.free(prompt);
                try session.appendUser(prompt);
                exchange_start = Io.Clock.now(.awake, io);
                exchange_base = session.usage;
                continue;
            },
            else => return err,
        };
        session.usage.input += answer.usage.input;
        session.usage.cached += answer.usage.cached;
        session.usage.output += answer.usage.output;
        log.logf("usage", "event=tokens turn={d} input={d} cached={d} output={d} session_input={d} session_cached={d} session_output={d}", .{ session.turn, answer.usage.input, answer.usage.cached, answer.usage.output, session.usage.input, session.usage.cached, session.usage.output });
        try session.appendEntry(.{ .assistant = answer });
        syncTui(&session);
        if (answer.calls.len == 0) {
            tui.noteState(.idle, "");
            log.flush();
            try options.output.writeByte('\n');
            if (options.input != null) {
                const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(Io.Clock.now(.awake, io).nanoseconds - exchange_start.nanoseconds, std.time.ns_per_ms)));
                try printExchangeStats(options.output, elapsed_ms, .{
                    .input = session.usage.input - exchange_base.input,
                    .cached = session.usage.cached - exchange_base.cached,
                    .output = session.usage.output - exchange_base.output,
                }, contextPercent(&session));
            }
            try options.output.flush();
            if (options.input == null and try consumeSteering(&session) > 0) continue;
            const reader = options.input orelse return;
            const prompt = (try readPrompt(&session, reader, null)) orelse return;
            defer gpa.free(prompt);
            try session.appendUser(prompt);
            exchange_start = Io.Clock.now(.awake, io);
            exchange_base = session.usage;
            continue;
        }

        const results = try session.allocator().alloc(ToolResult, answer.calls.len);
        // Tool blocks are blank-line separated from streamed text: two
        // breaks close the open text line and leave a gap; pure tool
        // rounds start at column zero already. The breaks stay on the
        // answer stream even when tool lines are diverted to stderr, so
        // piped output keeps rounds separated.
        const trace = session.trace;
        if (answer.text.len > 0) {
            try options.output.writeAll("\n\n");
            try options.output.flush();
        }
        for (answer.calls, 0..) |call, i| {
            tui.noteState(.tooling, call.name);
            const start = Io.Clock.now(.awake, io);
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const scratch_gpa = scratch.allocator();
            invoke: {
                var parsed = std.json.parseFromSlice(std.json.Value, scratch_gpa, call.arguments, .{}) catch |err| {
                    try printToolCall(trace, call.name, null);
                    results[i] = .{ .id = call.id, .text = try std.fmt.allocPrint(session.allocator(), "invalid tool arguments: {s}", .{@errorName(err)}) };
                    break :invoke;
                };
                defer parsed.deinit();
                try printToolCall(trace, call.name, parsed.value);
                const result = tools.executeWithContext(scratch_gpa, io, call.name, parsed.value, .{
                    .cwd = session.cwd,
                    .firecrawl_api_key = session.settings.value.firecrawl_api_key,
                    .write_enabled = true,
                    .subagent_manager = if (session.subagent_manager) |*manager| manager else null,
                    .subagent_launch = .{
                        .provider = @tagName(session.provider),
                        .model = session.model,
                        .effort = if (session.effort) |value| @tagName(value) else null,
                        .fast = session.fast,
                    },
                }) catch |err|
                    try std.fmt.allocPrint(scratch_gpa, "tool error: {s}", .{@errorName(err)});
                results[i] = .{ .id = call.id, .text = try session.allocator().dupe(u8, result) };
            }
            if (toolMayChangeWorktree(call.name)) {
                refreshGit(&session);
                syncTui(&session);
            }
            const elapsed_ms: i64 = @intCast(@divTrunc(Io.Clock.now(.awake, io).nanoseconds - start.nanoseconds, std.time.ns_per_ms));
            if (elapsed_ms >= slow_tool_ms) {
                try trace.writeAll(" \u{b7} ");
                try writeDuration(trace, @intCast(elapsed_ms));
            }
            try trace.print("{s}\n", .{term.reset()});
            try trace.flush();
            log.logf("tool", "event=call turn={d} name={s} args_bytes={d} result_bytes={d} ms={d}", .{ session.turn, call.name, call.arguments.len, results[i].text.len, elapsed_ms });
            if (isSubagentTool(call.name)) {
                try printSubagentOutcome(trace, results[i].text);
            } else {
                try printToolOutcome(trace, results[i].text);
            }
            if (session.verbose) try printToolVerbose(trace, results[i].text);
            // A ctrl-c during tool execution ends the whole exchange;
            // checked here because the next spawn resets the flag.
            if (cancel.requested()) {
                var remaining = i + 1;
                while (remaining < answer.calls.len) : (remaining += 1) {
                    results[remaining] = .{ .id = answer.calls[remaining].id, .text = "cancelled by the user before execution" };
                }
                break;
            }
        }
        // A gap after the block keeps the next streamed answer readable.
        try trace.writeByte('\n');
        try trace.flush();
        try session.appendEntry(.{ .results = results });
        syncTui(&session);
        log.flush();
        if (cancel.requested()) {
            cancel.reset();
            const interrupted_ms: u64 = @intCast(@max(0, @divTrunc(Io.Clock.now(.awake, io).nanoseconds - exchange_start.nanoseconds, std.time.ns_per_ms)));
            try options.output.writeAll("interrupted after ");
            try writeDuration(options.output, interrupted_ms);
            try options.output.writeByte('\n');
            try options.output.flush();
            tui.noteState(.idle, "");
            syncTui(&session);
            const reader = options.input orelse return error.Interrupted;
            const prompt = (try readPrompt(&session, reader, null)) orelse return;
            defer gpa.free(prompt);
            try session.appendUser(prompt);
            exchange_start = Io.Clock.now(.awake, io);
            exchange_base = session.usage;
            continue;
        }
    }
}

/// Subagent workers receive steering through an atomically replaced JSONL
/// file. Each message becomes a normal user entry before the next model turn.
fn consumeSteering(session: *Session) !usize {
    const path = session.subagent_control orelse return 0;
    const bytes = Io.Dir.cwd().readFileAlloc(session.io, path, session.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer session.gpa.free(bytes);
    var seen: usize = 0;
    var added: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (seen < session.subagent_control_seen) {
            seen += 1;
            continue;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, session.gpa, line, .{}) catch continue;
        defer parsed.deinit();
        const message = switch (parsed.value) {
            .string => |text| text,
            else => continue,
        };
        try session.appendUser(message);
        seen += 1;
        added += 1;
    }
    session.subagent_control_seen = seen;
    return added;
}

/// Prompt until a non-empty, non-command line arrives. Slash commands run
/// locally and re-prompt. Returns null on EOF or /exit. `prefill` seeds
/// the editor once (for example with a cancelled prompt).
fn readPrompt(session: *Session, reader: *Io.Reader, prefill: ?[]const u8) !?[]const u8 {
    try setTitle(session, false);
    var initial = prefill;
    while (true) {
        const line = (try input_mod.readLine(session.gpa, reader, session.output, &slash_suggestions, initial)) orelse return null;
        initial = null;
        if (line.len == 0) {
            session.gpa.free(line);
            continue;
        }
        if (line[0] == '/') {
            const keep_going = try runCommand(session, reader, line[1..]);
            session.gpa.free(line);
            if (!keep_going) return null;
            syncTui(session);
            continue;
        }
        return line;
    }
}

const Command = enum { help, model, effort, fast, verbose, firecrawl, agents, settings, status, compact, clear, new, resume_thread, exit };

const CommandSpec = struct {
    command: Command,
    name: []const u8,
    alias: ?[]const u8 = null,
    args: []const u8 = "",
    help: []const u8,
};

const command_specs = [_]CommandSpec{
    .{ .command = .help, .name = "help", .help = "list commands" },
    .{ .command = .model, .name = "model", .args = " [ID]", .help = "pick model, effort, and speed" },
    .{ .command = .effort, .name = "effort", .args = " [LEVEL]", .help = "pick or set reasoning effort" },
    .{ .command = .fast, .name = "fast", .args = " [MODE]", .help = "toggle normal or fast mode" },
    .{ .command = .verbose, .name = "verbose", .args = " [on|off]", .help = "show tool output inline" },
    .{ .command = .firecrawl, .name = "firecrawl", .args = " [status|clear]", .help = "configure Firecrawl web tools" },
    .{ .command = .agents, .name = "agents", .help = "list subagents and their status" },
    .{ .command = .settings, .name = "settings", .alias = "config", .help = "configure context compaction" },
    .{ .command = .status, .name = "status", .help = "show session and token usage" },
    .{ .command = .compact, .name = "compact", .help = "compact older context now" },
    .{ .command = .clear, .name = "clear", .help = "clear the current thread" },
    .{ .command = .new, .name = "new", .help = "start a new saved thread" },
    .{ .command = .resume_thread, .name = "resume", .args = " [ID]", .help = "pick or resume a saved thread" },
    .{ .command = .exit, .name = "exit", .alias = "quit", .help = "leave xaq" },
};

const slash_suggestions = blk: {
    var out: [command_specs.len]input_mod.Suggestion = undefined;
    for (command_specs, 0..) |spec, i| out[i] = .{
        .name = spec.name,
        .alias = spec.alias,
        .args = spec.args,
        .help = spec.help,
    };
    break :blk out;
};

fn modelChoices(provider: auth.Provider) []const []const u8 {
    return models.choices(provider);
}

/// Exact name or alias first, then unique prefix (`/mod` resolves to /model).
fn findCommand(word: []const u8) error{Ambiguous}!?Command {
    if (word.len == 0) return null;
    for (command_specs) |spec| {
        if (std.mem.eql(u8, spec.name, word)) return spec.command;
        if (spec.alias) |alias| if (std.mem.eql(u8, alias, word)) return spec.command;
    }
    var match: ?Command = null;
    for (command_specs) |spec| {
        var hit = std.mem.startsWith(u8, spec.name, word);
        if (spec.alias) |alias| hit = hit or std.mem.startsWith(u8, alias, word);
        if (!hit) continue;
        if (match) |previous| {
            if (previous != spec.command) return error.Ambiguous;
        }
        match = spec.command;
    }
    return match;
}

/// Returns false when the session should end.
fn runCommand(session: *Session, reader: *Io.Reader, body: []const u8) !bool {
    const output = session.output;
    const split = std.mem.findAny(u8, body, " \t") orelse body.len;
    const word = body[0..split];
    const args = std.mem.trim(u8, body[split..], " \t");
    const command = findCommand(word) catch {
        try output.print("ambiguous command: /{s} (matches", .{word});
        for (command_specs) |spec| {
            var hit = std.mem.startsWith(u8, spec.name, word);
            if (spec.alias) |alias| hit = hit or std.mem.startsWith(u8, alias, word);
            if (hit) try output.print(" /{s}", .{spec.name});
        }
        try output.writeAll(")\n");
        try output.flush();
        return true;
    } orelse {
        try output.print("unknown command: /{s} (try /help)\n", .{word});
        try output.flush();
        return true;
    };
    log.logf("agent", "event=command name={s}", .{@tagName(command)});
    switch (command) {
        .help => {
            for (command_specs) |spec| {
                try output.print("  {s}/{s}{s}{s}", .{ term.bold(), spec.name, spec.args, term.reset() });
                var column = 1 + spec.name.len + spec.args.len;
                while (column < input_mod.help_column) : (column += 1) try output.writeByte(' ');
                try output.print("{s}", .{spec.help});
                if (spec.alias) |alias| try output.print(" {s}(also /{s}){s}", .{ term.dim(), alias, term.reset() });
                try output.writeByte('\n');
            }
            try output.print("{s}  enter sends \u{b7} \\ continues \u{b7} \u{2191}\u{2193} history \u{b7} tab completes \u{b7} ctrl-d exits{s}\n", .{ term.dim(), term.reset() });
        },
        .model => if (args.len == 0) {
            if (input_mod.interactive) {
                try pickModel(session, reader);
            } else {
                try output.print("model {s} (provider default {s})\n", .{ session.model, defaultModel(session.provider) });
            }
        } else {
            const was_fast = session.fast;
            try session.setModel(args);
            try output.print("model set to {s}\n", .{session.model});
            if (was_fast and !session.fast) try output.writeAll("fast mode turned off; this model does not support it\n");
        },
        .effort => if (args.len == 0) {
            if (input_mod.interactive) {
                try pickEffort(session, reader);
            } else {
                try output.print("effort {s}\n", .{if (session.effort) |value| @tagName(value) else "provider-default"});
            }
        } else {
            const value = if (std.mem.eql(u8, args, "default") or std.mem.eql(u8, args, "provider-default")) null else Effort.parse(args) orelse {
                try output.writeAll("unknown effort (low, medium, high, xhigh, max, or default)\n");
                try output.flush();
                return true;
            };
            if (value) |effort| if (!models.supportsEffort(session.provider, session.model, effort)) {
                try output.print("{s} does not support {s} effort (try /effort)\n", .{ session.model, @tagName(effort) });
                try output.flush();
                return true;
            };
            try session.setEffort(value);
            try output.print("effort set to {s}\n", .{if (value) |effort| @tagName(effort) else "provider-default"});
        },
        .fast => {
            const enabled = if (args.len == 0)
                !session.fast
            else if (std.mem.eql(u8, args, "on"))
                true
            else if (std.mem.eql(u8, args, "off"))
                false
            else if (std.mem.eql(u8, args, "status")) {
                try output.print("fast mode {s}\n", .{if (session.fast) "on" else "off"});
                try output.flush();
                return true;
            } else {
                try output.writeAll("usage: /fast [on|off|status]\n");
                try output.flush();
                return true;
            };
            if (enabled and !models.supportsFast(session.provider, session.model)) {
                try output.print("fast mode is not available for {s}\n", .{session.model});
                try output.flush();
                return true;
            }
            try session.setFast(enabled);
            try output.print("fast mode {s}\n", .{if (enabled) "on" else "off"});
        },
        .verbose => {
            const enabled = if (args.len == 0)
                !session.verbose
            else if (std.mem.eql(u8, args, "on"))
                true
            else if (std.mem.eql(u8, args, "off"))
                false
            else {
                try output.writeAll("usage: /verbose [on|off]\n");
                try output.flush();
                return true;
            };
            session.verbose = enabled;
            try output.print("verbose tool output {s}\n", .{if (enabled) "on" else "off"});
        },
        .firecrawl => {
            if (std.mem.eql(u8, args, "status")) {
                try output.print("Firecrawl web tools {s}\n", .{if (session.settings.value.firecrawl_api_key != null) "on" else "off"});
            } else if (std.mem.eql(u8, args, "clear")) {
                session.settings.value.firecrawl_api_key = null;
                try saveSettings(session);
                try output.writeAll("Firecrawl API key removed; web tools are off\n");
            } else if (args.len > 0) {
                try output.writeAll("usage: /firecrawl [status|clear]\nRun /firecrawl with no argument to paste the key into a hidden prompt.\n");
            } else {
                try output.print("{s}Paste a Firecrawl API key. The prompt is hidden and the key is stored in ~/.config/xaq/settings.json.{s}\n", .{ term.dim(), term.reset() });
                try output.flush();
                const entered = (try input_mod.readSecret(session.gpa, reader, output, "Firecrawl API key: ")) orelse {
                    try output.writeAll("Firecrawl setup cancelled\n");
                    try output.flush();
                    return true;
                };
                defer session.gpa.free(entered);
                if (!settings_mod.validFirecrawlApiKey(entered)) {
                    try output.writeAll("invalid Firecrawl API key: use a non-empty key with no spaces\n");
                    try output.flush();
                    return true;
                }
                session.settings.value.firecrawl_api_key = try session.settings.arena.allocator().dupe(u8, entered);
                try saveSettings(session);
                try output.writeAll("Firecrawl configured; web_fetch and web_search are now available\n");
            }
        },
        .agents => {
            if (session.subagent_manager) |*manager| {
                const list = try manager.formatList(session.gpa);
                defer session.gpa.free(list);
                try output.writeAll(list);
            } else {
                try output.writeAll("subagents are unavailable inside a subagent\n");
            }
        },
        .settings => {
            if (input_mod.interactive) {
                try pickSettings(session, reader);
            } else {
                try printSettings(session);
            }
        },
        .status => {
            const context_tokens = models.contextWindow(session.provider, session.model);
            try output.print(
                "  thread    {s}\n  provider  {s}\n  model     {s}\n  effort    {s}\n  fast      {s}\n  web       {s}\n  cwd       {s}\n  turns     {d}\n  context   ~{d} / {d} tokens\n",
                .{ if (session.thread) |thread| thread.id else "ephemeral", @tagName(session.provider), session.model, if (session.effort) |value| @tagName(value) else "provider-default", if (session.fast) "on" else "off", if (session.settings.value.firecrawl_api_key != null) "Firecrawl" else "off", session.cwd, session.turn, estimatedContextTokens(session), context_tokens },
            );
            try output.writeAll("  tokens    ");
            try writeTokens(output, session.usage.input);
            try output.writeAll(" input \u{b7} ");
            try writeTokens(output, session.usage.cached);
            try output.writeAll(" cached \u{b7} ");
            try writeTokens(output, session.usage.output);
            try output.writeAll(" output\n");
            if (log.activePath()) |path| try output.print("  log       {s}\n", .{path});
        },
        .compact => {
            if (try compactIfNeeded(session, true)) {
                try output.print("context compacted to ~{d} tokens\n", .{estimatedContextTokens(session)});
            } else {
                try output.print("nothing to compact (~{d} tokens)\n", .{estimatedContextTokens(session)});
            }
        },
        .clear => {
            try session.clear();
            try output.writeAll("thread cleared\n");
        },
        .new => {
            try session.newThread();
            try output.print("new thread {s}\n", .{session.thread.?.id});
        },
        .resume_thread => {
            if (args.len == 0 and input_mod.interactive) {
                try pickResume(session, reader);
            } else {
                session.resumeThread(if (args.len == 0) null else args) catch |err| {
                    try output.print("cannot resume: {s}\n", .{resumeErrorMessage(err)});
                    try output.flush();
                    return true;
                };
                try printResumed(session);
            }
        },
        .exit => return false,
    }
    try output.flush();
    return true;
}

/// Interactive model switcher: current model first, then per-provider
/// suggestions. Selection is optional sugar over `/model <id>`.
fn pickModel(session: *Session, reader: *Io.Reader) !void {
    const output = session.output;
    var values: [9][]const u8 = undefined;
    var labels: [9][]const u8 = undefined;
    var owned: [9]?[]u8 = @splat(null);
    var count: usize = 0;
    defer for (owned[0..count]) |label| {
        if (label) |text| session.gpa.free(text);
    };
    values[count] = session.model;
    owned[count] = try std.fmt.allocPrint(session.gpa, "{s} (current)", .{session.model});
    labels[count] = owned[count].?;
    count += 1;
    const default_id = defaultModel(session.provider);
    for (modelChoices(session.provider)) |choice| {
        if (count == values.len) break;
        if (std.mem.eql(u8, choice, session.model)) continue;
        values[count] = choice;
        if (std.mem.eql(u8, choice, default_id)) {
            owned[count] = try std.fmt.allocPrint(session.gpa, "{s} (default)", .{choice});
            labels[count] = owned[count].?;
        } else {
            labels[count] = choice;
        }
        count += 1;
    }
    try output.print("{s}pick a model \u{b7} enter confirms \u{b7} q cancels \u{b7} any ID via /model <id>{s}\r\n", .{ term.dim(), term.reset() });
    try output.flush();
    if (try input_mod.pick(reader, output, labels[0..count], 0)) |index| {
        const selected_model = values[index];
        const preferences = (try pickModelPreferences(session, reader, selected_model)) orelse {
            try output.print("model {s} (unchanged)\n", .{session.model});
            return;
        };
        if (!std.mem.eql(u8, selected_model, session.model)) try session.setModel(selected_model);
        if (session.effort != preferences.effort) try session.setEffort(preferences.effort);
        if (session.fast != preferences.fast) try session.setFast(preferences.fast);
        log.logf("agent", "event=model model={s}", .{session.model});
        if (models.supportsFast(session.provider, session.model)) {
            try output.print("model {s} \u{b7} effort {s} \u{b7} {s}\n", .{
                session.model,
                if (session.effort) |effort| @tagName(effort) else "provider-default",
                if (session.fast) "fast" else "normal",
            });
        } else if (models.efforts(session.provider, session.model).len > 0) {
            try output.print("model {s} \u{b7} effort {s}\n", .{
                session.model,
                if (session.effort) |effort| @tagName(effort) else "provider-default",
            });
        } else {
            try output.print("model {s}\n", .{session.model});
        }
    } else {
        try output.print("model {s} (unchanged)\n", .{session.model});
    }
}

const ModelPreferences = struct {
    effort: ?Effort,
    fast: bool,
};

/// Follow model selection with the controls that model supports. Nothing is
/// applied until every visible stage has been confirmed.
fn pickModelPreferences(session: *Session, reader: *Io.Reader, model: []const u8) !?ModelPreferences {
    var selected: ModelPreferences = .{
        .effort = null,
        // Match fx's staged picker: supported models start on Fast, while
        // Normal remains one arrow key away.
        .fast = models.supportsFast(session.provider, model),
    };
    const available_efforts = models.efforts(session.provider, model);
    if (available_efforts.len > 0) {
        var labels: [6][]const u8 = undefined;
        labels[0] = "provider-default";
        for (available_efforts, 1..) |effort, index| labels[index] = @tagName(effort);
        try session.output.print("{s}effort for {s} \u{b7} enter confirms \u{b7} q cancels{s}\r\n", .{ term.dim(), model, term.reset() });
        try session.output.flush();
        const index = (try input_mod.pick(reader, session.output, labels[0 .. available_efforts.len + 1], 0)) orelse return null;
        selected.effort = if (index == 0) null else available_efforts[index - 1];
    }
    if (models.supportsFast(session.provider, model)) {
        const labels = [_][]const u8{ "normal", "fast" };
        try session.output.print("{s}speed for {s} \u{b7} fast uses more credits \u{b7} enter confirms \u{b7} q cancels{s}\r\n", .{ term.dim(), model, term.reset() });
        try session.output.flush();
        const index = (try input_mod.pick(reader, session.output, &labels, 1)) orelse return null;
        selected.fast = index == 1;
    }
    return selected;
}

fn pickEffort(session: *Session, reader: *Io.Reader) !void {
    var labels: [6][]const u8 = undefined;
    labels[0] = "provider-default";
    var count: usize = 1;
    var initial: usize = 0;
    for (models.efforts(session.provider, session.model)) |effort| {
        labels[count] = @tagName(effort);
        if (session.effort == effort) initial = count;
        count += 1;
    }
    try session.output.print("{s}pick reasoning effort \u{b7} enter confirms \u{b7} q cancels{s}\r\n", .{ term.dim(), term.reset() });
    try session.output.flush();
    if (try input_mod.pick(reader, session.output, labels[0..count], initial)) |index| {
        const value: ?Effort = if (index == 0) null else models.efforts(session.provider, session.model)[index - 1];
        try session.setEffort(value);
        try session.output.print("effort {s}\n", .{labels[index]});
    } else {
        try session.output.print("effort {s} (unchanged)\n", .{if (session.effort) |effort| @tagName(effort) else "provider-default"});
    }
}

fn configuredCompactModel(session: *const Session) []const u8 {
    return session.settings.value.compactModel(session.provider);
}

fn effectiveCompactModel(session: *const Session) []const u8 {
    const configured = configuredCompactModel(session);
    if (std.mem.eql(u8, configured, "current")) return session.model;
    if (models.find(session.provider, configured) != null) return configured;
    return session.model;
}

fn effectiveCompactEffort(session: *const Session) ?Effort {
    const effort = session.settings.value.compactEffort(session.provider) orelse return null;
    return if (models.supportsEffort(session.provider, effectiveCompactModel(session), effort)) effort else null;
}

fn printSettings(session: *Session) !void {
    const configured_model = configuredCompactModel(session);
    try session.output.print(
        "  auto compact       {s}\n  threshold          {d}%\n  compaction model   {s}\n  compaction effort  {s}\n  subagents          {s}\n  agent concurrency  {d}\n  agent default      {s}\n",
        .{
            if (session.settings.value.auto_compact) "on" else "off",
            session.settings.value.compact_threshold_percent,
            configured_model,
            if (session.settings.value.compactEffort(session.provider)) |effort| @tagName(effort) else "provider-default",
            if (session.settings.value.subagents_enabled) "on" else "off",
            session.settings.value.subagent_max_concurrent,
            if (session.settings.value.subagent_default_background) "background" else "foreground",
        },
    );
}

fn saveSettings(session: *Session) !void {
    try settings_mod.save(session.gpa, session.io, session.home, session.settings.value);
}

fn pickSettings(session: *Session, reader: *Io.Reader) !void {
    while (true) {
        var storage: [7][160]u8 = undefined;
        const items = [_][]const u8{
            try std.fmt.bufPrint(&storage[0], "auto compact       {s}", .{if (session.settings.value.auto_compact) "on" else "off"}),
            try std.fmt.bufPrint(&storage[1], "threshold          {d}%", .{session.settings.value.compact_threshold_percent}),
            try std.fmt.bufPrint(&storage[2], "compaction model   {s}", .{configuredCompactModel(session)}),
            try std.fmt.bufPrint(&storage[3], "compaction effort  {s}", .{if (session.settings.value.compactEffort(session.provider)) |effort| @tagName(effort) else "provider-default"}),
            try std.fmt.bufPrint(&storage[4], "subagents          {s}", .{if (session.settings.value.subagents_enabled) "on" else "off"}),
            try std.fmt.bufPrint(&storage[5], "agent concurrency  {d}", .{session.settings.value.subagent_max_concurrent}),
            try std.fmt.bufPrint(&storage[6], "agent default      {s}", .{if (session.settings.value.subagent_default_background) "background" else "foreground"}),
        };
        try session.output.print("{s}settings for {s} \u{b7} enter edits \u{b7} q closes{s}\r\n", .{ term.dim(), @tagName(session.provider), term.reset() });
        try session.output.flush();
        const selected = (try input_mod.pick(reader, session.output, &items, 0)) orelse return;
        switch (selected) {
            0 => {
                const labels = [_][]const u8{ "on", "off" };
                const initial: usize = if (session.settings.value.auto_compact) 0 else 1;
                try session.output.print("{s}automatic compaction{s}\r\n", .{ term.dim(), term.reset() });
                try session.output.flush();
                if (try input_mod.pick(reader, session.output, &labels, initial)) |index| {
                    session.settings.value.auto_compact = index == 0;
                    try saveSettings(session);
                }
            },
            1 => {
                const labels = [_][]const u8{ "50%", "60%", "70%", "80%", "90%", "95%" };
                const values = [_]u8{ 50, 60, 70, 80, 90, 95 };
                var initial: usize = 0;
                for (values, 0..) |value, i| if (value == session.settings.value.compact_threshold_percent) {
                    initial = i;
                    break;
                };
                try session.output.print("{s}compact at percent of model context{s}\r\n", .{ term.dim(), term.reset() });
                try session.output.flush();
                if (try input_mod.pick(reader, session.output, &labels, initial)) |index| {
                    session.settings.value.compact_threshold_percent = values[index];
                    try saveSettings(session);
                }
            },
            2 => {
                var labels: [9][]const u8 = undefined;
                labels[0] = "current";
                var count: usize = 1;
                var initial: usize = 0;
                for (modelChoices(session.provider)) |model| {
                    labels[count] = model;
                    if (std.mem.eql(u8, configuredCompactModel(session), model)) initial = count;
                    count += 1;
                }
                try session.output.print("{s}model used to summarize old context{s}\r\n", .{ term.dim(), term.reset() });
                try session.output.flush();
                if (try input_mod.pick(reader, session.output, labels[0..count], initial)) |index| {
                    session.settings.value.setCompactModel(session.provider, labels[index]);
                    try saveSettings(session);
                }
            },
            3 => {
                var labels: [6][]const u8 = undefined;
                labels[0] = "provider-default";
                var count: usize = 1;
                var initial: usize = 0;
                const supported = models.efforts(session.provider, effectiveCompactModel(session));
                for (supported) |effort| {
                    labels[count] = @tagName(effort);
                    if (session.settings.value.compactEffort(session.provider) == effort) initial = count;
                    count += 1;
                }
                try session.output.print("{s}reasoning effort used for summaries{s}\r\n", .{ term.dim(), term.reset() });
                try session.output.flush();
                if (try input_mod.pick(reader, session.output, labels[0..count], initial)) |index| {
                    session.settings.value.setCompactEffort(session.provider, if (index == 0) null else supported[index - 1]);
                    try saveSettings(session);
                }
            },
            4 => {
                const labels = [_][]const u8{ "on", "off" };
                const initial: usize = if (session.settings.value.subagents_enabled) 0 else 1;
                try session.output.print("{s}make subagent tools available to the model{s}\r\n", .{ term.dim(), term.reset() });
                try session.output.flush();
                if (try input_mod.pick(reader, session.output, &labels, initial)) |index| {
                    session.settings.value.subagents_enabled = index == 0;
                    try saveSettings(session);
                    try applySubagentSettings(session);
                }
            },
            5 => {
                const labels = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8" };
                const initial = session.settings.value.subagent_max_concurrent - 1;
                try session.output.print("{s}maximum subagent processes running at once{s}\r\n", .{ term.dim(), term.reset() });
                try session.output.flush();
                if (try input_mod.pick(reader, session.output, &labels, initial)) |index| {
                    session.settings.value.subagent_max_concurrent = @intCast(index + 1);
                    try saveSettings(session);
                    try applySubagentSettings(session);
                }
            },
            6 => {
                const labels = [_][]const u8{ "background", "foreground" };
                const initial: usize = if (session.settings.value.subagent_default_background) 0 else 1;
                try session.output.print("{s}default when Agent omits run_in_background{s}\r\n", .{ term.dim(), term.reset() });
                try session.output.flush();
                if (try input_mod.pick(reader, session.output, &labels, initial)) |index| {
                    session.settings.value.subagent_default_background = index == 0;
                    try saveSettings(session);
                    try applySubagentSettings(session);
                }
            },
            else => unreachable,
        }
    }
}

fn applySubagentSettings(session: *Session) !void {
    if (session.subagent_manager) |*manager| try manager.configure(.{
        .enabled = session.settings.value.subagents_enabled,
        .max_concurrent = session.settings.value.subagent_max_concurrent,
        .background_by_default = session.settings.value.subagent_default_background,
    });
}

fn pickResume(session: *Session, reader: *Io.Reader) !void {
    const excluded = if (session.thread) |thread| thread.id else null;
    const summaries = try threads.list(session.gpa, session.io, session.home, session.cwd, excluded, 8);
    defer threads.freeSummaries(session.gpa, summaries);
    if (summaries.len == 0) {
        try session.output.writeAll("no other saved threads for this directory\n");
        return;
    }
    const now_seconds = Io.Clock.real.now(session.io).toSeconds();
    const items = try session.gpa.alloc([]const u8, summaries.len);
    var built: usize = 0;
    defer {
        for (items[0..built]) |item| session.gpa.free(item);
        session.gpa.free(items);
    }
    for (summaries, 0..) |summary, i| {
        var age_buffer: [24]u8 = undefined;
        const age = fmtAge(&age_buffer, now_seconds, summary.modified);
        items[i] = try std.fmt.allocPrint(session.gpa, "{s}  {s:<7} {s}", .{ summary.id, age, summary.preview });
        built += 1;
    }
    try session.output.print("{s}pick a thread \u{b7} newest first \u{b7} enter confirms \u{b7} q cancels{s}\r\n", .{ term.dim(), term.reset() });
    try session.output.flush();
    if (try input_mod.pick(reader, session.output, items, 0)) |index| {
        session.resumeThread(summaries[index].id) catch |err| {
            try session.output.print("cannot resume: {s}\n", .{resumeErrorMessage(err)});
            return;
        };
        try printResumed(session);
    } else if (session.thread) |thread| {
        try session.output.print("thread {s} (unchanged)\n", .{thread.id});
    }
}

pub fn fmtAge(buffer: []u8, now_seconds: i64, modified_ns: i96) []const u8 {
    const modified_seconds: i64 = @intCast(@divTrunc(modified_ns, std.time.ns_per_s));
    const delta = @max(now_seconds - modified_seconds, 0);
    if (delta < 90) return "now";
    if (delta < 90 * 60) return std.fmt.bufPrint(buffer, "{d}m ago", .{@divTrunc(delta, 60)}) catch "?";
    if (delta < 36 * 60 * 60) return std.fmt.bufPrint(buffer, "{d}h ago", .{@divTrunc(delta, 60 * 60)}) catch "?";
    return std.fmt.bufPrint(buffer, "{d}d ago", .{@divTrunc(delta, 24 * 60 * 60)}) catch "?";
}

/// Orientation after any resume: identity line plus the tail of the last
/// exchange, so the user knows where the thread left off.
fn printResumed(session: *Session) !void {
    const output = session.output;
    try output.print("{s}resumed {s} \u{b7} {s}/{s} \u{b7} {d} entries{s}\n", .{ term.dim(), session.thread.?.id, @tagName(session.provider), session.model, session.entries.items.len, term.reset() });
    var last_user: ?[]const u8 = null;
    var last_assistant: ?[]const u8 = null;
    for (session.entries.items) |entry| switch (entry) {
        .user => |text| last_user = text,
        .assistant => |answer| {
            if (answer.text.len > 0) last_assistant = answer.text;
        },
        .results => {},
    };
    if (last_user) |text| {
        try output.print("{s}\u{258c}", .{term.dim()});
        try writePreview(output, text);
        try output.print("{s}\n", .{term.reset()});
    }
    if (last_assistant) |text| {
        const replay_limit = 2048;
        if (text.len > replay_limit) try output.print("{s}[\u{2026}]{s} ", .{ term.dim(), term.reset() });
        var rendered = markdown.Writer.init(output);
        try rendered.write(if (text.len > replay_limit) text[text.len - replay_limit ..] else text);
        try rendered.finish();
        try output.writeByte('\n');
    }
    try output.flush();
}

const slow_tool_ms = 2000;

/// Window title: `✳ xaq · dir` while busy, `xaq · dir` at the prompt.
/// No-op unless interactive with styling enabled.
fn setTitle(session: *Session, busy: bool) !void {
    if (!input_mod.interactive) return;
    const marker: []const u8 = if (busy) "\u{2733} " else "";
    try term.title(session.output, "{s}xaq \u{b7} {s}", .{ marker, std.fs.path.basename(session.cwd) });
    try session.output.flush();
}

// The fullscreen view erases its screen on exit, taking any final
// provider diagnostic with it; main re-prints this on the real screen.
var provider_error_buffer: [512]u8 = undefined;
var provider_error_len: usize = 0;

fn rememberProviderError(status: u16, body: []const u8) void {
    var writer: Io.Writer = .fixed(&provider_error_buffer);
    writer.print("provider HTTP {d}: ", .{status}) catch {};
    for (body) |byte| {
        if (byte == '\n' or byte == '\r') break;
        if (byte < 0x20 or byte == 0x7f) continue;
        writer.writeByte(byte) catch break;
    }
    provider_error_len = writer.buffered().len;
}

pub fn lastProviderError() ?[]const u8 {
    if (provider_error_len == 0) return null;
    return provider_error_buffer[0..provider_error_len];
}

/// Human-readable messages for /resume failures; raw Zig error names
/// like NoThreads read as internals, not guidance.
fn resumeErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NoThreads => "no saved threads for this directory",
        error.FileNotFound => "no thread with that ID for this directory",
        error.InvalidThreadId => "invalid thread ID (16 URL-safe base64 characters)",
        error.InvalidThread => "thread file is corrupt or incomplete",
        else => @errorName(err),
    };
}

/// Dim aftermath line for failed tool calls: `  ↳ exit 2`. Success stays
/// silent (timing is appended inline on the call line); failures should not
/// require reading the model's reaction to be noticed. Routine read
/// truncation is model-facing pagination, not a failure, and stays silent.
fn printToolOutcome(output: *Io.Writer, text: []const u8) !void {
    var info: ?[]const u8 = null;
    if (std.mem.startsWith(u8, text, "tool error:") or std.mem.startsWith(u8, text, "invalid tool arguments")) {
        info = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
    } else {
        const trimmed = std.mem.trimEnd(u8, text, " \n");
        const last_start = if (std.mem.findScalarLast(u8, trimmed, '\n')) |pos| pos + 1 else 0;
        const last = trimmed[last_start..];
        if (last.len >= 3 and last[0] == '[' and last[last.len - 1] == ']') info = last[1 .. last.len - 1];
    }
    if (info == null) return;
    if (std.mem.startsWith(u8, info.?, "truncated:")) return;
    try output.print("{s}  \u{21b3} ", .{term.dim()});
    try writePreview(output, info.?);
    try output.print("{s}\n", .{term.reset()});
    try output.flush();
}

const verbose_lines_max = 12;

/// Indented, clamped echo of a tool result for /verbose: at most twelve
/// lines, each sanitized and cut at the preview width.
fn printToolVerbose(output: *Io.Writer, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \n");
    if (trimmed.len == 0) return;
    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        if (shown == verbose_lines_max) {
            try output.print("{s}  \u{2502} \u{2026}{s}\n", .{ term.dim(), term.reset() });
            break;
        }
        try output.print("{s}  \u{2502} ", .{term.dim()});
        try writePreview(output, line);
        try output.print("{s}\n", .{term.reset()});
        shown += 1;
    }
    try output.flush();
}

/// One dim line per call: `[bash] zig build test · 4.2s`. Previews show the
/// first line of the main argument, sanitized and clamped, never full
/// contents. The line stays open (dim, no newline) so the caller can append
/// the elapsed time once the tool returns.
fn printToolCall(output: *Io.Writer, name: []const u8, arguments: ?std.json.Value) !void {
    try output.print("{s}[{s}]", .{ term.dim(), name });
    if (arguments) |value| {
        const key = if (std.mem.eql(u8, name, "bash"))
            "command"
        else if (std.mem.eql(u8, name, "Agent"))
            "description"
        else if (std.mem.eql(u8, name, "get_subagent_result") or std.mem.eql(u8, name, "steer_subagent"))
            "agent_id"
        else
            "path";
        if (eventString(value, key)) |preview| {
            try output.writeByte(' ');
            try writePreview(output, preview);
        }
    }
    try output.flush();
}

fn isSubagentTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "Agent") or std.mem.eql(u8, name, "get_subagent_result") or std.mem.eql(u8, name, "steer_subagent");
}

fn printSubagentOutcome(output: *Io.Writer, text: []const u8) !void {
    const first_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    if (first_end == 0) return;
    try output.print("{s}  \u{21b3} ", .{term.dim()});
    try writePreview(output, text[0..first_end]);
    try output.print("{s}\n", .{term.reset()});
    try output.flush();
}

/// One dim trailer per exchange: `2.4s (↑1 ↓104) · 34%`. Time spans the
/// whole exchange including tool rounds; arrows are input and output tokens;
/// the percentage is estimated context use against the model window.
fn printExchangeStats(output: *Io.Writer, elapsed_ms: u64, used: Usage, percent: usize) !void {
    try output.print("{s}", .{term.dim()});
    try writeDuration(output, elapsed_ms);
    try output.writeAll(" (\u{2191}");
    try writeTokens(output, used.input);
    try output.writeAll(" \u{2193}");
    try writeTokens(output, used.output);
    try output.print(") \u{b7} {d}%{s}\n", .{ percent, term.reset() });
}

fn contextPercent(session: *const Session) usize {
    const window = models.contextWindow(session.provider, session.model);
    if (window == 0) return 0;
    return @min(estimatedContextTokens(session) * 100 / window, 100);
}

fn writeDuration(output: *Io.Writer, ms: u64) !void {
    if (ms < 1000) {
        try output.print("{d}ms", .{ms});
    } else if (ms < 10_000) {
        try output.print("{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 });
    } else if (ms < 60_000) {
        try output.print("{d}s", .{ms / 1000});
    } else {
        try output.print("{d}m{d}s", .{ ms / 60_000, (ms % 60_000) / 1000 });
    }
}

fn writeTokens(output: *Io.Writer, count: u64) !void {
    if (count < 1000) {
        try output.print("{d}", .{count});
    } else if (count < 100_000) {
        const tenths = (count + 50) / 100;
        try output.print("{d}.{d}k", .{ tenths / 10, tenths % 10 });
    } else if (count < 1_000_000) {
        try output.print("{d}k", .{(count + 500) / 1000});
    } else {
        const tenths = (count + 50_000) / 100_000;
        try output.print("{d}.{d}m", .{ tenths / 10, tenths % 10 });
    }
}

const preview_max_bytes = 80;

fn writePreview(output: *Io.Writer, text: []const u8) !void {
    const line_end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    const clamped = @min(line_end, preview_max_bytes);
    for (text[0..clamped]) |byte| try output.writeByte(if (byte < 0x20 or byte == 0x7f) ' ' else byte);
    if (clamped < text.len) try output.writeAll("...");
}

const compact_summary_bytes = 64 * 1024;

fn compactIfNeeded(session: *Session, force: bool) !bool {
    const entry_tokens = types.approximateTokens(session.entries.items);
    const current_tokens = estimatedContextTokens(session);
    const context_tokens: usize = models.contextWindow(session.provider, session.model);
    const threshold_tokens = context_tokens * session.settings.value.compact_threshold_percent / 100;
    if (!force) {
        if (!session.settings.value.auto_compact) return false;
        if (current_tokens <= threshold_tokens) return false;
    }
    // Forced compaction accepts tiny histories: even three oversized
    // entries can exceed the model window with no other way out.
    if (session.entries.items.len < @as(usize, if (force) 2 else 4)) return false;

    var keep_start = session.entries.items.len;
    var kept: usize = 0;
    const tail_tokens = if (force) @max(entry_tokens / 2, 1) else @max(threshold_tokens / 3, 16_000);
    while (keep_start > 0 and kept < tail_tokens) {
        keep_start -= 1;
        kept += types.approximateTokens(session.entries.items[keep_start .. keep_start + 1]);
    }
    // Keep a coherent turn boundary when the cut lands on tool results.
    while (keep_start > 0 and session.entries.items[keep_start] == .results) keep_start -= 1;
    if (keep_start == 0) return false;

    const compact_model = effectiveCompactModel(session);
    try session.trace.print("{s}[compacting \u{b7} {s}]{s}\n", .{ term.dim(), compact_model, term.reset() });
    try session.trace.flush();
    var summary: Io.Writer.Allocating = .init(session.gpa);
    defer summary.deinit();
    try summary.writer.writeAll("Compacted earlier conversation:\n");
    const generated = compactWithModel(session, compact_model, session.entries.items[0..keep_start]) catch |err| fallback: {
        // A cancelled summary must not silently fall back and keep
        // working; the caller's loop-top check handles the message.
        if (err == error.Cancelled) return false;
        log.logf("agent", "event=compact_fallback error={s}", .{@errorName(err)});
        break :fallback null;
    };
    if (generated) |text| {
        if (text.len > 0) try summary.writer.writeAll(text);
    }
    if (generated == null or summary.written().len == "Compacted earlier conversation:\n".len) {
        try session.trace.print("{s}[using local compaction fallback]{s}\n", .{ term.dim(), term.reset() });
        try session.trace.flush();
        for (session.entries.items[0..keep_start]) |entry| {
            if (summary.written().len >= compact_summary_bytes) break;
            switch (entry) {
                .user => |text| try summarySnippet(&summary.writer, "\nUser: ", text),
                .assistant => |answer| {
                    try summarySnippet(&summary.writer, "\nAssistant: ", answer.text);
                    for (answer.calls) |call| {
                        try summarySnippet(&summary.writer, "\nTool call: ", call.name);
                        try summarySnippet(&summary.writer, " ", call.arguments);
                    }
                },
                .results => |results| for (results) |result| try summarySnippet(&summary.writer, "\nTool result: ", result.text),
            }
        }
    }

    var next_arena: std.heap.ArenaAllocator = .init(session.gpa);
    // Disarm once installed: persistSnapshot failing after the swap must
    // not free the arena the session now owns.
    var installed = false;
    errdefer if (!installed) next_arena.deinit();
    const next_gpa = next_arena.allocator();
    var next_entries: std.ArrayList(Entry) = .empty;
    try next_entries.append(next_gpa, .{ .user = try next_gpa.dupe(u8, summary.written()) });
    for (session.entries.items[keep_start..]) |entry| try next_entries.append(next_gpa, try cloneEntry(next_gpa, entry));
    session.arena.deinit();
    session.arena = next_arena;
    session.entries = next_entries;
    installed = true;
    try persistSnapshot(session);
    log.logf("agent", "event=compact before_tokens={d} after_tokens={d} model={s}", .{ current_tokens, estimatedContextTokens(session), compact_model });
    return true;
}

/// Push identity and usage into the fullscreen status bar; no-op in
/// plain mode.
fn syncTui(session: *Session) void {
    if (!tui.active) return;
    const window = models.contextWindow(session.provider, session.model);
    const percent: u8 = @intCast(@min(estimatedContextTokens(session) * 100 / @max(window, 1), 100));
    const git_identity: ?tui.GitIdentity = if (session.git_status.present) .{
        .worktree = session.git_status.worktree(),
        .branch = session.git_status.branch(),
        .dirty = session.git_status.dirty,
    } else null;
    tui.noteIdentity(
        @tagName(session.provider),
        session.model,
        if (session.effort) |value| @tagName(value) else null,
        session.fast,
        if (session.thread) |thread| thread.id else null,
        git_identity,
    );
    tui.noteUsage(session.usage.input, session.usage.output, percent);
    if (session.subagent_manager) |*manager| {
        const agent_counts = manager.counts();
        tui.noteAgents(agent_counts.running, agent_counts.queued);
    } else {
        tui.noteAgents(0, 0);
    }
}

fn refreshGit(session: *Session) void {
    if (!tui.active) return;
    session.git_status = git.inspect(session.gpa, session.io, session.cwd) orelse .{};
}

fn toolMayChangeWorktree(name: []const u8) bool {
    return std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "Agent") or
        std.mem.eql(u8, name, "get_subagent_result");
}

test "git refresh follows workspace-changing tools" {
    try std.testing.expect(toolMayChangeWorktree("bash"));
    try std.testing.expect(toolMayChangeWorktree("edit"));
    try std.testing.expect(toolMayChangeWorktree("write"));
    try std.testing.expect(toolMayChangeWorktree("Agent"));
    try std.testing.expect(toolMayChangeWorktree("get_subagent_result"));
    try std.testing.expect(!toolMayChangeWorktree("read"));
    try std.testing.expect(!toolMayChangeWorktree("web_fetch"));
}

fn estimatedContextTokens(session: *const Session) usize {
    const instruction_tokens = (session.instructions.len + 3) / 4;
    return types.approximateTokens(session.entries.items) + instruction_tokens + 2048;
}

fn compactWithModel(session: *Session, model: []const u8, entries: []const Entry) !?[]const u8 {
    var request_arena: std.heap.ArenaAllocator = .init(session.gpa);
    defer request_arena.deinit();
    const fast = session.fast and models.supportsFast(session.provider, model);
    const body = try request.buildCompact(request_arena.allocator(), session.provider, model, effectiveCompactEffort(session), fast, entries);
    var sink: Io.Writer.Allocating = .init(session.gpa);
    defer sink.deinit();
    const answer = try performBody(session, model, body, &sink.writer, "compact", fast);
    if (answer.calls.len > 0 or answer.text.len == 0) return null;
    session.usage.input += answer.usage.input;
    session.usage.cached += answer.usage.cached;
    session.usage.output += answer.usage.output;
    log.logf("usage", "event=compact_tokens input={d} cached={d} output={d}", .{ answer.usage.input, answer.usage.cached, answer.usage.output });
    return answer.text;
}

fn summarySnippet(writer: *Io.Writer, prefix: []const u8, value: []const u8) !void {
    const remaining = compact_summary_bytes -| writer.buffered().len;
    if (remaining == 0) return;
    const prefix_len = @min(prefix.len, remaining);
    try writer.writeAll(prefix[0..prefix_len]);
    const after_prefix = compact_summary_bytes -| writer.buffered().len;
    const limit = @min(value.len, @min(after_prefix, 4096));
    try writer.writeAll(value[0..limit]);
    if (limit < value.len and writer.buffered().len + 3 <= compact_summary_bytes) try writer.writeAll("...");
}

fn cloneEntry(gpa: std.mem.Allocator, entry: Entry) !Entry {
    return switch (entry) {
        .user => |text| .{ .user = try gpa.dupe(u8, text) },
        .assistant => |answer| blk: {
            const calls = try gpa.alloc(ToolCall, answer.calls.len);
            for (answer.calls, 0..) |call, i| calls[i] = .{
                .id = try gpa.dupe(u8, call.id),
                .name = try gpa.dupe(u8, call.name),
                .arguments = try gpa.dupe(u8, call.arguments),
            };
            const raw = try gpa.alloc([]const u8, answer.raw_items.len);
            for (answer.raw_items, 0..) |item, i| raw[i] = try gpa.dupe(u8, item);
            break :blk .{ .assistant = .{
                .text = try gpa.dupe(u8, answer.text),
                .calls = calls,
                .raw_items = raw,
                .usage = answer.usage,
            } };
        },
        .results => |old| blk: {
            const results = try gpa.alloc(ToolResult, old.len);
            for (old, 0..) |result, i| results[i] = .{
                .id = try gpa.dupe(u8, result.id),
                .text = try gpa.dupe(u8, result.text),
            };
            break :blk .{ .results = results };
        },
    };
}

fn persistSnapshot(session: *Session) !void {
    if (session.thread) |*thread| {
        try thread.rewrite(
            session.provider,
            session.model,
            if (session.effort) |value| @tagName(value) else null,
            session.fast,
            session.cwd,
            session.entries.items,
        );
    }
}

pub fn buildRequest(gpa: std.mem.Allocator, provider: auth.Provider, model: []const u8, effort: ?Effort, fast: bool, tool_options: tools.SchemaOptions, cwd: []const u8, instructions: []const u8, entries: []const Entry) ![]u8 {
    return request.build(gpa, provider, model, effort, fast, tool_options, cwd, instructions, entries);
}

const compact_system = request.compact_system;
const compact_prompt = request.compact_prompt;

fn buildCompactRequest(gpa: std.mem.Allocator, provider: auth.Provider, model: []const u8, effort: ?Effort, fast: bool, entries: []const Entry) ![]u8 {
    return request.buildCompact(gpa, provider, model, effort, fast, entries);
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

fn eventObject(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn eventInteger(value: std.json.Value, key: []const u8) ?u64 {
    const child = switch (value) {
        .object => |o| o.get(key) orelse return null,
        else => return null,
    };
    return switch (child) {
        .integer => |n| if (n < 0) null else @intCast(n),
        else => null,
    };
}

fn performRound(session: *Session) !Assistant {
    var request_arena: std.heap.ArenaAllocator = .init(session.gpa);
    defer request_arena.deinit();
    const body = try request.build(
        request_arena.allocator(),
        session.provider,
        session.model,
        session.effort,
        session.fast,
        .{
            .web_enabled = session.settings.value.firecrawl_api_key != null,
            .write_enabled = true,
            .subagents_enabled = session.subagent_manager != null and session.settings.value.subagents_enabled,
        },
        session.cwd,
        session.instructions,
        session.entries.items,
    );
    return performBody(session, session.model, body, session.output, "round", session.fast);
}

fn performBody(session: *Session, model: []const u8, body: []const u8, output: *Io.Writer, kind: []const u8, fast: bool) !Assistant {
    log.logf("agent", "event=request kind={s} provider={s} model={s} fast={s} turn={d} entries={d} body_bytes={d}", .{ kind, @tagName(session.provider), model, if (fast) "on" else "off", session.turn, session.entries.items.len, body.len });
    var attempt: usize = 0;
    var refreshed = false;
    while (attempt < 3) : (attempt += 1) {
        var credential_arena: std.heap.ArenaAllocator = .init(session.gpa);
        defer credential_arena.deinit();
        const credential = try auth.credential(credential_arena.allocator(), session.io, session.home, session.provider);
        var decoder = Decoder.init(session.provider, session.gpa, session.allocator(), output);
        // A continuously animated placeholder covers the wait; it runs on
        // its own Io task, so it keeps moving even while the provider is
        // silent. Main rounds stop it just before the first visible
        // output; compact rounds stream into a sink, so theirs spins
        // until the round finishes.
        const compacting = std.mem.eql(u8, kind, "compact");
        decoder.stop_spinner = !compacting;
        try output.flush();
        spin.start(session.io, if (compacting) "compacting" else "thinking");
        const response = requestStream(session.gpa, session.io, session.provider, credential, body, &decoder, fast) catch |err| {
            spin.stop();
            if (err == error.Cancelled or err == error.ProviderRequestFailed) {
                // Close any active markdown style before control returns to
                // the prompt or an error line is printed.
                decoder.finishRendering() catch {};
                return err;
            }
            // A partial answer is worth keeping for a normal round; a
            // partial compaction summary is silent data loss, because it
            // would replace history it never covered.
            if (decoder.received and !compacting) {
                // A short construct may still be buffered. Flush it before
                // the interruption notice so display order stays faithful.
                try decoder.finishRendering();
                try output.writeAll("\n[stream interrupted; partial response saved]\n");
                try output.flush();
                return decoder.finish();
            }
            if (attempt + 1 < 3 and retryableTransport(err)) {
                spin.start(session.io, "retrying");
                defer spin.stop();
                try session.io.sleep(.fromSeconds(@intCast(attempt + 1)), .awake);
                if (cancel.requested()) return error.Cancelled;
                continue;
            }
            return err;
        };
        spin.stop();
        defer session.gpa.free(response.body);
        log.logf("agent", "event=response kind={s} turn={d} status={d} attempt={d}", .{ kind, session.turn, response.status, attempt + 1 });
        if (response.status >= 200 and response.status < 300) return decoder.finish();
        if (response.status == 401 and !refreshed) {
            var refresh_arena: std.heap.ArenaAllocator = .init(session.gpa);
            defer refresh_arena.deinit();
            try auth.forceRefresh(refresh_arena.allocator(), session.io, session.home, session.provider);
            refreshed = true;
            continue;
        }
        if (attempt + 1 < 3 and retryableStatus(response.status)) {
            const delay = @min(response.retry_after_seconds orelse @as(u64, @intCast(attempt + 1)), 30);
            spin.start(session.io, "retrying");
            defer spin.stop();
            try session.io.sleep(.fromSeconds(@intCast(delay)), .awake);
            if (cancel.requested()) return error.Cancelled;
            continue;
        }
        // Interactive sessions read the diagnostic in the transcript and
        // return to the prompt. One-shots propagate the error and main
        // prints the remembered line to stderr, keeping piped stdout clean.
        if (session.interactive) {
            try output.print("provider HTTP {d}: ", .{response.status});
            var safe: term.SafeWriter = .{ .output = output };
            if (providerErrorMessage(session.gpa, response.body)) |message| {
                defer session.gpa.free(message);
                try safe.write(message);
                rememberProviderError(response.status, message);
            } else {
                try safe.write(response.body);
                rememberProviderError(response.status, response.body);
            }
            try output.writeByte('\n');
            try output.flush();
        } else if (providerErrorMessage(session.gpa, response.body)) |message| {
            defer session.gpa.free(message);
            rememberProviderError(response.status, message);
        } else {
            rememberProviderError(response.status, response.body);
        }
        return error.ProviderRequestFailed;
    }
    return error.ProviderRequestFailed;
}

/// Extract the human-facing message from a JSON provider error body
/// (`error.message`, `detail`, or `message`); null keeps the raw body.
fn providerErrorMessage(gpa: std.mem.Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    for ([_][]const u8{ "error", "detail", "message" }) |key| {
        const value = eventObject(parsed.value, key) orelse continue;
        switch (value) {
            .string => |text| return gpa.dupe(u8, text) catch null,
            .object => if (eventString(value, "message")) |text| return gpa.dupe(u8, text) catch null,
            else => {},
        }
    }
    return null;
}

fn retryableTransport(err: anyerror) bool {
    return err == error.TransportFailed or err == error.InvalidHttpResponse or err == error.ReadFailed;
}

fn retryableStatus(status: u16) bool {
    return status == 408 or status == 409 or status == 425 or status == 429 or status == 500 or status == 502 or status == 503 or status == 504;
}

fn requestStream(gpa: std.mem.Allocator, io: Io, provider: auth.Provider, credential: auth.Credential, body: []const u8, decoder: *Decoder, fast: bool) !transport.Response {
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{credential.access});
    defer gpa.free(authorization);
    return switch (provider) {
        .chatgpt => transport.postStream(gpa, io, "https://chatgpt.com/backend-api/codex/responses", "application/json", &.{
            .{ .name = "Authorization", .value = authorization },
            .{ .name = "chatgpt-account-id", .value = credential.account_id orelse return error.InvalidAccessToken },
            .{ .name = "originator", .value = "xaq" },
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
            .{ .name = "User-Agent", .value = "xaq/0.1" },
        }, body, decoder, decodeLine),
        .claude => transport.postStream(gpa, io, "https://api.anthropic.com/v1/messages", "application/json", &.{
            .{ .name = "Authorization", .value = authorization },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "anthropic-beta", .value = claudeBetaHeader(fast) },
            .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" },
            .{ .name = "User-Agent", .value = "claude-cli/2.1.75" },
            .{ .name = "x-app", .value = "cli" },
        }, body, decoder, decodeLine),
        .grok => transport.postStream(gpa, io, "https://api.x.ai/v1/responses", "application/json", &.{
            .{ .name = "Authorization", .value = authorization },
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "User-Agent", .value = "xaq/0.1" },
        }, body, decoder, decodeLine),
    };
}

fn claudeBetaHeader(fast: bool) []const u8 {
    return if (fast)
        "claude-code-20250219,oauth-2025-04-20,fast-mode-2026-02-01"
    else
        "claude-code-20250219,oauth-2025-04-20";
}

fn decodeLine(context_ptr: ?*anyopaque, line: []const u8) !void {
    const decoder: *Decoder = @ptrCast(@alignCast(context_ptr.?));
    try decoder.feed(line);
}

const Decoder = struct {
    core: stream_decoder.Decoder,
    rendered: markdown.Writer,
    stop_spinner: bool = true,
    received: bool = false,

    fn init(provider: auth.Provider, parse_gpa: std.mem.Allocator, persist: std.mem.Allocator, output: *Io.Writer) Decoder {
        return .{
            .core = stream_decoder.Decoder.init(provider, parse_gpa, persist, .{}),
            .rendered = markdown.Writer.init(output),
        };
    }

    fn bind(self: *Decoder) void {
        self.core.hooks = .{
            .context = self,
            .on_output = onOutput,
            .on_delta = onDelta,
        };
    }

    fn onOutput(raw: ?*anyopaque) !void {
        const self: *Decoder = @ptrCast(@alignCast(raw.?));
        self.received = true;
        if (self.stop_spinner) spin.stop();
    }

    fn onDelta(raw: ?*anyopaque, delta: []const u8) !void {
        const self: *Decoder = @ptrCast(@alignCast(raw.?));
        try self.rendered.write(delta);
        try self.rendered.output.flush();
    }

    fn feed(self: *Decoder, line: []const u8) !void {
        self.bind();
        try self.core.feed(line);
        self.received = self.core.received;
    }

    fn finishRendering(self: *Decoder) !void {
        try self.rendered.finish();
    }

    fn finish(self: *Decoder) !Assistant {
        self.bind();
        try self.finishRendering();
        return self.core.finish();
    }
};
test "slash command lookup matches names, aliases, and unique prefixes" {
    try std.testing.expectEqual(Command.help, (try findCommand("help")).?);
    try std.testing.expectEqual(Command.model, (try findCommand("mod")).?);
    try std.testing.expectEqual(Command.fast, (try findCommand("fast")).?);
    try std.testing.expectEqual(Command.firecrawl, (try findCommand("fire")).?);
    try std.testing.expectEqual(Command.agents, (try findCommand("ag")).?);
    try std.testing.expectError(error.Ambiguous, findCommand("s"));
    try std.testing.expectEqual(Command.status, (try findCommand("stat")).?);
    try std.testing.expectEqual(Command.settings, (try findCommand("config")).?);
    try std.testing.expectEqual(Command.new, (try findCommand("new")).?);
    try std.testing.expectEqual(Command.resume_thread, (try findCommand("res")).?);
    try std.testing.expectEqual(Command.exit, (try findCommand("quit")).?);
    try std.testing.expectEqual(Command.exit, (try findCommand("q")).?);
    try std.testing.expectEqual(null, try findCommand("bogus"));
    try std.testing.expectEqual(null, try findCommand(""));
}

test "duration formatting" {
    var buffer: [64]u8 = undefined;
    inline for (.{
        .{ 0, "0ms" },
        .{ 999, "999ms" },
        .{ 2400, "2.4s" },
        .{ 12_600, "12s" },
        .{ 61_500, "1m1s" },
    }) |case| {
        var writer: Io.Writer = .fixed(&buffer);
        try writeDuration(&writer, case[0]);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}

test "token count formatting" {
    var buffer: [64]u8 = undefined;
    inline for (.{
        .{ 1, "1" },
        .{ 104, "104" },
        .{ 999, "999" },
        .{ 1049, "1.0k" },
        .{ 12_345, "12.3k" },
        .{ 123_456, "123k" },
        .{ 1_234_567, "1.2m" },
    }) |case| {
        var writer: Io.Writer = .fixed(&buffer);
        try writeTokens(&writer, case[0]);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}

test "provider defaults" {
    try std.testing.expectEqualStrings("gpt-5.6-sol", defaultModel(.chatgpt));
    try std.testing.expectEqualStrings("claude-opus-5", defaultModel(.claude));
    try std.testing.expectEqualStrings("grok-4.6", defaultModel(.grok));
}

test "compact requests omit coding tools and use the selected model" {
    const body = try buildCompactRequest(std.testing.allocator, .claude, "claude-opus-5", .low, false, &.{.{ .user = "keep this decision" }});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "claude-opus-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, compact_prompt) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"low\"") != null);

    const chatgpt = try buildCompactRequest(std.testing.allocator, .chatgpt, "gpt-5.6-sol", .low, false, &.{.{ .user = "keep this decision" }});
    defer std.testing.allocator.free(chatgpt);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt, "max_output_tokens") == null);
}

test "fast mode uses each provider's request contract" {
    const openai = try buildRequest(std.testing.allocator, .chatgpt, "gpt-5.6-sol", null, true, .{}, "/work", "", &.{});
    defer std.testing.allocator.free(openai);
    try std.testing.expect(std.mem.indexOf(u8, openai, "\"service_tier\":\"fast\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openai, "\"speed\"") == null);

    const anthropic = try buildRequest(std.testing.allocator, .claude, "claude-opus-5", null, true, .{}, "/work", "", &.{});
    defer std.testing.allocator.free(anthropic);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"speed\":\"fast\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic, "\"service_tier\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, claudeBetaHeader(true), "fast-mode-2026-02-01") != null);
    try std.testing.expect(std.mem.indexOf(u8, claudeBetaHeader(false), "fast-mode-2026-02-01") == null);

    const standard = try buildRequest(std.testing.allocator, .chatgpt, "gpt-5.6-sol", null, false, .{}, "/work", "", &.{});
    defer std.testing.allocator.free(standard);
    try std.testing.expect(std.mem.indexOf(u8, standard, "\"service_tier\"") == null);
}

test "web tools are included only after Firecrawl setup" {
    const disabled = try buildRequest(std.testing.allocator, .chatgpt, "gpt-5.6-sol", null, false, .{}, "/work", "", &.{});
    defer std.testing.allocator.free(disabled);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "web_fetch") == null);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "web_search") == null);

    const enabled = try buildRequest(std.testing.allocator, .chatgpt, "gpt-5.6-sol", null, false, .{ .web_enabled = true }, "/work", "", &.{});
    defer std.testing.allocator.free(enabled);
    try std.testing.expect(std.mem.indexOf(u8, enabled, "web_fetch") != null);
    try std.testing.expect(std.mem.indexOf(u8, enabled, "web_search") != null);
}

test "decode Responses SSE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var decoder = Decoder.init(.chatgpt, std.testing.allocator, arena.allocator(), &writer);
    try decoder.feed("data: {\"type\":\"response.output_text.delta\",\"delta\":\"done\"}");
    try decoder.feed("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}");
    try decoder.feed("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":3},\"output_tokens\":5}}}");
    const result = try decoder.finish();
    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expectEqualStrings("read", result.calls[0].name);
    try std.testing.expectEqualStrings("done", writer.buffered());
    try std.testing.expectEqual(@as(u64, 10), result.usage.input);
    try std.testing.expectEqual(@as(u64, 3), result.usage.cached);
    try std.testing.expectEqual(@as(u64, 5), result.usage.output);
}

test "decode Anthropic SSE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var decoder = Decoder.init(.claude, std.testing.allocator, arena.allocator(), &writer);
    try decoder.feed("data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}");
    try decoder.feed("data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"bash\",\"input\":{}}}");
    try decoder.feed("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}");
    try decoder.feed("data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7,\"cache_read_input_tokens\":2,\"output_tokens\":1}}}");
    try decoder.feed("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}");
    const result = try decoder.finish();
    try std.testing.expectEqualStrings("ok", result.text);
    try std.testing.expectEqualStrings("bash", result.calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", result.calls[0].arguments);
    try std.testing.expectEqual(@as(u64, 7), result.usage.input);
    try std.testing.expectEqual(@as(u64, 2), result.usage.cached);
    try std.testing.expectEqual(@as(u64, 9), result.usage.output);
}

test "stream decoder renders each Responses delta immediately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var decoder = Decoder.init(.chatgpt, std.testing.allocator, arena.allocator(), &writer);
    try decoder.feed("data: {\"type\":\"response.output_text.delta\",\"delta\":\"one\"}");
    try std.testing.expectEqualStrings("one", writer.buffered());
    try decoder.feed("data: {\"type\":\"response.output_text.delta\",\"delta\":\" two\"}");
    try std.testing.expectEqualStrings("one two", writer.buffered());
    const result = try decoder.finish();
    try std.testing.expectEqualStrings("one two", result.text);
}
