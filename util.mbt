///|
/// Small helpers shared by the CLI, the store and the Docker backend: paths,
/// durations, names, quoting and colour. Kept together because they are the
/// only things every command touches.

///|
/// serbox's state directory: `$SERBOX_HOME`, else `~/.serbox`.
pub fn serbox_home() -> String {
  match @env.get_env_var("SERBOX_HOME") {
    Some(home) if home.length() > 0 => home
    _ => path_join(user_home(), ".serbox")
  }
}

///|
/// The invoking user's home directory, without an FFI call: `HOME` covers
/// every shell and service manager serbox is expected to run under.
pub fn user_home() -> String {
  match @env.get_env_var("HOME") {
    Some(home) if home.length() > 0 => home
    _ => "/root"
  }
}

///|
/// One path segment below another, with no doubled slash.
pub fn path_join(left : String, right : String) -> String {
  if left.length() == 0 {
    return right
  }
  if left.clamped_view().has_suffix("/") {
    "\{left}\{right}"
  } else {
    "\{left}/\{right}"
  }
}

///|
/// Everything before the last `/`, or `.` when there is none.
pub fn path_dirname(path : String) -> String {
  let view = path.clamped_view()
  match view.rev_find("/") {
    Some(i) =>
      if i == 0 {
        "/"
      } else {
        view.exact_view(start=0, end=i).to_owned()
      }
    None => "."
  }
}

///|
/// Everything after the last `/`, or the whole path.
pub fn path_basename(path : String) -> String {
  let view = path.clamped_view()
  match view.rev_find("/") {
    Some(i) =>
      if i + 1 >= view.length() {
        // `"/"` and `"a/"` name the directory itself, not an empty string.
        if i == 0 {
          "/"
        } else {
          view.exact_view(start=0, end=i).to_owned()
        }
      } else {
        view.exact_view(start=i + 1, end=view.length()).to_owned()
      }
    None => path
  }
}

///|
/// `mkdir -p`.
pub async fn ensure_dir(path : String) -> Unit {
  @fs.mkdir(path, recursive=true, allow_exist=true)
}

///|
/// Read a UTF-8 file, or `None` when it does not exist or cannot be read.
pub async fn read_text(path : String) -> String? {
  if !(@fs.exists(path) catch { _ => false }) {
    return None
  }
  let text = @fs.read_file(path).text() catch { _ => return None }
  Some(text)
}

///|
/// Replace a file's contents atomically, so a crash never leaves a truncated
/// JSON record that `load_box` would silently skip.
async fn write_text_mode(
  path : String,
  text : String,
  permission : Int32,
) -> Unit {
  let stamp = match @env.rand(8) {
    Some(bytes) => hex_encode(bytes)
    None => @env.now().to_string()
  }
  let tmp = path_join(
    path_dirname(path),
    ".serbox-tmp-\{serbox_getpid()}-\{stamp}",
  )
  @fs.write_file(tmp, text, create_mode=@fs.CreateOrTruncate, permission~)
  @fs.rename(tmp, path, replace=true)
}

///|
/// Replace a file's contents.
pub async fn write_text(path : String, text : String) -> Unit {
  write_text_mode(path, text, 0o644)
}

///|
/// Replace a file only the owner can read, for secrets and history.
pub async fn write_secret(path : String, text : String) -> Unit {
  // `secrets set` (or the first `host add`) may be the first command on a
  // host, before anything else created the state directory.
  ensure_dir(path_dirname(path)) catch {
    _ => ()
  }
  write_text_mode(path, text, 0o600)
  // Replacing via rename gives the temp file's mode, but an existing file may
  // have been replaced by something else; enforce the mode every time.
  @fs.chmod(path, 0o600) catch {
    _ => ()
  }
}

///|
/// Replace a file with private contents. Used for command history, which can
/// contain output the user did not expect to be world-readable.
pub async fn write_private_text(path : String, text : String) -> Unit {
  write_text_mode(path, text, 0o600)
}

///|
/// Quote a value so a POSIX shell reads it back literally.
pub fn shell_single_quote(text : String) -> String {
  let buf = StringBuilder()
  buf.write_char('\'')
  for i in 0..<text.length() {
    let c = text.get_char(i).unwrap_or(' ')
    if c == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
/// Directory entry names, sorted, without the `.`/`..` noise. `[]` for a
/// directory that does not exist.
pub async fn list_dir(path : String) -> Array[String] {
  if !(@fs.exists(path) catch { _ => false }) {
    return []
  }
  @fs.readdir(path) catch {
    _ => []
  }
}

///|
/// Current time in Unix seconds.
pub fn now_secs() -> Int64 {
  @env.now().reinterpret_as_int64() / 1000L
}

///|
/// Parse a duration such as `30m`, `2h`, `45s`, `1h30m` or `0`.
///
/// Bare digits mean minutes where a command documents minutes (`max-run`), so
/// callers that want seconds pass `default_unit_secs=1`; `0` always means off.
pub fn parse_duration(
  text : String,
  default_unit_secs~ : Int64 = 60L,
) -> Int64? {
  let s = text.trim().to_owned()
  if s.length() == 0 {
    return None
  }
  if s == "0" {
    return Some(0L)
  }
  let mut total = 0L
  let mut number = -1L
  let mut any = false
  let mut i = 0
  let view = s.clamped_view()
  while i < view.length() {
    let c = view.get_char(i).unwrap_or(' ')
    if c >= '0' && c <= '9' {
      if number < 0 {
        number = 0L
      }
      if number > 100000000000L {
        return None
      }
      number = number * 10L + (c.to_int().to_int64() - 48L)
      any = true
    } else {
      if number < 0 {
        return None
      }
      let unit = match c {
        's' => 1L
        'm' => 60L
        'h' => 3600L
        'd' => 86400L
        'w' => 604800L
        _ => return None
      }
      // Reject absurd values instead of letting Int64 wrap into a negative
      // duration, which would make a limit mean "immediately".
      if number > 100000000000L {
        return None
      }
      total = total + number * unit
      number = -1L
    }
    i = i + 1
  }
  if number >= 0 {
    if number > 100000000000L {
      return None
    }
    total = total + number * default_unit_secs
  }
  if !any {
    return None
  }
  Some(total)
}

///|
/// `90s` → `1m30s`, `7200s` → `2h`. Compact and unambiguous.
pub fn format_duration(secs : Int64) -> String {
  if secs <= 0L {
    return "0s"
  }
  let mut rest = secs
  let d = rest / 86400L
  rest = rest % 86400L
  let h = rest / 3600L
  rest = rest % 3600L
  let m = rest / 60L
  let s = rest % 60L
  let buf = StringBuilder()
  if d > 0L {
    buf.write_string("\{d}d")
  }
  if h > 0L {
    buf.write_string("\{h}h")
  }
  if m > 0L {
    buf.write_string("\{m}m")
  }
  if s > 0L && d == 0L {
    buf.write_string("\{s}s")
  }
  buf.to_string()
}

///|
/// How long ago a past timestamp was, as `3s`, `12m`, `4h`, `2d`.
pub fn format_age(seconds : Int64) -> String {
  if seconds < 0L {
    return "0s"
  }
  if seconds < 60L {
    "\{seconds}s"
  } else if seconds < 3600L {
    "\{seconds / 60L}m"
  } else if seconds < 86400L {
    "\{seconds / 3600L}h"
  } else {
    "\{seconds / 86400L}d"
  }
}

///|
/// Box names double as Docker container suffixes and file names, so they are
/// restricted to what is safe in both: lowercase letters, digits, `_` and `-`,
/// starting with a letter or digit, at most 40 characters.
pub fn valid_box_name(name : String) -> Bool {
  let n = name.length()
  if n == 0 || n > 40 {
    return false
  }
  let view = name.clamped_view()
  let first = view.get_char(0).unwrap_or(' ')
  if !((first >= 'a' && first <= 'z') || (first >= '0' && first <= '9')) {
    return false
  }
  for i in 0..<n {
    let c = view.get_char(i).unwrap_or(' ')
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
/// Truncate to at most `limit` bytes without splitting a UTF-8 character, so
/// stored command output stays valid JSON.
pub fn truncate_utf8(text : String, limit : Int32) -> String {
  if text.length() <= limit {
    return text
  }
  let buf = StringBuilder()
  let mut used = 0
  for ch in text {
    let code = ch.to_int()
    let size = if code <= 0x7F {
      1
    } else if code <= 0x7FF {
      2
    } else if code <= 0xFFFF {
      3
    } else {
      4
    }
    if used + size > limit {
      break
    }
    buf.write_char(ch)
    used = used + size
  }
  buf.to_string()
}

///|
/// Quote one argument for a POSIX shell, so `exec` can hand a shell string
/// through `bash -lc` without the caller's metacharacters being reinterpreted
/// a second time.
pub fn shell_quote(arg : String) -> String {
  let buf = StringBuilder()
  buf.write_char('\'')
  for i in 0..<arg.length() {
    let c = arg.get_char(i).unwrap_or(' ')
    if c == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
/// Join arguments into one shell command line, quoting each.
pub fn shell_join(args : Array[String]) -> String {
  let buf = StringBuilder()
  for i in 0..<args.length() {
    if i > 0 {
      buf.write_char(' ')
    }
    buf.write_string(shell_quote(args[i]))
  }
  buf.to_string()
}

///|
/// Environment variable names: a letter or `_`, then letters, digits or `_`.
pub fn valid_env_key(key : String) -> Bool {
  if key.length() == 0 || key.length() > 128 {
    return false
  }
  for i in 0..<key.length() {
    let c = key.get_char(i).unwrap_or(' ')
    let ok = (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '_'
    if !ok || (i == 0 && c >= '0' && c <= '9') {
      return false
    }
  }
  true
}

///|
/// `KEY=VALUE` split at the first `=`. `None` when there is no `=`.
pub fn split_assignment(text : String) -> (String, String)? {
  let view = text.clamped_view()
  match view.find("=") {
    Some(i) =>
      if i == 0 {
        None
      } else {
        Some(
          (
            view.exact_view(start=0, end=i).to_owned(),
            view.exact_view(start=i + 1, end=view.length()).to_owned(),
          ),
        )
      }
    None => None
  }
}

///|
/// Clamp a large byte count to a short human string (`12.4 MiB`).
pub fn format_size(bytes : Int64) -> String {
  if bytes < 1024L {
    return "\{bytes} B"
  }
  let units : Array[String] = ["KiB", "MiB", "GiB", "TiB"]
  let mut value = bytes.to_double()
  let mut unit = 0
  while value >= 1024.0 && unit < 3 {
    value = value / 1024.0
    unit = unit + 1
  }
  let rounded = (value * 10.0).round() / 10.0
  "\{rounded} \{units[unit - 1]}"
}

///|
/// Whether stdout is a terminal. Colors are for people; a pipe or a CI log
/// gets plain text, and `--json` never gets either.
pub fn stdout_is_tty() -> Bool {
  serbox_isatty(1) != 0
}

///|
/// Colors on, unless `NO_COLOR` is set or stdout is not a terminal.
pub fn colors_enabled() -> Bool {
  if @env.get_env_var("NO_COLOR") is Some(_) {
    return false
  }
  stdout_is_tty()
}

///|
/// ANSI helper: wraps `text` when colors are on.
fn paint(code : String, text : String) -> String {
  if colors_enabled() {
    "\u{1b}[\{code}m\{text}\u{1b}[0m"
  } else {
    text
  }
}

///|
pub fn green(text : String) -> String {
  paint("32", text)
}

///|
pub fn yellow(text : String) -> String {
  paint("33", text)
}

///|
pub fn red(text : String) -> String {
  paint("31", text)
}

///|
pub fn bold(text : String) -> String {
  paint("1", text)
}

///|
pub fn dim(text : String) -> String {
  paint("2", text)
}

///|
/// Pad `text` on the right to `width` display columns (ASCII-safe; box names,
/// states and ports are all ASCII).
pub fn pad_right(text : String, width : Int32) -> String {
  if text.length() >= width {
    return text
  }
  let buf = StringBuilder()
  buf.write_string(text)
  for _ in 0..<(width - text.length()) {
    buf.write_char(' ')
  }
  buf.to_string()
}

///|
pub fn pad_left(text : String, width : Int32) -> String {
  if text.length() >= width {
    return text
  }
  let buf = StringBuilder()
  for _ in 0..<(width - text.length()) {
    buf.write_char(' ')
  }
  buf.write_string(text)
  buf.to_string()
}

///|
/// Render a simple table with a header, the shape `instabox ls` uses.
pub fn render_table(
  headers : Array[String],
  rows : Array[Array[String]],
) -> String {
  let widths : Array[Int32] = []
  for h in headers {
    widths.push(h.length())
  }
  for row in rows {
    for i in 0..<row.length() {
      if i < widths.length() && row[i].length() > widths[i] {
        widths[i] = row[i].length()
      }
    }
  }
  let buf = StringBuilder()
  for i in 0..<headers.length() {
    if i > 0 {
      buf.write_string("  ")
    }
    buf.write_string(bold(pad_right(headers[i], widths[i])))
  }
  buf.write_string("\n")
  for row in rows {
    for i in 0..<row.length() {
      if i > 0 {
        buf.write_string("  ")
      }
      buf.write_string(pad_right(row[i], widths[i]))
    }
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
/// Read a whole file's lines, `[]` when absent.
pub async fn read_lines(path : String) -> Array[String] {
  match read_text(path) {
    Some(text) => {
      let lines : Array[String] = []
      for line in text.split("\n") {
        lines.push(line.to_owned())
      }
      lines
    }
    None => []
  }
}

///|
/// FFI: `isatty(3)`, so color decisions match the terminal.
extern "C" fn serbox_isatty(fd : Int32) -> Int32 = "serbox_isatty"

///|
/// FFI: toggle terminal echo, for a secret typed at a prompt.
pub extern "C" fn serbox_echo(on : Int32) -> Unit = "serbox_echo"

///|
/// FFI: this process's pid, for the daemon's pid file.
pub extern "C" fn serbox_getpid() -> Int32 = "serbox_getpid"

///|
/// FFI: `exit(3)`, the only way a command reports its status.
pub extern "C" fn serbox_exit(status : Int32) -> Unit = "serbox_exit"

///|
/// Civil date for days since 1970-01-01.
fn civil_from_days(days : Int32) -> (Int32, Int32, Int32) {
  let z = days + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  (if m <= 2 { y + 1 } else { y }, m, d)
}

///|
/// `20261125-0430` in UTC, the shape instabox uses for snapshot names.
pub fn compact_time(epoch : Int64) -> String {
  let days = (epoch / 86400L).to_int()
  let seconds = (epoch % 86400L).to_int()
  let (year, month, day) = civil_from_days(days)
  let hh = seconds / 3600
  let mm = seconds % 3600 / 60
  "\{year}\{pad2(month)}\{pad2(day)}-\{pad2(hh)}\{pad2(mm)}"
}

///|
fn pad2(value : Int32) -> String {
  if value < 10 {
    "0\{value}"
  } else {
    "\{value}"
  }
}

///|
/// ASCII lowercase, for prompts where the answer is `y`/`yes`.
pub fn ascii_lowercase(text : String) -> String {
  let buf = StringBuilder()
  for i in 0..<text.length() {
    let c = text.get_char(i).unwrap_or(' ')
    if c >= 'A' && c <= 'Z' {
      buf.write_char((c.to_int() - 65 + 97).unsafe_to_char())
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// Lowercase hex, for the remote protocol: JSON carries text, and command
/// output is arbitrary bytes, so every byte goes over as two hex digits.
pub fn hex_encode(data : Bytes) -> String {
  let alphabet = "0123456789abcdef"
  let buf = StringBuilder()
  for byte in data {
    let value = byte.to_int() & 0xff
    buf.write_char(alphabet.get_char(value / 16).unwrap_or('0'))
    buf.write_char(alphabet.get_char(value % 16).unwrap_or('0'))
  }
  buf.to_string()
}

///|
/// The inverse of `hex_encode`; `None` for odd length or a non-hex digit.
pub fn hex_decode(text : String) -> Bytes? {
  let n = text.length()
  if n % 2 != 0 {
    return None
  }
  let out : Array[Byte] = []
  let view = text.clamped_view()
  let mut i = 0
  while i < n {
    let hi = hex_digit(view.get_char(i).unwrap_or(' '))
    let lo = hex_digit(view.get_char(i + 1).unwrap_or(' '))
    match (hi, lo) {
      (Some(hi), Some(lo)) => out.push((hi * 16 + lo).to_byte())
      _ => return None
    }
    i = i + 2
  }
  Some(Bytes::from_array(out))
}

///|
fn hex_digit(c : Char) -> Int32? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - 48)
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 87)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 55)
  } else {
    None
  }
}
