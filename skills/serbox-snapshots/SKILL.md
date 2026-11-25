---
name: serbox-snapshots
description: Use when the user wants to save a serbox box's state and load it later - "save a snapshot", "checkpoint this box", "restore from a snapshot", "start a new box from my setup", "clone this box". Covers serbox snapshot save/ls/restore/rm/import, fork and create from a saved image.
metadata:
  installed-by: serbox
---

# serbox snapshots: save, restore, fork

A snapshot is a Docker image made from a box with `docker commit`. It contains
the box's whole filesystem: system files, installed packages and `/data`
(including `HOME`). It does **not** contain running processes, memory, open
connections or host-side port forwards. A box restored from a snapshot is a
power-cut copy: files are exactly as they were, processes are not running.

Snapshots stay on the machine, need no registry and no account. They are listed
under `~/.serbox/snapshots` (or `SERBOX_HOME`) and stored as local Docker
images tagged `serbox-snapshot/<name>:latest`.

## Save

```sh
serbox snapshot save work --name work-ready --description "deps installed"
serbox snapshot save work                    # name: work-<timestamp>
serbox snapshot ls
```

- A running box is committed live. The command waits for Docker to finish, so
  when it returns the snapshot is ready. Stop the box only when a program must
  flush its data first (a database mid-write); `docker commit` also works on a
  stopped box.
- Names are 1 to 80 characters from `a-z`, `A-Z`, `0-9`, `.`, `_` and `-`, must
  start with a letter or digit, and cannot start with `sn_` or `im_`. They must
  be unique on the machine.
- A snapshot can contain credentials that applications wrote to disk (git
  credentials, cloud CLI state, `.netrc`, shell history). Treat a snapshot as
  sensitive: do not publish or share the machine's images without review.

## Restore and load

```sh
serbox snapshot restore work --snapshot work-ready --yes   # in place
serbox create --name work2 --snapshot work-ready           # a new box
serbox fork work --name work2 --count 2                    # copies of a box
```

`snapshot restore` replaces the box's container with the snapshot image. The
box keeps its name, `--env` values, secret names and published ports, but every
file changed since the snapshot is lost. Without `--snapshot` it uses the most
recent snapshot whose source is that box.

`create --snapshot NAME` creates a new box from a snapshot without touching the
source. `fork BOX` commits the current state under a temporary tag and creates
`BOX-copy` boxes from it; the temporary image is not listed as a snapshot.

Snapshots are per-machine. To move one to another host, save the image, copy
it, load it there, then record it as a snapshot:

```sh
docker save serbox-snapshot/work-ready:latest -o work-ready.tar
# copy work-ready.tar to the other host, then:
docker load -i work-ready.tar
serbox snapshot import serbox-snapshot/work-ready:latest --name work-ready
```

`snapshot import IMAGE --name NAME` records an image reference that is already
present locally or that Docker can pull; `--name` is required.

## Remove

```sh
serbox snapshot rm work-ready --yes
```

This deletes the snapshot record and its Docker image. Boxes already created
from it are unaffected. Removing a box never removes its snapshots; remove
those explicitly when they are no longer needed.

## Safety

- Deleting a snapshot is irreversible. Confirm the name with `snapshot ls`
  before running `rm`.
- A snapshot of a box with secrets in its environment does not store the
  environment, but files the box wrote (`.env`, tokens in config files) are
  included. Rotate credentials before sharing an image.
- Published ports are host configuration, not part of the snapshot; a new box
  needs its own `port publish`.
