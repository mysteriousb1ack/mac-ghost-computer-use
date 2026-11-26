---
name: mac-ghost
description: 使用 MacGhost v2 MCP 在 macOS 后台高效读取与批量操控指定窗口。默认纯文本紧凑 AX 树与帧间 Diff、支持批量动作编排、组合快捷键、富文本粘贴与进程定向输入。
---

1. **权限与目标确认**：先用 `check_permissions` 检查宿主的 `accessibility`、`screenRecording` 与 `postEvents`。用 `list_windows` 获取目标应用的 `pid`、`windowId` 与标题（PID/窗口 ID 可能复用）。浏览器已开授权 CDP 会话时优先用 `stealth-cdp`。
2. **默认纯文本无图流（优先 `get_state`）**：
   - 先调 `get_state({ pid, window_id })` 获取紧凑文本 AX 树、`snapshot` 与节点 `ref`（如 `e12`）；
   - 后续调 `get_state({ pid, window_id })` 默认只返回相对上一帧的增量 Diff（`remove_ranges` + `upsert`），零图片载荷；需要完整树时传 `full: true`；
   - 仅在画布、纯图片或缺少 AX 标签的界面再显式调用 `capture_window`（如 `{"window_id":42,"grid":"6x4","max_width":1440}` 或传 `save_path` 仅拿元数据）。
3. **批量连招（优先 `run_actions`）**：
   - 多步连续操作优先合并为单次 `run_actions({ pid, window_id, snapshot, steps: [...] })`（最多 32 步），支持 `ax_press`、`ax_set_value`、`click`、`scroll`、`type_text`、`press_key`、`paste`、`perform_secondary_action`、`drag`、`select_text`、`wait`、`assert`；
   - 批内遇首个失败或焦点漂移立即停止、不回滚，并返回 `completed`、`failed_index`、`effect`、`focusAudit` 与相对入批 `snapshot` 的最新 Diff。若返回 `STALE_FRAME` / `STALE_ELEMENT`，重新调用 `get_state` 刷新引用。
4. **文本、快捷键与富文本粘贴**：
   - `type_text` 与 `bg_type_or_scroll(mode: "type")` 严格禁止真实换行；多行或带排版内容（Word/Keynote/Pages/WPS/邮件/IM）一律用 `paste({ format: "text" | "md" | "html", text })`（自动无损备份并恢复原剪贴板）；提交表单显式发 `press_key({ key: "Return" })`；
   - `press_key` 支持 xdotool 风格组合键（如 `super+s`、`super+shift+Left`、`Tab`、`Escape`），禁止用 `cmd+v`/`super+v` 绕过 `paste`；
   - 改词或放光标用 `select_text`（支持 `prefix`/`suffix` 消歧与 `text`/`cursor_before`/`cursor_after`）；特殊原生动作（如 `AXShowMenu`）用 `perform_secondary_action`。
5. **焦点与安全红线**：
   - 关注每次写入返回的 `focusAudit`，出现 `changed` 或 `unverified` 时暂停连续写入并向用户确认；仅在显式需要时传 `restore_focus: true`；
   - 遇到钥匙串、凭据、系统授权、验证码、支付或身份认证页面，立即停止自动化交由用户手动处理，遇到 `SENSITIVE_TARGET` 立即结束操作。
