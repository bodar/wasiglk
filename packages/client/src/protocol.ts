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

/** Display metrics for RemGlk protocol window layout. */
export interface Metrics {
  // Overall dimensions
  width: number;
  height: number;
  // Generic character dimensions (deprecated, use grid/buffer-specific)
  charwidth?: number;
  charheight?: number;
  // Outer/inner spacing
  outspacingx?: number;
  outspacingy?: number;
  inspacingx?: number;
  inspacingy?: number;
  // Grid window character dimensions and margins
  gridcharwidth?: number;
  gridcharheight?: number;
  gridmarginx?: number;
  gridmarginy?: number;
  // Buffer window character dimensions and margins
  buffercharwidth?: number;
  buffercharheight?: number;
  buffermarginx?: number;
  buffermarginy?: number;
  // Graphics window margins
  graphicsmarginx?: number;
  graphicsmarginy?: number;
}

// Special input request for file dialogs (GlkOte spec)
export interface SpecialInput {
  type: 'fileref_prompt';
  filemode: 'read' | 'write' | 'readwrite' | 'writeappend';
  filetype: 'save' | 'data' | 'transcript' | 'command';
  gameid?: string;
}

// Output updates (interpreter -> client)
export interface RemGlkUpdate {
  type: 'update' | 'error';
  gen: number;
  windows?: WindowUpdate[];
  content?: ContentUpdate[];
  input?: InputRequest[];
  specialinput?: SpecialInput;  // File dialog request (GlkOte spec)
  timer?: number | null;  // Timer interval in ms, or null to cancel
  disable?: boolean;  // true when no input is expected (game is processing)
  exit?: boolean;  // true when game has exited
  debugoutput?: string[];  // Debug messages from the interpreter (per GlkOte spec)
  message?: string;
}

/** Window layout update from the interpreter. */
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

/** Image alignment in buffer windows. */
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
  terminators?: string[];  // line input terminators (e.g., ["escape", "func1"])
}
