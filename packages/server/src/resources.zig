// resources.zig - Image helpers + ad-hoc file-resource table.
//
// Two responsibilities, both serving interpreters whose graphics are NOT
// delivered through a client-visible Blorb (so the client cannot resolve image
// numbers to pixels itself and the server must carry the bytes):
//
//  1. Shared image helpers — sniff PNG/JPEG mime + dimensions, and build a
//     `data:` URI. Used for both Hugo (bytes come from a server-synthesized
//     Blorb map) and Scare (bytes come from the table below).
//  2. The garglk file-resource table — Scare registers image byte-ranges inside
//     its own story file via `garglk_add_resource_from_file`; we read the bytes
//     out of the mounted story and hand back a sequential id, mirroring
//     Gargoyle's `resource_maps`. `glk_image_*` consult this when the Blorb map
//     has no such image.

const std = @import("std");
const state = @import("state.zig");

const glui32 = state.glui32;
const allocator = state.allocator;

// ============== Image sniffing ==============

pub const ImageMime = enum {
    png,
    jpeg,
    unknown,

    pub fn str(self: ImageMime) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .unknown => "application/octet-stream",
        };
    }
};

const png_sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

pub fn sniffMime(bytes: []const u8) ImageMime {
    if (bytes.len >= png_sig.len and std.mem.eql(u8, bytes[0..png_sig.len], &png_sig)) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return .jpeg;
    return .unknown;
}

pub const Dims = struct { width: u32, height: u32 };

/// Read pixel dimensions from a PNG/JPEG byte buffer without decoding it.
/// Returns null if the format is unrecognized or the header is truncated.
pub fn sniffDims(bytes: []const u8) ?Dims {
    return switch (sniffMime(bytes)) {
        .png => pngDims(bytes),
        .jpeg => jpegDims(bytes),
        .unknown => null,
    };
}

fn readU32Be(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

fn readU16Be(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .big);
}

// PNG: 8-byte signature, then IHDR chunk (4 len + 4 "IHDR" + width@16 + height@20).
fn pngDims(bytes: []const u8) ?Dims {
    if (bytes.len < 24) return null;
    return .{ .width = readU32Be(bytes, 16), .height = readU32Be(bytes, 20) };
}

// JPEG: scan segment markers for a Start-Of-Frame (SOFn) and read its 16-bit
// height/width. Skips other segments by their length field.
fn jpegDims(bytes: []const u8) ?Dims {
    if (bytes.len < 4) return null;
    var i: usize = 2; // skip SOI (FF D8)
    while (i + 9 < bytes.len) {
        if (bytes[i] != 0xff) {
            i += 1;
            continue;
        }
        const marker = bytes[i + 1];
        // Standalone markers with no length payload.
        if (marker == 0xd8 or marker == 0xd9 or (marker >= 0xd0 and marker <= 0xd7) or marker == 0x01 or marker == 0xff) {
            i += 2;
            continue;
        }
        const seg_len = readU16Be(bytes, i + 2);
        if (seg_len < 2) return null;
        // SOF0..SOF15 carry the frame dimensions (excluding DHT/JPG/DAC markers).
        const is_sof = (marker >= 0xc0 and marker <= 0xcf) and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (is_sof) {
            if (i + 9 >= bytes.len) return null;
            const height = readU16Be(bytes, i + 5);
            const width = readU16Be(bytes, i + 7);
            return .{ .width = width, .height = height };
        }
        i += 2 + seg_len;
    }
    return null;
}

// ============== data: URI ==============

/// Build a `data:<mime>;base64,<...>` URI for the given image bytes, allocated
/// with `a`. Caller owns the result. Returns null if the mime is unrecognized
/// (we only emit types the display can render) or allocation fails.
pub fn dataUri(a: std.mem.Allocator, bytes: []const u8) ?[]u8 {
    const mime = sniffMime(bytes);
    if (mime == .unknown) return null;

    const prefix = "data:";
    const infix = ";base64,";
    const enc = std.base64.standard.Encoder;
    const b64_len = enc.calcSize(bytes.len);

    const mime_str = mime.str();
    const total = prefix.len + mime_str.len + infix.len + b64_len;
    const out = a.alloc(u8, total) catch return null;

    var pos: usize = 0;
    @memcpy(out[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(out[pos..][0..mime_str.len], mime_str);
    pos += mime_str.len;
    @memcpy(out[pos..][0..infix.len], infix);
    pos += infix.len;
    _ = enc.encode(out[pos..], bytes);

    return out;
}

// ============== garglk file-resource table ==============

const Resource = struct {
    usage: glui32,
    filename: []const u8, // owned
    offset: glui32,
    bytes: []u8, // owned
    width: u32,
    height: u32,
};

// Index i holds the resource with id (i + 1); id 0 means "not a resource".
var resources: std.ArrayList(Resource) = .{};

/// Register a byte-range of a file as an image resource, returning a 1-based id
/// (0 on failure). Reads the bytes out of the mounted story now, so later draws
/// need no file access. Deduped by (usage, filename, offset) like Gargoyle.
pub fn addResourceFromFile(usage: glui32, filename: []const u8, offset: glui32, len: glui32) glui32 {
    if (len == 0) return 0; // no resource (Scare passes len 0 to clear/skip)

    // Reuse an existing entry for the same slice.
    for (resources.items, 0..) |r, i| {
        if (r.usage == usage and r.offset == offset and std.mem.eql(u8, r.filename, filename)) {
            return @intCast(i + 1);
        }
    }

    const bytes = readFileRange(filename, offset, len) orelse return 0;
    errdefer allocator.free(bytes);

    const name_copy = allocator.dupe(u8, filename) catch return 0;
    const dims = sniffDims(bytes) orelse Dims{ .width = 0, .height = 0 };

    resources.append(allocator, .{
        .usage = usage,
        .filename = name_copy,
        .offset = offset,
        .bytes = bytes,
        .width = dims.width,
        .height = dims.height,
    }) catch {
        allocator.free(name_copy);
        return 0;
    };
    return @intCast(resources.items.len);
}

pub fn get(id: glui32) ?*const Resource {
    if (id == 0 or id > resources.items.len) return null;
    return &resources.items[id - 1];
}

/// Raw image bytes for a resource id, or null.
pub fn getBytes(id: glui32) ?[]const u8 {
    const r = get(id) orelse return null;
    return r.bytes;
}

/// Pixel dimensions for a resource id, or null.
pub fn getDims(id: glui32) ?Dims {
    const r = get(id) orelse return null;
    return .{ .width = r.width, .height = r.height };
}

// Read `len` bytes at `offset` from a story file. The story lives at /sys/<name>
// in the worker sandbox; `filename` is usually a bare basename (Scare strips it
// to one), resolved against the story directory via state.resolvePath.
fn readFileRange(filename: []const u8, offset: glui32, len: glui32) ?[]u8 {
    var pathbuf: [1024]u8 = undefined;
    const path = state.resolvePath(&pathbuf, filename);
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    file.seekTo(offset) catch return null;
    const buf = allocator.alloc(u8, len) catch return null;
    const n = file.readAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    if (n != len) {
        allocator.free(buf);
        return null;
    }
    return buf;
}

// ============== Tests ==============

const testing = std.testing;

test "sniffMime detects png and jpeg" {
    try testing.expectEqual(ImageMime.png, sniffMime(&png_sig));
    try testing.expectEqual(ImageMime.jpeg, sniffMime(&[_]u8{ 0xff, 0xd8, 0xff, 0xe0 }));
    try testing.expectEqual(ImageMime.unknown, sniffMime(&[_]u8{ 0x00, 0x01 }));
    try testing.expectEqual(ImageMime.unknown, sniffMime(&[_]u8{}));
}

test "sniffDims reads png IHDR" {
    var png = [_]u8{0} ** 24;
    @memcpy(png[0..8], &png_sig);
    std.mem.writeInt(u32, png[16..20], 320, .big);
    std.mem.writeInt(u32, png[20..24], 200, .big);
    const dims = sniffDims(&png).?;
    try testing.expectEqual(@as(u32, 320), dims.width);
    try testing.expectEqual(@as(u32, 200), dims.height);
}

test "sniffDims scans jpeg SOF0" {
    // SOI, APP0 (len 4, skipped), SOF0 (len 17) with height=100 width=150.
    var jpg = [_]u8{
        0xff, 0xd8, // SOI
        0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, // APP0 len=4 + 2 payload
        0xff, 0xc0, 0x00, 0x11, 0x08, // SOF0 len=17, precision
        0x00, 0x64, // height 100
        0x00, 0x96, // width 150
        0x03, // components
    };
    const dims = sniffDims(&jpg).?;
    try testing.expectEqual(@as(u32, 150), dims.width);
    try testing.expectEqual(@as(u32, 100), dims.height);
}

test "dataUri encodes png with correct prefix" {
    const uri = dataUri(testing.allocator, &png_sig).?;
    defer testing.allocator.free(uri);
    try testing.expect(std.mem.startsWith(u8, uri, "data:image/png;base64,"));
    // "iVBORw0KGgo=" is the base64 of the 8-byte PNG signature.
    try testing.expect(std.mem.endsWith(u8, uri, "iVBORw0KGgo="));
}

test "dataUri returns null for unknown mime" {
    try testing.expect(dataUri(testing.allocator, &[_]u8{ 0x00, 0x01, 0x02 }) == null);
}
