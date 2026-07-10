/**
 * OPFS Storage Provider
 *
 * Origin Private File System storage for persistent files.
 * Files survive page reloads and browser restarts.
 */

import { SyncOPFSFile, Directory, type Inode } from '@bjorn3/browser_wasi_shim';
import { READ_ONLY_FILES, type StorageProvider, type StorageConfig, type FilePromptMetadata, type FilePromptResult } from './types';
import { generateFilename } from './filename-generator';

/**
 * OPFS-based storage provider.
 *
 * Directory structure: /wasiglk/[storyId]/
 * Mirrors the WASI filesystem structure.
 */
export class OpfsProvider implements StorageProvider {
  private rootDir: FileSystemDirectoryHandle | null = null;
  private readonly storyId: string;
  private readonly openHandles: FileSystemSyncAccessHandle[] = [];
  private rootContents: Map<string, Inode> = new Map();

  constructor(config: StorageConfig) {
    this.storyId = config.storyId;
  }

  /**
   * Check if OPFS is available in this environment.
   * Requires secure context (HTTPS or localhost) and Worker context.
   */
  static isAvailable(): boolean {
    return typeof navigator?.storage?.getDirectory === 'function';
  }

  /**
   * Check if a path should be persisted to OPFS. Only /var paths reach here;
   * read-only game files live in /sys and never do (see READ_ONLY_FILES).
   */
  shouldPersist(path: string): boolean {
    const filename = path.split('/').pop() ?? path;
    return !READ_ONLY_FILES.has(filename);
  }

  async initialize(): Promise<Map<string, Inode>> {
    this.rootContents = new Map();

    try {
      // Get OPFS root
      const opfsRoot = await navigator.storage.getDirectory();

      // Create directory structure: /wasiglk/[gameName]/[versionHash]/var/
      // storyId is hierarchical like "advent/a3f2b1c8"
      // Files go in /var/ to mirror WASI structure and avoid conflicts with /home/
      let dir = await opfsRoot.getDirectoryHandle('wasiglk', { create: true });
      for (const segment of this.storyId.split('/')) {
        dir = await dir.getDirectoryHandle(segment, { create: true });
      }
      this.rootDir = await dir.getDirectoryHandle('var', { create: true });

      // Recursively load all files from OPFS
      await this.loadDirectory(this.rootDir, this.rootContents, '');

      const fileCount = this.openHandles.length;
      console.log(`[opfs] Loaded ${fileCount} existing files for story ${this.storyId}`);
      console.log(`[opfs] Root contents:`, [...this.rootContents.keys()]);
    } catch (err) {
      console.error('[opfs] Initialization failed:', err);
      throw err;
    }

    return this.rootContents;
  }

  /**
   * Recursively load files from an OPFS directory into a Map.
   */
  private async loadDirectory(
    dirHandle: FileSystemDirectoryHandle,
    contents: Map<string, Inode>,
    pathPrefix: string,
  ): Promise<void> {
    for await (const [name, handle] of dirHandle.entries()) {
      const fullPath = pathPrefix ? `${pathPrefix}/${name}` : name;
      if (handle.kind === 'file') {
        try {
          const fileHandle = handle as FileSystemFileHandle;
          const syncHandle = await fileHandle.createSyncAccessHandle();
          this.openHandles.push(syncHandle);
          contents.set(name, new SyncOPFSFile(syncHandle));
          console.log(`[opfs] Loaded file: ${fullPath}`);
        } catch (err) {
          console.warn(`[opfs] Failed to open existing file ${fullPath}:`, err);
        }
      } else if (handle.kind === 'directory') {
        // Recursively load subdirectory
        const subDirHandle = handle as FileSystemDirectoryHandle;
        const subContents = new Map<string, Inode>();
        await this.loadDirectory(subDirHandle, subContents, fullPath);
        contents.set(name, new Directory(subContents));
        console.log(`[opfs] Loaded directory: ${fullPath} with ${subContents.size} entries`);
      }
    }
  }

  async createFile(path: string): Promise<void> {
    if (!this.rootDir) {
      throw new Error('OpfsProvider not initialized');
    }

    // Check if file already exists
    if (this.findFile(path)) {
      console.log(`[opfs] File already exists: ${path}`);
      return;
    }

    const syncHandle = await this.createFileHandle(path);
    const opfsFile = new SyncOPFSFile(syncHandle);
    this.addFileToTree(path, opfsFile);
    console.log(`[opfs] Created persistent file: ${path}`);
  }

  /**
   * Create a file handle in OPFS.
   * Supports nested paths like "saves/game.sav".
   */
  private async createFileHandle(path: string): Promise<FileSystemSyncAccessHandle> {
    if (!this.rootDir) {
      throw new Error('OpfsProvider not initialized');
    }

    // Parse path into directory components and filename
    const parts = path.split('/').filter(p => p.length > 0);
    const filename = parts.pop();
    if (!filename) {
      throw new Error(`Invalid path: ${path}`);
    }

    // Navigate/create directories as needed
    let currentDir = this.rootDir;
    for (const dirName of parts) {
      currentDir = await currentDir.getDirectoryHandle(dirName, { create: true });
    }

    // Create the file
    const fileHandle = await currentDir.getFileHandle(filename, { create: true });
    const syncHandle = await fileHandle.createSyncAccessHandle();
    this.openHandles.push(syncHandle);
    return syncHandle;
  }

  async handlePrompt(metadata: FilePromptMetadata): Promise<FilePromptResult> {
    // Auto-generate a deterministic filename (no dialog in OPFS mode)
    const filename = generateFilename(metadata.filetype);
    console.log(`[opfs] Auto-generated filename for ${metadata.filetype}: ${filename}`);
    return { filename: `var/${filename}` };
  }

  /**
   * Find a file in the root contents by path.
   */
  private findFile(path: string): Inode | null {
    const parts = path.split('/').filter(p => p.length > 0);
    let current: Inode | Map<string, Inode> = this.rootContents;

    for (const part of parts) {
      if (current instanceof Map) {
        const entry: Inode | undefined = current.get(part);
        if (!entry) return null;
        current = entry;
      } else if (current instanceof Directory) {
        const entry: Inode | undefined = current.contents.get(part);
        if (!entry) return null;
        current = entry;
      } else {
        return null;
      }
    }

    return current instanceof Map ? null : current;
  }

  /**
   * Add a file to the root contents tree.
   */
  private addFileToTree(path: string, file: Inode): void {
    const parts = path.split('/').filter(p => p.length > 0);
    const filename = parts.pop();
    if (!filename) return;

    // Navigate/create directories
    let current = this.rootContents;
    for (const part of parts) {
      let next = current.get(part);
      if (!next) {
        next = new Directory(new Map());
        current.set(part, next);
      }
      if (!(next instanceof Directory)) {
        console.error(`[opfs] Path component ${part} is not a directory`);
        return;
      }
      current = next.contents;
    }

    current.set(filename, file);
  }

  close(): void {
    for (const handle of this.openHandles) {
      try {
        handle.close();
      } catch (err) {
        console.warn('[opfs] Failed to close handle:', err);
      }
    }
    this.openHandles.length = 0;
    console.log('[opfs] Closed all file handles');
  }
}
