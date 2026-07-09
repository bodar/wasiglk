/**
 * Draw-operation interpreter.
 *
 * The GlkOte/RemGlk protocol delivers graphics as a list of {@link DrawOperation}
 * primitives (`setcolor` / `fill` / `image`) with CSS hex colours and pixel
 * geometry — the interpreter never rasterises. Every client has to walk that
 * list the same way: track the current colour set by `setcolor`, default an
 * omitted `fill` rect to the whole window, and resolve `image` numbers to URLs.
 * This helper does exactly that and drives any {@link GraphicsRenderer}, so
 * apps don't reimplement it (and so the number-vs-string colour boundary lives
 * in one place).
 */

import type { GraphicsRenderer } from './types';
import type { DrawOperation } from '../protocol';

export interface ApplyDrawOptions {
  /** Resolve a blorb image number to a URL (e.g. `client.getImageUrl`). */
  getImageUrl?: (imageNum: number) => string | undefined;
  /** Graphics window width in px — the default extent for a `fill` that omits `width`. */
  width: number;
  /** Graphics window height in px — the default extent for a `fill` that omits `height`. */
  height: number;
}

/** Parse a CSS hex colour (`#RRGGBB`) to a 24-bit GLK colour, else `fallback`. */
function parseHexColor(css: string | undefined, fallback: number): number {
  if (!css || css[0] !== '#') return fallback;
  const n = parseInt(css.slice(1), 16);
  return Number.isNaN(n) ? fallback : n & 0xffffff;
}

/**
 * Apply `ops` to `renderer` in order, tracking the current fill colour across
 * `setcolor`/`fill`. Black (`0x000000`) is the initial colour, matching Glk.
 */
export function applyDrawOperations(
  renderer: GraphicsRenderer,
  ops: DrawOperation[],
  options: ApplyDrawOptions,
): void {
  let color = 0x000000;

  for (const op of ops) {
    switch (op.special) {
      case 'setcolor':
        color = parseHexColor(op.color, color);
        break;
      case 'fill':
        renderer.fillRect(
          parseHexColor(op.color, color),
          op.x ?? 0,
          op.y ?? 0,
          op.width ?? options.width,
          op.height ?? options.height,
        );
        break;
      case 'image': {
        const url = (op.image !== undefined ? options.getImageUrl?.(op.image) : undefined) ?? op.url;
        if (url) renderer.drawImage(url, op.x ?? 0, op.y ?? 0, op.width, op.height);
        break;
      }
    }
  }
}
