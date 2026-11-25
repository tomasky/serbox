///|
/// The `serbox` command line: parsing, dispatch, help and the error/exit
/// contract.
///
/// The contract is instabox's, because scripts written for one should work
/// with the other where the command means the same thing: `--json` on every
/// command, a JSON `{"error":{...}}` object on failure, and exit codes that
/// say what went wrong (2 usage, 4 not found, 75 retryable, 124 timeout,
/// 130 interrupted).

///|
/// A command failure. Usage errors are separated from everything else because
/// they exit 2 and print the help hint.
pub suberror CliError {
  Usage(String)
  Failed(Int32, String)
}

///|
pub fn usage_error(message : String) -> CliError {
  CliError::Usage(message)
}

///|
/// Whether `--json` (or `-o json`) was asked for. Every command honors it.
let json_mode : Ref[Bool] = Ref(false)

///|
pub fn set_json_mode(on : Bool) -> Unit {
  json_mode.val = on
}

///|
pub fn json_requested() -> Bool {
  json_mode.val
}

///|
pub async fn out(text : String) -> Unit {
  @stdio.stdout.write(text)
}

///|
pub async fn line(text : String) -> Unit {
  @stdio.stdout.write(text + "\n")
}

///|
pub async fn eline(text : String) -> Unit {
  @stdio.stderr.write(text + "\n")
}

///|
/// Print a value as JSON when `--json` is on. Commands that would otherwise
/// print a table call this and then the table only when it returns false.
pub async fn json_only(value : @json.Json) -> Bool {
  if json_mode.val {
    @stdio.stdout.write(value.stringify() + "\n")
    true
  } else {
    false
  }
}

///|
/// The name an exit code carries in `--json` errors.
pub fn error_code_name(code : Int32) -> String {
  match code {
    2 => "usage"
    4 => "not_found"
    75 => "retryable"
    124 => "timeout"
    130 => "interrupted"
    _ => "error"
  }
}

///|
/// Flags a command takes: which ones carry a value and which are switches.
/// Anything else is a usage error, so a typo never becomes a silently ignored
/// argument.
pub struct Args {
  positional : Array[String]
  values : Map[String, Array[String]]
  bools : Map[String, Bool]
  rest : Array[String]
}

///|
fn canonical_flag(name : String) -> String {
  match name {
    "y" => "yes"
    "f" => "follow"
    "e" => "env"
    "p" => "parents"
    "r" => "recursive"
    "q" => "quiet"
    "h" => "help"
    "o" => "output"
    "c" => "count"
    _ => name
  }
}

///|
pub fn parse_args(
  raw : Array[String],
  value_flags : Array[String],
  bool_flags : Array[String],
) -> Args raise {
  let positional : Array[String] = []
  let values : Map[String, Array[String]] = Map([])
  let bools : Map[String, Bool] = Map([])
  let rest : Array[String] = []
  let mut i = 0
  let mut after_dash = false
  while i < raw.length() {
    let arg = raw[i]
    i = i + 1
    if after_dash {
      rest.push(arg)
      continue
    }
    if arg == "--" {
      after_dash = true
      continue
    }
    if arg.length() > 2 && arg.clamped_view().has_prefix("--") {
      let body = arg
        .clamped_view()
        .exact_view(start=2, end=arg.length())
        .to_owned()
      let (name, inline) = match split_assignment(body) {
        Some((k, v)) => (canonical_flag(k), Some(v))
        None => (canonical_flag(body), None)
      }
      if value_flags.contains(name) {
        match inline {
          Some(v) => {
            if !values.contains(name) {
              values.set(name, [])
            }
            values.get(name).unwrap().push(v)
          }
          None =>
            if i >= raw.length() {
              raise usage_error("--\{name} needs a value")
            } else {
              let v = raw[i]
              i = i + 1
              if !values.contains(name) {
                values.set(name, [])
              }
              values.get(name).unwrap().push(v)
            }
        }
      } else if bool_flags.contains(name) {
        bools.set(name, true)
      } else if name == "json" {
        bools.set(name, true)
        json_mode.val = true
      } else {
        raise usage_error("unknown flag --\{name}")
      }
      continue
    }
    if arg.length() > 1 &&
      arg.clamped_view().get_char(0).unwrap_or(' ') == '-' &&
      arg != "-" {
      let name = canonical_flag(
        arg.clamped_view().exact_view(start=1, end=arg.length()).to_owned(),
      )
      if bool_flags.contains(name) {
        bools.set(name, true)
      } else if value_flags.contains(name) {
        if i >= raw.length() {
          raise usage_error("-\{name} needs a value")
        }
        let v = raw[i]
        i = i + 1
        if !values.contains(name) {
          values.set(name, [])
        }
        values.get(name).unwrap().push(v)
      } else if name == "json" {
        json_mode.val = true
      } else {
        raise usage_error("unknown flag -\{name}")
      }
      continue
    }
    positional.push(arg)
  }
  { positional, values, bools, rest, }
}

///|
pub fn Args::value(self : Args, name : String) -> String? {
  match self.values.get(name) {
    Some(items) =>
      if items.length() == 0 {
        None
      } else {
        Some(items[items.length() - 1])
      }
    None => None
  }
}

///|
pub fn Args::all(self : Args, name : String) -> Array[String] {
  match self.values.get(name) {
    Some(items) => items
    None => []
  }
}

///|
pub fn Args::flag(self : Args, name : String) -> Bool {
  match self.bools.get(name) {
    Some(value) => value
    None => false
  }
}

///|
pub fn Args::need(self : Args, name : String) -> String raise {
  match self.value(name) {
    Some(value) => value
    None => raise usage_error("--\{name} is required")
  }
}

///|
pub fn Args::arg(self : Args, index : Int32, what : String) -> String raise {
  if index >= self.positional.length() {
    raise usage_error("missing \{what}")
  }
  self.positional[index]
}

///|
pub fn Args::arg_opt(self : Args, index : Int32) -> String? {
  if index >= self.positional.length() {
    None
  } else {
    Some(self.positional[index])
  }
}

///|
/// Flags every command accepts.
let common_bools : Array[String] = ["json", "help", "quiet"]

///|
let common_values : Array[String] = ["output"]

///|
/// Add the common flags to a command's own lists.
fn with_common(
  values : Array[String],
  bools : Array[String],
) -> (Array[String], Array[String]) {
  let v : Array[String] = []
  for flag in common_values {
    v.push(flag)
  }
  for flag in values {
    v.push(flag)
  }
  let b : Array[String] = []
  for flag in common_bools {
    b.push(flag)
  }
  for flag in bools {
    b.push(flag)
  }
  (v, b)
}

///|
/// The version command, also used by the npm launcher's smoke test.
pub async fn cmd_version() -> Unit {
  let json = @json.Json::object(
    Map([
      ("name", @json.Json::string("serbox")),
      ("version", @json.Json::string(serbox_version)),
      ("moonbit", @json.Json::boolean(true)),
    ]),
  )
  if json_only(json) {
    return
  }
  line("serbox \{serbox_version}")
}

///|
/// Entry point of the `serbox` binary.
pub async fn main_cli() -> Unit {
  let argv = @env.args()
  let raw : Array[String] = []
  let mut i = 1
  while i < argv.length() {
    let arg = argv[i]
    i = i + 1
    if arg == "--no-color" {
      @env.set_env_var("NO_COLOR", "1")
    } else if arg == "--json" {
      json_mode.val = true
    } else if arg == "-o" || arg == "--output" || arg == "--format" {
      // `-o json` is `--json`; anything else is a table request.
      if i < argv.length() {
        let value = argv[i]
        i = i + 1
        if value == "json" {
          json_mode.val = true
        }
      } else {
        raw.push(arg)
      }
    } else {
      raw.push(arg)
    }
  }
  if raw.length() == 0 {
    print_usage() catch {
      _ => ()
    }
    serbox_exit(1)
    return
  }
  let command = raw[0]
  let rest : Array[String] = []
  for i in 1..<raw.length() {
    rest.push(raw[i])
  }
  dispatch(command, rest) catch {
    CliError::Usage(message) => report_usage(message)
    CliError::Failed(code, message) => report_failure(code, message)
    error => {
      let text = error.to_string()
      if text.contains("Broken pipe") || text.contains("EPIPE") {
        serbox_exit(0)
      } else {
        report_failure(1, text)
      }
    }
  }
}

///|
async fn report_usage(message : String) -> Unit {
  if json_mode.val {
    line(
      @json.Json::object(
        Map([
          (
            "error",
            @json.Json::object(
              Map([
                ("code", @json.Json::string("usage")),
                ("message", @json.Json::string(message)),
              ]),
            ),
          ),
        ]),
      ).stringify(),
    )
  }
  eline("serbox: \{message}")
  eline("run `serbox help` for usage")
  serbox_exit(2)
}

///|
async fn report_failure(code : Int32, message : String) -> Unit {
  let name = error_code_name(code)
  if json_mode.val {
    line(
      @json.Json::object(
        Map([
          (
            "error",
            @json.Json::object(
              Map([
                ("code", @json.Json::string(name)),
                ("message", @json.Json::string(message)),
              ]),
            ),
          ),
        ]),
      ).stringify(),
    )
  }
  eline("serbox: error \{name}: \{message}")
  serbox_exit(code)
}

///|
async fn dispatch(command : String, rest : Array[String]) -> Unit {
  match command {
    "help" | "--help" =>
      if rest.length() > 0 {
        print_command_help(rest[0])
      } else {
        print_usage()
      }
    "version" | "--version" | "-v" => cmd_version()
    "create" =>
      cmd_create(
        parse_args(
          rest,
          with_common(
            [
              "name", "template", "snapshot", "image", "env", "env-file", "publish",
              "meta", "auto-suspend", "delete-after", "setup-file", "secrets", "cwd",
            ],
            ["no-wait", "fail-fast"],
          ).0,
          with_common([], ["no-wait", "fail-fast"]).1,
        ),
      )
    "ls" | "list" =>
      cmd_ls(
        parse_args(
          rest,
          with_common(["meta"], []).0,
          with_common([], ["all"]).1,
        ),
      )
    "get" | "show" =>
      cmd_get(parse_args(rest, with_common([], []).0, with_common([], []).1))
    "rename" =>
      cmd_rename(parse_args(rest, with_common([], []).0, with_common([], []).1))
    "rm" | "delete" =>
      cmd_rm(
        parse_args(
          rest,
          with_common([], []).0,
          with_common([], ["yes", "force"]).1,
        ),
      )
    "start"
    | "stop"
    | "suspend"
    | "pause"
    | "resume"
    | "restart"
    | "recover"
    | "wake" =>
      cmd_lifecycle(
        command,
        parse_args(rest, with_common([], []).0, with_common([], ["no-wait"]).1),
      )
    "auto-suspend" =>
      cmd_auto_suspend(
        parse_args(rest, with_common([], []).0, with_common([], []).1),
      )
    "max-run" =>
      cmd_max_run(
        parse_args(rest, with_common([], []).0, with_common([], []).1),
      )
    "resize" =>
      cmd_resize(
        parse_args(
          rest,
          with_common(["cpus", "memory", "disk"], []).0,
          with_common([], ["restart"]).1,
        ),
      )
    "templates" => cmd_templates()
    "usage" => cmd_usage()
    "gc" =>
      cmd_gc(
        parse_args(
          rest,
          with_common(["keep"], []).0,
          with_common([], ["dry-run"]).1,
        ),
      )
    "run" =>
      cmd_run(
        parse_args(
          rest,
          with_common(["template", "name", "push", "cwd", "env", "timeout"], []).0,
          with_common([], ["keep"]).1,
        ),
      )
    "exec" =>
      cmd_exec(
        parse_args(
          rest,
          with_common(["cwd", "env", "timeout"], []).0,
          with_common([], ["stdin", "stream", "background"]).1,
        ),
      )
    "jobs" =>
      cmd_jobs(
        parse_args(
          rest,
          with_common(["timeout", "signal"], []).0,
          with_common([], ["follow"]).1,
        ),
      )
    "ps" | "top" =>
      cmd_ps(
        parse_args(rest, with_common([], []).0, with_common([], ["all"]).1),
      )
    "history" =>
      cmd_history(
        parse_args(rest, with_common(["limit"], []).0, with_common([], []).1),
      )
    "output" =>
      cmd_output(parse_args(rest, with_common([], []).0, with_common([], []).1))
    "ssh" | "shell" | "mosh" =>
      cmd_ssh(
        parse_args(
          rest,
          with_common(["cwd", "env"], []).0,
          with_common([], ["no-paste"]).1,
        ),
      )
    "files" | "cat" =>
      cmd_files(
        parse_args(rest, with_common([], []).0, with_common([], ["all"]).1),
      )
    "push" =>
      cmd_push(
        parse_args(
          rest,
          with_common([], []).0,
          with_common([], ["parents", "all"]).1,
        ),
      )
    "pull" =>
      cmd_pull(parse_args(rest, with_common([], []).0, with_common([], []).1))
    "cp" =>
      cmd_cp(
        parse_args(
          rest,
          with_common([], []).0,
          with_common([], ["recursive", "parents"]).1,
        ),
      )
    "disk" =>
      cmd_disk(parse_args(rest, with_common([], []).0, with_common([], []).1))
    "metrics" | "stats" =>
      cmd_metrics(
        parse_args(rest, with_common([], []).0, with_common([], []).1),
      )
    "logs" =>
      cmd_logs(
        parse_args(
          rest,
          with_common(["tail"], []).0,
          with_common([], ["follow"]).1,
        ),
      )
    "snapshot" | "snapshots" | "image" | "images" =>
      cmd_snapshot(
        parse_args(
          rest,
          with_common(["name", "description", "snapshot"], []).0,
          with_common([], ["yes", "root-only", "restart", "stopped"]).1,
        ),
      )
    "fork" | "clone" =>
      cmd_fork(
        parse_args(
          rest,
          with_common(["name", "count"], []).0,
          with_common([], []).1,
        ),
      )
    "port" | "ports" =>
      cmd_port(
        parse_args(
          rest,
          with_common(["host"], []).0,
          with_common([], ["private", "public"]).1,
        ),
      )
    "secrets" | "secret" =>
      cmd_secrets(
        parse_args(rest, with_common([], []).0, with_common([], ["yes"]).1),
      )
    "skills" =>
      cmd_skills(
        parse_args(
          rest,
          with_common([], []).0,
          with_common([], [
            "yes", "claude", "codex", "cursor", "opencode", "antigravity", "all",
          ]).1,
        ),
      )
    "doctor" =>
      cmd_doctor(parse_args(rest, with_common([], []).0, with_common([], []).1))
    "completion" =>
      cmd_completion(
        parse_args(rest, with_common([], []).0, with_common([], []).1),
      )
    "update" | "self-update" =>
      cmd_update(parse_args(rest, with_common([], []).0, with_common([], []).1))
    "__forward" =>
      if rest.length() < 3 {
        raise usage_error("bad internal forwarder invocation")
      } else {
        run_forwarder(rest[0], parse_port(rest[1]), parse_port(rest[2]))
      }
    "login"
    | "logout"
    | "whoami"
    | "claim"
    | "keys"
    | "key"
    | "vault"
    | "webhooks"
    | "webhook"
    | "workspace"
    | "org"
    | "ci"
    | "feedback"
    | "gpu"
    | "orca"
    | "mcp"
    | "agent" => cmd_not_local(command)
    _ => raise usage_error("unknown command '\{command}'")
  }
}

///|
/// Commands that only make sense against instabox's hosted service. serbox is
/// the local counterpart, so they exist to say what to use instead rather than
/// to fail with a parse error.
fn cmd_not_local(command : String) -> Unit raise {
  let replacement = match command {
    "login" | "logout" | "whoami" | "claim" | "keys" | "key" =>
      "serbox has no accounts: run it on the server that owns the boxes"
    "workspace" | "org" =>
      "serbox has no workspaces: every box on this host is yours"
    "vault" | "secrets" | "secret" =>
      "use `serbox secrets set NAME` for a local value store"
    "gpu" =>
      "use `serbox create --image <cuda image>` and `resize --cpus/--memory`"
    "mcp" => "serbox does not ship an MCP server yet"
    "ci" | "feedback" | "webhooks" | "webhook" | "orca" =>
      "that is an instabox cloud feature; serbox is the local tool"
    _ => "that is an instabox cloud feature; serbox is the local tool"
  }
  raise CliError::Failed(2, "\{command}: \{replacement}")
}

///|
/// Print the top-level help. Kept short: one line per command group, with the
/// details behind `serbox help <command>`.
pub async fn print_usage() -> Unit {
  let rows : Array[Array[String]] = [
    ["create --name N", "start a box"],
    ["ls", "list boxes"],
    ["get NAME", "show one box"],
    ["exec NAME -- CMD", "run a command"],
    ["ssh NAME", "open a shell"],
    ["push/pull/cp", "copy files"],
    ["suspend / resume", "pause and unpause"],
    ["start / stop", "boot and shut down"],
    ["snapshot save NAME", "save a box's files"],
    ["fork NAME", "copy a box"],
    ["port publish", "publish a port"],
    ["skills install", "install agent skills"],
    ["doctor", "check the host"],
  ]
  let text = render_table(["command", "what it does"], rows)
  line(
    "serbox \{serbox_version} — Linux boxes of your own, on your own server",
  )
  line("")
  line(text.trim_end().to_owned())
  line("")
  line("Global flags: --json, --no-color")
  line(
    "Run `serbox help <command>` for flags. Host state lives in \{serbox_home()}",
  )
}

///|
/// Per-command help, so `serbox help exec` is the same as `serbox exec --help`.
pub async fn print_command_help(command : String) -> Unit {
  let text = match command {
    "create" =>
      "serbox create --name N [--template T | --snapshot S | --image I]\n" +
      "              [--env K=V ...] [--env-file PATH] [--publish PORT[:HOST]]\n" +
      "              [--meta K=V ...] [--auto-suspend D] [--delete-after D]\n" +
      "              [--setup-file PATH] [--json]"
    "ls" => "serbox ls [--meta K=V ...] [--json]"
    "exec" =>
      "serbox exec BOX [--cwd DIR] [--env K=V ...] [--timeout SECS]\n" +
      "            [--stdin] [--stream] [--background] [--json] -- CMD..."
    "ssh" => "serbox ssh BOX [-- COMMAND...]"
    "snapshot" =>
      "serbox snapshot save BOX [--name N] [--description D]\n" +
      "serbox snapshot ls\n" +
      "serbox snapshot rm NAME [--yes]\n" +
      "serbox snapshot import IMAGE --name N\n" +
      "serbox snapshot restore BOX [--snapshot N]"
    "port" =>
      "serbox port publish BOX PORT [--host PORT]\n" +
      "serbox port ls [BOX]\n" +
      "serbox port unpublish BOX PORT"
    "skills" =>
      "serbox skills install [-y] [--claude|--codex|--cursor|--opencode|--antigravity|--all]"
    "push" => "serbox push BOX LOCAL [REMOTE] [-p] [--all]"
    "pull" => "serbox pull BOX REMOTE [LOCAL]"
    "cp" => "serbox cp [-r] BOX:/path ./local   (or the other way round)"
    "jobs" => "serbox jobs ls|logs|wait|kill BOX [JOB]"
    "secrets" =>
      "serbox secrets set NAME | ls | rm NAME | select BOX NAMES | show BOX | push BOX"
    "run" => "serbox run [--template T] [--keep] [--push DIR] -- CMD..."
    _ => "no help for '\{command}'"
  }
  line(text)
}
