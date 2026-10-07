#!/usr/bin/env node
// Launcher for scripts/install.sh. npm's Windows shims run .sh bins through /bin/sh with
// backslash paths, which breaks; a node entry point works the same on every OS.
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const script = path.join(__dirname, '..', 'scripts', 'install.sh');

function findBash() {
  if (process.platform !== 'win32') return 'bash';
  // Prefer Git Bash: System32\bash.exe is WSL, which can't see Windows paths or $HOME.
  const roots = [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Programs')];
  for (const root of roots.filter(Boolean)) {
    for (const rel of ['Git/bin/bash.exe', 'Git/usr/bin/bash.exe']) {
      const p = path.join(root, rel);
      if (fs.existsSync(p)) return p;
    }
  }
  const where = spawnSync('where', ['git'], { encoding: 'utf8' });
  for (const g of (where.stdout || '').split(/\r?\n/).filter(Boolean)) {
    const p = path.join(path.dirname(g), '..', 'bin', 'bash.exe');
    if (fs.existsSync(p)) return p;
  }
  return null;
}

const bash = findBash();
if (!bash) {
  console.error('fullstack-orchestrator needs Git Bash (https://git-scm.com/download/win).');
  process.exit(1);
}
const res = spawnSync(bash, [script, ...process.argv.slice(2)], { stdio: 'inherit' });
process.exit(res.status ?? 1);
