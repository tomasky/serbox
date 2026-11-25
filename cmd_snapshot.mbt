///|
/// Snapshots and forks: `snapshot save|ls|rm|import|restore` and `fork`.
///
/// A snapshot is a Docker image made with `docker commit`, so it carries the
/// box's whole filesystem — installed software and `/data` alike — without a
/// registry. Creating from a snapshot is a plain `docker run` of that image.

///|
/// Snapshot names end up in image tags, so they follow Docker's tag rules and
/// stay clear of serbox's own `sn`/`im` prefixes.
pub fn valid_snapshot_name(name : String) -> Bool {
  let n = name.length()
  if n == 0 || n > 80 {
    return false
  }
  if name.clamped_view().has_prefix("sn_") ||
    name.clamped_view().has_prefix("im_") {
    return false
  }
  let view = name.clamped_view()
  let first = view.get_char(0).unwrap_or(' ')
  if !((first >= 'a' && first <= 'z') ||
    (first >= 'A' && first <= 'Z') ||
    (first >= '0' && first <= '9')) {
    return false
  }
  for i in 0..<n {
    let c = view.get_char(i).unwrap_or(' ')
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '.' ||
      c == '_' ||
      c == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
/// `serbox snapshot`
pub async fn cmd_snapshot(args : Args) -> Unit {
  let sub = args.arg(0, "snapshot subcommand (save|ls|rm|import|restore)")
  match sub {
    "save" => snapshot_save(args)
    "ls" | "list" => snapshot_ls(args)
    "rm" | "delete" => snapshot_rm(args)
    "import" => snapshot_import(args)
    "restore" => snapshot_restore(args)
    _ => raise usage_error("unknown snapshot subcommand '\{sub}'")
  }
}

///|

///|
/// Snapshotting and forking only need the container to exist: `docker commit`
/// works on a stopped box, and refusing there would block the obvious way to
/// save a box before it is booted again.
async fn require_committable(config : BoxConfig) -> Unit {
  match container_state(config.name) {
    "missing" =>
      raise CliError::Failed(
        4,
        "box '\{config.name}' has no container; run `serbox rm \{config.name}`",
      )
    "unknown" =>
      raise CliError::Failed(
        1, "the container runtime is not answering; run `serbox doctor`",
      )
    _ => ()
  }
}

///|
async fn snapshot_save(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(1, "box name"))
  require_committable(config)
  let name = match args.value("name") {
    Some(name) => name
    None => "\{config.name}-\{compact_time(now_secs())}"
  }
  if !valid_snapshot_name(name) {
    raise usage_error("bad snapshot name '\{name}'")
  }
  if load_snapshot(name) is Some(_) {
    raise CliError::Failed(1, "snapshot '\{name}' already exists")
  }
  let image = snapshot_image(name)
  @stdio.stderr.write("serbox: saving \{config.name} as \{name}\n")
  let committed = commit_container(config.name, image)
  if committed.code != 0 {
    raise CliError::Failed(
      1,
      "could not save the snapshot: \{committed.err.trim().to_owned()}",
    )
  }
  let snapshot : Snapshot = {
    name,
    image,
    source: config.name,
    created_at: now_secs(),
    description: match args.value("description") {
      Some(text) => text
      None => ""
    },
  }
  save_snapshot(snapshot) catch {
    _ => raise CliError::Failed(1, "could not record the snapshot")
  }
  if json_only(@json.to_json(snapshot)) {
    return
  }
  line("saved snapshot \{name} from \{config.name}")
}

///|
async fn snapshot_ls(args : Args) -> Unit {
  ignore(args)
  let snapshots = all_snapshots()
  let rows : Array[Array[String]] = []
  let json_rows : Array[@json.Json] = []
  for snapshot in snapshots {
    rows.push([
      snapshot.name,
      snapshot.source,
      format_age(now_secs() - snapshot.created_at),
      snapshot.description,
    ])
    json_rows.push(@json.to_json(snapshot))
  }
  if json_only(@json.Json::array(json_rows)) {
    return
  }
  if rows.length() == 0 {
    line("no snapshots; save one with `serbox snapshot save BOX`")
    return
  }
  out(render_table(["NAME", "SOURCE", "AGE", "DESCRIPTION"], rows))
}

///|
async fn snapshot_rm(args : Args) -> Unit {
  let name = args.arg(1, "snapshot name")
  let snapshot = match load_snapshot(name) {
    Some(snapshot) => snapshot
    None => raise CliError::Failed(4, "no such snapshot '\{name}'")
  }
  if !args.flag("yes") {
    let yes = confirm("delete snapshot \{name}?") catch { _ => false }
    if !yes {
      raise CliError::Failed(1, "not removed (pass --yes to confirm)")
    }
  }
  let removed = remove_image(snapshot.image)
  if removed.code != 0 {
    raise CliError::Failed(
      1,
      "could not delete the image: \{removed.err.trim().to_owned()}",
    )
  }
  delete_snapshot_config(name)
  if json_only(@json.Json::object(Map([("removed", @json.Json::string(name))]))) {
    return
  }
  line("removed snapshot \{name}")
}

///|
async fn snapshot_import(args : Args) -> Unit {
  let image = resolve_image(args.arg(1, "image"))
  let name = args.need("name")
  if !valid_snapshot_name(name) {
    raise usage_error("bad snapshot name '\{name}'")
  }
  if load_snapshot(name) is Some(_) {
    raise CliError::Failed(1, "snapshot '\{name}' already exists")
  }
  if !image_exists(image) {
    if !pull_image(image) {
      raise CliError::Failed(75, "could not pull image '\{image}'")
    }
  }
  let snapshot : Snapshot = {
    name,
    image,
    source: "",
    created_at: now_secs(),
    description: match args.value("description") {
      Some(text) => text
      None => ""
    },
  }
  save_snapshot(snapshot) catch {
    _ => raise CliError::Failed(1, "could not record the snapshot")
  }
  if json_only(@json.to_json(snapshot)) {
    return
  }
  line("imported \{image} as snapshot \{name}")
}

///|
/// Put a box's files back to a snapshot, in place: same name, same ports.
async fn snapshot_restore(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(1, "box name"))
  let snapshot = match args.value("snapshot") {
    Some(name) =>
      match load_snapshot(name) {
        Some(snapshot) => snapshot
        None => raise CliError::Failed(4, "no such snapshot '\{name}'")
      }
    None => {
      let candidates : Array[Snapshot] = []
      for snapshot in all_snapshots() {
        if snapshot.source == config.name {
          candidates.push(snapshot)
        }
      }
      if candidates.length() == 0 {
        raise CliError::Failed(4, "no snapshot of '\{config.name}' to restore")
      }
      candidates[candidates.length() - 1]
    }
  }
  if !args.flag("yes") {
    let yes = confirm(
      "restore \{config.name} from \{snapshot.name}? everything since then is lost",
    ) catch {
      _ => false
    }
    if !yes {
      raise CliError::Failed(1, "not restored (pass --yes to confirm)")
    }
  }
  let removed = remove_container(config.name)
  if removed.code != 0 && container_state(config.name) != "missing" {
    raise CliError::Failed(
      1,
      "could not stop the box: \{removed.err.trim().to_owned()}",
    )
  }
  let args_run : Array[String] = [
    "-e",
    "HOME=\{box_home}",
    "-e",
    "SERBOX_BOX=\{config.name}",
  ]
  for key, value in config.env {
    args_run.push("-e")
    args_run.push("\{key}=\{value}")
  }
  let stored = load_secrets()
  let secret_entries : Array[(String, String)] = []
  for name in config.secrets {
    match stored.get(name) {
      Some(value) => secret_entries.push((name, value))
      None => ()
    }
  }
  let env_file = write_secret_env_file(secret_entries)
  match env_file {
    Some(path) => {
      args_run.push("--env-file")
      args_run.push(path)
    }
    None => ()
  }
  for port in config.ports {
    args_run.push("-p")
    args_run.push("\{port.host}:\{port.container}")
  }
  let image = resolve_image(snapshot.image)
  let started = run_container(config.name, image, args_run)
  match env_file {
    Some(path) => @fs.remove(path, allow_missing=true) catch { _ => () }
    None => ()
  }
  if started.code != 0 {
    raise CliError::Failed(
      1,
      "could not restore the box: \{started.err.trim().to_owned()}",
    )
  }
  config.paused_by = ""
  config.running_since = now_secs()
  // The container now runs the snapshot image, not the template image it was
  // created from; `inspect` and later saves should report the truth.
  config.image = image
  touch_box(config) catch {
    _ => ()
  }
  if json_only(@json.to_json(config)) {
    return
  }
  line("restored \{config.name} from \{snapshot.name}")
}

///|
/// `serbox fork BOX [--count N] [--name N]`
pub async fn cmd_fork(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  require_committable(config)
  let count = match args.value("count") {
    Some(text) =>
      @string.parse_int(text) catch {
        _ => raise usage_error("bad --count '\{text}'")
      }
    None => 1
  }
  if count < 1 || count > 5 {
    raise usage_error("--count is 1 to 5")
  }
  let base_name = match args.value("name") {
    Some(name) => name
    None => config.name
  }
  let image = "serbox-fork-\{config.name}:latest"
  let committed = commit_container(config.name, image)
  if committed.code != 0 {
    raise CliError::Failed(
      1,
      "could not copy the box: \{committed.err.trim().to_owned()}",
    )
  }
  let created : Array[@json.Json] = []
  for i in 1..<=count {
    // `--name X` is the name to use; without it the copy is `<box>-copy`.
    // Several copies always get a numeric suffix so they cannot collide.
    let name = if count == 1 {
      "\{base_name}-copy"
    } else {
      "\{base_name}-\{i}"
    }
    let name = if count == 1 {
      match args.value("name") {
        Some(explicit) => explicit
        None => name
      }
    } else {
      name
    }
    let child = create_box({
      name,
      template: config.template,
      image,
      env: config.env,
      meta: config.meta,
      ports: [],
      secrets: config.secrets,
      auto_suspend_secs: config.auto_suspend_secs,
      delete_at: 0L,
    })
    created.push(@json.to_json(child))
    if !json_requested() {
      line("created \{name} from \{config.name}")
    }
  }
  let _ = remove_image(image)
  let _ = json_only(@json.Json::array(created))
}
