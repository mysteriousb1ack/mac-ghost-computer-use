import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRunner } from './tools.mjs';
import { tools } from './tool-schemas.mjs';

const manifest = JSON.parse(await readFile(new URL('../plugin.json', import.meta.url), 'utf8'));
const versions = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const maxInput = 1024 * 1024;
const invalid = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
const ok = (id, result) => ({ jsonrpc: '2.0', id, result });
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

function toolError(code, message, focusAudit) {
  return {
    isError: true,
    content: [{
      type: 'text',
      text: JSON.stringify({ ok: false, error: { code, message }, focusAudit }),
    }],
  };
}

function session(runner, { maxBatchItems = 32, maxBatchBytes = 8 * 1024 * 1024, maxBatchMs = 30000 }) {
  let phase = 'new', version;

  async function handle(msg, deadline) {
    if (!object(msg) || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string' ||
        (Object.hasOwn(msg, 'id') && !(typeof msg.id === 'string' || Number.isSafeInteger(msg.id)))) {
      return invalid(null, -32600, 'Invalid JSON-RPC request.');
    }
    const { id, method, params = {} } = msg;
    if (id === undefined) {
      if (method === 'notifications/initialized' && phase === 'initializing') phase = 'ready';
      return;
    }
    if (!object(params)) return invalid(id, -32602, 'Expected an object for params.');
    if (method === 'ping') return ok(id, {});
    if (method === 'initialize') {
      if (phase !== 'new') return invalid(id, -32600, 'Already initialized.');
      if (typeof params.protocolVersion !== 'string' || !object(params.capabilities) || !object(params.clientInfo) ||
          typeof params.clientInfo.name !== 'string' || typeof params.clientInfo.version !== 'string') {
        return invalid(id, -32602, 'Provide protocolVersion, capabilities and clientInfo.');
      }
      version = versions.includes(params.protocolVersion) ? params.protocolVersion : versions[0];
      phase = 'initializing';
      return ok(id, {
        protocolVersion: version,
        capabilities: { tools: {} },
        serverInfo: { name: manifest.name, version: manifest.version },
      });
    }

    if (phase !== 'ready') return invalid(id, -32002, 'Initialize the session and send notifications/initialized.');
    if (method === 'tools/list') return ok(id, { tools });
    if (method !== 'tools/call') return invalid(id, -32601, 'Method not found.');
    if (!tools.some(t => t.name === params.name) || (Object.hasOwn(params, 'arguments') && !object(params.arguments))) {
      return invalid(id, -32602, 'Unknown tool or invalid arguments object.');
    }
    try {
      return ok(id, await runner(params.name, params.arguments ?? {}, deadline));
    } catch (error) {
      const auditFailed = error?.code === 'AUDIT_UNAVAILABLE';
      return ok(id, toolError(
        auditFailed ? 'AUDIT_UNAVAILABLE' : 'TOOL_FAILED',
        auditFailed
          ? 'Audit storage failed. Inspect target state before retrying.'
          : 'Local tool operation failed.',
        error?.focusAudit,
      ));
    }
  }

  return async value => {
    if (!Array.isArray(value)) return handle(value);
    if (version !== '2025-03-26' || phase !== 'ready' || !value.length) {
      return invalid(null, -32600, 'Batch unavailable in this session.');
    }
    if (value.length > maxBatchItems) return invalid(null, -32600, 'Batch item limit exceeded.');
    const deadline = performance.now() + maxBatchMs;
    const replies = [];
    // Reserve space for one bounded error per remaining request, including long string IDs.
    const errors = value.map(msg => object(msg) && msg.jsonrpc === '2.0' &&
      typeof msg.method === 'string' && !Object.hasOwn(msg, 'id') ? undefined :
      invalid(typeof msg?.id === 'string' || Number.isSafeInteger(msg?.id) ? msg.id : null,
        -32000, 'Batch limit reached. Inspect state before retrying.'));
    const size = reply => reply === undefined ? 0 : Buffer.byteLength(JSON.stringify(reply)) + 1;
    let bytes = 2 + errors.reduce((sum, reply) => sum + size(reply), 0);
    if (bytes > maxBatchBytes) return invalid(null, -32600, 'Batch response budget exceeded.');
    let stopped = false;
    for (const [index, msg] of value.entries()) {
      const fallback = errors[index];
      let reply = fallback;
      const ms = Math.floor(deadline - performance.now());
      if (!stopped && ms > 0) {
        let timer;
        try {
          reply = await Promise.race([handle(msg, deadline), new Promise(resolve => {
            timer = setTimeout(() => { stopped = true; resolve(fallback); }, ms);
          })]);
        } finally { clearTimeout(timer); }
        bytes += size(reply) - size(fallback);
        if (bytes > maxBatchBytes || performance.now() >= deadline) {
          stopped = true;
          reply = fallback;
        }
      }
      if (reply !== undefined) replies.push(reply);
    }
    return replies.length ? replies : undefined;
  };
}

// Read a line once even when split into individual bytes; count framed bodies in bytes.
async function* readMessages(stream) {
  let pieces = [], length = 0, headers = null, headerBytes = 0, remaining = 0;
  const bad = (framed, fatal = false) => ({ bad: true, framed, fatal });

  function take() {
    const data = pieces.length === 1 ? pieces[0] : Buffer.concat(pieces, length);
    pieces = [];
    length = 0;
    return data;
  }

  for await (const chunk of stream) {
    let start = 0;
    while (start < chunk.length) {
      if (remaining) {
        const n = Math.min(remaining, chunk.length - start);
        pieces.push(chunk.subarray(start, start + n));
        length += n;
        remaining -= n;
        start += n;
        if (remaining === 0) yield { body: take(), framed: true };
        continue;
      }

      const newline = chunk.indexOf(10, start);
      const end = newline < 0 ? chunk.length : newline;
      if (end > start) {
        pieces.push(chunk.subarray(start, end));
        length += end - start;
      }
      if (length > (headers ? 8192 : maxInput)) {
        yield bad(headers !== null, true);
        return;
      }
      if (newline < 0) break;
      start = newline + 1;

      const line = take();
      if (!headers && !/^(?:Content-Length|Content-Type):/i.test(line.toString('ascii', 0, 16))) {
        if (line.toString('utf8').trim()) yield { body: line, framed: false };
        continue;
      }

      headers ??= new Map();
      const header = line.toString('ascii').trim();
      headerBytes += line.length + 1;
      if (headerBytes > 8192) {
        yield bad(true, true);
        return;
      }
      if (header.length) {
        const match = /^([A-Za-z-]+):\s*(.+)$/.exec(header);
        if (!match || headers.has(match[1].toLowerCase())) {
          yield bad(true, true);
          return;
        }
        headers.set(match[1].toLowerCase(), match[2]);
      } else {
        const n = headers.get('content-length') ?? '';
        if (!/^[1-9]\d*$/.test(n) || Number(n) > maxInput) {
          yield bad(true, true);
          return;
        }
        remaining = Number(n);
        headers = null;
        headerBytes = 0;
      }
    }
  }
  if (remaining || headers) yield bad(true);
  else if (length) yield { body: take(), framed: false };
}

export async function serve({ input = process.stdin, output = process.stdout, ...config } = {}) {
  const runner = createRunner(config);
  const dispatch = session(runner, config);
  try {
    for await (const frame of readMessages(input)) {
      let reply;
      if (frame.bad) {
        reply = invalid(null, -32700, 'Invalid or truncated frame.');
      } else {
        let message;
        try {
          message = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(frame.body));
        } catch {
          reply = invalid(null, -32700, 'Invalid JSON or UTF-8.');
        }
        if (!reply) reply = await dispatch(message);
      }

      if (reply !== undefined) {
        const payload = Buffer.from(JSON.stringify(reply));
        const packet = frame.framed
          ? Buffer.concat([Buffer.from('Content-Length: ' + payload.length + '\r\n\r\n'), payload])
          : Buffer.concat([payload, Buffer.from('\n')]);
        await new Promise((resolveWrite, reject) => {
          output.write(packet, err => err ? reject(err) : resolveWrite());
        });
      }
      if (frame.fatal) return;
    }
  } finally {
    runner.close?.();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await serve(); }
  catch { process.exitCode = 1; }
}
