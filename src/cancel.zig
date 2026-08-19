const std = @import("std");

/// Per-run cancellation state. Embedded agents keep one token each, so a
/// cancellation in one host session cannot stop another session's request or
/// tool process.
pub const Token = struct {
    requested_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    child_group: std.atomic.Value(std.posix.pid_t) = std.atomic.Value(std.posix.pid_t).init(0),

    pub fn request(self: *Token) void {
        const already_requested = self.requested_flag.swap(true, .seq_cst);
        const pgid = self.child_group.load(.seq_cst);
        if (pgid > 0) std.posix.kill(-pgid, if (already_requested) .KILL else .TERM) catch {};
    }

    pub fn isRequested(self: *const Token) bool {
        return self.requested_flag.load(.seq_cst);
    }

    pub fn reset(self: *Token) void {
        self.requested_flag.store(false, .seq_cst);
    }

    pub fn setChild(self: *Token, pid: std.posix.pid_t) void {
        // Do not clear an already-delivered cancellation here. Callers reset
        // only after handling it; clearing during a retry can lose it.
        self.child_group.store(pid, .seq_cst);
    }

    pub fn clearChild(self: *Token) void {
        self.child_group.store(0, .seq_cst);
    }
};

var process_token: Token = .{};

pub fn processToken() *Token {
    return &process_token;
}

fn handle(_: std.posix.SIG) callconv(.c) void {
    // First ctrl-c asks nicely; a second one, while the first is still
    // unhandled, escalates to KILL for children that ignore TERM. Only
    // async-signal-safe calls here.
    process_token.request();
}

pub const Scope = struct {
    old: std.posix.Sigaction = undefined,
    installed: bool = false,

    pub fn install() Scope {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handle },
            .mask = std.posix.sigemptyset(),
            // SA_RESTART: without it the signal interrupts unrelated
            // blocked reads (stdin, curl stdout) with EINTR, which
            // surfaces as spurious ReadFailed after a clean cancel.
            .flags = std.posix.SA.RESTART,
        };
        var scope: Scope = .{};
        process_token.reset();
        std.posix.sigaction(.INT, &action, &scope.old);
        scope.installed = true;
        return scope;
    }

    pub fn deinit(self: *Scope) void {
        clearChild();
        if (self.installed) std.posix.sigaction(.INT, &self.old, null);
        self.installed = false;
    }
};

pub fn setChild(pid: std.posix.pid_t) void {
    process_token.setChild(pid);
}

pub fn clearChild() void {
    process_token.clearChild();
}

pub fn requested() bool {
    return process_token.isRequested();
}

pub fn reset() void {
    process_token.reset();
}

test "tokens cancel independently" {
    var first: Token = .{};
    var second: Token = .{};
    first.request();
    try std.testing.expect(first.isRequested());
    try std.testing.expect(!second.isRequested());
    first.reset();
    try std.testing.expect(!first.isRequested());
}
