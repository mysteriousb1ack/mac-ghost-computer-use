import { spawn } from 'node:child_process';

const bytes = value => Buffer.byteLength(JSON.stringify(value));
const problem = (code, effect = 'not_started') =>
  Object.assign(new Error(code), { code, effect });

/**
 * 按 PID 托管常驻 mac-ghost-helper session 子进程池。
 * 单会话内严格串行请求；崩溃、EOF 或超时即清理并拒绝挂起任务。
 */
export function createSessionPool({
  helper, prefix = [], idleTimeoutMs = 60000, requestTimeoutMs = 10000,
}) {
  const sessions = new Map();
  const validMs = n => Number.isInteger(n) && n > 0 && n <= 2147483647;

  if (!validMs(idleTimeoutMs) || !validMs(requestTimeoutMs)) {
    throw problem('INVALID_ARGUMENT');
  }

  function start(sessionKey, pid) {
    const child = spawn(helper, [...prefix, 'session', '--pid', String(pid)], {
      stdio: ['pipe', 'pipe', 'ignore'],
    });
    const queue = [];
    let active, idle;
    let dead = false;
    let sequence = 0;
    let chunks = [];
    let size = 0;

    function stop(code = 'SESSION_CLOSED', { gracefulMs = 0 } = {}) {
      if (dead) return;
      dead = true;
      clearTimeout(idle);
      if (sessions.get(sessionKey) === session) sessions.delete(sessionKey);

      // A killed helper cannot release a held global mouse button. Closing stdin
      // lets the drag observe peer shutdown and unwind its native cleanup first.
      const finishingDrag = active?.op === 'drag' && active.sent;
      const effectiveGracefulMs = gracefulMs > 0
        ? gracefulMs
        : (active?.op === 'paste' && active.sent ? 1200 : 0);

      for (const job of [active, ...queue]) {
        if (!job) continue;
        clearTimeout(job.timer);
        job.reject(problem(code, job.sent ? 'unknown' : 'not_started'));
      }
      queue.length = 0;
      active = undefined;
      chunks = [];
      size = 0;
      if (finishingDrag) {
        child.stdin.end();
      } else if (effectiveGracefulMs > 0) {
        // 对正在执行的 paste 事务给予短暂优雅退出窗口，允许 Swift 完成剪贴板还原再退出。
        child.stdin.end();
        const killTimer = setTimeout(() => child.kill('SIGKILL'), effectiveGracefulMs);
        killTimer.unref();
        child.once('exit', () => clearTimeout(killTimer));
      } else {
        child.stdin.destroy();
        child.kill('SIGKILL');
      }
    }

    function pump() {
      clearTimeout(idle);
      if (dead || active) return;
      while (queue.length) {
        const next = queue.shift();
        if (performance.now() >= next.end) {
          clearTimeout(next.timer);
          next.reject(problem('TIMEOUT', 'not_started'));
          continue;
        }
        active = next;
        break;
      }

      if (!active) {
        idle = setTimeout(() => stop('SESSION_CLOSED'), idleTimeoutMs);
        idle.unref();
        return;
      }
      active.sent = true;
      child.stdin.write(active.line);
    }

    function enqueue(op, params, ms) {
      const id = String(++sequence);
      const end = performance.now() + ms;
      const line = JSON.stringify({ id, op, params }) + '\n';

      return new Promise((resolve, reject) => {
        const job = { id, op, end, line, timer: null, resolve, reject, sent: false };
        job.timer = setTimeout(() => {
          if (active === job) {
            stop('TIMEOUT', { gracefulMs: op === 'paste' ? 1200 : 0 });
          } else {
            const idx = queue.indexOf(job);
            if (idx >= 0) queue.splice(idx, 1);
            job.reject(problem('TIMEOUT', 'not_started'));
          }
        }, ms);
        queue.push(job);
        pump();
      });
    }

    const session = { stop, enqueue };
    sessions.set(sessionKey, session);

    child.stdout.on('data', chunk => {
      let offset = 0;
      while (!dead && offset < chunk.length) {
        const newline = chunk.indexOf(10, offset);
        const part = chunk.subarray(offset, newline < 0 ? chunk.length : newline);
        size += part.length;
        if (!active || size > 16 * 1024 * 1024) return stop('HELPER_PROTOCOL');
        chunks.push(part);
        if (newline < 0) break;

        let reply;
        try {
          reply = JSON.parse(Buffer.concat(chunks, size).toString('utf8'));
        } catch {
          return stop('HELPER_PROTOCOL');
        }
        if (String(reply?.id) !== active.id || typeof reply.ok !== 'boolean' ||
            (!reply.ok && typeof reply.error?.code !== 'string')) {
          return stop('HELPER_PROTOCOL');
        }
        if (performance.now() >= active.end) return stop('TIMEOUT');

        clearTimeout(active.timer);
        active.resolve(reply);
        active = undefined;
        chunks = [];
        size = 0;
        offset = newline + 1;
        pump();
      }
    });

    for (const stream of [child, child.stdin, child.stdout]) {
      stream.on('error', () => stop('HELPER_FAILED'));
    }
    child.stdout.once('end', () => stop('HELPER_FAILED'));
    child.once('exit', () => stop('HELPER_FAILED'));
    child.once('close', () => stop('HELPER_FAILED'));
    return session;
  }

  return {
    async request(pid, op, params, timeoutMs = requestTimeoutMs) {
      if (!Number.isInteger(pid) || pid < 1 || pid > 2147483647 ||
          !validMs(timeoutMs)) throw problem('INVALID_ARGUMENT');
      const key = params?.window_id !== undefined ? `${pid}:${params.window_id}` : String(pid);
      return (sessions.get(key) ?? start(key, pid)).enqueue(op, params, timeoutMs);
    },
    close(pid, windowId) {
      if (windowId !== undefined) {
        sessions.get(`${pid}:${windowId}`)?.stop();
        return;
      }
      for (const [k, s] of [...sessions.entries()]) {
        if (k === String(pid) || k.startsWith(`${pid}:`)) s.stop();
      }
    },
    closeAll() {
      for (const session of [...sessions.values()]) session.stop();
    },
  };
}

const encoded = /data:[^\s,]*;base64,|(?:^|[^A-Za-z0-9+/])[A-Za-z0-9+/]{16,}={1,2}(?:$|[^=])|[A-Za-z0-9+/_-]{96,}|iVBORw0KGgo|\/9j\/4|R0lGOD/i;
const plain = value => typeof value === 'string' && !encoded.test(value);
const isRef = value => typeof value === 'string' && /^e(?:0|[1-9]\d{0,19})$/.test(value);
const invalid = () => { throw problem('HELPER_PROTOCOL'); };

/**
 * 清洗并裁剪状态载荷：禁止图片/二进制载荷、剔除受保护节点敏感字段、强制 64 KiB 字节上限。
 */
export function sanitizeStatePayload(state, maxBytes = 65536, { fallbackReason } = {}) {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw problem('INVALID_ARGUMENT');

  const diff = state?.kind === 'diff';
  if ((!diff && state?.kind !== 'full') || !plain(state.snapshot) || !state.snapshot ||
      (diff && (!plain(state.base) || !state.base))) invalid();

  const out = {
    kind: state.kind,
    snapshot: state.snapshot,
    complete: state.complete !== false && state.truncated !== true,
    truncated: state.truncated === true,
  };
  if (diff) {
    out.base = state.base;
    if (!Array.isArray(state.remove_ranges) ||
        !state.remove_ranges.every(range =>
          Array.isArray(range) && range.length === 2 &&
          range.every(n => Number.isSafeInteger(n) && n >= 0) &&
          range[0] <= range[1])) invalid();
    out.remove_ranges = state.remove_ranges;
  } else {
    const reason = fallbackReason ?? state.reason ?? state.fallback_reason;
    if (plain(reason)) out.reason = reason;
    out.remove_ranges = [];
  }

  // 统一输出 upsert（同时兼容 Swift full 的 upsert 与测试 mock 的 nodes）。
  const sourceRows = Array.isArray(state.upsert) ? state.upsert
    : (!diff && Array.isArray(state.nodes) ? state.nodes : null);
  if (!sourceRows) invalid();

  const rows = out.upsert = [];
  let used = bytes(out);
  if (used > maxBytes) throw problem(diff ? 'DIFF_BYTE_LIMIT' : 'STATE_LIMIT');

  for (const node of sourceRows) {
    if (!node || !isRef(node.ref) || (node.parent != null && !isRef(node.parent))) invalid();

    const row = { ref: node.ref };
    if (Object.hasOwn(node, 'parent')) row.parent = node.parent;
    if (Number.isSafeInteger(node.order)) row.order = node.order;

    const secure = Object.entries(node).some(([key, value]) =>
      /secure|protected|password|sensitive/i.test(key) && Boolean(value)) ||
      /secure|password|protected/i.test(
        [node.role, node.subrole, node.subRole, node.AXSubrole].join(' '),
      );

    for (const key of ['enabled', 'focused', 'selected', 'editable']) {
      if (typeof node[key] === 'boolean') row[key] = node[key];
    }
    if (plain(node.role)) row.role = node.role;

    if (secure) {
      row.protected = true;
    } else {
      for (const key of ['title', 'description', 'value', 'subrole']) {
        if (plain(node[key]) || (key === 'value' &&
            (Number.isFinite(node[key]) || typeof node[key] === 'boolean'))) {
          row[key] = node[key];
        }
      }
      if (Array.isArray(node.actions)) row.actions = node.actions.filter(plain);
      if (node.frame && typeof node.frame === 'object' &&
          ['x', 'y', 'width', 'height'].every(k => Number.isFinite(node.frame[k]))) {
        row.frame = { x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height };
      }
    }

    const cost = bytes(row) + Number(rows.length > 0);
    if (used + cost > maxBytes) {
      // Diff 不可截断输出（否则保留 remove_ranges 却丢失部分 upsert 会导致状态损坏），改由调用方回退受限 full。
      if (diff) throw problem('DIFF_BYTE_LIMIT');
      out.truncated = true;
      out.complete = false;
      // 保留原始 snapshot 供已返回 ref 执行动作，同时显式标明不可作为后续 diff 基线。
      out.baseline_usable = false;
      while (rows.length > 0 && bytes(out) > maxBytes) rows.pop();
      if (bytes(out) > maxBytes) throw problem('STATE_LIMIT');
      break;
    }
    rows.push(row);
    used += cost;
  }
  return out;
}
