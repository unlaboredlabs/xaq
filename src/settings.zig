const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const models = @import("models.zig");

pub const Config = struct {
    auto_compact: bool = true,
    compact_threshold_percent: u8 = 80,
    compact_models: ProviderModels = .{},
    compact_efforts: ProviderEfforts = .{},

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
    if (value.compact_threshold_percent < 10 or value.compact_threshold_percent > 95) return error.InvalidSettings;
    inline for (.{ value.compact_models.chatgpt, value.compact_models.claude, value.compact_models.grok }) |model| {
        if (model.len == 0 or model.len > 128 or std.mem.findAny(u8, model, "\r\n") != null) return error.InvalidSettings;
    }
    return .{ .arena = arena, .value = value };
}

pub fn save(gpa: std.mem.Allocator, io: Io, home: []const u8, value: Config) !void {
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
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
    errdefer Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = temporary,
        .data = out.written(),
        .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o600) },
    });
    var file = try Io.Dir.cwd().openFile(io, temporary, .{ .mode = .read_write });
    defer file.close(io);
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
    try save(std.testing.allocator, std.testing.io, home, value);
    var loaded = try load(std.testing.allocator, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expect(!loaded.value.auto_compact);
    try std.testing.expectEqual(@as(u8, 70), loaded.value.compact_threshold_percent);
    try std.testing.expectEqualStrings("claude-sonnet-5", loaded.value.compactModel(.claude));
    try std.testing.expectEqual(models.Effort.medium, loaded.value.compactEffort(.claude).?);
}
