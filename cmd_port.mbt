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
  let server = @socket.TcpServer(addr) catch { _ => return false }
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
) -> Unit {
  let ip = match container_ip(box) {
    Some(ip) => ip
    None =>
      raise CliError::Failed(
        1,
        "container '\{container_name(box)}' has no address",
      )
  }
  let addr = @socket.Addr::parse("0.0.0.0:\{host_port}")
  let server = @socket.TcpServer(addr)
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
  @fs.realpath("/proc/self/exe") catch {
    _ => "serbox"
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
    ["__forward", config.name, "\{host}", "\{container_port}"],
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
    _ => ()
  }
  // Give the listener a moment to bind so `port ls` and a curl right after
  // `publish` do not race it.
  for _ in 0..<20 {
    @async.sleep(50)
    if !port_free(host) {
      break
    }
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
  if process_alive(forward.pid) {
    ignore(@process.run("kill", ["-TERM", "\{forward.pid}"]) catch { _ => 0 })
  }
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
      if process_alive(forward.pid) {
        ignore(
          @process.run("kill", ["-TERM", "\{forward.pid}"]) catch {
            _ => 0
          },
        )
      }
      @fs.remove(port_record_path(box, forward.container), allow_missing=true) catch {
        _ => ()
      }
    }
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
      let container_port = parse_port(args.arg(2, "port"))
      let host_port = match args.value("host") {
        Some(text) => parse_port(text)
        None => container_port
      }
      let forward = publish_port(config, container_port, host_port)
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
