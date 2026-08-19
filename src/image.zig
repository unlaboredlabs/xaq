const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const auth = @import("auth.zig");
const types = @import("types.zig");

pub const max_image_bytes = 5 * 1024 * 1024;
pub const max_images_per_prompt = 4;

pub const Input = struct {
    gpa: std.mem.Allocator,
    text: []u8,
    images: []types.Image,

    pub fn deinit(self: *Input) void {
        for (self.images) |image| {
            self.gpa.free(image.name);
            self.gpa.free(image.data);
        }
        self.gpa.free(self.images);
        self.gpa.free(self.text);
        self.* = undefined;
    }
};

pub const Display = struct {
    gpa: std.mem.Allocator,
    text: []const u8,
    cursor: usize,
    owned: ?[]u8 = null,

    pub fn deinit(self: *Display) void {
        if (self.owned) |owned| self.gpa.free(owned);
        self.* = undefined;
    }
};

/// Load explicit paths such as repeated `--image` arguments.
pub fn loadPaths(gpa: std.mem.Allocator, io: Io, cwd: []const u8, paths: []const []const u8) ![]types.Image {
    if (paths.len > max_images_per_prompt) return error.TooManyImages;
    const images = try gpa.alloc(types.Image, paths.len);
    errdefer gpa.free(images);
    var loaded: usize = 0;
    errdefer for (images[0..loaded]) |image| {
        gpa.free(image.name);
        gpa.free(image.data);
    };
    for (paths, 0..) |path, index| {
        images[index] = try load(gpa, io, cwd, path);
        loaded += 1;
    }
    return images;
}

pub fn freeImages(gpa: std.mem.Allocator, images: []types.Image) void {
    for (images) |image| {
        gpa.free(image.name);
        gpa.free(image.data);
    }
    gpa.free(images);
}

pub fn validateProvider(provider: auth.Provider, images: []const types.Image) !void {
    if (provider != .grok) return;
    for (images) |image| {
        if (!std.mem.eql(u8, image.media_type, "image/png") and !std.mem.eql(u8, image.media_type, "image/jpeg")) {
            return error.UnsupportedImageForProvider;
        }
    }
}

/// Copy a desktop clipboard image to a private temporary file. Terminals do
/// not transmit bitmap data in bracketed paste, so Ctrl-V uses the native
/// clipboard helpers commonly available on Linux and macOS.
pub fn clipboardToTemp(gpa: std.mem.Allocator, io: Io) ![]u8 {
    const commands = switch (builtin.os.tag) {
        .linux => &[_][]const []const u8{
            &.{ "wl-paste", "--type", "image/png" },
            &.{ "wl-paste", "--type", "image/jpeg" },
            &.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" },
            &.{ "xclip", "-selection", "clipboard", "-t", "image/jpeg", "-o" },
        },
        .macos => &[_][]const []const u8{
            &.{ "pngpaste", "-" },
            &.{ "pbpaste", "-Prefer", "png" },
        },
        else => return error.ClipboardUnavailable,
    };
    var bytes: ?[]u8 = null;
    for (commands) |argv| {
        bytes = try readClipboardCommand(gpa, io, argv);
        if (bytes != null) break;
    }
    if (bytes == null and builtin.os.tag == .macos) bytes = try readMacClipboard(gpa, io);
    const contents = bytes orelse return error.ClipboardUnavailable;
    defer gpa.free(contents);
    const media_type = detectMediaType(contents) orelse return error.ClipboardUnavailable;
    const extension: []const u8 = if (std.mem.eql(u8, media_type, "image/jpeg")) "jpg" else "png";
    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const path = try std.fmt.allocPrint(gpa, "/tmp/xaq-clipboard-{s}.{s}", .{ &hex, extension });
    errdefer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .exclusive = true, .permissions = @enumFromInt(0o600) },
    });
    return path;
}

fn readMacClipboard(gpa: std.mem.Allocator, io: Io) !?[]u8 {
    const script =
        \\ObjC.import('AppKit');
        \\var image = $.NSImage.alloc.initWithPasteboard($.NSPasteboard.generalPasteboard);
        \\if (!image) throw new Error('no image');
        \\var rep = $.NSBitmapImageRep.imageRepWithData(image.TIFFRepresentation);
        \\var data = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary);
        \\ObjC.unwrap(data.base64EncodedStringWithOptions(0));
    ;
    const max_encoded_bytes = std.base64.standard.Encoder.calcSize(max_image_bytes) + 1024;
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "osascript", "-l", "JavaScript", "-e", script },
        .stdout_limit = .limited(max_encoded_bytes),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.StreamTooLong => return error.ImageTooLarge,
        else => return null,
    };
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    if (!exitedZero(result.term)) return null;
    const encoded = std.mem.trim(u8, result.stdout, " \t\r\n");
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
    if (decoded_len > max_image_bytes) return error.ImageTooLarge;
    const decoded = try gpa.alloc(u8, decoded_len);
    errdefer gpa.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch {
        gpa.free(decoded);
        return null;
    };
    if (detectMediaType(decoded) == null) {
        gpa.free(decoded);
        return null;
    }
    return decoded;
}

pub fn discardClipboardTemp(io: Io, path: []const u8) void {
    if (!isClipboardTemp(path)) return;
    Io.Dir.deleteFileAbsolute(io, path) catch {};
}

fn readClipboardCommand(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) !?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_image_bytes + 1),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.StreamTooLong => return error.ImageTooLarge,
        else => return null,
    };
    defer gpa.free(result.stderr);
    if (!exitedZero(result.term) or result.stdout.len == 0 or result.stdout.len > max_image_bytes or detectMediaType(result.stdout) == null) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn exitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn isClipboardTemp(path: []const u8) bool {
    const prefix = "/tmp/xaq-clipboard-";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const suffix = path[prefix.len..];
    const dot = std.mem.lastIndexOfScalar(u8, suffix, '.') orelse return false;
    if (dot != 24 or (!std.mem.eql(u8, suffix[dot..], ".png") and !std.mem.eql(u8, suffix[dot..], ".jpg"))) return false;
    for (suffix[0..dot]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

/// Attach existing image paths mentioned in a prompt. `@path` is explicit;
/// bare paths are accepted so terminal file drops work without special UI.
/// Existing images carried from a failed or cancelled request stay attached.
pub fn fromPrompt(gpa: std.mem.Allocator, io: Io, cwd: []const u8, input_text: []u8, carried: []const types.Image) !Input {
    return parsePrompt(gpa, io, cwd, input_text, carried, true);
}

/// Parse image paths for editor previews without consuming clipboard-owned
/// temporary files. A submitted prompt uses `fromPrompt`, which owns and
/// removes those files even when loading one fails.
pub fn inspectPrompt(gpa: std.mem.Allocator, io: Io, cwd: []const u8, input_text: []u8) !Input {
    return parsePrompt(gpa, io, cwd, input_text, &.{}, false);
}

fn parsePrompt(gpa: std.mem.Allocator, io: Io, cwd: []const u8, input_text: []u8, carried: []const types.Image, consume_clipboard_temps: bool) !Input {
    var text = input_text;
    var images: std.ArrayList(types.Image) = .empty;
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(gpa);
    errdefer {
        for (images.items) |image| {
            gpa.free(image.name);
            gpa.free(image.data);
        }
        images.deinit(gpa);
        gpa.free(text);
    }
    for (carried) |image| try appendClone(gpa, &images, image);

    var words = WordIterator{ .text = text };
    while (try words.next(gpa)) |word| {
        defer if (word.owned) |owned| gpa.free(owned);
        if (!looksLikeImagePath(word.path)) continue;
        defer if (consume_clipboard_temps) discardClipboardTemp(io, word.path);
        if (imageIndex(images.items, word.path)) |index| {
            try replacements.append(gpa, .{ .start = word.start, .end = word.end, .image_index = index });
            continue;
        }
        if (images.items.len == max_images_per_prompt) {
            if (word.explicit) return error.TooManyImages;
            continue;
        }
        const candidate = load(gpa, io, cwd, word.path) catch |err| switch (err) {
            error.FileNotFound => if (word.explicit) return err else continue,
            else => return err,
        };
        images.append(gpa, candidate) catch |err| {
            gpa.free(candidate.name);
            gpa.free(candidate.data);
            return err;
        };
        try replacements.append(gpa, .{ .start = word.start, .end = word.end, .image_index = images.items.len - 1 });
    }
    if (replacements.items.len > 0) {
        const displayed = try replaceWithPlaceholders(gpa, text, replacements.items, null);
        gpa.free(text);
        text = displayed.owned.?;
    }
    return .{ .gpa = gpa, .text = text, .images = try images.toOwnedSlice(gpa) };
}

/// Render paths already recognized as pasted images as numbered markers.
/// The raw token remains visible while its cursor is inside it, so editing a
/// pasted path does not leave the cursor moving through hidden bytes.
pub fn displayPlaceholders(gpa: std.mem.Allocator, text: []const u8, cursor: usize, paths: []const []const u8) !Display {
    if (paths.len == 0) return .{ .gpa = gpa, .text = text, .cursor = cursor };
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(gpa);
    var assigned: [max_images_per_prompt]?usize = @splat(null);
    var next_image_index = highestPlaceholderNumber(text);
    var words = WordIterator{ .text = text };
    while (try words.next(gpa)) |word| {
        defer if (word.owned) |owned| gpa.free(owned);
        const path_index = pathIndex(paths, word.path) orelse continue;
        const index = assigned[path_index] orelse assign: {
            assigned[path_index] = next_image_index;
            next_image_index += 1;
            break :assign assigned[path_index].?;
        };
        if (cursor > word.start and cursor < word.end) continue;
        try replacements.append(gpa, .{ .start = word.start, .end = word.end, .image_index = index });
    }
    if (replacements.items.len == 0) return .{ .gpa = gpa, .text = text, .cursor = cursor };
    return replaceWithPlaceholders(gpa, text, replacements.items, cursor);
}

fn highestPlaceholderNumber(text: []const u8) usize {
    const prefix = "[Image #";
    var highest: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, text, offset, prefix)) |start| {
        const digits_start = start + prefix.len;
        const end = std.mem.indexOfScalarPos(u8, text, digits_start, ']') orelse break;
        const number = std.fmt.parseUnsigned(usize, text[digits_start..end], 10) catch 0;
        highest = @max(highest, number);
        offset = end + 1;
    }
    return highest;
}

fn appendClone(gpa: std.mem.Allocator, images: *std.ArrayList(types.Image), image: types.Image) !void {
    if (images.items.len == max_images_per_prompt) return error.TooManyImages;
    const name = try gpa.dupe(u8, image.name);
    errdefer gpa.free(name);
    const data = try gpa.dupe(u8, image.data);
    errdefer gpa.free(data);
    try images.append(gpa, .{ .name = name, .media_type = image.media_type, .data = data });
}

fn load(gpa: std.mem.Allocator, io: Io, cwd: []const u8, requested: []const u8) !types.Image {
    const resolved = if (std.fs.path.isAbsolute(requested))
        try gpa.dupe(u8, requested)
    else
        try std.fs.path.join(gpa, &.{ cwd, requested });
    defer gpa.free(resolved);
    const bytes = Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(max_image_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.ImageTooLarge,
        else => return err,
    };
    defer gpa.free(bytes);
    if (bytes.len > max_image_bytes) return error.ImageTooLarge;
    if (bytes.len == 0) return error.EmptyImage;
    const media_type = detectMediaType(bytes) orelse return error.UnsupportedImage;
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const data = try gpa.alloc(u8, encoded_len);
    errdefer gpa.free(data);
    _ = std.base64.standard.Encoder.encode(data, bytes);
    return .{
        .name = try gpa.dupe(u8, requested),
        .media_type = media_type,
        .data = data,
    };
}

fn detectMediaType(bytes: []const u8) ?[]const u8 {
    if (startsWith(bytes, &.{ 0xff, 0xd8, 0xff })) return "image/jpeg";
    if (startsWith(bytes, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a })) return "image/png";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return bytes.len >= prefix.len and std.mem.eql(u8, bytes[0..prefix.len], prefix);
}

fn looksLikeImagePath(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".png") or
        std.ascii.eqlIgnoreCase(extension, ".jpg") or
        std.ascii.eqlIgnoreCase(extension, ".jpeg") or
        std.ascii.eqlIgnoreCase(extension, ".gif") or
        std.ascii.eqlIgnoreCase(extension, ".webp");
}

fn imageIndex(images: []const types.Image, path: []const u8) ?usize {
    for (images, 0..) |image, index| if (std.mem.eql(u8, image.name, path)) return index;
    return null;
}

fn pathIndex(paths: []const []const u8, path: []const u8) ?usize {
    for (paths, 0..) |candidate, index| if (std.mem.eql(u8, candidate, path)) return index;
    return null;
}

const Word = struct {
    path: []const u8,
    explicit: bool,
    start: usize,
    end: usize,
    owned: ?[]u8 = null,
};

const WordIterator = struct {
    text: []const u8,
    offset: usize = 0,

    fn next(self: *WordIterator, gpa: std.mem.Allocator) !?Word {
        while (self.offset < self.text.len and std.ascii.isWhitespace(self.text[self.offset])) self.offset += 1;
        if (self.offset == self.text.len) return null;
        const start = self.offset;
        var quote: ?u8 = null;
        if (self.text[self.offset] == '@') self.offset += 1;
        if (self.offset < self.text.len and (self.text[self.offset] == '\'' or self.text[self.offset] == '"')) {
            quote = self.text[self.offset];
            self.offset += 1;
        }
        var escaped = false;
        while (self.offset < self.text.len) : (self.offset += 1) {
            const byte = self.text[self.offset];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                continue;
            }
            if (quote) |delimiter| {
                if (byte == delimiter) {
                    self.offset += 1;
                    break;
                }
            } else if (std.ascii.isWhitespace(byte)) break;
        }
        const explicit = self.text[start] == '@';
        var raw = self.text[start + @intFromBool(explicit) .. self.offset];
        if (quote != null and raw.len >= 2 and raw[0] == quote.? and raw[raw.len - 1] == quote.?) raw = raw[1 .. raw.len - 1];
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return .{ .path = raw, .explicit = explicit, .start = start, .end = self.offset };
        const owned = try unescape(gpa, raw);
        return .{ .path = owned, .explicit = explicit, .start = start, .end = self.offset, .owned = owned };
    }
};

const Replacement = struct {
    start: usize,
    end: usize,
    image_index: usize,
};

fn replaceWithPlaceholders(gpa: std.mem.Allocator, text: []const u8, replacements: []const Replacement, cursor: ?usize) !Display {
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var previous: usize = 0;
    var mapped_cursor = cursor orelse text.len;
    for (replacements) |replacement| {
        try output.writer.writeAll(text[previous..replacement.start]);
        const before = output.written().len;
        try output.writer.print("[Image #{d}]", .{replacement.image_index + 1});
        const placeholder_len = output.written().len - before;
        if (cursor) |position| {
            if (position >= replacement.end) {
                mapped_cursor = mapped_cursor - (replacement.end - replacement.start) + placeholder_len;
            }
        }
        previous = replacement.end;
    }
    try output.writer.writeAll(text[previous..]);
    const owned = try output.toOwnedSlice();
    return .{ .gpa = gpa, .text = owned, .cursor = mapped_cursor, .owned = owned };
}

fn unescape(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    const output = try gpa.alloc(u8, value.len);
    var write: usize = 0;
    var read: usize = 0;
    while (read < value.len) : (read += 1) {
        if (value[read] == '\\' and read + 1 < value.len) read += 1;
        output[write] = value[read];
        write += 1;
    }
    return gpa.realloc(output, write);
}

test "detects supported image signatures" {
    try std.testing.expectEqualStrings("image/jpeg", detectMediaType(&.{ 0xff, 0xd8, 0xff, 0xe0 }).?);
    try std.testing.expectEqualStrings("image/png", detectMediaType(&.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }).?);
    try std.testing.expectEqualStrings("image/gif", detectMediaType("GIF89a...").?);
    try std.testing.expectEqualStrings("image/webp", detectMediaType("RIFFxxxxWEBP").?);
    try std.testing.expect(detectMediaType("not an image") == null);
}

test "Grok accepts only its documented image formats" {
    try validateProvider(.grok, &.{.{ .name = "shot.png", .media_type = "image/png", .data = "" }});
    try std.testing.expectError(error.UnsupportedImageForProvider, validateProvider(.grok, &.{.{ .name = "shot.webp", .media_type = "image/webp", .data = "" }}));
    try validateProvider(.chatgpt, &.{.{ .name = "shot.webp", .media_type = "image/webp", .data = "" }});
}

test "clipboard command accepts image bytes and temp names are strict" {
    const bytes = (try readClipboardCommand(std.testing.allocator, std.testing.io, &.{ "/bin/sh", "-c", "printf '\\211PNG\\r\\n\\032\\n'" })).?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("image/png", detectMediaType(bytes).?);
    try std.testing.expect(isClipboardTemp("/tmp/xaq-clipboard-0123456789abcdef01234567.png"));
    try std.testing.expect(!isClipboardTemp("/tmp/xaq-clipboard-not-owned.png"));
    try std.testing.expect(!isClipboardTemp("/tmp/xaq-clipboard-0123456789abcdef01234567.png/extra"));
}

test "prompt words support at-prefix, quotes, and dropped escaped paths" {
    var words = WordIterator{ .text = "inspect @one.png @\"two words.jpg\" /tmp/three\\ four.webp" };
    try std.testing.expectEqualStrings("inspect", (try words.next(std.testing.allocator)).?.path);
    try std.testing.expectEqualStrings("one.png", (try words.next(std.testing.allocator)).?.path);
    try std.testing.expectEqualStrings("two words.jpg", (try words.next(std.testing.allocator)).?.path);
    const last = (try words.next(std.testing.allocator)).?;
    defer if (last.owned) |owned| std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("/tmp/three four.webp", last.path);
}

test "pasted image paths render as placeholders outside the active token" {
    const text = "compare @\"before shot.png\" with after.jpg";
    var display = try displayPlaceholders(std.testing.allocator, text, text.len, &.{ "before shot.png", "after.jpg" });
    defer display.deinit();
    try std.testing.expectEqualStrings("compare [Image #1] with [Image #2]", display.text);
    try std.testing.expectEqual(display.text.len, display.cursor);

    const inside = std.mem.indexOf(u8, text, "shot").?;
    var editing = try displayPlaceholders(std.testing.allocator, text, inside, &.{ "before shot.png", "after.jpg" });
    defer editing.deinit();
    try std.testing.expect(std.mem.indexOf(u8, editing.text, "before shot.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, editing.text, "[Image #2]") != null);

    var continued = try displayPlaceholders(std.testing.allocator, "[Image #1] then next.png", "[Image #1] then next.png".len, &.{"next.png"});
    defer continued.deinit();
    try std.testing.expectEqualStrings("[Image #1] then [Image #2]", continued.text);
}

test "loads explicit and prompt image paths" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const cwd = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(cwd);
    const path = try std.fs.path.join(std.testing.allocator, &.{ cwd, "shot.png" });
    defer std.testing.allocator.free(path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a },
    });

    const explicit = try loadPaths(std.testing.allocator, std.testing.io, cwd, &.{"shot.png"});
    defer freeImages(std.testing.allocator, explicit);
    try std.testing.expectEqualStrings("image/png", explicit[0].media_type);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", explicit[0].data);

    var prompt = try fromPrompt(std.testing.allocator, std.testing.io, cwd, try std.testing.allocator.dupe(u8, "inspect @shot.png and @shot.png"), &.{});
    defer prompt.deinit();
    try std.testing.expectEqual(@as(usize, 1), prompt.images.len);
    try std.testing.expectEqualStrings("shot.png", prompt.images[0].name);
    try std.testing.expectEqualStrings("inspect [Image #1] and [Image #1]", prompt.text);
}
