import { describe, expect, test } from 'bun:test';
import { serializeGlktra, parseGlktra, inputsFromGlktra } from '../src/glktra';
import type { TranscriptStanza } from '../src/worker/transcript';

const stanza = (gen: number, value: string): TranscriptStanza => ({
  format: 'glkote',
  input: { type: 'line', gen, window: 1, value },
  output: { type: 'update', gen: gen + 1 },
  sessionId: 'sess-1',
  label: 'advent.ulx',
  timestamp: gen * 10,
  outtimestamp: gen * 10 + 1,
});

const initStanza: TranscriptStanza = {
  format: 'glkote',
  input: { type: 'init', gen: 0, metrics: { width: 80, height: 24 } },
  output: { type: 'update', gen: 0 },
  sessionId: 'sess-1',
  label: 'advent.ulx',
  timestamp: 0,
  outtimestamp: 1,
};

/** Drain a byte stream to a string. */
async function streamText(stream: ReadableStream<Uint8Array>): Promise<string> {
  return new Response(stream).text();
}

/** Collect an async iterable into an array. */
async function collect<T>(it: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const x of it) out.push(x);
  return out;
}

async function* asyncFrom<T>(items: T[]): AsyncGenerator<T> {
  for (const x of items) yield x;
}

describe('serializeGlktra', () => {
  test('serializes a flat array to newline-framed JSON', async () => {
    const stanzas = [stanza(1, 'a'), stanza(2, 'b')];
    const text = await streamText(serializeGlktra(stanzas));

    expect(text).toBe(stanzas.map(s => JSON.stringify(s) + '\n').join(''));
    const lines = text.split('\n').filter(l => l.length > 0);
    expect(lines).toHaveLength(2);
    for (const l of lines) expect(() => JSON.parse(l)).not.toThrow();
  });

  test('flattens a batched AsyncIterable<TranscriptStanza[]> with uneven batches', async () => {
    const batches: TranscriptStanza[][] = [[stanza(1, 'a'), stanza(2, 'b')], [stanza(3, 'c')]];
    const text = await streamText(serializeGlktra(asyncFrom(batches)));
    const parsed = await collect(parseGlktra(text));

    expect(parsed).toEqual([stanza(1, 'a'), stanza(2, 'b'), stanza(3, 'c')]);
  });

  test('accepts a flat async generator of single stanzas', async () => {
    const text = await streamText(serializeGlktra(asyncFrom([stanza(1, 'a')])));
    expect(await collect(parseGlktra(text))).toEqual([stanza(1, 'a')]);
  });

  test('an empty source yields an empty stream', async () => {
    expect(await streamText(serializeGlktra([]))).toBe('');
  });
});

describe('parseGlktra', () => {
  test('round-trips serializeGlktra output through a real ReadableStream', async () => {
    const stanzas = [initStanza, stanza(1, 'go north'), stanza(2, 'x me')];
    const parsed = await collect(parseGlktra(serializeGlktra(stanzas)));
    expect(parsed).toEqual(stanzas);
  });

  test('parses a JSON line split mid-line across chunks', async () => {
    const s = stanza(1, 'a');
    const full = JSON.stringify(s) + '\n';
    const mid = Math.floor(full.length / 2);
    const enc = new TextEncoder();
    const chunks = asyncFrom([enc.encode(full.slice(0, mid)), enc.encode(full.slice(mid))]);
    expect(await collect(parseGlktra(chunks))).toEqual([s]);
  });

  test('decodes a multi-byte UTF-8 character split across a chunk boundary', async () => {
    const s = stanza(1, 'café ☕'); // multi-byte chars
    const bytes = new TextEncoder().encode(JSON.stringify(s) + '\n');
    // Split at every byte to stress the streaming decoder / line buffer.
    const chunks = asyncFrom(Array.from(bytes, b => new Uint8Array([b])));
    const parsed = await collect(parseGlktra(chunks));
    expect(parsed).toEqual([s]);
    expect((parsed[0].input as { value: string }).value).toBe('café ☕');
  });

  test('tolerates blank lines and a missing trailing newline', async () => {
    const s1 = stanza(1, 'a');
    const s2 = stanza(2, 'b');
    const text = `\n${JSON.stringify(s1)}\n\n${JSON.stringify(s2)}`; // no final newline
    expect(await collect(parseGlktra(text))).toEqual([s1, s2]);
  });

  test('throws on a malformed JSON line, with the line number', async () => {
    const text = `${JSON.stringify(stanza(1, 'a'))}\nnot json{\n`;
    await expect(collect(parseGlktra(text))).rejects.toThrow(/line 2: invalid JSON/);
  });

  test('throws on a well-formed line that is not a glkote stanza', async () => {
    const text = `${JSON.stringify({ hello: 'world' })}\n`;
    await expect(collect(parseGlktra(text))).rejects.toThrow(/expected a .*glkote.* stanza/);
  });
});

describe('inputsFromGlktra', () => {
  test('returns each stanza input in order', async () => {
    const stanzas = [initStanza, stanza(1, 'go north'), stanza(2, 'x me')];
    const inputs = await inputsFromGlktra(serializeGlktra(stanzas));
    expect(inputs).toEqual(stanzas.map(s => s.input));
  });

  test('throws when a non-empty recording does not start with an init event', async () => {
    const text = await streamText(serializeGlktra([stanza(1, 'a')]));
    await expect(inputsFromGlktra(text)).rejects.toThrow(/must start with an init event/);
  });

  test('an empty recording is a legal no-op replay', async () => {
    expect(await inputsFromGlktra('')).toEqual([]);
  });
});
