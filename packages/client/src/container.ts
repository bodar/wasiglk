/**
 * Single-file containers.
 *
 * A story is always delivered as one file: either the bare story, or a
 * container that holds the story plus companion resource files (an `.a3r`
 * resource blorb for alan3, a `.blorb` for jacl, media for Hugo, a second disk
 * image for Scott/Taylor, …). Today the only supported container is a plain
 * zip.
 *
 * The container is never unpacked across an interface — it travels to the
 * worker as one blob and is exploded into the in-memory `/sys` directory there,
 * so each interpreter sees a normal game folder and its own companion-file
 * logic (which derives sibling names from the story filename, or opens a name
 * baked into the story) just works. This module only sniffs and unpacks; it
 * does not know about the worker filesystem.
 */
import { unzipSync } from 'fflate';
import { detectFormat, type FormatInfo } from './format';

/** Local file header signature "PK\x03\x04" that begins every zip. */
const ZIP_MAGIC = [0x50, 0x4b, 0x03, 0x04];

/** True if `data` is a zip container (as opposed to a bare story file). */
export function isZip(data: Uint8Array): boolean {
  return data.length >= 4 && ZIP_MAGIC.every((b, i) => data[i] === b);
}

/** One file unpacked from a container. `name` is a bare filename, never a path. */
export interface ContainerEntry {
  name: string;
  data: Uint8Array;
}

/**
 * Unpack a zip into a flat list of `basename → bytes` entries. Directory
 * entries and any path components are dropped so files land as siblings in one
 * directory — which is how interpreters expect a game's files to sit relative
 * to each other. Empty and path-traversal names (`.`, `..`) are skipped.
 */
export function unzipEntries(data: Uint8Array): ContainerEntry[] {
  const raw = unzipSync(data);
  const entries: ContainerEntry[] = [];
  const seen = new Set<string>();
  for (const [path, bytes] of Object.entries(raw)) {
    if (path.endsWith('/')) continue; // directory record
    const name = path.split('/').pop() ?? '';
    if (!name || name === '.' || name === '..') continue;
    // Everything flattens into one directory, so two archive paths can collide
    // on a basename (e.g. `a/game.ulx` and `b/game.ulx`). Keep the first — the
    // archive order is deterministic, so the client's primary pick and the
    // worker's /sys end up built from one identical set rather than desyncing.
    if (seen.has(name)) continue;
    seen.add(name);
    entries.push({ name, data: bytes });
  }
  return entries;
}

/** The story file within a container, plus its detected format. */
export interface PrimarySelection {
  primary: ContainerEntry;
  formatInfo: FormatInfo;
}

/**
 * Choose the entry that is the actual story file — the one an interpreter loads
 * as `argv[1]`. Companions (`.a3r`, `.blorb`, media, extra disk images) detect
 * as an unknown format, so the first entry that detects as a known story format
 * wins. `override` forces a format (from `ClientConfig.format`): the entry
 * matching it is preferred, else the largest file. With nothing recognised we
 * fall back to the largest entry.
 */
export function pickPrimary(
  entries: ContainerEntry[],
  override?: FormatInfo,
): PrimarySelection {
  if (entries.length === 0) throw new Error('Container is empty');

  // Detect once per entry; every branch below reads from this single pass.
  const detected = entries.map((entry) => ({ entry, fi: detectFormat(entry.name, entry.data) }));
  const largest = () =>
    detected.reduce((a, b) => (b.entry.data.length > a.entry.data.length ? b : a));

  if (override) {
    const match = detected.find((d) => d.fi.format === override.format);
    return { primary: (match ?? largest()).entry, formatInfo: override };
  }

  const chosen = detected.find((d) => d.fi.format !== 'unknown') ?? largest();
  return { primary: chosen.entry, formatInfo: chosen.fi };
}
