/**
 * `.glktra` serialization and parsing
 *
 * Environment-agnostic helpers for turning the {@link TranscriptStanza} stream
 * produced by {@link WasiGlkClient.transcript} into a `.glktra` file, and back.
 *
 * A `.glktra` file is JSON Lines: one `JSON.stringify(stanza)` per line, each
 * terminated by `\n` (concatenated JSON documents, not one document). Because
 * `JSON.stringify` escapes newlines inside string values, a stanza never spans
 * physical lines, so splitting on `\n` is safe. See
 * https://eblong.com/zarf/glk/glkote/docs.html ("The .glktra File Format").
 *
 * These use only web-standard streaming APIs (`ReadableStream`, `TextEncoder`,
 * `TextDecoder`), available in browsers and Bun/Node alike — no filesystem.
 */

import type { TranscriptStanza } from './worker/transcript';

/** Anything {@link serializeGlktra} accepts: the batched `transcript()` output, or a flat stanza stream/array. */
export type GlktraSource =
  | AsyncIterable<TranscriptStanza[]>
  | AsyncIterable<TranscriptStanza>
  | Iterable<TranscriptStanza>;

/** Flatten a mixed batched/flat/sync stanza source into a single async stream of stanzas. */
async function* flatten(source: GlktraSource): AsyncGenerator<TranscriptStanza> {
  // for-await-of accepts sync Iterable, AsyncIterable<T> and AsyncIterable<T[]>
  // uniformly; Array.isArray distinguishes a batch from a lone stanza (a stanza
  // is never itself an array).
  for await (const item of source as AsyncIterable<TranscriptStanza | TranscriptStanza[]>) {
    if (Array.isArray(item)) yield* item;
    else yield item;
  }
}

/**
 * Serialize a stanza stream into a `.glktra` byte stream (`JSON.stringify(stanza)
 * + "\n"` per stanza, UTF-8). Accepts the batched `AsyncIterable<TranscriptStanza[]>`
 * from {@link WasiGlkClient.transcript} as well as a flat stanza array or stream;
 * batch boundaries are a timing artifact and are flattened away.
 *
 * Pipe the result anywhere — a `Response` for download, an OPFS/R2 writable, a
 * `fetch` body. The stream is lazy: stanzas are pulled from the source on demand.
 */
export function serializeGlktra(source: GlktraSource): ReadableStream<Uint8Array> {
  const stanzas = flatten(source);
  const encoder = new TextEncoder();
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      const { value, done } = await stanzas.next();
      if (done) controller.close();
      else controller.enqueue(encoder.encode(JSON.stringify(value) + '\n'));
    },
    async cancel() {
      await stanzas.return(undefined);
    },
  });
}

/** Adapt a `ReadableStream` to an async iterable of chunks (releases the lock when done). */
async function* readableToChunks(stream: ReadableStream<Uint8Array>): AsyncGenerator<Uint8Array> {
  const reader = stream.getReader();
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      if (value) yield value;
    }
  } finally {
    // On early abort (consumer breaks out of parseGlktra), tell the source to
    // stop — e.g. close a fetch body — rather than leaving it dangling.
    reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

function parseStanza(line: string, lineNum: number): TranscriptStanza {
  let obj: unknown;
  try {
    obj = JSON.parse(line);
  } catch {
    throw new Error(`.glktra parse error at line ${lineNum}: invalid JSON`);
  }
  if (!obj || typeof obj !== 'object' || (obj as { format?: unknown }).format !== 'glkote') {
    throw new Error(`.glktra parse error at line ${lineNum}: expected a {"format":"glkote",...} stanza`);
  }
  return obj as TranscriptStanza;
}

/**
 * Parse a `.glktra` source into a stream of {@link TranscriptStanza}.
 *
 * Strict JSON Lines: splits on `\n`, `JSON.parse`s each non-blank line, and
 * **throws** on a malformed line or a line whose top-level shape isn't
 * `{"format":"glkote",...}`. (Deliberately louder than the worker-side
 * recorder, which silently skips bad input to keep a live session alive — a
 * file you are about to trust for replay should fail fast instead.) Tolerates
 * blank lines and a final line missing its trailing newline.
 *
 * Accepts a whole string, a `ReadableStream<Uint8Array>`, or an async iterable
 * of `Uint8Array`/`string` chunks; partial lines and multi-byte characters are
 * buffered correctly across chunk boundaries.
 */
export async function* parseGlktra(
  source: string | ReadableStream<Uint8Array> | AsyncIterable<Uint8Array | string>,
): AsyncGenerator<TranscriptStanza> {
  const decoder = new TextDecoder();
  let buffer = '';
  let lineNum = 0;

  function* drain(final: boolean): Generator<TranscriptStanza> {
    let idx: number;
    while ((idx = buffer.indexOf('\n')) !== -1) {
      const raw = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 1);
      lineNum++;
      const line = raw.trim();
      if (line.length > 0) yield parseStanza(line, lineNum);
    }
    if (final && buffer.length > 0) {
      lineNum++;
      const line = buffer.trim();
      buffer = '';
      if (line.length > 0) yield parseStanza(line, lineNum);
    }
  }

  if (typeof source === 'string') {
    buffer = source;
    yield* drain(true);
    return;
  }

  const chunks = source instanceof ReadableStream ? readableToChunks(source) : source;
  for await (const chunk of chunks) {
    buffer += typeof chunk === 'string' ? chunk : decoder.decode(chunk, { stream: true });
    yield* drain(false);
  }
  buffer += decoder.decode(); // flush any pending multi-byte tail
  yield* drain(true);
}

/**
 * Parse a `.glktra` source into the array of input events for replay
 * ({@link ClientConfig.replayInputs} / {@link WasiGlkClient.fromGlktra}).
 *
 * Validates that a non-empty recording starts with an `init` event, failing on
 * the main thread rather than letting a malformed transcript crash the worker
 * obscurely. An empty recording yields `[]` (a legal no-op replay).
 */
export async function inputsFromGlktra(
  source: string | ReadableStream<Uint8Array> | AsyncIterable<Uint8Array | string>,
): Promise<TranscriptStanza['input'][]> {
  const inputs: TranscriptStanza['input'][] = [];
  for await (const stanza of parseGlktra(source)) inputs.push(stanza.input);
  if (inputs.length > 0 && (inputs[0] as { type?: unknown }).type !== 'init') {
    throw new Error('.glktra replay must start with an init event');
  }
  return inputs;
}
