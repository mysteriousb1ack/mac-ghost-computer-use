#!/bin/sh
set -eu
cd "$(dirname "$0")"
[ "$(uname -sm)" = "Darwin arm64" ] || { echo 'Requires Apple Silicon macOS.' >&2; exit 1; }
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)' || { echo 'Node.js 22+ is required.' >&2; exit 1; }
[ -x bin/mac-ghost-helper ] || ./build.sh
bin/mac-ghost-helper --help >/dev/null
# Only publish a new directory. Copy the discovery manifest last.
node --input-type=module - <<'NODE'
import { mkdir, cp, readFile, writeFile, rm } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
const parent = join(homedir(), '.gemini/config/plugins');
const dest = join(parent, 'mac-ghost-computer-use');
await mkdir(parent, { recursive: true, mode: 0o700 });
try { await mkdir(dest, { mode: 0o700 }); }
catch (e) {
  if (e.code !== 'EEXIST') throw e;
  console.error('Destination exists. Move the existing plugin aside before installing:', dest);
  process.exit(1);
}
try {
  for (const item of ['bin', 'src', 'skills', 'assets', 'README.md', 'LICENSE']) {
    await cp(item, join(dest, item), { recursive: true, errorOnExist: true, force: false });
  }
  const config = JSON.parse(await readFile('mcp_config.json', 'utf8'));
  config.mcpServers['mac-ghost'].command = process.execPath;
  await writeFile(join(dest, 'mcp_config.json'), JSON.stringify(config, null, 2) + '\n', { flag: 'wx' });
  await cp('plugin.json', join(dest, 'plugin.json'), { errorOnExist: true, force: false });
} catch (e) { await rm(dest, { recursive: true, force: true }); throw e; }
console.log('Installed:', dest);
console.log('Rollback after closing the plugin host:');
console.log('mv "$HOME/.gemini/config/plugins/mac-ghost-computer-use" "$HOME/mac-ghost-computer-use.disabled-$(date +%s)"');
NODE
