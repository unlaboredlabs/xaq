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

    /// Keep Ctrl-C responsive during provider backoff and login polling.
    pub fn sleep(self: *const Token, io: std.Io, duration: std.Io.Duration) !void {
        if (self.isRequested()) return error.Cancelled;
        const deadline = std.Io.Clock.now(.awake, io).addDuration(duration);
        while (true) {
            if (self.isRequested()) return error.Cancelled;
            const remaining = std.Io.Clock.now(.awake, io).durationTo(deadline);
            if (remaining.nanoseconds <= 0) return;
            try io.sleep(.fromNanoseconds(@min(remaining.nanoseconds, 50 * std.time.ns_per_ms)), .awake);
        }
    }

    pub fn reset(self: *Token) void {
        self.requested_flag.store(false, .seq_cst);
    }

    pub fn setChild(self: *Token, pid: std.posix.pid_t) void {
        // Do not clear an already-delivered cancellation here. Callers reset
        // only after handling it; clearing during a retry can lose it.
        self.child_group.store(pid, .seq_cst);
        // Cancellation may have arrived between spawning and registration.
        // The requester could not signal this group until it was published.
        if (self.isRequested()) std.posix.kill(-pid, .TERM) catch {};
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

test "backoff sleep stops promptly when cancelled" {
    var token: Token = .{};
    const Request = struct {
        fn run(io: std.Io, value: *Token) void {
            io.sleep(.fromMilliseconds(20), .awake) catch return;
            value.request();
        }
    };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var future = try io.concurrent(Request.run, .{ io, &token });
    defer future.await(io);
    const started = std.Io.Clock.now(.awake, io);
    try std.testing.expectError(error.Cancelled, token.sleep(io, .fromSeconds(5)));
    try std.testing.expect(started.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds < 2 * std.time.ns_per_s);
    try std.testing.expectError(error.Cancelled, token.sleep(undefined, .zero));
}

test "child registration delivers an earlier cancellation" {
    const io = std.testing.io;
    var token: Token = .{};
    token.request();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "1" },
        .pgid = 0,
    });
    defer if (child.id != null) child.kill(io);
    token.setChild(child.id.?);
    defer token.clearChild();
    const term = try child.wait(io);
    token.clearChild();
    try std.testing.expectEqual(std.process.Child.Term{ .signal = .TERM }, term);
}
