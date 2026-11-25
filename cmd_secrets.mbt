///|
/// A host_path secret store, the counterpart of instabox's vault for a single
/// server.
///
/// Values live in `~/.serbox/secrets.json` with mode 0600 and are injected as
/// environment variables when a box is created, or written to
/// `/data/.serbox/secrets.env` when pushed into a running one. `secrets ls`
/// never prints a value, only a name, so a transcript stays safe.

///|
pub fn secrets_path() -> String {
  path_join(serbox_home(), "secrets.json")
}

///|
/// Every stored secret. A missing or unreadable file is an empty store, not an
/// error: secrets are optional.
pub async fn load_secrets() -> Map[String, String] {
  match read_text(secrets_path()) {
    None => Map([])
    Some(text) => {
      let json : @json.Json = @json.parse(text) catch { _ => return Map([]) }
      let values : Map[String, String] = @json.from_json(json) catch {
        _ => return Map([])
      }
      values
    }
  }
}

///|
pub async fn secrets_names() -> Array[String] {
  let secrets = load_secrets()
  let names : Array[String] = []
  for key, _ in secrets {
    names.push(key)
  }
  names.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  names
}

///|
/// `serbox secrets`
pub async fn cmd_secrets(args : Args) -> Unit {
  let sub = args.arg(0, "secrets subcommand (set|ls|rm|select|show|push)")
  match sub {
    "set" => {
      let name = args.arg(1, "secret name")
      if !valid_secret_name(name) {
        raise usage_error("bad secret name '\{name}' (A-Z, digits, _)")
      }
      let value = secret_value_from_stdin(name) catch {
        CliError::Failed(_, message) => raise CliError::Failed(1, message)
        _ => raise CliError::Failed(1, "could not read the secret")
      }
      let secrets = load_secrets()
      secrets.set(name, value)
      save_secrets(secrets)
      if json_only(
          @json.Json::object(Map([("name", @json.Json::string(name))])),
        ) {
        return
      }
      line("stored secret \{name}")
    }
    "ls" | "list" => {
      let names = secrets_names()
      let rows : Array[Array[String]] = []
      let json_rows : Array[@json.Json] = []
      for name in names {
        rows.push([name])
        json_rows.push(@json.Json::string(name))
      }
      if json_only(@json.Json::array(json_rows)) {
        return
      }
      if rows.length() == 0 {
        line("no secrets")
        return
      }
      out(render_table(["NAME"], rows))
    }
    "rm" | "delete" => {
      let name = args.arg(1, "secret name")
      let secrets = load_secrets()
      if !secrets.contains(name) {
        raise CliError::Failed(4, "no such secret '\{name}'")
      }
      if !args.flag("yes") {
        let yes = confirm("delete secret \{name}?") catch { _ => false }
        if !yes {
          raise CliError::Failed(1, "not removed (pass --yes to confirm)")
        }
      }
      secrets.remove(name)
      save_secrets(secrets)
      if json_only(@json.Json::boolean(true)) {
        return
      }
      line("removed secret \{name}")
    }
    "select" => {
      let config = load_box_or_fail(args.arg(1, "box name"))
      let spec = args.arg(2, "all|none|NAME,...")
      config.secrets = if spec == "all" {
        secrets_names()
      } else if spec == "none" {
        []
      } else {
        let names : Array[String] = []
        for name in spec.split(",") {
          names.push(name.to_owned())
        }
        names
      }
      save_box(config) catch {
        _ => ()
      }
      if json_only(@json.to_json(config)) {
        return
      }
      line("selected \{config.secrets.length()} secret(s) for \{config.name}")
    }
    "show" => {
      let config = load_box_or_fail(args.arg(1, "box name"))
      let stored = load_secrets()
      let rows : Array[Array[String]] = []
      let json_rows : Array[@json.Json] = []
      for name in config.secrets {
        rows.push([
          name,
          if stored.contains(name) {
            "stored"
          } else {
            "missing"
          },
        ])
        json_rows.push(@json.Json::string(name))
      }
      if json_only(@json.Json::array(json_rows)) {
        return
      }
      if rows.length() == 0 {
        line("no secrets selected for \{config.name}")
        return
      }
      out(render_table(["NAME", "STATE"], rows))
    }
    "push" => {
      let config = load_box_or_fail(args.arg(1, "box name"))
      require_usable(config, true)
      let secrets = load_secrets()
      let buf = StringBuilder()
      for name in config.secrets {
        match secrets.get(name) {
          Some(value) => buf.write_string("\{name}=\{value}\n")
          None => ()
        }
      }
      let host_path = path_join(serbox_home(), "secrets.env.tmp")
      ensure_dir(serbox_home()) catch {
        _ => ()
      }
      write_text(host_path, buf.to_string()) catch {
        _ => raise CliError::Failed(1, "could not stage the secrets file")
      }
      let copied = copy_in(config.name, host_path, "/data/.serbox/secrets.env")
      @fs.remove(host_path, allow_missing=true) catch {
        _ => ()
      }
      if copied.code != 0 {
        raise CliError::Failed(
          1,
          "could not deliver the secrets: \{copied.err.trim().to_owned()}",
        )
      }
      if json_only(@json.to_json(config)) {
        return
      }
      line("delivered \{config.secrets.length()} secret(s) to \{config.name}")
    }
    _ => raise usage_error("unknown secrets subcommand '\{sub}'")
  }
}

///|
/// Secret names become environment variables, so they follow the same rules.
pub fn valid_secret_name(name : String) -> Bool {
  if name.length() == 0 || name.length() > 64 {
    return false
  }
  let view = name.clamped_view()
  for i in 0..<name.length() {
    let c = view.get_char(i).unwrap_or(' ')
    let ok = (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '_'
    if !ok {
      return false
    }
  }
  true
}

///|
/// A secret's value: one line from stdin (a hidden prompt is the caller's job,
/// or `echo -n value | serbox secrets set NAME`).
async fn secret_value_from_stdin(name : String) -> String {
  ignore(name)
  match @stdio.stdin.read_until("\n") {
    Some(text) => {
      let value = text.trim_end().to_owned()
      if value.length() == 0 {
        raise CliError::Failed(
          1, "empty value; pipe it in or type it at the prompt",
        )
      }
      value
    }
    None => raise CliError::Failed(1, "no value on stdin")
  }
}

///|
async fn save_secrets(secrets : Map[String, String]) -> Unit {
  let path = secrets_path()
  let written = @fs.write_file(
    path,
    @json.to_json(secrets).stringify(),
    create_mode=@fs.CreateOrTruncate,
    permission=0o600,
  ) catch {
    _ => raise CliError::Failed(1, "could not write \{path}")
  }
  ignore(written)
}
