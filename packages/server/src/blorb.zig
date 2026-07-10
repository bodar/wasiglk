// blorb.zig - Blorb resource file support

const types = @import("types.zig");

const glui32 = types.glui32;
const strid_t = types.strid_t;

// Blorb types
pub const giblorb_err_t = glui32;
pub const giblorb_map_t = opaque {};

// Image info structure (matches gi_blorb.h)
pub const giblorb_image_info_t = extern struct {
    chunktype: glui32,
    width: glui32,
    height: glui32,
    alttext: ?[*:0]u8,
};

// Blorb chunk type constants
pub const giblorb_ID_PNG: glui32 = 0x504e4720; // 'PNG '
pub const giblorb_ID_JPEG: glui32 = 0x4a504547; // 'JPEG'
pub const giblorb_ID_Pict: glui32 = 0x50696374; // 'Pict'

// Resource-load methods (gi_blorb.h)
pub const giblorb_method_DontLoad: glui32 = 0;
pub const giblorb_method_Memory: glui32 = 1;
pub const giblorb_method_FilePos: glui32 = 2;

// Result of loading a resource/chunk (matches gi_blorb.h giblorb_result_t).
pub const giblorb_result_t = extern struct {
    chunknum: glui32,
    data: extern union {
        ptr: ?*anyopaque,
        startpos: glui32,
    },
    length: glui32,
    chunktype: glui32,
};

pub var blorb_map: ?*giblorb_map_t = null;

// These are provided by gi_blorb.c
pub extern fn giblorb_create_map(file: strid_t, newmap: *?*giblorb_map_t) callconv(.c) giblorb_err_t;
pub extern fn giblorb_destroy_map(map: ?*giblorb_map_t) callconv(.c) giblorb_err_t;
pub extern fn giblorb_load_image_info(map: ?*giblorb_map_t, resnum: glui32, res: *giblorb_image_info_t) callconv(.c) giblorb_err_t;
pub extern fn giblorb_load_resource(map: ?*giblorb_map_t, method: glui32, res: *giblorb_result_t, usage: glui32, resnum: glui32) callconv(.c) giblorb_err_t;

/// Load an image resource's raw bytes from the current Blorb map, if any.
/// Returns a slice into memory owned by the Blorb library (valid until the map
/// is destroyed) — do not free it. Null if there is no map or no such image.
pub fn loadImageBytes(resnum: glui32) ?[]const u8 {
    const map = blorb_map orelse return null;
    var res: giblorb_result_t = undefined;
    const err = giblorb_load_resource(map, giblorb_method_Memory, &res, giblorb_ID_Pict, resnum);
    if (err != 0) return null;
    const ptr = res.data.ptr orelse return null;
    return @as([*]const u8, @ptrCast(ptr))[0..res.length];
}

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
