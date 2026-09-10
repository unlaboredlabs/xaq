const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const models = @import("models.zig");

/// How a custom endpoint receives its API key. Each wire format has a
/// conventional default; a proxy that expects the other one can override.
pub const AuthStyle = enum {
    bearer,
    @"x-api-key",

    pub fn parse(value: []const u8) ?AuthStyle {
        inline for (@typeInfo(AuthStyle).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn default(api: auth.Api) AuthStyle {
        return switch (api) {
            .messages => .@"x-api-key",
            .responses, .chat_completions => .bearer,
        };
    }
};

/// One user-defined endpoint under `providers` in settings.json. The map
/// key is the provider name used by --provider, /model, and thread files.
/// Model IDs outside `models` remain usable with the provider-wide limits;
/// the list only feeds pickers and subagent overrides.
pub const CustomProvider = struct {
    api: auth.Api,
    base_url: []const u8,
    /// Literal key. Prefer `api_key_env` so the settings file stays shareable.
    api_key: ?[]const u8 = null,
    /// Name of an environment variable holding the key.
    api_key_env: ?[]const u8 = null,
    auth: ?AuthStyle = null,
    /// Extra request headers. A user header replaces a default of the same name.
    headers: ?std.json.ArrayHashMap([]const u8) = null,
    models: []const []const u8 = &.{},
    context_tokens: u32 = default_context_tokens,
    efforts: []const models.Effort = &.{},

    pub fn authStyle(self: *const CustomProvider) AuthStyle {
        return self.auth orelse AuthStyle.default(self.api);
    }

    pub fn defaultModel(self: *const CustomProvider) []const u8 {
        return if (self.models.len > 0) self.models[0] else "";
    }

    pub fn listsModel(self: *const CustomProvider, id: []const u8) bool {
        for (self.models) |model| if (std.mem.eql(u8, model, id)) return true;
        return false;
    }

    pub fn supportsEffort(self: *const CustomProvider, effort: models.Effort) bool {
        return std.mem.containsAtLeastScalar(models.Effort, self.efforts, 1, effort);
    }

    /// Deep copy into `allocator`, typically a settings arena that must
    /// own every string it later serializes.
    pub fn clone(self: *const CustomProvider, allocator: std.mem.Allocator) !CustomProvider {
        var copy = self.*;
        copy.base_url = try allocator.dupe(u8, self.base_url);
        copy.api_key = if (self.api_key) |key| try allocator.dupe(u8, key) else null;
        copy.api_key_env = if (self.api_key_env) |name| try allocator.dupe(u8, name) else null;
        const model_list = try allocator.alloc([]const u8, self.models.len);
        for (self.models, 0..) |model, index| model_list[index] = try allocator.dupe(u8, model);
        copy.models = model_list;
        copy.efforts = try allocator.dupe(models.Effort, self.efforts);
        if (self.headers) |headers| {
            var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            var iterator = headers.map.iterator();
            while (iterator.next()) |entry| {
                try map.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
            }
            copy.headers = .{ .map = map };
        }
        return copy;
    }
};

pub const default_context_tokens: u32 = 128_000;
pub const max_providers = 16;
pub const max_provider_name = 32;
pub const max_provider_models = 64;
pub const max_provider_headers = 16;

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
    providers: ?std.json.ArrayHashMap(CustomProvider) = null,

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

    /// Custom endpoints always compact with the session model.
    pub fn compactModel(self: *const Config, provider: auth.Provider) []const u8 {
        return switch (provider) {
            .chatgpt => self.compact_models.chatgpt,
            .claude => self.compact_models.claude,
            .grok => self.compact_models.grok,
            .custom => "current",
        };
    }

    pub fn setCompactModel(self: *Config, provider: auth.Provider, value: []const u8) void {
        switch (provider) {
            .chatgpt => self.compact_models.chatgpt = value,
            .claude => self.compact_models.claude = value,
            .grok => self.compact_models.grok = value,
            .custom => {},
        }
    }

    pub fn compactEffort(self: *const Config, provider: auth.Provider) ?models.Effort {
        return switch (provider) {
            .chatgpt => self.compact_efforts.chatgpt,
            .claude => self.compact_efforts.claude,
            .grok => self.compact_efforts.grok,
            .custom => null,
        };
    }

    pub fn setCompactEffort(self: *Config, provider: auth.Provider, value: ?models.Effort) void {
        switch (provider) {
            .chatgpt => self.compact_efforts.chatgpt = value,
            .claude => self.compact_efforts.claude = value,
            .grok => self.compact_efforts.grok = value,
            .custom => {},
        }
    }

    /// Borrowed from the settings arena; valid until the settings are replaced.
    pub fn customProvider(self: *const Config, name: []const u8) ?*const CustomProvider {
        const map = if (self.providers) |*map| &map.map else return null;
        return map.getPtr(name);
    }

    pub fn customProviderCount(self: *const Config) usize {
        return if (self.providers) |*map| map.map.count() else 0;
    }

    /// Names in file order, borrowed from the settings arena.
    pub fn customProviderNames(self: *const Config) []const []const u8 {
        return if (self.providers) |*map| map.map.keys() else &.{};
    }
};

/// Provider names are file keys, CLI arguments, and thread metadata, so
/// they stay short lowercase identifiers that can never be mistaken for
/// a built-in provider or the `custom` tag itself.
pub fn validProviderName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_provider_name) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
        if (std.ascii.isUpper(byte)) return false;
    }
    if (auth.Provider.parse(name) != null or std.mem.eql(u8, name, "custom")) return false;
    return true;
}

/// `http://` is accepted for local servers such as Ollama; the config is
/// explicit user intent. Characters that could break the curl config or a
/// header line are rejected here rather than at request time.
pub fn validBaseUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > 2048) return false;
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return false;
    if (rest.len == 0 or rest[0] == '/' or rest[0] == '?' or rest[0] == '#') return false;
    for (url) |byte| if (byte <= ' ' or byte == 0x7f or byte == '"' or byte == '\\') return false;
    return true;
}

pub fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.ascii.isDigit(name[0])) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

pub fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |byte| if (byte <= ' ' or byte == 0x7f) return false;
    return true;
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |byte| if (byte <= ' ' or byte >= 0x7f or byte == ':' or byte == '"' or byte == '\\') return false;
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    if (value.len > 4096) return false;
    for (value) |byte| if (byte < ' ' or byte == 0x7f or byte == '"' or byte == '\\') return false;
    return true;
}

pub fn validateProvider(name: []const u8, value: CustomProvider) error{InvalidSettings}!void {
    if (!validProviderName(name)) return error.InvalidSettings;
    if (!validBaseUrl(value.base_url)) return error.InvalidSettings;
    if (value.api_key != null and value.api_key_env != null) return error.InvalidSettings;
    if (value.api_key) |key| if (!validFirecrawlApiKey(key)) return error.InvalidSettings;
    if (value.api_key_env) |env| if (!validEnvName(env)) return error.InvalidSettings;
    if (value.models.len > max_provider_models) return error.InvalidSettings;
    for (value.models) |model| if (!validModelId(model)) return error.InvalidSettings;
    if (value.context_tokens < 1024) return error.InvalidSettings;
    if (value.efforts.len > @typeInfo(models.Effort).@"enum".fields.len) return error.InvalidSettings;
    if (value.headers) |headers| {
        if (headers.map.count() > max_provider_headers) return error.InvalidSettings;
        var iterator = headers.map.iterator();
        while (iterator.next()) |entry| {
            if (!validHeaderName(entry.key_ptr.*) or !validHeaderValue(entry.value_ptr.*)) return error.InvalidSettings;
        }
    }
}

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
    if (value.providers) |map| {
        if (map.map.count() > max_providers) return error.InvalidSettings;
        var iterator = map.map.iterator();
        while (iterator.next()) |entry| try validateProvider(entry.key_ptr.*, entry.value_ptr.*);
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
    inline for (auth.Provider.builtin) |provider| {
        const name = @tagName(provider);
        const changed_model = !std.mem.eql(u8, @field(previous.compact_models, name), @field(desired.compact_models, name));
        // Either edit carries the pair so a stale session cannot apply an
        // effort to a different model selected by another session.
        if (changed_model or @field(previous.compact_efforts, name) != @field(desired.compact_efforts, name)) {
            @field(latest.value.compact_models, name) = try allocator.dupe(u8, @field(desired.compact_models, name));
            @field(latest.value.compact_efforts, name) = @field(desired.compact_efforts, name);
        }
    }
    if (!optionalStringEqual(previous.firecrawl_api_key, desired.firecrawl_api_key)) {
        latest.value.firecrawl_api_key = if (desired.firecrawl_api_key) |key| try allocator.dupe(u8, key) else null;
    }
    try saveJsonFile(gpa, io, path, latest.value);
    return latest;
}

/// Add or replace one custom provider under the settings lock. Other
/// fields and providers keep whatever the latest file says. The returned
/// arena owns the merged configuration.
pub fn saveProvider(gpa: std.mem.Allocator, io: Io, home: []const u8, name: []const u8, value: CustomProvider) !Loaded {
    try validateProvider(name, value);
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
    if (latest.value.providers == null) latest.value.providers = .{};
    const map = &latest.value.providers.?.map;
    const owned_name = try allocator.dupe(u8, name);
    try map.put(allocator, owned_name, try value.clone(allocator));
    try validate(latest.value);
    try saveJsonFile(gpa, io, path, latest.value);
    return latest;
}

/// Remove one custom provider. Returns the merged configuration and
/// whether the name existed.
pub fn removeProvider(gpa: std.mem.Allocator, io: Io, home: []const u8, name: []const u8) !struct { loaded: Loaded, removed: bool } {
    const path = try pathFor(gpa, home);
    defer gpa.free(path);
    var lock = lockJsonFile(gpa, io, path) catch |err| switch (err) {
        error.WouldBlock => return error.SettingsInUse,
        else => return err,
    };
    defer lock.close(io);
    var latest = try load(gpa, io, home);
    errdefer latest.deinit();
    var removed = false;
    if (latest.value.providers) |*map| {
        removed = map.map.orderedRemove(name);
        if (map.map.count() == 0) latest.value.providers = null;
    }
    if (removed) try saveJsonFile(gpa, io, path, latest.value);
    return .{ .loaded = latest, .removed = removed };
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

test "custom providers round trip, validate, and merge under the lock" {
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try testHome(&temporary.sub_path);
    defer gpa.free(home);
    try save(gpa, std.testing.io, home, .{ .copy_on_select = false });

    var extra: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer extra.deinit(gpa);
    try extra.put(gpa, "X-Title", "xaq");
    const definition: CustomProvider = .{
        .api = .chat_completions,
        .base_url = "http://localhost:11434/v1",
        .api_key_env = "OLLAMA_API_KEY",
        .headers = .{ .map = extra },
        .models = &.{ "qwen3-coder", "llama4" },
        .context_tokens = 64_000,
        .efforts = &.{ .low, .high },
    };
    var first = try saveProvider(gpa, std.testing.io, home, "ollama", definition);
    first.deinit();
    var second = try saveProvider(gpa, std.testing.io, home, "router", .{ .api = .responses, .base_url = "https://example.test/v1", .api_key = "sk-1" });
    second.deinit();

    var loaded = try load(gpa, std.testing.io, home);
    defer loaded.deinit();
    try std.testing.expect(!loaded.value.copy_on_select);
    try std.testing.expectEqual(@as(usize, 2), loaded.value.customProviderCount());
    const ollama = loaded.value.customProvider("ollama").?;
    try std.testing.expectEqual(auth.Api.chat_completions, ollama.api);
    try std.testing.expectEqualStrings("OLLAMA_API_KEY", ollama.api_key_env.?);
    try std.testing.expectEqualStrings("xaq", ollama.headers.?.map.get("X-Title").?);
    try std.testing.expectEqualStrings("llama4", ollama.models[1]);
    try std.testing.expectEqual(@as(u32, 64_000), ollama.context_tokens);
    try std.testing.expectEqual(models.Effort.high, ollama.efforts[1]);
    try std.testing.expectEqual(AuthStyle.bearer, ollama.authStyle());
    try std.testing.expectEqual(AuthStyle.@"x-api-key", AuthStyle.default(.messages));
    try std.testing.expectEqualStrings("sk-1", loaded.value.customProvider("router").?.api_key.?);

    // Field edits from another session keep providers intact.
    var merged = try saveChanges(gpa, std.testing.io, home, .{}, .{ .auto_compact = false });
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 2), merged.value.customProviderCount());

    var removed = try removeProvider(gpa, std.testing.io, home, "router");
    removed.loaded.deinit();
    try std.testing.expect(removed.removed);
    var absent = try removeProvider(gpa, std.testing.io, home, "router");
    absent.loaded.deinit();
    try std.testing.expect(!absent.removed);
    var after = try load(gpa, std.testing.io, home);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.value.customProviderCount());
    try std.testing.expectEqual(null, after.value.customProvider("router"));
}

test "custom provider validation rejects unsafe definitions" {
    const valid: CustomProvider = .{ .api = .messages, .base_url = "https://proxy.test/v1", .models = &.{"m"} };
    try validateProvider("proxy", valid);
    try std.testing.expectError(error.InvalidSettings, validateProvider("claude", valid));
    try std.testing.expectError(error.InvalidSettings, validateProvider("custom", valid));
    try std.testing.expectError(error.InvalidSettings, validateProvider("Has Space", valid));
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "ftp://x" }));
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "https://" }));
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "https://x/\"" }));
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "https://x", .api_key = "a", .api_key_env = "B" }));
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "https://x", .api_key_env = "1BAD" }));
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "https://x", .api_key = "has space" }));
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "https://x", .models = &.{"bad id"} }));
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "https://x", .context_tokens = 10 }));
    var bad_headers: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer bad_headers.deinit(std.testing.allocator);
    try bad_headers.put(std.testing.allocator, "X-Bad", "line\nbreak");
    try std.testing.expectError(error.InvalidSettings, validateProvider("proxy", .{ .api = .messages, .base_url = "https://x", .headers = .{ .map = bad_headers } }));
    try std.testing.expect(validBaseUrl("http://127.0.0.1:8080"));
    try std.testing.expect(!validBaseUrl("localhost:11434"));
}
