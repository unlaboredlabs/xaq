const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const cancel = @import("cancel.zig");
const context = @import("context.zig");
const input_mod = @import("input.zig");
const log = @import("log.zig");
const models = @import("models.zig");
const settings_mod = @import("settings.zig");
const term = @import("term.zig");
const threads = @import("threads.zig");
const tools = @import("tools.zig");
const transport = @import("transport.zig");
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
    first_prompt: ?[]const u8 = null,
    input: ?*Io.Reader = null,
    output: *Io.Writer,
    /// Empty means the latest thread for cwd; non-empty is an explicit ID.
    resume_id: ?[]const u8 = null,
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
    output: *Io.Writer,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    instructions: []u8,
    settings: settings_mod.Loaded,
    thread: ?threads.Thread = null,
    turn: u64 = 0,
    usage: Usage = .{},

    fn allocator(self: *Session) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *Session) void {
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
    }

    fn setEffort(self: *Session, value: ?Effort) !void {
        self.effort = value;
        if (self.thread) |*thread| try thread.appendEffort(if (value) |effort| @tagName(effort) else "default");
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
        if (self.thread) |*thread| try thread.appendReset();
    }

    fn startThread(self: *Session) !void {
        if (self.thread) |*thread| thread.deinit();
        self.thread = try threads.create(self.gpa, self.io, self.home, self.cwd, self.provider, self.model, if (self.effort) |value| @tagName(value) else null);
    }

    fn newThread(self: *Session) !void {
        self.replaceArena();
        self.turn = 0;
        self.usage = .{};
        try self.startThread();
    }

    fn resumeThread(self: *Session, requested: ?[]const u8) !void {
        var next_arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer next_arena.deinit();
        const excluded = if (requested == null) if (self.thread) |thread| thread.id else null else null;
        var loaded = try threads.load(self.gpa, next_arena.allocator(), self.io, self.home, self.cwd, requested, excluded);
        errdefer loaded.thread.deinit();
        const loaded_model = try self.gpa.dupe(u8, loaded.model);
        errdefer self.gpa.free(loaded_model);

        if (self.thread) |*thread| thread.deinit();
        self.arena.deinit();
        self.gpa.free(self.model);
        self.arena = next_arena;
        self.entries = loaded.entries;
        self.thread = loaded.thread;
        self.provider = loaded.provider;
        self.model = loaded_model;
        self.effort = if (loaded.effort) |value| Effort.parse(value) else null;
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
        .output = options.output,
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
        // Orientation matters most interactively; one-shot output stays clean.
        if (options.input != null) try printResumed(&session);
    } else if (options.input != null) {
        try session.startThread();
    }
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
        try setTitle(&session, true);
        _ = try compactIfNeeded(&session, false);
        session.turn += 1;
        const answer = performRound(&session) catch |err| switch (err) {
            error.NotLoggedIn => {
                try options.output.print("not logged in; run: xaq login {s}\n", .{@tagName(session.provider)});
                try options.output.flush();
                return;
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
        if (answer.calls.len == 0) {
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
            const reader = options.input orelse return;
            const prompt = (try readPrompt(&session, reader, null)) orelse return;
            defer gpa.free(prompt);
            try session.appendUser(prompt);
            exchange_start = Io.Clock.now(.awake, io);
            exchange_base = session.usage;
            continue;
        }

        const results = try session.allocator().alloc(ToolResult, answer.calls.len);
        for (answer.calls, 0..) |call, i| {
            const start = Io.Clock.now(.awake, io);
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const scratch_gpa = scratch.allocator();
            invoke: {
                var parsed = std.json.parseFromSlice(std.json.Value, scratch_gpa, call.arguments, .{}) catch |err| {
                    try printToolCall(options.output, i == 0, call.name, null);
                    results[i] = .{ .id = call.id, .text = try std.fmt.allocPrint(session.allocator(), "invalid tool arguments: {s}", .{@errorName(err)}) };
                    break :invoke;
                };
                defer parsed.deinit();
                try printToolCall(options.output, i == 0, call.name, parsed.value);
                const result = tools.execute(scratch_gpa, io, call.name, parsed.value) catch |err|
                    try std.fmt.allocPrint(scratch_gpa, "tool error: {s}", .{@errorName(err)});
                results[i] = .{ .id = call.id, .text = try session.allocator().dupe(u8, result) };
            }
            const elapsed_ms: i64 = @intCast(@divTrunc(Io.Clock.now(.awake, io).nanoseconds - start.nanoseconds, std.time.ns_per_ms));
            if (elapsed_ms >= slow_tool_ms) {
                try options.output.writeAll(" \u{b7} ");
                try writeDuration(options.output, @intCast(elapsed_ms));
            }
            try options.output.print("{s}\n", .{term.reset()});
            try options.output.flush();
            log.logf("tool", "event=call turn={d} name={s} args_bytes={d} result_bytes={d} ms={d}", .{ session.turn, call.name, call.arguments.len, results[i].text.len, elapsed_ms });
            try printToolOutcome(options.output, results[i].text);
        }
        try session.appendEntry(.{ .results = results });
        log.flush();
    }
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
            continue;
        }
        return line;
    }
}

const Command = enum { help, model, effort, settings, status, compact, clear, new, resume_thread, exit };

const CommandSpec = struct {
    command: Command,
    name: []const u8,
    alias: ?[]const u8 = null,
    args: []const u8 = "",
    help: []const u8,
};

const command_specs = [_]CommandSpec{
    .{ .command = .help, .name = "help", .help = "list commands" },
    .{ .command = .model, .name = "model", .args = " [ID]", .help = "pick or set the model" },
    .{ .command = .effort, .name = "effort", .args = " [LEVEL]", .help = "pick or set reasoning effort" },
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
        try output.print("ambiguous command: /{s} (try /help)\n", .{word});
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
                while (column < 18) : (column += 1) try output.writeByte(' ');
                try output.print("{s}", .{spec.help});
                if (spec.alias) |alias| try output.print(" {s}(also /{s}){s}", .{ term.dim(), alias, term.reset() });
                try output.writeByte('\n');
            }
            try output.print("{s}  enter sends \u{b7} \\ continues \u{b7} \u{2191}\u{2193} history \u{b7} tab completes \u{b7} ctrl-c ctrl-c or ctrl-d exits{s}\n", .{ term.dim(), term.reset() });
        },
        .model => if (args.len == 0) {
            if (input_mod.interactive) {
                try pickModel(session, reader);
            } else {
                try output.print("model {s} (provider default {s})\n", .{ session.model, defaultModel(session.provider) });
            }
        } else {
            try session.setModel(args);
            try output.print("model set to {s}\n", .{session.model});
        },
        .effort => if (args.len == 0) {
            if (input_mod.interactive) {
                try pickEffort(session, reader);
            } else {
                try output.print("effort {s}\n", .{if (session.effort) |value| @tagName(value) else "provider-default"});
            }
        } else {
            const value = if (std.mem.eql(u8, args, "default") or std.mem.eql(u8, args, "provider-default")) null else Effort.parse(args) orelse {
                try output.writeAll("unknown effort (try /effort)\n");
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
                "  thread    {s}\n  provider  {s}\n  model     {s}\n  effort    {s}\n  cwd       {s}\n  turns     {d}\n  context   ~{d} / {d} tokens\n",
                .{ if (session.thread) |thread| thread.id else "ephemeral", @tagName(session.provider), session.model, if (session.effort) |value| @tagName(value) else "provider-default", session.cwd, session.turn, estimatedContextTokens(session), context_tokens },
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
                    try output.print("cannot resume: {s}\n", .{@errorName(err)});
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
        if (index != 0) try session.setModel(values[index]);
        log.logf("agent", "event=model model={s}", .{session.model});
        try output.print("model {s}\n", .{session.model});
    } else {
        try output.print("model {s} (unchanged)\n", .{session.model});
    }
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
        "  auto compact       {s}\n  threshold          {d}%\n  compaction model   {s}\n  compaction effort  {s}\n",
        .{
            if (session.settings.value.auto_compact) "on" else "off",
            session.settings.value.compact_threshold_percent,
            configured_model,
            if (session.settings.value.compactEffort(session.provider)) |effort| @tagName(effort) else "provider-default",
        },
    );
}

fn saveSettings(session: *Session) !void {
    try settings_mod.save(session.gpa, session.io, session.home, session.settings.value);
}

fn pickSettings(session: *Session, reader: *Io.Reader) !void {
    while (true) {
        var storage: [4][160]u8 = undefined;
        const items = [_][]const u8{
            try std.fmt.bufPrint(&storage[0], "auto compact       {s}", .{if (session.settings.value.auto_compact) "on" else "off"}),
            try std.fmt.bufPrint(&storage[1], "threshold          {d}%", .{session.settings.value.compact_threshold_percent}),
            try std.fmt.bufPrint(&storage[2], "compaction model   {s}", .{configuredCompactModel(session)}),
            try std.fmt.bufPrint(&storage[3], "compaction effort  {s}", .{if (session.settings.value.compactEffort(session.provider)) |effort| @tagName(effort) else "provider-default"}),
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
            else => unreachable,
        }
    }
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
            try session.output.print("cannot resume: {s}\n", .{@errorName(err)});
            return;
        };
        try printResumed(session);
    } else if (session.thread) |thread| {
        try session.output.print("thread {s} (unchanged)\n", .{thread.id});
    }
}

fn fmtAge(buffer: []u8, now_seconds: i64, modified_ns: i96) []const u8 {
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
        var safe: term.SafeWriter = .{ .output = output };
        try safe.write(if (text.len > replay_limit) text[text.len - replay_limit ..] else text);
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

/// Dim aftermath line for failed tool calls: `  ↳ exit 2`. Success stays
/// silent (timing is appended inline on the call line); failures should not
/// require reading the model's reaction to be noticed.
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
    try output.print("{s}  \u{21b3} ", .{term.dim()});
    try writePreview(output, info.?);
    try output.print("{s}\n", .{term.reset()});
    try output.flush();
}

/// One dim line per call: `[bash] zig build test · 4.2s`. Previews show the
/// first line of the main argument, sanitized and clamped, never full
/// contents. The line stays open (dim, no newline) so the caller can append
/// the elapsed time once the tool returns.
fn printToolCall(output: *Io.Writer, first: bool, name: []const u8, arguments: ?std.json.Value) !void {
    if (first) try output.writeByte('\n');
    try output.print("{s}[{s}]", .{ term.dim(), name });
    if (arguments) |value| {
        const key = if (std.mem.eql(u8, name, "bash")) "command" else "path";
        if (eventString(value, key)) |preview| {
            try output.writeByte(' ');
            try writePreview(output, preview);
        }
    }
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
    if (session.entries.items.len < 4) return false;

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
    try session.output.print("{s}[compacting \u{b7} {s}]{s}\n", .{ term.dim(), compact_model, term.reset() });
    try session.output.flush();
    var summary: Io.Writer.Allocating = .init(session.gpa);
    defer summary.deinit();
    try summary.writer.writeAll("Compacted earlier conversation:\n");
    const generated = compactWithModel(session, compact_model, session.entries.items[0..keep_start]) catch |err| fallback: {
        log.logf("agent", "event=compact_fallback error={s}", .{@errorName(err)});
        break :fallback null;
    };
    if (generated) |text| {
        if (text.len > 0) try summary.writer.writeAll(text);
    }
    if (generated == null or summary.written().len == "Compacted earlier conversation:\n".len) {
        try session.output.print("{s}[using local compaction fallback]{s}\n", .{ term.dim(), term.reset() });
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
    errdefer next_arena.deinit();
    const next_gpa = next_arena.allocator();
    var next_entries: std.ArrayList(Entry) = .empty;
    try next_entries.append(next_gpa, .{ .user = try next_gpa.dupe(u8, summary.written()) });
    for (session.entries.items[keep_start..]) |entry| try next_entries.append(next_gpa, try cloneEntry(next_gpa, entry));
    session.arena.deinit();
    session.arena = next_arena;
    session.entries = next_entries;
    try persistSnapshot(session);
    log.logf("agent", "event=compact before_tokens={d} after_tokens={d} model={s}", .{ current_tokens, estimatedContextTokens(session), compact_model });
    return true;
}

fn estimatedContextTokens(session: *const Session) usize {
    const instruction_tokens = (session.instructions.len + 3) / 4;
    return types.approximateTokens(session.entries.items) + instruction_tokens + 2048;
}

fn compactWithModel(session: *Session, model: []const u8, entries: []const Entry) !?[]const u8 {
    var request_arena: std.heap.ArenaAllocator = .init(session.gpa);
    defer request_arena.deinit();
    const body = try buildCompactRequest(request_arena.allocator(), session.provider, model, effectiveCompactEffort(session), entries);
    var sink: Io.Writer.Allocating = .init(session.gpa);
    defer sink.deinit();
    const answer = try performBody(session, model, body, &sink.writer, "compact");
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
        try thread.appendReset();
        for (session.entries.items) |entry| try thread.appendEntry(entry);
    }
}

fn buildRequest(gpa: std.mem.Allocator, provider: auth.Provider, model: []const u8, effort: ?Effort, cwd: []const u8, instructions: []const u8, entries: []const Entry) ![]u8 {
    const system = try std.fmt.allocPrint(gpa, "You are a concise coding agent in {s}. Use read, bash, edit, and write to inspect and modify the host directly. Tools have full user permissions; do not ask for tool approval. Verify material changes.{s}", .{ cwd, instructions });
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
        try tools.claudeSchemas(&js);
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
            try js.objectField("instructions");
            try js.write(system);
            try js.objectField("text");
            try js.beginObject();
            try js.objectField("verbosity");
            try js.write("low");
            try js.endObject();
        }
        try js.objectField("input");
        try writeResponsesInput(&js, entries, if (provider == .grok) system else null, null);
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

const compact_system = "Summarize the supplied coding-agent history for continuation. Preserve the active goal, user requirements, decisions, files and symbols changed, commands and test results, unresolved errors, and exact identifiers needed to continue. Drop repetition and obsolete exploration. Output only a concise factual handoff; do not call tools.";
const compact_prompt = "Create the continuation handoff now.";

fn buildCompactRequest(gpa: std.mem.Allocator, provider: auth.Provider, model: []const u8, effort: ?Effort, entries: []const Entry) ![]u8 {
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
            try js.objectField("instructions");
            try js.write(compact_system);
            try js.objectField("text");
            try js.beginObject();
            try js.objectField("verbosity");
            try js.write("low");
            try js.endObject();
        }
        try js.objectField("input");
        try writeResponsesInput(&js, entries, if (provider == .grok) compact_system else null, compact_prompt);
    }
    try js.endObject();
    return out.toOwnedSlice();
}

fn writeResponsesInput(js: *std.json.Stringify, entries: []const Entry, system: ?[]const u8, final_user: ?[]const u8) !void {
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

fn writeClaudeMessages(js: *std.json.Stringify, entries: []const Entry, final_user: ?[]const u8) !void {
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
    const body = try buildRequest(
        request_arena.allocator(),
        session.provider,
        session.model,
        session.effort,
        session.cwd,
        session.instructions,
        session.entries.items,
    );
    return performBody(session, session.model, body, session.output, "round");
}

fn performBody(session: *Session, model: []const u8, body: []const u8, output: *Io.Writer, kind: []const u8) !Assistant {
    log.logf("agent", "event=request kind={s} provider={s} model={s} turn={d} entries={d} body_bytes={d}", .{ kind, @tagName(session.provider), model, session.turn, session.entries.items.len, body.len });
    var attempt: usize = 0;
    var refreshed = false;
    while (attempt < 3) : (attempt += 1) {
        var credential_arena: std.heap.ArenaAllocator = .init(session.gpa);
        defer credential_arena.deinit();
        const credential = try auth.credential(credential_arena.allocator(), session.io, session.home, session.provider);
        var decoder = Decoder.init(session.provider, session.gpa, session.allocator(), output);
        // An animated placeholder covers the silent reasoning gap; every
        // streamed event advances one frame, and it is erased before the
        // first visible output. Compact rounds stream into a sink, so
        // their spinner draws on the terminal and spins until finished.
        if (term.enabled) {
            if (std.mem.eql(u8, kind, "compact")) {
                decoder.spinner_output = session.output;
                decoder.spinner_label = "compacting";
            }
            decoder.indicator = true;
            try decoder.tickSpinner();
        }
        const response = requestStream(session.gpa, session.io, session.provider, credential, body, &decoder) catch |err| {
            decoder.clearIndicator() catch {};
            if (err == error.Cancelled or err == error.ProviderRequestFailed) return err;
            if (decoder.received) {
                try output.writeAll("\n[stream interrupted; partial response saved]\n");
                try output.flush();
                return decoder.finish();
            }
            if (attempt + 1 < 3 and retryableTransport(err)) {
                try printRetry(session, attempt + 1);
                try session.io.sleep(.fromSeconds(@intCast(attempt + 1)), .awake);
                continue;
            }
            return err;
        };
        decoder.clearIndicator() catch {};
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
            try printRetry(session, delay);
            try session.io.sleep(.fromSeconds(@intCast(delay)), .awake);
            continue;
        }
        try output.print("provider HTTP {d}: ", .{response.status});
        var safe: term.SafeWriter = .{ .output = output };
        if (providerErrorMessage(session.gpa, response.body)) |message| {
            defer session.gpa.free(message);
            try safe.write(message);
        } else {
            try safe.write(response.body);
        }
        try output.writeByte('\n');
        try output.flush();
        return error.ProviderRequestFailed;
    }
    return error.ProviderRequestFailed;
}

/// Dim one-liner before a backoff sleep, so retries never look like a hang.
fn printRetry(session: *Session, seconds: u64) !void {
    if (!term.enabled) return;
    try session.output.print("{s}[retrying in {d}s]{s}\n", .{ term.dim(), seconds, term.reset() });
    try session.output.flush();
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

fn requestStream(gpa: std.mem.Allocator, io: Io, provider: auth.Provider, credential: auth.Credential, body: []const u8, decoder: *Decoder) !transport.Response {
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
            .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20" },
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

fn decodeLine(context_ptr: ?*anyopaque, line: []const u8) !void {
    const decoder: *Decoder = @ptrCast(@alignCast(context_ptr.?));
    try decoder.feed(line);
}

const StreamingClaudeCall = struct {
    index: i64,
    id: []const u8,
    name: []const u8,
    args: Io.Writer.Allocating,
};

const Decoder = struct {
    provider: auth.Provider,
    parse_gpa: std.mem.Allocator,
    persist: std.mem.Allocator,
    safe: term.SafeWriter,
    text: Io.Writer.Allocating,
    calls: std.ArrayList(ToolCall) = .empty,
    raw: std.ArrayList([]const u8) = .empty,
    claude_calls: std.ArrayList(StreamingClaudeCall) = .empty,
    usage: Usage = .{},
    received: bool = false,
    indicator: bool = false,
    spinner_frame: usize = 0,
    spinner_output: ?*Io.Writer = null,
    spinner_label: []const u8 = "thinking",

    const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    fn spinnerTarget(self: *Decoder) *Io.Writer {
        return self.spinner_output orelse self.safe.output;
    }

    /// Redraw the animated `⠙ thinking` placeholder in place; each streamed
    /// event advances one frame, so silent reasoning still shows activity.
    fn tickSpinner(self: *Decoder) !void {
        if (!self.indicator) return;
        const target = self.spinnerTarget();
        try target.print("\r{s}{s} {s}{s}", .{ term.dim(), spinner_frames[self.spinner_frame], self.spinner_label, term.reset() });
        try target.flush();
        self.spinner_frame = (self.spinner_frame + 1) % spinner_frames.len;
    }

    /// Erase the placeholder line.
    fn clearIndicator(self: *Decoder) !void {
        if (!self.indicator) return;
        self.indicator = false;
        const target = self.spinnerTarget();
        try target.writeAll("\r\x1b[K");
        try target.flush();
    }

    /// Erase the placeholder before visible output lands on the same
    /// writer. When the spinner draws elsewhere (compact rounds stream
    /// into a sink) it keeps spinning until the round finishes.
    fn clearBeforeOutput(self: *Decoder) !void {
        if (self.spinner_output != null) return;
        try self.clearIndicator();
    }

    fn init(provider: auth.Provider, parse_gpa: std.mem.Allocator, persist: std.mem.Allocator, output: *Io.Writer) Decoder {
        return .{
            .provider = provider,
            .parse_gpa = parse_gpa,
            .persist = persist,
            .safe = .{ .output = output },
            .text = .init(persist),
        };
    }

    fn feed(self: *Decoder, raw_line: []const u8) !void {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const data = std.mem.trimStart(u8, line[5..], " ");
        if (std.mem.eql(u8, data, "[DONE]") or data.len == 0) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.parse_gpa, data, .{}) catch return;
        defer parsed.deinit();
        self.received = true;
        try self.tickSpinner();
        if (self.provider == .claude) {
            try self.feedClaude(parsed.value, data);
        } else {
            try self.feedResponses(parsed.value, data);
        }
    }

    fn feedResponses(self: *Decoder, value: std.json.Value, data: []const u8) !void {
        const kind = eventString(value, "type") orelse return;
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            const delta = eventString(value, "delta") orelse return;
            try self.clearBeforeOutput();
            try self.text.writer.writeAll(delta);
            try self.safe.write(delta);
            try self.safe.output.flush();
        } else if (std.mem.eql(u8, kind, "response.output_item.done")) {
            try self.clearBeforeOutput();
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
            try self.clearBeforeOutput();
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
                const part = eventString(delta, "text") orelse return;
                try self.clearBeforeOutput();
                try self.text.writer.writeAll(part);
                try self.safe.write(part);
                try self.safe.output.flush();
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

    fn finish(self: *Decoder) !Assistant {
        try self.clearIndicator();
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

test "slash command lookup matches names, aliases, and unique prefixes" {
    try std.testing.expectEqual(Command.help, (try findCommand("help")).?);
    try std.testing.expectEqual(Command.model, (try findCommand("mod")).?);
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
    const body = try buildCompactRequest(std.testing.allocator, .claude, "claude-opus-5", .low, &.{.{ .user = "keep this decision" }});
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "claude-opus-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, compact_prompt) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"low\"") != null);

    const chatgpt = try buildCompactRequest(std.testing.allocator, .chatgpt, "gpt-5.6-sol", .low, &.{.{ .user = "keep this decision" }});
    defer std.testing.allocator.free(chatgpt);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt, "max_output_tokens") == null);
}

test "spinner ticks frames in place and clears" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var decoder = Decoder.init(.chatgpt, std.testing.allocator, arena.allocator(), &writer);
    try decoder.tickSpinner(); // inactive: draws nothing
    try std.testing.expectEqualStrings("", writer.buffered());
    decoder.indicator = true;
    try decoder.tickSpinner();
    try decoder.tickSpinner();
    try decoder.clearIndicator();
    try decoder.clearIndicator(); // idempotent
    try std.testing.expectEqualStrings("\r⠋ thinking\r⠙ thinking\r\x1b[K", writer.buffered());
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
