///|
/// Box lifecycle: create, list, inspect, rename, delete, start/stop, suspend
/// and resume, plus the runtime limits (`auto-suspend`, `max-run`, `resize`),
/// `gc` and `run`.

///|
/// The image a template starts from. Everything here is a public Docker Hub
/// image, so a fresh server needs no registry of its own.
pub fn template_image(template : String) -> String? {
  match template {
    "default" | "debian" => Some("debian:bookworm-slim")
    "ubuntu" => Some("ubuntu:24.04")
    "alpine" => Some("alpine:3.20")
    "node" => Some("node:22-bookworm")
    "python" => Some("python:3.12-bookworm")
    "go" | "golang" => Some("golang:1.23-bookworm")
    "rust" => Some("rust:1.83-bookworm")
    "agent" => Some("node:22-bookworm")
    _ => None
  }
}

///|
pub let template_names : Array[String] = [
  "default", "ubuntu", "alpine", "node", "python", "go", "rust", "agent",
]

///|
pub fn parse_port(text : String) -> Int32 raise {
  let port = @string.parse_int(text) catch {
    _ => raise usage_error("bad port '\{text}'")
  }
  if port <= 0 || port > 65535 {
    raise usage_error("bad port '\{text}' (1-65535)")
  }
  port
}

///|
/// Parse a `--publish` value: `8080` publishes 8080 on the host, `8080:18080`
/// maps box port 8080 to host 18080.
pub fn parse_publish(text : String) -> PortMap raise {
  let parts : Array[String] = []
  for part in text.split(":") {
    parts.push(part.to_owned())
  }
  if parts.length() == 1 {
    let port = parse_port(parts[0])
    { container: port, host: port, }
  } else if parts.length() == 2 {
    let c = parse_port(parts[0])
    let h = parse_port(parts[1])
    { container: c, host: h, }
  } else {
    raise usage_error("bad --publish '\{text}' (use PORT or PORT:HOSTPORT)")
  }
}

///|
/// `KEY=VALUE` from a flag, or a usage error.
pub fn parse_assignment(text : String, flag : String) -> (String, String) raise {
  match split_assignment(text) {
    Some(pair) => pair
    None => raise usage_error("--\{flag} expects KEY=VALUE, got '\{text}'")
  }
}

///|
/// Read a `.env`-style file: one `KEY=VALUE` per line, `#` comments and blank
/// lines ignored.
pub async fn read_env_file(path : String) -> Map[String, String] {
  let text = match read_text(path) {
    Some(text) => text
    None => raise CliError::Failed(1, "cannot read env file '\{path}'")
  }
  let values : Map[String, String] = Map([])
  for raw in text.split("\n") {
    let line = raw.trim().to_owned()
    if line.length() == 0 || line.clamped_view().has_prefix("#") {
      continue
    }
    match split_assignment(line) {
      Some((key, value)) => values.set(key, value)
      None => ()
    }
  }
  values
}

///|
pub async fn load_box_or_fail(name : String) -> BoxConfig {
  match load_box(name) {
    Some(config) => config
    None => raise CliError::Failed(4, "no such box '\{name}'")
  }
}

///|
/// Refuse a command against a box that cannot take it, with the exact command
/// that fixes the state. `wake` transparently resumes an auto-pause.
pub async fn require_usable(config : BoxConfig, wake : Bool) -> Unit {
  match box_blocked_reason(config, wake) {
    Some(reason) => raise CliError::Failed(1, reason)
    None => ()
  }
}

///|
async fn box_state(config : BoxConfig) -> String {
  display_state(container_state(config.name), config.paused_by)
}

///|
/// A short, unique box name for commands that do not ask for one.
pub fn generate_box_name(prefix : String) -> String {
  let stamp = @env.now() % 100000UL
  "\{prefix}\{stamp}"
}

///|
/// What every path that creates a box needs. Kept in one struct so `create`
/// and `run` cannot drift apart.
pub struct CreateOptions {
  name : String
  template : String
  image : String
  env : Map[String, String]
  meta : Map[String, String]
  ports : Array[PortMap]
  secrets : Array[String]
  auto_suspend_secs : Int64
  delete_at : Int64
}

///|
pub async fn create_box(options : CreateOptions) -> BoxConfig {
  let docker_ok = docker_available()
  if !docker_ok {
    raise CliError::Failed(
      1, "the docker daemon is not reachable; run `serbox doctor`",
    )
  }
  if !valid_box_name(options.name) {
    raise usage_error(
      "bad box name '\{options.name}' (lowercase letters, digits, - and _, at most 40)",
    )
  }
  if load_box(options.name) is Some(_) {
    raise CliError::Failed(1, "box '\{options.name}' already exists")
  }
  if container_exists(options.name) {
    raise CliError::Failed(
      1,
      "a container named '\{container_name(options.name)}' already exists; remove it with `serbox rm \{options.name}`",
    )
  }
  let image = options.image
  if !image_exists(image) {
    if !pull_image(image) {
      raise CliError::Failed(75, "could not pull image '\{image}'")
    }
  }
  let args : Array[String] = [
    "-e",
    "HOME=\{box_home}",
    "-e",
    "SERBOX_BOX=\{options.name}",
    "-w",
    box_home,
  ]
  let secrets = load_secrets()
  for name in options.secrets {
    match secrets.get(name) {
      Some(value) => {
        args.push("-e")
        args.push("\{name}=\{value}")
      }
      None => ()
    }
  }
  for key, value in options.env {
    args.push("-e")
    args.push("\{key}=\{value}")
  }
  for port in options.ports {
    args.push("-p")
    args.push("\{port.host}:\{port.container}")
  }
  let result = run_container(options.name, image, args)
  if result.code != 0 {
    raise CliError::Failed(
      75,
      "docker could not start the box: \{result.err.trim().to_owned()}",
    )
  }
  let config = new_box_config(options.name, options.template, image)
  let shell_probe = exec_in_box_capture(options.name, [
    "sh", "-c", "command -v bash >/dev/null 2>&1 && echo bash || echo sh",
  ])
  if shell_probe.code == 0 && shell_probe.out.trim().length() > 0 {
    config.shell = shell_probe.out.trim().to_owned()
  }
  config.env = options.env
  config.meta = options.meta
  config.ports = options.ports
  config.auto_suspend_secs = options.auto_suspend_secs
  config.delete_at = options.delete_at
  config.last_used_at = now_secs()
  save_box(config) catch {
    _ =>
      raise CliError::Failed(
        1,
        "the box started but its record could not be written to \{box_config_path(config.name)}",
      )
  }
  config
}

///|
/// `serbox create`
pub async fn cmd_create(args : Args) -> Unit {
  let name = match args.value("name") {
    Some(name) => name
    None => generate_box_name("box-")
  }
  let template = match args.value("template") {
    Some(t) => t
    None =>
      if args.value("image") is Some(_) || args.value("snapshot") is Some(_) {
        "custom"
      } else {
        default_template
      }
  }
  let image = match args.value("image") {
    Some(image) => image
    None =>
      match args.value("snapshot") {
        Some(snapshot_name) =>
          match load_snapshot(snapshot_name) {
            Some(snapshot) => snapshot.image
            None =>
              raise CliError::Failed(4, "no such snapshot '\{snapshot_name}'")
          }
        None =>
          match template_image(template) {
            Some(image) => image
            None =>
              raise usage_error(
                "unknown template '\{template}'; try: \{template_names.join(", ")}",
              )
          }
      }
  }
  let env : Map[String, String] = Map([])
  for text in args.all("env") {
    let (key, value) = parse_assignment(text, "env")
    env.set(key, value)
  }
  for file in args.all("env-file") {
    let from_file = read_env_file(file)
    for key, value in from_file {
      env.set(key, value)
    }
  }
  let meta : Map[String, String] = Map([])
  for text in args.all("meta") {
    let (key, value) = parse_assignment(text, "meta")
    meta.set(key, value)
  }
  let ports : Array[PortMap] = []
  for text in args.all("publish") {
    ports.push(parse_publish(text))
  }
  let auto_suspend = match args.value("auto-suspend") {
    Some(text) =>
      match parse_duration(text) {
        Some(secs) => secs
        None =>
          raise usage_error("bad --auto-suspend '\{text}' (e.g. 10m or 0)")
      }
    None => 1800L
  }
  let delete_at = match args.value("delete-after") {
    Some(text) =>
      match parse_duration(text) {
        Some(secs) => if secs == 0L { 0L } else { now_secs() + secs }
        None => raise usage_error("bad --delete-after '\{text}' (e.g. 1h)")
      }
    None => 0L
  }
  let selected_secrets = match args.value("secrets") {
    Some("all") => secrets_names()
    Some("none") | None => []
    Some(list) => {
      let names : Array[String] = []
      for name in list.split(",") {
        names.push(name.to_owned())
      }
      names
    }
  }
  let config = create_box({
    name,
    template,
    image,
    env,
    meta,
    ports,
    secrets: selected_secrets,
    auto_suspend_secs: auto_suspend,
    delete_at,
  })
  match args.value("setup-file") {
    Some(path) => run_setup_file(config, path, false)
    None => ()
  }
  if args.flag("no-wait") {
    if json_only(@json.to_json(config)) {
      return
    }
    line("created box \{config.name}")
    return
  }
  if json_only(@json.to_json(config)) {
    return
  }
  line("box \{bold(config.name)} is running")
  line("  template  \{config.template} (\{config.image})")
  line("  home      \{box_home}")
  if config.ports.length() > 0 {
    let maps : Array[String] = []
    for port in config.ports {
      maps.push("\{port.host} -> \{port.container}")
    }
    line("  ports     \{maps.join(", ")}")
  }
  line("next: serbox ssh \{config.name}")
}

///|
/// Run a setup script inside a box: copy it in, run it with bash, record the
/// exit status. A failed script keeps the box, as instabox's does.
pub async fn run_setup_file(
  config : BoxConfig,
  path : String,
  quiet : Bool,
) -> Unit {
  let script = match read_text(path) {
    Some(text) => text
    None => raise CliError::Failed(1, "cannot read setup file '\{path}'")
  }
  // `docker cp` keeps the script out of the heredoc quoting problem entirely.
  let prepared = exec_in_box_capture(config.name, [
    "mkdir", "-p", "/data/.serbox",
  ])
  if prepared.code != 0 {
    raise CliError::Failed(1, "could not prepare the setup directory")
  }
  let local_copy = path_join(serbox_home(), "setup.tmp.sh")
  ensure_dir(serbox_home()) catch {
    _ => ()
  }
  write_text(local_copy, script) catch {
    _ => raise CliError::Failed(1, "cannot stage the setup script")
  }
  let copied = copy_in(config.name, local_copy, "/data/.serbox/setup.sh")
  @fs.remove(local_copy, allow_missing=true) catch {
    _ => ()
  }
  if copied.code != 0 {
    raise CliError::Failed(
      1,
      "could not copy the setup script: \{copied.err.trim().to_owned()}",
    )
  }
  let code = exec_in_box(
    config.name,
    [config.shell, "/data/.serbox/setup.sh"],
    Some(box_home),
    Map([]),
    false,
  )
  config.setup_exit = code
  save_box(config) catch {
    _ => ()
  }
  if code != 0 {
    if !quiet {
      eline("serbox: setup script exited \{code}; box \{config.name} was kept")
    }
    raise CliError::Failed(code, "setup script failed")
  }
}

///|
/// `serbox ls`
pub async fn cmd_ls(args : Args) -> Unit {
  let boxes = all_boxes()
  let filters : Array[(String, String)] = []
  for text in args.all("meta") {
    filters.push(parse_assignment(text, "meta"))
  }
  let rows : Array[Array[String]] = []
  let json_rows : Array[@json.Json] = []
  for config in boxes {
    let mut matches = true
    for filter in filters {
      let (key, value) = filter
      match config.meta.get(key) {
        Some(have) => if have != value { matches = false }
        None => matches = false
      }
    }
    if !matches {
      continue
    }
    let state = box_state(config)
    let age = format_age(now_secs() - config.created_at)
    let ports : Array[String] = []
    for port in config.ports {
      ports.push("\{port.host}->\{port.container}")
    }
    rows.push([config.name, state, config.template, age, ports.join(",")])
    json_rows.push(@json.to_json(config))
  }
  if json_only(@json.Json::array(json_rows)) {
    return
  }
  if rows.length() == 0 {
    line("no boxes; create one with `serbox create --name dev`")
    return
  }
  let table = render_table(["NAME", "STATE", "TEMPLATE", "AGE", "PORTS"], rows)
  out(table)
}

///|
/// `serbox get`
pub async fn cmd_get(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  if json_only(@json.to_json(config)) {
    return
  }
  let state = box_state(config)
  line("\{bold(config.name)}  \{state}")
  line("  template   \{config.template} (\{config.image})")
  line("  created    \{format_age(now_secs() - config.created_at)} ago")
  line("  home       \{box_home}")
  if config.ports.length() > 0 {
    let maps : Array[String] = []
    for port in config.ports {
      maps.push("\{port.host} -> \{port.container}")
    }
    line("  ports      \{maps.join(", ")}")
  }
  if config.env.length() > 0 {
    let keys : Array[String] = []
    for key, _ in config.env {
      keys.push(key)
    }
    line("  env        \{keys.join(", ")}")
  }
  if config.meta.length() > 0 {
    let pairs : Array[String] = []
    for key, value in config.meta {
      pairs.push("\{key}=\{value}")
    }
    line("  meta       \{pairs.join(", ")}")
  }
  if config.auto_suspend_secs > 0L {
    line("  auto-pause after \{format_duration(config.auto_suspend_secs)} idle")
  } else {
    line("  auto-pause off")
  }
  if config.max_run_secs > 0L {
    line("  max run    \{format_duration(config.max_run_secs)}")
  }
}

///|
/// `serbox rename`
pub async fn cmd_rename(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let new_name = args.arg(1, "new name")
  if !valid_box_name(new_name) {
    raise usage_error("bad box name '\{new_name}'")
  }
  if load_box(new_name) is Some(_) {
    raise CliError::Failed(1, "box '\{new_name}' already exists")
  }
  let renamed = docker_capture([
    "rename",
    container_name(config.name),
    container_name(new_name),
  ])
  if renamed.code != 0 {
    raise CliError::Failed(
      1,
      "could not rename the container: \{renamed.err.trim().to_owned()}",
    )
  }
  @fs.remove(box_config_path(config.name), allow_missing=true) catch {
    _ => ()
  }
  config.name = new_name
  save_box(config) catch {
    _ => ()
  }
  if json_only(@json.to_json(config)) {
    return
  }
  line("renamed to \{new_name}")
}

///|
/// Ask y/N on a terminal. Off a terminal the answer is no: destructive
/// commands need `--yes`, so a pipe cannot delete a box by accident.
pub async fn confirm(question : String) -> Bool {
  if !stdout_is_tty() {
    return false
  }
  out("\{question} [y/N] ")
  match @stdio.stdin.read_until("\n") {
    Some(answer) => {
      let text = ascii_lowercase(answer.trim().to_owned())
      text == "y" || text == "yes"
    }
    None => false
  }
}

///|
/// `serbox rm`
pub async fn cmd_rm(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let force = args.flag("yes") || args.flag("force")
  if !force {
    let yes = confirm("remove box \{config.name} and its files?") catch {
      _ => false
    }
    if !yes {
      raise CliError::Failed(1, "not removed (pass --yes to confirm)")
    }
  }
  // Stop forwarders first: a listener on a dead container only produces
  // connection resets, and its record would outlive the box file.
  unpublish_box_ports(config.name) catch {
    _ => ()
  }
  let removed = remove_container(config.name)
  if removed.code != 0 {
    raise CliError::Failed(
      1,
      "could not remove the container: \{removed.err.trim().to_owned()}",
    )
  }
  delete_box_config(config.name)
  if json_only(
      @json.Json::object(Map([("removed", @json.Json::string(config.name))])),
    ) {
    return
  }
  line("removed box \{config.name}")
}

///|
/// `serbox start|stop|suspend|resume|restart|wake`
pub async fn cmd_lifecycle(command : String, args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  match command {
    "start" => {
      let state = container_state(config.name)
      let result = if state == "paused" {
        unpause_container(config.name)
      } else {
        start_container(config.name)
      }
      if result.code != 0 {
        raise CliError::Failed(
          1,
          "could not start: \{result.err.trim().to_owned()}",
        )
      }
      config.paused_by = ""
      touch_box(config) catch {
        _ => ()
      }
    }
    "stop" => {
      let result = stop_container(config.name)
      if result.code != 0 {
        raise CliError::Failed(
          1,
          "could not stop: \{result.err.trim().to_owned()}",
        )
      }
      config.paused_by = ""
      save_box(config) catch {
        _ => ()
      }
    }
    "suspend" | "pause" => {
      let state = container_state(config.name)
      if state != "running" {
        raise CliError::Failed(
          1,
          "box '\{config.name}' is \{display_state(state, config.paused_by)}, not running",
        )
      }
      let result = pause_container(config.name)
      if result.code != 0 {
        raise CliError::Failed(
          1,
          "could not pause: \{result.err.trim().to_owned()}",
        )
      }
      config.paused_by = "user"
      save_box(config) catch {
        _ => ()
      }
    }
    "resume" | "wake" => {
      let state = container_state(config.name)
      if state == "paused" {
        let result = unpause_container(config.name)
        if result.code != 0 {
          raise CliError::Failed(
            1,
            "could not resume: \{result.err.trim().to_owned()}",
          )
        }
        config.paused_by = ""
        touch_box(config) catch {
          _ => ()
        }
      } else if command == "wake" && (state == "exited" || state == "created") {
        raise CliError::Failed(
          1,
          "box '\{config.name}' is stopped; `serbox start \{config.name}` boots it",
        )
      } else if command == "resume" && (state == "exited" || state == "created") {
        let result = start_container(config.name)
        if result.code != 0 {
          raise CliError::Failed(
            1,
            "could not start: \{result.err.trim().to_owned()}",
          )
        }
        config.paused_by = ""
        touch_box(config) catch {
          _ => ()
        }
      }
    }
    "restart" | "recover" => {
      let result = restart_container(config.name)
      if result.code != 0 {
        raise CliError::Failed(
          1,
          "could not restart: \{result.err.trim().to_owned()}",
        )
      }
      config.paused_by = ""
      touch_box(config) catch {
        _ => ()
      }
    }
    _ => raise usage_error("unknown lifecycle command '\{command}'")
  }
  let state = box_state(config)
  if json_only(@json.to_json(config)) {
    return
  }
  line("box \{config.name} is \{state}")
}

///|
/// `serbox auto-suspend BOX DURATION|0`
pub async fn cmd_auto_suspend(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let text = args.arg(1, "duration")
  let secs = match parse_duration(text) {
    Some(secs) => secs
    None => raise usage_error("bad duration '\{text}' (e.g. 10m or 0)")
  }
  config.auto_suspend_secs = secs
  save_box(config) catch {
    _ => ()
  }
  if json_only(@json.to_json(config)) {
    return
  }
  if secs == 0L {
    line("auto-pause off for \{config.name}")
  } else {
    line("box \{config.name} pauses after \{format_duration(secs)} idle")
  }
}

///|
/// `serbox max-run BOX MINUTES`
pub async fn cmd_max_run(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let text = args.arg(1, "minutes")
  let minutes = @string.parse_int(text) catch {
    _ => raise usage_error("bad minutes '\{text}'")
  }
  if minutes < 0 {
    config.max_run_secs = 0L
  } else if minutes == 0 {
    let paused = pause_container(config.name)
    if paused.code == 0 {
      config.paused_by = "user"
    }
    config.max_run_secs = 0L
  } else {
    config.max_run_secs = minutes.to_int64() * 60L
  }
  save_box(config) catch {
    _ => ()
  }
  if json_only(@json.to_json(config)) {
    return
  }
  line("max run set to \{minutes} minute(s)")
}

///|
/// `serbox resize BOX --cpus N --memory M`
pub async fn cmd_resize(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let cpus = args.value("cpus")
  let memory = args.value("memory")
  if cpus is None && memory is None {
    if args.value("disk") is Some(_) {
      raise CliError::Failed(
        1, "--disk is not supported: a Docker box has no separate data disk to grow",
      )
    }
    raise usage_error("resize needs --cpus and/or --memory")
  }
  let cmd : Array[String] = ["update"]
  match cpus {
    Some(value) => {
      cmd.push("--cpus")
      cmd.push(value)
    }
    None => ()
  }
  match memory {
    Some(value) => {
      cmd.push("--memory")
      cmd.push(value)
    }
    None => ()
  }
  cmd.push(container_name(config.name))
  let result = docker_capture(cmd)
  if result.code != 0 {
    raise CliError::Failed(
      1,
      "could not resize: \{result.err.trim().to_owned()}",
    )
  }
  if json_only(@json.to_json(config)) {
    return
  }
  line("resized box \{config.name}")
}

///|
/// `serbox templates`
pub async fn cmd_templates() -> Unit {
  let rows : Array[Array[String]] = []
  let json_rows : Array[@json.Json] = []
  for name in template_names {
    let image = match template_image(name) {
      Some(image) => image
      None => ""
    }
    rows.push([name, image])
    json_rows.push(
      @json.Json::object(
        Map([
          ("name", @json.Json::string(name)),
          ("image", @json.Json::string(image)),
        ]),
      ),
    )
  }
  if json_only(@json.Json::array(json_rows)) {
    return
  }
  out(render_table(["TEMPLATE", "IMAGE"], rows))
}

///|
/// `serbox usage`
pub async fn cmd_usage() -> Unit {
  let boxes = all_boxes()
  let snapshots = all_snapshots()
  let mut running = 0
  for config in boxes {
    if container_state(config.name) == "running" {
      running = running + 1
    }
  }
  let json = @json.Json::object(
    Map([
      ("boxes", @json.Json::number(running.to_double())),
      ("boxesTotal", @json.Json::number(boxes.length().to_double())),
      ("snapshots", @json.Json::number(snapshots.length().to_double())),
      ("home", @json.Json::string(serbox_home())),
    ]),
  )
  if json_only(json) {
    return
  }
  line("boxes      \{boxes.length()} (\{running} running)")
  line("snapshots  \{snapshots.length()}")
  line("home       \{serbox_home()}")
}

///|
/// `serbox gc`: pause what has been idle and delete what was due.
///
/// serbox ships no daemon of its own, so this is the one command that has to
/// run on a timer — `serbox gc` from cron once a minute is all a host needs.
pub async fn cmd_gc(args : Args) -> Unit {
  let dry = args.flag("dry-run")
  let now = now_secs()
  let boxes = all_boxes()
  let actions : Array[@json.Json] = []
  for config in boxes {
    if config.delete_at > 0L && now >= config.delete_at {
      if !dry {
        unpublish_box_ports(config.name) catch {
          _ => ()
        }
        let removed = remove_container(config.name)
        if removed.code == 0 {
          delete_box_config(config.name)
        }
      }
      actions.push(
        @json.Json::object(
          Map([
            ("box", @json.Json::string(config.name)),
            ("action", @json.Json::string("delete")),
          ]),
        ),
      )
      continue
    }
    if config.auto_suspend_secs <= 0L {
      continue
    }
    if container_state(config.name) != "running" {
      continue
    }
    if now - config.last_used_at < config.auto_suspend_secs {
      continue
    }
    if !dry {
      let paused = pause_container(config.name)
      if paused.code != 0 {
        continue
      }
      config.paused_by = "auto"
      save_box(config) catch {
        _ => ()
      }
    }
    actions.push(
      @json.Json::object(
        Map([
          ("box", @json.Json::string(config.name)),
          ("action", @json.Json::string("auto-pause")),
        ]),
      ),
    )
  }
  if json_only(@json.Json::array(actions)) {
    return
  }
  if actions.length() == 0 {
    line("nothing to do")
    return
  }
  for action in actions {
    line(action.stringify())
  }
}

///|
/// `serbox run`: create a box, run one command, delete the box.
pub async fn cmd_run(args : Args) -> Unit {
  let template = match args.value("template") {
    Some(t) => t
    None => default_template
  }
  let image = match template_image(template) {
    Some(image) => image
    None => raise usage_error("unknown template '\{template}'")
  }
  let name = match args.value("name") {
    Some(name) => name
    None => generate_box_name("run-")
  }
  let env : Map[String, String] = Map([])
  for text in args.all("env") {
    let (key, value) = parse_assignment(text, "env")
    env.set(key, value)
  }
  let config = create_box({
    name,
    template,
    image,
    env,
    meta: Map([]),
    ports: [],
    secrets: [],
    auto_suspend_secs: 0L,
    delete_at: 0L,
  })
  let keep = args.flag("keep")
  let mut code = 1
  let mut failure : String? = None
  match args.value("push") {
    Some(dir) =>
      push_path(config.name, dir, Some(box_home), false) catch {
        CliError::Failed(_, message) => failure = Some(message)
        error => failure = Some(error.to_string())
      }
    None => ()
  }
  if failure is None {
    let argv = command_argv(args)
    if argv.length() == 0 {
      failure = Some("run needs a command: serbox run -- CMD")
    } else {
      match args.value("cwd") {
        Some(_) => ()
        None => ()
      }
      code = exec_box_batch(
        config.name,
        argv,
        args.value("cwd"),
        env,
        None,
        shell=config.shell,
      )
    }
  }
  let failed_to_start = failure is Some(_)
  if !keep || failed_to_start {
    let _ = remove_container(config.name)
    delete_box_config(config.name)
  } else {
    eline("serbox: kept box \{config.name}")
  }
  match failure {
    Some(message) => raise CliError::Failed(125, message)
    None => serbox_exit(code)
  }
}

///|
/// The command a command line asked for: everything after `--`, or the
/// positionals after the ones the command consumed.
pub fn command_argv(args : Args) -> Array[String] {
  let argv : Array[String] = []
  for arg in args.rest {
    argv.push(arg)
  }
  argv
}
