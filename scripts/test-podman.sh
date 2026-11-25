#!/usr/bin/env bash
#
# End-to-end check with Podman instead of Docker.
#
#   scripts/test-podman.sh [path-to-serbox]
#
# Needs: podman (rootless is enough), curl, and network access for the first
# alpine pull. Uses a throwaway SERBOX_HOME and removes every box it creates.

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="${1:-$root/_build/native/release/build/cmd/main/main.exe}"
command -v podman >/dev/null || {
  echo "skip: podman is not installed"
  exit 0
}
[ -x "$bin" ] || {
  echo "error: $bin is not executable" >&2
  exit 1
}

export SERBOX_HOME="$(mktemp -d)"
export SERBOX_RUNTIME=podman
name="pod$$"
work="$(mktemp -d)"
pass=0

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
  "$bin" rm "$name" --yes >/dev/null 2>&1 || true
  "$bin" rm "$name-copy" --yes >/dev/null 2>&1 || true
  "$bin" snapshot rm "$name-snap" --yes >/dev/null 2>&1 || true
  rm -rf "$SERBOX_HOME" "$work"
}
trap cleanup EXIT

expect_code() {
  local want="$1"
  shift
  set +e
  "$@" >/dev/null 2>&1
  local got=$?
  set -e
  [ "$got" = "$want" ] || fail "$* -> exit $got, wanted $want"
}

say "runtime"
"$bin" doctor | grep -q "podman CLI" || fail "doctor did not select podman"
ok "doctor selects Podman"

say "create and exec"
"$bin" create --name "$name" --template alpine >/dev/null || fail "create"
[ "$("$bin" exec "$name" -- 'echo hello')" = "hello" ] || fail "exec"
expect_code 7 "$bin" exec "$name" -- 'exit 7'
[ "$(printf piped | "$bin" exec "$name" --stdin -- 'cat')" = "piped" ] || fail "stdin"
ok "create, exec, exit codes and stdin"

say "files"
echo hello >"$work/a.txt"
"$bin" push "$name" "$work/a.txt" /data/a.txt >/dev/null || fail "push"
"$bin" exec "$name" -- 'echo more > /data/b.txt'
"$bin" pull "$name" /data/b.txt "$work/b.txt" >/dev/null || fail "pull"
[ "$(cat "$work/b.txt")" = "more" ] || fail "pull contents"
ok "push and pull"

say "snapshots"
"$bin" snapshot save "$name" --name "$name-snap" >/dev/null || fail "snapshot save"
"$bin" fork "$name" --name "$name-copy" --count 1 >/dev/null || fail "fork"
[ "$("$bin" exec "$name-copy" -- 'cat /data/a.txt')" = "hello" ] || fail "fork contents"
ok "snapshot save and fork"

say "published port"
"$bin" exec "$name" --background -- \
  'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi" | nc -l -p 3000; done' >/dev/null
sleep 1
"$bin" port publish "$name" 3000 --host 18197 >/dev/null 2>"$work/port.err" || {
  # Rootless Podman cannot add a port to a running box; that is reported, not
  # a crash, and the test accepts the documented refusal.
  grep -q "rootless Podman" "$work/port.err" || {
    cat "$work/port.err" >&2
    fail "port publish"
  }
  ok "rootless Podman refuses late publish with guidance"
}
if [ -s "$work/port.err" ] && grep -q "rootless Podman" "$work/port.err"; then
  :
else
  sleep 1
  [ "$(curl -fsS -m 3 http://127.0.0.1:18197/)" = "hi" ] || fail "port forward"
  "$bin" port unpublish "$name" 3000 >/dev/null
  ok "port publish forwards to the box"
fi

say "cleanup"
"$bin" rm "$name-copy" --yes >/dev/null || fail "rm copy"
"$bin" rm "$name" --yes >/dev/null || fail "rm"
expect_code 4 "$bin" exec "$name" -- true
ok "boxes removed"

printf '\n%s checks passed\n' "$pass"
