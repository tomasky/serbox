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
#include <unistd.h>
#include <termios.h>

MOONBIT_FFI_EXPORT
void serbox_exit(int32_t status) {
  exit((int)status);
}

MOONBIT_FFI_EXPORT
int32_t serbox_isatty(int32_t fd) {
  return isatty((int)fd) ? 1 : 0;
}

// Turning echo off around a password read is the difference between a secret
// and a secret printed into the terminal's scrollback.
MOONBIT_FFI_EXPORT
void serbox_echo(int32_t on) {
  struct termios t;
  if (tcgetattr(STDIN_FILENO, &t) != 0) return;
  if (on) {
    t.c_lflag |= ECHO;
  } else {
    t.c_lflag &= ~(tcflag_t)ECHO;
  }
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &t);
}

// The daemon writes its pid so `serve --restart` can replace exactly that
// process. MoonBit's async process API exposes child pids but not our own.
int32_t serbox_getpid(void) {
  return (int32_t)getpid();
}
