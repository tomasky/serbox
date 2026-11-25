# serbox

Linux boxes for agents — on your own server.

```bash
npx @tomasko/serbox create --name dev
npx @tomasko/serbox ssh dev
npx @tomasko/serbox rm dev --yes
```

This package is a small launcher. On first run it downloads the statically
linked `serbox` binary for your machine (linux-x86_64 or linux-aarch64) from
GitHub Releases into `~/.cache/serbox`, verifies the published SHA-256, and
execs it. There is no install script, so it works under `npm ci
--ignore-scripts`, pnpm and `npx`.

Requirements: Linux with a reachable Docker or Podman engine. `serbox doctor`
checks it. Set `SERBOX_RUNTIME=podman` to use Podman; it is detected
automatically when Docker is absent.

`serbox` needs no account, API key or hosted service: it creates isolated
Docker boxes on the machine it runs on and gives you `create`, `exec`, `ssh`,
`push`/`pull`, `suspend`, `snapshot`, `fork`, `port publish`, `secrets` and
`skills install` around them, with `--json` and documented exit codes for
agents and scripts. Four agent skills (`serbox`, `serbox-snapshots`,
`serbox-move-repo`, `serbox-basic-setup`) ship in this package under `skills/`
and are also embedded in the binary, so installation works offline.

Full documentation: https://github.com/tomasky/serbox

License: Apache-2.0.

Environment overrides: `SERBOX_VERSION`, `SERBOX_BINARY`, `SERBOX_CACHE_DIR`,
`SERBOX_DOWNLOAD_BASE`, `SERBOX_REPO`, `SERBOX_NO_VERIFY`.
