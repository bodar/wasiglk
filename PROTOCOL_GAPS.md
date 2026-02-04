# Protocol Gap Analysis: wasiglk vs RemGLK/GlkOte Specification

This document tracks discrepancies between wasiglk's implementation and the official RemGLK/GlkOte JSON protocol specification. Use this as a checklist when fixing issues.

**Reference Documentation:**
- GlkOte spec: https://eblong.com/zarf/glk/glkote/docs.html
- RemGLK docs: https://eblong.com/zarf/glk/remglk/docs.html

**When fixing issues:** If you discover additional discrepancies not listed here, add them to this file before fixing.

**Testing:** When fixing protocol issues, add or update tests to verify the correct format is being sent. Tests should verify the exact JSON structure matches the GlkOte spec.

**Code style:** When processing arrays in TypeScript, prefer using `array.map()` and `array.flatMap()` over manual for-loops with result.push(). This makes the code more functional and readable.

**Backwards compatibility:** There is no need for backwards compatibility with legacy formats. We are implementing the GlkOte spec correctly - just make the changes to match the spec without supporting old formats.

**Build process:** After modifying server-side Zig code, run `./run build` to rebuild WASM files. Client-side TypeScript changes are hot-reloaded by the dev server, but if changes don't take effect, restart the server.

**No extra messages:** Only send messages defined in the RemGLK/GlkOte spec. Do not add custom messages for debugging or UI purposes - keep the protocol clean and spec-compliant.

---

## Protocol Deviations (Format/Structure Issues)

These are cases where wasiglk sends data in a different format than the spec requires.

### [x] 1. Init Message Flow (FIXED)

**Location:** `packages/client/src/worker/interpreter.worker.ts:56-67`, `packages/server/src/protocol.zig:524-574`

**Fixed:**
- Display now sends: `{type: "init", gen: 0, support: ["timer", "graphics", "graphicswin", "hyperlinks"], metrics: {...}}`
- Interpreter responds with first `update` message (not `init`) when the game creates windows

**Implementation:**
1. Client sends `support` array declaring its capabilities
2. Server parses support array and stores in `state.client_support` struct
3. Server no longer sends `type: "init"` response - the game's first `update` with windows serves as the response
4. Example app detects initialization from first window update instead of init message

---

### [x] 2. Graphics Window Content Uses Wrong Array Name (FIXED)

**Location:** `packages/server/src/protocol.zig:229-302`

**Current:** `{"id": 1, "draw": [{"special": "fill", ...}]}`

**Fixed:** Now uses `draw` array with `special` as a string value per GlkOte spec.

---

### [x] 3. Color Format is Integer Instead of CSS String (FIXED)

**Location:** `packages/server/src/protocol.zig:259-302`

**Current:** `{"color": "#BC614E"}`

**Fixed:** Colors are now formatted as CSS hex strings.

---

### [x] 4. Image Alignment Sent as Integer (FIXED)

**Location:** `packages/server/src/protocol.zig:211-226`

**Fixed:** Server now sends alignment as string (`"inlineup"`, etc.) per GlkOte spec.

---

### [x] 5. Buffer Window Content Missing Paragraph Structure (FIXED)

**Location:** `packages/server/src/protocol.zig:188-196`

**Fixed:** Buffer window content now uses paragraph structure:
```json
{"id": 1, "text": [{"append": true, "content": ["Hello world"]}]}
```

---

### [x] 6. Grid Window Content Uses Correct Format (FIXED)

**Location:** `packages/server/src/protocol.zig`, `packages/server/src/state.zig`, `packages/server/src/window.zig`, `packages/server/src/stream.zig`

**Fixed:** Grid windows now use `lines` array with explicit line numbers per GlkOte spec:
```json
{"id": 1, "lines": [{"line": 0, "content": ["text"]}]}
```

**Implementation:**
1. Added cursor position tracking to WindowData struct (cursor_x, cursor_y)
2. Added grid buffer and dirty tracking to WindowData
3. Implemented `glk_window_move_cursor` to update cursor position
4. Created `flushGridWindow` function to send grid content in lines format
5. Modified `putCharToStream` to write to grid buffer for grid windows
6. Grid buffer allocated when grid window is opened, freed on close
7. `glk_window_clear` clears grid buffer and resets cursor

---

### [x] 7. Graphics Window Missing Dedicated Dimension Fields (FIXED)

**Location:** `packages/server/src/protocol.zig:168-186`

**Fixed:** Graphics windows now include both `graphwidth`/`graphheight` (canvas size) and `width`/`height` (window size).

---

### [ ] 8. Window Positions Always Zero

**Location:** `packages/server/src/protocol.zig:176-185`

**Current:** `left` and `top` always set to 0.

**Spec:** Should reflect actual window layout positions for proper rendering.

---

### [ ] 9. Metrics Object Incomplete

**Location:** `packages/server/src/protocol.zig:44-49`, `packages/client/src/protocol.ts:31-36`

**Current fields:** `width`, `height`, `charwidth`, `charheight`

**Spec requires:**
- `outspacingx`, `outspacingy` - outer spacing
- `inspacingx`, `inspacingy` - inner spacing between windows
- `gridcharwidth`, `gridcharheight` - grid character dimensions
- `gridmarginx`, `gridmarginy` - grid margins
- `buffercharwidth`, `buffercharheight` - buffer character dimensions
- `buffermarginx`, `buffermarginy` - buffer margins
- `graphicsmarginx`, `graphicsmarginy` - graphics margins

---

## Missing Input Event Handling

These are input events the display can send that wasiglk doesn't handle.

### [ ] 10. Hyperlink Events Not Handled

**Location:** `packages/server/src/event.zig`

Display can send: `{type: "hyperlink", gen: N, window: ID, value: LINK_VALUE}`

Currently: Hyperlink API exists but events are not processed in `glk_select`.

---

### [ ] 11. Mouse Events Not Handled

**Location:** `packages/server/src/event.zig:131-133, 156-158`

Display can send: `{type: "mouse", gen: N, window: ID, x: X, y: Y}`

Currently: `glk_request_mouse_event` and `glk_cancel_mouse_event` are empty stubs.

---

### [ ] 12. Timer Events Not Handled

**Location:** `packages/server/src/event.zig:104-106`

Display can send: `{type: "timer", gen: N}`

Currently: `glk_request_timer_events` is an empty stub.

---

### [ ] 13. Arrange Events Not Handled

Display can send: `{type: "arrange", gen: N, metrics: {...}}`

Currently: No handling for window resize events.

---

### [ ] 14. Redraw Events Not Handled

Display can send: `{type: "redraw", gen: N, window?: ID}`

Currently: No handling for graphics redraw requests.

---

### [ ] 15. Refresh Events Not Handled

Display can send: `{type: "refresh", gen: N}`

Currently: No handling for full state refresh requests.

---

### [ ] 16. Special Response Events Not Handled

Display can send: `{type: "specialresponse", response: "fileref_prompt", value: FILEREF|null}`

Currently: File dialogs not implemented.

---

### [ ] 17. Debug Input Events Not Handled

Display can send: `{type: "debuginput", gen: N, value: "command"}`

Currently: No debug command handling.

---

### [ ] 18. External Events Not Handled

Display can send: `{type: "external", gen: N, value: ANY}`

Currently: No external event handling.

---

### [ ] 19. Line Input Terminator Not Handled

**Location:** `packages/server/src/event.zig:61-93`

Display can send: `{type: "line", ..., terminator: "escape"}`

Currently: `terminator` field is ignored. Should report which special key ended input.

---

### [ ] 20. Partial Input Not Captured

Display sends: `{..., partial: {WINDOW_ID: "partial text"}}`

Currently: `partial` field parsed but not used. Should preserve partial input when events interrupt.

---

## Missing Output Fields

Fields that should be sent from interpreter to display but aren't.

### [ ] 21. Timer Field Not Sent

**Location:** `packages/server/src/protocol.zig:90-96`

**Spec:** Update can include `timer: NUMBER` (set interval) or `timer: null` (cancel).

Currently: Timer field never included in updates.

---

### [ ] 22. Disable Field Not Sent

**Spec:** Update can include `disable: true` to disable all input.

Currently: Not implemented.

---

### [ ] 23. Exit Field Not Sent

**Spec:** Update can include `exit: true` when game exits (RemGLK 0.3.2+).

Currently: Not sent on exit.

---

### [ ] 24. Special Input Requests Not Sent

**Spec:** Update can include `specialinput: {type: "fileref_prompt", filemode: "write", filetype: "save"}`

Currently: File dialogs not implemented.

---

### [ ] 25. Debug Output Not Sent

**Spec:** Update can include `debugoutput: ["debug message", ...]`

Currently: Not implemented.

---

## Missing Input Request Fields

Fields that should be included in input requests but aren't.

### [ ] 26. Terminators Array Not Sent

**Location:** `packages/server/src/protocol.zig:82-88`

**Spec:** Line input can include `terminators: ["escape", "func1", ...]`

Currently: Not sent.

---

### [ ] 27. Hyperlink Boolean Not Sent

**Spec:** Input requests can include `hyperlink: true` to enable hyperlink input alongside text input.

Currently: Not sent.

---

### [ ] 28. Mouse Boolean Not Sent

**Spec:** Input requests can include `mouse: true` to enable mouse input alongside text input.

Currently: Not sent.

---

### [ ] 29. Grid Input Position Not Sent

**Spec:** Grid window input requires `xpos` and `ypos` for cursor position.

Currently: Not sent for grid windows.

---

### [ ] 30. Initial Text Not Populated

**Location:** `packages/server/src/protocol.zig:82-88`, `packages/server/src/event.zig:108-123`

**Spec:** Line input can include `initial: "prefilled text"`

Currently: Field exists but `initlen` parameter is ignored, initial text not sent.

---

## Priority Order (Suggested)

### High Priority (Breaking Issues)
1. ~~Graphics content format (#2)~~ ✅ FIXED
2. ~~Buffer content paragraph structure (#5)~~ ✅ FIXED
3. ~~Grid content format (#6)~~ ✅ FIXED - implemented cursor tracking and grid buffer
4. ~~Init message flow (#1)~~ ✅ FIXED - client sends support array, server stores capabilities, responds with update

### Medium Priority (Functional Gaps)
5. ~~Color format (#3)~~ ✅ FIXED
6. ~~Image alignment format (#4)~~ ✅ FIXED
7. ~~Graphics dimension fields (#7)~~ ✅ FIXED
8. Timer events (#12, #21)
9. Arrange events (#13)
10. Mouse events (#11)
11. Hyperlink events (#10)

### Low Priority (Polish)
12. Metrics completeness (#9)
13. Window positions (#8)
14. Remaining input fields (#26-30)
15. Debug features (#17, #25)
16. External events (#18)

---

## Notes

- The TypeScript client (`packages/client/src/protocol.ts`) may compensate for some server-side issues
- Some features (sound) are intentionally stubbed and not listed here
- Test with actual GlkOte to verify fixes work with the reference implementation
