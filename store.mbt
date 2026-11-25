///|
/// The box store: one JSON file per box under `~/.serbox/boxes`.
///
/// The container is the source of truth for *state* (running, paused, gone),
/// because Docker is the thing that knows. The record is the source of truth
/// for what only serbox knows: the template, the environment, published
/// ports, metadata and the idle/run limits. Losing the record loses the
/// naming, not the files.

///|
/// One published port: a host port on the server, forwarded to a port inside
/// the box.
#derive(Debug, ToJson, FromJson)
pub(all) struct PortMap {
  mut container : Int32
  mut host : Int32
}

///|
/// Everything serbox remembers about a box.
#derive(Debug, ToJson, FromJson)
pub(all) struct BoxConfig {
  mut name : String
  mut template : String
  mut image : String
  /// The login shell this box has: `bash` where it exists, else `sh`.
  mut shell : String
  mut created_at : Int64
  mut env : Map[String, String]
  mut meta : Map[String, String]
  mut ports : Array[PortMap]
  /// Names of the local secrets delivered to this box.
  mut secrets : Array[String]
  /// Pause the box once idle this long. `0` turns it off.
  mut auto_suspend_secs : Int64
  /// Pause the box after this many seconds of runtime. `0` turns it off.
  mut max_run_secs : Int64
  /// Who paused it last: `user` or `auto`. Only `auto` is undone by a command.
  mut paused_by : String
  /// Last time a command touched the box, for the idle check.
  mut last_used_at : Int64
  /// When the box last started running, for the `max-run` limit. `0` when it
  /// is not running.
  mut running_since : Int64
  /// Delete the box at this time. `0` keeps it.
  mut delete_at : Int64
  /// Exit status of the last `--setup-file` run, `-1` before any.
  mut setup_exit : Int32
}

///|
/// A saved copy of a box's filesystem.
#derive(Debug, ToJson, FromJson)
pub(all) struct Snapshot {
  mut name : String
  mut image : String
  mut source : String
  mut created_at : Int64
  mut description : String
}

///|
/// A detached command started with `exec --background`.
#derive(Debug, ToJson, FromJson)
pub(all) struct Job {
  mut id : String
  mut box : String
  mut command : String
  mut started_at : Int64
  mut pid : Int32
}

///|
/// One `exec` that ran, newest last, for `serbox history`.
#derive(Debug, ToJson, FromJson)
pub(all) struct HistoryEntry {
  mut id : String
  mut command : String
  mut exit_code : Int32
  mut started_at : Int64
  mut duration_ms : Int64
  mut stdout_text : String
  mut stderr_text : String
}

///|
pub fn boxes_dir() -> String {
  path_join(serbox_home(), "boxes")
}

///|
pub fn snapshots_dir() -> String {
  path_join(serbox_home(), "snapshots")
}

///|
pub fn jobs_dir() -> String {
  path_join(serbox_home(), "jobs")
}

///|
pub fn history_dir() -> String {
  path_join(serbox_home(), "history")
}

///|
pub fn box_config_path(name : String) -> String {
  path_join(boxes_dir(), "\{name}.json")
}

///|
pub fn snapshot_config_path(name : String) -> String {
  path_join(snapshots_dir(), "\{name}.json")
}

///|
/// The record a freshly created box starts from.
pub fn new_box_config(
  name : String,
  template : String,
  image : String,
) -> BoxConfig {
  {
    name,
    template,
    image,
    shell: "bash",
    created_at: now_secs(),
    env: Map([]),
    meta: Map([]),
    ports: [],
    secrets: [],
    auto_suspend_secs: 1800L,
    max_run_secs: 0L,
    paused_by: "",
    last_used_at: now_secs(),
    running_since: 0L,
    delete_at: 0L,
    setup_exit: -1,
  }
}

///|
pub async fn save_box(config : BoxConfig) -> Unit {
  ensure_dir(boxes_dir())
  write_text(box_config_path(config.name), @json.to_json(config).stringify())
}

///|
/// Fill in fields a record written by another serbox build did not have, so a
/// field added in a newer version never makes an older box unreadable.
pub fn with_box_defaults(json : @json.Json) -> @json.Json {
  match (json, @json.to_json(new_box_config("", "", ""))) {
    (@json.Json::Object(members), @json.Json::Object(defaults)) => {
      for key, value in defaults {
        if !members.contains(key) {
          members.set(key, value)
        }
      }
      json
    }
    _ => json
  }
}

///|
pub async fn load_box(name : String) -> BoxConfig? {
  match read_text(box_config_path(name)) {
    None => None
    Some(text) => {
      let json = @json.parse(text) catch { _ => return None }
      let config : BoxConfig = @json.from_json(with_box_defaults(json)) catch {
        _ => return None
      }
      Some(config)
    }
  }
}

///|
pub async fn delete_box_config(name : String) -> Unit {
  @fs.remove(box_config_path(name), allow_missing=true) catch {
    _ => ()
  }
}

///|
/// Every box record on this host, oldest first.
pub async fn all_boxes() -> Array[BoxConfig] {
  let names = list_dir(boxes_dir())
  let boxes : Array[BoxConfig] = []
  for entry in names {
    if entry.clamped_view().has_suffix(".json") {
      let name = entry
        .clamped_view()
        .exact_view(start=0, end=entry.length() - 5)
        .to_owned()
      match load_box(name) {
        Some(config) => boxes.push(config)
        None => ()
      }
    }
  }
  boxes.sort_by(fn(a, b) {
    if a.created_at < b.created_at {
      -1
    } else if a.created_at > b.created_at {
      1
    } else {
      0
    }
  })
  boxes
}

///|
pub async fn save_snapshot(snapshot : Snapshot) -> Unit {
  ensure_dir(snapshots_dir())
  write_text(
    snapshot_config_path(snapshot.name),
    @json.to_json(snapshot).stringify(),
  )
}

///|
pub async fn load_snapshot(name : String) -> Snapshot? {
  match read_text(snapshot_config_path(name)) {
    None => None
    Some(text) => {
      let json = @json.parse(text) catch { _ => return None }
      let snapshot : Snapshot = @json.from_json(json) catch { _ => return None }
      Some(snapshot)
    }
  }
}

///|
pub async fn all_snapshots() -> Array[Snapshot] {
  let names = list_dir(snapshots_dir())
  let snapshots : Array[Snapshot] = []
  for entry in names {
    if entry.clamped_view().has_suffix(".json") {
      let name = entry
        .clamped_view()
        .exact_view(start=0, end=entry.length() - 5)
        .to_owned()
      match load_snapshot(name) {
        Some(snapshot) => snapshots.push(snapshot)
        None => ()
      }
    }
  }
  snapshots.sort_by(fn(a, b) {
    if a.created_at < b.created_at {
      -1
    } else if a.created_at > b.created_at {
      1
    } else {
      0
    }
  })
  snapshots
}

///|
pub async fn delete_snapshot_config(name : String) -> Unit {
  @fs.remove(snapshot_config_path(name), allow_missing=true) catch {
    _ => ()
  }
}

///|
/// Mark a box as used now. Every command that runs something in a box calls
/// this, so the idle check measures work, not file timestamps.
pub async fn touch_box(config : BoxConfig) -> Unit {
  config.last_used_at = now_secs()
  save_box(config) catch {
    _ => ()
  }
}

///|
/// The state a user sees, combining Docker's state with serbox's own.
///
/// `auto-paused` is a paused box that paused itself and would resume on the
/// next command; `paused` and `stopped` are the user's own decisions.
pub fn display_state(container_state : String, paused_by : String) -> String {
  match container_state {
    "running" => "running"
    "paused" => if paused_by == "auto" { "auto-paused" } else { "paused" }
    "exited" | "created" => "stopped"
    "restarting" => "restarting"
    "missing" => "lost"
    "unknown" => "unknown"
    _ => container_state
  }
}

///|
/// The reason a command cannot touch a box, or `None` when it can.
///
/// `wake=true` revives a box that paused itself, which is instabox's rule:
/// idle pauses are transparent, a pause the user asked for is not.
pub async fn box_blocked_reason(config : BoxConfig, wake : Bool) -> String? {
  let state = container_state(config.name)
  match state {
    "running" => None
    "restarting" => None
    "paused" =>
      if config.paused_by == "auto" && wake {
        let r = unpause_container(config.name)
        if r.code == 0 {
          config.paused_by = ""
          config.running_since = now_secs()
          touch_box(config) catch {
            _ => ()
          }
          None
        } else {
          Some("could not resume the box: \{r.err.trim().to_owned()}")
        }
      } else if config.paused_by == "auto" {
        None
      } else {
        Some(
          "box '\{config.name}' is paused; run `serbox resume \{config.name}` first",
        )
      }
    "exited" | "created" =>
      Some(
        "box '\{config.name}' is stopped; run `serbox start \{config.name}` first",
      )
    "missing" =>
      Some(
        "box '\{config.name}' has no container; run `serbox rm \{config.name}`",
      )
    "unknown" =>
      Some("the docker daemon is not answering; check it with `serbox doctor`")
    _ => None
  }
}

///|
/// Load a box or report the exact command that creates one.
pub async fn require_box(name : String) -> BoxConfig? {
  match load_box(name) {
    Some(config) => Some(config)
    None => None
  }
}

///|
/// A published port: a detached forwarder on the host, from a host port to a
/// port inside a box.
#derive(Debug, ToJson, FromJson)
pub(all) struct PortForward {
  mut box : String
  mut container : Int32
  mut host : Int32
  mut pid : Int32
  mut created_at : Int64
}

///|
pub fn ports_dir() -> String {
  path_join(serbox_home(), "ports")
}

///|
pub fn port_record_path(box : String, container_port : Int32) -> String {
  path_join(ports_dir(), "\{box}-\{container_port}.json")
}

///|
pub async fn save_port_forward(forward : PortForward) -> Unit {
  ensure_dir(ports_dir())
  write_text(
    port_record_path(forward.box, forward.container),
    @json.to_json(forward).stringify(),
  )
}

///|
pub async fn load_port_forward(
  box : String,
  container_port : Int32,
) -> PortForward? {
  match read_text(port_record_path(box, container_port)) {
    None => None
    Some(text) => {
      let json = @json.parse(text) catch { _ => return None }
      let forward : PortForward = @json.from_json(json) catch {
        _ => return None
      }
      Some(forward)
    }
  }
}

///|
pub async fn all_port_forwards() -> Array[PortForward] {
  let names = list_dir(ports_dir())
  let forwards : Array[PortForward] = []
  for entry in names {
    if entry.clamped_view().has_suffix(".json") {
      match read_text(path_join(ports_dir(), entry)) {
        Some(text) => {
          let json = @json.parse(text) catch { _ => continue }
          let forward : PortForward = @json.from_json(json) catch {
            _ => continue
          }
          forwards.push(forward)
        }
        None => ()
      }
    }
  }
  forwards
}

///|
/// A server this CLI can drive remotely: the SSH target used to reach it, the
/// daemon port on that server, and the token that daemon requires.
///
/// The token is as sensitive as an SSH key: anyone holding it can run any
/// serbox command on that server. `hosts.json` is therefore written `0600`.
#derive(Debug, ToJson, FromJson)
pub(all) struct HostRecord {
  mut name : String
  /// `user@host` for ssh, or "" when only a pre-made tunnel address is known.
  mut target : String
  /// The `serbox` path on the server, or "serbox" when it is on PATH.
  mut remote_bin : String
  mut remote_port : Int32
  /// Local end of the ssh tunnel; this is what clients connect to.
  mut local_port : Int32
  /// Bearer token for the remote daemon.
  mut token : String
  /// ssh tunnel process, so `host rm` can stop it.
  mut tunnel_pid : Int32
  mut created_at : Int64
}

///|
pub fn hosts_path() -> String {
  path_join(serbox_home(), "hosts.json")
}

///|
pub async fn all_hosts() -> Array[HostRecord] {
  match read_text(hosts_path()) {
    None => []
    Some(text) => {
      let json = @json.parse(text) catch { _ => return [] }
      let hosts : Array[HostRecord] = @json.from_json(json) catch {
        _ => return []
      }
      hosts
    }
  }
}

///|
pub async fn save_hosts(hosts : Array[HostRecord]) -> Unit {
  ensure_dir(serbox_home())
  write_secret(hosts_path(), @json.to_json(hosts).stringify())
}

///|
pub async fn load_host(name : String) -> HostRecord? {
  for host in all_hosts() {
    if host.name == name {
      return Some(host)
    }
  }
  None
}

///|
/// Replace one host record, or append it when the name is new.
pub async fn upsert_host(record : HostRecord) -> Unit {
  let hosts = all_hosts()
  let out : Array[HostRecord] = []
  let mut replaced = false
  for host in hosts {
    if host.name == record.name {
      out.push(record)
      replaced = true
    } else {
      out.push(host)
    }
  }
  if !replaced {
    out.push(record)
  }
  save_hosts(out)
}

///|
pub async fn delete_host(name : String) -> Bool {
  let out : Array[HostRecord] = []
  let mut found = false
  for host in all_hosts() {
    if host.name == name {
      found = true
    } else {
      out.push(host)
    }
  }
  if found {
    save_hosts(out)
  }
  found
}
