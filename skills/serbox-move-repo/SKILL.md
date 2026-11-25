---
name: serbox-move-repo
description: Use when the user wants to move the repository they are working in into a serbox box - "move this repo to a box", "continue this work in the box", "copy my project into serbox". Copies the checkout, its worktrees, uncommitted and stashed work, then installs dependencies inside the box.
metadata:
  installed-by: serbox
---

# Move a local repository into a serbox box

This moves the git checkout of the current directory into one box and leaves
the local copy untouched. After it finishes the box has the same HEAD, index,
branches, stashes and worktrees, plus untracked files that git does not ignore.
Conversation history from agent tools is **not** copied; this skill only moves
the repository.

Paths in the examples assume this skill is installed at
`~/.agents/skills/serbox-move-repo` (or `~/.claude/skills/...`); adjust `S` if
yours is elsewhere.

Prerequisites: `git`, `tar`, `node` (for the file plan) and a working `serbox`
box. Run the steps in one shell session so `S`, `ROOT`, `BOX` and `DEST` stay
set.

## 1. Pick the box and destination

```sh
set -euo pipefail
S="$HOME/.agents/skills/serbox-move-repo/scripts"
ROOT="$(git rev-parse --show-toplevel)"
BOX="${BOX:-work}"
DEST="${DEST:-/data/home/$(basename "$ROOT")}"
serbox get "$BOX" >/dev/null || serbox create --name "$BOX" --template alpine
```

If the box does not exist, create it with the template the project needs
(`ubuntu`, `node`, `python`, ...; see `serbox templates`). A wrong template
means missing runtimes later.

## 2. See the plan

```sh
node "$S/repo-files.mjs" --json "$ROOT"
```

The plan lists the files that will move and the size. Build output and
dependency directories (`node_modules`, `target`, `dist`, `.venv`, caches, ...)
are skipped even when they are untracked; **tracked** files are always kept so
`git status` matches. Use `--keep NAME` to include an excluded directory by
literal name (for example a source tree that really lives in `build/`).

Before moving, tell the user:

- Git push and pull will not work in the box until credentials are configured
  there; environment secrets and git config are separate steps (see the
  `serbox-basic-setup` skill).
- Copying `.git/config` copies any remote URL, including an embedded token.
- Untracked `.env` files that git ignores are **not** copied. Move their values
  with `serbox secrets set`, never by printing them.

## 3. Copy the repository and its git data

```sh
node "$S/repo-files.mjs" --list0 "$ROOT" > /tmp/serbox-move.list
tar -C "$ROOT" --null -cf /tmp/serbox-move.tar -T /tmp/serbox-move.list
tar -C "$ROOT" -rf /tmp/serbox-move.tar .git
serbox push "$BOX" /tmp/serbox-move.tar /tmp/serbox-move.tar
serbox exec "$BOX" -- sh -c "mkdir -p '$DEST' && tar -xf /tmp/serbox-move.tar -C '$DEST' && rm /tmp/serbox-move.tar"
rm -f /tmp/serbox-move.list /tmp/serbox-move.tar
```

The second `tar -rf` adds `.git` (all branches, stashes, index and worktree
metadata) while the file list stays manageable. If the user does not want git
history in the box, omit that line and add `--no-git` when running
`move.sh` below.

## 4. Verify and install dependencies

```sh
serbox exec "$BOX" --workdir "$DEST" -- 'git status --short; git log -1 --oneline'
bash "$S/deps.sh" "$BOX" "$DEST"
```

`deps.sh` detects `package.json`, lockfiles, `Cargo.toml`, `go.mod`,
`requirements.txt`, `pyproject.toml` and `Gemfile`, and runs the matching
install command with the tool already present in the box. It does not install
missing runtimes; if a tool is absent, tell the user which template or package
to add.

## Shortcut

`move.sh` wraps steps 3 and 4:

```sh
bash "$S/move.sh" "$ROOT" "$BOX"            # keeps .git, installs deps
bash "$S/move.sh" "$ROOT" "$BOX" --no-git   # code only
```

The box and the local checkout are independent after the move. Nothing keeps
them in sync; later changes need another `push` or a git remote.
