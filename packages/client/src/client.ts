/**
 * WasiGlk Client
 *
 * Runs IF interpreters in a Web Worker using JSPI for async I/O.
 */

import { BlorbParser } from './blorb';
import { detectFormat, type FormatInfo, type StoryFormat } from './format';
import type { RemGlkUpdate } from './protocol';
import type { MainToWorkerMessage, WorkerToMainMessage } from './worker/messages';

/** Configuration for creating a WasiGlk client instance. */
export interface ClientConfig {
  /** URL to the story file */
  storyUrl?: string;
  /** Story file data (alternative to storyUrl) */
  storyData?: Uint8Array;
  /** URL to the interpreter WASM module (auto-detected if not provided) */
  interpreterUrl?: string;
  /** Interpreter WASM data (alternative to interpreterUrl) */
  interpreterData?: ArrayBuffer;
  /** Override format detection */
  format?: StoryFormat;
  /** URL to the worker script (required) */
  workerUrl: string | URL;
  /**
   * File system configuration.
   * - 'auto' (default): OPFS if available, falls back to memory
   * - 'opfs': OPFS only (throws if unavailable)
   * - 'memory': In-memory only (no persistence)
   * - 'dialog': OPFS base + file dialogs for user-prompted saves
   */
  filesystem?: 'auto' | 'opfs' | 'memory' | 'dialog';
  /** Display metrics for the interpreter output area. */
  metrics?: UpdatesConfig;
}

/** Display metrics for the interpreter output area. */
export interface UpdatesConfig {
  width: number;
  height: number;
  charWidth?: number;
  charHeight?: number;
}

/**
 * Client for running Interactive Fiction interpreters in a Web Worker.
 *
 * Use {@link createClient} to create an instance. The client loads the story
 * file and interpreter WASM module, then runs the interpreter in a Web Worker
 * using JSPI for async I/O.
 *
 * Call {@link updates} to start the interpreter and receive typed updates
 * via an async iterator. Send user input back with {@link sendInput}.
 */
export class WasiGlkClient {
  private storyData: Uint8Array;
  private interpreterData: ArrayBuffer;
  private formatInfo: FormatInfo;
  private blorb: BlorbParser | null = null;
  private worker: Worker | null = null;
  private running = false;
  private pendingUpdates: RemGlkUpdate[] = [];
  private updateResolve: ((value: IteratorResult<RemGlkUpdate>) => void) | null = null;
  private workerUrl: string | URL;
  private storyId: string;
  private filesystem: 'auto' | 'opfs' | 'memory' | 'dialog';
  private metrics: UpdatesConfig;

  private constructor(
    storyData: Uint8Array,
    interpreterData: ArrayBuffer,
    formatInfo: FormatInfo,
    blorb: BlorbParser | null,
    workerUrl: string | URL,
    storyId: string,
    filesystem: 'auto' | 'opfs' | 'memory' | 'dialog',
    metrics: UpdatesConfig,
  ) {
    this.storyData = storyData;
    this.interpreterData = interpreterData;
    this.formatInfo = formatInfo;
    this.blorb = blorb;
    this.workerUrl = workerUrl;
    this.storyId = storyId;
    this.filesystem = filesystem;
    this.metrics = metrics;
  }

  /**
   * Create a new client instance from configuration.
   * Loads the story file and interpreter, parses Blorb if applicable,
   * and returns a ready-to-use client.
   * @param config - Client configuration with story URL/data and worker URL
   */
  static async create(config: ClientConfig): Promise<WasiGlkClient> {
    // Load story
    let storyData: Uint8Array;
    let storyUrl: string | null = null;

    if (config.storyData) {
      storyData = config.storyData;
    } else if (config.storyUrl) {
      storyUrl = config.storyUrl;
      const response = await fetch(config.storyUrl);
      if (!response.ok) throw new Error(`Failed to load story: ${response.status}`);
      storyData = new Uint8Array(await response.arrayBuffer());
    } else {
      throw new Error('Either storyUrl or storyData must be provided');
    }

    // Detect format
    const formatInfo = config.format
      ? { format: config.format, interpreter: getInterpreterName(config.format), isBlorb: false }
      : detectFormat(storyUrl, storyData);

    // Parse Blorb
    let blorb: BlorbParser | null = null;
    let executableData = storyData;

    if (formatInfo.isBlorb || BlorbParser.isBlorb(storyData)) {
      blorb = new BlorbParser(storyData);
      const exec = blorb.getExecutable();
      if (exec) {
        executableData = exec.data;
        if (exec.type === 'GLUL') {
          formatInfo.format = 'glulx';
          formatInfo.interpreter = 'glulxe';
        } else if (exec.type === 'ZCOD') {
          formatInfo.format = 'zcode';
          formatInfo.interpreter = 'fizmo';
        }
      }
    }

    // Load interpreter
    let interpreterData: ArrayBuffer;
    if (config.interpreterData) {
      interpreterData = config.interpreterData;
    } else {
      const interpreterUrl = config.interpreterUrl ?? `/${formatInfo.interpreter}.wasm`;
      const response = await fetch(interpreterUrl);
      if (!response.ok) throw new Error(`Failed to load interpreter: ${response.status}`);
      interpreterData = await response.arrayBuffer();
    }

    // Generate story ID for save isolation: gameName/versionHash
    // This ensures different versions of the same game have separate saves
    const gameName = storyUrl
      ? storyUrl.split('/').pop()?.replace(/\.[^.]+$/, '') ?? 'unknown'
      : 'story';
    const versionHash = hashBytes(storyData).toString(16).padStart(8, '0');
    const storyId = `${gameName}/${versionHash}`;

    return new WasiGlkClient(executableData, interpreterData, formatInfo, blorb, config.workerUrl, storyId, config.filesystem ?? 'auto', config.metrics ?? { width: 80, height: 24 });
  }

  /** The detected format and interpreter for the loaded story. */
  get format(): FormatInfo {
    return this.formatInfo;
  }

  /** Get the Blorb parser if the story is a Blorb file, or null otherwise. */
  getBlorb(): BlorbParser | null {
    return this.blorb;
  }

  /**
   * Get a blob URL for a Blorb image resource by number.
   * @param imageNum - The image resource number from the Blorb file
   * @returns A blob URL string, or undefined if not found
   */
  getImageUrl(imageNum: number): string | undefined {
    return this.blorb?.getImageUrl(imageNum);
  }

  /**
   * Send line or character input to the interpreter.
   * Call this in response to an `input-request` update.
   * @param value - The input string (full line for line input, single char for char input)
   */
  sendInput(value: string): void {
    this.worker?.postMessage({ type: 'input', value } satisfies MainToWorkerMessage);
  }

  /**
   * Send a single character input. Alias for {@link sendInput}.
   * @param char - The character to send
   */
  sendChar(char: string): void {
    this.sendInput(char);
  }

  /**
   * Send an arrange event to notify the interpreter of window resize.
   * This should be called when the display dimensions change.
   */
  sendArrange(metrics: UpdatesConfig): void {
    this.worker?.postMessage({
      type: 'arrange',
      metrics: {
        width: metrics.width,
        height: metrics.height,
        charWidth: metrics.charWidth,
        charHeight: metrics.charHeight,
      },
    } satisfies MainToWorkerMessage);
  }

  /**
   * Send a mouse click event to the interpreter.
   * This should be called when the user clicks in a window that has requested mouse input.
   * @param windowId - The ID of the window that was clicked
   * @param x - The x coordinate of the click (in window-relative units)
   * @param y - The y coordinate of the click (in window-relative units)
   */
  sendMouse(windowId: number, x: number, y: number): void {
    this.worker?.postMessage({
      type: 'mouse',
      windowId,
      x,
      y,
    } satisfies MainToWorkerMessage);
  }

  /**
   * Send a hyperlink click event to the interpreter.
   * This should be called when the user clicks a hyperlink in a window that has requested hyperlink input.
   * @param windowId - The ID of the window containing the hyperlink
   * @param linkValue - The link value (number) that was set with glk_set_hyperlink
   */
  sendHyperlink(windowId: number, linkValue: number): void {
    this.worker?.postMessage({
      type: 'hyperlink',
      windowId,
      linkValue,
    } satisfies MainToWorkerMessage);
  }

  /**
   * Send a redraw request to the interpreter.
   * This notifies the game that a graphics window needs to be redrawn.
   * @param windowId - Optional window ID. If omitted, all graphics windows need redrawing.
   */
  sendRedraw(windowId?: number): void {
    this.worker?.postMessage({
      type: 'redraw',
      windowId,
    } satisfies MainToWorkerMessage);
  }

  /**
   * Send a refresh request to the interpreter.
   * This requests a full state refresh from the game.
   */
  sendRefresh(): void {
    this.worker?.postMessage({
      type: 'refresh',
    } satisfies MainToWorkerMessage);
  }

  /** Stop the interpreter and terminate the Web Worker. */
  stop(): void {
    this.running = false;
    this.blorb?.dispose();
    if (this.worker) {
      this.worker.postMessage({ type: 'stop' } satisfies MainToWorkerMessage);
      this.worker.terminate();
      this.worker = null;
    }
    if (this.updateResolve) {
      this.updateResolve({ value: undefined as any, done: true });
      this.updateResolve = null;
    }
  }

  /**
   * Start the interpreter and yield {@link RemGlkUpdate} objects as they arrive.
   *
   * Each update represents a complete turn from the interpreter, containing
   * all window, content, and input changes in a single batch.
   *
   * @example
   * ```typescript
   * for await (const update of client.updates()) {
   *   if (update.windows) { /* handle window layout *\/ }
   *   if (update.content) { /* handle content for each window *\/ }
   *   if (update.input) { /* prompt user and call client.sendInput() *\/ }
   * }
   * ```
   */
  async *updates(): AsyncIterableIterator<RemGlkUpdate> {
    if (this.running) throw new Error('Client is already running');
    this.running = true;

    try {
      this.worker = new Worker(this.workerUrl, { type: 'module' });

      this.worker.onmessage = (e: MessageEvent<WorkerToMainMessage>) => {
        this.handleWorkerMessage(e.data);
      };

      this.worker.onerror = (e: ErrorEvent) => {
        this.pendingUpdates.push({ type: 'error', gen: 0, message: e.message || 'Worker error' });
        this.resolveNextUpdate();
      };

      const initMessage: MainToWorkerMessage = {
        type: 'init',
        interpreter: this.interpreterData,
        story: this.storyData,
        args: [this.formatInfo.interpreter, '/sys/story.ulx'],
        metrics: this.metrics,
        storyId: this.storyId,
        filesystem: this.filesystem,
      };
      this.worker.postMessage(initMessage, [this.interpreterData]);

      while (this.running) {
        if (this.pendingUpdates.length > 0) {
          yield this.pendingUpdates.shift()!;
        } else {
          const result = await new Promise<IteratorResult<RemGlkUpdate>>(resolve => {
            this.updateResolve = resolve;
            if (!this.running) resolve({ value: undefined as any, done: true });
          });
          if (result.done) break;
          yield result.value;
        }
      }
    } finally {
      this.running = false;
      this.worker?.terminate();
      this.worker = null;
    }
  }

  private handleWorkerMessage(msg: WorkerToMainMessage): void {
    switch (msg.type) {
      case 'update':
        this.pendingUpdates.push(msg.data);
        this.resolveNextUpdate();
        break;
      case 'error':
        this.pendingUpdates.push({ type: 'error', gen: 0, message: msg.message });
        this.resolveNextUpdate();
        break;
      case 'exit':
        this.running = false;
        this.resolveNextUpdate();
        break;
      case 'fileDialogRequest':
        this.handleFileDialogRequest(msg.filemode, msg.filetype);
        break;
    }
  }

  private async handleFileDialogRequest(
    filemode: 'read' | 'write' | 'readwrite' | 'writeappend',
    filetype: 'save' | 'data' | 'transcript' | 'command'
  ): Promise<void> {
    // Check if File System Access API is available
    if (!('showOpenFilePicker' in window) || !('showSaveFilePicker' in window)) {
      console.warn('[client] File System Access API not available');
      this.worker?.postMessage({ type: 'fileDialogResult', filename: null } satisfies MainToWorkerMessage);
      return;
    }

    // Get file extension and description based on filetype
    const { extension, description } = getFileTypeInfo(filetype);

    try {
      let handle: FileSystemFileHandle;

      // Choose picker based on filemode:
      // - read: showOpenFilePicker (select existing file)
      // - write/readwrite/writeappend: showSaveFilePicker (create new or select existing)
      if (filemode === 'read') {
        // Show open file picker for reading existing files
        const [pickedHandle] = await (window as any).showOpenFilePicker({
          types: [{
            description,
            accept: { 'application/octet-stream': [`.${extension}`] },
          }],
          multiple: false,
        });
        handle = pickedHandle;
      } else {
        // Show save file picker for writing (allows creating new files)
        handle = await (window as any).showSaveFilePicker({
          suggestedName: `file.${extension}`,
          types: [{
            description,
            accept: { 'application/octet-stream': [`.${extension}`] },
          }],
        });
      }

      // Send the handle to the worker
      this.worker?.postMessage({
        type: 'fileDialogResult',
        filename: handle.name,
        handle,
      } satisfies MainToWorkerMessage);
    } catch (e) {
      // User cancelled or error occurred
      if ((e as Error).name !== 'AbortError') {
        console.error('[client] File dialog error:', e);
      }
      this.worker?.postMessage({ type: 'fileDialogResult', filename: null } satisfies MainToWorkerMessage);
    }
  }

  private resolveNextUpdate(): void {
    if (!this.updateResolve) return;
    const resolve = this.updateResolve;
    this.updateResolve = null;
    if (this.pendingUpdates.length > 0) {
      resolve({ value: this.pendingUpdates.shift()!, done: false });
    } else if (!this.running) {
      resolve({ value: undefined as any, done: true });
    }
  }
}

function getInterpreterName(format: StoryFormat): string {
  const names: Record<string, string> = {
    glulx: 'glulxe', zcode: 'fizmo', hugo: 'hugo',
    tads2: 'tads2', tads3: 'tads3',
    alan2: 'alan2', alan3: 'alan3',
    adrift: 'scare', agt: 'agility', advsys: 'advsys',
    level9: 'level9', magnetic: 'magnetic',
    scott: 'scott', taylor: 'taylor', sagaplus: 'plus',
  };
  return names[format] ?? 'glulxe';
}

function hashBytes(data: Uint8Array): number {
  let hash = 0;
  for (let i = 0; i < Math.min(data.length, 1024); i++) {
    hash = ((hash << 5) - hash + data[i]) | 0;
  }
  return hash >>> 0;
}

function getFileTypeInfo(filetype: 'save' | 'data' | 'transcript' | 'command'): { extension: string; description: string } {
  switch (filetype) {
    case 'save':
      return { extension: 'glksave', description: 'Saved Games' };
    case 'transcript':
      return { extension: 'txt', description: 'Transcripts' };
    case 'command':
      return { extension: 'txt', description: 'Command Scripts' };
    case 'data':
    default:
      return { extension: 'glkdata', description: 'Data Files' };
  }
}

/**
 * Create a new WasiGlk client.
 *
 * Loads the story file and appropriate WASM interpreter, auto-detecting
 * the story format from file extension or Blorb contents. Returns a
 * ready-to-use client.
 *
 * @param config - Client configuration with story URL/data and worker URL
 * @returns A configured client instance ready to call {@link WasiGlkClient.updates}
 *
 * @example
 * ```typescript
 * const client = await createClient({
 *   storyUrl: '/stories/zork1.z5',
 *   workerUrl: '/worker.js',
 *   filesystem: 'opfs',
 * });
 * ```
 */
export async function createClient(config: ClientConfig): Promise<WasiGlkClient> {
  return WasiGlkClient.create(config);
}
