//! Cross-session memory of the last explicit model, effort, and fast-mode
//! selection, kept per provider so switching providers round-trips cleanly.
//! Unlike settings.json (user-authored intent, rejected loudly when invalid),
//! this file is machine-written: missing, corrupt, or stale content degrades
//! to defaults instead of failing startup.
const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const models = @import("models.zig");
const settings = @import("settings.zig");

/// One remembered tuple. Effort and fast are only meaningful together with
/// the model they were chosen for, so they are stored and validated as a unit.
pub const Selection = struct {
    model: []const u8,
    effort: ?models.Effort = null,
    fast: bool = false,
};

pub const State = struct {
    provider: ?auth.Provider = null,
    chatgpt: ?Selection = null,
    claude: ?Selection = null,
    grok: ?Selection = null,

    pub fn selection(self: *const State, provider: auth.Provider) ?Selection {
        return switch (provider) {
            .chatgpt => self.chatgpt,
            .claude => self.claude,
            .grok => self.grok,
        };
    }

    pub fn setSelection(self: *State, provider: auth.Provider, value: Selection) void {
        switch (provider) {
            .chatgpt => self.chatgpt = value,
            .claude => self.claude = value,
            .grok => self.grok = value,
        }
    }
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    value: State,

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
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024)) catch {
        return .{ .arena = arena, .value = .{} };
    };
    var value = std.json.parseFromSliceLeaky(State, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        return .{ .arena = arena, .value = .{} };
    };
    value.chatgpt = sanitize(.chatgpt, value.chatgpt);
    value.claude = sanitize(.claude, value.claude);
    value.grok = sanitize(.grok, value.grok);
    return .{ .arena = arena, .value = value };
}

/// Unknown model IDs stay usable (snapshot IDs must survive a catalog that
/// has not heard of them), but an effort or fast flag the model is known
/// not to support is dropped rather than sent.
fn sanitize(provider: auth.Provider, remembered: ?Selection) ?Selection {
    var value = remembered orelse return null;
    if (value.model.len == 0 or value.model.len > 128 or std.mem.findAny(u8, value.model, "\r\n") != null) return null;
    if (value.effort) |effort| {
        if (!models.supportsEffort(provider, value.model, effort)) value.effort = null;
    }
    if (value.fast and !models.supportsFast(provider, value.model)) value.fast = false;
    return value;
}

pub fn save(gpa: std.mem.Allocator, io: Io, home: []const u8, value: State) !void {
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    try settings.saveJsonFile(gpa, io, path, value);
}

fn pathFor(gpa: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home, ".config", "xaq", "state.json" });
}

fn testHome(gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    return std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/{s}", .{ cwd_buffer[0..cwd_length], sub_path });
}

test "state round trips per-provider selections" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(std.testing.allocator, &temporary.sub_path);
    defer std.testing.allocator.free(home);
    var value: State = .{ .provider = .claude };
    value.setSelection(.claude, .{ .model = "claude-fable-5", .effort = .high, .fast = false });
    value.setSelection(.chatgpt, .{ .model = "gpt-5.6-sol", .effort = .max, .fast = true });
    try save(std.testing.allocator, std.testing.io, home, value);
    var loaded = try load(std.testing.allocator, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expectEqual(auth.Provider.claude, loaded.value.provider.?);
    const claude = loaded.value.selection(.claude).?;
    try std.testing.expectEqualStrings("claude-fable-5", claude.model);
    try std.testing.expectEqual(models.Effort.high, claude.effort.?);
    try std.testing.expect(!claude.fast);
    const chatgpt = loaded.value.selection(.chatgpt).?;
    try std.testing.expectEqualStrings("gpt-5.6-sol", chatgpt.model);
    try std.testing.expectEqual(models.Effort.max, chatgpt.effort.?);
    try std.testing.expect(chatgpt.fast);
    try std.testing.expectEqual(null, loaded.value.selection(.grok));
}

test "state load drops capabilities the model does not support" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(std.testing.allocator, &temporary.sub_path);
    defer std.testing.allocator.free(home);
    var value: State = .{ .provider = .grok };
    value.setSelection(.claude, .{ .model = "claude-haiku-4-5", .effort = .high, .fast = true });
    value.setSelection(.grok, .{ .model = "grok-4.6", .effort = .max, .fast = true });
    // Unknown snapshot IDs keep their remembered capabilities.
    value.setSelection(.chatgpt, .{ .model = "gpt-5.6-sol-2026-08-01", .effort = .max, .fast = false });
    try save(std.testing.allocator, std.testing.io, home, value);
    var loaded = try load(std.testing.allocator, std.testing.io, home);
    defer loaded.deinit();
    const claude = loaded.value.selection(.claude).?;
    try std.testing.expectEqual(null, claude.effort);
    try std.testing.expect(!claude.fast);
    const grok = loaded.value.selection(.grok).?;
    try std.testing.expectEqual(null, grok.effort);
    try std.testing.expect(!grok.fast);
    const chatgpt = loaded.value.selection(.chatgpt).?;
    try std.testing.expectEqual(models.Effort.max, chatgpt.effort.?);
}

test "state load discards malformed model IDs" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(std.testing.allocator, &temporary.sub_path);
    defer std.testing.allocator.free(home);
    var value: State = .{};
    value.setSelection(.chatgpt, .{ .model = "gpt\n5" });
    value.setSelection(.claude, .{ .model = "" });
    try save(std.testing.allocator, std.testing.io, home, value);
    var loaded = try load(std.testing.allocator, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expectEqual(null, loaded.value.selection(.chatgpt));
    try std.testing.expectEqual(null, loaded.value.selection(.claude));
}

test "missing or corrupt state degrades to defaults" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(std.testing.allocator, &temporary.sub_path);
    defer std.testing.allocator.free(home);
    var missing = try load(std.testing.allocator, std.testing.io, home);
    defer missing.deinit();
    try std.testing.expectEqual(null, missing.value.provider);

    const path = try pathFor(std.testing.allocator, home);
    defer std.testing.allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(std.testing.io, parent);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "{not json" });
    var corrupt = try load(std.testing.allocator, std.testing.io, home);
    defer corrupt.deinit();
    try std.testing.expectEqual(null, corrupt.value.provider);
    try std.testing.expectEqual(null, corrupt.value.selection(.chatgpt));
}
