const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const models = @import("models.zig");

pub const Config = struct {
    auto_compact: bool = true,
    compact_threshold_percent: u8 = 80,
    compact_models: ProviderModels = .{},
    compact_efforts: ProviderEfforts = .{},
    subagents_enabled: bool = true,
    subagent_max_concurrent: u8 = 4,
    subagent_default_background: bool = true,
    subagent_panel: bool = true,
    copy_on_select: bool = true,
    firecrawl_api_key: ?[]const u8 = null,

    pub const ProviderModels = struct {
        chatgpt: []const u8 = "current",
        claude: []const u8 = "current",
        grok: []const u8 = "current",
    };

    pub const ProviderEfforts = struct {
        chatgpt: ?models.Effort = .low,
        claude: ?models.Effort = .low,
        grok: ?models.Effort = .low,
    };

    pub fn compactModel(self: *const Config, provider: auth.Provider) []const u8 {
        return switch (provider) {
            .chatgpt => self.compact_models.chatgpt,
            .claude => self.compact_models.claude,
            .grok => self.compact_models.grok,
        };
    }

    pub fn setCompactModel(self: *Config, provider: auth.Provider, value: []const u8) void {
        switch (provider) {
            .chatgpt => self.compact_models.chatgpt = value,
            .claude => self.compact_models.claude = value,
            .grok => self.compact_models.grok = value,
        }
    }

    pub fn compactEffort(self: *const Config, provider: auth.Provider) ?models.Effort {
        return switch (provider) {
            .chatgpt => self.compact_efforts.chatgpt,
            .claude => self.compact_efforts.claude,
            .grok => self.compact_efforts.grok,
        };
    }

    pub fn setCompactEffort(self: *Config, provider: auth.Provider, value: ?models.Effort) void {
        switch (provider) {
            .chatgpt => self.compact_efforts.chatgpt = value,
            .claude => self.compact_efforts.claude = value,
            .grok => self.compact_efforts.grok = value,
        }
    }
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    value: Config,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn load(gpa: std.mem.Allocator, io: Io, home: []const u8) !Loaded {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const path = try pathFor(allocator, home);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .value = .{} },
        else => return err,
    };
    const value = try std.json.parseFromSliceLeaky(Config, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    try validate(value);
    return .{ .arena = arena, .value = value };
}

fn validate(value: Config) !void {
    if (value.compact_threshold_percent < 10 or value.compact_threshold_percent > 95) return error.InvalidSettings;
    if (value.subagent_max_concurrent < 1 or value.subagent_max_concurrent > 8) return error.InvalidSettings;
    inline for (.{ value.compact_models.chatgpt, value.compact_models.claude, value.compact_models.grok }) |model| {
        if (model.len == 0 or model.len > 128 or std.mem.findAny(u8, model, "\r\n") != null) return error.InvalidSettings;
    }
    if (value.firecrawl_api_key) |key| {
        if (!validFirecrawlApiKey(key)) return error.InvalidSettings;
    }
}

pub fn validFirecrawlApiKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 1024) return false;
    for (key) |byte| if (byte <= ' ' or byte == 0x7f) return false;
    return true;
}

pub fn save(gpa: std.mem.Allocator, io: Io, home: []const u8, value: Config) !void {
    try validate(value);
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    try saveJsonFile(gpa, io, path, value);
}

/// Apply a session's edits to the latest settings while retaining other
/// sessions' changes. The returned arena owns every string in the result.
pub fn saveChanges(gpa: std.mem.Allocator, io: Io, home: []const u8, previous: Config, desired: Config) !Loaded {
    try validate(desired);
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    var lock = lockJsonFile(gpa, io, path) catch |err| switch (err) {
        error.WouldBlock => return error.SettingsInUse,
        else => return err,
    };
    defer lock.close(io);
    var latest = try load(gpa, io, home);
    errdefer latest.deinit();
    const allocator = latest.arena.allocator();
    inline for (.{ "auto_compact", "compact_threshold_percent", "subagents_enabled", "subagent_max_concurrent", "subagent_default_background", "subagent_panel", "copy_on_select" }) |field| {
        if (@field(previous, field) != @field(desired, field)) @field(latest.value, field) = @field(desired, field);
    }
    inline for (@typeInfo(auth.Provider).@"enum".fields) |field| {
        const changed_model = !std.mem.eql(u8, @field(previous.compact_models, field.name), @field(desired.compact_models, field.name));
        // Either edit carries the pair so a stale session cannot apply an
        // effort to a different model selected by another session.
        if (changed_model or @field(previous.compact_efforts, field.name) != @field(desired.compact_efforts, field.name)) {
            @field(latest.value.compact_models, field.name) = try allocator.dupe(u8, @field(desired.compact_models, field.name));
            @field(latest.value.compact_efforts, field.name) = @field(desired.compact_efforts, field.name);
        }
    }
    if (!optionalStringEqual(previous.firecrawl_api_key, desired.firecrawl_api_key)) {
        latest.value.firecrawl_api_key = if (desired.firecrawl_api_key) |key| try allocator.dupe(u8, key) else null;
    }
    try saveJsonFile(gpa, io, path, latest.value);
    return latest;
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}

/// The sidecar stays on disk so replacing the JSON cannot change which inode
/// serializes readers that are about to modify it. Conflicts fail promptly.
pub fn lockJsonFile(gpa: std.mem.Allocator, io: Io, path: []const u8) !Io.File {
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
    defer gpa.free(lock_path);
    return Io.Dir.cwd().createFile(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = @enumFromInt(0o600),
    });
}

/// Atomically replace `path` (absolute) with pretty-printed JSON: exclusive
/// temp file, fsync, rename. Shared by settings, state, and credentials.
pub fn saveJsonFile(gpa: std.mem.Allocator, io: Io, path: []const u8, value: anytype) !void {
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');

    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(gpa, "{s}.tmp-{s}", .{ path, &hex });
    defer gpa.free(temporary);
    var file = try Io.Dir.cwd().createFile(io, temporary, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    // Cleanup only after acquiring this file. A name collision must not
    // delete another writer's temporary file.
    errdefer Io.Dir.cwd().deleteFile(io, temporary) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, out.written());
    try file.sync(io);
    try Io.Dir.renameAbsolute(temporary, path, io);
}

fn pathFor(gpa: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home, ".config", "xaq", "settings.json" });
}

test "settings round trip provider-specific compaction choices" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const home = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buffer[0..cwd_length], temporary.sub_path });
    defer std.testing.allocator.free(home);
    var value: Config = .{};
    value.auto_compact = false;
    value.compact_threshold_percent = 70;
    value.setCompactModel(.claude, "claude-sonnet-5");
    value.setCompactEffort(.claude, .medium);
    value.subagents_enabled = false;
    value.subagent_max_concurrent = 2;
    value.subagent_default_background = false;
    value.subagent_panel = false;
    value.firecrawl_api_key = "fc-test-key";
    try save(std.testing.allocator, std.testing.io, home, value);
    var loaded = try load(std.testing.allocator, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expect(!loaded.value.auto_compact);
    try std.testing.expectEqual(@as(u8, 70), loaded.value.compact_threshold_percent);
    try std.testing.expectEqualStrings("claude-sonnet-5", loaded.value.compactModel(.claude));
    try std.testing.expectEqual(models.Effort.medium, loaded.value.compactEffort(.claude).?);
    try std.testing.expect(!loaded.value.subagents_enabled);
    try std.testing.expectEqual(@as(u8, 2), loaded.value.subagent_max_concurrent);
    try std.testing.expect(!loaded.value.subagent_default_background);
    try std.testing.expect(!loaded.value.subagent_panel);
    try std.testing.expectEqualStrings("fc-test-key", loaded.value.firecrawl_api_key.?);
}

test "Firecrawl API keys reject whitespace and empty values" {
    try std.testing.expect(validFirecrawlApiKey("fc-test-key"));
    try std.testing.expect(!validFirecrawlApiKey(""));
    try std.testing.expect(!validFirecrawlApiKey("fc-test key"));
    try std.testing.expect(!validFirecrawlApiKey("fc-test\nkey"));
}

test "copy on select defaults on for missing and existing settings" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const home = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buffer[0..cwd_length], temporary.sub_path });
    defer std.testing.allocator.free(home);
    var missing = try load(std.testing.allocator, std.testing.io, home);
    defer missing.deinit();
    try std.testing.expect(missing.value.copy_on_select);

    const path = try pathFor(std.testing.allocator, home);
    defer std.testing.allocator.free(path);
    try saveJsonFile(std.testing.allocator, std.testing.io, path, .{ .auto_compact = false });
    var existing = try load(std.testing.allocator, std.testing.io, home);
    defer existing.deinit();
    try std.testing.expect(existing.value.copy_on_select);
    try std.testing.expect(!existing.value.auto_compact);
}

test "copy on select persists both off and on" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const home = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buffer[0..cwd_length], temporary.sub_path });
    defer std.testing.allocator.free(home);
    for ([_]bool{ false, true }) |enabled| {
        try save(std.testing.allocator, std.testing.io, home, .{ .copy_on_select = enabled });
        var loaded = try load(std.testing.allocator, std.testing.io, home);
        defer loaded.deinit();
        try std.testing.expectEqual(enabled, loaded.value.copy_on_select);
    }
}

fn testHome(sub_path: []const u8) ![]u8 {
    var cwd: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(std.testing.io, &cwd);
    return std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd[0..len], sub_path });
}

test "settings edits preserve other sessions changes and own the merged strings" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(&temporary.sub_path);
    defer gpa.free(home);
    const original: Config = .{ .firecrawl_api_key = "fc-original" };
    try save(gpa, std.testing.io, home, original);
    var first = original;
    first.auto_compact = false;
    first.firecrawl_api_key = "fc-new";
    first.setCompactModel(.claude, "claude-sonnet-5");
    first.setCompactEffort(.claude, .high);
    var first_saved = try saveChanges(gpa, std.testing.io, home, original, first);
    first_saved.deinit();

    var stale = original;
    stale.copy_on_select = false;
    const desired_model = try gpa.dupe(u8, "gpt-5.6-sol");
    defer gpa.free(desired_model);
    stale.setCompactModel(.chatgpt, desired_model);
    stale.setCompactEffort(.chatgpt, .medium);
    var merged = try saveChanges(gpa, std.testing.io, home, original, stale);
    defer merged.deinit();
    @memset(desired_model, 'x');
    stale.setCompactModel(.chatgpt, "gpt-5.6-sol");
    try std.testing.expect(!merged.value.auto_compact);
    try std.testing.expect(!merged.value.copy_on_select);
    try std.testing.expectEqualStrings("fc-new", merged.value.firecrawl_api_key.?);
    try std.testing.expectEqualStrings("claude-sonnet-5", merged.value.compactModel(.claude));
    try std.testing.expectEqual(models.Effort.high, merged.value.compactEffort(.claude).?);
    try std.testing.expectEqualStrings("gpt-5.6-sol", merged.value.compactModel(.chatgpt));
    try std.testing.expectEqual(models.Effort.medium, merged.value.compactEffort(.chatgpt).?);

    // A stale model edit must carry its effort, rather than inheriting the
    // other session's high effort for a different model.
    stale.setCompactModel(.claude, "claude-haiku-4-5");
    stale.setCompactEffort(.claude, null);
    var paired = try saveChanges(gpa, std.testing.io, home, original, stale);
    defer paired.deinit();
    try std.testing.expectEqualStrings("claude-haiku-4-5", paired.value.compactModel(.claude));
    try std.testing.expectEqual(null, paired.value.compactEffort(.claude));
    try std.testing.expectEqualStrings("fc-new", paired.value.firecrawl_api_key.?);
}

test "settings merge lock conflicts preserve the saved configuration" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(&temporary.sub_path);
    defer gpa.free(home);
    try save(gpa, std.testing.io, home, .{});
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    {
        var held = try lockJsonFile(gpa, std.testing.io, path);
        defer held.close(std.testing.io);
        try std.testing.expectError(error.SettingsInUse, saveChanges(gpa, std.testing.io, home, .{}, .{ .auto_compact = false }));
        var unchanged = try load(gpa, std.testing.io, home);
        defer unchanged.deinit();
        try std.testing.expect(unchanged.value.auto_compact);
    }
    var saved = try saveChanges(gpa, std.testing.io, home, .{}, .{ .auto_compact = false });
    defer saved.deinit();
    try std.testing.expect(!saved.value.auto_compact);
}

test "atomic JSON saves preserve existing temporary files and clean up partial writes" {
    const Fault = struct {
        fn random(_: ?*anyopaque, bytes: []u8) Io.RandomSecureError!void {
            @memset(bytes, 0);
        }
        fn partial(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
            if (operation == .file_write_streaming) {
                var write = operation.file_write_streaming;
                const bytes = write.data[0];
                if (bytes[0] != '{') return .{ .file_write_streaming = error.NoSpaceLeft };
                write.data = &.{bytes[0..8]};
                return std.testing.io.vtable.operate(userdata, .{ .file_write_streaming = write });
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
        fn rename(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir, _: []const u8) Io.Dir.RenameError!void {
            return error.AccessDenied;
        }
    };
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(&temporary.sub_path);
    defer gpa.free(home);
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    try saveJsonFile(gpa, std.testing.io, path, .{ .marker = "original" });
    const original = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1024));
    defer gpa.free(original);
    const temp_path = try std.fmt.allocPrint(gpa, "{s}.tmp-0000000000000000", .{path});
    defer gpa.free(temp_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = temp_path, .data = "another writer" });
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = Fault.random;
    const io: Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.PathAlreadyExists, saveJsonFile(gpa, io, path, .{ .marker = "changed" }));
    const other = try Io.Dir.cwd().readFileAlloc(std.testing.io, temp_path, gpa, .limited(1024));
    defer gpa.free(other);
    try std.testing.expectEqualStrings("another writer", other);
    try Io.Dir.cwd().deleteFile(std.testing.io, temp_path);

    vtable.operate = Fault.partial;
    try std.testing.expectError(error.NoSpaceLeft, saveJsonFile(gpa, io, path, .{ .marker = "changed" }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(std.testing.io, temp_path, .{}));
    vtable.operate = std.testing.io.vtable.operate;
    vtable.dirRename = Fault.rename;
    try std.testing.expectError(error.AccessDenied, saveJsonFile(gpa, io, path, .{ .marker = "changed" }));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(std.testing.io, temp_path, .{}));
    const retained = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1024));
    defer gpa.free(retained);
    try std.testing.expectEqualStrings(original, retained);
}

test "settings reject invalid writes before replacing the existing configuration" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(&temporary.sub_path);
    defer gpa.free(home);
    try save(gpa, std.testing.io, home, .{ .copy_on_select = false });
    try std.testing.expectError(error.InvalidSettings, save(gpa, std.testing.io, home, .{ .compact_threshold_percent = 0 }));
    try std.testing.expectError(error.InvalidSettings, saveChanges(gpa, std.testing.io, home, .{}, .{ .firecrawl_api_key = "bad\nkey" }));
    var retained = try load(gpa, std.testing.io, home);
    defer retained.deinit();
    try std.testing.expect(!retained.value.copy_on_select);
}
