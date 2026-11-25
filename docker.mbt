///|
/// The Docker backend.
///
/// A box is one Docker container, and Docker is the isolation serbox does not
/// want to reimplement: namespaces, cgroups, filesystem layers, pause/resume
/// and `commit`-based snapshots all come from it. Nothing here talks to the
/// Docker API directly; every call is the `docker` CLI, so any Docker
/// installation that works from a shell works under serbox.

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
/// Run `docker <args>` and collect its output.
pub async fn docker_capture(args : Array[String]) -> DockerResult {
  let result = @process.collect_output("docker", args) catch {
    _ =>
      return {
        code: 127,
        out: "",
        err: "could not run the docker CLI; is Docker installed?",
      }
  }
  let (code, out, err) = result
  { code, out: decode_data(out), err: decode_data(err), }
}

///|
/// Run `docker <args>` with this process's stdio, so pull progress and
/// interactive shells reach the terminal.
pub async fn docker_inherit(args : Array[String]) -> Int32 {
  @process.run("docker", args) catch {
    _ => 127
  }
}

///|
/// Whether the Docker daemon answers.
pub async fn docker_available() -> Bool {
  let r = docker_capture(["info", "--format", "{{.ServerVersion}}"])
  r.code == 0 && r.out.trim().to_owned().length() > 0
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
    return "missing"
  }
  r.out.trim().to_owned()
}

///|
/// Whether a box's container exists at all.
pub async fn container_exists(box : String) -> Bool {
  container_state(box) != "missing"
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
  @stdio.stderr.write("serbox: pulling \{image}\n")
  docker_inherit(["pull", image]) == 0
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
  docker_capture(["image", "rm", "-f", image])
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
