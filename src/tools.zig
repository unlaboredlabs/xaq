const std = @import("std");
const Io = std.Io;

pub const names = [_][]const u8{ "read", "bash", "edit", "write" };
pub const max_output = 50 * 1024;

pub fn schemas(s: *std.json.Stringify) !void {
    try s.beginArray();
    try schema(s, "read", "Read a text file. Paths may be relative or absolute.",
        \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}
    );
    try schema(s, "bash", "Run a shell command in the current directory with full host permissions.",
        \\{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"integer","minimum":1,"maximum":3600}},"required":["command"],"additionalProperties":false}
    );
    try schema(s, "edit", "Apply exact, non-overlapping text replacements to a file.",
        \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"oldText":{"type":"string"},"newText":{"type":"string"}},"required":["oldText","newText"],"additionalProperties":false},"minItems":1}},"required":["path","edits"],"additionalProperties":false}
    );
    try schema(s, "write", "Create or overwrite a text file, creating parent directories.",
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}
    );
    try s.endArray();
}

pub fn claudeSchemas(s: *std.json.Stringify) !void {
    try s.beginArray();
    try claudeSchema(s, "read", "Read a text file. Paths may be relative or absolute.",
        \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}
    );
    try claudeSchema(s, "bash", "Run a shell command in the current directory with full host permissions.",
        \\{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"integer","minimum":1,"maximum":3600}},"required":["command"],"additionalProperties":false}
    );
    try claudeSchema(s, "edit", "Apply exact, non-overlapping text replacements to a file.",
        \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"oldText":{"type":"string"},"newText":{"type":"string"}},"required":["oldText","newText"],"additionalProperties":false},"minItems":1}},"required":["path","edits"],"additionalProperties":false}
    );
    try claudeSchema(s, "write", "Create or overwrite a text file, creating parent directories.",
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}
    );
    try s.endArray();
}

fn schema(s: *std.json.Stringify, name: []const u8, description: []const u8, parameters: []const u8) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("function");
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("parameters");
    try rawValue(s, parameters);
    try s.endObject();
}

fn claudeSchema(s: *std.json.Stringify, name: []const u8, description: []const u8, parameters: []const u8) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("input_schema");
    try rawValue(s, parameters);
    try s.endObject();
}

fn rawValue(s: *std.json.Stringify, value: []const u8) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll(value);
    s.endWriteRaw();
}

pub fn execute(gpa: std.mem.Allocator, io: Io, name: []const u8, args: std.json.Value) ![]u8 {
    if (std.mem.eql(u8, name, "read")) return read(gpa, io, args);
    if (std.mem.eql(u8, name, "bash")) return bash(gpa, io, args);
    if (std.mem.eql(u8, name, "edit")) return edit(gpa, io, args);
    if (std.mem.eql(u8, name, "write")) return write(gpa, io, args);
    return std.fmt.allocPrint(gpa, "unknown tool: {s}", .{name});
}

fn fieldString(args: std.json.Value, key: []const u8) ![]const u8 {
    const value = switch (args) {
        .object => |o| o.get(key) orelse return error.MissingField,
        else => return error.InvalidArguments,
    };
    return switch (value) {
        .string => |v| v,
        else => error.InvalidArguments,
    };
}

fn optionalInt(args: std.json.Value, key: []const u8) ?i64 {
    const value = switch (args) {
        .object => |o| o.get(key) orelse return null,
        else => return null,
    };
    return switch (value) {
        .integer => |v| v,
        else => null,
    };
}

fn read(gpa: std.mem.Allocator, io: Io, args: std.json.Value) ![]u8 {
    const path = try fieldString(args, "path");
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);
    const offset: usize = @intCast(@max(optionalInt(args, "offset") orelse 1, 1));
    const limit: usize = @intCast(@max(optionalInt(args, "limit") orelse 2000, 1));

    var line: usize = 1;
    var start: usize = 0;
    while (line < offset and start < bytes.len) : (line += 1) {
        start = (std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len - 1) + 1;
    }
    var end = start;
    var taken: usize = 0;
    while (taken < limit and end < bytes.len) : (taken += 1) {
        end = (std.mem.indexOfScalarPos(u8, bytes, end, '\n') orelse bytes.len - 1) + 1;
    }
    end = @min(end, @min(bytes.len, start + max_output));
    return gpa.dupe(u8, bytes[start..end]);
}

fn bash(gpa: std.mem.Allocator, io: Io, args: std.json.Value) ![]u8 {
    const command = try fieldString(args, "command");
    const seconds = optionalInt(args, "timeout");
    const timeout: Io.Timeout = if (seconds) |n| .{ .duration = .{ .raw = .fromSeconds(@min(@max(n, 1), 3600)), .clock = .awake } } else .none;
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "/bin/sh", "-lc", command },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
        .timeout = timeout,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(result.stdout);
    try out.writer.writeAll(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) try out.writer.print("\n[exit {d}]", .{code}),
        .signal => |sig| try out.writer.print("\n[signal {d}]", .{@intFromEnum(sig)}),
        else => try out.writer.writeAll("\n[process terminated]"),
    }
    const all = out.written();
    return gpa.dupe(u8, if (all.len > max_output) all[all.len - max_output ..] else all);
}

fn ensureParent(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try Io.Dir.cwd().createDirPath(io, parent);
    }
}

fn write(gpa: std.mem.Allocator, io: Io, args: std.json.Value) ![]u8 {
    const path = try fieldString(args, "path");
    const content = try fieldString(args, "content");
    try ensureParent(io, path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
    return std.fmt.allocPrint(gpa, "wrote {d} bytes to {s}", .{ content.len, path });
}

const Replacement = struct { start: usize, end: usize, text: []const u8 };

fn lessThan(_: void, a: Replacement, b: Replacement) bool {
    return a.start < b.start;
}

fn edit(gpa: std.mem.Allocator, io: Io, args: std.json.Value) ![]u8 {
    const path = try fieldString(args, "path");
    const values = switch (args) {
        .object => |o| switch (o.get("edits") orelse return error.MissingField) {
            .array => |a| a.items,
            else => return error.InvalidArguments,
        },
        else => return error.InvalidArguments,
    };
    if (values.len == 0) return error.InvalidArguments;
    const original = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(original);
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(gpa);

    for (values) |value| {
        const old = try fieldString(value, "oldText");
        const new = try fieldString(value, "newText");
        if (old.len == 0) return error.EmptyOldText;
        const start = std.mem.indexOf(u8, original, old) orelse return error.TextNotFound;
        if (std.mem.indexOfPos(u8, original, start + old.len, old) != null) return error.TextNotUnique;
        try replacements.append(gpa, .{ .start = start, .end = start + old.len, .text = new });
    }
    std.mem.sort(Replacement, replacements.items, {}, lessThan);
    for (replacements.items[1..], replacements.items[0 .. replacements.items.len - 1]) |next, prev| {
        if (next.start < prev.end) return error.OverlappingEdits;
    }

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var cursor: usize = 0;
    for (replacements.items) |replacement| {
        try out.writer.writeAll(original[cursor..replacement.start]);
        try out.writer.writeAll(replacement.text);
        cursor = replacement.end;
    }
    try out.writer.writeAll(original[cursor..]);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
    return std.fmt.allocPrint(gpa, "applied {d} edit(s) to {s}", .{ replacements.items.len, path });
}

test "tool names match pi defaults" {
    try std.testing.expectEqualStrings("read", names[0]);
    try std.testing.expectEqualStrings("bash", names[1]);
    try std.testing.expectEqualStrings("edit", names[2]);
    try std.testing.expectEqualStrings("write", names[3]);
}
