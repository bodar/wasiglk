/**
 * WasiGlk Example
 *
 * Demonstrates using @bodar/wasiglk to run an interactive fiction interpreter.
 */

import { createClient, type RemGlkUpdate, type ContentSpan } from '@bodar/wasiglk';

// DOM elements
const outputEl = document.getElementById('output')!;
const inputEl = document.getElementById('input') as HTMLInputElement;
const sendBtn = document.getElementById('send') as HTMLButtonElement;
const statusEl = document.getElementById('status')!;
const gameStatusBar = document.getElementById('game-status-bar')!;

// Client instance
let client: Awaited<ReturnType<typeof createClient>> | null = null;

// Track windows by ID and type
const windows = new Map<number, { type: 'buffer' | 'grid' | 'graphics' | 'pair' }>();

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

// Output handling
function appendOutput(text: string): void {
  outputEl.textContent += text;
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
    }
    if (!initialized) {
      initialized = true;
      setStatus('Game initialized!', 'success');
    }
  }

  if (update.content) {
    for (const content of update.content) {
      const win = windows.get(content.id);

      if (win?.type === 'grid') {
        // Grid window (status bar) - extract text from lines
        let text = '';
        for (const line of content.lines ?? []) {
          for (const span of line.content ?? []) {
            text += spanText(span);
          }
        }
        if (text) {
          gameStatusBar.textContent = text;
          gameStatusBar.classList.add('visible');
        }
      } else {
        // Buffer window - append text from paragraphs
        if (content.clear) {
          outputEl.textContent = '';
        }
        for (const para of content.text ?? []) {
          for (const span of para.content ?? []) {
            appendOutput(spanText(span));
          }
        }
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

// Main
async function main(): Promise<void> {
  // Check JSPI support
  const jspiCheck = checkJSPISupport();
  if (!jspiCheck.supported) {
    setStatus(
      `JSPI not supported: ${jspiCheck.reason}. Enable chrome://flags/#enable-experimental-webassembly-jspi`,
      'error'
    );
    return;
  }

  setStatus('JSPI supported! Loading...', 'info');

  try {
    // Create client - auto-detects format and loads interpreter
    const outputRect = outputEl.getBoundingClientRect();
    client = await createClient({
      storyUrl: '/advent.ulx',
      interpreterUrl: '/glulxe.wasm',
      workerUrl: '/worker.js',
      metrics: {
        width: Math.floor(outputRect.width) || 800,
        height: Math.floor(outputRect.height) || 600,
        charWidth: 10,
        charHeight: 18,
      },
    });

    setStatus('Starting interpreter...', 'info');

    // Run the interpreter and handle updates
    for await (const update of client.updates()) {
      handleUpdate(update);
    }

    setStatus('Game ended.', 'info');
  } catch (e) {
    console.error('Error:', e);
    setStatus(`Error: ${(e as Error).message}`, 'error');
  }
}

main();
