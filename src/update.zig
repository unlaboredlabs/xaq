const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const release_base = "https://github.com/unlaboredlabs/xaq/releases/download/edge";
const max_binary_bytes = 16 * 1024 * 1024;
const max_checksums_bytes = 64 * 1024;

pub fn run(gpa: std.mem.Allocator, io: Io) !void {
    const asset = platformAsset() orelse return error.UnsupportedPlatform;
    const checksum_url = try std.fmt.allocPrint(gpa, "{s}/SHA256SUMS", .{release_base});
    defer gpa.free(checksum_url);
    const asset_url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ release_base, asset });
    defer gpa.free(asset_url);

    const checksums = try download(gpa, io, checksum_url, max_checksums_bytes);
    defer gpa.free(checksums);
    const expected = try checksumFor(checksums, asset);

    const binary = try download(gpa, io, asset_url, max_binary_bytes);
    defer gpa.free(binary);
    const actual = sha256(binary);
    if (!std.mem.eql(u8, &expected, &actual)) return error.ChecksumMismatch;

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

fn checksumFor(contents: []const u8, asset: []const u8) ![64]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 66) continue;
        const digest = line[0..64];
        if (!allHex(digest)) continue;
        var name = std.mem.trimStart(u8, line[64..], " \t");
        if (name.len > 0 and name[0] == '*') name = name[1..];
        if (!std.mem.eql(u8, name, asset)) continue;
        var result: [64]u8 = undefined;
        for (digest, 0..) |byte, i| result[i] = std.ascii.toLower(byte);
        return result;
    }
    return error.MissingChecksum;
}

fn allHex(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn sha256(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "checksum lookup matches the exact release asset" {
    const sums =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  xaq-linux-x86_64.tar.gz\n" ++
        "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789 *xaq-linux-x86_64\r\n";
    const found = try checksumFor(sums, "xaq-linux-x86_64");
    try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", &found);
}

test "checksum lookup rejects missing and malformed entries" {
    const malformed = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz  xaq-linux-x86_64\n";
    try std.testing.expectError(error.MissingChecksum, checksumFor(malformed, "xaq-linux-x86_64"));
    try std.testing.expectError(error.MissingChecksum, checksumFor("", "xaq-linux-x86_64"));
}
