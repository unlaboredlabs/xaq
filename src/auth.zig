const std = @import("std");
const Io = std.Io;
const transport = @import("transport.zig");

pub const Provider = enum {
    chatgpt,
    claude,
    grok,

    pub fn parse(value: []const u8) ?Provider {
        inline for (@typeInfo(Provider).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const Credential = struct {
    access: []const u8,
    refresh: []const u8,
    expires: i64,
    account_id: ?[]const u8 = null,
};

const Store = struct {
    chatgpt: ?Credential = null,
    claude: ?Credential = null,
    grok: ?Credential = null,
};

const openai_client = "app_EMoamEEZ73f0CkXaXp7hrann";
const anthropic_client = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const xai_client = "b1a00492-073a-47ea-816f-4c329264a828";

pub fn login(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider, input: *Io.Reader, output: *Io.Writer) !void {
    const new_credential = switch (provider) {
        .chatgpt => try loginChatGpt(gpa, io, output),
        .claude => try loginClaude(gpa, io, input, output),
        .grok => try loginGrok(gpa, io, output),
    };
    try put(gpa, io, home, provider, new_credential);
    try output.print("saved {s} credentials\n", .{@tagName(provider)});
}

pub fn credential(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider) !Credential {
    var store = try load(gpa, io, home);
    var current = get(store, provider) orelse return error.NotLoggedIn;
    const now = Io.Clock.real.now(io).toSeconds();
    if (current.expires > now + 60) return current;
    current = try refresh(gpa, io, provider, current);
    set(&store, provider, current);
    try save(gpa, io, home, store);
    return current;
}

fn authPath(gpa: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home, ".config", "xaq", "auth.json" });
}

fn load(gpa: std.mem.Allocator, io: Io, home: []const u8) !Store {
    const path = try authPath(gpa, home);
    defer gpa.free(path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer gpa.free(bytes);
    return try std.json.parseFromSliceLeaky(Store, gpa, bytes, .{ .ignore_unknown_fields = true });
}

fn save(gpa: std.mem.Allocator, io: Io, home: []const u8, store: Store) !void {
    const path = try authPath(gpa, home);
    defer gpa.free(path);
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(store, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = out.written(),
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.setPermissions(io, @enumFromInt(0o600));
}

fn put(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider, value: Credential) !void {
    var store = try load(gpa, io, home);
    set(&store, provider, value);
    try save(gpa, io, home, store);
}

fn get(store: Store, provider: Provider) ?Credential {
    return switch (provider) {
        .chatgpt => store.chatgpt,
        .claude => store.claude,
        .grok => store.grok,
    };
}

fn set(store: *Store, provider: Provider, value: Credential) void {
    switch (provider) {
        .chatgpt => store.chatgpt = value,
        .claude => store.claude = value,
        .grok => store.grok = value,
    }
}

fn requireStatus(response: transport.Response) !void {
    if (response.status < 200 or response.status >= 300) {
        std.debug.print("provider HTTP {d}: {s}\n", .{ response.status, response.body });
        return error.ProviderRequestFailed;
    }
}

fn parseJson(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
}

fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    const item = switch (value) {
        .object => |o| o.get(key) orelse return error.InvalidTokenResponse,
        else => return error.InvalidTokenResponse,
    };
    return switch (item) {
        .string => |s| s,
        else => error.InvalidTokenResponse,
    };
}

fn number(value: std.json.Value, key: []const u8, fallback: i64) i64 {
    const item = switch (value) {
        .object => |o| o.get(key) orelse return fallback,
        else => return fallback,
    };
    return switch (item) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        .string => |n| std.fmt.parseInt(i64, n, 10) catch fallback,
        else => fallback,
    };
}

fn tokenCredential(gpa: std.mem.Allocator, io: Io, body: []const u8, old_refresh: ?[]const u8) !Credential {
    var parsed = try parseJson(gpa, body);
    defer parsed.deinit();
    const access = try gpa.dupe(u8, try string(parsed.value, "access_token"));
    const refresh_token = if (switch (parsed.value) {
        .object => |o| o.get("refresh_token"),
        else => null,
    }) |v|
        try gpa.dupe(u8, switch (v) {
            .string => |s| s,
            else => return error.InvalidTokenResponse,
        })
    else if (old_refresh) |old| try gpa.dupe(u8, old) else return error.InvalidTokenResponse;
    return .{
        .access = access,
        .refresh = refresh_token,
        .expires = Io.Clock.real.now(io).toSeconds() + number(parsed.value, "expires_in", 3600) - 300,
    };
}

fn loginChatGpt(gpa: std.mem.Allocator, io: Io, output: *Io.Writer) !Credential {
    const response = try transport.post(gpa, io, "https://auth.openai.com/api/accounts/deviceauth/usercode", "application/json", &.{},
        \\{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann"}
    );
    defer gpa.free(response.body);
    try requireStatus(response);
    var parsed = try parseJson(gpa, response.body);
    defer parsed.deinit();
    const device_id = try gpa.dupe(u8, try string(parsed.value, "device_auth_id"));
    const user_code = try gpa.dupe(u8, try string(parsed.value, "user_code"));
    const interval = number(parsed.value, "interval", 5);
    try output.print("Open https://auth.openai.com/codex/device and enter: {s}\n", .{user_code});
    try output.flush();

    while (true) {
        try io.sleep(.fromSeconds(@max(interval, 1)), .awake);
        var body: Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        try js.objectField("device_auth_id");
        try js.write(device_id);
        try js.objectField("user_code");
        try js.write(user_code);
        try js.endObject();
        const poll = try transport.post(gpa, io, "https://auth.openai.com/api/accounts/deviceauth/token", "application/json", &.{}, body.written());
        defer gpa.free(poll.body);
        if (poll.status == 403 or poll.status == 404) continue;
        try requireStatus(poll);
        var token = try parseJson(gpa, poll.body);
        defer token.deinit();
        const code = try gpa.dupe(u8, try string(token.value, "authorization_code"));
        const verifier = try gpa.dupe(u8, try string(token.value, "code_verifier"));
        return exchangeOpenAi(gpa, io, code, verifier);
    }
}

fn exchangeOpenAi(gpa: std.mem.Allocator, io: Io, code: []const u8, verifier: []const u8) !Credential {
    const body = try transport.formEncode(gpa, &.{
        .{ "grant_type", "authorization_code" }, .{ "client_id", openai_client },                                    .{ "code", code },
        .{ "code_verifier", verifier },          .{ "redirect_uri", "https://auth.openai.com/deviceauth/callback" },
    });
    defer gpa.free(body);
    const response = try transport.post(gpa, io, "https://auth.openai.com/oauth/token", "application/x-www-form-urlencoded", &.{}, body);
    defer gpa.free(response.body);
    try requireStatus(response);
    var result = try tokenCredential(gpa, io, response.body, null);
    result.account_id = try accountId(gpa, result.access);
    return result;
}

fn accountId(gpa: std.mem.Allocator, jwt: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return error.InvalidAccessToken;
    const payload = parts.next() orelse return error.InvalidAccessToken;
    const size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    const decoded = try gpa.alloc(u8, size);
    defer gpa.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload);
    var parsed = try parseJson(gpa, decoded);
    defer parsed.deinit();
    const claim = switch (parsed.value) {
        .object => |o| o.get("https://api.openai.com/auth") orelse return error.InvalidAccessToken,
        else => return error.InvalidAccessToken,
    };
    return gpa.dupe(u8, try string(claim, "chatgpt_account_id"));
}

fn pkce(gpa: std.mem.Allocator, io: Io) !struct { verifier: []u8, challenge: []u8 } {
    var random: [32]u8 = undefined;
    try io.randomSecure(&random);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const verifier = try gpa.alloc(u8, encoder.calcSize(random.len));
    _ = encoder.encode(verifier, &random);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = try gpa.alloc(u8, encoder.calcSize(digest.len));
    _ = encoder.encode(challenge, &digest);
    return .{ .verifier = verifier, .challenge = challenge };
}

fn loginClaude(gpa: std.mem.Allocator, io: Io, input: *Io.Reader, output: *Io.Writer) !Credential {
    const pair = try pkce(gpa, io);
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "code", "true" },                                    .{ "client_id", anthropic_client },                                                                                         .{ "response_type", "code" },
        .{ "redirect_uri", "http://localhost:53692/callback" }, .{ "scope", "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload" }, .{ "code_challenge", pair.challenge },
        .{ "code_challenge_method", "S256" },                   .{ "state", pair.verifier },
    };
    const query = try transport.formEncode(gpa, &fields);
    const url = try std.fmt.allocPrint(gpa, "https://claude.ai/oauth/authorize?{s}", .{query});
    try output.print("Open this URL:\n{s}\nPaste the final redirect URL or authorization code: ", .{url});
    try output.flush();
    const line = (try input.takeDelimiter('\n')) orelse return error.EndOfStream;
    const code = try authorizationCode(gpa, std.mem.trim(u8, line, " \r\n"));

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var js: std.json.Stringify = .{ .writer = &body.writer };
    try js.beginObject();
    inline for (.{ .{ "grant_type", "authorization_code" }, .{ "client_id", anthropic_client }, .{ "code", code }, .{ "state", pair.verifier }, .{ "redirect_uri", "http://localhost:53692/callback" }, .{ "code_verifier", pair.verifier } }) |field| {
        try js.objectField(field[0]);
        try js.write(field[1]);
    }
    try js.endObject();
    const response = try transport.post(gpa, io, "https://platform.claude.com/v1/oauth/token", "application/json", &.{.{ .name = "Accept", .value = "application/json" }}, body.written());
    defer gpa.free(response.body);
    try requireStatus(response);
    return tokenCredential(gpa, io, response.body, null);
}

fn authorizationCode(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, value, "code=")) |at| {
        const tail = value[at + 5 ..];
        const end = std.mem.indexOfAny(u8, tail, "&#") orelse tail.len;
        const out = try gpa.dupe(u8, tail[0..end]);
        return std.Uri.percentDecodeInPlace(out);
    }
    if (std.mem.indexOfScalar(u8, value, '#')) |at| return gpa.dupe(u8, value[0..at]);
    return gpa.dupe(u8, value);
}

fn loginGrok(gpa: std.mem.Allocator, io: Io, output: *Io.Writer) !Credential {
    const body = try transport.formEncode(gpa, &.{
        .{ "client_id", xai_client }, .{ "scope", "openid profile email offline_access grok-cli:access api:access" }, .{ "referrer", "xaq" },
    });
    defer gpa.free(body);
    const response = try transport.post(gpa, io, "https://auth.x.ai/oauth2/device/code", "application/x-www-form-urlencoded", &.{}, body);
    defer gpa.free(response.body);
    try requireStatus(response);
    var parsed = try parseJson(gpa, response.body);
    defer parsed.deinit();
    const device = try gpa.dupe(u8, try string(parsed.value, "device_code"));
    const user = try string(parsed.value, "user_code");
    const uri = try string(parsed.value, "verification_uri");
    const interval = number(parsed.value, "interval", 5);
    try output.print("Open {s} and enter: {s}\n", .{ uri, user });
    try output.flush();
    while (true) {
        try io.sleep(.fromSeconds(@max(interval, 1)), .awake);
        const poll_body = try transport.formEncode(gpa, &.{
            .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" }, .{ "client_id", xai_client }, .{ "device_code", device },
        });
        defer gpa.free(poll_body);
        const poll = try transport.post(gpa, io, "https://auth.x.ai/oauth2/token", "application/x-www-form-urlencoded", &.{}, poll_body);
        defer gpa.free(poll.body);
        if (poll.status >= 200 and poll.status < 300) return tokenCredential(gpa, io, poll.body, null);
        var problem = parseJson(gpa, poll.body) catch continue;
        defer problem.deinit();
        const kind = string(problem.value, "error") catch continue;
        if (std.mem.eql(u8, kind, "authorization_pending") or std.mem.eql(u8, kind, "slow_down")) continue;
        try requireStatus(poll);
    }
}

fn refresh(gpa: std.mem.Allocator, io: Io, provider: Provider, old: Credential) !Credential {
    const endpoint = switch (provider) {
        .chatgpt => "https://auth.openai.com/oauth/token",
        .claude => "https://platform.claude.com/v1/oauth/token",
        .grok => "https://auth.x.ai/oauth2/token",
    };
    const client = switch (provider) {
        .chatgpt => openai_client,
        .claude => anthropic_client,
        .grok => xai_client,
    };
    var response: transport.Response = undefined;
    if (provider == .claude) {
        var body: Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        var js: std.json.Stringify = .{ .writer = &body.writer };
        try js.beginObject();
        inline for (.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client }, .{ "refresh_token", old.refresh } }) |field| {
            try js.objectField(field[0]);
            try js.write(field[1]);
        }
        try js.endObject();
        response = try transport.post(gpa, io, endpoint, "application/json", &.{}, body.written());
    } else {
        const body = try transport.formEncode(gpa, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client }, .{ "refresh_token", old.refresh } });
        defer gpa.free(body);
        response = try transport.post(gpa, io, endpoint, "application/x-www-form-urlencoded", &.{}, body);
    }
    defer gpa.free(response.body);
    try requireStatus(response);
    var result = try tokenCredential(gpa, io, response.body, old.refresh);
    if (provider == .chatgpt) result.account_id = try accountId(gpa, result.access);
    return result;
}

test "provider parsing" {
    try std.testing.expectEqual(Provider.chatgpt, Provider.parse("chatgpt").?);
    try std.testing.expectEqual(@as(?Provider, null), Provider.parse("openai"));
}
