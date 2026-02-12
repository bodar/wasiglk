// startup.zig - Glkunix startup and main entry point

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const stream = @import("stream.zig");
const fileref = @import("fileref.zig");
const protocol = @import("protocol.zig");

const glui32 = types.glui32;
const strid_t = types.strid_t;
const fileusage = types.fileusage;
const filemode = types.filemode;
const glkunix_argumentlist_t = types.glkunix_argumentlist_t;
const glkunix_startup_t = types.glkunix_startup_t;
const allocator = state.allocator;

// These are defined by the interpreter
extern var glkunix_arguments: [*]glkunix_argumentlist_t;
extern fn glkunix_startup_code(data: *glkunix_startup_t) callconv(.c) c_int;
extern fn glk_main() callconv(.c) void;

export fn glkunix_set_base_file(filename: ?[*:0]const u8) callconv(.c) void {
    const filename_ptr = filename orelse return;

    if (state.workdir) |w| allocator.free(w);

    const path = std.mem.span(filename_ptr);
    state.workdir = if (std.fs.path.dirname(path)) |dir|
        allocator.dupe(u8, dir) catch null
    else
        allocator.dupe(u8, ".") catch null;
}

export fn glkunix_stream_open_pathname_gen(pathname: ?[*:0]const u8, writemode: glui32, textmode: glui32, rock: glui32) callconv(.c) strid_t {
    if (pathname == null) return null;
    const fref = fileref.glk_fileref_create_by_name(
        (if (textmode != 0) fileusage.TextMode else fileusage.BinaryMode) | fileusage.Data,
        pathname,
        0,
    );
    if (fref == null) return null;

    const fmode = if (writemode != 0) filemode.Write else filemode.Read;
    const str = stream.glk_stream_open_file(fref, fmode, rock);
    fileref.glk_fileref_destroy(fref);

    return str;
}

export fn glkunix_stream_open_pathname(pathname: ?[*:0]const u8, textmode: glui32, rock: glui32) callconv(.c) strid_t {
    return glkunix_stream_open_pathname_gen(pathname, 0, textmode, rock);
}

// Main entry point for glkunix model - Glk library provides main
fn wasiGlkMain(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    // Output initialization message
    protocol.ensureGlkInitialized();

    // Call interpreter's startup code
    var startdata = glkunix_startup_t{
        .argc = argc,
        .argv = argv,
    };

    const startup_result = glkunix_startup_code(&startdata);
    if (startup_result == 0) {
        protocol.sendError("Startup failed");
        return 1;
    }

    glk_main();

    // Import glk_exit from gestalt module
    const gestalt = @import("gestalt.zig");
    gestalt.glk_exit();
}

comptime {
    if (!@import("builtin").is_test) {
        @export(&wasiGlkMain, .{ .name = "main", .linkage = .strong });
    }
}
