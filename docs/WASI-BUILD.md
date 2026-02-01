# Building Emglken with Zig for WASI

This document describes how to build the Interactive Fiction interpreters using Zig to target WebAssembly with WASI (WebAssembly System Interface). This enables running the interpreters on Cloudflare Workers, Wasmtime, Wasmer, and other WASI-compatible runtimes.

## Overview

The traditional Emglken build uses Emscripten to compile C/C++ code to WebAssembly with JavaScript glue code. This alternative build path uses Zig's built-in C/C++ compiler to target `wasm32-wasi`, producing standalone `.wasm` files that work with any WASI runtime.

## Requirements

- **Zig 0.15.0 or later**: https://ziglang.org/download/
- **Git submodules initialized**: The interpreter source code is in submodules

## Quick Start

```bash
# Clone and initialize submodules
git clone https://github.com/curiousdannii/emglken.git
cd emglken
git submodule update --init --recursive

# Build all interpreters
zig build -Doptimize=ReleaseSmall

# Output files will be in zig-out/bin/
ls zig-out/bin/*.wasm
```

## Available Interpreters

| Interpreter | Format | Description | Status |
|-------------|--------|-------------|--------|
| `glulxe.wasm` | Glulx (.ulx, .gblorb) | Reference Glulx implementation | ✅ Working |
| `hugo.wasm` | Hugo (.hex) | Hugo IF interpreter | ✅ Working |
| `git.wasm` | Glulx (.ulx, .gblorb) | Optimized Glulx implementation | ⚠️ Needs setjmp/longjmp |
| `bocfel.wasm` | Z-machine (.z3-.z8, .zblorb) | Z-machine interpreter | ⚠️ Needs C++ fstream |
| `scare.wasm` | ADRIFT (.taf) | SCARE interpreter for ADRIFT games | ⚠️ Needs setjmp/longjmp + zlib |

### Build Status Notes

- **Glulxe and Hugo** build successfully and produce working WASM binaries
- **Git and Scare** use setjmp/longjmp which requires WASM exception handling (not yet standardized in WASI)
- **Bocfel** requires C++ fstream support which is limited in WASI's libc++

## Build Options

```bash
# Debug build (faster compilation, larger output)
zig build

# Release build (optimized for size)
zig build -Doptimize=ReleaseSmall

# Release build (optimized for speed)
zig build -Doptimize=ReleaseFast

# Build specific interpreter
zig build glulxe
zig build git
zig build hugo
zig build bocfel
zig build scare
```

## Architecture

### Comparison with Emscripten Build

| Aspect | Emscripten | Zig/WASI |
|--------|------------|----------|
| **Async handling** | Asyncify transforms synchronous C into resumable code | Blocking stdin/stdout I/O |
| **I/O mechanism** | JavaScript FFI via `EM_JS` | WASI syscalls (fd_read, fd_write) |
| **Output format** | `.js` + `.wasm` | `.wasm` only |
| **Runtime targets** | Browser, Node.js | WASI hosts (Cloudflare, Wasmtime, etc.) |
| **Glk implementation** | RemGlk-rs (Rust) | WASI-Glk (C) |

### I/O Protocol

The WASI build uses a JSON-based protocol over stdin/stdout, compatible with the RemGlk/GlkOte protocol used by the Emscripten build:

**Output (stdout):**
```json
{"type":"init","version":"0.7.6","support":["unicode","hyperlinks","datetime"]}
{"type":"update","content":[{"id":1,"win":1,"op":"create","wintype":3}]}
{"type":"input","gen":1,"windows":[{"id":1,"type":"line"}]}
```

**Input (stdin):**
```
look
```

### WASI-Glk Implementation

The `src/wasi-glk/` directory contains a complete Glk 0.7.6 implementation:

- **`glk.h`** - Standard Glk API header
- **`wasi_glk.c`** - WASI-compatible implementation (~1200 lines)

Features:
- Window management (text buffer, text grid, graphics stubs)
- Stream I/O (memory streams, file streams, window streams)
- Unicode support
- Datetime functions
- Hyperlink support
- File references via WASI filesystem

## Running with WASI Runtimes

### Wasmtime

```bash
# Run with a storyfile
wasmtime --dir=. zig-out/bin/glulxe.wasm -- story.ulx

# Interactive mode
echo "look" | wasmtime --dir=. zig-out/bin/glulxe.wasm -- story.ulx
```

### Wasmer

```bash
wasmer run --dir=. zig-out/bin/glulxe.wasm -- story.ulx
```

### Cloudflare Workers

See `examples/cloudflare-worker/` for a complete example. The basic pattern:

```javascript
import { WASI } from '@cloudflare/workers-wasi';
import glulxeWasm from './glulxe.wasm';

export default {
  async fetch(request) {
    const wasi = new WASI({
      args: ['glulxe', '/game/story.ulx'],
      preopens: { '/game': virtualFS }
    });

    const instance = new WebAssembly.Instance(glulxeWasm, {
      wasi_snapshot_preview1: wasi.wasiImport
    });

    await wasi.start(instance);
    // Handle I/O...
  }
};
```

## Limitations

### No Asyncify

The Emscripten build uses Asyncify to transform synchronous C code (that blocks waiting for user input in `glk_select()`) into asynchronous code that can yield to JavaScript. WASI doesn't have this capability.

The WASI-Glk implementation uses blocking I/O instead:
- `glk_select()` blocks on `fgets(stdin)`
- Output is flushed to stdout before waiting for input
- This works well for request/response patterns (like Cloudflare Workers)

### Sound and Graphics

Sound playback (`GLK_MODULE_SOUND`) and graphics (`GLK_MODULE_IMAGE`) are not implemented in the WASI build. The gestalt functions report these as unavailable.

### Timer Events

Timer events are not supported in the basic WASI implementation since there's no background thread or async mechanism.

## Development

### Adding a New Interpreter

1. Add a build function in `build.zig`:

```zig
fn buildNewInterp(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "newinterp",
        .target = target,
        .optimize = optimize,
    });

    exe.addCSourceFiles(.{
        .root = b.path("newinterp"),
        .files = &.{ "main.c", "..." },
        .flags = &.{ "-Wall", "-D_WASI_EMULATED_SIGNAL" },
    });

    exe.addCSourceFiles(.{
        .root = b.path("src/wasi-glk"),
        .files = &.{"wasi_glk.c"},
        .flags = &.{ "-D_WASI_EMULATED_SIGNAL" },
    });

    exe.addIncludePath(b.path("newinterp"));
    exe.addIncludePath(b.path("src/wasi-glk"));
    exe.linkLibC();

    return exe;
}
```

2. Register it in the `build()` function:

```zig
const newinterp = buildNewInterp(b, target, optimize);
b.installArtifact(newinterp);
```

### Modifying WASI-Glk

The WASI-Glk implementation in `src/wasi-glk/wasi_glk.c` can be extended to support additional features. Key areas:

- **JSON output**: `json_append()` and `json_flush()` functions
- **Event handling**: `glk_select()` function
- **Window management**: `glk_window_*` functions
- **Stream I/O**: `glk_stream_*` and `glk_put_*`/`glk_get_*` functions

## Resources

- [Cloudflare Workers WASI](https://developers.cloudflare.com/workers/runtime-apis/webassembly/)
- [WASI specification](https://wasi.dev/)
- [Zig WASM documentation](https://ziglang.org/documentation/master/#WebAssembly)
- [Glk API specification](https://www.eblong.com/zarf/glk/)
- [RemGlk protocol](https://github.com/erkyrath/remglk)
