//! Child-process helpers that never block the calling thread for longer than
//! a bounded poll. Tool and clipboard commands drive their own deadlines from
//! the caller's thread with these instead of a watchdog task: `Io.async` runs
//! its function inline when the Io pool has no spare worker, which turned a
//! timeout task into a sleep for the whole timeout before any output was read.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Term = std.process.Child.Term;

/// Reaps `child` when it has exited; null means it is still running. Once
/// reaped, `child.id` is cleared so `Child.kill` cannot signal a recycled pid.
pub fn reap(child: *std.process.Child) !?Term {
    const pid = child.id.?;
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return null;
                child.id = null;
                return Io.Threaded.statusToTerm(@bitCast(status));
            },
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

/// Waits up to `timeout_ms` for `events` on `fd`. Returns the ready events,
/// or zero when the timeout elapsed first.
pub fn poll(fd: std.posix.fd_t, events: i16, timeout_ms: i32) !i16 {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const ready = try std.posix.poll(&fds, timeout_ms);
    return if (ready == 0) 0 else fds[0].revents;
}

/// One write on a blocking descriptor, for use after `poll` reported it
/// writable so a stalled reader cannot hold the caller.
pub fn writeSome(fd: std.posix.fd_t, bytes: []const u8) !usize {
    while (true) {
        const rc = std.posix.system.write(fd, bytes.ptr, bytes.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .PIPE => return error.BrokenPipe,
            .AGAIN => return error.WouldBlock,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

/// Whole milliseconds until `deadline`, rounded up so a poll never returns
/// early and spins, clamped to `[0, cap]`.
pub fn millisUntil(io: Io, deadline: Io.Timestamp, cap: i32) i32 {
    return millisBetween(Io.Clock.now(.awake, io), deadline, cap);
}

fn millisBetween(now: Io.Timestamp, deadline: Io.Timestamp, cap: i32) i32 {
    const remaining = now.durationTo(deadline).nanoseconds;
    if (remaining <= 0) return 0;
    const millis = @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(@min(millis, cap));
}

test "poll timeouts round up and clamp" {
    const now: Io.Timestamp = .{ .nanoseconds = 1_000_000_000 };
    try std.testing.expectEqual(@as(i32, 0), millisBetween(now, now, 50));
    try std.testing.expectEqual(@as(i32, 0), millisBetween(now, now.subDuration(.fromSeconds(1)), 50));
    try std.testing.expectEqual(@as(i32, 1), millisBetween(now, now.addDuration(.fromNanoseconds(1)), 50));
    try std.testing.expectEqual(@as(i32, 2), millisBetween(now, now.addDuration(.fromNanoseconds(1_000_001)), 50));
    try std.testing.expectEqual(@as(i32, 50), millisBetween(now, now.addDuration(.fromSeconds(5)), 50));
}

test "reap returns null while running and the term afterwards" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 3" }, .pgid = 0 });
    defer if (child.id != null) child.kill(io);
    const term = while (true) {
        if (try reap(&child)) |term| break term;
        try io.sleep(.fromMilliseconds(5), .awake);
    };
    try std.testing.expectEqual(Term{ .exited = 3 }, term);
    try std.testing.expect(child.id == null);
}
