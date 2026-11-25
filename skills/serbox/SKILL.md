---
name: serbox
description: Use when the user wants an isolated Linux box on this server with the `serbox` CLI - create, exec or shell into, copy files, run background jobs, publish a port, save or restore a snapshot, pause and resume, set secrets, use a remote server, or delete the box.
metadata:
  installed-by: serbox
---

# serbox CLI

`serbox` runs disposable Linux boxes as containers on the machine where it is
installed. There is no account and no hosted service: `serbox` talks to the
local Docker or Podman engine, keeps its state under `~/.serbox` (override with
`SERBOX_HOME`), and works the same on any Linux server. Set
`SERBOX_RUNTIME=podman` to use Podman; otherwise Docker is preferred and Podman
is the fallback.

A box has a writable root filesystem and a persistent `/data` disk. `HOME` is
`/data/home`, so files under `/data` survive pause, resume, snapshot and fork.
Each box is its own container; processes, installed packages and files stay
inside it. Everything the CLI prints is meant for an agent: add `--json` for a
machine-readable document.

Safety rules to state before acting:

- `serbox rm NAME` deletes the container and its `/data`. Save a snapshot
  first if the box matters.
- `serbox port publish` exposes a container port on this host. Anyone who can
  reach the host and port can use it; use `--private` to bind loopback only.
- Secrets are plain environment variables inside the box; code running there
  can read them.

## Create and inspect

```sh
serbox create --name work --template alpine       # fast, small
serbox create --name work --template ubuntu --publish 3000 --secrets TOKEN
serbox ls                                         # state, template, age
serbox get work --json                            # one box as JSON
serbox templates                                  # known image aliases
serbox doctor                                     # runtime and state checks
```

`create` returns once the box accepts commands.
`--setup-file PATH` runs a script after creation; `--env K=V`, `--secrets NAME`,
`--publish PORT` and `--auto-suspend 30m` are also accepted. Names are
lowercase letters, digits, `_` and `-`, 1 to 40 characters.

## Run commands

```sh
serbox exec work -- uname -a                      # exact argv
serbox exec work -- 'apt-get update && apt-get install -y git'   # one string: shell
serbox exec work --stdin -- 'cat > /data/note'     # pipe stdin
serbox exec work --timeout 120 -- ./build.sh       # 1..600 seconds
serbox exec work --json -- 'echo hi'               # stdout, stderr, exitCode
serbox shell work                                  # interactive shell
serbox ssh work                                    # same, for muscle memory
```

Exit codes are the command's own; 124 means `--timeout` expired, 130 means
interrupted. Use `--cwd DIR` and `--env K=V` for one command.

## Files and secrets

```sh
serbox push work ./src /data/home/src              # local -> box
serbox pull work /data/home/src ./src              # box -> local
serbox files work /data/home                       # list
serbox cp work:/data/home/a.txt ./a.txt            # either direction
```

`cp` accepts `BOX:/path` on one side and a local path on the other.

```sh
printf '%s' "$TOKEN" | serbox secrets set GITHUB_TOKEN
serbox secrets ls                                  # names only, never values
serbox secrets push work                           # /data/.serbox/secrets.env, mode 0600
serbox create --name work2 --secrets GITHUB_TOKEN
```

Never echo a secret value into logs or commit it. To use a secret in a later
`exec`, source `/data/.serbox/secrets.env` inside the box, or pass an explicit
`--env NAME=value` (the CLI does not read secret values from the store):

```sh
serbox exec work -- 'set -a; . /data/.serbox/secrets.env; set +a; ./deploy'
```

## Background jobs

```sh
serbox exec work --background -- 'make test > /data/test.log 2>&1'
serbox jobs ls work
serbox jobs logs work JOB_ID --follow
serbox jobs wait work JOB_ID --timeout 600
serbox jobs kill work JOB_ID --signal TERM
```

`--background` prints the job id. Jobs keep running inside the box after the
CLI exits; `jobs wait` returns the job's exit code.

## Ports

```sh
serbox port publish work 3000                     # host picks a free port
serbox port publish work 3000 --host 8080 --private
serbox port ls
serbox port unpublish work 3000
```

A forwarder runs on the host and connects to the container address. It stops
when the box is removed or the port is unpublished.

## Pause, snapshot, remove

```sh
serbox suspend work            # processes stop, disks stay
serbox resume work
serbox stop work               # stop the container
serbox start work
serbox snapshot save work --name work-ready
serbox snapshot ls
serbox fork work --name work2 --count 2
serbox rename work work-old
serbox rm work --yes
```

`fork` copies the box's disks; `snapshot restore` copies a snapshot into an
existing box (its current `/data` is replaced). `--root-only` is not
implemented: serbox snapshots always include `/data`.

See the `serbox-snapshots` skill for the full snapshot workflow, and
`serbox-move-repo` / `serbox-basic-setup` for moving a repository or dotfiles
into a box.

## Remote servers

```sh
serbox host add prod me@server.example.com --install   # installs and tunnels
serbox host use prod                                  # current server
serbox create --name work                             # runs on prod
serbox exec work -- uptime                            # through the ssh tunnel
serbox -H prod ls                                     # one-off override
serbox host ls
serbox host current
serbox host rm prod
```

Hosts added with `--address 127.0.0.1:7373 --token T` skip ssh and talk to a
daemon reached some other way. On the server, `serbox serve` runs the daemon;
it listens on loopback and keeps its token in `~/.serbox/serve-token`. Rotate it
with `serbox serve --rotate-token`, and re-authorize a client with
`serbox host add NAME USER@HOST --force`.

`push`, `pull` and `cp` need an ssh-added host: the remote daemon cannot read
your local disk. Run interactive shells with `serbox shell`; it uses `ssh -t`.

## Housekeeping

```sh
serbox usage
serbox auto-suspend work 30m
serbox max-run work 8h              # bare numbers mean minutes
serbox gc --dry-run
serbox logs work --tail 100
serbox metrics work
serbox history
serbox completion bash
```

`gc` deletes boxes whose `--delete-after` has passed and pauses boxes that hit
their auto-suspend or max-run limit. Limits are per box, so set them with
`auto-suspend` and `max-run`; `max-run 0` disables that limit.
