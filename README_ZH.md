# MacGhost Computer Use（中文说明）

> **补齐 Google Antigravity 缺失的原生 macOS 桌面 Computer Use 插件（同时兼容任意 MCP 客户端）：纯文本 AX 控件树帧间 Diff、单次 32 步动作编排、焦点漂移审计，零第三方依赖。**

[English README](README.md)

![MacGhost Architecture Overview](assets/hero_architecture.png)

---

## 为什么做 MacGhost？

**Google Antigravity** 自带很强的代码、终端和浏览器代理能力，但**目前并没有原生桌面级 Computer Use**，没法直接操作你 Mac 上的本地客户端软件（如 Finder、WPS/Office、MarginNote、Keynote、本地专业软件等）。而市面常见的截图型桌面操控方案每操作一步都要截一张整屏高清图，既狂烧图像 Token、容易打穿上下文缓存，又老抢占前台窗口。

**MacGhost v2.0.2** 专为 Google Antigravity 补齐这块原生桌面操控拼图，同时遵循标准 MCP 协议（Claude Desktop / Cursor / Codex 均可直连），完全基于 Apple 原生框架（`Accessibility`、`ScreenCaptureKit`、`CoreGraphics`）与 Node.js 22 标准库从零编写：

- **默认纯文本无图流**：`get_state` 读取紧凑 AX 控件树并分配稳定引用 `e<id>`，后续调用默认只返回相对上一帧的增量 Diff（`remove_ranges` + `upsert`），常规办公和桌面操作零图片传输。仅在画布或缺少 AX 标签时才按需用 `capture_window`（支持归一化裁剪和 `6×4` 网格坐标）。
- **单次 32 步批量连招**：`run_actions` 一次 MCP 调用即可串行执行最多 32 个步骤（支持点击、按键、富文本粘贴、选词、拖拽、等待、控件状态断言），遇到界面过期（`STALE_FRAME`）或焦点漂移自动停止不盲点。
- AX 读取、AXPress 和 AXSetValue 可在后台执行。`paste`、`type_text` 和 `press_key` 依赖目标应用内已聚焦的控件。`posted_unverified` 仅确认事件已投递，建议通过断言或回读核实效果。画布拖拽显式传入 `allow_activate: true` 会将目标窗口切到前台。
- 旧版写操作在投递前、投递后和 150 毫秒后采样焦点。v2 在投递前后采样，并在 UISettler 的 1–5 秒观察期后复查。可按需指定 `restore_focus`。
- 粘贴会检测外部修改，并在仍持有剪贴板时尽力恢复原有条目。`receipts[].clipboardRestore` 记录结果。HTML 支持不带属性的格式标签。
- **内置安全护栏与本地审计**：通过 [`src/guardrails.json`](src/guardrails.json) 自动拦截钥匙串、1Password、系统设置、Touch ID、支付确认与验证码窗口；调用审计以 `0600` 权限写入 `.local/audit.jsonl`。
- **零外部依赖**：纯 Swift 5.9 + Node.js 22 标准库，无需 `npm install`、无需 Python 运行时。

---

## 运行环境

- **macOS 14.0+**（Apple Silicon / ARM64）
- 源码编译需要 Xcode Command Line Tools、Swift 5.9+ 和 macOS 14.2 或更新的 SDK。
- **Node.js 22+**

---

## 快速开始

### 1. 编译与全量测试

```bash
git clone https://github.com/mysteriousb1ack/mac-ghost-computer-use.git
cd mac-ghost-computer-use

# 编译 Apple Silicon 原生 Swift helper 到 bin/mac-ghost-helper
./build.sh

# 运行 Swift 原生单测与 Node MCP 协议测试
./build.sh test
node --test tests/test_mac_ghost.mjs
```

### 2. 接入 MCP 宿主

- **Google Antigravity 插件一键安装**：
  ```bash
  ./install_v11.sh --dry-run   # 预览安装/升级计划
  ./install_v11.sh             # 关闭 Antigravity 后执行安装（自动备份旧版）
  ```
- **通用 MCP 客户端（Claude Desktop / Cursor / Windsurf 等）**：用 `node -p 'process.execPath'` 获取 Node 绝对路径并填入 `command`。
  ```json
  {
    "mcpServers": {
      "mac-ghost": {
        "command": "/absolute/path/to/node",
        "args": ["/你的本地路径/mac-ghost-computer-use/src/mcp-server.mjs"]
      }
    }
  }
  ```

### 3. 开启系统权限

在客户端调用一次 `check_permissions`，然后前往：
1. **系统设置 → 隐私与安全性 → 辅助功能**：勾选对应宿主应用
2. **系统设置 → 隐私与安全性 → 屏幕与系统音频录制**：仅在需要调用 `capture_window` 截图时勾选

重启宿主后再次调用 `check_permissions`，基础 AX 操控只需确认 `accessibility: true`。投递键鼠事件还会检查 `postEvents`。按需截图另需开启录屏并确认 `screenRecording: true`。旧版坐标写入须在指定窗口命中可核验的 AX 控件。截图前后均检查目标窗口控件树，检查不完整或超过 192 个节点时拒绝返回图像。

---

## 全部 17 个 MCP 工具速查

- **v2 会话与批处理**：`get_state`、`run_actions`
- **v2 原子动作**：`type_text`、`press_key`、`paste`、`perform_secondary_action`、`drag`、`select_text`
- **窗口发现、按需截图与基础操作**：`check_permissions`、`list_windows`、`find_controls`、`inspect_ui_tree`、`capture_window`、`ax_press`、`ax_set_value`、`bg_click`、`bg_type_or_scroll`

---

## 开源许可

[MIT License](LICENSE)
