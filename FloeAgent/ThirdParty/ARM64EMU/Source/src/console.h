/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Host-side endpoints for the guest's console devices.
 *
 * Every guest console — the PL011 UART, each virtio-console — has to reach some
 * host byte stream. That used to be the process terminal by construction: both
 * devices called into tty.c directly, so every console in a run shared one
 * stdin/stdout. Fine for a single console on a terminal, and exactly what a run
 * with several consoles cannot do. A ConsoleEP names one host endpoint; each
 * device holds a pointer to the one it speaks through.
 *
 * Two kinds exist:
 *
 *   stdio  the process terminal, backed by tty.c (raw mode, the CTRL-A escape,
 *          geometry from TIOCGWINSZ and SIGWINCH). A singleton: devices left
 *          unbound all share it, which is what keeps the "input follows output"
 *          arbitration in machine_tick meaningful.
 *
 *   fd     a plain descriptor pair — a socketpair from an embedding process, a
 *          pipe, a PTY. Geometry is pushed in from outside instead of read from
 *          a terminal, and output is buffered rather than blocking: a console
 *          whose host side has stopped reading must never stall the guest.
 */
#ifndef A64_CONSOLE_H
#define A64_CONSOLE_H

#include "types.h"
#include <stddef.h>

typedef struct ConsoleEP ConsoleEP;

/* The process terminal. Never NULL, never freed; repeated calls return the same
 * endpoint, so devices that share it really do share one stdin. */
ConsoleEP *console_stdio(void);

/* An endpoint on inherited descriptors. Pass the same fd for both when the host
 * side is one bidirectional channel (a socketpair or a PTY). Both are set
 * non-blocking. Returns NULL if the descriptors are unusable. */
ConsoleEP *console_open_fd(int fd_in, int fd_out);

/* Release an fd endpoint and close its descriptors. No-op for stdio. */
void console_close(ConsoleEP *e);

/* True for the shared process-terminal endpoint. */
bool console_is_stdio(const ConsoleEP *e);

/* One byte of host input, or -1 when none is available right now. Never blocks. */
int console_getchar(ConsoleEP *e);

/* Guest console output. Bulk (a whole descriptor's worth) and single-byte forms.
 * Returns the number of bytes accepted into the channel's bounded output ring.
 * A virtio-console caller must check this and apply transport backpressure
 * (leave the TX descriptor queued) when accepted < len — bytes are never
 * silently dropped and the machine is never faulted by console saturation.
 * The PL011 UART (channel 0) keeps the legacy bounded contract: the run loop
 * parks with FLOE_AE_OUTPUT_FULL before its ring can overflow. */
size_t console_write(ConsoleEP *e, const void *buf, size_t len);
void console_putchar(ConsoleEP *e, int ch);

/* Free space in the endpoint's bounded output ring right now. A
 * virtio-console TX path uses this to apply transport backpressure: only
 * admit a descriptor chain that fits in its entirety. 0 when the endpoint
 * has no channel. */
size_t console_output_space(const ConsoleEP *e);

/* Push out whatever console_write could not hand to the kernel earlier. Cheap
 * and safe to call on every tick; a no-op for stdio and for an empty buffer. */
void console_flush(ConsoleEP *e);

/* Descriptor to wait on for host input, or -1 when this endpoint can never
 * produce any (stdio that is not a terminal, a closed peer). */
int console_poll_fd(const ConsoleEP *e);

/* Terminal geometry, 0x0 when unknown — the "no geometry" state a serial line
 * reports. For stdio this is the host window; for an fd endpoint it is whatever
 * console_set_winsize last pushed in. */
void console_get_winsize(ConsoleEP *e, u16 *cols, u16 *rows);
void console_set_winsize(ConsoleEP *e, u16 cols, u16 rows);

/* True once (clearing the flag) if the geometry changed since the last call:
 * SIGWINCH for stdio, a console_set_winsize for an fd endpoint. */
bool console_take_winch(ConsoleEP *e);

/* ---- host control channel ----------------------------------------------
 *
 * A process that binds console endpoints to descriptors it owns also needs a
 * way to say things about them while the machine runs — starting with "this
 * terminal is now 100x30", which no fd endpoint can work out for itself. That
 * is this channel: one more inherited descriptor carrying fixed 8-byte
 * little-endian messages,
 *
 *     u8 op, u8 dev, u16 cols, u16 rows, u16 reserved
 *
 * where dev is CONSOLE_CTRL_UART or an hvc index. Fixed-size messages keep the
 * reader trivial and self-resynchronising; the reserved field and the unused op
 * space leave room to say more later without a second channel. Messages may
 * arrive split across reads, so partial ones are held until complete.
 */
typedef struct ConsoleCtrl ConsoleCtrl;

#define CONSOLE_CTRL_MSG_SIZE 8
#define CONSOLE_CTRL_UART     0xff   /* dev byte naming the PL011 */

enum {
    CONSOLE_OP_NOP     = 0,   /* liveness / padding; ignored */
    CONSOLE_OP_WINSIZE = 1,   /* set dev's terminal geometry to cols x rows */
};

/* Take over `fd` as the control channel. Returns NULL if it is unusable. */
ConsoleCtrl *console_ctrl_open(int fd);

/* Apply whatever has arrived. `hvc` is indexed by the dev byte; entries may be
 * NULL (that console is on the shared terminal, whose geometry is the host
 * window's and not ours to set). Never blocks. */
void console_ctrl_poll(ConsoleCtrl *c, ConsoleEP *uart, ConsoleEP **hvc, int n_hvc);

/* Descriptor to wait on for control messages, or -1 once the peer is gone. */
int console_ctrl_fd(const ConsoleCtrl *c);

#endif /* A64_CONSOLE_H */
