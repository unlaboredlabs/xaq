const std = @import("std");

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    id: []const u8,
    text: []const u8,
};

pub const Usage = struct {
    input: u64 = 0,
    cached: u64 = 0,
    output: u64 = 0,
};

pub const Assistant = struct {
    text: []const u8,
    calls: []const ToolCall,
    raw_items: []const []const u8 = &.{},
    usage: Usage = .{},
};

pub const Entry = union(enum) {
    user: []const u8,
    assistant: Assistant,
    results: []const ToolResult,
};

pub fn approximateBytes(entries: []const Entry) usize {
    var total: usize = 0;
    for (entries) |entry| switch (entry) {
        .user => |text| total += text.len,
        .assistant => |answer| {
            total += answer.text.len;
            for (answer.calls) |call| total += call.id.len + call.name.len + call.arguments.len;
            for (answer.raw_items) |raw| total += raw.len;
        },
        .results => |results| {
            for (results) |result| total += result.id.len + result.text.len;
        },
    };
    return total;
}

/// Conservative token estimate for deciding when to compact. Natural text
/// and code average roughly four bytes per token; opaque persisted response
/// items are denser and use a two-byte estimate.
pub fn approximateTokens(entries: []const Entry) usize {
    var total: usize = 0;
    for (entries) |entry| switch (entry) {
        .user => |text| total += tokenEstimate(text.len, 4),
        .assistant => |answer| {
            if (answer.raw_items.len > 0) {
                for (answer.raw_items) |raw| total += tokenEstimate(raw.len, 2);
            } else {
                total += tokenEstimate(answer.text.len, 4);
                for (answer.calls) |call| total += tokenEstimate(call.id.len + call.name.len + call.arguments.len, 4);
            }
        },
        .results => |results| {
            for (results) |result| total += tokenEstimate(result.id.len + result.text.len, 4);
        },
    };
    return total;
}

fn tokenEstimate(bytes: usize, divisor: usize) usize {
    return (bytes + divisor - 1) / divisor;
}

test "approximate conversation size includes nested values" {
    const entries = [_]Entry{
        .{ .user = "abc" },
        .{ .assistant = .{ .text = "de", .calls = &.{.{ .id = "f", .name = "g", .arguments = "{}" }} } },
        .{ .results = &.{.{ .id = "f", .text = "h" }} },
    };
    try std.testing.expectEqual(@as(usize, 11), approximateBytes(&entries));
    try std.testing.expectEqual(@as(usize, 4), approximateTokens(&entries));
}
