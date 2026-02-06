# wasiglk

**Work in Progress** - Interactive Fiction interpreters compiled to WebAssembly (WASI) using Zig.

## Overview

wasiglk is inspired by [emglken](https://github.com/curiousdannii/emglken), which compiles IF interpreters to WebAssembly using Emscripten and Asyncify. This project takes a different approach:

| | emglken | wasiglk |
|---|---------|---------|
| **Compiler** | Emscripten | Zig (with C sources) |
| **Target** | JavaScript/WASM | WASI |
| **Async handling** | Asyncify (code transformation) | [JSPI](https://v8.dev/blog/jspi) (native browser feature) |
| **Glk implementation** | RemGlk-rs (Rust) | Custom Zig implementation |

### WASM Binary Size Comparison

The combination of Zig, WASI, JSPI, and wasm-opt produces dramatically smaller binaries:

| Interpreter | emglken | wasiglk | Reduction |
|-------------|---------|---------|-----------|
| glulxe.wasm | 1.68 MB | 240 KB | **86% smaller** |
| git.wasm | 1.68 MB | 249 KB | **85% smaller** |
| hugo.wasm | 1.12 MB | 207 KB | **82% smaller** |
| tads2.wasm | 3.9 MB | 671 KB | **83% smaller** |
| tads3.wasm | 3.9 MB | 1.32 MB | **66% smaller** |
| scare.wasm | 1.82 MB | 447 KB | **76% smaller** |

**Why WASI?** Targeting [WASI](https://wasi.dev/) instead of Emscripten's custom runtime means portable binaries that run in browsers (via a shim), Node.js, Bun, Deno, and standalone runtimes like Wasmtime. WASI binaries are self-contained with no generated JavaScript glue code, and WASI is a W3C standard with broad industry backing rather than a project-specific runtime.

**Why Zig?** Zig can target `wasm32-wasi` natively, cross-compiling C sources without Emscripten's toolchain complexity. Combined with WASI and wasm-opt, this produces the dramatically smaller binaries shown above.

**Why JSPI?** JSPI (JavaScript Promise Integration) is a native browser feature that allows WASM to suspend and resume execution without code transformation, resulting in smaller binaries and better performance.

**Current limitations:** JSPI is cutting-edge technology currently only available in Chrome 131+. Firefox has experimental support that can be enabled via `about:config` by setting `javascript.options.wasm_js_promise_integration` to `true`. Additionally, Bocfel (C++ Z-machine interpreter) is blocked on upstream wasi-sdk changes for C++ exception handling. In the long term, JSPI should achieve wide browser support and become the preferred approach for async WASM.

The interpreters use a Glk implementation (in `packages/server/src/`) that communicates via JSON over stdin/stdout, compatible with the RemGlk protocol.

## Getting Started

The `./run` script auto-installs all required tools (Zig, Bun, wasi-sdk) on first run:

```bash
./run build    # Build all interpreters
./run test     # Run tests
./run serve    # Start dev server
```

## Interpreters

| Name | Language | Format | Extensions | License | WASM | Native |
|------|----------|--------|------------|---------|------|--------|
| [AdvSys](https://github.com/garglk/garglk) | C | AdvSys | .dat | [BSD-3-Clause](https://github.com/garglk/garglk/blob/master/licenses/BSD-3-Clause.txt) | ✅ | ✅ |
| [Agility](https://github.com/garglk/garglk) | C | AGT | .agx, .d$$ | [GPL-2.0](https://github.com/garglk/garglk/blob/master/licenses/GNU%20General%20Public%20License.txt) | ✅ | ✅ |
| [Alan2](https://github.com/garglk/garglk) | C | Alan 2 | .acd | [Artistic-2.0](https://github.com/garglk/garglk/blob/master/licenses/Artistic%20License%202.0.txt) | ✅ | ✅ |
| [Alan3](https://github.com/garglk/garglk) | C | Alan 3 | .a3c | [Artistic-2.0](https://github.com/garglk/garglk/blob/master/licenses/Artistic%20License%202.0.txt) | ✅ | ✅ |
| [Bocfel](https://github.com/garglk/garglk) | C++ | Z-machine | .z3-.z8 | [MIT](https://github.com/garglk/garglk/blob/master/licenses/MIT%20License.txt) | ❌ (C++ exceptions) | ✅ |
| [Fizmo](https://github.com/danielbodart/libfizmo) | C | Z-machine (v1-5, 7, 8) | .z1-.z5, .z7, .z8, .zblorb | [BSD-3-Clause](https://github.com/chrender/fizmo/blob/master/LICENSE) | ✅ | ✅ |
| [Git](https://github.com/DavidKinder/Git) | C | Glulx | .ulx, .gblorb | [MIT](https://github.com/DavidKinder/Git/blob/master/LICENSE) | ✅ | ✅ |
| [Glulxe](https://github.com/erkyrath/glulxe) | C | Glulx | .ulx, .gblorb | [MIT](https://github.com/erkyrath/glulxe/blob/master/LICENSE) | ✅ | ✅ |
| [Hugo](https://github.com/hugoif/hugo-unix) | C | Hugo | .hex | [BSD-2-Clause](https://github.com/hugoif/hugo-unix/blob/master/License.txt) | ✅ | ✅ |
| [JACL](https://github.com/garglk/garglk) | C | JACL | .j2 | [GPL-2.0](https://github.com/garglk/garglk/blob/master/licenses/GNU%20General%20Public%20License.txt) | ✅ | ✅ |
| [Level9](https://github.com/garglk/garglk) | C | Level 9 | .l9, .sna | [GPL-2.0](https://github.com/garglk/garglk/blob/master/licenses/GNU%20General%20Public%20License.txt) | ✅ | ✅ |
| [Magnetic](https://github.com/garglk/garglk) | C | Magnetic Scrolls | .mag | [GPL-2.0](https://github.com/garglk/garglk/blob/master/licenses/GNU%20General%20Public%20License.txt) | ✅ | ✅ |
| [Scare](https://github.com/garglk/garglk) | C | ADRIFT | .taf | [GPL-2.0](https://github.com/garglk/garglk/blob/master/licenses/GNU%20General%20Public%20License.txt) | ✅ | ✅ |
| [TADS 2](https://github.com/garglk/garglk) | C | TADS 2 | .gam | [TADS Freeware](https://www.tads.org/t3doc/license.txt) | ✅ | ✅ |
| [TADS 3](https://github.com/garglk/garglk) | C++ | TADS 3 | .t3 | [TADS Freeware](https://www.tads.org/t3doc/license.txt) | ✅ | ✅ |

### Native-Only Interpreters

**Bocfel** is a C++ interpreter that uses C++ exceptions (`throw`/`catch`) for control flow. Its WASM build is blocked because wasi-sdk doesn't ship `libc++`/`libc++abi` with C++ exception support. (TADS 3 also uses C++ but its error handling is setjmp/longjmp-based, so it compiles to WASM without C++ exception support.)

**What's needed for C++ WASM support:**
- wasi-sdk built with `LIBCXX_ENABLE_EXCEPTIONS=ON`, `LIBCXXABI_ENABLE_EXCEPTIONS=ON`, and `libunwind`
- Compile flags: `-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false`
- Link flags: `-lunwind`

**Tracking:**
- [wasi-sdk#565](https://github.com/WebAssembly/wasi-sdk/issues/565) - C++ exception support tracking issue
- [Build instructions gist](https://gist.github.com/yerzham/302efcec6a2e82c1e8de4aed576ea29d) - How to build wasi-sdk with exception support (requires LLVM 21.1.5+)

## Browser Usage

The `@wasiglk/client` package provides a TypeScript client for running interpreters in the browser using JSPI.

**Browser Support:**
- Chrome 131+: JSPI enabled by default
- Chrome 128-130: Enable `chrome://flags/#enable-experimental-webassembly-jspi`
- Firefox: Enable `javascript.options.wasm_js_promise_integration` in `about:config`

```typescript
import { createClient } from '@wasiglk/client';

const client = await createClient({
  storyUrl: '/stories/adventure.gblorb',
  workerUrl: '/worker.js',  // Required: URL to the bundled worker script
});

// Run the interpreter and handle updates
for await (const update of client.updates({ width: 80, height: 24 })) {
  switch (update.type) {
    case 'content':
      // Display text content
      console.log(update.text);
      break;

    case 'input-request':
      // Prompt user for input
      const input = await getUserInput(update.inputType);
      client.sendInput(input);
      break;

    case 'window':
      // Handle window creation/updates
      break;
  }
}

// Stop the interpreter when done
client.stop();
```

The client handles:
- Automatic format detection from file extension or Blorb contents
- Loading the appropriate interpreter WASM module
- Parsing Blorb files and providing image URLs
- Converting RemGlk protocol to typed updates
- Running interpreter in a Web Worker for responsive UI
- Configurable file storage (OPFS, file dialogs, or in-memory)

### File Storage

The `filesystem` option controls how save files and other user data are persisted:

```typescript
const client = await createClient({
  storyUrl: '/stories/adventure.gblorb',
  workerUrl: '/worker.js',
  filesystem: 'auto', // 'auto' | 'opfs' | 'memory' | 'dialog'
});
```

| Mode | Description |
|------|-------------|
| `'auto'` | (Default) Uses OPFS if available, falls back to in-memory |
| `'opfs'` | Origin Private File System - persistent storage that survives page reloads. Throws if unavailable. |
| `'memory'` | In-memory only - files are lost when the page is closed |
| `'dialog'` | Shows native file dialogs for save/restore, with OPFS for other files. Allows users to save to their local filesystem. |

**When to use each mode:**

- **`'auto'`** - Best for most applications. Saves "just work" without user interaction.
- **`'opfs'`** - When you need guaranteed persistence and want to fail explicitly if unavailable.
- **`'memory'`** - For demos, testing, or when you don't want saves to persist.
- **`'dialog'`** - When users need portable save files they can back up or transfer between devices.

See `packages/example/` for a complete working example. Run it with:

```bash
cd packages/example
bun run dev
```

## Architecture

### Separation of Concerns

```
┌─────────────────────────────────────────────────────────────────┐
│  Main Thread                                                    │
│  - UI rendering                                                 │
│  - User input handling                                          │
│  - Blorb parsing (images stay here)                             │
│  - Client API (WasiGlkClient)                                   │
└───────────────────────────┬─────────────────────────────────────┘
                            │ postMessage (JSON only)
┌───────────────────────────┴─────────────────────────────────────┐
│  Web Worker                                                     │
│  - WASM interpreter execution                                   │
│  - WASI implementation (browser_wasi_shim)                      │
│  - Pluggable storage (OPFS, memory, or file dialogs)            │
│  - JSPI for async stdin                                         │
└─────────────────────────────────────────────────────────────────┘
```

### Why This Architecture?

**Worker for WASM**: Keeps main thread responsive. Heavy interpreter
computation doesn't block UI.

**Pluggable Storage**: File storage is configurable per-client. OPFS provides
synchronous file access in Workers with persistence across page reloads.
File dialogs allow users to save to their local filesystem. In-memory mode
is available for testing or demos.

**JSPI for Input**: JavaScript Promise Integration allows WASM to suspend
while waiting for user input, without Asyncify code transformation.

**Blorb on Main Thread**: Images are referenced by ID in the RemGlk protocol.
The interpreter sends "draw image 5", the client looks up image 5 in the
Blorb and renders it. No large binary transfers between threads.

### Graphics Flow

```
Interpreter (Worker)              Client (Main Thread)
─────────────────────             ────────────────────
glk_image_draw(5, x, y)
        │
        ▼
JSON: {"image": 5, "x": 10}  ──►  Receive update
                                         │
                                         ▼
                                  blorb.getImageUrl(5)
                                         │
                                         ▼
                                  Render <img src="blob:...">
```

### Sound (Future)

Sound will follow the same pattern as graphics:
- Interpreter sends sound commands (play, stop, volume)
- Client extracts audio from Blorb
- Client handles playback via Web Audio API

## Project Structure

```
wasiglk/
├── run                     # Build script (auto-installs tools)
├── package.json
├── packages/
│   ├── client/             # TypeScript client library
│   │   ├── src/
│   │   │   ├── client.ts   # Main client (Worker communication)
│   │   │   ├── worker/     # Web Worker implementation
│   │   │   │   └── storage/ # Pluggable storage providers
│   │   │   ├── blorb.ts    # Blorb parser
│   │   │   └── protocol.ts # RemGlk protocol types
│   │   └── package.json
│   ├── example/            # Browser example using @wasiglk/client
│   │   ├── src/main.ts     # Example entry point
│   │   ├── public/         # Static files
│   │   └── serve.ts        # Dev server
│   ├── server/             # Zig GLK implementation + interpreters
│   │   ├── build.zig       # Zig build configuration
│   │   └── src/
│   │       ├── root.zig    # Module entry point
│   │       ├── protocol.zig # RemGlk JSON protocol
│   │       ├── window.zig  # Window functions
│   │       ├── stream.zig  # Stream I/O functions
│   │       └── ...         # Other Glk modules
│   ├── garglk/             # Garglk interpreters (submodule)
│   ├── git/                # Git interpreter (submodule)
│   ├── glulxe/             # Glulxe interpreter (submodule)
│   ├── hugo/               # Hugo interpreter (submodule)
│   └── zlib/               # zlib for Scare (submodule)
└── tests/                  # Test story files
```

## License

MIT. See [LICENSE](LICENSE) for details.

Individual interpreters retain their original licenses (MIT, BSD-2-Clause, or GPL-2.0).
