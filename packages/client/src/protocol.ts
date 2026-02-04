/**
 * RemGLK Protocol Types
 *
 * These types represent the JSON protocol used for communication
 * between the WASM interpreter and the client.
 */

// Input events (client -> interpreter)
export interface InitEvent {
  type: 'init';
  gen: number;
  metrics: Metrics;
  support?: string[];  // Features the display supports: 'timer', 'graphics', 'graphicswin', 'hyperlinks'
}

export interface LineInputEvent {
  type: 'line';
  gen: number;
  window: number;
  value: string;
}

export interface CharInputEvent {
  type: 'char';
  gen: number;
  window: number;
  value: string;
}

export interface TimerInputEvent {
  type: 'timer';
  gen: number;
}

export interface ArrangeInputEvent {
  type: 'arrange';
  gen: number;
  metrics: Metrics;
}

export interface MouseInputEvent {
  type: 'mouse';
  gen: number;
  window: number;
  x: number;
  y: number;
}

export interface HyperlinkInputEvent {
  type: 'hyperlink';
  gen: number;
  window: number;
  value: number;  // The link value (number) set with glk_set_hyperlink
}

export type InputEvent = InitEvent | LineInputEvent | CharInputEvent | TimerInputEvent | ArrangeInputEvent | MouseInputEvent | HyperlinkInputEvent;

export interface Metrics {
  width: number;
  height: number;
  charwidth?: number;
  charheight?: number;
}

// Output updates (interpreter -> client)
export interface RemGlkUpdate {
  type: 'update' | 'error';
  gen: number;
  windows?: WindowUpdate[];
  content?: ContentUpdate[];
  input?: InputRequest[];
  timer?: number | null;  // Timer interval in ms, or null to cancel
  message?: string;
}

export interface WindowUpdate {
  id: number;
  type: 'buffer' | 'grid' | 'graphics' | 'pair';
  rock: number;
  left?: number;
  top?: number;
  width: number;
  height: number;
  // Grid window dimensions (character cells)
  gridwidth?: number;
  gridheight?: number;
  // Graphics window canvas dimensions (pixels)
  graphwidth?: number;
  graphheight?: number;
}

export interface ContentUpdate {
  id: number;
  clear?: boolean;
  text?: TextParagraph[];   // Buffer windows: array of paragraph objects (GlkOte spec)
  lines?: GridLine[];       // Grid windows: array of line objects (GlkOte spec)
  draw?: DrawOperation[];   // Graphics windows: array of draw operations (GlkOte spec)
}

// Buffer window paragraph structure (GlkOte spec)
export interface TextParagraph {
  append?: boolean;
  flowbreak?: boolean;
  content?: ContentSpan[];
}

// Grid window line structure (GlkOte spec)
export interface GridLine {
  line: number;
  content?: ContentSpan[];
}

// Graphics window draw operations (GlkOte spec)
export interface DrawOperation {
  special: 'setcolor' | 'fill' | 'image';
  color?: string;  // CSS hex color like "#RRGGBB"
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  image?: number;
  url?: string;
}

export type ContentSpan = string | TextSpan | SpecialSpan;

export interface TextSpan {
  style?: string;
  text: string;
  hyperlink?: number;
}

export interface SpecialSpan {
  special: SpecialContent;
}

export interface SpecialContent {
  type: 'image' | 'flowbreak' | 'setcolor' | 'fill';
  // Image fields
  image?: number;
  url?: string;
  alignment?: ImageAlignment;
  width?: number;
  height?: number;
  alttext?: string;
  // Graphics window fields
  color?: number;
  x?: number;
  y?: number;
}

export type ImageAlignment =
  | 'inlineup'
  | 'inlinedown'
  | 'inlinecenter'
  | 'marginleft'
  | 'marginright';

export const IMAGE_ALIGNMENT_VALUES: Record<number, ImageAlignment> = {
  1: 'inlineup',
  2: 'inlinedown',
  3: 'inlinecenter',
  4: 'marginleft',
  5: 'marginright',
};

export interface InputRequest {
  id: number;
  type: 'line' | 'char';
  gen?: number;
  maxlen?: number;
  initial?: string;
  mouse?: boolean;  // true if mouse input is enabled for this window
  hyperlink?: boolean;  // true if hyperlink input is enabled for this window
  xpos?: number;  // cursor x position for grid windows
  ypos?: number;  // cursor y position for grid windows
}

// Client update types (what we yield from the async iterator)
export type ClientUpdate =
  | ContentClientUpdate
  | InputRequestClientUpdate
  | WindowClientUpdate
  | ErrorClientUpdate
  | TimerClientUpdate;

export interface ContentClientUpdate {
  type: 'content';
  windowId: number;
  clear: boolean;
  content: ProcessedContentSpan[];
}

export interface ProcessedContentSpan {
  type: 'text' | 'image' | 'flowbreak' | 'fill' | 'setcolor';
  // Text fields
  text?: string;
  style?: string;
  hyperlink?: number;
  // Image fields
  imageNumber?: number;
  imageUrl?: string;
  alignment?: ImageAlignment;
  width?: number;
  height?: number;
  alttext?: string;
  // Graphics draw fields (from draw array)
  color?: string;  // CSS hex color
  x?: number;
  y?: number;
}

export interface InputRequestClientUpdate {
  type: 'input-request';
  windowId: number;
  inputType: 'line' | 'char';
  maxLength?: number;
  initial?: string;
  mouse?: boolean;  // true if mouse input is enabled for this window
  hyperlink?: boolean;  // true if hyperlink input is enabled for this window
  xpos?: number;  // cursor x position for grid windows
  ypos?: number;  // cursor y position for grid windows
}

export interface WindowClientUpdate {
  type: 'window';
  windows: WindowUpdate[];
}

export interface ErrorClientUpdate {
  type: 'error';
  message: string;
}

export interface TimerClientUpdate {
  type: 'timer';
  interval: number | null;  // Interval in ms, or null to cancel timer
}

/**
 * Parse a RemGLK update and convert to client updates
 */
export function parseRemGlkUpdate(
  update: RemGlkUpdate,
  resolveImageUrl: (imageNum: number) => string | undefined
): ClientUpdate[] {
  const clientUpdates: ClientUpdate[] = [];

  if (update.type === 'error') {
    clientUpdates.push({
      type: 'error',
      message: update.message ?? 'Unknown error',
    });
  }

  if (update.windows && update.windows.length > 0) {
    clientUpdates.push({
      type: 'window',
      windows: update.windows,
    });
  }

  if (update.content) {
    for (const content of update.content) {
      // Handle graphics window draw operations
      if (content.draw) {
        clientUpdates.push({
          type: 'content',
          windowId: content.id,
          clear: content.clear ?? false,
          content: processDrawOperations(content.draw, resolveImageUrl),
        });
      } else if (content.lines) {
        // Handle grid window lines format
        clientUpdates.push({
          type: 'content',
          windowId: content.id,
          clear: content.clear ?? false,
          content: processGridLines(content.lines, resolveImageUrl),
        });
      } else if (content.text) {
        // Handle buffer window content - may be paragraph format or legacy format
        clientUpdates.push({
          type: 'content',
          windowId: content.id,
          clear: content.clear ?? false,
          content: processBufferText(content.text, resolveImageUrl),
        });
      } else {
        // Empty content update (clear only)
        clientUpdates.push({
          type: 'content',
          windowId: content.id,
          clear: content.clear ?? false,
          content: [],
        });
      }
    }
  }

  if (update.input) {
    for (const input of update.input) {
      clientUpdates.push({
        type: 'input-request',
        windowId: input.id,
        inputType: input.type,
        maxLength: input.maxlen,
        initial: input.initial,
        mouse: input.mouse,
        hyperlink: input.hyperlink,
        xpos: input.xpos,
        ypos: input.ypos,
      });
    }
  }

  // Handle timer field (present when timer state changes)
  if (update.timer !== undefined) {
    clientUpdates.push({
      type: 'timer',
      interval: update.timer,
    });
  }

  return clientUpdates;
}

function processContentSpan(
  span: ContentSpan,
  resolveImageUrl: (imageNum: number) => string | undefined
): ProcessedContentSpan | null {
  if (typeof span === 'string') {
    return { type: 'text', text: span };
  }
  if ('text' in span) {
    return {
      type: 'text',
      text: span.text,
      style: span.style,
      hyperlink: span.hyperlink,
    };
  }
  if ('special' in span) {
    const special = span.special;
    if (special.type === 'image' && special.image !== undefined) {
      return {
        type: 'image',
        imageNumber: special.image,
        imageUrl: resolveImageUrl(special.image) ?? special.url,
        alignment: typeof special.alignment === 'number'
          ? IMAGE_ALIGNMENT_VALUES[special.alignment]
          : special.alignment,
        width: special.width,
        height: special.height,
        alttext: special.alttext,
      };
    }
    if (special.type === 'flowbreak') {
      return { type: 'flowbreak' };
    }
  }
  return null;
}

function processContentSpans(
  spans: ContentSpan[],
  resolveImageUrl: (imageNum: number) => string | undefined
): ProcessedContentSpan[] {
  return spans
    .map((span) => processContentSpan(span, resolveImageUrl))
    .filter((span): span is ProcessedContentSpan => span !== null);
}

function processDrawOperation(
  draw: DrawOperation,
  resolveImageUrl: (imageNum: number) => string | undefined
): ProcessedContentSpan | null {
  switch (draw.special) {
    case 'image':
      if (draw.image !== undefined) {
        return {
          type: 'image',
          imageNumber: draw.image,
          imageUrl: resolveImageUrl(draw.image) ?? draw.url,
          width: draw.width,
          height: draw.height,
          x: draw.x,
          y: draw.y,
        };
      }
      return null;
    case 'fill':
      return {
        type: 'fill',
        color: draw.color,
        x: draw.x,
        y: draw.y,
        width: draw.width,
        height: draw.height,
      };
    case 'setcolor':
      return {
        type: 'setcolor',
        color: draw.color,
      };
    default:
      return null;
  }
}

/**
 * Process graphics window draw operations (GlkOte spec format)
 */
function processDrawOperations(
  draws: DrawOperation[],
  resolveImageUrl: (imageNum: number) => string | undefined
): ProcessedContentSpan[] {
  return draws
    .map((draw) => processDrawOperation(draw, resolveImageUrl))
    .filter((span): span is ProcessedContentSpan => span !== null);
}

/**
 * Process buffer window paragraphs (GlkOte spec format)
 */
function processBufferText(
  paragraphs: TextParagraph[],
  resolveImageUrl: (imageNum: number) => string | undefined
): ProcessedContentSpan[] {
  // Defensive check - ensure we have an array
  if (!Array.isArray(paragraphs)) {
    console.warn('processBufferText: expected array, got', typeof paragraphs, paragraphs);
    // Handle legacy string format
    if (typeof paragraphs === 'string') {
      return [{ type: 'text', text: paragraphs }];
    }
    return [];
  }
  return paragraphs.flatMap((para): ProcessedContentSpan[] => {
    const spans: ProcessedContentSpan[] = [];
    if (para.flowbreak) {
      spans.push({ type: 'flowbreak' });
    }
    if (para.content) {
      spans.push(...processContentSpans(para.content, resolveImageUrl));
    }
    return spans;
  });
}

/**
 * Process grid window lines (GlkOte spec format)
 */
function processGridLines(
  lines: GridLine[],
  resolveImageUrl: (imageNum: number) => string | undefined
): ProcessedContentSpan[] {
  return lines.flatMap((line) =>
    line.content ? processContentSpans(line.content, resolveImageUrl) : []
  );
}
