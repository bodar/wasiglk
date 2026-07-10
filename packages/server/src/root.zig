// root.zig - WASI-compatible Glk implementation for wasiglk
//
// This implements the Glk API using WASI stdin/stdout for I/O.
// Output is sent as JSON to stdout, input is read from stdin.
// This follows the RemGlk protocol for compatibility.

// Re-export all public types
pub const types = @import("types.zig");
pub const glui32 = types.glui32;
pub const glsi32 = types.glsi32;
pub const winid_t = types.winid_t;
pub const strid_t = types.strid_t;
pub const frefid_t = types.frefid_t;
pub const schanid_t = types.schanid_t;
pub const event_t = types.event_t;
pub const stream_result_t = types.stream_result_t;
pub const DispatchRock = types.DispatchRock;
pub const glktimeval_t = types.glktimeval_t;
pub const glkdate_t = types.glkdate_t;
pub const glkunix_argumentlist_t = types.glkunix_argumentlist_t;
pub const glkunix_startup_t = types.glkunix_startup_t;

// Re-export constants
pub const gestalt = types.gestalt;
pub const evtype = types.evtype;
pub const wintype = types.wintype;
pub const fileusage = types.fileusage;
pub const filemode = types.filemode;
pub const seekmode = types.seekmode;
pub const keycode = types.keycode;

// Re-export internal state for advanced usage
pub const state = @import("state.zig");

// Re-export protocol for custom extensions
pub const protocol = @import("protocol.zig");

// Force linking of all modules that export C functions.
// These modules use `export fn` which makes them available to C code.
comptime {
    _ = @import("gestalt.zig");
    _ = @import("window.zig");
    _ = @import("stream.zig");
    _ = @import("fileref.zig");
    _ = @import("event.zig");
    _ = @import("unicode.zig");
    _ = @import("datetime.zig");
    _ = @import("graphics.zig");
    _ = @import("sound.zig");
    _ = @import("style.zig");
    _ = @import("dispatch.zig");
    _ = @import("blorb.zig");
    _ = @import("garglk.zig");
    _ = @import("resources.zig");
    _ = @import("startup.zig");
}
