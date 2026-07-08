import { describe, expect, test } from 'bun:test';
import { readFileSync, readdirSync } from 'fs';
import { join } from 'path';
import { agtToAgx } from '../src/agt';
import { detectFormatFromData } from '../src/format';

const wasmPath = join(import.meta.dir, '../wasm/agt2agx.wasm');
const agtModule = await WebAssembly.compile(readFileSync(wasmPath));

// Real multi-file AGT game (Crusade, David Malmberg, 1987 freeware from the
// IF Archive) — the canonical case this converter exists for.
function crusadeFiles(): Record<string, Uint8Array> {
  const dir = join(import.meta.dir, 'fixtures/agt');
  const files: Record<string, Uint8Array> = {};
  for (const name of readdirSync(dir)) files[name] = new Uint8Array(readFileSync(join(dir, name)));
  return files;
}

describe('agtToAgx', () => {
  test('packs a classic multi-file AGT game into a valid AGX', () => {
    const agx = agtToAgx(agtModule, crusadeFiles());
    // AGX signature 0x51C1C758 (little-endian).
    expect(Array.from(agx.slice(0, 4))).toEqual([0x58, 0xc7, 0xc1, 0x51]);
    // Sanity: a real game, not a stub/error dump.
    expect(agx.length).toBeGreaterThan(10_000);
    // The result is recognised as an AGT/agility story by content.
    expect(detectFormatFromData(agx)?.interpreter).toBe('agility');
  });

  test('throws when no .da1 file is present', () => {
    expect(() => agtToAgx(agtModule, { 'readme.txt': new Uint8Array([1, 2, 3]) }))
      .toThrow(/no \.da1/);
  });
});
