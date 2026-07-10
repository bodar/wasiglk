import { describe, expect, test } from 'bun:test';
import { fixedToPx, resolve, type WindowKind } from '../src/layout';
import type { LayoutNode, Metrics } from '../src/protocol';

const metrics: Metrics = {
  width: 800,
  height: 600,
  gridcharwidth: 10,
  gridcharheight: 20,
  buffercharwidth: 8,
  buffercharheight: 16,
  gridmarginx: 0,
  gridmarginy: 0,
  buffermarginx: 0,
  buffermarginy: 0,
};

// A kind lookup backed by a plain map for tests.
const kinds = (m: Record<number, WindowKind>) => (id: number) => m[id];

describe('fixedToPx', () => {
  test('grid columns use gridcharwidth on the row (horizontal) axis', () => {
    expect(fixedToPx(8, 'row', 'grid', metrics)).toBe(80);
  });

  test('grid rows use gridcharheight on the column (vertical) axis', () => {
    expect(fixedToPx(1, 'column', 'grid', metrics)).toBe(20);
  });

  test('buffer uses buffer char metrics', () => {
    expect(fixedToPx(10, 'row', 'buffer', metrics)).toBe(80);
    expect(fixedToPx(2, 'column', 'buffer', metrics)).toBe(32);
  });

  test('margins are added to the converted size', () => {
    expect(fixedToPx(8, 'row', 'grid', { ...metrics, gridmarginx: 4 })).toBe(84);
  });

  test('graphics / unknown kinds pass the size through as pixels', () => {
    expect(fixedToPx(100, 'row', 'graphics', metrics)).toBe(100);
    expect(fixedToPx(100, 'column', undefined, metrics)).toBe(100);
  });

  test('a missing char metric falls back to treating the size as pixels', () => {
    expect(fixedToPx(50, 'row', 'grid', { width: 800, height: 600 })).toBe(50);
  });
});

describe('resolve', () => {
  test('a lone leaf fills the whole area', () => {
    const node: LayoutNode = { window: 1 };
    expect(resolve(node, { width: 800, height: 600 }, metrics, kinds({ 1: 'buffer' }))).toEqual([
      { window: 1, left: 0, top: 0, width: 800, height: 600 },
    ]);
  });

  test('column: a fixed grid row on top, buffer takes the remainder', () => {
    const node: LayoutNode = {
      direction: 'column',
      children: [
        { window: 1, size: { fixed: 1 } },
        { window: 2 },
      ],
    };
    expect(resolve(node, { width: 800, height: 600 }, metrics, kinds({ 1: 'grid', 2: 'buffer' }))).toEqual([
      { window: 1, left: 0, top: 0, width: 800, height: 20 },
      { window: 2, left: 0, top: 20, width: 800, height: 580 },
    ]);
  });

  test('row: a fixed grid sidebar beside a growing main window', () => {
    const node: LayoutNode = {
      direction: 'row',
      children: [
        { window: 1, size: { fixed: 10 } },
        { window: 2 },
      ],
    };
    expect(resolve(node, { width: 800, height: 600 }, metrics, kinds({ 1: 'grid', 2: 'buffer' }))).toEqual([
      { window: 1, left: 0, top: 0, width: 100, height: 600 },
      { window: 2, left: 100, top: 0, width: 700, height: 600 },
    ]);
  });

  test('proportional size takes a percentage of the main axis', () => {
    const node: LayoutNode = {
      direction: 'column',
      children: [
        { window: 1, size: { prop: 25 } },
        { window: 2 },
      ],
    };
    expect(resolve(node, { width: 800, height: 600 }, metrics, kinds({ 1: 'buffer', 2: 'buffer' }))).toEqual([
      { window: 1, left: 0, top: 0, width: 800, height: 150 },
      { window: 2, left: 0, top: 150, width: 800, height: 450 },
    ]);
  });

  test('multiple unsized children split the remainder equally', () => {
    const node: LayoutNode = {
      direction: 'column',
      children: [
        { window: 1, size: { fixed: 1 } },
        { window: 2 },
        { window: 3 },
      ],
    };
    expect(resolve(node, { width: 800, height: 600 }, metrics, kinds({ 1: 'grid', 2: 'buffer', 3: 'buffer' }))).toEqual([
      { window: 1, left: 0, top: 0, width: 800, height: 20 },
      { window: 2, left: 0, top: 20, width: 800, height: 290 },
      { window: 3, left: 0, top: 310, width: 800, height: 290 },
    ]);
  });

  test('nested containers resolve within their parent region', () => {
    const node: LayoutNode = {
      direction: 'row',
      children: [
        { window: 1, size: { fixed: 10 } },
        {
          direction: 'column',
          children: [
            { window: 2, size: { fixed: 1 } },
            { window: 3 },
          ],
        },
      ],
    };
    expect(
      resolve(node, { width: 800, height: 600 }, metrics, kinds({ 1: 'grid', 2: 'grid', 3: 'buffer' })),
    ).toEqual([
      { window: 1, left: 0, top: 0, width: 100, height: 600 },
      { window: 2, left: 100, top: 0, width: 700, height: 20 },
      { window: 3, left: 100, top: 20, width: 700, height: 580 },
    ]);
  });
});
