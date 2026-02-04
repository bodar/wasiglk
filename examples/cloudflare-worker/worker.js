/**
 * Cloudflare Worker for running Interactive Fiction interpreters
 *
 * This worker uses WASI to run IF interpreters compiled with Zig.
 * The interpreters communicate via stdin/stdout using a JSON protocol
 * compatible with RemGlk/GlkOte.
 *
 * Usage:
 * POST /play - Start a new game session
 * POST /input - Send input to an existing session
 *
 * Request body format:
 * {
 *   "sessionId": "...",  // Optional for /play, required for /input
 *   "interpreter": "glulxe" | "git" | "hugo" | "bocfel" | "scare",
 *   "storyfile": "base64-encoded storyfile", // Only for /play
 *   "input": "user input text"  // Only for /input
 * }
 */

import { WASI } from '@cloudflare/workers-wasi';

// Import WASM modules (these would be the compiled interpreters)
// import glulxeWasm from './glulxe.wasm';
// import gitWasm from './git.wasm';
// etc.

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // CORS headers for browser access
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    };

    // Handle preflight requests
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }

    // Health check endpoint
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({ status: 'ok' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Info endpoint
    if (url.pathname === '/info') {
      return new Response(JSON.stringify({
        name: 'emglken-wasi',
        version: '0.1.0',
        interpreters: ['glulxe', 'git', 'hugo', 'bocfel', 'scare'],
        description: 'Interactive Fiction interpreters running on WASI'
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    // Main game endpoints
    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405, headers: corsHeaders });
    }

    try {
      const body = await request.json();

      if (url.pathname === '/play') {
        return await handlePlay(body, env, corsHeaders);
      } else if (url.pathname === '/input') {
        return await handleInput(body, env, corsHeaders);
      }

      return new Response('Not found', { status: 404, headers: corsHeaders });
    } catch (error) {
      return new Response(JSON.stringify({ error: error.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }
  }
};

/**
 * Start a new game session
 */
async function handlePlay(body, env, corsHeaders) {
  const { interpreter, storyfile } = body;

  if (!interpreter || !storyfile) {
    return new Response(JSON.stringify({ error: 'Missing interpreter or storyfile' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }

  // Decode the storyfile
  const storyfileBytes = Uint8Array.from(atob(storyfile), c => c.charCodeAt(0));

  // Generate a session ID
  const sessionId = crypto.randomUUID();

  // Get the appropriate WASM module
  const wasmModule = getInterpreterModule(interpreter);
  if (!wasmModule) {
    return new Response(JSON.stringify({ error: `Unknown interpreter: ${interpreter}` }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }

  // Create WASI instance with the storyfile in the virtual filesystem
  const wasi = new WASI({
    args: [interpreter, '/game/story'],
    env: {},
    preopens: {
      '/game': createVirtualFS(storyfileBytes)
    }
  });

  // Instantiate the WASM module
  const instance = new WebAssembly.Instance(wasmModule, {
    wasi_snapshot_preview1: wasi.wasiImport
  });

  // Collect output
  let output = '';
  const originalWrite = wasi.wasiImport.fd_write;
  wasi.wasiImport.fd_write = (fd, iovs, iovsLen, nwritten) => {
    // Capture stdout (fd 1)
    if (fd === 1) {
      // Read the output from memory and collect it
      // This is a simplified version - real implementation needs proper iovec handling
    }
    return originalWrite.call(wasi, fd, iovs, iovsLen, nwritten);
  };

  // Start the interpreter
  await wasi.start(instance);

  // Store session state (in production, use KV or Durable Objects)
  // await env.SESSIONS.put(sessionId, JSON.stringify({ interpreter, state: ... }));

  return new Response(JSON.stringify({
    sessionId,
    output: output,
    status: 'started'
  }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

/**
 * Send input to an existing game session
 */
async function handleInput(body, env, corsHeaders) {
  const { sessionId, input } = body;

  if (!sessionId || input === undefined) {
    return new Response(JSON.stringify({ error: 'Missing sessionId or input' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });
  }

  // Retrieve session state (in production, use KV or Durable Objects)
  // const session = await env.SESSIONS.get(sessionId);

  // For a real implementation, you would:
  // 1. Resume the WASI instance with the saved state
  // 2. Provide the input via stdin
  // 3. Collect the output
  // 4. Save the new state

  return new Response(JSON.stringify({
    sessionId,
    output: 'Response placeholder - implement session resumption',
    status: 'ok'
  }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

/**
 * Get the WASM module for the specified interpreter
 */
function getInterpreterModule(interpreter) {
  // In production, these would be actual imported WASM modules
  const modules = {
    // 'glulxe': glulxeWasm,
    // 'git': gitWasm,
    // 'hugo': hugoWasm,
    // 'bocfel': bocfelWasm,
    // 'scare': scareWasm,
  };
  return modules[interpreter];
}

/**
 * Create a virtual filesystem with the storyfile
 */
function createVirtualFS(storyfileBytes) {
  // This is a placeholder - the actual implementation depends on
  // how @cloudflare/workers-wasi handles preopens
  return {
    'story': storyfileBytes
  };
}
