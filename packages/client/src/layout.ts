/**
 * Window arrangement resolution (Phase 5).
 *
 * The interpreter emits a semantic {@link LayoutNode} tree (row/column
 * containers of window leaves, each optionally sized) alongside the absolute
 * `windows[]` rects. This module turns that tree into concrete geometry, so
 * every UI — chat flow, SVG, canvas, plain DOM — shares one computation rather
 * than reverse-engineering adjacency from pixels:
 *
 * - {@link resolve} → absolute pixel regions per window (for canvas/SVG or any
 *   absolutely-positioned renderer).
 * - {@link layoutToFlex} → a nested CSS flexbox DOM subtree (for a responsive,
 *   stretchy renderer that reflows with the viewport, never `position:absolute`).
 *
 * Both interpret a child's `fixed` size in the sized window's natural unit
 * (character cells for text, pixels for graphics) using the same
 * {@link Metrics} the client sent, and an unsized child as the remainder.
 */

import type { LayoutNode, LayoutSize, Metrics } from './protocol';
import { isLayoutContainer } from './protocol';

/** The concrete window kinds a leaf can resolve to. */
export type WindowKind = 'buffer' | 'grid' | 'graphics' | 'pair';

/** Look up a window's kind by id (typically from the update's `windows[]`). */
export type WindowKindLookup = (window: number) => WindowKind | undefined;

/** An absolute pixel rectangle for one window leaf. */
export interface ResolvedRegion {
  window: number;
  left: number;
  top: number;
  width: number;
  height: number;
}

/** The pixel area a layout is resolved into. */
export interface ResolveArea {
  left?: number;
  top?: number;
  width: number;
  height: number;
}

/**
 * Convert a `fixed` size to pixels along `direction`'s main axis. Text windows
 * measure in character cells (× char metric + margin); graphics and containers
 * are already pixels. Mirrors the server's `fixedSplitPx`. Falls back to
 * treating the size as pixels when the relevant char metric is missing.
 */
export function fixedToPx(
  size: number,
  direction: 'row' | 'column',
  kind: WindowKind | undefined,
  metrics: Metrics,
): number {
  const horizontal = direction === 'row';
  let charPx: number | undefined;
  let margin = 0;
  if (kind === 'grid') {
    charPx = horizontal ? metrics.gridcharwidth : metrics.gridcharheight;
    margin = (horizontal ? metrics.gridmarginx : metrics.gridmarginy) ?? 0;
  } else if (kind === 'buffer') {
    charPx = horizontal ? metrics.buffercharwidth : metrics.buffercharheight;
    margin = (horizontal ? metrics.buffermarginx : metrics.buffermarginy) ?? 0;
  }
  // graphics / pair / unknown, or no char metric available: size is pixels.
  if (!charPx || charPx <= 0) return size;
  return size * charPx + margin;
}

/** Kind of a leaf node (containers resolve their fixed sizes as pixels). */
function nodeKind(node: LayoutNode, windowKind: WindowKindLookup): WindowKind | undefined {
  return isLayoutContainer(node) ? undefined : windowKind(node.window);
}

/**
 * Compute each child's extent (px) along the container's main axis: fixed →
 * converted px, proportional → % of the extent, unsized → an equal share of
 * whatever remains. This is flexbox semantics (basis + grow), matching how
 * {@link layoutToFlex} lets CSS do the same distribution.
 */
function distributeMain(
  children: LayoutNode[],
  mainExtent: number,
  direction: 'row' | 'column',
  metrics: Metrics,
  windowKind: WindowKindLookup,
): number[] {
  const sizes: (number | null)[] = children.map((child) => {
    const size: LayoutSize | undefined = child.size;
    if (!size) return null; // grows into the remainder
    if ('fixed' in size) return fixedToPx(size.fixed, direction, nodeKind(child, windowKind), metrics);
    return (size.prop / 100) * mainExtent;
  });

  const used = sizes.reduce((sum: number, s) => sum + (s ?? 0), 0);
  const growCount = sizes.filter((s) => s === null).length;
  const remainder = Math.max(0, mainExtent - used);
  const growShare = growCount > 0 ? remainder / growCount : 0;

  return sizes.map((s) => s ?? growShare);
}

/**
 * Resolve `node` into absolute pixel regions, one per window leaf, laid out
 * within `area`. Children are placed sequentially along each container's main
 * axis and stretched across the cross axis.
 */
export function resolve(
  node: LayoutNode,
  area: ResolveArea,
  metrics: Metrics,
  windowKind: WindowKindLookup,
): ResolvedRegion[] {
  const left = area.left ?? 0;
  const top = area.top ?? 0;
  const { width, height } = area;

  if (!isLayoutContainer(node)) {
    return [{ window: node.window, left, top, width, height }];
  }

  const horizontal = node.direction === 'row';
  const mainExtent = horizontal ? width : height;
  const extents = distributeMain(node.children, mainExtent, node.direction, metrics, windowKind);

  const regions: ResolvedRegion[] = [];
  let offset = horizontal ? left : top;
  node.children.forEach((child, i) => {
    const extent = extents[i];
    const childArea: ResolveArea = horizontal
      ? { left: offset, top, width: extent, height }
      : { left, top: offset, width, height: extent };
    regions.push(...resolve(child, childArea, metrics, windowKind));
    offset += extent;
  });
  return regions;
}

/** Options for {@link layoutToFlex}. */
export interface FlexOptions {
  /** Display metrics, for converting `fixed` cell sizes to pixels. */
  metrics: Metrics;
  /** Look up a window's kind by id (from the update's `windows[]`). */
  windowKind: WindowKindLookup;
  /**
   * Build (or fetch) the DOM element for a window leaf. The caller owns the
   * element and its content; sizing/positioning is applied on top by this
   * helper. Reuse a persistent element per window id so content and scroll
   * survive rearrangement.
   */
  renderLeaf: (window: number, kind: WindowKind | undefined) => HTMLElement;
}

/** Apply the flex sizing a child gets from its `size` within `direction`. */
function applyChildFlex(
  el: HTMLElement,
  node: LayoutNode,
  direction: 'row' | 'column',
  opts: FlexOptions,
): void {
  // Let flex children shrink below content size so long text/large canvases
  // don't blow out the layout.
  el.style.minWidth = '0';
  el.style.minHeight = '0';
  const size = node.size;
  if (!size) {
    el.style.flex = '1 1 0';
  } else if ('fixed' in size) {
    const px = fixedToPx(size.fixed, direction, nodeKind(node, opts.windowKind), opts.metrics);
    el.style.flex = `0 0 ${px}px`;
  } else {
    el.style.flex = `0 0 ${size.prop}%`;
  }
}

function buildFlex(node: LayoutNode, opts: FlexOptions): HTMLElement {
  if (!isLayoutContainer(node)) {
    return opts.renderLeaf(node.window, opts.windowKind(node.window));
  }
  const el = document.createElement('div');
  el.style.display = 'flex';
  el.style.flexDirection = node.direction;
  el.style.minWidth = '0';
  el.style.minHeight = '0';
  for (const child of node.children) {
    const childEl = buildFlex(child, opts);
    applyChildFlex(childEl, child, node.direction, opts);
    el.appendChild(childEl);
  }
  return el;
}

/**
 * Build a nested CSS flexbox DOM subtree from a {@link LayoutNode}. Containers
 * become `display:flex` row/column boxes; sized children get a fixed/percentage
 * flex-basis, unsized children grow to fill. The returned root is set to fill
 * its mount (`width/height:100%`), so it stretches responsively — mount it in a
 * sized container and it reflows on resize with no recompute. Window content is
 * app-supplied via {@link FlexOptions.renderLeaf}.
 */
export function layoutToFlex(node: LayoutNode, opts: FlexOptions): HTMLElement {
  const root = buildFlex(node, opts);
  root.style.width = '100%';
  root.style.height = '100%';
  root.style.minWidth = '0';
  root.style.minHeight = '0';
  return root;
}
