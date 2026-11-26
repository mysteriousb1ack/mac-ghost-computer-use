import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { basename, join } from 'node:path';

const [dir, command, ...args] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(join(dir, 'fixture.json'), 'utf8'));
await appendFile(join(dir, 'calls.jsonl'), JSON.stringify([command, ...args]) + '\n');
const flag = name => args[args.indexOf(name) + 1];
const foreground = { pid: 5, bundleId: 'test.front', activeWindow: { status: 'focused' } };
const focusAudit = fixture.focusAudit ?? { beforeFrontmost: foreground, afterFrontmost: foreground, status: 'preserved', focusPreserved: true };
const emit = object => console.log(JSON.stringify({ ok: true, ...object }));
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOQC6gAAAF2AOe0MgrYAAAAAElFTkSuQmCC', 'base64');

if (command === 'session') {
  let seq = 0;
  let lastSnapshot = null;
  let currentNodes = fixture.sessionNodes ?? [
    { ref: 'e1', parent: null, order: 0, role: 'AXWindow', title: '窗口甲', enabled: true },
    { ref: 'e2', parent: 'e1', order: 0, role: 'AXTextArea', title: '正文', value: '旧内容', enabled: true, focused: true, actions: ['AXConfirm'] },
    { ref: 'e3', parent: 'e1', order: 1, role: 'AXButton', title: '发送', enabled: true, actions: ['AXPress'] },
  ];
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.trim()) continue;
    const req = JSON.parse(line);
    await appendFile(join(dir, 'calls.jsonl'), JSON.stringify(['session:' + req.op, req.params]) + '\n');
    const reply = obj => process.stdout.write(JSON.stringify({ id: req.id, ...obj }) + '\n');
    if (req.op === 'close') {
      reply({ ok: true, closed: true });
      break;
    }
    if (req.op === fixture.failureCommand) {
      if (fixture.failure === 'crash') { process.kill(process.pid, 'SIGKILL'); break; }
      if (fixture.failure === 'hang') { await new Promise(r => setTimeout(r, 10000)); continue; }
      if (fixture.failure === 'invalid-json') { process.stdout.write('not-json\n'); continue; }
      reply({ ok: false, focusAudit, error: { code: fixture.failureCode ?? 'AX_ACTION_FAILED', message: 'Mock session error.' } });
      continue;
    }
    if (req.op === 'get_state') {
      const p = req.params ?? {};
      const advance = p.advance_baseline !== false;
      const full = p.full === true || !lastSnapshot || !advance;
      const snap = advance ? `snap-${++seq}` : `internal-${seq}`;
      if (full) {
        const state = {
          kind: 'full',
          snapshot: snap,
          complete: true,
          truncated: false,
          reason: !lastSnapshot ? 'no_baseline' : (p.full ? 'requested_full' : 'internal_read'),
          remove_ranges: [],
          upsert: currentNodes,
        };
        if (advance) lastSnapshot = snap;
        reply({ ok: true, state });
      } else {
        const base = p.since ?? lastSnapshot;
        const changed = fixture.sessionAfterWriteNodes && seq > 1 ? fixture.sessionAfterWriteNodes : [];
        const state = {
          kind: 'diff',
          base,
          snapshot: snap,
          complete: true,
          truncated: false,
          remove_ranges: [],
          upsert: changed,
        };
        lastSnapshot = snap;
        reply({ ok: true, state });
      }
      continue;
    }
    if (req.op === 'assert') {
      const p = req.params ?? {};
      const matched = currentNodes.filter(n =>
        !n.protected &&
        (p.ref === undefined || n.ref === p.ref) &&
        (p.role === undefined || n.role === p.role) &&
        (p.title === undefined || n.title === p.title),
      );
      const pass = p.condition === 'exists' ? matched.length > 0
        : p.condition === 'absent' ? matched.length === 0
        : matched.length === 1 && matched[0][p.condition] === true;
      if (pass) reply({ ok: true, asserted: true, condition: p.condition });
      else reply({ ok: false, error: { code: 'ASSERTION_FAILED', message: 'Assertion did not hold.' } });
      continue;
    }
    if (req.op === 'paste' || req.op === 'type_text') {
      // 模拟写入后节点 value 含有拆分片段（验证按字段脱敏）
      currentNodes = currentNodes.map(n => n.ref === 'e2' ? { ...n, value: String(req.params.text).slice(0, 6) } : n);
      fixture.sessionAfterWriteNodes = [currentNodes[1]];
    }
    const stepAudit = fixture.stepFocusAudit?.[req.op] ?? focusAudit;
    reply({ ok: true, delivery: 'ax_success', focusAudit: stepAudit });
  }
  process.exit(0);
}

if (command === fixture.failureCommand) {
  switch (fixture.failure) {
    case 'crash': process.kill(process.pid, 'SIGKILL'); break;
    case 'hang': await new Promise(r => setTimeout(r, 10000)); break;
    case 'invalid-json': console.log('not JSON'); break;
    case 'native-error':
      console.log(JSON.stringify({ ok: false, focusAudit: fixture.focusAudit, error: { code: 'AX_PERMISSION', message: 'Enable Accessibility.' } }));
      process.exitCode = 1; break;
  }
} else {
  switch (command) {
    case 'permissions': emit({ accessibility: true, screenRecording: true, postEvents: true, guidance: '系统设置 → 隐私与安全性', ...fixture.permissions }); break;
    case 'windows': emit({ windows: fixture.windows }); break;
    case 'ax-tree': emit({ nodes: [{ nodeId: '0/2', role: 'AXButton', title: '确定', description: '', value: null,
      frame: { x: 12, y: 20, width: 40, height: 30 }, enabled: true, actions: ['AXPress'] }], truncated: false }); break;
    case 'find-controls': emit({ controls: fixture.controls ?? [], visited: 6, truncated: false }); break;
    case 'capture': {
      if (args.includes('--save-path')) {
        await mkdir(join(dir, 'captures'), { recursive: true });
        const savedPath = join(dir, 'captures', basename(flag('--save-path')));
        await writeFile(savedPath, png, { flag: 'wx', mode: 0o600 });
        emit({ width: 1, height: 1, windowId: 42, savedPath, cellToPoint: { A1: { x: 0.25, y: 0.25 } } });
        break;
      }
      const out = flag('--out');
      await writeFile(out, fixture.badPng ? Buffer.from('bad') : png);
      emit({ width: 1, height: 1, out, windowId: 42, pointsPerPixelX: 0.5, pointsPerPixelY: 0.5, grid: flag('--grid') });
      break;
    }
    case 'ax-press': case 'ax-set-value': emit({ focusAudit, mode: 'ax_no_activate', delivery: 'ax_success' }); break;
    case 'bg-click': case 'bg-key': case 'bg-scroll':
      emit({ focusAudit, mode: 'cg_post_to_pid_no_activate', delivery: 'posted_unverified' }); break;
    default: process.exitCode = 5;
  }
}
