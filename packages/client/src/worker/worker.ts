/**
 * @module
 *
 * Interpreter Worker - runs the WASM interpreter in a Web Worker using
 * browser_wasi_shim. Uses JSPI for async stdin and pluggable file storage.
 */

import {
  WASI,
  File,
  OpenFile,
  Directory,
  PreopenDirectory,
  ConsoleStdout,
  WASIProcExit,
  wasi,
  type Inode,
} from '@bjorn3/browser_wasi_shim';
import { AsyncStdinFd } from './stdin';
import {
  createStorageProvider,
  isDialogProvider,
  type StorageProvider,
  type FileType,
  type FileMode,
} from './storage';
import { AsyncFSAFile } from './storage/async-fsa-file';
import type { MainToWorkerMessage, WorkerToMainMessage } from './messages';
import type { InputEvent, RemGlkUpdate } from '../protocol';
import { TranscriptRecorder } from './transcript';
import { ReplayQueue } from './replay-queue';

let inputResolve: ((value: string) => void) | null = null;
let generation = 0;
let currentInputRequest: { windowId: number; type: 'line' | 'char' } | null = null;
let timerIntervalId: ReturnType<typeof setInterval> | null = null;

// File dialog state (for dialog mode)
let pendingFileDialog: { filemode: FileMode; filetype: FileType } | null = null;
let fileDialogResolve: ((result: { filename: string | null; handle?: FileSystemFileHandle }) => void) | null = null;

// Storage provider (set during init)
let storageProvider: StorageProvider | null = null;

function post(msg: WorkerToMainMessage): void {
  self.postMessage(msg);
}

self.onmessage = async (e: MessageEvent<MainToWorkerMessage>) => {
  const msg = e.data;
  if (msg.type === 'init') {
    await runInterpreter(msg);
  } else if (msg.type === 'input' && inputResolve) {
    const resolve = inputResolve;
    inputResolve = null;
    // Format as RemGlk input event
    const inputEvent = {
      type: currentInputRequest?.type ?? 'line',
      gen: generation,
      window: currentInputRequest?.windowId ?? 0,
      value: msg.value,
    };
    resolve(JSON.stringify(inputEvent));
  } else if (msg.type === 'arrange' && inputResolve) {
    // Send arrange event to interrupt current input request
    const resolve = inputResolve;
    inputResolve = null;
    resolve(JSON.stringify({
      type: 'arrange',
      gen: generation,
      metrics: msg.metrics,
    }));
  } else if (msg.type === 'mouse' && inputResolve) {
    // Send mouse click event to interrupt current input request
    const resolve = inputResolve;
    inputResolve = null;
    resolve(JSON.stringify({
      type: 'mouse',
      gen: generation,
      window: msg.windowId,
      x: msg.x,
      y: msg.y,
    }));
  } else if (msg.type === 'hyperlink' && inputResolve) {
    // Send hyperlink click event to interrupt current input request
    const resolve = inputResolve;
    inputResolve = null;
    resolve(JSON.stringify({
      type: 'hyperlink',
      gen: generation,
      window: msg.windowId,
      value: msg.linkValue,
    }));
  } else if (msg.type === 'redraw' && inputResolve) {
    // Send redraw request to interrupt current input request
    const resolve = inputResolve;
    inputResolve = null;
    resolve(JSON.stringify({
      type: 'redraw',
      gen: generation,
      window: msg.windowId,
    }));
  } else if (msg.type === 'refresh' && inputResolve) {
    // Send refresh request to get full state resent
    const resolve = inputResolve;
    inputResolve = null;
    resolve(JSON.stringify({
      type: 'refresh',
      gen: generation,
    }));
  } else if (msg.type === 'fileDialogResult' && fileDialogResolve) {
    // File dialog completed, resolve the pending promise
    const resolve = fileDialogResolve;
    fileDialogResolve = null;
    resolve({ filename: msg.filename, handle: msg.handle });
  } else if (msg.type === 'stop') {
    self.close();
  }
};

async function runInterpreter(msg: MainToWorkerMessage & { type: 'init' }): Promise<void> {
  try {
    // Initialize storage provider based on filesystem mode
    storageProvider = await createStorageProvider({
      mode: msg.filesystem,
      storyId: msg.storyId,
    });

    // Set up dialog requester for dialog-capable providers
    if (isDialogProvider(storageProvider)) {
      storageProvider.setDialogRequester(async (filemode, filetype) => {
        // Request file dialog from main thread
        post({
          type: 'fileDialogRequest',
          filemode,
          filetype,
        });
        // Wait for result
        return new Promise(resolve => {
          fileDialogResolve = resolve;
        });
      });
    }

    // Initialize storage and get existing files
    const rootContents = await storageProvider.initialize();

    // Transcript recorder (optional): pairs every input fed to the interpreter
    // with the output update it produces, emitting `.glktra` stanzas.
    const recorder = msg.recordTranscript
      ? new TranscriptRecorder(
          msg.sessionId ?? crypto.randomUUID(),
          msg.transcriptLabel ?? msg.storyId,
          stanza => post({ type: 'transcript', stanza }),
        )
      : null;

    // Recorded inputs to replay verbatim before falling through to live input.
    // Symmetric with the recorder above: it taps this funnel's output, the
    // queue supplies its input. Empty unless msg.replayInputs is provided.
    const replayQueue = new ReplayQueue(msg.replayInputs);

    // The single funnel producing every stdin string the interpreter reads.
    const provideInput = async (): Promise<string> => {
      // Replay: feed the next recorded event verbatim (exact gen, timer ticks,
      // dialog answers) until the recording is exhausted, then resume live.
      if (replayQueue.active) {
        const next = replayQueue.next()!;
        const genVal = (next as { gen?: unknown }).gen;
        if (typeof genVal === 'number') generation = genVal;
        // A recorded dialog answer stands in for re-prompting storage; clear
        // the flag so a later live turn can't re-trigger an answered dialog.
        if ((next as { type?: unknown }).type === 'specialresponse') pendingFileDialog = null;
        // On drain, arm the live timer with the last interval the game asked
        // for during replay (a later output may still override it below).
        const deferred = replayQueue.takeDeferredTimer();
        if (deferred) handleTimerUpdate(deferred.interval);
        return JSON.stringify(next);
      }

      if (generation === 0) {
        generation = 1;
        return JSON.stringify({
          type: 'init',
          gen: 0,
          metrics: msg.metrics,
          support: msg.support ?? ['timer', 'graphics', 'graphicswin', 'hyperlinks'],
        } satisfies InputEvent);
      }

      // Check for pending file dialog
      if (pendingFileDialog) {
        const dialogInfo = pendingFileDialog;
        pendingFileDialog = null;

        // Let the storage provider handle the prompt
        const result = await storageProvider!.handlePrompt({
          filetype: dialogInfo.filetype,
          filemode: dialogInfo.filemode,
        });

        return JSON.stringify({
          type: 'specialresponse',
          gen: generation,
          response: 'fileref_prompt',
          value: result.filename,
        });
      }

      return new Promise<string>(resolve => { inputResolve = resolve; });
    };

    // stdin: async for JSPI. When recording, capture every input string fed to
    // the interpreter (init/line/char/timer/arrange/mouse/hyperlink/special).
    const stdin = new AsyncStdinFd(
      recorder
        ? async () => {
            const input = await provideInput();
            recorder.recordInput(input, Date.now());
            return input;
          }
        : provideInput,
    );

    // stdout: parse JSON updates, batching all output from one interpreter turn
    let pendingBatch: RemGlkUpdate[] = [];
    let batchScheduled = false;

    const stdout = ConsoleStdout.lineBuffered((line: string) => {
      if (!line.trim()) return;
      try {
        const update = JSON.parse(line) as RemGlkUpdate;
        // Track state immediately (before batched post)
        if (update.gen !== undefined) generation = update.gen;
        if (update.input && update.input.length > 0) {
          currentInputRequest = { windowId: update.input[0].id, type: update.input[0].type };
        }
        if (update.timer !== undefined) {
          // During replay, recorded `timer` events supply the ticks — stash the
          // interval instead of arming the live setInterval that would race the
          // drain; ReplayQueue applies it when the recording runs out.
          if (replayQueue.active) replayQueue.deferTimer(update.timer);
          else handleTimerUpdate(update.timer);
        }
        if (update.specialinput) {
          pendingFileDialog = { filemode: update.specialinput.filemode as FileMode, filetype: update.specialinput.filetype as FileType };
        }
        // Batch: the interpreter runs synchronously between glk_select calls,
        // so all styled runs from one turn arrive in the same JS task.
        // Merge them into one update on the next microtask.
        pendingBatch.push(update);
        if (!batchScheduled) {
          batchScheduled = true;
          queueMicrotask(() => {
            batchScheduled = false;
            const batch = pendingBatch;
            pendingBatch = [];
            const merged = mergeRemGlkUpdates(batch);
            recorder?.recordOutput(merged, Date.now());
            post({ type: 'update', data: merged });
          });
        }
      } catch {
        console.log('[interpreter]', line);
      }
    });

    // stderr - use console.debug for debug messages from the interpreter
    const stderr = ConsoleStdout.lineBuffered(line => console.debug('[interpreter]', line));

    // Filesystem: Unix-like structure
    // /sys/  - read-only system files (story)
    // /var/  - auto-managed data (saves, transcripts) - from storage provider
    // /home/ - user files from dialogs
    const sysDir = new Directory(new Map([
      ['story.ulx', new File(msg.story, { readonly: true })],
    ]));
    const homeContents = new Map<string, Inode>();
    const homeDir = new Directory(homeContents);

    // Give dialog provider access to /home/ directory
    if (isDialogProvider(storageProvider)) {
      storageProvider.setHomeDirectory(homeContents);
    }

    // Root combines system dirs with storage provider contents (which go in /var/)
    const rootMap = new Map<string, Inode>([
      ['sys', sysDir],
      ['var', new Directory(rootContents)],
      ['home', homeDir],
    ]);

    const root = new PreopenDirectory('/', rootMap);

    // Create WASI and instantiate
    const wasiInstance = new WASI(msg.args, [], [stdin, stdout, stderr, root]);
    const module = await WebAssembly.compile(msg.interpreter);
    const imports = wrapWithJSPI(wasiInstance, stdin, storageProvider, root);
    const instance = await WebAssembly.instantiate(module, imports);
    wasiInstance.inst = instance as { exports: { memory: WebAssembly.Memory } };

    // Run with JSPI
    const main = (instance.exports._start ?? instance.exports.main) as Function | undefined;
    if (!main) throw new Error('No _start or main export found');

    // @ts-expect-error - JSPI API
    const promisedMain = WebAssembly.promising(main);

    try {
      await promisedMain();
      post({ type: 'exit', code: 0 });
    } catch (err) {
      if (err instanceof WASIProcExit) {
        post({ type: 'exit', code: err.code });
      } else {
        throw err;
      }
    } finally {
      // Clean up storage handles to release file locks
      storageProvider?.close();
    }
  } catch (err) {
    post({ type: 'error', message: err instanceof Error ? err.message : String(err) });
  }
}

function wrapWithJSPI(
  wasiInstance: WASI,
  stdin: AsyncStdinFd,
  provider: StorageProvider,
  root: PreopenDirectory,
): WebAssembly.Imports {
  const imports = wasiInstance.wasiImport;
  const ROOT_FD = 3; // Root preopen directory is fd 3

  // Async fd_read for stdin (other fds use sync path)
  const asyncFdRead = async (fd: number, iovsPtr: number, iovsLen: number, nreadPtr: number): Promise<number> => {
    // Stdin - async via JSPI
    if (fd === 0) {
      const memory = wasiInstance.inst.exports.memory;
      const view = new DataView(memory.buffer);
      const bytes = new Uint8Array(memory.buffer);

      let nread = 0;
      for (let i = 0; i < iovsLen; i++) {
        const buf = view.getUint32(iovsPtr + i * 8, true);
        const len = view.getUint32(iovsPtr + i * 8 + 4, true);
        const { ret, data } = await stdin.fd_read_async(len);
        if (ret !== wasi.ERRNO_SUCCESS) {
          view.setUint32(nreadPtr, nread, true);
          return ret;
        }
        bytes.set(data, buf);
        nread += data.length;
        if (data.length < len) break;
      }
      view.setUint32(nreadPtr, nread, true);
      return wasi.ERRNO_SUCCESS;
    }

    // Other fds - sync (AsyncFSAFile.read() is sync via inherited WasiFile)
    return imports.fd_read(fd, iovsPtr, iovsLen, nreadPtr) as number;
  };


  // Async path_open for persistent file creation
  const asyncPathOpen = async (
    fd: number,
    dirflags: number,
    pathPtr: number,
    pathLen: number,
    oflags: number,
    fsRightsBase: bigint,
    fsRightsInheriting: bigint,
    fdFlags: number,
    openedFdPtr: number,
  ): Promise<number> => {
    const memory = wasiInstance.inst.exports.memory;
    const bytes = new Uint8Array(memory.buffer);

    // Decode path string
    const path = new TextDecoder().decode(bytes.slice(pathPtr, pathPtr + pathLen));
    console.log(`[wasi] path_open: fd=${fd} path="${path}" oflags=${oflags}`);

    // Files under /var/ are managed by the storage provider
    const VAR_PREFIX = 'var/';
    const isVarPath = path.startsWith(VAR_PREFIX);
    const storagePath = isVarPath ? path.slice(VAR_PREFIX.length) : path;

    const shouldPersist =
      fd === ROOT_FD &&
      isVarPath &&
      (oflags & wasi.OFLAGS_CREAT) !== 0 &&
      provider.shouldPersist(storagePath);

    if (shouldPersist) {
      // Check if file already exists in the directory tree
      const existingFile = findFileInTree(root.dir, path);

      if (!existingFile) {
        try {
          // Async file creation - WASM suspends here
          // Provider paths are relative to /var/, so use storagePath
          await provider.createFile(storagePath);
        } catch (err) {
          console.error(`[storage] Failed to create file ${path}:`, err);
          // Fall through to normal path_open which will create in-memory file
        }
      }
    }

    // Use normal path_open (now the file exists if we created it)
    return imports.path_open(
      fd, dirflags, pathPtr, pathLen, oflags,
      fsRightsBase, fsRightsInheriting, fdFlags, openedFdPtr,
    ) as number;
  };

  // Async fd_close for files with external handles
  const asyncFdClose = async (fd: number): Promise<number> => {
    const fdObj = wasiInstance.fds[fd];

    // Capture data and handle synchronously before closing
    let dataToWrite: ArrayBuffer | null = null;
    let handleToWrite: FileSystemFileHandle | null = null;

    if (fdObj instanceof OpenFile && fdObj.file instanceof AsyncFSAFile) {
      const asyncFile = fdObj.file;
      if (asyncFile.externalHandle) {
        // Copy data before close to ensure we have final state
        dataToWrite = asyncFile.data.slice().buffer;
        handleToWrite = asyncFile.externalHandle;
      }
    }

    // Close the fd first (proper WASI semantics)
    const result = imports.fd_close(fd) as number;

    // Then async write to external file (WASM suspended via JSPI)
    if (dataToWrite && handleToWrite) {
      try {
        const writable = await handleToWrite.createWritable();
        await writable.write(dataToWrite);
        await writable.close();
        console.log(`[async-fsa] Wrote ${dataToWrite.byteLength} bytes to external file`);
      } catch (err) {
        console.error('[async-fsa] Failed to write to external file:', err);
        // Log and continue - fd is already closed
      }
    }

    return result;
  };

  return {
    wasi_snapshot_preview1: {
      ...imports,
      // @ts-expect-error - JSPI API
      fd_read: new WebAssembly.Suspending(asyncFdRead),
      // @ts-expect-error - JSPI API
      path_open: new WebAssembly.Suspending(asyncPathOpen),
      // @ts-expect-error - JSPI API
      fd_close: new WebAssembly.Suspending(asyncFdClose),
    },
  };
}

/**
 * Find a file in the directory tree by path.
 */
function findFileInTree(dir: Directory, path: string): Inode | null {
  const parts = path.split('/').filter(p => p.length > 0);
  let current: Inode = dir;

  for (const part of parts) {
    if (!(current instanceof Directory)) {
      return null;
    }
    const next = current.contents.get(part);
    if (!next) {
      return null;
    }
    current = next;
  }

  return current;
}

/**
 * Merge multiple RemGlk updates from one interpreter turn into one.
 * Style changes cause the interpreter to flush per styled run, but
 * the renderer needs all content from one turn together.
 */
function mergeRemGlkUpdates(updates: RemGlkUpdate[]): RemGlkUpdate {
  if (updates.length === 1) return updates[0];
  const merged: RemGlkUpdate = { type: 'update', gen: 0 };
  for (const update of updates) {
    if (update.gen !== undefined) merged.gen = update.gen;
    if (update.type === 'error') merged.type = 'error';
    if (update.message) merged.message = update.message;
    if (update.windows) merged.windows = update.windows;
    if (update.input) merged.input = update.input;
    if (update.timer !== undefined) merged.timer = update.timer;
    if (update.specialinput) merged.specialinput = update.specialinput;
    if (update.disable !== undefined) merged.disable = update.disable;
    if (update.exit !== undefined) merged.exit = update.exit;
    if (update.debugoutput) merged.debugoutput = [...(merged.debugoutput ?? []), ...update.debugoutput];
    if (update.content) {
      if (!merged.content) merged.content = [];
      for (const c of update.content) {
        const existing = merged.content.find(e => e.id === c.id);
        if (existing && c.text) {
          if (!existing.text) existing.text = [];
          existing.text.push(...c.text);
        } else {
          merged.content.push({ ...c, text: c.text ? [...c.text] : undefined });
        }
      }
    }
  }
  return merged;
}

/**
 * Handle timer updates from the interpreter.
 * Sets up or cancels a JavaScript interval timer.
 */
function handleTimerUpdate(interval: number | null): void {
  // Clear any existing timer
  if (timerIntervalId !== null) {
    clearInterval(timerIntervalId);
    timerIntervalId = null;
  }

  // Set up new timer if interval is specified
  if (interval !== null && interval > 0) {
    timerIntervalId = setInterval(() => {
      // Fire timer event if we're waiting for input
      if (inputResolve) {
        const resolve = inputResolve;
        inputResolve = null;
        resolve(JSON.stringify({
          type: 'timer',
          gen: generation,
        }));
      }
    }, interval);
  }
}
