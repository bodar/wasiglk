/**
 * Development server for the example
 */

import { join, dirname } from 'path';

const PORT = 3000;
const EXAMPLE_DIR = dirname(new URL(import.meta.url).pathname);
const ROOT_DIR = join(EXAMPLE_DIR, '../..');

// File locations
const paths: Record<string, string> = {
  '/': join(EXAMPLE_DIR, 'public/index.html'),
  '/index.html': join(EXAMPLE_DIR, 'public/index.html'),
  '/advent.ulx': join(ROOT_DIR, 'tests/advent.ulx'),
  '/glulxe.wasm': join(ROOT_DIR, 'packages/server/zig-out/bin/glulxe.wasm'),
};

// MIME types
const mimeTypes: Record<string, string> = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.ts': 'application/javascript',
  '.wasm': 'application/wasm',
  '.ulx': 'application/octet-stream',
  '.css': 'text/css',
  '.json': 'application/json',
};

function getMimeType(path: string): string {
  const ext = path.substring(path.lastIndexOf('.'));
  return mimeTypes[ext] || 'application/octet-stream';
}

void Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    let path = url.pathname;

    const headers = new Headers();

    // Check static paths
    if (paths[path]) {
      const file = Bun.file(paths[path]);
      if (await file.exists()) {
        headers.set('Content-Type', getMimeType(paths[path]));
        return new Response(file, { headers });
      }
    }

    // Serve main.ts transpiled
    if (path === '/main.js') {
      try {
        const result = await Bun.build({
          entrypoints: [join(EXAMPLE_DIR, 'src/main.ts')],
          target: 'browser',
          format: 'esm',
        });
        if (result.outputs.length > 0) {
          headers.set('Content-Type', 'application/javascript');
          return new Response(await result.outputs[0].text(), { headers });
        }
      } catch (e) {
        console.error('Build error:', e);
        return new Response(`Build error: ${e}`, { status: 500 });
      }
    }

    // Serve worker - inline build
    if (path === '/worker.js') {
      try {
        const result = await Bun.build({
          entrypoints: [join(ROOT_DIR, 'packages/client/src/worker/worker.ts')],
          target: 'browser',
          format: 'esm',
        });
        if (result.outputs.length > 0) {
          headers.set('Content-Type', 'application/javascript');
          return new Response(await result.outputs[0].text(), { headers });
        }
      } catch (e) {
        console.error('Worker build error:', e);
        return new Response(`Worker build error: ${e}`, { status: 500 });
      }
    }

    return new Response('Not found', { status: 404 });
  },
});

console.log(`Server running at http://localhost:${PORT}`);
console.log('Press Ctrl+C to stop');
