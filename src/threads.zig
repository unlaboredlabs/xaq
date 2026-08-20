const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const types = @import("types.zig");

pub const Thread = struct {
    gpa: std.mem.Allocator,
    io: Io,
    id: []u8,
    path: []u8,
    scratch: Io.Writer.Allocating,

    pub fn deinit(self: *Thread) void {
        self.scratch.deinit();
        self.gpa.free(self.id);
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// Remove a newly created thread that was never installed into a live
    /// session. Deletion is best-effort because the original operation's
    /// failure must remain the reported error.
    pub fn discard(self: *Thread) void {
        Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        self.deinit();
    }

    pub fn appendEntry(self: *Thread, entry: types.Entry) !void {
        self.scratch.clearRetainingCapacity();
        defer self.recycleScratch();
        var js: std.json.Stringify = .{ .writer = &self.scratch.writer };
        try writeEntryLine(&js, &self.scratch.writer, entry);
        try append(self.io, self.path, self.scratch.written());
    }

    /// Replace the whole file atomically with a fresh meta line plus the
    /// given entries. Used for compaction snapshots: append-reset-then-
    /// re-append was neither atomic nor bounded, so a mid-write failure
    /// truncated replayable history and long sessions grew the file
    /// without limit.
    pub fn rewrite(self: *Thread, provider: auth.Provider, model: []const u8, effort: ?[]const u8, fast: bool, cwd: []const u8, entries: []const types.Entry) !void {
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer };
        try js.beginObject();
        try field(&js, "type", "meta");
        try field(&js, "id", self.id);
        try field(&js, "provider", @tagName(provider));
        try field(&js, "model", model);
        if (effort) |value| try field(&js, "effort", value);
        try js.objectField("fast");
        try js.write(fast);
        try field(&js, "cwd", cwd);
        try js.endObject();
        try out.writer.writeByte('\n');
        for (entries) |entry| {
            js = .{ .writer = &out.writer };
            try writeEntryLine(&js, &out.writer, entry);
        }
        var random: [8]u8 = undefined;
        try self.io.randomSecure(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const temporary = try std.fmt.allocPrint(self.gpa, "{s}.tmp-{s}", .{ self.path, &hex });
        defer self.gpa.free(temporary);
        errdefer Io.Dir.cwd().deleteFile(self.io, temporary) catch {};
        try Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = temporary,
            .data = out.written(),
            .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o600) },
        });
        try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), self.path, self.io);
    }

    fn writeEntryLine(js: *std.json.Stringify, writer: *Io.Writer, entry: types.Entry) !void {
        try js.beginObject();
        switch (entry) {
            .user => |user| {
                try field(js, "type", "user");
                try field(js, "text", user.text);
                if (user.images.len > 0) {
                    try js.objectField("images");
                    try js.write(user.images);
                }
            },
            .assistant => |answer| {
                try field(js, "type", "assistant");
                try field(js, "text", answer.text);
                try js.objectField("calls");
                try js.write(answer.calls);
                try js.objectField("raw_items");
                try js.write(answer.raw_items);
                try js.objectField("usage");
                try js.write(answer.usage);
            },
            .results => |results| {
                try field(js, "type", "results");
                try js.objectField("results");
                try js.write(results);
            },
        }
        try js.endObject();
        try writer.writeByte('\n');
    }

    pub fn appendReset(self: *Thread) !void {
        try append(self.io, self.path, "{\"type\":\"reset\"}\n");
    }

    pub fn appendModel(self: *Thread, model: []const u8) !void {
        try self.appendSetting("model", "model", model);
    }

    pub fn appendEffort(self: *Thread, effort: []const u8) !void {
        try self.appendSetting("effort", "effort", effort);
    }

    pub fn appendFast(self: *Thread, enabled: bool) !void {
        self.scratch.clearRetainingCapacity();
        defer self.recycleScratch();
        var js: std.json.Stringify = .{ .writer = &self.scratch.writer };
        try js.beginObject();
        try field(&js, "type", "fast");
        try js.objectField("fast");
        try js.write(enabled);
        try js.endObject();
        try self.scratch.writer.writeByte('\n');
        try append(self.io, self.path, self.scratch.written());
    }

    fn appendSetting(self: *Thread, kind: []const u8, name: []const u8, value: []const u8) !void {
        self.scratch.clearRetainingCapacity();
        defer self.recycleScratch();
        var js: std.json.Stringify = .{ .writer = &self.scratch.writer };
        try js.beginObject();
        try field(&js, "type", kind);
        try field(&js, name, value);
        try js.endObject();
        try self.scratch.writer.writeByte('\n');
        try append(self.io, self.path, self.scratch.written());
    }

    fn recycleScratch(self: *Thread) void {
        if (self.scratch.writer.buffer.len > 128 * 1024) {
            self.scratch.deinit();
            self.scratch = .init(self.gpa);
        } else {
            self.scratch.clearRetainingCapacity();
        }
    }
};

pub const Loaded = struct {
    thread: Thread,
    provider: auth.Provider,
    model: []const u8,
    effort: ?[]const u8,
    fast: bool,
    entries: std.ArrayList(types.Entry),
};

pub const Summary = struct {
    id: []u8,
    modified: i96,
    /// First line of the first user prompt in the thread; may be empty.
    preview: []u8,

    pub fn deinit(self: Summary, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.preview);
    }
};

pub fn freeSummaries(gpa: std.mem.Allocator, summaries: []Summary) void {
    for (summaries) |summary| summary.deinit(gpa);
    gpa.free(summaries);
}

/// Newest saved threads for cwd. Free with `freeSummaries`.
pub fn list(gpa: std.mem.Allocator, io: Io, home: []const u8, cwd: []const u8, exclude_id: ?[]const u8, limit: usize) ![]Summary {
    const dir_path = try threadDir(gpa, home, cwd);
    defer gpa.free(dir_path);
    return listDir(gpa, io, dir_path, exclude_id, limit);
}

fn listDir(gpa: std.mem.Allocator, io: Io, dir_path: []const u8, exclude_id: ?[]const u8, limit: usize) ![]Summary {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return gpa.alloc(Summary, 0),
        else => return err,
    };
    defer dir.close(io);
    var summaries: std.ArrayList(Summary) = .empty;
    errdefer {
        for (summaries.items) |summary| summary.deinit(gpa);
        summaries.deinit(gpa);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const id = entry.name[0 .. entry.name.len - ".jsonl".len];
        if (!validId(id)) continue;
        if (exclude_id) |excluded| if (std.mem.eql(u8, id, excluded)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        try summaries.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .modified = stat.mtime.nanoseconds,
            .preview = try gpa.alloc(u8, 0),
        });
    }
    std.mem.sort(Summary, summaries.items, {}, newestFirst);
    while (summaries.items.len > limit) summaries.pop().?.deinit(gpa);
    // Previews are read only for the survivors to keep listing cheap.
    for (summaries.items) |*summary| {
        const preview = firstUserPreview(gpa, io, dir, summary.id) catch continue;
        gpa.free(summary.preview);
        summary.preview = preview;
    }
    return summaries.toOwnedSlice(gpa);
}

// Large enough that a long first prompt (bounded by the 4 MiB stdin cap
// but typically far smaller) still yields a parseable preview line.
const preview_scan_bytes = 64 * 1024;
const preview_max_bytes = 48;
const max_thread_line_bytes = 64 * 1024 * 1024;

fn firstUserPreview(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, id: []const u8) ![]u8 {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}.jsonl", .{id});
    var file = dir.openFile(io, name, .{}) catch return gpa.alloc(u8, 0);
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);
    var chunk: [preview_scan_bytes]u8 = undefined;
    var filled: usize = 0;
    while (filled < chunk.len) {
        const count = file_reader.interface.readSliceShort(chunk[filled..]) catch break;
        if (count == 0) break;
        filled += count;
    }
    const bytes = chunk[0..filled];
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (previewFromUserLine(gpa, line)) |preview| return preview;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch continue;
        defer parsed.deinit();
        const kind = objectString(parsed.value, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "user")) continue;
        const text = objectString(parsed.value, "text") orelse continue;
        const first_line = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
        const out = try gpa.alloc(u8, @min(first_line.len, preview_max_bytes));
        for (out, first_line[0..out.len]) |*destination, byte| {
            destination.* = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        }
        return out;
    }
    return gpa.alloc(u8, 0);
}

/// User text is serialized before image payloads, so a bounded prefix can
/// produce the picker preview without reading or parsing a multi-megabyte
/// attachment line.
fn previewFromUserLine(gpa: std.mem.Allocator, line: []const u8) ?[]u8 {
    const prefix = "{\"type\":\"user\",\"text\":\"";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var out = gpa.alloc(u8, preview_max_bytes) catch return null;
    var source = prefix.len;
    var destination: usize = 0;
    while (source < line.len and destination < out.len) {
        var byte = line[source];
        source += 1;
        if (byte == '"') break;
        if (byte == '\\') {
            if (source >= line.len) break;
            byte = line[source];
            source += 1;
            byte = switch (byte) {
                '"', '\\', '/' => byte,
                'b', 'f', 'n', 'r', 't' => ' ',
                // Non-ASCII JSON escapes are rare in persisted prompts; a
                // replacement keeps the preview valid without consuming a
                // partial surrogate pair from the bounded prefix.
                'u' => blk: {
                    source = @min(source + 4, line.len);
                    break :blk '?';
                },
                else => '?',
            };
        }
        if (byte == '\n' or byte == '\r') break;
        out[destination] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        destination += 1;
    }
    while (destination > 0 and !std.unicode.utf8ValidateSlice(out[0..destination])) destination -= 1;
    const result = gpa.dupe(u8, out[0..destination]) catch {
        gpa.free(out);
        return null;
    };
    gpa.free(out);
    return result;
}

fn nextThreadLine(reader: *Io.Reader, out: *Io.Writer.Allocating) !?[]const u8 {
    out.clearRetainingCapacity();
    const count = try reader.streamDelimiterLimit(&out.writer, '\n', .limited(max_thread_line_bytes + 1));
    const separator = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return if (count == 0) null else out.written(),
        else => return err,
    };
    std.debug.assert(separator == '\n');
    return out.written();
}

fn newestFirst(_: void, a: Summary, b: Summary) bool {
    if (a.modified != b.modified) return a.modified > b.modified;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Threads kept per directory; older ones are pruned on create.
pub const retained_threads = 50;

pub fn create(gpa: std.mem.Allocator, io: Io, home: []const u8, cwd: []const u8, provider: auth.Provider, model: []const u8, effort: ?[]const u8, fast: bool) !Thread {
    const dir_path = try threadDir(gpa, home, cwd);
    defer gpa.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    pruneDir(gpa, io, dir_path, retained_threads - 1) catch {};

    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    var encoded: [16]u8 = undefined;
    const id = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random);
    const path = try std.fs.path.join(gpa, &.{ dir_path, id });
    defer gpa.free(path);
    const jsonl_path = try std.fmt.allocPrint(gpa, "{s}.jsonl", .{path});
    errdefer gpa.free(jsonl_path);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try field(&js, "type", "meta");
    try field(&js, "id", id);
    try field(&js, "provider", @tagName(provider));
    try field(&js, "model", model);
    if (effort) |value| try field(&js, "effort", value);
    try js.objectField("fast");
    try js.write(fast);
    try field(&js, "cwd", cwd);
    try js.endObject();
    try out.writer.writeByte('\n');
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = jsonl_path,
        .data = out.written(),
        .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o600) },
    });
    return .{ .gpa = gpa, .io = io, .id = try gpa.dupe(u8, id), .path = jsonl_path, .scratch = .init(gpa) };
}

/// Load an explicit thread ID, or the most recently modified thread for cwd.
pub fn load(gpa: std.mem.Allocator, entry_gpa: std.mem.Allocator, io: Io, home: []const u8, cwd: []const u8, requested_id: ?[]const u8, exclude_id: ?[]const u8) !Loaded {
    const dir_path = try threadDir(gpa, home, cwd);
    defer gpa.free(dir_path);
    const id = if (requested_id) |value|
        if (validId(value)) try gpa.dupe(u8, value) else return error.InvalidThreadId
    else
        try latestId(gpa, io, dir_path, exclude_id);
    errdefer gpa.free(id);
    const filename = try std.fmt.allocPrint(gpa, "{s}.jsonl", .{id});
    defer gpa.free(filename);
    const path = try std.fs.path.join(gpa, &.{ dir_path, filename });
    errdefer gpa.free(path);
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);
    var line_buffer: Io.Writer.Allocating = .init(gpa);
    defer line_buffer.deinit();

    var provider: ?auth.Provider = null;
    var model: ?[]const u8 = null;
    var effort: ?[]const u8 = null;
    var fast = false;
    var entries: std.ArrayList(types.Entry) = .empty;
    errdefer entries.deinit(entry_gpa);
    var last_reset_offset: u64 = 0;
    while (try nextThreadLine(&file_reader.interface, &line_buffer)) |line| {
        if (std.mem.eql(u8, line, "{\"type\":\"reset\"}")) last_reset_offset = file_reader.logicalPos();
    }
    try file_reader.seekTo(0);
    while (true) {
        const this_offset = file_reader.logicalPos();
        const line = (try nextThreadLine(&file_reader.interface, &line_buffer)) orelse break;
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch continue;
        defer parsed.deinit();
        const kind = objectString(parsed.value, "type") orelse continue;
        if (std.mem.eql(u8, kind, "meta")) {
            provider = auth.Provider.parse(objectString(parsed.value, "provider") orelse continue);
            model = try entry_gpa.dupe(u8, objectString(parsed.value, "model") orelse continue);
            if (objectString(parsed.value, "effort")) |value| effort = try entry_gpa.dupe(u8, value);
            fast = objectBool(parsed.value, "fast") orelse false;
        } else if (std.mem.eql(u8, kind, "model")) {
            model = try entry_gpa.dupe(u8, objectString(parsed.value, "model") orelse continue);
        } else if (std.mem.eql(u8, kind, "effort")) {
            effort = try entry_gpa.dupe(u8, objectString(parsed.value, "effort") orelse continue);
        } else if (std.mem.eql(u8, kind, "fast")) {
            fast = objectBool(parsed.value, "fast") orelse continue;
        } else if (std.mem.eql(u8, kind, "reset")) {
            entries.clearRetainingCapacity();
        } else if (std.mem.eql(u8, kind, "user")) {
            if (this_offset < last_reset_offset) continue;
            try entries.append(entry_gpa, .{ .user = .{
                .text = try entry_gpa.dupe(u8, objectString(parsed.value, "text") orelse ""),
                .images = try parseImages(entry_gpa, parsed.value),
            } });
        } else if (std.mem.eql(u8, kind, "assistant")) {
            if (this_offset < last_reset_offset) continue;
            try entries.append(entry_gpa, .{ .assistant = try parseAssistant(entry_gpa, parsed.value) });
        } else if (std.mem.eql(u8, kind, "results")) {
            if (this_offset < last_reset_offset) continue;
            try entries.append(entry_gpa, .{ .results = try parseResults(entry_gpa, parsed.value) });
        }
    }
    return .{
        .thread = .{ .gpa = gpa, .io = io, .id = id, .path = path, .scratch = .init(gpa) },
        .provider = provider orelse return error.InvalidThread,
        .model = model orelse return error.InvalidThread,
        .effort = effort,
        .fast = fast,
        .entries = entries,
    };
}

fn validId(value: []const u8) bool {
    if (value.len != 16) return false;
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn parseAssistant(gpa: std.mem.Allocator, value: std.json.Value) !types.Assistant {
    const calls_value = objectValue(value, "calls") orelse return error.InvalidThread;
    const calls_items = switch (calls_value) {
        .array => |array| array.items,
        else => return error.InvalidThread,
    };
    const calls = try gpa.alloc(types.ToolCall, calls_items.len);
    for (calls_items, 0..) |call, i| calls[i] = .{
        .id = try gpa.dupe(u8, objectString(call, "id") orelse return error.InvalidThread),
        .name = try gpa.dupe(u8, objectString(call, "name") orelse return error.InvalidThread),
        .arguments = try gpa.dupe(u8, objectString(call, "arguments") orelse "{}"),
    };
    const raw_value = objectValue(value, "raw_items");
    const raw_items = if (raw_value) |raw| switch (raw) {
        .array => |array| blk: {
            const items = try gpa.alloc([]const u8, array.items.len);
            for (array.items, 0..) |item, i| items[i] = try gpa.dupe(u8, switch (item) {
                .string => |text| text,
                else => return error.InvalidThread,
            });
            break :blk items;
        },
        else => return error.InvalidThread,
    } else &.{};
    var usage: types.Usage = .{};
    if (objectValue(value, "usage")) |usage_value| {
        usage.input = objectUnsigned(usage_value, "input") orelse 0;
        usage.cached = objectUnsigned(usage_value, "cached") orelse 0;
        usage.output = objectUnsigned(usage_value, "output") orelse 0;
    }
    return .{
        .text = try gpa.dupe(u8, objectString(value, "text") orelse ""),
        .calls = calls,
        .raw_items = raw_items,
        .usage = usage,
    };
}

fn parseImages(gpa: std.mem.Allocator, value: std.json.Value) ![]const types.Image {
    const images_value = objectValue(value, "images") orelse return &.{};
    const items = switch (images_value) {
        .array => |array| array.items,
        else => return error.InvalidThread,
    };
    const images = try gpa.alloc(types.Image, items.len);
    for (items, 0..) |image, index| images[index] = .{
        .name = try gpa.dupe(u8, objectString(image, "name") orelse "image"),
        .media_type = try gpa.dupe(u8, objectString(image, "media_type") orelse return error.InvalidThread),
        .data = try gpa.dupe(u8, objectString(image, "data") orelse return error.InvalidThread),
    };
    return images;
}

fn parseResults(gpa: std.mem.Allocator, value: std.json.Value) ![]const types.ToolResult {
    const results_value = objectValue(value, "results") orelse return error.InvalidThread;
    const items = switch (results_value) {
        .array => |array| array.items,
        else => return error.InvalidThread,
    };
    const results = try gpa.alloc(types.ToolResult, items.len);
    for (items, 0..) |result, i| results[i] = .{
        .id = try gpa.dupe(u8, objectString(result, "id") orelse return error.InvalidThread),
        .text = try gpa.dupe(u8, objectString(result, "text") orelse ""),
    };
    return results;
}

/// Best-effort: delete the oldest thread files beyond `keep`.
fn pruneDir(gpa: std.mem.Allocator, io: Io, dir_path: []const u8, keep: usize) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var summaries: std.ArrayList(Summary) = .empty;
    defer {
        for (summaries.items) |summary| summary.deinit(gpa);
        summaries.deinit(gpa);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const id = entry.name[0 .. entry.name.len - ".jsonl".len];
        if (!validId(id)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        try summaries.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .modified = stat.mtime.nanoseconds,
            .preview = try gpa.alloc(u8, 0),
        });
    }
    if (summaries.items.len <= keep) return;
    std.mem.sort(Summary, summaries.items, {}, newestFirst);
    const now_ns: i96 = Io.Clock.real.now(io).nanoseconds;
    const one_day_ns: i96 = 24 * 60 * 60 * std.time.ns_per_s;
    for (summaries.items[keep..]) |summary| {
        // Never delete a recently-touched thread: it may belong to a
        // live session in another process, and recreating it later
        // would lose its meta line.
        if (now_ns - summary.modified < one_day_ns) continue;
        var name_buffer: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s}.jsonl", .{summary.id}) catch continue;
        dir.deleteFile(io, name) catch {};
    }
}

fn latestId(gpa: std.mem.Allocator, io: Io, dir_path: []const u8, exclude_id: ?[]const u8) ![]u8 {
    const summaries = try listDir(gpa, io, dir_path, exclude_id, 1);
    if (summaries.len == 0) {
        gpa.free(summaries);
        return error.NoThreads;
    }
    const id = summaries[0].id;
    gpa.free(summaries[0].preview);
    gpa.free(summaries);
    return id;
}

fn threadDir(gpa: std.mem.Allocator, home: []const u8, cwd: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(cwd, &digest, .{});
    const key = std.fmt.bytesToHex(digest[0..8], .lower);
    return std.fs.path.join(gpa, &.{ home, ".config", "xaq", "threads", &key });
}

fn append(io: Io, path: []const u8, bytes: []const u8) !void {
    // Open, never create: silently recreating a pruned or deleted thread
    // file would produce a meta-less JSONL that later fails to load.
    var file = Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only, .lock = .exclusive }) catch |err| switch (err) {
        error.FileNotFound => return error.ThreadMissing,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buffer);
    try writer.seekTo(stat.size);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn field(js: *std.json.Stringify, name: []const u8, value: []const u8) !void {
    try js.objectField(name);
    try js.write(value);
}

fn objectValue(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn objectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    return if (objectValue(value, key)) |item| switch (item) {
        .string => |text| text,
        else => null,
    } else null;
}

fn objectBool(value: std.json.Value, key: []const u8) ?bool {
    return if (objectValue(value, key)) |item| switch (item) {
        .bool => |enabled| enabled,
        else => null,
    } else null;
}

fn objectUnsigned(value: std.json.Value, key: []const u8) ?u64 {
    return if (objectValue(value, key)) |item| switch (item) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    } else null;
}

test "thread directory is stable for a working directory" {
    const a = try threadDir(std.testing.allocator, "/home/test", "/work/a");
    defer std.testing.allocator.free(a);
    const b = try threadDir(std.testing.allocator, "/home/test", "/work/a");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.startsWith(u8, a, "/home/test/.config/xaq/threads/"));
}

test "thread IDs cannot escape their directory" {
    try std.testing.expect(validId("Abcdef012345_-xy"));
    try std.testing.expect(!validId("../../auth.json"));
    try std.testing.expect(!validId("too-short"));
}

test "discard removes an uninstalled thread file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    var thread = try create(std.testing.allocator, std.testing.io, home, "/work/discard", .chatgpt, "model-a", null, false);
    const path = try std.testing.allocator.dupe(u8, thread.path);
    defer std.testing.allocator.free(path);

    thread.discard();
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(std.testing.io, path, .{}));
}

test "thread JSONL resumes state after the last reset" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    var thread = try create(std.testing.allocator, std.testing.io, home, "/work/project", .chatgpt, "model-a", "high", true);
    const id = try std.testing.allocator.dupe(u8, thread.id);
    defer std.testing.allocator.free(id);
    {
        var initial_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer initial_arena.deinit();
        var initial = try load(std.testing.allocator, initial_arena.allocator(), std.testing.io, home, "/work/project", id, null);
        defer initial.thread.deinit();
        try std.testing.expect(initial.fast);
    }
    try thread.appendEntry(.{ .user = .{ .text = "old" } });
    const scratch_capacity = thread.scratch.writer.buffer.len;
    try thread.appendReset();
    try thread.appendEntry(.{ .user = .{ .text = "new" } });
    try std.testing.expectEqual(scratch_capacity, thread.scratch.writer.buffer.len);
    try thread.appendFast(false);
    const summaries = try list(std.testing.allocator, std.testing.io, home, "/work/project", null, 8);
    defer freeSummaries(std.testing.allocator, summaries);
    try std.testing.expectEqual(@as(usize, 1), summaries.len);
    try std.testing.expectEqualStrings(id, summaries[0].id);
    try std.testing.expectEqualStrings("old", summaries[0].preview);
    const excluded = try list(std.testing.allocator, std.testing.io, home, "/work/project", id, 8);
    defer freeSummaries(std.testing.allocator, excluded);
    try std.testing.expectEqual(@as(usize, 0), excluded.len);
    thread.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, "/work/project", id, null);
    defer loaded.thread.deinit();
    try std.testing.expectEqual(auth.Provider.chatgpt, loaded.provider);
    try std.testing.expectEqualStrings("model-a", loaded.model);
    try std.testing.expectEqualStrings("high", loaded.effort.?);
    try std.testing.expect(!loaded.fast);
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    try std.testing.expectEqualStrings("new", loaded.entries.items[0].user.text);
}

test "thread JSONL persists image content" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    var thread = try create(std.testing.allocator, std.testing.io, home, "/work/images", .chatgpt, "model-a", null, false);
    defer thread.deinit();
    const id = try std.testing.allocator.dupe(u8, thread.id);
    defer std.testing.allocator.free(id);
    const image_data = try std.testing.allocator.alloc(u8, preview_scan_bytes + 1024);
    defer std.testing.allocator.free(image_data);
    @memset(image_data, 'A');
    const image: types.Image = .{ .name = "shot.png", .media_type = "image/png", .data = image_data };
    try thread.appendEntry(.{ .user = .{ .text = "look", .images = &.{image} } });

    const summaries = try list(std.testing.allocator, std.testing.io, home, "/work/images", null, 8);
    defer freeSummaries(std.testing.allocator, summaries);
    try std.testing.expectEqualStrings("look", summaries[0].preview);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, "/work/images", id, null);
    defer loaded.thread.deinit();
    const user = loaded.entries.items[0].user;
    try std.testing.expectEqualStrings("look", user.text);
    try std.testing.expectEqual(@as(usize, 1), user.images.len);
    try std.testing.expectEqualStrings("image/png", user.images[0].media_type);
    try std.testing.expectEqualStrings(image_data, user.images[0].data);
}

test "thread loader streams files larger than the former aggregate cap" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    var thread = try create(std.testing.allocator, std.testing.io, home, "/work/large-thread", .chatgpt, "model-a", null, false);
    defer thread.deinit();
    const padding = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(padding);
    @memset(padding, ' ');
    padding[padding.len - 1] = '\n';
    for (0..65) |_| try append(std.testing.io, thread.path, padding);
    try thread.appendEntry(.{ .user = .{ .text = "still resumable" } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, "/work/large-thread", thread.id, null);
    defer loaded.thread.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    try std.testing.expectEqualStrings("still resumable", loaded.entries.items[0].user.text);
}
