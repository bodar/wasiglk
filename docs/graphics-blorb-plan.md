# Graphics & Blorb Handling Plan

Make image/graphics support work correctly and uniformly across every wasiglk
interpreter, by aligning story-file delivery with the reference design
(emglken + asyncglk + remglk-rs).

## Background

wasiglk's JSON protocol and architecture are copied from **emglken** (the
asyncglk JS display + remglk-rs wasm Glk library). That stack handles Blorb
resources with a deliberately uniform contract:

> Hand the interpreter the **whole, unmodified story file**. The interpreter
> self-detects a Blorb wrapper and calls the standard `giblorb_set_resource_map`
> on its own story stream. The library parses the whole file into a resource
> map, answers `glk_image_get_info` from it, and sends image **numbers** (not
> pixels) over the protocol. The display holds its own copy of the Blorb and
> resolves numbers → pixels for rendering.

emglken **never** strips the executable chunk out of a Blorb before handing it
to the interpreter. (asyncglk *has* a `get_exec_data('GLUL'|'ZCOD')` unwrap, but
it is used only by the Parchment web frontend, never by the runner.)

**wasiglk diverged on exactly one point.** In `packages/client/src/client.ts`
(`create()`), when the story is a Blorb containing an `Exec` chunk (GLUL/ZCOD),
the client unwraps it and sends only the bare `.ulx`/`.z5` to the wasm worker:

```ts
// client.ts:163-176
if (formatInfo.isBlorb || BlorbParser.isBlorb(storyData)) {
  blorb = new BlorbParser(storyData);
  const exec = blorb.getExecutable();
  if (exec) {
    executableData = exec.data;            // <-- the divergence: strip to exec chunk
    if (exec.type === 'GLUL') { ...glulxe }
    else if (exec.type === 'ZCOD') { ...fizmo }
  }
}
```

Consequence: glulxe takes the non-Blorb `'Glul'` startup branch
(`glulxe/unixstrt.c:246`), so it **never calls `giblorb_set_resource_map`**. The
server-side `blorb_map` stays null, and `glk_image_draw` / `glk_image_get_info`
return 0 without emitting anything (`server/src/graphics.zig:16-19,39`). Images
in the retained client-side Blorb never reach the interpreter/server draw path.

### Interpreter graphics landscape (audit)

| Class | Interpreters | Graphics source |
|---|---|---|
| Blorb via giblorb, **main story stream** | glulxe, git, fizmo | self-detect `FORM/IFRS` → `giblorb_set_resource_map` → server map |
| Blorb via giblorb, **companion file** | alan3 (`.a3r`), jacl (`.blb`) | separate resource blorb the terp opens itself |
| Own decoder → `glk_window_fill_rect` | scott, taylor, plus, level9, magnetic | paint rectangles; never touch giblorb |
| Graphics compiled out (source exists, disabled) | hugo, scare | see Phase 2 |
| No graphics at all | tads2, tads3, agility, advsys, alan2 | — |

The pipeline is otherwise uniform: the worker writes a single read-only
`/sys/story.ulx` and passes one argv; every interpreter takes `argv[1]` via the
standard `glkunix_startup_code`. `gi_blorb.c` is linked into every interpreter.
Self-rendering terps (scott/level9/magnetic/taylor/plus) are unaffected by the
strip and already work.

---

## Phase 0 — Gestalt gated on display support ✅ DONE (this session)

Prerequisite already applied so graphics can be advertised at all.

**Problem:** `gestalt_Graphics` was gated on the server having a `blorb_map`
(always null in the client-strips-blorb architecture), so every graphics game
hit *"This interpreter does not support graphics!"* and bailed. `Timer` and
`Hyperlinks` were hardcoded to `1` regardless of what the display advertised.

**Fix** (`server/src/gestalt.zig`): gate `Graphics`/`DrawImage`/
`GraphicsTransparency`, `Timer`, and `Hyperlinks`/`HyperlinkInput` on
`state.client_support.*` — the capability flags from the init `support` array.
This matches remglk-rs, which gates graphics on the `support` list, not Blorb
presence. Unit tests updated (`gestalt.zig` tests now set `client_support`
before asserting). All 7 regtests + zig tests green.

Note: after Phase 1 the server *also* has a `blorb_map`, so both signals become
available — but gating on `client_support` is the semantically correct one
(graphics is a display capability, not a story property) and matches prior art.

---

## Phase 1 — Stop extracting the story

Align with emglken: hand every interpreter the whole, unmodified container.

**Change** (`packages/client/src/client.ts`): keep parsing the Blorb for
(a) interpreter selection via `exec.type` and (b) client-side pixel rendering,
but **do not overwrite `executableData` with the exec chunk** — send the
original whole `storyData` to the worker.

Minimal diff: drop the `executableData = exec.data` assignment (client.ts:167);
keep the `exec.type` → interpreter branches. `executableData` then stays
identical to `storyData`, so `storyData: executableData` at client.ts:202 sends
the whole file. Consider renaming the variable away from "executable" since it
is no longer the stripped executable.

**Why it's safe for all formats:**
- glulxe/git self-detect `FORM/IFRS` (`unixstrt.c:246-256`, `git.c:114-123`) →
  now take the Blorb branch → `giblorb_set_resource_map` → server map populates.
- fizmo self-detects `.zblorb` (`libfizmo/src/interpreter/fizmo.c:144-187`
  `is_form_type(...,"IFRS")`) → z-code v6 graphics light up too (bonus).
- All non-Blorb formats (hugo/tads/scott/…) never entered the strip block →
  completely unaffected.

**Unblocked by this phase:** with `blorb_map` populated server-side,
`glk_image_get_info` and `glk_image_draw` work; the server emits image draw ops
carrying the image **number** (`graphics.zig` → `protocol.sendGraphicsImageUpdate`
/ `sendImageUpdate`); the client resolves number → pixels from its retained
`BlorbParser` (`client.ts` `getImageUrl`) — exactly emglken's split.

**Non-issues (verified):**
- Save isolation already hashes the whole Blorb (`client.ts:194` hashes
  `storyData`), so no save-key migration.
- Format detection preserved (still reads `exec.type`).
- Memory: wasm's wasi fs now holds the whole Blorb once; giblorb seeks image
  bytes on demand rather than slurping. Same residency profile as emglken
  (interpreter copy + display copy). Bounded; matters only for very large
  illustrated/audio games.

**Verification:**
- `graphwintest.gblorb` (already in `packages/server/tests/`): confirm a
  graphics window opens AND `image 0` / `image 1 300,20` now emit
  `special:"image"` draw ops (previously emitted nothing).
- `imagetest.gblorb`: images inside a buffer window (inline + margin alignment).
- A z-code v6 Blorb: confirm the fizmo path emits image ops uniformly.
- Regression: `advent.ulx` (raw, non-Blorb) still runs unchanged.

---

## Phase 2 — Compile in Hugo and Scare graphics

Both interpreters have upstream graphics code that is currently disabled in the
wasiglk build ("compiled out"). Turn it on.

### Hugo

- Currently `heglk/heglk.c:896-911` stubs graphics: `hugo_hasgraphics()` returns
  `false`, `hugo_displaypicture()` opens+closes the file and draws nothing.
- The real media file `hemedia.c` (contains the actual `glk_image_*` calls) is
  **not** in the hugo source list (`server/build.zig:304-318`).
- **Steps:** add `hemedia.c` to the build; enable real `hugo_hasgraphics()` /
  `hugo_displaypicture()`; confirm `GLK_MODULE_IMAGE` support is sufficient
  (it is defined in `glk.h`).
- **Open sub-dependency:** Hugo resources may live in a separate resource file
  (`.hlb`) rather than embedded — if so, this hits the same companion-file gap
  as Phase 3 (worker writes only `story.ulx`). Verify whether target test games
  embed resources or use a companion `.hlb`.

### Scare

- Graphics/sound in `garglk/terps/scare/os_glk.c:1789+` are wrapped in
  `#ifdef GLK_MODULE_GARGLK_FILE_RESOURCES`, which is **not** defined; the
  `#else` stubs (`os_show_graphic` no-op) compile instead.
- Scare extracts TAF resources to files and calls `garglk_add_resource_from_file`
  — a garglk extension the server does not export (`garglk.zig` stubs only
  `garglk_set_*`).
- **Steps:** define `GLK_MODULE_GARGLK_FILE_RESOURCES`; implement + export
  `garglk_add_resource_from_file` server-side; ensure the temp-file extraction
  path works under the wasi filesystem. More involved than Hugo (needs the
  garglk file-resource API implemented, not just a source-list add).

**Verification:** a Hugo game with graphics (e.g. a Hugo illustrated game) and a
Scare `.taf` with images; confirm image draw ops emit.

> Note: each interpreter is an independent effort; Hugo is lighter (source-list +
> flag), Scare needs a new server-side garglk resource API.

---

## Phase 3 — Handle alan3 / jacl companion resource Blorbs (SPIKE)

Scoped investigation, not a committed design yet.

**The gap:** alan3 and jacl are Blorb-aware but load a **separate companion
resource file**, not the story stream:
- alan3 (`garglk/terps/alan3/glkstart.c:77-113`) derives a `.a3r` filename from
  the story path and calls `giblorb_set_resource_map` on it.
- jacl (`garglk/terps/jacl/jacl.c:237-258`) opens a companion `.blb` and calls
  `giblorb_set_resource_map`.

The worker currently writes only one file (`/sys/story.ulx`,
`worker/worker.ts:275-277`), so the companion file the interpreter tries to open
does not exist in the wasi filesystem → resources never load. Phase 1 does not
fix this (different mechanism).

**Requirement:** multi-file story delivery — the client must supply companion
resource file(s), and the worker must write them into `/sys` under the names the
interpreter expects.

**Open questions to resolve in the spike:**
1. **Naming:** interpreters derive the companion name from the story filename
   (e.g. `story.a3r` next to `story.a3c`). The worker writes `story.ulx`
   regardless of format — the companion name must match what the terp computes.
   Do we write story files under format-correct names/extensions?
2. **Source:** where does the client obtain the companion file? Separate
   download alongside the story? Bundled? Part of a zip/container?
3. **Delivery shape:** extend the worker `init` message from a single `story`
   byte-array to a set of named files? A small virtual-FS manifest?
4. **Detection:** how does format detection know a companion is expected and
   fetch it?
5. Whether any of the self-rendering terps or Hugo `.hlb` (Phase 2) share the
   same multi-file need — design the mechanism once for all of them.

**Deliverable of the spike:** a short design note recommending the multi-file
delivery mechanism, then a follow-up implementation phase.

---

## Cross-cutting notes

- The **image draw protocol** (server emits image number + geometry; client
  resolves pixels from its own Blorb copy) already exists and is correct — it
  only needs `blorb_map` populated server-side (Phase 1) to start firing.
- Session experiment files to clean up or fold into tests before/at Phase 1:
  `example/serve.ts` (added routes + `.gblorb` mime), `example/src/main.ts`
  (`storyUrl` → graphwintest + WIN logging), `example/tests/_baseline.spec.js`.
  Downloaded `graphwintest.gblorb` / `imagetest.gblorb` in
  `packages/server/tests/` are useful permanent fixtures.

## Sequencing

Phase 1 first (unblocks glulx + z-code graphics, smallest diff, matches prior
art). Phase 2 independent (build/shim work per interpreter). Phase 3 is a spike
whose mechanism may also serve Hugo `.hlb` resources from Phase 2 — worth
designing the multi-file delivery once.
