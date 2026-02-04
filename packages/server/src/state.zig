// state.zig - Internal data structures and global state

const std = @import("std");
const types = @import("types.zig");

pub const glui32 = types.glui32;
pub const glsi32 = types.glsi32;
pub const DispatchRock = types.DispatchRock;

// Use C allocator to be compatible with C code's malloc/free
// Note: There's a known issue with free() causing hangs in WASM - see stream.zig glk_stream_close
pub const allocator = std.heap.c_allocator;

// ============== Internal Data Structures ==============

pub const StreamType = enum { window, memory, file };

// Maximum grid window dimensions (in character cells)
pub const MAX_GRID_WIDTH = 256;
pub const MAX_GRID_HEIGHT = 128;

pub const WindowData = struct {
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
    // Grid window state (cursor position and content buffer)
    cursor_x: glui32 = 0,
    cursor_y: glui32 = 0,
    grid_width: glui32 = 80,
    grid_height: glui32 = 24,
    grid_buffer: ?*[MAX_GRID_HEIGHT][MAX_GRID_WIDTH]u8 = null,
    grid_dirty: ?*[MAX_GRID_HEIGHT]bool = null, // Track which lines have been modified
    // Linked list
    prev: ?*WindowData = null,
    next: ?*WindowData = null,
};

pub const StreamData = struct {
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
    // Retained array rock for memory buffer (for dispatch layer copy-back)
    buf_rock: DispatchRock = .{ .num = 0 },
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

pub const FileRefData = struct {
    id: glui32,
    rock: glui32,
    filename: []const u8,
    usage: glui32,
    textmode: bool,
    // Lazily allocated null-terminated copy for C interop (glkunix_fileref_get_filename)
    filename_cstr: ?[*:0]const u8 = null,
    // Dispatch rock for Glulxe
    dispatch_rock: DispatchRock = .{ .num = 0 },
    prev: ?*FileRefData = null,
    next: ?*FileRefData = null,
};

// ============== Global State ==============

pub var root_window: ?*WindowData = null;
pub var window_list: ?*WindowData = null;
pub var stream_list: ?*StreamData = null;
pub var current_stream: ?*StreamData = null;
pub var fileref_list: ?*FileRefData = null;

pub var window_id_counter: glui32 = 1;
pub var stream_id_counter: glui32 = 1;
pub var fileref_id_counter: glui32 = 1;

// Text output buffer (fixed size, simple approach)
pub var text_buffer: [8192]u8 = undefined;
pub var text_buffer_len: usize = 0;
pub var text_buffer_win: ?*WindowData = null;

// Initialization flag and client metrics
pub var glk_initialized: bool = false;
pub var client_metrics: struct {
    width: u32 = 80,
    height: u32 = 24,
} = .{};

// Client capabilities (populated from init message's support array)
pub var client_support: struct {
    timer: bool = false,
    graphics: bool = false,
    graphicswin: bool = false,
    hyperlinks: bool = false,
} = .{};

// Working directory for glkunix
pub var workdir: ?[]const u8 = null;
