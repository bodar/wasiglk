/**
 * WasiGlk Client
 *
 * Runs IF interpreters in a Web Worker using JSPI for async I/O.
 */

import { BlorbParser } from './blorb';
import { detectFormat, extensionForFormat, type FormatInfo, type StoryFormat } from './format';
import { isZip, unzipEntries, pickPrimary } from './container';
import type { Metrics, RemGlkUpdate } from './protocol';
import type { MainToWorkerMessage, WorkerToMainMessage } from './worker/messages';
import type { TranscriptStanza } from './worker/transcript';
import type { ReplayEvent } from './worker/replay-queue';
import { inputsFromGlktra } from './glktra';

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
  metrics?: Metrics;
  /** Features the display supports (per GlkOte spec). Defaults to ['timer', 'graphics', 'graphicswin', 'hyperlinks']. */
  support?: string[];
  /**
   * Record a `.glktra` transcript stream of the session (default: false).
   * When enabled, iterate {@link WasiGlkClient.transcript} to receive the
   * recorded stanzas; the library only produces them — persistence is the
   * consumer's responsibility.
   */
  recordTranscript?: boolean;
  /** Label stored in each transcript stanza. Defaults to storyUrl ?? storyId. */
  transcriptLabel?: string;
  /**
   * Recorded `.glktra` input events to replay through the interpreter before
   * falling through to live input. Each event is fed to the interpreter's stdin
   * verbatim — exact gens, timer ticks and file-dialog responses — so a
   * deterministic interpreter reproduces the recorded session. Once the
   * recording is exhausted the session continues live (input from
   * {@link WasiGlkClient.sendInput} etc.). Build this from a `.glktra` stream
   * with {@link inputsFromGlktra}, or use {@link WasiGlkClient.fromGlktra}.
   */
  replayInputs?: ReplayEvent[];
}

/** Fully-resolved construction options, assembled by {@link WasiGlkClient.create}. */
interface WasiGlkClientOptions {
  storyData: Uint8Array;
  storyName: string;
  interpreterData: ArrayBuffer;
  formatInfo: FormatInfo;
  blorb: BlorbParser | null;
  workerUrl: string | URL;
  storyId: string;
  filesystem: 'auto' | 'opfs' | 'memory' | 'dialog';
  metrics: Metrics;
  support: string[] | undefined;
  recordTranscript: boolean;
  sessionId: string;
  transcriptLabel: string;
  replayInputs: ReplayEvent[] | undefined;
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
  private storyName: string;
  private interpreterData: ArrayBuffer;
  private formatInfo: FormatInfo;
  private blorb: BlorbParser | null = null;
  private worker: Worker | null = null;
  private running = false;
  private pendingUpdates: RemGlkUpdate[] = [];
  private updateResolve: ((value: IteratorResult<RemGlkUpdate>) => void) | null = null;
  private pendingStanzas: TranscriptStanza[] = [];
  private transcriptResolve: ((value: TranscriptStanza[] | null) => void) | null = null;
  private transcriptDone = false;
  private workerUrl: string | URL;
  private storyId: string;
  private filesystem: 'auto' | 'opfs' | 'memory' | 'dialog';
  private metrics: Metrics;
  private support?: string[];
  private recordTranscript: boolean;
  private sessionId: string;
  private transcriptLabel: string;
  private replayInputs?: ReplayEvent[];

  private constructor(options: WasiGlkClientOptions) {
    this.storyData = options.storyData;
    this.storyName = options.storyName;
    this.interpreterData = options.interpreterData;
    this.formatInfo = options.formatInfo;
    this.blorb = options.blorb;
    this.workerUrl = options.workerUrl;
    this.storyId = options.storyId;
    this.filesystem = options.filesystem;
    this.metrics = options.metrics;
    this.support = options.support;
    this.recordTranscript = options.recordTranscript;
    this.sessionId = options.sessionId;
    this.transcriptLabel = options.transcriptLabel;
    this.replayInputs = options.replayInputs;
  }

  /** The unique id for this play session (used as `sessionId` in stanzas). */
  get session(): string {
    return this.sessionId;
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

    // The story is always ONE blob: either a bare story file, or a single-file
    // container (a zip) holding the story plus companion resources. Delivery
    // stays single-blob — the whole `storyData` goes to the worker, which
    // explodes any container into /sys. Here we only peek inside to pick the
    // interpreter and the primary filename.
    //
    // `primaryData` is the story file's own bytes (the container's story entry,
    // or `storyData` itself); it drives format detection, Blorb parsing and the
    // save hash. `storyName` is the primary file's name in /sys — the original
    // name is preserved so interpreters that derive companion names from it
    // (alan3, plus, taylor, …) find their siblings.
    const configFormat = config.format
      ? { format: config.format, interpreter: getInterpreterName(config.format), isBlorb: false }
      : undefined;

    let formatInfo: FormatInfo;
    let primaryData: Uint8Array;
    let storyName: string;

    if (isZip(storyData)) {
      const sel = pickPrimary(unzipEntries(storyData), configFormat);
      formatInfo = sel.formatInfo;
      primaryData = sel.primary.data;
      storyName = sel.primary.name;
    } else {
      formatInfo = configFormat ?? detectFormat(storyUrl, storyData);
      primaryData = storyData;
      storyName = storyFilename(storyUrl, formatInfo);
    }

    // Parse Blorb (if any) to pick the interpreter and to hold image resources
    // for client-side rendering. We deliberately do NOT unwrap the executable
    // chunk: the whole, unmodified story file is handed to the interpreter so it
    // can self-detect the Blorb and call giblorb_set_resource_map itself. That
    // populates the server-side blorb map, which is what glk_image_get_info /
    // glk_image_draw read from. (This mirrors the emglken/remglk-rs contract;
    // stripping to the bare .ulx/.z5 is why images previously never drew.)
    let blorb: BlorbParser | null = null;

    if (formatInfo.isBlorb || BlorbParser.isBlorb(primaryData)) {
      blorb = new BlorbParser(primaryData);
      const exec = blorb.getExecutable();
      if (exec) {
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

    // Generate story ID for save isolation: gameName/versionHash. Hash the
    // story file's own bytes (not the container) so re-zipping a game keeps its
    // saves. This ensures different versions of the same game have separate saves.
    const gameName = (storyUrl ? basename(storyUrl) : storyName).replace(/\.[^.]+$/, '') || 'story';
    const versionHash = hashBytes(primaryData).toString(16).padStart(8, '0');
    const storyId = `${gameName}/${versionHash}`;

    // Unique per-play-session id, distinct from the per-story-version storyId.
    const sessionId = crypto.randomUUID();
    const transcriptLabel = config.transcriptLabel ?? storyUrl ?? storyId;

    return new WasiGlkClient({
      storyData,
      storyName,
      interpreterData,
      formatInfo,
      blorb,
      workerUrl: config.workerUrl,
      storyId,
      filesystem: config.filesystem ?? 'auto',
      metrics: config.metrics ?? { width: 80, height: 24 },
      support: config.support,
      recordTranscript: config.recordTranscript ?? false,
      sessionId,
      transcriptLabel,
      replayInputs: config.replayInputs,
    });
  }

  /**
   * Create a client that replays a `.glktra` recording, then continues live.
   *
   * Convenience over {@link createClient}: parses the recording's input events
   * ({@link inputsFromGlktra}) and passes them as {@link ClientConfig.replayInputs}.
   * Iterate {@link updates} as usual — the first updates are the interpreter's
   * responses to the recorded input (pulled at your own pace, not wall-clock),
   * and once the recording runs out `sendInput` and friends drive it live.
   *
   * @param config - Client configuration (without `replayInputs`).
   * @param glktra - The `.glktra` recording as a byte stream or chunk iterable.
   */
  static async fromGlktra(
    config: Omit<ClientConfig, 'replayInputs'>,
    glktra: string | ReadableStream<Uint8Array> | AsyncIterable<Uint8Array | string>,
  ): Promise<WasiGlkClient> {
    const replayInputs = await inputsFromGlktra(glktra);
    return WasiGlkClient.create({ ...config, replayInputs });
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
  sendArrange(metrics: Metrics): void {
    this.worker?.postMessage({
      type: 'arrange',
      metrics,
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
        this.finish();
      };

      const initMessage: MainToWorkerMessage = {
        type: 'init',
        interpreter: this.interpreterData,
        story: this.storyData,
        storyName: this.storyName,
        args: [this.formatInfo.interpreter, `/sys/${this.storyName}`],
        metrics: this.metrics,
        support: this.support,
        storyId: this.storyId,
        filesystem: this.filesystem,
        recordTranscript: this.recordTranscript,
        sessionId: this.sessionId,
        transcriptLabel: this.transcriptLabel,
        replayInputs: this.replayInputs,
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
      // End both streams, in case no 'exit'/'error' message arrived
      // (explicit termination, or the consumer broke the loop early).
      this.finish();
      this.worker?.terminate();
      this.worker = null;
    }
  }

  /** End the session: terminate both the update and transcript streams. */
  private finish(): void {
    this.running = false;
    this.transcriptDone = true;
    this.resolveNextUpdate();
    this.resolveNextTranscript();
  }

  /**
   * Stream of recorded `.glktra` transcript stanzas, when
   * {@link ClientConfig.recordTranscript} is enabled.
   *
   * Each pull yields **all** stanzas accumulated since the previous pull
   * (always at least one): when the consumer keeps up, arrays hold a single
   * stanza; when it falls behind, the stream self-batches. Batch boundaries are
   * a timing artifact and carry no meaning — do not key off the grouping.
   *
   * Requires {@link updates} to be iterated concurrently — that call starts the
   * worker and drives the session that produces these stanzas; without it this
   * stream yields nothing and never ends. The stream ends when the session
   * exits or errors.
   *
   * The library only produces stanzas; persist them however you like — e.g.
   * concatenate `JSON.stringify(stanza) + "\n"` per stanza to build a `.glktra`
   * file.
   */
  async *transcript(): AsyncIterableIterator<TranscriptStanza[]> {
    if (!this.recordTranscript) return; // nothing will ever be produced
    while (!this.transcriptDone || this.pendingStanzas.length > 0) {
      if (this.pendingStanzas.length > 0) {
        const batch = this.pendingStanzas;
        this.pendingStanzas = [];
        yield batch;
      } else {
        const batch = await new Promise<TranscriptStanza[] | null>(resolve => {
          this.transcriptResolve = resolve;
          if (this.transcriptDone) resolve(null);
        });
        if (batch === null) break;
        yield batch;
      }
    }
  }

  private handleWorkerMessage(msg: WorkerToMainMessage): void {
    switch (msg.type) {
      case 'update':
        this.pendingUpdates.push(msg.data);
        this.resolveNextUpdate();
        break;
      case 'error':
        // A worker error ends the session; deliver the error update, then
        // terminate both streams (the worker sends nothing further).
        this.pendingUpdates.push({ type: 'error', gen: 0, message: msg.message });
        this.finish();
        break;
      case 'transcript':
        this.pendingStanzas.push(msg.stanza);
        this.resolveNextTranscript();
        break;
      case 'exit':
        this.finish();
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

  private resolveNextTranscript(): void {
    if (!this.transcriptResolve) return;
    const resolve = this.transcriptResolve;
    this.transcriptResolve = null;
    if (this.pendingStanzas.length > 0) {
      const batch = this.pendingStanzas;
      this.pendingStanzas = [];
      resolve(batch);
    } else if (this.transcriptDone) {
      resolve(null);
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

/** The final path segment of a URL, with any query/fragment stripped. */
function basename(url: string): string {
  return url.split(/[?#]/)[0].split('/').pop() ?? '';
}

/**
 * The name a bare (non-container) story file gets in /sys. The original name is
 * preserved when the URL carries one (interpreters that derive companion names
 * from it need the real name); otherwise — raw bytes with no name — a canonical
 * `story.<ext>` is fabricated from the detected format.
 */
function storyFilename(url: string | null, formatInfo: FormatInfo): string {
  if (url) {
    const name = basename(url);
    if (name.includes('.')) return name;
  }
  return `story${extensionForFormat(formatInfo.format, formatInfo.isBlorb)}`;
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

/**
 * Create a client that replays a `.glktra` recording, then continues live.
 *
 * Thin wrapper over {@link WasiGlkClient.fromGlktra}: loads the story and
 * interpreter as {@link createClient} does, but re-drives the interpreter with
 * the recorded input first. Iterate {@link WasiGlkClient.updates} as usual.
 *
 * @param config - Client configuration (without `replayInputs`).
 * @param glktra - The `.glktra` recording as a byte stream or chunk iterable.
 *
 * @example
 * ```typescript
 * const res = await fetch('/recordings/session.glktra');
 * const client = await createReplayClient(
 *   { storyUrl: '/stories/advent.ulx', workerUrl: '/worker.js' },
 *   res.body!,
 * );
 * for await (const update of client.updates()) { /* render *\/ }
 * ```
 */
export async function createReplayClient(
  config: Omit<ClientConfig, 'replayInputs'>,
  glktra: string | ReadableStream<Uint8Array> | AsyncIterable<Uint8Array | string>,
): Promise<WasiGlkClient> {
  return WasiGlkClient.fromGlktra(config, glktra);
}
