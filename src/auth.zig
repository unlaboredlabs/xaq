const std = @import("std");
const Io = std.Io;
const cancel = @import("cancel.zig");
const input_mod = @import("input.zig");
const spin = @import("spin.zig");
const term = @import("term.zig");
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

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .chatgpt => "ChatGPT",
            .claude => "Claude",
            .grok => "Grok",
        };
    }
};

pub const Credential = struct {
    access: []const u8,
    refresh: []const u8,
    expires: i64,
    account_id: ?[]const u8 = null,
};

pub const LoginStatus = enum {
    not_connected,
    connected,
    refresh_needed,

    pub fn label(self: LoginStatus) []const u8 {
        return switch (self) {
            .not_connected => "not connected",
            .connected => "connected",
            .refresh_needed => "refresh needed",
        };
    }

    pub fn hasCredential(self: LoginStatus) bool {
        return self != .not_connected;
    }
};

/// Caller-owned storage for an OAuth or device-flow failure. Keeping this on
/// the request stack avoids a process-global error slot when subagents refresh
/// credentials at the same time.
pub const Diagnostic = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buffer[0..self.len];
    }

    fn clear(self: *Diagnostic) void {
        self.len = 0;
    }

    fn capture(self: *Diagnostic, gpa: std.mem.Allocator, response: transport.Response) void {
        var writer: Io.Writer = .fixed(&self.buffer);
        writeProviderFailure(gpa, response, &writer) catch {};
        self.len = writer.buffered().len;
    }
};

const Store = struct {
    chatgpt: ?Credential = null,
    claude: ?Credential = null,
    grok: ?Credential = null,
};

const openai_client = "app_EMoamEEZ73f0CkXaXp7hrann";
const openai_redirect = "http://localhost:1455/auth/callback";
const anthropic_client = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const anthropic_authorize = "https://claude.com/cai/oauth/authorize";
const anthropic_redirect = "https://platform.claude.com/oauth/code/callback";
const anthropic_token = "https://platform.claude.com/v1/oauth/token";
const anthropic_scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";
const anthropic_refresh_scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";
const anthropic_oauth_headers = [_]transport.Header{
    .{ .name = "Accept", .value = "application/json" },
    .{ .name = "User-Agent", .value = "xaq/0.1" },
};
const xai_client = "b1a00492-073a-47ea-816f-4c329264a828";

pub fn login(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider, input: *Io.Reader, output: *Io.Writer) !void {
    const new_credential = switch (provider) {
        .chatgpt => try loginChatGpt(gpa, io, input, output),
        .claude => try loginClaude(gpa, io, input, output),
        .grok => try loginGrok(gpa, io, output),
    };
    try put(gpa, io, home, provider, new_credential);
    try output.print("{s} connected.\n", .{provider.label()});
}

/// Inspect the local credential store without refreshing a token or making a
/// provider request. An expired access token can still have a usable refresh
/// token, so report it separately instead of calling it fully connected.
pub fn loginStatus(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider) !LoginStatus {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const current = get(try load(arena.allocator(), io, home), provider) orelse return .not_connected;
    const now = Io.Clock.real.now(io).toSeconds();
    return if (current.expires > now + 60) .connected else .refresh_needed;
}

pub fn isLoggedIn(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider) !bool {
    return (try loginStatus(gpa, io, home, provider)).hasCredential();
}

pub fn credential(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider) !Credential {
    return credentialWithDiagnostic(gpa, io, home, provider, null);
}

pub fn credentialWithDiagnostic(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider, diagnostic: ?*Diagnostic) !Credential {
    if (diagnostic) |value| value.clear();
    var lock = try authLock(gpa, io, home);
    defer lock.close(io);
    var store = try load(gpa, io, home);
    var current = get(store, provider) orelse return error.NotLoggedIn;
    const now = Io.Clock.real.now(io).toSeconds();
    if (current.expires > now + 60) return current;
    current = try refresh(gpa, io, provider, current, diagnostic);
    set(&store, provider, current);
    try saveUnlocked(gpa, io, home, store);
    return current;
}

/// Refresh even when the cached expiry has not elapsed. Used once after an
/// authenticated provider request returns 401.
pub fn forceRefresh(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider) !void {
    return forceRefreshWithDiagnostic(gpa, io, home, provider, null);
}

pub fn forceRefreshWithDiagnostic(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider, diagnostic: ?*Diagnostic) !void {
    if (diagnostic) |value| value.clear();
    var lock = try authLock(gpa, io, home);
    defer lock.close(io);
    var store = try load(gpa, io, home);
    const current = get(store, provider) orelse return error.NotLoggedIn;
    set(&store, provider, try refresh(gpa, io, provider, current, diagnostic));
    try saveUnlocked(gpa, io, home, store);
}

pub fn logout(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider) !bool {
    var lock = try authLock(gpa, io, home);
    defer lock.close(io);
    var store = try load(gpa, io, home);
    if (get(store, provider) == null) return false;
    switch (provider) {
        .chatgpt => store.chatgpt = null,
        .claude => store.claude = null,
        .grok => store.grok = null,
    }
    try saveUnlocked(gpa, io, home, store);
    return true;
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
    return try std.json.parseFromSliceLeaky(Store, gpa, bytes, .{
        .ignore_unknown_fields = true,
        // Store strings must outlive the input buffer; credentials are used
        // after this function frees `bytes`.
        .allocate = .alloc_always,
    });
}

fn saveUnlocked(gpa: std.mem.Allocator, io: Io, home: []const u8, store: Store) !void {
    const path = try authPath(gpa, home);
    defer gpa.free(path);
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(store, .{ .whitespace = .indent_2 }, &out.writer);
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
    try file.setPermissions(io, @enumFromInt(0o600));
    try file.sync(io);
    try Io.Dir.renameAbsolute(temporary, path, io);
}

fn put(gpa: std.mem.Allocator, io: Io, home: []const u8, provider: Provider, value: Credential) !void {
    var lock = try authLock(gpa, io, home);
    defer lock.close(io);
    var store = try load(gpa, io, home);
    set(&store, provider, value);
    try saveUnlocked(gpa, io, home, store);
}

fn authLock(gpa: std.mem.Allocator, io: Io, home: []const u8) !Io.File {
    const directory = try std.fs.path.join(gpa, &.{ home, ".config", "xaq" });
    defer gpa.free(directory);
    try Io.Dir.cwd().createDirPath(io, directory);
    const path = try std.fs.path.join(gpa, &.{ directory, "auth.lock" });
    defer gpa.free(path);
    return Io.Dir.cwd().createFile(io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = @enumFromInt(0o600),
    });
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

fn writeProviderFailure(gpa: std.mem.Allocator, response: transport.Response, writer: *Io.Writer) !void {
    try writer.print("provider HTTP {d}", .{response.status});
    if (transport.errorMessage(gpa, response.body)) |message| {
        defer gpa.free(message);
        try writer.writeAll(": ");
        var safe: term.SafeWriter = .{ .output = writer };
        try safe.write(message);
    }
}

fn requireStatus(gpa: std.mem.Allocator, response: transport.Response, output: ?*Io.Writer, diagnostic: ?*Diagnostic) !void {
    if (response.status < 200 or response.status >= 300) {
        if (diagnostic) |value| value.capture(gpa, response);
        if (output) |writer| {
            try writeProviderFailure(gpa, response, writer);
            try writer.writeByte('\n');
            try writer.flush();
        } else if (diagnostic == null) {
            std.debug.print("provider HTTP {d}\n", .{response.status});
        }
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

fn loginChatGpt(gpa: std.mem.Allocator, io: Io, input: *Io.Reader, output: *Io.Writer) !Credential {
    const pair = try pkce(gpa, io);
    const state = try randomToken(gpa, io, 16);
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "response_type", "code" },
        .{ "client_id", openai_client },
        .{ "redirect_uri", openai_redirect },
        .{ "scope", "openid profile email offline_access" },
        .{ "code_challenge", pair.challenge },
        .{ "code_challenge_method", "S256" },
        .{ "state", state },
        .{ "id_token_add_organizations", "true" },
        .{ "codex_cli_simplified_flow", "true" },
        .{ "originator", "xaq" },
    };
    const query = try transport.formEncode(gpa, &fields);
    const url = try std.fmt.allocPrint(gpa, "https://auth.openai.com/oauth/authorize?{s}", .{query});
    openBrowser(gpa, io, url);
    try output.print(
        "Open this URL if your browser did not open:\n{s}\nThe localhost page may fail to load. Copy its full URL from the address bar.\n",
        .{url},
    );
    try output.flush();
    const submitted = (try input_mod.readSecret(gpa, input, output, "Callback URL or code: ")) orelse return error.EndOfStream;
    defer gpa.free(submitted);
    const returned_state = try authorizationState(gpa, submitted);
    if (returned_state) |actual| {
        if (!std.mem.eql(u8, actual, state)) return error.OAuthStateMismatch;
    }
    const code = try authorizationCode(gpa, submitted);
    try requireCodeShape(code);
    return exchangeOpenAi(gpa, io, code, pair.verifier, output);
}

fn exchangeOpenAi(gpa: std.mem.Allocator, io: Io, code: []const u8, verifier: []const u8, output: *Io.Writer) !Credential {
    const body = try transport.formEncode(gpa, &.{
        .{ "grant_type", "authorization_code" }, .{ "client_id", openai_client },      .{ "code", code },
        .{ "code_verifier", verifier },          .{ "redirect_uri", openai_redirect },
    });
    defer gpa.free(body);
    const response = try transport.post(gpa, io, "https://auth.openai.com/oauth/token", "application/x-www-form-urlencoded", &.{}, body);
    defer gpa.free(response.body);
    try requireStatus(gpa, response, output, null);
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

fn randomToken(gpa: std.mem.Allocator, io: Io, comptime byte_count: usize) ![]u8 {
    var random: [byte_count]u8 = undefined;
    try io.randomSecure(&random);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const token = try gpa.alloc(u8, encoder.calcSize(random.len));
    _ = encoder.encode(token, &random);
    return token;
}

/// Best-effort convenience: launch the platform opener and ignore any
/// failure; the URL is always printed for manual use.
fn openBrowser(gpa: std.mem.Allocator, io: Io, url: []const u8) void {
    const opener = if (@import("builtin").os.tag == .macos) "open" else "xdg-open";
    const result = std.process.run(gpa, io, .{
        .argv = &.{ opener, url },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch return;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

fn loginClaude(gpa: std.mem.Allocator, io: Io, input: *Io.Reader, output: *Io.Writer) !Credential {
    const pair = try pkce(gpa, io);
    const url = try claudeAuthorizationUrl(gpa, pair.challenge, pair.verifier);
    defer gpa.free(url);
    openBrowser(gpa, io, url);
    try output.print(
        "Open this URL if your browser did not open:\n{s}\nCopy the authorization code from the callback page.\n",
        .{url},
    );
    try output.flush();
    const submitted = (try input_mod.readSecret(gpa, input, output, "Callback URL or code: ")) orelse return error.EndOfStream;
    defer gpa.free(submitted);
    // The callback state echoes the PKCE verifier; when the paste
    // includes one, a mismatch means a stale or foreign login attempt.
    if (try authorizationState(gpa, submitted)) |actual| {
        if (!std.mem.eql(u8, actual, pair.verifier)) return error.OAuthStateMismatch;
    }
    const code = try authorizationCode(gpa, submitted);
    defer gpa.free(code);
    try requireCodeShape(code);

    const body = try claudeExchangeBody(gpa, code, pair.verifier);
    defer gpa.free(body);
    const response = try transport.post(gpa, io, anthropic_token, "application/json", &anthropic_oauth_headers, body);
    defer gpa.free(response.body);
    try requireStatus(gpa, response, output, null);
    return tokenCredential(gpa, io, response.body, null);
}

fn claudeAuthorizationUrl(gpa: std.mem.Allocator, challenge: []const u8, state: []const u8) ![]u8 {
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "code", "true" },                     .{ "client_id", anthropic_client }, .{ "response_type", "code" },
        .{ "redirect_uri", anthropic_redirect }, .{ "scope", anthropic_scopes },     .{ "code_challenge", challenge },
        .{ "code_challenge_method", "S256" },    .{ "state", state },
    };
    const query = try transport.formEncode(gpa, &fields);
    defer gpa.free(query);
    return std.fmt.allocPrint(gpa, "{s}?{s}", .{ anthropic_authorize, query });
}

fn claudeExchangeBody(gpa: std.mem.Allocator, code: []const u8, verifier: []const u8) ![]u8 {
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var js: std.json.Stringify = .{ .writer = &body.writer };
    try js.beginObject();
    inline for (.{ .{ "grant_type", "authorization_code" }, .{ "client_id", anthropic_client }, .{ "code", code }, .{ "state", verifier }, .{ "redirect_uri", anthropic_redirect }, .{ "code_verifier", verifier } }) |field| {
        try js.objectField(field[0]);
        try js.write(field[1]);
    }
    try js.endObject();
    return body.toOwnedSlice();
}

/// Reject pastes that cannot be an authorization code before they reach
/// the token endpoint, so the user gets "that doesn't look like a
/// callback URL or code" instead of a cryptic provider HTTP 400.
fn requireCodeShape(code: []const u8) error{InvalidAuthorizationInput}!void {
    if (code.len == 0 or code.len > 2048) return error.InvalidAuthorizationInput;
    for (code) |byte| {
        if (byte <= ' ' or byte == 0x7f) return error.InvalidAuthorizationInput;
    }
}

fn authorizationCode(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, value, "code=")) |at| {
        const tail = value[at + 5 ..];
        const end = std.mem.indexOfAny(u8, tail, "&#") orelse tail.len;
        const out = try gpa.dupe(u8, tail[0..end]);
        // percentDecodeInPlace returns a subslice; dupe so callers can free.
        defer gpa.free(out);
        return try gpa.dupe(u8, std.Uri.percentDecodeInPlace(out));
    }
    if (std.mem.indexOfScalar(u8, value, '#')) |at| return gpa.dupe(u8, value[0..at]);
    return gpa.dupe(u8, value);
}

fn authorizationState(gpa: std.mem.Allocator, value: []const u8) !?[]const u8 {
    if (std.mem.indexOf(u8, value, "state=")) |at| {
        const tail = value[at + 6 ..];
        const end = std.mem.indexOfAny(u8, tail, "&#") orelse tail.len;
        const out = try gpa.dupe(u8, tail[0..end]);
        defer gpa.free(out);
        return try gpa.dupe(u8, std.Uri.percentDecodeInPlace(out));
    }
    if (std.mem.indexOfScalar(u8, value, '#')) |at| return try gpa.dupe(u8, value[at + 1 ..]);
    return null;
}

fn loginGrok(gpa: std.mem.Allocator, io: Io, output: *Io.Writer) !Credential {
    try checkLoginCancellation();
    const body = try transport.formEncode(gpa, &.{
        .{ "client_id", xai_client }, .{ "scope", "openid profile email offline_access grok-cli:access api:access" }, .{ "referrer", "xaq" },
    });
    defer gpa.free(body);
    const response = try transport.post(gpa, io, "https://auth.x.ai/oauth2/device/code", "application/x-www-form-urlencoded", &.{}, body);
    defer gpa.free(response.body);
    try requireStatus(gpa, response, output, null);
    var parsed = try parseJson(gpa, response.body);
    defer parsed.deinit();
    const device = try gpa.dupe(u8, try string(parsed.value, "device_code"));
    const user = try string(parsed.value, "user_code");
    const uri = try string(parsed.value, "verification_uri");
    const interval = number(parsed.value, "interval", 5);
    openBrowser(gpa, io, uri);
    try output.print("Open {s} and enter: {s}\n", .{ uri, user });
    // The spinner is a no-op without styling (NO_COLOR, dumb terminals,
    // pipes); print a static line so the minutes-long poll is not silent.
    if (!term.enabled) try output.writeAll("waiting for approval...\n");
    try output.flush();
    spin.start(io, "waiting for approval");
    defer spin.stop();
    while (true) {
        try waitForLoginPoll(io, interval);
        const poll_body = try transport.formEncode(gpa, &.{
            .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" }, .{ "client_id", xai_client }, .{ "device_code", device },
        });
        defer gpa.free(poll_body);
        try checkLoginCancellation();
        const poll = try transport.post(gpa, io, "https://auth.x.ai/oauth2/token", "application/x-www-form-urlencoded", &.{}, poll_body);
        defer gpa.free(poll.body);
        if (poll.status >= 200 and poll.status < 300) return tokenCredential(gpa, io, poll.body, null);
        var problem = parseJson(gpa, poll.body) catch continue;
        defer problem.deinit();
        const kind = string(problem.value, "error") catch continue;
        if (std.mem.eql(u8, kind, "authorization_pending") or std.mem.eql(u8, kind, "slow_down")) continue;
        try requireStatus(gpa, poll, output, null);
    }
}

fn checkLoginCancellation() !void {
    if (cancel.requested()) return error.Cancelled;
}

fn waitForLoginPoll(io: Io, seconds: i64) !void {
    var remaining_ms: i64 = @min(@max(seconds, @as(i64, 1)), @as(i64, 60)) * @as(i64, 1000);
    while (remaining_ms > 0) {
        try checkLoginCancellation();
        const step = @min(remaining_ms, 100);
        try io.sleep(.fromMilliseconds(step), .awake);
        remaining_ms -= step;
    }
    try checkLoginCancellation();
}

fn refresh(gpa: std.mem.Allocator, io: Io, provider: Provider, old: Credential, diagnostic: ?*Diagnostic) !Credential {
    const endpoint = switch (provider) {
        .chatgpt => "https://auth.openai.com/oauth/token",
        .claude => anthropic_token,
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
        inline for (.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client }, .{ "refresh_token", old.refresh }, .{ "scope", anthropic_refresh_scopes } }) |field| {
            try js.objectField(field[0]);
            try js.write(field[1]);
        }
        try js.endObject();
        response = try transport.post(gpa, io, endpoint, "application/json", &anthropic_oauth_headers, body.written());
    } else {
        const body = try transport.formEncode(gpa, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client }, .{ "refresh_token", old.refresh } });
        defer gpa.free(body);
        response = try transport.post(gpa, io, endpoint, "application/x-www-form-urlencoded", &.{}, body);
    }
    defer gpa.free(response.body);
    try requireStatus(gpa, response, null, diagnostic);
    var result = try tokenCredential(gpa, io, response.body, old.refresh);
    if (provider == .chatgpt) result.account_id = try accountId(gpa, result.access);
    return result;
}

test "provider parsing" {
    try std.testing.expectEqual(Provider.chatgpt, Provider.parse("chatgpt").?);
    try std.testing.expectEqual(@as(?Provider, null), Provider.parse("openai"));
    try std.testing.expectEqualStrings("ChatGPT", Provider.chatgpt.label());
}

test "guided login cancellation is checked before polling" {
    cancel.reset();
    defer cancel.reset();
    try checkLoginCancellation();
    cancel.processToken().request();
    try std.testing.expectError(error.Cancelled, checkLoginCancellation());
}

test "guided login wait responds to cancellation" {
    const Request = struct {
        fn run(io: Io) void {
            io.sleep(.fromMilliseconds(20), .awake) catch return;
            cancel.processToken().request();
        }
    };
    cancel.reset();
    defer cancel.reset();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var future = try threaded.io().concurrent(Request.run, .{threaded.io()});
    try std.testing.expectError(error.Cancelled, waitForLoginPoll(threaded.io(), 5));
    future.await(threaded.io());
}

test "login status reads the local store without refreshing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    const home = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buffer[0..cwd_length], temporary.sub_path });
    defer std.testing.allocator.free(home);

    try std.testing.expectEqual(LoginStatus.not_connected, try loginStatus(gpa, std.testing.io, home, .chatgpt));
    try std.testing.expect(!try isLoggedIn(gpa, std.testing.io, home, .chatgpt));
    try put(gpa, std.testing.io, home, .chatgpt, .{
        .access = "access",
        .refresh = "refresh",
        .expires = 1,
    });
    try std.testing.expectEqual(LoginStatus.refresh_needed, try loginStatus(gpa, std.testing.io, home, .chatgpt));
    try std.testing.expect(try isLoggedIn(gpa, std.testing.io, home, .chatgpt));
    try put(gpa, std.testing.io, home, .claude, .{
        .access = "access",
        .refresh = "refresh",
        .expires = std.math.maxInt(i64),
    });
    try std.testing.expectEqual(LoginStatus.connected, try loginStatus(gpa, std.testing.io, home, .claude));
}

test "authorization input parses browser callback" {
    const gpa = std.testing.allocator;
    const url = "http://localhost:1455/auth/callback?code=abc%2F123&state=expected";
    const code = try authorizationCode(gpa, url);
    defer gpa.free(code);
    const state = (try authorizationState(gpa, url)).?;
    defer gpa.free(state);
    try std.testing.expectEqualStrings("abc/123", code);
    try std.testing.expectEqualStrings("expected", state);
}

test "Claude manual OAuth uses the current provider callback" {
    const gpa = std.testing.allocator;
    const url = try claudeAuthorizationUrl(gpa, "challenge", "state");
    defer gpa.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://claude.com/cai/oauth/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2Flocalhost") == null);

    const body = try claudeExchangeBody(gpa, "code", "verifier");
    defer gpa.free(body);
    var parsed = try parseJson(gpa, body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://platform.claude.com/oauth/code/callback", try string(parsed.value, "redirect_uri"));
    try std.testing.expectEqualStrings("code", try string(parsed.value, "code"));
    try std.testing.expectEqualStrings("verifier", try string(parsed.value, "code_verifier"));
    try std.testing.expectEqualStrings("verifier", try string(parsed.value, "state"));
}

test "Claude OAuth requests identify xaq instead of curl" {
    try std.testing.expectEqualStrings("Accept", anthropic_oauth_headers[0].name);
    try std.testing.expectEqualStrings("application/json", anthropic_oauth_headers[0].value);
    try std.testing.expectEqualStrings("User-Agent", anthropic_oauth_headers[1].name);
    try std.testing.expectEqualStrings("xaq/0.1", anthropic_oauth_headers[1].value);
}

test "login provider failures show the OAuth error description" {
    const gpa = std.testing.allocator;
    const body = try gpa.dupe(u8, "{\"error\":\"invalid_grant\",\"error_description\":\"Authorization code expired\"}");
    defer gpa.free(body);
    var buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.ProviderRequestFailed, requireStatus(gpa, .{ .status = 400, .body = body }, &writer, null));
    try std.testing.expectEqualStrings("provider HTTP 400: Authorization code expired\n", writer.buffered());

    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.ProviderRequestFailed, requireStatus(gpa, .{ .status = 400, .body = body }, null, &diagnostic));
    try std.testing.expectEqualStrings("provider HTTP 400: Authorization code expired", diagnostic.message().?);
}

test "Claude manual authorization code carries callback state" {
    const gpa = std.testing.allocator;
    const code = try authorizationCode(gpa, "authorization-code#expected-state");
    defer gpa.free(code);
    const state = (try authorizationState(gpa, "authorization-code#expected-state")).?;
    defer gpa.free(state);
    try std.testing.expectEqualStrings("authorization-code", code);
    try std.testing.expectEqualStrings("expected-state", state);
}

test "credential strings outlive auth file buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const source = try gpa.dupe(u8,
        \\{"chatgpt":{"access":"access-token","refresh":"refresh-token","expires":42,"account_id":"account-id"}}
    );
    const store = try std.json.parseFromSliceLeaky(Store, gpa, source, .{
        .allocate = .alloc_always,
    });
    gpa.free(source);
    const overwrite = try gpa.alloc(u8, source.len);
    @memset(overwrite, 'x');
    try std.testing.expectEqualStrings("access-token", store.chatgpt.?.access);
    try std.testing.expectEqualStrings("account-id", store.chatgpt.?.account_id.?);
}
