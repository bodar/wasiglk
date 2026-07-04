/**
 * Transcript Recorder
 *
 * Records a session as a stream of GlkOte `.glktra` stanzas — one per
 * input->output round trip — pairing each input event fed to the interpreter
 * with the output update it produced.
 *
 * The recorder only *produces* stanzas; it does not persist them. The sink is
 * injected (in the worker it posts to the main thread; in tests it pushes to an
 * array), keeping this class pure and backing-agnostic. Consumers persist the
 * stanzas however they like (OPFS, R2, a file, a download).
 *
 * Format reference: https://eblong.com/zarf/glk/glkote/docs.html
 * ("The .glktra File Format")
 */

import type { InputEvent, RemGlkUpdate } from '../protocol';

/**
 * A single `.glktra` recording stanza (raw-object form).
 *
 * Concatenating `JSON.stringify(stanza) + "\n"` for each stanza yields a valid
 * `.glktra` file. `input`/`output` hold the raw, unmodified GlkOte objects so
 * the session can be replayed faithfully (styles, windows, timer interval).
 */
export interface TranscriptStanza {
  /** Always the literal "glkote". */
  format: 'glkote';
  /** The raw GlkOte input event fed to the interpreter. */
  input: InputEvent | Record<string, unknown>;
  /** The raw GlkOte output update the interpreter produced in response. */
  output: RemGlkUpdate;
  /** UUID string identifying this play session; shared by all its stanzas. */
  sessionId: string;
  /** Recording label (e.g. story URL or storyId). */
  label: string;
  /** Unix epoch ms when the input was received. */
  timestamp: number;
  /** Unix epoch ms when the output was generated. */
  outtimestamp: number;
}

/** Sink for produced stanzas (postMessage in the worker, array push in tests). */
export type StanzaSink = (stanza: TranscriptStanza) => void;

/**
 * Pairs interpreter inputs with their resulting outputs into `.glktra` stanzas.
 *
 * RemGlk reads exactly one event per `glk_select` and emits one update in
 * response, so inputs and outputs strictly alternate: the pending input
 * recorded by {@link recordInput} is paired with the next output passed to
 * {@link recordOutput}. This captures every input kind — including worker-
 * injected `timer` ticks — since they all flow through the same stdin funnel.
 */
export class TranscriptRecorder {
  private pendingInput: { input: TranscriptStanza['input']; timestamp: number } | null = null;

  constructor(
    private readonly sessionId: string,
    private readonly label: string,
    private readonly emit: StanzaSink,
  ) {}

  /**
   * Record an input event about to be fed to the interpreter's stdin.
   * @param rawJson - The raw JSON string being written to stdin.
   * @param timestamp - Unix epoch ms when the input was produced.
   */
  recordInput(rawJson: string, timestamp: number): void {
    let input: TranscriptStanza['input'];
    try {
      input = JSON.parse(rawJson) as TranscriptStanza['input'];
    } catch {
      // Non-JSON stdin should never happen (all inputs are JSON events), but
      // don't let a malformed line break recording — skip pairing this turn.
      return;
    }
    this.pendingInput = { input, timestamp };
  }

  /**
   * Record an output update the interpreter produced, pairing it with the
   * pending input and emitting a completed stanza.
   * @param output - The merged RemGlk update for this turn.
   * @param outtimestamp - Unix epoch ms when the output was generated.
   */
  recordOutput(output: RemGlkUpdate, outtimestamp: number): void {
    const pending = this.pendingInput;
    if (!pending) return; // output with no preceding input — nothing to pair
    this.pendingInput = null;

    this.emit({
      format: 'glkote',
      input: pending.input,
      output,
      sessionId: this.sessionId,
      label: this.label,
      timestamp: pending.timestamp,
      outtimestamp,
    });
  }
}
