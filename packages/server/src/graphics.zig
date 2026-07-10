// graphics.zig - Glk graphics and image functions

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const protocol = @import("protocol.zig");
const blorb = @import("blorb.zig");
const resources = @import("resources.zig");

const glui32 = types.glui32;
const glsi32 = types.glsi32;
const winid_t = types.winid_t;
const wintype = types.wintype;
const WindowData = state.WindowData;

// Resolve an image's natural pixel dimensions from whichever resource map holds
// it: the Blorb map (glulx/git/fizmo story Blorbs and Hugo's synthesized one)
// or the garglk file-resource table (Scare). Null if neither knows the image.
fn imageDims(image: glui32) ?resources.Dims {
    if (blorb.blorb_map) |map| {
        var info: blorb.giblorb_image_info_t = undefined;
        if (blorb.giblorb_load_image_info(map, image, &info) == 0)
            return .{ .width = info.width, .height = info.height };
    }
    return resources.getDims(image);
}

// Emit an image draw op. When the client can resolve image numbers itself
// (it holds the story's Blorb) we send the number; otherwise (Hugo/Scare) we
// ship the pixels inline as a `data:` URI read from the server-side bytes.
fn emitImageDraw(w: *WindowData, image: glui32, val1: glsi32, val2: glsi32, width: glui32, height: glui32) void {
    protocol.flushTextBuffer();

    var uri: ?[]u8 = null;
    defer if (uri) |u| state.allocator.free(u);
    var image_num: ?glui32 = image;

    if (state.server_resolves_images) {
        const bytes = blorb.loadImageBytes(image) orelse resources.getBytes(image);
        if (bytes) |b| {
            if (resources.dataUri(state.allocator, b)) |u| {
                uri = u;
                image_num = null;
            }
        }
    }

    // Buffer windows: val1 is alignment, val2 unused. Graphics: val1=x, val2=y.
    if (w.win_type == wintype.TextBuffer) {
        protocol.sendImageUpdate(w.id, image_num, uri, val1, width, height);
    } else if (w.win_type == wintype.Graphics) {
        protocol.sendGraphicsImageUpdate(w.id, image_num, uri, val1, val2, width, height);
    }
}

export fn glk_image_get_info(image: glui32, width: ?*glui32, height: ?*glui32) callconv(.c) glui32 {
    if (imageDims(image)) |d| {
        if (width) |w| w.* = d.width;
        if (height) |h| h.* = d.height;
        return 1;
    }
    if (width) |w| w.* = 0;
    if (height) |h| h.* = 0;
    return 0;
}

export fn glk_image_draw(win: winid_t, image: glui32, val1: glsi32, val2: glsi32) callconv(.c) glui32 {
    const w: *WindowData = @ptrCast(@alignCast(win orelse return 0));

    const dims = imageDims(image) orelse return 0;
    emitImageDraw(w, image, val1, val2, dims.width, dims.height);
    return 1;
}

export fn glk_image_draw_scaled(win: winid_t, image: glui32, val1: glsi32, val2: glsi32, width: glui32, height: glui32) callconv(.c) glui32 {
    const w: *WindowData = @ptrCast(@alignCast(win orelse return 0));

    // Verify the image exists; draw at the caller's requested size.
    if (imageDims(image) == null) return 0;
    emitImageDraw(w, image, val1, val2, width, height);
    return 1;
}

export fn glk_window_flow_break(win: winid_t) callconv(.c) void {
    const w: ?*WindowData = @ptrCast(@alignCast(win));
    if (w == null) return;
    if (w.?.win_type != wintype.TextBuffer) return;

    protocol.flushTextBuffer();
    protocol.sendFlowBreakUpdate(w.?.id);
}

export fn glk_window_erase_rect(win: winid_t, left: glsi32, top: glsi32, width: glui32, height: glui32) callconv(.c) void {
    const w: ?*WindowData = @ptrCast(@alignCast(win));
    if (w == null) return;
    if (w.?.win_type != wintype.Graphics) return;

    protocol.flushTextBuffer();
    protocol.sendGraphicsEraseUpdate(w.?.id, left, top, width, height);
}

export fn glk_window_fill_rect(win: winid_t, color: glui32, left: glsi32, top: glsi32, width: glui32, height: glui32) callconv(.c) void {
    const w: ?*WindowData = @ptrCast(@alignCast(win));
    if (w == null) return;
    if (w.?.win_type != wintype.Graphics) return;

    protocol.flushTextBuffer();
    protocol.sendGraphicsFillUpdate(w.?.id, color, left, top, width, height);
}

export fn glk_window_set_background_color(win: winid_t, color: glui32) callconv(.c) void {
    const w: ?*WindowData = @ptrCast(@alignCast(win));
    if (w == null) return;
    if (w.?.win_type != wintype.Graphics) return;

    protocol.flushTextBuffer();
    protocol.sendGraphicsSetColorUpdate(w.?.id, color);
}
