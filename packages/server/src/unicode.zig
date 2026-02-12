// unicode.zig - Glk Unicode support functions

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const stream = @import("stream.zig");

const glui32 = types.glui32;
const glsi32 = types.glsi32;
const strid_t = types.strid_t;

// ============== Character Case Conversion ==============

export fn glk_char_to_lower(ch: u8) callconv(.c) u8 {
    return std.ascii.toLower(ch);
}

export fn glk_char_to_upper(ch: u8) callconv(.c) u8 {
    return std.ascii.toUpper(ch);
}

export fn glk_buffer_to_lower_case_uni(buf: ?[*]glui32, len: glui32, numchars: glui32) callconv(.c) glui32 {
    const buf_ptr = buf orelse return numchars;
    const count = @min(numchars, len);
    for (buf_ptr[0..count]) |*ch| {
        if (ch.* >= 'A' and ch.* <= 'Z') {
            ch.* += 'a' - 'A';
        }
    }
    return numchars;
}

export fn glk_buffer_to_upper_case_uni(buf: ?[*]glui32, len: glui32, numchars: glui32) callconv(.c) glui32 {
    const buf_ptr = buf orelse return numchars;
    const count = @min(numchars, len);
    for (buf_ptr[0..count]) |*ch| {
        if (ch.* >= 'a' and ch.* <= 'z') {
            ch.* -= 'a' - 'A';
        }
    }
    return numchars;
}

export fn glk_buffer_to_title_case_uni(buf: ?[*]glui32, len: glui32, numchars: glui32, lowerrest: glui32) callconv(.c) glui32 {
    const buf_ptr = buf orelse return numchars;
    if (numchars == 0 or len == 0) return numchars;

    if (buf_ptr[0] >= 'a' and buf_ptr[0] <= 'z') {
        buf_ptr[0] -= 'a' - 'A';
    }

    if (lowerrest != 0) {
        const count = @min(numchars, len);
        for (buf_ptr[1..count]) |*ch| {
            if (ch.* >= 'A' and ch.* <= 'Z') {
                ch.* += 'a' - 'A';
            }
        }
    }
    return numchars;
}

export fn glk_buffer_canon_decompose_uni(buf: ?[*]glui32, len: glui32, numchars: glui32) callconv(.c) glui32 {
    _ = buf;
    _ = len;
    return numchars;
}

export fn glk_buffer_canon_normalize_uni(buf: ?[*]glui32, len: glui32, numchars: glui32) callconv(.c) glui32 {
    _ = buf;
    _ = len;
    return numchars;
}

// ============== Tests ==============

const testing = std.testing;

test "glk_char_to_lower converts uppercase ASCII" {
    try testing.expectEqual(@as(u8, 'a'), glk_char_to_lower('A'));
    try testing.expectEqual(@as(u8, 'z'), glk_char_to_lower('Z'));
}

test "glk_char_to_lower preserves non-alpha characters" {
    try testing.expectEqual(@as(u8, '0'), glk_char_to_lower('0'));
    try testing.expectEqual(@as(u8, ' '), glk_char_to_lower(' '));
    try testing.expectEqual(@as(u8, 'a'), glk_char_to_lower('a'));
}

test "glk_char_to_upper converts lowercase ASCII" {
    try testing.expectEqual(@as(u8, 'A'), glk_char_to_upper('a'));
    try testing.expectEqual(@as(u8, 'Z'), glk_char_to_upper('z'));
}

test "glk_char_to_upper preserves non-alpha characters" {
    try testing.expectEqual(@as(u8, '0'), glk_char_to_upper('0'));
    try testing.expectEqual(@as(u8, ' '), glk_char_to_upper(' '));
    try testing.expectEqual(@as(u8, 'A'), glk_char_to_upper('A'));
}

test "glk_buffer_to_lower_case_uni converts buffer" {
    var buf = [_]glui32{ 'H', 'E', 'L', 'L', 'O' };
    const result = glk_buffer_to_lower_case_uni(&buf, 5, 5);
    try testing.expectEqual(@as(glui32, 5), result);
    try testing.expectEqual(@as(glui32, 'h'), buf[0]);
    try testing.expectEqual(@as(glui32, 'e'), buf[1]);
    try testing.expectEqual(@as(glui32, 'l'), buf[2]);
    try testing.expectEqual(@as(glui32, 'o'), buf[4]);
}

test "glk_buffer_to_lower_case_uni with null buf" {
    try testing.expectEqual(@as(glui32, 3), glk_buffer_to_lower_case_uni(null, 5, 3));
}

test "glk_buffer_to_lower_case_uni respects numchars < len" {
    var buf = [_]glui32{ 'A', 'B', 'C', 'D' };
    _ = glk_buffer_to_lower_case_uni(&buf, 4, 2);
    try testing.expectEqual(@as(glui32, 'a'), buf[0]);
    try testing.expectEqual(@as(glui32, 'b'), buf[1]);
    try testing.expectEqual(@as(glui32, 'C'), buf[2]); // unchanged
    try testing.expectEqual(@as(glui32, 'D'), buf[3]); // unchanged
}

test "glk_buffer_to_upper_case_uni converts buffer" {
    var buf = [_]glui32{ 'h', 'e', 'l', 'l', 'o' };
    const result = glk_buffer_to_upper_case_uni(&buf, 5, 5);
    try testing.expectEqual(@as(glui32, 5), result);
    try testing.expectEqual(@as(glui32, 'H'), buf[0]);
    try testing.expectEqual(@as(glui32, 'O'), buf[4]);
}

test "glk_buffer_to_title_case_uni capitalizes first char" {
    var buf = [_]glui32{ 'h', 'e', 'l', 'l', 'o' };
    const result = glk_buffer_to_title_case_uni(&buf, 5, 5, 0);
    try testing.expectEqual(@as(glui32, 5), result);
    try testing.expectEqual(@as(glui32, 'H'), buf[0]);
    try testing.expectEqual(@as(glui32, 'e'), buf[1]); // rest unchanged
}

test "glk_buffer_to_title_case_uni with lowerrest" {
    var buf = [_]glui32{ 'h', 'E', 'L', 'L', 'O' };
    _ = glk_buffer_to_title_case_uni(&buf, 5, 5, 1);
    try testing.expectEqual(@as(glui32, 'H'), buf[0]);
    try testing.expectEqual(@as(glui32, 'e'), buf[1]);
    try testing.expectEqual(@as(glui32, 'l'), buf[2]);
    try testing.expectEqual(@as(glui32, 'o'), buf[4]);
}

test "glk_buffer_to_title_case_uni empty buffer" {
    var buf = [_]glui32{ 'a' };
    try testing.expectEqual(@as(glui32, 0), glk_buffer_to_title_case_uni(&buf, 0, 0, 0));
}

// ============== Unicode Output ==============

export fn glk_put_char_uni(ch: glui32) callconv(.c) void {
    stream.putCharUniToStream(state.current_stream, ch);
}

export fn glk_put_string_uni(s: ?[*:0]const glui32) callconv(.c) void {
    const s_ptr = s orelse return;
    var ptr = s_ptr;
    while (ptr[0] != 0) : (ptr += 1) {
        stream.putCharUniToStream(state.current_stream, ptr[0]);
    }
}

export fn glk_put_buffer_uni(buf: ?[*]const glui32, len: glui32) callconv(.c) void {
    const buf_ptr = buf orelse return;
    for (buf_ptr[0..len]) |ch| {
        stream.putCharUniToStream(state.current_stream, ch);
    }
}

export fn glk_put_char_stream_uni(str: strid_t, ch: glui32) callconv(.c) void {
    stream.putCharUniToStream(@ptrCast(@alignCast(str)), ch);
}

export fn glk_put_string_stream_uni(str: strid_t, s: ?[*:0]const glui32) callconv(.c) void {
    const s_ptr = s orelse return;
    const str_data = @as(?*state.StreamData, @ptrCast(@alignCast(str)));
    var ptr = s_ptr;
    while (ptr[0] != 0) : (ptr += 1) {
        stream.putCharUniToStream(str_data, ptr[0]);
    }
}

export fn glk_put_buffer_stream_uni(str: strid_t, buf: ?[*]const glui32, len: glui32) callconv(.c) void {
    const buf_ptr = buf orelse return;
    const str_data = @as(?*state.StreamData, @ptrCast(@alignCast(str)));
    for (buf_ptr[0..len]) |ch| {
        stream.putCharUniToStream(str_data, ch);
    }
}

// ============== Unicode Input ==============

export fn glk_get_char_stream_uni(str: strid_t) callconv(.c) glsi32 {
    return stream.getCharUniFromStream(@ptrCast(@alignCast(str)));
}

export fn glk_get_buffer_stream_uni(str: strid_t, buf: ?[*]glui32, len: glui32) callconv(.c) glui32 {
    const buf_ptr = buf orelse return 0;
    const str_data: ?*state.StreamData = @ptrCast(@alignCast(str));
    for (buf_ptr[0..len], 0..) |*slot, i| {
        const ch = stream.getCharUniFromStream(str_data);
        if (ch < 0) return @intCast(i);
        slot.* = @intCast(ch);
    }
    return len;
}

export fn glk_get_line_stream_uni(str_opaque: strid_t, buf: ?[*]glui32, len: glui32) callconv(.c) glui32 {
    const buf_ptr = buf orelse return 0;
    if (len == 0) return 0;
    const str_data: ?*state.StreamData = @ptrCast(@alignCast(str_opaque));
    for (buf_ptr[0 .. len - 1], 0..) |*slot, i| {
        const ch = stream.getCharUniFromStream(str_data);
        if (ch < 0) return @intCast(i);
        slot.* = @intCast(ch);
        if (ch == '\n') return @intCast(i + 1);
    }
    return len - 1;
}
