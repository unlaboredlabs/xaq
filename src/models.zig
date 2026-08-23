const std = @import("std");
const auth = @import("auth.zig");

pub const Effort = enum {
    low,
    medium,
    high,
    xhigh,
    max,

    pub fn parse(value: []const u8) ?Effort {
        inline for (@typeInfo(Effort).@"enum".fields) |item| {
            if (std.mem.eql(u8, value, item.name)) return @enumFromInt(item.value);
        }
        return null;
    }
};

pub const Profile = struct {
    provider: auth.Provider,
    id: []const u8,
    context_tokens: u32,
    efforts: []const Effort,
    fast: bool = false,
};

const standard_efforts = [_]Effort{ .low, .medium, .high, .xhigh };
const full_efforts = [_]Effort{ .low, .medium, .high, .xhigh, .max };
const no_efforts = [_]Effort{};

/// Subscription-facing limits, not API-key product limits. The ChatGPT
/// values come from the Codex model catalog fetched on 2026-08-19; its
/// 272K window intentionally differs from the 1.05M OpenAI API window.
pub const profiles = [_]Profile{
    .{ .provider = .chatgpt, .id = "gpt-5.6-sol", .context_tokens = 272_000, .efforts = &full_efforts, .fast = true },
    .{ .provider = .chatgpt, .id = "gpt-5.6-terra", .context_tokens = 272_000, .efforts = &full_efforts, .fast = true },
    .{ .provider = .chatgpt, .id = "gpt-5.6-luna", .context_tokens = 272_000, .efforts = &full_efforts, .fast = true },
    .{ .provider = .chatgpt, .id = "gpt-5.5", .context_tokens = 272_000, .efforts = &standard_efforts, .fast = true },
    .{ .provider = .chatgpt, .id = "gpt-5.4", .context_tokens = 272_000, .efforts = &standard_efforts, .fast = true },
    .{ .provider = .chatgpt, .id = "gpt-5.4-mini", .context_tokens = 272_000, .efforts = &standard_efforts },
    .{ .provider = .chatgpt, .id = "gpt-5.3-codex-spark", .context_tokens = 128_000, .efforts = &standard_efforts },
    .{ .provider = .claude, .id = "claude-opus-5", .context_tokens = 1_000_000, .efforts = &full_efforts, .fast = true },
    .{ .provider = .claude, .id = "claude-sonnet-5", .context_tokens = 1_000_000, .efforts = &full_efforts },
    .{ .provider = .claude, .id = "claude-fable-5", .context_tokens = 1_000_000, .efforts = &full_efforts },
    .{ .provider = .claude, .id = "claude-haiku-4-5", .context_tokens = 200_000, .efforts = &no_efforts },
    .{ .provider = .grok, .id = "grok-4.6", .context_tokens = 500_000, .efforts = &standard_efforts },
};

const chatgpt_choices = [_][]const u8{
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-5.6-luna",
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.3-codex-spark",
};
const claude_choices = [_][]const u8{
    "claude-opus-5",
    "claude-sonnet-5",
    "claude-fable-5",
    "claude-haiku-4-5",
};
const grok_choices = [_][]const u8{"grok-4.6"};

pub fn defaultModel(provider: auth.Provider) []const u8 {
    return switch (provider) {
        .chatgpt => chatgpt_choices[0],
        .claude => claude_choices[0],
        .grok => grok_choices[0],
    };
}

pub fn choices(provider: auth.Provider) []const []const u8 {
    return switch (provider) {
        .chatgpt => &chatgpt_choices,
        .claude => &claude_choices,
        .grok => &grok_choices,
    };
}

pub fn find(provider: auth.Provider, id: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        if (profile.provider == provider and std.mem.eql(u8, profile.id, id)) return profile;
    }
    return null;
}

/// Catalog model IDs are globally unique, so a bare ID also names its
/// provider. This is what lets /model and --model switch providers without
/// a separate provider argument. Unknown IDs return null and stay with the
/// caller's provider.
pub fn findAny(id: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        if (std.mem.eql(u8, profile.id, id)) return profile;
    }
    return null;
}

pub fn contextWindow(provider: auth.Provider, id: []const u8) u32 {
    if (find(provider, id)) |profile| return profile.context_tokens;
    return switch (provider) {
        .chatgpt, .grok => 128_000,
        .claude => 200_000,
    };
}

/// Unknown explicit model IDs remain usable; only known models are rejected
/// when a documented capability is absent.
pub fn supportsEffort(provider: auth.Provider, id: []const u8, effort: Effort) bool {
    const profile = find(provider, id) orelse return true;
    return std.mem.containsAtLeastScalar(Effort, profile.efforts, 1, effort);
}

pub fn efforts(provider: auth.Provider, id: []const u8) []const Effort {
    return if (find(provider, id)) |profile| profile.efforts else &full_efforts;
}

/// Fast mode is a billed service tier, so unknown model IDs are rejected
/// unless they are snapshot IDs in Anthropic's documented Opus families.
pub fn supportsFast(provider: auth.Provider, id: []const u8) bool {
    if (find(provider, id)) |profile| return profile.fast;
    return provider == .claude and
        (std.mem.startsWith(u8, id, "claude-opus-5-") or
            std.mem.eql(u8, id, "claude-opus-4-8") or
            std.mem.startsWith(u8, id, "claude-opus-4-8-"));
}

test "catalog model IDs resolve their provider" {
    try std.testing.expectEqual(auth.Provider.chatgpt, findAny("gpt-5.4-mini").?.provider);
    try std.testing.expectEqual(auth.Provider.claude, findAny("claude-opus-5").?.provider);
    try std.testing.expectEqual(auth.Provider.grok, findAny("grok-4.6").?.provider);
    try std.testing.expectEqual(@as(?*const Profile, null), findAny("gpt-6-unknown"));
}

test "subscription profiles preserve product-specific context windows" {
    try std.testing.expectEqual(@as(u32, 272_000), contextWindow(.chatgpt, "gpt-5.6-sol"));
    try std.testing.expectEqual(@as(u32, 1_000_000), contextWindow(.claude, "claude-opus-5"));
    try std.testing.expectEqual(@as(u32, 200_000), contextWindow(.claude, "claude-haiku-4-5"));
    try std.testing.expectEqual(@as(u32, 500_000), contextWindow(.grok, "grok-4.6"));
    try std.testing.expect(!supportsEffort(.claude, "claude-haiku-4-5", .low));
    try std.testing.expect(!supportsEffort(.grok, "grok-4.6", .max));
    try std.testing.expect(supportsEffort(.chatgpt, "gpt-5.6-sol", .max));
    try std.testing.expect(supportsFast(.chatgpt, "gpt-5.6-sol"));
    try std.testing.expect(supportsFast(.chatgpt, "gpt-5.4"));
    try std.testing.expect(!supportsFast(.chatgpt, "gpt-5.4-mini"));
    try std.testing.expect(supportsFast(.claude, "claude-opus-5"));
    try std.testing.expect(supportsFast(.claude, "claude-opus-5-20260801"));
    try std.testing.expect(supportsFast(.claude, "claude-opus-4-8"));
    try std.testing.expect(!supportsFast(.claude, "claude-sonnet-5"));
    try std.testing.expect(!supportsFast(.grok, "grok-4.6"));
}
