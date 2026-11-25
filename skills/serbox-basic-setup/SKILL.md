---
name: serbox-basic-setup
description: Use when the user wants a serbox box set up like their machine - "put my tokens, git config and editor config in the box", "set up my box like my laptop", "move my dotfiles to serbox". Stores credentials as serbox secrets and copies approved git/editor config; moves no repository code (use serbox-move-repo for that).
metadata:
  installed-by: serbox
---

# Set up a serbox box like the user's machine

This skill has two separate parts. Credentials become serbox **secrets**;
ordinary configuration files are **copied** into the box. Keeping them separate
means a token is never written into a dotfile the user might share, and a
`.vimrc` is never mistaken for a secret.

Nothing here invents values. The scripts list names and sizes only; the user
approves what moves, and secret values are read with a hidden prompt (or piped
from the user's own command) and never printed.

Paths assume this skill is installed at `~/.agents/skills/serbox-basic-setup`;
adjust `S` if needed.

## 1. Inventory (read-only)

```sh
set -euo pipefail
S="$HOME/.agents/skills/serbox-basic-setup/scripts"
BOX="${BOX:-work}"
node "$S/scan.mjs" --json
```

The report contains:

- `files`: known git and editor config that exists, with `path`, `size` and
  `symlink` (symlinks are reported but never copied).
- `env`: **names** of environment variables that look like credentials
  (`*TOKEN*`, `*KEY*`, `*SECRET*`, `*PASSWORD*`, ...). No values.
- `suggested`: one line per group.

Show the user the names and let them choose. Do not read or echo the values.

## 2. Store credentials as secrets

Prefer a hidden prompt; the value never appears in shell history or logs:

```sh
read -r -s -p "Value for GITHUB_TOKEN: " VALUE; echo
printf '%s' "$VALUE" | serbox secrets set GITHUB_TOKEN
unset VALUE
serbox secrets ls                       # names only
```

If the user already has the value in an environment variable, pipe it without
printing it:

```sh
printf '%s' "${GITHUB_TOKEN:?not set}" | serbox secrets set GITHUB_TOKEN
```

Apply secrets to boxes:

```sh
serbox create --name "$BOX" --secrets GITHUB_TOKEN,OPENAI_API_KEY
serbox secrets push "$BOX"               # /data/.serbox/secrets.env, mode 0600
```

A box only receives a secret at `create` time when it is named in `--secrets`,
or later through `secrets push`. Adding a secret to the store does not change a
box that is already running. To use the pushed file:

```sh
serbox exec "$BOX" -- 'set -a; . /data/.serbox/secrets.env; set +a; env | grep -c TOKEN'
```

The last command prints a count, not values.

## 3. Copy config files

Start with the files the user approved:

```sh
bash "$S/copy.sh" "$BOX" --dry-run \
  .gitconfig .config/git/config .vimrc .tmux.conf .bash_aliases
bash "$S/copy.sh" "$BOX" \
  .gitconfig .config/git/config .vimrc .tmux.conf .bash_aliases
```

`copy.sh` refuses symlinks, creates parent directories, copies through
`serbox push` and sets mode `0600` on the copied files. Without a file list it
copies the existing defaults from the scan. It does not copy directories
wholesale: nvim plugin checkouts and caches are deliberately excluded.

Verify:

```sh
serbox exec "$BOX" -- 'git config --global user.name; git config --global user.email'
serbox exec "$BOX" -- 'test -f /data/home/.vimrc && echo vimrc-ok'
```

## 4. Tell the user what still needs a manual step

- Git push/pull needs an SSH key or token inside the box. A `.gitconfig` alone
  does not authenticate. For HTTPS, a credential helper or a token in the
  remote URL is required; for SSH, generate a key in the box and add it to the
  user's account. Never copy the host's private keys unless the user explicitly
  asks and understands the risk.
- Secrets in the environment are visible to every process in the box. A
  compromised dependency can read them.
- `serbox rm BOX` destroys the box's `/data`; snapshots saved earlier remain.
- Config copied now is a snapshot in time. The local machine and the box do not
  stay in sync.

## Security rules

- Never print a secret value, a credential-bearing config file, or the output of
  `env`/`printenv` that may contain secrets.
- Do not copy `.ssh` private keys, cloud credential files (`.aws/credentials`,
  `.config/gcloud/...`), browser profiles or keychains by default. Name them to
  the user and require explicit approval; prefer creating fresh credentials in
  the box.
- Do not paste tokens into a command line where `ps` can see them. Use stdin as
  shown above.
