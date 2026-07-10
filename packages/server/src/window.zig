// window.zig - Glk window functions

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const stream = @import("stream.zig");
const dispatch = @import("dispatch.zig");
const protocol = @import("protocol.zig");

const glui32 = types.glui32;
const winid_t = types.winid_t;
const strid_t = types.strid_t;
const stream_result_t = types.stream_result_t;
const WindowData = state.WindowData;
const StreamData = state.StreamData;
const allocator = state.allocator;

export fn glk_window_get_root() callconv(.c) winid_t {
    return @ptrCast(state.root_window);
}

export fn glk_window_open(split_opaque: winid_t, method: glui32, size: glui32, win_type: glui32, rock: glui32) callconv(.c) winid_t {
    const split_win: ?*WindowData = @ptrCast(@alignCast(split_opaque));

    // Output init message on first window open
    protocol.ensureGlkInitialized();

    // Create the new window
    const win = allocator.create(WindowData) catch return null;
    win.* = WindowData{
        .id = state.window_id_counter,
        .rock = rock,
        .win_type = win_type,
    };
    state.window_id_counter += 1;

    // Initialize grid buffer for grid windows
    if (win_type == types.wintype.TextGrid) {
        win.grid_buffer = allocator.create([state.MAX_GRID_HEIGHT][state.MAX_GRID_WIDTH]u8) catch {
            allocator.destroy(win);
            return null;
        };
        win.grid_dirty = allocator.create([state.MAX_GRID_HEIGHT]bool) catch {
            allocator.destroy(win.grid_buffer.?);
            allocator.destroy(win);
            return null;
        };
        // Initialize grid with spaces
        for (win.grid_buffer.?) |*row| {
            @memset(row, ' ');
        }
        // Clear dirty flags
        @memset(win.grid_dirty.?, false);
    }

    // Add to window list
    win.next = state.window_list;
    if (state.window_list) |list| list.prev = win;
    state.window_list = win;

    // Create window stream
    win.stream = stream.createWindowStream(win);

    if (split_win == null) {
        // First window - becomes the root
        state.root_window = win;
        state.current_stream = win.stream;
    } else {
        // Split an existing window - create a pair window
        const pair = allocator.create(WindowData) catch {
            // Cleanup on failure
            if (win.grid_buffer) |buf| allocator.destroy(buf);
            if (win.grid_dirty) |dirty| allocator.destroy(dirty);
            allocator.destroy(win);
            return null;
        };
        pair.* = WindowData{
            .id = state.window_id_counter,
            .rock = 0,
            .win_type = types.wintype.Pair,
            .split_method = method,
            .split_size = size,
            .split_key = win, // The new window is the key window
        };
        state.window_id_counter += 1;

        // Add pair to window list
        pair.next = state.window_list;
        if (state.window_list) |list| list.prev = pair;
        state.window_list = pair;

        // Insert pair into the tree where split_win was
        pair.parent = split_win.?.parent;
        if (split_win.?.parent) |parent| {
            if (parent.child1 == split_win.?) {
                parent.child1 = pair;
            } else {
                parent.child2 = pair;
            }
        } else {
            // split_win was root
            state.root_window = pair;
        }

        // The direction determines which child is which
        // Left/Above: new window is child1, old is child2
        // Right/Below: old window is child1, new is child2
        const dir = method & types.winmethod.DirMask;
        if (dir == types.winmethod.Left or dir == types.winmethod.Above) {
            pair.child1 = win;
            pair.child2 = split_win.?;
        } else {
            pair.child1 = split_win.?;
            pair.child2 = win;
        }

        // Update parent pointers
        win.parent = pair;
        split_win.?.parent = pair;

        // Register pair with dispatch system
        if (dispatch.object_register_fn) |register_fn| {
            pair.dispatch_rock = register_fn(@ptrCast(pair), dispatch.gidisp_Class_Window);
        }
    }

    // Register with dispatch system
    if (dispatch.object_register_fn) |register_fn| {
        win.dispatch_rock = register_fn(@ptrCast(win), dispatch.gidisp_Class_Window);
    }

    // Recalculate window layout
    recalculateLayout();

    // Queue window updates for all visible windows
    queueAllWindowUpdates();
    protocol.sendUpdate();

    return @ptrCast(win);
}

export fn glk_window_close(win_opaque: winid_t, result: ?*stream_result_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    const w = win.?;

    // Report stream statistics for the explicitly-closed window.
    if (result) |r| {
        if (w.stream) |s| {
            r.readcount = s.readcount;
            r.writecount = s.writecount;
        } else {
            r.readcount = 0;
            r.writecount = 0;
        }
    }

    // Flush any buffered output before the window tree changes underneath it.
    protocol.flushTextBuffer();

    // Per the Glk spec, closing a window also removes its parent pair window;
    // the sibling is promoted into the pair's slot in the tree. Skipping this
    // leaves the parent (and grandparent) holding dangling child/key pointers
    // to the freed window, which recalculateLayout() then dereferences and
    // writes through -> heap corruption.
    if (w.parent) |p| {
        const sibling = if (p.child1 == w) p.child2 else p.child1;
        const grandparent = p.parent;

        if (grandparent) |gp| {
            if (gp.child1 == p) gp.child1 = sibling else gp.child2 = sibling;
            if (gp.split_key == p or gp.split_key == w) gp.split_key = sibling;
        } else {
            state.root_window = sibling;
        }
        if (sibling) |s| s.parent = grandparent;

        // Free the now-defunct parent pair window. Non-recursive: the sibling
        // subtree survives and must not be torn down.
        freeWindow(p);
    } else {
        // Closing the root window tears down the whole tree.
        state.root_window = null;
    }

    // Destroy the closed window and all of its descendants.
    closeSubtree(w);

    // Rebuild layout for the surviving tree and notify the client.
    recalculateLayout();
    queueAllWindowUpdates();
    protocol.sendUpdate();
}

/// Tear down a single window: close its stream, unregister it, free buffers,
/// unlink it from the flat window list, and destroy it. Does NOT touch the
/// window tree (parent/child pointers); callers are responsible for structure.
fn freeWindow(w: *WindowData) void {
    if (w.stream) |s| {
        s.win = null;
        stream.glk_stream_close(@ptrCast(s), null);
        w.stream = null;
    }

    if (dispatch.object_unregister_fn) |unregister_fn| {
        unregister_fn(@ptrCast(w), dispatch.gidisp_Class_Window, w.dispatch_rock);
    }

    if (w.grid_buffer) |buf| allocator.destroy(buf);
    if (w.grid_dirty) |dirty| allocator.destroy(dirty);

    // Unlink from the flat window list.
    if (w.prev) |p| p.next = w.next else state.window_list = w.next;
    if (w.next) |n| n.prev = w.prev;

    // Drop any surviving global references to this window.
    if (state.text_buffer_win == w) {
        state.text_buffer_len = 0;
        state.text_buffer_win = null;
    }
    if (state.root_window == w) state.root_window = null;

    allocator.destroy(w);
}

/// Recursively close a window and all of its descendants (depth-first).
fn closeSubtree(w: *WindowData) void {
    if (w.win_type == types.wintype.Pair) {
        if (w.child1) |c| closeSubtree(c);
        if (w.child2) |c| closeSubtree(c);
    }
    freeWindow(w);
}

/// Convert a pixel extent to character cells: (px - margin) / char_px, floored,
/// clamped to >= 0. Used to report text-window sizes to the game.
pub fn pxToCells(px: f64, margin: f64, char_px: f64) glui32 {
    if (char_px <= 0) return 0;
    const usable = px - margin;
    if (usable <= 0) return 0;
    return @intFromFloat(usable / char_px);
}

/// Character-cell width of a text window from its laid-out pixel width.
fn textCols(win: *WindowData) glui32 {
    const cm = state.client_metrics;
    if (win.win_type == types.wintype.TextGrid)
        return pxToCells(win.layout_width, cm.grid_margin_x, cm.grid_char_w);
    return pxToCells(win.layout_width, cm.buffer_margin_x, cm.buffer_char_w);
}

/// Character-cell height of a text window from its laid-out pixel height.
fn textRows(win: *WindowData) glui32 {
    const cm = state.client_metrics;
    if (win.win_type == types.wintype.TextGrid)
        return pxToCells(win.layout_height, cm.grid_margin_y, cm.grid_char_h);
    return pxToCells(win.layout_height, cm.buffer_margin_y, cm.buffer_char_h);
}

/// Pixel size of a Fixed split, converting the key window's char-cell size to
/// pixels. `horizontal` true → the split divides width (columns); false →
/// height (rows). Graphics/other key windows keep pixel units.
fn fixedSplitPx(key: ?*WindowData, horizontal: bool, size: glui32) f64 {
    const s: f64 = @floatFromInt(size);
    const k = key orelse return s;
    const cm = state.client_metrics;
    return switch (k.win_type) {
        types.wintype.TextGrid => if (horizontal) s * cm.grid_char_w + cm.grid_margin_x else s * cm.grid_char_h + cm.grid_margin_y,
        types.wintype.TextBuffer => if (horizontal) s * cm.buffer_char_w + cm.buffer_margin_x else s * cm.buffer_char_h + cm.buffer_margin_y,
        else => s, // graphics / pair: already pixels
    };
}

export fn glk_window_get_size(win_opaque: winid_t, widthptr: ?*glui32, heightptr: ?*glui32) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win) |w| {
        // Grid/buffer windows report character cells; graphics report pixels.
        if (w.win_type == types.wintype.TextGrid or w.win_type == types.wintype.TextBuffer) {
            if (widthptr) |wp| wp.* = if (w.layout_width > 0) textCols(w) else 80;
            if (heightptr) |hp| hp.* = if (w.layout_height > 0) textRows(w) else 24;
        } else {
            // Graphics/other windows: return pixel dimensions
            if (widthptr) |wp| wp.* = if (w.layout_width > 0) @intFromFloat(w.layout_width) else 80;
            if (heightptr) |hp| hp.* = if (w.layout_height > 0) @intFromFloat(w.layout_height) else 24;
        }
    } else {
        // Fallback for null window
        if (widthptr) |wp| wp.* = 80;
        if (heightptr) |hp| hp.* = 24;
    }
}

export fn glk_window_set_arrangement(win_opaque: winid_t, method: glui32, size: glui32, keywin_opaque: winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    const keywin: ?*WindowData = @ptrCast(@alignCast(keywin_opaque));
    if (win == null) return;
    const w = win.?;

    // Only valid for pair windows
    if (w.win_type != types.wintype.Pair) return;

    w.split_method = method;
    w.split_size = size;
    if (keywin != null) {
        w.split_key = keywin;
    }

    // Recalculate layout after arrangement change
    recalculateLayout();

    // Queue window updates for all visible windows
    queueAllWindowUpdates();
    protocol.sendUpdate();
}

export fn glk_window_get_arrangement(win_opaque: winid_t, methodptr: ?*glui32, sizeptr: ?*glui32, keywinptr: ?*winid_t) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) {
        if (methodptr) |m| m.* = 0;
        if (sizeptr) |s| s.* = 0;
        if (keywinptr) |k| k.* = null;
        return;
    }
    const w = win.?;

    // Only valid for pair windows
    if (w.win_type != types.wintype.Pair) {
        if (methodptr) |m| m.* = 0;
        if (sizeptr) |s| s.* = 0;
        if (keywinptr) |k| k.* = null;
        return;
    }

    if (methodptr) |m| m.* = w.split_method;
    if (sizeptr) |s| s.* = w.split_size;
    if (keywinptr) |k| k.* = @ptrCast(w.split_key);
}

export fn glk_window_iterate(win_opaque: winid_t, rockptr: ?*glui32) callconv(.c) winid_t {
    var win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) {
        win = state.window_list;
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
    const w = win.?;

    protocol.flushTextBuffer();

    // For grid windows, also clear the grid buffer and reset cursor
    if (w.win_type == types.wintype.TextGrid) {
        if (w.grid_buffer) |buf| {
            for (buf) |*row| {
                @memset(row, ' ');
            }
        }
        if (w.grid_dirty) |dirty| {
            @memset(dirty, false);
        }
        w.cursor_x = 0;
        w.cursor_y = 0;
    }

    protocol.queueContentUpdate(w.id, null, true);
    protocol.sendUpdate();
}

export fn glk_window_move_cursor(win_opaque: winid_t, xpos: glui32, ypos: glui32) callconv(.c) void {
    const win: ?*WindowData = @ptrCast(@alignCast(win_opaque));
    if (win == null) return;
    const w = win.?;

    // Only valid for grid windows
    if (w.win_type != types.wintype.TextGrid) return;

    // Flush any pending text before moving cursor
    protocol.flushTextBuffer();

    // Clamp to grid dimensions
    w.cursor_x = if (xpos < w.grid_width) xpos else w.grid_width -| 1;
    w.cursor_y = if (ypos < w.grid_height) ypos else w.grid_height -| 1;
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
        state.current_stream = w.stream;
    } else {
        state.current_stream = null;
    }
}

// ============== Layout Calculation ==============

/// Recalculate the layout of all windows based on the current tree structure
pub fn recalculateLayout() void {
    if (state.root_window) |root| {
        // Start with the full display area
        const width: f64 = @floatFromInt(state.client_metrics.width);
        const height: f64 = @floatFromInt(state.client_metrics.height);
        layoutWindow(root, 0, 0, width, height);
    }
}

/// Recursively layout a window within the given bounds
fn layoutWindow(win: *WindowData, left: f64, top: f64, width: f64, height: f64) void {
    win.layout_left = left;
    win.layout_top = top;
    win.layout_width = width;
    win.layout_height = height;

    // Keep a grid window's logical cell dimensions (its buffer wrap width and
    // cursor bounds) in sync with what glk_window_get_size reports, clamped to
    // the backing buffer. Otherwise writes wrap at the stale default width.
    if (win.win_type == types.wintype.TextGrid) {
        const cols = textCols(win);
        const rows = textRows(win);
        win.grid_width = @min(cols, @as(glui32, state.MAX_GRID_WIDTH));
        win.grid_height = @min(rows, @as(glui32, state.MAX_GRID_HEIGHT));
    }

    // If this is a pair window, split the space between children
    if (win.win_type == types.wintype.Pair) {
        const child1 = win.child1 orelse return;
        const child2 = win.child2 orelse return;

        const dir = win.split_method & types.winmethod.DirMask;
        const division = win.split_method & types.winmethod.DivisionMask;
        const size = win.split_size;

        // Determine the split size in pixels
        var key_size: f64 = 0;
        if (division == types.winmethod.Fixed) {
            // Fixed: the size is in the KEY window's natural unit — character
            // rows/columns for a text key window, pixels for graphics. Convert
            // to pixels for layout using that window's char metrics.
            const horizontal = (dir == types.winmethod.Left or dir == types.winmethod.Right);
            key_size = fixedSplitPx(win.split_key, horizontal, size);
        } else {
            // Proportional: size is a percentage (0-100)
            const total = if (dir == types.winmethod.Left or dir == types.winmethod.Right) width else height;
            key_size = total * @as(f64, @floatFromInt(size)) / 100.0;
        }

        // Split based on direction
        switch (dir) {
            types.winmethod.Left => {
                // child1 (key) on left, child2 on right
                const c1_width = @min(key_size, width);
                layoutWindow(child1, left, top, c1_width, height);
                layoutWindow(child2, left + c1_width, top, width - c1_width, height);
            },
            types.winmethod.Right => {
                // child1 on left, child2 (key) on right
                const c2_width = @min(key_size, width);
                layoutWindow(child1, left, top, width - c2_width, height);
                layoutWindow(child2, left + width - c2_width, top, c2_width, height);
            },
            types.winmethod.Above => {
                // child1 (key) on top, child2 on bottom
                const c1_height = @min(key_size, height);
                layoutWindow(child1, left, top, width, c1_height);
                layoutWindow(child2, left, top + c1_height, width, height - c1_height);
            },
            types.winmethod.Below => {
                // child1 on top, child2 (key) on bottom
                const c2_height = @min(key_size, height);
                layoutWindow(child1, left, top, width, height - c2_height);
                layoutWindow(child2, left, top + height - c2_height, width, c2_height);
            },
            else => {
                // Unknown direction, give all space to child1
                layoutWindow(child1, left, top, width, height);
            },
        }
    }
}

/// Queue window updates for all non-pair windows
pub fn queueAllWindowUpdates() void {
    var win = state.window_list;
    while (win) |w| : (win = w.next) {
        // Only send updates for non-pair windows
        if (w.win_type != types.wintype.Pair) {
            protocol.queueWindowUpdate(w);
        }
    }
}

const testing = std.testing;

test "pxToCells converts pixels to character cells with margin" {
    try testing.expectEqual(@as(glui32, 80), pxToCells(800, 0, 10));
    try testing.expectEqual(@as(glui32, 79), pxToCells(800, 10, 10)); // (800-10)/10
    try testing.expectEqual(@as(glui32, 40), pxToCells(480, 0, 12));
    try testing.expectEqual(@as(glui32, 0), pxToCells(5, 10, 10)); // usable <= 0
    try testing.expectEqual(@as(glui32, 0), pxToCells(800, 0, 0)); // char_px <= 0
}

test "fixedSplitPx: text splits use char metrics, graphics stays pixels" {
    state.client_metrics.grid_char_w = 10;
    state.client_metrics.grid_char_h = 12;
    state.client_metrics.grid_margin_x = 0;
    state.client_metrics.grid_margin_y = 0;
    var grid = WindowData{ .id = 1, .rock = 0, .win_type = types.wintype.TextGrid };
    try testing.expectEqual(@as(f64, 12), fixedSplitPx(&grid, false, 1)); // 1 row -> 12px
    try testing.expectEqual(@as(f64, 80), fixedSplitPx(&grid, true, 8)); // 8 cols -> 80px
    var gfx = WindowData{ .id = 2, .rock = 0, .win_type = types.wintype.Graphics };
    try testing.expectEqual(@as(f64, 100), fixedSplitPx(&gfx, false, 100)); // pixels
}
