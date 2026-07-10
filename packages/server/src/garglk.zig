// garglk.zig - Garglk extension stubs
//
// These are informational functions used by some interpreters.
// For our JSON-over-stdin/stdout protocol, these are no-ops.

const std = @import("std");
const types = @import("types.zig");
const resources = @import("resources.zig");

const glui32 = types.glui32;
const strid_t = types.strid_t;

export fn garglk_set_program_name(_: ?[*:0]const u8) callconv(.c) void {}
export fn garglk_set_program_info(_: ?[*:0]const u8) callconv(.c) void {}
export fn garglk_set_story_name(_: ?[*:0]const u8) callconv(.c) void {}
export fn garglk_set_story_title(_: ?[*:0]const u8) callconv(.c) void {}

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

// Register a byte-range of a file as an image/sound resource and return its id.
// Scare uses this to expose graphics embedded in its .taf story; the bytes are
// read out of the mounted story now and resolved to pixels server-side.
export fn garglk_add_resource_from_file(usage: glui32, filename: ?[*:0]const u8, offset: glui32, len: glui32) callconv(.c) glui32 {
    const name_ptr = filename orelse return 0;
    return resources.addResourceFromFile(usage, std.mem.span(name_ptr), offset, len);
}
