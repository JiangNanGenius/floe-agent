/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* usernet internals shared between usernet_core.c and the per-protocol files.
 * Addresses and ports are kept in HOST byte order everywhere internally; the
 * un_rd/un_wr helpers convert at the wire boundary. */
#ifndef USERNET_PRIV_H
#define USERNET_PRIV_H

#include "usernet.h"
#include <poll.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

/* ---- fixed topology (host byte order) ---- */
#define UN_IP(a,b,c,d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | \
                        ((uint32_t)(c) << 8) | (uint32_t)(d))
#define UN_IP_HOST   UN_IP(10,0,2,2)     /* gateway; also reaches host loopback */
#define UN_IP_DNS    UN_IP(10,0,2,3)     /* virtual DNS, redirected to real one */
#define UN_IP_GUEST  UN_IP(10,0,2,15)
#define UN_NET       UN_IP(10,0,2,0)
#define UN_NETMASK   0xffffff00u

#define UN_MTU       1500
#define UN_MAX_FRAME (14 + UN_MTU)       /* eth header + MTU, no FCS */
#define UN_POLL_MAX  128

#define UN_ETH_IP    0x0800
#define UN_ETH_ARP   0x0806
#define UN_IPP_ICMP  1
#define UN_IPP_TCP   6
#define UN_IPP_UDP   17

extern const uint8_t un_host_mac[6];     /* 52:55:0a:00:02:02 */

/* ---- Darwin send(2) portability ------------------------------------------
 * MSG_NOSIGNAL is Linux-only. On Darwin every socket is created with
 * SO_NOSIGPIPE (un_socket_dgram/un_socket_stream below) so a dead peer can
 * never raise SIGPIPE into the host process; sends then use 0 flags. There
 * are deliberately no global signal() changes anywhere in this engine.
 */
#ifdef MSG_NOSIGNAL
#define UN_SEND_FLAGS MSG_NOSIGNAL
#else
#define UN_SEND_FLAGS 0
#endif
/* Darwin does not accept SOCK_NONBLOCK/SOCK_CLOEXEC in socket's type.
 * Apply both flags explicitly and fail before exposing an unsafe descriptor.
 * No process-global SIGPIPE handler is installed. */
static inline int un_prepare_socket(int fd) {
    int status = fcntl(fd, F_GETFL);
    int descriptor = fcntl(fd, F_GETFD);
    if (status < 0 || descriptor < 0 ||
        fcntl(fd, F_SETFL, status | O_NONBLOCK) < 0 ||
        fcntl(fd, F_SETFD, descriptor | FD_CLOEXEC) < 0) return -1;
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0) return -1;
#endif
    return 0;
}
static inline int un_socket(int type, int protocol) {
    int fd = socket(AF_INET, type, protocol);
    if (fd >= 0 && un_prepare_socket(fd) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}
void un_icmp_unreach(UserNet *, uint32_t src_ip, uint32_t dst_ip,
                     const uint8_t *payload, size_t length);

/* ---- poll table entry kinds ---- */
enum { UN_PK_NONE = 0, UN_PK_UDP, UN_PK_TCP, UN_PK_ICMP,
       UN_PK_TCP_LISTEN, UN_PK_UDP_FWD };

/* -netfwd rule: a host listener (TCP) or bound socket (UDP) that forwards
 * to 10.0.2.15:guest_port. Persists across guest reboots. */
typedef struct HostFwd {
    bool     is_udp;
    uint16_t host_port, guest_port;
    int      fd;
} HostFwd;

#define UN_FWD_MAX 16

/* One relayed external ping (guest echo id <-> unprivileged ICMP socket;
 * the kernel rewrites the id on the wire, we map it back on replies). */
typedef struct IcmpFlow {
    bool     in_use;
    uint16_t g_id;
    uint32_t dst_ip;
    int      fd;
    int64_t  last_ms;
} IcmpFlow;

#define UN_ICMP_MAX     8
#define UN_ICMP_TTL_MS  30000

/* ---- TCP proxy ----
 * Guest-side TCP is synthesized here; the host side is an ordinary
 * nonblocking socket. The virtual link cannot reorder and guest->host frames
 * cannot be lost (TX is synchronous), so no reassembly queue and no
 * congestion control; only host->guest segments can be refused by the RX
 * ring, which the emit loop treats as "not sent yet". */
enum {
    TG_FREE = 0,
    TG_SYN_WAIT,     /* guest SYN seen; host connect() in flight */
    TG_SYN_RCVD,     /* SYN-ACK sent (or pending), waiting for guest ACK */
    TG_SYN_SENT,     /* hostfwd active open: SYN sent toward the guest */
    TG_EST,
    TG_LINGER        /* fully closed; absorbs stray retransmits, then freed */
};

#define UN_TCP_MAX          128
#define UN_TCP_H2G          65536    /* host->guest ring; retransmit source */
#define UN_TCP_G2H          32768    /* guest->host staging for blocked writes */
#define UN_TCP_MSS          1460
#define UN_TCP_RTO_MS       500
#define UN_TCP_RTO_SHOTS    8
#define UN_TCP_SYN_TMO_MS   30000
#define UN_TCP_LINGER_MS    5000

typedef struct TcpConn {
    struct TcpConn *next;
    uint8_t  state;
    bool     is_hostfwd;
    uint32_t r_ip;                   /* remote as the guest sees it */
    uint16_t r_port, g_port;
    int      fd;

    /* our send side (host->guest): [snd_una, snd_nxt) in flight */
    uint32_t iss, snd_una, snd_nxt;
    uint32_t rcv_nxt;                /* guest->host */
    uint16_t mss;                    /* guest's, clamped to UN_TCP_MSS */
    uint32_t peer_wnd;               /* guest's advertised window (no WS) */
    bool     synack_sent, fin_sent, fin_acked;
    bool     guest_fin_rcvd, host_eof, host_wr_shut;

    /* h2g ring holds [snd_una ...]; g2h ring drains into the host socket */
    uint8_t *h2g, *g2h;
    uint32_t h2g_head, h2g_len, g2h_head, g2h_len;

    int64_t  rto_at;                 /* 0 = unarmed */
    uint8_t  rto_shots;
    int64_t  expire_at;              /* SYN_WAIT / SYN_SENT / LINGER deadline */
} TcpConn;

/* One NATed UDP flow: guest source port <-> connected host socket.
 * r_* is the remote as the guest sees it (10.0.2.3:53 for DNS); the socket
 * is connected to the real target chosen at creation. */
typedef struct UdpFlow {
    bool     in_use, is_dns;
    uint16_t g_port, r_port;
    uint32_t r_ip;
    int      fd;
    int64_t  last_ms;
} UdpFlow;

#define UN_UDP_MAX      64
#define UN_UDP_TTL_MS   60000
#define UN_DNS_TTL_MS   10000

struct UserNet {
    usernet_output_fn output;
    void   *opaque;

    uint8_t guest_mac[6];            /* seeded at creation, tracked on TX */

    int64_t  now_ms;                     /* refreshed at each poll/input */
    uint16_t ip_id;                      /* incrementing, deterministic */

    /* poll table, rebuilt from live flows on every usernet_poll() */
    struct pollfd pfds[UN_POLL_MAX];
    struct { uint8_t kind; void *obj; } pref[UN_POLL_MAX];
    int npfds;

    UdpFlow udp[UN_UDP_MAX];
    int64_t udp_sweep_ms;

    TcpConn *tcp;                    /* live connections (singly linked) */
    int      n_tcp;
    uint32_t tcp_iss;                /* deterministic ISS counter */

    IcmpFlow icmp[UN_ICMP_MAX];
    int64_t  icmp_sweep_ms;
    bool     ping_unavail;           /* ping sockets denied: drop silently */

    HostFwd fwd[UN_FWD_MAX];
    int     n_fwd;

    /* DNS relay target: explicit configuration wins; otherwise probed from
     * the host resolver. dns_ip == 0 means guest DNS is refused. */
    uint32_t dns_cfg;                /* host-order IPv4 from config, or 0 */
    uint32_t dns_ip;                 /* probed resolver, or 0 */
    int64_t  dns_check_ms;
    bool     dns_warned;

    /* live counters (read through usernet_get_stats; never atexit) */
    uint64_t st_in_frames, st_out_ok, st_out_refused, st_out_drop;
    uint64_t st_tcp_conns, st_tcp_rtx;
};

/* ---- big-endian field access ---- */
static inline uint16_t un_rd16(const uint8_t *p) {
    return (uint16_t)((p[0] << 8) | p[1]);
}
static inline uint32_t un_rd32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}
static inline void un_wr16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v;
}
static inline void un_wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}

/* ---- internet checksum ---- */
static inline uint32_t un_cksum_add(uint32_t sum, const uint8_t *p, size_t n) {
    while (n > 1) { sum += (uint32_t)((p[0] << 8) | p[1]); p += 2; n -= 2; }
    if (n) sum += (uint32_t)(p[0] << 8);
    return sum;
}
static inline uint16_t un_cksum_fin(uint32_t sum) {
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)(~sum & 0xffff);
}
/* TCP/UDP checksum incl. IPv4 pseudo-header; l4 has the checksum field zeroed. */
uint16_t un_l4_cksum(uint32_t src, uint32_t dst, uint8_t proto,
                     const uint8_t *l4, size_t len);

int64_t un_now_ms(void);

/* Frame output via the device callback.
 * false = device RX ring full, frame not delivered. */
bool un_output(UserNet *un, const uint8_t *frame, size_t len);

/* Build eth+IPv4 around an L4 payload and emit it to the guest.
 * src/dst in host byte order; l4len <= UN_MTU - 20. */
bool un_emit_ip(UserNet *un, uint8_t proto, uint32_t src, uint32_t dst,
                const uint8_t *l4, size_t l4len);

/* Register an fd in the per-poll table (rebuilt every usernet_poll). */
static inline void un_poll_add(UserNet *un, int fd, short events,
                               uint8_t kind, void *obj) {
    if (un->npfds >= UN_POLL_MAX) return;
    un->pfds[un->npfds].fd = fd;
    un->pfds[un->npfds].events = events;
    un->pfds[un->npfds].revents = 0;
    un->pref[un->npfds].kind = kind;
    un->pref[un->npfds].obj = obj;
    un->npfds++;
}

/* usernet_udp.c */
bool un_emit_udp(UserNet *un, const uint8_t *eth_dst,
                 uint32_t src_ip, uint16_t src_port,
                 uint32_t dst_ip, uint16_t dst_port,
                 const uint8_t *payload, size_t plen);
void un_udp_input(UserNet *un, uint32_t src, uint32_t dst,
                  const uint8_t *udp, size_t len);
void un_udp_fill(UserNet *un);
void un_udp_readable(UserNet *un, UdpFlow *f);
void un_udp_tick(UserNet *un);
void un_udp_reset(UserNet *un);
void un_udp_destroy(UserNet *un);

/* usernet_tcp.c */
void un_tcp_input(UserNet *un, uint32_t src, uint32_t dst,
                  const uint8_t *tcp, size_t len);
void un_tcp_fill(UserNet *un);
void un_tcp_event(UserNet *un, TcpConn *c, short revents);
void un_tcp_tick(UserNet *un);
void un_tcp_emit_all(UserNet *un);
void un_tcp_reset(UserNet *un);
void un_tcp_destroy(UserNet *un);
void un_tcp_accept(UserNet *un, HostFwd *fw);

/* hostfwd (rule sockets live in core; UDP data path in usernet_udp.c) */
bool un_udp_fwd_input(UserNet *un, uint32_t dst, uint16_t sport,
                      uint16_t dport, const uint8_t *payload, size_t plen);
void un_udp_fwd_readable(UserNet *un, HostFwd *fw);

#endif
