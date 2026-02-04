/**
 * Interpreter Worker
 *
 * Runs the WASM interpreter in a Web Worker using browser_wasi_shim.
 * Uses JSPI for async stdin and OPFS file creation.
 */

import {
  WASI,
  File,
  Directory,
  PreopenDirectory,
  ConsoleStdout,
  WASIProcExit,
  SyncOPFSFile,
  wasi,
  type Inode,
} from '@bjorn3/browser_wasi_shim';
import { AsyncStdinFd } from './stdin';
import { OpfsStorage } from './opfs-storage';
import type { MainToWorkerMessage, WorkerToMainMessage } from './messages';
import type { InputEvent, RemGlkUpdate } from '../protocol';

let inputResolve: ((value: string) => void) | null = null;
let generation = 0;
let currentInputRequest: { windowId: number; type: 'line' | 'char' } | null = null;

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
  } else if (msg.type === 'stop') {
    self.close();
  }
};

async function runInterpreter(msg: MainToWorkerMessage & { type: 'init' }): Promise<void> {
  try {
    // stdin: async for JSPI
    const stdin = new AsyncStdinFd(async () => {
      if (generation === 0) {
        generation = 1;
        return JSON.stringify({
          type: 'init',
          gen: 0,
          metrics: {
            width: msg.metrics.width,
            height: msg.metrics.height,
            charwidth: msg.metrics.charWidth,
            charheight: msg.metrics.charHeight,
          },
          // Declare features the display supports (per GlkOte spec)
          support: ['timer', 'graphics', 'graphicswin', 'hyperlinks'],
        } satisfies InputEvent);
      }
      return new Promise<string>(resolve => { inputResolve = resolve; });
    });

    // stdout: parse JSON updates
    const stdout = ConsoleStdout.lineBuffered((line: string) => {
      if (!line.trim()) return;
      try {
        const update = JSON.parse(line) as RemGlkUpdate;
        // Track generation for input responses
        if (update.gen !== undefined) {
          generation = update.gen;
        }
        // Track current input request
        if (update.input && update.input.length > 0) {
          currentInputRequest = {
            windowId: update.input[0].id,
            type: update.input[0].type,
          };
        }
        post({ type: 'update', data: update });
      } catch {
        console.log('[interpreter]', line);
      }
    });

    // stderr
    const stderr = ConsoleStdout.lineBuffered(line => console.error('[interpreter]', line));

    // Initialize OPFS for persistent storage (if available)
    let opfsStorage: OpfsStorage | null = null;
    let rootContents = new Map<string, Inode>();

    if (OpfsStorage.isAvailable()) {
      try {
        const result = await OpfsStorage.create({ storyId: msg.storyId });
        opfsStorage = result.manager;
        rootContents = result.rootContents;
      } catch (err) {
        console.warn('[worker] OPFS initialization failed, files will not persist:', err);
      }
    } else {
      console.warn('[worker] OPFS not available, files will not persist');
    }

    // Filesystem: story file (read-only) + any persisted files from OPFS
    // Ensure saves directory exists (for compatibility)
    if (!rootContents.has('saves')) {
      rootContents.set('saves', new Directory(new Map()));
    }
    // Add story file (read-only, not persisted)
    rootContents.set('story.ulx', new File(msg.story, { readonly: true }));

    const root = new PreopenDirectory('/', rootContents);

    // Create WASI and instantiate
    const wasiInstance = new WASI(msg.args, [], [stdin, stdout, stderr, root]);
    const module = await WebAssembly.compile(msg.interpreter);
    const imports = wrapWithJSPI(wasiInstance, stdin, opfsStorage, root);
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
      // Clean up OPFS handles to release file locks
      opfsStorage?.close();
    }
  } catch (err) {
    post({ type: 'error', message: err instanceof Error ? err.message : String(err) });
  }
}

function wrapWithJSPI(
  wasiInstance: WASI,
  stdin: AsyncStdinFd,
  opfsStorage: OpfsStorage | null,
  root: PreopenDirectory,
): WebAssembly.Imports {
  const imports = wasiInstance.wasiImport;
  const ROOT_FD = 3; // Root preopen directory is fd 3

  // Async fd_read for stdin
  const asyncFdRead = async (fd: number, iovsPtr: number, iovsLen: number, nreadPtr: number): Promise<number> => {
    if (fd !== 0) {
      return imports.fd_read(fd, iovsPtr, iovsLen, nreadPtr) as number;
    }

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
  };

  // Async path_open for OPFS file creation
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

    // Check if creating a file that should be persisted
    const shouldPersist =
      opfsStorage !== null &&
      fd === ROOT_FD &&
      (oflags & wasi.OFLAGS_CREAT) !== 0 &&
      OpfsStorage.shouldPersist(path);

    if (shouldPersist) {
      // Check if file already exists in the directory tree
      const existingFile = findFileInTree(root.dir, path);

      if (!existingFile) {
        try {
          // Async OPFS file creation - WASM suspends here
          const syncHandle = await opfsStorage.createFile(path);
          const opfsFile = new SyncOPFSFile(syncHandle);
          addFileToTree(root.dir, path, opfsFile);
          console.log(`[opfs] Created persistent file: ${path}`);
        } catch (err) {
          console.error(`[opfs] Failed to create file ${path}:`, err);
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

  return {
    wasi_snapshot_preview1: {
      ...imports,
      // @ts-expect-error - JSPI API
      fd_read: new WebAssembly.Suspending(asyncFdRead),
      // @ts-expect-error - JSPI API
      path_open: new WebAssembly.Suspending(asyncPathOpen),
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
 * Add a file to the directory tree at the given path.
 * Creates intermediate directories as needed.
 */
function addFileToTree(dir: Directory, path: string, file: Inode): void {
  const parts = path.split('/').filter(p => p.length > 0);
  const filename = parts.pop();
  if (!filename) return;

  // Navigate/create directories
  let current = dir;
  for (const part of parts) {
    let next = current.contents.get(part);
    if (!next) {
      next = new Directory(new Map());
      current.contents.set(part, next);
    }
    if (!(next instanceof Directory)) {
      console.error(`[opfs] Path component ${part} is not a directory`);
      return;
    }
    current = next;
  }

  current.contents.set(filename, file);
}
