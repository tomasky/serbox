///|
/// Published ports.
///
/// Docker cannot add a published port to a running container, and recreating a
/// box to add one would throw away its running programs. Instead `serbox`
/// keeps a small forwarder of its own: a detached process listening on the
/// host port and relaying to the container's address on the Docker bridge.
/// `port unpublish` stops it. Ports given at `create --publish` time are plain
/// Docker mappings and are listed here too.

///|
/// Whether a port is free to bind on this host.
pub async fn port_free(port : Int32) -> Bool {
  let addr = @socket.Addr::parse("0.0.0.0:\{port}") catch { _ => return false }
  // reuse_addr mirrors what the forwarder does, so a port that can be bound
  // after a restart is not reported as busy because of TIME_WAIT.
  let server = @socket.TcpServer(addr, reuse_addr=true) catch {
    _ => return false
  }
  server.close()
  true
}

///|
/// Pick a host port: the requested one when it is free, otherwise the first
/// free port at or above 10000.
pub async fn allocate_host_port(preferred : Int32) -> Int32 {
  if port_free(preferred) {
    return preferred
  }
  for candidate in 10000..<20000 {
    if port_free(candidate) {
      return candidate
    }
  }
  raise CliError::Failed(1, "no free host port")
}

///|
/// Relay bytes one way until either side closes.
async fn relay(source : @socket.Tcp, target : @socket.Tcp) -> Unit {
  while true {
    let chunk = source.read_some(max_len=65536) catch { _ => break }
    match chunk {
      Some(data) =>
        if data.length() > 0 {
          target.write(data) catch {
            _ => break
          }
        }
      None => break
    }
  }
}

///|
/// RFD 6455-free TCP relay: accept on `host_port`, connect to the container's
/// address, splice both directions.
pub async fn run_forwarder(
  box : String,
  host_port : Int32,
  container_port : Int32,
  bind : String,
) -> Unit {
  let ip = match container_ip(box) {
    Some(ip) => ip
    None =>
      raise CliError::Failed(
        1,
        "container '\{container_name(box)}' has no address",
      )
  }
  let addr = @socket.Addr::parse("\{bind}:\{host_port}")
  let server = @socket.TcpServer(addr, reuse_addr=true)
  server.run_forever(async fn(client, _peer) {
    let upstream = @socket.Tcp::connect_to_host(ip, port=container_port) catch {
      _ => {
        client.close()
        return
      }
    }
    @async.with_task_group(fn(group) {
      group.spawn_bg(async fn() {
        relay(client, upstream)
        upstream.close()
      })
      group.spawn_bg(async fn() {
        relay(upstream, client)
        client.close()
      })
    })
  })
}

///|
/// The executable to re-launch for a forwarder: `/proc/self/exe`, so the npm
/// launcher's downloaded binary is used rather than whatever is on `PATH`.
pub async fn self_exe() -> String {
  let path = @fs.realpath("/proc/self/exe") catch { _ => "serbox" }
  // An upgraded binary may have been replaced on disk; the running inode is
  // still executable through /proc/self/exe.
  let exists = @fs.exists(path) catch { _ => false }
  if exists {
    path
  } else {
    "/proc/self/exe"
  }
}

///|
async fn process_alive(pid : Int32) -> Bool {
  @fs.exists("/proc/\{pid}") catch {
    _ => false
  }
}

///|
/// Start the detached forwarder and record it.
pub async fn publish_port(
  config : BoxConfig,
  container_port : Int32,
  host_port : Int32,
  bind : String,
) -> PortForward {
  if container_state(config.name) != "running" {
    raise CliError::Failed(1, "box '\{config.name}' is not running")
  }
  if load_port_forward(config.name, container_port) is Some(existing) {
    raise CliError::Failed(
      1,
      "port \{container_port} is already published on \{existing.host}",
    )
  }
  if !(container_ip(config.name) is Some(_)) {
    raise CliError::Failed(1, "container '\{config.name}' has no address yet")
  }
  let host = allocate_host_port(host_port)
  let exe = self_exe()
  let log_path = path_join(
    serbox_home(),
    "port-\{config.name}-\{container_port}.log",
  )
  ensure_dir(serbox_home()) catch {
    _ => ()
  }
  let log = @process.redirect_to_file(
    log_path,
    append=true,
    create_mode=@fs.OpenOrCreate,
  ) catch {
    _ => raise CliError::Failed(1, "could not open \{log_path}")
  }
  let pid = @process.spawn_orphan(
    exe,
    ["__forward", config.name, "\{host}", "\{container_port}", bind],
    stdout=log,
    stderr=log,
  ) catch {
    _ => raise CliError::Failed(1, "could not start the port forwarder")
  }
  let forward : PortForward = {
    box: config.name,
    container: container_port,
    host,
    pid,
    created_at: now_secs(),
  }
  save_port_forward(forward) catch {
    _ => {
      let _ = @process.run("kill", ["-TERM", "\{pid}"]) catch { _ => 0 }
      raise CliError::Failed(1, "could not record the published port")
    }
  }
  // Give the listener a moment to bind so `port ls` and a curl right after
  // `publish` do not race it. A forwarder that dies (address in use, bad
  // container address) must fail the publish, not leave a dead record.
  let mut ready = false
  for _ in 0..<20 {
    @async.sleep(50)
    if !process_alive(pid) {
      break
    }
    if !port_free(host) {
      ready = true
      break
    }
  }
  if !ready {
    let _ = @process.run("kill", ["-TERM", "\{pid}"]) catch { _ => 0 }
    @fs.remove(
      port_record_path(config.name, container_port),
      allow_missing=true,
    ) catch {
      _ => ()
    }
    raise CliError::Failed(
      1,
      "the port forwarder for \{host} did not start; see \{log_path}",
    )
  }
  forward
}

///|
/// Stop a published port.
pub async fn unpublish_port(box : String, container_port : Int32) -> Unit {
  let forward = match load_port_forward(box, container_port) {
    Some(forward) => forward
    None => raise CliError::Failed(4, "port \{container_port} is not published")
  }
  await_forwarder_stop(forward.pid)
  @fs.remove(port_record_path(box, container_port), allow_missing=true) catch {
    _ => ()
  }
}

///|
/// Stop every forwarder a box owns. `rm` and `gc` use this so a removed box
/// cannot leave a listener behind; a box with no published ports is a no-op.
pub async fn unpublish_box_ports(box : String) -> Unit {
  for forward in all_port_forwards() {
    if forward.box == box {
      await_forwarder_stop(forward.pid)
      @fs.remove(port_record_path(box, forward.container), allow_missing=true) catch {
        _ => ()
      }
    }
  }
}

///|
/// Stop a forwarder: SIGTERM, then SIGKILL if it is still there after a second.
async fn await_forwarder_stop(pid : Int32) -> Unit {
  if !process_alive(pid) {
    return
  }
  let _ = @process.run("kill", ["-TERM", "\{pid}"]) catch { _ => 0 }
  let mut waited = 0
  while process_alive(pid) && waited < 20 {
    @async.sleep(50)
    waited = waited + 1
  }
  if process_alive(pid) {
    let _ = @process.run("kill", ["-KILL", "\{pid}"]) catch { _ => 0 }
  }
}

///|
/// `serbox port publish|ls|unpublish|setup`
pub async fn cmd_port(args : Args) -> Unit {
  let sub = args.arg(0, "port subcommand (publish|ls|unpublish)")
  match sub {
    "publish" => {
      let config = load_box_or_fail(args.arg(1, "box name"))
      require_usable(config, true)
      if runtime_rootless() {
        raise CliError::Failed(
          1,
          "rootless Podman cannot add a port to a running box; create it with " +
          "`serbox create --publish PORT` or run Podman as root",
        )
      }
      let container_port = parse_port(args.arg(2, "port"))
      let host_port = match args.value("host") {
        Some(text) => parse_port(text)
        None => container_port
      }
      if args.value("host") is Some(_) && !port_free(host_port) {
        raise CliError::Failed(
          1,
          "host port \{host_port} is already in use; pick another with --host",
        )
      }
      let bind = if args.flag("private") { "127.0.0.1" } else { "0.0.0.0" }
      let forward = publish_port(config, container_port, host_port, bind)
      if json_only(@json.to_json(forward)) {
        return
      }
      line(
        "published \{config.name}:\{container_port} on http://\{host_name()}:\{forward.host}/",
      )
    }
    "ls" | "list" => {
      let forwards = all_port_forwards()
      let only = args.arg_opt(1)
      let rows : Array[Array[String]] = []
      let json_rows : Array[@json.Json] = []
      for forward in forwards {
        if only is Some(name) && name != forward.box {
          continue
        }
        let alive = if process_alive(forward.pid) { "live" } else { "dead" }
        rows.push([
          forward.box,
          "\{forward.host}",
          "\{forward.container}",
          alive,
          forward_url(forward),
        ])
        json_rows.push(@json.to_json(forward))
      }
      if json_only(@json.Json::array(json_rows)) {
        return
      }
      if rows.length() == 0 {
        line("no published ports")
        return
      }
      out(render_table(["BOX", "HOST PORT", "BOX PORT", "STATE", "URL"], rows))
    }
    "unpublish" => {
      let config = load_box_or_fail(args.arg(1, "box name"))
      let port = parse_port(args.arg(2, "port"))
      unpublish_port(config.name, port)
      if json_only(@json.Json::boolean(true)) {
        return
      }
      line("unpublished \{config.name}:\{port}")
    }
    _ => raise usage_error("unknown port subcommand '\{sub}'")
  }
}

///|
/// The host a published URL points at: `SERBOX_HOST`, else the machine's own
/// hostname.
pub fn host_name() -> String {
  match @env.get_env_var("SERBOX_HOST") {
    Some(host) if host.length() > 0 => host
    _ =>
      match @env.get_env_var("HOSTNAME") {
        Some(host) if host.length() > 0 => host
        _ => "localhost"
      }
  }
}

///|
fn forward_url(forward : PortForward) -> String {
  "http://\{host_name()}:\{forward.host}/"
}
