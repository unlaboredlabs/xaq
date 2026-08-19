const std = @import("std");
const Io = std.Io;
const agent = @import("agent.zig");
const auth = @import("auth.zig");
const input_mod = @import("input.zig");
const log = @import("log.zig");
const term = @import("term.zig");
const tui = @import("tui.zig");

const version_string = "0.1.0";

const usage =
    \\xaq — minimal subscription coding harness
    \\
    \\  xaq login <chatgpt|claude|grok>
    \\  xaq logout <chatgpt|claude|grok>
    \\  xaq [--provider NAME] [--model ID] [--effort LEVEL] [--plain] [PROMPT]
    \\  xaq --continue | --resume THREAD
    \\  xaq --version
    \\
    \\A PROMPT argument (or -p PROMPT), or piped stdin, runs once; use
    \\`--` before a prompt that starts with a dash.
    \\Without a prompt, xaq starts an interactive session: /help lists
    \\commands; /exit, ctrl-d, or ctrl-c pressed twice leaves.
    \\Defaults: provider=chatgpt; model follows the provider.
    \\
;

/// User mistakes end here: one line to stderr, exit 2, no stack trace.
fn fatal(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buffer: [2048]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &buffer);
    stderr_file.interface.print("xaq: " ++ fmt ++ "\nrun 'xaq --help' for usage\n", args) catch {};
    stderr_file.interface.flush() catch {};
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    const home = init.environ_map.get("HOME") orelse return error.HomeNotSet;
    log.init(gpa, io, home, init.environ_map.get("XAQ_LOG"), init.environ_map.get("XAQ_LOG_SCOPES"));
    defer log.shutdown();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const output = &stdout_file.interface;
    defer output.flush() catch {};
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_file: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const input = &stdin_file.interface;

    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--")) break;
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
            term.detect(stdout_tty, init.environ_map.get("NO_COLOR"), init.environ_map.get("TERM"));
            try auth.login(gpa, io, home, provider, input, output);
        } else {
            try output.print("{s}\n", .{if (try auth.logout(gpa, io, home, provider)) "credentials removed" else "not logged in"});
        }
        return;
    }

    var provider: auth.Provider = .chatgpt;
    var model: ?[]const u8 = null;
    var effort: ?agent.Effort = null;
    var prompt: ?[]const u8 = null;
    var resume_id: ?[]const u8 = null;
    var plain = init.environ_map.get("XAQ_PLAIN") != null;
    var dash_prompt: ?[]u8 = null;
    defer if (dash_prompt) |value| gpa.free(value);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--provider")) {
            i += 1;
            if (i >= args.len) fatal(io, "--provider needs a value", .{});
            provider = auth.Provider.parse(args[i]) orelse
                fatal(io, "unknown provider '{s}' (chatgpt, claude, or grok)", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--model")) {
            i += 1;
            if (i >= args.len) fatal(io, "--model needs a value", .{});
            model = args[i];
        } else if (std.mem.eql(u8, args[i], "--effort")) {
            i += 1;
            if (i >= args.len) fatal(io, "--effort needs a value", .{});
            effort = agent.Effort.parse(args[i]) orelse
                fatal(io, "effort must be low, medium, high, xhigh, or max (got '{s}')", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--plain")) {
            plain = true;
        } else if (std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "--continue")) {
            resume_id = "";
        } else if (std.mem.eql(u8, args[i], "--resume")) {
            i += 1;
            if (i >= args.len) fatal(io, "--resume needs a thread ID", .{});
            resume_id = args[i];
        } else if (std.mem.eql(u8, args[i], "-p") or std.mem.eql(u8, args[i], "--prompt")) {
            i += 1;
            if (i >= args.len) fatal(io, "{s} needs a value", .{args[i - 1]});
            prompt = args[i];
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

    const stdin_tty = Io.File.stdin().isTty(io) catch false;
    var stdin_prompt: ?[]u8 = null;
    defer if (stdin_prompt) |value| gpa.free(value);
    var combined_prompt: ?[]u8 = null;
    defer if (combined_prompt) |value| gpa.free(value);
    if (!stdin_tty) {
        const piped = try input.allocRemaining(gpa, .limited(4 * 1024 * 1024));
        stdin_prompt = piped;
        if (piped.len > 0) {
            combined_prompt = if (prompt) |argument|
                try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ piped, argument })
            else
                try gpa.dupe(u8, piped);
            prompt = combined_prompt.?;
        }
    }
    if (prompt == null and !stdin_tty) {
        fatal(io, "no prompt: pass PROMPT, use -p, or pipe input (stdin is not a terminal)", .{});
    }

    const interactive = prompt == null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    // Styling follows stdout alone so one-shot runs on a terminal are
    // dimmed consistently; the raw-mode editor still needs both ends.
    const stdout_tty = Io.File.stdout().isTty(io) catch false;
    term.detect(stdout_tty, init.environ_map.get("NO_COLOR"), init.environ_map.get("TERM"));
    var agent_output: *Io.Writer = output;
    if (interactive) {
        input_mod.interactive = stdout_tty and stdin_tty;
        // Fullscreen is the default session view on a terminal; --plain or
        // XAQ_PLAIN=1 keeps the classic inline flow, and any error falls
        // back to it silently.
        if (input_mod.interactive and !plain) {
            if (tui.enter(gpa, io, output)) |tee| {
                agent_output = tee;
            } else |_| {}
        }
        if (tui.active) {
            try agent_output.print("{s}/help for commands · pgup/pgdn history · ctrl-d exits{s}\n", .{ term.dim(), term.reset() });
        } else {
            try agent_output.print("{s}xaq · {s}/{s} · {s}{s}\n{s}/help for commands · ctrl-d exits{s}\n", .{
                term.bold(),  @tagName(provider), model orelse agent.defaultModel(provider),
                cwd,          term.reset(),       term.dim(),
                term.reset(),
            });
        }
        try agent_output.flush();
    }
    defer tui.exit();
    // Echo stays off for the whole interactive session so type-ahead
    // (arrow keys, stray keystrokes) cannot smear `^[[A`-style junk into
    // streamed output; the editor re-echoes queued input at the next
    // prompt. No-op when not interactive.
    const echo_guard = input_mod.muteEcho();
    defer if (echo_guard) |guard| guard.restore();
    agent.run(gpa, io, .{
        .home = home,
        .cwd = cwd,
        .provider = provider,
        .model = model orelse agent.defaultModel(provider),
        .effort = effort,
        .first_prompt = prompt,
        .input = if (interactive) input else null,
        .output = agent_output,
        .resume_id = resume_id,
    }) catch |err| {
        // The catch may end in process.exit, which skips defers; leave
        // the alternate screen first so messages land on the real one.
        tui.exit();
        output.flush() catch {};
        switch (err) {
            error.NotLoggedIn => {
                try output.print("not logged in; run: xaq login {s}\n", .{@tagName(provider)});
                output.flush() catch {};
                std.process.exit(1);
            },
            error.NoThreads => {
                try output.writeAll("no saved thread for this directory\n");
                output.flush() catch {};
                std.process.exit(1);
            },
            error.InvalidEffortForModel => {
                try output.writeAll("selected reasoning effort is not supported by this model\n");
                output.flush() catch {};
                std.process.exit(1);
            },
            error.InvalidThreadId => fatal(io, "invalid thread ID (16 URL-safe base64 characters; see /resume)", .{}),
            error.InvalidThread => fatal(io, "thread file is missing required metadata or is corrupt", .{}),
            // The agent already printed the provider error body.
            error.ProviderRequestFailed => std.process.exit(1),
            // One-shot run interrupted by ctrl-c: conventional 128+SIGINT.
            error.Interrupted => std.process.exit(130),
            else => return err,
        }
    };
}

test {
    _ = @import("agent.zig");
    _ = @import("cancel.zig");
    _ = @import("context.zig");
    _ = @import("git.zig");
    _ = @import("input.zig");
    _ = @import("log.zig");
    _ = @import("markdown.zig");
    _ = @import("models.zig");
    _ = @import("request.zig");
    _ = @import("settings.zig");
    _ = @import("spin.zig");
    _ = @import("stream.zig");
    _ = @import("subagents.zig");
    _ = @import("term.zig");
    _ = @import("tools.zig");
    _ = @import("transport.zig");
    _ = @import("tui.zig");
    _ = @import("threads.zig");
    _ = @import("types.zig");
}
