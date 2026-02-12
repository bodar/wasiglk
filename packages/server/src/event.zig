// event.zig - Glk event handling

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const protocol = @import("protocol.zig");
const dispatch = @import("dispatch.zig");

const glui32 = types.glui32;
const winid_t = types.winid_t;
const event_t = types.event_t;
const evtype = types.evtype;
const keycode = types.keycode;
const WindowData = state.WindowData;
const allocator = state.allocator;

// Convert terminator string to keycode (per GlkOte spec)
fn terminatorToKeycode(terminator: ?[]const u8) glui32 {
    const term = terminator orelse return 0;

    if (std.mem.eql(u8, term, "escape")) return keycode.Escape;
    if (std.mem.eql(u8, term, "func1")) return keycode.Func1;
    if (std.mem.eql(u8, term, "func2")) return keycode.Func2;
    if (std.mem.eql(u8, term, "func3")) return keycode.Func3;
    if (std.mem.eql(u8, term, "func4")) return keycode.Func4;
    if (std.mem.eql(u8, term, "func5")) return keycode.Func5;
    if (std.mem.eql(u8, term, "func6")) return keycode.Func6;
    if (std.mem.eql(u8, term, "func7")) return keycode.Func7;
    if (std.mem.eql(u8, term, "func8")) return keycode.Func8;
    if (std.mem.eql(u8, term, "func9")) return keycode.Func9;
    if (std.mem.eql(u8, term, "func10")) return keycode.Func10;
    if (std.mem.eql(u8, term, "func11")) return keycode.Func11;
    if (std.mem.eql(u8, term, "func12")) return keycode.Func12;

    return 0;
}

// Helper to extract initial text from line buffer
fn getInitialText(w: *WindowData) ?[]const u8 {
    if (w.line_initlen == 0) return null;

    if (w.line_request and w.line_buffer != null) {
        // Regular char buffer - can return slice directly
        const len = @min(w.line_initlen, w.line_buflen);
        return w.line_buffer.?[0..len];
    }

    // For unicode buffers, we'd need to convert - not yet implemented
    // Unicode initial text would need conversion to UTF-8
    return null;
}

export fn glk_select(event: ?*event_t) callconv(.c) void {
    if (event == null) return;

    // Flush text buffer and grid windows before waiting for input
    protocol.flushTextBuffer();
    protocol.flushGridWindows();

    event.?.type = evtype.None;
    event.?.win = null;
    event.?.val1 = 0;
    event.?.val2 = 0;

    // Find window with text input request
    var win = state.window_list;
    while (win) |w| : (win = w.next) {
        if (w.char_request or w.line_request or w.char_request_uni or w.line_request_uni) {
            break;
        }
    }

    // Check if any window has a mouse or hyperlink request
    var has_mouse_request = false;
    var has_hyperlink_request = false;
    var aux_win = state.window_list;
    while (aux_win) |aw| : (aux_win = aw.next) {
        if (aw.mouse_request) has_mouse_request = true;
        if (aw.hyperlink_request) has_hyperlink_request = true;
    }

    // Check if we have any input source (window input, mouse input, hyperlink input, or timer)
    const has_timer = state.timer_interval != null;
    if (win == null and !has_timer and !has_mouse_request and !has_hyperlink_request) return;

    // Queue input request if we have a window with input request
    if (win) |w| {
        const input_type: protocol.TextInputType = if (w.line_request or w.line_request_uni) .line else .char;
        // For grid windows, include cursor position
        const xpos: ?glui32 = if (w.win_type == types.wintype.TextGrid) w.cursor_x else null;
        const ypos: ?glui32 = if (w.win_type == types.wintype.TextGrid) w.cursor_y else null;
        // Get initial text if line input with initlen > 0
        const initial: ?[]const u8 = if ((w.line_request or w.line_request_uni) and w.line_initlen > 0)
            getInitialText(w)
        else
            null;
        // Get terminators if line input has them set
        const terminators: ?[]const glui32 = if ((w.line_request or w.line_request_uni) and w.line_terminators_count > 0)
            w.line_terminators[0..w.line_terminators_count]
        else
            null;
        protocol.queueInputRequest(w.id, input_type, w.mouse_request, w.hyperlink_request, xpos, ypos, initial, terminators);
    }

    // Queue timer if active
    protocol.queueTimer(state.timer_interval);

    protocol.sendUpdate();

    // Read JSON input from stdin
    var json_buf: [4096]u8 = undefined;
    const json_line = protocol.readLineFromStdin(&json_buf) orelse {
        glk_exit();
    };

    // Parse the input event
    const input_event = protocol.parseInputEvent(json_line) orelse {
        return;
    };
    defer {
        allocator.free(input_event.type);
        if (input_event.value) |v| allocator.free(v);
        if (input_event.terminator) |t| allocator.free(t);
    }

    // Handle timer events
    if (std.mem.eql(u8, input_event.type, "timer")) {
        event.?.type = evtype.Timer;
        event.?.win = null;
        event.?.val1 = 0;
        event.?.val2 = 0;
        return;
    }

    // Handle arrange events (window resize)
    if (std.mem.eql(u8, input_event.type, "arrange")) {
        // Update stored metrics from the event
        if (input_event.metrics) |m| {
            if (m.width) |w| state.client_metrics.width = w;
            if (m.height) |h| state.client_metrics.height = h;
        }
        event.?.type = evtype.Arrange;
        event.?.win = @ptrCast(state.root_window);
        event.?.val1 = 0;
        event.?.val2 = 0;
        return;
    }

    // Handle mouse events
    if (std.mem.eql(u8, input_event.type, "mouse")) {
        // Find the window with matching ID that has a mouse request
        const target_win_id = input_event.window orelse return;
        var target_win = state.window_list;
        while (target_win) |tw| : (target_win = tw.next) {
            if (tw.id == target_win_id and tw.mouse_request) {
                event.?.type = evtype.MouseInput;
                event.?.win = @ptrCast(tw);
                event.?.val1 = @bitCast(input_event.x orelse 0);
                event.?.val2 = @bitCast(input_event.y orelse 0);
                tw.mouse_request = false; // Mouse request is one-shot
                return;
            }
        }
        return;
    }

    // Handle hyperlink events
    if (std.mem.eql(u8, input_event.type, "hyperlink")) {
        // Find the window with matching ID that has a hyperlink request
        const target_win_id = input_event.window orelse return;
        var target_win = state.window_list;
        while (target_win) |tw| : (target_win = tw.next) {
            if (tw.id == target_win_id and tw.hyperlink_request) {
                event.?.type = evtype.Hyperlink;
                event.?.win = @ptrCast(tw);
                event.?.val1 = input_event.linkval orelse 0;
                event.?.val2 = 0;
                tw.hyperlink_request = false; // Hyperlink request is one-shot
                return;
            }
        }
        return;
    }

    // Handle redraw events (graphics window needs redrawing)
    if (std.mem.eql(u8, input_event.type, "redraw")) {
        event.?.type = evtype.Redraw;
        // If window ID provided, find and return that window; otherwise use root
        if (input_event.window) |win_id| {
            var target_win = state.window_list;
            while (target_win) |tw| : (target_win = tw.next) {
                if (tw.id == win_id) {
                    event.?.win = @ptrCast(tw);
                    event.?.val1 = 0;
                    event.?.val2 = 0;
                    return;
                }
            }
        }
        event.?.win = @ptrCast(state.root_window);
        event.?.val1 = 0;
        event.?.val2 = 0;
        return;
    }

    // Handle refresh events (full state refresh request)
    // Per GlkOte spec, this should resend all window and content state
    // For now, we treat it like an arrange event to trigger state refresh
    if (std.mem.eql(u8, input_event.type, "refresh")) {
        event.?.type = evtype.Arrange;
        event.?.win = @ptrCast(state.root_window);
        event.?.val1 = 0;
        event.?.val2 = 0;
        return;
    }

    // Handle debug input events (display sends debug commands)
    // Per GlkOte spec, these are for debugging purposes
    // Currently we acknowledge but don't process them
    if (std.mem.eql(u8, input_event.type, "debuginput")) {
        event.?.type = evtype.None;
        event.?.win = null;
        event.?.val1 = 0;
        event.?.val2 = 0;
        return;
    }

    // Handle external events (custom extension events)
    // Per GlkOte spec, these are for custom implementations
    // Currently we acknowledge but don't process them
    if (std.mem.eql(u8, input_event.type, "external")) {
        event.?.type = evtype.None;
        event.?.win = null;
        event.?.val1 = 0;
        event.?.val2 = 0;
        return;
    }

    // Handle char/line input events - need a window for these
    if (win == null) return;
    const w = win.?;

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
            event.?.val2 = terminatorToKeycode(input_event.terminator);

            // Unregister the buffer so Glulxe copies data back to VM memory
            if (dispatch.retained_unregister_fn) |unregister_fn| {
                // Typecode for char array with passout: "&+#!Cn"
                var typecode = "&+#!Cn".*;
                unregister_fn(@ptrCast(lb), w.line_buflen, &typecode, w.line_buffer_rock);
            }
        }
        w.line_request = false;
        w.line_buffer = null;
        w.line_buffer_rock = .{ .num = 0 };
    } else if (w.line_request_uni) {
        if (w.line_buffer_uni) |lb| {
            const max_copy = if (w.line_buflen > 1) w.line_buflen - 1 else 0;
            const copy_len: glui32 = @intCast(@min(input_value.len, max_copy));
            // Copy input bytes as unicode codepoints (ASCII range)
            for (0..copy_len) |i| {
                lb[i] = input_value[i];
            }
            if (copy_len < w.line_buflen) {
                lb[copy_len] = 0;
            }

            event.?.type = evtype.LineInput;
            event.?.win = @ptrCast(w);
            event.?.val1 = copy_len;
            event.?.val2 = terminatorToKeycode(input_event.terminator);

            if (dispatch.retained_unregister_fn) |unregister_fn| {
                // Typecode for glui32 array with passout: "&+#!Iu"
                var typecode = "&+#!Iu".*;
                unregister_fn(@ptrCast(lb), w.line_buflen, &typecode, w.line_buffer_rock);
            }
        }
        w.line_request_uni = false;
        w.line_buffer_uni = null;
        w.line_buffer_rock = .{ .num = 0 };
    } else if (w.char_request) {
        event.?.type = evtype.CharInput;
        event.?.win = @ptrCast(w);
        event.?.val1 = if (input_value.len > 0) input_value[0] else keycode.Return;
        w.char_request = false;
    } else if (w.char_request_uni) {
        event.?.type = evtype.CharInput;
        event.?.win = @ptrCast(w);
        event.?.val1 = if (input_value.len > 0) input_value[0] else keycode.Return;
        w.char_request_uni = false;
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
    // Set timer interval: 0 means disable, non-zero enables with that interval
    if (millisecs == 0) {
        state.timer_interval = null;
    } else {
        state.timer_interval = millisecs;
    }
}

export fn glk_request_line_event(win_opaque: winid_t, buf: ?[*]u8, maxlen: glui32, initlen: glui32) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;

    win.?.line_request = true;
    win.?.line_buffer = buf;
    win.?.line_buflen = maxlen;
    win.?.line_initlen = initlen;
    win.?.line_partial_len = 0; // Reset partial text from any previous interrupted input

    // Register the buffer with the retained registry so it gets copied back
    if (dispatch.retained_register_fn) |register_fn| {
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

export fn glk_request_mouse_event(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    // Mouse events are only meaningful for grid and graphics windows
    if (win.?.win_type == types.wintype.TextGrid or win.?.win_type == types.wintype.Graphics) {
        win.?.mouse_request = true;
    }
}

export fn glk_cancel_line_event(win_opaque: winid_t, event: ?*event_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    const w = win.?;

    if (event) |e| {
        // If line input was active, return LineInput event with partial text length
        if (w.line_request or w.line_request_uni) {
            e.type = evtype.LineInput;
            e.win = win_opaque;
            e.val1 = w.line_partial_len; // Number of characters entered so far
            e.val2 = 0;
        } else {
            e.type = evtype.None;
            e.win = null;
            e.val1 = 0;
            e.val2 = 0;
        }
    }

    // Unregister the buffer so Glulxe copies data back to VM memory
    if (w.line_request and w.line_buffer != null) {
        if (dispatch.retained_unregister_fn) |unregister_fn| {
            var typecode = "&+#!Cn".*;
            unregister_fn(@ptrCast(w.line_buffer), w.line_buflen, &typecode, w.line_buffer_rock);
        }
    } else if (w.line_request_uni and w.line_buffer_uni != null) {
        if (dispatch.retained_unregister_fn) |unregister_fn| {
            var typecode = "&+#!Iu".*;
            unregister_fn(@ptrCast(w.line_buffer_uni), w.line_buflen, &typecode, w.line_buffer_rock);
        }
    }

    w.line_request = false;
    w.line_request_uni = false;
    w.line_buffer = null;
    w.line_buffer_uni = null;
    w.line_partial_len = 0;
    w.line_buffer_rock = .{ .num = 0 };
}

export fn glk_cancel_char_event(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.char_request = false;
}

export fn glk_cancel_mouse_event(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.mouse_request = false;
}

export fn glk_request_char_event_uni(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.char_request_uni = true;
}

export fn glk_request_line_event_uni(win_opaque: winid_t, buf: ?[*]glui32, maxlen: glui32, initlen: glui32) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.line_request_uni = true;
    win.?.line_buffer_uni = buf;
    win.?.line_buflen = maxlen;
    win.?.line_initlen = initlen;
    win.?.line_partial_len = 0; // Reset partial text from any previous interrupted input

    // Register the buffer with the retained registry so it gets copied back
    if (dispatch.retained_register_fn) |register_fn| {
        // Typecode "&+#!Iu" = reference, passout, array, retained, glui32
        var typecode = "&+#!Iu".*;
        win.?.line_buffer_rock = register_fn(@ptrCast(buf), maxlen, &typecode);
    }
}

// ============== Tests ==============

const testing = std.testing;

test "terminatorToKeycode maps all 13 terminator strings" {
    try testing.expectEqual(keycode.Escape, terminatorToKeycode("escape"));
    try testing.expectEqual(keycode.Func1, terminatorToKeycode("func1"));
    try testing.expectEqual(keycode.Func2, terminatorToKeycode("func2"));
    try testing.expectEqual(keycode.Func3, terminatorToKeycode("func3"));
    try testing.expectEqual(keycode.Func4, terminatorToKeycode("func4"));
    try testing.expectEqual(keycode.Func5, terminatorToKeycode("func5"));
    try testing.expectEqual(keycode.Func6, terminatorToKeycode("func6"));
    try testing.expectEqual(keycode.Func7, terminatorToKeycode("func7"));
    try testing.expectEqual(keycode.Func8, terminatorToKeycode("func8"));
    try testing.expectEqual(keycode.Func9, terminatorToKeycode("func9"));
    try testing.expectEqual(keycode.Func10, terminatorToKeycode("func10"));
    try testing.expectEqual(keycode.Func11, terminatorToKeycode("func11"));
    try testing.expectEqual(keycode.Func12, terminatorToKeycode("func12"));
}

test "terminatorToKeycode returns 0 for null and unknown" {
    try testing.expectEqual(@as(glui32, 0), terminatorToKeycode(null));
    try testing.expectEqual(@as(glui32, 0), terminatorToKeycode("unknown"));
    try testing.expectEqual(@as(glui32, 0), terminatorToKeycode(""));
}

test "keycodeToTerminator and terminatorToKeycode roundtrip" {
    const keycodes = [_]glui32{
        keycode.Escape, keycode.Func1,  keycode.Func2,  keycode.Func3,
        keycode.Func4,  keycode.Func5,  keycode.Func6,  keycode.Func7,
        keycode.Func8,  keycode.Func9,  keycode.Func10, keycode.Func11,
        keycode.Func12,
    };
    for (keycodes) |kc| {
        const term_str = protocol.keycodeToTerminator(kc).?;
        try testing.expectEqual(kc, terminatorToKeycode(term_str));
    }
}

// glk_exit is used by event handling
pub fn glk_exit() callconv(.c) noreturn {
    protocol.flushTextBuffer();
    protocol.flushGridWindows();
    // Always send a final update with exit: true
    protocol.queueExit();
    protocol.sendUpdate();
    std.process.exit(0);
}
