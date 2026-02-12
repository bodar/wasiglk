// fileref.zig - Glk file reference functions

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const dispatch = @import("dispatch.zig");

const glui32 = types.glui32;
const frefid_t = types.frefid_t;
const fileusage = types.fileusage;
const FileRefData = state.FileRefData;
const allocator = state.allocator;

export fn glk_fileref_create_temp(usage: glui32, rock: glui32) callconv(.c) frefid_t {
    var buf: [64]u8 = undefined;
    const filename = std.fmt.bufPrint(&buf, "glktmp_{d}", .{state.fileref_id_counter}) catch return null;

    const fref = allocator.create(FileRefData) catch return null;
    const filename_copy = allocator.dupe(u8, filename) catch {
        allocator.destroy(fref);
        return null;
    };

    fref.* = FileRefData{
        .id = state.fileref_id_counter,
        .rock = rock,
        .filename = filename_copy,
        .usage = usage,
        .textmode = (usage & fileusage.TextMode) != 0,
    };
    state.fileref_id_counter += 1;

    fref.next = state.fileref_list;
    if (state.fileref_list) |list| list.prev = fref;
    state.fileref_list = fref;

    // Register with dispatch system
    if (dispatch.object_register_fn) |register_fn| {
        fref.dispatch_rock = register_fn(@ptrCast(fref), dispatch.gidisp_Class_Fileref);
    }

    return @ptrCast(fref);
}

pub export fn glk_fileref_create_by_name(usage: glui32, name: ?[*:0]const u8, rock: glui32) callconv(.c) frefid_t {
    const name_ptr = name orelse return null;
    const name_span = std.mem.span(name_ptr);
    const filename_copy = allocator.dupe(u8, name_span) catch return null;

    const fref = allocator.create(FileRefData) catch {
        allocator.free(filename_copy);
        return null;
    };

    fref.* = FileRefData{
        .id = state.fileref_id_counter,
        .rock = rock,
        .filename = filename_copy,
        .usage = usage,
        .textmode = (usage & fileusage.TextMode) != 0,
    };
    state.fileref_id_counter += 1;

    fref.next = state.fileref_list;
    if (state.fileref_list) |list| list.prev = fref;
    state.fileref_list = fref;

    // Register with dispatch system
    if (dispatch.object_register_fn) |register_fn| {
        fref.dispatch_rock = register_fn(@ptrCast(fref), dispatch.gidisp_Class_Fileref);
    }

    return @ptrCast(fref);
}

export fn glk_fileref_create_by_prompt(usage: glui32, fmode: glui32, rock: glui32) callconv(.c) frefid_t {
    const protocol = @import("protocol.zig");

    // Send specialinput and wait for user response (JSPI suspends here)
    const filename = protocol.sendSpecialInputAndWait(fmode, usage) orelse {
        return null; // User cancelled
    };
    defer allocator.free(filename);

    // Create the fileref with the returned filename
    const fref = allocator.create(FileRefData) catch return null;
    const filename_copy = allocator.dupe(u8, filename) catch {
        allocator.destroy(fref);
        return null;
    };

    fref.* = FileRefData{
        .id = state.fileref_id_counter,
        .rock = rock,
        .filename = filename_copy,
        .usage = usage,
        .textmode = (usage & fileusage.TextMode) != 0,
    };
    state.fileref_id_counter += 1;

    fref.next = state.fileref_list;
    if (state.fileref_list) |list| list.prev = fref;
    state.fileref_list = fref;

    // Register with dispatch system
    if (dispatch.object_register_fn) |register_fn| {
        fref.dispatch_rock = register_fn(@ptrCast(fref), dispatch.gidisp_Class_Fileref);
    }

    return @ptrCast(fref);
}

export fn glk_fileref_create_from_fileref(usage: glui32, fref_opaque: frefid_t, rock: glui32) callconv(.c) frefid_t {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return null;
    return glk_fileref_create_by_name(usage, @ptrCast(fref.?.filename.ptr), rock);
}

pub export fn glk_fileref_destroy(fref_opaque: frefid_t) callconv(.c) void {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return;
    const f = fref.?;

    // Unregister from dispatch system
    if (dispatch.object_unregister_fn) |unregister_fn| {
        unregister_fn(@ptrCast(f), dispatch.gidisp_Class_Fileref, f.dispatch_rock);
    }

    // Remove from list
    if (f.prev) |p| p.next = f.next else state.fileref_list = f.next;
    if (f.next) |n| n.prev = f.prev;

    // Free the C string copy if it was allocated
    if (f.filename_cstr) |cstr| {
        const slice: [:0]const u8 = std.mem.span(cstr);
        allocator.free(slice);
    }
    allocator.free(f.filename);
    allocator.destroy(f);
}

export fn glk_fileref_iterate(fref_opaque: frefid_t, rockptr: ?*glui32) callconv(.c) frefid_t {
    var fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) {
        fref = state.fileref_list;
    } else {
        fref = fref.?.next;
    }

    if (fref) |f| {
        if (rockptr) |r| r.* = f.rock;
    }
    return @ptrCast(fref);
}

export fn glk_fileref_get_rock(fref_opaque: frefid_t) callconv(.c) glui32 {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref) |f| return f.rock;
    return 0;
}

export fn glk_fileref_delete_file(fref_opaque: frefid_t) callconv(.c) void {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return;
    std.fs.cwd().deleteFile(fref.?.filename) catch return;
}

export fn glk_fileref_does_file_exist(fref_opaque: frefid_t) callconv(.c) glui32 {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return 0;
    _ = std.fs.cwd().statFile(fref.?.filename) catch return 0;
    return 1;
}

// Unix Glk extension: get filename from fileref as C string
// The returned pointer is valid until the fileref is destroyed
export fn glkunix_fileref_get_filename(fref_opaque: frefid_t) callconv(.c) ?[*:0]const u8 {
    const fref: ?*FileRefData = @ptrCast(@alignCast(fref_opaque));
    if (fref == null) return null;
    const f = fref.?;

    // Return cached C string if already allocated
    if (f.filename_cstr) |cstr| return cstr;

    // Allocate null-terminated copy
    const cstr = allocator.dupeZ(u8, f.filename) catch return null;
    f.filename_cstr = cstr.ptr;
    return cstr.ptr;
}
