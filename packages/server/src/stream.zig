// stream.zig - Glk stream functions

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const dispatch = @import("dispatch.zig");
const protocol = @import("protocol.zig");

const glui32 = types.glui32;
const glsi32 = types.glsi32;
const strid_t = types.strid_t;
const frefid_t = types.frefid_t;
const stream_result_t = types.stream_result_t;
const filemode = types.filemode;
const seekmode = types.seekmode;
const wintype = types.wintype;
const StreamData = state.StreamData;
const FileRefData = state.FileRefData;
const WindowData = state.WindowData;
const allocator = state.allocator;

// ============== Stream Creation ==============

pub export fn glk_stream_open_file(fref_opaque: frefid_t, fmode: glui32, rock: glui32) callconv(.c) strid_t {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return null;
    const f = fref.?;

    const readable = (fmode == filemode.Read or fmode == filemode.ReadWrite);
    const writable = (fmode != filemode.Read);

    // Temp filerefs are backed by an in-memory buffer on the fileref, not the
    // sandbox filesystem. Model as a memory stream over that buffer; writes grow
    // it (see putCharUniToStream). Write mode (not read) truncates, matching Glk.
    if (f.is_temp) {
        if (f.temp_buf == null) f.temp_buf = .{};
        const tb = &f.temp_buf.?;
        if (writable and !readable) tb.clearRetainingCapacity();
        const stream = allocator.create(StreamData) catch return null;
        stream.* = StreamData{
            .id = state.stream_id_counter,
            .rock = rock,
            .stream_type = .memory,
            .readable = readable,
            .writable = writable,
            .buf = if (tb.items.len > 0) tb.items.ptr else null,
            .buflen = @intCast(tb.items.len),
            .temp_fref = f,
        };
        state.stream_id_counter += 1;
        stream.next = state.stream_list;
        if (state.stream_list) |list| list.prev = stream;
        state.stream_list = stream;
        if (dispatch.object_register_fn) |register_fn| {
            stream.dispatch_rock = register_fn(@ptrCast(stream), dispatch.gidisp_Class_Stream);
        }
        return @ptrCast(stream);
    }

    const flags: std.fs.File.OpenFlags = .{
        .mode = if (readable and writable) .read_write else if (writable) .write_only else .read_only,
    };

    // Resolve companion/relative names against the story directory (our cwd).
    var pathbuf: [1024]u8 = undefined;
    const path = state.resolvePath(&pathbuf, f.filename);

    const file = std.fs.cwd().openFile(path, flags) catch |err| {
        if (err == error.FileNotFound and writable) {
            // Create file for writing
            const new_file = std.fs.cwd().createFile(path, .{ .read = readable }) catch return null;
            const stream = allocator.create(StreamData) catch {
                new_file.close();
                return null;
            };
            stream.* = StreamData{
                .id = state.stream_id_counter,
                .rock = rock,
                .stream_type = .file,
                .readable = readable,
                .writable = writable,
                .file = new_file,
                .textmode = f.textmode,
            };
            state.stream_id_counter += 1;

            stream.next = state.stream_list;
            if (state.stream_list) |list| list.prev = stream;
            state.stream_list = stream;

            if (dispatch.object_register_fn) |register_fn| {
                stream.dispatch_rock = register_fn(@ptrCast(stream), dispatch.gidisp_Class_Stream);
            }

            return @ptrCast(stream);
        }
        return null;
    };

    const stream = allocator.create(StreamData) catch {
        file.close();
        return null;
    };
    stream.* = StreamData{
        .id = state.stream_id_counter,
        .rock = rock,
        .stream_type = .file,
        .readable = readable,
        .writable = writable,
        .file = file,
        .textmode = f.textmode,
    };
    state.stream_id_counter += 1;

    stream.next = state.stream_list;
    if (state.stream_list) |list| list.prev = stream;
    state.stream_list = stream;

    if (dispatch.object_register_fn) |register_fn| {
        stream.dispatch_rock = register_fn(@ptrCast(stream), dispatch.gidisp_Class_Stream);
    }

    return @ptrCast(stream);
}

export fn glk_stream_open_memory(buf: ?[*]u8, buflen: glui32, fmode: glui32, rock: glui32) callconv(.c) strid_t {
    const readable = (fmode == filemode.Read or fmode == filemode.ReadWrite);
    const writable = (fmode != filemode.Read);

    const stream = allocator.create(StreamData) catch return null;
    stream.* = StreamData{
        .id = state.stream_id_counter,
        .rock = rock,
        .stream_type = .memory,
        .readable = readable,
        .writable = writable,
        .buf = buf,
        .buflen = buflen,
        .is_unicode = false,
    };
    state.stream_id_counter += 1;

    stream.next = state.stream_list;
    if (state.stream_list) |list| list.prev = stream;
    state.stream_list = stream;

    // Register buffer with retained registry so Glulxe knows not to free it
    if (buf != null and buflen > 0) {
        if (dispatch.retained_register_fn) |register_fn| {
            // Typecode format: prefix chars + type + subtype
            // typecode[4] must be 'C' or 'I' for glulxe_retained_register to work
            // Use "&+#!Cn" format: & (ref), + (passout), # (array), ! (retained), C (char), n (subtype)
            var typecode = "&+#!Cn".*;
            stream.buf_rock = register_fn(@ptrCast(buf), buflen, &typecode);
        }
    }

    // Register stream with dispatch system
    if (dispatch.object_register_fn) |register_fn| {
        stream.dispatch_rock = register_fn(@ptrCast(stream), dispatch.gidisp_Class_Stream);
    }

    return @ptrCast(stream);
}

export fn glk_stream_open_memory_uni(buf: ?[*]glui32, buflen: glui32, fmode: glui32, rock: glui32) callconv(.c) strid_t {
    const readable = (fmode == filemode.Read or fmode == filemode.ReadWrite);
    const writable = (fmode != filemode.Read);

    const stream = allocator.create(StreamData) catch return null;
    stream.* = StreamData{
        .id = state.stream_id_counter,
        .rock = rock,
        .stream_type = .memory,
        .readable = readable,
        .writable = writable,
        .buf_uni = buf,
        .buflen = buflen,
        .is_unicode = true,
    };
    state.stream_id_counter += 1;

    stream.next = state.stream_list;
    if (state.stream_list) |list| list.prev = stream;
    state.stream_list = stream;

    // Register buffer with retained registry so Glulxe knows not to free it
    if (buf != null and buflen > 0) {
        if (dispatch.retained_register_fn) |register_fn| {
            // typecode[4] must be 'I' for glulxe_retained_register to work with unicode
            var typecode = "&+#!Iu".*;
            stream.buf_rock = register_fn(@ptrCast(buf), buflen, &typecode);
        }
    }

    // Register stream with dispatch system
    if (dispatch.object_register_fn) |register_fn| {
        stream.dispatch_rock = register_fn(@ptrCast(stream), dispatch.gidisp_Class_Stream);
    }

    return @ptrCast(stream);
}

export fn glk_stream_open_file_uni(fref: frefid_t, fmode: glui32, rock: glui32) callconv(.c) strid_t {
    return glk_stream_open_file(fref, fmode, rock);
}

// Create window stream (internal helper)
pub fn createWindowStream(win: *WindowData) ?*StreamData {
    const stream = allocator.create(StreamData) catch return null;
    stream.* = StreamData{
        .id = state.stream_id_counter,
        .rock = 0,
        .stream_type = .window,
        .readable = false,
        .writable = true,
        .win = win,
    };
    state.stream_id_counter += 1;

    // Add to list
    stream.next = state.stream_list;
    if (state.stream_list) |list| list.prev = stream;
    state.stream_list = stream;

    // Register with dispatch system
    if (dispatch.object_register_fn) |register_fn| {
        stream.dispatch_rock = register_fn(@ptrCast(stream), dispatch.gidisp_Class_Stream);
    }

    return stream;
}

// ============== Stream Operations ==============

pub export fn glk_stream_close(str_opaque: strid_t, result: ?*stream_result_t) callconv(.c) void {
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null) return;
    const s = str.?;

    if (result) |r| {
        r.readcount = s.readcount;
        r.writecount = s.writecount;
    }

    if (s.file) |f| {
        f.sync() catch {};
        f.close();
    }

    if (state.current_stream == s) state.current_stream = null;

    // Unregister memory buffer from retained registry (must be before object
    // unregister). Temp streams own no caller buffer (backed by the fileref's
    // in-memory buffer), so skip them.
    if (s.stream_type == .memory and s.temp_fref == null) {
        if (dispatch.retained_unregister_fn) |unregister_fn| {
            if (s.is_unicode) {
                if (s.buf_uni) |buf| {
                    var typecode = "&+#!Iu".*;
                    unregister_fn(@ptrCast(buf), s.buflen, &typecode, s.buf_rock);
                }
            } else {
                if (s.buf) |buf| {
                    var typecode = "&+#!Cn".*;
                    unregister_fn(@ptrCast(buf), s.buflen, &typecode, s.buf_rock);
                }
            }
        }
    }

    // Unregister stream from dispatch system
    if (dispatch.object_unregister_fn) |unregister_fn| {
        unregister_fn(@ptrCast(s), dispatch.gidisp_Class_Stream, s.dispatch_rock);
    }

    // Remove from list
    if (s.prev) |p| p.next = s.next else state.stream_list = s.next;
    if (s.next) |n| n.prev = s.prev;

    allocator.destroy(s);
}

export fn glk_stream_iterate(str_opaque: strid_t, rockptr: ?*glui32) callconv(.c) strid_t {
    var str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null) {
        str = state.stream_list;
    } else {
        str = str.?.next;
    }

    if (str) |s| {
        if (rockptr) |r| r.* = s.rock;
    }
    return @ptrCast(str);
}

export fn glk_stream_get_rock(str_opaque: strid_t) callconv(.c) glui32 {
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str) |s| return s.rock;
    return 0;
}

export fn glk_stream_set_position(str_opaque: strid_t, pos: glsi32, mode: glui32) callconv(.c) void {
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null) return;
    const s = str.?;

    switch (s.stream_type) {
        .file => {
            if (s.file) |f| {
                switch (mode) {
                    seekmode.Current => f.seekBy(pos) catch return,
                    seekmode.End => f.seekFromEnd(pos) catch return,
                    else => f.seekTo(@intCast(@max(0, pos))) catch return,
                }
            }
        },
        .memory => {
            if (mode == seekmode.Current) {
                const new_pos = @as(i64, s.bufptr) + pos;
                s.bufptr = @intCast(@max(0, @min(new_pos, s.buflen)));
            } else if (mode == seekmode.End) {
                const new_pos = @as(i64, s.buflen) + pos;
                s.bufptr = @intCast(@max(0, @min(new_pos, s.buflen)));
            } else {
                s.bufptr = @intCast(@max(0, @min(pos, @as(glsi32, @intCast(s.buflen)))));
            }
        },
        .window => {},
    }
}

export fn glk_stream_get_position(str_opaque: strid_t) callconv(.c) glui32 {
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null) return 0;
    const s = str.?;

    switch (s.stream_type) {
        .file => {
            if (s.file) |f| {
                return @intCast(f.getPos() catch 0);
            }
            return 0;
        },
        .memory => return s.bufptr,
        .window => return 0,
    }
}

export fn glk_stream_set_current(str_opaque: strid_t) callconv(.c) void {
    state.current_stream = @ptrCast(@alignCast(str_opaque));
}

export fn glk_stream_get_current() callconv(.c) strid_t {
    return @ptrCast(state.current_stream);
}

// ============== Output Functions ==============

fn putCharToStream(str: ?*StreamData, ch: u8) void {
    putCharUniToStream(str, ch);
}

/// Write a unicode character (glui32) to a stream. Handles both unicode and
/// non-unicode memory streams correctly: unicode streams store glui32 values,
/// non-unicode streams store the lower byte.
pub fn putCharUniToStream(str: ?*StreamData, ch: glui32) void {
    if (str == null or !str.?.writable) return;
    const s = str.?;
    s.writecount += 1;

    switch (s.stream_type) {
        .window => {
            if (s.win) |w| {
                // For grid windows, write directly to the grid buffer
                if (w.win_type == wintype.TextGrid) {
                    putCharToGridWindow(w, if (ch < 256) @intCast(ch) else '?');
                } else {
                    // Buffer text output for other window types
                    if (state.text_buffer_win != w) {
                        protocol.flushTextBuffer();
                        state.text_buffer_win = w;
                    }
                    // Auto-flush when buffer is nearly full to avoid silent truncation
                    if (state.text_buffer_len >= state.text_buffer.len - 4) {
                        protocol.flushTextBuffer();
                        state.text_buffer_win = w;
                    }
                    // UTF-8 encode the character into the text buffer
                    if (ch < 0x80) {
                        state.text_buffer[state.text_buffer_len] = @intCast(ch);
                        state.text_buffer_len += 1;
                    } else {
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(ch), &utf8_buf) catch return;
                        for (utf8_buf[0..len]) |b| {
                            state.text_buffer[state.text_buffer_len] = b;
                            state.text_buffer_len += 1;
                        }
                    }
                }
            }
        },
        .memory => {
            if (s.temp_fref) |f| {
                // Growable in-memory temp file: append past the end instead of
                // dropping. Buffer lives on the fileref; keep the stream's view
                // in sync in case appends reallocate it.
                const tb = &f.temp_buf.?;
                const byte: u8 = if (ch < 256) @intCast(ch) else '?';
                while (tb.items.len < s.bufptr) tb.append(state.allocator, 0) catch return;
                if (s.bufptr < tb.items.len) {
                    tb.items[s.bufptr] = byte;
                } else {
                    tb.append(state.allocator, byte) catch return;
                }
                s.bufptr += 1;
                s.buf = tb.items.ptr;
                s.buflen = @intCast(tb.items.len);
            } else if (s.is_unicode) {
                if (s.buf_uni) |buf| {
                    if (s.bufptr < s.buflen) {
                        buf[s.bufptr] = ch;
                        s.bufptr += 1;
                    }
                }
            } else {
                if (s.buf) |buf| {
                    if (s.bufptr < s.buflen) {
                        buf[s.bufptr] = if (ch < 256) @intCast(ch) else '?';
                        s.bufptr += 1;
                    }
                }
            }
        },
        .file => {
            if (s.file) |f| {
                if (s.textmode) {
                    // Text mode: UTF-8 encode characters
                    if (ch < 0x80) {
                        _ = f.write(&[_]u8{@intCast(ch)}) catch return;
                    } else {
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(ch), &utf8_buf) catch return;
                        _ = f.write(utf8_buf[0..len]) catch return;
                    }
                } else {
                    // Binary mode: write raw byte
                    _ = f.write(&[_]u8{if (ch < 256) @intCast(ch) else '?'}) catch return;
                }
            }
        },
    }
}

// Write a character to a grid window at the current cursor position
fn putCharToGridWindow(w: *WindowData, ch: u8) void {
    const grid_buf = w.grid_buffer orelse return;
    const dirty = w.grid_dirty orelse return;

    // Newline advances to next line
    if (ch == '\n') {
        w.cursor_x = 0;
        if (w.cursor_y + 1 < w.grid_height) {
            w.cursor_y += 1;
        }
        return;
    }

    // Ignore other control characters
    if (ch < 0x20) return;

    // Write character if within bounds
    if (w.cursor_y < w.grid_height and w.cursor_x < w.grid_width) {
        grid_buf[w.cursor_y][w.cursor_x] = ch;
        dirty[w.cursor_y] = true;

        // Advance cursor
        w.cursor_x += 1;
        if (w.cursor_x >= w.grid_width) {
            w.cursor_x = 0;
            if (w.cursor_y + 1 < w.grid_height) {
                w.cursor_y += 1;
            }
        }
    }
}

pub export fn glk_put_char(ch: u8) callconv(.c) void {
    putCharToStream(state.current_stream, ch);
}

export fn glk_put_char_stream(str_opaque: strid_t, ch: u8) callconv(.c) void {
    putCharToStream(@ptrCast(@alignCast(str_opaque)), ch);
}

export fn glk_put_string(s: ?[*:0]const u8) callconv(.c) void {
    glk_put_string_stream(@ptrCast(state.current_stream), s);
}

export fn glk_put_string_stream(str_opaque: strid_t, s: ?[*:0]const u8) callconv(.c) void {
    const s_ptr = s orelse return;
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    for (std.mem.span(s_ptr)) |ch| {
        putCharToStream(str, ch);
    }
}

export fn glk_put_buffer(buf: ?[*]const u8, len: glui32) callconv(.c) void {
    glk_put_buffer_stream(@ptrCast(state.current_stream), buf, len);
}

export fn glk_put_buffer_stream(str_opaque: strid_t, buf: ?[*]const u8, len: glui32) callconv(.c) void {
    const buf_ptr = buf orelse return;
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    for (buf_ptr[0..len]) |ch| {
        putCharToStream(str, ch);
    }
}

export fn glk_set_style(styl: glui32) callconv(.c) void {
    // Flush current buffer before changing style (so previous text keeps its style)
    if (state.current_style != styl) {
        protocol.flushTextBuffer();
        state.current_style = styl;
    }
}

export fn glk_set_style_stream(str_opaque: strid_t, styl: glui32) callconv(.c) void {
    // For now, only handle setting style on the current stream
    // A full implementation would track style per-stream
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str != null and str == state.current_stream) {
        glk_set_style(styl);
    }
}

// ============== Input Functions ==============

pub export fn glk_get_char_stream(str_opaque: strid_t) callconv(.c) glsi32 {
    return getCharUniFromStream(@ptrCast(@alignCast(str_opaque)));
}

/// Read a character from a stream as a glsi32 value. Handles both unicode
/// and non-unicode memory streams: unicode streams return the glui32 value,
/// non-unicode streams return the byte value.
pub fn getCharUniFromStream(str: ?*StreamData) glsi32 {
    if (str == null or !str.?.readable) return -1;
    const s = str.?;
    s.readcount += 1;

    switch (s.stream_type) {
        .memory => {
            if (s.is_unicode) {
                if (s.buf_uni) |buf| {
                    if (s.bufptr < s.buflen) {
                        const ch = buf[s.bufptr];
                        s.bufptr += 1;
                        return @bitCast(ch);
                    }
                }
            } else {
                if (s.buf) |buf| {
                    if (s.bufptr < s.buflen) {
                        const ch = buf[s.bufptr];
                        s.bufptr += 1;
                        return ch;
                    }
                }
            }
            return -1;
        },
        .file => {
            if (s.file) |f| {
                var byte: [1]u8 = undefined;
                const n = f.read(&byte) catch return -1;
                if (n == 0) return -1;
                return byte[0];
            }
            return -1;
        },
        .window => return -1,
    }
}

export fn glk_get_line_stream(str_opaque: strid_t, buf: ?[*]u8, len: glui32) callconv(.c) glui32 {
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null or !str.?.readable or buf == null or len == 0) return 0;
    const s = str.?;

    var count: glui32 = 0;
    const b = buf.?;

    switch (s.stream_type) {
        .memory => {
            if (s.is_unicode) {
                if (s.buf_uni) |src| {
                    while (count < len - 1 and s.bufptr < s.buflen) {
                        const ch = src[s.bufptr];
                        s.bufptr += 1;
                        b[count] = if (ch < 256) @intCast(ch) else '?';
                        count += 1;
                        s.readcount += 1;
                        if (ch == '\n') break;
                    }
                }
            } else {
                if (s.buf) |src| {
                    while (count < len - 1 and s.bufptr < s.buflen) {
                        const ch = src[s.bufptr];
                        s.bufptr += 1;
                        b[count] = ch;
                        count += 1;
                        s.readcount += 1;
                        if (ch == '\n') break;
                    }
                }
            }
        },
        .file => {
            if (s.file) |f| {
                while (count < len - 1) {
                    var byte: [1]u8 = undefined;
                    const n = f.read(&byte) catch break;
                    if (n == 0) break;
                    b[count] = byte[0];
                    count += 1;
                    s.readcount += 1;
                    if (byte[0] == '\n') break;
                }
            }
        },
        .window => {},
    }

    if (count < len) b[count] = 0;
    return count;
}

export fn glk_get_buffer_stream(str_opaque: strid_t, buf: ?[*]u8, len: glui32) callconv(.c) glui32 {
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null or !str.?.readable or buf == null) return 0;
    const s = str.?;

    var count: glui32 = 0;
    const b = buf.?;

    switch (s.stream_type) {
        .memory => {
            if (s.is_unicode) {
                if (s.buf_uni) |src| {
                    while (count < len and s.bufptr < s.buflen) {
                        b[count] = if (src[s.bufptr] < 256) @intCast(src[s.bufptr]) else '?';
                        s.bufptr += 1;
                        count += 1;
                        s.readcount += 1;
                    }
                }
            } else {
                if (s.buf) |src| {
                    while (count < len and s.bufptr < s.buflen) {
                        b[count] = src[s.bufptr];
                        s.bufptr += 1;
                        count += 1;
                        s.readcount += 1;
                    }
                }
            }
        },
        .file => {
            if (s.file) |f| {
                const slice = b[0..len];
                count = @intCast(f.read(slice) catch 0);
                s.readcount += count;
            }
        },
        .window => {},
    }

    return count;
}

// Resource streams (stubs)
export fn glk_stream_open_resource(filenum: glui32, rock: glui32) callconv(.c) strid_t {
    _ = filenum;
    _ = rock;
    return null;
}

export fn glk_stream_open_resource_uni(filenum: glui32, rock: glui32) callconv(.c) strid_t {
    _ = filenum;
    _ = rock;
    return null;
}
