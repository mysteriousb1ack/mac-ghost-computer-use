import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { constants } from 'node:fs';
import { mkdir, mkdtemp, lstat, open, readFile, rm, stat } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tools, matches, v2ActionNames, v2SessionTools, toolWrites } from './tool-schemas.mjs';
import { createSessionPool } from './ax-state.mjs';
import { executeGetState, executeRunActions, executeSingleAction } from './run-actions.mjs';

export { tools, matches };

const run = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
const rules = JSON.parse(await readFile(new URL('./guardrails.json', import.meta.url), 'utf8'));

export class Problem extends Error {
  constructor(code, message, focusAudit) {
    super(message);
    this.code = code;
    this.focusAudit = focusAudit;
  }
}

function sensitive(row) {
  const name = String(row.appName ?? '').toLowerCase();
  const bundle = String(row.bundleId ?? '').toLowerCase();
  const title = String(row.title ?? '').toLowerCase();
  return row.protected === true || rules.identities.some(s => name === s.toLowerCase()) ||
    rules.bundlePrefixes.some(s => bundle.startsWith(s)) || rules.markers.some(s => name.includes(s) || title.includes(s));
}

// 显式命令白名单，禁止未知工具静默回落到键盘/滚轮命令。
const legacyCommands = {
  check_permissions: 'permissions',
  list_windows: 'windows',
  capture_window: 'capture',
  inspect_ui_tree: 'ax-tree',
  find_controls: 'find-controls',
  ax_press: 'ax-press',
  ax_set_value: 'ax-set-value',
  bg_click: 'bg-click',
};

const flags = {
  role: '--role', title_contains: '--title-contains', value_contains: '--value-contains', action: '--action', max_results: '--max-results',
  save_path: '--save-path', app: '--app', window_id: '--window-id', grid: '--grid', max_width: '--max-width', pid: '--pid',
  window_title: '--window-title', max_depth: '--max-depth', max_nodes: '--max-nodes', path: '--path',
  value: '--value', x: '--x', y: '--y', button: '--button', clicks: '--clicks', dy: '--dy', text: '--text',
};

const eventTools = new Set(['bg_click', 'bg_type_or_scroll', 'type_text', 'press_key', 'paste', 'drag', 'click', 'scroll']);

export function createRunner({
  helper = join(root, 'bin/mac-ghost-helper'),
  prefix = [],
  stateDir = join(root, '.local'),
  timeout = 30000,
  sessionIdleTimeoutMs = 60000,
} = {}) {
  const pool = createSessionPool({
    helper,
    prefix,
    idleTimeoutMs: sessionIdleTimeoutMs,
    requestTimeoutMs: Math.min(timeout, 15000),
  });

  async function invoke(args, callTimeout = timeout) {
    let output;
    try {
      output = (await run(helper, [...prefix, ...args], {
        timeout: callTimeout,
        killSignal: 'SIGKILL',
        maxBuffer: 16 * 1024 * 1024,
      })).stdout;
    } catch (error) {
      if (error.killed || error.signal || typeof error.code !== 'number') {
        throw new Problem('HELPER_FAILED', 'Helper unavailable, terminated or timed out. Read back state before retrying.');
      }
      output = error.stdout;
      try {
        const { error: e, focusAudit } = JSON.parse(output);
        if (typeof e?.code === 'string' && typeof e.message === 'string') {
          throw new Problem(e.code, e.message, focusAudit);
        }
      } catch (parse) {
        if (parse instanceof Problem) throw parse;
      }
      throw new Problem('HELPER_FAILED', 'Helper exited without a valid error response.');
    }
    try {
      const result = JSON.parse(output);
      if (result?.ok !== true) throw new Error();
      return result;
    } catch {
      throw new Problem('HELPER_PROTOCOL', 'Invalid native helper response.');
    }
  }

  async function audit(name, status) {
    // 仅记录固定工具名与状态类别，并在写入前核验目录属主/0700 权限及已打开 fd 属主/0600 权限。
    try {
      await mkdir(stateDir, { recursive: true, mode: 0o700 });
      const dirInfo = await lstat(stateDir);
      const uid = typeof process.getuid === 'function' ? process.getuid() : null;
      if (!dirInfo.isDirectory() || (uid !== null && dirInfo.uid !== uid) || (dirInfo.mode & 0o077) !== 0) {
        throw new Error('Unsafe state directory.');
      }
      const file = await open(
        join(stateDir, 'audit.jsonl'),
        constants.O_CREAT | constants.O_WRONLY | constants.O_APPEND | constants.O_NOFOLLOW,
        0o600,
      );
      try {
        const info = await file.stat();
        if (!info.isFile() || (uid !== null && info.uid !== uid) || (info.mode & 0o777) !== 0o600) {
          throw new Error('Unsafe audit file permissions.');
        }
        await file.writeFile(JSON.stringify({ time: new Date().toISOString(), tool: name, status }) + '\n');
      } finally {
        await file.close();
      }
    } catch {
      throw new Problem('AUDIT_UNAVAILABLE', 'Cannot write the local audit file.');
    }
  }

  async function diagnoseUnavailable(name, error, callTimeout = timeout) {
    const p = await invoke(['permissions'], callTimeout);
    if (name === 'capture_window' && p.screenRecording === false) throw new Problem('SCREEN_PERMISSION', p.guidance);
    if (name !== 'capture_window' && p.accessibility === false) throw new Problem('AX_PERMISSION', p.guidance);
    if (eventTools.has(name) && p.postEvents === false) throw new Problem('EVENT_PERMISSION', p.guidance);
    throw error;
  }

  async function preflightTarget(name, args, callTimeout = timeout) {
    let inventory;
    try {
      inventory = (await invoke(['windows'], callTimeout)).windows;
    } catch (e) {
      if (e.code === 'WINDOWS_UNAVAILABLE') return diagnoseUnavailable(name, e, callTimeout);
      throw e;
    }
    if (!Array.isArray(inventory)) throw new Problem('HELPER_PROTOCOL', 'Missing window list.');
    const window = args.window_id === undefined ? undefined : inventory.find(w => w.windowId === args.window_id);
    if (args.window_id !== undefined && (!window || (args.pid && window.pid !== args.pid))) {
      return diagnoseUnavailable(name, new Problem('TARGET_UNAVAILABLE', 'Window disappeared or belongs to a different process.'), callTimeout);
    }
    const owned = inventory.filter(w => w.pid === (args.pid ?? window?.pid));
    if (!owned.length || owned.some(w => !w.appName && !w.bundleId)) {
      return diagnoseUnavailable(name, new Problem('TARGET_UNAVAILABLE', 'Cannot identify target.'), callTimeout);
    }
    if (owned.some(sensitive)) throw new Problem('SENSITIVE_TARGET', 'Protected process or window.');
    return { ok: true, owned, window };
  }

  async function guardedLegacy(name, args) {
    const command = name === 'bg_type_or_scroll'
      ? (args.mode === 'scroll' ? 'bg-scroll' : args.mode === 'type' ? 'bg-key' : null)
      : legacyCommands[name];
    if (!command) throw new Problem('UNKNOWN_TOOL', 'Unsupported command.');

    const argv = [command];
    for (const [key, value] of Object.entries(args)) {
      if (key === 'visible_only') { if (value) argv.push('--visible-only'); }
      else if (key === 'restore_focus') { if (value) argv.push('--restore-focus'); }
      else if (key === 'crop') argv.push('--crop', JSON.stringify(value));
      else if (key !== 'mode') argv.push(flags[key], String(value));
    }

    let expectedPath;
    if (args.save_path !== undefined) {
      const filename = basename(args.save_path);
      expectedPath = join(stateDir, 'captures', filename);
      if (filename.startsWith('.') || /[\u0000-\u001f\u007f]/u.test(filename) || !filename.toLowerCase().endsWith('.png') ||
          Buffer.byteLength(filename) > 255 || (args.save_path !== filename && args.save_path !== expectedPath)) {
        throw new Problem('INVALID_ARGUMENT', 'Use a new PNG filename directly inside .local/captures.');
      }
    }
    if (args.crop && (args.crop.x >= 1 || args.crop.y >= 1 || args.crop.x + args.crop.width > 1 || args.crop.y + args.crop.height > 1)) {
      throw new Problem('INVALID_ARGUMENT', 'Crop extends beyond the window.');
    }
    if (name === 'check_permissions') return invoke(argv);
    if (name === 'list_windows') {
      if (args.app && sensitive({ appName: args.app })) throw new Problem('SENSITIVE_TARGET', 'Protected application.');
      const list = await invoke(argv);
      if (!Array.isArray(list.windows)) throw new Problem('HELPER_PROTOCOL', 'Missing window list.');
      return { ...list, windows: list.windows.map(w => sensitive(w) ? { ...w, title: null, protected: true } : w) };
    }

    await preflightTarget(name, args);

    if (name !== 'capture_window') {
      const result = await invoke(argv);
      if (toolWrites.has(name) && (typeof result.focusAudit?.focusPreserved !== 'boolean' ||
          !result.focusAudit.beforeFrontmost || !result.focusAudit.afterFrontmost)) {
        throw new Problem('HELPER_PROTOCOL', 'Write returned without a focus audit. Inspect state before retrying.');
      }
      return result;
    }
    if (expectedPath) {
      const result = await invoke(argv);
      if (result.savedPath !== expectedPath) throw new Problem('HELPER_PROTOCOL', 'Unexpected saved screenshot path.');
      return result;
    }

    const folder = await mkdtemp(join(stateDir, 'capture-'));
    try {
      const output = join(folder, 'window.png');
      const { out, ...meta } = await invoke([...argv, '--out', output]);
      if (out !== output) throw new Problem('HELPER_PROTOCOL', 'Unexpected screenshot path.');
      const info = await stat(output);
      if (!info.isFile() || info.size > 64 * 1024 * 1024) throw new Problem('IMAGE_LIMIT', 'Reduce max_width.');
      const png = await readFile(output);
      if (png.length < 24 || !png.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')) ||
          png.toString('ascii', 12, 16) !== 'IHDR' || png.readUInt32BE(16) !== meta.width || png.readUInt32BE(20) !== meta.height) {
        throw new Problem('HELPER_PROTOCOL', 'Invalid PNG or image dimensions.');
      }
      return { content: [{ type: 'text', text: JSON.stringify(meta) }, { type: 'image', mimeType: 'image/png', data: png.toString('base64') }] };
    } finally {
      await rm(folder, { recursive: true, force: true });
    }
  }

  const sessionDeps = {
    pool,
    preflightTarget: (opName, target, ms) => preflightTarget(opName, target, ms),
    auditStep: (opName, status) => audit(`step:${opName}`, status),
  };

  async function runner(name, args) {
    const tool = tools.find(t => t.name === name);
    if (!tool) throw new Problem('UNKNOWN_TOOL', 'Unknown tool.');
    await audit(name, 'requested');
    try {
      if (!matches(args, tool.inputSchema)) {
        throw new Problem('INVALID_ARGUMENT', 'Arguments do not match the tool schema.');
      }
      if (v2SessionTools.has(name)) {
        let result;
        if (name === 'get_state') {
          result = { ok: true, state: await executeGetState(sessionDeps, args) };
        } else if (name === 'run_actions') {
          result = await executeRunActions(sessionDeps, args);
        } else if (v2ActionNames.has(name)) {
          result = await executeSingleAction(sessionDeps, name, args);
        }
        const status = result.focusAudit?.status;
        try {
          const outcome = result.ok === false
            ? (result.error?.code === 'SENSITIVE_TARGET' ? 'denied' : 'failed')
            : (status === 'changed' ? 'focus_changed' : status === 'unverified' ? 'focus_unverified' : 'returned');
          await audit(name, outcome);
        } catch (auditErr) {
          // 动作已执行但写后审计失败：保留 completed/effect/focusAudit/state，防止调用方盲目重放。
          return {
            isError: true,
            content: [{
              type: 'text',
              text: JSON.stringify({
                ...result,
                ok: false,
                phase: 'post_audit',
                error: {
                  code: 'AUDIT_UNAVAILABLE',
                  message: 'Operation completed, but post-action audit failed. Inspect returned state before retrying.',
                },
              }),
            }],
          };
        }
        return {
          ...(result.ok === false ? { isError: true } : {}),
          content: [{ type: 'text', text: JSON.stringify(result) }],
        };
      }

      const result = await guardedLegacy(name, args);
      const status = result.focusAudit?.status;
      try {
        await audit(name, status === 'changed' ? 'focus_changed' : status === 'unverified' ? 'focus_unverified' : 'returned');
      } catch (error) {
        error.focusAudit = result.focusAudit;
        throw error;
      }
      return result.content ? result : { content: [{ type: 'text', text: JSON.stringify(result) }] };
    } catch (error) {
      try {
        await audit(name, error.code === 'SENSITIVE_TARGET' ? 'denied' : 'failed');
      } catch (auditError) {
        auditError.focusAudit = error.focusAudit;
        error = auditError;
      }
      const e = error instanceof Problem
        ? error
        : (typeof error?.code === 'string'
          ? new Problem(error.code, error.message || 'Local tool operation failed.', error.focusAudit)
          : new Problem('TOOL_FAILED', 'Local tool operation failed.'));
      return {
        isError: true,
        content: [{ type: 'text', text: JSON.stringify({ ok: false, error: { code: e.code, message: e.message }, focusAudit: e.focusAudit }) }],
      };
    }
  }

  runner.close = () => pool.closeAll();
  return runner;
}
