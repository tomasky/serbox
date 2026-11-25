#!/usr/bin/env bash
#
# End-to-end check of the remote layer: two daemons, two "servers", one CLI.
#
#   scripts/test-remote.sh [path-to-serbox]
#
# The daemons listen on loopback, so no ssh or network is needed. The ssh path
# (host add without --address, tunnels, scp for push/pull) needs a reachable
# sshd and is covered by hand and by CI on a machine that has one.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bin="${1:-$root/_build/native/release/build/cmd/serbox/serbox.exe}"
[ -x "$bin" ] || {
  printf 'error: %s is not executable; build it first\n' "$bin" >&2
  exit 1
}

home_a="$(mktemp -d)"
home_b="$(mktemp -d)"
client="$(mktemp -d)"
port_a=7481
port_b=7482
pass=0
pids=()

say() { printf '\n== %s\n' "$*"; }
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$*"
}
fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}
cleanup() {
  for pid in "${pids[@]:-}"; do
    if [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for home in "$home_a" "$home_b"; do
    SERBOX_HOME="$home" "$bin" ls --json 2>/dev/null |
      sed -n 's/.*"name":"\([^"]*\)".*/\1/p' |
      while read -r name; do
        SERBOX_HOME="$home" "$bin" rm "$name" --yes >/dev/null 2>&1 || true
      done
  done
  rm -rf "$home_a" "$home_b" "$client"
}
trap cleanup EXIT

start_daemon() {
  local home="$1" port="$2"
  (SERBOX_HOME="$home" "$bin" serve --restart --port "$port" >/dev/null)
  for _ in $(seq 1 30); do
    [ -s "$home/serve-$port.pid" ] && break
    sleep 0.1
  done
  pids+=("$(cat "$home/serve-$port.pid" 2>/dev/null || echo 0)")
  for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
    sleep 0.1
  done
  fail "daemon on $port did not start"
}

say "two servers"
start_daemon "$home_a" "$port_a"
start_daemon "$home_b" "$port_b"
ok "daemons on $port_a and $port_b"

export SERBOX_HOME="$client"
"$bin" host add alpha --address "127.0.0.1:$port_a" --token "$(cat "$home_a/serve-token")" >/dev/null
"$bin" host add beta --address "127.0.0.1:$port_b" --token "$(cat "$home_b/serve-token")" >/dev/null
"$bin" host ls | grep -q alpha || fail "host ls"
ok "two hosts added with separate tokens"

say "switch between servers"
"$bin" host use alpha >/dev/null
[ "$("$bin" host current)" = "alpha" ] || fail "host current"
"$bin" create --name on-a --template alpine >/dev/null || fail "create on alpha"
[ "$("$bin" ls | grep -c on-a)" = 1 ] || fail "alpha lists its box"
"$bin" exec on-a -- 'echo alpha' | grep -q alpha || fail "exec on alpha"

"$bin" host use beta >/dev/null
"$bin" create --name on-b --template alpine >/dev/null || fail "create on beta"
"$bin" exec on-b -- 'echo beta' | grep -q beta || fail "exec on beta"
[ "$("$bin" ls | grep -c on-a)" = 0 ] || fail "beta must not see alpha's boxes"
ok "host use switches without -H"

"$bin" -H alpha exec on-a -- 'echo pinned' | grep -q pinned || fail "-H override"
ok "-H overrides the current host"

say "exit codes and json"
set +e
"$bin" -H alpha exec on-a -- 'exit 7'
code=$?
set -e
[ "$code" = 7 ] || fail "exit code was $code"
"$bin" -H alpha exec on-a --json -- 'echo out' | grep -q '"stdout":"out' || fail "--json"
ok "exit code and --json survive the tunnel"

say "token rotation"
new_token="$(SERBOX_HOME="$home_a" "$bin" serve --rotate-token --port "$port_a" | tail -1)"
[ -n "$new_token" ] || fail "rotate-token printed nothing"
set +e
"$bin" -H alpha ls >/dev/null 2>&1
stale=$?
set -e
[ "$stale" != 0 ] || fail "old token still works after rotation"
"$bin" host add alpha --address "127.0.0.1:$port_a" --token "$new_token" --force >/dev/null ||
  fail "re-auth with the new token"
"$bin" -H alpha ls >/dev/null || fail "new token rejected"
ok "rotating a token invalidates the old one; --force re-authorizes"

say "cleanup"
"$bin" -H alpha rm on-a --yes >/dev/null || fail "rm alpha box"
"$bin" -H beta rm on-b --yes >/dev/null || fail "rm beta box"
"$bin" host use local >/dev/null
[ "$("$bin" host current)" = "local" ] || fail "host use local"
"$bin" host rm alpha >/dev/null
"$bin" host rm beta >/dev/null
"$bin" hosts | grep -q "no remote hosts" || fail "hosts after rm"
ok "hosts removed"

printf '\n%d checks passed\n' "$pass"
