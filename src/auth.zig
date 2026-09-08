const std = @import("std");
const Io = std.Io;
const cancel = @import("cancel.zig");
const input_mod = @import("input.zig");
const spin = @import("spin.zig");
const settings = @import("settings.zig");
const term = @import("term.zig");
const transport = @import("transport.zig");
const tui = @import("tui.zig");

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
    try tui.setMouseReporting(false);
    defer tui.setMouseReporting(true) catch {};
    const new_credential = switch (provider) {
        .chatgpt => try loginChatGpt(gpa, io, input, output),
        .claude => try loginClaude(gpa, io, input, output),
        .grok => try loginGrok(gpa, io, input, output),
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
    try settings.saveJsonFile(gpa, io, path, store);
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
    var file = try Io.Dir.cwd().createFile(io, path, .{
        .truncate = false,
        .permissions = @enumFromInt(0o600),
    });
    errdefer file.close(io);
    while (true) {
        // Another session may hold this lock throughout a token refresh.
        // Poll without blocking Ctrl-C behind its network request.
        if (cancel.requested()) return error.Cancelled;
        if (try file.tryLock(io, .exclusive)) return file;
        try cancel.processToken().sleep(io, .fromMilliseconds(50));
    }
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

fn number(value: std.json.Value, key: []const u8, fallback: i64) !i64 {
    const item = switch (value) {
        .object => |o| o.get(key) orelse return fallback,
        else => return fallback,
    };
    return switch (item) {
        .integer => |n| n,
        .float => |n| if (std.math.isFinite(n) and n >= -0x1p63 and n < 0x1p63 and @floor(n) == n)
            @intFromFloat(n)
        else
            error.InvalidTokenResponse,
        .string, .number_string => |n| std.fmt.parseInt(i64, n, 10) catch error.InvalidTokenResponse,
        else => error.InvalidTokenResponse,
    };
}

fn tokenCredential(gpa: std.mem.Allocator, io: Io, body: []const u8, old_refresh: ?[]const u8) !Credential {
    var parsed = try parseJson(gpa, body);
    defer parsed.deinit();
    const access_text = try string(parsed.value, "access_token");
    const refresh_token = if (switch (parsed.value) {
        .object => |o| o.get("refresh_token"),
        else => null,
    }) |v|
        switch (v) {
            .string => |s| s,
            else => return error.InvalidTokenResponse,
        }
    else if (old_refresh) |old| old else return error.InvalidTokenResponse;
    if (access_text.len == 0 or refresh_token.len == 0) return error.InvalidTokenResponse;
    const lifetime = try number(parsed.value, "expires_in", 3600);
    if (lifetime <= 0) return error.InvalidTokenResponse;
    const expires = std.math.add(i64, Io.Clock.real.now(io).toSeconds(), lifetime) catch return error.InvalidTokenResponse;
    const access = try gpa.dupe(u8, access_text);
    errdefer gpa.free(access);
    return .{
        .access = access,
        .refresh = try gpa.dupe(u8, refresh_token),
        // Readers already refresh one minute early. Subtracting a second
        // margin here made short-lived tokens expire as soon as they arrived.
        .expires = expires,
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
    try showLoginLink(output, url);
    try output.writeAll("The localhost page may fail to load. Copy its full URL from the address bar.\n");
    try output.flush();
    openBrowser(gpa, io, url);
    const submitted = (try input_mod.readSecretWithCopy(gpa, io, input, output, "Callback URL or code: ", url)) orelse return error.EndOfStream;
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

fn showLoginLink(output: *Io.Writer, url: []const u8) !void {
    try output.print("Open this URL to sign in:\n{s}\n", .{url});
    if (input_mod.interactive) try output.writeAll("Ctrl-Y copies the full sign-in link.\n");
}

const browser_guard =
    \\if [ -n "${SSH_CONNECTION+x}${SSH_CLIENT+x}${SSH_TTY+x}" ]; then exit 0; fi
    \\if [ "$1" = linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then exit 0; fi
    \\shift
    \\exec "$@"
;

/// Best-effort convenience for local sessions. Print and flush the link
/// before calling this so browser failures never hide the manual path.
fn openBrowser(gpa: std.mem.Allocator, io: Io, url: []const u8) void {
    const opener = if (@import("builtin").os.tag == .macos) "open" else "xdg-open";
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", browser_guard, "xaq-browser", @tagName(@import("builtin").os.tag), opener, url },
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
    try showLoginLink(output, url);
    try output.writeAll("Copy the authorization code from the callback page.\n");
    try output.flush();
    openBrowser(gpa, io, url);
    const submitted = (try input_mod.readSecretWithCopy(gpa, io, input, output, "Callback URL or code: ", url)) orelse return error.EndOfStream;
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

fn loginGrok(gpa: std.mem.Allocator, io: Io, input: *Io.Reader, output: *Io.Writer) !Credential {
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
    const device = try string(parsed.value, "device_code");
    const user = try string(parsed.value, "user_code");
    const uri = try deviceLoginUri(parsed.value);
    // Browser and copy-prompt time consume the device code's validity too.
    const expires = try deviceLoginDeadline(parsed.value, Io.Clock.boot.now(io));
    var interval = try number(parsed.value, "interval", 5);
    if (interval <= 0) return error.InvalidTokenResponse;
    try showLoginLink(output, uri);
    try output.print("Code: {s}\n", .{user});
    try output.flush();
    openBrowser(gpa, io, uri);
    if (input_mod.interactive) {
        const submitted = (try input_mod.readSecretWithCopy(gpa, io, input, output, "Press Enter to wait for approval: ", uri)) orelse return error.EndOfStream;
        gpa.free(submitted);
    }
    // The spinner is a no-op without styling (NO_COLOR, dumb terminals,
    // pipes); print a static line so the minutes-long poll is not silent.
    if (!term.enabled) try output.writeAll("waiting for approval...\n");
    try output.flush();
    spin.start(io, "waiting for approval");
    defer spin.stop();
    const poll_body = try transport.formEncode(gpa, &.{
        .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" }, .{ "client_id", xai_client }, .{ "device_code", device },
    });
    defer gpa.free(poll_body);
    while (true) {
        waitForLoginPoll(io, interval, expires) catch |err| {
            if (err != error.DeviceAuthorizationExpired) return err;
            spin.stop();
            try output.writeAll("Device login code expired; run xaq login grok again.\n");
            try output.flush();
            return error.ProviderRequestFailed;
        };
        try checkLoginCancellation();
        const poll = try transport.post(gpa, io, "https://auth.x.ai/oauth2/token", "application/x-www-form-urlencoded", &.{}, poll_body);
        defer gpa.free(poll.body);
        if (poll.status >= 200 and poll.status < 300) return tokenCredential(gpa, io, poll.body, null);
        if (try devicePollInterval(gpa, poll.body, interval)) |next| {
            interval = next;
            continue;
        }
        spin.stop();
        try requireStatus(gpa, poll, output, null);
    }
}

fn deviceLoginUri(response: std.json.Value) ![]const u8 {
    if (string(response, "verification_uri_complete") catch null) |complete| {
        if (validLoginUri(complete)) return complete;
    }
    const uri = try string(response, "verification_uri");
    if (!validLoginUri(uri)) return error.InvalidTokenResponse;
    return uri;
}

fn validLoginUri(value: []const u8) bool {
    for (value) |byte| if (byte <= ' ' or byte == 0x7f) return false;
    const uri = std.Uri.parse(value) catch return false;
    const host = uri.host orelse return false;
    return !host.isEmpty() and
        (std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "http"));
}

fn checkLoginCancellation() !void {
    if (cancel.requested()) return error.Cancelled;
}

fn deviceLoginDeadline(response: std.json.Value, now: Io.Timestamp) !Io.Timestamp {
    const seconds = try number(response, "expires_in", 0);
    if (seconds <= 0) return error.InvalidTokenResponse;
    return now.addDuration(.fromSeconds(seconds));
}

// RFC 8628 section 3.5: only these two errors permit another poll. Every
// slow_down adds five seconds for this and all subsequent requests.
fn devicePollInterval(gpa: std.mem.Allocator, body: []const u8, current: i64) !?i64 {
    var problem = parseJson(gpa, body) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer problem.deinit();
    const kind = string(problem.value, "error") catch return null;
    if (std.mem.eql(u8, kind, "authorization_pending")) return current;
    if (std.mem.eql(u8, kind, "slow_down")) return current +| 5;
    return null;
}

fn waitForLoginPoll(io: Io, seconds: i64, expires: Io.Timestamp) !void {
    const next_poll = Io.Clock.boot.now(io).addDuration(.fromSeconds(seconds));
    while (true) {
        try checkLoginCancellation();
        const now = Io.Clock.boot.now(io);
        const remaining = now.durationTo(expires).nanoseconds;
        if (remaining <= 0) return error.DeviceAuthorizationExpired;
        const delay = now.durationTo(next_poll).nanoseconds;
        if (delay <= 0) return;
        // Include suspended time in the expiry check, and do not sleep past
        // expiry when the provider's interval exceeds the code's lifetime.
        try io.sleep(.fromNanoseconds(@min(@min(delay, remaining), 50 * std.time.ns_per_ms)), .awake);
    }
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

test "device login prefers complete links and falls back without inventing a query" {
    const cases = [_]struct { response: []const u8, expected: []const u8 }{
        .{ .response = "{\"verification_uri\":\"https://auth.x.ai/activate\",\"verification_uri_complete\":\"https://auth.x.ai/activate?user_code=ABCD-EFGH\"}", .expected = "https://auth.x.ai/activate?user_code=ABCD-EFGH" },
        .{ .response = "{\"verification_uri\":\"https://auth.x.ai/activate\",\"user_code\":\"ABCD-EFGH\"}", .expected = "https://auth.x.ai/activate" },
        .{ .response = "{\"verification_uri\":\"https://auth.x.ai/activate\",\"verification_uri_complete\":null}", .expected = "https://auth.x.ai/activate" },
        .{ .response = "{\"verification_uri\":\"https://auth.x.ai/activate\",\"verification_uri_complete\":\"javascript:alert(1)\"}", .expected = "https://auth.x.ai/activate" },
        .{ .response = "{\"verification_uri\":\"https://auth.x.ai/activate\",\"verification_uri_complete\":\"https://\"}", .expected = "https://auth.x.ai/activate" },
        .{ .response = "{\"verification_uri\":\"https://auth.x.ai/activate\",\"verification_uri_complete\":\"https://auth.x.ai/activate\\n\"}", .expected = "https://auth.x.ai/activate" },
    };
    for (cases) |case| {
        var parsed = try parseJson(std.testing.allocator, case.response);
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case.expected, try deviceLoginUri(parsed.value));
    }
    var invalid = try parseJson(std.testing.allocator, "{\"verification_uri\":\"file:///tmp/activate\"}");
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidTokenResponse, deviceLoginUri(invalid.value));
}

test "browser auto opening requires a local graphical session" {
    const cases = [_]struct {
        platform: []const u8 = "linux",
        display: ?[]const u8 = null,
        wayland: ?[]const u8 = null,
        ssh: ?[]const u8 = null,
        opens: bool = false,
    }{
        .{},
        .{ .display = "", .wayland = "" },
        .{ .display = ":0", .opens = true },
        .{ .wayland = "wayland-0", .opens = true },
        .{ .display = ":0", .ssh = "SSH_CONNECTION" },
        .{ .display = ":0", .ssh = "SSH_CLIENT" },
        .{ .wayland = "wayland-0", .ssh = "SSH_TTY" },
        .{ .platform = "macos", .opens = true },
        .{ .platform = "macos", .ssh = "SSH_CONNECTION" },
    };
    for (cases) |case| {
        var environ: std.process.Environ.Map = .init(std.testing.allocator);
        defer environ.deinit();
        if (case.display) |value| try environ.put("DISPLAY", value);
        if (case.wayland) |value| try environ.put("WAYLAND_DISPLAY", value);
        if (case.ssh) |name| try environ.put(name, "");
        const result = try std.process.run(std.testing.allocator, std.testing.io, .{
            .argv = &.{ "/bin/sh", "-c", browser_guard, "browser-test", case.platform, "/bin/sh", "-c", "printf browser-started" },
            .environ_map = &environ,
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(64),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } },
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqualStrings(if (case.opens) "browser-started" else "", result.stdout);
    }
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
    try std.testing.expectError(error.Cancelled, waitForLoginPoll(threaded.io(), 5, Io.Clock.boot.now(threaded.io()).addDuration(.fromSeconds(60))));
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

test "token responses reject malformed lifetimes without leaking credentials" {
    const gpa = std.testing.allocator;
    const invalid = [_][]const u8{
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":1e300}",
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":9223372036854775807}",
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":-1}",
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":1.5}",
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":\"invalid\"}",
        "{\"access_token\":\"access\",\"refresh_token\":false}",
        "{\"access_token\":\"access\"}",
        "{\"access_token\":\"\",\"refresh_token\":\"refresh\"}",
    };
    for (invalid) |body| try std.testing.expectError(error.InvalidTokenResponse, tokenCredential(gpa, std.testing.io, body, null));
    const before = Io.Clock.real.now(std.testing.io).toSeconds();
    const short = try tokenCredential(gpa, std.testing.io, "{\"access_token\":\"access\",\"expires_in\":120}", "old-refresh");
    defer gpa.free(short.access);
    defer gpa.free(short.refresh);
    try std.testing.expectEqualStrings("old-refresh", short.refresh);
    try std.testing.expect(short.expires >= before + 120);
    try std.testing.expect(short.expires > Io.Clock.real.now(std.testing.io).toSeconds() + 60);
}

test "waiting for another sessions token refresh can be cancelled" {
    const Request = struct {
        fn run(io: Io) void {
            io.sleep(.fromMilliseconds(20), .awake) catch return;
            cancel.processToken().request();
        }
    };
    const gpa = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const home = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer gpa.free(home);
    cancel.reset();
    defer cancel.reset();
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    {
        var held = try authLock(gpa, io, home);
        defer held.close(io);
        var future = try io.concurrent(Request.run, .{io});
        defer future.await(io);
        const started = Io.Clock.now(.awake, io);
        try std.testing.expectError(error.Cancelled, authLock(gpa, io, home));
        try std.testing.expect(started.durationTo(Io.Clock.now(.awake, io)).nanoseconds < 2 * std.time.ns_per_s);
    }
    cancel.reset();
    var acquired = try authLock(gpa, io, home);
    acquired.close(io);
}

test "device login polling backs off only for retryable OAuth errors" {
    const gpa = std.testing.allocator;
    var interval: i64 = 5;
    interval = (try devicePollInterval(gpa, "{\"error\":\"slow_down\"}", interval)).?;
    try std.testing.expectEqual(@as(i64, 10), interval);
    interval = (try devicePollInterval(gpa, "{\"error\":\"authorization_pending\"}", interval)).?;
    try std.testing.expectEqual(@as(i64, 10), interval);
    interval = (try devicePollInterval(gpa, "{\"error\":\"slow_down\"}", interval)).?;
    try std.testing.expectEqual(@as(i64, 15), interval);
    try std.testing.expectEqual(@as(?i64, 65), try devicePollInterval(gpa, "{\"error\":\"slow_down\"}", 60));
    for ([_][]const u8{ "<html>gateway failed</html>", "{}", "{\"error\":false}", "{\"error\":\"access_denied\"}", "{\"error\":\"expired_token\"}", "{\"error\":\"invalid_client\"}" }) |body| {
        try std.testing.expectEqual(null, try devicePollInterval(gpa, body, interval));
    }
}

test "device login expires during polling waits and honors intervals above one minute" {
    const Clock = struct {
        now_ns: i96 = 0,
        fn now(raw: ?*anyopaque, _: Io.Clock) Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = self.now_ns };
        }
        fn sleep(raw: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.now_ns += timeout.duration.raw.nanoseconds;
        }
    };
    cancel.reset();
    defer cancel.reset();
    var clock: Clock = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    vtable.sleep = Clock.sleep;
    const io: Io = .{ .userdata = &clock, .vtable = &vtable };
    var parsed = try parseJson(std.testing.allocator, "{\"expires_in\":90}");
    defer parsed.deinit();
    const deadline = try deviceLoginDeadline(parsed.value, Io.Clock.boot.now(io));
    try std.testing.expectEqual(@as(i64, 5), try number(parsed.value, "interval", 5));
    try waitForLoginPoll(io, 65, deadline);
    try std.testing.expectEqual(@as(i96, 65 * std.time.ns_per_s), clock.now_ns);
    try std.testing.expectError(error.DeviceAuthorizationExpired, waitForLoginPoll(io, 65, deadline));
    try std.testing.expectEqual(@as(i96, 90 * std.time.ns_per_s), clock.now_ns);
    // Already-expired codes issue no new sleep or poll, including after suspend.
    clock.now_ns = 200 * std.time.ns_per_s;
    try std.testing.expectError(error.DeviceAuthorizationExpired, waitForLoginPoll(io, 5, deadline));
    try std.testing.expectEqual(@as(i96, 200 * std.time.ns_per_s), clock.now_ns);
    for ([_][]const u8{ "{}", "{\"expires_in\":0}", "{\"expires_in\":-1}" }) |body| {
        var invalid = try parseJson(std.testing.allocator, body);
        defer invalid.deinit();
        try std.testing.expectError(error.InvalidTokenResponse, deviceLoginDeadline(invalid.value, .{ .nanoseconds = 0 }));
    }
}
