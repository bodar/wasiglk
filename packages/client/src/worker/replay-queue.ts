/**
 * Replay Queue
 *
 * Sources recorded `.glktra` input events for the worker's stdin funnel, so a
 * session can be re-driven through the interpreter verbatim.
 *
 * Symmetric with {@link TranscriptRecorder}: the recorder taps the *output* of
 * the `provideInput` funnel; this queue supplies its *input*. Because every
 * input kind — including worker-synthesized `timer` ticks and file-dialog
 * `specialresponse` answers — flows through that one funnel, replaying from it
 * reproduces them exactly (identical stdin -> identical stdout for a
 * deterministic interpreter). A main-thread, `sendInput`-driven replay cannot:
 * it can't inject individual timer ticks or a recorded dialog answer.
 *
 * Pure and worker-free (no `postMessage`, WASM or JSPI) so it is unit-testable.
 */

import type { TranscriptStanza } from './transcript';

/**
 * A recorded input event to replay — the `input` field of a recorded
 * {@link TranscriptStanza}. Wider than `InputEvent` (it also admits the
 * runtime-only `specialresponse`/`redraw`/`refresh` events that flow through
 * the stdin funnel), so it is defined once, there, and reused here.
 */
export type ReplayEvent = TranscriptStanza['input'];

/**
 * A drainable queue of recorded input events, plus the deferred-timer
 * bookkeeping needed to hand a timed game cleanly back to live input.
 */
export class ReplayQueue {
  private readonly queue: ReplayEvent[];
  /** Latest timer interval an output requested while still replaying; applied on drain. */
  private deferredTimer: number | null | undefined = undefined;

  constructor(events?: readonly ReplayEvent[]) {
    this.queue = events ? [...events] : [];
  }

  /** True while recorded events remain to be fed. */
  get active(): boolean {
    return this.queue.length > 0;
  }

  /** Dequeue the next recorded event, or null if the queue is drained. */
  next(): ReplayEvent | null {
    return this.queue.shift() ?? null;
  }

  /**
   * Stash a timer arm/cancel request seen in an output produced during replay.
   * Recorded `timer` events supply the ticks meanwhile, so the live
   * `setInterval` must not run and race the drain — this holds the game's
   * intended interval until {@link takeDeferredTimer} applies it on drain.
   */
  deferTimer(interval: number | null): void {
    this.deferredTimer = interval;
  }

  /**
   * If the queue has just drained and a timer state was deferred, return it
   * once (so the caller can arm the live timer) and clear it. Returns null
   * while still replaying, or when no timer was deferred.
   */
  takeDeferredTimer(): { interval: number | null } | null {
    if (this.queue.length === 0 && this.deferredTimer !== undefined) {
      const interval = this.deferredTimer;
      this.deferredTimer = undefined;
      return { interval };
    }
    return null;
  }
}
