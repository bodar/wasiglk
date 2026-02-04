/**
 * Worker Message Types
 */

import type { RemGlkUpdate } from '../protocol';

/** Metrics passed to the worker */
export interface WorkerMetrics {
  width: number;
  height: number;
  charWidth?: number;
  charHeight?: number;
}

/** Messages from main thread to worker */
export type MainToWorkerMessage =
  | { type: 'init'; interpreter: ArrayBuffer; story: Uint8Array; args: string[]; metrics: WorkerMetrics; storyId: string }
  | { type: 'input'; value: string }
  | { type: 'stop' };

/** Messages from worker to main thread */
export type WorkerToMainMessage =
  | { type: 'update'; data: RemGlkUpdate }
  | { type: 'error'; message: string }
  | { type: 'exit'; code: number };
