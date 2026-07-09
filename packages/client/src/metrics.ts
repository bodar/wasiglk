/**
 * Display metrics measurement.
 *
 * The GlkOte/RemGlk protocol works entirely in pixels: `width`/`height` are the
 * display area in pixels, and the `*charwidth`/`*charheight` fields are the
 * pixels occupied by one character, which the interpreter uses to convert a
 * text window's pixel size into character rows/columns.
 *
 * `measureMetrics` measures real DOM elements into a {@link Metrics} object so
 * every client computes this the same way instead of hardcoding guesses. It
 * probes the *actual rendered elements* — so it honours everything CSS applies:
 * variable-font axes (`font-variation-settings`), `letter-spacing`, font
 * features, the real loaded webfont, and content-box padding. A canvas
 * `measureText` cannot see any of those.
 *
 * Browser-only (uses the DOM); import it from UI code, not the worker. The
 * elements must be attached and laid out (fonts loaded) when you call this.
 */

import type { Metrics } from './protocol';

export interface MeasureTargets {
  /**
   * Element whose content-box HEIGHT is the display height. This is the
   * viewport/game area the windows live in.
   */
  area: HTMLElement;
  /**
   * Monospace (grid) element. Its content-box WIDTH becomes `Metrics.width`
   * (grid windows are cell-positioned, so the display width must match the
   * grid's own column), and it is probed for grid character metrics.
   * Defaults to `area`.
   */
  grid?: HTMLElement;
  /**
   * Proportional (buffer) element, probed for buffer character metrics.
   * Defaults to `grid` (else `area`). Buffer windows wrap via CSS, so their
   * char width only informs the interpreter's column estimate.
   */
  buffer?: HTMLElement;
}

/** Content-box width in px (border-box `clientWidth` minus horizontal padding). */
function contentWidth(el: HTMLElement): number {
  const cs = getComputedStyle(el);
  const pad = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
  return el.clientWidth - pad;
}

/** Content-box height in px (border-box `clientHeight` minus vertical padding). */
function contentHeight(el: HTMLElement): number {
  const cs = getComputedStyle(el);
  const pad = (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0);
  return el.clientHeight - pad;
}

/**
 * Pixel advance of one character, averaged over a 100-char sample rendered
 * inside `el` so it inherits the element's real computed style.
 */
function charWidthPx(el: HTMLElement): number {
  const probe = document.createElement('span');
  probe.setAttribute('aria-hidden', 'true');
  // Absolutely positioned + hidden so it neither reflows the element's layout
  // (e.g. a flex/centred grid) nor becomes visible.
  probe.style.cssText = 'position:absolute;left:-9999px;top:0;visibility:hidden;white-space:pre;';
  probe.textContent = '0'.repeat(100);
  el.appendChild(probe);
  const width = probe.getBoundingClientRect().width / 100;
  probe.remove();
  return width;
}

/** Line height in px; falls back to ~1.2x font size when `line-height: normal`. */
function lineHeightPx(el: HTMLElement): number {
  const cs = getComputedStyle(el);
  const fontSize = parseFloat(cs.fontSize) || 16;
  const lineHeight = parseFloat(cs.lineHeight);
  return Number.isFinite(lineHeight) ? lineHeight : Math.ceil(fontSize * 1.2);
}

/**
 * Measure the given elements into a {@link Metrics} object (all pixels). The
 * interpreter divides these pixel sizes by the char metrics to get character
 * cells. See {@link MeasureTargets} for how each field is sourced.
 */
export function measureMetrics(targets: MeasureTargets): Metrics {
  const { area } = targets;
  const grid = targets.grid ?? area;
  const buffer = targets.buffer ?? grid;

  return {
    width: Math.max(1, Math.floor(contentWidth(grid))),
    height: Math.max(1, Math.floor(contentHeight(area))),
    gridcharwidth: charWidthPx(grid),
    gridcharheight: lineHeightPx(grid),
    buffercharwidth: charWidthPx(buffer),
    buffercharheight: lineHeightPx(buffer),
  };
}
