// wasi_glk.zig - WASI-compatible Glk implementation for Emglken
//
// This implements the Glk API using WASI stdin/stdout for I/O.
// Output is sent as JSON to stdout, input is read from stdin.
// This follows the RemGlk protocol for compatibility.

const std = @import("std");
const builtin = @import("builtin");

// ============== Types ==============

pub const glui32 = u32;
pub const glsi32 = i32;

// Opaque pointer types for C compatibility
pub const Window = opaque {};
pub const Stream = opaque {};
pub const FileRef = opaque {};
pub const SoundChannel = opaque {};

pub const winid_t = ?*Window;
pub const strid_t = ?*Stream;
pub const frefid_t = ?*FileRef;
pub const schanid_t = ?*SoundChannel;

// Event structure (matches C layout)
pub const event_t = extern struct {
    type: glui32,
    win: winid_t,
    val1: glui32,
    val2: glui32,
};

pub const stream_result_t = extern struct {
    readcount: glui32,
    writecount: glui32,
};

// Glk constants
pub const gestalt = struct {
    pub const Version: glui32 = 0;
    pub const CharInput: glui32 = 1;
    pub const LineInput: glui32 = 2;
    pub const CharOutput: glui32 = 3;
    pub const CharOutput_CannotPrint: glui32 = 0;
    pub const CharOutput_ApproxPrint: glui32 = 1;
    pub const CharOutput_ExactPrint: glui32 = 2;
    pub const MouseInput: glui32 = 4;
    pub const Timer: glui32 = 5;
    pub const Graphics: glui32 = 6;
    pub const DrawImage: glui32 = 7;
    pub const Sound: glui32 = 8;
    pub const SoundVolume: glui32 = 9;
    pub const SoundNotify: glui32 = 10;
    pub const Hyperlinks: glui32 = 11;
    pub const HyperlinkInput: glui32 = 12;
    pub const SoundMusic: glui32 = 13;
    pub const GraphicsTransparency: glui32 = 14;
    pub const Unicode: glui32 = 15;
    pub const UnicodeNorm: glui32 = 16;
    pub const LineInputEcho: glui32 = 17;
    pub const LineTerminators: glui32 = 18;
    pub const LineTerminatorKey: glui32 = 19;
    pub const DateTime: glui32 = 20;
    pub const Sound2: glui32 = 21;
    pub const ResourceStream: glui32 = 22;
    pub const GraphicsCharInput: glui32 = 23;
};

pub const evtype = struct {
    pub const None: glui32 = 0;
    pub const Timer: glui32 = 1;
    pub const CharInput: glui32 = 2;
    pub const LineInput: glui32 = 3;
    pub const MouseInput: glui32 = 4;
    pub const Arrange: glui32 = 5;
    pub const Redraw: glui32 = 6;
    pub const SoundNotify: glui32 = 7;
    pub const Hyperlink: glui32 = 8;
};

pub const wintype = struct {
    pub const AllTypes: glui32 = 0;
    pub const Pair: glui32 = 1;
    pub const Blank: glui32 = 2;
    pub const TextBuffer: glui32 = 3;
    pub const TextGrid: glui32 = 4;
    pub const Graphics: glui32 = 5;
};

pub const fileusage = struct {
    pub const Data: glui32 = 0x00;
    pub const SavedGame: glui32 = 0x01;
    pub const Transcript: glui32 = 0x02;
    pub const InputRecord: glui32 = 0x03;
    pub const TypeMask: glui32 = 0x0f;
    pub const TextMode: glui32 = 0x100;
    pub const BinaryMode: glui32 = 0x000;
};

pub const filemode = struct {
    pub const Write: glui32 = 0x01;
    pub const Read: glui32 = 0x02;
    pub const ReadWrite: glui32 = 0x03;
    pub const WriteAppend: glui32 = 0x05;
};

pub const seekmode = struct {
    pub const Start: glui32 = 0;
    pub const Current: glui32 = 1;
    pub const End: glui32 = 2;
};

pub const keycode = struct {
    pub const Unknown: glui32 = 0xffffffff;
    pub const Left: glui32 = 0xfffffffe;
    pub const Right: glui32 = 0xfffffffd;
    pub const Up: glui32 = 0xfffffffc;
    pub const Down: glui32 = 0xfffffffb;
    pub const Return: glui32 = 0xfffffffa;
    pub const Delete: glui32 = 0xfffffff9;
    pub const Escape: glui32 = 0xfffffff8;
    pub const Tab: glui32 = 0xfffffff7;
    pub const PageUp: glui32 = 0xfffffff6;
    pub const PageDown: glui32 = 0xfffffff5;
    pub const Home: glui32 = 0xfffffff4;
    pub const End: glui32 = 0xfffffff3;
};

// ============== Internal Structures ==============

// Dispatch rock type (matches gidispatch_rock_t)
pub const DispatchRock = extern union {
    num: glui32,
    ptr: ?*anyopaque,
};

const WindowData = struct {
    id: glui32,
    rock: glui32,
    win_type: glui32,
    stream: ?*StreamData = null,
    echo_stream: ?*StreamData = null,
    parent: ?*WindowData = null,
    child1: ?*WindowData = null,
    child2: ?*WindowData = null,
    // Input state
    char_request: bool = false,
    line_request: bool = false,
    char_request_uni: bool = false,
    line_request_uni: bool = false,
    line_buffer: ?[*]u8 = null,
    line_buffer_uni: ?[*]glui32 = null,
    line_buflen: glui32 = 0,
    // Retained array rock for line buffer (for dispatch layer copy-back)
    line_buffer_rock: DispatchRock = .{ .num = 0 },
    // Dispatch rock for Glulxe
    dispatch_rock: DispatchRock = .{ .num = 0 },
    // Linked list
    prev: ?*WindowData = null,
    next: ?*WindowData = null,
};

const StreamType = enum { window, memory, file };

const StreamData = struct {
    id: glui32,
    rock: glui32,
    stream_type: StreamType,
    readable: bool,
    writable: bool,
    // Memory stream
    buf: ?[*]u8 = null,
    buf_uni: ?[*]glui32 = null,
    buflen: glui32 = 0,
    bufptr: glui32 = 0,
    is_unicode: bool = false,
    // File stream
    file: ?std.fs.File = null,
    // Associated window
    win: ?*WindowData = null,
    // Statistics
    readcount: glui32 = 0,
    writecount: glui32 = 0,
    // Dispatch rock for Glulxe
    dispatch_rock: DispatchRock = .{ .num = 0 },
    // Linked list
    prev: ?*StreamData = null,
    next: ?*StreamData = null,
};

const FileRefData = struct {
    id: glui32,
    rock: glui32,
    filename: []const u8,
    usage: glui32,
    textmode: bool,
    // Dispatch rock for Glulxe
    dispatch_rock: DispatchRock = .{ .num = 0 },
    prev: ?*FileRefData = null,
    next: ?*FileRefData = null,
};

// ============== Global State ==============

// Use C allocator to avoid conflicts with C code's malloc/free
const allocator = std.heap.c_allocator;

var root_window: ?*WindowData = null;
var window_list: ?*WindowData = null;
var stream_list: ?*StreamData = null;
var current_stream: ?*StreamData = null;
var fileref_list: ?*FileRefData = null;

var window_id_counter: glui32 = 1;
var stream_id_counter: glui32 = 1;
var fileref_id_counter: glui32 = 1;

// Text output buffer (fixed size, simple approach)
var text_buffer: [8192]u8 = undefined;
var text_buffer_len: usize = 0;
var text_buffer_win: ?*WindowData = null;

// Initialization flag and client metrics
var glk_initialized: bool = false;
var client_metrics: struct {
    width: u32 = 80,
    height: u32 = 24,
} = .{};

// ============== RemGlk Protocol Types ==============

// Input event types (client -> interpreter)
const InputEvent = struct {
    type: []const u8,
    gen: u32 = 0,
    window: ?u32 = null,
    value: ?[]const u8 = null,
    metrics: ?Metrics = null,
    partial: ?std.json.Value = null,
};

const Metrics = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    charwidth: ?f64 = null,
    charheight: ?f64 = null,
};

// Output types (interpreter -> client)
const WindowType = enum {
    buffer,
    grid,
    graphics,
    pair,
};

const TextInputType = enum {
    line,
    char,
};

const WindowUpdate = struct {
    id: u32,
    type: WindowType,
    rock: u32 = 0,
    left: f64 = 0,
    top: f64 = 0,
    width: f64,
    height: f64,
    gridwidth: ?u32 = null,
    gridheight: ?u32 = null,
};

const ContentUpdate = struct {
    id: u32,
    clear: ?bool = null,
    text: ?[]const u8 = null,
};

const InputRequest = struct {
    id: u32,
    type: TextInputType,
    gen: ?u32 = null,
    maxlen: ?u32 = null,
    initial: ?[]const u8 = null,
};

const StateUpdate = struct {
    type: []const u8 = "update",
    gen: u32,
    windows: ?[]const WindowUpdate = null,
    content: ?[]const ContentUpdate = null,
    input: ?[]const InputRequest = null,
};

const InitResponse = struct {
    type: []const u8 = "init",
    gen: u32 = 0,
    metrics: ?Metrics = null,
    support: []const []const u8 = &[_][]const u8{ "timer", "hyperlinks", "graphics", "graphicswin" },
};

const ErrorResponse = struct {
    type: []const u8 = "error",
    message: []const u8,
};

// Protocol state
var generation: u32 = 0;
var pending_windows: [16]WindowUpdate = undefined;
var pending_windows_len: usize = 0;
var pending_content: [64]ContentUpdate = undefined;
var pending_content_len: usize = 0;
var pending_input: [8]InputRequest = undefined;
var pending_input_len: usize = 0;

// ============== I/O Helpers ==============

fn writeStdout(data: []const u8) void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, data) catch {};
}

fn readLineFromStdin(buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch return null;
        if (n == 0) return null; // EOF
        if (byte[0] == '\n') return buf[0..i];
        buf[i] = byte[0];
        i += 1;
    }
    return buf[0..i];
}

// ============== JSON Protocol ==============

fn writeJson(value: anytype) void {
    var buf: [16384]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(value, .{})}) catch return;
    writeStdout(slice);
    writeStdout("\n");
}

fn parseInputEvent(json_str: []const u8) ?InputEvent {
    const parsed = std.json.parseFromSlice(InputEvent, allocator, json_str, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    // Copy to avoid lifetime issues
    return InputEvent{
        .type = allocator.dupe(u8, parsed.value.type) catch return null,
        .gen = parsed.value.gen,
        .window = parsed.value.window,
        .value = if (parsed.value.value) |v| allocator.dupe(u8, v) catch null else null,
        .metrics = parsed.value.metrics,
    };
}

fn sendUpdate() void {
    const update = StateUpdate{
        .gen = generation,
        .windows = if (pending_windows_len > 0) pending_windows[0..pending_windows_len] else null,
        .content = if (pending_content_len > 0) pending_content[0..pending_content_len] else null,
        .input = if (pending_input_len > 0) pending_input[0..pending_input_len] else null,
    };
    writeJson(update);

    pending_windows_len = 0;
    pending_content_len = 0;
    pending_input_len = 0;
    generation += 1;
}

fn sendError(message: []const u8) void {
    writeJson(ErrorResponse{ .message = message });
}

fn queueWindowUpdate(win: *WindowData) void {
    if (pending_windows_len >= pending_windows.len) return;
    const wtype: WindowType = switch (win.win_type) {
        wintype.TextBuffer => .buffer,
        wintype.TextGrid => .grid,
        wintype.Graphics => .graphics,
        else => .buffer,
    };
    pending_windows[pending_windows_len] = .{
        .id = win.id,
        .type = wtype,
        .rock = win.rock,
        .width = @floatFromInt(client_metrics.width),
        .height = @floatFromInt(client_metrics.height),
        .gridwidth = if (wtype == .grid) client_metrics.width else null,
        .gridheight = if (wtype == .grid) client_metrics.height else null,
    };
    pending_windows_len += 1;
}

fn queueContentUpdate(win_id: u32, text: ?[]const u8, clear: bool) void {
    if (pending_content_len >= pending_content.len) return;
    pending_content[pending_content_len] = .{
        .id = win_id,
        .clear = if (clear) true else null,
        .text = text,
    };
    pending_content_len += 1;
}

fn queueInputRequest(win_id: u32, input_type: TextInputType) void {
    if (pending_input_len >= pending_input.len) return;
    pending_input[pending_input_len] = .{
        .id = win_id,
        .type = input_type,
        .gen = generation,
    };
    pending_input_len += 1;
}

fn flushTextBuffer() void {
    if (text_buffer_len > 0 and text_buffer_win != null) {
        // Need to copy text since we're queuing it
        const text_copy = allocator.dupe(u8, text_buffer[0..text_buffer_len]) catch return;
        queueContentUpdate(text_buffer_win.?.id, text_copy, false);
        text_buffer_len = 0;
    }
}

fn ensureGlkInitialized() void {
    if (!glk_initialized) {
        glk_initialized = true;

        // Wait for client's init message
        var buf: [4096]u8 = undefined;
        const line = readLineFromStdin(&buf) orelse {
            sendError("No init message received");
            return;
        };

        // Parse the init event
        if (parseInputEvent(line)) |event| {
            if (std.mem.eql(u8, event.type, "init")) {
                if (event.metrics) |m| {
                    if (m.width) |w| client_metrics.width = w;
                    if (m.height) |h| client_metrics.height = h;
                }
            }
            // Free the type string we allocated
            allocator.free(event.type);
            if (event.value) |v| allocator.free(v);
        }

        // Send our init response
        writeJson(InitResponse{});
    }
}

// ============== Core Functions ==============

export fn glk_exit() callconv(.c) noreturn {
    flushTextBuffer();
    if (pending_content.len > 0 or pending_windows.len > 0) {
        sendUpdate();
    }
    std.process.exit(0);
}

export fn glk_set_interrupt_handler(_: ?*const fn () callconv(.c) void) callconv(.c) void {
    // WASI doesn't support interrupts
}

export fn glk_tick() callconv(.c) void {
    // No-op for WASI
}

export fn glk_gestalt(sel: glui32, val: glui32) callconv(.c) glui32 {
    return glk_gestalt_ext(sel, val, null, 0);
}

export fn glk_gestalt_ext(sel: glui32, val: glui32, arr: ?[*]glui32, arrlen: glui32) callconv(.c) glui32 {
    switch (sel) {
        gestalt.Version => return 0x00000706, // 0.7.6
        gestalt.CharInput => {
            if (val <= 0x7F or (val >= 0xA0 and val <= 0xFF)) return 1;
            if (val >= 0xffffffff - 28) return 1; // Special keys
            return 0;
        },
        gestalt.LineInput => {
            if (val <= 0x7F or (val >= 0xA0 and val <= 0xFF)) return 1;
            return 0;
        },
        gestalt.CharOutput => {
            if (val <= 0x7F or (val >= 0xA0 and val <= 0xFF)) {
                if (arr != null and arrlen >= 1) arr.?[0] = 1;
                return gestalt.CharOutput_ExactPrint;
            }
            if (arr != null and arrlen >= 1) arr.?[0] = 0;
            return gestalt.CharOutput_CannotPrint;
        },
        gestalt.Unicode, gestalt.UnicodeNorm => return 1,
        gestalt.Timer => return 0,
        gestalt.Graphics, gestalt.DrawImage, gestalt.GraphicsTransparency, gestalt.GraphicsCharInput => return 0,
        gestalt.Sound, gestalt.SoundVolume, gestalt.SoundNotify, gestalt.SoundMusic, gestalt.Sound2 => return 0,
        gestalt.Hyperlinks, gestalt.HyperlinkInput => return 1,
        gestalt.MouseInput => return 0,
        gestalt.DateTime => return 1,
        gestalt.LineInputEcho, gestalt.LineTerminators => return 1,
        gestalt.LineTerminatorKey => return 0,
        gestalt.ResourceStream => return 1,
        else => return 0,
    }
}

export fn glk_char_to_lower(ch: u8) callconv(.c) u8 {
    return std.ascii.toLower(ch);
}

export fn glk_char_to_upper(ch: u8) callconv(.c) u8 {
    return std.ascii.toUpper(ch);
}

// ============== Window Functions ==============

fn createWindowStream(win: *WindowData) ?*StreamData {
    const stream = allocator.create(StreamData) catch return null;
    stream.* = StreamData{
        .id = stream_id_counter,
        .rock = 0,
        .stream_type = .window,
        .readable = false,
        .writable = true,
        .win = win,
    };
    stream_id_counter += 1;

    // Add to list
    stream.next = stream_list;
    if (stream_list) |list| list.prev = stream;
    stream_list = stream;

    // Register with dispatch system
    if (object_register_fn) |register_fn| {
        stream.dispatch_rock = register_fn(@ptrCast(stream), gidisp_Class_Stream);
    }

    return stream;
}

export fn glk_window_get_root() callconv(.c) winid_t {
    return @ptrCast(root_window);
}

export fn glk_window_open(split: winid_t, method: glui32, size: glui32, win_type: glui32, rock: glui32) callconv(.c) winid_t {
    _ = split;
    _ = method;
    _ = size;


    // Output init message on first window open
    ensureGlkInitialized();

    const win = allocator.create(WindowData) catch return null;
    win.* = WindowData{
        .id = window_id_counter,
        .rock = rock,
        .win_type = win_type,
    };
    window_id_counter += 1;

    // Add to list
    win.next = window_list;
    if (window_list) |list| list.prev = win;
    window_list = win;

    // Create window stream
    win.stream = createWindowStream(win);

    if (root_window == null) {
        root_window = win;
        // Set the first window's stream as current by default
        current_stream = win.stream;
    }

    // Register with dispatch system
    if (object_register_fn) |register_fn| {
        win.dispatch_rock = register_fn(@ptrCast(win), gidisp_Class_Window);
    }

    // Queue window creation update
    queueWindowUpdate(win);
    sendUpdate();

    return @ptrCast(win);
}

export fn glk_window_close(win_opaque: winid_t, result: ?*stream_result_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    const w = win.?;

    if (result) |r| {
        if (w.stream) |s| {
            r.readcount = s.readcount;
            r.writecount = s.writecount;
        } else {
            r.readcount = 0;
            r.writecount = 0;
        }
    }

    // Close associated stream
    if (w.stream) |s| {
        s.win = null;
        glk_stream_close(@ptrCast(s), null);
        w.stream = null;
    }

    // Unregister from dispatch system
    if (object_unregister_fn) |unregister_fn| {
        unregister_fn(@ptrCast(w), gidisp_Class_Window, w.dispatch_rock);
    }

    // Remove from list
    if (w.prev) |p| p.next = w.next else window_list = w.next;
    if (w.next) |n| n.prev = w.prev;

    if (root_window == w) root_window = null;

    allocator.destroy(w);
}

export fn glk_window_get_size(win_opaque: winid_t, widthptr: ?*glui32, heightptr: ?*glui32) callconv(.c) void {
    _ = win_opaque;
    if (widthptr) |w| w.* = 80;
    if (heightptr) |h| h.* = 24;
}

export fn glk_window_set_arrangement(win: winid_t, method: glui32, size: glui32, keywin: winid_t) callconv(.c) void {
    _ = win;
    _ = method;
    _ = size;
    _ = keywin;
}

export fn glk_window_get_arrangement(win: winid_t, methodptr: ?*glui32, sizeptr: ?*glui32, keywinptr: ?*winid_t) callconv(.c) void {
    _ = win;
    if (methodptr) |m| m.* = 0;
    if (sizeptr) |s| s.* = 0;
    if (keywinptr) |k| k.* = null;
}

export fn glk_window_iterate(win_opaque: winid_t, rockptr: ?*glui32) callconv(.c) winid_t {
    var win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) {
        win = window_list;
    } else {
        win = win.?.next;
    }

    if (win) |w| {
        if (rockptr) |r| r.* = w.rock;
    }
    return @ptrCast(win);
}

export fn glk_window_get_rock(win_opaque: winid_t) callconv(.c) glui32 {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win) |w| return w.rock;
    return 0;
}

export fn glk_window_get_type(win_opaque: winid_t) callconv(.c) glui32 {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win) |w| return w.win_type;
    return 0;
}

export fn glk_window_get_parent(win_opaque: winid_t) callconv(.c) winid_t {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win) |w| return @ptrCast(w.parent);
    return null;
}

export fn glk_window_get_sibling(win_opaque: winid_t) callconv(.c) winid_t {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win) |w| {
        if (w.parent) |p| {
            if (p.child1 == w) return @ptrCast(p.child2);
            return @ptrCast(p.child1);
        }
    }
    return null;
}

export fn glk_window_clear(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    flushTextBuffer();
    queueContentUpdate(win.?.id, null, true);
    sendUpdate();
}

export fn glk_window_move_cursor(win: winid_t, xpos: glui32, ypos: glui32) callconv(.c) void {
    _ = win;
    _ = xpos;
    _ = ypos;
}

export fn glk_window_get_stream(win_opaque: winid_t) callconv(.c) strid_t {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win) |w| return @ptrCast(w.stream);
    return null;
}

export fn glk_window_set_echo_stream(win_opaque: winid_t, str_opaque: strid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (win) |w| w.echo_stream = str;
}

export fn glk_window_get_echo_stream(win_opaque: winid_t) callconv(.c) strid_t {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win) |w| return @ptrCast(w.echo_stream);
    return null;
}

export fn glk_set_window(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win) |w| {
        current_stream = w.stream;
    } else {
        current_stream = null;
    }
}

// ============== Stream Functions ==============

export fn glk_stream_open_file(fref_opaque: frefid_t, fmode: glui32, rock: glui32) callconv(.c) strid_t {
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
                .id = stream_id_counter,
                .rock = rock,
                .stream_type = .file,
                .readable = readable,
                .writable = writable,
                .file = new_file,
            };
            stream_id_counter += 1;

            stream.next = stream_list;
            if (stream_list) |list| list.prev = stream;
            stream_list = stream;

            // Register with dispatch system
            if (object_register_fn) |register_fn| {
                stream.dispatch_rock = register_fn(@ptrCast(stream), gidisp_Class_Stream);
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
        .id = stream_id_counter,
        .rock = rock,
        .stream_type = .file,
        .readable = readable,
        .writable = writable,
        .file = file,
    };
    stream_id_counter += 1;

    stream.next = stream_list;
    if (stream_list) |list| list.prev = stream;
    stream_list = stream;

    // Register with dispatch system
    if (object_register_fn) |register_fn| {
        stream.dispatch_rock = register_fn(@ptrCast(stream), gidisp_Class_Stream);
    }

    return @ptrCast(stream);
}

export fn glk_stream_open_memory(buf: ?[*]u8, buflen: glui32, fmode: glui32, rock: glui32) callconv(.c) strid_t {
    const readable = (fmode == filemode.Read or fmode == filemode.ReadWrite);
    const writable = (fmode != filemode.Read);

    const stream = allocator.create(StreamData) catch return null;
    stream.* = StreamData{
        .id = stream_id_counter,
        .rock = rock,
        .stream_type = .memory,
        .readable = readable,
        .writable = writable,
        .buf = buf,
        .buflen = buflen,
        .is_unicode = false,
    };
    stream_id_counter += 1;

    stream.next = stream_list;
    if (stream_list) |list| list.prev = stream;
    stream_list = stream;

    // Register with dispatch system
    if (object_register_fn) |register_fn| {
        stream.dispatch_rock = register_fn(@ptrCast(stream), gidisp_Class_Stream);
    }

    return @ptrCast(stream);
}

export fn glk_stream_close(str_opaque: strid_t, result: ?*stream_result_t) callconv(.c) void {
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null) return;
    const s = str.?;

    if (result) |r| {
        r.readcount = s.readcount;
        r.writecount = s.writecount;
    }

    if (s.file) |f| f.close();

    if (current_stream == s) current_stream = null;

    // Unregister from dispatch system
    if (object_unregister_fn) |unregister_fn| {
        unregister_fn(@ptrCast(s), gidisp_Class_Stream, s.dispatch_rock);
    }

    // Remove from list
    if (s.prev) |p| p.next = s.next else stream_list = s.next;
    if (s.next) |n| n.prev = s.prev;

    allocator.destroy(s);
}

export fn glk_stream_iterate(str_opaque: strid_t, rockptr: ?*glui32) callconv(.c) strid_t {
    var str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str == null) {
        str = stream_list;
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
    current_stream = @ptrCast(@alignCast(str_opaque));
}

export fn glk_stream_get_current() callconv(.c) strid_t {
    return @ptrCast(current_stream);
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
                if (text_buffer_win != w) {
                    flushTextBuffer();
                    text_buffer_win = w;
                }
                if (text_buffer_len < text_buffer.len) {
                    text_buffer[text_buffer_len] = ch;
                    text_buffer_len += 1;
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

export fn glk_put_char(ch: u8) callconv(.c) void {
    putCharToStream(current_stream, ch);
}

export fn glk_put_char_stream(str_opaque: strid_t, ch: u8) callconv(.c) void {
    putCharToStream(@ptrCast(@alignCast(str_opaque)), ch);
}

export fn glk_put_string(s: ?[*:0]const u8) callconv(.c) void {
    glk_put_string_stream(@ptrCast(current_stream), s);
}

export fn glk_put_string_stream(str_opaque: strid_t, s: ?[*:0]const u8) callconv(.c) void {
    const s_ptr = s orelse return;
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    for (std.mem.span(s_ptr)) |ch| {
        putCharToStream(str, ch);
    }
}

export fn glk_put_buffer(buf: ?[*]const u8, len: glui32) callconv(.c) void {
    glk_put_buffer_stream(@ptrCast(current_stream), buf, len);
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

export fn glk_get_char_stream(str_opaque: strid_t) callconv(.c) glsi32 {
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

// ============== File Reference Functions ==============

export fn glk_fileref_create_temp(usage: glui32, rock: glui32) callconv(.c) frefid_t {
    var buf: [64]u8 = undefined;
    const filename = std.fmt.bufPrint(&buf, "/tmp/glktmp_{d}", .{fileref_id_counter}) catch return null;

    const fref = allocator.create(FileRefData) catch return null;
    const filename_copy = allocator.dupe(u8, filename) catch {
        allocator.destroy(fref);
        return null;
    };

    fref.* = FileRefData{
        .id = fileref_id_counter,
        .rock = rock,
        .filename = filename_copy,
        .usage = usage,
        .textmode = (usage & fileusage.TextMode) != 0,
    };
    fileref_id_counter += 1;

    fref.next = fileref_list;
    if (fileref_list) |list| list.prev = fref;
    fileref_list = fref;

    // Register with dispatch system
    if (object_register_fn) |register_fn| {
        fref.dispatch_rock = register_fn(@ptrCast(fref), gidisp_Class_Fileref);
    }

    return @ptrCast(fref);
}

export fn glk_fileref_create_by_name(usage: glui32, name: ?[*:0]const u8, rock: glui32) callconv(.c) frefid_t {
    const name_ptr = name orelse return null;
    const name_span = std.mem.span(name_ptr);
    const filename_copy = allocator.dupe(u8, name_span) catch return null;

    const fref = allocator.create(FileRefData) catch {
        allocator.free(filename_copy);
        return null;
    };

    fref.* = FileRefData{
        .id = fileref_id_counter,
        .rock = rock,
        .filename = filename_copy,
        .usage = usage,
        .textmode = (usage & fileusage.TextMode) != 0,
    };
    fileref_id_counter += 1;

    fref.next = fileref_list;
    if (fileref_list) |list| list.prev = fref;
    fileref_list = fref;

    // Register with dispatch system
    if (object_register_fn) |register_fn| {
        fref.dispatch_rock = register_fn(@ptrCast(fref), gidisp_Class_Fileref);
    }

    return @ptrCast(fref);
}

export fn glk_fileref_create_by_prompt(usage: glui32, fmode: glui32, rock: glui32) callconv(.c) frefid_t {
    _ = usage;
    _ = fmode;
    _ = rock;
    // TODO: Implement using RemGlk specialinput protocol
    // For now, return null (file operations not supported via prompt)
    return null;
}

export fn glk_fileref_create_from_fileref(usage: glui32, fref_opaque: frefid_t, rock: glui32) callconv(.c) frefid_t {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return null;
    return glk_fileref_create_by_name(usage, @ptrCast(fref.?.filename.ptr), rock);
}

export fn glk_fileref_destroy(fref_opaque: frefid_t) callconv(.c) void {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return;
    const f = fref.?;

    // Unregister from dispatch system
    if (object_unregister_fn) |unregister_fn| {
        unregister_fn(@ptrCast(f), gidisp_Class_Fileref, f.dispatch_rock);
    }

    // Remove from list
    if (f.prev) |p| p.next = f.next else fileref_list = f.next;
    if (f.next) |n| n.prev = f.prev;

    allocator.free(f.filename);
    allocator.destroy(f);
}

export fn glk_fileref_iterate(fref_opaque: frefid_t, rockptr: ?*glui32) callconv(.c) frefid_t {
    var fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) {
        fref = fileref_list;
    } else {
        fref = fref.?.next;
    }

    if (fref) |f| {
        if (rockptr) |r| r.* = f.rock;
    }
    return @ptrCast(fref);
}

export fn glk_fileref_get_rock(fref_opaque: frefid_t) callconv(.c) glui32 {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref) |f| return f.rock;
    return 0;
}

export fn glk_fileref_delete_file(fref_opaque: frefid_t) callconv(.c) void {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return;
    std.fs.cwd().deleteFile(fref.?.filename) catch return;
}

export fn glk_fileref_does_file_exist(fref_opaque: frefid_t) callconv(.c) glui32 {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return 0;
    _ = std.fs.cwd().statFile(fref.?.filename) catch return 0;
    return 1;
}

// ============== Event Functions ==============

export fn glk_select(event: ?*event_t) callconv(.c) void {
    if (event == null) return;

    // Flush text buffer before waiting for input
    flushTextBuffer();

    event.?.type = evtype.None;
    event.?.win = null;
    event.?.val1 = 0;
    event.?.val2 = 0;

    // Find window with input request
    var win = window_list;
    while (win) |w| : (win = w.next) {
        if (w.char_request or w.line_request or w.char_request_uni or w.line_request_uni) {
            break;
        }
    }

    if (win == null) return;
    const w = win.?;

    // Queue input request and send update
    const input_type: TextInputType = if (w.line_request or w.line_request_uni) .line else .char;
    queueInputRequest(w.id, input_type);
    sendUpdate();

    // Read JSON input from stdin
    var json_buf: [4096]u8 = undefined;
    const json_line = readLineFromStdin(&json_buf) orelse {
        glk_exit();
    };

    // Parse the input event
    const input_event = parseInputEvent(json_line) orelse {
        return;
    };
    defer {
        allocator.free(input_event.type);
        if (input_event.value) |v| allocator.free(v);
    }

    const input_value = input_event.value orelse return;

    if (w.line_request) {
        if (w.line_buffer) |lb| {
            // Ensure we don't underflow if buflen is 0, leave room for null
            const max_copy = if (w.line_buflen > 1) w.line_buflen - 1 else 0;
            const copy_len: glui32 = @intCast(@min(input_value.len, max_copy));
            if (copy_len > 0) {
                @memcpy(lb[0..copy_len], input_value[0..copy_len]);
            }
            // Add null terminator for compatibility (even though Glk spec says not to)
            if (copy_len < w.line_buflen) {
                lb[copy_len] = 0;
            }

            event.?.type = evtype.LineInput;
            event.?.win = @ptrCast(w);
            event.?.val1 = copy_len;

            // Unregister the buffer so Glulxe copies data back to VM memory
            if (retained_unregister_fn) |unregister_fn| {
                // Typecode for char array with passout: "&+#!Cn"
                var typecode = "&+#!Cn".*;
                unregister_fn(@ptrCast(lb), w.line_buflen, &typecode, w.line_buffer_rock);
            }
        }
        w.line_request = false;
        w.line_buffer = null;
        w.line_buffer_rock = .{ .num = 0 };
    } else if (w.char_request) {
        event.?.type = evtype.CharInput;
        event.?.win = @ptrCast(w);
        event.?.val1 = if (input_value.len > 0) input_value[0] else keycode.Return;
        w.char_request = false;
    }
}

export fn glk_select_poll(event: ?*event_t) callconv(.c) void {
    if (event == null) return;
    event.?.type = evtype.None;
    event.?.win = null;
    event.?.val1 = 0;
    event.?.val2 = 0;
}

export fn glk_request_timer_events(millisecs: glui32) callconv(.c) void {
    _ = millisecs;
}

export fn glk_request_line_event(win_opaque: winid_t, buf: ?[*]u8, maxlen: glui32, initlen: glui32) callconv(.c) void {
    _ = initlen;
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;

    win.?.line_request = true;
    win.?.line_buffer = buf;
    win.?.line_buflen = maxlen;

    // Register the buffer with the retained registry so it gets copied back
    if (retained_register_fn) |register_fn| {
        // Typecode "&+#!Cn" = reference, passout, array, retained, char
        var typecode = "&+#!Cn".*;
        win.?.line_buffer_rock = register_fn(@ptrCast(buf), maxlen, &typecode);
    }
}

export fn glk_request_char_event(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.char_request = true;
}

export fn glk_request_mouse_event(win: winid_t) callconv(.c) void {
    _ = win;
}

export fn glk_cancel_line_event(win_opaque: winid_t, event: ?*event_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;

    if (event) |e| {
        e.type = evtype.None;
        e.win = null;
        e.val1 = 0;
        e.val2 = 0;
    }

    win.?.line_request = false;
    win.?.line_buffer = null;
}

export fn glk_cancel_char_event(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.char_request = false;
}

export fn glk_cancel_mouse_event(win: winid_t) callconv(.c) void {
    _ = win;
}

// ============== Style Hints ==============

export fn glk_stylehint_set(wintype_val: glui32, styl: glui32, hint: glui32, val: glsi32) callconv(.c) void {
    _ = wintype_val;
    _ = styl;
    _ = hint;
    _ = val;
}

export fn glk_stylehint_clear(wintype_val: glui32, styl: glui32, hint: glui32) callconv(.c) void {
    _ = wintype_val;
    _ = styl;
    _ = hint;
}

export fn glk_style_distinguish(win: winid_t, styl1: glui32, styl2: glui32) callconv(.c) glui32 {
    _ = win;
    return if (styl1 != styl2) 1 else 0;
}

export fn glk_style_measure(win: winid_t, styl: glui32, hint: glui32, result: ?*glui32) callconv(.c) glui32 {
    _ = win;
    _ = styl;
    _ = hint;
    if (result) |r| r.* = 0;
    return 0;
}

// ============== Optional Modules ==============

export fn glk_set_echo_line_event(win: winid_t, val: glui32) callconv(.c) void {
    _ = win;
    _ = val;
}

export fn glk_set_terminators_line_event(win: winid_t, keycodes_ptr: ?[*]glui32, count: glui32) callconv(.c) void {
    _ = win;
    _ = keycodes_ptr;
    _ = count;
}

// Unicode support
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

export fn glk_put_char_uni(ch: glui32) callconv(.c) void {
    if (ch < 0x80) {
        glk_put_char(@intCast(ch));
    } else {
        // UTF-8 encode
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(ch), &utf8_buf) catch return;
        for (utf8_buf[0..len]) |b| {
            glk_put_char(b);
        }
    }
}

export fn glk_put_string_uni(s: ?[*:0]const glui32) callconv(.c) void {
    const s_ptr = s orelse return;
    var ptr = s_ptr;
    while (ptr[0] != 0) : (ptr += 1) {
        glk_put_char_uni(ptr[0]);
    }
}

export fn glk_put_buffer_uni(buf: ?[*]const glui32, len: glui32) callconv(.c) void {
    const buf_ptr = buf orelse return;
    for (buf_ptr[0..len]) |ch| {
        glk_put_char_uni(ch);
    }
}

export fn glk_put_char_stream_uni(str: strid_t, ch: glui32) callconv(.c) void {
    const save = current_stream;
    current_stream = @ptrCast(@alignCast(str));
    glk_put_char_uni(ch);
    current_stream = save;
}

export fn glk_put_string_stream_uni(str: strid_t, s: ?[*:0]const glui32) callconv(.c) void {
    const save = current_stream;
    current_stream = @ptrCast(@alignCast(str));
    glk_put_string_uni(s);
    current_stream = save;
}

export fn glk_put_buffer_stream_uni(str: strid_t, buf: ?[*]const glui32, len: glui32) callconv(.c) void {
    const save = current_stream;
    current_stream = @ptrCast(@alignCast(str));
    glk_put_buffer_uni(buf, len);
    current_stream = save;
}

export fn glk_get_char_stream_uni(str: strid_t) callconv(.c) glsi32 {
    return glk_get_char_stream(str);
}

export fn glk_get_buffer_stream_uni(str: strid_t, buf: ?[*]glui32, len: glui32) callconv(.c) glui32 {
    const buf_ptr = buf orelse return 0;
    // Simplified - doesn't handle UTF-8 properly
    for (buf_ptr[0..len], 0..) |*slot, i| {
        const ch = glk_get_char_stream(str);
        if (ch < 0) return @intCast(i);
        slot.* = @intCast(ch);
    }
    return len;
}

export fn glk_get_line_stream_uni(str_opaque: strid_t, buf: ?[*]glui32, len: glui32) callconv(.c) glui32 {
    const buf_ptr = buf orelse return 0;
    if (len == 0) return 0;
    for (buf_ptr[0 .. len - 1], 0..) |*slot, i| {
        const ch = glk_get_char_stream(str_opaque);
        if (ch < 0) return @intCast(i);
        slot.* = @intCast(ch);
        if (ch == '\n') return @intCast(i + 1);
    }
    return len - 1;
}

export fn glk_stream_open_file_uni(fref: frefid_t, fmode: glui32, rock: glui32) callconv(.c) strid_t {
    return glk_stream_open_file(fref, fmode, rock);
}

export fn glk_stream_open_memory_uni(buf: ?[*]glui32, buflen: glui32, fmode: glui32, rock: glui32) callconv(.c) strid_t {
    const readable = (fmode == filemode.Read or fmode == filemode.ReadWrite);
    const writable = (fmode != filemode.Read);

    const stream = allocator.create(StreamData) catch return null;
    stream.* = StreamData{
        .id = stream_id_counter,
        .rock = rock,
        .stream_type = .memory,
        .readable = readable,
        .writable = writable,
        .buf_uni = buf,
        .buflen = buflen,
        .is_unicode = true,
    };
    stream_id_counter += 1;

    stream.next = stream_list;
    if (stream_list) |list| list.prev = stream;
    stream_list = stream;

    // Register with dispatch system
    if (object_register_fn) |register_fn| {
        stream.dispatch_rock = register_fn(@ptrCast(stream), gidisp_Class_Stream);
    }

    return @ptrCast(stream);
}

export fn glk_request_char_event_uni(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.char_request_uni = true;
}

export fn glk_request_line_event_uni(win_opaque: winid_t, buf: ?[*]glui32, maxlen: glui32, initlen: glui32) callconv(.c) void {
    _ = initlen;
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.line_request_uni = true;
    win.?.line_buffer_uni = buf;
    win.?.line_buflen = maxlen;
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

// Hyperlinks
export fn glk_set_hyperlink(linkval: glui32) callconv(.c) void {
    _ = linkval;
}

export fn glk_set_hyperlink_stream(str: strid_t, linkval: glui32) callconv(.c) void {
    _ = str;
    _ = linkval;
}

export fn glk_request_hyperlink_event(win: winid_t) callconv(.c) void {
    _ = win;
}

export fn glk_cancel_hyperlink_event(win: winid_t) callconv(.c) void {
    _ = win;
}

// DateTime
const glktimeval_t = extern struct {
    high_sec: glsi32,
    low_sec: glui32,
    microsec: glsi32,
};

const glkdate_t = extern struct {
    year: glsi32,
    month: glsi32,
    day: glsi32,
    weekday: glsi32,
    hour: glsi32,
    minute: glsi32,
    second: glsi32,
    microsec: glsi32,
};

export fn glk_current_time(time: ?*glktimeval_t) callconv(.c) void {
    if (time == null) return;
    const ts = std.time.timestamp();
    time.?.high_sec = @intCast(@as(i64, ts) >> 32);
    time.?.low_sec = @intCast(@as(u64, @bitCast(ts)) & 0xFFFFFFFF);
    time.?.microsec = 0;
}

export fn glk_current_simple_time(factor: glui32) callconv(.c) glsi32 {
    if (factor == 0) return 0;
    const ts = std.time.timestamp();
    return @intCast(@divTrunc(ts, factor));
}

export fn glk_time_to_date_utc(time: ?*const glktimeval_t, date: ?*glkdate_t) callconv(.c) void {
    if (time == null or date == null) return;
    const secs = (@as(i64, time.?.high_sec) << 32) | time.?.low_sec;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    date.?.year = @intCast(year_day.year);
    date.?.month = @intCast(@intFromEnum(month_day.month));
    date.?.day = month_day.day_index + 1;
    // Day of week: epoch day 0 (1970-01-01) was Thursday (4). Calculate modulo 7.
    const day_num: i64 = @intCast(day.day);
    date.?.weekday = @intCast(@mod(day_num + 4, 7)); // Sunday = 0
    date.?.hour = @intCast(day_seconds.getHoursIntoDay());
    date.?.minute = @intCast(day_seconds.getMinutesIntoHour());
    date.?.second = @intCast(day_seconds.getSecondsIntoMinute());
    date.?.microsec = time.?.microsec;
}

export fn glk_time_to_date_local(time: ?*const glktimeval_t, date: ?*glkdate_t) callconv(.c) void {
    // For simplicity, treat local as UTC
    glk_time_to_date_utc(time, date);
}

export fn glk_simple_time_to_date_utc(time: glsi32, factor: glui32, date: ?*glkdate_t) callconv(.c) void {
    var tv: glktimeval_t = undefined;
    tv.high_sec = 0;
    tv.low_sec = @intCast(@as(u32, @bitCast(time)) *% factor);
    tv.microsec = 0;
    glk_time_to_date_utc(&tv, date);
}

export fn glk_simple_time_to_date_local(time: glsi32, factor: glui32, date: ?*glkdate_t) callconv(.c) void {
    glk_simple_time_to_date_utc(time, factor, date);
}

export fn glk_date_to_time_utc(date: ?*const glkdate_t, time: ?*glktimeval_t) callconv(.c) void {
    if (date == null or time == null) return;
    // Simplified calculation
    time.?.high_sec = 0;
    time.?.low_sec = 0;
    time.?.microsec = date.?.microsec;
}

export fn glk_date_to_time_local(date: ?*const glkdate_t, time: ?*glktimeval_t) callconv(.c) void {
    glk_date_to_time_utc(date, time);
}

export fn glk_date_to_simple_time_utc(date: ?*const glkdate_t, factor: glui32) callconv(.c) glsi32 {
    if (date == null or factor == 0) return 0;
    var time: glktimeval_t = undefined;
    glk_date_to_time_utc(date, &time);
    return @intCast(@divTrunc(time.low_sec, factor));
}

export fn glk_date_to_simple_time_local(date: ?*const glkdate_t, factor: glui32) callconv(.c) glsi32 {
    return glk_date_to_simple_time_utc(date, factor);
}

// Resource streams
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

// Image stubs
export fn glk_image_get_info(image: glui32, width: ?*glui32, height: ?*glui32) callconv(.c) glui32 {
    _ = image;
    if (width) |w| w.* = 0;
    if (height) |h| h.* = 0;
    return 0;
}

export fn glk_image_draw(win: winid_t, image: glui32, val1: glsi32, val2: glsi32) callconv(.c) glui32 {
    _ = win;
    _ = image;
    _ = val1;
    _ = val2;
    return 0;
}

export fn glk_image_draw_scaled(win: winid_t, image: glui32, val1: glsi32, val2: glsi32, width: glui32, height: glui32) callconv(.c) glui32 {
    _ = win;
    _ = image;
    _ = val1;
    _ = val2;
    _ = width;
    _ = height;
    return 0;
}

export fn glk_window_flow_break(win: winid_t) callconv(.c) void {
    _ = win;
}

export fn glk_window_erase_rect(win: winid_t, left: glsi32, top: glsi32, width: glui32, height: glui32) callconv(.c) void {
    _ = win;
    _ = left;
    _ = top;
    _ = width;
    _ = height;
}

export fn glk_window_fill_rect(win: winid_t, color: glui32, left: glsi32, top: glsi32, width: glui32, height: glui32) callconv(.c) void {
    _ = win;
    _ = color;
    _ = left;
    _ = top;
    _ = width;
    _ = height;
}

export fn glk_window_set_background_color(win: winid_t, color: glui32) callconv(.c) void {
    _ = win;
    _ = color;
}

// Sound channel stubs
export fn glk_schannel_iterate(chan: schanid_t, rockptr: ?*glui32) callconv(.c) schanid_t {
    _ = chan;
    if (rockptr) |r| r.* = 0;
    return null;
}

export fn glk_schannel_get_rock(chan: schanid_t) callconv(.c) glui32 {
    _ = chan;
    return 0;
}

export fn glk_schannel_create(rock: glui32) callconv(.c) schanid_t {
    _ = rock;
    return null;
}

export fn glk_schannel_create_ext(rock: glui32, volume: glui32) callconv(.c) schanid_t {
    _ = rock;
    _ = volume;
    return null;
}

export fn glk_schannel_destroy(chan: schanid_t) callconv(.c) void {
    _ = chan;
}

export fn glk_schannel_play(chan: schanid_t, snd: glui32) callconv(.c) glui32 {
    _ = chan;
    _ = snd;
    return 0;
}

export fn glk_schannel_play_ext(chan: schanid_t, snd: glui32, repeats: glui32, notify: glui32) callconv(.c) glui32 {
    _ = chan;
    _ = snd;
    _ = repeats;
    _ = notify;
    return 0;
}

export fn glk_schannel_play_multi(chanarray: ?[*]schanid_t, chancount: glui32, sndarray: ?[*]glui32, soundcount: glui32, notify: glui32) callconv(.c) glui32 {
    _ = chanarray;
    _ = chancount;
    _ = sndarray;
    _ = soundcount;
    _ = notify;
    return 0;
}

export fn glk_schannel_stop(chan: schanid_t) callconv(.c) void {
    _ = chan;
}

export fn glk_schannel_set_volume(chan: schanid_t, vol: glui32) callconv(.c) void {
    _ = chan;
    _ = vol;
}

export fn glk_schannel_set_volume_ext(chan: schanid_t, vol: glui32, duration: glui32, notify: glui32) callconv(.c) void {
    _ = chan;
    _ = vol;
    _ = duration;
    _ = notify;
}

export fn glk_schannel_pause(chan: schanid_t) callconv(.c) void {
    _ = chan;
}

export fn glk_schannel_unpause(chan: schanid_t) callconv(.c) void {
    _ = chan;
}

export fn glk_sound_load_hint(snd: glui32, flag: glui32) callconv(.c) void {
    _ = snd;
    _ = flag;
}

// Garglk extensions
export fn garglk_set_zcolors(fg: glui32, bg: glui32) callconv(.c) void {
    _ = fg;
    _ = bg;
}

export fn garglk_set_zcolors_stream(str: strid_t, fg: glui32, bg: glui32) callconv(.c) void {
    _ = str;
    _ = fg;
    _ = bg;
}

export fn garglk_set_reversevideo(reverse: glui32) callconv(.c) void {
    _ = reverse;
}

export fn garglk_set_reversevideo_stream(str: strid_t, reverse: glui32) callconv(.c) void {
    _ = str;
    _ = reverse;
}

// ============== Dispatch Layer ==============

// Object class constants (from Glk spec)
const gidisp_Class_Window: glui32 = 0;
const gidisp_Class_Stream: glui32 = 1;
const gidisp_Class_Fileref: glui32 = 2;
const gidisp_Class_Schannel: glui32 = 3;

// Use DispatchRock as the gidispatch_rock_t type
pub const gidispatch_rock_t = DispatchRock;

// Registry callbacks
var object_register_fn: ?*const fn (?*anyopaque, glui32) callconv(.c) gidispatch_rock_t = null;
var object_unregister_fn: ?*const fn (?*anyopaque, glui32, gidispatch_rock_t) callconv(.c) void = null;
var retained_register_fn: ?*const fn (?*anyopaque, glui32, [*:0]u8) callconv(.c) gidispatch_rock_t = null;
var retained_unregister_fn: ?*const fn (?*anyopaque, glui32, [*:0]u8, gidispatch_rock_t) callconv(.c) void = null;

export fn gidispatch_set_object_registry(
    regi: ?*const fn (?*anyopaque, glui32) callconv(.c) gidispatch_rock_t,
    unregi: ?*const fn (?*anyopaque, glui32, gidispatch_rock_t) callconv(.c) void,
) callconv(.c) void {
    object_register_fn = regi;
    object_unregister_fn = unregi;

    // Register all existing objects
    if (regi) |register_fn| {
        // Register all windows
        var win = window_list;
        while (win) |w| : (win = w.next) {
            w.dispatch_rock = register_fn(@ptrCast(w), gidisp_Class_Window);
        }
        // Register all streams
        var str = stream_list;
        while (str) |s| : (str = s.next) {
            s.dispatch_rock = register_fn(@ptrCast(s), gidisp_Class_Stream);
        }
        // Register all file references
        var fref = fileref_list;
        while (fref) |f| : (fref = f.next) {
            f.dispatch_rock = register_fn(@ptrCast(f), gidisp_Class_Fileref);
        }
    }
}

export fn gidispatch_get_objrock(obj: ?*anyopaque, objclass: glui32) callconv(.c) gidispatch_rock_t {
    if (obj == null) return gidispatch_rock_t{ .num = 0 };

    switch (objclass) {
        gidisp_Class_Window => {
            const win: *WindowData = @ptrCast(@alignCast(obj));
            return win.dispatch_rock;
        },
        gidisp_Class_Stream => {
            const str: *StreamData = @ptrCast(@alignCast(obj));
            return str.dispatch_rock;
        },
        gidisp_Class_Fileref => {
            const fref: *FileRefData = @ptrCast(@alignCast(obj));
            return fref.dispatch_rock;
        },
        else => return gidispatch_rock_t{ .num = 0 },
    }
}

export fn gidispatch_set_retained_registry(
    regi: ?*const fn (?*anyopaque, glui32, [*:0]u8) callconv(.c) gidispatch_rock_t,
    unregi: ?*const fn (?*anyopaque, glui32, [*:0]u8, gidispatch_rock_t) callconv(.c) void,
) callconv(.c) void {
    retained_register_fn = regi;
    retained_unregister_fn = unregi;
}

export fn gidispatch_set_autorestore_registry(
    locatearr: ?*const fn (?*anyopaque, glui32, [*:0]u8, gidispatch_rock_t, *c_int) callconv(.c) c_long,
    restorearr: ?*const fn (c_long, glui32, [*:0]u8, *?*anyopaque) callconv(.c) gidispatch_rock_t,
) callconv(.c) void {
    _ = locatearr;
    _ = restorearr;
}

// Blorb support
pub const giblorb_err_t = glui32;
pub const giblorb_map_t = opaque {};

var blorb_map: ?*giblorb_map_t = null;

// These are provided by gi_blorb.c
extern fn giblorb_create_map(file: strid_t, newmap: *?*giblorb_map_t) callconv(.c) giblorb_err_t;
extern fn giblorb_destroy_map(map: ?*giblorb_map_t) callconv(.c) giblorb_err_t;

export fn giblorb_set_resource_map(file: strid_t) callconv(.c) giblorb_err_t {
    if (blorb_map != null) {
        _ = giblorb_destroy_map(blorb_map);
        blorb_map = null;
    }

    if (file == null) return 0; // giblorb_err_None

    return giblorb_create_map(file, &blorb_map);
}

export fn giblorb_get_resource_map() callconv(.c) ?*giblorb_map_t {
    return blorb_map;
}

// ============== Glkunix Startup ==============

pub const glkunix_argumentlist_t = extern struct {
    name: ?[*:0]const u8,
    argtype: c_int,
    desc: ?[*:0]const u8,
};

pub const glkunix_startup_t = extern struct {
    argc: c_int,
    argv: [*][*:0]u8,
};

// These are defined by the interpreter
extern var glkunix_arguments: [*]glkunix_argumentlist_t;
extern fn glkunix_startup_code(data: *glkunix_startup_t) callconv(.c) c_int;
extern fn glk_main() callconv(.c) void;

var workdir: ?[]const u8 = null;

export fn glkunix_set_base_file(filename: ?[*:0]const u8) callconv(.c) void {
    const filename_ptr = filename orelse return;

    if (workdir) |w| allocator.free(w);

    const path = std.mem.span(filename_ptr);
    workdir = if (std.fs.path.dirname(path)) |dir|
        allocator.dupe(u8, dir) catch null
    else
        allocator.dupe(u8, ".") catch null;
}

export fn glkunix_stream_open_pathname_gen(pathname: ?[*:0]const u8, writemode: glui32, textmode: glui32, rock: glui32) callconv(.c) strid_t {
    if (pathname == null) return null;

    const fref = glk_fileref_create_by_name(
        (if (textmode != 0) fileusage.TextMode else fileusage.BinaryMode) | fileusage.Data,
        pathname,
        0,
    );
    if (fref == null) return null;

    const fmode = if (writemode != 0) filemode.Write else filemode.Read;
    const str = glk_stream_open_file(fref, fmode, rock);
    glk_fileref_destroy(fref);

    return str;
}

export fn glkunix_stream_open_pathname(pathname: ?[*:0]const u8, textmode: glui32, rock: glui32) callconv(.c) strid_t {
    return glkunix_stream_open_pathname_gen(pathname, 0, textmode, rock);
}

// Main entry point for glkunix model - Glk library provides main
fn wasiGlkMain(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    // Output initialization message
    ensureGlkInitialized();

    // Call interpreter's startup code
    var startdata = glkunix_startup_t{
        .argc = argc,
        .argv = argv,
    };

    const startup_result = glkunix_startup_code(&startdata);
    if (startup_result == 0) {
        sendError("Startup failed");
        return 1;
    }

    glk_main();
    glk_exit();
}

comptime {
    @export(&wasiGlkMain, .{ .name = "main", .linkage = .strong });
}
