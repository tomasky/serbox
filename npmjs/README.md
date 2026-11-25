# serbox

**Linux boxes for agents — on your own server.**
No account, no API key, no control plane. `serbox` creates small disposable
Linux boxes on the machine it runs on and gives you `create`, `exec`, `ssh`,
`push`/`pull`, suspend, snapshots, forks, port forwarding, secrets and agent
skills around them.

It is the local counterpart of [instabox](https://instabox.sh): the same box
workflow, without the hosted service.

```bash
npx @tomasko/serbox create --name dev
npx @tomasko/serbox exec dev -- 'uname -a'
npx @tomasko/serbox ssh dev
npx @tomasko/serbox rm dev --yes
```

## Install

```bash
npm install -g @tomasko/serbox
serbox version
```

Or use it without installing:

```bash
npx @tomasko/serbox@latest ls
```

This npm package is a small launcher. On first run it downloads the matching
**statically linked** `serbox` binary for this machine
(`linux-x86_64` or `linux-aarch64`) from GitHub Releases into
`~/.cache/serbox`, verifies the published SHA-256, and runs it. The cached
binary is reused afterwards, so later runs start instantly and work offline.

There is **no install script**. That means the package works under
`npm ci --ignore-scripts`, pnpm, Yarn PnP and `npx`, all of which may block
dependency lifecycle scripts. Downloads happen at run time instead.

Requirements:

- Linux (`x64` or `arm64`); the npm package declares both
- A reachable **Docker or Podman** engine (CLI plus daemon/socket)
- Permission to talk to it — membership in the `docker` group, root, or a
  rootless Podman setup

Nothing else: no Python, no Node runtime inside the boxes, no hosted account.

`serbox doctor` checks the runtime it selected and prints what is missing.

## Quick start

```bash
# a Debian box named dev (also: ubuntu, alpine, node, python, go, rust, agent)
serbox create --name dev

# run a command; the exit code is the command's exit code
serbox exec dev -- 'apt-get update && apt-get install -y ripgrep'

# interactive shell
serbox ssh dev

# files in and out; boxes keep their files under /data
serbox push dev ./src /data/src
serbox pull dev /data/out.log ./out.log

# pause without losing the filesystem
serbox suspend dev
serbox resume dev

# save the whole box as an image and start another one from it
serbox snapshot save dev --name ready
serbox create --name dev2 --snapshot ready

# expose a service running inside the box on this server
serbox port publish dev 3000 --host 3000

# clean up
serbox rm dev --yes
```

`$HOME` inside a box is `/data/home`, and `/data` is the one predictable place
for files, pushes, pulls and snapshots.

## What a box is

- a Docker/Podman container named `serbox-<box>` with the label
  `serbox.managed=1`
- running `sleep infinity`, so commands can attach at any time
- created from a template image (`default` is `debian:bookworm-slim`; also
  `ubuntu`, `alpine`, `node`, `python`, `go`, `rust`, `agent`), a snapshot, or
  any image you name
- described by a small JSON file in `~/.serbox/boxes/`, so `ls`, `gc` and
  `doctor` still work after a reboot

Isolation is the container runtime's: namespaces, cgroups and the container's
own filesystem. Boxes share the host kernel. Anyone who can run `docker` /
`podman` can read every box on the machine, so serbox is for a server you
already trust, not for untrusted multi-tenant hosting. For a stronger boundary,
run serbox itself inside a VM.

## Docker or Podman

Docker is used when it is installed. Set `SERBOX_RUNTIME=podman` to choose
Podman explicitly; Podman is picked automatically when Docker is absent.

```bash
SERBOX_RUNTIME=podman serbox doctor
SERBOX_RUNTIME=podman serbox create --name dev --template alpine
```

Two Podman differences matter:

- **Rootless Podman** keeps boxes on a private network. A host-side forwarder
  cannot reach them, so publish ports at create time:
  `serbox create --name dev --publish 3000:8080`. `serbox port publish` on a
  running rootless box explains this instead of leaving a dead forwarder.
- **Short image names** can trigger Podman's interactive short-name prompt.
  Built-in templates use full references (`docker.io/library/...`). For
  `--image`, pass a full reference such as `docker.io/library/alpine:3.20`.

Rootful Podman with its default bridge network behaves closest to Docker.

## Commands

| command | what it does |
| --- | --- |
| `create --name N [--template T \| --snapshot S \| --image I]` | start a box; flags: `--env K=V`, `--env-file F`, `--publish PORT[:HOST]`, `--meta K=V`, `--secrets NAMES\|all`, `--auto-suspend D`, `--delete-after D`, `--setup-file F`, `--no-wait` |
| `ls [--meta K=V]`, `get N` | list / inspect boxes |
| `exec N [--cwd DIR] [--env K=V] [--timeout SECS] [--stdin] [--stream] [--background] -- CMD` | run a command |
| `ssh N [-- CMD]` | interactive shell, or a command through the box's login shell |
| `push N LOCAL [REMOTE] [-p]` | copy a file or tree into a box; `-p` creates parent directories |
| `pull N REMOTE [LOCAL]` | copy a file or tree out |
| `cp [-r] SRC DST` | `BOX:/path` on either side; local↔box only |
| `files N [PATH]` | list a directory or print a text file |
| `suspend N` / `resume N` | pause / unpause a box (filesystem kept) |
| `start N` / `stop N` / `restart N` | boot / shut down / restart |
| `rename OLD NEW` | rename a box and its state |
| `auto-suspend N D`, `max-run N D` | idle and runtime limits (`0` disables) |
| `resize N --cpus C --memory M [--restart]` | change container limits |
| `snapshot save N [--name S] [--description D]` | commit a box to an image |
| `snapshot ls`, `snapshot rm S [--yes]` | list / delete snapshots |
| `snapshot import IMAGE --name S` | record an existing image as a snapshot |
| `snapshot restore N [--snapshot S] [--yes]` | replace a box's container from a snapshot |
| `fork N [--name M] [--count K]` | copy a box, files included |
| `port publish N PORT [--host PORT] [--private]` | forward a box port on this server |
| `port ls [N]`, `port unpublish N PORT` | list / remove forwarders |
| `secrets set NAME`, `secrets ls`, `secrets rm NAME` | local credential store |
| `secrets select N NAMES`, `secrets show N`, `secrets push N` | choose and deliver secrets |
| `run [--template T] [--keep] [--push DIR] -- CMD` | create, run, delete in one step |
| `jobs ls\|logs\|wait\|kill N [JOB]` | background commands from `exec --background` |
| `ps N`, `history N`, `output N`, `disk N`, `metrics N`, `logs N` | look inside a box |
| `templates`, `usage`, `gc [--dry-run]` | host information and idle cleanup |
| `doctor`, `completion bash\|zsh\|fish`, `update` | host and shell help |
| `skills list`, `skills install` | install bundled agent skills |
| `serve`, `host add\|ls\|use\|current\|rm` | run and use boxes on another server |
| `version`, `help [COMMAND]` | version and help |

Global flags: `-H/--remote HOST`, `--json` (`-o json`), `--no-color`.

### exec semantics

One command argument is run through the box's login shell; several arguments
are an exact argv with no shell:

```bash
serbox exec dev -- 'echo $HOME && ls /data'   # shell (pipes work)
serbox exec dev -- printf '%s\n' 'a b'        # exact argv
```

The default timeout is 60 seconds; `--timeout` accepts `30`, `2m`, `1h` and is
capped at 600 seconds. A timed-out command exits `124`. `exec --background`
prints a job id (`j...`), which `jobs` can wait on or kill.

### JSON and exit codes

`--json` is available on every command. Results go to **stdout** as one JSON
document; human progress lines and errors also go to stderr, so stdout stays
parseable. Errors look like:

```json
{"error":{"code":"not_found","message":"no such box 'dev'"}}
```

`code` is symbolic (`usage`, `not_found`, `retryable`, `timeout`,
`interrupted`, `error`) and matches the process exit code below.

Exit codes:

| code | meaning |
| --- | --- |
| `0` | success |
| `2` | usage error (bad flag, bad name, missing argument) |
| `4` | not found (box, snapshot, host, job, path) |
| `75` | retryable: image pull or container start failed |
| `124` | command timed out |
| `130` | interrupted (Ctrl-C) |
| other | the command's own exit status |

## Agent skills

Four complete agent skills ship **inside the binary** and in this npm package
under `skills/`:

| skill | covers |
| --- | --- |
| `serbox` | create, exec, files, jobs, ports, pause, remote hosts |
| `serbox-snapshots` | save, restore, fork, import and delete snapshots |
| `serbox-move-repo` | copy a git checkout, worktrees and uncommitted work into a box, then install dependencies |
| `serbox-basic-setup` | store tokens as secrets, copy git/editor config, check manual steps |

```bash
serbox skills list
serbox skills install -y                  # every skill, for every agent found
serbox skills install --target claude,codex
serbox skills install --only serbox-snapshots -y
serbox skills install --claude --codex --cursor --opencode --antigravity
```

Targets are installed where each agent looks for skills:

| agent | directory |
| --- | --- |
| Claude Code | `~/.claude/skills` |
| Codex, Cursor, OpenCode | `~/.agents/skills` |
| Antigravity | `~/.gemini/config/skills` |

Each skill is a directory with a `SKILL.md` and any helper scripts
(`scripts/repo-files.mjs`, `scripts/deps.sh`, ...). A `SKILL.md` you wrote
yourself (one without the `installed-by: serbox` marker) is never overwritten.

## Secrets

```bash
serbox secrets set GITHUB_TOKEN      # reads one line from stdin
serbox create --name dev --secrets GITHUB_TOKEN
serbox exec dev -- 'gh auth status'  # value is already in the environment
```

Values live in `~/.serbox/secrets.json` with mode `0600` and are passed to new
boxes as environment variables. `secrets push dev` writes the selected values
to `/data/.serbox/secrets.env` inside a running box for tools that read a file.
`secrets ls` and `secrets show` never print a value.

## Boxes on another server

A box lives on one Linux host, but you do not have to sit on that host. Run a
small daemon there, register it from your laptop, and every command works
against it — even from a laptop with no Docker installed.

On the server, once:

```bash
serbox serve --ensure          # 127.0.0.1:7373, prints the token
serbox serve --print-token     # show it again later
```

On the laptop:

```bash
# checks/installs serbox on the server, starts the daemon, opens an ssh tunnel
serbox host add prod me@prod.example.com

serbox host use prod
serbox create --name dev --template node
serbox exec dev -- 'node --version'
serbox ssh dev
serbox host use local          # back to this machine
```

`serbox -H prod ls` pins one command to a host without changing the default.
`serbox host ls` shows hosts, their state and the current marker. Tunnels are
started on demand and reused.

Each host has its own token in `~/.serbox/hosts.json` (mode `0600`), so servers
never share credentials. Rotate a server's token with
`serbox serve --rotate-token` on that server, then re-authorize clients with
`serbox host add NAME ... --force`.

A host added by ssh needs `ssh` and either `serbox` in `PATH` or `--install`.
An air-gapped or pre-tunnelled server can be registered directly:

```bash
serbox host add prod --address 127.0.0.1:7373 --token TOKEN
```

`exec`, `ls`, `create`, snapshots, jobs and ports are served by the daemon;
exit codes and `--json` come back unchanged. `push` and `pull` also touch your
local disk, so they need a host added by ssh (not `--address`).

Security: the daemon speaks plain HTTP on loopback by default and authenticates
every request with a 32-hex-character token. Reach it through ssh, a private
network, or a TLS terminator; **never expose the port to the internet**. Anyone
with the token can run commands in your boxes.

## State and environment

Everything lives in `~/.serbox` (override with `SERBOX_HOME`):

```
boxes/         one JSON record per box
snapshots/     snapshot metadata
jobs/          background job metadata
history/       per-box command history
ports/         published port records
secrets.json   credentials (0600)
hosts.json     remote hosts and tokens (0600)
serve-token    daemon token (0600)
```

Deleting that directory loses serbox's view of the boxes, not the containers.
`serbox doctor` and `docker ps -a --filter label=serbox.managed=1` (or the
Podman equivalent) help recover.

### npm launcher overrides

| variable | effect |
| --- | --- |
| `SERBOX_VERSION` | release to download (default: this package's version) |
| `SERBOX_BINARY` | run this binary and never download |
| `SERBOX_CACHE_DIR` | where the binary is cached (default: `~/.cache/serbox`) |
| `SERBOX_DOWNLOAD_BASE` | full base URL (mirror), overrides repo/version |
| `SERBOX_REPO` | `owner/repo` to download from |
| `SERBOX_FORCE_DOWNLOAD` | re-download even when a cached binary exists |
| `SERBOX_SKIP_DOWNLOAD` | never download; fail if the binary is missing |
| `SERBOX_NO_VERIFY` | skip SHA-256 verification |

### Runtime overrides

| variable | effect |
| --- | --- |
| `SERBOX_RUNTIME` | `docker` or `podman` |
| `SERBOX_HOME` | state directory (default: `~/.serbox`) |

## Troubleshooting

**`the container runtime is not reachable`**
Run `serbox doctor`. For Docker: `docker info` must work without sudo; add the
user to the `docker` group and log in again. For rootless Podman: check
`podman info` and its rootless prerequisites.

**`could not pull image ...`**
Boxes use the server's network, not yours. Check DNS/proxy settings and disk
space, or pass a full image reference with `--image`.

**`port is already in use`**
`serbox port ls` shows what serbox forwards; `ss -ltnp` shows the rest.
`port publish` uses `--host PORT` to pick a different host port.

**A box is stuck or its container disappeared**
`serbox rm NAME --yes` removes the record even when the container is gone.
`serbox gc --dry-run` shows what idle cleanup would do; `serbox gc` is safe to
run from cron.

**Updating**
`npm install -g @tomasko/serbox@latest`. The launcher caches by version, so a
new package version downloads the matching binary. `serbox update` prints the
npm command; serbox does not rewrite its own binary.

**Uninstalling**
`npm uninstall -g @tomasko/serbox`, then remove `~/.cache/serbox` and, if you
want to forget every box, `~/.serbox` (containers are removed with
`serbox rm NAME --yes`).

## Links

- Source and full documentation: <https://github.com/tomasky/serbox>
- Issues: <https://github.com/tomasky/serbox/issues>
- Install script:
  `curl -LsSf https://raw.githubusercontent.com/tomasky/serbox/main/install.sh | bash`

License: **Apache-2.0**.
