const std = @import("std");
const Io = std.Io;
const agent = @import("agent.zig");
const auth = @import("auth.zig");

const usage =
    \\xaq — minimal subscription coding harness
    \\
    \\  xaq login <chatgpt|claude|grok>
    \\  xaq [--provider NAME] [--model ID] [-p PROMPT]
    \\
    \\Defaults: provider=chatgpt; model follows the provider.
    \\Interactive input exits on an empty line or /exit.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    const home = init.environ_map.get("HOME") orelse return error.HomeNotSet;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const output = &stdout_file.interface;
    defer output.flush() catch {};
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_file: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const input = &stdin_file.interface;

    if (args.len > 1 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        try output.writeAll(usage);
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "login")) {
        if (args.len != 3) {
            try output.writeAll(usage);
            return error.InvalidArguments;
        }
        const provider = auth.Provider.parse(args[2]) orelse return error.UnknownProvider;
        try auth.login(gpa, io, home, provider, input, output);
        return;
    }

    var provider: auth.Provider = .chatgpt;
    var model: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--provider")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            provider = auth.Provider.parse(args[i]) orelse return error.UnknownProvider;
        } else if (std.mem.eql(u8, args[i], "--model")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            model = args[i];
        } else if (std.mem.eql(u8, args[i], "-p") or std.mem.eql(u8, args[i], "--prompt")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            prompt = args[i];
        } else return error.InvalidArguments;
    }

    const interactive = prompt == null;
    if (interactive) {
        try output.print("xaq · {s}/{s}\n> ", .{ @tagName(provider), model orelse agent.defaultModel(provider) });
        try output.flush();
        const line = (try input.takeDelimiter('\n')) orelse return;
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0) return;
        prompt = try gpa.dupe(u8, trimmed);
    }

    const credentials = auth.credential(gpa, io, home, provider) catch |err| {
        if (err == error.NotLoggedIn) {
            try output.print("not logged in; run: xaq login {s}\n", .{@tagName(provider)});
            return;
        }
        return err;
    };
    try agent.run(gpa, io, provider, credentials, model orelse agent.defaultModel(provider), prompt.?, if (interactive) input else null, output);
}

test {
    _ = @import("tools.zig");
    _ = @import("transport.zig");
}
