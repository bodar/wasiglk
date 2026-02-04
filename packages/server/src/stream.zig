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

    // Open the file
    const flags: std.fs.File.OpenFlags = .{
        .mode = if (writable) .write_only else .read_only,
    };

    const file = std.fs.cwd().openFile(f.filename, flags) catch |err| {
        if (err == error.FileNotFound and writable) {
            // Create file for writing
            const new_file = std.fs.cwd().createFile(f.filename, .{}) catch return null;
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
            };
            state.stream_id_counter += 1;

            stream.next = state.stream_list;
            if (state.stream_list) |list| list.prev = stream;
            state.stream_list = stream;

            // Register with dispatch system
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
    };
    state.stream_id_counter += 1;

    stream.next = state.stream_list;
    if (state.stream_list) |list| list.prev = stream;
    state.stream_list = stream;

    // Register with dispatch system
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

    if (s.file) |f| f.close();

    if (state.current_stream == s) state.current_stream = null;

    // Unregister memory buffer from retained registry (must be before object unregister)
    if (s.stream_type == .memory) {
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
    if (str == null or !str.?.writable) return;
    const s = str.?;
    s.writecount += 1;

    switch (s.stream_type) {
        .window => {
            if (s.win) |w| {
                // Buffer text output
                if (state.text_buffer_win != w) {
                    protocol.flushTextBuffer();
                    state.text_buffer_win = w;
                }
                if (state.text_buffer_len < state.text_buffer.len) {
                    state.text_buffer[state.text_buffer_len] = ch;
                    state.text_buffer_len += 1;
                }
            }
        },
        .memory => {
            if (s.buf) |buf| {
                if (s.bufptr < s.buflen) {
                    buf[s.bufptr] = ch;
                    s.bufptr += 1;
                }
            }
        },
        .file => {
            if (s.file) |f| {
                _ = f.write(&[_]u8{ch}) catch return;
            }
        },
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
    _ = styl;
}

export fn glk_set_style_stream(str: strid_t, styl: glui32) callconv(.c) void {
    _ = str;
    _ = styl;
}

// ============== Input Functions ==============

pub export fn glk_get_char_stream(str_opaque: strid_t) callconv(.c) glsi32 {
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null or !str.?.readable) return -1;
    const s = str.?;
    s.readcount += 1;

    switch (s.stream_type) {
        .memory => {
            if (s.buf) |buf| {
                if (s.bufptr < s.buflen) {
                    const ch = buf[s.bufptr];
                    s.bufptr += 1;
                    return ch;
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
            if (s.buf) |src| {
                while (count < len and s.bufptr < s.buflen) {
                    b[count] = src[s.bufptr];
                    s.bufptr += 1;
                    count += 1;
                    s.readcount += 1;
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
