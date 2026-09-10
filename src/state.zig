//! Cross-session memory of the last explicit model, effort, and fast-mode
//! selection, kept per provider so switching providers round-trips cleanly.
//! Unlike settings.json (user-authored intent, rejected loudly when invalid),
//! this file is machine-written: missing, corrupt, or stale content degrades
//! to defaults instead of failing startup.
const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const models = @import("models.zig");
const providers = @import("providers.zig");
const settings = @import("settings.zig");

/// One remembered tuple. Effort and fast are only meaningful together with
/// the model they were chosen for, so they are stored and validated as a unit.
pub const Selection = struct {
    model: []const u8,
    effort: ?models.Effort = null,
    fast: bool = false,
};

pub const State = struct {
    /// Provider name: a built-in tag or a custom provider's settings name.
    provider: ?[]const u8 = null,
    chatgpt: ?Selection = null,
    claude: ?Selection = null,
    grok: ?Selection = null,
    /// Custom providers keyed by settings name.
    custom: ?std.json.ArrayHashMap(Selection) = null,

    pub fn rememberedRef(self: *const State) ?providers.Ref {
        return providers.Ref.parse(self.provider orelse return null);
    }

    pub fn selection(self: *const State, ref: providers.Ref) ?Selection {
        return switch (ref.provider) {
            .chatgpt => self.chatgpt,
            .claude => self.claude,
            .grok => self.grok,
            .custom => if (self.custom) |map| map.map.get(ref.name()) else null,
        };
    }

    /// `allocator` only matters for custom providers, whose map may grow.
    pub fn setSelection(self: *State, allocator: std.mem.Allocator, ref: providers.Ref, value: Selection) !void {
        switch (ref.provider) {
            .chatgpt => self.chatgpt = value,
            .claude => self.claude = value,
            .grok => self.grok = value,
            .custom => {
                if (self.custom == null) self.custom = .{};
                try self.custom.?.map.put(allocator, ref.name(), value);
            },
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
    if (value.provider) |name| {
        if (providers.Ref.parse(name) == null) value.provider = null;
    }
    if (value.custom) |*map| {
        // Custom capabilities live in settings, which this loader does not
        // read; main re-checks effort and fast against the resolved catalog.
        var index: usize = 0;
        while (index < map.map.count()) {
            const name = map.map.keys()[index];
            const entry = sanitizeShape(map.map.values()[index]);
            if (entry == null or !settings.validProviderName(name)) {
                map.map.orderedRemoveAt(index);
                continue;
            }
            map.map.values()[index] = entry.?;
            index += 1;
        }
        if (map.map.count() == 0) value.custom = null;
    }
    return .{ .arena = arena, .value = value };
}

/// Unknown model IDs stay usable (snapshot IDs must survive a catalog that
/// has not heard of them), but an effort or fast flag the model is known
/// not to support is dropped rather than sent.
fn sanitize(provider: auth.Provider, remembered: ?Selection) ?Selection {
    var value = sanitizeShape(remembered) orelse return null;
    if (value.effort) |effort| {
        if (!models.supportsEffort(provider, value.model, effort)) value.effort = null;
    }
    if (value.fast and !models.supportsFast(provider, value.model)) value.fast = false;
    return value;
}

fn sanitizeShape(remembered: ?Selection) ?Selection {
    const value = remembered orelse return null;
    if (value.model.len == 0 or value.model.len > 128 or std.mem.findAny(u8, value.model, "\r\n") != null) return null;
    return value;
}

pub fn save(gpa: std.mem.Allocator, io: Io, home: []const u8, value: State) !void {
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    try settings.saveJsonFile(gpa, io, path, value);
}

/// Remember one provider without losing another session's latest choices.
/// The lock covers the complete read/modify/write, including the reload.
pub fn remember(gpa: std.mem.Allocator, io: Io, home: []const u8, ref: providers.Ref, value: Selection) !void {
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    var lock = settings.lockJsonFile(gpa, io, path) catch |err| switch (err) {
        error.WouldBlock => return error.StateInUse,
        else => return err,
    };
    defer lock.close(io);
    var latest = try load(gpa, io, home);
    defer latest.deinit();
    latest.value.provider = ref.name();
    try latest.value.setSelection(latest.arena.allocator(), ref, value);
    try save(gpa, io, home, latest.value);
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
    var value: State = .{ .provider = "claude" };
    try value.setSelection(std.testing.allocator, .builtin(.claude), .{ .model = "claude-fable-5", .effort = .high, .fast = false });
    try value.setSelection(std.testing.allocator, .builtin(.chatgpt), .{ .model = "gpt-5.6-sol", .effort = .max, .fast = true });
    try save(std.testing.allocator, std.testing.io, home, value);
    var loaded = try load(std.testing.allocator, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("claude", loaded.value.provider.?);
    const claude = loaded.value.selection(.builtin(.claude)).?;
    try std.testing.expectEqualStrings("claude-fable-5", claude.model);
    try std.testing.expectEqual(models.Effort.high, claude.effort.?);
    try std.testing.expect(!claude.fast);
    const chatgpt = loaded.value.selection(.builtin(.chatgpt)).?;
    try std.testing.expectEqualStrings("gpt-5.6-sol", chatgpt.model);
    try std.testing.expectEqual(models.Effort.max, chatgpt.effort.?);
    try std.testing.expect(chatgpt.fast);
    try std.testing.expectEqual(null, loaded.value.selection(.builtin(.grok)));
}

test "state load drops capabilities the model does not support" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(std.testing.allocator, &temporary.sub_path);
    defer std.testing.allocator.free(home);
    var value: State = .{ .provider = "grok" };
    try value.setSelection(std.testing.allocator, .builtin(.claude), .{ .model = "claude-haiku-4-5", .effort = .high, .fast = true });
    try value.setSelection(std.testing.allocator, .builtin(.grok), .{ .model = "grok-4.6", .effort = .max, .fast = true });
    // Unknown snapshot IDs keep their remembered capabilities.
    try value.setSelection(std.testing.allocator, .builtin(.chatgpt), .{ .model = "gpt-5.6-sol-2026-08-01", .effort = .max, .fast = false });
    try save(std.testing.allocator, std.testing.io, home, value);
    var loaded = try load(std.testing.allocator, std.testing.io, home);
    defer loaded.deinit();
    const claude = loaded.value.selection(.builtin(.claude)).?;
    try std.testing.expectEqual(null, claude.effort);
    try std.testing.expect(!claude.fast);
    const grok = loaded.value.selection(.builtin(.grok)).?;
    try std.testing.expectEqual(null, grok.effort);
    try std.testing.expect(!grok.fast);
    const chatgpt = loaded.value.selection(.builtin(.chatgpt)).?;
    try std.testing.expectEqual(models.Effort.max, chatgpt.effort.?);
}

test "state load discards malformed model IDs" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(std.testing.allocator, &temporary.sub_path);
    defer std.testing.allocator.free(home);
    var value: State = .{};
    try value.setSelection(std.testing.allocator, .builtin(.chatgpt), .{ .model = "gpt\n5" });
    try value.setSelection(std.testing.allocator, .builtin(.claude), .{ .model = "" });
    try save(std.testing.allocator, std.testing.io, home, value);
    var loaded = try load(std.testing.allocator, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expectEqual(null, loaded.value.selection(.builtin(.chatgpt)));
    try std.testing.expectEqual(null, loaded.value.selection(.builtin(.claude)));
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
    try std.testing.expectEqual(null, corrupt.value.selection(.builtin(.chatgpt)));
}

test "remember serializes provider edits and preserves other providers" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(gpa, &temporary.sub_path);
    defer gpa.free(home);
    try remember(gpa, std.testing.io, home, .builtin(.chatgpt), .{ .model = "gpt-5.6-sol", .effort = .max, .fast = true });
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    {
        var held = try settings.lockJsonFile(gpa, std.testing.io, path);
        defer held.close(std.testing.io);
        try std.testing.expectError(error.StateInUse, remember(gpa, std.testing.io, home, .builtin(.claude), .{ .model = "claude-sonnet-5" }));
    }
    try remember(gpa, std.testing.io, home, .builtin(.claude), .{ .model = "claude-sonnet-5", .effort = .high });
    var loaded = try load(gpa, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("claude", loaded.value.provider.?);
    try std.testing.expectEqualStrings("gpt-5.6-sol", loaded.value.selection(.builtin(.chatgpt)).?.model);
    try std.testing.expectEqualStrings("claude-sonnet-5", loaded.value.selection(.builtin(.claude)).?.model);
}

test "state remembers custom providers by name and drops malformed entries" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(gpa, &temporary.sub_path);
    defer gpa.free(home);
    try remember(gpa, std.testing.io, home, .builtin(.claude), .{ .model = "claude-sonnet-5" });
    try remember(gpa, std.testing.io, home, providers.Ref.parse("ollama").?, .{ .model = "qwen3-coder", .effort = .high });
    var loaded = try load(gpa, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("ollama", loaded.value.provider.?);
    try std.testing.expectEqual(auth.Provider.custom, loaded.value.rememberedRef().?.provider);
    try std.testing.expectEqualStrings("ollama", loaded.value.rememberedRef().?.name());
    const custom = loaded.value.selection(providers.Ref.parse("ollama").?).?;
    try std.testing.expectEqualStrings("qwen3-coder", custom.model);
    try std.testing.expectEqual(models.Effort.high, custom.effort.?);
    try std.testing.expectEqualStrings("claude-sonnet-5", loaded.value.selection(.builtin(.claude)).?.model);
    try std.testing.expectEqual(null, loaded.value.selection(providers.Ref.parse("other").?));

    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "{\"provider\":\"Bad Name\",\"custom\":{\"ok\":{\"model\":\"m\"},\"BAD\":{\"model\":\"m\"},\"empty\":{\"model\":\"\"}}}" });
    var repaired = try load(gpa, std.testing.io, home);
    defer repaired.deinit();
    try std.testing.expectEqual(null, repaired.value.provider);
    try std.testing.expectEqual(@as(usize, 1), repaired.value.custom.?.map.count());
    try std.testing.expectEqualStrings("m", repaired.value.selection(providers.Ref.parse("ok").?).?.model);
}
