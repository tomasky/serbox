///|
/// Agent skills, the same idea as instabox's `skills install`.
///
/// Four complete skills ship inside the binary: the core CLI guide, snapshots,
/// moving a repository and copying a machine's setup. Each is a directory
/// (SKILL.md plus any scripts), compiled from `skills/` by
/// `scripts/gen-skills.py`, so installation works with no checkout and no
/// network. Installing is a copy: it never signs in or talks to a server.

///|
/// One file of a bundled skill, relative to the skill's own directory.
pub struct SkillFile {
  skill : String
  path : String
  body : String
}

///|
/// One place a skill can be installed, and the flag that names it.
pub struct SkillTarget {
  name : String
  dirs : Array[String]
}

///|
/// The directories each agent reads skills from, relative to HOME.
/// Codex, Cursor and OpenCode share `~/.agents/skills`; installing there once
/// avoids every agent showing the same skill twice.
pub fn skill_targets() -> Array[SkillTarget] {
  [
    { name: "claude", dirs: [".claude/skills"], },
    { name: "codex", dirs: [".agents/skills"], },
    { name: "cursor", dirs: [".agents/skills"], },
    { name: "opencode", dirs: [".agents/skills"], },
    { name: "antigravity", dirs: [".gemini/config/skills"], },
  ]
}

///|
/// The skill directories this binary carries, in name order.
pub fn bundled_skill_names() -> Array[String] {
  let names : Array[String] = []
  for file in bundled_skill_files() {
    if !names.contains(file.skill) {
      names.push(file.skill)
    }
  }
  names
}

///|
/// The one-line `description:` from a skill's front matter.
pub fn skill_description(name : String) -> String {
  for file in bundled_skill_files() {
    if file.skill == name && file.path == "SKILL.md" {
      let mut in_front = false
      for line in file.body.split("\n") {
        let text = line.to_owned()
        if text == "---" {
          if in_front {
            return ""
          }
          in_front = true
          continue
        }
        if in_front && text.has_prefix("description:") {
          return text
            .clamped_view()
            .exact_view(start=12, end=text.length())
            .trim()
            .to_owned()
        }
      }
    }
  }
  ""
}

///|
/// Files of one skill, sorted by path (SKILL.md first because of the name).
fn skill_files_of(name : String) -> Array[SkillFile] {
  let files : Array[SkillFile] = []
  for file in bundled_skill_files() {
    if file.skill == name {
      files.push(file)
    }
  }
  files
}

///|
/// Install one skill under `root`. Returns installed, updated, unchanged, kept
/// or failed. A copy the user wrote (no `installed-by: serbox` marker) is kept
/// untouched, so reinstalling never overwrites a hand-written skill.
async fn install_skill(root : String, name : String) -> String {
  let files = skill_files_of(name)
  let dir = path_join(root, name)
  ensure_dir(dir) catch {
    _ => return "failed"
  }
  let marker = path_join(dir, "SKILL.md")
  let existing = read_text(marker)
  let mut status = "installed"
  match existing {
    Some(text) =>
      if !text.contains("installed-by: serbox") {
        return "kept"
      } else {
        status = "unchanged"
      }
    None => ()
  }
  for file in files {
    let target = path_join(dir, file.path)
    if file.path.contains("/") {
      ensure_dir(path_dirname(target)) catch {
        _ => return "failed"
      }
    }
    let current = read_text(target)
    let same = match current {
      Some(text) => text == file.body
      None => false
    }
    if !same {
      write_text(target, file.body) catch {
        _ => return "failed"
      }
      if status == "unchanged" {
        status = "updated"
      }
    }
    // Scripts can be run directly after install; they are only helpers, so a
    // chmod failure is not worth failing the whole installation.
    if file.path.has_suffix(".sh") || file.path.has_suffix(".mjs") {
      @fs.chmod(target, 0o755) catch {
        _ => ()
      }
    }
  }
  status
}

///|
/// The list form of a target selection: `--target claude,codex`.
fn parse_targets(args : Args) -> Array[String] raise {
  let wanted : Array[String] = []
  let mut any = false
  for target in skill_targets() {
    if args.flag(target.name) {
      wanted.push(target.name)
      any = true
    }
  }
  for text in args.all("target") {
    for part in text.split(",") {
      let name = part.trim().to_owned()
      if name.length() == 0 {
        continue
      }
      let mut known = false
      for target in skill_targets() {
        if target.name == name {
          known = true
        }
      }
      if !known {
        raise usage_error(
          "unknown target '\{name}' (claude, codex, cursor, opencode, antigravity)",
        )
      }
      if !wanted.contains(name) {
        wanted.push(name)
      }
      any = true
    }
  }
  if !any {
    for target in skill_targets() {
      wanted.push(target.name)
    }
  }
  wanted
}

///|
/// `serbox skills list`
async fn skills_list(args : Args) -> Unit {
  ignore(args)
  let names = bundled_skill_names()
  let rows : Array[@json.Json] = []
  for name in names {
    rows.push(
      @json.Json::object(
        Map([
          ("name", @json.Json::string(name)),
          ("description", @json.Json::string(skill_description(name))),
        ]),
      ),
    )
  }
  if json_only(@json.Json::array(rows)) {
    return
  }
  let table : Array[Array[String]] = []
  for name in names {
    let description = skill_description(name)
    let short = if description.length() > 96 {
      truncate_utf8(description, 96) + "..."
    } else {
      description
    }
    table.push([name, short])
  }
  out(render_table(["NAME", "DESCRIPTION"], table))
}

///|
/// `serbox skills install [-y] [--target LIST] [--only NAME]`
async fn skills_install(args : Args) -> Unit {
  let wanted = parse_targets(args)
  let only : Array[String] = []
  for text in args.all("only") {
    for part in text.split(",") {
      let name = part.trim().to_owned()
      if name.length() == 0 {
        continue
      }
      if !bundled_skill_names().contains(name) {
        raise usage_error(
          "no bundled skill '\{name}'; run `serbox skills list`",
        )
      }
      if !only.contains(name) {
        only.push(name)
      }
    }
  }
  let names = if only.length() > 0 { only } else { bundled_skill_names() }
  if !args.flag("yes") && stdout_is_tty() {
    let yes = confirm("install \{names.join(", ")} for \{wanted.join(", ")}?") catch {
      _ => false
    }
    if !yes {
      raise CliError::Failed(1, "not installed (pass -y to confirm)")
    }
  }
  let home = user_home()
  let installed : Array[String] = []
  let updated : Array[String] = []
  let unchanged : Array[String] = []
  let kept : Array[String] = []
  let failed : Array[String] = []
  let roots : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for target in skill_targets() {
    if !wanted.contains(target.name) {
      continue
    }
    for dir in target.dirs {
      let root = path_join(home, dir)
      if seen.contains(root) {
        continue
      }
      seen.set(root, true)
      roots.push(root)
      ensure_dir(root) catch {
        _ => raise CliError::Failed(1, "could not create \{root}")
      }
      for name in names {
        let status = install_skill(root, name)
        let label = "\{name} (\{display_home(root)})"
        if status == "installed" {
          installed.push(label)
        } else if status == "updated" {
          updated.push(label)
        } else if status == "unchanged" {
          unchanged.push(label)
        } else if status == "kept" {
          kept.push(label)
        } else {
          failed.push(label)
        }
      }
    }
  }
  let json_roots : Array[@json.Json] = []
  for root in roots {
    json_roots.push(@json.Json::string(root))
  }
  let json_list = fn(items : Array[String]) -> @json.Json {
    let values : Array[@json.Json] = []
    for item in items {
      values.push(@json.Json::string(item))
    }
    @json.Json::array(values)
  }
  if json_only(
      @json.Json::object(
        Map([
          ("roots", @json.Json::array(json_roots)),
          ("installed", json_list(installed)),
          ("updated", json_list(updated)),
          ("unchanged", json_list(unchanged)),
          ("kept", json_list(kept)),
          ("failed", json_list(failed)),
        ]),
      ),
    ) {
    return
  }
  if installed.length() > 0 {
    line("installed \{installed.join(", ")}")
  }
  if updated.length() > 0 {
    line("updated \{updated.join(", ")}")
  }
  if unchanged.length() > 0 {
    line("already up to date: \{unchanged.join(", ")}")
  }
  if kept.length() > 0 {
    line("kept your own: \{kept.join(", ")}")
  }
  if failed.length() > 0 {
    raise CliError::Failed(1, "could not write \{failed.join(", ")}")
  }
}

///|
/// Show a path relative to HOME so output stays short.
fn display_home(path : String) -> String {
  let home = user_home()
  if path == home {
    return "~"
  }
  if path.has_prefix(home + "/") {
    let rest = path
      .clamped_view()
      .exact_view(start=home.length() + 1, end=path.length())
      .to_owned()
    return "~/" + rest
  }
  path
}

///|
/// `serbox skills`
pub async fn cmd_skills(args : Args) -> Unit {
  let sub = match args.arg_opt(0) {
    Some(sub) => sub
    None => "list"
  }
  match sub {
    "list" | "ls" => skills_list(args)
    "install" => skills_install(args)
    _ =>
      raise usage_error(
        "unknown skills subcommand '\{sub}' (use `list` or `install`)",
      )
  }
}
