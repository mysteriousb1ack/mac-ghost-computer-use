import { isDeepStrictEqual } from 'node:util';

const integer = (minimum, maximum) => ({ type: 'integer', minimum, maximum });
const text = (minLength = 1) => ({ type: 'string', minLength, maxLength: 65536 });

function schema(properties, required = []) {
  return { type: 'object', properties, required, additionalProperties: false };
}

const pid = integer(1, 2147483647);
const window_id = integer(1, 4294967295);
const point = { type: 'number', minimum: 0 };
const xy = { pid, window_id, x: point, y: point };
const path = {
  type: 'string',
  maxLength: 263,
  pattern: '^[0-9]{1,7}(/[0-9]{1,7}){0,32}$',
};
const grid = {
  type: 'string',
  pattern: '^([1-9]|1[0-9]|2[0-6])x([1-9]|[1-4][0-9]|50)$',
};
const restore_focus = { type: 'boolean', default: false };
const unit = { type: 'number', minimum: 0, maximum: 1 };
const extent = { ...unit, not: { const: 0 } };
const crop = schema(
  { x: unit, y: unit, width: extent, height: extent },
  ['x', 'y', 'width', 'height'],
);

// 拒绝真实换行与 Unicode 行分隔符；字面量两字符 \n 仍合法。
const singleLine = {
  ...text(),
  pattern: '^[^\\r\\n\\u0085\\u2028\\u2029]*(?![\\s\\S])',
};
const typeArgs = schema(
  { mode: { const: 'type' }, pid, restore_focus, text: singleLine },
  ['mode', 'pid', 'text'],
);
const scrollArgs = schema(
  {
    mode: { const: 'scroll' },
    ...xy,
    restore_focus,
    dy: { ...integer(-100000, 100000), not: { const: 0 } },
  },
  ['mode', 'pid', 'x', 'y', 'dy'],
);

const legacy = [
  [
    'check_permissions',
    'Report TCC permissions and manual System Settings guidance.',
    schema({}),
  ],
  [
    'list_windows',
    'List WindowServer windows; filter by owner substring or on-screen state.',
    schema({ app: text(), visible_only: { type: 'boolean' } }),
  ],
  [
    'capture_window',
    'Capture a window or normalized top-left crop. Grid is columns x rows; cellToPoint contains window-local centers. save_path saves a new PNG in .local/captures and returns metadata only.',
    schema({ window_id, grid, crop, save_path: text(), max_width: integer(1, 8192) }, ['window_id']),
  ],
  [
    'inspect_ui_tree',
    'Read accessible windows and controls. nodeId uses zero-based window/child indices. Window title filter is exact.',
    schema({ pid, window_title: text(0), max_depth: integer(0, 32), max_nodes: integer(1, 1000) }, ['pid']),
  ],
  [
    'ax_press',
    'Press a control from the current AX tree using its nodeId as path.',
    schema({ pid, path, restore_focus }, ['pid', 'path']),
  ],
  [
    'ax_set_value',
    'Set a writable control value using its current AX nodeId.',
    schema({ pid, path, restore_focus, value: text(0) }, ['pid', 'path', 'value']),
  ],
  [
    'bg_click',
    'Post a click at window-local top-left points. Supply window_id for a multi-window app and verify the effect.',
    schema({ ...xy, restore_focus, button: { enum: ['left', 'right'] }, clicks: integer(1, 2) }, ['pid', 'x', 'y']),
  ],
  [
    'bg_type_or_scroll',
    'Post Unicode text to the process focused control, or a pixel scroll at window-local points. Verify the effect.',
    {
      ...schema({
        ...xy,
        restore_focus,
        mode: { type: 'string', enum: ['type', 'scroll'] },
        text: singleLine,
        dy: scrollArgs.properties.dy,
      }, ['pid', 'mode']),
      oneOf: [typeArgs, scrollArgs],
    },
  ],
  [
    'find_controls',
    'Search accessible controls natively. Exact window_title, role and action; case-insensitive title/value substrings. Returns matching nodeIds, states and truncation.',
    schema({
      pid,
      window_title: text(0),
      role: text(),
      title_contains: text(),
      value_contains: text(),
      action: text(),
      max_results: integer(1, 100),
    }, ['pid']),
  ],
];

// 精确约束 e<uint64> 格式，避免超出 64 位无符号整数范围。
function uint64Pattern() {
  const limit = '18446744073709551615';
  const choices = ['0', '[1-9][0-9]{0,18}', limit];
  for (let i = 1; i < limit.length; i++) {
    const digit = Number(limit[i]);
    if (digit > 0) {
      choices.push(limit.slice(0, i) + '[0-' + (digit - 1) + '][0-9]{' + (19 - i) + '}');
    }
  }
  return '^e(?:' + choices.join('|') + ')(?![\\s\\S])';
}

const ref = { type: 'string', pattern: uint64Pattern() };
const snapshot = text();
const target = { pid, window_id, snapshot };
const targetKeys = Object.keys(target);
const nonZeroDy = { ...integer(-100000, 100000), not: { const: 0 } };
const keyChord = {
  type: 'string',
  minLength: 1,
  maxLength: 64,
  pattern: '^(?:(?:super|cmd|ctrl|control|alt|option|shift)\\+){0,4}(?:[a-zA-Z0-9]|Return|Tab|Escape|BackSpace|Delete|space|Left|Right|Up|Down|Home|End|Page_Up|Page_Down|KP_[0-9]|F(?:[1-9]|1[0-9]|20))(?![\\s\\S])',
};

// 独立暴露的 6 个 v2 原子动作（同时也是 run_actions 的合法步骤）。
const atomic = [
  [
    'type_text',
    'Type a single line into the referenced or focused control; rejects line breaks (use paste or press_key Return).',
    { ref, text: singleLine },
    ['text'],
  ],
  [
    'press_key',
    'Send one xdotool-style key chord (e.g. Return, Tab, super+s, super+shift+Left) to the target window.',
    { key: keyChord },
    ['key'],
  ],
  [
    'paste',
    'Paste plain text, Markdown or HTML via multi-format clipboard with automatic restore of prior clipboard contents.',
    { ref, text: text(), format: { enum: ['text', 'md', 'html'], default: 'text' } },
    ['text'],
  ],
  [
    'perform_secondary_action',
    'Perform an exact AX action (e.g. AXShowMenu, AXIncrement) exposed on a referenced control.',
    { ref, action: text() },
    ['ref', 'action'],
  ],
  [
    'drag',
    'Smoothly drag between two window-local points or along a multi-point path (points); supports opt-in allow_activate for PencilKit/canvas gestures and always releases mouse button on interruption.',
    {
      from_x: point,
      from_y: point,
      to_x: point,
      to_y: point,
      points: {
        type: 'array',
        minItems: 2,
        maxItems: 256,
        items: schema({ x: point, y: point }, ['x', 'y']),
      },
      duration_ms: integer(0, 5000),
      allow_activate: { type: 'boolean', default: false },
    },
    [],
  ],
  [
    'select_text',
    'Select matched text or place cursor before/after it in an editable control using UTF-16 ranges.',
    {
      ref,
      text: text(),
      prefix: text(0),
      suffix: text(0),
      selection_type: { enum: ['text', 'cursor_before', 'cursor_after'], default: 'text' },
    },
    ['ref', 'text'],
  ],
];

const step = (name, fields, keys) => schema({ op: { const: name }, ...fields }, ['op', ...keys]);

// 批内额外支持的基础动作（复用同一窗口与 snapshot）以及 wait / assert。
const batchOnlySteps = [
  step('ax_press', { ref }, ['ref']),
  step('ax_set_value', { ref, value: text(0) }, ['ref', 'value']),
  step('click', { x: point, y: point, button: { enum: ['left', 'right'] }, clicks: integer(1, 2) }, ['x', 'y']),
  step('scroll', { x: point, y: point, dy: nonZeroDy }, ['x', 'y', 'dy']),
  step('wait', { ms: integer(1, 5000) }, ['ms']),
  step('assert', {
    ref,
    role: text(),
    title: text(0),
    condition: { enum: ['exists', 'absent', 'enabled', 'focused'] },
  }, ['condition']),
];

const allSteps = [
  ...atomic.map(([name, , fields, keys]) => step(name, fields, keys)),
  ...batchOnlySteps,
];

export const legacyToolNames = new Set(legacy.map(([name]) => name));
export const v2ActionNames = new Set(atomic.map(([name]) => name));
export const v2SessionTools = new Set(['get_state', 'run_actions', ...v2ActionNames]);
export const toolWrites = new Set([
  'ax_press', 'ax_set_value', 'bg_click', 'bg_type_or_scroll', 'run_actions', ...v2ActionNames,
]);

export const tools = [
  ...legacy,
  [
    'get_state',
    'Read compact text-only AX tree for a window; returns an incremental diff against the previous or specified snapshot by default (zero images).',
    schema({
      pid,
      window_id,
      since: snapshot,
      full: { type: 'boolean', default: false },
      max_depth: integer(0, 32),
      max_nodes: integer(1, 1000),
      diff_lines: integer(1, 2000),
    }, ['pid', 'window_id']),
  ],
  [
    'run_actions',
    'Validate and execute up to 32 sequential actions/waits/asserts on one window; stops on first error and returns the latest AX diff and focusAudit.',
    schema({
      ...target,
      restore_focus,
      timeout_ms: { ...integer(1, 15000), default: 10000 },
      steps: { type: 'array', minItems: 1, maxItems: 32, items: { oneOf: allSteps } },
    }, [...targetKeys, 'steps']),
  ],
  ...atomic.map(([name, description, fields, keys]) => [
    name,
    description,
    schema({ ...target, restore_focus, ...fields }, [...targetKeys, ...keys]),
  ]),
].map(([name, description, inputSchema]) => ({ name, description, inputSchema }));

function hasType(value, type) {
  switch (type) {
    case 'object': return value !== null && typeof value === 'object' && !Array.isArray(value);
    case 'array': return Array.isArray(value);
    case 'integer': return Number.isInteger(value);
    case 'number': return Number.isFinite(value);
    case 'null': return value === null;
    case 'string':
    case 'boolean': return typeof value === type;
    default: return false;
  }
}

export function matches(value, spec) {
  if (typeof value === 'string' && value.includes('\0')) return false;
  if (typeof spec === 'boolean') return spec;

  if (spec.type !== undefined && ![].concat(spec.type).some(type => hasType(value, type))) return false;
  if (Object.hasOwn(spec, 'const') && !isDeepStrictEqual(value, spec.const)) return false;
  if (spec.enum && !spec.enum.some(item => isDeepStrictEqual(value, item))) return false;
  if (Object.hasOwn(spec, 'not') && matches(value, spec.not)) return false;
  if (spec.oneOf && spec.oneOf.filter(branch => matches(value, branch)).length !== 1) return false;

  if (Array.isArray(value)) {
    if (value.length < (spec.minItems ?? 0) || value.length > (spec.maxItems ?? Infinity)) return false;
    return spec.items === undefined || value.every(item => matches(item, spec.items));
  }

  if (hasType(value, 'object')) {
    if (spec.required?.some(key => !Object.hasOwn(value, key))) return false;
    const properties = spec.properties ?? {};
    return Object.keys(value).every(key => {
      const field = Object.hasOwn(properties, key) ? properties[key] : spec.additionalProperties;
      return field === undefined || matches(value[key], field);
    });
  }

  if (typeof value === 'number') {
    return Number.isFinite(value) &&
      value >= (spec.minimum ?? -Infinity) && value <= (spec.maximum ?? Infinity);
  }

  if (typeof value === 'string') {
    const length = Array.from(value).length;
    return length >= (spec.minLength ?? 0) && length <= (spec.maxLength ?? Infinity) &&
      (spec.pattern === undefined || new RegExp(spec.pattern, 'u').test(value));
  }

  return true;
}
