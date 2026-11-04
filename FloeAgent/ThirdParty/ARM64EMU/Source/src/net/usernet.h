/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* usernet: self-contained user-mode NAT stack for the virtio-net backend.
 *
 * Replaces libslirp with the same fixed topology: guest 10.0.2.15/24,
 * gateway/host 10.0.2.2, DNS 10.0.2.3. Guest TCP/UDP flows are terminated
 * here and proxied through ordinary nonblocking host sockets — no TAP, TUN,
 * or privileges required. IPv4 only.
 *
 * The device layer feeds guest TX frames in via usernet_input() and drives
 * the stack with usernet_poll() (nonblocking, called from machine_tick).
 * Frames for the guest come back through the output callback; returning
 * false means "can't take it now" (device RX ring full) — the stack holds
 * TCP data back (its own backpressure) and drops loss-tolerant frames.
 *
 * Floe embedded restoration (this profile):
 *  - No process exit, no atexit, no environment variables: pcap capture and
 *    the stats-at-exit dump are absent; counters are read live through
 *    usernet_get_stats(). Diagnostic notes go through the host printf hook.
 *  - Darwin portability: MSG_NOSIGNAL does not exist on macOS/iOS, so every
 *    socket is created with SO_NOSIGPIPE and sends use 0 flags there.
 *  - Host port-forward listeners bind host loopback (127.0.0.1) only, and
 *    add/remove return the real host error (e.g. EADDRINUSE) instead of a
 *    silent "-1".
 *  - usernet_destroy() tears down every owned descriptor, flow buffer and
 *    listener; safe on a quiet machine before device destruction.
 *  - The DNS relay target comes from explicit configuration when provided;
 *    otherwise the host resolver is probed (resolv.conf, res_ninit on
 *    macOS). When no resolver exists usernet_dns_server() returns 0 and
 *    guest DNS datagrams are refused honestly — never a hardcoded public
 *    DNS substitute.
 */
#ifndef USERNET_H
#define USERNET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct UserNet UserNet;

typedef bool (*usernet_output_fn)(void *opaque, const uint8_t *frame, size_t len);

/* guest_mac: the MAC the device advertises in config space, so frames can
 * be addressed to the guest before it ever transmits. dns_server: host-order
 * IPv4 of the resolver guest DNS relays to, or 0 to probe the host. Returns
 * NULL only on allocation failure (all owned state is released then). */
UserNet *usernet_new(usernet_output_fn output, void *opaque,
                     const uint8_t guest_mac[6], uint32_t dns_server);
/* Full teardown: closes every socket, listener, ping socket and pcap-free
 * state, frees flow buffers and the instance. The output callback is never
 * invoked after this returns. */
void     usernet_destroy(UserNet *un);
/* Bind a loopback host listener (TCP) or socket (UDP) forwarding to
 * 10.0.2.15:guest_port. Returns 0, or -errno on failure (EADDRINUSE when the
 * host port is taken, EMFILE/ENFILE, ENOMEM...). Rules persist across guest
 * reboots; usernet_remove_hostfwd closes and drops one. */
int      usernet_add_hostfwd(UserNet *un, bool is_udp,
                             uint16_t host_port, uint16_t guest_port);
int      usernet_remove_hostfwd(UserNet *un, bool is_udp, uint16_t host_port);
void     usernet_input(UserNet *un, const uint8_t *frame, size_t len);
void     usernet_poll(UserNet *un);
/* Guest-driven device reset (warm reboot): tear down all flows but keep
 * host-side listeners and sockets that outlive the guest. */
void     usernet_guest_reset(UserNet *un);

/* Resolver relay target actually in use (host-order IPv4), or 0 when guest
 * DNS cannot be served and will be refused. */
uint32_t usernet_dns_server(UserNet *un);
/* Live counters (never atexit). Any pointer may be NULL. */
void     usernet_get_stats(UserNet *un,
                           uint64_t *in_frames, uint64_t *out_ok,
                           uint64_t *out_refused,
                           unsigned *tcp_conns, unsigned *udp_flows);

#endif
