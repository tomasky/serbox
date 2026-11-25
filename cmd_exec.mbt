///|
/// Running things in a box: `exec` (foreground, streamed or detached), the
/// `jobs` that `exec --background` leaves behind, `ssh`, `ps`, `history`,
/// `output`, `disk`, `metrics` and `logs`.

///|
/// The argv to hand `docker exec` for a command line: one argument is a shell
/// string run through `bash -lc` (instabox's rule, and the only form that
/// supports pipes and redirection), several are an exact argv with no shell.
pub fn exec_argv(
  command : Array[String],
  timeout_secs : Int64?,
  shell~ : String = "bash",
) -> Array[String] {
  let argv : Array[String] = []
  match timeout_secs {
    Some(secs) => {
      // `timeout` inside the box is what makes a killed command exit 124, the
      // same code instabox uses.
      argv.push("timeout")
      argv.push("-k")
      argv.push("5")
      argv.push("\{secs}s")
    }
    None => ()
  }
  if command.length() == 1 {
    argv.push(shell)
    argv.push("-lc")
    argv.push(command[0])
  } else {
    for arg in command {
      argv.push(arg)
    }
  }
  argv
}

///|
/// Run a command in a box with inherited stdio and no history entry. Returns
/// the command's exit status.
pub async fn exec_box_batch(
  box : String,
  command : Array[String],
  cwd : String?,
  env : Map[String, String],
  timeout_secs : Int64?,
  shell~ : String = "bash",
) -> Int32 {
  let argv = exec_argv(command, timeout_secs, shell~)
  exec_in_box(box, argv, cwd, env, false)
}

///|
/// The command line a `serbox exec` invocation asked for.
pub fn exec_command_of(args : Args) -> Array[String] {
  let command : Array[String] = []
  for arg in args.rest {
    command.push(arg)
  }
  if command.length() > 0 {
    return command
  }
  for i in 1..<args.positional.length() {
    command.push(args.positional[i])
  }
  command
}

///|
/// Append one entry to a box's history, keeping the newest 200 entries.
pub async fn record_history(box : String, entry : HistoryEntry) -> Unit {
  let dir = history_dir()
  ensure_dir(dir) catch {
    _ => return
  }
  let path = path_join(dir, "\{box}.jsonl")
  let existing = read_text(path)
  let lines : Array[String] = []
  match existing {
    Some(text) =>
      for line in text.split("\n") {
        let trimmed = line.trim().to_owned()
        if trimmed.length() > 0 {
          lines.push(trimmed)
        }
      }
    None => ()
  }
  lines.push(@json.to_json(entry).stringify())
  let start = if lines.length() > 200 { lines.length() - 200 } else { 0 }
  let buf = StringBuilder()
  for i in start..<lines.length() {
    buf.write_string(lines[i])
    buf.write_char('\n')
  }
  write_text(path, buf.to_string()) catch {
    _ => ()
  }
}

///|
/// The stored history of a box, newest first, at most `limit` entries.
pub async fn read_history(box : String, limit : Int32) -> Array[HistoryEntry] {
  let path = path_join(history_dir(), "\{box}.jsonl")
  let text = match read_text(path) {
    Some(text) => text
    None => return []
  }
  let entries : Array[HistoryEntry] = []
  for line in text.split("\n") {
    let trimmed = line.trim().to_owned()
    if trimmed.length() == 0 {
      continue
    }
    let json = @json.parse(trimmed) catch { _ => continue }
    let entry : HistoryEntry = @json.from_json(json) catch { _ => continue }
    entries.push(entry)
  }
  let result : Array[HistoryEntry] = []
  let mut i = entries.length() - 1
  while i >= 0 && result.length() < limit {
    result.push(entries[i])
    i = i - 1
  }
  result
}

///|
/// `serbox exec`
pub async fn cmd_exec(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let command = exec_command_of(args)
  if command.length() == 0 {
    raise usage_error("exec needs a command: serbox exec BOX -- CMD")
  }
  let cwd = args.value("cwd")
  let env : Map[String, String] = Map([])
  for text in args.all("env") {
    let (key, value) = parse_assignment(text, "env")
    if !valid_env_key(key) {
      raise usage_error("bad --env name '\{key}' (letters, digits and _)")
    }
    env.set(key, value)
  }
  let timeout_secs = match args.value("timeout") {
    Some(text) =>
      match parse_duration(text, default_unit_secs=1L) {
        Some(secs) if secs > 0L && secs <= 600L => Some(secs)
        Some(secs) if secs > 600L =>
          raise usage_error("--timeout is at most 600 seconds")
        _ => raise usage_error("bad --timeout '\{text}'")
      }
    None => Some(60L)
  }
  let background = args.flag("background")
  require_usable(config, true)
  touch_box(config) catch {
    _ => ()
  }
  if background {
    let job = start_job(config, command, cwd, env, timeout_secs)
    if json_only(
        @json.Json::object(
          Map([
            ("jobId", @json.Json::string(job.id)),
            ("pid", @json.Json::number(job.pid.to_double())),
          ]),
        ),
      ) {
      return
    }
    line(job.id)
    return
  }
  let started = now_secs()
  let timer_start = @env.now()
  let argv = exec_argv(command, timeout_secs, shell=config.shell)
  let stdin = args.flag("stdin")
  if args.flag("stream") {
    let code = normalize_timeout_code(
      exec_in_box(config.name, argv, cwd, env, stdin),
      timeout_secs,
    )
    record_exec(
      config.name,
      command,
      code,
      started,
      @env.now() - timer_start,
      "",
      "",
    )
    serbox_exit(code)
    return
  }
  let result = exec_in_box_capture_argv(config.name, argv, cwd, env, stdin)
  let code = normalize_timeout_code(result.code, timeout_secs)
  if json_requested() {
    let body = @json.Json::object(
      Map([
        ("stdout", @json.Json::string(result.out)),
        ("stderr", @json.Json::string(result.err)),
        ("exitCode", @json.Json::number(code.to_double())),
        ("timedOut", @json.Json::boolean(code == 124)),
      ]),
    )
    let _ = json_only(body)
    record_exec(
      config.name,
      command,
      code,
      started,
      @env.now() - timer_start,
      result.out,
      result.err,
    )
    serbox_exit(code)
    return
  }
  out(result.out)
  if result.err.length() > 0 {
    @stdio.stderr.write(result.err)
  }
  record_exec(
    config.name,
    command,
    code,
    started,
    @env.now() - timer_start,
    result.out,
    result.err,
  )
  serbox_exit(code)
}

///|
/// `timeout` reports 143 (SIGTERM) or 137 (SIGKILL) when it kills the command.
/// instabox reports 124 for "the timeout fired", and scripts branch on that,
/// so map the two signal codes onto it.
fn normalize_timeout_code(code : Int32, timeout_secs : Int64?) -> Int32 {
  match timeout_secs {
    Some(_) =>
      if code == 124 || code == 137 || code == 143 {
        124
      } else {
        code
      }
    None => code
  }
}

///|
async fn record_exec(
  box : String,
  command : Array[String],
  code : Int32,
  started : Int64,
  elapsed_ms : UInt64,
  stdout_text : String,
  stderr_text : String,
) -> Unit {
  let entry : HistoryEntry = {
    id: generate_box_name("c"),
    command: command.join(" "),
    exit_code: code,
    started_at: started,
    duration_ms: elapsed_ms.reinterpret_as_int64(),
    stdout_text: truncate_output(stdout_text),
    stderr_text: truncate_output(stderr_text),
  }
  ignore(record_history(box, entry))
}

///|
fn truncate_output(text : String) -> String {
  truncate_utf8(text, 65536)
}

///|
/// `docker exec` with cwd/env/stdin, captured.
pub async fn exec_in_box_capture_argv(
  box : String,
  argv : Array[String],
  cwd : String?,
  env : Map[String, String],
  stdin : Bool,
) -> DockerResult {
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
  docker_capture(cmd)
}

///|
/// `serbox ssh` (and `shell`): a login shell, or a command over it.
pub async fn cmd_ssh(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let command : Array[String] = []
  for arg in args.rest {
    command.push(arg)
  }
  for i in 1..<args.positional.length() {
    command.push(args.positional[i])
  }
  require_usable(config, true)
  touch_box(config) catch {
    _ => ()
  }
  let argv = if command.length() == 0 {
    [config.shell, "-l"]
  } else if command.length() == 1 {
    [config.shell, "-lc", command[0]]
  } else {
    command
  }
  let code = exec_in_box(config.name, argv, None, Map([]), true)
  serbox_exit(code)
}

///|
/// `serbox jobs`
pub async fn cmd_jobs(args : Args) -> Unit {
  let sub = args.arg(0, "jobs subcommand (ls|logs|wait|kill)")
  let config = load_box_or_fail(args.arg(1, "box name"))
  require_usable(config, true)
  match sub {
    "ls" | "list" => {
      let jobs = all_jobs(config.name)
      let rows : Array[Array[String]] = []
      let json_rows : Array[@json.Json] = []
      for job in jobs {
        let status = job_status(config.name, job)
        rows.push([
          job.id,
          status,
          format_age(now_secs() - job.started_at),
          job.command,
        ])
        json_rows.push(@json.to_json(job))
      }
      if json_only(@json.Json::array(json_rows)) {
        return
      }
      if rows.length() == 0 {
        line("no background jobs in \{config.name}")
        return
      }
      out(render_table(["JOB", "STATUS", "AGE", "COMMAND"], rows))
    }
    "logs" => {
      let job_id = args.arg(2, "job id")
      require_job_id(job_id)
      let follow = args.flag("follow")
      let cmd : Array[String] = [
        "exec",
        "-w",
        box_home,
        container_name(config.name),
        "tail",
      ]
      if follow {
        cmd.push("-f")
      }
      cmd.push("-n")
      cmd.push("+1")
      cmd.push(job_log_path(job_id))
      let code = docker_inherit(cmd)
      serbox_exit(code)
    }
    "wait" => {
      let job_id = args.arg(2, "job id")
      require_job_id(job_id)
      let timeout = match args.value("timeout") {
        Some(text) =>
          match parse_duration(text) {
            Some(secs) => secs
            None => raise usage_error("bad --timeout '\{text}'")
          }
        None => 0L
      }
      let started = now_secs()
      while true {
        match job_exit_code(config.name, job_id) {
          Some(code) => {
            if json_only(
                @json.Json::object(
                  Map([("exitCode", @json.Json::number(code.to_double()))]),
                ),
              ) {
              return
            }
            line("job \{job_id} exited \{code}")
            serbox_exit(code)
            return
          }
          None => ()
        }
        if timeout > 0L && now_secs() - started >= timeout {
          raise CliError::Failed(124, "timed out waiting for job \{job_id}")
        }
        @async.sleep(500)
      }
    }
    "kill" => {
      let job_id = args.arg(2, "job id")
      require_job_id(job_id)
      let signal = match args.value("signal") {
        Some(signal) => {
          if !valid_signal(signal) {
            raise usage_error("bad --signal '\{signal}' (e.g. TERM, KILL, 9)")
          }
          signal
        }
        None => "TERM"
      }
      let pid = job_pid(config.name, job_id)
      if pid <= 0 {
        raise CliError::Failed(4, "no pid for job '\{job_id}'")
      }
      let script = "kill -\{signal} -- -\{pid} 2>/dev/null || kill -\{signal} \{pid}"
      let result = exec_in_box_capture(config.name, ["sh", "-c", script])
      if result.code != 0 {
        raise CliError::Failed(
          1,
          "could not signal the job: \{result.err.trim().to_owned()}",
        )
      }
      if json_only(@json.to_json(@json.Json::string(job_id))) {
        return
      }
      line("signalled job \{job_id}")
    }
    _ => raise usage_error("unknown jobs subcommand '\{sub}'")
  }
}

///|
/// Job ids are generated as `j` followed by digits; anything else must not
/// reach a shell or a path inside the box.
fn require_job_id(id : String) -> Unit raise {
  let ok = id.length() > 1 && id.clamped_view().has_prefix("j")
  for i in 1..<id.length() {
    let c = id.get_char(i).unwrap_or(' ')
    if c < '0' || c > '9' {
      raise CliError::Failed(4, "bad job id '\{id}'")
    }
  }
  if !ok {
    raise CliError::Failed(4, "bad job id '\{id}'")
  }
}

///|
fn valid_signal(signal : String) -> Bool {
  if signal.length() == 0 || signal.length() > 16 {
    return false
  }
  for i in 0..<signal.length() {
    let c = signal.get_char(i).unwrap_or(' ')
    let ok = (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '+' ||
      c == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
/// The in-container path of a job's files.
pub fn job_log_path(job_id : String) -> String {
  "/data/.serbox/jobs/\{job_id}.log"
}

///|
fn job_dir(box : String) -> String {
  path_join(jobs_dir(), box)
}

///|
/// All job records of a box, newest first.
pub async fn all_jobs(box : String) -> Array[Job] {
  let names = list_dir(job_dir(box))
  let jobs : Array[Job] = []
  for entry in names {
    if entry.clamped_view().has_suffix(".json") {
      match read_text(path_join(job_dir(box), entry)) {
        Some(text) => {
          let json = @json.parse(text) catch { _ => continue }
          let job : Job = @json.from_json(json) catch { _ => continue }
          jobs.push(job)
        }
        None => ()
      }
    }
  }
  jobs.sort_by(fn(a, b) {
    if a.started_at > b.started_at {
      -1
    } else if a.started_at < b.started_at {
      1
    } else {
      0
    }
  })
  jobs
}

///|
/// Start a detached job: a script inside the box writes its own log and exit
/// status, so nothing has to stay running on the host to watch it.
pub async fn start_job(
  config : BoxConfig,
  command : Array[String],
  cwd : String?,
  env : Map[String, String],
  timeout_secs : Int64?,
) -> Job {
  let id = generate_box_name("j")
  let run_dir = match cwd {
    Some(dir) => dir
    None => box_home
  }
  // One argument is a shell string; several are an exact argv. Quoting the
  // argv form keeps `exec --background box -- echo a b` from becoming a
  // different command than the foreground one.
  let body = if command.length() == 1 {
    command[0]
  } else {
    exec_argv(command, timeout_secs, shell=config.shell) |> shell_join
  }
  let body = match timeout_secs {
    Some(secs) if command.length() == 1 =>
      "timeout -k 5 \{secs}s \{config.shell} -lc \{shell_quote(body)}"
    Some(secs) => "timeout -k 5 \{secs}s \{body}"
    None => body
  }
  let script = "mkdir -p /data/.serbox/jobs\n" +
    "cd \{shell_quote(run_dir)} || exit 1\n" +
    "(\n\{body}\n) > \{job_log_path(id)} 2>&1 &\n" +
    "echo $! > /data/.serbox/jobs/\{id}.pid\n" +
    "wait $!\n" +
    "echo $? > /data/.serbox/jobs/\{id}.exit\n"
  let host_path = path_join(serbox_home(), "\{id}.sh")
  ensure_dir(serbox_home()) catch {
    _ => ()
  }
  write_text(host_path, script) catch {
    _ => ()
  }
  let _ = exec_in_box_capture(config.name, ["mkdir", "-p", "/data/.serbox/jobs"])
  let copied = copy_in(config.name, host_path, "/data/.serbox/jobs/\{id}.sh")
  @fs.remove(host_path, allow_missing=true) catch {
    _ => ()
  }
  if copied.code != 0 {
    raise CliError::Failed(1, "could not stage the job: \{copied.err.trim()}")
  }
  let job : Job = {
    id,
    box: config.name,
    command: command.join(" "),
    started_at: now_secs(),
    pid: 0,
  }
  let args : Array[String] = ["exec", "-d", "-w", box_home]
  for key, value in env {
    args.push("-e")
    args.push("\{key}=\{value}")
  }
  args.push(container_name(config.name))
  args.push("sh")
  args.push("/data/.serbox/jobs/\{id}.sh")
  let started = docker_capture(args)
  if started.code != 0 {
    raise CliError::Failed(1, "could not start the job: \{started.err.trim()}")
  }
  // The pid file appears as soon as the script's child is forked.
  let mut pid = 0
  for _ in 0..<20 {
    @async.sleep(100)
    let found = job_pid(config.name, id)
    if found > 0 {
      pid = found
      break
    }
  }
  job.pid = pid
  ensure_dir(job_dir(config.name)) catch {
    _ => ()
  }
  write_text(
    path_join(job_dir(config.name), "\{id}.json"),
    @json.to_json(job).stringify(),
  ) catch {
    _ => ()
  }
  job
}

///|
pub async fn job_pid(box : String, job_id : String) -> Int32 {
  let result = exec_in_box_capture(box, [
    "sh",
    "-c",
    "cat /data/.serbox/jobs/\{job_id}.pid 2>/dev/null",
  ])
  if result.code != 0 {
    return 0
  }
  @string.parse_int(result.out.trim().to_owned()) catch {
    _ => 0
  }
}

///|
/// The job's exit code, or `None` while it still runs.
pub async fn job_exit_code(box : String, job_id : String) -> Int32? {
  let result = exec_in_box_capture(box, [
    "sh",
    "-c",
    "cat /data/.serbox/jobs/\{job_id}.exit 2>/dev/null",
  ])
  if result.code != 0 || result.out.trim().to_owned().length() == 0 {
    return None
  }
  let code = @string.parse_int(result.out.trim().to_owned()) catch {
    _ => return None
  }
  Some(code)
}

///|
async fn job_status(box : String, job : Job) -> String {
  match job_exit_code(box, job.id) {
    Some(code) => "exited(\{code})"
    None => if job.pid == 0 { "lost" } else { "running" }
  }
}

///|
/// `serbox ps`
pub async fn cmd_ps(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  if container_state(config.name) != "running" {
    raise CliError::Failed(1, "box '\{config.name}' is not running")
  }
  let result = container_top(config.name, args.flag("all"))
  if result.code != 0 {
    raise CliError::Failed(1, result.err.trim().to_owned())
  }
  if json_only(@json.Json::string(result.out)) {
    return
  }
  out(result.out)
}

///|
/// `serbox history`
pub async fn cmd_history(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let limit = match args.value("limit") {
    Some(text) =>
      @string.parse_int(text) catch {
        _ => raise usage_error("bad --limit '\{text}'")
      }
    None => 20
  }
  let entries = read_history(config.name, limit)
  let rows : Array[Array[String]] = []
  let json_rows : Array[@json.Json] = []
  for entry in entries {
    rows.push([
      entry.id,
      format_age(now_secs() - entry.started_at),
      "\{entry.exit_code}",
      "\{entry.duration_ms}ms",
      entry.command,
    ])
    json_rows.push(@json.to_json(entry))
  }
  if json_only(@json.Json::array(json_rows)) {
    return
  }
  if rows.length() == 0 {
    line("no commands recorded for \{config.name}")
    return
  }
  out(render_table(["ID", "WHEN", "EXIT", "TOOK", "COMMAND"], rows))
}

///|
/// `serbox output`: the last command's stored output.
pub async fn cmd_output(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let entries = read_history(config.name, 200)
  if entries.length() == 0 {
    raise CliError::Failed(4, "no command recorded for '\{config.name}'")
  }
  let mut chosen = entries[0]
  match args.arg_opt(1) {
    Some(id) => {
      let mut found = false
      for entry in entries {
        if entry.id == id {
          chosen = entry
          found = true
        }
      }
      if !found {
        raise CliError::Failed(4, "no command '\{id}' in the history")
      }
    }
    None => ()
  }
  if json_only(@json.to_json(chosen)) {
    return
  }
  out(chosen.stdout_text)
  if chosen.stderr_text.length() > 0 {
    @stdio.stderr.write(chosen.stderr_text)
  }
  serbox_exit(chosen.exit_code)
}

///|
/// `serbox disk`
pub async fn cmd_disk(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  require_usable(config, true)
  let result = exec_in_box_capture(config.name, [
    "sh", "-c", "df -P / /data 2>/dev/null",
  ])
  if result.code != 0 {
    raise CliError::Failed(1, result.err.trim().to_owned())
  }
  if json_only(@json.Json::string(result.out)) {
    return
  }
  out(result.out)
}

///|
/// `serbox metrics`: one Docker stats sample.
pub async fn cmd_metrics(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let stats = match container_stats(config.name) {
    Some(json) => {
      if json_only(json) {
        return
      }
      json
    }
    None => raise CliError::Failed(1, "box '\{config.name}' is not running")
  }
  let fields = [
    ("cpu", "CPUPerc"),
    ("memory", "MemUsage"),
    ("net", "NetIO"),
    ("block", "BlockIO"),
  ]
  for field in fields {
    let (label, key) = field
    let value = match stats {
      @json.Json::Object(map) =>
        match map.get(key) {
          Some(@json.Json::String(text)) => text
          _ => "-"
        }
      _ => "-"
    }
    line("\{pad_right(label, 8)} \{value}")
  }
}

///|
/// `serbox logs`
pub async fn cmd_logs(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  let tail = match args.value("tail") {
    Some(text) =>
      @string.parse_int(text) catch {
        _ => raise usage_error("bad --tail '\{text}'")
      }
    None => 100
  }
  let code = container_logs(config.name, tail, args.flag("follow"))
  serbox_exit(code)
}
