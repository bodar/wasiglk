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

**Commits:** Create a git commit after completing each major item (e.g., after fixing an issue and verifying tests pass). This keeps changes atomic and makes it easier to review or revert if needed.

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

### [x] 8. Window Positions Now Calculated (FIXED)

**Location:** `packages/server/src/window.zig`, `packages/server/src/protocol.zig`, `packages/server/src/state.zig`

**Fixed:** Window positions are now calculated based on the Glk pair window tree:
1. Added `split_method`, `split_size`, `split_key` fields to WindowData for pair windows
2. Added `layout_left`, `layout_top`, `layout_width`, `layout_height` fields to all windows
3. `glk_window_open` now creates proper pair windows when splitting
4. `recalculateLayout()` traverses the window tree and computes positions
5. `queueWindowUpdate()` uses calculated layout positions
6. `glk_window_get_size()` returns calculated dimensions
7. `glk_window_set_arrangement()` and `glk_window_get_arrangement()` now work properly

---

### [x] 9. Metrics Object Complete (FIXED)

**Location:** `packages/server/src/protocol.zig`, `packages/client/src/protocol.ts`, `packages/client/src/worker/messages.ts`

**Fixed:** Added all GlkOte spec metrics fields:
- `outspacingx`, `outspacingy` - outer spacing
- `inspacingx`, `inspacingy` - inner spacing between windows
- `gridcharwidth`, `gridcharheight` - grid character dimensions
- `gridmarginx`, `gridmarginy` - grid margins
- `buffercharwidth`, `buffercharheight` - buffer character dimensions
- `buffermarginx`, `buffermarginy` - buffer margins
- `graphicsmarginx`, `graphicsmarginy` - graphics margins

Client sends all fields with sensible defaults. Grid/buffer specific char dimensions fall back to generic charwidth/charheight. Spacing and margins default to 0.

---

## Missing Input Event Handling

These are input events the display can send that wasiglk doesn't handle.

### [x] 10. Hyperlink Events Handled (FIXED)

**Location:** `packages/server/src/event.zig`, `packages/server/src/style.zig`, `packages/server/src/state.zig`, `packages/client/src/client.ts`

**Fixed:** Hyperlink events are now fully implemented:
1. `WindowData` struct has `hyperlink_request` flag
2. `glk_request_hyperlink_event(win)` sets the flag for buffer/grid windows
3. `glk_cancel_hyperlink_event(win)` clears the flag
4. `glk_select()` handles `{type: "hyperlink", gen: N, window: ID, value: LINK_VALUE}` events
5. Input requests include `hyperlink: true` when hyperlink input is enabled for the window
6. Client has `sendHyperlink(windowId, linkValue)` method to send hyperlink clicks
7. Worker forwards hyperlink events to the interpreter

---

### [x] 11. Mouse Events Handled (FIXED)

**Location:** `packages/server/src/event.zig`, `packages/server/src/state.zig`, `packages/client/src/client.ts`

**Fixed:** Mouse events are now fully implemented:
1. `WindowData` struct has `mouse_request` flag
2. `glk_request_mouse_event(win)` sets the flag for grid/graphics windows
3. `glk_cancel_mouse_event(win)` clears the flag
4. `glk_select()` handles `{type: "mouse", gen: N, window: ID, x: X, y: Y}` events
5. Input requests include `mouse: true` when mouse input is enabled for the window
6. Client has `sendMouse(windowId, x, y)` method to send mouse clicks
7. Worker forwards mouse events to the interpreter

---

### [x] 12. Timer Events Handled (FIXED)

**Location:** `packages/server/src/event.zig:105-113`, `packages/server/src/protocol.zig`

**Fixed:** Timer events are now fully implemented:
1. `glk_request_timer_events(millisecs)` stores timer interval in `state.timer_interval`
2. `glk_select()` checks for timer and includes `timer` field in update message
3. Client handles timer updates, creates JavaScript interval timer
4. When timer fires, client sends `{type: "timer", gen: N}` event
5. Server parses timer events and returns `evtype_Timer` to game

---

### [x] 13. Arrange Events Handled (FIXED)

**Location:** `packages/server/src/event.zig:67-80`, `packages/client/src/client.ts`, `packages/client/src/worker/interpreter.worker.ts`

**Fixed:** Arrange events are now fully implemented:
1. Client exposes `sendArrange(metrics)` method for notifying the interpreter of window resize
2. Worker forwards arrange events to the interpreter via stdin
3. `glk_select()` parses arrange events and updates `state.client_metrics`
4. Returns `evtype_Arrange` with root window in the event struct

---

### [x] 14. Redraw Events Handled (FIXED)

Display can send: `{type: "redraw", gen: N, window?: ID}`

**Fixed:**
1. `glk_select()` handles "redraw" events and returns `evtype_Redraw`
2. If window ID is provided, that window is returned; otherwise root window
3. Client has `sendRedraw(windowId?)` method to trigger redraw requests

---

### [x] 15. Refresh Events Handled (FIXED)

Display can send: `{type: "refresh", gen: N}`

**Fixed:**
1. `glk_select()` handles "refresh" events, returning `evtype_Arrange` to trigger state resend
2. Client has `sendRefresh()` method to request full state refresh

---

### [ ] 16. Special Response Events Not Handled

Display can send: `{type: "specialresponse", response: "fileref_prompt", value: FILEREF|null}`

Currently: File dialogs not implemented.

---

### [x] 17. Debug Input Events Handled (FIXED)

Display can send: `{type: "debuginput", gen: N, value: "command"}`

**Fixed:** Events are now parsed and acknowledged (returns evtype.None). Debug commands could be implemented in the future but currently are no-ops.

---

### [x] 18. External Events Handled (FIXED)

Display can send: `{type: "external", gen: N, value: ANY}`

**Fixed:** Events are now parsed and acknowledged (returns evtype.None). External events are for custom extensions and are safely ignored.

---

### [x] 19. Line Input Terminator Handled (FIXED)

**Location:** `packages/server/src/event.zig`, `packages/server/src/protocol.zig`, `packages/server/src/types.zig`

Display can send: `{type: "line", ..., terminator: "escape"}`

**Fixed:**
1. Added `terminator` field to InputEvent structs
2. Added function key constants (Func1-Func12) to keycode struct
3. Added `terminatorToKeycode()` helper to convert terminator strings
4. Line input now returns the terminator keycode in event.val2

---

### [x] 20. Partial Input Now Captured (FIXED)

Display sends: `{..., partial: {WINDOW_ID: "partial text"}}`

**Fixed:**
1. Added `line_partial_len` field to WindowData to track partial text length
2. `parseInputEvent` now processes the `partial` field from events
3. When events with partial data are received, text is copied to the window's line buffer
4. `glk_cancel_line_event` now returns LineInput event with partial text length in val1
5. Buffer dispatch unregistration added to glk_cancel_line_event for proper Glulxe integration

---

## Missing Output Fields

Fields that should be sent from interpreter to display but aren't.

### [x] 21. Timer Field Now Sent (FIXED)

**Location:** `packages/server/src/protocol.zig:147-193`

**Fixed:** Timer field is now included in update messages:
- `timer: NUMBER` when timer is active (set interval)
- `timer: null` when timer is cancelled
- Field omitted when timer state hasn't changed

---

### [x] 22. Disable Field Now Sent (FIXED)

**Spec:** Update can include `disable: true` to disable all input.

**Fixed:** Updates without input requests now include `disable: true` to indicate the game is not expecting input.

---

### [x] 23. Exit Field Now Sent (FIXED)

**Spec:** Update can include `exit: true` when game exits (RemGLK 0.3.2+).

**Fixed:** `glk_exit` now always sends a final update with `exit: true` before terminating.

---

### [ ] 24. Special Input Requests Not Sent

**Spec:** Update can include `specialinput: {type: "fileref_prompt", filemode: "write", filetype: "save"}`

Currently: File dialogs not implemented.

---

### [x] 25. Debug Output Now Implemented (FIXED)

**Location:** `packages/server/src/protocol.zig`, `packages/server/src/style.zig`, `packages/server/src/state.zig`, `packages/client/src/protocol.ts`

**Spec:** Update can include `debugoutput: ["debug message", ...]`

**Fixed:**
1. Added `debug_buffer`, `debug_buffer_len`, `debug_stream` to state.zig
2. Added `glk_set_debug_stream()` to style.zig
3. Added `pending_debug` arrays and `queueDebugMessage()` to protocol.zig
4. Modified `sendUpdate()` to include `debugoutput` array when debug messages are queued
5. Added `debugoutput` field to RemGlkUpdate interface in protocol.ts
6. Added `DebugOutputClientUpdate` type and parsing in parseRemGlkUpdate()

---

### [x] 25b. Hyperlink Output Now Implemented (FIXED)

**Location:** `packages/server/src/style.zig:60-67`, `packages/server/src/protocol.zig`, `packages/server/src/state.zig`

**Spec:** Text spans can include `hyperlink: LINK_VALUE` to make text clickable:
```json
{"text": [{"append": true, "content": [{"style": "normal", "text": "click here", "hyperlink": 42}]}]}
```

**Fixed:**
1. Added `current_hyperlink` field to global state
2. `glk_set_hyperlink()` flushes text buffer and updates current hyperlink value
3. `glk_set_hyperlink_stream()` delegates to `glk_set_hyperlink()` for current stream
4. `sendBufferTextUpdate()` now includes `hyperlink` field when value is non-zero
5. Games can now create clickable hyperlinks that work with `glk_request_hyperlink_event()`

---

### [x] 25c. Style Output Now Implemented (FIXED)

**Location:** `packages/server/src/stream.zig:470-477`, `packages/server/src/protocol.zig`, `packages/server/src/state.zig`

**Spec:** Text spans can include `style` to specify formatting:
```json
{"text": [{"append": true, "content": [{"style": "emphasized", "text": "important text"}]}]}
```

Valid styles: `normal`, `emphasized`, `preformatted`, `header`, `subheader`, `alert`, `note`, `blockquote`, `input`, `user1`, `user2`

**Fixed:**
1. Added `current_style` field to global state
2. `glk_set_style()` flushes text buffer and updates current style
3. `glk_set_style_stream()` delegates to `glk_set_style()` for current stream
4. `sendBufferTextUpdate()` now outputs text with `style` field in content spans
5. Added `styleToString()` helper to convert Glk style constants to GlkOte style names

---

## Missing Input Request Fields

Fields that should be included in input requests but aren't.

### [x] 26. Terminators Array Now Sent (FIXED)

**Location:** `packages/server/src/protocol.zig`, `packages/server/src/state.zig`, `packages/server/src/style.zig`

**Spec:** Line input can include `terminators: ["escape", "func1", ...]`

**Fixed:**
1. Added `line_terminators` array and `line_terminators_count` to WindowData struct
2. Implemented `glk_set_terminators_line_event(win, keycodes, count)` to set terminators for a window
3. Input requests now include `terminators: ["escape", "func1", ...]` array when terminators are set
4. Added TypeScript types for terminators field in InputRequest and InputRequestClientUpdate

---

### [x] 27. Hyperlink Boolean Now Sent (FIXED)

**Spec:** Input requests can include `hyperlink: true` to enable hyperlink input alongside text input.

**Fixed:** Input requests now include `hyperlink: true` when the window has an active hyperlink request.

---

### [x] 28. Mouse Boolean Now Sent (FIXED)

**Spec:** Input requests can include `mouse: true` to enable mouse input alongside text input.

**Fixed:** Input requests now include `mouse: true` when the window has an active mouse request.

---

### [x] 29. Grid Input Position Now Sent (FIXED)

**Spec:** Grid window input requires `xpos` and `ypos` for cursor position.

**Fixed:** Input requests for grid windows now include `xpos` and `ypos` fields with the current cursor position.

---

### [x] 30. Initial Text Now Populated (FIXED)

**Location:** `packages/server/src/event.zig`, `packages/server/src/state.zig`

**Spec:** Line input can include `initial: "prefilled text"`

**Fixed:**
1. Added `line_initlen` field to WindowData to store the initial text length
2. `glk_request_line_event` and `glk_request_line_event_uni` now store initlen
3. `getInitialText` helper extracts initial text from line buffer
4. Input requests include `initial` field with pre-filled text when initlen > 0

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
8. ~~Timer events (#12, #21)~~ ✅ FIXED - full timer support with glk_request_timer_events, timer field in updates, client-side timer handling
9. ~~Arrange events (#13)~~ ✅ FIXED - client sendArrange method, worker forwarding, server evtype_Arrange
10. ~~Mouse events (#11)~~ ✅ FIXED - mouse_request flag, glk_request/cancel_mouse_event, mouse event parsing, client sendMouse method
11. ~~Hyperlink events (#10)~~ ✅ FIXED - hyperlink_request flag, glk_request/cancel_hyperlink_event, hyperlink event parsing, client sendHyperlink method

### Low Priority (Polish)
12. ~~Metrics completeness (#9)~~ ✅ FIXED - all GlkOte spec metrics fields added
13. ~~Window positions (#8)~~ ✅ FIXED - pair window tree layout implemented
14. ~~Remaining input fields (#26-30)~~ ✅ FIXED - terminators (#26), hyperlink (#27), mouse (#28), xpos/ypos (#29), initial (#30) all implemented
15. ~~Debug input events (#17)~~ ✅ FIXED - acknowledged with evtype.None
16. ~~External events (#18)~~ ✅ FIXED - acknowledged with evtype.None
17. ~~Debug output (#25)~~ ✅ FIXED
17. ~~Partial input (#20)~~ ✅ FIXED - partial text captured from interrupted input

---

## Code Quality Improvements

### [x] Refactor Zig Protocol to Use Structs Instead of String Concatenation (FIXED)

**Location:** `packages/server/src/protocol.zig`

**Fixed:** Refactored all protocol output to use proper Zig structs with `std.json` serialization:

1. Added proper struct types matching GlkOte/RemGLK JSON schema:
   - `TextSpan`, `ImageSpan`, `ContentSpan` (union) for text content
   - `TextParagraph` for buffer window paragraphs
   - `GridLine` for grid window lines
   - `DrawOp` for graphics window operations
   - `ContentUpdateJson` for content updates
   - `InputRequestJson` for input requests
   - `StateUpdateJson` for full update messages
   - `TimerValue` union for timer interval or cancellation

2. Refactored `sendUpdate()` to use struct serialization with `emit_null_optional_fields = false`

3. Refactored all special update functions:
   - `sendBufferTextUpdate()` - uses TextParagraph and ContentSpan
   - `sendFlowBreakUpdate()` - uses TextParagraph
   - `sendImageUpdate()` - uses ImageSpan and TextParagraph
   - `sendGraphicsImageUpdate()` - uses DrawOp
   - `sendGraphicsFillUpdate()` - uses DrawOp
   - `sendGraphicsEraseUpdate()` - uses DrawOp
   - `sendGraphicsSetColorUpdate()` - uses DrawOp
   - `flushGridWindow()` - uses GridLine and ContentSpan

4. Removed manual `jsonEscapeString()` helper - std.json handles escaping automatically

5. Added `sendContentUpdate()` helper for simple content-only updates

Benefits achieved:
- Protocol schema clearly documented in code via struct definitions
- Zig's optional fields with null defaults provide clean optional handling
- Eliminated manual string escaping and formatting bugs
- Code is more maintainable and self-documenting

---

## Notes

- The TypeScript client (`packages/client/src/protocol.ts`) may compensate for some server-side issues
- Some features (sound) are intentionally stubbed and not listed here
- Test with actual GlkOte to verify fixes work with the reference implementation
