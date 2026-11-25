///|
/// serbox — instabox-style Linux boxes on your own server.
///
/// The public surface of this package is deliberately small: the CLI lives in
/// `kupas/serbox/cli`, the box store and the Docker backend behind it, and this
/// file only holds what every part needs — the version and the names of the
/// places serbox keeps its state.

///|
/// The version of this serbox build.
///
/// Single source for `serbox version`, the `--help` banner and the npm
/// launcher. Keep it in step with `moon.mod` and `npmjs/package.json`.
pub let serbox_version : String = "0.1.0"

///|
/// Prefix of every Docker container serbox owns. A container outside this
/// prefix is never touched, so serbox can share a host with other tools.
pub let container_prefix : String = "serbox-"

///|
/// Prefix of every Docker image a snapshot creates.
pub let snapshot_image_prefix : String = "serbox-snap-"

///|
/// The default template and the image it starts from.
///
/// `default` is a bare Debian like instabox's Linux machines: bash, coreutils,
/// git and curl, which is enough for an agent to install what it needs.
pub let default_template : String = "default"

///|
/// Where a box keeps its files, the way instabox keeps `/data`.
pub let box_data_root : String = "/data"

///|
/// HOME inside a box, under the persistent data directory.
pub let box_home : String = "/data/home"

///|
/// What `serbox exec` runs a shell string with.
pub let box_shell : String = "bash -lc"
