//! Best-effort Git identity for the fullscreen header. Git is queried only
//! when the session starts and after tools that may change the worktree.

const std = @import("std");
const Io = std.Io;

const label_bytes = 128;
const command_output_bytes = 8 * 1024;

pub const Status = struct {
    present: bool = false,
    worktree_buffer: [label_bytes]u8 = undefined,
    worktree_len: usize = 0,
    branch_buffer: [label_bytes]u8 = undefined,
    branch_len: usize = 0,
    dirty: bool = false,

    pub fn worktree(self: *const Status) []const u8 {
        return self.worktree_buffer[0..self.worktree_len];
    }

    pub fn branch(self: *const Status) []const u8 {
        return self.branch_buffer[0..self.branch_len];
    }
};

/// Return null outside a repository or when Git is unavailable. Status
/// failures still return the discovered worktree instead of hiding it.
pub fn inspect(gpa: std.mem.Allocator, io: Io, cwd: []const u8) ?Status {
    const root_result = run(gpa, io, cwd, &.{ "git", "--no-optional-locks", "rev-parse", "--show-toplevel" }) catch return null;
    defer gpa.free(root_result.stdout);
    defer gpa.free(root_result.stderr);
    if (!exitedZero(root_result.term)) return null;

    const root = std.mem.trimEnd(u8, root_result.stdout, "\r\n");
    if (root.len == 0) return null;
    var result: Status = .{ .present = true };
    result.worktree_len = copySafe(&result.worktree_buffer, std.fs.path.basename(root));

    const status_result = run(gpa, io, cwd, &.{
        "git", "--no-optional-locks", "status", "--porcelain=v2", "--branch", "--no-ahead-behind", "--untracked-files=normal",
    }) catch |err| {
        if (err == error.StreamTooLong) result.dirty = true;
        fillBranchFallback(gpa, io, cwd, &result);
        return result;
    };
    defer gpa.free(status_result.stdout);
    defer gpa.free(status_result.stderr);
    if (exitedZero(status_result.term)) parsePorcelain(&result, status_result.stdout);
    if (result.branch_len == 0) fillBranchFallback(gpa, io, cwd, &result);
    return result;
}

fn run(gpa: std.mem.Allocator, io: Io, cwd: []const u8, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(command_output_bytes),
        .stderr_limit = .limited(command_output_bytes),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
    });
}

fn exitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn parsePorcelain(result: *Status, output: []const u8) void {
    var oid: []const u8 = "";
    var head: []const u8 = "";
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "# branch.oid ")) {
            oid = line["# branch.oid ".len..];
        } else if (std.mem.startsWith(u8, line, "# branch.head ")) {
            head = line["# branch.head ".len..];
        } else if (line.len > 0 and line[0] != '#') {
            result.dirty = true;
        }
    }
    if (head.len > 0 and !std.mem.eql(u8, head, "(detached)")) {
        result.branch_len = copySafe(&result.branch_buffer, head);
    } else if (oid.len > 0 and !std.mem.eql(u8, oid, "(initial)")) {
        const short = oid[0..@min(oid.len, 8)];
        const label = std.fmt.bufPrint(&result.branch_buffer, "detached@{s}", .{short}) catch return;
        result.branch_len = label.len;
    }
}

fn fillBranchFallback(gpa: std.mem.Allocator, io: Io, cwd: []const u8, status: *Status) void {
    const branch_result = run(gpa, io, cwd, &.{ "git", "--no-optional-locks", "symbolic-ref", "--quiet", "--short", "HEAD" }) catch {
        fillDetachedFallback(gpa, io, cwd, status);
        return;
    };
    defer gpa.free(branch_result.stdout);
    defer gpa.free(branch_result.stderr);
    if (!exitedZero(branch_result.term)) {
        fillDetachedFallback(gpa, io, cwd, status);
        return;
    }
    status.branch_len = copySafe(&status.branch_buffer, std.mem.trimEnd(u8, branch_result.stdout, "\r\n"));
}

fn fillDetachedFallback(gpa: std.mem.Allocator, io: Io, cwd: []const u8, status: *Status) void {
    const oid_result = run(gpa, io, cwd, &.{ "git", "--no-optional-locks", "rev-parse", "--short=8", "HEAD" }) catch return;
    defer gpa.free(oid_result.stdout);
    defer gpa.free(oid_result.stderr);
    if (!exitedZero(oid_result.term)) return;
    const oid = std.mem.trimEnd(u8, oid_result.stdout, "\r\n");
    const label = std.fmt.bufPrint(&status.branch_buffer, "detached@{s}", .{oid}) catch return;
    status.branch_len = label.len;
}

/// Copy terminal-safe UTF-8 into a fixed label. Invalid and control bytes
/// become `?`, and complete code points are never split at the buffer edge.
fn copySafe(destination: []u8, source: []const u8) usize {
    var read: usize = 0;
    var written: usize = 0;
    while (read < source.len and written < destination.len) {
        const byte = source[read];
        if (byte < 0x80) {
            destination[written] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
            read += 1;
            written += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch {
            destination[written] = '?';
            read += 1;
            written += 1;
            continue;
        };
        if (read + length > source.len or written + length > destination.len) break;
        _ = std.unicode.utf8Decode(source[read .. read + length]) catch {
            destination[written] = '?';
            read += 1;
            written += 1;
            continue;
        };
        @memcpy(destination[written .. written + length], source[read .. read + length]);
        read += length;
        written += length;
    }
    return written;
}

test "porcelain status captures branch and dirty state" {
    var status: Status = .{ .present = true };
    parsePorcelain(&status,
        \\# branch.oid 0123456789abcdef
        \\# branch.head feature/tui
        \\1 .M N... 100644 100644 100644 abcdef abcdef src/tui.zig
        \\
    );
    try std.testing.expectEqualStrings("feature/tui", status.branch());
    try std.testing.expect(status.dirty);
}

test "porcelain status labels detached heads" {
    var status: Status = .{ .present = true };
    parsePorcelain(&status,
        \\# branch.oid 0123456789abcdef
        \\# branch.head (detached)
        \\
    );
    try std.testing.expectEqualStrings("detached@01234567", status.branch());
    try std.testing.expect(!status.dirty);
}

test "safe labels replace terminal controls and keep utf8 whole" {
    var buffer: [6]u8 = undefined;
    const length = copySafe(&buffer, "a\x1bb中b");
    try std.testing.expectEqualStrings("a?b中", buffer[0..length]);
}
