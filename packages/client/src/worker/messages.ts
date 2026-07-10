/**
 * Worker Message Types
 */

import type { Metrics, RemGlkUpdate } from '../protocol';
import type { FilesystemMode } from './storage';
import type { TranscriptStanza } from './transcript';
import type { ReplayEvent } from './replay-queue';

export type { FilesystemMode };

/** Messages from main thread to worker */
export type MainToWorkerMessage =
  | { type: 'init'; interpreter: ArrayBuffer; story: Uint8Array; storyName: string; args: string[]; metrics: Metrics; support?: string[]; serverResolvesImages?: boolean; storyId: string; filesystem: FilesystemMode; recordTranscript?: boolean; sessionId?: string; transcriptLabel?: string; replayInputs?: ReplayEvent[] }
  | { type: 'input'; value: string }
  | { type: 'arrange'; metrics: Metrics }
  | { type: 'mouse'; windowId: number; x: number; y: number }
  | { type: 'hyperlink'; windowId: number; linkValue: number }
  | { type: 'redraw'; windowId?: number }
  | { type: 'refresh' }
  | { type: 'stop' }
  // File dialog responses
  | { type: 'fileDialogResult'; filename: string | null; handle?: FileSystemFileHandle };

/** Supported file dialog modes */
export type FileDialogMode = 'read' | 'write' | 'readwrite' | 'writeappend';

/** Messages from worker to main thread */
export type WorkerToMainMessage =
  | { type: 'update'; data: RemGlkUpdate }
  | { type: 'error'; message: string }
  | { type: 'exit'; code: number }
  // Transcript recording stanza (when recordTranscript is enabled)
  | { type: 'transcript'; stanza: TranscriptStanza }
  // File dialog request
  | { type: 'fileDialogRequest'; filemode: FileDialogMode; filetype: 'save' | 'data' | 'transcript' | 'command' };
