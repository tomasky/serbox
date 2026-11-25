// Blackbox tests: the public API only, the way another MoonBit package and the
// CLI see serbox. Docker is not needed here; everything below is pure.

///|
test "parse_duration reads units and compound values" {
  assert_eq(@serbox.parse_duration("30m"), Some(1800L))
  assert_eq(@serbox.parse_duration("2h"), Some(7200L))
  assert_eq(@serbox.parse_duration("1h30m"), Some(5400L))
  assert_eq(@serbox.parse_duration("45s"), Some(45L))
  assert_eq(@serbox.parse_duration("2d"), Some(172800L))
  assert_eq(@serbox.parse_duration("1w"), Some(604800L))
}

///|
test "parse_duration treats bare digits as the caller's unit" {
  // `max-run 90` means 90 minutes; `auto-suspend 90` means 90 seconds.
  assert_eq(@serbox.parse_duration("90"), Some(5400L))
  assert_eq(@serbox.parse_duration("90", default_unit_secs=1L), Some(90L))
  assert_eq(@serbox.parse_duration("0"), Some(0L))
}

///|
test "parse_duration rejects nonsense" {
  assert_eq(@serbox.parse_duration(""), None)
  assert_eq(@serbox.parse_duration("soon"), None)
  assert_eq(@serbox.parse_duration("m"), None)
  assert_eq(@serbox.parse_duration("10x"), None)
}

///|
test "format_duration is compact" {
  assert_eq(@serbox.format_duration(0L), "0s")
  assert_eq(@serbox.format_duration(90L), "1m30s")
  assert_eq(@serbox.format_duration(7200L), "2h")
  assert_eq(@serbox.format_duration(90000L), "1d1h")
}

///|
test "format_age picks the largest unit" {
  assert_eq(@serbox.format_age(-5L), "0s")
  assert_eq(@serbox.format_age(59L), "59s")
  assert_eq(@serbox.format_age(120L), "2m")
  assert_eq(@serbox.format_age(7200L), "2h")
  assert_eq(@serbox.format_age(172800L), "2d")
}

///|
test "valid_box_name matches what docker and a file name allow" {
  assert_true(@serbox.valid_box_name("dev"))
  assert_true(@serbox.valid_box_name("box-1_a"))
  assert_true(@serbox.valid_box_name("9lives"))
  assert_false(@serbox.valid_box_name(""))
  assert_false(@serbox.valid_box_name("-dev"))
  assert_false(@serbox.valid_box_name("_dev"))
  assert_false(@serbox.valid_box_name("Dev"))
  assert_false(@serbox.valid_box_name("my box"))
  assert_false(@serbox.valid_box_name("a/b"))
  assert_false(@serbox.valid_box_name("a".repeat(41)))
}

///|
test "shell_quote survives quotes and spaces" {
  assert_eq(@serbox.shell_quote("plain"), "'plain'")
  assert_eq(@serbox.shell_quote("a b"), "'a b'")
  assert_eq(@serbox.shell_quote("it's"), "'it'\\''s'")
  assert_eq(@serbox.shell_join(["a b", "c"]), "'a b' 'c'")
}

///|
test "split_assignment keeps everything after the first equals" {
  assert_eq(@serbox.split_assignment("A=B"), Some(("A", "B")))
  assert_eq(@serbox.split_assignment("TOKEN=a=b=c"), Some(("TOKEN", "a=b=c")))
  assert_eq(@serbox.split_assignment("EMPTY="), Some(("EMPTY", "")))
  assert_eq(@serbox.split_assignment("NOEQUALS"), None)
}

///|
test "path helpers" {
  assert_eq(@serbox.path_join("/data", "home"), "/data/home")
  assert_eq(@serbox.path_join("/data/", "home"), "/data/home")
  assert_eq(@serbox.path_join("", "home"), "home")
  assert_eq(@serbox.path_basename("/data/home/x.txt"), "x.txt")
  assert_eq(@serbox.path_basename("x.txt"), "x.txt")
  assert_eq(@serbox.path_dirname("/data/home/x.txt"), "/data/home")
  assert_eq(@serbox.path_dirname("/x"), "/")
  assert_eq(@serbox.path_dirname("x"), ".")
}

///|
test "format_size rounds to one decimal" {
  assert_eq(@serbox.format_size(512L), "512 B")
  assert_eq(@serbox.format_size(2048L), "2 KiB")
  assert_eq(@serbox.format_size(1536L), "1.5 KiB")
  assert_eq(@serbox.format_size(5L * 1024L * 1024L * 1024L), "5 GiB")
}

///|
test "parse_port and parse_publish" {
  assert_eq(@serbox.parse_port("8080"), 8080)
  assert_true(@serbox.parse_publish("8080").container == 8080)
  let mapped = @serbox.parse_publish("8080:18080")
  assert_true(mapped.container == 8080 && mapped.host == 18080)
}

///|
test "parse_assignment names the flag in its error" {
  assert_eq(@serbox.parse_assignment("A=B", "env"), ("A", "B"))
  let failed = try {
    let _ = @serbox.parse_assignment("oops", "env")
    false
  } catch {
    @serbox.CliError::Usage(message) => message.contains("--env")
    _ => false
  }
  assert_true(failed)
}

///|
test "exec_argv uses a shell only for a single argument" {
  assert_eq(@serbox.exec_argv(["echo hi"], None), ["bash", "-lc", "echo hi"])
  assert_eq(@serbox.exec_argv(["sh"], None, shell="sh"), ["sh", "-lc", "sh"])
  assert_eq(@serbox.exec_argv(["echo", "hi"], None), ["echo", "hi"])
  // A timeout is enforced by `timeout(1)` inside the box so the exit code is 124.
  assert_eq(@serbox.exec_argv(["sleep 5"], Some(2L)), [
    "timeout", "-k", "5", "2s", "bash", "-lc", "sleep 5",
  ])
}

///|
test "error codes follow the documented CLI contract" {
  assert_eq(@serbox.error_code_name(2), "usage")
  assert_eq(@serbox.error_code_name(4), "not_found")
  assert_eq(@serbox.error_code_name(75), "retryable")
  assert_eq(@serbox.error_code_name(124), "timeout")
  assert_eq(@serbox.error_code_name(130), "interrupted")
  assert_eq(@serbox.error_code_name(1), "error")
}

///|
test "display_state separates auto-pause from a real pause" {
  assert_eq(@serbox.display_state("running", ""), "running")
  assert_eq(@serbox.display_state("paused", "user"), "paused")
  assert_eq(@serbox.display_state("paused", "auto"), "auto-paused")
  assert_eq(@serbox.display_state("exited", ""), "stopped")
  assert_eq(@serbox.display_state("missing", ""), "lost")
}

///|
test "a box file from an older build still loads" {
  // `shell` and `secrets` were added after 0.1; a missing field must not make
  // an existing box unreadable.
  let old = @json.parse(
    "{\"name\":\"dev\",\"template\":\"alpine\",\"image\":\"alpine:3.20\",\"created_at\":\"1\",\"env\":{},\"meta\":{},\"ports\":[],\"auto_suspend_secs\":\"0\",\"max_run_secs\":\"0\",\"paused_by\":\"\",\"last_used_at\":\"1\",\"delete_at\":\"0\",\"setup_exit\":-1}",
  )
  let filled = @serbox.with_box_defaults(old)
  let config : @serbox.BoxConfig = @json.from_json(filled)
  assert_eq(config.name, "dev")
  assert_eq(config.shell, "bash")
  assert_true(config.secrets.length() == 0)
}

///|
test "parse_args separates flags, values and the command after --" {
  let args = @serbox.parse_args(
    ["--name", "dev", "-y", "--", "echo", "hi"],
    ["name"],
    ["yes"],
  )
  assert_eq(args.value("name"), Some("dev"))
  assert_true(args.flag("yes"))
  assert_eq(args.rest, ["echo", "hi"])
  // `-c` is a documented alias for `--count`.
  let aliased = @serbox.parse_args(["-c", "3"], ["count"], [])
  assert_eq(aliased.value("count"), Some("3"))
}

///|
test "an unknown flag is a usage error" {
  let failed = try {
    let _ = @serbox.parse_args(["--nope"], [], [])
    false
  } catch {
    @serbox.CliError::Usage(_) => true
    _ => false
  }
  assert_true(failed)
}

///|
test "compact_time is sortable and zero padded" {
  assert_eq(@serbox.compact_time(0L), "19700101-0000")
  assert_eq(@serbox.compact_time(86400L + 62L * 60L), "19700102-0102")
}

///|
test "ascii_lowercase leaves other characters alone" {
  assert_eq(@serbox.ascii_lowercase("YeS"), "yes")
  assert_eq(@serbox.ascii_lowercase("MiXeD-1!"), "mixed-1!")
}

///|
test "templates map to pinned images" {
  assert_eq(@serbox.template_image("default"), Some("debian:bookworm-slim"))
  assert_eq(@serbox.template_image("alpine"), Some("alpine:3.20"))
  assert_eq(@serbox.template_image("nope"), None)
}
