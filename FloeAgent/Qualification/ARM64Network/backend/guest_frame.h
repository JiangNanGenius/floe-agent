/* SPDX-License-Identifier: Apache-2.0 */
/* An in-process virtual guest for the usernet/libslirp backend candidate.
 *
 * It speaks ordinary Ethernet over the exact callback contract
 * Source/src/devices/virtio_net.c uses (usernet_input in, usernet_output_fn
 * out), so the backend under test and the seam under test are both the real
 * ones. No VM, no Simulator and no App is involved.
 *
 * What it implements, and why each part is necessary:
 *
 *  - ARP. libslirp addresses guest-bound frames through its own ARP table, so
 *    a probe that never answers ARP for 10.0.2.15 receives nothing at all and
 *    can easily be misread as a protocol failure. This guest both answers the
 *    backend's requests and resolves the gateway itself, exactly as Linux does.
 *  - IPv4/IPv6, TCP, UDP, ICMP and DNS wire encoding with correct checksums.
 *  - A minimal but correct single-connection TCP responder: SYN/SYN-ACK/ACK
 *    handshake, in-order data accept, echo, and FIN half-close in both
 *    directions. No retransmission and no congestion control are needed
 *    because the virtual link is lossless and cannot reorder — the same
 *    property the previous in-tree stack documented for itself.
 *
 * Deliberately NOT implemented: window scaling, SACK, out-of-order recovery
 * and fragmentation. The pinned libslirp 4.9.7 builds with TCP_DO_RFC1323=0
 * and its tcp_dooptions() only honours TCPOPT_MAXSEG, so neither side of this
 * pair has those capabilities. Tests therefore assert real behaviour, not a
 * modern-TCP claim. See HANDOFF.md "Actual TCP capability".
 */
#ifndef GUEST_FRAME_H
#define GUEST_FRAME_H

#include <poll.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct UserNet;

#define VG_MAC_GUEST   { 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }
#define VG_MAX_FRAME   2048
#define VG_RX_SLOTS    256
#define VG_CONN_BUF    (1024u * 1024u)
#define VG_IP_GUEST    0x0a00020fu   /* 10.0.2.15 */
#define VG_IP_GW       0x0a000202u   /* 10.0.2.2  */
#define VG_IP_DNS      0x0a000203u   /* 10.0.2.3  */

typedef enum {
    VG_CLOSED = 0,
    VG_SYN_SENT,     /* we sent SYN, waiting for SYN-ACK   */
    VG_SYN_RCVD,     /* we answered a SYN, waiting for ACK */
    VG_ESTABLISHED,
    VG_FIN_WAIT,     /* we sent FIN                        */
    VG_CLOSE_WAIT,   /* peer FIN received, ours not sent   */
    VG_LAST_ACK,
    VG_DONE
} VConnState;

typedef struct VConn {
    bool      active;
    uint32_t  lip, rip;          /* host order */
    uint16_t  lport, rport;
    uint32_t  iss, snd_una, snd_nxt, rcv_nxt;
    uint16_t  mss;
    uint16_t  peer_wnd;
    VConnState state;
    bool      fin_sent, fin_rcvd, rst_seen;
    /* bytes the peer sent us, and the bytes we still owe back */
    uint8_t   rx[VG_CONN_BUF];
    uint32_t  rxlen;
    uint32_t  echoed;            /* bytes of rx already echoed back */
    bool      echo_on;           /* echo every received byte back */
    /* Pending outbound bytes, flushed as the peer's window allows. */
    uint8_t   txq[VG_CONN_BUF];
    uint32_t  txq_len, txq_off;
    uint32_t  unacked;           /* snd_nxt - snd_una, in flight */
} VConn;

/* A UDP datagram the backend delivered to the guest, kept so a test can reply
 * to the exact addresses libslirp presented (which is how a real guest would). */
typedef struct VDatagram {
    bool     valid;
    uint32_t src_ip, dst_ip;      /* host order */
    uint16_t sport, dport;
    uint16_t len;
    uint8_t  payload[1500];
} VDatagram;

#define VG_DGRAM_SLOTS 16

typedef struct VGuest {
    uint8_t  mac[6];
    uint8_t  gw_mac[6];
    bool     gw_mac_known;

    /* Frames the backend delivered to us. */
    uint8_t  rx[VG_RX_SLOTS][VG_MAX_FRAME];
    uint32_t rx_len[VG_RX_SLOTS];
    uint32_t rx_count;           /* total ever delivered   */
    uint32_t rx_head;            /* next unconsumed slot   */
    uint32_t rx_pending;         /* unconsumed slots       */
    uint32_t rx_refused;         /* times we simulated a full ring */

    /* false makes the output callback refuse frames, which is how the tests
     * exercise the backend's bounded deferred-TX backpressure. */
    bool     accept_rx;

    VConn    conn;

    /* counters for assertions */
    uint32_t arp_requests_seen, arp_replies_seen, arp_replies_sent;
    uint32_t icmp_echo_replies, icmp_unreach_seen, icmp_admin_prohib_seen;
    uint32_t dns_responses;
    VDatagram dgram[VG_DGRAM_SLOTS];
    uint32_t dgram_count;          /* total datagrams captured */
    uint32_t dgram_next;           /* ring write index         */
    uint32_t ip6_seen;
    uint32_t icmp6_echo_replies;
    uint32_t icmp6_admin_prohib_seen;
    uint32_t ndp_ns_seen, ndp_na_sent;
    uint32_t ra_seen;
    bool     ip6_ready;        /* an unsolicited NA has been sent */
    uint64_t bytes_received;
} VGuest;

void vg_init(VGuest *g);

/* Deliver one backend-produced frame into the guest. Returns false when the
 * simulated RX ring is full (accept_rx == false). */
bool vg_output(void *opaque, const uint8_t *frame, size_t len);

/* Parse and react to every frame the backend has delivered so far: ARP, TCP,
 * UDP, ICMP, IPv6. Emitted responses are returned through `emit`. */
typedef void (*vg_emit_fn)(struct UserNet *un, const uint8_t *frame, size_t len);
void vg_drain(struct VGuest *g, struct UserNet *un, vg_emit_fn emit);

/* ---- frame builders (return the frame length) ---- */
size_t vg_eth(struct VGuest *g, uint8_t *out, uint16_t ethertype,
              const uint8_t *dst_mac, const void *payload, size_t len);
size_t vg_arp_request(struct VGuest *g, uint8_t *out, uint32_t target_ip);
size_t vg_build_ipv4(struct VGuest *g, uint8_t *out, uint8_t proto,
                     uint32_t src, uint32_t dst,
                     const void *l4, size_t l4len);
size_t vg_tcp(struct VGuest *g, uint8_t *out, VConn *c, uint8_t flags,
              uint32_t seq, uint32_t ack, const void *data, size_t dlen);
size_t vg_udp(struct VGuest *g, uint8_t *out, uint32_t src, uint32_t dst,
              uint16_t sport, uint16_t dport, const void *payload, size_t plen);
size_t vg_icmp_echo(struct VGuest *g, uint8_t *out, uint32_t src, uint32_t dst,
                    uint16_t id, uint16_t seq, const void *payload, size_t plen);
size_t vg_dns_query_a(struct VGuest *g, uint8_t *out, uint32_t src,
                      uint16_t sport, uint16_t txid, const char *name);
/* Reply to a captured datagram, swapping addresses and ports. */
size_t vg_udp_reply(struct VGuest *g, uint8_t *out, const VDatagram *d,
                    const void *payload, size_t plen);
/* Most recent captured datagram addressed to `dport`, or NULL. */
const VDatagram *vg_dgram_last(const VGuest *g, uint16_t dport);

/* ---- IPv6 / NDP ---- */
/* fd00::/64 is libslirp's own default guest prefix; fd00::2 is its host. */
extern const uint8_t VG_IP6_GUEST[16];
extern const uint8_t VG_IP6_GW[16];
/* Build and emit an unsolicited Neighbor Advertisement for our own address so
 * libslirp learns our link-layer address without waiting for its own NS. */
size_t vg_ndp_advertise_self(struct VGuest *g, uint8_t *out);
size_t vg_icmp6_echo(struct VGuest *g, uint8_t *out, const uint8_t src[16],
                     const uint8_t dst[16], uint16_t id, uint16_t seq,
                     const void *payload, size_t plen);
size_t vg_tcp6_syn(struct VGuest *g, uint8_t *out, const uint8_t src[16],
                   const uint8_t dst[16], uint16_t sport, uint16_t dport,
                   uint32_t seq);
/* Mark the guest IPv6-ready (emits the unsolicited NA). */
void vg_ipv6_boot(struct VGuest *g, struct UserNet *un, vg_emit_fn emit);

/* ---- TCP responder helpers ---- */
void vg_tcp_connect(VGuest *g, struct UserNet *un, vg_emit_fn emit,
                    uint32_t dst_ip, uint16_t dst_port, uint16_t src_port);
void vg_tcp_send(VGuest *g, struct UserNet *un, vg_emit_fn emit,
                 const void *data, size_t len);
void vg_tcp_close(VGuest *g, struct UserNet *un, vg_emit_fn emit);

/* ---- pump: run the backend and the guest until `done` or timeout ---- */
typedef bool (*vg_pred_fn)(void *ctx);
/* Drives usernet_poll() + guest processing + optional host-socket servicing
 * until pred(ctx) is true or timeout_ms elapses. Returns pred's last value.
 * `host_pollfds`/`host_nfds` let a test include its own real host descriptors
 * (a listening socket, a connected client) in the same wait, so the loop makes
 * progress on both sides without any fixed sleep. */
bool vg_pump(struct VGuest *g, struct UserNet *un, vg_emit_fn emit,
             struct pollfd *host_pf, int host_nfds,
             void (*host_service)(void *), void *host_ctx,
             vg_pred_fn pred, void *ctx, int timeout_ms);

/* ---- wire parsing helpers used by the tests ---- */
uint16_t vg_rd16(const uint8_t *p);
uint32_t vg_rd32(const uint8_t *p);
void     vg_wr16(uint8_t *p, uint16_t v);
void     vg_wr32(uint8_t *p, uint32_t v);
uint32_t vg_cksum(uint32_t sum, const uint8_t *p, size_t n);
uint16_t vg_cksum_fin(uint32_t sum);

#endif
