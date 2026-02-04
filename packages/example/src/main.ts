/**
 * WasiGlk Example
 *
 * Demonstrates using @wasiglk/client to run an interactive fiction interpreter.
 */

import { createClient, type ClientUpdate } from '@wasiglk/client';

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
function handleUpdate(update: ClientUpdate): void {
  switch (update.type) {
    case 'content': {
      const win = windows.get(update.windowId);
      const isGrid = win?.type === 'grid';

      if (isGrid) {
        // Grid window (status bar) - replace content
        let text = '';
        for (const span of update.content) {
          if (span.type === 'text' && span.text) {
            text += span.text;
          }
        }
        if (text) {
          gameStatusBar.textContent = text;
          gameStatusBar.classList.add('visible');
        }
      } else {
        // Buffer window - append content
        if (update.clear) {
          outputEl.textContent = '';
        }
        for (const span of update.content) {
          if (span.type === 'text' && span.text) {
            appendOutput(span.text);
          }
        }
      }
      break;
    }

    case 'input-request':
      enableInput();
      break;

    case 'window':
      // Track window types
      for (const win of update.windows) {
        windows.set(win.id, { type: win.type });
      }
      // First window update means the game is initialized
      if (!initialized) {
        initialized = true;
        setStatus('Game initialized!', 'success');
      }
      break;

    case 'error':
      setStatus(`Error: ${update.message}`, 'error');
      break;
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
    client = await createClient({
      storyUrl: '/advent.ulx',
      interpreterUrl: '/glulxe.wasm',
      workerUrl: '/worker.js',
    });

    setStatus('Starting interpreter...', 'info');

    // Run the interpreter and handle updates
    for await (const update of client.updates({ width: 80, height: 24 })) {
      handleUpdate(update);
    }

    setStatus('Game ended.', 'info');
  } catch (e) {
    console.error('Error:', e);
    setStatus(`Error: ${(e as Error).message}`, 'error');
  }
}

main();
