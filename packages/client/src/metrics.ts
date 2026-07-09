/**
 * Display metrics measurement.
 *
 * The GlkOte/RemGlk protocol works entirely in pixels: `width`/`height` are the
 * display area in pixels, and the `*charwidth`/`*charheight` fields are the
 * pixels occupied by one character, which the interpreter uses to convert a
 * text window's pixel size into character rows/columns.
 *
 * `measureMetrics` measures a real DOM element into a {@link Metrics} object so
 * every client computes this the same way instead of hardcoding guesses.
 * Browser-only (uses the DOM and a canvas); import it from UI code, not the
 * worker.
 */

import type { Metrics } from './protocol';

export interface MeasureOptions {
  /** CSS `font` shorthand for the grid (monospace) window. Defaults to the container's computed font. */
  gridFont?: string;
  /** CSS `font` shorthand for the buffer window. Defaults to `gridFont`. */
  bufferFont?: string;
}

/** Pixel advance of one character in `font`, averaged over a 100-char sample. */
function charWidthPx(ctx: CanvasRenderingContext2D, font: string): number {
  ctx.font = font;
  return ctx.measureText('0'.repeat(100)).width / 100;
}

/**
 * Measure `container` into a {@link Metrics} object (all pixels). Pass the
 * element the game's windows render into; the interpreter divides these pixel
 * sizes by the char metrics to get character cells.
 */
export function measureMetrics(container: HTMLElement, opts: MeasureOptions = {}): Metrics {
  const rect = container.getBoundingClientRect();
  const cs = getComputedStyle(container);
  const gridFont = opts.gridFont ?? `${cs.fontSize} ${cs.fontFamily}`;
  const bufferFont = opts.bufferFont ?? gridFont;

  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');

  // Line height in px; fall back to ~1.2x font size when `line-height: normal`.
  const fontSize = parseFloat(cs.fontSize) || 16;
  const lineHeight = parseFloat(cs.lineHeight) || Math.ceil(fontSize * 1.2);

  const gridCharWidth = ctx ? charWidthPx(ctx, gridFont) : fontSize * 0.6;
  const bufferCharWidth = ctx ? charWidthPx(ctx, bufferFont) : fontSize * 0.6;

  return {
    width: Math.max(1, Math.floor(rect.width)),
    height: Math.max(1, Math.floor(rect.height)),
    gridcharwidth: gridCharWidth,
    gridcharheight: lineHeight,
    buffercharwidth: bufferCharWidth,
    buffercharheight: lineHeight,
  };
}
