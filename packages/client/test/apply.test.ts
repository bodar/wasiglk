import { describe, expect, test } from 'bun:test';
import { applyDrawOperations } from '../src/renderers/apply';
import type { GraphicsRenderer } from '../src/renderers/types';
import type { DrawOperation } from '../src/protocol';

// In-memory GraphicsRenderer that records the calls it receives, so we can
// assert exactly how applyDrawOperations drives a renderer.
type Call =
  | { op: 'fill'; color: number; x: number; y: number; width: number; height: number }
  | { op: 'image'; url: string; x: number; y: number; width?: number; height?: number };

class RecordingRenderer implements GraphicsRenderer {
  calls: Call[] = [];
  mount(): void {}
  setSize(): void {}
  setBackgroundColor(): void {}
  fillRect(color: number, x: number, y: number, width: number, height: number): void {
    this.calls.push({ op: 'fill', color, x, y, width, height });
  }
  eraseRect(): void {}
  drawImage(url: string, x: number, y: number, width?: number, height?: number): void {
    this.calls.push({ op: 'image', url, x, y, width, height });
  }
  clear(): void {}
  dispose(): void {}
}

describe('applyDrawOperations', () => {
  test('fill uses its own colour and coordinates', () => {
    const r = new RecordingRenderer();
    const ops: DrawOperation[] = [{ special: 'fill', color: '#ff8800', x: 1, y: 2, width: 3, height: 4 }];
    applyDrawOperations(r, ops, { width: 100, height: 50 });
    expect(r.calls).toEqual([{ op: 'fill', color: 0xff8800, x: 1, y: 2, width: 3, height: 4 }]);
  });

  test('fill without a colour inherits the current setcolor', () => {
    const r = new RecordingRenderer();
    const ops: DrawOperation[] = [
      { special: 'setcolor', color: '#00ff00' },
      { special: 'fill', x: 0, y: 0, width: 10, height: 10 },
    ];
    applyDrawOperations(r, ops, { width: 100, height: 50 });
    expect((r.calls[0] as Extract<Call, { op: 'fill' }>).color).toBe(0x00ff00);
  });

  test('fill without dimensions fills the whole window', () => {
    const r = new RecordingRenderer();
    const ops: DrawOperation[] = [{ special: 'fill', color: '#000000' }];
    applyDrawOperations(r, ops, { width: 640, height: 480 });
    expect(r.calls).toEqual([{ op: 'fill', color: 0x000000, x: 0, y: 0, width: 640, height: 480 }]);
  });

  test('the initial colour is black when fill precedes any setcolor', () => {
    const r = new RecordingRenderer();
    applyDrawOperations(r, [{ special: 'fill', x: 0, y: 0, width: 1, height: 1 }], { width: 1, height: 1 });
    expect((r.calls[0] as Extract<Call, { op: 'fill' }>).color).toBe(0x000000);
  });

  test('image resolves a blorb number via getImageUrl', () => {
    const r = new RecordingRenderer();
    const ops: DrawOperation[] = [{ special: 'image', image: 7, x: 5, y: 6, width: 8, height: 9 }];
    applyDrawOperations(r, ops, {
      width: 100,
      height: 100,
      getImageUrl: (n) => (n === 7 ? 'blob:img-7' : undefined),
    });
    expect(r.calls).toEqual([{ op: 'image', url: 'blob:img-7', x: 5, y: 6, width: 8, height: 9 }]);
  });

  test('image falls back to op.url when the number does not resolve', () => {
    const r = new RecordingRenderer();
    const ops: DrawOperation[] = [{ special: 'image', image: 7, url: 'https://example/i.png', x: 0, y: 0 }];
    applyDrawOperations(r, ops, { width: 100, height: 100, getImageUrl: () => undefined });
    expect(r.calls).toEqual([{ op: 'image', url: 'https://example/i.png', x: 0, y: 0, width: undefined, height: undefined }]);
  });

  test('image with no resolvable url is skipped', () => {
    const r = new RecordingRenderer();
    applyDrawOperations(r, [{ special: 'image', image: 1 }], { width: 10, height: 10, getImageUrl: () => undefined });
    expect(r.calls).toEqual([]);
  });

  test('operations apply in order', () => {
    const r = new RecordingRenderer();
    const ops: DrawOperation[] = [
      { special: 'setcolor', color: '#111111' },
      { special: 'fill', width: 2, height: 2 },
      { special: 'fill', color: '#222222', x: 1, y: 1, width: 1, height: 1 },
    ];
    applyDrawOperations(r, ops, { width: 2, height: 2 });
    expect(r.calls.map((c) => (c as Extract<Call, { op: 'fill' }>).color)).toEqual([0x111111, 0x222222]);
  });
});
