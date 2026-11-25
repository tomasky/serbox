///|
/// The commands about serbox itself: `doctor`, `completion` and `update`.

///|
/// One diagnostic line.
pub struct Check {
  name : String
  ok : Bool
  detail : String
}

///|
/// `serbox doctor`: the host's prerequisites, in the order they break.
pub async fn cmd_doctor(args : Args) -> Unit {
  ignore(args)
  let checks : Array[Check] = []
  let runtime = container_runtime()
  let cli = docker_capture(["--version"])
  let install_hint = if runtime == "podman" {
    "not found; install Podman (https://podman.io/docs/installation)"
  } else {
    "not found; install Docker (https://docs.docker.com/engine/install/)"
  }
  checks.push({
    name: "\{runtime} CLI",
    ok: cli.code == 0,
    detail: if cli.code == 0 {
      cli.out.trim().to_owned()
    } else {
      install_hint
    },
  })
  let daemon = docker_capture(["info"])
  let daemon_ok = daemon.code == 0
  checks.push({
    name: "\{runtime} daemon",
    ok: daemon_ok,
    detail: if daemon_ok {
      if runtime == "podman" {
        "reachable (set SERBOX_RUNTIME=podman to make this the default)"
      } else {
        "reachable"
      }
    } else if runtime == "podman" {
      "unreachable; run `podman info` and check rootless setup"
    } else {
      "unreachable; is the service running and is this user in the docker group?"
    },
  })
  if runtime == "podman" {
    let controllers = read_text("/sys/fs/cgroup/cgroup.controllers")
    match controllers {
      Some(text) =>
        if !text.contains("pids") {
          checks.push({
            name: "podman cgroups",
            ok: true,
            detail: "pids controller missing; boxes start with --cgroups=disabled, so pause and stats are unavailable",
          })
        }
      None => ()
    }
  }
  let home = serbox_home()
  // A fresh host has no state directory yet; creating it is exactly what the
  // first real command would do, so doctor should not call that a failure.
  ensure_dir(home) catch {
    _ => ()
  }
  let writable = probe_home(home)
  checks.push({
    name: "state directory",
    ok: writable,
    detail: if writable {
      home
    } else {
      "\{home} is not writable"
    },
  })
  let df = docker_capture(["version", "--format", "{{.Server.Arch}}"])
  ignore(df)
  let uname = @process.collect_output("uname", ["-sm"]) catch {
    _ => (1, @utf8.encode(""), @utf8.encode(""))
  }
  let (uname_code, uname_out, _) = uname
  checks.push({
    name: "kernel",
    ok: uname_code == 0,
    detail: if uname_code == 0 {
      @utf8.decode_lossy(uname_out.binary()).trim().to_owned()
    } else {
      "unknown"
    },
  })
  let mut failures = 0
  let json_checks : Array[@json.Json] = []
  for check in checks {
    if !check.ok {
      failures = failures + 1
    }
    json_checks.push(
      @json.Json::object(
        Map([
          ("name", @json.Json::string(check.name)),
          ("ok", @json.Json::boolean(check.ok)),
          ("detail", @json.Json::string(check.detail)),
        ]),
      ),
    )
  }
  if json_only(
      @json.Json::object(
        Map([
          ("ok", @json.Json::boolean(failures == 0)),
          ("checks", @json.Json::array(json_checks)),
        ]),
      ),
    ) {
    if failures > 0 {
      serbox_exit(1)
    }
    return
  }
  for check in checks {
    let mark = if check.ok { green("ok") } else { red("fail") }
    line("\{pad_right(mark, 6)} \{pad_right(check.name, 16)} \{check.detail}")
  }
  if failures > 0 {
    eline("serbox: \{failures} check(s) failed")
    serbox_exit(1)
  }
}

///|
async fn probe_home(home : String) -> Bool {
  let path = path_join(home, ".doctor-probe")
  @fs.write_file(path, "ok", create_mode=@fs.CreateOrTruncate) catch {
    _ => return false
  }
  @fs.remove(path, allow_missing=true) catch {
    _ => ()
  }
  true
}

///|
/// `serbox completion bash|zsh|fish`
pub async fn cmd_completion(args : Args) -> Unit {
  let shell = args.arg(0, "shell (bash|zsh|fish)")
  let commands = [
    "create", "ls", "get", "rename", "rm", "start", "stop", "suspend", "resume",
    "restart", "wake", "auto-suspend", "max-run", "resize", "templates", "usage",
    "gc", "run", "exec", "jobs", "ps", "history", "output", "ssh", "files", "push",
    "pull", "cp", "disk", "metrics", "logs", "snapshot", "fork", "port", "secrets",
    "skills", "host", "hosts", "serve", "doctor", "completion", "update", "version",
    "help",
  ]
  let words = commands.join(" ")
  match shell {
    "bash" =>
      line(
        "_serbox() {\n" +
        "  local cur=\"${COMP_WORDS[COMP_CWORD]}\"\n" +
        "  if [ \"$COMP_CWORD\" -eq 1 ]; then\n" +
        "    COMPREPLY=( $(compgen -W \"\{words}\" -- \"$cur\") )\n" +
        "  else\n" +
        "    COMPREPLY=( $(compgen -W \"$(serbox ls --json 2>/dev/null | sed -n 's/.*\"name\":\"\\([^\"]*\\)\".*/\\1/p')\" -- \"$cur\") )\n" +
        "  fi\n" +
        "}\n" +
        "complete -F _serbox serbox",
      )
    "zsh" =>
      line(
        "#compdef serbox\n" +
        "_serbox() {\n" +
        "  local -a commands\n" +
        "  commands=(\{words})\n" +
        "  if (( CURRENT == 2 )); then\n" +
        "    _describe 'command' commands\n" +
        "  fi\n" +
        "}\n" +
        "_serbox \"$@\"",
      )
    "fish" =>
      for command in commands {
        line("complete -c serbox -n '__fish_use_subcommand' -a '\{command}'")
      }
    _ => raise usage_error("unknown shell '\{shell}' (bash, zsh or fish)")
  }
}

///|
/// `serbox update`: the npm package is the distribution channel, so updating
/// is npm's job rather than a self-rewriting binary.
pub async fn cmd_update(args : Args) -> Unit {
  ignore(args)
  let json = @json.Json::object(
    Map([
      ("version", @json.Json::string(serbox_version)),
      ("command", @json.Json::string("npm install -g @tomasko/serbox@latest")),
    ]),
  )
  if json_only(json) {
    return
  }
  line("serbox \{serbox_version}")
  line("update with: npm install -g @tomasko/serbox@latest")
  line("or run:     npx @tomasko/serbox@latest")
}
