///|
/// Agent skills: the same idea as instabox's `skills install`, but for this
/// host's boxes.
///
/// One self-contained `SKILL.md` teaches a coding agent what a box is, how to
/// create one, run things in it, move files and pause it. The text is compiled
/// into the binary so `serbox skills install` works on a server with no
/// checkout, no network and no npm.

///|
pub let serbox_skill : String =
  #|---
  #|name: serbox
  #|description: Run commands, files and long jobs on an isolated Linux box on this server with the `serbox` CLI — create a box, exec in it, copy files in and out, publish a port, pause it. Use whenever a task needs a clean Linux machine, root inside a sandbox, or a background service that must not touch the host.
  #|---
  #|
  #|# serbox
  #|
  #|`serbox` gives you Linux boxes on the machine it runs on. Each box is a
  #|Docker container with its own filesystem, root and processes. Files live
  #|under `/data` (home is `/data/home`) and survive stop, pause and restart.
  #|There is no account and no network service: if `serbox` is installed,
  #|it works.
  #|
  #|## The loop
  #|
  #|```sh
  #|serbox create --name dev              # start a box called dev
  #|serbox exec dev -- uname -a           # run one command
  #|serbox ssh dev                        # interactive shell
  #|serbox exec dev --background -- make  # long job, returns a job id
  #|serbox jobs logs dev <job> -f         # follow it
  #|serbox suspend dev                    # pause: memory and processes kept
  #|serbox resume dev                     # continue where it stopped
  #|serbox rm dev --yes                   # delete it and its files
  #|```
  #|
  #|## Rules that matter
  #|
  #|- One argument after `--` is a shell string (`serbox exec dev -- 'a | b'`);
  #|  several run as an exact argv with no shell.
  #|- `exec` exits with the command's own status. `124` means the timeout
  #|  (default 60s, `--timeout`) killed it.
  #|- `exec` does not wake a box you paused or stopped; `serbox start` or
  #|  `resume` does. A box that paused itself (`auto-paused`) wakes on use.
  #|- Long work belongs in `exec --background`: the job keeps running after
  #|  the CLI exits, and `jobs logs` reads its output from the box.
  #|- A box is not a secret store: anything in its environment is readable by
  #|  anything in it.
  #|
  #|## Files
  #|
  #|```sh
  #|serbox push dev ./src /data/src      # host -> box
  #|serbox pull dev /data/out ./out      # box -> host
  #|serbox cp dev:/data/x.tgz ./x.tgz    # either direction
  #|serbox files dev /data               # list a directory
  #|serbox files dev /data/a.txt         # print a text file
  #|```
  #|
  #|`push` of a directory whose name ends in `/` copies its contents.
  #|
  #|## Ports
  #|
  #|```sh
  #|serbox create --name web --publish 8080
  #|serbox port publish web 3000          # later, for a running box
  #|serbox port ls
  #|serbox port unpublish web 3000
  #|```
  #|
  #|The URL is `http://<server>:<port>/`. Behind a firewall, reach it through
  #|an SSH tunnel instead.
  #|
  #|## Snapshots
  #|
  #|```sh
  #|serbox snapshot save dev --name ready   # save files and installed software
  #|serbox create --name dev2 --snapshot ready
  #|serbox fork dev --count 2               # copies for parallel work
  #|```
  #|
  #|## Scripting
  #|
  #|Every command takes `--json` and prints one JSON object; failures print
  #|`{"error":{"code":...,"message":...}}` and exit non-zero (2 usage, 4 not
  #|found, 75 retryable, 124 timeout). Check the host first with
  #|`serbox doctor`.

///|
/// One place a skill can be installed, and the flag that names it.
pub struct SkillTarget {
  name : String
  dirs : Array[String]
}

///|
/// The directories each agent reads skills from, relative to HOME.
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
/// `serbox skills install [-y] [--target]`
pub async fn cmd_skills(args : Args) -> Unit {
  let sub = args.arg(0, "skills subcommand (install)")
  if sub != "install" {
    raise usage_error("unknown skills subcommand '\{sub}' (only `install`)")
  }
  let all = args.flag("all")
  let wanted : Array[String] = []
  for target in skill_targets() {
    if all || args.flag(target.name) {
      wanted.push(target.name)
    }
  }
  if wanted.length() == 0 {
    for target in skill_targets() {
      wanted.push(target.name)
    }
  }
  if !args.flag("yes") && stdout_is_tty() {
    let yes = confirm("install the serbox skill for \{wanted.join(", ")}?") catch {
      _ => false
    }
    if !yes {
      raise CliError::Failed(1, "not installed (pass -y to confirm)")
    }
  }
  let home = user_home()
  let installed : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for target in skill_targets() {
    let mut selected = false
    for name in wanted {
      if name == target.name {
        selected = true
      }
    }
    if !selected {
      continue
    }
    for dir in target.dirs {
      let full = path_join(path_join(home, dir), "serbox")
      if seen.contains(full) {
        continue
      }
      seen.set(full, true)
      ensure_dir(full) catch {
        _ => raise CliError::Failed(1, "could not create \{full}")
      }
      write_text(path_join(full, "SKILL.md"), serbox_skill) catch {
        _ => raise CliError::Failed(1, "could not write \{full}/SKILL.md")
      }
      installed.push(full)
    }
  }
  let json_rows : Array[@json.Json] = []
  for path in installed {
    json_rows.push(@json.Json::string(path))
  }
  if json_only(@json.Json::array(json_rows)) {
    return
  }
  for path in installed {
    line("installed \{path}/SKILL.md")
  }
}
