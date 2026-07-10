import { describe, expect, test } from 'bun:test';
import { zipSync } from 'fflate';
import { isZip, unzipEntries, pickPrimary } from '../src/container';

// 'Glul' magic — a bare Glulx story detectFormatFromData recognises.
const GLULX = new Uint8Array([0x47, 0x6c, 0x75, 0x6c, 0, 3, 1, 0]);
const bytes = (...b: number[]) => new Uint8Array(b);

describe('isZip', () => {
  test('true for a zip (PK\\x03\\x04), false for a bare story', () => {
    const zip = zipSync({ 'a.txt': bytes(1) });
    expect(isZip(zip)).toBe(true);
    expect(isZip(GLULX)).toBe(false);
    expect(isZip(bytes(0x50, 0x4b))).toBe(false); // too short
  });
});

describe('unzipEntries', () => {
  test('flattens to basenames and drops directory paths', () => {
    const zip = zipSync({
      'game/story.ulx': GLULX,
      'game/story.a3r': bytes(9, 9, 9),
    });
    const names = unzipEntries(zip).map((e) => e.name).sort();
    expect(names).toEqual(['story.a3r', 'story.ulx']);
  });

  test('dedupes colliding basenames to the first (client and worker agree)', () => {
    // Two archive paths flatten to the same basename; keep the first so the
    // client's primary pick and the worker's /sys build from one identical set.
    const zip = zipSync({ 'a/game.ulx': GLULX, 'b/game.ulx': bytes(1, 2, 3) });
    const entries = unzipEntries(zip);
    expect(entries.map((e) => e.name)).toEqual(['game.ulx']);
    expect(Array.from(entries[0].data)).toEqual(Array.from(GLULX));
  });

  test('round-trips file bytes', () => {
    const zip = zipSync({ 'story.ulx': GLULX });
    const [entry] = unzipEntries(zip);
    expect(entry.name).toBe('story.ulx');
    expect(Array.from(entry.data)).toEqual(Array.from(GLULX));
  });
});

describe('pickPrimary', () => {
  test('picks the story file, not the companion resource', () => {
    // alan3 case: .acd story + .a3r resource blorb sibling.
    const entries = unzipEntries(
      zipSync({ 'story.a3r': bytes(0, 0, 0), 'story.acd': bytes(65) }),
    );
    const { primary, formatInfo } = pickPrimary(entries);
    expect(primary.name).toBe('story.acd');
    expect(formatInfo.format).toBe('alan3');
    expect(formatInfo.interpreter).toBe('alan3');
  });

  test('detects the story by content when the name has no clue', () => {
    const entries = unzipEntries(
      zipSync({ 'data.bin': bytes(0, 0), 'game': GLULX }),
    );
    const { primary, formatInfo } = pickPrimary(entries);
    expect(primary.name).toBe('game');
    expect(formatInfo.format).toBe('glulx');
  });

  test('override forces the format and matches the right entry', () => {
    const entries = unzipEntries(
      zipSync({ 'notes.txt': bytes(1), 'x.acd': bytes(65) }),
    );
    const { primary } = pickPrimary(entries, {
      format: 'alan3', interpreter: 'alan3', isBlorb: false,
    });
    expect(primary.name).toBe('x.acd');
  });

  test('falls back to the largest entry when nothing is recognised', () => {
    // 0xff-prefixed bytes match no story magic (low bytes look like z-code).
    const entries = unzipEntries(
      zipSync({ 'small.bin': bytes(0xff), 'big.bin': bytes(0xff, 0xff, 0xff, 0xff, 0xff) }),
    );
    expect(pickPrimary(entries).primary.name).toBe('big.bin');
  });

  test('throws on an empty container', () => {
    expect(() => pickPrimary([])).toThrow(/empty/);
  });
});
