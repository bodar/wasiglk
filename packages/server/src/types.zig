// types.zig - Core Glk type definitions and constants

const std = @import("std");

// ============== Basic Types ==============

pub const glui32 = u32;
pub const glsi32 = i32;

// Opaque pointer types for C compatibility
pub const Window = opaque {};
pub const Stream = opaque {};
pub const FileRef = opaque {};
pub const SoundChannel = opaque {};

pub const winid_t = ?*Window;
pub const strid_t = ?*Stream;
pub const frefid_t = ?*FileRef;
pub const schanid_t = ?*SoundChannel;

// ============== Structures ==============

// Event structure (matches C layout)
pub const event_t = extern struct {
    type: glui32,
    win: winid_t,
    val1: glui32,
    val2: glui32,
};

pub const stream_result_t = extern struct {
    readcount: glui32,
    writecount: glui32,
};

// Dispatch rock type (matches gidispatch_rock_t in gi_dispa.h)
// IMPORTANT: Must include dummy_variant to ensure 8-byte size on WASM32,
// matching the C union which has an int64_t member for Rust compatibility.
// Without this, the union would be 4 bytes on WASM32 vs 8 bytes in C,
// causing ABI mismatch and memory corruption.
pub const DispatchRock = extern union {
    num: glui32,
    ptr: ?*anyopaque,
    dummy_variant: i64,
};

// ============== Glk Constants ==============

pub const gestalt = struct {
    pub const Version: glui32 = 0;
    pub const CharInput: glui32 = 1;
    pub const LineInput: glui32 = 2;
    pub const CharOutput: glui32 = 3;
    pub const CharOutput_CannotPrint: glui32 = 0;
    pub const CharOutput_ApproxPrint: glui32 = 1;
    pub const CharOutput_ExactPrint: glui32 = 2;
    pub const MouseInput: glui32 = 4;
    pub const Timer: glui32 = 5;
    pub const Graphics: glui32 = 6;
    pub const DrawImage: glui32 = 7;
    pub const Sound: glui32 = 8;
    pub const SoundVolume: glui32 = 9;
    pub const SoundNotify: glui32 = 10;
    pub const Hyperlinks: glui32 = 11;
    pub const HyperlinkInput: glui32 = 12;
    pub const SoundMusic: glui32 = 13;
    pub const GraphicsTransparency: glui32 = 14;
    pub const Unicode: glui32 = 15;
    pub const UnicodeNorm: glui32 = 16;
    pub const LineInputEcho: glui32 = 17;
    pub const LineTerminators: glui32 = 18;
    pub const LineTerminatorKey: glui32 = 19;
    pub const DateTime: glui32 = 20;
    pub const Sound2: glui32 = 21;
    pub const ResourceStream: glui32 = 22;
    pub const GraphicsCharInput: glui32 = 23;
};

pub const evtype = struct {
    pub const None: glui32 = 0;
    pub const Timer: glui32 = 1;
    pub const CharInput: glui32 = 2;
    pub const LineInput: glui32 = 3;
    pub const MouseInput: glui32 = 4;
    pub const Arrange: glui32 = 5;
    pub const Redraw: glui32 = 6;
    pub const SoundNotify: glui32 = 7;
    pub const Hyperlink: glui32 = 8;
};

pub const wintype = struct {
    pub const AllTypes: glui32 = 0;
    pub const Pair: glui32 = 1;
    pub const Blank: glui32 = 2;
    pub const TextBuffer: glui32 = 3;
    pub const TextGrid: glui32 = 4;
    pub const Graphics: glui32 = 5;
};

pub const fileusage = struct {
    pub const Data: glui32 = 0x00;
    pub const SavedGame: glui32 = 0x01;
    pub const Transcript: glui32 = 0x02;
    pub const InputRecord: glui32 = 0x03;
    pub const TypeMask: glui32 = 0x0f;
    pub const TextMode: glui32 = 0x100;
    pub const BinaryMode: glui32 = 0x000;
};

pub const filemode = struct {
    pub const Write: glui32 = 0x01;
    pub const Read: glui32 = 0x02;
    pub const ReadWrite: glui32 = 0x03;
    pub const WriteAppend: glui32 = 0x05;
};

pub const seekmode = struct {
    pub const Start: glui32 = 0;
    pub const Current: glui32 = 1;
    pub const End: glui32 = 2;
};

pub const keycode = struct {
    pub const Unknown: glui32 = 0xffffffff;
    pub const Left: glui32 = 0xfffffffe;
    pub const Right: glui32 = 0xfffffffd;
    pub const Up: glui32 = 0xfffffffc;
    pub const Down: glui32 = 0xfffffffb;
    pub const Return: glui32 = 0xfffffffa;
    pub const Delete: glui32 = 0xfffffff9;
    pub const Escape: glui32 = 0xfffffff8;
    pub const Tab: glui32 = 0xfffffff7;
    pub const PageUp: glui32 = 0xfffffff6;
    pub const PageDown: glui32 = 0xfffffff5;
    pub const Home: glui32 = 0xfffffff4;
    pub const End: glui32 = 0xfffffff3;
};

// ============== DateTime Structures ==============

pub const glktimeval_t = extern struct {
    high_sec: glsi32,
    low_sec: glui32,
    microsec: glsi32,
};

pub const glkdate_t = extern struct {
    year: glsi32,
    month: glsi32,
    day: glsi32,
    weekday: glsi32,
    hour: glsi32,
    minute: glsi32,
    second: glsi32,
    microsec: glsi32,
};

// ============== Glkunix Structures ==============

pub const glkunix_argumentlist_t = extern struct {
    name: ?[*:0]const u8,
    argtype: c_int,
    desc: ?[*:0]const u8,
};

pub const glkunix_startup_t = extern struct {
    argc: c_int,
    argv: [*][*:0]u8,
};
