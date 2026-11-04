/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Raw terminal handling for the serial console (host stdin/stdout). */
#ifndef A64_TTY_H
#define A64_TTY_H

#include "types.h"

/* Put the controlling terminal into raw mode (no echo/canon, non-blocking
 * stdin). Safe to call when stdin is not a TTY (no-op). Restored on exit. */
void tty_raw_enable(void);
void tty_raw_disable(void);

/* Non-blocking read of one byte from stdin. Returns -1 if none available. */
int tty_getchar(void);

/* Write one byte to stdout (the emulated UART TX). */
void tty_putchar(int ch);

/* Bulk write to stdout (the emulated console TX) in a single write(2), so a
 * console device doesn't syscall per byte. */
void tty_write(const void *buf, size_t len);

/* Host terminal size. Writes the current columns/rows, or 0×0 when unknown
 * (stdout is not a TTY, or the ioctl fails) — the same "no geometry" state a
 * serial line reports today. */
void tty_get_winsize(unsigned short *cols, unsigned short *rows);

/* Returns 1 (clearing the pending flag) if a SIGWINCH has arrived since the
 * last call, else 0. The handler is installed by tty_raw_enable(). */
int tty_take_winch(void);

#endif /* A64_TTY_H */
