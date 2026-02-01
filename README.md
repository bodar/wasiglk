# wasiglk

Interactive Fiction interpreters compiled to WebAssembly (WASI) using Zig.

## Overview

wasiglk compiles IF interpreters to WebAssembly with WASI, enabling them to run in browsers using [JSPI (JavaScript Promise Integration)](https://github.com/aspect-labs/aspect-engineering/blob/main/aspect-blog/2024-10-16-async-wasm.md) or in any WASI-compatible runtime.

The interpreters use a Glk implementation (`src/wasi_glk.zig`) that communicates via JSON over stdin/stdout, compatible with the RemGlk protocol.

## Building

Requires [Zig 0.15+](https://ziglang.org/).

The Git interpreter additionally requires [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) for its precompiled `libsetjmp.a` (setjmp/longjmp support via WASM exception handling). Install via [mise](https://mise.jdx.dev/): `mise install wasi-sdk@27` or set `WASI_SDK_PATH` to your wasi-sdk installation.

```bash
# Build all interpreters
zig build -Doptimize=ReleaseSmall

# Build specific interpreter
zig build glulxe -Doptimize=ReleaseSmall

# Output in zig-out/bin/
ls zig-out/bin/*.wasm
```

## Interpreters

| Name | Language | Format | License | Status |
|------|----------|--------|---------|--------|
| [Glulxe](https://github.com/erkyrath/glulxe) | C | Glulx (.ulx, .gblorb) | MIT | Working |
| [Hugo](https://github.com/hugoif/hugo-unix) | C | Hugo (.hex) | BSD-2-Clause | Working |
| [Git](https://github.com/DavidKinder/Git) | C | Glulx | MIT | Working (requires wasi-sdk) |
| [Bocfel](https://github.com/garglk/garglk) | C++ | Z-machine (.z3-.z8) | MIT | Needs fstream support |

## Browser Usage with JSPI

See `examples/jspi-browser/` for a complete browser example using JSPI.

JSPI allows WebAssembly to suspend execution while waiting for async JavaScript operations (like user input), without requiring Asyncify transformation.

**Browser Support:**
- Chrome 131+: JSPI enabled by default
- Chrome 128-130: Enable `chrome://flags/#enable-experimental-webassembly-jspi`

```javascript
import { runWithJSPI } from './jspi-wasi.js';

await runWithJSPI(wasmBytes, {
    args: ['glulxe', 'story.ulx'],
    storyData: storyFileBytes,
    onOutput: (json) => { /* handle RemGlk output */ },
    getInput: async () => { /* return user input */ },
});
```

## Project Structure

```
wasiglk/
├── build.zig           # Zig build configuration
├── src/
│   ├── wasi_glk.zig    # Zig Glk implementation
│   ├── glk.h           # Glk API header
│   ├── gi_dispa.c      # Glk dispatch layer
│   └── gi_blorb.c      # Blorb support
├── glulxe/             # Glulxe interpreter (submodule)
├── hugo/               # Hugo interpreter (submodule)
├── git/                # Git interpreter (submodule)
├── garglk/             # Garglk (contains Bocfel)
└── examples/
    └── jspi-browser/   # Browser JSPI example
```

## License

MIT. See [LICENSE](LICENSE) for details.

Individual interpreters retain their original licenses (MIT or BSD-2-Clause).
