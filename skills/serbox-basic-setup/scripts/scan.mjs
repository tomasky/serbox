#!/usr/bin/env node
// Read-only inventory for serbox-basic-setup. Names and sizes only.
import { existsSync, lstatSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const DEFAULT_FILES = [
  '.gitconfig',
  '.config/git/config',
  '.gitignore_global',
  '.vimrc',
  '.config/nvim/init.vim',
  '.config/nvim/init.lua',
  '.tmux.conf',
  '.bashrc',
  '.bash_aliases',
  '.zshrc',
  '.inputrc',
];

const CREDENTIAL = /(TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL)/i;

const args = process.argv.slice(2);
if (args.includes('-h') || args.includes('--help')) {
  process.stdout.write('usage: scan.mjs [--json]\n');
  process.exit(0);
}
if (args.some((a) => a !== '--json')) {
  process.stderr.write('scan.mjs: unknown argument\n');
  process.exit(2);
}

const home = homedir();
const files = [];
for (const rel of DEFAULT_FILES) {
  const full = join(home, rel);
  if (!existsSync(full)) continue;
  let stat;
  try {
    stat = lstatSync(full);
  } catch {
    continue;
  }
  files.push({
    path: rel,
    size: stat.isSymbolicLink() ? 0 : stat.size,
    symlink: stat.isSymbolicLink(),
  });
}

const env = Object.keys(process.env)
  .filter((name) => CREDENTIAL.test(name))
  .sort();

const report = {
  home,
  files,
  env,
  suggested: [
    files.length
      ? `copy ${files.filter((f) => !f.symlink).length} config file(s) with copy.sh`
      : 'no known config files found',
    env.length
      ? `store ${env.length} credential name(s) with serbox secrets set NAME`
      : 'no credential-like environment variables found',
  ],
};
process.stdout.write(JSON.stringify(report, null, 2) + '\n');
