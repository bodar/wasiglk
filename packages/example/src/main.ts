/**
 * WasiGlk Example
 *
 * Demonstrates using @bodar/wasiglk to run an interactive fiction interpreter.
 */

import { createClient, measureMetrics, type RemGlkUpdate, type ContentSpan, type DrawOperation, type StoryFormat } from '@bodar/wasiglk';

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
const outputEl = document.getElementById('output')!;
const inputEl = document.getElementById('input') as HTMLInputElement;
const sendBtn = document.getElementById('send') as HTMLButtonElement;
const statusEl = document.getElementById('status')!;
const gameStatusBar = document.getElementById('game-status-bar')!;

// Client instance
let client: Awaited<ReturnType<typeof createClient>> | null = null;

// Monotonic run token: switching stories increments it so a superseded update
// loop (still draining the previous client) stops touching the DOM.
let runGen = 0;

// Track windows by ID and type
const windows = new Map<number, { type: 'buffer' | 'grid' | 'graphics' | 'pair' }>();

// Canvas per graphics window, and the current default fill colour per window.
const graphicsCanvases = new Map<number, HTMLCanvasElement>();
const graphicsColor = new Map<number, string>();

// Text of each grid (status) window's lines, indexed by window id then line
// number, so a multi-line status window renders as separate lines rather than
// one concatenated string.
const gridLineText = new Map<number, string[]>();

// Lazily create (or fetch) the canvas for a graphics window, sized to the
// window's pixel dimensions and inserted above the text output.
function ensureGraphicsCanvas(id: number, width: number, height: number): HTMLCanvasElement {
  let canvas = graphicsCanvases.get(id);
  if (!canvas) {
    canvas = document.createElement('canvas');
    canvas.style.display = 'block';
    canvas.style.border = '1px solid #888';
    canvas.style.margin = '4px 0';
    outputEl.parentElement!.insertBefore(canvas, outputEl);
    graphicsCanvases.set(id, canvas);
  }
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  return canvas;
}

// Apply the interpreter's draw operations to a graphics window's canvas.
function drawGraphics(id: number, ops: DrawOperation[]): void {
  const canvas = graphicsCanvases.get(id);
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  for (const op of ops) {
    if (op.special === 'setcolor' && op.color) {
      graphicsColor.set(id, op.color);
    } else if (op.special === 'fill') {
      ctx.fillStyle = op.color ?? graphicsColor.get(id) ?? '#000000';
      ctx.fillRect(op.x ?? 0, op.y ?? 0, op.width ?? canvas.width, op.height ?? canvas.height);
    } else if (op.special === 'image') {
      const url = (op.image !== undefined ? client?.getImageUrl(op.image) : undefined) ?? op.url;
      if (!url) continue;
      const x = op.x ?? 0, y = op.y ?? 0, w = op.width, h = op.height;
      const img = new Image();
      img.onload = () => ctx.drawImage(img, x, y, w ?? img.width, h ?? img.height);
      img.src = url;
    }
  }
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

// Extract text from a content span
function spanText(span: ContentSpan): string {
  if (typeof span === 'string') return span;
  if ('text' in span) return span.text;
  return '';
}

// Append an inline image (Glk image drawn into a buffer window) to the output.
function appendBufferImage(span: Extract<ContentSpan, { special: 'image' }>): void {
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
  outputEl.appendChild(img);
  outputEl.scrollTop = outputEl.scrollHeight;
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

// Handle updates from the interpreter
function handleUpdate(update: RemGlkUpdate): void {
  if (update.type === 'error') {
    setStatus(`Error: ${update.message}`, 'error');
    return;
  }

  if (update.windows) {
    for (const win of update.windows) {
      windows.set(win.id, { type: win.type });
      if (win.type === 'graphics') {
        ensureGraphicsCanvas(win.id, win.graphwidth ?? win.width, win.graphheight ?? win.height);
      }
    }
    if (!initialized) {
      initialized = true;
      setStatus('Game initialized!', 'success');
    }
  }

  if (update.content) {
    for (const content of update.content) {
      const win = windows.get(content.id);

      if (win?.type === 'graphics') {
        const canvas = graphicsCanvases.get(content.id);
        if (content.clear && canvas) {
          canvas.getContext('2d')?.clearRect(0, 0, canvas.width, canvas.height);
        }
        if (content.draw) {
          drawGraphics(content.id, content.draw);
        }
      } else if (win?.type === 'grid') {
        // Grid window (status bar): updates carry only the changed lines, each
        // with its line number. Accumulate per line, render the window with a
        // newline between lines (grid sizing is now correct, so lines don't
        // spuriously wrap).
        let lines = gridLineText.get(content.id);
        if (!lines || content.clear) {
          lines = [];
          gridLineText.set(content.id, lines);
        }
        for (const line of content.lines ?? []) {
          let text = '';
          for (const span of line.content ?? []) {
            text += spanText(span);
          }
          lines[line.line] = text;
        }
        gameStatusBar.textContent = lines.map((l) => l ?? '').join('\n');
        gameStatusBar.classList.add('visible');
      } else {
        // Buffer window - append text and inline images from paragraphs.
        if (content.clear) {
          outputEl.replaceChildren();
        }
        for (const para of content.text ?? []) {
          for (const span of para.content ?? []) {
            if (typeof span === 'object' && 'special' in span && span.special === 'image') {
              appendBufferImage(span);
            } else {
              outputEl.appendChild(document.createTextNode(spanText(span)));
            }
          }
        }
        outputEl.scrollTop = outputEl.scrollHeight;
      }
    }
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

// Reset all per-story UI and state before (re)starting an interpreter.
function resetForNewStory(): void {
  windows.clear();
  for (const canvas of graphicsCanvases.values()) canvas.remove();
  graphicsCanvases.clear();
  graphicsColor.clear();
  gridLineText.clear();
  initialized = false;
  outputEl.textContent = '';
  gameStatusBar.textContent = '';
  gameStatusBar.classList.remove('visible');
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
    // Measure the real pixel size of the output area and its font, so the
    // interpreter converts to character cells correctly.
    client = await createClient({
      storyUrl: `/${story.file}`,
      ...(story.format ? { format: story.format } : {}),
      workerUrl: '/worker.js',
      metrics: measureMetrics({ area: outputEl }),
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
