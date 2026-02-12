// style.zig - Glk style hint functions

const types = @import("types.zig");
const state = @import("state.zig");
const protocol = @import("protocol.zig");

const glui32 = types.glui32;
const glsi32 = types.glsi32;
const winid_t = types.winid_t;
const strid_t = types.strid_t;
const WindowData = state.WindowData;
const StreamData = state.StreamData;

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

// ============== Tests ==============

const testing = @import("std").testing;

test "glk_style_distinguish returns 1 for different styles" {
    try testing.expectEqual(@as(glui32, 1), glk_style_distinguish(null, 0, 1));
    try testing.expectEqual(@as(glui32, 1), glk_style_distinguish(null, 2, 8));
}

test "glk_style_distinguish returns 0 for same style" {
    try testing.expectEqual(@as(glui32, 0), glk_style_distinguish(null, 0, 0));
    try testing.expectEqual(@as(glui32, 0), glk_style_distinguish(null, 5, 5));
}

export fn glk_set_echo_line_event(win: winid_t, val: glui32) callconv(.c) void {
    _ = win;
    _ = val;
}

export fn glk_set_terminators_line_event(win_opaque: winid_t, keycodes_ptr: ?[*]const glui32, count: glui32) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;

    // Clear existing terminators
    win.?.line_terminators_count = 0;

    // Copy new terminators (up to the max we can store)
    if (keycodes_ptr) |keys| {
        const max_copy: glui32 = @intCast(@min(count, win.?.line_terminators.len));
        for (0..max_copy) |i| {
            win.?.line_terminators[i] = keys[i];
        }
        win.?.line_terminators_count = max_copy;
    }
}

// Hyperlinks
export fn glk_set_hyperlink(linkval: glui32) callconv(.c) void {
    // Flush current buffer before changing hyperlink (so previous text keeps its link value)
    if (state.current_hyperlink != linkval) {
        protocol.flushTextBuffer();
        state.current_hyperlink = linkval;
    }
}

export fn glk_set_hyperlink_stream(str_opaque: strid_t, linkval: glui32) callconv(.c) void {
    // For now, only handle setting hyperlink on the current stream
    // A full implementation would track hyperlink per-stream
    const str: ?*StreamData = @ptrCast(@alignCast(str_opaque));
    if (str != null and str == state.current_stream) {
        glk_set_hyperlink(linkval);
    }
}

export fn glk_request_hyperlink_event(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    // Hyperlink events are meaningful for buffer and grid windows
    if (win.?.win_type == types.wintype.TextBuffer or win.?.win_type == types.wintype.TextGrid) {
        win.?.hyperlink_request = true;
    }
}

export fn glk_cancel_hyperlink_event(win_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    win.?.hyperlink_request = false;
}

// Debug stream support per GlkOte spec
// Debug output is collected and sent in the debugoutput field of updates
export fn glk_set_debug_stream(str_opaque: strid_t) callconv(.c) void {
    state.debug_stream = @ptrCast(@alignCast(str_opaque));
}
