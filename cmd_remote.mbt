/// Remote servers: `serbox serve` runs a small daemon on a server, and `-H`
/// drives it over an ssh tunnel.
///
/// The wire protocol is deliberately boring: newline-delimited JSON over TCP,
/// authenticated with a token the daemon owns, and every byte of command
/// output travels as hex. A request is one line `{"argv":[…],"stdin":bool}`;
/// the daemon spawns `serbox` with that argv and streams `{"out"}`/`{"err"}`
/// frames back, ending with `{"exit":code}`. Nothing is parsed twice, so a
/// remote command behaves exactly like the same command run locally.

///|
pub const DEFAULT_SERVE_PORT : Int32 = 7373

///|
pub fn serve_token_path() -> String {
  path_join(serbox_home(), "serve-token")
}

///|
pub fn serve_log_path() -> String {
  path_join(serbox_home(), "serve.log")
}

///|
/// The daemon's token. `create=true` generates and stores one on first use;
/// the file is `0600` because the token is as powerful as an ssh key.
pub async fn serve_token(create : Bool) -> String {
  match read_text(serve_token_path()) {
    Some(text) => if text.trim().length() > 0 { return text.trim().to_owned() }
    None => ()
  }
  if !create {
    raise CliError::Failed(4, "this server has no serbox token yet")
  }
  let token = match @env.rand(16) {
    Some(bytes) => hex_encode(bytes)
    None => raise CliError::Failed(1, "cannot read random bytes for the token")
  }
  ensure_dir(serbox_home())
  write_secret(serve_token_path(), token)
  token
}

///|
/// Whether something accepts connections on `127.0.0.1:port`.
pub async fn local_port_open(port : Int32) -> Bool {
  let addr = @socket.Addr::parse("127.0.0.1:\{port}") catch {
    _ => return false
  }
  let conn = @socket.Tcp::connect(addr) catch { _ => return false }
  conn.close()
  true
}

///|
async fn wait_for_port(port : Int32, checks : Int32) -> Bool {
  let mut i = 0
  while i < checks {
    if local_port_open(port) {
      return true
    }
    @async.sleep(100)
    i = i + 1
  }
  false
}

///|
/// JSON for `host add` and `serve --ensure`: where the daemon listens and the
/// token to use.
fn serve_info(port : Int32, token : String) -> @json.Json {
  @json.Json::object(
    Map([
      ("port", @json.Json::number(port.to_double())),
      ("token", @json.Json::string(token)),
      ("version", @json.Json::string(serbox_version)),
    ]),
  )
}

///|
/// One request handler: authenticate, read the argv, run it, stream it back.
async fn serve_connection(conn : @socket.Tcp) -> Unit {
  let token = serve_token(false) catch { _ => return }
  let auth = conn.read_until("\n") catch { _ => return }
  let auth_json = match auth {
    Some(text) => @json.parse(text) catch { _ => return }
    None => return
  }
  let presented = match auth_json {
    @json.Json::Object(fields) =>
      match fields.get("token") {
        Some(@json.Json::String(value)) => value
        _ => ""
      }
    _ => ""
  }
  if presented != token {
    let _ = conn.write(
      @json.Json::object(Map([("error", @json.Json::string("unauthorized"))])).stringify() +
      "\n",
    ) catch {
      _ => ()
    }
    conn.close()
    return
  }
  let request_line = conn.read_until("\n") catch { _ => return }
  let request = match request_line {
    Some(text) => @json.parse(text) catch { _ => return }
    None => return
  }
  let (argv, wants_stdin) = match request {
    @json.Json::Object(fields) => {
      let argv : Array[String] = []
      match fields.get("argv") {
        Some(@json.Json::Array(items)) =>
          for item in items {
            match item {
              @json.Json::String(text) => argv.push(text)
              _ => ()
            }
          }
        _ => ()
      }
      let wants_stdin = match fields.get("stdin") {
        Some(@json.Json::True) => true
        _ => false
      }
      (argv, wants_stdin)
    }
    _ => (Array(capacity=0), false)
  }
  if argv.length() == 0 {
    let _ = conn.write(
      @json.Json::object(Map([("error", @json.Json::string("empty argv"))])).stringify() +
      "\n",
    ) catch {
      _ => ()
    }
    conn.close()
    return
  }

  let (child_in, child_in_w) = @process.write_to_process() catch { _ => return }
  let (out_r, out_w) = @process.read_from_process() catch { _ => return }
  let (err_r, err_w) = @process.read_from_process() catch { _ => return }
  let write_lock = @async.Mutex()
  // A daemon started before an upgrade runs a deleted file. The inode is still
  // executable through /proc/self/exe, so children keep working until the
  // daemon is restarted.
  let installed = self_exe()
  let installed_exists = @fs.exists(installed) catch { _ => false }
  let exe = if installed_exists { installed } else { "/proc/self/exe" }

  let exit_box : ExitBox = { code: 1, }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      let process = @process.spawn(
        group,
        exe,
        argv,
        stdin=child_in,
        stdout=out_w,
        stderr=err_w,
      ) catch {
        _ => {
          exit_box.code = 127
          return
        }
      }
      exit_box.code = process.wait()
      out_w.close()
      err_w.close()
    })
    group.spawn_bg(async fn() {
      pump_child_to_client(conn, out_r, "out", write_lock)
    })
    group.spawn_bg(async fn() {
      pump_child_to_client(conn, err_r, "err", write_lock)
    })
    pump_client_to_child(conn, child_in_w, wants_stdin)
  })
  send_frame(
    conn,
    write_lock,
    @json.Json::object(
      Map([("exit", @json.Json::number(exit_box.code.to_double()))]),
    ),
  )
  conn.close()
}

///|
/// Mutable exit status shared between the task that waits for the child and
/// the code that reports it. MoonBit closures cannot close over a `mut` local.
priv struct ExitBox {
  mut code : Int32
}

///|
async fn send_frame(
  conn : @socket.Tcp,
  lock : @async.Mutex,
  value : @json.Json,
) -> Unit {
  lock.acquire()
  let line = value.stringify() + "\n"
  let _ = conn.write(line) catch { _ => () }
  lock.release()
}

///|
/// Read the child's output and forward it as hex frames until EOF.
async fn pump_child_to_client(
  conn : @socket.Tcp,
  reader : @process.ReadFromProcess,
  field : String,
  lock : @async.Mutex,
) -> Unit {
  while true {
    let chunk = reader.read_some(max_len=16384) catch { _ => None }
    match chunk {
      None => return
      Some(bytes) =>
        if bytes.length() > 0 {
          send_frame(
            conn,
            lock,
            @json.Json::object(
              Map([(field, @json.Json::string(hex_encode(bytes)))]),
            ),
          )
        }
    }
  }
}

///|
/// Forward `{"in"}` frames into the child's stdin, and close it on `{"eof"}`.
/// A client that does not want stdin sends `{"eof":true}` immediately, so a
/// command never waits for input it will not get.
async fn pump_client_to_child(
  conn : @socket.Tcp,
  child_in : @process.WriteToProcess,
  wants_stdin : Bool,
) -> Unit {
  if !wants_stdin {
    child_in.close()
    return
  }
  while true {
    let line = conn.read_until("\n") catch { _ => None }
    let frame = match line {
      None => break
      Some(text) => @json.parse(text) catch { _ => break }
    }
    match frame {
      @json.Json::Object(fields) => {
        if fields.contains("eof") {
          break
        }
        match fields.get("in") {
          Some(@json.Json::String(text)) =>
            match hex_decode(text) {
              Some(bytes) =>
                if bytes.length() > 0 {
                  child_in.write(bytes) catch {
                    _ => break
                  }
                }
              None => ()
            }
          _ => ()
        }
      }
      _ => ()
    }
  }
  child_in.close()
}

///|
/// Check that the daemon on `port` accepts this token, before trusting an
/// existing listener. Two `SERBOX_HOME`s on one port would otherwise silently
/// talk past each other.
async fn serve_auth_ok(port : Int32, token : String) -> Bool {
  let addr = @socket.Addr::parse("127.0.0.1:\{port}")
  let conn = @socket.Tcp::connect(addr)
  let auth = @json.Json::object(Map([("token", @json.Json::string(token))]))
  conn.write(auth.stringify() + "\n")
  conn.write("{\"argv\":[\"version\",\"--json\"],\"stdin\":false}\n")
  conn.write("{\"eof\":true}\n")
  let mut ok = false
  while true {
    let line = conn.read_until("\n") catch { _ => break }
    let text = match line {
      None => break
      Some(text) => text
    }
    if text.contains("unauthorized") {
      ok = false
      break
    }
    if text.contains("\"exit\"") {
      ok = !text.contains("unauthorized")
      break
    }
  }
  conn.close()
  ok
}

///|
/// The daemon loop. Binds loopback by default: the client reaches it through
/// an ssh tunnel, so there is no reason to expose the port to the network.
pub async fn serve_loop(bind : String, port : Int32) -> Unit {
  let addr = @socket.Addr::parse("\{bind}:\{port}") catch {
    _ => raise CliError::Failed(2, "bad bind address '\{bind}:\{port}'")
  }
  let server = @socket.TcpServer(addr, reuse_addr=true)
  @signal.set_global_cancellation_signals([@signal.SIGTERM, @signal.SIGINT])
  server.run_forever(async fn(conn, _peer) {
    serve_connection(conn) catch {
      _ => ()
    }
  }) catch {
    _ => ()
  }
}

///|
/// `serbox serve [--port N] [--bind ADDR] [--ensure] [--daemon] [--print-token]`
pub async fn cmd_serve(args : Args) -> Unit {
  let port = match args.value("port") {
    Some(text) =>
      @string.parse_int(text) catch {
        _ => raise usage_error("bad --port '\{text}'")
      }
    None => DEFAULT_SERVE_PORT
  }
  let bind = match args.value("bind") {
    Some(text) => text
    None => "127.0.0.1"
  }
  if args.flag("rotate-token") {
    let bytes = match @env.rand(16) {
      Some(bytes) => bytes
      None => raise CliError::Failed(1, "cannot read random bytes")
    }
    let fresh = hex_encode(bytes)
    ensure_dir(serbox_home())
    write_secret(serve_token_path(), fresh)
    if json_only(serve_info(port, fresh)) {
      return
    }
    line(fresh)
    return
  }
  let token = serve_token(true)
  if args.flag("print-token") {
    line(token)
    return
  }
  if args.flag("restart") {
    let mut pid = read_serve_pid(port)
    if pid <= 0 && local_port_open(port) {
      pid = find_daemon_pid(port)
    }
    if pid_alive(pid) {
      let _ = @process.run("kill", ["-TERM", "\{pid}"]) catch { _ => 0 }
    }
    // Wait for the listener to go away so the new daemon can bind.
    let mut waited = 0
    while local_port_open(port) && waited < 50 {
      @async.sleep(100)
      waited = waited + 1
    }
    start_daemon(bind, port)
    if !wait_for_port(port, 100) {
      raise CliError::Failed(
        1,
        "the serbox daemon did not restart on \{bind}:\{port}; see \{serve_log_path()}",
      )
    }
    if json_only(serve_info(port, token)) {
      return
    }
    line("restarted the serbox daemon on \{bind}:\{port}")
    return
  }
  if args.flag("ensure") {
    if local_port_open(port) {
      let ok = serve_auth_ok(port, token) catch { _ => false }
      if !ok {
        raise CliError::Failed(
          1,
          "port \{bind}:\{port} is already used by a serbox daemon with another token; stop it or run `serbox serve --restart --port \{port}`",
        )
      }
    }
    if !local_port_open(port) {
      start_daemon(bind, port)
      if !wait_for_port(port, 100) {
        raise CliError::Failed(
          1,
          "the serbox daemon did not start on \{bind}:\{port}; see \{serve_log_path()}",
        )
      }
    }
    if json_only(serve_info(port, token)) {
      return
    }
    line("serving on \{bind}:\{port}")
    return
  }
  if args.flag("daemon") {
    write_serve_pid(port)
    serve_loop(bind, port)
    return
  }
  line("serbox daemon on \{bind}:\{port} (token in \{serve_token_path()})")
  serve_loop(bind, port)
}

///|
pub fn serve_pid_path(port : Int32) -> String {
  path_join(serbox_home(), "serve-\{port}.pid")
}

///|
async fn write_serve_pid(port : Int32) -> Unit {
  ensure_dir(serbox_home()) catch {
    _ => ()
  }
  write_text(serve_pid_path(port), serbox_getpid().to_string()) catch {
    _ => ()
  }
}

///|
async fn read_serve_pid(port : Int32) -> Int32 {
  match read_text(serve_pid_path(port)) {
    None => 0
    Some(text) => @string.parse_int(text.trim().to_owned()) catch { _ => 0 }
  }
}

///|
/// Find a daemon by scanning `/proc`, for daemons started before pid files
/// existed (or by an older build). Linux-only, like the rest of serbox.
async fn find_daemon_pid(port : Int32) -> Int32 {
  let want = "\{port}"
  for entry in list_dir("/proc") {
    let pid = @string.parse_int(entry) catch { _ => continue }
    let cmdline = match read_text("/proc/\{pid}/cmdline") {
      Some(text) => text
      None => continue
    }
    if cmdline.contains("serve") &&
      cmdline.contains("--daemon") &&
      cmdline.contains(want) {
      return pid
    }
  }
  0
}

///|
/// Start the daemon detached, with a log file, so `host add` can leave a
/// server running it without keeping an ssh session open.
async fn start_daemon(bind : String, port : Int32) -> Unit {
  let exe = self_exe()
  ensure_dir(serbox_home()) catch {
    _ => ()
  }
  let log = @process.redirect_to_file(
    serve_log_path(),
    append=true,
    create_mode=@fs.OpenOrCreate,
  ) catch {
    _ => return
  }
  // A daemon started from a deleted file (an upgrade) is replaced on restart.
  let exe_exists = @fs.exists(exe) catch { _ => false }
  let runnable = if exe_exists { exe } else { "/proc/self/exe" }
  let pid = @process.spawn_orphan(
    runnable,
    ["serve", "--daemon", "--port", "\{port}", "--bind", bind],
    stdout=log,
    stderr=log,
  ) catch {
    _ => 0
  }
  write_serve_pid(port)
  let _ = pid
}

///|
/// A finished command: status plus captured output.
priv struct Captured {
  code : Int32
  out : String
  err : String
}

///|
async fn capture_command(exe : String, argv : Array[String]) -> Captured {
  let (code, out, err) = @process.collect_output(exe, argv) catch {
    _ => return { code: 127, out: "", err: "\{exe} could not be started", }
  }
  let out_text = out.text() catch { _ => "" }
  let err_text = err.text() catch { _ => "" }
  { code, out: out_text, err: err_text, }
}

///|
/// Is `pid` still running? Used to decide whether a tunnel needs restarting.
async fn pid_alive(pid : Int32) -> Bool {
  if pid <= 0 {
    return false
  }
  @fs.exists("/proc/\{pid}") catch {
    _ => false
  }
}

///|
/// Pick a free loopback port for a tunnel. Binding port 0 and reading back the
/// assigned port avoids guessing and racing another process.
async fn free_local_port() -> Int32 {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
    _ => raise CliError::Failed(1, "could not find a free local port")
  }
  let port = server.addr.port()
  server.close()
  port
}

///|
/// The command that runs `argv` on the remote host's daemon. The binary path is
/// quoted because `host add` may find it outside PATH.
fn remote_command(host : HostRecord, argv : Array[String]) -> String {
  let bin = if host.remote_bin.trim().length() > 0 {
    shell_quote(host.remote_bin.trim().to_owned())
  } else {
    "serbox"
  }
  "\{bin} \{shell_join(argv)}"
}

///|
async fn ssh_capture(host : String, command : String) -> Captured {
  capture_command("ssh", ["-o", "BatchMode=yes", host, command])
}

///|
/// Start (or restart) the ssh tunnel that exposes the remote daemon on
/// `127.0.0.1:<local_port>`. The daemon itself only listens on the server's
/// loopback, so the tunnel is the only way in and no port is exposed publicly.
async fn start_tunnel(host : HostRecord) -> Unit {
  if host.target.trim().length() == 0 {
    raise CliError::Failed(
      4,
      "host '\{host.name}' has no ssh target; add it again with `serbox host add`",
    )
  }
  if pid_alive(host.tunnel_pid) {
    let _ = @process.run("kill", ["-TERM", "\{host.tunnel_pid}"]) catch {
      _ => 0
    }
  }
  let log_path = path_join(serbox_home(), "tunnel-\{host.name}.log")
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
  let forward = "127.0.0.1:\{host.local_port}:127.0.0.1:\{host.remote_port}"
  let argv = [
    "-N",
    "-o",
    "BatchMode=yes",
    "-o",
    "ExitOnForwardFailure=yes",
    "-o",
    "ServerAliveInterval=30",
    "-o",
    "StrictHostKeyChecking=accept-new",
    "-L",
    forward,
    host.target,
  ]
  let pid = @process.spawn_orphan("ssh", argv, stdout=log, stderr=log) catch {
    _ => raise CliError::Failed(1, "could not start ssh to \{host.target}")
  }
  if !wait_for_port(host.local_port, 100) {
    raise CliError::Failed(
      1,
      "ssh tunnel to \{host.target} did not come up; see \{log_path}",
    )
  }
  let updated : HostRecord = {
    name: host.name,
    target: host.target,
    remote_bin: host.remote_bin,
    remote_port: host.remote_port,
    local_port: host.local_port,
    token: host.token,
    tunnel_pid: pid,
    created_at: host.created_at,
  }
  upsert_host(updated)
}

///|
async fn ensure_tunnel(host : HostRecord) -> Unit {
  if local_port_open(host.local_port) {
    return
  }
  start_tunnel(host)
}

///|
/// Send one request to a host's daemon and stream the result. Returns the exit
/// code, so a remote `exec` exits exactly like a local one.
pub async fn remote_run(host_name : String, argv : Array[String]) -> Int32 {
  let host = match load_host(host_name) {
    Some(host) => host
    None =>
      raise CliError::Failed(
        4,
        "no such host '\{host_name}'; add it with `serbox host add \{host_name} user@server`",
      )
  }
  // A shell must have a terminal. The daemon has none, so interactive shells
  // go through ssh -t and the binary already installed on the server; that is
  // the same path instabox takes for `ssh`.
  if stdout_is_tty() && argv.length() > 0 && is_interactive_command(argv[0]) {
    return ssh_interactive(host, argv)
  }
  match remote_files(host, argv) {
    Some(code) => return code
    None => ()
  }
  remote_exec(host, argv)
}

///|
/// `push` and `pull` move files between *this* machine and a box. A daemon
/// cannot see the client's disk, so those two commands travel over ssh: the
/// file is scp'd to a temp path on the server, the remote command runs there,
/// and the temp path is removed.
async fn remote_files(host : HostRecord, argv : Array[String]) -> Int32? {
  let command = if argv.length() > 0 { argv[0] } else { "" }
  if command != "push" && command != "pull" {
    return None
  }
  if host.target.trim().length() == 0 {
    raise CliError::Failed(
      4,
      "host '\{host.name}' was added with --address, so push/pull cannot see its files; add it with ssh instead",
    )
  }
  let stamp = hex_encode(
    Bytes::from_array([(@env.now() % 1000000UL).to_int().to_byte()]),
  )
  if command == "push" {
    if argv.length() < 3 {
      return None
    }
    let source = argv[2]
    if !(@fs.exists(source) catch { _ => false }) {
      return None
    }
    let temp = "/tmp/serbox-push-\{stamp}"
    let uploaded = scp_to(host.target, source, temp)
    if uploaded.code != 0 {
      raise CliError::Failed(
        1,
        "scp to \{host.target} failed: \{uploaded.err.trim()}",
      )
    }
    let forwarded : Array[String] = []
    forwarded.push("push")
    forwarded.push(argv[1])
    forwarded.push(temp)
    for i in 3..<argv.length() {
      forwarded.push(argv[i])
    }
    let code = remote_exec(host, forwarded) catch {
      CliError::Failed(code, message) => {
        cleanup_remote(host.target, temp)
        raise CliError::Failed(code, message)
      }
      _ => {
        cleanup_remote(host.target, temp)
        raise CliError::Failed(1, "the remote push failed")
      }
    }
    cleanup_remote(host.target, temp)
    Some(code)
  } else {
    if argv.length() < 3 {
      return None
    }
    let remote_path = argv[2]
    let destination = if argv.length() >= 4 {
      argv[3]
    } else {
      path_basename(remote_path)
    }
    let temp = "/tmp/serbox-pull-\{stamp}"
    let forwarded = ["pull", argv[1], remote_path, temp]
    let code = remote_exec(host, forwarded)
    if code == 0 {
      let downloaded = scp_from(host.target, temp, destination)
      if downloaded.code != 0 {
        cleanup_remote(host.target, temp)
        raise CliError::Failed(
          1,
          "scp from \{host.target} failed: \{downloaded.err.trim()}",
        )
      }
    }
    cleanup_remote(host.target, temp)
    Some(code)
  }
}

///|
async fn scp_to(
  target : String,
  source : String,
  destination : String,
) -> Captured {
  capture_command("scp", [
    "-q",
    "-r",
    "-o",
    "BatchMode=yes",
    "-o",
    "StrictHostKeyChecking=accept-new",
    source,
    "\{target}:\{destination}",
  ])
}

///|
async fn scp_from(
  target : String,
  source : String,
  destination : String,
) -> Captured {
  capture_command("scp", [
    "-q",
    "-r",
    "-o",
    "BatchMode=yes",
    "-o",
    "StrictHostKeyChecking=accept-new",
    "\{target}:\{source}",
    destination,
  ])
}

///|
async fn cleanup_remote(target : String, path : String) -> Unit {
  let _ = @process.run("ssh", [
    "-o",
    "BatchMode=yes",
    target,
    "rm -rf \{shell_quote(path)}",
  ]) catch {
    _ => 0
  }
}

///|
/// The transport itself: open the tunnel, authenticate, run one argv and
/// stream its output back.
async fn remote_exec(host : HostRecord, argv : Array[String]) -> Int32 {
  ensure_tunnel(host)
  let addr = @socket.Addr::parse("127.0.0.1:\{host.local_port}") catch {
    _ => raise CliError::Failed(1, "bad tunnel address for '\{host.name}'")
  }
  let conn = @socket.Tcp::connect(addr) catch {
    _ => raise CliError::Failed(1, "cannot reach the tunnel for '\{host.name}'")
  }
  let wants_stdin = argv_has(argv, "--stdin") ||
    (argv.length() > 0 && argv[0] == "ssh")
  let auth = @json.Json::object(
    Map([("token", @json.Json::string(host.token))]),
  )
  conn.write(auth.stringify() + "\n") catch {
    _ => raise CliError::Failed(1, "the remote daemon closed the connection")
  }
  let request = @json.Json::object(
    Map([
      ("argv", @json.Json::array(argv.map(fn(arg) { @json.Json::string(arg) }))),
      ("stdin", @json.Json::boolean(wants_stdin)),
    ]),
  )
  conn.write(request.stringify() + "\n") catch {
    _ => raise CliError::Failed(1, "the remote daemon closed the connection")
  }
  let code : ExitBox = { code: 1, }
  @async.with_task_group(async fn(group) {
    if wants_stdin {
      group.spawn_bg(async fn() { pump_stdin_to_remote(conn) })
    } else {
      conn.write("{\"eof\":true}\n") catch {
        _ => ()
      }
    }
    read_remote_frames(conn, code)
  })
  conn.close()
  code.code
}

///|
fn is_interactive_command(command : String) -> Bool {
  command == "ssh" || command == "shell" || command == "mosh"
}

///|
fn argv_has(argv : Array[String], flag : String) -> Bool {
  for arg in argv {
    if arg == flag {
      return true
    }
  }
  false
}

///|
/// Local stdin → `{"in"}` frames, then `{"eof"}`. A closed stdin is normal
/// (scripts run without one), so it is not an error.
async fn pump_stdin_to_remote(conn : @socket.Tcp) -> Unit {
  while true {
    let chunk = @stdio.stdin.read_some(max_len=8192) catch { _ => None }
    match chunk {
      None => break
      Some(bytes) =>
        if bytes.length() > 0 {
          let frame = @json.Json::object(
            Map([("in", @json.Json::string(hex_encode(bytes)))]),
          )
          conn.write(frame.stringify() + "\n") catch {
            _ => break
          }
        }
    }
  }
  conn.write("{\"eof\":true}\n") catch {
    _ => ()
  }
}

///|
/// Read `out`/`err`/`exit` frames until the remote command ends.
async fn read_remote_frames(conn : @socket.Tcp, code : ExitBox) -> Unit {
  while true {
    let line = conn.read_until("\n") catch { _ => return }
    let text = match line {
      None => return
      Some(text) => text
    }
    let frame = @json.parse(text) catch { _ => return }
    match frame {
      @json.Json::Object(fields) => {
        match fields.get("out") {
          Some(@json.Json::String(hex)) =>
            match hex_decode(hex) {
              Some(bytes) =>
                if bytes.length() > 0 {
                  @stdio.stdout.write(bytes) catch {
                    _ => ()
                  }
                }
              None => ()
            }
          _ => ()
        }
        match fields.get("err") {
          Some(@json.Json::String(hex)) =>
            match hex_decode(hex) {
              Some(bytes) =>
                if bytes.length() > 0 {
                  @stdio.stderr.write(bytes) catch {
                    _ => ()
                  }
                }
              None => ()
            }
          _ => ()
        }
        match fields.get("exit") {
          Some(@json.Json::Number(value, ..)) => {
            code.code = value.to_int()
            return
          }
          _ => ()
        }
        match fields.get("error") {
          Some(@json.Json::String(message)) => {
            eline("serbox: remote error: \{message}")
            code.code = 1
            return
          }
          _ => ()
        }
      }
      _ => ()
    }
  }
}

///|
/// An interactive shell on the server: `ssh -t target 'serbox ssh box'`. This
/// is the only command that does not go through the daemon, because a terminal
/// has to be allocated by ssh itself.
async fn ssh_interactive(host : HostRecord, argv : Array[String]) -> Int32 {
  let command = remote_command(host, argv)
  @process.run("ssh", [
    "-t",
    "-o",
    "ServerAliveInterval=30",
    "-o",
    "StrictHostKeyChecking=accept-new",
    host.target,
    command,
  ])
}

///|
/// `serbox host add NAME USER@HOST [--port N] [--install]`
pub async fn cmd_host_add(args : Args) -> Unit {
  let name = args.arg(0, "host name")
  if !valid_box_name(name) {
    raise usage_error(
      "bad host name '\{name}' (lowercase letters, digits, _ and -)",
    )
  }
  match load_host(name) {
    Some(existing) =>
      if !args.flag("force") {
        raise CliError::Failed(
          1,
          "host '\{name}' already exists; pass --force to replace it",
        )
      } else if pid_alive(existing.tunnel_pid) {
        let _ = @process.run("kill", ["-TERM", "\{existing.tunnel_pid}"]) catch {
          _ => 0
        }
      }
    None => ()
  }
  let record = match args.value("address") {
    // A pre-made tunnel (or a local daemon) is useful in tests and in setups
    // where ssh is handled by something else.
    Some(address) => {
      let (host_part, port) = parse_address(address)
      if host_part != "127.0.0.1" && host_part != "localhost" {
        raise usage_error("--address must be 127.0.0.1:PORT")
      }
      let token = match args.value("token") {
        Some(token) => token
        None => raise usage_error("--address needs --token")
      }
      let host : HostRecord = {
        name,
        target: "",
        remote_bin: "",
        remote_port: port,
        local_port: port,
        token,
        tunnel_pid: 0,
        created_at: now_secs(),
      }
      host
    }
    None => {
      let target = args.arg(1, "user@host")
      let remote_port = match args.value("port") {
        Some(text) =>
          @string.parse_int(text) catch {
            _ => raise usage_error("bad --port '\{text}'")
          }
        None => DEFAULT_SERVE_PORT
      }
      let found = ssh_capture(target, "command -v serbox || true")
      let bin = found.out.trim().to_owned()
      if bin.length() == 0 {
        if !args.flag("install") {
          raise CliError::Failed(
            4,
            "serbox is not installed on \{target}; rerun with --install, or install it there first",
          )
        }
        line("installing serbox on \{target}")
        let installed = ssh_capture(
          target, "curl -LsSf https://raw.githubusercontent.com/kupas/serbox/main/install.sh | bash",
        )
        if installed.code != 0 {
          raise CliError::Failed(1, "install failed: \{installed.err.trim()}")
        }
        let again = ssh_capture(target, "command -v serbox || true")
        if again.out.trim().length() == 0 {
          raise CliError::Failed(
            1, "serbox was installed but is not on PATH for non-interactive ssh",
          )
        }
      }
      let bin = ssh_capture(target, "command -v serbox || true").out
        .trim()
        .to_owned()
      let started = ssh_capture(
        target,
        "\{shell_quote(bin)} serve --ensure --json --port \{remote_port}",
      )
      if started.code != 0 {
        raise CliError::Failed(
          1,
          "could not start the daemon on \{target}: \{started.err.trim()}",
        )
      }
      let info = @json.parse(started.out.trim().to_owned()) catch {
        _ =>
          raise CliError::Failed(
            1,
            "unexpected answer from \{target}: \{started.out.trim()}",
          )
      }
      let (port, token, version) = match info {
        @json.Json::Object(fields) => {
          let port = match fields.get("port") {
            Some(@json.Json::Number(value, ..)) => value.to_int()
            _ => remote_port
          }
          let token = match fields.get("token") {
            Some(@json.Json::String(value)) => value
            _ => ""
          }
          let version = match fields.get("version") {
            Some(@json.Json::String(value)) => value
            _ => ""
          }
          (port, token, version)
        }
        _ => (remote_port, "", "")
      }
      if token.length() == 0 {
        raise CliError::Failed(1, "the daemon on \{target} returned no token")
      }
      if version != serbox_version {
        raise CliError::Failed(
          1,
          "serbox on \{target} is \{version}, this CLI is \{serbox_version}; update the server with `serbox update`",
        )
      }
      let host : HostRecord = {
        name,
        target,
        remote_bin: bin,
        remote_port: port,
        local_port: free_local_port(),
        token,
        tunnel_pid: 0,
        created_at: now_secs(),
      }
      host
    }
  }
  upsert_host(record)
  // Bring the tunnel up now, so `host add` either succeeds fully or fails with
  // a message while the user is still looking.
  if record.target.trim().length() > 0 {
    start_tunnel(record)
  }
  let saved = match load_host(name) {
    Some(host) => host
    None => record
  }
  if json_only(@json.to_json(saved)) {
    return
  }
  let addr = "127.0.0.1:\{saved.local_port}"
  if saved.target.trim().length() > 0 {
    line("host \{name} added (\{saved.target})")
    line("  daemon   \{addr} -> \{saved.target}:127.0.0.1:\{saved.remote_port}")
  } else {
    line("host \{name} added (existing daemon at \{addr})")
  }
  line("next: serbox -H \{name} ls")
}

///|
fn parse_address(text : String) -> (String, Int32) raise {
  let parts : Array[String] = []
  for part in text.split(":") {
    parts.push(part.to_owned())
  }
  if parts.length() != 2 {
    raise usage_error("--address expects HOST:PORT")
  }
  let port = @string.parse_int(parts[1]) catch {
    _ => raise usage_error("bad port in --address '\{text}'")
  }
  (parts[0], port)
}

///|
/// `serbox host ls`
pub async fn cmd_host_ls(_args : Args) -> Unit {
  let hosts = all_hosts()
  let rows : Array[Array[String]] = []
  let items : Array[@json.Json] = []
  for host in hosts {
    let state = if local_port_open(host.local_port) {
      "connected"
    } else if host.target.trim().length() > 0 {
      "down"
    } else {
      "external"
    }
    let current = current_host()
    let marker = if current.length() > 0 && current == host.name {
      "*"
    } else {
      " "
    }
    rows.push([
      "\{marker}\{host.name}",
      if host.target.trim().length() > 0 {
        host.target
      } else {
        "-"
      },
      state,
      "127.0.0.1:\{host.local_port}",
    ])
    items.push(
      @json.Json::object(
        Map([
          ("name", @json.Json::string(host.name)),
          ("target", @json.Json::string(host.target)),
          ("state", @json.Json::string(state)),
          ("port", @json.Json::number(host.local_port.to_double())),
        ]),
      ),
    )
  }
  if json_only(@json.Json::array(items)) {
    return
  }
  if hosts.length() == 0 {
    line("no remote hosts; add one with `serbox host add prod user@server`")
    return
  }
  out(render_table(["NAME", "TARGET", "STATE", "TUNNEL"], rows))
}

///|
/// `serbox host rm NAME`
pub async fn cmd_host_rm(args : Args) -> Unit {
  let name = args.arg(0, "host name")
  let host = match load_host(name) {
    Some(host) => host
    None => raise CliError::Failed(4, "no such host '\{name}'")
  }
  if pid_alive(host.tunnel_pid) {
    let _ = @process.run("kill", ["-TERM", "\{host.tunnel_pid}"]) catch {
      _ => 0
    }
  }
  let was_current = current_host() == name
  let _ = delete_host(name)
  if was_current {
    set_current_host("local")
  }
  if json_only(@json.Json::object(Map([("removed", @json.Json::string(name))]))) {
    return
  }
  line("removed host \{name}")
}

///|
pub fn current_host_path() -> String {
  path_join(serbox_home(), "current-host")
}

///|
/// The host `-H` falls back to. `""` means local: commands run on this
/// machine, exactly as before a host was added.
pub async fn current_host() -> String {
  match read_text(current_host_path()) {
    None => ""
    Some(text) =>
      if text.trim() == "local" {
        ""
      } else {
        text.trim().to_owned()
      }
  }
}

///|
async fn set_current_host(name : String) -> Unit {
  ensure_dir(serbox_home())
  write_text(current_host_path(), if name == "local" { "local" } else { name })
}

///|
/// `serbox host use NAME|local`
pub async fn cmd_host_use(args : Args) -> Unit {
  let name = args.arg(0, "host name or 'local'")
  if name != "local" && load_host(name) is None {
    raise CliError::Failed(4, "no such host '\{name}'")
  }
  set_current_host(name)
  if json_only(@json.Json::object(Map([("current", @json.Json::string(name))]))) {
    return
  }
  if name == "local" {
    line("now using this machine")
  } else {
    line("now using host \{name}; `serbox host use local` goes back")
  }
}

///|
/// `serbox host current`
pub async fn cmd_host_current(_args : Args) -> Unit {
  let name = current_host()
  let label = if name.length() == 0 { "local" } else { name }
  if json_only(
      @json.Json::object(
        Map([
          ("current", @json.Json::string(label)),
          ("local", @json.Json::boolean(name.length() == 0)),
        ]),
      ),
    ) {
    return
  }
  line(label)
}
