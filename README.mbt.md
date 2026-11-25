# serbox

Linux boxes for agents — on your own server.

`serbox` creates small, disposable Docker boxes on the machine it runs on, then
gives you one command to run things inside them, copy files in and out, pause
them, snapshot them and forward their ports. No account, no API key, no control
plane: the server you already have is the control plane.

It is the local counterpart of [instabox](https://instabox.sh): the same box
workflow, without the hosted service.

```bash
npx serbox create --name dev
npx serbox exec dev -- 'apt-get update && apt-get install -y ripgrep'
npx serbox ssh dev
npx serbox rm dev --yes
```

## Install

```bash
npm install -g serbox      # or: npx serbox ...
```

The npm package is a launcher. It downloads the matching static binary from
GitHub Releases on first run into `~/.cache/serbox`, verifies its SHA-256 and
execs it. Works under `--ignore-scripts`, pnpm and npx because there is no
install script.

Other ways:

```bash
# install script
curl -LsSf https://raw.githubusercontent.com/kupas/serbox/main/install.sh | bash

# from source (MoonBit)
moon build --target native --release
./_build/native/release/build/cmd/main/main.exe version
```

Supported targets: `linux-x86_64`, `linux-aarch64`. serbox is meant to run on
the Linux server that owns the boxes; on macOS use a Linux VM or Docker
Desktop's Linux engine.

## Requirements

- Linux with Docker (the `docker` CLI and a reachable daemon)
- Permission to talk to the daemon (`docker` group or root)
- Nothing else — no Python, no runtime, no account

`serbox doctor` checks all of this and says what is missing.

## A box in one minute

```bash
serbox create --name dev --template node    # pull image, start container
serbox exec dev -- 'node --version'         # one command, exit code preserved
serbox ssh dev                              # interactive shell
serbox push dev ./src /data/src             # copy in
serbox pull dev /data/out.log ./out.log     # copy out
serbox suspend dev                          # pause (frees CPU, keeps disk)
serbox resume dev                           # unpause
serbox snapshot save dev --name ready       # commit the box to an image
serbox create --name dev2 --snapshot ready  # start another box from it
serbox port publish dev 3000 --host 3000    # expose a port on this server
serbox rm dev --yes
```

Boxes keep their files under `/data` (`$HOME` is `/data/home`), so `push`,
`pull` and snapshots have one predictable place to work with.

## What a box is

- a Docker container named `serbox-<box>`, labelled `serbox.managed=1`
- running `sleep infinity` so `exec` can attach any time
- created from a template image (`default` is `debian:bookworm-slim`; also
  `ubuntu`, `alpine`, `node`, `python`, `go`, `rust`, `agent`)
- described by a small JSON file in `~/.serbox/boxes/`, so `ls`, `gc` and
  `doctor` work even after a reboot

Isolation is Docker's: namespaces, cgroups and the container's own filesystem.
Boxes share the host kernel. Anyone who can run `docker` can read every box on
the machine, so serbox is for a server you already trust, not for untrusted
multi-tenant hosting.

## Commands

| command | what it does |
| --- | --- |
| `create --name N [--template T] [--env K=V] [--publish P] [--setup-file F]` | start a box |
| `ls`, `get N` | list / inspect boxes |
| `exec N -- CMD` | run a command (`--timeout`, `--stream`, `--background`, `--json`) |
| `ssh N` | interactive shell |
| `push`, `pull`, `cp`, `files N PATH` | move files, list or cat them |
| `suspend` / `resume`, `start` / `stop`, `restart` | lifecycle |
| `snapshot save/ls/rm/restore/import`, `fork N` | images and copies |
| `port publish/unpublish/ls` | forward a box port to this server |
| `secrets set/ls/rm/select/push` | keep credentials out of command lines |
| `auto-suspend N 30m`, `max-run N 2h`, `gc` | idle cleanup |
| `run -- CMD` | create, run, delete in one step (`--keep` to keep) |
| `jobs ls/logs/wait/kill` | background commands started by `exec --background` |
| `ps`, `history`, `output`, `disk`, `metrics`, `logs` | look inside |
| `templates`, `usage`, `doctor`, `completion`, `update` | host and shell help |
| `skills install` | install the serbox agent skill |

Global flags: `--json` (`-o json`), `--no-color`.

### Piping and exit codes

One argument is run through the box's shell, several arguments are an exact
argv with no shell:

```bash
serbox exec dev -- 'echo $HOME && ls /data'   # shell
serbox exec dev -- printf '%s\n' 'a b'        # argv
```

Exit codes follow the documented contract: `2` usage, `4` not found, `75`
retryable, `124` timeout, `130` interrupted, anything else is the command's own
status. `--json` prints `{"error":{"code","message"}}` on stdout and one human
line on stderr, so scripts can parse stdout without losing the reason.

### Agent skills

```bash
serbox skills install          # asks which agents it found
serbox skills install --all -y # claude, codex/cursor/opencode, gemini
```

The skill teaches an agent the loop — create a box, work inside it, bring
results back, clean up — and is installed as plain `SKILL.md` files, so no
network access is needed afterwards.

### Secrets

```bash
serbox secrets set GITHUB_TOKEN     # reads the value from stdin
serbox create --name dev --secrets GITHUB_TOKEN
serbox exec dev -- 'gh auth status' # value is in the environment
```

Values live in `~/.serbox/secrets.json` (mode `0600`) and are passed to the
container as environment variables. `secrets push` writes them to
`/data/.serbox/secrets.env` inside the box for tools that read a file.

## Host state

Everything lives in `~/.serbox` (override with `SERBOX_HOME`):

```
boxes/       one JSON file per box
snapshots/   snapshot metadata
jobs/        background job metadata
history/     per-box command history
ports/       published port records
secrets.json credentials (0600)
```

Deleting that directory loses serbox's view of the boxes, not the containers;
`serbox doctor` and `docker ps -a --filter label=serbox.managed=1` help recover.

## How it differs from instabox

| | `serbox` | `instabox` |
| --- | --- | --- |
| where boxes run | the server you run it on | instabox's cloud |
| account | none | sign in / API key |
| isolation | Docker on your kernel | microVM |
| snapshots | `docker commit` images | VM snapshots |
| port URLs | your server's host and port | public URLs |
| offline | yes (after images are pulled) | no |

Use serbox when you have a Linux box and want the workflow without the service.
Use instabox when you want someone else to run the machines.

## Development

```bash
moon test --target native          # unit tests (no docker needed)
moon build --target native --release
node --test npmjs/                 # npm launcher tests
scripts/build-linux-static.sh      # static musl binary in dist/
```

An end-to-end check that needs Docker:

```bash
SERBOX_HOME=$(mktemp -d) scripts/test-e2e.sh ./_build/native/release/build/cmd/main/main.exe
```

## Publishing

Releases are cut from a tag:

```bash
# bump the version in moon.mod, serbox.mbt and npmjs/package.json
git tag v0.1.1 && git push origin v0.1.1
```

The release workflow builds both static Linux binaries, publishes a GitHub
release with `.sha256` files, then publishes `npmjs/` to npm when the
`NPM_TOKEN` secret is set. To publish by hand:

```bash
cd npmjs && npm publish --access public
```

## License

Apache-2.0.
