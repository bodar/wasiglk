import { describe, expect, test } from 'bun:test';
import { parseRemGlkUpdate, type RemGlkUpdate } from '../src/protocol';

// Default image URL resolver for tests
const noopResolver = () => undefined;

describe('parseRemGlkUpdate', () => {
  test('parses content update with plain text (paragraph format)', () => {
    // GlkOte spec: buffer window text uses paragraph structure
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

    const results = parseRemGlkUpdate(update, noopResolver);

    const contentUpdate = results.find((u) => u.type === 'content');
    expect(contentUpdate).toBeDefined();
    expect(contentUpdate?.type).toBe('content');
    if (contentUpdate?.type === 'content') {
      expect(contentUpdate.windowId).toBe(1);
      expect(contentUpdate.content).toHaveLength(1);
      expect(contentUpdate.content[0].type).toBe('text');
      expect(contentUpdate.content[0].text).toBe('Hello, world!');
    }
  });

  test('parses content with string spans (paragraph format)', () => {
    // GlkOte spec: buffer window text uses paragraph structure
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 3,
      content: [
        {
          id: 1,
          text: [{ append: true, content: ['Plain text as string'] }],
        },
      ],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const contentUpdate = results.find((u) => u.type === 'content');
    expect(contentUpdate?.type).toBe('content');
    if (contentUpdate?.type === 'content') {
      expect(contentUpdate.content[0].text).toBe('Plain text as string');
    }
  });

  test('parses content with image special span (paragraph format)', () => {
    const imageUrlResolver = (num: number) =>
      num === 5 ? 'blob:test-image-5' : undefined;

    // GlkOte spec: buffer window text uses paragraph structure
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 4,
      content: [
        {
          id: 1,
          text: [
            {
              append: true,
              content: [
                {
                  special: {
                    type: 'image',
                    image: 5,
                    width: 100,
                    height: 80,
                  },
                },
              ],
            },
          ],
        },
      ],
    };

    const results = parseRemGlkUpdate(update, imageUrlResolver);

    const contentUpdate = results.find((u) => u.type === 'content');
    expect(contentUpdate?.type).toBe('content');
    if (contentUpdate?.type === 'content') {
      expect(contentUpdate.content).toHaveLength(1);
      expect(contentUpdate.content[0].type).toBe('image');
      expect(contentUpdate.content[0].imageNumber).toBe(5);
      expect(contentUpdate.content[0].imageUrl).toBe('blob:test-image-5');
      expect(contentUpdate.content[0].width).toBe(100);
      expect(contentUpdate.content[0].height).toBe(80);
    }
  });

  test('parses content with flowbreak (paragraph format)', () => {
    // GlkOte spec: flowbreak can be in paragraph object or content array
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 5,
      content: [
        {
          id: 1,
          text: [{ flowbreak: true }],
        },
      ],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const contentUpdate = results.find((u) => u.type === 'content');
    expect(contentUpdate?.type).toBe('content');
    if (contentUpdate?.type === 'content') {
      expect(contentUpdate.content).toHaveLength(1);
      expect(contentUpdate.content[0].type).toBe('flowbreak');
    }
  });

  test('parses input request for line input', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 6,
      input: [{ id: 1, type: 'line', maxlen: 255 }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.inputType).toBe('line');
      expect(inputUpdate.windowId).toBe(1);
      expect(inputUpdate.maxLength).toBe(255);
    }
  });

  test('parses input request for char input', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 7,
      input: [{ id: 2, type: 'char' }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.inputType).toBe('char');
      expect(inputUpdate.windowId).toBe(2);
    }
  });

  test('parses window update', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 8,
      windows: [
        {
          id: 1,
          type: 'buffer',
          rock: 0,
          left: 0,
          top: 0,
          width: 80,
          height: 25,
        },
      ],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const windowUpdate = results.find((u) => u.type === 'window');
    expect(windowUpdate?.type).toBe('window');
    if (windowUpdate?.type === 'window') {
      expect(windowUpdate.windows).toHaveLength(1);
      expect(windowUpdate.windows[0].id).toBe(1);
      expect(windowUpdate.windows[0].type).toBe('buffer');
    }
  });

  test('parses error update', () => {
    const update: RemGlkUpdate = {
      type: 'error',
      gen: 0,
      message: 'Something went wrong',
    };

    const results = parseRemGlkUpdate(update, noopResolver);
    expect(results).toHaveLength(1);
    expect(results[0].type).toBe('error');
    if (results[0].type === 'error') {
      expect(results[0].message).toBe('Something went wrong');
    }
  });

  test('parses clear flag', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 9,
      content: [
        {
          id: 1,
          clear: true,
          text: [],
        },
      ],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const contentUpdate = results.find((u) => u.type === 'content');
    expect(contentUpdate?.type).toBe('content');
    if (contentUpdate?.type === 'content') {
      expect(contentUpdate.clear).toBe(true);
    }
  });

  test('parses grid window lines format (GlkOte spec)', () => {
    // GlkOte spec: grid window content uses lines array with explicit line numbers
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

    const results = parseRemGlkUpdate(update, noopResolver);

    const contentUpdate = results.find((u) => u.type === 'content');
    expect(contentUpdate?.type).toBe('content');
    if (contentUpdate?.type === 'content') {
      expect(contentUpdate.windowId).toBe(2);
      expect(contentUpdate.content).toHaveLength(1);
      expect(contentUpdate.content[0].type).toBe('text');
      expect(contentUpdate.content[0].text).toBe(' At End Of Road                     Score: 36    Moves: 1');
    }
  });

  test('parses grid window with multiple lines', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 11,
      content: [
        {
          id: 2,
          lines: [
            { line: 0, content: ['Line 0 text'] },
            { line: 2, content: ['Line 2 text'] },
          ],
        },
      ],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const contentUpdate = results.find((u) => u.type === 'content');
    expect(contentUpdate?.type).toBe('content');
    if (contentUpdate?.type === 'content') {
      expect(contentUpdate.content).toHaveLength(2);
      expect(contentUpdate.content[0].text).toBe('Line 0 text');
      expect(contentUpdate.content[1].text).toBe('Line 2 text');
    }
  });

  test('parses timer update with interval', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 12,
      timer: 1000, // 1 second
      input: [{ id: 1, type: 'char' }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const timerUpdate = results.find((u) => u.type === 'timer');
    expect(timerUpdate?.type).toBe('timer');
    if (timerUpdate?.type === 'timer') {
      expect(timerUpdate.interval).toBe(1000);
    }
  });

  test('parses timer update with null (cancel)', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 13,
      timer: null,
      input: [{ id: 1, type: 'char' }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const timerUpdate = results.find((u) => u.type === 'timer');
    expect(timerUpdate?.type).toBe('timer');
    if (timerUpdate?.type === 'timer') {
      expect(timerUpdate.interval).toBe(null);
    }
  });

  test('does not include timer update when timer field is absent', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 14,
      input: [{ id: 1, type: 'char' }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const timerUpdate = results.find((u) => u.type === 'timer');
    expect(timerUpdate).toBeUndefined();
  });

  test('parses input request with mouse flag', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 15,
      input: [{ id: 1, type: 'char', mouse: true }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.inputType).toBe('char');
      expect(inputUpdate.windowId).toBe(1);
      expect(inputUpdate.mouse).toBe(true);
    }
  });

  test('input request without mouse flag has undefined mouse', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 16,
      input: [{ id: 1, type: 'line' }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.mouse).toBeUndefined();
    }
  });

  test('parses input request with hyperlink flag', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 17,
      input: [{ id: 1, type: 'line', hyperlink: true }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.inputType).toBe('line');
      expect(inputUpdate.windowId).toBe(1);
      expect(inputUpdate.hyperlink).toBe(true);
    }
  });

  test('input request without hyperlink flag has undefined hyperlink', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 18,
      input: [{ id: 1, type: 'char' }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.hyperlink).toBeUndefined();
    }
  });

  test('parses input request with both mouse and hyperlink flags', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 19,
      input: [{ id: 1, type: 'char', mouse: true, hyperlink: true }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.mouse).toBe(true);
      expect(inputUpdate.hyperlink).toBe(true);
    }
  });

  test('parses input request with grid cursor position', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 20,
      input: [{ id: 1, type: 'line', xpos: 5, ypos: 2 }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.xpos).toBe(5);
      expect(inputUpdate.ypos).toBe(2);
    }
  });

  test('input request without grid position has undefined xpos/ypos', () => {
    const update: RemGlkUpdate = {
      type: 'update',
      gen: 21,
      input: [{ id: 1, type: 'line' }],
    };

    const results = parseRemGlkUpdate(update, noopResolver);

    const inputUpdate = results.find((u) => u.type === 'input-request');
    expect(inputUpdate?.type).toBe('input-request');
    if (inputUpdate?.type === 'input-request') {
      expect(inputUpdate.xpos).toBeUndefined();
      expect(inputUpdate.ypos).toBeUndefined();
    }
  });
});
