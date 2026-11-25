#!/usr/bin/env bash
# Copy a git checkout into a serbox box (shortcut for the steps in SKILL.md).
# usage: move.sh REPO BOX [--dest PATH] [--no-git]
set -euo pipefail
root="${1:?usage: move.sh REPO BOX [--dest PATH] [--no-git]}"
box="${2:?usage: move.sh REPO BOX [--dest PATH] [--no-git]}"
shift 2
dest=""
git=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) dest="${2:?--dest needs a path}"; shift 2 ;;
    --no-git) git=0; shift ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "move.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
S="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$root" rev-parse --show-toplevel)"
[ -n "$dest" ] || dest="/data/home/$(basename "$root")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

node "$S/repo-files.mjs" --list0 "$root" > "$work/files"
tar -C "$root" --null -cf "$work/repo.tar" -T "$work/files"
if [ "$git" = 1 ]; then
  tar -C "$root" -rf "$work/repo.tar" .git
fi
serbox push "$box" "$work/repo.tar" /tmp/serbox-move.tar >/dev/null
serbox exec "$box" -- sh -c "mkdir -p '$dest' && tar -xf /tmp/serbox-move.tar -C '$dest' && rm /tmp/serbox-move.tar"
if [ "$git" = 1 ]; then
  serbox exec "$box" --workdir "$dest" -- 'git status --short'
fi
bash "$S/deps.sh" "$box" "$dest"
echo "moved $root to $box:$dest"
