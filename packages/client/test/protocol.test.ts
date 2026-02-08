import { describe, expect, test } from 'bun:test';
import type { RemGlkUpdate, ContentSpan, TextSpan } from '../src/protocol';

describe('RemGlkUpdate protocol types', () => {
  test('content span can be a plain string', () => {
    const span: ContentSpan = 'Hello, world!';
    expect(typeof span).toBe('string');
  });

  test('content span can be a text span with style', () => {
    const span: ContentSpan = { style: 'emphasized', text: 'Important text' };
    expect((span as TextSpan).text).toBe('Important text');
    expect((span as TextSpan).style).toBe('emphasized');
  });

  test('content span can be a text span with hyperlink', () => {
    const span: ContentSpan = { style: 'normal', text: 'click here', hyperlink: 42 };
    expect((span as TextSpan).hyperlink).toBe(42);
  });

  test('RemGlkUpdate has expected shape for buffer content', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 2,
      content: [
        {
          id: 1,
          text: [{ append: true, content: [{ style: 'normal', text: 'Hello, world!' }] }],
        },
      ],
    };

    expect(update.content).toHaveLength(1);
    expect(update.content![0].id).toBe(1);
    expect(update.content![0].text).toHaveLength(1);
    expect(update.content![0].text![0].content).toHaveLength(1);
  });

  test('RemGlkUpdate has expected shape for grid content', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 10,
      content: [
        {
          id: 2,
          lines: [
            { line: 0, content: [' At End Of Road                     Score: 36    Moves: 1'] },
          ],
        },
      ],
    };

    expect(update.content![0].lines).toHaveLength(1);
    expect(update.content![0].lines![0].line).toBe(0);
  });

  test('RemGlkUpdate can contain windows, content, and input together', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 1,
      windows: [{ id: 1, type: 'buffer', rock: 0, width: 80, height: 25 }],
      content: [{ id: 1, text: [{ content: [{ style: 'normal', text: 'Welcome' }] }] }],
      input: [{ id: 1, type: 'line', maxlen: 255 }],
    };

    expect(update.windows).toHaveLength(1);
    expect(update.content).toHaveLength(1);
    expect(update.input).toHaveLength(1);
  });

  test('RemGlkUpdate error type', () => {
    const update: RemGlkUpdate = {
      type: 'error',
      gen: 0,
      message: 'Something went wrong',
    };

    expect(update.type).toBe('error');
    expect(update.message).toBe('Something went wrong');
  });

  test('RemGlkUpdate timer field', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 12,
      timer: 1000,
    };

    expect(update.timer).toBe(1000);
  });

  test('RemGlkUpdate timer null cancels timer', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 13,
      timer: null,
    };

    expect(update.timer).toBe(null);
  });
});
