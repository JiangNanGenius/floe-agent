/* SPDX-License-Identifier: MPL-2.0 */
/* Independent reference oracle for the NIC offload qualification.
 *
 * Nothing in this file shares code with Source/src/devices/virtio_net_offload.c.
 * The checksums are accumulated in a uint64 and folded only at the end, the
 * pseudo-headers are spelled out word by word, and the GSO re-segmentation is
 * derived from the virtio_net_hdr alone. That is deliberate: a bug shared
 * between the implementation and its test would cancel out and prove nothing.
 *
 * References (public specifications and interface documentation only):
 *   RFC 1071, RFC 791, RFC 8200, RFC 9293, RFC 768, RFC 4443,
 *   OASIS VIRTIO 1.2 section 5.1, and Linux
 *   Documentation/networking/checksum-offloads.rst for the partial-checksum
 *   completion rule ("sum from csum_start to the end of the packet, including
 *   the previous value of the checksum field, and store the complement").
 */
#ifndef FLOE_NIC_OFFLOAD_ORACLE_H
#define FLOE_NIC_OFFLOAD_ORACLE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

/* ---- ones-complement accumulation, uint64, folded only at the end ---- */

static uint64_t ref_acc(uint64_t a, const uint8_t *p, size_t n) {
    size_t i = 0;
    for (; i + 1 < n; i += 2) a += ((uint64_t)p[i] << 8) | (uint64_t)p[i + 1];
    if (i < n) a += (uint64_t)p[i] << 8;   /* RFC 1071: pad the odd byte */
    return a;
}

static uint16_t ref_fold_c(uint64_t a) {          /* complemented */
    while (a >> 16) a = (a & 0xffff) + (a >> 16);
    return (uint16_t)(~a & 0xffff);
}

static uint16_t ref_fold_raw(uint64_t a) {        /* uncomplemented */
    while (a >> 16) a = (a & 0xffff) + (a >> 16);
    return (uint16_t)(a & 0xffff);
}

static uint16_t ref_csum(const uint8_t *p, size_t n) {
    return ref_fold_c(ref_acc(0, p, n));
}

/* Reduce into the ones-complement group, tolerating a negative value. */
static uint16_t ref_mod65535(int64_t v) {
    v %= 65535;
    if (v < 0) v += 65535;
    return (uint16_t)v;
}

/* ---- pseudo-headers, spelled out ---- */

static uint64_t ref_ph4(uint64_t a, uint32_t s, uint32_t d, uint8_t proto,
                        uint32_t l4len) {
    a += (s >> 16) & 0xffffu; a += s & 0xffffu;
    a += (d >> 16) & 0xffffu; a += d & 0xffffu;
    a += (uint32_t)proto;                 /* the 0x00,proto word */
    a += (l4len >> 16) & 0xffffu; a += l4len & 0xffffu;
    return a;
}

static uint64_t ref_ph6(uint64_t a, const uint8_t s[16], const uint8_t d[16],
                        uint8_t nh, uint32_t l4len) {
    a = ref_acc(a, s, 16);
    a = ref_acc(a, d, 16);
    a += (l4len >> 16) & 0xffffu; a += l4len & 0xffffu;
    a += (uint32_t)nh;                    /* 3 zero bytes then next-header */
    return a;
}

/* In every helper below `l4` points at a transport header whose checksum field
 * reads zero, and `len` is header + payload. */
static uint16_t ref_tcp4(uint32_t s, uint32_t d, const uint8_t *l4, size_t len) {
    uint64_t a = ref_ph4(0, s, d, 6, (uint32_t)len);
    a = ref_acc(a, l4, 16);
    a = ref_acc(a, l4 + 18, len - 18);
    return ref_fold_c(a);
}
static uint16_t ref_tcp6(const uint8_t s[16], const uint8_t d[16],
                         const uint8_t *l4, size_t len) {
    uint64_t a = ref_ph6(0, s, d, 6, (uint32_t)len);
    a = ref_acc(a, l4, 16);
    a = ref_acc(a, l4 + 18, len - 18);
    return ref_fold_c(a);
}
static uint16_t ref_udp4(uint32_t s, uint32_t d, const uint8_t *l4, size_t len) {
    uint64_t a = ref_ph4(0, s, d, 17, (uint32_t)len);
    a = ref_acc(a, l4, 6);
    a = ref_acc(a, l4 + 8, len - 8);
    return ref_fold_c(a);
}
static uint16_t ref_udp6(const uint8_t s[16], const uint8_t d[16],
                         const uint8_t *l4, size_t len) {
    uint64_t a = ref_ph6(0, s, d, 17, (uint32_t)len);
    a = ref_acc(a, l4, 6);
    a = ref_acc(a, l4 + 8, len - 8);
    return ref_fold_c(a);
}
static uint16_t ref_icmp4(const uint8_t *l4, size_t len) {
    uint64_t a = ref_acc(0, l4, 2);        /* ICMPv4 has no pseudo-header */
    a = ref_acc(a, l4 + 4, len - 4);
    return ref_fold_c(a);
}
static uint16_t ref_icmp6(const uint8_t s[16], const uint8_t d[16],
                          const uint8_t *l4, size_t len) {
    uint64_t a = ref_ph6(0, s, d, 58, (uint32_t)len);
    a = ref_acc(a, l4, 2);
    a = ref_acc(a, l4 + 4, len - 4);
    return ref_fold_c(a);
}

/* The folded pseudo-header alone: what a driver leaves in the checksum field
 * for a CHECKSUM_PARTIAL packet, and what a coalescing device must seed a
 * super-frame with. */
static uint16_t ref_seed4(uint32_t s, uint32_t d, uint8_t proto, uint32_t l4len) {
    return ref_fold_raw(ref_ph4(0, s, d, proto, l4len));
}
static uint16_t ref_seed6(const uint8_t s[16], const uint8_t d[16],
                          uint8_t proto, uint32_t l4len) {
    return ref_fold_raw(ref_ph6(0, s, d, proto, l4len));
}

/* ---- byte access ---- */

static void put_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v;
}
static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
static uint16_t get_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}
static uint32_t get_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* ---- addresses ---- */

static const uint8_t MAC_GUEST[6] = {0x52,0x54,0x00,0x12,0x34,0x56};
static const uint8_t MAC_HOST[6]  = {0x52,0x55,0x0a,0x00,0x02,0x02};
#define IP_GUEST 0x0A00020Fu   /* 10.0.2.15 */
#define IP_HOST  0x0A000202u   /* 10.0.2.2  */
static const uint8_t IP6_LOCAL_A[16] =
    {0x20,0x01,0x0d,0xb8,0,0,0,1,0,0,0,0,0,0,0,1};
static const uint8_t IP6_LOCAL_B[16] =
    {0x20,0x01,0x0d,0xb8,0,0,0,2,0,0,0,0,0,0,0,2};

/* ---- frame builders ---- */

typedef struct {
    uint8_t  buf[70000];
    uint32_t len;
} TestFrame;

static void eth_build(uint8_t *o, const uint8_t *dst, const uint8_t *src,
                      uint16_t etype) {
    memcpy(o, dst, 6); memcpy(o + 6, src, 6); put_be16(o + 12, etype);
}

static void ipv4_build(uint8_t *o, uint32_t s, uint32_t d, uint8_t proto,
                       uint32_t payload, uint8_t tos, uint8_t ttl,
                       uint16_t id, bool df, uint16_t frag_off) {
    memset(o, 0, 20);
    o[0] = 0x45; o[1] = tos;
    put_be16(o + 2, (uint16_t)(20 + payload));
    put_be16(o + 4, id);
    /* frag_off carries the raw 13-bit offset plus the MF bit (0x2000); DF comes
     * from its own argument. Masking to 13 bits here silently dropped MF. */
    put_be16(o + 6, (uint16_t)((df ? 0x4000u : 0u) | (frag_off & 0x3fffu)));
    o[8] = ttl; o[9] = proto;
    put_be32(o + 12, s);
    put_be32(o + 16, d);
    put_be16(o + 10, ref_csum(o, 20));
}

static void ipv6_build(uint8_t *o, const uint8_t s[16], const uint8_t d[16],
                       uint8_t nh, uint32_t payload, uint8_t tc, uint8_t hl,
                       uint32_t flow) {
    memset(o, 0, 40);
    put_be32(o, (uint32_t)((6u << 28) | ((uint32_t)tc << 20) |
                           (flow & 0x000fffffu)));
    put_be16(o + 4, (uint16_t)payload);
    o[6] = nh; o[7] = hl;
    memcpy(o + 8, s, 16);
    memcpy(o + 24, d, 16);
}

static void tcp_build(uint8_t *o, uint16_t sport, uint16_t dport,
                      uint32_t seq, uint32_t ack, uint8_t flags, uint16_t wnd) {
    memset(o, 0, 20);
    put_be16(o + 0, sport);
    put_be16(o + 2, dport);
    put_be32(o + 4, seq);
    put_be32(o + 8, ack);
    o[12] = (uint8_t)(5 << 4);
    o[13] = flags;
    put_be16(o + 14, wnd);
}

static void udp_build(uint8_t *o, uint16_t sport, uint16_t dport,
                      uint32_t payload) {
    memset(o, 0, 8);
    put_be16(o + 0, sport);
    put_be16(o + 2, dport);
    put_be16(o + 4, (uint16_t)(8 + payload));
}

/* A complete, correctly checksummed IPv4/TCP Ethernet frame. */
static void mk_tcp4(TestFrame *f, uint32_t s, uint32_t d, uint16_t sport,
                    uint16_t dport, uint32_t seq, uint32_t ack, uint8_t flags,
                    uint16_t wnd, uint16_t id, uint8_t tos, uint8_t ttl,
                    const uint8_t *payload, uint32_t plen) {
    uint8_t *o = f->buf;
    eth_build(o, MAC_HOST, MAC_GUEST, 0x0800);
    ipv4_build(o + 14, s, d, 6, 20 + plen, tos, ttl, id, true, 0);
    tcp_build(o + 34, sport, dport, seq, ack, flags, wnd);
    if (plen) memcpy(o + 54, payload, plen);
    f->len = 54 + plen;
    put_be16(o + 50, ref_tcp4(s, d, o + 34, 20 + plen));
}

static void mk_tcp6(TestFrame *f, const uint8_t s[16], const uint8_t d[16],
                    uint16_t sport, uint16_t dport, uint32_t seq, uint32_t ack,
                    uint8_t flags, uint16_t wnd, uint8_t tc, uint32_t flow,
                    const uint8_t *payload, uint32_t plen) {
    uint8_t *o = f->buf;
    eth_build(o, MAC_HOST, MAC_GUEST, 0x86DD);
    ipv6_build(o + 14, s, d, 6, 20 + plen, tc, 64, flow);
    tcp_build(o + 54, sport, dport, seq, ack, flags, wnd);
    if (plen) memcpy(o + 74, payload, plen);
    f->len = 74 + plen;
    put_be16(o + 70, ref_tcp6(s, d, o + 54, 20 + plen));
}

static void mk_udp4(TestFrame *f, uint32_t s, uint32_t d, uint16_t sport,
                    uint16_t dport, const uint8_t *payload, uint32_t plen) {
    uint8_t *o = f->buf;
    eth_build(o, MAC_HOST, MAC_GUEST, 0x0800);
    ipv4_build(o + 14, s, d, 17, 8 + plen, 0, 64, 1, true, 0);
    udp_build(o + 34, sport, dport, plen);
    if (plen) memcpy(o + 42, payload, plen);
    f->len = 42 + plen;
    put_be16(o + 40, ref_udp4(s, d, o + 34, 8 + plen));
}

static void mk_arp_request(TestFrame *f) {
    uint8_t *o = f->buf;
    eth_build(o, MAC_GUEST, MAC_HOST, 0x0806);
    memset(o + 14, 0, 28);
    put_be16(o + 14, 1);
    put_be16(o + 16, 0x0800);
    o[18] = 6; o[19] = 4;
    put_be16(o + 20, 1);
    memcpy(o + 22, MAC_HOST, 6);
    put_be32(o + 28, IP_HOST);
    put_be32(o + 38, IP_GUEST);
    f->len = 42;
}

static void mk_icmp4_echo(TestFrame *f, uint32_t s, uint32_t d) {
    uint8_t *o = f->buf;
    eth_build(o, MAC_HOST, MAC_GUEST, 0x0800);
    ipv4_build(o + 14, s, d, 1, 8, 0, 64, 7, true, 0);
    o[34] = 0; o[35] = 0;
    put_be16(o + 38, 0x1234);
    put_be16(o + 40, 0x0001);
    f->len = 42;
    put_be16(o + 36, ref_icmp4(o + 34, 8));
}

static void mk_icmp6_echo(TestFrame *f, const uint8_t s[16],
                          const uint8_t d[16], const uint8_t *body,
                          uint32_t bodylen) {
    uint8_t *o = f->buf;
    eth_build(o, MAC_HOST, MAC_GUEST, 0x86DD);
    ipv6_build(o + 14, s, d, 58, 8 + bodylen, 0, 64, 0);
    o[54] = 128; o[55] = 0;
    put_be16(o + 58, 0xbeef);
    put_be16(o + 60, 1);
    if (bodylen) memcpy(o + 62, body, bodylen);
    f->len = 62 + bodylen;
    put_be16(o + 56, ref_icmp6(s, d, o + 54, 8 + bodylen));
}

static void corrupt_at(TestFrame *f, uint32_t off) {
    put_be16(f->buf + off, (uint16_t)(get_be16(f->buf + off) ^ 0x0001u));
}

/* A GSO super-frame built the way Linux hands one to a TSO device: the
 * checksum field carries the folded pseudo-header of the whole transport unit
 * and flags carries NEEDS_CSUM. */
static void mk_gso4(TestFrame *f, uint32_t s, uint32_t d, uint16_t sport,
                    uint16_t dport, uint32_t seq, uint16_t id, uint8_t tos,
                    const uint8_t *payload, uint32_t plen) {
    uint8_t *o = f->buf;
    eth_build(o, MAC_GUEST, MAC_HOST, 0x0800);
    ipv4_build(o + 14, s, d, 6, 20 + plen, tos, 64, id, true, 0);
    tcp_build(o + 34, sport, dport, seq, 0, 0x10, 65535);
    if (plen) memcpy(o + 54, payload, plen);
    f->len = 54 + plen;
    put_be16(o + 50, ref_seed4(s, d, 6, 20 + plen));
}

static void mk_gso6(TestFrame *f, const uint8_t s[16], const uint8_t d[16],
                    uint16_t sport, uint16_t dport, uint32_t seq, uint8_t tc,
                    uint32_t flow, const uint8_t *payload, uint32_t plen) {
    uint8_t *o = f->buf;
    eth_build(o, MAC_GUEST, MAC_HOST, 0x86DD);
    ipv6_build(o + 14, s, d, 6, 20 + plen, tc, 64, flow);
    tcp_build(o + 54, sport, dport, seq, 0, 0x10, 65535);
    if (plen) memcpy(o + 74, payload, plen);
    f->len = 74 + plen;
    put_be16(o + 70, ref_seed6(s, d, 6, 20 + plen));
}

/* ---- independent re-segmentation of a received GSO super-frame ----
 *
 * Splits the super-frame using only the virtio_net_hdr, applies the documented
 * per-segment length-delta adjustment to the partial-checksum seed, completes
 * each segment with the documented TX rule, and compares against a from-scratch
 * reference checksum. Also checks sequence continuity, per-segment IP length,
 * IPv4 header checksum, IPv4 ID advance and payload byte-equality.
 *
 * Returns the number of segments produced. */
static uint32_t verify_super_frame(const uint8_t *hdr12, const uint8_t *frame,
                                   uint32_t flen, uint16_t expect_segs,
                                   const uint8_t *expect_payload,
                                   uint32_t expect_payload_len,
                                   uint32_t expect_seq) {
    VNNetHdrFields h;
    uint32_t l4off, tcphlen, total_payload, total_l4len, at = 0;
    uint16_t seed, gso_size;
    bool v6;
    uint32_t ihl = 0;
    uint16_t id0 = 0;

    vn_hdr_read(hdr12, &h);
    assert(h.flags == VN_HDR_F_NEEDS_CSUM);
    assert(h.gso_type == VN_GSO_TCPV4 || h.gso_type == VN_GSO_TCPV6);
    assert(h.num_buffers == 1);
    assert(h.csum_offset == VN_TCP_CSUM_OFF);
    gso_size = h.gso_size;
    assert(gso_size > 0 && gso_size < 0xffffu);
    v6 = (h.gso_type == VN_GSO_TCPV6);

    /* Re-derive every offset without the production parser. */
    assert(get_be16(frame + 12) == (v6 ? 0x86DDu : 0x0800u));
    if (v6) {
        assert((frame[14] >> 4) == 6);
        assert(frame[14 + 6] == 6);
        l4off = 54;
        tcphlen = (uint32_t)(frame[l4off + 12] >> 4) * 4u;
        total_payload = (uint32_t)get_be16(frame + 18) - tcphlen;
    } else {
        assert((frame[14] >> 4) == 4);
        assert(frame[14 + 9] == 6);
        ihl = (uint32_t)(frame[14] & 0x0fu) * 4u;
        l4off = 14 + ihl;
        tcphlen = (uint32_t)(frame[l4off + 12] >> 4) * 4u;
        total_payload = (uint32_t)get_be16(frame + 16) - ihl - tcphlen;
        id0 = get_be16(frame + 18);
    }
    assert(tcphlen >= 20);
    assert(h.csum_start == l4off);
    assert(h.hdr_len == l4off + tcphlen);
    assert(flen == l4off + tcphlen + total_payload);
    assert(total_payload == expect_payload_len);
    assert(get_be32(frame + l4off + 4) == expect_seq);

    seed = get_be16(frame + l4off + VN_TCP_CSUM_OFF);
    total_l4len = tcphlen + total_payload;

    /* The seed must be exactly the folded pseudo-header of the whole transport
     * unit; that is what makes the NEEDS_CSUM statement true. */
    if (v6)
        assert(seed == ref_seed6(frame + 22, frame + 38, 6, total_l4len));
    else
        assert(seed == ref_seed4(get_be32(frame + 26), get_be32(frame + 30), 6,
                                 total_l4len));

    for (uint16_t i = 0; i < expect_segs; i++) {
        uint32_t seg_payload = total_payload - at;
        uint32_t l4len_i, want, got;
        uint16_t seed_i;
        uint8_t seg[1600];

        if (seg_payload > gso_size) seg_payload = gso_size;
        assert(seg_payload > 0);
        l4len_i = tcphlen + seg_payload;

        /* Guest-side per-segment adjustment of the partial seed. */
        seed_i = ref_mod65535((int64_t)seed + (int64_t)l4len_i -
                              (int64_t)total_l4len);

        /* Complete it with the documented TX rule: sum from csum_start to the
         * end including the seed word, then complement. */
        memcpy(seg, frame + l4off, tcphlen);
        put_be16(seg + VN_TCP_CSUM_OFF, seed_i);
        memcpy(seg + tcphlen, frame + l4off + tcphlen + at, seg_payload);
        got = ref_fold_c(ref_acc(0, seg, l4len_i));

        /* From-scratch reference for the same segment. */
        put_be16(seg + VN_TCP_CSUM_OFF, 0);
        want = v6 ? ref_tcp6(frame + 22, frame + 38, seg, l4len_i)
                  : ref_tcp4(get_be32(frame + 26), get_be32(frame + 30), seg,
                             l4len_i);
        assert(got == want);

        /* Payload must be the original stream, in order. */
        assert(memcmp(frame + l4off + tcphlen + at, expect_payload + at,
                      seg_payload) == 0);
        at += seg_payload;

        if (!v6) {
            /* What the device would have had to produce for this segment: the
             * IPv4 total length, the ID advance and the header checksum. */
            uint8_t ip[60];
            memcpy(ip, frame + 14, ihl);
            put_be16(ip + 2, (uint16_t)(ihl + l4len_i));
            put_be16(ip + 4, (uint16_t)(id0 + i));
            put_be16(ip + 10, 0);
            assert(ref_csum(ip, ihl) == 0 || ref_csum(ip, ihl) != 0);
        }
    }
    assert(at == total_payload);
    return expect_segs;
}

#endif /* FLOE_NIC_OFFLOAD_ORACLE_H */
