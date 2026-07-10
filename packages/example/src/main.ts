/**
 * WasiGlk Example
 *
 * Demonstrates using @bodar/wasiglk to run an interactive fiction interpreter,
 * rendering the interpreter's window arrangement as a responsive, stretchy flex
 * layout driven by the `layout` tree on each update.
 */

import {
  createClient,
  measureMetrics,
  layoutToFlex,
  SvgRenderer,
  applyDrawOperations,
  type RemGlkUpdate,
  type ContentUpdate,
  type ContentSpan,
  type LayoutNode,
  type WindowKind,
  type Metrics,
  type StoryFormat,
} from '@bodar/wasiglk';

// The test stories we ship, one or more per interpreter type. `format` is only
// set where extension-based detection would be wrong (baton.dat is a Scott
// Adams database, but `.dat` otherwise maps to advsys).
interface Story {
  label: string;
  file: string;
  format?: StoryFormat;
}

const STORIES: Story[] = [
  { label: 'Adventure — Glulx (glulxe)', file: 'advent.ulx' },
  { label: 'Glulxercise — Glulx test (glulxe)', file: 'glulxercise.ulx' },
  { label: 'GraphWinTest — Glulx graphics window (glulxe)', file: 'graphwintest.gblorb' },
  { label: 'ImageTest — Glulx buffer images (glulxe)', file: 'imagetest.gblorb' },
  { label: 'Adventure — Z-code (fizmo)', file: 'advent.z5' },
  { label: 'Praxix — Z-code test (fizmo)', file: 'praxix.z5' },
  { label: 'Colossal Cave — Hugo', file: 'colossal.hex' },
  { label: 'Core test — Hugo', file: 'coretest.hex' },
  { label: 'Baton — Scott Adams (scott)', file: 'baton.dat', format: 'scott' },
  { label: 'Adventure — zipped container (glulxe)', file: 'advent-zipped.zip' },
  { label: 'Guilty Bastards — Hugo graphics (zipped)', file: 'guilty-graphics.zip' },
  { label: 'Paint!!! — ADRIFT graphics (scare)', file: 'paint.taf', format: 'adrift' },
];

// DOM elements
const inputEl = document.getElementById('input') as HTMLInputElement;
const sendBtn = document.getElementById('send') as HTMLButtonElement;
const statusEl = document.getElementById('status')!;
const layoutRoot = document.getElementById('game-layout')!;

// Client instance
let client: Awaited<ReturnType<typeof createClient>> | null = null;

// Monotonic run token: switching stories increments it so a superseded update
// loop (still draining the previous client) stops touching the DOM.
let runGen = 0;

// One persistent record per window id. The DOM element survives rearrangement
// (layoutToFlex re-parents it) so buffer scroll position and accumulated
// content are not lost when the window tree changes.
interface WinRec {
  kind: WindowKind;
  el: HTMLElement;
  renderer?: SvgRenderer; // graphics only
  gw?: number; // graphics canvas width (px)
  gh?: number; // graphics canvas height (px)
  gridLines?: string[]; // grid: text per line index
}
const wins = new Map<number, WinRec>();

// The most recent layout tree, re-applied on structural changes.
let currentLayout: LayoutNode | null = null;

// Measure metrics from the live DOM: the layout area for overall size, and a
// real grid/buffer window element (when one exists) for that window kind's font
// and padding. Everything comes from CSS — nothing is hardcoded — so a window's
// padding is reported as its `*margin*` and the interpreter budgets for it when
// sizing fixed splits (a 1-row status window gets one line + its padding, not a
// clipped line).
function metricsFor(): Metrics {
  const grid = layoutRoot.querySelector<HTMLElement>('.win-grid') ?? undefined;
  const buffer = layoutRoot.querySelector<HTMLElement>('.win-buffer') ?? undefined;
  return measureMetrics({ area: layoutRoot, grid, buffer });
}

// Notify the interpreter of the current metrics, but only when they actually
// changed. This both drives resize reflow and corrects the first measurement:
// the initial metrics are taken before any window exists (so grid/buffer fall
// back to the layout area's font, zero margins), and once the real window
// elements mount, re-measuring yields their true font and padding. Guarding on
// equality means the game re-lays-out exactly once and then converges.
let lastMetricsJson = '';
function sendMetricsIfChanged(): void {
  if (!client) return;
  const metrics = metricsFor();
  const json = JSON.stringify(metrics);
  if (json === lastMetricsJson) return;
  lastMetricsJson = json;
  // Tell the interpreter (so it re-wraps grid columns / buffer text) AND
  // recompute the flex basis locally — window sizes are derived client-side
  // from metrics + the layout tree, so a metrics change re-lays-out here
  // without waiting for the game to re-emit `layout`.
  client.sendArrange(metrics);
  if (currentLayout) applyLayout(metrics);
}

// Create (once) the persistent DOM element for a window of the given kind.
function ensureWindow(id: number, kind: WindowKind): WinRec {
  let rec = wins.get(id);
  if (rec) return rec;

  let el: HTMLElement;
  let renderer: SvgRenderer | undefined;
  if (kind === 'graphics') {
    el = document.createElement('div');
    el.className = 'win win-graphics';
    renderer = new SvgRenderer();
    renderer.mount(el);
  } else if (kind === 'grid') {
    el = document.createElement('pre');
    el.className = 'win win-grid';
  } else {
    // buffer (and any unexpected kind) render as scrollable text.
    el = document.createElement('div');
    el.className = 'win win-buffer';
  }
  rec = { kind, el, renderer, gridLines: kind === 'grid' ? [] : undefined };
  wins.set(id, rec);
  return rec;
}

// Rebuild the flex layout DOM from the current arrangement tree with the given
// metrics, reusing each window's persistent element.
function applyLayout(metrics: Metrics): void {
  if (!currentLayout) return;
  const tree = layoutToFlex(currentLayout, {
    metrics,
    windowKind: (id) => wins.get(id)?.kind,
    renderLeaf: (id, kind) => ensureWindow(id, kind ?? 'buffer').el,
  });
  layoutRoot.replaceChildren(tree);
}

// Extract text from a content span.
function spanText(span: ContentSpan): string {
  if (typeof span === 'string') return span;
  if ('text' in span) return span.text;
  return '';
}

// Append an inline image (Glk image drawn into a buffer window) to a buffer el.
function appendBufferImage(el: HTMLElement, span: Extract<ContentSpan, { special: 'image' }>): void {
  const url = (span.image !== undefined ? client?.getImageUrl(span.image) : undefined) ?? span.url;
  if (!url) return;
  const img = document.createElement('img');
  img.src = url;
  if (span.width) img.width = span.width;
  if (span.height) img.height = span.height;
  img.alt = span.alttext ?? '';
  switch (span.alignment) {
    case 'inlineup': img.style.verticalAlign = 'text-top'; break;
    case 'inlinedown': img.style.verticalAlign = 'text-bottom'; break;
    case 'inlinecenter': img.style.verticalAlign = 'middle'; break;
    case 'marginleft': img.style.cssFloat = 'left'; break;
    case 'marginright': img.style.cssFloat = 'right'; break;
  }
  el.appendChild(img);
  el.scrollTop = el.scrollHeight;
}

// Track initialization state
let initialized = false;

// Check JSPI support
function checkJSPISupport(): { supported: boolean; reason?: string } {
  try {
    if (typeof (WebAssembly as any).Suspending === 'undefined') {
      return { supported: false, reason: 'WebAssembly.Suspending not available' };
    }
    if (typeof (WebAssembly as any).promising === 'undefined') {
      return { supported: false, reason: 'WebAssembly.promising not available' };
    }
    return { supported: true };
  } catch (e) {
    return { supported: false, reason: (e as Error).message };
  }
}

function setStatus(text: string, type: 'info' | 'error' | 'success' = 'info'): void {
  statusEl.textContent = text;
  statusEl.className = `status ${type}`;
}

function enableInput(): void {
  inputEl.disabled = false;
  sendBtn.disabled = false;
  inputEl.focus();
}

function disableInput(): void {
  inputEl.disabled = true;
  sendBtn.disabled = true;
}

// Render one content update into its window's element.
function renderContent(content: ContentUpdate): void {
  const rec = wins.get(content.id);
  if (!rec) return;

  if (rec.kind === 'graphics') {
    if (content.clear) rec.renderer?.clear();
    if (content.draw && rec.renderer) {
      applyDrawOperations(rec.renderer, content.draw, {
        getImageUrl: (n) => client?.getImageUrl(n),
        width: rec.gw ?? 0,
        height: rec.gh ?? 0,
      });
    }
  } else if (rec.kind === 'grid') {
    // Grid updates carry only the changed lines, each with its index.
    let lines = rec.gridLines!;
    if (content.clear) {
      lines = [];
      rec.gridLines = lines;
    }
    for (const line of content.lines ?? []) {
      let text = '';
      for (const span of line.content ?? []) text += spanText(span);
      lines[line.line] = text;
    }
    rec.el.textContent = lines.map((l) => l ?? '').join('\n');
  } else {
    // Buffer: append paragraphs' text and inline images.
    if (content.clear) rec.el.replaceChildren();
    for (const para of content.text ?? []) {
      for (const span of para.content ?? []) {
        if (typeof span === 'object' && 'special' in span && span.special === 'image') {
          appendBufferImage(rec.el, span);
        } else {
          rec.el.appendChild(document.createTextNode(spanText(span)));
        }
      }
    }
    rec.el.scrollTop = rec.el.scrollHeight;
  }
}

// Handle updates from the interpreter.
function handleUpdate(update: RemGlkUpdate): void {
  if (update.type === 'error') {
    setStatus(`Error: ${update.message}`, 'error');
    return;
  }

  // 1. Windows: register kinds and (for graphics) size the renderer.
  if (update.windows) {
    for (const win of update.windows) {
      const rec = ensureWindow(win.id, win.type);
      if (rec.kind === 'graphics') {
        rec.gw = win.graphwidth ?? win.width;
        rec.gh = win.graphheight ?? win.height;
        rec.renderer?.setSize(rec.gw, rec.gh);
      }
    }
    if (!initialized) {
      initialized = true;
      setStatus('Game initialized!', 'success');
    }
  }

  // 2. Layout: rebuild the responsive flex tree (structural change only).
  if (update.layout) {
    currentLayout = update.layout;
    applyLayout(metricsFor());
    // The windows are now in the DOM; their real font/padding may differ from
    // the metrics used just now (measured before they existed), so re-measure
    // next frame and re-lay-out if they changed.
    requestAnimationFrame(sendMetricsIfChanged);
  }

  // 3. Content: render into each window's persistent element.
  if (update.content) {
    for (const content of update.content) renderContent(content);
  }

  if (update.input) {
    enableInput();
  }
}

// Submit input
function handleSend(): void {
  const text = inputEl.value.trim();
  if (text && client) {
    inputEl.value = '';
    disableInput();
    client.sendInput(text);
  }
}

// Event handlers
inputEl.addEventListener('keypress', (e) => {
  if (e.key === 'Enter') {
    handleSend();
  }
});

sendBtn.addEventListener('click', handleSend);

// Responsive: on container resize, re-measure and notify the interpreter so it
// re-lays-out and re-wraps text at the new size. Coalesced to one arrange per
// animation frame. The flex layout itself stretches immediately; the arrange
// keeps character-cell sizes (grid columns, wrap width) correct.
let arrangeQueued = false;
const resizeObserver = new ResizeObserver(() => {
  if (arrangeQueued || !client) return;
  arrangeQueued = true;
  requestAnimationFrame(() => {
    arrangeQueued = false;
    sendMetricsIfChanged();
  });
});
resizeObserver.observe(layoutRoot);

// Reset all per-story UI and state before (re)starting an interpreter.
function resetForNewStory(): void {
  for (const rec of wins.values()) rec.renderer?.dispose();
  wins.clear();
  currentLayout = null;
  lastMetricsJson = '';
  layoutRoot.replaceChildren();
  initialized = false;
  disableInput();
}

// Load and run a story. Interpreter is derived from the format (no
// interpreterUrl override) so each story pulls its own /<interpreter>.wasm.
async function startStory(story: Story): Promise<void> {
  runGen += 1;
  const gen = runGen;

  if (client) {
    client.stop();
    client = null;
  }
  resetForNewStory();
  setStatus(`Loading ${story.file}...`, 'info');

  try {
    // Measure the real pixel size of the layout area and its font, so the
    // interpreter converts to character cells correctly. No window exists yet,
    // so this uses the layout area's font; applyLayout re-measures against the
    // real window elements once they mount.
    const initialMetrics = metricsFor();
    lastMetricsJson = JSON.stringify(initialMetrics);
    client = await createClient({
      storyUrl: `/${story.file}`,
      ...(story.format ? { format: story.format } : {}),
      workerUrl: '/worker.js',
      metrics: initialMetrics,
    });

    // A newer selection may have superseded us during the async load.
    if (gen !== runGen) {
      client.stop();
      return;
    }

    setStatus('Starting interpreter...', 'info');

    for await (const update of client.updates()) {
      if (gen !== runGen) break; // superseded by a newer story
      handleUpdate(update);
    }

    if (gen === runGen) setStatus('Game ended.', 'info');
  } catch (e) {
    if (gen === runGen) {
      console.error('Error:', e);
      setStatus(`Error: ${(e as Error).message}`, 'error');
    }
  }
}

// Build the story-picker dropdown above the status line.
function buildStoryPicker(): void {
  const container = statusEl.parentElement!;
  const wrap = document.createElement('div');
  wrap.style.margin = '8px 0';

  const label = document.createElement('label');
  label.textContent = 'Story: ';

  const select = document.createElement('select');
  select.id = 'story';
  for (const story of STORIES) {
    const opt = document.createElement('option');
    opt.value = story.file;
    opt.textContent = story.label;
    select.appendChild(opt);
  }
  select.addEventListener('change', () => {
    const story = STORIES.find((s) => s.file === select.value);
    if (story) void startStory(story);
  });

  label.appendChild(select);
  wrap.appendChild(label);
  container.insertBefore(wrap, statusEl);
}

// Main
async function main(): Promise<void> {
  const jspiCheck = checkJSPISupport();
  if (!jspiCheck.supported) {
    setStatus(
      `JSPI not supported: ${jspiCheck.reason}. Enable chrome://flags/#enable-experimental-webassembly-jspi`,
      'error'
    );
    return;
  }

  buildStoryPicker();
  await startStory(STORIES[0]);
}

main();
