const std = @import("std");
const Io = std.Io;

const file_limit = 64 * 1024;
const total_limit = 256 * 1024;

/// Load ~/.config/xaq/AGENTS.md followed by each AGENTS.md from the
/// filesystem root down to the current directory. Missing files are normal.
pub fn load(gpa: std.mem.Allocator, io: Io, home: []const u8, cwd: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const global = try std.fs.path.join(gpa, &.{ home, ".config", "xaq", "AGENTS.md" });
    defer gpa.free(global);
    try appendFile(gpa, io, &out.writer, global);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }
    var cursor = cwd;
    while (true) {
        try paths.append(gpa, try std.fs.path.join(gpa, &.{ cursor, "AGENTS.md" }));
        const parent = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, parent, cursor)) break;
        cursor = parent;
    }
    var i = paths.items.len;
    while (i > 0) {
        i -= 1;
        try appendFile(gpa, io, &out.writer, paths.items[i]);
        if (out.written().len >= total_limit) break;
    }
    return out.toOwnedSlice();
}

fn appendFile(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, path: []const u8) !void {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_limit)) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return,
        error.StreamTooLong => return error.InstructionFileTooLarge,
        else => return err,
    };
    defer gpa.free(bytes);
    if (bytes.len == 0) return;
    if (writer.buffered().len + bytes.len + path.len + 24 > total_limit) return error.InstructionsTooLarge;
    try writer.print("\nInstructions from {s}:\n{s}\n", .{ path, bytes });
}

test "missing instruction files produce empty context" {
    const result = try load(std.testing.allocator, std.testing.io, "/xaq-no-home", "/xaq-no-cwd");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
