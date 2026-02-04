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
    value: ?std.json.Value = null, // Can be string (line/char) or integer (hyperlink)
    metrics: ?Metrics = null,
    support: ?[]const []const u8 = null, // Features the display supports
    partial: ?std.json.Value = null,
    // Mouse event coordinates
    x: ?i32 = null,
    y: ?i32 = null,
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
};

pub const Metrics = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    charwidth: ?f64 = null,
    charheight: ?f64 = null,
};

// Output types (interpreter -> client)
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

pub const ContentUpdate = struct {
    id: u32,
    clear: ?bool = null,
    text: ?[]const u8 = null,
};

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
};

const StateUpdate = struct {
    type: []const u8 = "update",
    gen: u32,
    windows: ?[]const WindowUpdate = null,
    content: ?[]const ContentUpdate = null,
    input: ?[]const InputRequest = null,
    timer: ?u32 = null, // Timer interval in ms, null = not included in output
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
    };
}

pub fn sendUpdate() void {
    // Build update manually to control which fields are included
    var buf: [32768]u8 = undefined;
    var offset: usize = 0;

    // Start object
    const header = std.fmt.bufPrint(buf[offset..], "{{\"type\":\"update\",\"gen\":{d}", .{generation}) catch return;
    offset += header.len;

    // Add windows if present
    if (pending_windows_len > 0) {
        const windows_json = std.fmt.bufPrint(buf[offset..], ",\"windows\":{f}", .{std.json.fmt(pending_windows[0..pending_windows_len], .{})}) catch return;
        offset += windows_json.len;
    }

    // Add content if present
    if (pending_content_len > 0) {
        const content_json = std.fmt.bufPrint(buf[offset..], ",\"content\":{f}", .{std.json.fmt(pending_content[0..pending_content_len], .{})}) catch return;
        offset += content_json.len;
    }

    // Add input if present
    if (pending_input_len > 0) {
        const input_json = std.fmt.bufPrint(buf[offset..], ",\"input\":{f}", .{std.json.fmt(pending_input[0..pending_input_len], .{})}) catch return;
        offset += input_json.len;
    }

    // Add timer only if explicitly set
    if (pending_timer_set) {
        if (pending_timer) |interval| {
            const timer_json = std.fmt.bufPrint(buf[offset..], ",\"timer\":{d}", .{interval}) catch return;
            offset += timer_json.len;
        } else {
            const timer_null = ",\"timer\":null";
            @memcpy(buf[offset..][0..timer_null.len], timer_null);
            offset += timer_null.len;
        }
    }

    // Close object
    buf[offset] = '}';
    offset += 1;

    writeStdout(buf[0..offset]);
    writeStdout("\n");

    pending_windows_len = 0;
    pending_content_len = 0;
    pending_input_len = 0;
    pending_timer = null;
    pending_timer_set = false;
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
    pending_windows[pending_windows_len] = .{
        .id = win.id,
        .type = wtype,
        .rock = win.rock,
        .width = @floatFromInt(state.client_metrics.width),
        .height = @floatFromInt(state.client_metrics.height),
        // Grid windows: dimensions in character cells
        .gridwidth = if (wtype == .grid) state.client_metrics.width else null,
        .gridheight = if (wtype == .grid) state.client_metrics.height else null,
        // Graphics windows: canvas dimensions in pixels
        .graphwidth = if (wtype == .graphics) state.client_metrics.width else null,
        .graphheight = if (wtype == .graphics) state.client_metrics.height else null,
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

pub fn queueInputRequest(win_id: u32, input_type: TextInputType, mouse: bool, hyperlink: bool, xpos: ?u32, ypos: ?u32) void {
    if (pending_input_len >= pending_input.len) return;
    pending_input[pending_input_len] = .{
        .id = win_id,
        .type = input_type,
        .gen = generation,
        .mouse = if (mouse) true else null,
        .hyperlink = if (hyperlink) true else null,
        .xpos = xpos,
        .ypos = ypos,
    };
    pending_input_len += 1;
}

pub fn queueTimer(interval: ?glui32) void {
    pending_timer = interval;
    pending_timer_set = true;
}

// ============== Special Update Functions ==============

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

// Send an image content update for buffer windows using paragraph format per GlkOte spec
pub fn sendImageUpdate(win_id: u32, image: glui32, alignment: glsi32, img_width: glui32, img_height: glui32) void {
    // Flush any pending updates first
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    const alignment_str = alignmentToString(alignment);

    // Build JSON with paragraph format: {"text":[{"append":true,"content":[{"special":"image",...}]}]}
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"type":"update","gen":{d},"content":[{{"id":{d},"text":[{{"append":true,"content":[{{"special":"image","image":{d},"alignment":"{s}","width":{d},"height":{d}}}]}}]}}]}}
    , .{ generation, win_id, image, alignment_str, img_width, img_height }) catch return;

    writeStdout(json);
    writeStdout("\n");
    generation += 1;
}

// Send a graphics window image update (includes x, y position)
// Uses "draw" array with "special" as string value per GlkOte spec
pub fn sendGraphicsImageUpdate(win_id: u32, image: glui32, x: glsi32, y: glsi32, img_width: glui32, img_height: glui32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"type":"update","gen":{d},"content":[{{"id":{d},"draw":[{{"special":"image","image":{d},"x":{d},"y":{d},"width":{d},"height":{d}}}]}}]}}
    , .{ generation, win_id, image, x, y, img_width, img_height }) catch return;

    writeStdout(json);
    writeStdout("\n");
    generation += 1;
}

pub fn sendFlowBreakUpdate(win_id: u32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    // Use paragraph format with flowbreak flag per GlkOte spec
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"type":"update","gen":{d},"content":[{{"id":{d},"text":[{{"flowbreak":true}}]}}]}}
    , .{ generation, win_id }) catch return;

    writeStdout(json);
    writeStdout("\n");
    generation += 1;
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

    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"type":"update","gen":{d},"content":[{{"id":{d},"draw":[{{"special":"fill","color":"{s}","x":{d},"y":{d},"width":{d},"height":{d}}}]}}]}}
    , .{ generation, win_id, color_str, x, y, width, height }) catch return;

    writeStdout(json);
    writeStdout("\n");
    generation += 1;
}

pub fn sendGraphicsEraseUpdate(win_id: u32, x: glsi32, y: glsi32, width: glui32, height: glui32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"type":"update","gen":{d},"content":[{{"id":{d},"draw":[{{"special":"fill","x":{d},"y":{d},"width":{d},"height":{d}}}]}}]}}
    , .{ generation, win_id, x, y, width, height }) catch return;

    writeStdout(json);
    writeStdout("\n");
    generation += 1;
}

pub fn sendGraphicsSetColorUpdate(win_id: u32, color: glui32) void {
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    // Format color as CSS hex string
    var color_buf: [8]u8 = undefined;
    const color_str = formatColorHex(&color_buf, color);

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"type":"update","gen":{d},"content":[{{"id":{d},"draw":[{{"special":"setcolor","color":"{s}"}}]}}]}}
    , .{ generation, win_id, color_str }) catch return;

    writeStdout(json);
    writeStdout("\n");
    generation += 1;
}

// ============== Text Buffer Management ==============

// Helper to escape a string for JSON output
fn jsonEscapeString(input: []const u8, output: []u8) []const u8 {
    var out_i: usize = 0;
    for (input) |c| {
        if (out_i + 6 >= output.len) break; // Ensure space for escape sequences
        switch (c) {
            '"' => {
                output[out_i] = '\\';
                output[out_i + 1] = '"';
                out_i += 2;
            },
            '\\' => {
                output[out_i] = '\\';
                output[out_i + 1] = '\\';
                out_i += 2;
            },
            '\n' => {
                output[out_i] = '\\';
                output[out_i + 1] = 'n';
                out_i += 2;
            },
            '\r' => {
                output[out_i] = '\\';
                output[out_i + 1] = 'r';
                out_i += 2;
            },
            '\t' => {
                output[out_i] = '\\';
                output[out_i + 1] = 't';
                out_i += 2;
            },
            else => {
                if (c < 0x20) {
                    // Control character - use \uXXXX format
                    const hex = "0123456789abcdef";
                    output[out_i] = '\\';
                    output[out_i + 1] = 'u';
                    output[out_i + 2] = '0';
                    output[out_i + 3] = '0';
                    output[out_i + 4] = hex[c >> 4];
                    output[out_i + 5] = hex[c & 0xf];
                    out_i += 6;
                } else {
                    output[out_i] = c;
                    out_i += 1;
                }
            },
        }
    }
    return output[0..out_i];
}

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

    // Build JSON with lines array format per GlkOte spec
    // Format: {"type":"update","gen":N,"content":[{"id":N,"lines":[{"line":N,"content":["text"]},...]}]}
    var buf: [65536]u8 = undefined;
    var offset: usize = 0;

    // Start of message
    const header = std.fmt.bufPrint(buf[offset..], "{{\"type\":\"update\",\"gen\":{d},\"content\":[{{\"id\":{d},\"lines\":[", .{ generation, win.id }) catch return;
    offset += header.len;

    var first_line = true;
    for (0..win.grid_height) |row| {
        if (!dirty[row]) continue;

        // Find the end of meaningful content (trim trailing spaces)
        var line_end: usize = win.grid_width;
        while (line_end > 0 and grid_buf[row][line_end - 1] == ' ') {
            line_end -= 1;
        }

        // Comma before all but the first line
        if (!first_line) {
            if (offset < buf.len) {
                buf[offset] = ',';
                offset += 1;
            }
        }
        first_line = false;

        // Start line object
        const line_start = std.fmt.bufPrint(buf[offset..], "{{\"line\":{d},\"content\":[\"", .{row}) catch return;
        offset += line_start.len;

        // Escape and add the line content
        var escaped_buf: [1024]u8 = undefined;
        const escaped = jsonEscapeString(grid_buf[row][0..line_end], &escaped_buf);
        if (offset + escaped.len < buf.len) {
            @memcpy(buf[offset..][0..escaped.len], escaped);
            offset += escaped.len;
        }

        // Close line object
        const line_end_str = "\"]}";
        if (offset + line_end_str.len < buf.len) {
            @memcpy(buf[offset..][0..line_end_str.len], line_end_str);
            offset += line_end_str.len;
        }

        // Mark line as clean
        dirty[row] = false;
    }

    // Close the message
    // Close: lines array "]", content object "}", content array "]", root object "}"
    const footer = "]}]}";
    if (offset + footer.len < buf.len) {
        @memcpy(buf[offset..][0..footer.len], footer);
        offset += footer.len;
    }

    writeStdout(buf[0..offset]);
    writeStdout("\n");
    generation += 1;
}

// Send buffer window text with proper paragraph structure per GlkOte spec
// Format: {"id": N, "text": [{"append": true, "content": ["escaped text"]}]}
pub fn sendBufferTextUpdate(win_id: u32, text: []const u8, clear: bool) void {
    // Flush any other pending updates first
    if (pending_content_len > 0 or pending_windows_len > 0 or pending_input_len > 0) {
        sendUpdate();
    }

    // Escape the text for JSON
    var escaped_buf: [16384]u8 = undefined;
    const escaped_text = jsonEscapeString(text, &escaped_buf);

    var buf: [32768]u8 = undefined;
    const json = if (clear)
        std.fmt.bufPrint(&buf,
            \\{{"type":"update","gen":{d},"content":[{{"id":{d},"clear":true,"text":[{{"append":true,"content":["{s}"]}}]}}]}}
        , .{ generation, win_id, escaped_text }) catch return
    else
        std.fmt.bufPrint(&buf,
            \\{{"type":"update","gen":{d},"content":[{{"id":{d},"text":[{{"append":true,"content":["{s}"]}}]}}]}}
        , .{ generation, win_id, escaped_text }) catch return;

    writeStdout(json);
    writeStdout("\n");
    generation += 1;
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
