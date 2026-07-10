---
title: "Graphics & Blorb Handling Plan"
date: 2026-07-09
author: Daniel Bodart
type: plan
status: in-progress
tags: [plan, graphics, blorb, images, metrics, layout, interpreters]
---

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

## Phase 3 — Companion / multi-file resource delivery ✅ DONE

Delivered as **single-file container delivery**: a story is always one blob —
either the bare story, or a container (a zip) holding the story plus its
companion resource files. The container is exploded into the in-memory WASI
`/sys` directory *inside the worker sandbox*, so every interpreter sees a normal
game folder and its own companion-file logic resolves against it. Nothing about
the delivery interface is multi-file; the container carries the multiplicity.

### The unifying principle (what made it simple)

**The client faithfully mirrors the original game directory into `/sys` under
the original filenames. Zero name derivation, zero bytecode parsing.** Every
interpreter already computes its own companion path — by extension-swap
(alan3 `.acd`→`.a3r`, jacl `<stem>.blorb`), by numbered-slot loop (TADS
`.3r0`–`.3r9` / `.RS0`–`.RS9`), by a name baked into the compiled story (Hugo's
`resourcefile "..."`), or by substring surgery on the original filename
(plus `HULK1`→`HULK2`, taylor part-letter flip, magnetic/level9 `.gfx`/`.pic`).
All of these operate on the *real* names they were written for. If those files
sit in `/sys` under their real names, each terp's existing logic just works —
so the client neither derives companion names nor parses story bytecode. The zip
*is* the manifest.

This also dissolves the naming/detection open questions from the original spike:
the primary story name is preserved verbatim (interpreters that key off it get
the real name); companions are preserved verbatim; the primary entry is found by
running the existing format detector over the container's entries.

### Consumers (all covered by the one mechanism)
- **alan3** (`.a3r`), **jacl** (`<stem>.blorb`) — Glk fileref → `giblorb_set_resource_map`.
- **TADS** — `load_ext_resfiles` numbered-slot loop, own resource format.
- **Hugo** — author-named `resourcefile` opened relative to the story dir.
- **Self-rendering, raw `fopen`** — plus / taylor / magnetic / level9 read
  sibling disk/graphics files directly (bypassing Glk); they resolve against the
  WASI `/sys` dir like any real folder, and their not-found paths degrade
  gracefully. Preserving the *original* filename is what makes their name
  derivation work — hence names are never canonicalised when a real one exists.

### What shipped
- **`packages/client/src/container.ts`** — `isZip`, `unzipEntries` (flatten to
  basenames, drop dir/traversal entries, dedupe colliding basenames first-wins so
  the client's primary pick and the worker's `/sys` build from one identical set),
  `pickPrimary` (detect the story entry among companions; `ClientConfig.format`
  override; largest-file fallback). Uses
  **fflate** (MIT, ~3KB gz) — the one small dependency, chosen over a Zig
  `unzip.wasm` (measured ~32KB / ~14.5KB gz, zero-dep) purely for ~85 fewer lines
  and no build artifact.
- **`client.ts` `create()`** — sniffs the blob; if a zip, peeks inside to pick
  interpreter + primary filename; else preserves the URL basename (or fabricates
  `story.<ext>` for nameless raw bytes via `extensionForFormat`). Blorb parsing
  and the save hash now run on the *primary* bytes (so re-zipping keeps saves).
- **Init message** — stays single-blob (`story: Uint8Array` unchanged), gains
  `storyName`; `args[1]` is `/sys/<storyName>` (no more hardcoded `story.ulx`).
- **`worker.ts`** — builds `/sys` by exploding a zip via `unzipEntries`, else a
  single named file; all entries read-only. (`READ_ONLY_FILES` was a stale
  `/var`-scoped guard referencing `story.ulx`; now correctly empty.)
- **Delivery stays single-file end-to-end** — the worker re-unzips its own copy;
  the client unzips only transiently for detection. The redundant unzip is the
  (sub-ms) price of never carrying loose files across an interface.

### Verified
- `packages/client/test/container.test.ts` — zip sniff, basename flattening,
  primary selection (alan3 `.acd`+`.a3r`, content detection, override, fallback,
  empty), basename-collision dedupe. 64 client unit tests green.
- `packages/example/tests/container.spec.js` — full client → worker → glulxe run
  over a zipped `advent.ulx` (`advent-zipped.zip` fixture + demo picker entry):
  "Welcome to Adventure" renders and input advances moves. All 13 e2e green.

### AGT (agt2agx) — unchanged, revisit later
agility reads the raw multi-file AGT set directly (`agil.c:842` `open_descr`), so
this delivery *could* replace the `agt2agx` pre-pack. Kept as-is: dropping it
needs its own case-sensitivity verification of agility's `.DA1`↔`.da1` retries
under the WASI dir. Additive, not blocked.

### Follow-ups
- Ship real companion-game fixtures (an alan3 `.acd`+`.a3r`, a Hugo `.hlb` game)
  and add e2e coverage that images/resources actually load server-side.
- Client-side image rendering for companion-blorb resources (alan3 `.a3r`): the
  client retains the whole container and can unzip its own copy to build a
  `BlorbParser` for the companion when resolving image numbers → pixels.

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

### Background research & design rationale (why this shape)

**How Glk lets you signal limited window support (cheapglk study).** There is
**no gestalt** for window count or window types. The *only* in-band signal is
`glk_window_open` returning **NULL** — and the Glk spec *requires* programs to
cope with NULL (degrade to fewer windows). cheapglk (`../cheapglk/cgwindow.c`)
leans entirely on this: it accepts exactly one `wintype_TextBuffer` and returns
NULL for any second window or any non-buffer type, no warning. So "tell the
interpreter we only support X" = *refuse the opens we can't honour*. wasiglk
does NOT need to do this (it builds the full tree); the arrangement tree +
reflow mapping is the better path than refusing windows, which silently drops
content (quote boxes, maps, graphics panes).

**Why a hint, not absolute pixels.** talebrary renders like a chat log: grid
pinned top, input pinned bottom, everything scrolls for history, and it
*enriches* game output (injects images, suggestion chips). Absolute-positioned
windows are impossible there. So the tree is a **flow hint**: map a split to
nested flex (`Left/Right`→`row`, `Above/Below`→`column`), split size →
`flex-basis`/grow, and let it reflow — never `position: absolute`.

**Why NOT precompute CSS/geometry server-side.** Tempting for DRY, but it
repeats RemGlk's original "layout computed where the rendering knowledge isn't"
smell: the server can't see the medium (CSS vs SVG vs canvas), the enrichment,
or the viewport; emitting CSS actively excludes non-CSS renderers. Killer
detail: Glk fixed sizes are in **character cells**, and cell→pixel needs the
client's font metrics (which is *why* metrics flow client→server in the first
place) — so the server literally can't compute correct pixels. Keep the
protocol **semantic** (the tree); resolve geometry at the edge (the shared
`resolve()` in the client lib). One computation, every medium.

**Naming decisions (settled):**
- `layout` — chosen over `arrangement` (Glk overloads that word for a single
  pair's split params, and it's long) and over `tree` (generic, says nothing of
  purpose). `layout` states intent and matches every render target's vocab.
- `window` for a leaf's id — not `win`/`window_id`; matches the existing input
  events which already use `window: number` for a window reference.
- `direction: 'row' | 'column'` — spelled out, not `dir`/`col`; matches CSS.
- `Leaf` / `Container` node types; `size?` folded onto the node (no `Child`
  wrapper); `update.layout` *is* the root node (no `{ root }` wrapper).

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
art). Phase 2 independent (build/shim work per interpreter). Phase 3 (done)
delivers the single-file container mechanism that also serves Hugo `.hlb`
resources from Phase 2 — so a Hugo game shipping a companion resource file now
just needs to arrive zipped.
