import { setTimeout as delay } from 'node:timers/promises';
import { tools, matches, v2ActionNames } from './tool-schemas.mjs';
import { sanitizeStatePayload } from './ax-state.mjs';

const schemas = new Map(tools.map(tool => [tool.name, tool.inputSchema]));
const publicCodes = new Set((
  'INVALID_ARGUMENT STALE_FRAME STALE_ELEMENT STALE_SNAPSHOT STALE_WINDOW ' +
  'TARGET_UNAVAILABLE WINDOWS_UNAVAILABLE SENSITIVE_TARGET AX_PERMISSION AX_UNAVAILABLE EVENT_PERMISSION ' +
  'INCOMPLETE_ACTION CANCELLED VALIDATION_FAILED CLIPBOARD_RESTORE_FAILED CLIPBOARD_WRITE_FAILED UNSAFE_HTML PASTE_SEND_FAILED ' +
  'NO_FOCUSED_CONTROL DISABLED_CONTROL UNSUPPORTED_ACTION READ_ONLY OUT_OF_BOUNDS ' +
  'TEXT_NOT_FOUND AMBIGUOUS_TEXT MULTILINE_TEXT CLIPBOARD_CHANGED CLIPBOARD_UNREADABLE ' +
  'HELPER_FAILED HELPER_PROTOCOL SESSION_CLOSED TIMEOUT STATE_LIMIT ' +
  'ASSERT_FAILED ASSERTION_FAILED FOCUS_CHANGED FOCUS_UNVERIFIED AUDIT_UNAVAILABLE STATE_UNAVAILABLE'
).split(' '));

const fault = (code, message) => Object.assign(new Error(message ?? code), { code });
const publicCode = error => publicCodes.has(error?.code) ? error.code : 'HELPER_FAILED';
const remaining = end => Math.floor(end - performance.now());

async function bounded(end, fn) {
  const ms = remaining(end);
  if (ms <= 0) throw fault('TIMEOUT');
  let timer;
  try {
    const value = await Promise.race([
      fn(ms),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(fault('TIMEOUT')), ms);
      }),
    ]);
    if (remaining(end) < 0) throw fault('TIMEOUT');
    return value;
  } finally {
    clearTimeout(timer);
  }
}

function validate(name, args) {
  if (!schemas.has(name) || !matches(args, schemas.get(name))) {
    throw fault('INVALID_ARGUMENT', 'Arguments do not match the tool schema.');
  }
}

function checked(reply) {
  if (reply?.ok === true) return reply;
  if (reply?.ok !== false) throw fault('HELPER_PROTOCOL');
  throw Object.assign(fault(publicCode(reply.error), reply.error?.message), {
    effect: reply.effect ?? reply.error?.effect,
    focusAudit: reply.focusAudit,
  });
}

async function preflight(deps, name, target, end) {
  const result = await bounded(end, ms => deps.preflightTarget(name, target, ms));
  if (result === false) throw fault('TARGET_UNAVAILABLE');
  if (result?.ok === false) checked(result);
}

// 记录已在 JS 侧被截断的快照 ID 与窗口，强制后续基于它们的读取回到完整帧，避免漏节点。
const unusableBaselines = new Set();
const unusableWindowKeys = new Set();

async function readState(deps, args, end, internal = false) {
  await preflight(deps, 'get_state', args, end);
  const windowKey = `${args.pid}:${args.window_id}`;
  const forceFull = args.full === true ||
    (args.since ? unusableBaselines.has(args.since) : unusableWindowKeys.has(windowKey));
  const requestArgs = forceFull ? { ...args, full: true } : args;
  const params = internal ? { ...requestArgs, advance_baseline: false } : requestArgs;
  const reply = checked(await bounded(end, ms =>
    deps.pool.request(args.pid, 'get_state', params, ms)));

  const state = reply.state ?? reply;
  if (state.kind === 'unavailable') throw fault(publicCode({ code: state.reason }));
  let clean;
  try {
    clean = sanitizeStatePayload(state);
  } catch (err) {
    if (err?.code === 'DIFF_BYTE_LIMIT' && !requestArgs.full) {
      // Diff 超过 64 KiB 字节预算时，重新拉取受预算约束的 full 帧，绝不交付残缺 Diff。
      const fallbackReply = checked(await bounded(end, ms =>
        deps.pool.request(args.pid, 'get_state', { ...params, full: true }, ms)));
      const fallbackState = fallbackReply.state ?? fallbackReply;
      if (fallbackState.kind === 'unavailable') throw fault(publicCode({ code: fallbackState.reason }));
      clean = sanitizeStatePayload(fallbackState, 65536, { fallbackReason: 'diff_byte_budget' });
      if (clean.baseline_usable === false || clean.truncated) {
        unusableBaselines.add(clean.snapshot);
        unusableWindowKeys.add(windowKey);
      } else {
        unusableWindowKeys.delete(windowKey);
      }
      return clean;
    }
    throw err;
  }
  if (requestArgs.full && clean.kind !== 'full') throw fault('HELPER_PROTOCOL');
  if (!forceFull && args.since && clean.kind === 'diff' && clean.base !== args.since) {
    throw fault('HELPER_PROTOCOL');
  }
  if (!internal) {
    if (clean.baseline_usable === false || clean.truncated) {
      unusableBaselines.add(clean.snapshot);
      unusableWindowKeys.add(windowKey);
    } else {
      unusableWindowKeys.delete(windowKey);
    }
  }
  return clean;
}

export async function executeGetState(deps, args) {
  validate('get_state', args);
  return readState(deps, args, performance.now() + 10000);
}

function sanitizeFocusAudit(raw) {
  if (!raw || typeof raw !== 'object' || !raw.beforeFrontmost || !raw.afterFrontmost || typeof raw.focusPreserved !== 'boolean') {
    return { status: 'unverified', focusPreserved: false };
  }
  let status;
  if (raw.status === 'changed') status = 'changed';
  else if (raw.status === 'unverified') status = 'unverified';
  else if ((raw.status === 'preserved' || raw.status === 'unchanged') && raw.focusPreserved === true) status = 'preserved';
  else status = 'unverified';
  const out = { status, focusPreserved: status === 'preserved', beforeFrontmost: raw.beforeFrontmost, afterFrontmost: raw.afterFrontmost };
  if (raw.immediateFrontmost) out.immediateFrontmost = raw.immediateFrontmost;
  if (raw.restoration) out.restoration = raw.restoration;
  if (raw.afterRestoreFrontmost) out.afterRestoreFrontmost = raw.afterRestoreFrontmost;
  if (typeof raw.warning === 'string') out.warning = raw.warning;
  return out;
}

async function audit(deps, op, status, end) {
  try {
    await bounded(end, ms => deps.auditStep(op, status, ms));
  } catch (error) {
    throw fault(error?.code === 'TIMEOUT' ? 'TIMEOUT' : 'AUDIT_UNAVAILABLE');
  }
}

function assertState(state, selector) {
  const source = state.upsert ?? state.nodes ?? [];
  const rows = source.filter(node =>
    ['ref', 'role', 'title'].every(key =>
      selector[key] === undefined || selector[key] === node[key]));
  const exhaustive = state.complete && !state.truncated;

  let pass;
  switch (selector.condition) {
    case 'exists':
      pass = rows.length > 0;
      break;
    case 'absent':
      pass = exhaustive && rows.length === 0;
      break;
    default:
      pass = (exhaustive || Boolean(selector.ref)) && rows.length === 1 &&
        rows[0][selector.condition] === true;
  }
  if (!pass) throw fault('ASSERT_FAILED', 'State assertion failed.');
}

function hideSensitiveBodies(state, bodies, maskFreeText = false) {
  const nonEmpty = bodies.filter(b => typeof b === 'string' && b.length > 0);
  if (!nonEmpty.length && !maskFreeText) return state;
  const contains = value =>
    typeof value === 'string' && nonEmpty.some(body => value.includes(body));

  if ([state.snapshot, state.base].some(contains)) throw fault('STATE_UNAVAILABLE');
  if (contains(state.reason)) delete state.reason;

  for (const row of state.upsert ?? []) {
    if (maskFreeText) {
      // 粘贴/输入后的终态回执屏蔽所有可能承载分段或转换后正文的自由文本字段（含 title）。
      delete row.title;
      delete row.value;
      delete row.description;
    }
    for (const key of ['title', 'description', 'value', 'role', 'subrole']) {
      if (contains(String(row[key] ?? ''))) delete row[key];
    }
    if (row.actions) row.actions = row.actions.filter(action => !contains(action));
    if (contains(row.ref) || contains(row.parent)) throw fault('STATE_UNAVAILABLE');
  }
  return state;
}

export async function executeRunActions(deps, args) {
  const start = performance.now();
  let completed = 0;
  let effect = 'not_started';
  let focusAudit = null;
  let failure;
  const receipts = [];

  try {
    validate('run_actions', args);
    args = structuredClone(args);

    for (const step of args.steps) {
      if (step.op === 'assert' && step.ref === undefined && step.role === undefined && step.title === undefined) {
        throw fault('INVALID_ARGUMENT');
      }
      if (step.op !== 'press_key') continue;
      const parts = step.key.toLowerCase().split('+');
      const key = parts.pop();
      const aliases = { super: 'cmd', control: 'ctrl', option: 'alt' };
      const mods = parts.map(mod => aliases[mod] ?? mod);
      if (new Set(mods).size !== mods.length || (mods.includes('cmd') && key === 'v')) {
        throw fault('INVALID_ARGUMENT');
      }
    }
  } catch {
    return {
      ok: false, completed, failed_index: 0, effect,
      error: { code: 'INVALID_ARGUMENT', message: 'Invalid action batch or forbidden shortcut.' },
      focusAudit, state: { kind: 'unavailable', reason: 'INVALID_ARGUMENT' },
    };
  }

  const { pid, window_id, snapshot, restore_focus = false, steps } = args;
  const target = Object.freeze({ pid, window_id, snapshot });
  const end = start + (args.timeout_ms ?? 10000);
  const work = end - 800;
  const bodies = steps.flatMap(step => {
    if (['paste', 'select_text', 'type_text'].includes(step.op)) return [step.text];
    if (step.op === 'ax_set_value') return [step.value];
    return [];
  });

  for (const { op, ...fields } of steps) {
    effect = 'not_started';
    let requested = false;
    let resultAuditStarted = false;

    try {
      await audit(deps, op, 'requested', work);
      requested = true;

      if (op === 'wait') {
        if (remaining(work) < fields.ms) throw fault('TIMEOUT');
        await bounded(work, () => delay(fields.ms));
      } else if (op === 'assert') {
        await preflight(deps, 'assert', target, work);
        // 交由 Swift HelperSession 直接通过 CFEqual 与原 snapshot 核验元素身份，防止临时编号碰撞。
        checked(await bounded(work, ms =>
          deps.pool.request(pid, 'assert', { ...fields, ...target }, ms)));
      } else {
        await preflight(deps, op, target, work);
        focusAudit = null;
        const reply = await bounded(work, ms => {
          effect = 'unknown';
          const pasteWait = op === 'paste' ? Math.min(600, Math.max(50, Math.floor(ms / 3))) : undefined;
          return deps.pool.request(pid, op, {
            ...fields, ...target, restore_focus,
            return_diff: false, settle_ms: Math.min(5000, Math.max(1000, ms - 50)),
            ...(pasteWait !== undefined ? { paste_wait_ms: pasteWait } : {}),
          }, ms);
        });
        const receipt = Object.fromEntries(['posted', 'pasteEffect', 'code', 'clipboardRestore',
          'partial', 'mouseUpPosted', 'delivery', 'deliveryMode', 'windowId', 'pointCount']
          .filter(key => Object.hasOwn(reply, key)).map(key => [key, reply[key]]));
        receipts.push({ index: completed, op, ...receipt });
        focusAudit = sanitizeFocusAudit(reply.focusAudit);
        const unsent = reply.posted === false || reply.pasteEffect === 'not_sent';
        const partial = reply.partial === true || reply.mouseUpPosted === false;
        const restoreFailed = reply.clipboardRestore !== undefined && reply.clipboardRestore !== 'restored';
        if (unsent || partial || restoreFailed || reply.code || reply.pasteEffect === 'unknown') {
          effect = unsent ? 'not_started' : partial ? 'partial' : 'unknown';
          throw fault(reply.code ?? reply.error?.code ?? (restoreFailed ? 'CLIPBOARD_RESTORE_FAILED' : 'INCOMPLETE_ACTION'));
        }
        checked(reply);
        effect = 'applied';
        if (focusAudit.status === 'unverified') throw fault('FOCUS_UNVERIFIED');
        if (op === 'drag' && fields.allow_activate === true) {
          const observations = [focusAudit.afterFrontmost];
          if (focusAudit.status === 'changed') observations.push(focusAudit.immediateFrontmost);
          if (!observations.every(front => front?.pid === pid && front.activeWindow?.status === 'focused' &&
              front.activeWindow.windowId === window_id)) throw fault('FOCUS_CHANGED');
        } else if (focusAudit.status === 'changed') throw fault('FOCUS_CHANGED');
      }

      resultAuditStarted = true;
      await audit(deps, op, 'returned', work);
      completed++;
    } catch (error) {
      if (['not_started', 'applied', 'unknown'].includes(error?.effect)) {
        effect = error.effect;
      }
      if (error?.focusAudit) focusAudit = sanitizeFocusAudit(error.focusAudit);
      failure = publicCode(error);

      if (requested && !resultAuditStarted && remaining(work) > 0) {
        try {
          await audit(deps, op, failure === 'SENSITIVE_TARGET' ? 'denied' : 'failed', work);
        } catch (auditError) {
          failure = publicCode(auditError);
        }
      }
      break;
    }
  }

  const hasSensitiveInput = steps.some(step => ['paste', 'type_text', 'ax_set_value'].includes(step.op));
  let state;
  let readbackFailure = null;
  try {
    state = hideSensitiveBodies(
      await readState(deps, { pid, window_id, since: snapshot }, end),
      bodies,
      hasSensitiveInput,
    );
  } catch (error) {
    state = { kind: 'unavailable', reason: publicCode(error) };
    if (!failure) readbackFailure = state.reason;
  }

  if (failure) {
    return {
      ok: false, completed, failed_index: completed, effect,
      error: { code: failure, message: 'Operation stopped; inspect returned state before retrying.' },
      receipts, focusAudit, state,
    };
  }
  if (readbackFailure) {
    return {
      ok: false, completed, phase: 'readback', effect: completed > 0 ? 'applied' : 'not_started',
      error: { code: readbackFailure, message: 'Actions completed, but final state readback failed.' },
      receipts, focusAudit, state,
    };
  }
  return { ok: true, completed, receipts, focusAudit, state };
}

export async function executeSingleAction(deps, name, args) {
  if (!v2ActionNames.has(name)) throw fault('INVALID_ARGUMENT');
  validate(name, args);
  const { pid, window_id, snapshot, restore_focus = false, ...fields } = args;
  return executeRunActions(deps, {
    pid, window_id, snapshot, restore_focus,
    steps: [{ op: name, ...fields }],
  });
}
