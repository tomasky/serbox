///|
/// The serbox executable. Every command lives in `kupas/serbox`.
async fn main {
  // Commands report their own errors and exit with a code that says what
  // happened; what escapes here is a bug or a closed pipe.
  @serbox.main_cli() catch {
    error => {
      let message = error.to_string()
      if message.contains("Broken pipe") || message.contains("EPIPE") {
        return
      }
      @stdio.stderr.write("serbox: unexpected failure: \{message}\n")
      @serbox.serbox_exit(2)
    }
  }
}
