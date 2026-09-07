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
    release_sha: []const u8,
    version: ?[]const u8,
};

pub const Status = enum { updated, already_current };

pub const RunResult = struct {
    status: Status,
    version: ?[]u8,

    pub fn deinit(self: *RunResult, gpa: std.mem.Allocator) void {
        if (self.version) |version| gpa.free(version);
        self.* = undefined;
    }
};

pub fn run(gpa: std.mem.Allocator, io: Io, current_git_sha: []const u8) !RunResult {
    const asset = platformAsset() orelse return error.UnsupportedPlatform;
    const manifest = try download(gpa, io, manifest_url, max_manifest_bytes);
    defer gpa.free(manifest);
    const selected = try assetFromManifest(manifest, asset);
    const release_version = if (selected.version) |version| try gpa.dupe(u8, version) else null;
    errdefer if (release_version) |version| gpa.free(version);
    if (std.mem.eql(u8, current_git_sha, selected.release_sha)) {
        return .{
            .status = .already_current,
            .version = release_version,
        };
    }
    const asset_url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ release_base, selected.filename });
    defer gpa.free(asset_url);

    // Capture the destination before downloading the binary. Resolving it after
    // another installer replaces this process's executable returns a path
    // ending in " (deleted)", which must never become an install target.
    const executable = std.process.executablePathAlloc(io, gpa) catch |err| switch (err) {
        error.FileNotFound, error.ProcessNotFound => return error.ExecutableChanged,
        else => return err,
    };
    defer gpa.free(executable);
    const original = try executableStat(io, executable);
    const binary = try download(gpa, io, asset_url, max_binary_bytes);
    defer gpa.free(binary);
    const actual = sha256(binary);
    if (!std.mem.eql(u8, &selected.checksum, &actual)) return error.ChecksumMismatch;

    try installBinary(gpa, io, executable, original, binary);
    return .{
        .status = .updated,
        .version = release_version,
    };
}

fn installBinary(gpa: std.mem.Allocator, io: Io, executable: []const u8, original: Io.File.Stat, binary: []const u8) !void {
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(gpa, "{s}.update-{s}", .{ executable, &suffix });
    defer gpa.free(temporary);
    var file = try Io.Dir.cwd().createFile(io, temporary, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o755),
    });
    // A failed exclusive create does not give us ownership of this path.
    errdefer Io.Dir.deleteFileAbsolute(io, temporary) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, binary);
    try file.setPermissions(io, @enumFromInt(0o755));
    try file.sync(io);
    const latest = try executableStat(io, executable);
    if (original.inode != latest.inode or original.size != latest.size or
        original.mtime.nanoseconds != latest.mtime.nanoseconds or original.ctime.nanoseconds != latest.ctime.nanoseconds)
    {
        return error.ExecutableChanged;
    }
    try Io.Dir.renameAbsolute(temporary, executable, io);
}

fn executableStat(io: Io, path: []const u8) !Io.File.Stat {
    return Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => error.ExecutableChanged,
        else => return err,
    };
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

    var selected: ?struct { filename: []const u8, checksum: [64]u8 } = null;
    var release_version: ?[]const u8 = null;
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
        if (std.mem.eql(u8, logical, "version")) {
            // The metadata uses the same three-field shape that old v1 clients
            // already validate and ignore for unselected assets.
            if (release_version != null or !validEdgeVersion(filename)) return error.MalformedManifest;
            const version_digest = sha256(filename);
            if (!std.mem.eql(u8, digest, &version_digest)) return error.MalformedManifest;
            release_version = filename;
            continue;
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
    const found = selected orelse return error.MissingAsset;
    return .{
        .filename = found.filename,
        .checksum = found.checksum,
        .release_sha = release_sha,
        .version = release_version,
    };
}

fn validEdgeVersion(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    const marker = "-edge.";
    const marker_index = std.mem.indexOf(u8, value, marker) orelse return false;
    const base = value[0..marker_index];
    const sequence = value[marker_index + marker.len ..];
    if (!validDecimal(sequence, false)) return false;

    var parts = std.mem.splitScalar(u8, base, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (!validDecimal(part, true)) return false;
        count += 1;
    }
    return count == 3;
}

fn validDecimal(value: []const u8, zero_allowed: bool) bool {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return zero_allowed or !std.mem.eql(u8, value, "0");
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

test "update staging retains other writers and rolls back partial writes and rename failures" {
    const Fault = struct {
        fn random(_: ?*anyopaque, bytes: []u8) Io.RandomSecureError!void {
            @memset(bytes, 0);
        }
        fn partial(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
            if (operation == .file_write_streaming) {
                var write = operation.file_write_streaming;
                const bytes = write.data[0];
                if (bytes[0] != 'n') return .{ .file_write_streaming = error.NoSpaceLeft };
                write.data = &.{bytes[0..3]};
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
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(std.testing.io, &directory_buffer);
    const path = try std.fs.path.join(gpa, &.{ directory_buffer[0..directory_len], "xaq" });
    defer gpa.free(path);
    const temp_path = try std.fmt.allocPrint(gpa, "{s}.update-0000000000000000", .{path});
    defer gpa.free(temp_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "original executable" });
    const original = try executableStat(std.testing.io, path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = temp_path, .data = "another writer" });
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = Fault.random;
    const io: Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.PathAlreadyExists, installBinary(gpa, io, path, original, "new executable"));
    const other = try Io.Dir.cwd().readFileAlloc(std.testing.io, temp_path, gpa, .limited(1024));
    defer gpa.free(other);
    try std.testing.expectEqualStrings("another writer", other);
    try Io.Dir.cwd().deleteFile(std.testing.io, temp_path);

    vtable.operate = Fault.partial;
    try std.testing.expectError(error.NoSpaceLeft, installBinary(gpa, io, path, original, "new executable"));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(std.testing.io, temp_path, .{}));
    vtable.operate = std.testing.io.vtable.operate;
    vtable.dirRename = Fault.rename;
    try std.testing.expectError(error.AccessDenied, installBinary(gpa, io, path, original, "new executable"));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(std.testing.io, temp_path, .{}));
    const retained = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1024));
    defer gpa.free(retained);
    try std.testing.expectEqualStrings("original executable", retained);
}

test "manifest selects an immutable asset and checksum" {
    const manifest =
        "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567 abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n" ++
        "xaq-linux-x86_64.tar.gz xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567.tar.gz aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n";
    const found = try assetFromManifest(manifest, "xaq-linux-x86_64");
    try std.testing.expectEqualStrings("xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567", found.filename);
    try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", &found.checksum);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", found.release_sha);
    try std.testing.expect(found.version == null);
}

test "manifest exposes numbered edge version" {
    const manifest =
        "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n" ++
        "version 0.1.0-edge.7 0e038f9b84ca5c860b8dd62dd9f4831e46c395d46e401fd16c2ea69e2215d9c4\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567 abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n";
    const found = try assetFromManifest(manifest, "xaq-linux-x86_64");
    try std.testing.expectEqualStrings("0.1.0-edge.7", found.version.?);
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

    const malformed_version =
        "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n" ++
        "version 0.1.0-edge.0 0e038f9b84ca5c860b8dd62dd9f4831e46c395d46e401fd16c2ea69e2215d9c4\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567 abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n";
    try std.testing.expectError(error.MalformedManifest, assetFromManifest(malformed_version, "xaq-linux-x86_64"));

    const bad_version_digest =
        "xaq-edge-v1 0123456789abcdef0123456789abcdef01234567\n" ++
        "version 0.1.0-edge.7 0000000000000000000000000000000000000000000000000000000000000000\n" ++
        "xaq-linux-x86_64 xaq-linux-x86_64-0123456789abcdef0123456789abcdef01234567 abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n";
    try std.testing.expectError(error.MalformedManifest, assetFromManifest(bad_version_digest, "xaq-linux-x86_64"));
}

test "edge version validation follows release numbering" {
    try std.testing.expect(validEdgeVersion("0.1.0-edge.1"));
    try std.testing.expect(validEdgeVersion("12.34.56-edge.789"));
    try std.testing.expect(!validEdgeVersion("0.1.0"));
    try std.testing.expect(!validEdgeVersion("0.1.0-edge.0"));
    try std.testing.expect(!validEdgeVersion("01.1.0-edge.1"));
}
