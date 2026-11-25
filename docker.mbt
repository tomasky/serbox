///|
/// The container backend: Docker by default, Podman when asked.
///
/// A box is one container, and the runtime is the isolation serbox does not
/// want to reimplement: namespaces, cgroups, filesystem layers, pause/resume
/// and `commit`-based snapshots all come from it. Nothing here talks to a
/// daemon API directly; every call is a CLI, so any Docker-compatible runtime
/// that works from a shell works under serbox.
///
/// Set `SERBOX_RUNTIME=podman` to use Podman even when Docker is installed.
/// Without it, Docker is preferred and Podman is the fallback.

///|
/// The result of a captured command: status, standard output and standard
/// error, already decoded. Docker's output is UTF-8 on every version serbox
/// supports, and undecodable bytes become U+FFFD rather than an error.
pub struct DockerResult {
  code : Int32
  out : String
  err : String
}

///|
fn decode_data(data : &@io.Data) -> String {
  @utf8.decode_lossy(data.binary())
}

///|
/// The container runtime to use: `SERBOX_RUNTIME`, else Docker when present,
/// else Podman. Both speak the same CLI for everything serbox needs.
pub async fn container_runtime() -> String {
  match @env.get_env_var("SERBOX_RUNTIME") {
    Some(value) => {
      let name = value.trim().to_owned()
      if name == "docker" || name == "podman" {
        return name
      }
    }
    None => ()
  }
  for
    path in [
      "/usr/bin/docker", "/usr/local/bin/docker", "/bin/docker", "/snap/bin/docker",
    ] {
    let found = @fs.exists(path) catch { _ => false }
    if found {
      return "docker"
    }
  }
  for path in ["/usr/bin/podman", "/usr/local/bin/podman", "/bin/podman"] {
    let found = @fs.exists(path) catch { _ => false }
    if found {
      return "podman"
    }
  }
  // Nothing found: keep the historical default so the error names Docker, and
  // `SERBOX_RUNTIME=podman` remains the way to get a Podman-specific message.
  "docker"
}

///|
/// Run `<runtime> <args>` and collect its output.
pub async fn docker_capture(args : Array[String]) -> DockerResult {
  let runtime = container_runtime()
  let result = @process.collect_output(runtime, args) catch {
    _ =>
      return {
        code: 127,
        out: "",
        err: "could not run the \{runtime} CLI; is it installed?",
      }
  }
  let (code, out, err) = result
  { code, out: decode_data(out), err: decode_data(err), }
}

///|
/// Run `<runtime> <args>` with this process's stdio, so pull progress and
/// interactive shells reach the terminal.
pub async fn docker_inherit(args : Array[String]) -> Int32 {
  let runtime = container_runtime()
  @process.run(runtime, args) catch {
    _ => 127
  }
}

///|
/// Whether Podman runs without root. Rootless Podman keeps the container on a
/// private network namespace, so a host-side forwarder cannot reach it; ports
/// then have to be published when the box is created.
pub async fn runtime_rootless() -> Bool {
  if container_runtime() != "podman" {
    return false
  }
  let r = docker_capture(["info", "--format", "{{.Host.Security.Rootless}}"])
  r.code == 0 && r.out.trim().to_owned() == "true"
}

///|
/// Whether the container runtime answers. `info` is common to Docker and
/// Podman and does not depend on a version field that differs between them.
pub async fn docker_available() -> Bool {
  let r = docker_capture(["info"])
  r.code == 0
}

///|
/// Whether an image reference already names a registry. `alpine` and
/// `library/alpine` do not; `docker.io/library/alpine`, `ghcr.io/x/y` and
/// `localhost:5000/x` do.
fn image_has_registry(image : String) -> Bool {
  // `ubuntu:22.04` has a colon but no registry. Only the segment before the
  // first slash can name one.
  match image.clamped_view().find("/") {
    None => false
    Some(i) => {
      let first = image.clamped_view().exact_view(start=0, end=i)
      first.contains(".") || first.contains(":") || first == "localhost"
    }
  }
}

///|
/// Podman treats a short image name as an interactive short-name question.
/// Qualifying it keeps pulls and runs non-interactive; serbox's own local
/// snapshot/fork images must stay untouched.
pub async fn resolve_image(image : String) -> String {
  if container_runtime() != "podman" ||
    image.clamped_view().has_prefix("serbox-") ||
    image_has_registry(image) {
    return image
  }
  if image.contains("/") {
    "docker.io/\{image}"
  } else {
    "docker.io/library/\{image}"
  }
}

///|
/// The container serbox uses for a box.
pub fn container_name(box : String) -> String {
  "\{container_prefix}\{box}"
}

///|
/// The image a snapshot is stored as.
pub fn snapshot_image(snapshot : String) -> String {
  "\{snapshot_image_prefix}\{snapshot}:latest"
}

///|
/// `running`, `paused`, `exited`, `created`, `restarting` or `missing`.
pub async fn container_state(box : String) -> String {
  let r = docker_capture([
    "inspect",
    "--format",
    "{{.State.Status}}",
    container_name(box),
  ])
  if r.code != 0 {
    // "missing" means Docker answered and the container is gone; "unknown"
    // means Docker itself failed. Conflating them would let a docker outage
    // look like every box had been deleted.
    let err = r.err
    if err.contains("No such object") ||
      err.contains("No such container") ||
      err.contains("no such") {
      return "missing"
    }
    return "unknown"
  }
  r.out.trim().to_owned()
}

///|
/// Whether a box's container exists at all.
pub async fn container_exists(box : String) -> Bool {
  let state = container_state(box)
  state != "missing" && state != "unknown"
}

///|
/// The host path Docker exposes a container's root filesystem at (an overlay
/// mount). Used only for reading metrics and, when available, nothing else.
pub async fn container_ip(box : String) -> String? {
  let r = docker_capture([
    "inspect",
    "--format",
    "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
    container_name(box),
  ])
  if r.code != 0 || r.out.trim().to_owned().length() == 0 {
    return None
  }
  Some(r.out.trim().to_owned())
}

///|
/// Whether an image is present locally.
pub async fn image_exists(image : String) -> Bool {
  let r = docker_capture(["image", "inspect", "--format", "{{.Id}}", image])
  r.code == 0
}

///|
/// Pull an image, showing progress on stderr the way Docker prints it.
pub async fn pull_image(image : String) -> Bool {
  let reference = resolve_image(image)
  @stdio.stderr.write("serbox: pulling \{reference}\n")
  docker_inherit(["pull", reference]) == 0
}

///|
/// Ensure `image` is present, pulling it when it is not.
pub async fn ensure_image(image : String) -> Bool {
  if image_exists(image) {
    return true
  }
  pull_image(image)
}

///|
/// Start a box's container from a block of `docker run` flags.
///
/// `args` holds everything between `docker run` and the image, so callers
/// decide the ports and environment and this stays one place where the
/// container's identity is fixed.
pub async fn run_container(
  box : String,
  image : String,
  args : Array[String],
) -> DockerResult {
  let cmd : Array[String] = ["run", "-d", "--name", container_name(box)]
  // Nested or unusually configured hosts may not expose the pids controller;
  // crun then refuses to start any container. Podman can run without cgroups,
  // and the box still has namespaces, so use that instead of failing.
  if container_runtime() == "podman" {
    let controllers = read_text("/sys/fs/cgroup/cgroup.controllers")
    match controllers {
      Some(text) => if !text.contains("pids") { cmd.push("--cgroups=disabled") }
      None => ()
    }
  }
  cmd.push("--hostname")
  cmd.push(box)
  cmd.push("--label")
  cmd.push("serbox.managed=1")
  cmd.push("--label")
  cmd.push("\{container_prefix}name=\{box}")
  for arg in args {
    cmd.push(arg)
  }
  cmd.push(image)
  // `sleep` is the init of the container: the box stays alive while commands
  // run in it through `docker exec`. `mkdir` first, so /data exists and the
  // image's own entrypoint never decides whether a box can start.
  cmd.push("sh")
  cmd.push("-c")
  cmd.push("mkdir -p /data/home && exec sleep 2147483647")
  docker_capture(cmd)
}

///|
/// `docker exec` into a box, with the flags that make a command behave like a
/// login shell would: the persistent HOME, a working directory and the box's
/// environment.
pub async fn exec_in_box(
  box : String,
  argv : Array[String],
  cwd : String?,
  env : Map[String, String],
  stdin : Bool,
) -> Int32 {
  let cmd : Array[String] = ["exec"]
  if stdin {
    cmd.push("-i")
  }
  cmd.push("-w")
  match cwd {
    Some(dir) => cmd.push(dir)
    None => cmd.push(box_home)
  }
  for key, value in env {
    cmd.push("-e")
    cmd.push("\{key}=\{value}")
  }
  cmd.push(container_name(box))
  for arg in argv {
    cmd.push(arg)
  }
  docker_inherit(cmd)
}

///|
/// `docker exec` with captured output.
pub async fn exec_in_box_capture(
  box : String,
  argv : Array[String],
) -> DockerResult {
  let cmd : Array[String] = ["exec", container_name(box)]
  for arg in argv {
    cmd.push(arg)
  }
  docker_capture(cmd)
}

///|
/// Pause a container: memory and processes are kept, exactly instabox's
/// suspend.
pub async fn pause_container(box : String) -> DockerResult {
  docker_capture(["pause", container_name(box)])
}

///|
/// Resume a paused container where it left off.
pub async fn unpause_container(box : String) -> DockerResult {
  docker_capture(["unpause", container_name(box)])
}

///|
/// Boot a stopped container; files stay, processes do not.
pub async fn start_container(box : String) -> DockerResult {
  docker_capture(["start", container_name(box)])
}

///|
/// Shut a container down.
pub async fn stop_container(box : String) -> DockerResult {
  docker_capture(["stop", "--time", "10", container_name(box)])
}

///|
/// Power-cycle a container.
pub async fn restart_container(box : String) -> DockerResult {
  docker_capture(["restart", "--time", "10", container_name(box)])
}

///|
/// Delete the container and everything in it. Snapshots taken from it stay.
pub async fn remove_container(box : String) -> DockerResult {
  docker_capture(["rm", "-f", "-v", container_name(box)])
}

///|
/// Save a container's filesystem as an image.
pub async fn commit_container(box : String, image : String) -> DockerResult {
  docker_capture(["commit", container_name(box), image])
}

///|
/// Remove an image.
pub async fn remove_image(image : String) -> DockerResult {
  // Not `-f`: Podman force-removes containers that still use the image, which
  // would turn `snapshot rm` into deleting the boxes created from it.
  docker_capture(["image", "rm", image])
}

///|
/// `docker cp` a host path into a box.
pub async fn copy_in(
  box : String,
  host_path : String,
  remote : String,
) -> DockerResult {
  docker_capture(["cp", host_path, "\{container_name(box)}:\{remote}"])
}

///|
/// `docker cp` a path out of a box.
pub async fn copy_out(
  box : String,
  remote : String,
  host_path : String,
) -> DockerResult {
  docker_capture(["cp", "\{container_name(box)}:\{remote}", host_path])
}

///|
/// A box's console output, `tail` lines or everything.
pub async fn container_logs(box : String, tail : Int32, follow : Bool) -> Int32 {
  let cmd : Array[String] = ["logs"]
  if tail > 0 {
    cmd.push("--tail")
    cmd.push("\{tail}")
  }
  if follow {
    cmd.push("-f")
  }
  cmd.push(container_name(box))
  docker_inherit(cmd)
}

///|
/// `docker stats` for one container, as JSON. `None` when the container is
/// not running, which is also when Docker cannot sample it.
pub async fn container_stats(box : String) -> @json.Json? {
  let r = docker_capture([
    "stats",
    "--no-stream",
    "--format",
    "{{json .}}",
    container_name(box),
  ])
  if r.code != 0 {
    return None
  }
  let json : @json.Json = @json.parse(r.out) catch { _ => return None }
  Some(json)
}

///|
/// The container's processes, as `docker top` prints them.
pub async fn container_top(box : String, all : Bool) -> DockerResult {
  let cmd : Array[String] = ["top", container_name(box)]
  if all {
    cmd.push("-a")
  }
  docker_capture(cmd)
}
