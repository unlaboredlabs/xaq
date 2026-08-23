const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const agent = @import("agent.zig");
const auth = @import("auth.zig");
const image_input = @import("image.zig");
const input_mod = @import("input.zig");
const log = @import("log.zig");
const models = @import("models.zig");
const state_mod = @import("state.zig");
const term = @import("term.zig");
const threads = @import("threads.zig");
const tui = @import("tui.zig");
const update = @import("update.zig");

const version_string = build_options.version;
const build_git_sha = build_options.git_sha;

const OutputFormat = enum {
    plain,
    json,
    streaming_json,

    fn parse(value: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, value, "plain")) return .plain;
        if (std.mem.eql(u8, value, "json")) return .json;
        if (std.mem.eql(u8, value, "streaming-json")) return .streaming_json;
        return null;
    }
};

const usage =
    \\xaq — minimal subscription coding harness
    \\
    \\  xaq login <chatgpt|claude|grok>
    \\  xaq logout <chatgpt|claude|grok>
    \\  xaq update
    \\  xaq [--provider NAME] [--model ID] [--image FILE] [--effort LEVEL] [--fast] [--plain] [--no-save] [--output-format FORMAT] [PROMPT]
    \\  xaq --continue | --resume THREAD
    \\  xaq threads
    \\  xaq --version
    \\
    \\Attach up to four PNG, JPEG, GIF, or WebP files with repeated
    \\-i/--image options. A positional PROMPT starts an interactive session
    \\and submits it. -p/--prompt PROMPT or piped stdin runs once. Use `--`
    \\before a positional prompt that starts with a dash. Without a prompt,
    \\xaq starts an interactive session: /help lists commands; /exit or
    \\ctrl-d leaves.
    \\Use --no-save for an interactive conversation that stays in memory.
    \\Output formats for one-shot runs: plain (default), json, streaming-json.
    \\Defaults: the last selection made interactively via /model, /effort,
    \\or /fast (initially provider=chatgpt with its default model); flags
    \\override for one invocation without changing what is remembered.
    \\A recognized --model ID implies its provider, so --provider is only
    \\needed for model IDs xaq does not know.
    \\
;

const ResolvedSelection = struct {
    model: ?[]const u8,
    effort: ?agent.Effort,
    fast: bool,
};

/// Flags beat memory; memory beats built-in defaults. The remembered effort
/// and fast flag belong to the remembered model, so an explicit --model
/// keeps them out of the resolution.
fn applyRememberedSelection(remembered: ?state_mod.Selection, model: ?[]const u8, effort: ?agent.Effort, fast: bool) ResolvedSelection {
    const as_given: ResolvedSelection = .{ .model = model, .effort = effort, .fast = fast };
    if (model != null) return as_given;
    const selection = remembered orelse return as_given;
    return .{
        .model = selection.model,
        .effort = effort orelse selection.effort,
        .fast = fast or selection.fast,
    };
}

/// A remembered provider whose login has since been removed must not turn
/// every new session into a startup error; prefer a still-connected one.
/// Credential-store read failures fall through to the remembered choice.
fn connectedProvider(gpa: std.mem.Allocator, io: Io, home: []const u8, last: auth.Provider) auth.Provider {
    if (auth.isLoggedIn(gpa, io, home, last) catch true) return last;
    for (std.enums.values(auth.Provider)) |candidate| {
        if (auth.isLoggedIn(gpa, io, home, candidate) catch false) return candidate;
    }
    return last;
}

/// Options whose next argument is a value, for the help/version pre-scan.
fn takesValue(argument: []const u8) bool {
    const value_options = [_][]const u8{ "--provider", "--model", "--image", "-i", "--effort", "--output-format", "--resume", "--subagent-control", "-p", "--prompt" };
    for (value_options) |option| {
        if (std.mem.eql(u8, argument, option)) return true;
    }
    return false;
}

const StartupEnvironment = struct {
    home: []const u8,
    log_value: ?[]const u8,
    log_scopes: ?[]const u8,
    no_color: ?[]const u8,
    term: ?[]const u8,
    plain: ?[]const u8,
};

/// Read only the six environment values xaq uses. The full Init path copies
/// every environment entry into a hash map before main; avoiding that work is
/// especially valuable for commands which immediately print and exit.
fn scanStartupEnvironment(environ: std.process.Environ) !StartupEnvironment {
    var home: ?[]const u8 = null;
    var log_value: ?[]const u8 = null;
    var log_scopes: ?[]const u8 = null;
    var no_color: ?[]const u8 = null;
    var terminal: ?[]const u8 = null;
    var plain: ?[]const u8 = null;

    for (environ.block.view().slice) |entry_z| {
        const entry = std.mem.span(entry_z);
        const equals = std.mem.findScalar(u8, entry, '=') orelse continue;
        const name = entry[0..equals];
        const value = entry[equals + 1 ..];
        if (std.mem.eql(u8, name, "HOME")) {
            home = value;
        } else if (std.mem.eql(u8, name, "XAQ_LOG")) {
            log_value = value;
        } else if (std.mem.eql(u8, name, "XAQ_LOG_SCOPES")) {
            log_scopes = value;
        } else if (std.mem.eql(u8, name, "NO_COLOR")) {
            no_color = value;
        } else if (std.mem.eql(u8, name, "TERM")) {
            terminal = value;
        } else if (std.mem.eql(u8, name, "XAQ_PLAIN")) {
            plain = value;
        }
    }

    return .{
        .home = home orelse return error.HomeNotSet,
        .log_value = log_value,
        .log_scopes = log_scopes,
        .no_color = no_color,
        .term = terminal,
        .plain = plain,
    };
}

const EarlyAction = enum { invalid_arguments, continue_startup, help, version };

fn findEarlyAction(args: std.process.Args) EarlyAction {
    var iterator = std.process.Args.Iterator.init(args);
    if (!iterator.skip()) return .invalid_arguments;
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, "--")) break;
        if (takesValue(argument)) {
            _ = iterator.skip();
            continue;
        }
        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) return .help;
        if (std.mem.eql(u8, argument, "-V") or std.mem.eql(u8, argument, "--version")) return .version;
    }
    return .continue_startup;
}

fn writeEarlyAction(io: Io, action: EarlyAction) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &buffer);
    const output = &stdout_file.interface;
    switch (action) {
        .help => try output.writeAll(usage),
        .version => try output.print("xaq {s}\n", .{version_string}),
        else => unreachable,
    }
    // Match the regular path's deferred best-effort flush (notably EPIPE).
    output.flush() catch {};
}

const JsonOutput = struct {
    output: *Io.Writer,
    format: OutputFormat,

    fn event(raw: ?*anyopaque, value: agent.Event) !void {
        const self: *JsonOutput = @ptrCast(@alignCast(raw.?));
        try self.writeEvent(value);
    }

    fn writeEvent(self: *JsonOutput, event_value: agent.Event) !void {
        if (self.format == .json and event_value != .completed) return;
        switch (event_value) {
            .run_start => |started| {
                try self.output.writeAll("{\"type\":\"start\",\"provider\":");
                try writeJsonString(self.output, @tagName(started.provider));
                try self.output.writeAll(",\"model\":");
                try writeJsonString(self.output, started.model);
                try self.output.writeAll(",\"thread_id\":");
                try writeOptionalString(self.output, started.thread_id);
            },
            .round_start => |started| {
                try self.output.print("{{\"type\":\"turn_start\",\"turn\":{d}", .{started.number});
            },
            .text_delta => |delta| {
                try self.output.writeAll("{\"type\":\"text\",\"data\":");
                try writeJsonString(self.output, delta);
            },
            .tool_start => |call| {
                try self.output.writeAll("{\"type\":\"tool_call\",\"id\":");
                try writeJsonString(self.output, call.id);
                try self.output.writeAll(",\"name\":");
                try writeJsonString(self.output, call.name);
                try self.output.writeAll(",\"arguments\":");
                try writeJsonString(self.output, call.arguments);
            },
            .tool_finish => |finished| {
                try self.output.writeAll("{\"type\":\"tool_result\",\"id\":");
                try writeJsonString(self.output, finished.call.id);
                try self.output.writeAll(",\"name\":");
                try writeJsonString(self.output, finished.call.name);
                try self.output.writeAll(",\"result\":");
                try writeJsonString(self.output, finished.result);
                try self.output.print(",\"duration_ms\":{d}", .{finished.duration_ms});
            },
            .usage => |value| {
                try self.output.writeAll("{\"type\":\"usage\",\"usage\":");
                try writeUsage(self.output, value);
            },
            .completed => |completed| {
                try self.output.writeAll(if (self.format == .streaming_json) "{\"type\":\"end\",\"text\":" else "{\"text\":");
                try writeJsonString(self.output, completed.text);
                try self.output.writeAll(",\"stop_reason\":");
                try writeJsonString(self.output, @tagName(completed.stop_reason));
                try self.output.writeAll(",\"provider\":");
                try writeJsonString(self.output, @tagName(completed.provider));
                try self.output.writeAll(",\"model\":");
                try writeJsonString(self.output, completed.model);
                try self.output.writeAll(",\"thread_id\":");
                try writeOptionalString(self.output, completed.thread_id);
                try self.output.writeAll(",\"usage\":");
                try writeUsage(self.output, completed.usage);
                try self.output.print(",\"num_turns\":{d},\"tool_calls\":{d}", .{ completed.rounds, completed.tool_calls });
            },
        }
        try self.output.writeAll("}\n");
        try self.output.flush();
    }

    fn writeError(self: *JsonOutput, message: []const u8) !void {
        try self.output.writeAll("{\"type\":\"error\",\"message\":");
        try writeJsonString(self.output, message);
        try self.output.writeAll("}\n");
        try self.output.flush();
    }
};

fn writeJsonString(output: *Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, output);
}

fn writeOptionalString(output: *Io.Writer, value: ?[]const u8) !void {
    if (value) |text_value| try writeJsonString(output, text_value) else try output.writeAll("null");
}

fn writeUsage(output: *Io.Writer, usage_value: agent.Usage) !void {
    try output.print("{{\"input_tokens\":{d},\"cached_input_tokens\":{d},\"output_tokens\":{d}}}", .{
        usage_value.input,
        usage_value.cached,
        usage_value.output,
    });
}

fn writeRunError(format: OutputFormat, json_output: *JsonOutput, human_output: *Io.Writer, message: []const u8) !void {
    if (format == .plain) {
        try human_output.print("{s}\n", .{message});
        try human_output.flush();
    } else {
        try json_output.writeError(message);
    }
}

/// User mistakes end here: one line to stderr, exit 2, no stack trace.
/// process.exit skips defers, so buffered trace lines flush here too.
fn fatal(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    log.shutdown();
    input_mod.restoreEcho();
    var buffer: [2048]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &buffer);
    stderr_file.interface.print("xaq: " ++ fmt ++ "\nrun 'xaq --help' for usage\n", args) catch {};
    stderr_file.interface.flush() catch {};
    std.process.exit(2);
}

fn writeStartupTime(output: *Io.Writer, elapsed_ns: i96) !void {
    const hundredths: u64 = @intCast(@max(0, @divTrunc(elapsed_ns, std.time.ns_per_ms / 100)));
    try output.print("startup {d}.{d:0>2} ms", .{ hundredths / 100, hundredths % 100 });
}

fn writeUpdateSuccess(output: *Io.Writer, current_version: []const u8, status: update.Status, release_version: ?[]const u8) !void {
    const target_version = release_version orelse current_version;
    switch (status) {
        .already_current => try output.print("xaq {s} is already up to date\n", .{target_version}),
        .updated => if (release_version) |version|
            try output.print("updated xaq {s} to {s}\n", .{ current_version, version })
        else
            try output.writeAll("updated xaq to the latest edge release\n"),
    }
}

pub fn main(minimal: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;
    const early_action = findEarlyAction(minimal.args);
    if (early_action == .invalid_arguments) return error.InvalidArguments;
    const environment = try scanStartupEnvironment(minimal.environ);

    var threaded: Io.Threaded = .init(gpa, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();
    if (early_action != .continue_startup and !log.requested(environment.log_value)) {
        return writeEarlyAction(io, early_action);
    }

    const startup_start = Io.Clock.now(.awake, io);
    const args = try minimal.args.toSlice(gpa);
    defer gpa.free(args);
    const home = environment.home;
    log.init(gpa, io, home, environment.log_value, environment.log_scopes);
    defer log.shutdown();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const output = &stdout_file.interface;
    defer output.flush() catch {};
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const errout = &stderr_file.interface;
    defer errout.flush() catch {};
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_file: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const input = &stdin_file.interface;

    var scan: usize = 1;
    while (scan < args.len) : (scan += 1) {
        const argument = args[scan];
        if (std.mem.eql(u8, argument, "--")) break;
        // Option values are never help flags: `xaq -p --help` sends the
        // literal text, `xaq --model --help` treats it as a model ID.
        if (takesValue(argument)) {
            scan += 1;
            continue;
        }
        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) {
            try output.writeAll(usage);
            return;
        }
        if (std.mem.eql(u8, argument, "-V") or std.mem.eql(u8, argument, "--version")) {
            try output.print("xaq {s}\n", .{version_string});
            return;
        }
    }
    if (args.len > 1 and (std.mem.eql(u8, args[1], "login") or std.mem.eql(u8, args[1], "logout"))) {
        if (args.len != 3) fatal(io, "{s} takes exactly one provider (chatgpt, claude, or grok)", .{args[1]});
        const provider = auth.Provider.parse(args[2]) orelse
            fatal(io, "unknown provider '{s}' (chatgpt, claude, or grok)", .{args[2]});
        if (std.mem.eql(u8, args[1], "login")) {
            // Styling detection enables the waiting spinner during device
            // polling; login otherwise never reaches the interactive setup.
            const stdout_tty = Io.File.stdout().isTty(io) catch false;
            const stdin_tty = Io.File.stdin().isTty(io) catch false;
            term.detect(stdout_tty, environment.no_color, environment.term);
            input_mod.interactive = stdout_tty and stdin_tty;
            auth.login(gpa, io, home, provider, input, output) catch |err| switch (err) {
                error.EndOfStream => fatal(io, "login cancelled (no input)", .{}),
                error.OAuthStateMismatch => fatal(io, "login state mismatch; paste the URL from the same login attempt", .{}),
                error.InvalidAuthorizationInput => fatal(io, "that doesn't look like a callback URL or authorization code", .{}),
                error.ProviderRequestFailed => {
                    // The HTTP status and body were already printed.
                    output.flush() catch {};
                    std.process.exit(1);
                },
                else => return err,
            };
        } else {
            try output.print("{s}\n", .{if (try auth.logout(gpa, io, home, provider)) "credentials removed" else "not logged in"});
        }
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "threads")) {
        if (args.len != 2) fatal(io, "threads takes no arguments", .{});
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = cwd_buf[0..try std.process.currentPath(io, &cwd_buf)];
        const summaries = try threads.list(gpa, io, home, cwd, null, threads.retained_threads);
        defer threads.freeSummaries(gpa, summaries);
        if (summaries.len == 0) {
            try output.writeAll("no saved threads for this directory\n");
            return;
        }
        const now_seconds = Io.Clock.real.now(io).toSeconds();
        for (summaries) |summary| {
            var age_buffer: [24]u8 = undefined;
            try output.print("{s}  {s:<7} {s}\n", .{ summary.id, agent.fmtAge(&age_buffer, now_seconds, summary.modified), summary.preview });
        }
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "update")) {
        if (args.len != 2) fatal(io, "update takes no arguments", .{});
        var update_result = update.run(gpa, io, build_git_sha) catch |err| {
            const message: []const u8 = switch (err) {
                error.UnsupportedPlatform => "no edge build is available for this platform",
                error.CurlNotFound => "curl is required to download the edge release",
                error.DownloadFailed => "could not download the edge release",
                error.ReleaseTooLarge => "the edge release exceeds the download size limit",
                error.MalformedManifest => "the edge manifest is malformed",
                error.MissingAsset => "the edge manifest has no entry for this platform",
                error.ChecksumMismatch => "the downloaded edge binary failed checksum verification",
                error.PermissionDenied, error.ReadOnlyFileSystem => "cannot replace this executable; check its directory permissions",
                else => @errorName(err),
            };
            errout.print("xaq: update failed: {s}\n", .{message}) catch {};
            errout.flush() catch {};
            std.process.exit(1);
        };
        defer update_result.deinit(gpa);
        try writeUpdateSuccess(output, version_string, update_result.status, update_result.version);
        return;
    }

    var provider_arg: ?auth.Provider = null;
    var model: ?[]const u8 = null;
    var effort: ?agent.Effort = null;
    var fast = false;
    var prompt: ?[]const u8 = null;
    var run_once = false;
    var resume_id: ?[]const u8 = null;
    var subagent_control: ?[]const u8 = null;
    var output_format: OutputFormat = .plain;
    var save_thread = true;
    var image_paths: std.ArrayList([]const u8) = .empty;
    defer image_paths.deinit(gpa);
    var plain = if (environment.plain) |value| log.isTruthy(std.mem.trim(u8, value, " \t")) else false;
    var dash_prompt: ?[]u8 = null;
    defer if (dash_prompt) |value| gpa.free(value);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--provider")) {
            i += 1;
            if (i >= args.len) fatal(io, "--provider needs a value", .{});
            provider_arg = auth.Provider.parse(args[i]) orelse
                fatal(io, "unknown provider '{s}' (chatgpt, claude, or grok)", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--model")) {
            i += 1;
            if (i >= args.len) fatal(io, "--model needs a value", .{});
            model = args[i];
        } else if (std.mem.eql(u8, args[i], "-i") or std.mem.eql(u8, args[i], "--image")) {
            i += 1;
            if (i >= args.len) fatal(io, "{s} needs a file path", .{args[i - 1]});
            try image_paths.append(gpa, args[i]);
            if (image_paths.items.len > image_input.max_images_per_prompt) fatal(io, "at most 4 images can be attached to one prompt", .{});
        } else if (std.mem.eql(u8, args[i], "--effort")) {
            i += 1;
            if (i >= args.len) fatal(io, "--effort needs a value", .{});
            effort = agent.Effort.parse(args[i]) orelse
                fatal(io, "effort must be low, medium, high, xhigh, or max (got '{s}')", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--output-format")) {
            i += 1;
            if (i >= args.len) fatal(io, "--output-format needs a value", .{});
            output_format = OutputFormat.parse(args[i]) orelse
                fatal(io, "output format must be plain, json, or streaming-json (got '{s}')", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--plain")) {
            plain = true;
        } else if (std.mem.eql(u8, args[i], "--no-save")) {
            save_thread = false;
        } else if (std.mem.eql(u8, args[i], "--fast")) {
            fast = true;
        } else if (std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "--continue")) {
            resume_id = "";
        } else if (std.mem.eql(u8, args[i], "--resume")) {
            i += 1;
            if (i >= args.len) fatal(io, "--resume needs a thread ID", .{});
            resume_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--subagent-control")) {
            i += 1;
            if (i >= args.len) fatal(io, "--subagent-control needs a path", .{});
            subagent_control = args[i];
        } else if (std.mem.eql(u8, args[i], "-p") or std.mem.eql(u8, args[i], "--prompt")) {
            i += 1;
            if (i >= args.len) fatal(io, "{s} needs a value", .{args[i - 1]});
            prompt = args[i];
            run_once = true;
        } else if (std.mem.eql(u8, args[i], "--")) {
            // Everything after `--` is the prompt, even if it starts with a dash.
            i += 1;
            if (i >= args.len) fatal(io, "nothing follows --", .{});
            var joined: Io.Writer.Allocating = .init(gpa);
            defer joined.deinit();
            for (args[i..], 0..) |argument, j| {
                if (j > 0) try joined.writer.writeByte(' ');
                try joined.writer.writeAll(argument);
            }
            dash_prompt = try joined.toOwnedSlice();
            prompt = dash_prompt.?;
            break;
        } else if (args[i].len > 0 and args[i][0] != '-' and prompt == null) {
            prompt = args[i];
        } else if (args[i].len > 0 and args[i][0] == '-') {
            fatal(io, "unknown option '{s}'", .{args[i]});
        } else {
            fatal(io, "unexpected argument '{s}' (prompt already given)", .{args[i]});
        }
    }

    // Fresh sessions start from the last explicit interactive selection.
    // Flags override without changing the memory, and a resumed thread
    // restores its own model/effort/fast, so memory stays out of resumes.
    var remembered = try state_mod.load(gpa, io, home);
    defer remembered.deinit();
    var provider: auth.Provider = provider_arg orelse .chatgpt;
    if (resume_id == null) {
        if (provider_arg == null) {
            // A catalog --model ID names its provider; treat the pair as
            // one choice. Unknown IDs keep the remembered provider so
            // snapshot names remain usable.
            if (if (model) |id| models.findAny(id) else null) |profile| {
                provider = profile.provider;
            } else if (remembered.value.provider) |last| {
                provider = connectedProvider(gpa, io, home, last);
            }
        }
        const resolved = applyRememberedSelection(remembered.value.selection(provider), model, effort, fast);
        model = resolved.model;
        effort = resolved.effort;
        fast = resolved.fast;
    }

    const stdin_tty = Io.File.stdin().isTty(io) catch false;
    var stdin_prompt: ?[]u8 = null;
    defer if (stdin_prompt) |value| gpa.free(value);
    var combined_prompt: ?[]u8 = null;
    defer if (combined_prompt) |value| gpa.free(value);
    if (!stdin_tty) {
        run_once = true;
        // Limit + 1 so input of exactly the limit is accepted; the limit
        // firing without the extra byte cannot distinguish "full" from
        // "overfull".
        const piped = input.allocRemaining(gpa, .limited(input_mod.max_input_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => fatal(io, "piped input exceeds 4 MiB", .{}),
            else => return err,
        };
        stdin_prompt = piped;
        if (piped.len > input_mod.max_input_bytes) fatal(io, "piped input exceeds 4 MiB", .{});
        if (piped.len > 0 and piped[0] == '/') {
            // A convincing hallucinated "command response" is worse than
            // a warning: slash commands only exist interactively.
            errout.writeAll("xaq: note: piped input goes to the model as a prompt; slash commands only work interactively\n") catch {};
            errout.flush() catch {};
        }
        if (piped.len > 0) {
            combined_prompt = if (prompt) |argument|
                try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ piped, argument })
            else
                try gpa.dupe(u8, piped);
            prompt = combined_prompt.?;
        }
    }
    if (prompt == null and !stdin_tty and image_paths.items.len == 0) {
        fatal(io, "no prompt: pass PROMPT, use -p, or pipe input (stdin is not a terminal)", .{});
    }
    if (prompt == null and !stdin_tty) prompt = "";

    const interactive = !run_once;
    if (interactive and output_format != .plain) fatal(io, "--output-format requires -p/--prompt or piped input", .{});
    if (!save_thread and resume_id != null) fatal(io, "--no-save cannot be combined with --continue or --resume", .{});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    const images = image_input.loadPaths(gpa, io, cwd, image_paths.items) catch |err| switch (err) {
        error.FileNotFound => fatal(io, "image file not found", .{}),
        error.ImageTooLarge => fatal(io, "each image must be 5 MiB or smaller", .{}),
        error.EmptyImage => fatal(io, "image file is empty", .{}),
        error.UnsupportedImage => fatal(io, "image must be PNG, JPEG, GIF, or WebP", .{}),
        error.TooManyImages => fatal(io, "at most 4 images can be attached to one prompt", .{}),
        else => return err,
    };
    defer image_input.freeImages(gpa, images);
    image_input.validateProvider(provider, images) catch fatal(io, "Grok accepts PNG and JPEG images only", .{});
    // Styling follows stdout alone so one-shot runs on a terminal are
    // dimmed consistently; the raw-mode editor still needs both ends.
    const stdout_tty = Io.File.stdout().isTty(io) catch false;
    term.detect(stdout_tty and output_format == .plain, environment.no_color, environment.term);
    var discard_buffer: [1024]u8 = undefined;
    var discard: Io.Writer.Discarding = .init(&discard_buffer);
    var agent_output: *Io.Writer = if (output_format == .plain) output else &discard.writer;
    if (interactive) {
        input_mod.interactive = stdout_tty and stdin_tty;
        // Fullscreen is the default session view on a terminal; --plain or
        // XAQ_PLAIN=1 keeps the classic inline flow, and any error falls
        // back to it silently.
        if (shouldEnterFullscreen(input_mod.interactive, plain)) {
            if (tui.enter(gpa, io, output)) |tee| {
                agent_output = tee;
            } else |err| switch (err) {
                error.TerminalTooSmall => try output.print("{s}terminal too small for fullscreen; using inline mode{s}\n", .{ term.dim(), term.reset() }),
                error.TerminalSizeUnavailable => {},
                else => return err,
            }
        }
        // An ephemeral session keeps prompt recall in memory but must not
        // load or append the cross-session history file.
        if (input_mod.interactive and save_thread) input_mod.initHistory(gpa, io, home);
        const startup_elapsed = Io.Clock.now(.awake, io).nanoseconds - startup_start.nanoseconds;
        if (tui.active) {
            try agent_output.print("{s}/help for commands · ctrl-v or drop images · wheel or pgup/pgdn history · ctrl-d exits{s}\n", .{ term.dim(), term.reset() });
        } else {
            try agent_output.print("{s}xaq · {s}/{s} · {s}{s}\n{s}/help for commands · ctrl-v or drop images · ctrl-d exits{s}\n", .{
                term.bold(),  @tagName(provider), model orelse agent.defaultModel(provider),
                cwd,          term.reset(),       term.dim(),
                term.reset(),
            });
        }
        try agent_output.flush();
        if (tui.active) {
            var startup_storage: [32]u8 = undefined;
            var startup_output: Io.Writer = .fixed(&startup_storage);
            try writeStartupTime(&startup_output, startup_elapsed);
            tui.showStartupHint(startup_output.buffered());
        }
    }
    defer tui.exit();
    // Echo stays off for the whole interactive session so inline type-ahead
    // cannot smear escape sequences into streamed output. Fullscreen keeps
    // the editor active while the agent runs. No-op when not interactive.
    const echo_guard = input_mod.muteEcho();
    defer if (echo_guard) |guard| guard.restore();
    var json_output: JsonOutput = .{ .output = output, .format = output_format };
    agent.run(gpa, io, .{
        .home = home,
        .cwd = cwd,
        .provider = provider,
        .model = model orelse agent.defaultModel(provider),
        .effort = effort,
        .fast = fast,
        .first_prompt = prompt,
        .first_images = images,
        .input = if (interactive) input else null,
        .output = agent_output,
        // Piped one-shots keep stdout as pure answer text; tool call and
        // compaction trace lines go to stderr instead.
        .tool_trace = if (!interactive and (!stdout_tty or output_format != .plain)) errout else null,
        .resume_id = resume_id,
        .save_thread = save_thread,
        .subagent_control = subagent_control,
        .events = if (output_format == .plain) null else .{ .context = &json_output, .emit = JsonOutput.event },
    }) catch |err| {
        // The catch may end in process.exit, which skips defers: leave
        // the alternate screen first so messages land on the real one,
        // and restore terminal echo so the shell is usable afterwards.
        tui.exit();
        if (echo_guard) |guard| guard.restore();
        log.shutdown();
        output.flush() catch {};
        switch (err) {
            error.NotLoggedIn => {
                var message_buffer: [128]u8 = undefined;
                const message = try std.fmt.bufPrint(&message_buffer, "not logged in; run: xaq login {s}", .{@tagName(provider)});
                try writeRunError(output_format, &json_output, output, message);
                std.process.exit(1);
            },
            error.NoThreads => {
                try writeRunError(output_format, &json_output, output, "no saved thread for this directory");
                std.process.exit(1);
            },
            error.InvalidEffortForModel => {
                try writeRunError(output_format, &json_output, output, "selected reasoning effort is not supported by this model");
                std.process.exit(1);
            },
            error.InvalidFastForModel => {
                try writeRunError(output_format, &json_output, output, "fast mode is not supported by this provider/model");
                std.process.exit(1);
            },
            error.InvalidThreadId => {
                if (output_format == .plain) fatal(io, "invalid thread ID (16 URL-safe base64 characters; see /resume)", .{});
                try json_output.writeError("invalid thread ID (16 URL-safe base64 characters; see /resume)");
                std.process.exit(2);
            },
            error.InvalidThread => {
                if (output_format == .plain) fatal(io, "thread file is missing required metadata or is corrupt", .{});
                try json_output.writeError("thread file is missing required metadata or is corrupt");
                std.process.exit(2);
            },
            error.ProviderRequestFailed => {
                // One-shots reach here (interactive sessions return to the
                // prompt); the diagnostic goes to stderr so piped stdout
                // stays pure answer text.
                if (agent.lastProviderError()) |message| {
                    errout.print("{s}\n", .{message}) catch {};
                    errout.flush() catch {};
                    if (output_format != .plain) try json_output.writeError(message);
                } else if (output_format != .plain) {
                    try json_output.writeError("provider request failed");
                }
                std.process.exit(1);
            },
            // One-shot run interrupted by ctrl-c: conventional 128+SIGINT.
            error.Interrupted => {
                if (output_format != .plain) try json_output.writeError("interrupted");
                std.process.exit(130);
            },
            // Transport-level failures that survived the retry policy are
            // environmental, not bugs: one line, no stack trace.
            error.ReadFailed, error.WriteFailed, error.TransportFailed, error.InvalidHttpResponse => {
                try writeRunError(output_format, &json_output, output, "network or stream failure; check connectivity and try again");
                std.process.exit(1);
            },
            error.InstructionsTooLarge, error.InstructionFileTooLarge => {
                if (output_format != .plain) {
                    try json_output.writeError("AGENTS.md instructions exceed the size limits (64 KiB per file, 256 KiB total)");
                    std.process.exit(2);
                }
                fatal(io, "AGENTS.md instructions exceed the size limits (64 KiB per file, 256 KiB total)", .{});
            },
            else => return err,
        }
    };
}

fn shouldEnterFullscreen(interactive: bool, plain: bool) bool {
    return interactive and term.presentation and !plain;
}

test "fullscreen requires terminal presentation support" {
    const previous = term.presentation;
    defer term.presentation = previous;

    term.presentation = true;
    try std.testing.expect(shouldEnterFullscreen(true, false));
    try std.testing.expect(!shouldEnterFullscreen(true, true));
    term.presentation = false;
    try std.testing.expect(!shouldEnterFullscreen(true, false));
}

test {
    _ = @import("agent.zig");
    _ = @import("cancel.zig");
    _ = @import("context.zig");
    _ = @import("image.zig");
    _ = @import("input.zig");
    _ = @import("log.zig");
    _ = @import("models.zig");
    _ = @import("settings.zig");
    _ = @import("spin.zig");
    _ = @import("state.zig");
    _ = @import("term.zig");
    _ = @import("tools.zig");
    _ = @import("transport.zig");
    _ = @import("tui.zig");
    _ = @import("threads.zig");
    _ = @import("types.zig");
    _ = @import("update.zig");
}

test "startup time has two decimal places in milliseconds" {
    var storage: [32]u8 = undefined;
    var output: Io.Writer = .fixed(&storage);

    try writeStartupTime(&output, 12_349_999);

    try std.testing.expectEqualStrings("startup 12.34 ms", output.buffered());
}

test "early action preserves option-value and delimiter semantics" {
    const help = [_][*:0]const u8{ "xaq", "--help" };
    try std.testing.expectEqual(EarlyAction.help, findEarlyAction(.{ .vector = &help }));

    const version_first = [_][*:0]const u8{ "xaq", "--version", "--help" };
    try std.testing.expectEqual(EarlyAction.version, findEarlyAction(.{ .vector = &version_first }));

    const prompt_value = [_][*:0]const u8{ "xaq", "-p", "--help" };
    try std.testing.expectEqual(EarlyAction.continue_startup, findEarlyAction(.{ .vector = &prompt_value }));

    const delimiter = [_][*:0]const u8{ "xaq", "--", "--help" };
    try std.testing.expectEqual(EarlyAction.continue_startup, findEarlyAction(.{ .vector = &delimiter }));

    const empty = [_][*:0]const u8{};
    try std.testing.expectEqual(EarlyAction.invalid_arguments, findEarlyAction(.{ .vector = &empty }));
}

test "remembered selection yields to flags and fills unset dimensions" {
    const remembered: state_mod.Selection = .{ .model = "claude-fable-5", .effort = .high, .fast = true };

    // No flags: the whole remembered tuple applies.
    const from_memory = applyRememberedSelection(remembered, null, null, false);
    try std.testing.expectEqualStrings("claude-fable-5", from_memory.model.?);
    try std.testing.expectEqual(agent.Effort.high, from_memory.effort.?);
    try std.testing.expect(from_memory.fast);

    // --model pins the whole tuple to the flags; remembered effort/fast
    // belong to the remembered model and must not leak onto another one.
    const flagged_model = applyRememberedSelection(remembered, "claude-sonnet-5", null, false);
    try std.testing.expectEqualStrings("claude-sonnet-5", flagged_model.model.?);
    try std.testing.expectEqual(null, flagged_model.effort);
    try std.testing.expect(!flagged_model.fast);

    // --effort overrides just that dimension of the remembered tuple.
    const flagged_effort = applyRememberedSelection(remembered, null, .low, false);
    try std.testing.expectEqualStrings("claude-fable-5", flagged_effort.model.?);
    try std.testing.expectEqual(agent.Effort.low, flagged_effort.effort.?);
    try std.testing.expect(flagged_effort.fast);

    // Nothing remembered: flags pass through untouched.
    const no_memory = applyRememberedSelection(null, null, .medium, true);
    try std.testing.expectEqual(null, no_memory.model);
    try std.testing.expectEqual(agent.Effort.medium, no_memory.effort.?);
    try std.testing.expect(no_memory.fast);
}

test "startup environment keeps the last value and requires home" {
    const entries = [_:null]?[*:0]const u8{
        "HOME=/first",
        "TERM=dumb",
        "HOME=/last",
        "XAQ_LOG=off",
        "XAQ_PLAIN=1",
    };
    const environment = try scanStartupEnvironment(.{ .block = .{ .slice = &entries } });
    try std.testing.expectEqualStrings("/last", environment.home);
    try std.testing.expectEqualStrings("dumb", environment.term.?);
    try std.testing.expectEqualStrings("off", environment.log_value.?);
    try std.testing.expectEqualStrings("1", environment.plain.?);

    const no_home = [_:null]?[*:0]const u8{"TERM=dumb"};
    try std.testing.expectError(error.HomeNotSet, scanStartupEnvironment(.{ .block = .{ .slice = &no_home } }));
}

test "update success reports numbered versions" {
    var storage: [128]u8 = undefined;

    var updated: Io.Writer = .fixed(&storage);
    try writeUpdateSuccess(&updated, "0.1.0-edge.6", .updated, "0.1.0-edge.7");
    try std.testing.expectEqualStrings("updated xaq 0.1.0-edge.6 to 0.1.0-edge.7\n", updated.buffered());

    var current: Io.Writer = .fixed(&storage);
    try writeUpdateSuccess(&current, "0.1.0-edge.7", .already_current, "0.1.0-edge.7");
    try std.testing.expectEqualStrings("xaq 0.1.0-edge.7 is already up to date\n", current.buffered());
}

test "output formats parse only documented values" {
    try std.testing.expectEqual(OutputFormat.plain, OutputFormat.parse("plain").?);
    try std.testing.expectEqual(OutputFormat.json, OutputFormat.parse("json").?);
    try std.testing.expectEqual(OutputFormat.streaming_json, OutputFormat.parse("streaming-json").?);
    try std.testing.expectEqual(null, OutputFormat.parse("jsonl"));
}

test "json output is one final result object" {
    var storage: [1024]u8 = undefined;
    var output: Io.Writer = .fixed(&storage);
    var json_output: JsonOutput = .{ .output = &output, .format = .json };

    try json_output.writeEvent(.{ .run_start = .{ .provider = .chatgpt, .model = "gpt-test", .thread_id = null } });
    try json_output.writeEvent(.{ .text_delta = "ignored delta" });
    try json_output.writeEvent(.{ .completed = .{
        .text = "done\ncleanly",
        .provider = .chatgpt,
        .model = "gpt-test",
        .thread_id = null,
        .usage = .{ .input = 12, .cached = 3, .output = 4 },
        .rounds = 2,
        .tool_calls = 1,
        .stop_reason = .completed,
    } });

    try std.testing.expectEqualStrings(
        "{\"text\":\"done\\ncleanly\",\"stop_reason\":\"completed\",\"provider\":\"chatgpt\",\"model\":\"gpt-test\",\"thread_id\":null,\"usage\":{\"input_tokens\":12,\"cached_input_tokens\":3,\"output_tokens\":4},\"num_turns\":2,\"tool_calls\":1}\n",
        output.buffered(),
    );
}

test "json output identifies an interrupted response" {
    var storage: [512]u8 = undefined;
    var output: Io.Writer = .fixed(&storage);
    var json_output: JsonOutput = .{ .output = &output, .format = .json };

    try json_output.writeEvent(.{ .completed = .{
        .text = "partial",
        .provider = .claude,
        .model = "claude-test",
        .thread_id = "thread",
        .usage = .{ .input = 3, .output = 1 },
        .rounds = 1,
        .tool_calls = 0,
        .stop_reason = .stream_interrupted,
    } });

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, std.mem.trimEnd(u8, output.buffered(), "\n"), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("partial", parsed.value.object.get("text").?.string);
    try std.testing.expectEqualStrings("stream_interrupted", parsed.value.object.get("stop_reason").?.string);
}

test "streaming json emits typed lines and an authoritative end" {
    var storage: [2048]u8 = undefined;
    var output: Io.Writer = .fixed(&storage);
    var json_output: JsonOutput = .{ .output = &output, .format = .streaming_json };
    const call: agent.ToolCall = .{ .id = "call_1", .name = "bash", .arguments = "{\"command\":\"pwd\"}" };

    try json_output.writeEvent(.{ .run_start = .{ .provider = .grok, .model = "grok-test", .thread_id = "thread" } });
    try json_output.writeEvent(.{ .round_start = .{ .number = 1 } });
    try json_output.writeEvent(.{ .text_delta = "checking" });
    try json_output.writeEvent(.{ .tool_start = call });
    try json_output.writeEvent(.{ .tool_finish = .{ .call = call, .result = "ok", .duration_ms = 7 } });
    try json_output.writeEvent(.{ .usage = .{ .input = 5, .cached = 2, .output = 1 } });
    try json_output.writeEvent(.{ .completed = .{
        .text = "finished",
        .provider = .grok,
        .model = "grok-test",
        .thread_id = "thread",
        .usage = .{ .input = 5, .cached = 2, .output = 1 },
        .rounds = 1,
        .tool_calls = 1,
        .stop_reason = .stream_interrupted,
    } });

    var lines = std.mem.splitScalar(u8, output.buffered(), '\n');
    const expected_types = [_][]const u8{ "start", "turn_start", "text", "tool_call", "tool_result", "usage", "end" };
    for (expected_types) |expected| {
        const line = lines.next().?;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(expected, parsed.value.object.get("type").?.string);
        if (std.mem.eql(u8, expected, "end")) {
            try std.testing.expectEqualStrings("stream_interrupted", parsed.value.object.get("stop_reason").?.string);
        }
    }
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expectEqual(null, lines.next());
}
