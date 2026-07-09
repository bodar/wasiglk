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

## Reference: pixels vs characters (the metrics model)

The single rule that makes it all cohere: **the GlkOte/RemGlk wire is entirely
in pixels.** `init` `metrics.width`/`height` are the display area in *pixels*,
never characters. Characters never travel as sizes — what travels are
**px-per-character conversion factors** so the library can convert on demand.

Metrics the client sends (all px):
- `width`, `height` — display area.
- `gridcharwidth`, `gridcharheight` — px for ONE grid (monospace) character:
  column advance and line height.
- `buffercharwidth`, `buffercharheight` — same for the buffer font
  (approximate; variable-width, use the "0"/average glyph).
- `gridmarginx/y`, `buffermarginx/y`, `graphicsmarginx/y` — px padding inside a
  window.
- `inspacingx/y` — px gutter between adjacent windows.

How the library reconciles the two units:
- **Layout is always pixels.** The whole window tree is laid out in the px
  display area.
- **Text (grid/buffer) windows convert.** `glk_window_get_size` returns
  `cols = floor((win_px_width - gridmarginx) / gridcharwidth)`,
  `rows = floor((win_px_height - gridmarginy) / gridcharheight)`.
  800px ÷ 10px/char = 80 columns — the width the game wraps to.
- **Graphics windows stay pixels.** `get_size` returns px; images drawn at px.
- **Fixed splits go the other way.** `glk_window_open(..., winmethod_Fixed,
  size, ...)`: `size` is in the *key window's* natural unit — characters for a
  text key window, pixels for graphics. Inform's "status height 1" = 1 char row;
  the library converts to px for layout (`1 * gridcharheight + gridmarginy`).

So pixels are the shared substrate; each window type declares its unit against
it; char metrics + margins are the exchange rate. Images (px) and text (chars)
never interoperate directly — one currency, two denominations.

**Reflow/chat clients (talebrary)** have no real windowed px viewport, so they
*fabricate consistent metrics*: pick the rendered cell size (e.g. 8×16px) and the
column count to wrap at (e.g. 80), send `width = 80×8`, `gridcharwidth = 8`,
`gridcharheight = 16`, `height =` rows×16. The only requirement is internal
consistency so `width / gridcharwidth` = the intended columns.

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

## Phase 1 — Stop extracting the story ✅ DONE

Shipped in 84df34e (whole Blorb handed to the interpreter; images draw). The
plus demo story picker + graphics/buffer-image rendering landed in 3fbc0d1 /
36097aa. Detail below for reference.

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

## Phase 4 — Grid window metrics (character cells vs pixels) ✅ DONE

Shipped in 51b824b (server: size text windows in cells; `client_metrics` gains
grid/buffer char w/h + margins; `get_size`/`queueWindowUpdate`/`layoutWindow`
convert px↔cells; fixed text splits = chars×metric; grid buffer wrap tracks the
computed size) and 5b61ace (`measureMetrics(container)` shipped in
`@bodar/wasiglk`; demo sends measured metrics + renders multi-line status). All
7 regtests passed unchanged — **no re-baseline was needed** after all. Follow-up:
talebrary should adopt `measureMetrics` and send real pixel metrics. Original
analysis below for reference.

Discovered while wiring the demo's status-window rendering. Grid (and buffer)
window dimensions are handled in **pixels where they should be character
cells**, and the two internal representations disagree.

Evidence (advent status window, demo):
```
GRIDWIN id=2 gw=800 gh=1            <- get_size / update REPORT 800 columns
GRIDLINE line=0 len=80 "...At End Of Road   M"   <- content WRAPS at 80
GRIDLINE line=1 len=8  "oves: 16"                <- overflow onto row 1
```

Three coupled defects:
1. `glk_window_get_size` (`window.zig:242`) returns `layout_width / char_width`
   with `char_width = char_height = 1` (a TODO) → reports pixels as columns
   (800 instead of ~80).
2. `queueWindowUpdate` (`protocol.zig:466`) has the same `char = 1` TODO for the
   `gridwidth`/`gridheight` it sends over the protocol.
3. `layoutWindow` treats a **Fixed** split size as pixels
   (`window.zig:445`), but for text windows a fixed split is in **character
   rows/columns** (e.g. Inform's `split status height 1` → a 1-row status
   window becomes 1 *pixel* tall).
Meanwhile the grid buffer itself wraps at `WindowData.grid_width` (default 80),
so games are told 800 but their output wraps at 80 — the visible symptoms are
status lines splitting mid-word and games (ScottFree) drawing full-width rules
as walls of dashes.

Fix direction: carry real character metrics (`gridcharwidth`/`gridcharheight`,
`buffercharwidth`/`buffercharheight`, parsed from the init `metrics` — the
client already sends them) in `state.client_metrics`; compute grid/buffer
window sizes as `layout / <char metric>`; treat fixed text-window splits as
character units in `layoutWindow`; and make `get_size`, the protocol update, and
the grid buffer all agree.

**Caveat — needs regtest re-baselining.** The `.regtest` expected outputs were
recorded against the current pixel-based behaviour, so correcting grid metrics
will change status-window rendering in those baselines. Do this as a focused
change with the regression suite re-recorded and reviewed, not as a drive-by.

### Server work (the actual bug)
1. Extend `state.client_metrics` beyond width/height to carry
   `gridcharwidth/height`, `buffercharwidth/height`, and the margins; parse them
   from the init `metrics` in `protocol.zig` (the client already sends them).
2. `glk_window_get_size` (`window.zig`): grid → cols/rows via the char metrics +
   margins; buffer → same with buffer metrics; graphics → px (unchanged).
3. `queueWindowUpdate` (`protocol.zig`): send `gridwidth`/`gridheight` computed
   the same way (drop the `char = 1`).
4. `layoutWindow` (`window.zig`): a Fixed split on a text key window is in
   **characters** → convert to px with that window's char metric before laying
   out. Graphics key windows stay px.
5. Make `get_size`, the protocol update, and the grid buffer wrap width all
   agree. Add zig unit tests for the conversions.
6. Re-record the `.regtest` baselines; review the diff (status-window rendering
   changes) before committing.

### Demo showcase (deliberately simple)
Keep the example a *plain* reference, NOT the fancy scroll-behind treatment
(that lives on talebrary). Measure the container the game renders into, send
real px metrics, and render the common 1-grid + 1-buffer + input case with a
standard inner scroll (buffer scrolls itself; grid pinned top; input pinned
bottom). Goal: the simplest correct end-to-end example.

### Reusable client helper (ship in the library, not the example)
While building the demo, factor genuinely reusable pieces into
`@bodar/wasiglk` so talebrary and other UIs share one implementation:
- **`measureMetrics(container, opts)`** — measure a DOM element into a GlkOte
  `Metrics` object: container px via `getBoundingClientRect`, grid char px via
  canvas `measureText` on a monospace sample, line height, margins. This is
  exactly what every client (incl. talebrary) needs and must not be
  reimplemented per app.
- Consider a small helper to re-emit an `arrange` event with fresh metrics on
  resize (feeds Phase 5).
Keep rendering (DOM/canvas) app-specific; only the measurement/metrics maths is
shared.

## Phase 5 — Responsive multi-window layout (arrangement hint)

Goal: use desktop real estate for multi-window games (status/map panes left &
right of the main text) and collapse those panes into swipe-out panels on
mobile — instead of today's stacking.

### Relationship to Phase 4
Phase 4 makes window **sizes** correct (px↔char). It does NOT replace the
arrangement work: correct per-window rects (`left/top/width/height`) become a
*usable but weak* signal (a reflow client would have to reverse-engineer
adjacency from pixels). The explicit arrangement **tree** below is a *strong*
hint — it carries the split semantics (axis, order, which child is sized, how)
without pixel archaeology. So Phase 4 = sizes; Phase 5 = structure. Keep both.

### The mechanism
`arrange` events. Init metrics → the game builds its window tree. On
resize/orientation change the client sends an **`arrange` event with new
metrics** → the game re-lays-out and re-emits its tree. So:
- Desktop: send a wider display → multi-window games place panes L/R.
- Mobile: send narrower via `arrange` → game reflows; demote non-primary
  windows to collapsed swipe-out panels.
Caveats: games also open/close windows mid-play (tree is live, not just at
startup); the primary-vs-panel mapping must stay stable across arranges or the
UI jumps.

### The arrangement tree (design converged earlier — RECORD, not yet built)
The essence of a Glk window layout is an **n-ary space partition**: rows and
columns of content surfaces, each child optionally sized. Glk stores it as a
strict *binary* pair tree and overloads internal nodes as addressable "pair
windows"; for a rendering protocol that is noise. Emit the collapsed n-ary
essence instead.

Wire shape — one optional `layout` key on the update (leaves `windows[]` rects
untouched for absolute clients; reflow clients read the tree):
```ts
type Size = { fixed: number } | { prop: number };   // cells or %
interface Leaf      { window: number; size?: Size }  // window id from windows[]
interface Container { direction: 'row' | 'column'; children: Node[]; size?: Size }
type Node = Leaf | Container;
// update.layout?: Node   (arrangement IS the root node; no wrapper)
```
Notes on the design decisions:
- `window` is the leaf's id → a pointer into `windows[]` (which carries type,
  rects, content). The arrangement tree holds zero duplicated content.
- n-ary (not Glk's binary) + per-child `size` dissolves Glk's "key window"
  concept: the sized children are fixed/proportional, an unsized child takes the
  remainder — exactly flex-basis/flex-grow and i3's `percent`.
- No "pair" nodes, no pair ids: the client never learns Glk's internal
  conflation of layout-node and window.
- Additive + optional; stock GlkOte/asyncglk ignore an unknown `layout` key;
  reflow clients that lack it fall back to inferring from rects.

Two functions realise it:
- **Fold (server, Zig):** walk the `WindowData` binary pair tree → collapse
  same-direction chains into n-ary `Container`s → emit `layout`. All inputs
  already in `WindowData` (`parent`, `split_method`, `split_size`,
  `child1/2`, `split_key`). One recursive fold; pure structure, no metrics.
- **Resolve (shared client lib):** `layout` tree + real metrics → concrete
  regions each renderer (chat-flow / SVG / canvas) consumes. This is the "one
  computation, every medium" DRY win — belongs in `@bodar/wasiglk`, not per app.

Prior art: this is exactly the emglken/RemGlk-rs + asyncglk split (blorb/image
model), and i3/sway serialise their layout as a JSON split-container tree over
IPC — logical tree is the source of truth, pixels are derived. Worth pitching
the `layout` field upstream to asyncglk (reflow displays are a real gap there).

### On mobile mapping
Read the arrangement tree, pick the largest buffer as the main scroll view,
route the rest to collapsed panels (swipe to reveal). Report a mobile-width
display via `arrange`. The tree tells you relative placement so panels land on
the correct side.

## Phase 6 — Play-to-learn UI profiles

Cache a per-game UI profile keyed by story hash (already computed for saves):
discovered window arrangement, command/verb set, and layout shape, learned by
actually playing the game. Second load maps to mobile/desktop well without
discovery lag; benefits every user after one play. **Hint, not gospel** — the
live runtime tree always wins if a game does something unexpected (dynamic
windows). Larger product line; depends on Phase 5's arrangement tree existing.

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
