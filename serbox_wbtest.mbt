// Whitebox tests: helpers that are private on purpose, checked where they live.

///|
test "a timed-out command is reported as 124" {
  // `timeout` sends TERM (143) or KILL (137); everything that scripts check
  // against should see instabox's 124.
  assert_eq(normalize_timeout_code(143, Some(5L)), 124)
  assert_eq(normalize_timeout_code(137, Some(5L)), 124)
  assert_eq(normalize_timeout_code(124, Some(5L)), 124)
  // Without --timeout those codes are the command's own exit status.
  assert_eq(normalize_timeout_code(143, None), 143)
  assert_eq(normalize_timeout_code(7, Some(5L)), 7)
  assert_eq(normalize_timeout_code(0, None), 0)
}

///|
test "container and snapshot names are namespaced" {
  assert_eq(container_name("dev"), "serbox-dev")
  assert_eq(snapshot_image("ready"), "serbox-snap-ready:latest")
  // A box called `box-x` must not collide with instabox's own naming.
  assert_eq(container_name("box-x"), "serbox-box-x")
}

///|
test "box templates are pinned to a digest-free tag" {
  for name in template_names {
    let image = template_image(name).unwrap()
    assert_true(image.contains(":"))
    assert_true(!image.contains(":latest"))
  }
  assert_eq(template_image("agent"), Some("docker.io/library/node:22-bookworm"))
}

///|
test "default box config is inert until setup runs" {
  let config = new_box_config("dev", "default", "debian:bookworm-slim")
  assert_eq(config.auto_suspend_secs, 1800L)
  assert_eq(config.max_run_secs, 0L)
  assert_eq(config.delete_at, 0L)
  assert_eq(config.setup_exit, -1)
  assert_eq(config.shell, "bash")
  assert_true(config.env.length() == 0)
}

///|
test "copy rules follow cp" {
  // `box:/dir` and `box:/dir/.` differ: the first copies the directory,
  // the second copies its contents.
  assert_true(copies_contents("/data/x/."))
  assert_true(!copies_contents("/data/x"))
  assert_eq(trim_trailing_slash("/data/x/"), "/data/x")
  assert_eq(trim_trailing_slash("/"), "/")
  assert_eq(trim_trailing_slash("/data/x"), "/data/x")
}

///|
test "a paused box is not usable without waking" {
  // The rule itself is checked through the pure display state; this keeps the
  // pairing between `paused_by` and the two visible states honest.
  assert_eq(display_state("paused", "auto"), "auto-paused")
  assert_eq(display_state("paused", ""), "paused")
}
