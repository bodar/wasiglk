import { describe, expect, test } from 'bun:test';
import { TranscriptRecorder, type TranscriptStanza } from '../src/worker/transcript';
import type { RemGlkUpdate } from '../src/protocol';

/** Make a recorder wired to an array sink; returns [recorder, captured]. */
function makeRecorder(sessionId = 'sess-1', label = 'advent.ulx'): [TranscriptRecorder, TranscriptStanza[]] {
  const captured: TranscriptStanza[] = [];
  const recorder = new TranscriptRecorder(sessionId, label, s => captured.push(s));
  return [recorder, captured];
}

const update = (gen: number, extra: Partial<RemGlkUpdate> = {}): RemGlkUpdate => ({
  type: 'update', gen, ...extra,
});

describe('TranscriptRecorder', () => {
  test('pairs one input with the following output into a single stanza', () => {
    const [recorder, captured] = makeRecorder();

    recorder.recordInput(JSON.stringify({ type: 'line', gen: 1, window: 1, value: 'go north' }), 1000);
    recorder.recordOutput(update(2, { content: [{ id: 1, text: [] }] }), 1005);

    expect(captured).toHaveLength(1);
    const stanza = captured[0];
    expect(stanza.format).toBe('glkote');
    expect(stanza.sessionId).toBe('sess-1');
    expect(stanza.label).toBe('advent.ulx');
    expect(stanza.timestamp).toBe(1000);
    expect(stanza.outtimestamp).toBe(1005);
  });

  test('input and output are stored as raw objects, not strings', () => {
    const [recorder, captured] = makeRecorder();

    recorder.recordInput(JSON.stringify({ type: 'line', gen: 1, window: 1, value: 'x me' }), 1);
    recorder.recordOutput(update(2), 2);

    expect(typeof captured[0].input).toBe('object');
    expect(typeof captured[0].output).toBe('object');
    expect(captured[0].input).toEqual({ type: 'line', gen: 1, window: 1, value: 'x me' });
    expect(captured[0].output).toEqual({ type: 'update', gen: 2 });
  });

  test('concatenating stringified stanzas yields newline-framed .glktra', () => {
    const [recorder, captured] = makeRecorder();

    recorder.recordInput(JSON.stringify({ type: 'init', gen: 0 }), 1);
    recorder.recordOutput(update(1), 2);
    recorder.recordInput(JSON.stringify({ type: 'line', gen: 1, window: 1, value: 'wait' }), 3);
    recorder.recordOutput(update(2), 4);

    const file = captured.map(s => JSON.stringify(s) + '\n').join('');
    const lines = file.split('\n').filter(l => l.length > 0);
    expect(lines).toHaveLength(2);
    expect(file.endsWith('\n')).toBe(true);
    // Each line is itself valid JSON (concatenated documents, not one document).
    for (const line of lines) expect(() => JSON.parse(line)).not.toThrow();
  });

  test('timer ticks are recorded as ordinary input events', () => {
    const [recorder, captured] = makeRecorder();

    recorder.recordInput(JSON.stringify({ type: 'timer', gen: 5 }), 100);
    recorder.recordOutput(update(6, { timer: 1000 }), 101);

    expect(captured).toHaveLength(1);
    expect((captured[0].input as { type: string }).type).toBe('timer');
    // The armed interval rides in the output update, so replay knows both.
    expect(captured[0].output.timer).toBe(1000);
  });

  test('output with no preceding input produces no stanza', () => {
    const [recorder, captured] = makeRecorder();

    recorder.recordOutput(update(1), 1);

    expect(captured).toHaveLength(0);
  });

  test('a pending input is consumed by exactly one output', () => {
    const [recorder, captured] = makeRecorder();

    recorder.recordInput(JSON.stringify({ type: 'line', gen: 1, window: 1, value: 'look' }), 1);
    recorder.recordOutput(update(2), 2);
    recorder.recordOutput(update(3), 3); // no pending input — must not emit

    expect(captured).toHaveLength(1);
  });

  test('malformed input JSON is skipped without throwing or emitting', () => {
    const [recorder, captured] = makeRecorder();

    expect(() => recorder.recordInput('not json{', 1)).not.toThrow();
    recorder.recordOutput(update(1), 2);

    expect(captured).toHaveLength(0);
  });
});
