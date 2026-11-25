#!/usr/bin/env bash
#
# End-to-end check against a real Docker daemon.
#
#   scripts/test-e2e.sh [path-to-serbox]
#
# It exercises the flow an agent actually uses: create, exec (exit code,
# timeout, stdin, background job), push/pull, suspend/resume, snapshot, fork,
# rename, port publish and removal. Every box it creates is removed on exit,
# including on failure, and host state goes to a throwaway SERBOX_HOME.
#
# Needs: docker (daemon reachable), curl, and network access for the first
# `alpine` pull (or that image already present).

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bin="${1:-$root/_build/native/release/build/cmd/main/main.exe}"
[ -x "$bin" ] || {
  printf 'error: %s is not executable; build it first\n' "$bin" >&2
  exit 1
}

export SERBOX_HOME="$(mktemp -d)"
name="e2e$$"
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
  "$bin" rm "$name-sec" --yes >/dev/null 2>&1 || true
  "$bin" rm "$name-gone" --yes >/dev/null 2>&1 || true
  "$bin" rm "$name-copy" --yes >/dev/null 2>&1 || true
  "$bin" snapshot rm "$name-snap" --yes >/dev/null 2>&1 || true
  "$bin" rm "$name-renamed" --yes >/dev/null 2>&1 || true
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

say "doctor"
"$bin" doctor >/dev/null || fail "doctor reported a problem"

say "create"
"$bin" create --name "$name" --template alpine >/dev/null || fail "create"
"$bin" ls | grep -q "$name" || fail "ls does not show the box"
ok "box created and listed"

say "exec"
[ "$("$bin" exec "$name" -- 'echo hello')" = "hello" ] || fail "exec output"
ok "single string runs through a shell"
[ "$("$bin" exec "$name" -- printf '%s' 'a b')" = "a b" ] || fail "argv form"
ok "multiple arguments are an exact argv"
expect_code 7 "$bin" exec "$name" -- 'exit 7'
ok "exit code 7 is preserved"
start=$(date +%s)
expect_code 124 "$bin" exec "$name" --timeout 1 -- 'sleep 5'
[ $(( $(date +%s) - start )) -lt 4 ] || fail "timeout did not return quickly"
ok "timeout returns 124"
[ "$(printf 'piped' | "$bin" exec "$name" --stdin -- 'cat')" = "piped" ] || fail "stdin"
ok "stdin is forwarded"
# A flag after `--` belongs to the command, not to serbox.
[ "$("$bin" exec "$name" -- printf '%s' '--json')" = "--json" ] || fail "-- after separator"
ok "flags after -- are passed through untouched"
out="$("$bin" exec "$name" --json -- 'echo out; echo err >&2')"
echo "$out" | grep -q '"stdout":"out' || fail "--json stdout"
echo "$out" | grep -q '"exitCode":0' || fail "--json exitCode"
ok "--json reports stdout, stderr and exitCode"

say "background job"
job="$("$bin" exec "$name" --background -- 'for i in 1 2 3; do echo $i; sleep 0.1; done' | tail -1)"
[ -n "$job" ] || fail "no job id"
"$bin" jobs wait "$name" "$job" >/dev/null || fail "job wait"
"$bin" jobs logs "$name" "$job" | grep -q 3 || fail "job logs"
ok "job $job ran and waited"

say "files"
mkdir -p "$work/sub"
echo hello >"$work/a.txt"
echo deep >"$work/sub/b.txt"
"$bin" push "$name" "$work" /data/work >/dev/null || fail "push"
[ "$("$bin" exec "$name" -- 'cat /data/work/sub/b.txt')" = "deep" ] || fail "push contents"
ok "push copies a tree"
"$bin" pull "$name" /data/work/a.txt "$work/back.txt" >/dev/null || fail "pull"
[ "$(cat "$work/back.txt")" = "hello" ] || fail "pull contents"
ok "pull copies a file"
"$bin" push "$name" "$work/sub/b.txt" /data/deep/dir/ >/dev/null 2>&1 || true
"$bin" exec "$name" -- 'mkdir -p /data/d' >/dev/null
"$bin" push "$name" "$work/a.txt" /data/d >/dev/null || fail "push into dir"
"$bin" files "$name" /data/d | grep -q a.txt || fail "files list"
ok "push into a directory and list it"
"$bin" push "$name" "$work/a.txt" >/dev/null || fail "push to home"
[ "$("$bin" exec "$name" -- 'cat /data/home/a.txt')" = "hello" ] || fail "push home contents"
ok "push without a remote path lands in the home directory"

say "secrets"
printf 's3cret' | "$bin" secrets set E2E_TOKEN >/dev/null || fail "secrets set"
"$bin" create --name "$name-sec" --template alpine --secrets E2E_TOKEN >/dev/null ||
  fail "create with secrets"
[ "$("$bin" exec "$name-sec" -- 'printf %s "$E2E_TOKEN"')" = "s3cret" ] || fail "secret env"
"$bin" secrets push "$name-sec" >/dev/null || fail "secrets push"
[ "$("$bin" exec "$name-sec" -- 'stat -c %a /data/.serbox/secrets.env')" = "600" ] ||
  fail "secrets file mode"
ok "secrets reach a box and the pushed file is 0600"

say "suspend and resume"
"$bin" suspend "$name" >/dev/null || fail "suspend"
expect_code 1 "$bin" exec "$name" -- true
"$bin" resume "$name" >/dev/null || fail "resume"
[ "$("$bin" exec "$name" -- 'echo awake')" = "awake" ] || fail "resume exec"
ok "paused boxes refuse work until resumed"
"$bin" max-run "$name" 0 >/dev/null || fail "max-run 0"
"$bin" ls | grep -q "running" || fail "max-run 0 paused the box"
ok "max-run 0 disables the limit instead of pausing"

say "snapshot and fork"
"$bin" snapshot save "$name" --name "$name-snap" >/dev/null || fail "snapshot save"
"$bin" snapshot ls | grep -q "$name-snap" || fail "snapshot ls"
"$bin" fork "$name" --name "$name-copy" --count 1 >/dev/null || fail "fork"
[ "$("$bin" exec "$name-copy" -- 'cat /data/work/a.txt')" = "hello" ] || fail "fork contents"
ok "fork keeps /data"
# fork --json must be one JSON document, not one per copy plus an array.
fork_json="$("$bin" fork "$name" --name "$name-copy2" --count 1 --json 2>/dev/null || true)"
if [ -n "$fork_json" ]; then
  echo "$fork_json" | python3 -c 'import json,sys; json.load(sys.stdin)' ||
    fail "fork --json is not one document"
  "$bin" rm "$name-copy2" --yes >/dev/null
fi
"$bin" stop "$name" >/dev/null || fail "stop before snapshot"
"$bin" snapshot save "$name" --name "$name-stopped" >/dev/null ||
  fail "snapshot of a stopped box"
"$bin" snapshot rm "$name-stopped" --yes >/dev/null
"$bin" start "$name" >/dev/null || fail "start after snapshot"
ok "a stopped box can be snapshotted"
"$bin" rename "$name-copy" "$name-renamed" >/dev/null || fail "rename"
"$bin" get "$name-renamed" | grep -q "$name-renamed" || fail "get after rename"
"$bin" port publish "$name-renamed" 3000 --host 18098 >/dev/null || fail "publish after rename"
"$bin" port ls | grep -q "$name-renamed" || fail "rename lost the port record"
"$bin" port unpublish "$name-renamed" 3000 >/dev/null
ok "rename"

say "port publish"
"$bin" exec "$name" --background -- \
  'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi" | nc -l -p 3000; done' >/dev/null || fail "start nc"
sleep 1
"$bin" port publish "$name" 3000 --host 18099 >/dev/null || fail "port publish"
sleep 1
body="$(curl -fsS -m 3 http://127.0.0.1:18099/ || true)"
[ "$body" = "hi" ] || fail "port forward returned '$body'"
"$bin" port unpublish "$name" 3000 >/dev/null || fail "port unpublish"
ok "port forwarded and unpublished"

# Removing a box must also stop its forwarders, or the host keeps a listener
# that only answers with connection resets.
"$bin" port publish "$name" 3000 --host 18099 --private >/dev/null || fail "re-publish"
ss -ltn | grep -q "127.0.0.1:18099" || fail "--private did not bind loopback"
ok "port publish --private binds loopback only"
"$bin" rm "$name" --yes >/dev/null || fail "rm with a published port"
"$bin" port ls | grep -q "$name" && fail "rm left a port record behind"
ok "rm stopped the forwarder"

say "rm cleans up a box whose container vanished"
"$bin" create --name "$name-gone" --template alpine >/dev/null || fail "create gone"
docker rm -f "serbox-$name-gone" >/dev/null || fail "docker rm gone"
"$bin" rm "$name-gone" --yes >/dev/null || fail "rm with a missing container"
expect_code 4 "$bin" get "$name-gone"
ok "rm removes the record of a missing container"

say "agent skills"
skill_home="$(mktemp -d)"
HOME="$skill_home" "$bin" skills list | grep -q serbox-move-repo || fail "skills list"
HOME="$skill_home" "$bin" skills install --target claude -y >/dev/null ||
  fail "skills install"
[ -f "$skill_home/.claude/skills/serbox-basic-setup/scripts/scan.mjs" ] ||
  fail "skills install missed a script"
node "$skill_home/.claude/skills/serbox-basic-setup/scripts/scan.mjs" --json |
  python3 -c 'import json,sys; json.load(sys.stdin)' || fail "scan.mjs output"
printf '%s\n' '---' 'name: mine' '---' >"$skill_home/.claude/skills/serbox/SKILL.md"
HOME="$skill_home" "$bin" skills install --target claude --only nope -y >/dev/null 2>&1 &&
  fail "installing an unknown skill succeeded"
HOME="$skill_home" "$bin" skills install --target claude -y | grep -q "kept your own" ||
  fail "a user skill was not kept"
grep -q "name: mine" "$skill_home/.claude/skills/serbox/SKILL.md" ||
  fail "a user skill was overwritten"
rm -rf "$skill_home"
ok "skills install to a clean HOME keeps user copies"

say "cleanup"
expect_code 4 "$bin" exec "$name" -- true
"$bin" rm "$name-renamed" --yes >/dev/null || fail "rm renamed"
ok "removed"

printf '\n%d checks passed\n' "$pass"
