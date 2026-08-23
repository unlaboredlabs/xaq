const std = @import("std");
const Io = std.Io;
const cancel = @import("cancel.zig");

pub const default_max_concurrent = 4;
const max_records = 32;
const result_limit = 50 * 1024;

pub const Status = enum { queued, running, completed, failed, stopped };

pub const Launch = struct {
    provider: []const u8,
    model: []const u8,
    effort: ?[]const u8,
    fast: bool,
};

pub const Counts = struct {
    running: usize = 0,
    queued: usize = 0,
};

/// One agent's compact state for the fullscreen panel and `/agents`.
/// Slices borrow record memory and stay valid until the next manager call.
pub const PanelInfo = struct {
    id: []const u8,
    status: Status,
    started_ms: i64,
    completed_ms: ?i64,
    model: []const u8,
    effort: ?[]const u8,
    description: []const u8,
    /// Composed live heartbeat ("Editing src/auth.zig · turn 3 · ↑48.2k"),
    /// empty until the worker reports one.
    activity: []const u8,
    /// Last stderr line for failed agents, empty otherwise.
    failure: []const u8,
};

pub const PanelCounts = struct { shown: usize = 0, total: usize = 0 };

pub const Config = struct {
    enabled: bool = true,
    max_concurrent: u8 = default_max_concurrent,
    background_by_default: bool = true,
};

const Record = struct {
    id: []u8,
    description: []u8,
    provider: []u8,
    model: []u8,
    effort: ?[]u8,
    fast: bool,
    background: bool,
    status: Status,
    started_ms: i64,
    completed_ms: ?i64 = null,
    prompt_path: []u8,
    output_path: []u8,
    error_path: []u8,
    done_path: []u8,
    control_path: []u8,
    status_path: []u8,
    process: ?std.process.Child = null,
    error_text: ?[]u8 = null,
    /// Raw last heartbeat payload, kept to skip recomposing unchanged reads.
    status_bytes: ?[]u8 = null,
    activity: ?[]u8 = null,
    failure_line: ?[]u8 = null,
    steers: std.ArrayList([]u8) = .empty,
    notified: bool = false,
    consumed: bool = false,

    fn deinit(self: *Record, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.description);
        gpa.free(self.provider);
        gpa.free(self.model);
        if (self.effort) |value| gpa.free(value);
        gpa.free(self.prompt_path);
        gpa.free(self.output_path);
        gpa.free(self.error_path);
        gpa.free(self.done_path);
        gpa.free(self.control_path);
        gpa.free(self.status_path);
        if (self.error_text) |text| gpa.free(text);
        if (self.status_bytes) |bytes| gpa.free(bytes);
        if (self.activity) |text| gpa.free(text);
        if (self.failure_line) |line| gpa.free(line);
        for (self.steers.items) |message| gpa.free(message);
        self.steers.deinit(gpa);
        gpa.destroy(self);
    }
};

pub const Manager = struct {
    gpa: std.mem.Allocator,
    io: Io,
    executable: [:0]u8,
    cwd: []u8,
    config: Config,
    temp_dir: ?[]u8 = null,
    records: std.ArrayList(*Record) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io, cwd: []const u8, config: Config) !Manager {
        try validateConfig(config);
        const executable = try std.process.executablePathAlloc(io, gpa);
        errdefer gpa.free(executable);
        return .{
            .gpa = gpa,
            .io = io,
            .executable = executable,
            .cwd = try gpa.dupe(u8, cwd),
            .config = config,
        };
    }

    pub fn configure(self: *Manager, config: Config) !void {
        try validateConfig(config);
        self.config = config;
        try self.refreshAll();
    }

    pub fn deinit(self: *Manager) void {
        self.stopAll();
        self.freeRecords();
        if (self.temp_dir) |path| {
            Io.Dir.cwd().deleteTree(self.io, path) catch {};
            self.gpa.free(path);
        }
        self.gpa.free(self.cwd);
        self.gpa.free(self.executable);
    }

    pub fn reset(self: *Manager) void {
        self.stopAll();
        self.freeRecords();
        if (self.temp_dir) |path| {
            Io.Dir.cwd().deleteTree(self.io, path) catch {};
            self.gpa.free(path);
            self.temp_dir = null;
        }
    }

    fn freeRecords(self: *Manager) void {
        for (self.records.items) |record| record.deinit(self.gpa);
        self.records.deinit(self.gpa);
        self.records = .empty;
    }

    fn stopAll(self: *Manager) void {
        for (self.records.items) |record| {
            if (record.status == .running) self.stop(record);
        }
    }

    fn stop(self: *Manager, record: *Record) void {
        if (record.process) |*child| {
            if (child.id) |pid| {
                std.posix.kill(-pid, .KILL) catch {};
                _ = child.wait(self.io) catch {};
            }
        }
        record.status = .stopped;
        record.completed_ms = nowMs(self.io);
    }

    pub fn execute(self: *Manager, gpa: std.mem.Allocator, name: []const u8, args: std.json.Value, launch: Launch) ![]u8 {
        if (std.mem.eql(u8, name, "Agent")) return self.agent(gpa, args, launch);
        if (std.mem.eql(u8, name, "get_subagent_result")) return self.getResult(gpa, args);
        if (std.mem.eql(u8, name, "steer_subagent")) return self.steer(gpa, args);
        return error.UnknownSubagentTool;
    }

    pub fn counts(self: *const Manager) Counts {
        var out: Counts = .{};
        for (self.records.items) |record| switch (record.status) {
            .running => out.running += 1,
            .queued => out.queued += 1,
            else => {},
        };
        return out;
    }

    pub fn formatList(self: *Manager, gpa: std.mem.Allocator) ![]u8 {
        try self.refreshAll();
        if (self.records.items.len == 0) return gpa.dupe(u8, "no subagents in this session\n");
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        for (self.records.items) |record| {
            try out.writer.print("  {s:<18} {s:<10} {s}", .{ record.id, @tagName(record.status), record.model });
            if (record.effort) |effort| try out.writer.print("/{s}", .{effort});
            try out.writer.print("  {s}", .{record.description});
            if (record.completed_ms) |finished|
                try out.writer.print(" · {s}", .{formatDuration(finished - record.started_ms)})
            else if (record.status == .running)
                try out.writer.print(" · {s}", .{formatDuration(nowMs(self.io) - record.started_ms)});
            try out.writer.writeByte('\n');
            if (record.status == .running) {
                if (record.activity) |activity| try out.writer.print("      {s}\n", .{activity});
            } else if (record.status == .failed) {
                self.captureFailureLine(record);
                if (record.failure_line) |line| try out.writer.print("      {s}\n", .{line});
            }
        }
        return out.toOwnedSlice();
    }

    /// True when a panel would have anything to show; cheap, no file IO.
    pub fn hasVisibleAgents(self: *const Manager) bool {
        for (self.records.items) |record| {
            const live = record.status == .running or record.status == .queued;
            if (live or !(record.consumed or record.notified)) return true;
        }
        return false;
    }

    /// Fill `out` with the agents a status panel should show: everything
    /// running or queued, plus finished agents whose result the parent has
    /// not yet seen. Returns how many were written and the eligible total.
    pub fn panelSnapshot(self: *Manager, out: []PanelInfo) PanelCounts {
        self.refreshAll() catch {};
        var tally: PanelCounts = .{};
        for (self.records.items) |record| {
            const live = record.status == .running or record.status == .queued;
            if (!live and (record.consumed or record.notified)) continue;
            tally.total += 1;
            if (tally.shown == out.len) continue;
            if (record.status == .failed) self.captureFailureLine(record);
            out[tally.shown] = .{
                .id = record.id,
                .status = record.status,
                .started_ms = record.started_ms,
                .completed_ms = record.completed_ms,
                .model = record.model,
                .effort = record.effort,
                .description = record.description,
                .activity = if (record.status == .running) record.activity orelse "" else "",
                .failure = record.failure_line orelse "",
            };
            tally.shown += 1;
        }
        return tally;
    }

    pub fn takeNotifications(self: *Manager, gpa: std.mem.Allocator) !?[]u8 {
        try self.refreshAll();
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var count: usize = 0;
        for (self.records.items) |record| {
            if (!record.background or record.notified or record.consumed) continue;
            if (record.status == .queued or record.status == .running) continue;
            const result = try self.resultText(gpa, record, false);
            defer gpa.free(result);
            try out.writer.print("<subagent-notification>\nAgent {s} finished with status {s}.\nDescription: {s}\n{s}\n</subagent-notification>\n", .{ record.id, @tagName(record.status), record.description, result });
            record.notified = true;
            count += 1;
        }
        if (count == 0) return null;
        return try out.toOwnedSlice();
    }

    fn agent(self: *Manager, gpa: std.mem.Allocator, args: std.json.Value, launch: Launch) ![]u8 {
        if (!self.config.enabled) return gpa.dupe(u8, "subagents are disabled in /settings");
        if (self.records.items.len >= max_records) return gpa.dupe(u8, "subagent limit reached for this session");
        const prompt = try fieldString(args, "prompt");
        const description = try fieldString(args, "description");
        if (prompt.len > 4 * 1024 * 1024 - 1024) return gpa.dupe(u8, "subagent prompt is too large");
        if (description.len > 120) return gpa.dupe(u8, "subagent description exceeds 120 bytes");
        const background = optionalBool(args, "run_in_background") orelse self.config.background_by_default;
        const model_override = optionalString(args, "model");
        const selected_model = model_override orelse launch.model;

        try self.ensureTempDir();
        var random: [6]u8 = undefined;
        try self.io.randomSecure(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const id = try std.fmt.allocPrint(self.gpa, "agent-{s}", .{&hex});
        errdefer self.gpa.free(id);
        const prompt_path = try self.pathFor(id, "prompt");
        errdefer self.gpa.free(prompt_path);
        const output_path = try self.pathFor(id, "output");
        errdefer self.gpa.free(output_path);
        const error_path = try self.pathFor(id, "error");
        errdefer self.gpa.free(error_path);
        const done_path = try self.pathFor(id, "done");
        errdefer self.gpa.free(done_path);
        const control_path = try self.pathFor(id, "steer");
        errdefer self.gpa.free(control_path);
        const status_path = try self.pathFor(id, "status");
        errdefer self.gpa.free(status_path);

        const briefing = try buildBriefing(gpa, prompt);
        defer gpa.free(briefing);
        try writePrivate(self.io, prompt_path, briefing);
        try writePrivate(self.io, control_path, "");

        const record = try self.gpa.create(Record);
        errdefer self.gpa.destroy(record);
        record.* = .{
            .id = id,
            .description = try self.gpa.dupe(u8, description),
            .provider = try self.gpa.dupe(u8, launch.provider),
            .model = try self.gpa.dupe(u8, selected_model),
            // An override may have a different effort/fast contract. Let the
            // provider choose safe defaults instead of failing the worker at
            // startup with inherited settings it does not support.
            .effort = if (model_override == null) if (launch.effort) |value| try self.gpa.dupe(u8, value) else null else null,
            .fast = model_override == null and launch.fast,
            .background = background,
            .status = if (background and self.counts().running >= self.config.max_concurrent) .queued else .running,
            .started_ms = nowMs(self.io),
            .prompt_path = prompt_path,
            .output_path = output_path,
            .error_path = error_path,
            .done_path = done_path,
            .control_path = control_path,
            .status_path = status_path,
        };
        try self.records.append(self.gpa, record);
        errdefer _ = self.records.pop();

        if (record.status == .running) self.start(record) catch |err| {
            record.status = .failed;
            record.completed_ms = nowMs(self.io);
            record.error_text = try std.fmt.allocPrint(self.gpa, "could not start subagent: {s}", .{@errorName(err)});
        };
        if (!background) {
            try self.waitFor(record, true);
            record.consumed = true;
            return self.resultText(gpa, record, true);
        }
        if (record.status == .failed) {
            record.consumed = true;
            return self.resultText(gpa, record, true);
        }
        return std.fmt.allocPrint(gpa, "Agent {s} {s} in background.\nDescription: {s}\nUse get_subagent_result with wait: true when the result is needed.", .{ record.id, if (record.status == .queued) "queued" else "started", record.description });
    }

    fn getResult(self: *Manager, gpa: std.mem.Allocator, args: std.json.Value) ![]u8 {
        const id = try fieldString(args, "agent_id");
        const resolved = self.resolve(id) catch return try gpa.dupe(u8, "agent reference is ambiguous");
        const record = resolved orelse return std.fmt.allocPrint(gpa, "agent not found: {s}", .{id});
        if (optionalBool(args, "wait") orelse false) try self.waitFor(record, false) else try self.refreshAll();
        if (record.status != .running and record.status != .queued) record.consumed = true;
        return self.resultText(gpa, record, true);
    }

    fn steer(self: *Manager, gpa: std.mem.Allocator, args: std.json.Value) ![]u8 {
        const id = try fieldString(args, "agent_id");
        const message = try fieldString(args, "message");
        if (message.len > 64 * 1024) return gpa.dupe(u8, "steering message exceeds 64 KiB");
        const resolved = self.resolve(id) catch return try gpa.dupe(u8, "agent reference is ambiguous");
        const record = resolved orelse return std.fmt.allocPrint(gpa, "agent not found: {s}", .{id});
        try self.refresh(record);
        if (record.status != .running and record.status != .queued) {
            return std.fmt.allocPrint(gpa, "agent {s} is not running (status: {s})", .{ record.id, @tagName(record.status) });
        }
        try record.steers.append(self.gpa, try self.gpa.dupe(u8, message));
        var contents: Io.Writer.Allocating = .init(gpa);
        defer contents.deinit();
        var js: std.json.Stringify = .{ .writer = &contents.writer };
        for (record.steers.items) |item| {
            try js.write(item);
            try contents.writer.writeByte('\n');
        }
        try atomicWrite(self.gpa, self.io, record.control_path, contents.written());
        return std.fmt.allocPrint(gpa, "Steering message queued for {s}. The agent will read it before its next model turn.", .{record.id});
    }

    fn ensureTempDir(self: *Manager) !void {
        if (self.temp_dir != null) return;
        var random: [8]u8 = undefined;
        try self.io.randomSecure(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const path = try std.fmt.allocPrint(self.gpa, "/tmp/xaq-subagents-{s}", .{&hex});
        errdefer self.gpa.free(path);
        try Io.Dir.cwd().createDir(self.io, path, @enumFromInt(0o700));
        self.temp_dir = path;
    }

    fn pathFor(self: *Manager, id: []const u8, suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}.{s}", .{ self.temp_dir.?, id, suffix });
    }

    fn start(self: *Manager, record: *Record) !void {
        const script =
            \\set -u
            \\exe=$1
            \\provider=$2
            \\model=$3
            \\effort=$4
            \\fast=$5
            \\control=$6
            \\status=$7
            \\prompt=$8
            \\output=$9
            \\errors=${10}
            \\done_file=${11}
            \\set -- "$exe" --provider "$provider" --model "$model" --subagent-control "$control" --subagent-status "$status"
            \\if [ "$effort" != "-" ]; then set -- "$@" --effort "$effort"; fi
            \\if [ "$fast" = "1" ]; then set -- "$@" --fast; fi
            \\"$@" < "$prompt" > "$output" 2> "$errors"
            \\code=$?
            \\tmp="${done_file}.tmp.$$"
            \\printf '%s\n' "$code" > "$tmp"
            \\mv "$tmp" "$done_file"
            \\exit "$code"
        ;
        const argv = [_][]const u8{
            "/bin/sh",                     "-c",                script,             "xaq-subagent",
            self.executable,               record.provider,     record.model,       record.effort orelse "-",
            if (record.fast) "1" else "0", record.control_path, record.status_path, record.prompt_path,
            record.output_path,            record.error_path,   record.done_path,
        };
        record.process = try std.process.spawn(self.io, .{
            .argv = &argv,
            .cwd = .{ .path = self.cwd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        });
        record.status = .running;
        record.started_ms = nowMs(self.io);
    }

    fn refreshAll(self: *Manager) !void {
        for (self.records.items) |record| try self.refresh(record);
        try self.drainQueue();
    }

    fn refresh(self: *Manager, record: *Record) !void {
        if (record.status != .running) return;
        self.refreshWorkerStatus(record);
        const done = Io.Dir.cwd().readFileAlloc(self.io, record.done_path, self.gpa, .limited(64)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.gpa.free(done);
        if (record.process) |*child| {
            if (child.id != null) _ = child.wait(self.io) catch {};
        }
        const code = std.fmt.parseInt(u8, std.mem.trim(u8, done, " \r\n\t"), 10) catch 1;
        record.status = if (code == 0) .completed else .failed;
        record.completed_ms = nowMs(self.io);
        if (record.status == .failed) self.captureFailureLine(record);
    }

    /// Best-effort read of the worker's heartbeat file. Unchanged payloads
    /// are skipped; a torn or malformed file just keeps the previous line.
    fn refreshWorkerStatus(self: *Manager, record: *Record) void {
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, record.status_path, self.gpa, .limited(4096)) catch return;
        if (record.status_bytes) |previous| {
            if (std.mem.eql(u8, previous, bytes)) {
                self.gpa.free(bytes);
                return;
            }
            self.gpa.free(previous);
        }
        record.status_bytes = bytes;
        const composed = composeWorkerStatus(self.gpa, bytes) orelse return;
        if (record.activity) |old| self.gpa.free(old);
        record.activity = composed;
    }

    /// Memoize a one-line failure hint: the spawn diagnostic when there is
    /// one, otherwise the last non-empty stderr line.
    fn captureFailureLine(self: *Manager, record: *Record) void {
        if (record.failure_line != null) return;
        if (record.error_text) |text| {
            record.failure_line = dupeHintLine(self.gpa, firstLine(text)) catch null;
            return;
        }
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, record.error_path, self.gpa, .limited(16 * 1024)) catch return;
        defer self.gpa.free(bytes);
        var line: []const u8 = "";
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |candidate| {
            const trimmed = std.mem.trim(u8, candidate, " \r\t");
            if (trimmed.len > 0) line = trimmed;
        }
        if (line.len == 0) return;
        record.failure_line = dupeHintLine(self.gpa, line) catch null;
    }

    fn drainQueue(self: *Manager) !void {
        if (!self.config.enabled) return;
        var running = self.counts().running;
        for (self.records.items) |record| {
            if (running >= self.config.max_concurrent) break;
            if (record.status != .queued) continue;
            self.start(record) catch |err| {
                record.status = .failed;
                record.completed_ms = nowMs(self.io);
                record.error_text = try std.fmt.allocPrint(self.gpa, "could not start subagent: {s}", .{@errorName(err)});
                continue;
            };
            running += 1;
        }
    }

    fn waitFor(self: *Manager, record: *Record, stop_on_cancel: bool) !void {
        while (record.status == .queued or record.status == .running) {
            try self.refreshAll();
            if (record.status != .queued and record.status != .running) break;
            if (cancel.requested()) {
                if (stop_on_cancel and record.status == .running) self.stop(record);
                return;
            }
            try self.io.sleep(.fromMilliseconds(50), .awake);
        }
    }

    fn resolve(self: *Manager, id: []const u8) error{Ambiguous}!?*Record {
        for (self.records.items) |record| if (std.mem.eql(u8, record.id, id)) return record;
        var found: ?*Record = null;
        for (self.records.items) |record| {
            if (!std.mem.startsWith(u8, record.id, id)) continue;
            if (found != null) return error.Ambiguous;
            found = record;
        }
        return found;
    }

    fn resultText(self: *Manager, gpa: std.mem.Allocator, record: *Record, include_header: bool) ![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        if (include_header) {
            try out.writer.print("Agent: {s}\nStatus: {s}", .{ record.id, @tagName(record.status) });
            if (record.completed_ms) |finished| try out.writer.print(" | Duration: {s}", .{formatDuration(finished - record.started_ms)});
            try out.writer.print("\nDescription: {s}\n", .{record.description});
        }
        switch (record.status) {
            .queued => try out.writer.writeAll("Agent is queued behind the concurrency limit."),
            .running => try out.writer.writeAll("Agent is still running. Use wait: true when its result is needed."),
            .stopped => try out.writer.writeAll("Agent was stopped."),
            .completed, .failed => {
                const answer = self.readCapped(gpa, record.output_path) catch |err| switch (err) {
                    error.FileNotFound => try gpa.dupe(u8, ""),
                    else => return err,
                };
                defer gpa.free(answer);
                if (answer.len > 0) {
                    if (include_header) try out.writer.writeAll("\nResult:\n");
                    try out.writer.writeAll(answer);
                } else if (record.status == .completed) {
                    try out.writer.writeAll("\nNo output.");
                }
                if (record.status == .failed) {
                    const diagnostic = if (record.error_text) |text|
                        try gpa.dupe(u8, text)
                    else
                        self.readCapped(gpa, record.error_path) catch |err| switch (err) {
                            error.FileNotFound => try gpa.dupe(u8, "subagent process failed"),
                            else => return err,
                        };
                    defer gpa.free(diagnostic);
                    if (diagnostic.len > 0) try out.writer.print("\nError:\n{s}", .{diagnostic});
                }
            },
        }
        const text = try out.toOwnedSlice();
        if (text.len <= result_limit) return text;
        var capped: Io.Writer.Allocating = .init(gpa);
        defer capped.deinit();
        try capped.writer.writeAll(text[0 .. result_limit - 192]);
        try capped.writer.print("\n[truncated; full output: {s}; errors: {s}]", .{ record.output_path, record.error_path });
        gpa.free(text);
        return capped.toOwnedSlice();
    }

    fn readCapped(self: *Manager, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        var file = try Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > 4 * 1024 * 1024) return error.StreamTooLong;
        const truncated = stat.size > result_limit;
        const read_len: usize = @intCast(if (truncated) result_limit - 96 else stat.size);
        const bytes = try gpa.alloc(u8, read_len);
        errdefer gpa.free(bytes);
        var read_buffer: [8192]u8 = undefined;
        var reader: Io.File.Reader = .init(file, self.io, &read_buffer);
        try reader.interface.readSliceAll(bytes);
        if (!truncated) return bytes;
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try out.writer.writeAll(bytes);
        try out.writer.print("\n[truncated; full subagent output: {s}]", .{path});
        gpa.free(bytes);
        return out.toOwnedSlice();
    }
};

fn validateConfig(config: Config) !void {
    if (config.max_concurrent < 1 or config.max_concurrent > 8) return error.InvalidSubagentConcurrency;
}

fn buildBriefing(gpa: std.mem.Allocator, prompt: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\You are a subagent working for another coding agent. Handle the task autonomously. You may inspect and edit files, run checks, and leave the working tree in a verified state.
        \\The parent has not shared its conversation. Work from this self-contained brief, do not ask the user questions, and return a concise factual report for the parent.
        \\
        \\Task:
        \\{s}
    , .{prompt});
}

fn fieldString(args: std.json.Value, key: []const u8) ![]const u8 {
    const value = switch (args) {
        .object => |object| object.get(key) orelse return error.MissingField,
        else => return error.InvalidArguments,
    };
    return switch (value) {
        .string => |text| text,
        else => error.InvalidArguments,
    };
}

fn optionalString(args: std.json.Value, key: []const u8) ?[]const u8 {
    const value = switch (args) {
        .object => |object| object.get(key) orelse return null,
        else => return null,
    };
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalBool(args: std.json.Value, key: []const u8) ?bool {
    const value = switch (args) {
        .object => |object| object.get(key) orelse return null,
        else => return null,
    };
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

const hint_line_max = 160;

/// Copy a diagnostic line with control bytes blanked and length capped, so
/// worker stderr cannot smuggle escape sequences into the chrome.
fn dupeHintLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    var clamped = @min(line.len, hint_line_max);
    while (clamped > 0 and !std.unicode.utf8ValidateSlice(line[0..clamped])) clamped -= 1;
    if (clamped == 0) return null;
    const copy = try gpa.dupe(u8, line[0..clamped]);
    for (copy) |*byte| {
        if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
    }
    return copy;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \r\t");
}

/// Parse one heartbeat payload written by the worker and compose the
/// display line shown in the panel and `/agents`. Null keeps the previous.
fn composeWorkerStatus(gpa: std.mem.Allocator, bytes: []const u8) ?[]u8 {
    const WorkerStatus = struct {
        state: []const u8 = "",
        activity: []const u8 = "",
        turn: u64 = 0,
        input: u64 = 0,
        output: u64 = 0,
        percent: u8 = 0,
    };
    var parsed = std.json.parseFromSlice(WorkerStatus, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const status = parsed.value;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const label = if (status.activity.len > 0) status.activity else status.state;
    if (label.len == 0) return null;
    writeSanitized(&out.writer, label, hint_line_max) catch return null;
    if (status.turn > 0) out.writer.print(" · turn {d}", .{status.turn}) catch return null;
    if (status.input + status.output > 0) {
        out.writer.writeAll(" · \u{2191}") catch return null;
        writeCount(&out.writer, status.input) catch return null;
        out.writer.writeAll(" \u{2193}") catch return null;
        writeCount(&out.writer, status.output) catch return null;
    }
    return out.toOwnedSlice() catch null;
}

fn writeSanitized(writer: *Io.Writer, text: []const u8, limit: usize) !void {
    var clamped = @min(text.len, limit);
    while (clamped > 0 and !std.unicode.utf8ValidateSlice(text[0..clamped])) clamped -= 1;
    for (text[0..clamped]) |byte| try writer.writeByte(if (byte < 0x20 or byte == 0x7f) ' ' else byte);
}

fn writeCount(writer: *Io.Writer, count: u64) !void {
    if (count < 1000) {
        try writer.print("{d}", .{count});
    } else if (count < 1_000_000) {
        const tenths = (count + 50) / 100;
        try writer.print("{d}.{d}k", .{ tenths / 10, tenths % 10 });
    } else {
        const tenths = (count + 50_000) / 100_000;
        try writer.print("{d}.{d}m", .{ tenths / 10, tenths % 10 });
    }
}

fn writePrivate(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
}

pub fn atomicWrite(gpa: std.mem.Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(gpa, "{s}.tmp-{s}", .{ path, &hex });
    defer gpa.free(temporary);
    errdefer Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try writePrivate(io, temporary, bytes);
    try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), path, io);
}

fn nowMs(io: Io) i64 {
    return Io.Clock.real.now(io).toMilliseconds();
}

fn formatDuration(milliseconds: i64) []const u8 {
    if (milliseconds < 1000) return "<1s";
    // This buffer is thread-local so callers can use the returned slice in a
    // single formatting expression without allocating.
    const State = struct {
        threadlocal var buffer: [24]u8 = undefined;
    };
    if (milliseconds < 60_000) return std.fmt.bufPrint(&State.buffer, "{d}.{d}s", .{ @divTrunc(milliseconds, 1000), @divTrunc(@mod(milliseconds, 1000), 100) }) catch "?";
    return std.fmt.bufPrint(&State.buffer, "{d}m{d}s", .{ @divTrunc(milliseconds, 60_000), @divTrunc(@mod(milliseconds, 60_000), 1000) }) catch "?";
}

test "worker heartbeats compose into one panel line" {
    const tooling = composeWorkerStatus(std.testing.allocator,
        \\{"state":"tooling","activity":"Editing src/auth.zig","turn":3,"input":48210,"output":3122,"percent":24}
    ).?;
    defer std.testing.allocator.free(tooling);
    try std.testing.expectEqualStrings("Editing src/auth.zig · turn 3 · ↑48.2k ↓3.1k", tooling);

    const thinking = composeWorkerStatus(std.testing.allocator,
        \\{"state":"thinking","activity":"","turn":1,"input":0,"output":0,"percent":2}
    ).?;
    defer std.testing.allocator.free(thinking);
    try std.testing.expectEqualStrings("thinking · turn 1", thinking);

    const escapes = composeWorkerStatus(std.testing.allocator,
        \\{"state":"tooling","activity":"bad\u001b[2Jline"}
    ).?;
    defer std.testing.allocator.free(escapes);
    try std.testing.expectEqualStrings("bad [2Jline", escapes);

    try std.testing.expect(composeWorkerStatus(std.testing.allocator, "not json") == null);
    try std.testing.expect(composeWorkerStatus(std.testing.allocator, "{}") == null);
}

test "panel snapshot tracks unseen agents and drops consumed ones" {
    var manager = try Manager.init(std.testing.allocator, std.testing.io, "/tmp", .{});
    defer manager.deinit();
    std.testing.allocator.free(manager.executable);
    manager.executable = try std.testing.allocator.dupeZ(u8, "/bin/echo");

    var storage: [4]PanelInfo = undefined;
    try std.testing.expectEqual(PanelCounts{ .shown = 0, .total = 0 }, manager.panelSnapshot(&storage));

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"prompt":"inspect auth","description":"Inspect auth"}
    , .{});
    defer parsed.deinit();
    const launch: Launch = .{ .provider = "chatgpt", .model = "test-model", .effort = "medium", .fast = false };
    const started = try manager.execute(std.testing.allocator, "Agent", parsed.value, launch);
    defer std.testing.allocator.free(started);

    // A finished background agent stays visible until its result is seen.
    try manager.waitFor(manager.records.items[0], false);
    const counts = manager.panelSnapshot(&storage);
    try std.testing.expectEqual(PanelCounts{ .shown = 1, .total = 1 }, counts);
    try std.testing.expectEqual(Status.completed, storage[0].status);
    try std.testing.expectEqualStrings("test-model", storage[0].model);
    try std.testing.expectEqualStrings("medium", storage[0].effort.?);
    try std.testing.expectEqualStrings("Inspect auth", storage[0].description);

    const id_start = "Agent ".len;
    const id_end = std.mem.indexOfScalarPos(u8, started, id_start, ' ').?;
    const args_text = try std.fmt.allocPrint(std.testing.allocator, "{{\"agent_id\":\"{s}\"}}", .{started[id_start..id_end]});
    defer std.testing.allocator.free(args_text);
    var result_args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, args_text, .{});
    defer result_args.deinit();
    const result = try manager.execute(std.testing.allocator, "get_subagent_result", result_args.value, launch);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(PanelCounts{ .shown = 0, .total = 0 }, manager.panelSnapshot(&storage));
}

test "worker status files feed record activity" {
    var manager = try Manager.init(std.testing.allocator, std.testing.io, "/tmp", .{});
    defer manager.deinit();
    std.testing.allocator.free(manager.executable);
    manager.executable = try std.testing.allocator.dupeZ(u8, "/bin/echo");

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"prompt":"inspect auth","description":"Inspect auth"}
    , .{});
    defer parsed.deinit();
    const launch: Launch = .{ .provider = "chatgpt", .model = "test-model", .effort = null, .fast = false };
    const started = try manager.execute(std.testing.allocator, "Agent", parsed.value, launch);
    defer std.testing.allocator.free(started);
    const record = manager.records.items[0];
    try manager.waitFor(record, false);

    // Replay a heartbeat as if the worker were mid-run: refresh captures
    // the activity line, then the done file finishes the record.
    record.status = .running;
    try writePrivate(std.testing.io, record.status_path,
        \\{"state":"tooling","activity":"Editing a.zig","turn":2,"input":100,"output":5,"percent":1}
    );
    try manager.refresh(record);
    try std.testing.expectEqual(Status.completed, record.status);
    try std.testing.expectEqualStrings("Editing a.zig · turn 2 · ↑100 ↓5", record.activity.?);
}

test "briefings include the self-contained task" {
    const text = try buildBriefing(std.testing.allocator, "change auth");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "inspect and edit files") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "change auth") != null);
}

test "capped result reads allocate only the returned prefix" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const contents = try std.testing.allocator.alloc(u8, result_limit + 4096);
    defer std.testing.allocator.free(contents);
    for (contents, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "result.txt", .data = contents });
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/result.txt", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var manager = try Manager.init(std.testing.allocator, std.testing.io, "/tmp", .{});
    defer manager.deinit();

    const result = try manager.readCapped(std.testing.allocator, path);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, contents[0 .. result_limit - 96], result[0 .. result_limit - 96]);
    try std.testing.expect(std.mem.endsWith(u8, result, "]"));
}

test "manager config disables launches and changes the background default" {
    var manager = try Manager.init(std.testing.allocator, std.testing.io, "/tmp", .{ .enabled = false });
    defer manager.deinit();
    std.testing.allocator.free(manager.executable);
    manager.executable = try std.testing.allocator.dupeZ(u8, "/bin/echo");

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"prompt":"inspect auth","description":"Inspect auth"}
    , .{});
    defer parsed.deinit();
    const launch: Launch = .{ .provider = "chatgpt", .model = "test-model", .effort = null, .fast = false };
    const disabled = try manager.execute(std.testing.allocator, "Agent", parsed.value, launch);
    defer std.testing.allocator.free(disabled);
    try std.testing.expectEqualStrings("subagents are disabled in /settings", disabled);

    try manager.configure(.{ .max_concurrent = 2, .background_by_default = false });
    const foreground = try manager.execute(std.testing.allocator, "Agent", parsed.value, launch);
    defer std.testing.allocator.free(foreground);
    try std.testing.expect(std.mem.indexOf(u8, foreground, "Status: completed") != null);
}

test "foreground and background agents return worker results" {
    var manager = try Manager.init(std.testing.allocator, std.testing.io, "/tmp", .{});
    defer manager.deinit();
    std.testing.allocator.free(manager.executable);
    manager.executable = try std.testing.allocator.dupeZ(u8, "/bin/echo");

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"prompt":"inspect auth","description":"Inspect auth","run_in_background":false}
    , .{});
    defer parsed.deinit();
    const result = try manager.execute(std.testing.allocator, "Agent", parsed.value, .{
        .provider = "chatgpt",
        .model = "test-model",
        .effort = null,
        .fast = false,
    });
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Status: completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--subagent-control") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--subagent-status") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "--subagent-read-only") == null);

    var background_args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"prompt":"inspect tests","description":"Inspect tests"}
    , .{});
    defer background_args.deinit();
    const started = try manager.execute(std.testing.allocator, "Agent", background_args.value, .{
        .provider = "chatgpt",
        .model = "test-model",
        .effort = null,
        .fast = false,
    });
    defer std.testing.allocator.free(started);
    const id_start = "Agent ".len;
    const id_end = std.mem.indexOfScalarPos(u8, started, id_start, ' ').?;
    const result_args_text = try std.fmt.allocPrint(std.testing.allocator, "{{\"agent_id\":\"{s}\",\"wait\":true}}", .{started[id_start..id_end]});
    defer std.testing.allocator.free(result_args_text);
    var result_args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result_args_text, .{});
    defer result_args.deinit();
    const background_result = try manager.execute(std.testing.allocator, "get_subagent_result", result_args.value, .{
        .provider = "chatgpt",
        .model = "test-model",
        .effort = null,
        .fast = false,
    });
    defer std.testing.allocator.free(background_result);
    try std.testing.expect(std.mem.indexOf(u8, background_result, "Status: completed") != null);

    var queued_id: ?[]u8 = null;
    defer if (queued_id) |id| std.testing.allocator.free(id);
    for (0..default_max_concurrent + 1) |index| {
        const launched = try manager.execute(std.testing.allocator, "Agent", background_args.value, .{
            .provider = "chatgpt",
            .model = "test-model",
            .effort = null,
            .fast = false,
        });
        defer std.testing.allocator.free(launched);
        if (index == default_max_concurrent) {
            try std.testing.expect(std.mem.indexOf(u8, launched, "queued in background") != null);
            const queued_end = std.mem.indexOfScalarPos(u8, launched, id_start, ' ').?;
            queued_id = try std.testing.allocator.dupe(u8, launched[id_start..queued_end]);
        }
    }
    const queued_args_text = try std.fmt.allocPrint(std.testing.allocator, "{{\"agent_id\":\"{s}\",\"wait\":true}}", .{queued_id.?});
    defer std.testing.allocator.free(queued_args_text);
    var queued_args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, queued_args_text, .{});
    defer queued_args.deinit();
    const queued_result = try manager.execute(std.testing.allocator, "get_subagent_result", queued_args.value, .{
        .provider = "chatgpt",
        .model = "test-model",
        .effort = null,
        .fast = false,
    });
    defer std.testing.allocator.free(queued_result);
    try std.testing.expect(std.mem.indexOf(u8, queued_result, "Status: completed") != null);
}
