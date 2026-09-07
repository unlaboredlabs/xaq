const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const types = @import("types.zig");

pub const Thread = struct {
    gpa: std.mem.Allocator,
    io: Io,
    id: []u8,
    path: []u8,
    /// Held for this session's entire ownership, including atomic rewrites.
    lock_file: Io.File,
    scratch: Io.Writer.Allocating,

    pub fn deinit(self: *Thread) void {
        self.scratch.deinit();
        self.gpa.free(self.id);
        self.gpa.free(self.path);
        self.lock_file.close(self.io);
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

    /// A mid-thread provider switch. Written before the accompanying model
    /// line so a resumed thread replays the pair in selection order.
    pub fn appendProvider(self: *Thread, provider: []const u8) !void {
        try self.appendSetting("provider", "provider", provider);
    }

    pub fn appendEffort(self: *Thread, effort: []const u8) !void {
        try self.appendSetting("effort", "effort", effort);
    }

    /// Persist the full selection in one record so a failed provider/model
    /// change cannot leave a mixture of the old and new settings on replay.
    pub fn appendSelection(self: *Thread, provider: auth.Provider, model: []const u8, effort: ?[]const u8, fast: bool) !void {
        self.scratch.clearRetainingCapacity();
        defer self.recycleScratch();
        var js: std.json.Stringify = .{ .writer = &self.scratch.writer };
        try js.beginObject();
        try field(&js, "type", "selection");
        try field(&js, "provider", @tagName(provider));
        try field(&js, "model", model);
        try js.objectField("effort");
        try js.write(effort);
        try js.objectField("fast");
        try js.write(fast);
        try js.endObject();
        try self.scratch.writer.writeByte('\n');
        try append(self.io, self.path, self.scratch.written());
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
        return copyPreview(gpa, text);
    }
    return gpa.alloc(u8, 0);
}

/// User text is serialized before image payloads, so a bounded prefix can
/// produce the picker preview without reading or parsing a multi-megabyte
/// attachment line.
fn previewFromUserLine(gpa: std.mem.Allocator, line: []const u8) ?[]u8 {
    const prefix = "{\"type\":\"user\",\"text\":\"";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var scanner = std.json.Scanner.initStreaming(gpa);
    defer scanner.deinit();
    // A JSON escape consumes at most six source bytes per decoded byte.
    // Feed only enough of the quoted text to fill a preview, even when the
    // prompt or its image payload is much larger than the scan buffer.
    const start = prefix.len - 1;
    scanner.feedInput(line[start..@min(line.len, start + 1 + 6 * preview_max_bytes)]);
    var out: [preview_max_bytes]u8 = undefined;
    var len: usize = 0;
    while (len < out.len) {
        const token = scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => break,
            else => return null,
        };
        const bytes: []const u8 = switch (token) {
            .string, .partial_string => |bytes| bytes,
            .partial_string_escaped_1 => |*bytes| bytes,
            .partial_string_escaped_2 => |*bytes| bytes,
            .partial_string_escaped_3 => |*bytes| bytes,
            .partial_string_escaped_4 => |*bytes| bytes,
            else => return null,
        };
        const line_end = std.mem.findAny(u8, bytes, "\r\n") orelse bytes.len;
        const count = @min(out.len - len, line_end);
        @memcpy(out[len..][0..count], bytes[0..count]);
        len += count;
        if (line_end < bytes.len or token == .string) break;
    }
    return copyPreview(gpa, out[0..len]) catch null;
}

fn copyPreview(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var len = @min(std.mem.findAny(u8, text, "\r\n") orelse text.len, preview_max_bytes);
    while (len > 0 and !std.unicode.utf8ValidateSlice(text[0..len])) len -= 1;
    const out = try gpa.dupe(u8, text[0..len]);
    for (out) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
        byte.* = ' ';
    };
    return out;
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

/// The sidecar inode must stay stable across rewrites and pruning. Never
/// unlink these empty files: a process may already have one open while it
/// acquires the lock. The OS releases ownership when the file closes or the
/// process exits, so a crash cannot leave a stale lock behind.
fn lockThread(io: Io, dir: Io.Dir, id: []const u8) !Io.File {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}.jsonl.lock", .{id});
    return dir.createFile(io, name, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = @enumFromInt(0o600),
    }) catch |err| switch (err) {
        error.WouldBlock => error.ThreadInUse,
        else => return err,
    };
}

pub fn create(gpa: std.mem.Allocator, io: Io, home: []const u8, cwd: []const u8, provider: auth.Provider, model: []const u8, effort: ?[]const u8, fast: bool) !Thread {
    const dir_path = try threadDir(gpa, home, cwd);
    defer gpa.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);

    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    var encoded: [16]u8 = undefined;
    const id = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &random);
    const path = try std.fs.path.join(gpa, &.{ dir_path, id });
    defer gpa.free(path);
    const jsonl_path = try std.fmt.allocPrint(gpa, "{s}.jsonl", .{path});
    errdefer gpa.free(jsonl_path);
    const owned_id = try gpa.dupe(u8, id);
    errdefer gpa.free(owned_id);
    const dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const lock_file = try lockThread(io, dir, id);
    errdefer lock_file.close(io);

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
    var file = try Io.Dir.cwd().createFile(io, jsonl_path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    // Arm deletion only after this call has created the file. A failed
    // initial write must not leave an orphan that masks the latest thread.
    errdefer Io.Dir.cwd().deleteFile(io, jsonl_path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, out.written());
    // Retention is a consequence of a successful creation. A failed /new
    // must neither replace the live session nor prune its saved history.
    pruneDir(gpa, io, dir_path, retained_threads) catch {};
    return .{ .gpa = gpa, .io = io, .id = owned_id, .path = jsonl_path, .lock_file = lock_file, .scratch = .init(gpa) };
}

/// Load an explicit thread ID, or the most recently modified thread for cwd.
/// A thread has one active session; another owner returns ThreadInUse.
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
    const dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const lock_file = try lockThread(io, dir, id);
    errdefer lock_file.close(io);
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
        } else if (std.mem.eql(u8, kind, "selection")) {
            const next_provider = auth.Provider.parse(objectString(parsed.value, "provider") orelse continue) orelse continue;
            const next_model = objectString(parsed.value, "model") orelse continue;
            const next_effort: ?[]const u8 = switch (objectValue(parsed.value, "effort") orelse continue) {
                .null => null,
                .string => |value| value,
                else => continue,
            };
            const next_fast = objectBool(parsed.value, "fast") orelse continue;
            const owned_model = try entry_gpa.dupe(u8, next_model);
            const owned_effort = if (next_effort) |value| try entry_gpa.dupe(u8, value) else null;
            if (provider != next_provider) {
                for (entries.items) |*entry| switch (entry.*) {
                    .assistant => |*answer| answer.raw_items = &.{},
                    else => {},
                };
            }
            provider = next_provider;
            model = owned_model;
            effort = owned_effort;
            fast = next_fast;
        } else if (std.mem.eql(u8, kind, "model")) {
            model = try entry_gpa.dupe(u8, objectString(parsed.value, "model") orelse continue);
        } else if (std.mem.eql(u8, kind, "provider")) {
            // An unparseable provider line keeps the previous value; the
            // thread stays loadable on builds that predate a new provider.
            provider = auth.Provider.parse(objectString(parsed.value, "provider") orelse continue) orelse provider;
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
        .thread = .{ .gpa = gpa, .io = io, .id = id, .path = path, .lock_file = lock_file, .scratch = .init(gpa) },
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
        // Keep the age grace for recent threads, including sessions running
        // older builds. A lifetime lock also protects idle active sessions.
        if (now_ns - summary.modified < one_day_ns) continue;
        const lock_file = lockThread(io, dir, summary.id) catch continue;
        defer lock_file.close(io);
        var name_buffer: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s}.jsonl", .{summary.id}) catch continue;
        // The previous owner may have written since the directory scan.
        const stat = dir.statFile(io, name, .{}) catch continue;
        if (now_ns - stat.mtime.nanoseconds < one_day_ns) continue;
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
    var file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .lock = .exclusive }) catch |err| switch (err) {
        error.FileNotFound => return error.ThreadMissing,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    // A short write can leave a complete JSON object without its newline.
    // Roll back failed appends so replay does not apply an operation whose
    // caller kept the previous in-memory state after receiving an error.
    errdefer file.setLength(io, stat.size) catch {};
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buffer);
    try writer.seekTo(stat.size);
    // A failed write or interrupted process may leave an incomplete final
    // line. Keep the next entry separate so replay can skip the damaged
    // record without also losing the newly appended one.
    if (stat.size > 0) {
        var last: [1]u8 = undefined;
        if (try file.readPositionalAll(io, &last, stat.size - 1) != 1) return error.ThreadChanged;
        if (last[0] != '\n') try writer.interface.writeByte('\n');
    }
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

test "failed metadata writes leave no new thread and do not prune existing history" {
    const FailMetadata = struct {
        fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
            if (operation == .file_write_streaming) {
                var write = operation.file_write_streaming;
                const bytes = write.data[0];
                if (!std.mem.startsWith(u8, bytes, "{\"type\":")) return .{ .file_write_streaming = error.NoSpaceLeft };
                write.data = &.{bytes[0..8]};
                return std.testing.io.vtable.operate(userdata, .{ .file_write_streaming = write });
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const cwd = "/work/failed-create";
    for (0..retained_threads) |_| {
        var thread = try create(std.testing.allocator, std.testing.io, home, cwd, .chatgpt, "original", null, false);
        defer thread.deinit();
        var file = try Io.Dir.cwd().openFile(std.testing.io, thread.path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } } });
    }
    const before = try list(std.testing.allocator, std.testing.io, home, cwd, null, retained_threads + 1);
    defer freeSummaries(std.testing.allocator, before);
    var failing_vtable = std.testing.io.vtable.*;
    failing_vtable.operate = FailMetadata.operate;
    const failing_io: Io = .{ .userdata = std.testing.io.userdata, .vtable = &failing_vtable };
    try std.testing.expectError(error.NoSpaceLeft, create(std.testing.allocator, failing_io, home, cwd, .chatgpt, "not-created", null, false));
    const after = try list(std.testing.allocator, std.testing.io, home, cwd, null, retained_threads + 1);
    defer freeSummaries(std.testing.allocator, after);
    try std.testing.expectEqual(retained_threads, after.len);
    for (before, after) |old, remaining| try std.testing.expectEqualStrings(old.id, remaining.id);

    // Successful creation still applies the retention limit.
    var created = try create(std.testing.allocator, std.testing.io, home, cwd, .chatgpt, "created", null, false);
    defer created.deinit();
    const retained = try list(std.testing.allocator, std.testing.io, home, cwd, null, retained_threads + 1);
    defer freeSummaries(std.testing.allocator, retained);
    try std.testing.expectEqual(retained_threads, retained.len);
    try std.testing.expectEqualStrings(created.id, retained[0].id);
}

test "thread ownership excludes other sessions across append and atomic rewrite" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cwd = "/work/ownership";
    const id = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, cwd, .chatgpt, "model-a", null, true);
        defer thread.deinit();
        try std.testing.expectError(error.ThreadInUse, load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, thread.id, null));
        try thread.appendEntry(.{ .user = .{ .text = "before compaction" } });
        try thread.rewrite(.chatgpt, "model-b", "high", true, cwd, &.{.{ .user = .{ .text = "compacted" } }});
        // Renaming the JSONL must not release the session's ownership.
        try std.testing.expectError(error.ThreadInUse, load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, null, null));
        try thread.appendEntry(.{ .user = .{ .text = "after compaction" } });
        break :blk try std.testing.allocator.dupe(u8, thread.id);
    };
    defer std.testing.allocator.free(id);

    {
        var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, id, null);
        defer loaded.thread.deinit();
        try std.testing.expectEqualStrings("model-b", loaded.model);
        try std.testing.expect(loaded.fast);
        try std.testing.expectEqual(@as(usize, 2), loaded.entries.items.len);
        try std.testing.expectEqualStrings("compacted", loaded.entries.items[0].user.text);
        try std.testing.expectEqualStrings("after compaction", loaded.entries.items[1].user.text);
        try std.testing.expectError(error.ThreadInUse, load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, id, null));
        try loaded.thread.appendEntry(.{ .user = .{ .text = "resumed" } });
    }
    var resumed = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, id, null);
    defer resumed.thread.deinit();
    try std.testing.expectEqualStrings("resumed", resumed.entries.items[2].user.text);
}

test "pruning protects an idle active thread and releases ownership after close" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const cwd = "/work/prune-active";
    const dir_path = try threadDir(std.testing.allocator, home, cwd);
    defer std.testing.allocator.free(dir_path);
    const path = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, cwd, .chatgpt, "model-a", null, false);
        defer thread.deinit();
        var file = try Io.Dir.cwd().openFile(std.testing.io, thread.path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } } });
        try pruneDir(std.testing.allocator, std.testing.io, dir_path, 0);
        // Appending proves pruning left the meta-bearing data file in place.
        try thread.appendEntry(.{ .user = .{ .text = "still active" } });
        try file.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } } });
        break :blk try std.testing.allocator.dupe(u8, thread.path);
    };
    defer std.testing.allocator.free(path);
    try pruneDir(std.testing.allocator, std.testing.io, dir_path, 0);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(std.testing.io, path, .{}));
}

test "failed thread loads release ownership" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const cwd = "/work/invalid-owned";
    const id = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, cwd, .chatgpt, "model-a", null, false);
        defer thread.deinit();
        try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = thread.path, .data = "{}\n" });
        break :blk try std.testing.allocator.dupe(u8, thread.id);
    };
    defer std.testing.allocator.free(id);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..2) |_| try std.testing.expectError(error.InvalidThread, load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, id, null));
}

test "thread JSONL resumes state after the last reset" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const id = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, "/work/project", .chatgpt, "model-a", "high", true);
        defer thread.deinit();
        try thread.appendEntry(.{ .user = .{ .text = "old" } });
        const scratch_capacity = thread.scratch.writer.buffer.len;
        try thread.appendReset();
        try thread.appendEntry(.{ .user = .{ .text = "new" } });
        try std.testing.expectEqual(scratch_capacity, thread.scratch.writer.buffer.len);
        try thread.appendFast(false);
        try thread.appendProvider("claude");
        try thread.appendProvider("not-a-provider");
        const summaries = try list(std.testing.allocator, std.testing.io, home, "/work/project", null, 8);
        defer freeSummaries(std.testing.allocator, summaries);
        try std.testing.expectEqual(@as(usize, 1), summaries.len);
        try std.testing.expectEqualStrings(thread.id, summaries[0].id);
        try std.testing.expectEqualStrings("old", summaries[0].preview);
        const excluded = try list(std.testing.allocator, std.testing.io, home, "/work/project", thread.id, 8);
        defer freeSummaries(std.testing.allocator, excluded);
        try std.testing.expectEqual(@as(usize, 0), excluded.len);

        break :blk try std.testing.allocator.dupe(u8, thread.id);
    };
    defer std.testing.allocator.free(id);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, "/work/project", id, null);
    defer loaded.thread.deinit();
    try std.testing.expectEqual(auth.Provider.claude, loaded.provider);
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
    const image_data = try std.testing.allocator.alloc(u8, preview_scan_bytes + 1024);
    defer std.testing.allocator.free(image_data);
    @memset(image_data, 'A');
    const image: types.Image = .{ .name = "shot.png", .media_type = "image/png", .data = image_data };
    const id = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, "/work/images", .chatgpt, "model-a", null, false);
        defer thread.deinit();
        try thread.appendEntry(.{ .user = .{ .text = "look", .images = &.{image} } });

        const summaries = try list(std.testing.allocator, std.testing.io, home, "/work/images", null, 8);
        defer freeSummaries(std.testing.allocator, summaries);
        try std.testing.expectEqualStrings("look", summaries[0].preview);

        break :blk try std.testing.allocator.dupe(u8, thread.id);
    };
    defer std.testing.allocator.free(id);

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

test "thread selection records apply together and clear replay items only on provider changes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const cwd = "/work/selection";
    const raw = "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}";
    const id = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, cwd, .chatgpt, "model-a", "high", true);
        defer thread.deinit();
        try thread.appendEntry(.{ .assistant = .{ .text = "answer", .calls = &.{}, .raw_items = &.{raw} } });
        try thread.appendSelection(.chatgpt, "model-b", null, false);
        break :blk try std.testing.allocator.dupe(u8, thread.id);
    };
    defer std.testing.allocator.free(id);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, id, null);
        defer loaded.thread.deinit();
        try std.testing.expectEqual(auth.Provider.chatgpt, loaded.provider);
        try std.testing.expectEqualStrings("model-b", loaded.model);
        try std.testing.expectEqual(null, loaded.effort);
        try std.testing.expect(!loaded.fast);
        try std.testing.expectEqualStrings(raw, loaded.entries.items[0].assistant.raw_items[0]);
        try loaded.thread.appendSelection(.claude, "model-c", "medium", true);
        // A malformed tuple must not change even its valid fields.
        try append(std.testing.io, loaded.thread.path, "{\"type\":\"selection\",\"provider\":\"grok\",\"model\":\"broken\",\"effort\":null,\"fast\":\"wrong type\"}\n");
        // A partially written next selection is ignored on replay.
        try append(std.testing.io, loaded.thread.path, "{\"type\":\"selection\",\"provider\":\"grok\"");
    }
    var resumed = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, id, null);
    defer resumed.thread.deinit();
    try std.testing.expectEqual(auth.Provider.claude, resumed.provider);
    try std.testing.expectEqualStrings("model-c", resumed.model);
    try std.testing.expectEqualStrings("medium", resumed.effort.?);
    try std.testing.expect(resumed.fast);
    try std.testing.expectEqualStrings("answer", resumed.entries.items[0].assistant.text);
    try std.testing.expectEqual(@as(usize, 0), resumed.entries.items[0].assistant.raw_items.len);
}

test "thread appends recover an interrupted tail and preserve complete unterminated entries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const id = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, "/work/interrupted", .chatgpt, "model-a", null, false);
        defer thread.deinit();
        try thread.appendEntry(.{ .user = .{ .text = "before" } });
        try append(std.testing.io, thread.path, "{\"type\":\"user\",\"text\":\"interrupted");
        try thread.appendEntry(.{ .user = .{ .text = "after" } });
        try append(std.testing.io, thread.path, "{\"type\":\"user\",\"text\":\"without newline\"}");
        try thread.appendEntry(.{ .user = .{ .text = "last" } });

        break :blk try std.testing.allocator.dupe(u8, thread.id);
    };
    defer std.testing.allocator.free(id);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, "/work/interrupted", id, null);
    defer loaded.thread.deinit();
    const expected = [_][]const u8{ "before", "after", "without newline", "last" };
    try std.testing.expectEqual(expected.len, loaded.entries.items.len);
    for (expected, loaded.entries.items) |text, entry| try std.testing.expectEqualStrings(text, entry.user.text);
}

test "failed selection append rolls back a complete JSON object without its newline" {
    const FailFinalNewline = struct {
        fn write(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
            if (header.len <= 1) return error.NoSpaceLeft;
            return std.testing.io.vtable.fileWritePositional(userdata, file, header[0 .. header.len - 1], data, splat, offset);
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const cwd = "/work/failed-selection";
    const id = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, cwd, .chatgpt, "original", "high", true);
        defer thread.deinit();
        const before = try Io.Dir.cwd().readFileAlloc(std.testing.io, thread.path, std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(before);
        var failing_vtable = std.testing.io.vtable.*;
        failing_vtable.fileWritePositional = FailFinalNewline.write;
        thread.io = .{ .userdata = std.testing.io.userdata, .vtable = &failing_vtable };
        try std.testing.expectError(error.WriteFailed, thread.appendSelection(.claude, "not-applied", null, false));
        thread.io = std.testing.io;
        const after = try Io.Dir.cwd().readFileAlloc(std.testing.io, thread.path, std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(before, after);
        try thread.appendEntry(.{ .user = .{ .text = "after failure" } });
        break :blk try std.testing.allocator.dupe(u8, thread.id);
    };
    defer std.testing.allocator.free(id);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, cwd, id, null);
    defer loaded.thread.deinit();
    try std.testing.expectEqual(auth.Provider.chatgpt, loaded.provider);
    try std.testing.expectEqualStrings("original", loaded.model);
    try std.testing.expectEqualStrings("high", loaded.effort.?);
    try std.testing.expect(loaded.fast);
    try std.testing.expectEqualStrings("after failure", loaded.entries.items[0].user.text);
}

test "thread previews decode escapes and keep the first line" {
    const cases = .{
        .{ "first\\nsecond", "first" },
        .{ "first\\r\\nsecond", "first" },
        .{ "caf\\u00e9 \\ud83d\\ude80 \\u006f\\u006b", "café 🚀 ok" },
        .{ "tab\\tand\\u001b", "tab and " },
        .{ "quoted \\\"text\\\"", "quoted \"text\"" },
    };
    inline for (cases) |case| {
        // The image payload need not be complete for a preview to render.
        const preview = previewFromUserLine(std.testing.allocator, "{\"type\":\"user\",\"text\":\"" ++ case[0] ++ "\",\"images\":[").?;
        defer std.testing.allocator.free(preview);
        try std.testing.expectEqualStrings(case[1], preview);
    }
}

test "thread previews truncate UTF-8 safely for either JSON field order" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const prefix = "a" ** (preview_max_bytes - 1);
    const lines = .{
        "{\"type\":\"user\",\"text\":\"" ++ prefix ++ "é tail\"}\n",
        "{\"text\":\"" ++ prefix ++ "é tail\",\"type\":\"user\"}\n",
    };
    inline for (lines, 0..) |line, index| {
        const cwd = "/work/preview-" ++ std.fmt.comptimePrint("{d}", .{index});
        var thread = try create(std.testing.allocator, std.testing.io, home, cwd, .chatgpt, "model-a", null, false);
        defer thread.deinit();
        try append(std.testing.io, thread.path, line);
        const summaries = try list(std.testing.allocator, std.testing.io, home, cwd, null, 8);
        defer freeSummaries(std.testing.allocator, summaries);
        try std.testing.expectEqual(@as(usize, 1), summaries.len);
        try std.testing.expectEqualStrings(prefix, summaries[0].preview);
    }
}

test "thread loader streams files larger than the former aggregate cap" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(home);
    const id = blk: {
        var thread = try create(std.testing.allocator, std.testing.io, home, "/work/large-thread", .chatgpt, "model-a", null, false);
        defer thread.deinit();
        const padding = try std.testing.allocator.alloc(u8, 1024 * 1024);
        defer std.testing.allocator.free(padding);
        @memset(padding, ' ');
        padding[padding.len - 1] = '\n';
        for (0..65) |_| try append(std.testing.io, thread.path, padding);
        try thread.appendEntry(.{ .user = .{ .text = "still resumable" } });

        break :blk try std.testing.allocator.dupe(u8, thread.id);
    };
    defer std.testing.allocator.free(id);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loaded = try load(std.testing.allocator, arena.allocator(), std.testing.io, home, "/work/large-thread", id, null);
    defer loaded.thread.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    try std.testing.expectEqualStrings("still resumable", loaded.entries.items[0].user.text);
}
