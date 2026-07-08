/**
 * AGT → AGX conversion.
 *
 * Classic AGT games are multi-file (`.da1`–`.da6`, `.ttl`, `.d$$`, …) and
 * cannot be served or run as a single blob. AGiliTy's own portable container
 * is AGX: one file the interpreter loads directly. This runs the `agt2agx`
 * WASI tool over the game's files entirely in memory (no disk, no network),
 * suitable for a Cloudflare Worker, and returns the AGX bytes.
 */
import { WASI, File, OpenFile, PreopenDirectory, ConsoleStdout, WASIProcExit } from '@bjorn3/browser_wasi_shim';

/** AGX file signature (little-endian 0x51C1C758). */
const AGX_MAGIC = [0x58, 0xc7, 0xc1, 0x51];

/**
 * Pack a classic multi-file AGT game into a single AGX file.
 *
 * @param agtModule A compiled `agt2agx.wasm` module. On Cloudflare Workers this
 *   must be a statically-imported (bundled) `WebAssembly.Module` — the runtime
 *   forbids compiling Wasm from bytes at request time.
 * @param files The game's files keyed by name (e.g. `CRUSADE.DA1`). Case does
 *   not matter; names are lowercased internally. Must include a `.da1` member.
 * @returns The AGX bytes.
 * @throws If no `.da1` is present, the converter exits non-zero, or the output
 *   is not a valid AGX file.
 */
export function agtToAgx(agtModule: WebAssembly.Module, files: Record<string, Uint8Array>): Uint8Array {
  // agt2agx opens `<base>.da1` (lowercase extension) first; its uppercase-retry
  // fallback rewrites the entire path (including the `/in` preopen) to upper
  // case, which no longer matches. Mounting everything lowercase makes the
  // first open succeed and sidesteps the retry.
  const contents = new Map<string, File>();
  let base: string | undefined;
  for (const [name, data] of Object.entries(files)) {
    const lower = name.toLowerCase();
    contents.set(lower, new File(data));
    if (lower.endsWith('.da1')) base = lower.slice(0, -4);
  }
  if (!base) throw new Error('agtToAgx: no .da1 file among inputs');

  const log: string[] = [];
  const wasi = new WASI(
    ['agt2agx', `/in/${base}`],
    [],
    [
      new OpenFile(new File(new Uint8Array())),
      ConsoleStdout.lineBuffered((line) => log.push(line)),
      ConsoleStdout.lineBuffered((line) => log.push(line)),
      new PreopenDirectory('/in', contents),
    ],
  );

  const instance = new WebAssembly.Instance(agtModule, { wasi_snapshot_preview1: wasi.wasiImport });

  let code = 0;
  try {
    wasi.start(instance as { exports: { memory: WebAssembly.Memory; _start: () => unknown } });
  } catch (e) {
    if (e instanceof WASIProcExit) code = e.code;
    else throw e;
  }

  const out = contents.get(`${base}.agx`);
  if (code !== 0 || !out) {
    throw new Error(`agtToAgx: conversion failed (exit ${code}): ${log.join(' ').trim()}`);
  }
  const d = out.data;
  if (d.length < 4 || AGX_MAGIC.some((b, i) => d[i] !== b)) {
    throw new Error('agtToAgx: output is not a valid AGX file');
  }
  return d;
}
