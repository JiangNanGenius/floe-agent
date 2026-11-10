/* SPDX-License-Identifier: Apache-2.0 */
/* Shared helpers for the backend component tests. */
#ifndef FLOE_NET_TEST_UTIL_H
#define FLOE_NET_TEST_UTIL_H

#include "harness.h"
#include "guest_frame.h"
#include "usernet.h"
#include "usernet_host.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static uint64_t tu_fnv64(const void *p, size_t n) {
    const uint8_t *b = p;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return h;
}

static void tu_fill_pattern(uint8_t *p, size_t n, uint32_t seed) {
    uint32_t x = seed ? seed : 1;
    for (size_t i = 0; i < n; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        p[i] = (uint8_t)(x >> 8);
    }
}

static void tu_set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* Bind an ephemeral loopback listener and hand back both the fd and the port. */
static int tu_tcp_listener(uint16_t *port_out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    socklen_t sl = sizeof(sa);
    getsockname(fd, (struct sockaddr *)&sa, &sl);
    if (listen(fd, 8) < 0) { close(fd); return -1; }
    tu_set_nonblock(fd);
    if (port_out) *port_out = ntohs(sa.sin_port);
    return fd;
}

/* Reserve an ephemeral loopback port and release it, so a forwarding rule can
 * bind the same number. */
static uint16_t tu_reserve_tcp_port(void) {
    uint16_t port = 0;
    int fd = tu_tcp_listener(&port);
    if (fd >= 0) close(fd);
    return port;
}

static uint16_t tu_reserve_udp_port(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;
    uint16_t port = 0;
    if (fd >= 0 && bind(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
        socklen_t sl = sizeof(sa);
        getsockname(fd, (struct sockaddr *)&sa, &sl);
        port = ntohs(sa.sin_port);
    }
    if (fd >= 0) close(fd);
    return port;
}

static void tu_emit(struct UserNet *un, const uint8_t *frame, size_t len) {
    usernet_input(un, frame, len);
}

static bool tu_pred_gw_mac(void *c) { return ((VGuest *)c)->gw_mac_known; }
static bool tu_pred_est(void *c)   { return ((VGuest *)c)->conn.state >= VG_ESTABLISHED; }

static bool tu_boot(VGuest *g, struct UserNet *un) {
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_arp_request(g, frame, VG_IP_GW);
    tu_emit(un, frame, n);
    return vg_pump(g, un, tu_emit, NULL, 0, NULL, NULL, tu_pred_gw_mac, g, 3000);
}

typedef struct {
    int listener;
    int conn;
    uint8_t buf[262144];
    size_t got;
    bool peer_fin;
} TuEcho;

static void tu_echo_service(void *ctx) {
    TuEcho *e = ctx;
    if (e->listener >= 0 && e->conn < 0) {
        int c = accept(e->listener, NULL, NULL);
        if (c >= 0) { tu_set_nonblock(c); e->conn = c; }
    }
    if (e->conn < 0) return;
    for (;;) {
        ssize_t n = recv(e->conn, e->buf + e->got, sizeof(e->buf) - e->got, 0);
        if (n > 0) {
            size_t base = e->got;
            e->got += (size_t)n;
            size_t off = 0;
            while (off < (size_t)n) {
                ssize_t w = send(e->conn, e->buf + base + off, (size_t)n - off, 0);
                if (w <= 0) break;
                off += (size_t)w;
            }
            continue;
        }
        if (n == 0) { e->peer_fin = true; shutdown(e->conn, SHUT_WR); }
        break;
    }
}

static void tu_ext(struct UserNet *un, UserNetExtStats *xs) {
    memset(xs, 0, sizeof(*xs));
    xs->struct_size = sizeof(*xs);
    usernet_get_ext_stats(un, xs);
}

#endif
