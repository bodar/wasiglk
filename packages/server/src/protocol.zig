// protocol.zig - RemGlk JSON protocol implementation

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");

const glui32 = types.glui32;
const glsi32 = types.glsi32;
const wintype = types.wintype;
const WindowData = state.WindowData;
const allocator = state.allocator;

// ============== I/O Helpers ==============

pub fn writeStdout(data: []const u8) void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, data) catch {};
}

pub fn readLineFromStdin(buf: []u8) ?[]u8 {
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

// ============== RemGlk Protocol Types ==============

// Input event types (client -> interpreter)
// Note: The 'value' field can be a string (for line/char input) or a number (for hyperlink events)
// We use std.json.Value to handle both cases, then extract appropriately in parseInputEvent
pub const InputEventRaw = struct {
    type: []const u8,
    gen: u32 = 0,
    window: ?u32 = null,
    value: ?std.json.Value = null, // Can be string (line/char/specialresponse) or integer (hyperlink)
    metrics: ?Metrics = null,
    support: ?[]const []const u8 = null, // Features the display supports
    partial: ?std.json.Value = null,
    // Mouse event coordinates
    x: ?i32 = null,
    y: ?i32 = null,
    // Line input terminator (e.g., "escape", "func1")
    terminator: ?[]const u8 = null,
    // Special response type (e.g., "fileref_prompt")
    response: ?[]const u8 = null,
};

// Processed input event with typed value fields
pub const InputEvent = struct {
    type: []const u8,
    gen: u32 = 0,
    window: ?u32 = null,
    value: ?[]const u8 = null, // String value for line/char input
    linkval: ?u32 = null, // Numeric value for hyperlink events
    metrics: ?Metrics = null,
    // Mouse event coordinates
    x: ?i32 = null,
    y: ?i32 = null,
    // Line input terminator
    terminator: ?[]const u8 = null,
};

pub const Metrics = struct {
    // Overall dimensions
    width: ?u32 = null,
    height: ?u32 = null,
    // Generic character dimensions (deprecated, use grid/buffer-specific)
    charwidth: ?f64 = null,
    charheight: ?f64 = null,
    // Outer/inner spacing
    outspacingx: ?f64 = null,
    outspacingy: ?f64 = null,
    inspacingx: ?f64 = null,
    inspacingy: ?f64 = null,
    // Grid window character dimensions and margins
    gridcharwidth: ?f64 = null,
    gridcharheight: ?f64 = null,
    gridmarginx: ?f64 = null,
    gridmarginy: ?f64 = null,
    // Buffer window character dimensions and margins
    buffercharwidth: ?f64 = null,
    buffercharheight: ?f64 = null,
    buffermarginx: ?f64 = null,
    buffermarginy: ?f64 = null,
    // Graphics window margins
    graphicsmarginx: ?f64 = null,
    graphicsmarginy: ?f64 = null,
};

// ============== Output Types (interpreter -> client) ==============
// These structs match the GlkOte/RemGLK JSON schema for proper serialization

pub const WindowType = enum {
    buffer,
    grid,
    graphics,
    pair,
};

pub const TextInputType = enum {
    line,
    char,
};

// Window update in the windows array
pub const WindowUpdate = struct {
    id: u32,
    type: WindowType,
    rock: u32 = 0,
    left: f64 = 0,
    top: f64 = 0,
    width: f64,
    height: f64,
    // Grid window dimensions (character cells)
    gridwidth: ?u32 = null,
    gridheight: ?u32 = null,
    // Graphics window canvas dimensions (pixels)
    graphwidth: ?u32 = null,
    graphheight: ?u32 = null,
};

// Text span within paragraph content (GlkOte spec)
pub const TextSpan = struct {
    style: []const u8 = "normal",
    text: []const u8,
    hyperlink: ?u32 = null,
};

// Special content span for images in buffer windows
pub const ImageSpan = struct {
    special: []const u8 = "image",
    image: u32,
    alignment: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

// Content span can be text or special (image)
// Using tagged union for proper JSON serialization
pub const ContentSpan = union(enum) {
    text: TextSpan,
    image: ImageSpan,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .text => |t| try jw.write(t),
            .image => |i| try jw.write(i),
        }
    }
};

// Text paragraph in buffer window content (GlkOte spec)
pub const TextParagraph = struct {
    append: ?bool = null,
    flowbreak: ?bool = null,
    content: ?[]const ContentSpan = null,
};

// Grid line in grid window content (GlkOte spec)
pub const GridLine = struct {
    line: u32,
    content: ?[]const ContentSpan = null,
};

// Draw operation for graphics windows (GlkOte spec)
pub const DrawOp = struct {
    special: []const u8, // "fill", "image", "setcolor"
    color: ?[]const u8 = null, // CSS hex color like "#RRGGBB"
    image: ?u32 = null,
    alignment: ?[]const u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

// Content update - can have text (buffer), lines (grid), or draw (graphics)
pub const ContentUpdateJson = struct {
    id: u32,
    clear: ?bool = null,
    text: ?[]const TextParagraph = null, // Buffer windows
    lines: ?[]const GridLine = null, // Grid windows
    draw: ?[]const DrawOp = null, // Graphics windows
};

// Legacy content update (kept for compatibility during refactor)
pub const ContentUpdate = struct {
    id: u32,
    clear: ?bool = null,
    text: ?[]const u8 = null,
};

// Maximum terminators we track per input request
pub const MAX_TERMINATORS = 16;

// Input request (for JSON serialization)
pub const InputRequestJson = struct {
    id: u32,
    type: TextInputType,
    gen: u32,
    initial: ?[]const u8 = null,
    mouse: ?bool = null,
    hyperlink: ?bool = null,
    xpos: ?u32 = null,
    ypos: ?u32 = null,
    terminators: ?[]const []const u8 = null,
};

// Internal input request (with fixed array storage)
pub const InputRequest = struct {
    id: u32,
    type: TextInputType,
    gen: ?u32 = null,
    maxlen: ?u32 = null,
    initial: ?[]const u8 = null,
    mouse: ?bool = null, // true if mouse input is enabled for this window
    hyperlink: ?bool = null, // true if hyperlink input is enabled for this window
    xpos: ?u32 = null, // cursor x position for grid windows
    ypos: ?u32 = null, // cursor y position for grid windows
    // Terminators stored as fixed array with count
    terminators_data: [MAX_TERMINATORS][]const u8 = undefined,
    terminators_count: u32 = 0,

    // Convert to JSON-serializable struct
    pub fn toJson(self: *const InputRequest) InputRequestJson {
        return .{
            .id = self.id,
            .type = self.type,
            .gen = self.gen orelse 0,
            .initial = self.initial,
            .mouse = self.mouse,
            .hyperlink = self.hyperlink,
            .xpos = self.xpos,
            .ypos = self.ypos,
            .terminators = if (self.terminators_count > 0) self.terminators_data[0..self.terminators_count] else null,
        };
    }
};

// Timer value wrapper - allows distinguishing between "not set" and "set to null"
pub const TimerValue = union(enum) {
    interval: u32, // Timer active with this interval
    cancelled: void, // Timer cancelled (serialize as null)

    // Custom JSON formatting
    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        switch (self) {
            .interval => |val| try jw.write(val),
            .cancelled => try jw.write(null),
        }
    }
};

// Special input request for file dialogs (GlkOte spec)
pub const SpecialInput = struct {
    type: []const u8 = "fileref_prompt",
    filemode: []const u8, // "read", "write", "readwrite", "writeappend"
    filetype: []const u8, // "save", "data", "transcript", "command"
    gameid: ?[]const u8 = null, // Optional game ID for filtering saves
};

// Full state update message (GlkOte spec)
pub const StateUpdateJson = struct {
    type: []const u8 = "update",
    gen: u32,
    windows: ?[]const WindowUpdate = null,
    content: ?[]const ContentUpdateJson = null,
    input: ?[]const InputRequestJson = null,
    specialinput: ?SpecialInput = null, // File dialog request (GlkOte spec)
    timer: ?TimerValue = null, // Timer interval or null to cancel (omit if not changed)
    disable: ?bool = null, // true when no input expected
    exit: ?bool = null, // true when game exits
    debugoutput: ?[]const []const u8 = null, // Debug messages
};

const ErrorResponse = struct {
    type: []const u8 = "error",
    message: []const u8,
};

// ============== Protocol State ==============

pub var generation: u32 = 0;
pub var pending_windows: [16]WindowUpdate = undefined;
pub var pending_windows_len: usize = 0;
pub var pending_content: [64]ContentUpdate = undefined;
pub var pending_content_len: usize = 0;
pub var pending_input: [8]InputRequest = undefined;
pub var pending_input_len: usize = 0;
pub var pending_timer: ?glui32 = null; // Timer interval to include in next update
pub var pending_timer_set: bool = false; // Whether timer field should be included
pub var pending_exit: bool = false; // Whether to include exit: true
// Debug output messages (per GlkOte spec: debugoutput array in updates)
pub var pending_debug: [16][256]u8 = undefined;
pub var pending_debug_lens: [16]usize = .{0} ** 16;
pub var pending_debug_count: usize = 0;

// ============== JSON Protocol Functions ==============

fn writeJson(value: anytype) void {
    var buf: [16384]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(value, .{})}) catch return;
    writeStdout(slice);
    writeStdout("\n");
}

pub fn parseInputEvent(json_str: []const u8) ?InputEvent {
    const parsed = std.json.parseFromSlice(InputEventRaw, allocator, json_str, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    // Extract value based on its type:
    // - String: line/char input value
    // - Integer: hyperlink link value
    var string_value: ?[]const u8 = null;
    var link_value: ?u32 = null;

    if (parsed.value.value) |v| {
        switch (v) {
            .string => |s| {
                string_value = allocator.dupe(u8, s) catch null;
            },
            .integer => |i| {
                if (i >= 0 and i <= std.math.maxInt(u32)) {
                    link_value = @intCast(i);
                }
            },
            else => {},
        }
    }

    // Process partial field - copy partial input text to windows' line buffers
    // Partial is an object like {"1": "hello", "2": "world"} where keys are window IDs
    if (parsed.value.partial) |partial_val| {
        if (partial_val == .object) {
            var iter = partial_val.object.iterator();
            while (iter.next()) |entry| {
                // Parse window ID from key
                const win_id = std.fmt.parseInt(u32, entry.key_ptr.*, 10) catch continue;
                // Get partial text value
                const partial_text = if (entry.value_ptr.* == .string)
                    entry.value_ptr.string
                else
                    continue;

                // Find window and copy partial text to its line buffer
                var win = state.window_list;
                while (win) |w| : (win = w.next) {
                    if (w.id == win_id and w.line_request and w.line_buffer != null) {
                        // Copy partial text to line buffer
                        const max_copy = if (w.line_buflen > 0) w.line_buflen - 1 else 0;
                        const copy_len: glui32 = @intCast(@min(partial_text.len, max_copy));
                        if (copy_len > 0) {
                            @memcpy(w.line_buffer.?[0..copy_len], partial_text[0..copy_len]);
                        }
                        // Store partial length for glk_cancel_line_event
                        w.line_partial_len = copy_len;
                        break;
                    }
                }
            }
        }
    }

    // Copy to avoid lifetime issues
    return InputEvent{
        .type = allocator.dupe(u8, parsed.value.type) catch return null,
        .gen = parsed.value.gen,
        .window = parsed.value.window,
        .value = string_value,
        .linkval = link_value,
        .metrics = parsed.value.metrics,
        .x = parsed.value.x,
        .y = parsed.value.y,
        .terminator = if (parsed.value.terminator) |t| allocator.dupe(u8, t) catch null else null,
    };
}

pub fn sendUpdate() void {
    // Build arrays for JSON serialization
    // Input requests - convert to JSON-serializable format
    var input_json: [8]InputRequestJson = undefined;
    for (pending_input[0..pending_input_len], 0..) |req, i| {
        input_json[i] = req.toJson();
    }

    // Content updates - convert legacy content to JSON format
    var content_json: [64]ContentUpdateJson = undefined;
    for (pending_content[0..pending_content_len], 0..) |c, i| {
        // For clear-only updates (no text), use the JSON struct directly
        // For text content, we'd need to build a paragraph structure - but that's
        // only used by flushTextBuffer for non-buffer windows, which is legacy
        content_json[i] = .{
            .id = c.id,
            .clear = c.clear,
            // Legacy text field not supported in struct serialization
            // All text content now goes through sendContentUpdate directly
        };
    }

    // Debug output - collect slices
    var debug_slices: [16][]const u8 = undefined;
    for (0..pending_debug_count) |i| {
        debug_slices[i] = pending_debug[i][0..pending_debug_lens[i]];
    }

    // Build timer value if set
    const timer_val: ?TimerValue = if (pending_timer_set)
        (if (pending_timer) |interval| TimerValue{ .interval = interval } else TimerValue{ .cancelled = {} })
    else
        null;

    // Build the full update struct
    const update = StateUpdateJson{
        .gen = generation,
        .windows = if (pending_windows_len > 0) pending_windows[0..pending_windows_len] else null,
        .content = if (pending_content_len > 0) content_json[0..pending_content_len] else null,
        .input = if (pending_input_len > 0) input_json[0..pending_input_len] else null,
        .timer = timer_val,
        .disable = if (pending_input_len == 0) true else null,
        .exit = if (pending_exit) true else null,
        .debugoutput = if (pending_debug_count > 0) debug_slices[0..pending_debug_count] else null,
    };

    // Serialize with emit_null_optional_fields = false to omit null fields
    var buf: [32768]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(update, .{ .emit_null_optional_fields = false })}) catch return;
    writeStdout(json);
    writeStdout("\n");

    // Reset pending state
    pending_windows_len = 0;
    pending_content_len = 0;
    pending_input_len = 0;
    pending_timer = null;
    pending_timer_set = false;
    pending_exit = false;
    pending_debug_count = 0;
    generation += 1;
}

pub fn sendError(message: []const u8) void {
    writeJson(ErrorResponse{ .message = message });
}

pub fn queueWindowUpdate(win: *WindowData) void {
    if (pending_windows_len >= pending_windows.len) return;
    const wtype: WindowType = switch (win.win_type) {
        wintype.TextBuffer => .buffer,
        wintype.TextGrid => .grid,
        wintype.Graphics => .graphics,
        else => .buffer,
    };

    // Use calculated layout dimensions
    const width = win.layout_width;
    const height = win.layout_height;

    // For grid windows, calculate character cell dimensions
    // Using gridcharwidth/gridcharheight if available, fallback to 1 char = 1 pixel
    const grid_char_w: u32 = 1; // TODO: use actual metrics
    const grid_char_h: u32 = 1;
    const grid_width: u32 = if (width > 0) @intFromFloat(width / @as(f64, @floatFromInt(grid_char_w))) else 80;
    const grid_height: u32 = if (height > 0) @intFromFloat(height / @as(f64, @floatFromInt(grid_char_h))) else 24;

    pending_windows[pending_windows_len] = .{
        .id = win.id,
        .type = wtype,
        .rock = win.rock,
        .left = win.layout_left,
        .top = win.layout_top,
        .width = width,
        .height = height,
        // Grid windows: dimensions in character cells
        .gridwidth = if (wtype == .grid) grid_width else null,
        .gridheight = if (wtype == .grid) grid_height else null,
        // Graphics windows: canvas dimensions in pixels
        .graphwidth = if (wtype == .graphics) @as(u32, @intFromFloat(width)) else null,
        .graphheight = if (wtype == .graphics) @as(u32, @intFromFloat(height)) else null,
    };
    pending_windows_len += 1;
}

pub fn queueContentUpdate(win_id: u32, text: ?[]const u8, clear: bool) void {
    if (pending_content_len >= pending_content.len) return;
    pending_content[pending_content_len] = .{
        .id = win_id,
        .clear = if (clear) true else null,
        .text = text,
    };
    pending_content_len += 1;
}

pub fn queueInputRequest(win_id: u32, input_type: TextInputType, mouse: bool, hyperlink: bool, xpos: ?u32, ypos: ?u32, initial: ?[]const u8, terminators: ?[]const glui32) void {
    if (pending_input_len >= pending_input.len) return;
    var req = InputRequest{
        .id = win_id,
        .type = input_type,
        .gen = generation,
        .mouse = if (mouse) true else null,
        .hyperlink = if (hyperlink) true else null,
        .xpos = xpos,
        .ypos = ypos,
        .initial = initial,
    };

    // Convert keycodes to terminator strings
    if (terminators) |terms| {
        var count: u32 = 0;
        for (terms) |kc| {
            if (count >= MAX_TERMINATORS) break;
            if (keycodeToTerminator(kc)) |term_str| {
                req.terminators_data[count] = term_str;
                count += 1;
            }
        }
        req.terminators_count = count;
    }

    pending_input[pending_input_len] = req;
    pending_input_len += 1;
}

pub fn queueTimer(interval: ?glui32) void {
    pending_timer = interval;
    pending_timer_set = true;
}

pub fn queueExit() void {
    pending_exit = true;
}

// Queue a debug message to be included in the next update (per GlkOte spec)
pub fn queueDebugMessage(message: []const u8) void {
    if (pending_debug_count >= pending_debug.len) return;
    const copy_len = @min(message.len, pending_debug[pending_debug_count].len - 1);
    @memcpy(pending_debug[pending_debug_count][0..copy_len], message[0..copy_len]);
    pending_debug_lens[pending_debug_count] = copy_len;
    pending_debug_count += 1;
}

// ============== Special Update Functions ==============

// Convert keycode to terminator string name per GlkOte spec
pub fn keycodeToTerminator(kc: glui32) ?[]const u8 {
    const keycode = types.keycode;
    return switch (kc) {
        keycode.Escape => "escape",
        keycode.Func1 => "func1",
        keycode.Func2 => "func2",
        keycode.Func3 => "func3",
        keycode.Func4 => "func4",
        keycode.Func5 => "func5",
        keycode.Func6 => "func6",
        keycode.Func7 => "func7",
        keycode.Func8 => "func8",
        keycode.Func9 => "func9",
        keycode.Func10 => "func10",
        keycode.Func11 => "func11",
        keycode.Func12 => "func12",
        else => null,
    };
}

// Alignment value to string mapping per GlkOte spec
fn alignmentToString(alignment: glsi32) []const u8 {
    return switch (alignment) {
        1 => "inlineup",
        2 => "inlinedown",
        3 => "inlinecenter",
        4 => "marginleft",
        5 => "marginright",
        else => "inlineup",
    };
}

// Helper to send a simple update with a single content entry
fn sendContentUpdate(content: ContentUpdateJson) void {
    const contents = [_]ContentUpdateJson{content};
    const update = StateUpdateJson{
        .gen = generation,
        .content = &contents,
        .disable = true, // Content-only updates don't expect input
    };
    var buf: [32768]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(update, .{ .emit_null_optional_fields = false })}) catch return;
    writeStdout(json);
    writeStdout("\n");
    generation += 1;
}

// Glk style number to GlkOte style name mapping
fn styleToString(style: glui32) []const u8 {
    return switch (style) {
        0 => "normal",
        1 => "emphasized",
        2 => "preformatted",
        3 => "header",
        4 => "subheader",
        5 => "alert",
        6 => "note",
        7 => "blockquote",
        8 => "input",
        9 => "user1",
        10 => "user2",
        else => "normal",
    };
}

// Send an image content update for buffer windows using paragraph format per GlkOte spec
pub fn sendImageUpdate(win_id: u32, image: glui32, alignment: glsi32, img_width: glui32, img_height: glui32) void {
    // Flush any pending updates first
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    const alignment_str = alignmentToString(alignment);
    const content = [_]ContentSpan{.{ .image = .{
        .image = image,
        .alignment = alignment_str,
        .width = img_width,
        .height = img_height,
    } }};
    const paragraphs = [_]TextParagraph{.{ .append = true, .content = &content }};
    sendContentUpdate(.{ .id = win_id, .text = &paragraphs });
}

// Send a graphics window image update (includes x, y position)
// Uses "draw" array with "special" as string value per GlkOte spec
pub fn sendGraphicsImageUpdate(win_id: u32, image: glui32, x: glsi32, y: glsi32, img_width: glui32, img_height: glui32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    const draw_ops = [_]DrawOp{.{
        .special = "image",
        .image = image,
        .x = x,
        .y = y,
        .width = img_width,
        .height = img_height,
    }};
    sendContentUpdate(.{ .id = win_id, .draw = &draw_ops });
}

pub fn sendFlowBreakUpdate(win_id: u32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    // Use paragraph format with flowbreak flag per GlkOte spec
    const paragraphs = [_]TextParagraph{.{ .flowbreak = true }};
    sendContentUpdate(.{ .id = win_id, .text = &paragraphs });
}

// Helper to format a color integer as CSS hex string "#RRGGBB"
fn formatColorHex(buf: []u8, color: glui32) []const u8 {
    const r: u8 = @truncate((color >> 16) & 0xFF);
    const g: u8 = @truncate((color >> 8) & 0xFF);
    const b: u8 = @truncate(color & 0xFF);
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch "#000000";
}

pub fn sendGraphicsFillUpdate(win_id: u32, color: glui32, x: glsi32, y: glsi32, width: glui32, height: glui32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    // Format color as CSS hex string
    var color_buf: [8]u8 = undefined;
    const color_str = formatColorHex(&color_buf, color);

    const draw_ops = [_]DrawOp{.{
        .special = "fill",
        .color = color_str,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    }};
    sendContentUpdate(.{ .id = win_id, .draw = &draw_ops });
}

pub fn sendGraphicsEraseUpdate(win_id: u32, x: glsi32, y: glsi32, width: glui32, height: glui32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    const draw_ops = [_]DrawOp{.{
        .special = "fill",
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    }};
    sendContentUpdate(.{ .id = win_id, .draw = &draw_ops });
}

pub fn sendGraphicsSetColorUpdate(win_id: u32, color: glui32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    // Format color as CSS hex string
    var color_buf: [8]u8 = undefined;
    const color_str = formatColorHex(&color_buf, color);

    const draw_ops = [_]DrawOp{.{
        .special = "setcolor",
        .color = color_str,
    }};
    sendContentUpdate(.{ .id = win_id, .draw = &draw_ops });
}

// ============== Text Buffer Management ==============

pub fn flushTextBuffer() void {
    if (state.text_buffer_len > 0 and state.text_buffer_win != null) {
        const win = state.text_buffer_win.?;
        const win_type = win.win_type;

        // For buffer windows, we need to use the paragraph format per GlkOte spec
        if (win_type == wintype.TextBuffer) {
            sendBufferTextUpdate(win.id, state.text_buffer[0..state.text_buffer_len], false);
        } else {
            // For other window types, queue normally for now
            const text_copy = allocator.dupe(u8, state.text_buffer[0..state.text_buffer_len]) catch return;
            queueContentUpdate(win.id, text_copy, false);
        }
        state.text_buffer_len = 0;
    }
}

// Flush dirty grid lines for all grid windows
pub fn flushGridWindows() void {
    var win = state.window_list;
    while (win) |w| : (win = w.next) {
        if (w.win_type == wintype.TextGrid) {
            flushGridWindow(w);
        }
    }
}

// Flush dirty lines for a single grid window
fn flushGridWindow(win: *state.WindowData) void {
    const grid_buf = win.grid_buffer orelse return;
    const dirty = win.grid_dirty orelse return;

    // Count dirty lines
    var dirty_count: usize = 0;
    for (0..win.grid_height) |i| {
        if (dirty[i]) dirty_count += 1;
    }
    if (dirty_count == 0) return;

    // Flush any pending updates first
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    // Build grid lines array - we need fixed-size arrays for struct serialization
    // Max 128 lines per state.MAX_GRID_HEIGHT
    var grid_lines: [state.MAX_GRID_HEIGHT]GridLine = undefined;
    var grid_text_spans: [state.MAX_GRID_HEIGHT][1]ContentSpan = undefined;
    var line_count: usize = 0;

    for (0..win.grid_height) |row| {
        if (!dirty[row]) continue;

        // Find the end of meaningful content (trim trailing spaces)
        var line_end: usize = win.grid_width;
        while (line_end > 0 and grid_buf[row][line_end - 1] == ' ') {
            line_end -= 1;
        }

        // Build text span for this line
        grid_text_spans[line_count][0] = .{ .text = .{
            .style = "normal",
            .text = grid_buf[row][0..line_end],
        } };
        grid_lines[line_count] = .{
            .line = @intCast(row),
            .content = &grid_text_spans[line_count],
        };
        line_count += 1;

        // Mark line as clean
        dirty[row] = false;
    }

    // Send using struct-based serialization
    sendContentUpdate(.{ .id = win.id, .lines = grid_lines[0..line_count] });
}

// Send buffer window text with proper paragraph structure per GlkOte spec
// Format: {"id": N, "text": [{"append": true, "content": [{"style": "normal", "text": "escaped text"}]}]}
// With hyperlink: {"content": [{"style": "normal", "text": "click me", "hyperlink": 42}]}
pub fn sendBufferTextUpdate(win_id: u32, text: []const u8, clear: bool) void {
    sendStyledBufferTextUpdate(win_id, text, clear, state.current_style, state.current_hyperlink);
}

// Send buffer window text with explicit style and hyperlink
fn sendStyledBufferTextUpdate(win_id: u32, text: []const u8, clear: bool, style: glui32, hyperlink: glui32) void {
    // Flush any other pending updates first
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    const style_str = styleToString(style);

    // Build content span
    const text_span = TextSpan{
        .style = style_str,
        .text = text,
        .hyperlink = if (hyperlink != 0) hyperlink else null,
    };
    const content = [_]ContentSpan{.{ .text = text_span }};
    const paragraphs = [_]TextParagraph{.{ .append = true, .content = &content }};

    sendContentUpdate(.{
        .id = win_id,
        .clear = if (clear) true else null,
        .text = &paragraphs,
    });
}

pub fn ensureGlkInitialized() void {
    if (!state.glk_initialized) {
        state.glk_initialized = true;

        // Wait for client's init message
        var buf: [4096]u8 = undefined;
        const line = readLineFromStdin(&buf) orelse {
            sendError("No init message received");
            return;
        };

        // Parse the init event (use Raw struct to access support array)
        const parsed = std.json.parseFromSlice(InputEventRaw, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch {
            sendError("Invalid init message");
            return;
        };
        defer parsed.deinit();

        const event = parsed.value;
        if (!std.mem.eql(u8, event.type, "init")) {
            sendError("Expected init message");
            return;
        }

        // Store client metrics
        if (event.metrics) |m| {
            if (m.width) |w| state.client_metrics.width = w;
            if (m.height) |h| state.client_metrics.height = h;
        }

        // Parse client capabilities from support array
        if (event.support) |support| {
            for (support) |feature| {
                if (std.mem.eql(u8, feature, "timer")) {
                    state.client_support.timer = true;
                } else if (std.mem.eql(u8, feature, "graphics")) {
                    state.client_support.graphics = true;
                } else if (std.mem.eql(u8, feature, "graphicswin")) {
                    state.client_support.graphicswin = true;
                } else if (std.mem.eql(u8, feature, "hyperlinks")) {
                    state.client_support.hyperlinks = true;
                }
            }
        }

        // Per RemGLK spec: interpreter responds with "update", not "init"
        // The first sendUpdate() call from the game will serve as the response
    }
}

// ============== File Dialog Support ==============

// Convert Glk filemode to GlkOte spec string
pub fn filemodeToString(fmode: glui32) []const u8 {
    const fm = types.filemode;
    return switch (fmode) {
        fm.Read => "read",
        fm.Write => "write",
        fm.ReadWrite => "readwrite",
        fm.WriteAppend => "writeappend",
        else => "read",
    };
}

// Convert Glk fileusage to GlkOte spec filetype string
pub fn fileusageToType(usage: glui32) []const u8 {
    const fu = types.fileusage;
    return switch (usage & fu.TypeMask) {
        fu.SavedGame => "save",
        fu.Transcript => "transcript",
        fu.InputRecord => "command",
        else => "data",
    };
}

// ============== Tests ==============

const testing = std.testing;

test "keycodeToTerminator maps all 13 terminators" {
    const kc = types.keycode;
    try testing.expectEqualStrings("escape", keycodeToTerminator(kc.Escape).?);
    try testing.expectEqualStrings("func1", keycodeToTerminator(kc.Func1).?);
    try testing.expectEqualStrings("func2", keycodeToTerminator(kc.Func2).?);
    try testing.expectEqualStrings("func3", keycodeToTerminator(kc.Func3).?);
    try testing.expectEqualStrings("func4", keycodeToTerminator(kc.Func4).?);
    try testing.expectEqualStrings("func5", keycodeToTerminator(kc.Func5).?);
    try testing.expectEqualStrings("func6", keycodeToTerminator(kc.Func6).?);
    try testing.expectEqualStrings("func7", keycodeToTerminator(kc.Func7).?);
    try testing.expectEqualStrings("func8", keycodeToTerminator(kc.Func8).?);
    try testing.expectEqualStrings("func9", keycodeToTerminator(kc.Func9).?);
    try testing.expectEqualStrings("func10", keycodeToTerminator(kc.Func10).?);
    try testing.expectEqualStrings("func11", keycodeToTerminator(kc.Func11).?);
    try testing.expectEqualStrings("func12", keycodeToTerminator(kc.Func12).?);
}

test "keycodeToTerminator returns null for unmapped keycodes" {
    try testing.expect(keycodeToTerminator(0) == null);
    try testing.expect(keycodeToTerminator('a') == null);
    try testing.expect(keycodeToTerminator(types.keycode.Return) == null);
    try testing.expect(keycodeToTerminator(types.keycode.Left) == null);
}

test "alignmentToString maps all 5 values" {
    try testing.expectEqualStrings("inlineup", alignmentToString(1));
    try testing.expectEqualStrings("inlinedown", alignmentToString(2));
    try testing.expectEqualStrings("inlinecenter", alignmentToString(3));
    try testing.expectEqualStrings("marginleft", alignmentToString(4));
    try testing.expectEqualStrings("marginright", alignmentToString(5));
}

test "alignmentToString defaults to inlineup" {
    try testing.expectEqualStrings("inlineup", alignmentToString(0));
    try testing.expectEqualStrings("inlineup", alignmentToString(99));
}

test "styleToString maps all 11 Glk styles" {
    try testing.expectEqualStrings("normal", styleToString(0));
    try testing.expectEqualStrings("emphasized", styleToString(1));
    try testing.expectEqualStrings("preformatted", styleToString(2));
    try testing.expectEqualStrings("header", styleToString(3));
    try testing.expectEqualStrings("subheader", styleToString(4));
    try testing.expectEqualStrings("alert", styleToString(5));
    try testing.expectEqualStrings("note", styleToString(6));
    try testing.expectEqualStrings("blockquote", styleToString(7));
    try testing.expectEqualStrings("input", styleToString(8));
    try testing.expectEqualStrings("user1", styleToString(9));
    try testing.expectEqualStrings("user2", styleToString(10));
}

test "styleToString defaults to normal for out-of-range" {
    try testing.expectEqualStrings("normal", styleToString(11));
    try testing.expectEqualStrings("normal", styleToString(999));
}

test "formatColorHex formats colors correctly" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("#000000", formatColorHex(&buf, 0x000000));
    try testing.expectEqualStrings("#FFFFFF", formatColorHex(&buf, 0xFFFFFF));
    try testing.expectEqualStrings("#FF0000", formatColorHex(&buf, 0xFF0000));
    try testing.expectEqualStrings("#00FF00", formatColorHex(&buf, 0x00FF00));
    try testing.expectEqualStrings("#0000FF", formatColorHex(&buf, 0x0000FF));
    try testing.expectEqualStrings("#ABCDEF", formatColorHex(&buf, 0xABCDEF));
}

test "filemodeToString maps all 4 modes" {
    const fm = types.filemode;
    try testing.expectEqualStrings("read", filemodeToString(fm.Read));
    try testing.expectEqualStrings("write", filemodeToString(fm.Write));
    try testing.expectEqualStrings("readwrite", filemodeToString(fm.ReadWrite));
    try testing.expectEqualStrings("writeappend", filemodeToString(fm.WriteAppend));
}

test "filemodeToString defaults to read for unknown" {
    try testing.expectEqualStrings("read", filemodeToString(99));
}

test "fileusageToType maps all 4 types" {
    const fu = types.fileusage;
    try testing.expectEqualStrings("data", fileusageToType(fu.Data));
    try testing.expectEqualStrings("save", fileusageToType(fu.SavedGame));
    try testing.expectEqualStrings("transcript", fileusageToType(fu.Transcript));
    try testing.expectEqualStrings("command", fileusageToType(fu.InputRecord));
}

test "fileusageToType masks off TextMode flag" {
    const fu = types.fileusage;
    try testing.expectEqualStrings("save", fileusageToType(fu.SavedGame | fu.TextMode));
    try testing.expectEqualStrings("transcript", fileusageToType(fu.Transcript | fu.TextMode));
}

// Send a specialinput request and wait for the response (per GlkOte spec)
// Returns the selected filename, or null if the user cancelled
// This function blocks via stdin read (JSPI suspends in browser)
pub fn sendSpecialInputAndWait(fmode: glui32, usage: glui32) ?[]const u8 {
    // Flush any pending buffers first
    flushTextBuffer();
    flushGridWindows();

    // Build the specialinput update
    const special = SpecialInput{
        .filemode = filemodeToString(fmode),
        .filetype = fileusageToType(usage),
    };

    const update = StateUpdateJson{
        .gen = generation,
        .specialinput = special,
        .disable = true, // No regular input expected
    };

    // Serialize and send
    var buf: [4096]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(update, .{ .emit_null_optional_fields = false })}) catch return null;
    writeStdout(json);
    writeStdout("\n");
    generation += 1;

    // Wait for response (JSPI suspends here in browser)
    var response_buf: [4096]u8 = undefined;
    const response_line = readLineFromStdin(&response_buf) orelse return null;

    // Parse the response
    const parsed = std.json.parseFromSlice(InputEventRaw, allocator, response_line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const event = parsed.value;

    // Must be a specialresponse with response="fileref_prompt"
    if (!std.mem.eql(u8, event.type, "specialresponse")) return null;
    if (event.response == null or !std.mem.eql(u8, event.response.?, "fileref_prompt")) return null;

    // Extract the filename from value (string or null)
    if (event.value) |val| {
        switch (val) {
            .string => |s| {
                // Return a copy of the filename
                return allocator.dupe(u8, s) catch null;
            },
            .null => return null,
            else => return null,
        }
    }

    return null;
}
