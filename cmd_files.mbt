///|
/// Files between the host and a box: `push`, `pull`, `cp` and `files`.
///
/// All four are `docker cp`, which streams through the daemon and needs
/// neither SSH nor a shell inside the box. The copy rules are instabox's: a
/// source ending in `/`, `/.,` or `.` copies its contents, anything else
/// keeps its own name inside an existing destination directory.

///|
/// Whether a path inside a box is a directory.
pub async fn box_path_is_dir(box : String, path : String) -> Bool {
  let result = exec_in_box_capture(box, ["test", "-d", path])
  result.code == 0
}

///|
/// Whether a path inside a box exists.
pub async fn box_path_exists(box : String, path : String) -> Bool {
  let result = exec_in_box_capture(box, ["test", "-e", path])
  result.code == 0
}

///|
/// `mkdir -p` inside a box.
pub async fn box_mkdir_p(box : String, path : String) -> Unit {
  let result = exec_in_box_capture(box, ["mkdir", "-p", path])
  if result.code != 0 {
    raise CliError::Failed(
      1,
      "could not create '\{path}': \{result.err.trim().to_owned()}",
    )
  }
}

///|
/// Whether a host path is a directory.
pub async fn host_path_is_dir(path : String) -> Bool {
  let kind = @fs.kind(path) catch { _ => return false }
  match kind {
    @fs.FileKind::Directory => true
    _ => false
  }
}

///|
/// The last path segment, without a trailing slash.
pub fn trim_trailing_slash(path : String) -> String {
  let mut text = path
  while text.length() > 1 && text.clamped_view().has_suffix("/") {
    text = text
      .clamped_view()
      .exact_view(start=0, end=text.length() - 1)
      .to_owned()
  }
  text
}

///|
/// Whether a source argument means "the contents of this directory".
pub fn copies_contents(path : String) -> Bool {
  path == "." ||
  path == ".." ||
  path.clamped_view().has_suffix("/.") ||
  (path.length() > 1 && path.clamped_view().has_suffix("/"))
}

///|
/// Push a host path into a box.
pub async fn push_path(
  box : String,
  host_path : String,
  remote : String?,
  parents : Bool,
) -> Unit {
  let source = trim_trailing_slash(host_path)
  if !(@fs.exists(source) catch { _ => false }) {
    raise CliError::Failed(4, "no such file or directory '\{host_path}'")
  }
  let target = match remote {
    Some(path) => path
    // A bare `push box ./file` means "into my home", not "replace /data/home".
    None => "\{box_home}/"
  }
  if parents && target != box_home {
    // `-p` creates the parents of the destination, and the destination when it
    // ends in a slash: `push box x /data/a/b` works without /data/a existing.
    if copies_contents(target) || !box_path_exists(box, target) {
      box_mkdir_p(box, trim_trailing_slash(target))
    }
  }
  let is_dir = host_path_is_dir(source)
  let into_dir = target.length() > 0 &&
    (copies_contents(target) || (is_dir && box_path_is_dir(box, target)))
  let (from, to) = if copies_contents(host_path) {
    ("\{source}/.", target)
  } else if into_dir {
    (source, path_join(trim_trailing_slash(target), path_basename(source)))
  } else {
    (source, target)
  }
  let result = copy_in(box, from, to)
  if result.code != 0 {
    raise CliError::Failed(1, "push failed: \{result.err.trim().to_owned()}")
  }
}

///|
/// Copy a path out of a box.
pub async fn pull_path(
  box : String,
  remote : String,
  host_path : String?,
) -> Unit {
  let target = match host_path {
    Some(path) => path
    None => "."
  }
  let source = trim_trailing_slash(remote)
  if !box_path_exists(box, source) {
    raise CliError::Failed(4, "no such path in the box: '\{remote}'")
  }
  let is_dir = box_path_is_dir(box, source)
  let to = if copies_contents(remote) {
    target
  } else if is_dir && host_path_is_dir(target) {
    path_join(trim_trailing_slash(target), path_basename(source))
  } else {
    target
  }
  ensure_dir(path_dirname(to)) catch {
    _ => ()
  }
  let result = copy_out(box, remote, to)
  if result.code != 0 {
    raise CliError::Failed(1, "pull failed: \{result.err.trim().to_owned()}")
  }
}

///|
/// `serbox push BOX LOCAL [REMOTE]`
pub async fn cmd_push(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  require_usable(config, true)
  touch_box(config) catch {
    _ => ()
  }
  let host_path = args.arg(1, "host_path path")
  let remote = args.arg_opt(2)
  push_path(config.name, host_path, remote, args.flag("parents")) catch {
    CliError::Failed(code, message) => raise CliError::Failed(code, message)
    _ => raise CliError::Failed(1, "push failed")
  }
  if json_only(
      @json.Json::object(Map([("pushed", @json.Json::string(host_path))])),
    ) {
    return
  }
  line("pushed \{host_path} -> \{config.name}")
}

///|
/// `serbox pull BOX REMOTE [LOCAL]`
pub async fn cmd_pull(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  require_usable(config, true)
  let remote = args.arg(1, "remote path")
  let host_path = args.arg_opt(2)
  pull_path(config.name, remote, host_path)
  if json_only(
      @json.Json::object(Map([("pulled", @json.Json::string(remote))])),
    ) {
    return
  }
  line("pulled \{config.name}:\{remote}")
}

///|
/// The slot of a `BOX:/path` argument.
priv struct RemoteRef {
  box : String
  path : String
}

///|
fn parse_remote_ref(text : String) -> RemoteRef? {
  match text.clamped_view().find(":") {
    Some(index) =>
      if index == 0 || index + 1 >= text.length() {
        None
      } else {
        Some({
          box: text.clamped_view().exact_view(start=0, end=index).to_owned(),
          path: text
          .clamped_view()
          .exact_view(start=index + 1, end=text.length())
          .to_owned(),
        })
      }
    None => None
  }
}

///|
/// `serbox cp [-r] SRC DST`, where either side may be `BOX:/path`.
pub async fn cmd_cp(args : Args) -> Unit {
  let src = args.arg(0, "source")
  let dst = args.arg(1, "destination")
  // `foo:bar` is a legal local filename. Only treat it as BOX:/path when the
  // local file does not exist.
  let src_exists = @fs.exists(src) catch { _ => false }
  let src_ref = if src_exists { None } else { parse_remote_ref(src) }
  match (src_ref, parse_remote_ref(dst)) {
    (Some(from), None) => {
      let config = load_box_or_fail(from.box)
      require_usable(config, true)
      pull_path(config.name, from.path, Some(dst))
    }
    (None, Some(to)) => {
      let config = load_box_or_fail(to.box)
      require_usable(config, true)
      touch_box(config) catch {
        _ => ()
      }
      push_path(config.name, src, Some(to.path), args.flag("parents"))
    }
    (Some(_), Some(_)) =>
      raise usage_error("cp copies between the host and one box, not two boxes")
    (None, None) => raise usage_error("cp needs one side as BOX:/path")
  }
  if json_only(@json.Json::boolean(true)) {
    return
  }
  line("copied \{src} -> \{dst}")
}

///|
/// `serbox files BOX [PATH]`: list a directory, print a text file.
pub async fn cmd_files(args : Args) -> Unit {
  let config = load_box_or_fail(args.arg(0, "box name"))
  require_usable(config, true)
  let path = match args.arg_opt(1) {
    Some(path) => path
    None => box_home
  }
  if box_path_is_dir(config.name, path) {
    let result = exec_in_box_capture(config.name, ["ls", "-la", path])
    if result.code != 0 {
      raise CliError::Failed(1, result.err.trim().to_owned())
    }
    if json_only(@json.Json::string(result.out)) {
      return
    }
    out(result.out)
    return
  }
  if !box_path_exists(config.name, path) {
    raise CliError::Failed(4, "no such path in the box: '\{path}'")
  }
  let result = exec_in_box_capture(config.name, ["cat", path])
  if result.code != 0 {
    raise CliError::Failed(1, result.err.trim().to_owned())
  }
  if json_only(@json.Json::string(result.out)) {
    return
  }
  out(result.out)
}
