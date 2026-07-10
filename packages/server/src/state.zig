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
    // Pair window split parameters (only used for pair windows)
    split_method: glui32 = 0, // winmethod_* flags
    split_size: glui32 = 0, // size constraint
    split_key: ?*WindowData = null, // key window for proportional/fixed split
    // Calculated layout position (in pixels, updated by layout calculation)
    layout_left: f64 = 0,
    layout_top: f64 = 0,
    layout_width: f64 = 0,
    layout_height: f64 = 0,
    // Input state
    char_request: bool = false,
    line_request: bool = false,
    char_request_uni: bool = false,
    line_request_uni: bool = false,
    mouse_request: bool = false,
    hyperlink_request: bool = false,
    line_buffer: ?[*]u8 = null,
    line_buffer_uni: ?[*]glui32 = null,
    line_buflen: glui32 = 0,
    line_initlen: glui32 = 0, // Length of pre-filled initial text
    line_partial_len: glui32 = 0, // Length of partial text from interrupted input
    // Line input terminators (keycodes that should terminate line input)
    line_terminators: [16]glui32 = undefined,
    line_terminators_count: glui32 = 0,
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
    // In-memory temp file (memory stream over a temp fileref's growable buffer).
    // Writes past buflen grow the fileref's buffer instead of being dropped.
    temp_fref: ?*FileRefData = null,
    // Retained array rock for memory buffer (for dispatch layer copy-back)
    buf_rock: DispatchRock = .{ .num = 0 },
    // File stream
    file: ?std.fs.File = null,
    textmode: bool = false,
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
    // Temp filerefs are backed by an in-memory buffer, not the sandbox
    // filesystem: scratch data (e.g. Hugo's synthesized Blorb) is ephemeral and
    // the browser WASI sandbox has no writable scratch. The buffer lives on the
    // fileref so it survives the write-stream close → read-stream reopen cycle.
    is_temp: bool = false,
    temp_buf: ?std.ArrayList(u8) = null,
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
pub var text_buffer: [65536]u8 = undefined;
pub var text_buffer_len: usize = 0;
pub var text_buffer_win: ?*WindowData = null;

// Current text style (Glk style constants: 0=Normal, 1=Emphasized, 2=Preformatted, etc.)
pub var current_style: glui32 = 0; // style_Normal

// Current hyperlink value (0 = no hyperlink active)
pub var current_hyperlink: glui32 = 0;

// Initialization flag and client metrics
pub var glk_initialized: bool = false;
// Display metrics from the init `metrics` message. width/height are PIXELS;
// the *char* fields are pixels-per-character (grid = monospace advance/line
// height, buffer = approximate), used to convert text-window pixel sizes to
// character cells. Char dims default to 1.0 so a client that sends neither
// pixels-plus-metrics nor char metrics still behaves as "1 unit = 1 cell".
pub var client_metrics: struct {
    width: u32 = 80,
    height: u32 = 24,
    grid_char_w: f64 = 1.0,
    grid_char_h: f64 = 1.0,
    grid_margin_x: f64 = 0.0,
    grid_margin_y: f64 = 0.0,
    buffer_char_w: f64 = 1.0,
    buffer_char_h: f64 = 1.0,
    buffer_margin_x: f64 = 0.0,
    buffer_margin_y: f64 = 0.0,
} = .{};

// Client capabilities (populated from init message's support array)
pub var client_support: struct {
    timer: bool = false,
    graphics: bool = false,
    graphicswin: bool = false,
    hyperlinks: bool = false,
} = .{};

// Whether the client expects the server to resolve image resources to pixels
// (delivering a `url` data-URI over the wire) rather than resolving image
// numbers itself from its own Blorb copy. The client sets this when it holds no
// client-parseable Blorb for the story: glulx/z-code Blorb games send image
// numbers (client resolves), while Hugo (server-synthesized Blorb) and Scare
// (garglk file resources) have no client-visible Blorb, so the server must
// carry the bytes. Defaults false to preserve the number path.
pub var server_resolves_images: bool = false;

// Timer state (global, not per-window)
pub var timer_interval: ?glui32 = null; // null = no timer, value = interval in milliseconds

// Debug output buffer (for debugoutput field in updates per GlkOte spec)
pub var debug_buffer: [4096]u8 = undefined;
pub var debug_buffer_len: usize = 0;
pub var debug_stream: ?*StreamData = null;

// Working directory for glkunix — the story's directory. Bare relative paths an
// interpreter opens through Glk (companion resources: Hugo's resource file,
// alan3's `.a3r`, TADS files, …) are resolved against this. WASI has no cwd
// syscall and Zig's std.fs ignores wasi-libc's userspace cwd, so we resolve
// paths ourselves. (Interpreters that use libc `fopen` directly are covered
// separately by an actual `chdir` in startup.)
pub var workdir: ?[]const u8 = null;

/// Resolve a filename an interpreter passed to a Glk file operation to the path
/// to actually open. Absolute paths and storage-managed `var/` paths (saves,
/// intercepted by the worker) are used verbatim; other relative names are joined
/// onto `workdir`. Returns a slice into `buf` when it joins, else the input.
pub fn resolvePath(buf: []u8, name: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(name)) return name;
    if (std.mem.startsWith(u8, name, "var/")) return name;
    const dir = workdir orelse return name;
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return name;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch name;
}
