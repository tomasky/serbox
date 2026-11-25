/*
 * Process-exit shim for the CLI.
 *
 * A command's exit status is part of the interface: scripts branch on 2
 * (usage), 4 (not found), 124 (timeout) and 130 (interrupted), and a wrapper
 * that ran `serbox exec` has to see the command's own code. The async stdio
 * layer writes straight to the file descriptors, so `exit()` leaves nothing
 * buffered behind.
 */

#include <moonbit.h>
#include <stdlib.h>

MOONBIT_FFI_EXPORT
void serbox_exit(int32_t status) {
  exit((int)status);
}

#include <unistd.h>

MOONBIT_FFI_EXPORT
int32_t serbox_isatty(int32_t fd) {
  return isatty((int)fd) ? 1 : 0;
}
