# Zig 0.16 Upgrade — Discovery Notes

Status: **Attempted, then reverted to zig 0.15.2.** Blocked by a zig 0.16.0 +
LLVM 21 toolchain regression affecting the setjmp/longjmp interpreters. This
file records what was done and learned so the next attempt is faster.

Date of investigation: 2026-07. Reverted at commit on `master` pinning
`zig = "0.15.2"` in `mise.toml`.

## TL;DR

- The **Io-model port** (0.16's big std change) and the **build.zig API
  migration** are both understood and were completed successfully — they are the
  easy, mechanical part.
- **8 of 17 interpreters build on 0.16.** The **9 setjmp/exception interpreters**
  (advsys, alan2, alan3, scare, tads2, tads3, scott, taylor, plus — and git) are
  blocked.
- The blocker: with the `exception_handling` target feature on (required for WASM
  setjmp/longjmp), **zig 0.16 miscompiles its own bundled wasi-libc**
  (`libc-top-half/musl/src/setjmp/wasm32/rt.c`) →
  `fatal error: error in backend: undefined tag symbol cannot be weak`.
- A working **build** bypass exists (point zig at wasi-sdk's prebuilt libc via a
  libc file), but the resulting binaries **trap at runtime** (`unreachable`) in
  **both** wasmtime and the browser. So the bypass is not viable as-is.
- **Recommendation: wait for zig to fix the bundled-libc setjmp compilation**
  (zig does not officially support wasm setjmp anyway — see Ziggit thread below).
  When fixed, the whole bypass becomes unnecessary and only the Io port +
  build.zig migration below are needed.

## Part 1 — The Io-model port (DONE, correct, re-apply as-is)

0.16 routes all file/stream/clock ops through a `std.Io` instance, and removed
`std.fs.cwd`, `std.fs.File`, `std.posix.write`, `std.time.timestamp`.

- Add `packages/server/src/io.zig`: a lazily-initialised process-wide
  `std.Io.Threaded` singleton (wasi_glk is a C-ABI object, no `main`, so a global
  is the only option):
  ```zig
  var threaded: std.Io.Threaded = undefined;
  var initialized = false;
  pub fn io() std.Io {
      if (!initialized) { threaded = std.Io.Threaded.init(state.allocator, .{}); initialized = true; }
      return threaded.io();
  }
  ```
- `state.zig`: `file: ?std.fs.File` → `?std.Io.File`; add `file_pos: u64 = 0`
  (0.16 File has **no** seek/getPos/plain read/write — track offset ourselves and
  use positional I/O).
- `stream.zig`: `std.fs.cwd().openFile/createFile` → `std.Io.Dir.cwd().openFile(io, ...)` /
  `createFile(io, ...)`; `f.close()`→`f.close(io)`, `f.sync()`→`f.sync(io)`;
  read → `f.readPositionalAll(io, buf, s.file_pos)` (+advance); write →
  `f.writePositionalAll(io, bytes, s.file_pos)` (+advance); seek → adjust
  `file_pos` (End needs `f.stat(io).size`); getPos → return `file_pos`.
- `protocol.zig`: `std.posix.write(STDOUT,...)` → `std.Io.File.stdout().writeStreamingAll(io, data)`;
  stdin read one byte at a time (unbuffered, to not over-read the pipe) via
  `std.Io.File.stdin().readStreaming(io, &iov)` where `iov = [_][]u8{&byte}`.
- `fileref.zig`: `std.fs.cwd().deleteFile/statFile` → `std.Io.Dir.cwd().deleteFile(io, name)` /
  `statFile(io, name, .{})`.
- `datetime.zig`: `std.time.timestamp()` →
  `@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)`.

## Part 2 — build.zig API migration (DONE, mechanical)

- `Compile` lost the module-linking methods; move them to `root_module`:
  `exe.addCSourceFiles/addCSourceFile/addIncludePath/addObject/addObjectFile/
  linkLibrary/linkSystemLibrary` → `exe.root_module.<same>(...)`. Keep
  `b.addObject(...)` (that's `Build`, not `Compile`).
- `exe.linkLibC()`/`linkLibCpp()` → `exe.root_module.link_libc = true` /
  `link_libcpp = true`.
- `linkSystemLibrary("x")` now takes options: `linkSystemLibrary("x", .{})`.
- `std.process.getEnvVarOwned(b.allocator, K)` (build.zig runs on host, 0.16
  removed it) → `b.graph.environ_map.get(K)` (returns `?[]const u8`).

## Part 3 — The setjmp blocker and what was tried

Trigger: interpreters using setjmp/longjmp set the `exception_handling` CPU
feature + `-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false`, and link
wasi-sdk's `libsetjmp.a`. On 0.16, zig compiles **its bundled wasi-libc with the
exe's target features**, and musl's `setjmp/wasm32/rt.c` fails in the LLVM 21
backend: `undefined tag symbol cannot be weak`.

Approaches tried (all dead ends for a *runnable* result):

1. **Per-source feature** (`-Xclang -target-feature -Xclang +exception-handling`
   in cflags only) — zig overrides target-features from the module CPU, so the
   feature never takes effect (`tags: 0`, no SjLj).
2. **Separate `addObject` for the EH C** — a C-only object with no root source
   file compiles to an **empty** object (0 bytes).
3. **Separate static `addLibrary`** — the EH-feature lib is **dropped** when
   linked into a baseline exe (feature mismatch); `forceUndefinedSymbol` didn't
   pull it. Conclusion: the **exe module itself** must carry the feature for the
   C to link → reintroduces the libc problem.
4. **`link_libc=false` + manually add wasi-sdk `libc.a`/crt** — zig still built
   its bundled libc because a *linked* module (`wasi_glk`) has `link_libc=true`
   (link_libc is graph-wide).
5. **`wasi_glk` with `link_libc=false`** — fails: `c_allocator` requires libc.

### What actually BUILDS (but doesn't run)

Point zig at wasi-sdk's prebuilt libc via a **libc file** (`exe.setLibCFile`),
keeping `link_libc=true`:

```zig
const libc_conf = b.fmt(
    "include_dir={s}\nsys_include_dir={s}\ncrt_dir={s}\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=",
    .{ inc, inc, lib_dir });          // inc = <sysroot>/include/wasm32-wasi, lib_dir = <sysroot>/lib/wasm32-wasi
const wf = b.addWriteFiles();
exe.setLibCFile(wf.add("wasi-sdk-libc.txt", libc_conf));
exe.root_module.link_libc = true;
exe.link_gc_sections = false;         // wasm-ld's gc doesn't treat wasi-sdk crt's _start->main as a root
// also addObjectFile: libsetjmp.a, libwasi-emulated-{signal,process-clocks,getpid,mman}.a,
//                     libc-printscan-long-double.a
```

Result: `git` compiled, linked, instantiated, EH `tags: 2`, ~85K optimized.

### Why it's still not viable

- **Runtime trap.** Both raw and optimized `git.wasm` trap with `unreachable`
  during execution — confirmed in **wasmtime** *and* in the **browser** (JSPI)
  via a playwright probe (`/?interp=git` loading advent.ulx → "Error:
  unreachable"). So it's a real defect in the wasi-sdk-libc/zig integration (heap
  layout / ctors / ABI — not chased to root cause), not just a wasmtime EH gap.
- `wasm-opt -Oz` **further** corrupts the new-EH wasm (warns about deprecated
  `--enable-typed-function-references`; optimized traps earlier than raw).
- `link_gc_sections=false` was needed just to get code linked, which bloats the
  raw wasm (wasm-opt would have to do all DCE).

## Useful incidental findings

- **wasmtime 41 needs `-W exceptions=y`** to even parse new-EH wasm; setjmp
  interpreters are otherwise browser-only (JSPI) and are **not** covered by the 6
  regtests (which use glulxe/fizmo/hugo — all non-setjmp).
- **`packages/example/serve.ts` has a stale story path**: `/advent.ulx` →
  `ROOT_DIR/tests/advent.ulx`, but the file is at
  `packages/server/tests/advent.ulx` → 404. The e2e story load is broken; CI
  doesn't catch it because `./run ci` does **not** run the playwright e2e
  (`testE2E`). Worth fixing independently.
- Browser interp is selectable in the example by wiring
  `interpreterUrl` to a `?interp=` query param — handy for A/B testing interps.
- zig does **not** officially support wasm setjmp/longjmp:
  https://ziggit.dev/t/zig-cc-wasi-and-setjmp/9882

## Next time

1. Re-apply Parts 1 & 2 (fast, mechanical).
2. Check whether a newer zig (0.16.x/0.17) compiles
   `setjmp/wasm32/rt.c` under `+exception_handling` (the `undefined tag symbol
   cannot be weak` bug). If fixed, the setjmp interpreters build with **no
   bypass** — just the original `exception_handling` target + `-wasm-enable-sjlj`
   flags + wasi-sdk `libsetjmp.a`, exactly as on 0.15.2.
3. Only if still broken: revisit the libc-file bypass AND debug the runtime
   `unreachable` trap (start with heap base / `__wasm_call_ctors` / crt vs
   compiler-rt interplay between wasi-sdk libc and zig objects).
