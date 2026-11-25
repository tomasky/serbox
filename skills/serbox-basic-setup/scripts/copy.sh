#!/usr/bin/env bash
# Copy approved config files into a serbox box.
# usage: copy.sh BOX [--dry-run] [FILE...]   (paths are relative to $HOME)
set -euo pipefail
box="${1:?usage: copy.sh BOX [--dry-run] [FILE...]}"
shift
dry=0
files=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    -*) echo "copy.sh: unknown option $arg" >&2; exit 2 ;;
    *) files+=("$arg") ;;
  esac
done
if [ ${#files[@]} -eq 0 ]; then
  files=(.gitconfig .config/git/config .vimrc .tmux.conf .bash_aliases .zshrc)
fi

for rel in "${files[@]}"; do
  case "$rel" in
    /*|*..*) echo "copy.sh: unsafe path $rel" >&2; exit 2 ;;
  esac
  src="$HOME/$rel"
  if [ -L "$src" ]; then
    echo "skip $rel (symlink)" >&2
    continue
  fi
  if [ ! -f "$src" ]; then
    echo "skip $rel (not a regular file)" >&2
    continue
  fi
  dest="/data/home/$rel"
  if [ "$dry" = 1 ]; then
    echo "would copy $rel -> $box:$dest"
    continue
  fi
  serbox exec "$box" -- "mkdir -p '$(dirname "$dest")'"
  serbox push "$box" "$src" "$dest" >/dev/null
  serbox exec "$box" -- "chmod 600 '$dest'"
  echo "copied $rel"
done
