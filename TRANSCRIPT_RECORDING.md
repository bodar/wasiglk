# Transcript Recording (`.glktra`)

**Status:** design, approved — not yet implemented.

Opt-in recording of a full session transcript (inputs + outputs + timer events)
as a stream of GlkOte `.glktra` stanzas, so a session can be replayed.
Configured at client construction and turned on per-instance.

**The library's job is to *produce the stream of stanzas*, nothing more.**
Where they go — OPFS, R2, a file, a download, memory — is entirely the
consumer's concern. The library exposes a hook; the embedder chooses the sink.
This is symmetric with the existing `updates()` iterator, and touches **no
storage code**.

---

## 1. Goal

- Record every input fed to the interpreter and every output update it emits,
  paired into `.glktra` stanzas.
- Expose the stanzas as a streaming iterator on the client, mirroring
  `updates()`. The consumer persists them however it likes.
- Configurable at `createClient(...)`; off by default.
- Timer information recorded so timed games replay faithfully.
- **No `StorageProvider` change.** Persistence is not the library's job.

## 2. File format — `.glktra` (GlkOte recording, Zarf spec)

Reference: <https://eblong.com/zarf/glk/glkote/docs.html> ("The .glktra File Format").

- A `.glktra` file is **concatenated JSON stanzas**, not a single JSON document.
- Every stanza — including the last — ends with a newline (`\n`).
- One stanza per input→output round trip, **raw-object form**:

  ```json
  { "format": "glkote",
    "input":  { <raw GlkOte input event: {type,gen,window,value,...}> },
    "output": { <raw GlkOte update object: {type:"update",gen,windows,content,input,timer,...}> },
    "sessionId": "<uuid string identifying the session>",
    "label": "<recording label: story URL or storyId>",
    "timestamp":    <Unix epoch ms when input received>,
    "outtimestamp": <Unix epoch ms when output generated> }
  ```

- `input`/`output` hold the **raw, unmodified** GlkOte objects (not the lossy
  `"simple"` string form) — required for faithful replay (styles, windows,
  line/char distinction, timer interval).
- No leading `metadata` stanza in v1 (optional per spec; easy to add later).

### Stanzas are yielded as objects, not strings

The iterator yields the stanza as a **structured object**, not a serialised
line. A consumer that wants the `.glktra` file does `JSON.stringify(stanza) +
"\n"` per stanza; a consumer that wants to inspect/transform gets the data
directly with no parse. The worker `postMessage`s the object (structured
clone), so there is no serialise-then-parse round trip.

```ts
interface TranscriptStanza {
  format: 'glkote';
  input: InputEvent | Record<string, unknown>;  // raw GlkOte input event
  output: RemGlkUpdate;                          // raw merged update
  sessionId: string;
  label: string;
  timestamp: number;     // Unix epoch ms, input received
  outtimestamp: number;  // Unix epoch ms, output generated
}
```

### Timer handling — free

A timer tick is an ordinary GlkOte input event `{"type":"timer","gen":N}`, and
the timer interval is carried in the output update's `timer` field. Recording
raw input + raw output therefore captures both *when a timer is armed*
(`output.timer`) and *each tick* (a `type:"timer"` input stanza) with no
special-case code. Replay reproduces timing from these stanzas.

## 3. Why the recorder lives in the worker (not the main thread)

The main thread already sees both sides — it sends inputs and receives updates —
so a naive recorder could run there. It **can't**, because of timers: timer
ticks are synthesised *inside the worker* (the `setInterval` in `worker.ts`
resolves the pending stdin read) and the main thread never sees an individual
tick — only that a timer was armed (`update.timer`). For faithful replay of
timer-driven games (especially tick-counting games, where the *count* of
`evtype_Timer` events matters), every `{type:"timer"}` input must be captured.
So the recorder taps the real stdin funnel in the worker, then streams stanzas
out to the main thread via `postMessage`.

## 4. Worker: `TranscriptRecorder`

New file `packages/client/src/worker/transcript.ts`:

```ts
class TranscriptRecorder {
  constructor(sessionId: string, label: string, emit: (stanza: TranscriptStanza) => void)
  recordInput(rawJson: string, timestamp: number): void   // JSON.parse + stash pending {input, timestamp}
  recordOutput(update: RemGlkUpdate, outtimestamp: number): void  // pair pending input → stanza → emit
}
```

- `recordInput` parses the raw stdin string back to an object and stashes it
  with its timestamp as the pending input.
- `recordOutput` builds a stanza from the pending input + this output and calls
  `emit(stanza)`.
- The **sink is injected** — the recorder does not know about `postMessage` or
  storage. In the worker the sink is
  `stanza => post({ type: 'transcript', stanza })`. In tests it's an array
  push. This keeps the recorder pure and trivially testable.

### Wiring in `runInterpreter` (`worker.ts`)

- After storage init, if `msg.recordTranscript`, construct the recorder with
  `msg.sessionId`, `msg.transcriptLabel`, and the `post`-based sink.
- Wrap the `InputProvider` closure (worker.ts:147-178): after the inner closure
  returns its string, call `recorder.recordInput(str, Date.now())` before
  returning it. This funnel captures **every** input kind — init, line, char,
  **timer**, arrange, mouse, hyperlink, redraw, refresh, specialresponse.
- In the stdout batch flush (worker.ts:203-208 microtask), after
  `mergeRemGlkUpdates(batch)`, call `recorder.recordOutput(merged, Date.now())`.

Strict input→output alternation (RemGlk reads one event per `glk_select`, emits
one update) makes pairing exact: init pairs with the first update; each
line/timer/special input pairs with the update it triggers.

## 5. Client: self-batching `transcript()` iterator

Add a second async iterator to `WasiGlkClient`, mirroring `updates()`:

```ts
async *transcript(): AsyncIterableIterator<TranscriptStanza[]>
```

Each pull returns **all stanzas accumulated since the last pull** (always ≥ 1).
When the consumer keeps up, arrays hold a single stanza; when it falls behind,
the next pull drains multiple — the stream self-batches according to consumer
speed. This is the **batch-on-backpressure** pattern (cf. Akka Streams `batch`,
Kafka `poll()`): aggregate while the consumer is busy, emit the aggregate when
it pulls.

Rationale:
- **No loss.** Stanzas buffer; nothing is dropped. Important for a transcript.
- **Throughput under burst.** One `await` per *pull*, not per stanza — so a
  fast-but-bursty consumer (replay fast-forward, timer-heavy game, server run)
  catches up in one drain instead of one microtask hop per stanza.
- **Sink-friendly coalescing.** A slow sink (e.g. writing to R2) naturally
  batches many stanzas into one write instead of one round trip per stanza.
- **Cheap.** The client already buffers `pendingUpdates` as an array; the
  transcript queue is the same shape — `next()` returns and clears the array.

Notes:
- Batch boundaries are **timing artifacts and carry no meaning** — consumers
  must not key off array grouping. Documented on the method.
- The buffer is **unbounded** (no high-water mark). A whole-session transcript
  is bounded (KB–MB) and fits in memory, and the producer (interpreter turns)
  can't be back-pressured cleanly, so unbounded-but-lossless is the right trade.
  A consumer that never drains will grow memory — same as any buffered stream.
- `updates()` is left **single-item**; this batching applies only to
  `transcript()`. No retrofit, no scope creep.

Consumer shape:

```ts
for await (const batch of client.transcript()) {
  for (const stanza of batch) {
    // e.g. append JSON.stringify(stanza) + "\n" to a .glktra file / R2 object
  }
}
```

## 6. Config plumbing (additive; mirrors `filesystem`)

1. `ClientConfig` (`client.ts`):
   ```ts
   /** Record a `.glktra` transcript stream of the session. Default: false. */
   recordTranscript?: boolean;
   /** Label stored in each stanza. Defaults to storyUrl ?? storyId. */
   transcriptLabel?: string;
   ```
2. `WasiGlkClient.create()`: mint `sessionId = crypto.randomUUID()`; compute
   default label `= storyUrl ?? storyId`. Pass both plus `recordTranscript`
   into the constructor as private fields.
3. `updates()` `initMessage`: add `recordTranscript`, `sessionId`,
   `transcriptLabel`.
4. `MainToWorkerMessage` `init` variant (`worker/messages.ts`): add
   `recordTranscript?: boolean; sessionId?: string; transcriptLabel?: string`.
5. `WorkerToMainMessage` (`worker/messages.ts`): add
   `{ type: 'transcript'; stanza: TranscriptStanza }`. `handleWorkerMessage`
   routes it into the transcript queue and resolves any pending `transcript()`
   pull (same pattern as `update`).

## 7. Tests (`bun:test`, `packages/client/test/`)

- **Stanza formatter / recorder pairing** (pure): construct a
  `TranscriptRecorder` with an array-push sink; `recordInput` then
  `recordOutput` → assert exactly one stanza with `format:"glkote"`, raw
  (object) `input`/`output`, correct `sessionId`/`label`/timestamps.
- **Timer capture**: feed a `{type:"timer",gen}` input → assert it is recorded
  as an input in the next stanza.
- **Self-batching iterator**: push several stanzas before pulling → assert one
  pull returns them all as an array; push one, pull, push one, pull → assert
  each pull returns a single-element array.

## 8. Touched files

- `packages/client/src/worker/transcript.ts` — **new** `TranscriptRecorder` + `TranscriptStanza`.
- `packages/client/src/worker/worker.ts` — construct + wire recorder (input funnel + stdout flush).
- `packages/client/src/worker/messages.ts` — init-message fields + `transcript` worker→main message.
- `packages/client/src/client.ts` — `ClientConfig` fields, `sessionId`, init plumbing, `transcript()` iterator + queue.
- `packages/client/test/transcript.test.ts` — **new** tests.

**Unchanged:** all `worker/storage/*` — no `StorageProvider` method added.
