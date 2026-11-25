#!/usr/bin/env bash
# Install a moved project's dependencies inside a serbox box.
# usage: deps.sh BOX DIR
set -euo pipefail
box="${1:?usage: deps.sh BOX DIR}"
dir="${2:?usage: deps.sh BOX DIR}"
run() { serbox exec "$box" --workdir "$dir" -- "$@"; }
have() { serbox exec "$box" -- "command -v '$1' >/dev/null 2>&1"; }

if serbox exec "$box" -- "test -f '$dir/package.json'"; then
  if serbox exec "$box" -- "test -f '$dir/pnpm-lock.yaml'"; then
    have pnpm && run pnpm install --frozen-lockfile || echo "note: pnpm is not installed in the box"
  elif serbox exec "$box" -- "test -f '$dir/yarn.lock'"; then
    have yarn && run yarn install --frozen-lockfile || echo "note: yarn is not installed in the box"
  elif serbox exec "$box" -- "test -f '$dir/package-lock.json'"; then
    have npm && run npm ci || echo "note: npm is not installed in the box"
  else
    have npm && run npm install || echo "note: npm is not installed in the box"
  fi
fi

if serbox exec "$box" -- "test -f '$dir/Cargo.toml'"; then
  have cargo && run cargo fetch || echo "note: cargo is not installed in the box"
fi
if serbox exec "$box" -- "test -f '$dir/go.mod'"; then
  have go && run go mod download || echo "note: go is not installed in the box"
fi
if serbox exec "$box" -- "test -f '$dir/requirements.txt'"; then
  have python3 && run python3 -m pip install -r requirements.txt ||
    echo "note: python3/pip is not installed in the box"
fi
if serbox exec "$box" -- "test -f '$dir/pyproject.toml'"; then
  have python3 && run python3 -m pip install -e . ||
    echo "note: python3/pip is not installed in the box"
fi
if serbox exec "$box" -- "test -f '$dir/Gemfile'"; then
  have bundle && run bundle install || echo "note: bundler is not installed in the box"
fi
