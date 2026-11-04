/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* usernet TCP: terminating proxy between synthesized guest-side TCP and
 * nonblocking host sockets.
 *
 * Deliberate omissions, safe because the virtual link is in-order and
 * guest->host frames cannot be lost: no reassembly queue, no SACK, no
 * congestion control, no window scaling (never offered, so the guest
 * doesn't use it either). Retransmission exists only for the rare case of
 * the guest dropping a delivered segment (RX-ring refusals are handled by
 * not advancing snd_nxt at all). Flow control is real on both sides: the
 * advertised guest window mirrors free g2h space, and reading from the
 * host socket stops while the h2g ring is full. */
#include "usernet_priv.h"
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

/* Darwin has no MSG_NOSIGNAL; see un_sock_nosigpipe() in usernet_priv.h. */

#define TF_FIN 0x01
#define TF_SYN 0x02
#define TF_RST 0x04
#define TF_PSH 0x08
#define TF_ACK 0x10

static inline bool seq_lt(uint32_t a, uint32_t b) { return (int32_t)(a - b) < 0; }
static inline uint32_t umin(uint32_t a, uint32_t b) { return a < b ? a : b; }

/* ---- byte rings ---- */

static void ring_put(uint8_t *buf, uint32_t cap, uint32_t head, uint32_t len,
                     const uint8_t *src, uint32_t n) {
    uint32_t tail = (head + len) % cap;
    uint32_t first = umin(n, cap - tail);
    memcpy(buf + tail, src, first);
    memcpy(buf, src + first, n - first);
}

static void ring_get(const uint8_t *buf, uint32_t cap, uint32_t pos,
                     uint8_t *dst, uint32_t n) {
    pos %= cap;
    uint32_t first = umin(n, cap - pos);
    memcpy(dst, buf + pos, first);
    memcpy(dst + first, buf, n - first);
}

/* ---- connection bookkeeping ---- */

static TcpConn *conn_find(UserNet *un, uint16_t g_port,
                          uint32_t r_ip, uint16_t r_port) {
    for (TcpConn *c = un->tcp; c; c = c->next)
        if (c->g_port == g_port && c->r_ip == r_ip && c->r_port == r_port)
            return c;
    return NULL;
}

static void conn_free(UserNet *un, TcpConn *c) {
    for (TcpConn **p = &un->tcp; *p; p = &(*p)->next)
        if (*p == c) { *p = c->next; break; }
    if (c->fd >= 0) close(c->fd);
    free(c->h2g);
    free(c->g2h);
    free(c);
    un->n_tcp--;
}

/* ---- segment emission ---- */

static bool tcp_emit(UserNet *un, TcpConn *c, uint8_t flags, uint32_t seq,
                     const uint8_t *payload, uint32_t plen, bool with_mss) {
    uint8_t seg[24 + UN_TCP_MSS];
    size_t hl = 20 + (with_mss ? 4 : 0);

    un_wr16(seg + 0, c->r_port);
    un_wr16(seg + 2, c->g_port);
    un_wr32(seg + 4, seq);
    un_wr32(seg + 8, (flags & TF_ACK) ? c->rcv_nxt : 0);
    seg[12] = (uint8_t)((hl / 4) << 4);
    seg[13] = flags;
    uint32_t wnd = umin(UN_TCP_G2H - c->g2h_len, 65535);
    un_wr16(seg + 14, (uint16_t)wnd);
    un_wr16(seg + 16, 0);
    un_wr16(seg + 18, 0);
    if (with_mss) {
        seg[20] = 2; seg[21] = 4;
        un_wr16(seg + 22, UN_TCP_MSS);
    }
    if (plen) memcpy(seg + hl, payload, plen);
    un_wr16(seg + 16, un_l4_cksum(c->r_ip, UN_IP_GUEST, UN_IPP_TCP,
                                  seg, hl + plen));
    return un_emit_ip(un, UN_IPP_TCP, c->r_ip, UN_IP_GUEST, seg, hl + plen);
}

/* RST for segments that belong to no connection (RFC 793 reset rules). */
static void tcp_rst_raw(UserNet *un, uint32_t r_ip, uint16_t r_port,
                        uint16_t g_port, uint32_t seq, uint32_t ack,
                        bool with_ack) {
    uint8_t seg[20];
    memset(seg, 0, sizeof(seg));
    un_wr16(seg + 0, r_port);
    un_wr16(seg + 2, g_port);
    un_wr32(seg + 4, seq);
    un_wr32(seg + 8, with_ack ? ack : 0);
    seg[12] = 5 << 4;
    seg[13] = TF_RST | (with_ack ? TF_ACK : 0);
    un_wr16(seg + 16, un_l4_cksum(r_ip, UN_IP_GUEST, UN_IPP_TCP, seg, 20));
    un_emit_ip(un, UN_IPP_TCP, r_ip, UN_IP_GUEST, seg, 20);
}

/* Abort: RST toward the guest (if it ever saw the connection), then free. */
static void conn_abort(UserNet *un, TcpConn *c) {
    if (c->state == TG_SYN_RCVD || c->state == TG_EST ||
        c->state == TG_SYN_SENT)
        tcp_emit(un, c, TF_RST | TF_ACK, c->snd_nxt, NULL, 0, false);
    else if (c->state == TG_SYN_WAIT)   /* guest still in SYN-SENT */
        tcp_rst_raw(un, c->r_ip, c->r_port, c->g_port, 0, c->rcv_nxt, true);
    conn_free(un, c);
}

static void try_send_synack(UserNet *un, TcpConn *c) {
    if (tcp_emit(un, c, TF_SYN | TF_ACK, c->iss, NULL, 0, true)) {
        c->synack_sent = true;
        c->snd_nxt = c->iss + 1;
        c->rto_at = un->now_ms + UN_TCP_RTO_MS;
    }
}

static void conn_linger(UserNet *un, TcpConn *c) {
    /* final ACK (covers the guest's FIN) before going quiet */
    tcp_emit(un, c, TF_ACK, c->snd_nxt, NULL, 0, false);
    if (c->fd >= 0) { close(c->fd); c->fd = -1; }
    c->state = TG_LINGER;
    c->expire_at = un->now_ms + UN_TCP_LINGER_MS;
    c->rto_at = 0;
}

/* Both FINs delivered and acknowledged? Then only stray retransmits remain. */
static void maybe_finish(UserNet *un, TcpConn *c) {
    if (c->state == TG_EST && c->guest_fin_rcvd && c->fin_sent && c->fin_acked &&
        c->g2h_len == 0)
        conn_linger(un, c);
}

/* ---- host socket I/O ---- */

/* Drain g2h into the host socket. Returns false if the connection died. */
static bool drain_g2h(UserNet *un, TcpConn *c) {
    bool drained = false;
    while (c->g2h_len > 0) {
        uint32_t chunk = umin(c->g2h_len, UN_TCP_G2H - c->g2h_head);
        ssize_t n = send(c->fd, c->g2h + c->g2h_head, chunk, UN_SEND_FLAGS);
        if (n > 0) {
            c->g2h_head = (c->g2h_head + (uint32_t)n) % UN_TCP_G2H;
            c->g2h_len -= (uint32_t)n;
            drained = true;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK ||
                             errno == EINTR)) {
            break;
        } else {
            conn_abort(un, c);
            return false;
        }
    }
    if (drained && c->state == TG_EST)
        tcp_emit(un, c, TF_ACK, c->snd_nxt, NULL, 0, false); /* window update */
    if (c->g2h_len == 0 && c->guest_fin_rcvd && !c->host_wr_shut && c->fd >= 0) {
        shutdown(c->fd, SHUT_WR);
        c->host_wr_shut = true;
    }
    maybe_finish(un, c);
    return true;
}

/* Pull host bytes into the h2g ring. Returns false if the connection died. */
static bool host_read(UserNet *un, TcpConn *c) {
    uint8_t tmp[16384];
    while (!c->host_eof && c->h2g_len < UN_TCP_H2G) {
        uint32_t want = umin(sizeof(tmp), UN_TCP_H2G - c->h2g_len);
        ssize_t n = read(c->fd, tmp, want);
        if (n > 0) {
            ring_put(c->h2g, UN_TCP_H2G, c->h2g_head, c->h2g_len,
                     tmp, (uint32_t)n);
            c->h2g_len += (uint32_t)n;
            if ((uint32_t)n < want) break;
        } else if (n == 0) {
            c->host_eof = true;
        } else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            break;
        } else {
            conn_abort(un, c);
            return false;
        }
    }
    return true;
}

/* Emit unsent h2g data (and the trailing FIN) within the guest's window;
 * an output refusal just leaves snd_nxt where it is for the next poll. */
static void emit_conn(UserNet *un, TcpConn *c) {
    if (c->state == TG_SYN_RCVD && !c->synack_sent) {
        try_send_synack(un, c);
        return;
    }
    if (c->state != TG_EST || c->fin_sent) return;

    uint8_t seg[UN_TCP_MSS];
    for (;;) {
        uint32_t sent_off = c->snd_nxt - c->snd_una;
        if (sent_off >= c->h2g_len) break;
        if (c->peer_wnd <= sent_off) break;
        uint32_t n = umin(umin(c->mss, c->h2g_len - sent_off),
                          c->peer_wnd - sent_off);
        ring_get(c->h2g, UN_TCP_H2G, c->h2g_head + sent_off, seg, n);
        if (!tcp_emit(un, c, TF_ACK | TF_PSH, c->snd_nxt, seg, n, false))
            return;                       /* RX ring full: retry next poll */
        c->snd_nxt += n;
        if (!c->rto_at) c->rto_at = un->now_ms + UN_TCP_RTO_MS;
    }
    if (c->host_eof && !c->fin_sent &&
        c->snd_nxt - c->snd_una == c->h2g_len) {
        if (tcp_emit(un, c, TF_FIN | TF_ACK, c->snd_nxt, NULL, 0, false)) {
            c->fin_sent = true;
            c->snd_nxt += 1;
            if (!c->rto_at) c->rto_at = un->now_ms + UN_TCP_RTO_MS;
        }
    }
}

/* ---- new guest-initiated connection ---- */

static uint16_t parse_mss(const uint8_t *t, size_t doff) {
    const uint8_t *o = t + 20, *end = t + doff;
    while (o < end && *o != 0) {
        if (*o == 1) { o++; continue; }
        if (o + 2 > end || o[1] < 2 || o + o[1] > end) break;
        if (*o == 2 && o[1] == 4) return un_rd16(o + 2);
        o += o[1];
    }
    return 536;
}

static void guest_open(UserNet *un, uint32_t dst, uint16_t g_port,
                       uint16_t r_port, const uint8_t *t, size_t doff,
                       uint32_t seq, uint32_t wnd) {
    if (un->n_tcp >= UN_TCP_MAX) {
        tcp_rst_raw(un, dst, r_port, g_port, 0, seq + 1, true);
        return;
    }

    /* Real target: virtual gateway -> host loopback, virtual DNS -> the
     * host's resolver, anything else straight out. */
    uint32_t t_ip = dst == UN_IP_HOST ? UN_IP(127,0,0,1) :
                    dst == UN_IP_DNS  ? usernet_dns_server(un) : dst;
    if (!t_ip) {
        tcp_rst_raw(un, dst, r_port, g_port, 0, seq + 1, true);
        return;
    }

    int fd = un_socket(SOCK_STREAM, 0);
    if (fd < 0) {
        tcp_rst_raw(un, dst, r_port, g_port, 0, seq + 1, true);
        return;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(t_ip);
    sa.sin_port = htons(r_port);
    int rc = connect(fd, (struct sockaddr *)&sa, sizeof(sa));
    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        tcp_rst_raw(un, dst, r_port, g_port, 0, seq + 1, true);
        return;
    }

    TcpConn *c = calloc(1, sizeof(*c));
    uint8_t *h2g = malloc(UN_TCP_H2G);
    uint8_t *g2h = malloc(UN_TCP_G2H);
    if (!c || !h2g || !g2h) {
        free(c); free(h2g); free(g2h); close(fd);
        return;
    }
    c->fd = fd;
    c->r_ip = dst; c->r_port = r_port; c->g_port = g_port;
    c->h2g = h2g; c->g2h = g2h;
    c->iss = un->tcp_iss; un->tcp_iss += 0x10000;
    c->snd_una = c->snd_nxt = c->iss;
    c->rcv_nxt = seq + 1;
    c->peer_wnd = wnd;
    uint16_t mss = parse_mss(t, doff);
    c->mss = mss < UN_TCP_MSS ? mss : UN_TCP_MSS;
    if (c->mss < 64) c->mss = 536;
    c->next = un->tcp; un->tcp = c;
    un->n_tcp++; un->st_tcp_conns++;

    if (rc == 0) {                        /* immediate connect (loopback) */
        c->state = TG_SYN_RCVD;
        try_send_synack(un, c);
    } else {
        c->state = TG_SYN_WAIT;
        c->expire_at = un->now_ms + UN_TCP_SYN_TMO_MS;
    }
}

/* ---- hostfwd: active open toward the guest ---- */

/* Accepted host connection -> synthesize a SYN to 10.0.2.15:guest_port,
 * sourced from the real peer's address so the guest sees who connected
 * (replies route via its default gateway even for off-subnet peers). */
void un_tcp_accept(UserNet *un, HostFwd *fw) {
    for (;;) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int fd = accept(fw->fd, (struct sockaddr *)&peer, &plen);
        if (fd < 0) return;
        if (un_prepare_socket(fd) < 0) { close(fd); continue; }

        uint32_t p_ip = ntohl(peer.sin_addr.s_addr);
        uint16_t p_port = ntohs(peer.sin_port);
        /* loopback peers are unroutable from the guest: present them as
         * the gateway (external peers keep their real address) */
        if ((p_ip >> 24) == 127 || p_ip == 0) p_ip = UN_IP_HOST;
        if (un->n_tcp >= UN_TCP_MAX ||
            conn_find(un, fw->guest_port, p_ip, p_port)) {
            close(fd);
            continue;
        }

        TcpConn *c = calloc(1, sizeof(*c));
        uint8_t *h2g = malloc(UN_TCP_H2G);
        uint8_t *g2h = malloc(UN_TCP_G2H);
        if (!c || !h2g || !g2h) {
            free(c); free(h2g); free(g2h); close(fd);
            return;
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

        c->fd = fd;
        c->is_hostfwd = true;
        c->r_ip = p_ip; c->r_port = p_port; c->g_port = fw->guest_port;
        c->h2g = h2g; c->g2h = g2h;
        c->iss = un->tcp_iss; un->tcp_iss += 0x10000;
        c->snd_una = c->snd_nxt = c->iss;
        c->mss = UN_TCP_MSS;             /* until the guest's SYN-ACK says */
        c->peer_wnd = 0;
        c->state = TG_SYN_SENT;
        c->expire_at = un->now_ms + UN_TCP_SYN_TMO_MS;
        c->next = un->tcp; un->tcp = c;
        un->n_tcp++; un->st_tcp_conns++;

        if (tcp_emit(un, c, TF_SYN, c->iss, NULL, 0, true))
            c->snd_nxt = c->iss + 1;
        /* if refused, the RTO path retries (guest may still be booting) */
        c->rto_at = un->now_ms + UN_TCP_RTO_MS;
    }
}

/* ---- guest segment input ---- */

void un_tcp_input(UserNet *un, uint32_t src, uint32_t dst,
                  const uint8_t *t, size_t len) {
    if (len < 20 || src != UN_IP_GUEST) return;
    uint16_t g_port = un_rd16(t + 0);
    uint16_t r_port = un_rd16(t + 2);
    uint32_t seq = un_rd32(t + 4);
    uint32_t ack = un_rd32(t + 8);
    size_t doff = (size_t)(t[12] >> 4) * 4;
    uint8_t fl = t[13];
    uint32_t wnd = un_rd16(t + 14);
    if (doff < 20 || doff > len) return;
    const uint8_t *payload = t + doff;
    uint32_t plen = (uint32_t)(len - doff);

    TcpConn *c = conn_find(un, g_port, dst, r_port);

    /* A fresh SYN onto a lingering pair: the old incarnation is done. */
    if (c && c->state == TG_LINGER && (fl & TF_SYN) && !(fl & TF_ACK)) {
        conn_free(un, c);
        c = NULL;
    }

    if (!c) {
        if (fl & TF_RST) return;
        if ((fl & TF_SYN) && !(fl & TF_ACK)) {
            guest_open(un, dst, g_port, r_port, t, doff, seq, wnd);
        } else if (fl & TF_ACK) {
            tcp_rst_raw(un, dst, r_port, g_port, ack, 0, false);
        } else {
            tcp_rst_raw(un, dst, r_port, g_port, 0,
                        seq + plen + !!(fl & TF_FIN), true);
        }
        return;
    }

    if (fl & TF_RST) {                    /* guest aborted */
        if (c->is_hostfwd && c->fd >= 0) {
            /* make the host peer see a reset, not a clean close */
            struct linger lg = { 1, 0 };
            setsockopt(c->fd, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
        }
        conn_free(un, c);
        return;
    }

    c->peer_wnd = wnd;

    switch (c->state) {
    case TG_SYN_WAIT:
        return;                           /* nothing sent yet; guest retries */
    case TG_SYN_SENT:                     /* hostfwd: waiting for SYN-ACK */
        if ((fl & (TF_SYN | TF_ACK)) == (TF_SYN | TF_ACK) &&
            c->snd_nxt == c->iss + 1 && ack == c->snd_nxt) {
            c->rcv_nxt = seq + 1;
            c->snd_una = ack;
            uint16_t mss = parse_mss(t, doff);
            c->mss = mss < UN_TCP_MSS ? mss : UN_TCP_MSS;
            if (c->mss < 64) c->mss = 536;
            c->rto_at = 0;
            c->rto_shots = 0;
            c->state = TG_EST;
            tcp_emit(un, c, TF_ACK, c->snd_nxt, NULL, 0, false);
        }
        return;
    case TG_SYN_RCVD:
        if (fl & TF_SYN) {                /* guest retransmitted its SYN */
            if (c->synack_sent)
                tcp_emit(un, c, TF_SYN | TF_ACK, c->iss, NULL, 0, true);
            else
                try_send_synack(un, c);
            return;
        }
        if ((fl & TF_ACK) && c->synack_sent && ack == c->snd_nxt) {
            c->snd_una = ack;
            c->rto_at = 0;
            c->rto_shots = 0;
            c->state = TG_EST;
            break;                        /* fall through to EST handling */
        }
        return;
    case TG_LINGER:                       /* stray retransmit: re-ACK it */
        tcp_emit(un, c, TF_ACK, c->snd_nxt, NULL, 0, false);
        return;
    case TG_EST:
        break;
    default:
        return;
    }

    /* ACK processing (window already tracked above) */
    if ((fl & TF_ACK) && seq_lt(c->snd_una, ack) && !seq_lt(c->snd_nxt, ack)) {
        uint32_t rel = ack - c->snd_una;
        uint32_t data = umin(rel, c->h2g_len);
        c->h2g_head = (c->h2g_head + data) % UN_TCP_H2G;
        c->h2g_len -= data;
        c->snd_una = ack;
        c->rto_shots = 0;
        c->rto_at = c->snd_nxt != c->snd_una ? un->now_ms + UN_TCP_RTO_MS : 0;
        if (c->fin_sent && ack == c->snd_nxt) c->fin_acked = true;
        /* freed h2g space: pull more from the host right away */
        if (!c->host_eof && !host_read(un, c)) return;
    }

    /* in-order data (with stale-prefix trimming) */
    bool advanced = false;
    if (plen > 0) {
        if (seq_lt(c->rcv_nxt, seq)) {    /* future segment: shouldn't happen */
            tcp_emit(un, c, TF_ACK, c->snd_nxt, NULL, 0, false);
            return;
        }
        uint32_t skip = c->rcv_nxt - seq;
        if (skip < plen) {
            uint32_t n = umin(plen - skip, UN_TCP_G2H - c->g2h_len);
            ring_put(c->g2h, UN_TCP_G2H, c->g2h_head, c->g2h_len,
                     payload + skip, n);
            c->g2h_len += n;
            c->rcv_nxt += n;
            advanced = n > 0;
        }
    }

    if ((fl & TF_FIN) && !c->guest_fin_rcvd && seq + plen == c->rcv_nxt) {
        c->guest_fin_rcvd = true;
        c->rcv_nxt += 1;
        advanced = true;
    }

    if (c->g2h_len > 0 || c->guest_fin_rcvd) {
        if (!drain_g2h(un, c)) return;    /* may shutdown(WR) or finish */
        if (c->state != TG_EST) return;   /* finished into LINGER */
    }

    /* ACK anything that carried payload (incl. zero-window probes and
     * stale retransmits) or consumed a FIN */
    if (advanced || plen > 0)
        tcp_emit(un, c, TF_ACK, c->snd_nxt, NULL, 0, false);

    emit_conn(un, c);                     /* window may have opened */
    maybe_finish(un, c);
}

/* ---- poll integration ---- */

void un_tcp_fill(UserNet *un) {
    for (TcpConn *c = un->tcp; c; c = c->next) {
        short ev = 0;
        switch (c->state) {
        case TG_SYN_WAIT:
            ev = POLLOUT;
            break;
        case TG_EST:
            if (!c->host_eof && c->h2g_len < UN_TCP_H2G) ev |= POLLIN;
            if (c->g2h_len > 0) ev |= POLLOUT;
            break;
        default:
            break;
        }
        if (ev && c->fd >= 0) un_poll_add(un, c->fd, ev, UN_PK_TCP, c);
    }
}

void un_tcp_event(UserNet *un, TcpConn *c, short revents) {
    if (c->state == TG_SYN_WAIT) {
        int err = 0; socklen_t elen = sizeof(err);
        if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &err, &elen) < 0)
            err = errno ? errno : EIO;
        if (err) {
            conn_abort(un, c);            /* guest sees connection refused */
            return;
        }
        c->state = TG_SYN_RCVD;
        try_send_synack(un, c);
        return;
    }
    if (c->state != TG_EST) return;

    if (revents & POLLERR) {
        conn_abort(un, c);
        return;
    }
    if (revents & (POLLIN | POLLHUP)) {
        if (!c->host_eof && c->h2g_len < UN_TCP_H2G && !host_read(un, c))
            return;
    }
    if (revents & POLLOUT) {
        if (!drain_g2h(un, c)) return;
    }
}

void un_tcp_tick(UserNet *un) {
    TcpConn *next;
    for (TcpConn *c = un->tcp; c; c = next) {
        next = c->next;
        switch (c->state) {
        case TG_SYN_WAIT:
            if (un->now_ms >= c->expire_at) conn_abort(un, c);
            continue;
        case TG_SYN_SENT:
            if (un->now_ms >= c->expire_at) {
                conn_abort(un, c);        /* guest never answered our SYN */
                continue;
            }
            if (c->rto_at && un->now_ms >= c->rto_at) {
                if (tcp_emit(un, c, TF_SYN, c->iss, NULL, 0, true))
                    c->snd_nxt = c->iss + 1;
                c->rto_shots++;
                c->rto_at = un->now_ms +
                            ((int64_t)UN_TCP_RTO_MS << umin(c->rto_shots, 6));
            }
            continue;
        case TG_LINGER:
            if (un->now_ms >= c->expire_at) conn_free(un, c);
            continue;
        default:
            break;
        }
        if (!c->rto_at || un->now_ms < c->rto_at) continue;

        /* retransmission timeout */
        if (++c->rto_shots > UN_TCP_RTO_SHOTS) {
            conn_abort(un, c);
            continue;
        }
        un->st_tcp_rtx++;
        if (c->state == TG_SYN_RCVD) {
            tcp_emit(un, c, TF_SYN | TF_ACK, c->iss, NULL, 0, true);
        } else if (c->snd_nxt != c->snd_una) {
            if (c->h2g_len > 0) {
                uint8_t seg[UN_TCP_MSS];
                uint32_t n = umin(c->mss, c->h2g_len);
                ring_get(c->h2g, UN_TCP_H2G, c->h2g_head, seg, n);
                tcp_emit(un, c, TF_ACK | TF_PSH, c->snd_una, seg, n, false);
            } else if (c->fin_sent && !c->fin_acked) {
                tcp_emit(un, c, TF_FIN | TF_ACK, c->snd_nxt - 1, NULL, 0, false);
            }
        }
        c->rto_at = un->now_ms +
                    ((int64_t)UN_TCP_RTO_MS << umin(c->rto_shots, 6));
    }
}

void un_tcp_emit_all(UserNet *un) {
    TcpConn *next;
    for (TcpConn *c = un->tcp; c; c = next) {
        next = c->next;
        emit_conn(un, c);
        maybe_finish(un, c);
    }
}

void un_tcp_reset(UserNet *un) {
    while (un->tcp) conn_free(un, un->tcp);
}

void un_tcp_destroy(UserNet *un) { un_tcp_reset(un); }
