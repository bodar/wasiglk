/**
 * Memory Storage Provider
 *
 * In-memory file storage with no persistence.
 * Files exist only for the duration of the session.
 */

import type { Inode } from '@bjorn3/browser_wasi_shim';
import { READ_ONLY_FILES, type StorageProvider, type StorageConfig, type FilePromptMetadata, type FilePromptResult } from './types';
import { generateFilename } from './filename-generator';

export class MemoryProvider implements StorageProvider {
  private readonly storyId: string;
  private rootContents: Map<string, Inode> = new Map();

  constructor(config: StorageConfig) {
    this.storyId = config.storyId;
  }

  async initialize(): Promise<Map<string, Inode>> {
    console.log(`[memory] Initialized in-memory storage for story ${this.storyId}`);
    // Start with empty map - no persistence
    this.rootContents = new Map();
    return this.rootContents;
  }

  async createFile(path: string): Promise<void> {
    // Memory provider doesn't need to do anything special
    // Files are created on-demand by browser_wasi_shim
    console.log(`[memory] File will be created in-memory: ${path}`);
  }

  async handlePrompt(metadata: FilePromptMetadata): Promise<FilePromptResult> {
    // Auto-generate a deterministic filename
    const filename = generateFilename(metadata.filetype);
    console.log(`[memory] Auto-generated filename for ${metadata.filetype}: ${filename}`);
    return { filename };
  }

  shouldPersist(path: string): boolean {
    const filename = path.split('/').pop() ?? path;
    // Only /var paths reach here; read-only game files live in /sys (see
    // READ_ONLY_FILES). Memory mode tracks files but never persists them.
    return !READ_ONLY_FILES.has(filename);
  }

  close(): void {
    console.log('[memory] Closed (no cleanup needed)');
  }
}
