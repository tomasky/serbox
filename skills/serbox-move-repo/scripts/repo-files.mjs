#!/usr/bin/env node
// Plan which files of a git checkout move into a serbox box.
// Prints names and sizes only; never reads file contents.
import { spawnSync } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';

const EXCLUDED_DIRS = new Set([
  'node_modules', 'target', 'dist', 'build', 'out', '.next', '.nuxt',
  '.svelte-kit', '.turbo', '.cache', 'coverage', '__pycache__', '.venv',
  'venv', '.tox', '.mypy_cache', '.pytest_cache', '.gradle', '.idea',
  '.vscode', 'bazel-bin', 'bazel-out', 'bazel-testlogs', '.dart_tool',
  '.terraform', '.serverless', '.parcel-cache', '.angular', '.expo',
]);

function usage(message) {
  if (message) process.stderr.write(`repo-files: ${message}\n`);
  process.stderr.write('usage: repo-files.mjs [--json|--list0] [--keep NAME] [ROOT]\n');
  process.exit(2);
}

const argv = process.argv.slice(2);
let mode = 'json';
let keep = new Set();
let rootArg = '';
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--json') mode = 'json';
  else if (a === '--list0') mode = 'list0';
  else if (a === '--keep') {
    if (i + 1 >= argv.length) usage('--keep needs a name');
    keep.add(argv[++i]);
  } else if (a === '-h' || a === '--help') usage();
  else if (a.startsWith('-')) usage(`unknown option ${a}`);
  else if (!rootArg) rootArg = a;
  else usage(`unexpected argument ${a}`);
}

const cwd = resolve(rootArg || '.');
const root = spawnSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], {
  encoding: 'utf8',
});
if (root.status !== 0) usage(`${cwd} is not inside a git checkout`);
const rootDir = root.stdout.trim();

const listed = spawnSync(
  'git',
  ['-C', rootDir, 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
  { encoding: 'buffer', maxBuffer: 1024 * 1024 * 512 },
);
if (listed.status !== 0) {
  process.stderr.write(listed.stderr?.toString() || 'git ls-files failed\n');
  process.exit(1);
}

const parts = listed.stdout.toString('utf8').split('\0').filter(Boolean);
const tracked = new Set(
  spawnSync('git', ['-C', rootDir, 'ls-files', '-z', '--cached'], {
    encoding: 'buffer',
    maxBuffer: 1024 * 1024 * 512,
  }).stdout.toString('utf8').split('\0').filter(Boolean),
);

function excluded(rel) {
  const segments = rel.split('/');
  for (const segment of segments) {
    if (EXCLUDED_DIRS.has(segment)) return !keep.has(segment);
    if (/\.egg-info$/.test(segment) || /^bazel-/.test(segment)) {
      return !keep.has(segment);
    }
  }
  const base = segments[segments.length - 1];
  if (/\.(o|so|pyc|pyo|class|dylib|dll|exe|a)$/.test(base)) {
    return !keep.has(base);
  }
  return false;
}

const files = [];
let bytes = 0;
for (const rel of parts) {
  if (!tracked.has(rel) && excluded(rel)) continue;
  const full = join(rootDir, rel);
  if (!existsSync(full)) continue;
  let size = 0;
  try {
    size = statSync(full).size;
  } catch {
    continue;
  }
  files.push({ path: rel, size, tracked: tracked.has(rel) });
  bytes += size;
}

if (mode === 'list0') {
  process.stdout.write(files.map((f) => f.path).join('\0') + '\0');
} else {
  const skipped = parts.length - files.length;
  process.stdout.write(
    JSON.stringify({
      root: rootDir,
      total: files.length,
      bytes,
      skipped,
      excludedDirs: [...EXCLUDED_DIRS].sort(),
      files,
    }, null, 2) + '\n',
  );
}
