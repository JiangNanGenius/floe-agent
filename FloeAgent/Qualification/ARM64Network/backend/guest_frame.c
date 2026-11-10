/* SPDX-License-Identifier: Apache-2.0 */
#include "guest_frame.h"
#include "usernet.h"

#include <arpa/inet.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* ---- primitives ---- */

uint16_t vg_rd16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
uint32_t vg_rd32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}
void vg_wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
void vg_wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
uint32_t vg_cksum(uint32_t sum, const uint8_t *p, size_t n) {
    while (n > 1) { sum += (uint32_t)((p[0] << 8) | p[1]); p += 2; n -= 2; }
    if (n) sum += (uint32_t)(p[0] << 8);
    return sum;              /* carries preserved; vg_cksum_fin() folds them */
}
uint16_t vg_cksum_fin(uint32_t sum) {
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)(~sum & 0xffff);
}

static int64_t vg_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void vg_init(VGuest *g) {
    memset(g, 0, sizeof(*g));
    static const uint8_t mac[6] = VG_MAC_GUEST;
    memcpy(g->mac, mac, 6);
    g->accept_rx = true;
    g->conn.mss = 1460;
    g->conn.peer_wnd = 65535;
    g->conn.state = VG_CLOSED;
}

/* ---- RX capture: the exact contract net_deliver_frame() has ---- */

bool vg_output(void *opaque, const uint8_t *frame, size_t len) {
    VGuest *g = opaque;
    if (!frame || len < 14 || len > VG_MAX_FRAME) return true;  /* drop, as the device does */
    if (!g->accept_rx) { g->rx_refused++; return false; }
    if (g->rx_pending >= VG_RX_SLOTS) { g->rx_refused++; return false; }
    uint32_t slot = (g->rx_head + g->rx_pending) % VG_RX_SLOTS;
    memcpy(g->rx[slot], frame, len);
    g->rx_len[slot] = (uint32_t)len;
    g->rx_pending++;
    g->rx_count++;
    return true;
}

/* ---- builders ---- */

size_t vg_eth(struct VGuest *g, uint8_t *out, uint16_t ethertype,
              const uint8_t *dst_mac, const void *payload, size_t len) {
    memcpy(out, dst_mac, 6);
    memcpy(out + 6, g->mac, 6);
    vg_wr16(out + 12, ethertype);
    if (payload && len) memcpy(out + 14, payload, len);
    size_t total = 14 + len;
    if (total < 60) { memset(out + total, 0, 60 - total); total = 60; }
    return total;
}

size_t vg_arp_request(struct VGuest *g, uint8_t *out, uint32_t target_ip) {
    uint8_t a[28];
    vg_wr16(a + 0, 1);                 /* HTYPE ethernet  */
    vg_wr16(a + 2, 0x0800);            /* PTYPE IPv4      */
    a[4] = 6; a[5] = 4;
    vg_wr16(a + 6, 1);                 /* REQUEST         */
    memcpy(a + 8, g->mac, 6);
    vg_wr32(a + 14, VG_IP_GUEST);
    memset(a + 18, 0, 6);
    vg_wr32(a + 24, target_ip);
    static const uint8_t bcast[6] = { 0xff,0xff,0xff,0xff,0xff,0xff };
    return vg_eth(g, out, 0x0806, bcast, a, sizeof(a));
}

static size_t vg_arp_reply(struct VGuest *g, uint8_t *out,
                           const uint8_t *req) {
    /* req points at the ARP payload of a request addressed to us. */
    uint8_t a[28];
    vg_wr16(a + 0, 1);
    vg_wr16(a + 2, 0x0800);
    a[4] = 6; a[5] = 4;
    vg_wr16(a + 6, 2);                 /* REPLY */
    memcpy(a + 8, g->mac, 6);
    vg_wr32(a + 14, VG_IP_GUEST);
    memcpy(a + 18, req + 8, 6);        /* back to the requester */
    vg_wr32(a + 24, vg_rd32(req + 14));
    return vg_eth(g, out, 0x0806, req + 8, a, sizeof(a));
}

size_t vg_build_ipv4(struct VGuest *g, uint8_t *out, uint8_t proto,
                     uint32_t src, uint32_t dst,
                     const void *l4, size_t l4len) {
    uint8_t ip[20 + 1500];
    if (l4len > 1500) return 0;
    ip[0] = 0x45; ip[1] = 0;
    vg_wr16(ip + 2, (uint16_t)(20 + l4len));
    static uint16_t idc = 1;
    vg_wr16(ip + 4, idc++);
    vg_wr16(ip + 6, 0);
    ip[8] = 64; ip[9] = proto;
    vg_wr16(ip + 10, 0);
    vg_wr32(ip + 12, src);
    vg_wr32(ip + 16, dst);
    vg_wr16(ip + 10, vg_cksum_fin(vg_cksum(0, ip, 20)));
    if (l4len) memcpy(ip + 20, l4, l4len);
    return vg_eth(g, out, 0x0800, g->gw_mac, ip, 20 + l4len);
}

static uint16_t vg_l4_cksum(uint32_t src, uint32_t dst, uint8_t proto,
                            const uint8_t *l4, size_t len) {
    uint8_t ph[12];
    vg_wr32(ph + 0, src);
    vg_wr32(ph + 4, dst);
    ph[8] = 0; ph[9] = proto;
    vg_wr16(ph + 10, (uint16_t)len);
    return vg_cksum_fin(vg_cksum(vg_cksum(0, ph, 12), l4, len));
}

size_t vg_tcp(struct VGuest *g, uint8_t *out, VConn *c, uint8_t flags,
              uint32_t seq, uint32_t ack, const void *data, size_t dlen) {
    uint8_t t[20 + 1500];
    if (dlen > 1460) dlen = 1460;
    memset(t, 0, 20);
    vg_wr16(t + 0, c->lport);
    vg_wr16(t + 2, c->rport);
    vg_wr32(t + 4, seq);
    vg_wr32(t + 8, ack);
    t[12] = (5 << 4);                  /* data offset 5 words, no options */
    t[13] = flags;
    vg_wr16(t + 14, 65535);            /* our advertised window */
    vg_wr16(t + 16, 0);
    vg_wr16(t + 18, 0);
    if (dlen) memcpy(t + 20, data, dlen);
    vg_wr16(t + 16, vg_l4_cksum(c->lip, c->rip, 6, t, 20 + dlen));
    return vg_build_ipv4(g, out, 6, c->lip, c->rip, t, 20 + dlen);
}

size_t vg_udp(struct VGuest *g, uint8_t *out, uint32_t src, uint32_t dst,
              uint16_t sport, uint16_t dport, const void *payload, size_t plen) {
    uint8_t u[8 + 1472];
    if (plen > 1472) return 0;
    vg_wr16(u + 0, sport);
    vg_wr16(u + 2, dport);
    vg_wr16(u + 4, (uint16_t)(8 + plen));
    vg_wr16(u + 6, 0);
    if (plen) memcpy(u + 8, payload, plen);
    vg_wr16(u + 6, vg_l4_cksum(src, dst, 17, u, 8 + plen));
    return vg_build_ipv4(g, out, 17, src, dst, u, 8 + plen);
}

size_t vg_icmp_echo(struct VGuest *g, uint8_t *out, uint32_t src, uint32_t dst,
                    uint16_t id, uint16_t seq, const void *payload, size_t plen) {
    uint8_t ic[8 + 1400];
    if (plen > 1400) return 0;
    ic[0] = 8; ic[1] = 0;              /* echo request */
    vg_wr16(ic + 2, 0);
    vg_wr16(ic + 4, id);
    vg_wr16(ic + 6, seq);
    if (plen) memcpy(ic + 8, payload, plen);
    vg_wr16(ic + 2, vg_cksum_fin(vg_cksum(0, ic, 8 + plen)));
    return vg_build_ipv4(g, out, 1, src, dst, ic, 8 + plen);
}

size_t vg_dns_query_a(struct VGuest *g, uint8_t *out, uint32_t src,
                      uint16_t sport, uint16_t txid, const char *name) {
    uint8_t q[512];
    memset(q, 0, 12);
    vg_wr16(q + 0, txid);
    vg_wr16(q + 2, 0x0100);            /* RD */
    vg_wr16(q + 4, 1);                 /* QDCOUNT */
    size_t p = 12;
    const char *s = name;
    while (*s) {
        const char *dot = strchr(s, '.');
        size_t n = dot ? (size_t)(dot - s) : strlen(s);
        if (n == 0 || n > 63 || p + n + 1 >= sizeof(q) - 5) return 0;
        q[p++] = (uint8_t)n;
        memcpy(q + p, s, n);
        p += n;
        s = dot ? dot + 1 : s + n;
    }
    q[p++] = 0;
    vg_wr16(q + p, 1);                 /* QTYPE A     */
    vg_wr16(q + p + 2, 1);             /* QCLASS IN   */
    p += 4;
    return vg_udp(g, out, src, VG_IP_DNS, sport, 53, q, p);
}

/* ---- TCP responder ---- */

static uint32_t vg_iss(void) {
    static uint32_t seq = 0x10000;
    seq += 0x01010101u;
    return seq;
}

static void vg_send(VGuest *g, struct UserNet *un, vg_emit_fn emit,
                    const uint8_t *frame, size_t len) {
    (void)un;
    emit(un, frame, len);
}

/* Flush as much of the outbound queue as the peer's window and our own MSS
 * allow. Called after every ACK we receive and from the pump, so a stalled
 * window resumes without any fixed retransmit timer. */
static void vg_tcp_flush(VGuest *g, struct UserNet *un, vg_emit_fn emit) {
    VConn *c = &g->conn;
    if (c->state != VG_ESTABLISHED && c->state != VG_FIN_WAIT &&
        c->state != VG_CLOSE_WAIT)
        return;
    uint8_t frame[VG_MAX_FRAME];
    int guard = 0;
    while (c->txq_off < c->txq_len && guard++ < 512) {
        uint32_t avail = c->peer_wnd > c->unacked ? c->peer_wnd - c->unacked : 0;
        if (!avail) break;
        uint32_t chunk = c->txq_len - c->txq_off;
        if (chunk > c->mss) chunk = c->mss;
        if (chunk > avail) chunk = avail;
        size_t n = vg_tcp(g, frame, c, 0x18 /* PSH|ACK */, c->snd_nxt,
                          c->rcv_nxt, c->txq + c->txq_off, chunk);
        if (!n) break;
        vg_send(g, un, emit, frame, n);
        c->snd_nxt += chunk;
        c->unacked += chunk;
        c->txq_off += chunk;
    }
    if (c->txq_off == c->txq_len) { c->txq_off = c->txq_len = 0; }
}

static void vg_tcp_queue(VGuest *g, const void *data, size_t len) {
    VConn *c = &g->conn;
    if (c->txq_len + len > VG_CONN_BUF) len = VG_CONN_BUF - c->txq_len;
    memcpy(c->txq + c->txq_len, data, len);
    c->txq_len += (uint32_t)len;
}

void vg_tcp_connect(VGuest *g, struct UserNet *un, vg_emit_fn emit,
                    uint32_t dst_ip, uint16_t dst_port, uint16_t src_port) {
    VConn *c = &g->conn;
    memset(c, 0, sizeof(*c));
    c->active = true;
    c->lip = VG_IP_GUEST; c->rip = dst_ip;
    c->lport = src_port;  c->rport = dst_port;
    c->mss = 1460;
    c->peer_wnd = 65535;
    c->iss = vg_iss();
    c->snd_una = c->iss;
    c->snd_nxt = c->iss + 1;
    c->state = VG_SYN_SENT;
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_tcp(g, frame, c, 0x02 /* SYN */, c->iss, 0, NULL, 0);
    vg_send(g, un, emit, frame, n);
}

void vg_tcp_send(VGuest *g, struct UserNet *un, vg_emit_fn emit,
                 const void *data, size_t len) {
    vg_tcp_queue(g, data, len);
    vg_tcp_flush(g, un, emit);
}

void vg_tcp_close(VGuest *g, struct UserNet *un, vg_emit_fn emit) {
    VConn *c = &g->conn;
    if (!c->active || c->fin_sent) return;
    vg_tcp_flush(g, un, emit);
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_tcp(g, frame, c, 0x19 /* FIN|PSH|ACK */, c->snd_nxt,
                      c->rcv_nxt, NULL, 0);
    vg_send(g, un, emit, frame, n);
    c->snd_nxt++;
    c->fin_sent = true;
    c->state = c->fin_rcvd ? VG_LAST_ACK : VG_FIN_WAIT;
}

static void vg_tcp_input(VGuest *g, struct UserNet *un, vg_emit_fn emit,
                         const uint8_t *ip, size_t iplen) {
    size_t ihl = (size_t)(ip[0] & 0xf) * 4;
    if (iplen < ihl + 20) return;
    const uint8_t *t = ip + ihl;
    size_t tlen = iplen - ihl;
    uint16_t sport = vg_rd16(t), dport = vg_rd16(t + 2);
    uint32_t seq = vg_rd32(t + 4), ack = vg_rd32(t + 8);
    size_t toff = (size_t)(t[12] >> 4) * 4;
    uint8_t flags = t[13];
    uint16_t win = vg_rd16(t + 14);
    if (tlen < toff) return;
    const uint8_t *data = t + toff;
    size_t dlen = tlen - toff;

    VConn *c = &g->conn;
    uint8_t frame[VG_MAX_FRAME];

    if (flags & 0x04) { c->rst_seen = true; c->state = VG_DONE; return; }

    if (!c->active) {
        /* The backend is actively opening (host forward). Answer the SYN. */
        if (!(flags & 0x02) || (flags & 0x10)) return;
        c->active = true;
        c->lip = vg_rd32(ip + 16);
        c->rip = vg_rd32(ip + 12);
        c->lport = dport;
        c->rport = sport;
        c->rcv_nxt = seq + 1;
        c->iss = vg_iss();
        c->snd_una = c->iss;
        c->snd_nxt = c->iss + 1;
        c->mss = 1460;
        c->peer_wnd = win ? win : 65535;
        c->state = VG_SYN_RCVD;
        /* Parse MSS from the SYN options so we never exceed what libslirp
         * told us it can accept. */
        for (size_t p = 20; p + 1 < toff; ) {
            uint8_t kind = t[p];
            if (kind == 0) break;
            if (kind == 1) { p++; continue; }
            uint8_t olen = t[p + 1];
            if (olen < 2 || p + olen > toff) break;
            if (kind == 2 && olen == 4) {
                uint16_t m = vg_rd16(t + p + 2);
                if (m >= 64 && m <= 1460) c->mss = m;
            }
            p += olen;
        }
        size_t n = vg_tcp(g, frame, c, 0x12 /* SYN|ACK */, c->iss, c->rcv_nxt,
                          NULL, 0);
        vg_send(g, un, emit, frame, n);
        return;
    }

    if (c->rport != sport || c->lport != dport) return;
    if (win) c->peer_wnd = win;

    switch (c->state) {
    case VG_SYN_SENT:
        if ((flags & 0x12) == 0x12) {          /* SYN + ACK */
            c->rcv_nxt = seq + 1;
            c->snd_una = ack;
            c->unacked = c->snd_nxt - c->snd_una;
            c->state = VG_ESTABLISHED;
            size_t n = vg_tcp(g, frame, c, 0x10 /* ACK */, c->snd_nxt,
                              c->rcv_nxt, NULL, 0);
            vg_send(g, un, emit, frame, n);
        }
        break;
    case VG_SYN_RCVD:
        if (flags & 0x10) {
            c->snd_una = ack;
            c->unacked = c->snd_nxt - c->snd_una;
            c->state = VG_ESTABLISHED;
        }
        break;
    default:
        break;
    }

    /* Established-path ACK accounting (also applies right after the handshake
     * completed above). */
    if (c->state == VG_ESTABLISHED || c->state == VG_FIN_WAIT ||
        c->state == VG_CLOSE_WAIT || c->state == VG_LAST_ACK) {
        if (flags & 0x10) {
            /* advance snd_una; ack may cover data we sent */
            int32_t delta = (int32_t)(ack - c->snd_una);
            if (delta > 0) {
                c->snd_una = ack;
                c->unacked = (uint32_t)((int32_t)c->unacked - delta);
            }
        }
    }

    /* Payload. The virtual link cannot reorder, so an in-order check is
     * sufficient and an out-of-order segment is a genuine protocol error we
     * want a test to see rather than silently absorb. */
    if (dlen && (c->state == VG_ESTABLISHED || c->state == VG_FIN_WAIT)) {
        if (seq == c->rcv_nxt) {
            uint32_t room = VG_CONN_BUF - c->rxlen;
            uint32_t take = dlen < room ? (uint32_t)dlen : room;
            memcpy(c->rx + c->rxlen, data, take);
            c->rxlen += take;
            g->bytes_received += take;
            c->rcv_nxt += (uint32_t)dlen;
            size_t n = vg_tcp(g, frame, c, 0x10, c->snd_nxt, c->rcv_nxt,
                              NULL, 0);
            vg_send(g, un, emit, frame, n);
            if (c->echo_on) {
                vg_tcp_queue(g, data, take);
                vg_tcp_flush(g, un, emit);
            }
        }
    } else if (!dlen && (c->state == VG_ESTABLISHED || c->state == VG_FIN_WAIT)) {
        /* A bare ACK may still have opened the window: try to drain. */
        vg_tcp_flush(g, un, emit);
    }

    if (flags & 0x01) {                        /* FIN */
        c->fin_rcvd = true;
        c->rcv_nxt++;
        size_t n = vg_tcp(g, frame, c, 0x10, c->snd_nxt, c->rcv_nxt, NULL, 0);
        vg_send(g, un, emit, frame, n);
        if (!c->fin_sent) {
            vg_tcp_flush(g, un, emit);
            n = vg_tcp(g, frame, c, 0x19 /* FIN|PSH|ACK */, c->snd_nxt,
                       c->rcv_nxt, NULL, 0);
            vg_send(g, un, emit, frame, n);
            c->snd_nxt++;
            c->fin_sent = true;
            c->state = VG_LAST_ACK;
        } else {
            c->state = VG_DONE;
        }
    }

    /* Our FIN acknowledged => fully closed. */
    if (c->fin_sent && c->fin_rcvd &&
        (int32_t)(ack - c->snd_nxt) >= 0 &&
        (c->state == VG_LAST_ACK || c->state == VG_FIN_WAIT)) {
        c->state = VG_DONE;
    }
}

/* ---- UDP / ICMP / IPv6 intake ---- */

static void vg_udp_input(VGuest *g, const uint8_t *ip, size_t iplen) {
    size_t ihl = (size_t)(ip[0] & 0xf) * 4;
    if (iplen < ihl + 8) return;
    const uint8_t *u = ip + ihl;
    uint16_t sport = vg_rd16(u), dport = vg_rd16(u + 2);
    uint16_t ulen = vg_rd16(u + 4);
    if (ulen < 8 || ihl + ulen > iplen) ulen = (uint16_t)(iplen - ihl);
    if (sport == 53 || dport == 53) g->dns_responses++;
    uint16_t plen = (uint16_t)(ulen - 8);
    g->bytes_received += plen;

    VDatagram *d = &g->dgram[g->dgram_next];
    g->dgram_next = (g->dgram_next + 1) % VG_DGRAM_SLOTS;
    g->dgram_count++;
    d->valid = true;
    d->src_ip = vg_rd32(ip + 12);
    d->dst_ip = vg_rd32(ip + 16);
    d->sport = sport;
    d->dport = dport;
    d->len = plen > sizeof(d->payload) ? (uint16_t)sizeof(d->payload) : plen;
    memcpy(d->payload, u + 8, d->len);
}

size_t vg_udp_reply(struct VGuest *g, uint8_t *out, const VDatagram *d,
                    const void *payload, size_t plen) {
    if (!d || !d->valid) return 0;
    return vg_udp(g, out, d->dst_ip, d->src_ip, d->dport, d->sport,
                  payload, plen);
}

const VDatagram *vg_dgram_last(const VGuest *g, uint16_t dport) {
    for (uint32_t i = 0; i < VG_DGRAM_SLOTS; i++) {
        uint32_t idx = (g->dgram_next + VG_DGRAM_SLOTS - 1 - i) % VG_DGRAM_SLOTS;
        const VDatagram *d = &g->dgram[idx];
        if (d->valid && d->dport == dport) return d;
    }
    return NULL;
}

static void vg_icmp_input(VGuest *g, const uint8_t *ip, size_t iplen) {
    size_t ihl = (size_t)(ip[0] & 0xf) * 4;
    if (iplen < ihl + 8) return;
    const uint8_t *ic = ip + ihl;
    if (ic[0] == 0 && ic[1] == 0) g->icmp_echo_replies++;
    else if (ic[0] == 3 && ic[1] == 3) g->icmp_unreach_seen++;
    else if (ic[0] == 3 && ic[1] == 13) g->icmp_admin_prohib_seen++;
}

/* ---- IPv6 / NDP ---- */

const uint8_t VG_IP6_GUEST[16] = {0xfd,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0x15};
const uint8_t VG_IP6_GW[16]    = {0xfd,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0x02};

/* libslirp derives the gateway's link-layer address from special_ethaddr plus
 * the low 4 bytes of the IPv6 address it is answering for. */
static void vg_ip6_gw_mac(uint8_t out[6], const uint8_t addr[16]) {
    out[0] = 0x52; out[1] = 0x55;
    memcpy(out + 2, addr + 12, 4);
}

static uint16_t vg_ip6_l4_cksum(const uint8_t src[16], const uint8_t dst[16],
                                uint8_t nh, const uint8_t *l4, size_t len) {
    uint32_t sum = 0;
    sum = vg_cksum(sum, src, 16);
    sum = vg_cksum(sum, dst, 16);
    uint8_t ph[8];
    vg_wr32(ph, (uint32_t)len);
    ph[4] = ph[5] = ph[6] = 0;
    ph[7] = nh;
    sum = vg_cksum(sum, ph, 8);
    sum = vg_cksum(sum, l4, len);
    return vg_cksum_fin(sum);
}

static size_t vg_build_ipv6_hl(struct VGuest *g, uint8_t *out, uint8_t nh,
                               const uint8_t src[16], const uint8_t dst[16],
                               const void *l4, size_t l4len, uint8_t hl);

static size_t vg_build_ipv6(struct VGuest *g, uint8_t *out, uint8_t nh,
                            const uint8_t src[16], const uint8_t dst[16],
                            const void *l4, size_t l4len) {
    return vg_build_ipv6_hl(g, out, nh, src, dst, l4, l4len, 64);
}

static size_t vg_build_ipv6_hl(struct VGuest *g, uint8_t *out, uint8_t nh,
                               const uint8_t src[16], const uint8_t dst[16],
                               const void *l4, size_t l4len, uint8_t hl) {
    uint8_t ip6[40 + 1500];
    if (l4len > 1500) return 0;
    memset(ip6, 0, 40);
    ip6[0] = 0x60;
    vg_wr32(ip6, 0x60000000u);
    vg_wr16(ip6 + 4, (uint16_t)l4len);
    ip6[6] = nh;
    ip6[7] = hl;
    memcpy(ip6 + 8, src, 16);
    memcpy(ip6 + 24, dst, 16);
    if (l4len) memcpy(ip6 + 40, l4, l4len);
    uint8_t dmac[6];
    vg_ip6_gw_mac(dmac, dst);
    return vg_eth(g, out, 0x86dd, dmac, ip6, 40 + l4len);
}

size_t vg_icmp6_echo(struct VGuest *g, uint8_t *out, const uint8_t src[16],
                     const uint8_t dst[16], uint16_t id, uint16_t seq,
                     const void *payload, size_t plen) {
    uint8_t ic[8 + 1400];
    if (plen > 1400) return 0;
    ic[0] = 128; ic[1] = 0;
    vg_wr16(ic + 2, 0);
    vg_wr16(ic + 4, id);
    vg_wr16(ic + 6, seq);
    if (plen) memcpy(ic + 8, payload, plen);
    vg_wr16(ic + 2, vg_ip6_l4_cksum(src, dst, 58, ic, 8 + plen));
    return vg_build_ipv6(g, out, 58, src, dst, ic, 8 + plen);
}

size_t vg_tcp6_syn(struct VGuest *g, uint8_t *out, const uint8_t src[16],
                   const uint8_t dst[16], uint16_t sport, uint16_t dport,
                   uint32_t seq) {
    uint8_t t[20];
    memset(t, 0, sizeof(t));
    vg_wr16(t + 0, sport);
    vg_wr16(t + 2, dport);
    vg_wr32(t + 4, seq);
    vg_wr32(t + 8, 0);
    t[12] = (5 << 4);
    t[13] = 0x02;                       /* SYN */
    vg_wr16(t + 14, 65535);
    vg_wr16(t + 16, vg_ip6_l4_cksum(src, dst, 6, t, 20));
    return vg_build_ipv6(g, out, 6, src, dst, t, 20);
}

static size_t vg_ndp_na(struct VGuest *g, uint8_t *out, const uint8_t src[16],
                        const uint8_t dst[16], const uint8_t target[16],
                        bool solicited) {
    uint8_t ic[8 + 16 + 8];
    memset(ic, 0, sizeof(ic));
    ic[0] = 136; ic[1] = 0;             /* Neighbor Advertisement */
    vg_wr16(ic + 2, 0);
    /* R S O flags in the top 3 bits of the 4-byte field at +4. */
    ic[4] = (uint8_t)((solicited ? 0x40 : 0x00) | 0x20);   /* Solicited+Override */
    memcpy(ic + 8, target, 16);
    ic[24] = 2;                          /* Target Link-Layer Address option */
    ic[25] = 1;                          /* 8 bytes */
    memcpy(ic + 26, g->mac, 6);
    vg_wr16(ic + 2, vg_ip6_l4_cksum(src, dst, 58, ic, sizeof(ic)));
    /* RFC 4861 requires hop limit 255 on NDP messages; libslirp enforces it
     * (ip6_icmp.c ndp_input checks ip->ip_hl == 255) and silently ignores
     * anything else, so an NA sent with an ordinary hop limit never teaches
     * libslirp our link-layer address. */
    return vg_build_ipv6_hl(g, out, 58, src, dst, ic, sizeof(ic), 255);
}

size_t vg_ndp_advertise_self(struct VGuest *g, uint8_t *out) {
    /* Unsolicited NA to the all-nodes multicast group: libslirp records our
     * link-layer address for the target from this (ip6_icmp.c ndp_table_add). */
    static const uint8_t allnodes[16] = {0xff,0x02,0,0,0,0,0,0,0,0,0,0,0,0,0,0x01};
    return vg_ndp_na(g, out, VG_IP6_GUEST, allnodes, VG_IP6_GUEST, false);
}

void vg_ipv6_boot(struct VGuest *g, struct UserNet *un, vg_emit_fn emit) {
    uint8_t out[VG_MAX_FRAME];
    size_t n = vg_ndp_advertise_self(g, out);
    emit(un, out, n);
    g->ip6_ready = true;
}

static void vg_ndp_input(VGuest *g, struct UserNet *un, vg_emit_fn emit,
                         const uint8_t *ip6, size_t iplen) {
    if (iplen < 40 + 8) return;
    const uint8_t *ic = ip6 + 40;
    if (ic[0] == 135) {                  /* Neighbor Solicitation */
        g->ndp_ns_seen++;
        if (iplen < 40 + 24) return;
        const uint8_t *target = ic + 8;
        if (memcmp(target, VG_IP6_GUEST, 16) != 0) return;
        uint8_t out[VG_MAX_FRAME];
        size_t n = vg_ndp_na(g, out, VG_IP6_GUEST, ip6 + 8, target, true);
        g->ndp_na_sent++;
        emit(un, out, n);
    } else if (ic[0] == 129) {
        g->icmp6_echo_replies++;
    } else if (ic[0] == 134) {
        g->ra_seen++;
    } else if (ic[0] == 1 && ic[1] == 1) {
        g->icmp6_admin_prohib_seen++;
    }
}

/* ---- drain everything the backend has delivered ---- */

void vg_drain(VGuest *g, struct UserNet *un, vg_emit_fn emit) {
    while (g->rx_pending) {
        uint32_t slot = g->rx_head;
        g->rx_head = (g->rx_head + 1) % VG_RX_SLOTS;
        g->rx_pending--;
        const uint8_t *f = g->rx[slot];
        size_t len = g->rx_len[slot];
        if (len < 14) continue;
        uint16_t eth = vg_rd16(f + 12);

        if (eth == 0x0806) {                     /* ARP */
            if (len < 14 + 28) continue;
            const uint8_t *a = f + 14;
            uint16_t op = vg_rd16(a + 6);
            if (op == 1) {
                g->arp_requests_seen++;
                if (vg_rd32(a + 24) == VG_IP_GUEST) {
                    uint8_t out[VG_MAX_FRAME];
                    size_t n = vg_arp_reply(g, out, a);
                    g->arp_replies_sent++;
                    vg_send(g, un, emit, out, n);
                }
            } else if (op == 2) {
                g->arp_replies_seen++;
                if (vg_rd32(a + 24) == VG_IP_GUEST) {
                    memcpy(g->gw_mac, a + 8, 6);
                    g->gw_mac_known = true;
                }
            }
            continue;
        }
        if (eth == 0x0800) {                     /* IPv4 */
            const uint8_t *ip = f + 14;
            size_t iplen = len - 14;
            if (iplen < 20) continue;
            size_t tot = vg_rd16(ip + 2);
            if (tot < 20 || tot > iplen) continue;
            switch (ip[9]) {
            case 6:  vg_tcp_input(g, un, emit, ip, tot); break;
            case 17: vg_udp_input(g, ip, tot); break;
            case 1:  vg_icmp_input(g, ip, tot); break;
            default: break;
            }
            continue;
        }
        if (eth == 0x86dd) {
            g->ip6_seen++;
            if (len >= 14 + 40 + 8 && f[14 + 6] == 58)
                vg_ndp_input(g, un, emit, f + 14, len - 14);
            else if (len >= 14 + 40 + 8 && f[14 + 6] == 6)
                g->ip6_seen = g->ip6_seen;   /* TCPv6 counted, no responder here */
            continue;
        }
    }
}

/* ---- pump ---- */

bool vg_pump(VGuest *g, struct UserNet *un, vg_emit_fn emit,
             struct pollfd *host_pf, int host_nfds,
             void (*host_service)(void *), void *host_ctx,
             vg_pred_fn pred, void *ctx, int timeout_ms) {
    int64_t deadline = vg_now_ms() + timeout_ms;
    UserNetWaitFd wfds[512];
    struct pollfd pf[512 + 16];

    for (;;) {
        if (pred && pred(ctx)) return true;
        if (vg_now_ms() >= deadline) return pred ? pred(ctx) : false;

        /* Park on the backend's REAL descriptor set with the REAL interests it
         * asked for — the same USERNET_WAIT_ABI 2 call both runtime wait sites
         * make — plus the test's own host descriptors. This keeps the loop
         * event-driven rather than a fixed sleep, and exercises the wait ABI
         * on every test. */
        UserNetWaitRequest req;
        UserNetWaitResult res;
        memset(&req, 0, sizeof(req));
        memset(&res, 0, sizeof(res));
        req.struct_size = sizeof(req);
        req.abi = USERNET_WAIT_ABI;
        req.capacity = 512;
        req.flags = USERNET_WAIT_F_DUP;
        req.entries = wfds;
        bool have = (usernet_fill_wait(un, &req, &res) == 0);

        int n = 0;
        for (int i = 0; i < host_nfds && n < 16; i++) {
            pf[n].fd = host_pf[i].fd;
            pf[n].events = host_pf[i].events;
            pf[n].revents = 0;
            n++;
        }
        int first_dup = n;
        if (have && !(res.flags & USERNET_WAIT_R_DEAD)) {
            for (uint32_t i = 0; i < res.count && (uint32_t)n < 512 + 16; i++) {
                pf[n].fd = wfds[i].fd;
                pf[n].events = (short)wfds[i].events;
                pf[n].revents = 0;
                n++;
            }
        }

        int tmo = 20;
        if (have && !(res.flags & USERNET_WAIT_R_DEAD) &&
            res.timeout_ms != UINT32_MAX && (int)res.timeout_ms < tmo)
            tmo = (int)res.timeout_ms;
        if (n > 0) poll(pf, (nfds_t)n, tmo);
        else usleep(1000);

        for (int i = first_dup; i < n; i++) if (pf[i].fd >= 0) close(pf[i].fd);

        usernet_poll(un);
        vg_drain(g, un, emit);
        if (host_service) host_service(host_ctx);
    }
}
