const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const manifest_url = "https://raw.githubusercontent.com/unlaboredlabs/xaq/edge-channel/manifest";
const release_base = "https://github.com/unlaboredlabs/xaq/releases/download/edge";
const max_binary_bytes = 16 * 1024 * 1024;
const max_manifest_bytes = 64 * 1024;

const ManifestAsset = struct {
    filename: []const u8,
    checksum: [64]u8,
};

pub fn run(gpa: std.mem.Allocator, io: Io) !void {
    const asset = platformAsset() orelse return error.UnsupportedPlatform;
    const manifest = try download(gpa, io, manifest_url, max_manifest_bytes);
    defer gpa.free(manifest);
    const selected = try assetFromManifest(manifest, asset);
    const asset_url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ release_base, selected.filename });
    defer gpa.free(asset_url);

    const binary = try download(gpa, io, asset_url, max_binary_bytes);
    defer gpa.free(binary);
    const actual = sha256(binary);
    if (!std.mem.eql(u8, &selected.checksum, &actual)) return error.ChecksumMismatch;

    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(gpa, "{s}.update-{s}", .{ executable, &suffix });
    defer gpa.free(temporary);
    errdefer Io.Dir.deleteFileAbsolute(io, temporary) catch {};

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = temporary,
        .data = binary,
        .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o755) },
    });
    var file = try Io.Dir.cwd().openFile(io, temporary, .{ .mode = .read_write });
    defer file.close(io);
    try file.setPermissions(io, @enumFromInt(0o755));
    try file.sync(io);
    try Io.Dir.renameAbsolute(temporary, executable, io);
}

fn platformAsset() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "xaq-linux-x86_64",
            .aarch64 => "xaq-linux-aarch64",
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "xaq-macos-x86_64",
            .aarch64 => "xaq-macos-aarch64",
            else => null,
        },
        else => null,
    };
}

fn download(gpa: std.mem.Allocator, io: Io, url: []const u8, limit: usize) ![]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{
            "curl",              "--fail", "--location", "--silent", "--show-error",
            "--connect-timeout", "10",     "--max-time", "300",      url,
        },
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(310), .clock = .awake } },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.CurlNotFound,
        error.StreamTooLong => return error.ReleaseTooLarge,
        else => return err,
    };
    defer gpa.free(result.stderr);
    if (!exitedZero(result.term)) {
        gpa.free(result.stdout);
        return error.DownloadFailed;
    }
    return result.stdout;
}

fn exitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn assetFromManifest(contents: []const u8, asset: []const u8) !ManifestAsset {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    const header = lines.next() orelse return error.MalformedManifest;
    var header_fields = std.mem.tokenizeAny(u8, header, " \t\r");
    if (!std.mem.eql(u8, header_fields.next() orelse return error.MalformedManifest, "xaq-edge-v1")) {
        return error.MalformedManifest;
    }
    const release_sha = header_fields.next() orelse return error.MalformedManifest;
    if (release_sha.len != 40 or !allLowerHex(release_sha) or header_fields.next() != null) {
        return error.MalformedManifest;
    }

    var selected: ?ManifestAsset = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const logical = fields.next() orelse return error.MalformedManifest;
        const filename = fields.next() orelse return error.MalformedManifest;
        const digest = fields.next() orelse return error.MalformedManifest;
        if (fields.next() != null or digest.len != 64 or !allLowerHex(digest)) {
            return error.MalformedManifest;
        }
        if (!std.mem.eql(u8, logical, asset)) continue;
        if (selected != null or filename.len != asset.len + 1 + release_sha.len or
            !std.mem.startsWith(u8, filename, asset) or filename[asset.len] != '-' or
            !std.mem.eql(u8, filename[asset.len + 1 ..], release_sha))
        {
            return error.MalformedManifest;
        }
        var checksum: [64]u8 = undefined;
        @memcpy(&checksum, digest);
        selected = .{ .filename = filename, .checksum = checksum };
    }
    return selected orelse error.MissingAsset;
}

fn allLowerHex(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn sha256(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "manifest selects an immutable asset and checksum" {
    const manifest =
        "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567 abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n" ++
        "xaq-linux-x86_64.tar.gz xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567.tar.gz aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n";
    const found = try assetFromManifest(manifest, "xaq-linux-x86_64");
    try std.testing.expectEqualStrings("xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567", found.filename);
    try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", &found.checksum);
}

test "manifest rejects mixed generations and duplicate assets" {
    const mixed =
        "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-89abcdef0123456789abcdef0123456789abcdef aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n";
    try std.testing.expectError(error.MalformedManifest, assetFromManifest(mixed, "xaq-linux-x86_64"));

    const duplicate =
        "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n";
    try std.testing.expectError(error.MalformedManifest, assetFromManifest(duplicate, "xaq-linux-x86_64"));
}

test "manifest rejects malformed and missing asset entries" {
    const malformed_header = "xaq-edge-v1 not-a-commit\n";
    try std.testing.expectError(error.MalformedManifest, assetFromManifest(malformed_header, "xaq-linux-x86_64"));

    const malformed_checksum =
        "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567 zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n";
    try std.testing.expectError(error.MalformedManifest, assetFromManifest(malformed_checksum, "xaq-linux-x86_64"));

    const missing = "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n";
    try std.testing.expectError(error.MissingAsset, assetFromManifest(missing, "xaq-linux-x86_64"));
}
