/**
 * @module
 *
 * TypeScript client library for running Interactive Fiction interpreters
 * compiled to WebAssembly with Zig. Run classic text adventures in the
 * browser via Web Workers, WASM and JSPI.
 *
 * ## Supported Interpreters
 *
 * | Interpreter | Format | Extensions |
 * |---|---|---|
 * | Glulxe | Glulx | .ulx, .gblorb |
 * | Fizmo | Z-machine (v1-5, 7, 8) | .z1-.z8, .zblorb |
 * | Git | Glulx | .ulx, .gblorb |
 * | Hugo | Hugo | .hex |
 * | TADS 2 | TADS 2 | .gam |
 * | TADS 3 | TADS 3 | .t3 |
 * | Alan 2 | Alan 2 | .acd |
 * | Alan 3 | Alan 3 | .a3c |
 * | Scare | ADRIFT | .taf |
 * | Agility | AGT | .agx |
 * | AdvSys | AdvSys | .dat |
 * | Level 9 | Level 9 | .l9, .sna |
 * | Magnetic | Magnetic Scrolls | .mag |
 * | Scott | Scott Adams | .saga |
 * | Plus | Scott Adams Plus | .sagaplus |
 * | Taylor | Adventure Int'l UK | .taylor |
 * | JACL | JACL | .j2 |
 *
 * The correct interpreter is selected automatically from the file extension
 * or Blorb contents.
 *
 * @example
 * ```typescript
 * import { createClient } from '@bodar/wasiglk';
 *
 * const client = await createClient({
 *   storyUrl: '/stories/adventure.gblorb',
 *   workerUrl: '/worker.js',
 * });
 *
 * for await (const update of client.updates()) {
 *   if (update.content) {
 *     for (const content of update.content) {
 *       for (const para of content.text ?? []) {
 *         for (const span of para.content ?? []) {
 *           if (typeof span === 'string') process.stdout.write(span);
 *           else if ('text' in span) process.stdout.write(span.text);
 *         }
 *       }
 *     }
 *   }
 * }
 * ```
 */

// Main client API
export { WasiGlkClient, createClient } from './client';
export type { ClientConfig, UpdatesConfig } from './client';

// Protocol types (raw RemGlk protocol)
export type {
  RemGlkUpdate,
  WindowUpdate,
  ContentUpdate,
  TextParagraph,
  GridLine,
  DrawOperation,
  ContentSpan,
  TextSpan,
  SpecialSpan,
  SpecialContent,
  InputRequest,
  SpecialInput,
  ImageAlignment,
  Metrics,
} from './protocol';

export { IMAGE_ALIGNMENT_VALUES } from './protocol';

// Blorb parser
export { BlorbParser } from './blorb';
export type { BlorbImage, BlorbResource } from './blorb';

// Format detection
export { detectFormat, detectFormatFromUrl, detectFormatFromData } from './format';
export type { StoryFormat, FormatInfo } from './format';

// Renderers (optional)
export type { GraphicsRenderer } from './renderers/types';
export { colorToCSS } from './renderers/types';
export { SvgRenderer } from './renderers/svg';

// Worker message types (for advanced use cases)
export type {
  MainToWorkerMessage,
  WorkerToMainMessage,
  FilesystemMode,
} from './worker/messages';
