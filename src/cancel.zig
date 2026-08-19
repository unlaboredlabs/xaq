const std = @import("std");

var requested_flag = std.atomic.Value(bool).init(false);
var child_group = std.atomic.Value(std.posix.pid_t).init(0);

fn handle(_: std.posix.SIG) callconv(.c) void {
    requested_flag.store(true, .seq_cst);
    const pgid = child_group.load(.seq_cst);
    if (pgid > 0) std.posix.kill(-pgid, .TERM) catch {};
}

pub const Scope = struct {
    old: std.posix.Sigaction = undefined,
    installed: bool = false,

    pub fn install() Scope {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handle },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var scope: Scope = .{};
        requested_flag.store(false, .seq_cst);
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
    requested_flag.store(false, .seq_cst);
    child_group.store(pid, .seq_cst);
}

pub fn clearChild() void {
    child_group.store(0, .seq_cst);
}

pub fn requested() bool {
    return requested_flag.load(.seq_cst);
}

pub fn reset() void {
    requested_flag.store(false, .seq_cst);
}
