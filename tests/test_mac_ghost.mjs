import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { crc32, inflateSync } from 'node:zlib';
import { createInterface } from 'node:readline';
import { chmod, copyFile, mkdir, mkdtemp, readFile, writeFile, rm, readdir, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const helper = join(root, 'bin/mac-ghost-helper');
const server = join(root, 'src/mcp-server.mjs');
const mock = join(root, 'tests/mock-helper.mjs');
const names = ['check_permissions', 'list_windows', 'capture_window', 'inspect_ui_tree',
  'ax_press', 'ax_set_value', 'bg_click', 'bg_type_or_scroll', 'find_controls',
  'get_state', 'run_actions', 'type_text', 'press_key', 'paste',
  'perform_secondary_action', 'drag', 'select_text'];
const sample = { windowId: 42, pid: 77, appName: 'Fixture Editor', title: '窗口甲', bundleId: 'example.editor',
  bounds: { x: -20, y: 10, width: 640, height: 480 }, layer: 0, isOnScreen: true };
const init = (version = '2025-11-25') => ({ jsonrpc: '2.0', id: 1, method: 'initialize',
  params: { protocolVersion: version, capabilities: {}, clientInfo: { name: '测试', version: '1' } } });
const ready = { jsonrpc: '2.0', method: 'notifications/initialized' };
const rpc = (id, method, params = {}) => ({ jsonrpc: '2.0', id, method, params });
const call = (id, name, args = {}) => rpc(id, 'tools/call', { name, arguments: args });
const payload = reply => JSON.parse(reply.result.content[0].text);
const errCode = reply => { assert.equal(reply.result.isError, true); return payload(reply).error.code; };
let scratch, permissions;

function command(exe, args, options = {}) {
  const result = spawnSync(exe, args, { cwd: root, encoding: 'utf8', timeout: 180000, ...options });
  assert.ifError(result.error);
  return result;
}
function success(exe, args, options) {
  const r = command(exe, args, options);
  assert.equal(r.status, 0, r.stderr + r.stdout + String(r.signal ?? ''));
  return r.stdout;
}
function native(args, status = 0) {
  const r = command(helper, args);
  assert.equal(r.status, status, r.stdout + r.stderr);
  return JSON.parse(r.stdout);
}
before(async () => {
  scratch = await mkdtemp(join(root, 'tests/.test-'));
  success('/bin/sh', ['build.sh']);
});
after(async () => { if (scratch) await rm(scratch, { recursive: true, force: true }); });

async function context(fixture = {}, options = {}) {
  const dir = await mkdtemp(join(scratch, 'session-'));
  await writeFile(join(dir, 'fixture.json'), JSON.stringify({ windows: [sample], ...fixture }));
  const config = { helper: process.execPath, prefix: [mock, dir], stateDir: dir, timeout: 3000, ...options };
  const source = 'import {serve} from ' + JSON.stringify(pathToFileURL(server).href) +
    '; await serve(' + JSON.stringify(config) + ');';
  return { dir, args: ['--input-type=module', '-e', source] };
}

function encodePacket(object, style) {
  const body = Buffer.from(JSON.stringify(object));
  if (style === 'line') return Buffer.concat([body, Buffer.from('\n')]);
  return Buffer.concat([Buffer.from('Content-Length: ' + body.length + '\r\n\r\n'), body]);
}
function decodePackets(input) {
  let buf = input;
  const replies = [];
  while (buf.length) {
    if (buf.subarray(0, 15).toString('ascii').startsWith('Content-Length:')) {
      const headerEnd = buf.indexOf('\r\n\r\n');
      assert.ok(headerEnd > 0);
      const n = Number(buf.subarray(16, headerEnd).toString());
      assert.ok(n > 0 && n <= buf.length - headerEnd - 4);
      replies.push({ style: 'frame', msg: JSON.parse(buf.subarray(headerEnd + 4, headerEnd + 4 + n)) });
      buf = buf.subarray(headerEnd + 4 + n);
    } else {
      const end = buf.indexOf(10);
      assert.ok(end > 0, 'response ends in newline');
      replies.push({ style: 'line', msg: JSON.parse(buf.subarray(0, end)) });
      buf = buf.subarray(end + 1);
    }
  }
  return replies;
}
async function exchange(ctx, messages, style = 'line', fragment = false) {
  const child = spawn(process.execPath, ctx.args, { cwd: root, stdio: 'pipe' });
  const done = once(child, 'close');
  const stdout = [], stderr = [];
  child.stdout.on('data', data => stdout.push(data));
  child.stderr.on('data', data => stderr.push(data));
  const input = Buffer.concat(messages.map(m => Buffer.isBuffer(m) ? m : encodePacket(m, style)));
  const timer = setTimeout(() => child.kill('SIGKILL'), 16000);
  try {
    if (fragment) {
      for (let i = 0; i < input.length; i += 7) {
        child.stdin.write(input.subarray(i, i + 7));
        await new Promise(r => setImmediate(r));
      }
    } else child.stdin.write(input);
    child.stdin.end();
    const [code, signal] = await done;
    assert.equal(code, 0, Buffer.concat(stderr).toString() + String(signal ?? ''));
    return decodePackets(Buffer.concat(stdout));
  } finally { clearTimeout(timer); }
}
async function calls(ctx, messages, style) {
  const results = await exchange(ctx, [init(), ready, ...messages], style);
  return results.slice(1).map(r => r.msg);
}
async function trace(ctx) {
  return (await readFile(join(ctx.dir, 'calls.jsonl'), 'utf8')).trim().split('\n').map(s => JSON.parse(s));
}

test('optimized build produces a Mach-O arm64 executable and JSON help for all native commands', async () => {
  const binary = await readFile(helper);
  assert.equal(binary.readUInt32LE(0), 0xfeedfacf);
  assert.equal(binary.readUInt32LE(4), 0x0100000c);
  const help = native(['--help']);
  assert.deepEqual(Object.keys(help.commands).sort(), ['permissions', 'windows', 'capture', 'ax-tree', 'ax-press',
    'ax-set-value', 'bg-click', 'bg-scroll', 'bg-key', 'find-controls', 'session'].sort());
  assert.deepEqual(native(['bg-click', '--help']).commands, { 'bg-click': help.commands['bg-click'] });
});

test('real TCC preflights and unauthorized read paths return JSON guidance without prompting', () => {
  permissions = native(['permissions']);
  for (const p of ['accessibility', 'screenRecording', 'postEvents']) assert.equal(typeof permissions[p], 'boolean');
  assert.match(permissions.guidance, /隐私与安全性/);
  if (!permissions.accessibility) assert.equal(native(['ax-tree', '--pid', '2147483647'], 1).error.code, 'AX_PERMISSION');
  if (!permissions.screenRecording) assert.equal(native(['capture', '--window-id', '4294967295', '--out', join(scratch, 'no.png')], 1).error.code, 'SCREEN_PERMISSION');
});

test('real server resolves the production helper and returns the same macOS preflights over STDIO', async () => {
  const ctx = await context({}, { helper, prefix: [] });
  const [reply] = await calls(ctx, [call(2, 'check_permissions')], 'frame');
  assert.deepEqual(payload(reply), native(['permissions']));
});

test('real CLI rejects missing, unrelated, duplicate, out-of-range and malformed options before touching a target', () => {
  const invalid = [[], ['unknown'], ['windows', '--app'], ['permissions', '--pid', '99'], ['ax-tree', '--pid', '0'],
    ['ax-tree', '--pid', '5', '--max-nodes', '0'], ['ax-press', '--pid', '5', '--path', '0//3'],
    ['ax-tree', '--pid', '5', '--pid', '5'], ['ax-set-value', '--pid', '4', '--path', '0/0'],
    ['bg-click', '--pid', '55', '--x', 'nan', '--y', '0'], ['bg-click', '--pid', '55', '--x', '5', '--y', '3', '--clicks', '3'],
    ['bg-click', '--pid', '55', '--x', '5', '--y', '3', '--button', 'middle'],
    ['bg-scroll', '--pid', '4', '--x', '1', '--y', '0', '--dy', '0'], ['bg-key', '--pid', '4', '--text', ''],
    ['capture', '--window-id', '1', '--out', 'a.jpg'], ['capture', '--window-id', '1', '--out', 'a.png', '--grid', '27x2'],
    ['capture', '--window-id', '1', '--out', 'a.png', '--max-width', '0']];
  for (const args of invalid) assert.equal(native(args, 2).error.code, 'INVALID_ARGUMENT', args.join(' '));
});

test('native sensitive application policy works with no desktop or TCC grant', () => {
  for (const name of ['sECURityAGENT', 'Keychain Access', '1Password', '系统设置']) {
    assert.equal(native(['windows', '--app', name], 1).error.code, 'SENSITIVE_TARGET');
  }
});

test('packaged entry point returns initialize while stdin remains open, then lists all tools', async () => {
  const manifest = JSON.parse(await readFile(join(root, 'plugin.json')));
  const config = JSON.parse(await readFile(join(root, 'mcp_config.json'))).mcpServers['mac-ghost'];
  assert.equal(config.command, 'node');
  assert.deepEqual(config.args, ['${PLUGIN_ROOT}/src/mcp-server.mjs']);
  assert.equal(manifest.name, 'mac-ghost-computer-use');
  success('/bin/sh', ['-n', 'install_to_antigravity.sh']);
  const child = spawn(process.execPath, [server], { cwd: dirname(root), stdio: 'pipe' });
  const done = once(child, 'close');
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
  try {
    child.stdin.write(encodePacket(init('2099-01-01'), 'line'));
    const first = JSON.parse((await lines.next()).value);
    assert.equal(first.result.protocolVersion, '2025-11-25');
    assert.equal(first.result.serverInfo.version, manifest.version);
    child.stdin.write(encodePacket(ready, 'line'));
    child.stdin.write(encodePacket(rpc(2, 'tools/list'), 'line'));
    const list = JSON.parse((await lines.next()).value).result.tools;
    assert.deepEqual(list.map(t => t.name), names);
    for (const tool of list) {
      assert.equal(tool.inputSchema.type, 'object');
      assert.equal(tool.inputSchema.additionalProperties, false);
      assert.ok(tool.description.length > 0);
    }
    assert.deepEqual(list[5].inputSchema.required, ['pid', 'path', 'value']);
    assert.equal(list[2].inputSchema.properties.max_width.maximum, 8192);
  } finally { child.stdin.end(); await done; clearTimeout(timer); }
});

for (const style of ['line', 'frame']) {
  test('handshake, UTF-8, notifications and tool schemas over fragmented ' + style, async () => {
    const ctx = await context();
    const replies = await exchange(ctx, [init('2025-06-18'), ready, { jsonrpc: '2.0', method: 'notifications/noop' },
      rpc('列举', 'tools/list'), call(3, 'check_permissions')], style, true);
    assert.deepEqual(replies.map(r => [r.style, r.msg.id]), [[style, 1], [style, '列举'], [style, 3]]);
    assert.equal(replies[0].msg.result.protocolVersion, '2025-06-18');
    assert.deepEqual(replies[1].msg.result.tools.map(t => t.name), names);
    assert.equal(payload(replies[2].msg).screenRecording, true);
  });
}

test('window filters, AX tree contents, targeted actions and literal Unicode survive transport', async () => {
  const ctx = await context();
  const secret = '示例输入🙂\\n--pid';
  const replies = await calls(ctx, [
    call(2, names[1], { app: 'Editor', visible_only: true }),
    call(3, names[3], { pid: 77, window_title: '窗口甲', max_depth: 2, max_nodes: 9 }),
    call(4, names[4], { pid: 77, path: '0/2' }), call(5, names[5], { pid: 77, path: '0/1', value: secret }),
    call(6, names[6], { pid: 77, window_id: 42, x: 20.5, y: 12, button: 'right', clicks: 2 }),
    call(7, names[7], { pid: 77, mode: 'type', text: secret }),
    call(8, names[7], { pid: 77, mode: 'scroll', window_id: 42, x: 10, y: 20, dy: -48 }),
  ]);
  assert.deepEqual(payload(replies[0]).windows, [sample]);
  assert.deepEqual(payload(replies[1]).nodes[0], { nodeId: '0/2', role: 'AXButton', title: '确定', description: '',
    value: null, frame: { x: 12, y: 20, width: 40, height: 30 }, enabled: true, actions: ['AXPress'] });
  assert.deepEqual(replies.slice(2).map(r => payload(r).delivery), ['ax_success', 'ax_success', ...Array(3).fill('posted_unverified')]);
  assert.deepEqual((await trace(ctx)).filter(args => args.length !== 1), [
    ['windows', '--app', 'Editor', '--visible-only'], ['ax-tree', '--pid', '77', '--window-title', '窗口甲', '--max-depth', '2', '--max-nodes', '9'],
    ['ax-press', '--pid', '77', '--path', '0/2'], ['ax-set-value', '--pid', '77', '--path', '0/1', '--value', secret],
    ['bg-click', '--pid', '77', '--window-id', '42', '--x', '20.5', '--y', '12', '--button', 'right', '--clicks', '2'],
    ['bg-key', '--pid', '77', '--text', secret], ['bg-scroll', '--pid', '77', '--window-id', '42', '--x', '10', '--y', '20', '--dy', '-48'],
  ]);
  for (const reply of replies.slice(2)) assert.equal(payload(reply).focusAudit.focusPreserved, true);
  const auditPath = join(ctx.dir, 'audit.jsonl');
  const audit = await readFile(auditPath, 'utf8');
  assert.equal((await stat(auditPath)).mode & 0o777, 0o600);
  assert.ok(!audit.includes('窗口甲') && !audit.includes('示例输入') && !audit.includes('0/2'));
  for (const row of audit.trim().split('\n')) assert.deepEqual(Object.keys(JSON.parse(row)).sort(), ['status', 'time', 'tool']);
});

test('grid capture sends native flags, embeds PNG and scale, and removes its private temporary file', async () => {
  const ctx = await context();
  const [reply] = await calls(ctx, [call(2, 'capture_window', { window_id: 42, grid: '6x4', max_width: 960 })], 'frame');
  assert.equal(payload(reply).pointsPerPixelY, 0.5);
  assert.equal(payload(reply).out, undefined);
  const im = reply.result.content[1];
  assert.equal(im.mimeType, 'image/png');
  assert.equal(Buffer.from(im.data, 'base64').subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  const png = Buffer.from(im.data, 'base64');
  let index = 8;
  const compressed = [];
  while (index < png.length) {
    const n = png.readUInt32BE(index);
    const type = png.toString('ascii', index + 4, index + 8);
    assert.equal(crc32(png.subarray(index + 4, index + 8 + n)), png.readUInt32BE(index + 8 + n));
    if (type === 'IDAT') compressed.push(png.subarray(index + 8, index + 8 + n));
    index += n + 12;
  }
  assert.deepEqual([...inflateSync(Buffer.concat(compressed))], [0, 30, 80, 120]);
  const capture = (await trace(ctx)).find(([name]) => name === 'capture');
  assert.deepEqual(capture.slice(0, -1), ['capture', '--window-id', '42', '--grid', '6x4', '--max-width', '960', '--out']);
  assert.ok(capture.at(-1).startsWith(join(ctx.dir, 'capture-')));
  assert.ok(!(await readdir(ctx.dir)).some(s => s.startsWith('capture-')));
});

test('sensitive owner, bundle, sibling payment window and helper protected flag block reads and writes before dispatch', async () => {
  for (const changes of [{ appName: 'SecurityAgent' }, { appName: 'Keychain Access' }, { appName: '1Password' },
    { bundleId: 'com.apple.LocalAuthentication.UIAgent' }, { title: 'Apple Pay — Confirm purchase' }, { protected: true }]) {
    const ctx = await context({ windows: [sample, { ...sample, windowId: 43, ...changes }] });
    const replies = await calls(ctx, [call(2, 'capture_window', { window_id: 42 }), call(3, 'ax_press', { pid: 77, path: '0/1' }),
      call(4, 'list_windows')]);
    assert.equal(errCode(replies[0]), 'SENSITIVE_TARGET');
    assert.equal(errCode(replies[1]), 'SENSITIVE_TARGET');
    assert.equal(payload(replies[2]).windows[1].title, null);
    assert.deepEqual(await trace(ctx), [['windows'], ['windows'], ['windows']]);
    assert.ok((await readFile(join(ctx.dir, 'audit.jsonl'), 'utf8')).includes('"denied"'));
  }
});

test('disappearing window, unknown PID and mismatched PID/window fail closed', async () => {
  const ctx = await context();
  const replies = await calls(ctx, [call(2, 'capture_window', { window_id: 41 }),
    call(3, 'inspect_ui_tree', { pid: 12 }), call(4, 'bg_click', { pid: 12, window_id: 42, x: 1, y: 2 })]);
  assert.deepEqual(replies.map(errCode), Array(3).fill('TARGET_UNAVAILABLE'));
  assert.deepEqual(await trace(ctx), Array.from({ length: 3 }, () => [['windows'], ['permissions']]).flat());
});

test('missing target metadata still returns the applicable TCC guidance before any desktop operation', async () => {
  const ctx = await context({ windows: [], permissions: { accessibility: false, screenRecording: false } });
  const replies = await calls(ctx, [call(2, 'capture_window', { window_id: 42 }), call(3, 'inspect_ui_tree', { pid: 77 })]);
  assert.deepEqual(replies.map(errCode), ['SCREEN_PERMISSION', 'AX_PERMISSION']);
  for (const reply of replies) assert.match(payload(reply).error.message, /隐私与安全性/);
  assert.deepEqual(await trace(ctx), [['windows'], ['permissions'], ['windows'], ['permissions']]);
});

test('schema errors reject unrelated keys, wrong types, malformed grid, path and incomplete gesture unions', async () => {
  const ctx = await context();
  const invalid = [['check_permissions', { extra: true }], ['capture_window', { window_id: 42, grid: '0x4' }],
    ['bg_click', { pid: 77, x: '1', y: 2 }], ['ax_press', { pid: 77, path: '../a' }],
    ['bg_type_or_scroll', { mode: 'type', pid: 77 }], ['bg_type_or_scroll', { mode: 'type', pid: 77, text: 'abc', x: 0 }],
    ['bg_type_or_scroll', { mode: 'scroll', pid: 77, x: 0, y: 0, dy: 0 }], ['ax_set_value', { pid: 77, path: '0', value: 'a\0b' }]];
  const replies = await calls(ctx, invalid.map(([n, v], i) => call(i + 2, n, v)));
  assert.deepEqual(replies.map(errCode), invalid.map(() => 'INVALID_ARGUMENT'));
  assert.ok(!(await readdir(ctx.dir)).includes('calls.jsonl'));
});

for (const [failure, expected] of [['crash', 'HELPER_FAILED'], ['hang', 'HELPER_FAILED'],
  ['invalid-json', 'HELPER_PROTOCOL'], ['native-error', 'AX_PERMISSION']]) {
  test('helper ' + failure + ' returns a tool error and the same session completes the next call', async () => {
    const ctx = await context({ failureCommand: 'ax-tree', failure }, { timeout: failure === 'hang' ? 750 : 3000 });
    const replies = await calls(ctx, [call(2, 'inspect_ui_tree', { pid: 77 }), call(3, 'check_permissions')]);
    assert.equal(errCode(replies[0]), expected);
    assert.equal(payload(replies[1]).accessibility, true);
    assert.equal((await trace(ctx)).filter(x => x[0] === 'ax-tree').length, 1);
  });
}
test('invalid screenshot cleans up and audit failure prevents dispatch', async () => {
  const ctx = await context({ badPng: true });
  const [reply] = await calls(ctx, [call(2, 'capture_window', { window_id: 42 })]);
  assert.equal(errCode(reply), 'HELPER_PROTOCOL');
  assert.ok(!(await readdir(ctx.dir)).some(s => s.startsWith('capture-')));
  const broken = await context({}, { stateDir: join(ctx.dir, 'fixture.json') });
  const [denied] = await calls(broken, [call(2, 'ax_press', { pid: 77, path: '0' })]);
  assert.equal(errCode(denied), 'AUDIT_UNAVAILABLE');
  assert.ok(!(await readdir(broken.dir)).includes('calls.jsonl'));
});
test('JSON-RPC errors, lifecycle, mixed framing, recovery and legacy batches', async () => {
  const ctx = await context();
  const replies = await exchange(ctx, [rpc(0, 'tools/list'), init('2025-03-26'), rpc('early', 'tools/list'), ready,
    Buffer.from('no-json\n'), encodePacket(rpc(3, 'ping'), 'frame'), rpc(4, 'bogus'), call(5, 'no-tool'), rpc(6, 'ping', []),
    [rpc(7, 'ping'), { jsonrpc: '2.0', method: 'notifications/test' }, rpc(8, 'ping')], init()]);
  assert.deepEqual(replies.map(r => r.msg.error?.code ?? 'ok'), [-32002, 'ok', -32002, -32700, 'ok', -32601, -32602, -32602, 'ok', -32600]);
  assert.equal(replies[4].style, 'frame');
  assert.deepEqual(replies[8].msg.map(r => r.id), [7, 8]);
  for (const raw of ['Content-Length: 100\r\n\r\n{}', 'Content-Length: 99999999\r\n\r\n', 'Content-Length: -1\r\n\r\n']) {
    const [error] = await exchange(ctx, [Buffer.from(raw)]);
    assert.equal(error.style, 'frame');
    assert.equal(error.msg.error.code, -32700);
  }
});

test('semantic query filters are passed once with original Unicode and empty window title', async () => {
  const controls = [{ nodeId: '2/9', role: 'AXButton', title: '保存' }];
  const ctx = await context({ controls });
  const [reply] = await calls(ctx, [call(2, 'find_controls', { pid: 77, window_title: '', role: 'AXButton',
    title_contains: '保存', value_contains: '--pid', action: 'AXPress', max_results: 2 })], 'frame');
  assert.deepEqual(payload(reply).controls, controls);
  assert.deepEqual(await trace(ctx), [['windows'], ['find-controls', '--pid', '77', '--window-title', '', '--role', 'AXButton',
    '--title-contains', '保存', '--value-contains', '--pid', '--action', 'AXPress', '--max-results', '2']]);
});

test('protected sibling blocks semantic search, saved crop and every write including restore', async () => {
  const ctx = await context({ windows: [sample, { ...sample, windowId: 43, protected: true }] });
  const attempts = [
    ['find_controls', { pid: 77 }], ['capture_window', { window_id: 42, save_path: 'safe.png' }],
    ['ax_press', { pid: 77, path: '0' }], ['ax_set_value', { pid: 77, path: '0', value: 'test' }],
    ['bg_click', { pid: 77, x: 1, y: 1 }], ['bg_type_or_scroll', { pid: 77, mode: 'type', text: '字' }],
    ['bg_type_or_scroll', { pid: 77, mode: 'scroll', x: 2, y: 3, dy: -12 }],
  ];
  const replies = await calls(ctx, attempts.map(([name, args], i) => call(i + 2, name, i >= 2 ? { ...args, restore_focus: true } : args)));
  assert.deepEqual(replies.map(errCode), attempts.map(() => 'SENSITIVE_TARGET'));
  assert.deepEqual(await trace(ctx), attempts.map(() => ['windows']));
  assert.ok(!(await readdir(ctx.dir)).includes('captures'));
});

test('changed focus, explicit restore, error details and safe audit log cross JSON-RPC', async () => {
  const before = { pid: 3, bundleId: 'test.front', activeWindow: { status: 'focused' } };
  const after = { ...before, pid: 77, bundleId: 'test.target' };
  const focusAudit = { beforeFrontmost: before, afterFrontmost: after, status: 'changed', focusPreserved: false,
    warning: 'focus changed', restoration: 'verified', afterRestoreFrontmost: before };
  const ctx = await context({ focusAudit, failure: 'native-error', failureCommand: 'ax-set-value' });
  const attempts = [
    ['ax_press', { pid: 77, path: '0/2' }], ['ax_set_value', { pid: 77, path: '0/1', value: 'test' }],
    ['bg_click', { pid: 77, x: 0, y: 1 }], ['bg_type_or_scroll', { pid: 77, mode: 'type', text: '字' }],
    ['bg_type_or_scroll', { pid: 77, mode: 'scroll', x: 2, y: 3, dy: -12 }],
  ];
  const replies = await calls(ctx, attempts.map(([name, args], i) => call(i + 2, name, { ...args, restore_focus: true })));
  assert.equal(errCode(replies[1]), 'AX_PERMISSION');
  for (const reply of replies) assert.deepEqual(payload(reply).focusAudit, focusAudit);
  const commands = (await trace(ctx)).filter(([name]) => !['windows', 'permissions'].includes(name));
  assert.ok(commands.every(args => args.at(-1) === '--restore-focus'));
  const audit = await readFile(join(ctx.dir, 'audit.jsonl'), 'utf8');
  assert.match(audit, /"focus_changed"/);
  assert.doesNotMatch(audit, /test\.front|test\.target/);
});

test('save_path returns metadata only; inline crop retains the PNG image block', async () => {
  const crop = { x: 0.25, y: 0, width: 0.5, height: 1 };
  const ctx = await context();
  const replies = await calls(ctx, [call(2, 'capture_window', { window_id: 42, grid: '1x1', crop, save_path: '截图.png' }),
    call(3, 'capture_window', { window_id: 42, crop })]);
  assert.equal(replies[0].result.content.length, 1);
  const meta = payload(replies[0]);
  assert.deepEqual(meta.cellToPoint.A1, { x: 0.25, y: 0.25 });
  assert.equal(meta.savedPath, join(ctx.dir, 'captures', '截图.png'));
  assert.equal((await stat(meta.savedPath)).mode & 0o777, 0o600);
  assert.equal((await readFile(meta.savedPath)).readUInt32BE(0), 0x89504e47);
  assert.equal(replies[1].result.content[1].type, 'image');
  assert.deepEqual((await trace(ctx)).find(([name]) => name === 'capture'), ['capture', '--window-id', '42', '--grid', '1x1', '--crop', JSON.stringify(crop), '--save-path', '截图.png']);
});

test('nested schema, ranges, safe path and boolean constraints reject calls before inspection', async () => {
  const ctx = await context();
  const crop = { x: 0, y: 0, width: 1, height: 1 };
  const invalid = [
    ...[{ ...crop, x: 0.1 }, { ...crop, width: 0 }, { ...crop, y: -1 }, { ...crop, x: '0' }, { ...crop, z: 0 }, {}, null]
      .map(value => ['capture_window', { window_id: 1, crop: value }]),
    ...['../outside.png', '/outside.png', '.secret.png', 'sub/file.png', 'demo.jpeg'].map(save_path => ['capture_window', { window_id: 1, save_path }]),
    ['find_controls', { pid: 77, max_results: 101 }], ['find_controls', { pid: 77, max_results: 0 }],
    ['find_controls', { pid: 77, restore_focus: true }], ['ax_press', { pid: 77, path: '0', restore_focus: 'true' }],
  ];
  const replies = await calls(ctx, invalid.map(([name, args], i) => call(i + 2, name, args)));
  assert.deepEqual(replies.map(errCode), invalid.map(() => 'INVALID_ARGUMENT'));
  assert.ok(!(await readdir(ctx.dir)).includes('calls.jsonl'));
});

test('installer dry-run, fresh install and backed-up upgrade in an isolated plugin tree', async () => {
  const dir = await mkdtemp(join(scratch, 'installer-'));
  const dest = join(dir, 'plugins', 'mac-ghost-computer-use');
  const script = ['./install_v11.sh', '--dest', dest];
  assert.equal(JSON.parse(success('/bin/sh', [...script, '--dry-run'])).operation, 'install');
  assert.deepEqual(await readdir(dir), []);
  assert.equal(JSON.parse(success('/bin/sh', script)).backup, null);
  const chinese = await readFile(join(root, 'README_ZH.md'));
  assert.deepEqual(await readFile(join(dest, 'README_ZH.md')), chinese);
  success('/bin/sh', ['./install_to_antigravity.sh'], { env: { ...process.env, HOME: dir } });
  assert.deepEqual(await readFile(join(dir, '.gemini/config/plugins/mac-ghost-computer-use/README_ZH.md')), chinese);
  const old = JSON.parse(await readFile(join(dest, 'plugin.json'), 'utf8'));
  old.version = '1.0.0';
  await writeFile(join(dest, 'plugin.json'), JSON.stringify(old));
  await mkdir(join(dest, '.local'));
  await writeFile(join(dest, '.local/audit.jsonl'), 'prior history\n');
  const previousEntries = await readdir(join(dir, 'mac-ghost-backups'));
  assert.equal(JSON.parse(success('/bin/sh', [...script, '--dry-run'])).operation, 'upgrade');
  assert.deepEqual(await readdir(join(dir, 'mac-ghost-backups')), previousEntries);
  assert.deepEqual(JSON.parse(await readFile(join(dest, 'plugin.json'))), old);
  const { backup } = JSON.parse(success('/bin/sh', script));
  assert.deepEqual(JSON.parse(await readFile(join(backup, 'plugin.json'))), old);
  assert.equal(JSON.parse(await readFile(join(dest, 'plugin.json'))).version, '2.0.1');
  for (const path of [dest, backup]) assert.equal(await readFile(join(path, '.local/audit.jsonl'), 'utf8'), 'prior history\n');
  const installed = join(dest, 'bin/mac-ghost-helper');
  assert.ok(JSON.parse(success(installed, ['--help'])).commands['find-controls']);
  assert.ok(JSON.parse(success(installed, ['--help'])).commands['session']);
  assert.equal(JSON.parse(command(installed, ['windows', '--app', 'SecurityAgent']).stdout).error.code, 'SENSITIVE_TARGET');
  assert.equal(JSON.parse(await readFile(join(dest, 'mcp_config.json'))).mcpServers['mac-ghost'].command, process.execPath);
});

test('v2 get_state returns full text AX tree then incremental diff with zero images or capture calls', async () => {
  const ctx = await context();
  const replies = await calls(ctx, [
    call(2, 'get_state', { pid: 77, window_id: 42 }),
    call(3, 'get_state', { pid: 77, window_id: 42 }),
  ]);
  for (const reply of replies) {
    assert.equal(reply.result.content.length, 1);
    assert.equal(reply.result.content[0].type, 'text');
    assert.doesNotMatch(reply.result.content[0].text, /iVBORw0KGgo|data:image/);
  }
  const first = payload(replies[0]);
  const second = payload(replies[1]);
  assert.equal(first.ok, true);
  assert.equal(first.state.kind, 'full');
  assert.equal(first.state.snapshot, 'snap-1');
  assert.equal(first.state.upsert.length, 3);
  assert.equal(second.ok, true);
  assert.equal(second.state.kind, 'diff');
  assert.equal(second.state.base, 'snap-1');
  assert.deepEqual(second.state.upsert, []);
  const callsLog = await trace(ctx);
  assert.ok(!callsLog.some(c => c[0] === 'capture'));
  assert.equal(callsLog.filter(c => c[0] === 'session').length, 1, 'session should be reused for the same PID');
});

test('v2 run_actions stops on first failed assert, never dispatches subsequent Return, and redacts pasted body', async () => {
  const ctx = await context();
  const secret = 'TOP_SECRET_PASTE_8842';
  const [st, res] = await calls(ctx, [
    call(2, 'get_state', { pid: 77, window_id: 42 }),
    call(3, 'run_actions', {
      pid: 77,
      window_id: 42,
      snapshot: 'snap-1',
      steps: [
        { op: 'paste', ref: 'e2', text: secret, format: 'md' },
        { op: 'wait', ms: 10 },
        { op: 'assert', role: 'AXButton', title: '不存在的按钮', condition: 'exists' },
        { op: 'press_key', key: 'Return' },
      ],
    }),
  ]);
  const snapshot = payload(st).state.snapshot;
  assert.equal(snapshot, 'snap-1');
  assert.equal(res.result.isError, true);
  const body = payload(res);
  assert.equal(body.ok, false);
  assert.equal(body.completed, 2);
  assert.equal(body.failed_index, 2);
  assert.equal(body.error.code, 'ASSERTION_FAILED');
  assert.equal(body.state.kind, 'diff');
  assert.equal(body.state.base, snapshot);
  // 验证分段粘贴后的自由文本 value、description 与 title 均被彻底脱敏
  assert.equal(body.state.upsert[0].value, undefined);
  assert.equal(body.state.upsert[0].title, undefined);
  assert.doesNotMatch(JSON.stringify(body), new RegExp(secret.slice(0, 6)));
  const audit = await readFile(join(ctx.dir, 'audit.jsonl'), 'utf8');
  assert.doesNotMatch(audit, new RegExp(secret));
  const ops = (await trace(ctx)).filter(c => c[0].startsWith('session:')).map(c => c[0]);
  assert.ok(ops.includes('session:paste'));
  assert.ok(!ops.includes('session:press_key'), 'Return must never be dispatched after failed assert');
});

test('v2 single-line guard rejects all real line breaks in type_text and bg_type_or_scroll, while allowing literal \\n', async () => {
  const ctx = await context();
  const badTexts = ['a\nb', 'a\rb', 'a\r\nb', 'a\u0085b', 'a\u2028b', 'a\u2029b'];
  const invalidCalls = [
    ...badTexts.map((t, i) => call(10 + i, 'bg_type_or_scroll', { mode: 'type', pid: 77, text: t })),
    ...badTexts.map((t, i) => call(30 + i, 'type_text', { pid: 77, window_id: 42, snapshot: 'snap-1', text: t })),
  ];
  const replies = await calls(ctx, invalidCalls);
  assert.deepEqual(replies.map(errCode), invalidCalls.map(() => 'INVALID_ARGUMENT'));
  assert.ok(!(await readdir(ctx.dir)).includes('calls.jsonl'));
});

test('v2 run_actions rejects duplicate modifiers, cmd+v bypass, and stops immediately on focus drift', async () => {
  const ctx = await context();
  const [badMod, badPasteBypass] = await calls(ctx, [
    call(2, 'run_actions', {
      pid: 77, window_id: 42, snapshot: 'snap-1',
      steps: [{ op: 'press_key', key: 'super+cmd+a' }],
    }),
    call(3, 'run_actions', {
      pid: 77, window_id: 42, snapshot: 'snap-1',
      steps: [{ op: 'press_key', key: 'super+v' }],
    }),
  ]);
  assert.equal(errCode(badMod), 'INVALID_ARGUMENT');
  assert.equal(errCode(badPasteBypass), 'INVALID_ARGUMENT');

  const before = { pid: 3, bundleId: 'test.front', activeWindow: { status: 'focused' } };
  const after = { pid: 77, bundleId: 'test.target', activeWindow: { status: 'focused' } };
  const driftCtx = await context({
    stepFocusAudit: {
      ax_press: { beforeFrontmost: before, afterFrontmost: after, status: 'changed', focusPreserved: false },
    },
  });
  const [st] = await calls(driftCtx, [call(2, 'get_state', { pid: 77, window_id: 42 })]);
  const [drift] = await calls(driftCtx, [call(3, 'run_actions', {
    pid: 77, window_id: 42, snapshot: payload(st).state.snapshot,
    steps: [
      { op: 'ax_press', ref: 'e3' },
      { op: 'press_key', key: 'Return' },
    ],
  })]);
  assert.equal(errCode(drift), 'FOCUS_CHANGED');
  assert.equal(payload(drift).completed, 0);
  const ops = (await trace(driftCtx)).filter(c => c[0].startsWith('session:')).map(c => c[0]);
  assert.ok(!ops.includes('session:press_key'), 'focus drift must stop subsequent batch steps');
});

test('v2 rejects overly permissive existing audit.jsonl (0644) before touching target', async () => {
  const ctx = await context();
  const auditPath = join(ctx.dir, 'audit.jsonl');
  await writeFile(auditPath, '', { mode: 0o644 });
  await chmod(auditPath, 0o644);
  const [reply] = await calls(ctx, [call(2, 'list_windows')]);
  assert.equal(errCode(reply), 'AUDIT_UNAVAILABLE');
  assert.ok(!(await readdir(ctx.dir)).includes('calls.jsonl'));
});

test('real production helper session handles invalid JSON, unknown op, and close cleanly over STDIO', async () => {
  const child = spawn(helper, ['session', '--pid', '77'], { cwd: root, stdio: 'pipe' });
  const done = once(child, 'close');
  const out = [];
  child.stdout.on('data', d => out.push(d));
  child.stdin.write('not-json\n');
  child.stdin.write(JSON.stringify({ id: '1', op: 'bogus_op', params: {} }) + '\n');
  child.stdin.write(JSON.stringify({ id: '2', op: 'close', params: {} }) + '\n');
  child.stdin.end();
  const [code] = await done;
  assert.equal(code, 0);
  const lines = Buffer.concat(out).toString('utf8').trim().split('\n').map(l => JSON.parse(l));
  assert.equal(lines.length, 3);
  assert.equal(lines[0].ok, false);
  assert.equal(lines[0].error.code, 'INVALID_JSON');
  assert.equal(lines[1].id, '1');
  assert.equal(lines[1].ok, false);
  assert.equal(lines[1].error.code, 'INVALID_ARGUMENT');
  assert.equal(lines[2].id, '2');
  assert.equal(lines[2].ok, true);
  assert.equal(lines[2].closed, true);
});

const target = { pid: 77, window_id: 42, snapshot: 'snap-1' };
const dragStep = { op: 'drag', from_x: 1, from_y: 1, to_x: 4, to_y: 4, allow_activate: true };
const pasteStep = { op: 'paste', text: 'body' };

for (const [label, step, receipt, code, effect] of [
  ['unsent paste', pasteStep, { posted: false, pasteEffect: 'not_sent', code: 'CLIPBOARD_CHANGED',
    clipboardRestore: 'changed_externally' }, 'CLIPBOARD_CHANGED', 'not_started'],
  ['partial drag', dragStep, { partial: true, mouseUpPosted: true, code: 'STALE_WINDOW' }, 'STALE_WINDOW', 'partial'],
  ['unreleased drag', dragStep, { partial: false, mouseUpPosted: false }, 'INCOMPLETE_ACTION', 'partial'],
  ['failed clipboard restoration', pasteStep, { posted: true, clipboardRestore: 'restore_failed' },
    'CLIPBOARD_RESTORE_FAILED', 'unknown'],
]) {
  test(label + ' preserves receipt and stops before next key', async () => {
    const ctx = await context({ receipt: { [step.op]: receipt } });
    const [reply] = await calls(ctx, [call(2, 'run_actions', { ...target, steps: [step, { op: 'press_key', key: 'Return' }] })]);
    assert.equal(errCode(reply), code);
    const result = payload(reply);
    assert.equal(result.ok, false);
    assert.equal(result.completed, 0);
    assert.equal(result.failed_index, 0);
    assert.equal(result.effect, effect);
    for (const [key, value] of Object.entries(receipt)) assert.equal(result.receipts[0][key], value);
    assert.ok(!(await trace(ctx)).some(([op]) => op === 'session:press_key'));
  });
}

test('activated drag exempts only verified target PID and window at both focus samples', async () => {
  const front = (pid, windowId) => ({ pid, activeWindow: { status: 'focused', windowId } });
  const wanted = front(77, 42);
  for (const [immediate, after, accepted] of [
    [wanted, wanted, true], [wanted, front(88, 42), false], [wanted, front(77, 43), false],
    [front(88, 42), wanted, false], [wanted, front(77, null), false],
  ]) {
    const ctx = await context({ stepFocusAudit: { drag: { status: 'changed', focusPreserved: false,
      beforeFrontmost: front(9, 1), immediateFrontmost: immediate, afterFrontmost: after } } });
    const [reply] = await calls(ctx, [call(2, 'run_actions', { ...target, steps: [dragStep, { op: 'press_key', key: 'Return' }] })]);
    assert.equal(payload(reply).completed, accepted ? 2 : 0);
    if (!accepted) assert.equal(errCode(reply), 'FOCUS_CHANGED');
    assert.equal((await trace(ctx)).some(([op]) => op === 'session:press_key'), accepted);
  }
});

test('activated drag ending in the original unrelated app cannot claim preserved focus as success', async () => {
  const ctx = await context();
  const [reply] = await calls(ctx, [call(2, 'run_actions', { ...target, steps: [dragStep] })]);
  assert.equal(errCode(reply), 'FOCUS_CHANGED');
  assert.equal(payload(reply).completed, 0);
});

test('missing AX trust blocks legacy pointer and capture but permits discovery', async () => {
  const ctx = await context({ permissions: { accessibility: false } });
  const replies = await calls(ctx, [call(2, 'list_windows'), call(3, 'bg_click', { pid: 77, x: 1, y: 2 }),
    call(4, 'bg_type_or_scroll', { pid: 77, mode: 'scroll', x: 1, y: 2, dy: 3 }),
    call(5, 'capture_window', { window_id: 42 })]);
  assert.deepEqual(payload(replies[0]).windows, [sample]);
  assert.deepEqual(replies.slice(1).map(errCode), Array(3).fill('AX_PERMISSION'));
  assert.ok((await trace(ctx)).every(([op]) => ['windows', 'permissions'].includes(op)));
});

test('legacy batch enforces count, aggregate response bytes and absolute deadline', async () => {
  const messages = [rpc(2, 'ping'), rpc(3, 'tools/list'), call(4, 'check_permissions')];
  const run = async (ctx, batch) => (await exchange(ctx, [init('2025-03-26'), ready, batch])).at(-1).msg;
  const ctx = await context({}, { maxBatchItems: 2 });
  assert.equal((await run(ctx, messages)).error.code, -32600);
  const small = await context({}, { maxBatchBytes: 800 });
  const replies = await run(small, messages);
  assert.ok(Buffer.byteLength(JSON.stringify(replies)) <= 800);
  assert.deepEqual(replies.map(r => r.error?.code ?? 0), [0, -32000, -32000]);
  assert.ok(!(await readdir(small.dir)).includes('calls.jsonl'));
  const slow = await context({ failureCommand: 'permissions', failure: 'hang' }, { maxBatchMs: 150 });
  const timed = await run(slow, [call(2, 'check_permissions'), call(3, 'list_windows')]);
  assert.equal(timed.at(-1).error.code, -32000);
  assert.ok(!(await trace(slow)).some(([op]) => op === 'windows'));
});

test('legacy MCP bodies travel only via stdin and the native CLI decodes the same arguments', async () => {
  const ctx = await context();
  const sentinel = 'private-正文🙂';
  const [reply] = await calls(ctx, [call(2, 'ax_set_value', { pid: 77, path: '0', value: sentinel })]);
  assert.equal(payload(reply).delivery, 'ax_success');
  assert.deepEqual(JSON.parse(await readFile(join(ctx.dir, 'transport.jsonl'), 'utf8')), ['--stdin-args']);
  const args = ['bg-key', '--pid', '77', '--text', sentinel + '\n'];
  const secure = command(helper, ['--stdin-args'], { input: JSON.stringify(args) });
  assert.equal(secure.status, 1);
  assert.deepEqual(JSON.parse(secure.stdout), native(args, 1));
});

test('default SwiftPM caches are distinct for two checkout paths', async () => {
  const dir = await mkdtemp(join(scratch, 'build-cache-'));
  const env = { ...process.env, HOME: dir };
  delete env.MACGHOST_BUILD_DIR;
  for (const name of ['checkout-a', 'checkout-b']) {
    const checkout = join(dir, name);
    await mkdir(checkout);
    await copyFile(join(root, 'build.sh'), join(checkout, 'build.sh'));
    const result = command('/bin/sh', ['build.sh', 'invalid'], { cwd: checkout, env });
    assert.equal(result.status, 2); // Select the scratch path without compiling.
  }
  const hashes = await readdir(join(dir, 'Library/Caches/mac-ghost-build'));
  assert.equal(hashes.length, 2);
  for (const hash of hashes) assert.match(hash, /^[0-9a-f]{64}$/);
});
