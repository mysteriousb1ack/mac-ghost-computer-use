#!/bin/sh
set -eu
cd "$(dirname "$0")"
umask 077
exec node --input-type=module - "$@" <<'NODE'
import { constants } from 'node:fs';
import { access, cp, lstat, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const name = 'mac-ghost-computer-use';
let dest = join(homedir(), '.gemini/config/plugins', name), dryRun = false;
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--dry-run') dryRun = true;
  else if (args[i] === '--dest' && args[i + 1]) dest = resolve(args[++i]);
  else throw new Error('Usage: ./install_v11.sh [--dry-run] [--dest /path/to/plugins/mac-ghost-computer-use]');
}
if (basename(dest) !== name || dest === process.cwd() || process.platform !== 'darwin' ||
    process.arch !== 'arm64' || Number(process.versions.node.split('.')[0]) < 22) throw new Error('Check destination, Apple Silicon and Node 22+.');
const parent = dirname(dest), backups = join(dirname(parent), 'mac-ghost-backups');
const files = ['bin/mac-ghost-helper', 'src', 'skills', 'assets', 'README.md', 'README_ZH.md', 'LICENSE', 'plugin.json'];
for (const file of files) await access(file);
await access(files[0], constants.X_OK);
const help = JSON.parse(execFileSync(resolve(files[0]), ['--help'], { encoding: 'utf8' }));
const manifest = JSON.parse(await readFile('plugin.json', 'utf8'));
if (manifest.name !== name || manifest.version !== '2.0.2' || !help.commands['find-controls'] || !help.commands['session']) throw new Error('Build the v2.0.2 release first.');
const config = JSON.parse(await readFile('mcp_config.json', 'utf8'));
config.mcpServers['mac-ghost'].command = process.execPath;

async function existing(path) {
  try { return await lstat(path); } catch (e) { if (e.code !== 'ENOENT') throw e; }
}
async function checkDestination() {
  const info = await existing(dest);
  if (info && (!info.isDirectory() || JSON.parse(await readFile(join(dest, 'plugin.json'), 'utf8')).name !== name)) {
    throw new Error('Destination is not an existing MacGhost installation.');
  }
  return Boolean(info);
}
if (dryRun) {
  const upgrade = await checkDestination();
  console.log(JSON.stringify({ dryRun, version: manifest.version, operation: upgrade ? 'upgrade' : 'install', dest, backupParent: upgrade ? backups : null }));
} else {
  await mkdir(parent, { recursive: true, mode: 0o700 });
  await mkdir(backups, { recursive: true, mode: 0o700 });
  const lock = join(backups, '.install-lock');
  await mkdir(lock);
  let staging, previous, moved = false;
  try {
    const upgrade = await checkDestination();
    staging = await mkdtemp(join(backups, '.staging-'));
    await mkdir(join(staging, 'bin'));
    for (const file of files) await cp(file, join(staging, file), { recursive: true, verbatimSymlinks: true });
    await writeFile(join(staging, 'mcp_config.json'), JSON.stringify(config, null, 2) + '\n', { flag: 'wx' });
    if (upgrade) {
      const state = join(dest, '.local');
      const info = await existing(state);
      if (info && !info.isDirectory()) throw new Error('Unsafe existing state directory.');
      if (info) await cp(state, join(staging, '.local'), { recursive: true, verbatimSymlinks: true });
      previous = join(await mkdtemp(join(backups, 'previous-')), name);
      await rename(dest, previous);
      moved = true;
    }
    try { await rename(staging, dest); }
    catch (error) {
      if (moved) await rename(previous, dest);
      throw error;
    }
    console.log(JSON.stringify({ version: manifest.version, dest, backup: previous ?? null }));
  } finally {
    if (staging) await rm(staging, { recursive: true, force: true });
    await rm(lock, { recursive: true });
  }
}
NODE
