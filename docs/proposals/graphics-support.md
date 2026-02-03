# Graphics Support Implementation Proposal

**Date:** 2026-02-03
**Status:** Draft
**Author:** Generated with assistance from Claude Code

## Executive Summary

This proposal outlines a plan to add graphics support to wasiglk, following the RemGLK URL-reference model. The implementation includes:

1. **Zig-side graphics implementation** in `wasi_glk.zig` generating RemGLK-compatible JSON
2. **TypeScript client library** (`@wasiglk/client`) that consumes the protocol and renders graphics
3. **Blorb parsing utilities** in TypeScript for extracting image resources

Sound support is deferred pending discussion with the RemGLK maintainer about their planned approach.

---

## Background

### Current State

wasiglk compiles Interactive Fiction interpreters (Glulxe, Git, Hugo, etc.) to WebAssembly using a custom GLK implementation written in Zig. The implementation:

- Communicates via JSON over stdin/stdout (RemGLK-compatible protocol)
- Uses JSPI (JavaScript Promise Integration) for async I/O in browsers
- Has Blorb support via `gi_blorb.c` for resource file parsing
- **Stubs out all graphics and sound functions** (gestalt queries return 0)

### RemGLK Graphics Approach

RemGLK has supported graphics since v0.2.4 (January 2017) using a URL-reference model:

- Images are **not** embedded as binary data in JSON
- JSON contains image metadata and a URL reference
- The display layer (GlkOte) independently fetches images by URL
- Resource URLs configured via `-resourceurl` or `-resourcedir` flags

This approach provides clean separation between the interpreter and display layer.

### Motivation

Many IF games include graphics (Photopia, City of Secrets, Anchorhead illustrated edition, etc.). Supporting graphics would:

- Enable a broader range of games to run in wasiglk
- Provide a foundation for a proper TypeScript client library
- Potentially contribute improvements back to the RemGLK community

---

## Proposed Solution

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Browser                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                  @wasiglk/client                          │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────────┐  │  │
│  │  │  WASI    │ │ Protocol │ │  Blorb   │ │  Display    │  │  │
│  │  │  Layer   │ │  Parser  │ │  Parser  │ │  State      │  │  │
│  │  └────┬─────┘ └────┬─────┘ └────┬─────┘ └──────┬──────┘  │  │
│  │       │            │            │              │          │  │
│  │       └────────────┴────────────┴──────────────┘          │  │
│  │                         │                                  │  │
│  │                    WasiGlkClient                          │  │
│  └──────────────────────────┬───────────────────────────────┘  │
│                             │ JSON Protocol                     │
│  ┌──────────────────────────┴───────────────────────────────┐  │
│  │                    WASM Module                            │  │
│  │  ┌────────────────────────────────────────────────────┐  │  │
│  │  │              Interpreter (Glulxe, etc.)             │  │  │
│  │  │                        │                            │  │  │
│  │  │  ┌─────────────────────┴─────────────────────────┐ │  │  │
│  │  │  │              wasi_glk.zig                      │ │  │  │
│  │  │  │  • Graphics JSON generation                   │ │  │  │
│  │  │  │  • Blorb resource lookup                      │ │  │  │
│  │  │  │  • URL reference generation                   │ │  │  │
│  │  │  └───────────────────────────────────────────────┘ │  │  │
│  │  └────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
│                             │                                   │
│                    Resource Server                              │
│                    (extracted images)                           │
└─────────────────────────────────────────────────────────────────┘
```

### Component 1: Zig Graphics Implementation

**File:** `src/wasi_glk.zig`

#### Changes Required

1. **Enable Graphics Gestalt** (lines 505-506)
   - Return 1 for `gestalt_Graphics`, `gestalt_DrawImage`, `gestalt_GraphicsTransparency`
   - Conditionally based on whether a Blorb map with images exists

2. **Implement `glk_image_get_info()`** (line 1774)
   - Query `giblorb_load_image_info()` from the Blorb map
   - Return actual width/height from image chunks
   - Return 1 on success, 0 on failure

3. **Implement `glk_image_draw()`** (line 1781)
   - Look up image in Blorb map
   - Determine format (PNG/JPEG) from chunk type
   - Generate URL: `{base}/pict-{number}.{extension}`
   - Queue graphics operation as JSON "special" span
   - Support alignment parameter (imagealign_InlineUp, etc.)

4. **Implement `glk_image_draw_scaled()`** (line 1789)
   - Same as above, but include explicit width/height

5. **Implement graphics window operations**
   - `glk_window_fill_rect()` - Generate fill operation JSON
   - `glk_window_set_background_color()` - Generate setcolor operation JSON
   - `glk_window_erase_rect()` - Generate erase operation JSON

6. **Update JSON serialization**
   - Extend `ContentUpdate` to include "special" spans
   - Format matching RemGLK protocol

#### JSON Output Format

**Text Buffer Image:**
```json
{
  "type": "update",
  "gen": 5,
  "content": [{
    "id": 1,
    "text": [
      "You see a painting on the wall.\n",
      { "special": {
          "type": "image",
          "image": 5,
          "url": "/resources/pict-5.png",
          "alignment": 3,
          "width": 320,
          "height": 240
        }
      },
      "\nIt depicts a stormy sea."
    ]
  }]
}
```

**Graphics Window Operations:**
```json
{
  "type": "update",
  "gen": 6,
  "content": [{
    "id": 2,
    "text": [
      { "special": { "type": "setcolor", "color": 16777215 }},
      { "special": { "type": "fill", "color": 255, "x": 10, "y": 10, "width": 100, "height": 100 }},
      { "special": { "type": "image", "image": 3, "url": "/resources/pict-3.jpeg", "x": 50, "y": 50 }}
    ]
  }]
}
```

### Component 2: TypeScript Client Library

**Package:** `@wasiglk/client`
**Location:** `packages/client/`

#### Package Structure

```
packages/client/
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts                 # Main export: createClient()
│   ├── client.ts                # WasiGlkClient implementation
│   ├── wasi/
│   │   ├── index.ts
│   │   ├── jspi-wasi.ts        # JSPI WASI implementation
│   │   ├── file-system.ts      # Virtual filesystem
│   │   ├── memory.ts           # Memory helpers
│   │   └── types.ts            # WASI types
│   ├── protocol/
│   │   ├── index.ts
│   │   ├── remglk.ts           # Protocol parser
│   │   ├── types.ts            # Protocol types
│   │   └── validator.ts        # Runtime validation
│   ├── blorb/
│   │   ├── index.ts
│   │   ├── parser.ts           # Blorb parser
│   │   ├── utils.ts            # URL generation, etc.
│   │   └── types.ts            # Blorb types
│   ├── display/
│   │   ├── index.ts
│   │   ├── state.ts            # Display state manager
│   │   ├── graphics.ts         # Graphics renderer
│   │   └── hooks.ts            # Framework integration hooks
│   └── utils/
│       ├── events.ts           # Event emitter
│       ├── streams.ts          # Stream utilities
│       └── errors.ts           # Error classes
└── test/
    └── ...
```

#### Public API

```typescript
// Main entry point
export interface WasiGlkConfig {
  wasmModule: ArrayBuffer;
  storyFile: Uint8Array;
  args?: string[];
  resourceUrlBase?: string;
  display?: { width?: number; height?: number };
  hooks?: DisplayHooks;
}

export interface WasiGlkClient {
  readonly state: DisplayState;
  readonly blorb?: BlorbParser;

  start(): Promise<void>;
  sendInput(windowId: number, value: string): Promise<void>;
  getWindow(id: number): WindowState | undefined;
  stop(): void;

  on(event: string, handler: Function): void;
  off(event: string, handler: Function): void;
}

export async function createClient(config: WasiGlkConfig): Promise<WasiGlkClient>;

// Submodule exports for tree-shaking
export * from './protocol';
export * from './blorb';
export * from './display';
```

#### Framework Integration

The library provides hooks rather than UI components, allowing integration with any framework:

**Vanilla JavaScript:**
```javascript
const client = await createClient({
  wasmModule,
  storyFile,
  resourceUrlBase: '/resources',
  hooks: {
    onContent: (windowId, content) => {
      renderContent(windowId, content);
    },
    onInputRequest: (windowId, request) => {
      enableInput(windowId);
    }
  }
});
await client.start();
```

**React Hook:**
```typescript
function useWasiGlk(config: WasiGlkConfig) {
  const [windows, setWindows] = useState<WindowState[]>([]);
  const clientRef = useRef<WasiGlkClient | null>(null);

  useEffect(() => {
    const init = async () => {
      const client = await createClient({
        ...config,
        hooks: {
          onWindowUpdate: () => setWindows([...client.state.getAllWindows()])
        }
      });
      clientRef.current = client;
      await client.start();
    };
    init();
    return () => clientRef.current?.stop();
  }, []);

  return { windows, sendInput: (id, value) => clientRef.current?.sendInput(id, value) };
}
```

### Component 3: Blorb Parser

A standalone TypeScript implementation of Blorb parsing:

```typescript
export class BlorbParser {
  constructor(data: Uint8Array);

  // Resource access
  getResource(usage: 'Pict' | 'Snd' | 'Exec' | 'Data', number: number): BlorbResource | null;
  getImage(number: number): BlorbImageInfo | null;
  getAllImages(): BlorbImageInfo[];

  // Metadata
  getMetadata(): BlorbMetadata;
  getExecutable(): Uint8Array | null;
}

export interface BlorbImageInfo {
  number: number;
  chunkType: 'PNG' | 'JPEG';
  width: number;
  height: number;
  data: Uint8Array;
}

// Utility functions
export function createImageUrl(image: BlorbImageInfo): string;
export function extractStoryFromBlorb(blorb: Uint8Array): { story: Uint8Array; resources: BlorbParser };
```

---

## Implementation Plan

### Phase 1: TypeScript Library Foundation

**Duration:** ~3-4 days

1. Create package structure at `packages/client/`
2. Set up build configuration (Bun, TypeScript strict mode)
3. Implement utility classes (EventEmitter, errors)
4. Port `jspi-wasi.js` to TypeScript with proper types
5. Implement RemGLK protocol types and parser
6. Write unit tests for protocol parsing

**Deliverables:**
- Working TypeScript WASI implementation
- Protocol types and parser
- Test suite

### Phase 2: Blorb Parser

**Duration:** ~2-3 days

1. Implement IFF/FORM structure parser
2. Implement resource index (RIdx) parsing
3. Implement image chunk parsing (PNG, JPEG dimensions)
4. Implement metadata chunk parsing
5. Create blob URL utilities
6. Write unit tests with sample Blorb files

**Deliverables:**
- Complete Blorb parser
- Test suite with fixtures

### Phase 3: Zig Graphics Implementation

**Duration:** ~2-3 days

1. Add graphics data structures to `wasi_glk.zig`
2. Implement `glk_image_get_info()` with Blorb integration
3. Implement `glk_image_draw()` with URL generation
4. Implement `glk_image_draw_scaled()`
5. Implement graphics window operations
6. Update JSON serialization for graphics spans
7. Enable graphics gestalt queries

**Deliverables:**
- Working graphics output in JSON
- Test with sample Blorb file

### Phase 4: Display Layer & Graphics Rendering

**Duration:** ~2-3 days

1. Implement DisplayState class
2. Implement window state tracking
3. Implement GraphicsRenderer class
4. Handle image display with alignment
5. Handle graphics window canvas operations
6. Write integration tests

**Deliverables:**
- Complete display state management
- Graphics rendering in browser

### Phase 5: Integration & Demo

**Duration:** ~2-3 days

1. Wire all layers together in WasiGlkClient
2. Create graphics demo page
3. Test with graphics-enabled games (Photopia, etc.)
4. Update existing example to use new library
5. Write migration guide

**Deliverables:**
- Working demo with graphics
- Updated examples

### Phase 6: Documentation & Polish

**Duration:** ~1-2 days

1. Add JSDoc comments
2. Write API documentation
3. Create getting-started guide
4. Prepare for npm publish

**Deliverables:**
- Complete documentation
- Ready for npm release

---

## Testing Strategy

### Unit Tests
- Protocol parsing with various JSON inputs
- Blorb parsing with sample files
- Display state transitions
- WASI function behavior

### Integration Tests
- Full client with mock WASM module
- Graphics rendering end-to-end
- Input/output flow

### Manual Testing
- **Photopia** - Text buffer images
- **City of Secrets** - Graphics window + images
- **Anchorhead Illustrated** - Heavy graphics usage
- **Bronze** - Verify no regression for text-only games

### Test Fixtures
- Sample Blorb files with known resources
- Expected JSON output samples
- Mock WASM modules for isolation

---

## Resource URL Strategy

Following RemGLK's approach, images are referenced by URL rather than embedded:

### URL Format
```
{base}/pict-{number}.{extension}

Examples:
/resources/pict-1.png
/resources/pict-5.jpeg
https://cdn.example.com/game/pict-12.png
```

### Configuration Options

**Zig side (command line):**
```
glulxe -resourceurl http://localhost:8000/static story.gblorb
```

**TypeScript side:**
```typescript
createClient({
  resourceUrlBase: '/resources',
  // or with Blorb parser for auto-extraction
  blorb: new BlorbParser(blorbData)
});
```

### Resource Extraction

For development/deployment, Blorb resources can be extracted:

```typescript
// In Node/Bun build script
const blorb = new BlorbParser(blorbData);
for (const image of blorb.getAllImages()) {
  const ext = image.chunkType.toLowerCase();
  await writeFile(`resources/pict-${image.number}.${ext}`, image.data);
}
```

---

## Future Considerations

### Sound Support (Deferred)

Sound support will be addressed separately after discussion with the RemGLK maintainer. Key considerations:

- RemGLK does not currently support sound
- A JSON protocol proposal exists (Dec 2023 community discussion)
- Web Audio API limitations (MOD format, async decoding)
- Event notifications (SoundNotify, VolumeNotify)

The architecture is designed to accommodate sound later:
- `schanid_t` type already defined
- Sound gestalt queries ready to enable
- Blorb parser can extract sound resources

### Potential Enhancements

1. **Save/Restore** - Persist game state to browser storage
2. **Hyperlinks** - Already supported in protocol, need rendering
3. **Styles** - Rich text styling support
4. **Accessibility** - Screen reader support, high contrast mode

---

## File Change Summary

### New Files

```
packages/client/
├── package.json
├── tsconfig.json
├── tsconfig.build.json
├── src/
│   ├── index.ts
│   ├── client.ts
│   ├── wasi/
│   │   ├── index.ts
│   │   ├── jspi-wasi.ts
│   │   ├── file-system.ts
│   │   ├── memory.ts
│   │   └── types.ts
│   ├── protocol/
│   │   ├── index.ts
│   │   ├── remglk.ts
│   │   ├── types.ts
│   │   └── validator.ts
│   ├── blorb/
│   │   ├── index.ts
│   │   ├── parser.ts
│   │   ├── utils.ts
│   │   └── types.ts
│   ├── display/
│   │   ├── index.ts
│   │   ├── state.ts
│   │   ├── graphics.ts
│   │   └── hooks.ts
│   └── utils/
│       ├── events.ts
│       ├── streams.ts
│       └── errors.ts
├── test/
│   └── ...
└── examples/
    └── vanilla/
        ├── index.html
        └── app.ts

examples/jspi-browser/
└── graphics-demo.html

docs/proposals/
└── graphics-support.md (this file)
```

### Modified Files

```
src/wasi_glk.zig
  - Lines ~318: Add graphics operation structures
  - Lines ~403: Update queueContentUpdate for graphics spans
  - Lines 505-506: Enable graphics gestalt queries
  - Lines 1774-1823: Implement graphics functions (replace stubs)

README.md
  - Document graphics support
  - Update interpreter capabilities table
```

---

## Appendix: RemGLK Protocol Reference

### Graphics Special Spans

```typescript
interface SpecialSpan {
  type: 'flowbreak' | 'image' | 'setcolor' | 'fill';

  // For type: 'image'
  image?: number;        // Resource number
  url?: string;          // Image URL
  alignment?: number;    // imagealign_* constant
  width?: number;        // Display width (optional, for scaling)
  height?: number;       // Display height (optional, for scaling)
  alttext?: string;      // Alt text for accessibility

  // For type: 'fill' (graphics windows)
  color?: number;        // RGB color value
  x?: number;            // X position
  y?: number;            // Y position
  // width/height reused for fill dimensions

  // For type: 'setcolor' (graphics windows)
  // color reused for background color
}
```

### Image Alignment Constants

```typescript
const imagealign = {
  InlineUp: 1,
  InlineDown: 2,
  InlineCenter: 3,
  MarginLeft: 4,
  MarginRight: 5
};
```

### Blorb Chunk Types

| FourCC | Description |
|--------|-------------|
| `PNG ` | PNG image |
| `JPEG` | JPEG image |
| `AIFF` | AIFF audio |
| `OGGV` | Ogg Vorbis audio |
| `MOD ` | MOD music |
| `ZCOD` | Z-code executable |
| `GLUL` | Glulx executable |
| `RIdx` | Resource index |
| `IFmd` | IFiction metadata |

---

## References

- [RemGLK Documentation](https://www.eblong.com/zarf/glk/remglk/docs.html)
- [GLK Specification](https://www.eblong.com/zarf/glk/Glk-Spec-075.html)
- [Blorb Specification](https://www.eblong.com/zarf/blorb/blorb.html)
- [GlkOte Documentation](https://eblong.com/zarf/glk/glkote/docs.html)
- [JSPI Specification](https://github.com/WebAssembly/js-promise-integration)
