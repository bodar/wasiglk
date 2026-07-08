/**
 * Story Format Detection
 *
 * Detects the story format from URL extension or file magic numbers.
 */

/** Supported Interactive Fiction story formats. */
export type StoryFormat =
  | 'glulx'
  | 'zcode'
  | 'hugo'
  | 'tads2'
  | 'tads3'
  | 'alan2'
  | 'alan3'
  | 'adrift'
  | 'agt'
  | 'advsys'
  | 'level9'
  | 'magnetic'
  | 'scott'
  | 'taylor'
  | 'sagaplus'
  | 'unknown';

/** Detected format with interpreter name and Blorb status. */
export interface FormatInfo {
  format: StoryFormat;
  interpreter: string;
  isBlorb: boolean;
}

const EXTENSION_MAP: Record<string, FormatInfo> = {
  // Glulx
  '.ulx': { format: 'glulx', interpreter: 'glulxe', isBlorb: false },
  '.gblorb': { format: 'glulx', interpreter: 'glulxe', isBlorb: true },
  '.blb': { format: 'glulx', interpreter: 'glulxe', isBlorb: true },

  // Z-machine
  '.z1': { format: 'zcode', interpreter: 'fizmo', isBlorb: false },
  '.z2': { format: 'zcode', interpreter: 'fizmo', isBlorb: false },
  '.z3': { format: 'zcode', interpreter: 'fizmo', isBlorb: false },
  '.z4': { format: 'zcode', interpreter: 'fizmo', isBlorb: false },
  '.z5': { format: 'zcode', interpreter: 'fizmo', isBlorb: false },
  '.z6': { format: 'zcode', interpreter: 'fizmo', isBlorb: false },
  '.z7': { format: 'zcode', interpreter: 'fizmo', isBlorb: false },
  '.z8': { format: 'zcode', interpreter: 'fizmo', isBlorb: false },
  '.zblorb': { format: 'zcode', interpreter: 'fizmo', isBlorb: true },

  // Hugo
  '.hex': { format: 'hugo', interpreter: 'hugo', isBlorb: false },

  // TADS
  '.gam': { format: 'tads2', interpreter: 'tads2', isBlorb: false },
  '.t3': { format: 'tads3', interpreter: 'tads3', isBlorb: false },

  // Alan
  '.acd': { format: 'alan3', interpreter: 'alan3', isBlorb: false },
  '.a3c': { format: 'alan3', interpreter: 'alan3', isBlorb: false },

  // ADRIFT
  '.taf': { format: 'adrift', interpreter: 'scare', isBlorb: false },

  // AGT
  '.agx': { format: 'agt', interpreter: 'agility', isBlorb: false },

  // AdvSys
  '.dat': { format: 'advsys', interpreter: 'advsys', isBlorb: false },

  // Level 9
  '.l9': { format: 'level9', interpreter: 'level9', isBlorb: false },
  '.sna': { format: 'level9', interpreter: 'level9', isBlorb: false },

  // Magnetic Scrolls
  '.mag': { format: 'magnetic', interpreter: 'magnetic', isBlorb: false },

  // Scott Adams
  '.saga': { format: 'scott', interpreter: 'scott', isBlorb: false },
  '.sagaplus': { format: 'sagaplus', interpreter: 'plus', isBlorb: false },

  // Adventure International UK (later titles)
  '.taylor': { format: 'taylor', interpreter: 'taylor', isBlorb: false },
};

// Magic number signatures (first 4-16 bytes)
const MAGIC_SIGNATURES: Array<{
  bytes: number[];
  offset: number;
  format: StoryFormat;
  interpreter: string;
}> = [
  // Glulx: 'Glul'
  {
    bytes: [0x47, 0x6c, 0x75, 0x6c],
    offset: 0,
    format: 'glulx',
    interpreter: 'glulxe',
  },
  // Z-machine versions (first byte indicates version)
  { bytes: [0x01], offset: 0, format: 'zcode', interpreter: 'fizmo' },
  { bytes: [0x02], offset: 0, format: 'zcode', interpreter: 'fizmo' },
  { bytes: [0x03], offset: 0, format: 'zcode', interpreter: 'fizmo' },
  { bytes: [0x04], offset: 0, format: 'zcode', interpreter: 'fizmo' },
  { bytes: [0x05], offset: 0, format: 'zcode', interpreter: 'fizmo' },
  { bytes: [0x06], offset: 0, format: 'zcode', interpreter: 'fizmo' },
  { bytes: [0x07], offset: 0, format: 'zcode', interpreter: 'fizmo' },
  { bytes: [0x08], offset: 0, format: 'zcode', interpreter: 'fizmo' },
  // Hugo: Look for HUGO signature at a specific offset
  {
    bytes: [0x48, 0x55, 0x47, 0x4f],
    offset: 0,
    format: 'hugo',
    interpreter: 'hugo',
  },
  // TADS2
  {
    bytes: [0x54, 0x41, 0x44, 0x53],
    offset: 0,
    format: 'tads2',
    interpreter: 'tads2',
  },
  // TADS3: T3-image
  {
    bytes: [0x54, 0x33, 0x2d, 0x69],
    offset: 0,
    format: 'tads3',
    interpreter: 'tads3',
  },
  // AGX (AGiliTy): file signature 0x51C1C758, little-endian
  {
    bytes: [0x58, 0xc7, 0xc1, 0x51],
    offset: 0,
    format: 'agt',
    interpreter: 'agility',
  },
];

/**
 * Detect story format from URL (by extension)
 */
export function detectFormatFromUrl(url: string): FormatInfo | null {
  // Extract extension from URL
  const urlObj = new URL(url, 'file://');
  const pathname = urlObj.pathname.toLowerCase();

  for (const [ext, info] of Object.entries(EXTENSION_MAP)) {
    if (pathname.endsWith(ext)) {
      return info;
    }
  }

  // Generic blorb
  if (pathname.endsWith('.blorb')) {
    return { format: 'unknown', interpreter: 'glulxe', isBlorb: true };
  }

  return null;
}

/**
 * Detect story format from file data (by magic numbers)
 */
export function detectFormatFromData(data: Uint8Array): FormatInfo | null {
  // Check for Blorb first
  if (data.length >= 12) {
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const form = view.getUint32(0, false);
    const ifrs = view.getUint32(8, false);

    if (form === 0x464f524d && ifrs === 0x49465253) {
      // FORM + IFRS = Blorb
      // Need to look inside for executable type
      const execInfo = detectBlorbExecutableType(data);
      if (execInfo) {
        return { ...execInfo, isBlorb: true };
      }
      return { format: 'unknown', interpreter: 'glulxe', isBlorb: true };
    }
  }

  // Check magic signatures
  for (const sig of MAGIC_SIGNATURES) {
    if (matchesSignature(data, sig.bytes, sig.offset)) {
      return { format: sig.format, interpreter: sig.interpreter, isBlorb: false };
    }
  }

  return null;
}

/**
 * Detect format from either URL or data
 */
export function detectFormat(
  url: string | null,
  data: Uint8Array
): FormatInfo {
  // Try URL first
  if (url) {
    const fromUrl = detectFormatFromUrl(url);
    if (fromUrl) return fromUrl;
  }

  // Try data
  const fromData = detectFormatFromData(data);
  if (fromData) return fromData;

  // Default to Glulx
  return { format: 'unknown', interpreter: 'glulxe', isBlorb: false };
}

function matchesSignature(
  data: Uint8Array,
  signature: number[],
  offset: number
): boolean {
  if (data.length < offset + signature.length) return false;
  for (let i = 0; i < signature.length; i++) {
    if (data[offset + i] !== signature[i]) return false;
  }
  return true;
}

function detectBlorbExecutableType(
  data: Uint8Array
): { format: StoryFormat; interpreter: string } | null {
  // Parse Blorb to find Exec chunk type
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  let pos = 12;
  const totalLength = Math.min(view.getUint32(4, false) + 8, data.length);

  while (pos < totalLength) {
    if (pos + 8 > data.length) break;

    const chunkType = view.getUint32(pos, false);
    const chunkLen = view.getUint32(pos + 4, false);

    // Check for GLUL or ZCOD
    if (chunkType === 0x474c554c) {
      // GLUL
      return { format: 'glulx', interpreter: 'glulxe' };
    }
    if (chunkType === 0x5a434f44) {
      // ZCOD
      return { format: 'zcode', interpreter: 'fizmo' };
    }

    pos = pos + 8 + chunkLen;
    if (pos & 1) pos++;
  }

  return null;
}
