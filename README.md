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

| Name | Language | Format | License | WASM | Native |
|------|----------|--------|---------|------|--------|
| [Glulxe](https://github.com/erkyrath/glulxe) | C | Glulx (.ulx, .gblorb) | MIT | ✅ | ✅ |
| [Hugo](https://github.com/hugoif/hugo-unix) | C | Hugo (.hex) | BSD-2-Clause | ✅ | ✅ |
| [Git](https://github.com/DavidKinder/Git) | C | Glulx | MIT | ✅ (requires wasi-sdk) | ✅ |
| [Bocfel](https://github.com/garglk/garglk) | C++ | Z-machine (.z3-.z8) | MIT | ❌ (C++ exceptions) | ✅ |
| [Scare](https://github.com/garglk/garglk) | C | ADRIFT (.taf) | GPL-2.0 | ❌ (needs zlib) | ✅ |
| [TADS](https://github.com/garglk/garglk) | C/C++ | TADS 2/3 (.gam, .t3) | GPL-2.0 | ❌ (C++ exceptions) | ✅ |

### Native-Only Interpreters

**Bocfel and TADS** are C++ interpreters that use exceptions for control flow. WASM builds are blocked because wasi-sdk doesn't ship `libc++`/`libc++abi` with C++ exception support.

**Scare** requires zlib for TAF file decompression. WASM builds are blocked because wasi-sdk doesn't include zlib. Could be enabled by bundling zlib source.

**What's needed for C++ WASM support:**
- wasi-sdk built with `LIBCXX_ENABLE_EXCEPTIONS=ON`, `LIBCXXABI_ENABLE_EXCEPTIONS=ON`, and `libunwind`
- Compile flags: `-fwasm-exceptions -mllvm -wasm-use-legacy-eh=false`
- Link flags: `-lunwind`

**Tracking:**
- [wasi-sdk#565](https://github.com/WebAssembly/wasi-sdk/issues/565) - C++ exception support tracking issue
- [Build instructions gist](https://gist.github.com/yerzham/302efcec6a2e82c1e8de4aed576ea29d) - How to build wasi-sdk with exception support (requires LLVM 21.1.5+)

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

Individual interpreters retain their original licenses (MIT, BSD-2-Clause, or GPL-2.0).
