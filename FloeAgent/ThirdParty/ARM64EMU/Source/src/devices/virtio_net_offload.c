/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre (virtio-net device; pinned upstream 55c8128cb02d) */
/* Copyright 2026 Floe contributors (NIC offload candidate) */
/* Implementation of virtio_net_offload.h. See that header for scope, the
 * normative references and the licensing statement: this is a self-contained
 * implementation, no third-party source was copied.
 *
 * Integration note: this translation unit is normally folded into
 * virtio_net.c by a single #include so the engine keeps its existing
 * translation-unit layout. Defining VN_OFFLOAD_SEPARATE_TU before including
 * virtio_net.c instead lets this file be compiled on its own (through a
 * Sources/NN_*.c wrapper); nothing else changes. */
#ifndef A64_VIRTIO_NET_OFFLOAD_C
#define A64_VIRTIO_NET_OFFLOAD_C

#include "virtio_net_offload.h"
#include <string.h>

/* ------------------------------------------------------------------ *
 * Byte access. Everything on the wire is big-endian except the         *
 * virtio_net_hdr, which is little-endian for a modern device.          *
 * ------------------------------------------------------------------ */

static inline uint16_t vn_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}
static inline uint32_t vn_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static inline void vn_put_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}
static inline void vn_put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}
static inline uint16_t vn_le16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}
static inline void vn_put_le16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

/* IPv6 extension headers that carry a length byte in the second position and
 * can legally appear before the transport header. A Fragment header (44) is
 * handled separately: it makes the frame a fragment, which is never offloaded.
 */
#define VN_IPV6_EXT_HBH      0u
#define VN_IPV6_EXT_ROUTING 43u
#define VN_IPV6_EXT_FRAGMENT 44u
#define VN_IPV6_EXT_DSTOPTS 60u
#define VN_IPV6_EXT_MOBILITY 135u
#define VN_IPV6_EXT_HIP      139u
#define VN_IPV6_EXT_SHIM6    140u
/* Bound the walk. A legitimate TCP session has at most a couple of these; the
 * cap exists so a hostile or corrupt chain cannot make us scan the frame. */
#define VN_IPV6_MAX_EXT      8u

/* ------------------------------------------------------------------ *
 * RFC 1071 ones-complement checksum                                   *
 * ------------------------------------------------------------------ */

/* Fold without complementing: the representative of an accumulator in the
 * ones-complement group. Note 0xFFFF and 0 are the same element here. */
static inline uint16_t vn_fold16(uint32_t acc) {
    acc = (acc & 0xffffu) + (acc >> 16);
    acc = (acc & 0xffffu) + (acc >> 16);
    return (uint16_t)(acc & 0xffffu);
}

/* Largest byte count summed before an intermediate fold. Even, and small
 * enough that 32767 words of 0xFFFF cannot overflow a u32 accumulator. */
#define VN_CSUM_CHUNK 65534u

uint32_t vn_csum_add(uint32_t acc, const uint8_t *p, uint32_t n) {
    uint32_t even = n & ~1u;
    uint32_t done = 0;
    while (done < even) {
        uint32_t take = even - done;
        const uint8_t *end;
        if (take > VN_CSUM_CHUNK) take = VN_CSUM_CHUNK;
        end = p + take;
        while (p < end) {
            acc += ((uint32_t)p[0] << 8) | (uint32_t)p[1];
            p += 2;
        }
        done += take;
        acc = (acc & 0xffffu) + (acc >> 16);
    }
    if (n & 1u) acc += (uint32_t)p[0] << 8;   /* RFC 1071 section 3 */
    return acc;
}

uint16_t vn_csum_fold(uint32_t acc) { return (uint16_t)~vn_fold16(acc); }

uint16_t vn_csum_region(const uint8_t *p, uint32_t n) {
    return vn_csum_fold(vn_csum_add(0, p, n));
}

uint16_t vn_pseudo4(const uint8_t saddr[4], const uint8_t daddr[4],
                    uint8_t proto, uint32_t l4len) {
    uint32_t acc = 0;
    acc += vn_be16(saddr);
    acc += vn_be16(saddr + 2);
    acc += vn_be16(daddr);
    acc += vn_be16(daddr + 2);
    acc += (uint32_t)proto;          /* the 3 zero bytes plus the protocol */
    acc += l4len & 0xffffu;          /* 32-bit length, added as two halves */
    acc += l4len >> 16;
    return vn_fold16(acc);
}

uint16_t vn_pseudo6(const uint8_t saddr[16], const uint8_t daddr[16],
                    uint8_t proto, uint32_t l4len) {
    uint32_t acc = 0;
    acc = vn_csum_add(acc, saddr, 16);
    acc = vn_csum_add(acc, daddr, 16);
    acc += l4len;                    /* folding later splits it into halves */
    acc += (uint32_t)proto;
    return vn_fold16(acc);
}

/* A computed checksum of 0x0000 is transmitted as 0xFFFF for UDP, because a
 * zero UDP checksum means "none" (RFC 768 / RFC 8200). Linux does the same
 * substitution (CSUM_MANGLED_0). TCP and ICMP have no such rule. */
static inline uint16_t vn_csum_fixup_zero(uint16_t csum, bool is_udp) {
    return (is_udp && csum == 0) ? (uint16_t)0xFFFFu : csum;
}

/* ------------------------------------------------------------------ *
 * struct virtio_net_hdr_v1                                            *
 * ------------------------------------------------------------------ */

void vn_hdr_read(const uint8_t *p, VNNetHdrFields *out) {
    out->flags       = p[0];
    out->gso_type    = p[1];
    out->hdr_len     = vn_le16(p + 2);
    out->gso_size    = vn_le16(p + 4);
    out->csum_start  = vn_le16(p + 6);
    out->csum_offset = vn_le16(p + 8);
    out->num_buffers = vn_le16(p + 10);
}

void vn_hdr_write(uint8_t *p, const VNNetHdrFields *in) {
    p[0] = in->flags;
    p[1] = in->gso_type;
    vn_put_le16(p + 2, in->hdr_len);
    vn_put_le16(p + 4, in->gso_size);
    vn_put_le16(p + 6, in->csum_start);
    vn_put_le16(p + 8, in->csum_offset);
    /* This device never negotiates MRG_RXBUF, so a delivered frame always
     * occupies exactly one buffer chain. */
    vn_put_le16(p + 10, 1);
}

void vn_hdr_write_plain(uint8_t *p) {
    VNNetHdrFields h;
    memset(&h, 0, sizeof(h));
    vn_hdr_write(p, &h);
}

/* ------------------------------------------------------------------ *
 * Frame parsing                                                       *
 * ------------------------------------------------------------------ */

VNParseStatus vn_frame_parse(const uint8_t *f, uint32_t len, VNFrameInfo *out) {
    uint16_t ethertype;
    uint32_t l3off;
    uint32_t l4off;
    uint32_t l4wire;

    memset(out, 0, sizeof(*out));
    out->family   = VN_FRAME_OTHER;
    out->csum_off = 0xFFFFu;
    if (!f || len < VN_ETH_HLEN) return VN_PARSE_SHORT;

    ethertype = vn_be16(f + 12);
    /* We never negotiate CTRL_VLAN, so a tagged frame is not something this
     * device knows how to offload. Report it rather than mis-parsing it. */
    if (ethertype == VN_ETH_P_VLAN || ethertype == VN_ETH_P_QINQ)
        return VN_PARSE_UNSUPPORTED;

    l3off = VN_ETH_HLEN;
    out->l3_off = (uint16_t)l3off;

    if (ethertype == VN_ETH_P_IP) {
        uint8_t  vihl;
        uint32_t ihl;
        uint32_t total;
        uint16_t frag;

        if (len < l3off + VN_IPV4_HLEN_MIN) return VN_PARSE_SHORT;
        vihl = f[l3off];
        if ((vihl >> 4) != 4u) return VN_PARSE_UNSUPPORTED;
        ihl = (uint32_t)(vihl & 0x0fu) * 4u;
        if (ihl < VN_IPV4_HLEN_MIN) return VN_PARSE_UNSUPPORTED;
        if (len < l3off + ihl) return VN_PARSE_SHORT;

        total = (uint32_t)vn_be16(f + l3off + 2);
        if (total < ihl) return VN_PARSE_SHORT;
        /* The IP total length is authoritative for the transport length; the
         * frame may legitimately carry Ethernet padding beyond it. Refuse a
         * header that claims bytes the frame does not have. */
        if (l3off + total > len) return VN_PARSE_SHORT;

        frag = vn_be16(f + l3off + 6);
        out->family        = VN_FRAME_IPV4;
        out->l3_len        = (uint16_t)ihl;
        out->proto         = f[l3off + 9];
        out->saddr         = f + l3off + 12;
        out->daddr         = f + l3off + 16;
        out->tos           = f[l3off + 1];
        out->ttl           = f[l3off + 8];
        out->ip_id         = vn_be16(f + l3off + 4);
        out->dont_fragment = (frag & 0x4000u) != 0;
        out->fragmented    = ((frag & 0x2000u) != 0) || ((frag & 0x1fffu) != 0);
        out->has_options   = ihl > VN_IPV4_HLEN_MIN;
        out->l4_wire_len   = total - ihl;
        l4off              = l3off + ihl;
        l4wire             = out->l4_wire_len;
    } else if (ethertype == VN_ETH_P_IPV6) {
        uint32_t payload;
        uint32_t first;
        uint8_t  nh;
        uint32_t off;
        uint32_t end;
        unsigned hops = 0;

        if (len < l3off + VN_IPV6_HLEN) return VN_PARSE_SHORT;
        first   = vn_be32(f + l3off);
        if ((first >> 28) != 6u) return VN_PARSE_UNSUPPORTED;
        payload = (uint32_t)vn_be16(f + l3off + 4);
        /* A jumbogram (payload_length == 0 with a Hop-by-Hop Jumbo option)
         * cannot be described by a 16-bit length; never offload it. */
        if (payload == 0) return VN_PARSE_UNSUPPORTED;
        if (l3off + VN_IPV6_HLEN + payload > len) return VN_PARSE_SHORT;

        nh  = f[l3off + 6];
        off = l3off + VN_IPV6_HLEN;
        end = off + payload;
        for (;;) {
            uint32_t ext_len;
            if (nh == VN_PROTO_TCP || nh == VN_PROTO_UDP ||
                nh == VN_PROTO_ICMPV6)
                break;
            if (nh == VN_IPV6_EXT_FRAGMENT) {
                /* Fragmented: no stable transport header to judge. Report the
                 * frame as IP with no known L4 so callers pass it through. */
                out->fragmented = true;
                nh = 0;
                break;
            }
            if (nh != VN_IPV6_EXT_HBH && nh != VN_IPV6_EXT_ROUTING &&
                nh != VN_IPV6_EXT_DSTOPTS && nh != VN_IPV6_EXT_MOBILITY &&
                nh != VN_IPV6_EXT_HIP && nh != VN_IPV6_EXT_SHIM6) {
                /* Something we do not know how to walk (ESP, AH, No Next
                 * Header, ...): opaque from here on. */
                nh = 0;
                break;
            }
            if (off + 2u > end) return VN_PARSE_SHORT;
            ext_len = ((uint32_t)f[off + 1] + 1u) * 8u;
            if (ext_len == 0 || off + ext_len > end) return VN_PARSE_SHORT;
            {
                uint8_t next = f[off];
                off += ext_len;
                nh = next;
            }
            if (++hops > VN_IPV6_MAX_EXT) return VN_PARSE_UNSUPPORTED;
            out->has_options = true;
        }

        out->family     = VN_FRAME_IPV6;
        out->l3_len     = (uint16_t)(off - l3off);
        out->proto      = nh;
        out->saddr      = f + l3off + 8;
        out->daddr      = f + l3off + 24;
        out->tos        = (uint8_t)((first >> 20) & 0xffu);
        out->ttl        = f[l3off + 7];
        out->flow_label = first & 0x000fffffu;
        out->l4_wire_len = end - off;
        l4off            = off;
        l4wire           = out->l4_wire_len;
    } else {
        /* ARP, LLDP, anything else: a frame this device must not touch. */
        return VN_PARSE_OK;
    }

    out->l4_off = (uint16_t)l4off;

    /* Transport header. Any inconsistency degrades to "unknown L4" so the
     * frame is still forwarded by the caller, just never offloaded. */
    switch (out->proto) {
    case VN_PROTO_TCP: {
        uint32_t th;
        if (l4wire < VN_TCP_HLEN_MIN) { out->proto = 0; break; }
        if (l4off + VN_TCP_HLEN_MIN > len) return VN_PARSE_SHORT;
        /* RFC 9293: the data offset is the high nibble of transport header
         * byte 12, immediately before the flags byte. */
        th = (uint32_t)(f[l4off + 12] >> 4) * 4u;
        if (th < VN_TCP_HLEN_MIN || th > VN_MAX_TCP_HLEN) { out->proto = 0; break; }
        if (l4wire < th) { out->proto = 0; break; }
        if (l4off + th > len) return VN_PARSE_SHORT;
        out->l4_hdr_len = (uint16_t)th;
        out->csum_off   = (uint16_t)(l4off + VN_TCP_CSUM_OFF);
        out->sport      = vn_be16(f + l4off);
        out->dport      = vn_be16(f + l4off + 2);
        break;
    }
    case VN_PROTO_UDP:
        if (l4wire < VN_UDP_HLEN) { out->proto = 0; break; }
        if (l4off + VN_UDP_HLEN > len) return VN_PARSE_SHORT;
        out->l4_hdr_len = VN_UDP_HLEN;
        out->csum_off   = (uint16_t)(l4off + VN_UDP_CSUM_OFF);
        out->sport      = vn_be16(f + l4off);
        out->dport      = vn_be16(f + l4off + 2);
        break;
    case VN_PROTO_ICMP:
    case VN_PROTO_ICMPV6:
        if (l4wire < VN_UDP_HLEN) { out->proto = 0; break; }
        if (l4off + VN_UDP_HLEN > len) return VN_PARSE_SHORT;
        out->l4_hdr_len = VN_UDP_HLEN;   /* type/code/checksum/id/sequence */
        out->csum_off   = (uint16_t)(l4off + 2);
        break;
    default:
        out->proto = 0;
        break;
    }

    if (out->proto != 0 && out->l4_hdr_len != 0) {
        out->payload_off = (uint16_t)(out->l4_off + out->l4_hdr_len);
        out->payload_len = l4wire - out->l4_hdr_len;
    } else {
        out->payload_off = out->l4_off;
        out->payload_len = l4wire;
    }
    return VN_PARSE_OK;
}

bool vn_frame_is_bulk(const VNFrameInfo *info) {
    if (!info) return false;
    if (info->family != VN_FRAME_IPV4 && info->family != VN_FRAME_IPV6)
        return false;
    return info->proto == VN_PROTO_TCP || info->proto == VN_PROTO_UDP;
}

/* ------------------------------------------------------------------ *
 * TX: partial checksum completion                                     *
 * ------------------------------------------------------------------ */

VNTxCsumStatus vn_tx_complete_csum(uint8_t *f, uint32_t len,
                                  const VNNetHdrFields *hdr) {
    uint32_t start, off, n;
    uint32_t acc;
    uint16_t val;
    VNFrameInfo info;
    bool is_udp;

    if (!f || !hdr) return VN_TX_CSUM_MALFORMED;
    if (!(hdr->flags & VN_HDR_F_NEEDS_CSUM)) return VN_TX_CSUM_NOT_REQUESTED;

    start = (uint32_t)hdr->csum_start;
    off   = (uint32_t)hdr->csum_offset;
    /* Each test is written so the u16 inputs can never wrap past len. */
    if (start > len) return VN_TX_CSUM_MALFORMED;
    if (off > len - start) return VN_TX_CSUM_MALFORMED;
    n = len - start;
    if (off + 2u > n) return VN_TX_CSUM_MALFORMED;

    /* Sum the region *including* the seed word the driver left in the
     * checksum field, then complement the fold. See the header comment: this
     * is the documented contract and it absorbs whatever pseudo-header
     * correction the driver seeded, without this device having to know it. */
    acc = vn_csum_add(0, f + start, n);
    val = vn_csum_fold(acc);

    is_udp = (vn_frame_parse(f, len, &info) == VN_PARSE_OK &&
              info.family != VN_FRAME_OTHER && info.proto == VN_PROTO_UDP);
    val = vn_csum_fixup_zero(val, is_udp);

    vn_put_be16(f + start + off, val);
    return VN_TX_CSUM_COMPLETED;
}

/* ------------------------------------------------------------------ *
 * TX: TCP segmentation                                                *
 * ------------------------------------------------------------------ */

/* IPv4 header checksum over the first ihl bytes, field included as-is. The
 * caller zeroes the field first when recomputing. */
static uint16_t vn_ipv4_header_csum(const uint8_t *ip, uint32_t ihl) {
    return vn_csum_region(ip, ihl);
}

VNSegStatus vn_tx_segment(const uint8_t *f, uint32_t len,
                          const VNNetHdrFields *hdr, uint64_t negotiated,
                          const VNSegCtx *ctx,
                          vn_emit_fn emit, void *opaque,
                          VNSegReport *report) {
    VNFrameInfo info;
    VNParseStatus st;
    uint8_t  base;
    uint32_t gso_size;
    uint32_t max_payload;
    uint32_t tcp_hdr_len;
    uint32_t prefix_len;
    uint32_t total_payload;
    uint32_t seg_payload;
    uint32_t seq;
    uint32_t needed;
    uint32_t produced = 0;
    uint64_t produced_bytes = 0;
    uint32_t hdr_sum;
    uint16_t ip_id;
    bool v6;
    bool want_ecn;
    uint32_t out_cap;

    if (report) { report->frames = 0; report->bytes = 0; }
    if (!f || !hdr || !ctx || !emit || !ctx->scratch) return VN_SEG_MALFORMED;

    base = (uint8_t)(hdr->gso_type & (uint8_t)~VN_GSO_ECN);
    if (base == VN_GSO_NONE) return VN_SEG_NOT_GSO;
    if (base != VN_GSO_TCPV4 && base != VN_GSO_TCPV6) return VN_SEG_UNSUPPORTED;

    v6 = (base == VN_GSO_TCPV6);
    if (!(negotiated & (v6 ? VN_F_HOST_TSO6 : VN_F_HOST_TSO4)))
        return VN_SEG_UNSUPPORTED;

    /* The ECN modifier is only meaningful when HOST_ECN was negotiated. This
     * candidate does not negotiate it, so per the documented default the ECN
     * codepoints are cleared in every produced segment rather than the frame
     * being refused - refusing would lose data the guest legitimately sent. */
    want_ecn = ((hdr->gso_type & VN_GSO_ECN) != 0) &&
               ((negotiated & VN_F_HOST_ECN) != 0);

    gso_size = (uint32_t)hdr->gso_size;
    if (gso_size == 0) return VN_SEG_MALFORMED;

    st = vn_frame_parse(f, len, &info);
    if (st != VN_PARSE_OK) return VN_SEG_MALFORMED;
    if (v6 ? (info.family != VN_FRAME_IPV6) : (info.family != VN_FRAME_IPV4))
        return VN_SEG_MALFORMED;
    if (info.proto != VN_PROTO_TCP || info.fragmented) return VN_SEG_MALFORMED;
    if (info.l4_hdr_len < VN_TCP_HLEN_MIN) return VN_SEG_MALFORMED;

    tcp_hdr_len  = info.l4_hdr_len;
    prefix_len   = (uint32_t)info.l4_off + tcp_hdr_len;
    total_payload = info.payload_len;
    if (total_payload == 0) return VN_SEG_MALFORMED;
    if (prefix_len + total_payload > len) return VN_SEG_MALFORMED;

    /* A partial-checksum request must point inside the frame. We recompute the
     * transport checksum from the segment's own bytes either way, so the seed
     * is never trusted to be correct - only checked to be in range. */
    if (hdr->flags & VN_HDR_F_NEEDS_CSUM) {
        uint32_t cs = (uint32_t)hdr->csum_start;
        uint32_t co = (uint32_t)hdr->csum_offset;
        if (cs > len) return VN_SEG_MALFORMED;
        if (co > len - cs) return VN_SEG_MALFORMED;
        if (cs + co + 2u > len) return VN_SEG_MALFORMED;
    }
    /* Flag bits beyond NEEDS_CSUM have no meaning for a device that does not
     * negotiate the matching feature (DATA_VALID and RSC_INFO are
     * device-to-driver only). They are ignored rather than treated as fatal:
     * refusing the frame would turn an unknown-but-harmless bit into lost
     * traffic. The caller can inspect hdr->flags to count them. */

    /* Never emit a frame the backend/link cannot carry. gso_size is a maximum
     * segment payload, so clamping down is legal and is what a real device
     * does at its link MTU. */
    out_cap = ctx->max_out_frame;
    if (out_cap == 0 || out_cap > ctx->scratch_cap) return VN_SEG_MALFORMED;
    if (prefix_len >= out_cap) return VN_SEG_MALFORMED;
    max_payload = out_cap - prefix_len;
    seg_payload = gso_size < max_payload ? gso_size : max_payload;
    if (seg_payload == 0) return VN_SEG_MALFORMED;

    needed = (total_payload + seg_payload - 1u) / seg_payload;
    if (needed == 0) needed = 1;
    if (needed > ctx->budget) {
        /* Emitting nothing keeps the super-packet whole: the caller leaves it
         * in the ring and a later drain produces every segment. Splitting a
         * super-packet across drains would strand payload the guest believes
         * was sent. */
        return VN_SEG_BUDGET;
    }

    seq = vn_be32(f + info.l4_off + 4);
    ip_id = info.ip_id;

    /* The transport header is replicated into every segment with only the
     * sequence number and the checksum changed. The prefix is staged once; the
     * header sum cannot be, because the sequence number is part of it. */
    if (prefix_len > ctx->scratch_cap) return VN_SEG_MALFORMED;
    memcpy(ctx->scratch, f, prefix_len);
    vn_put_be16(ctx->scratch + info.l4_off + VN_TCP_CSUM_OFF, 0);

    if (!want_ecn) {
        /* IPv4: the ECN codepoints are the low two bits of the TOS byte.
         * IPv6: the traffic class is split across bytes 1 and 2, and its low
         * two bits live in the high nibble of byte 1. */
        if (v6) ctx->scratch[info.l3_off + 1] &= (uint8_t)~0x30u;
        else    ctx->scratch[info.l3_off + 1] &= (uint8_t)~VN_INET_ECN_MASK;
    }

    for (uint32_t i = 0; i < needed; i++) {
        uint32_t off = i * seg_payload;
        uint32_t this_len = total_payload - off;
        uint32_t l4len;
        uint32_t acc;
        uint16_t csum;
        uint8_t *out = ctx->scratch;

        if (this_len > seg_payload) this_len = seg_payload;
        if (prefix_len + this_len > out_cap) return VN_SEG_MALFORMED;

        /* Payload for this segment. */
        memcpy(out + prefix_len, f + prefix_len + off, this_len);

        l4len = tcp_hdr_len + this_len;

        /* Transport header: sequence number, then the checksum. The header sum
         * is taken after the new sequence number is in place and with the
         * checksum field zeroed, so each segment is checksummed over its own
         * bytes. Summing the header once outside the loop would silently
         * checksum every segment with the first one's sequence number. */
        vn_put_be32(out + info.l4_off + 4, seq + off);
        vn_put_be16(out + info.l4_off + VN_TCP_CSUM_OFF, 0);
        hdr_sum = vn_csum_add(0, out + info.l4_off, tcp_hdr_len);
        acc = (v6 ? vn_pseudo6(info.saddr, info.daddr, VN_PROTO_TCP, l4len)
                  : vn_pseudo4(info.saddr, info.daddr, VN_PROTO_TCP, l4len));
        acc = (uint32_t)vn_fold16((uint32_t)acc + hdr_sum);
        acc = vn_csum_add(acc, out + prefix_len, this_len);
        csum = vn_csum_fold(acc);
        vn_put_be16(out + info.l4_off + VN_TCP_CSUM_OFF, csum);

        if (v6) {
            /* payload_length covers everything after the 40-byte fixed header,
             * which includes any extension headers we replicated verbatim. */
            vn_put_be16(out + info.l3_off + 4,
                        (uint16_t)(info.l3_len - VN_IPV6_HLEN + l4len));
        } else {
            uint32_t total = info.l3_len + l4len;
            if (total > 0xffffu) return VN_SEG_MALFORMED;
            vn_put_be16(out + info.l3_off + 2, (uint16_t)total);
            /* Documented default: the IP ID advances with every segment. That
             * is safe for atomic (DF) datagrams and required for the rest. */
            vn_put_be16(out + info.l3_off + 4, (uint16_t)(ip_id + i));
            vn_put_be16(out + info.l3_off + 10, 0);
            vn_put_be16(out + info.l3_off + 10,
                        vn_ipv4_header_csum(out + info.l3_off, info.l3_len));
        }

        if (!emit(opaque, out, prefix_len + this_len)) {
            if (report) { report->frames = produced; report->bytes = produced_bytes; }
            return VN_SEG_STOPPED;
        }
        produced++;
        produced_bytes += prefix_len + this_len;
    }

    if (report) { report->frames = produced; report->bytes = produced_bytes; }
    return VN_SEG_OK;
}

/* ------------------------------------------------------------------ *
 * RX: transport checksum verdict                                      *
 * ------------------------------------------------------------------ */

VNRxCsumVerdict vn_rx_verify(const uint8_t *f, uint32_t len,
                             const VNFrameInfo *info) {
    uint32_t l4len;
    uint32_t rel;
    uint32_t acc;
    uint16_t have, want;
    bool v4, is_udp, use_pseudo;

    if (!f || !info) return VN_RX_CSUM_UNKNOWN;
    if (info->family != VN_FRAME_IPV4 && info->family != VN_FRAME_IPV6)
        return VN_RX_CSUM_UNKNOWN;
    v4 = (info->family == VN_FRAME_IPV4);
    /* A fragment's transport header is only present in the first piece, and
     * the pseudo-header length of a non-first piece is meaningless. */
    if (info->fragmented) return VN_RX_CSUM_UNKNOWN;
    if (info->proto == 0 || info->l4_hdr_len == 0) return VN_RX_CSUM_UNKNOWN;
    if (info->csum_off == 0xFFFFu) return VN_RX_CSUM_UNKNOWN;
    if ((uint32_t)info->csum_off + 2u > len) return VN_RX_CSUM_UNKNOWN;
    if (info->csum_off < info->l4_off) return VN_RX_CSUM_UNKNOWN;

    l4len = info->l4_wire_len;
    if (l4len < info->l4_hdr_len) return VN_RX_CSUM_UNKNOWN;
    if ((uint32_t)info->l4_off + l4len > len) return VN_RX_CSUM_UNKNOWN;

    is_udp = (info->proto == VN_PROTO_UDP);
    have = vn_be16(f + info->csum_off);
    /* RFC 768: a zero UDP checksum in IPv4 means the sender disabled it. There
     * is then nothing to confirm, and claiming DATA_VALID would be a lie. */
    if (v4 && is_udp && have == 0) return VN_RX_CSUM_UNKNOWN;

    /* ICMPv4 has no pseudo-header (RFC 792); ICMPv6 does (RFC 4443). */
    use_pseudo = !(v4 && info->proto == VN_PROTO_ICMP);

    rel = (uint32_t)info->csum_off - (uint32_t)info->l4_off;
    if (rel + 2u > l4len) return VN_RX_CSUM_UNKNOWN;

    acc = use_pseudo
        ? (v4 ? vn_pseudo4(info->saddr, info->daddr, info->proto, l4len)
              : vn_pseudo6(info->saddr, info->daddr, info->proto, l4len))
        : 0u;
    /* Sum the transport header with the checksum field excluded, then the
     * rest of the transport data. */
    acc = vn_csum_add(acc, f + info->l4_off, rel);
    acc = vn_csum_add(acc, f + info->csum_off + 2u, l4len - rel - 2u);
    want = vn_csum_fold(acc);
    want = vn_csum_fixup_zero(want, is_udp);

    return (have == want) ? VN_RX_CSUM_VALID : VN_RX_CSUM_INVALID;
}

/* ------------------------------------------------------------------ *
 * RX: bounded TCP coalescing                                          *
 * ------------------------------------------------------------------ */

/* The only TCP flag combination a merged-in segment may carry. Anything else
 * is a boundary the guest must be allowed to see: SYN/FIN/RST change
 * connection state, PSH is an explicit push boundary, URG carries an offset
 * that cannot survive merging, and ECE/CWR are ECN state we do not negotiate. */
#define VN_COAL_ALLOWED_FLAGS VN_TCP_ACK

static VNCoalReason vn_tcp_view(const uint8_t *f, uint32_t len,
                                const VNFrameInfo *info, VNTcpView *view) {
    if (info->family != VN_FRAME_IPV4 && info->family != VN_FRAME_IPV6)
        return VN_COAL_NOT_IP;
    if (info->proto != VN_PROTO_TCP) return VN_COAL_NOT_TCP;
    if (info->fragmented) return VN_COAL_FRAGMENTED;
    if (info->l4_hdr_len < VN_TCP_HLEN_MIN) return VN_COAL_MALFORMED;
    if ((uint32_t)info->l4_off + info->l4_hdr_len > len) return VN_COAL_MALFORMED;

    view->info    = *info;
    view->seq     = vn_be32(f + info->l4_off + 4);
    view->ack     = vn_be32(f + info->l4_off + 8);
    view->hdr_len = (uint8_t)(f[info->l4_off + 12] & 0xf0u);  /* doff nibble */
    view->flags   = f[info->l4_off + 13];
    view->window  = vn_be16(f + info->l4_off + 14);
    return VN_COAL_OK;
}

VNCoalReason vn_coalesce_begin(const uint8_t *f, uint32_t len, uint64_t negotiated,
                               VNCoalesce *c, VNTcpView *view) {
    VNFrameInfo info;
    VNTcpView   local;
    VNCoalReason r;
    bool v6;

    if (!f || !c || !view) return VN_COAL_MALFORMED;
    if (vn_frame_parse(f, len, &info) != VN_PARSE_OK) return VN_COAL_MALFORMED;
    if (info.family != VN_FRAME_IPV4 && info.family != VN_FRAME_IPV6)
        return VN_COAL_NOT_IP;

    v6 = (info.family == VN_FRAME_IPV6);
    if (!(negotiated & VN_F_GUEST_CSUM)) return VN_COAL_NOT_NEGOTIATED;
    if (!(negotiated & (v6 ? VN_F_GUEST_TSO6 : VN_F_GUEST_TSO4)))
        return VN_COAL_NOT_NEGOTIATED;

    r = vn_tcp_view(f, len, &info, &local);
    if (r != VN_COAL_OK) return r;

    /* Options or extension headers would have to be replicated and re-linked
     * per member. They are rare on a plain TCP session, so refuse rather than
     * risk a wrong super-frame; the frame is still delivered normally. */
    if (info.has_options) return VN_COAL_HEADER_MISMATCH;
    if (local.flags != VN_COAL_ALLOWED_FLAGS) return VN_COAL_FLAGS_BOUNDARY;
    if (vn_rx_verify(f, len, &info) != VN_RX_CSUM_VALID)
        return VN_COAL_CSUM_UNVERIFIED;
    if (info.payload_len == 0) return VN_COAL_EMPTY_PAYLOAD;

    memset(c, 0, sizeof(*c));
    c->info         = info;
    c->ip_version   = (uint8_t)(v6 ? 6 : 4);
    c->gso_type     = (uint8_t)(v6 ? VN_GSO_TCPV6 : VN_GSO_TCPV4);
    c->l2_len       = info.l3_off;
    c->l3_len       = info.l3_len;
    c->tcp_hdr_len  = info.l4_hdr_len;
    c->prefix_len   = (uint16_t)((uint32_t)info.l4_off + info.l4_hdr_len);
    c->gso_size     = (uint16_t)info.payload_len;
    c->seq_next     = local.seq + info.payload_len;
    c->total_payload = info.payload_len;
    c->count        = 1;
    c->ack          = local.ack;
    c->window       = local.window;
    c->tcp_flags    = local.flags;
    c->sport        = info.sport;
    c->dport        = info.dport;
    c->addr_len     = (uint8_t)(v6 ? 16 : 4);
    memcpy(c->saddr, info.saddr, c->addr_len);
    memcpy(c->daddr, info.daddr, c->addr_len);
    memcpy(c->tcp_hdr, f + info.l4_off, info.l4_hdr_len);
    *view = local;
    return VN_COAL_OK;
}

VNCoalReason vn_coalesce_append(VNCoalesce *c, const uint8_t *f, uint32_t len,
                                const VNCaps *caps, uint32_t *member_payload) {
    VNFrameInfo info;
    VNTcpView   view;
    VNCoalReason r;
    bool v6;

    if (!c || !f || !caps) return VN_COAL_MALFORMED;
    if (vn_frame_parse(f, len, &info) != VN_PARSE_OK) return VN_COAL_MALFORMED;
    v6 = (c->ip_version == 6);
    if (v6 ? (info.family != VN_FRAME_IPV6) : (info.family != VN_FRAME_IPV4))
        return VN_COAL_DIFFERENT_FLOW;

    r = vn_tcp_view(f, len, &info, &view);
    if (r != VN_COAL_OK) return r;
    if (info.has_options) return VN_COAL_HEADER_MISMATCH;

    if (info.sport != c->sport || info.dport != c->dport)
        return VN_COAL_DIFFERENT_FLOW;
    if (memcmp(info.saddr, c->saddr, c->addr_len) != 0 ||
        memcmp(info.daddr, c->daddr, c->addr_len) != 0)
        return VN_COAL_DIFFERENT_FLOW;

    if (info.l3_off != c->l2_len || info.l3_len != c->l3_len ||
        info.l4_hdr_len != c->tcp_hdr_len)
        return VN_COAL_HEADER_MISMATCH;
    if (info.tos != c->info.tos || info.ttl != c->info.ttl)
        return VN_COAL_HEADER_MISMATCH;
    if (v6 && info.flow_label != c->info.flow_label)
        return VN_COAL_HEADER_MISMATCH;
    if (view.ack != c->ack || view.window != c->window)
        return VN_COAL_HEADER_MISMATCH;
    if (view.flags != VN_COAL_ALLOWED_FLAGS) return VN_COAL_FLAGS_BOUNDARY;

    /* Transport header must be identical apart from seq and the checksum. */
    {
        const uint8_t *th = f + info.l4_off;
        if (th[12] != c->tcp_hdr[12]) return VN_COAL_HEADER_MISMATCH;
        if (th[13] != c->tcp_hdr[13]) return VN_COAL_HEADER_MISMATCH;
        if (vn_be16(th + 14) != c->window) return VN_COAL_HEADER_MISMATCH;
        if (th[18] != c->tcp_hdr[18] || th[19] != c->tcp_hdr[19])
            return VN_COAL_HEADER_MISMATCH;
        if (c->tcp_hdr_len > VN_TCP_HLEN_MIN &&
            memcmp(th + VN_TCP_HLEN_MIN, c->tcp_hdr + VN_TCP_HLEN_MIN,
                   (size_t)c->tcp_hdr_len - VN_TCP_HLEN_MIN) != 0)
            return VN_COAL_HEADER_MISMATCH;
    }

    if (vn_rx_verify(f, len, &info) != VN_RX_CSUM_VALID)
        return VN_COAL_CSUM_UNVERIFIED;
    if (view.seq != c->seq_next) return VN_COAL_SEQ_DISCONTINUITY;
    if (info.payload_len == 0) return VN_COAL_EMPTY_PAYLOAD;
    /* gso_size describes every merged segment, so a different length ends the
     * aggregate instead of producing a super-frame the guest would split at
     * the wrong boundaries. */
    if (info.payload_len != (uint32_t)c->gso_size) return VN_COAL_SIZE_MISMATCH;

    if ((uint32_t)c->count + 1u > (uint32_t)caps->max_segments)
        return VN_COAL_TOO_MANY_SEGMENTS;
    if (c->total_payload + info.payload_len > caps->max_payload)
        return VN_COAL_TOO_LARGE;

    c->total_payload += info.payload_len;
    c->seq_next      += info.payload_len;
    c->count++;
    if (member_payload) *member_payload = info.payload_len;
    return VN_COAL_OK;
}

uint32_t vn_coalesce_emit(const VNCoalesce *c, const VNFrameRef *members,
                          uint16_t count, uint8_t *dst, uint32_t cap) {
    uint32_t total;
    uint32_t at;
    uint32_t l4off;
    uint32_t l4len;
    uint16_t seed;

    if (!c || !members || !dst || count < 2 || count != c->count) return 0;
    if (c->prefix_len == 0 || c->total_payload == 0) return 0;

    total = VN_HDR_LEN + (uint32_t)c->prefix_len + c->total_payload;
    if (total > cap) return 0;
    /* A super-frame must stay describable by the 16-bit IP length fields. */
    if (c->ip_version == 6) {
        if ((uint32_t)c->l3_len - VN_IPV6_HLEN + c->tcp_hdr_len +
            c->total_payload > 0xffffu) return 0;
    } else {
        if ((uint32_t)c->l3_len + c->tcp_hdr_len + c->total_payload > 0xffffu)
            return 0;
    }

    /* The first member supplies the Ethernet + IP + TCP prefix verbatim. */
    memcpy(dst + VN_HDR_LEN, members[0].bytes, c->prefix_len);

    at = VN_HDR_LEN + c->prefix_len;
    for (uint16_t i = 0; i < count; i++) {
        const VNFrameRef *m = &members[i];
        if (m->payload_off + m->payload_len > m->len) return 0;
        if (m->payload_len == 0) return 0;
        if (at + m->payload_len > cap) return 0;
        memcpy(dst + at, m->bytes + m->payload_off, m->payload_len);
        at += m->payload_len;
    }
    if (at != total) return 0;

    l4off = (uint32_t)c->prefix_len - c->tcp_hdr_len;
    l4len = (uint32_t)c->tcp_hdr_len + c->total_payload;

    /* Seed the super-frame's checksum field with the folded pseudo-header of
     * the whole transport unit. That is exactly the value a segmentation path
     * adjusts by the per-segment length delta, and it is what makes the
     * NEEDS_CSUM statement true rather than optimistic. */
    seed = (c->ip_version == 6)
        ? vn_pseudo6(c->saddr, c->daddr, VN_PROTO_TCP, l4len)
        : vn_pseudo4(c->saddr, c->daddr, VN_PROTO_TCP, l4len);
    vn_put_be16(dst + VN_HDR_LEN + l4off + VN_TCP_CSUM_OFF, seed);

    if (c->ip_version == 6) {
        vn_put_be16(dst + VN_HDR_LEN + c->l2_len + 4,
                    (uint16_t)((uint32_t)c->l3_len - VN_IPV6_HLEN + l4len));
    } else {
        vn_put_be16(dst + VN_HDR_LEN + c->l2_len + 2,
                    (uint16_t)((uint32_t)c->l3_len + l4len));
        /* The aggregate is one datagram now; keep the first member's ID and
         * mark it atomic so a receiver never tries to reassemble it. */
        vn_put_be16(dst + VN_HDR_LEN + c->l2_len + 6,
                    (uint16_t)(vn_be16(dst + VN_HDR_LEN + c->l2_len + 6) |
                               0x4000u));
        vn_put_be16(dst + VN_HDR_LEN + c->l2_len + 10, 0);
        vn_put_be16(dst + VN_HDR_LEN + c->l2_len + 10,
                    vn_ipv4_header_csum(dst + VN_HDR_LEN + c->l2_len,
                                        c->l3_len));
    }

    {
        VNNetHdrFields h;
        memset(&h, 0, sizeof(h));
        h.flags       = VN_HDR_F_NEEDS_CSUM;
        h.gso_type    = c->gso_type;
        h.hdr_len     = c->prefix_len;
        h.gso_size    = c->gso_size;
        h.csum_start  = (uint16_t)l4off;
        h.csum_offset = VN_TCP_CSUM_OFF;
        vn_hdr_write(dst, &h);
    }
    return total;
}

/* ------------------------------------------------------------------ *
 * Per-flow fair admission                                             *
 * ------------------------------------------------------------------ */

bool vn_flow_key(const uint8_t *f, uint32_t len, const VNFrameInfo *info,
                 VNFlowKey *out) {
    (void)f; (void)len;
    memset(out, 0, sizeof(*out));
    if (!info) return false;
    if (info->family != VN_FRAME_IPV4 && info->family != VN_FRAME_IPV6)
        return false;
    if (!info->saddr || !info->daddr) return false;
    out->ip_version = (uint8_t)(info->family == VN_FRAME_IPV6 ? 6 : 4);
    out->proto      = info->proto;
    out->sport      = info->sport;
    out->dport      = info->dport;
    out->addr_len   = (uint8_t)(out->ip_version == 6 ? 16 : 4);
    memcpy(out->saddr, info->saddr, out->addr_len);
    memcpy(out->daddr, info->daddr, out->addr_len);
    return true;
}

bool vn_flow_key_eq(const VNFlowKey *a, const VNFlowKey *b) {
    if (!a || !b) return false;
    if (a->ip_version != b->ip_version || a->proto != b->proto) return false;
    if (a->sport != b->sport || a->dport != b->dport) return false;
    if (a->addr_len != b->addr_len) return false;
    return memcmp(a->saddr, b->saddr, a->addr_len) == 0 &&
           memcmp(a->daddr, b->daddr, a->addr_len) == 0;
}

void vn_fairness_init(VNFairness *fq) {
    if (!fq) return;
    memset(fq, 0, sizeof(*fq));
}

static VNFairEntry *vn_fair_find(VNFairness *fq, const VNFlowKey *key) {
    for (unsigned i = 0; i < VN_FLOW_SLOTS; i++)
        if (fq->entry[i].used && vn_flow_key_eq(&fq->entry[i].key, key))
            return &fq->entry[i];
    return NULL;
}

static VNFairEntry *vn_fair_alloc(VNFairness *fq, const VNFlowKey *key) {
    for (unsigned i = 0; i < VN_FLOW_SLOTS; i++) {
        if (!fq->entry[i].used) {
            fq->entry[i].used  = true;
            fq->entry[i].slots = 0;
            fq->entry[i].key   = *key;
            fq->tracked++;
            return &fq->entry[i];
        }
    }
    return NULL;
}

static uint16_t vn_fair_active(const VNFairness *fq) {
    uint16_t n = 0;
    for (unsigned i = 0; i < VN_FLOW_SLOTS; i++)
        if (fq->entry[i].used && fq->entry[i].slots > 0) n++;
    return n;
}

bool vn_fairness_admit(VNFairness *fq, const VNFlowKey *key, bool bulk,
                       uint16_t ring_size, uint16_t ring_used) {
    VNFairEntry *e;
    uint16_t active, contenders;
    uint32_t share;

    if (!fq || ring_size == 0) return false;
    if (ring_used >= ring_size) return false;
    if (!key || key->ip_version == 0) {
        /* Not an IP flow (ARP, ...): always admitted while there is room. */
        fq->control_bypass++;
        return true;
    }

    e = vn_fair_find(fq, key);
    if (!bulk) {
        /* Control traffic never gets starved by a bulk flow's share. */
        fq->control_bypass++;
        if (!e) e = vn_fair_alloc(fq, key);
        if (e) e->slots++;
        fq->admits++;
        return true;
    }

    if (!e) {
        e = vn_fair_alloc(fq, key);
        if (!e) {
            /* No accounting slot left: fall back to plain FIFO admission,
             * which is exactly the legacy behaviour. Counted, never hidden. */
            fq->table_full++;
            fq->admits++;
            return true;
        }
    }

    active = vn_fair_active(fq);
    if (active >= 2 || (active == 1 && e->slots == 0)) {
        contenders = (uint16_t)(active + (e->slots == 0 ? 1 : 0));
        if (contenders < 2) contenders = 2;
        share = ((uint32_t)ring_size + contenders - 1u) / contenders;
        if (share == 0) share = 1;
        if ((uint32_t)e->slots >= share) {
            fq->refusals++;
            return false;
        }
    }
    e->slots++;
    fq->admits++;
    return true;
}

void vn_fairness_release(VNFairness *fq, const VNFlowKey *key) {
    VNFairEntry *e;
    if (!fq || !key) return;
    e = vn_fair_find(fq, key);
    if (!e) return;
    if (e->slots > 0) e->slots--;
    if (e->slots == 0) {
        e->used = false;
        memset(&e->key, 0, sizeof(e->key));
        if (fq->tracked > 0) fq->tracked--;
    }
}

void vn_fairness_reset(VNFairness *fq) {
    if (!fq) return;
    /* Counters survive a guest reset on purpose: they describe the device, not
     * the driver instance. Only the accounting is dropped. */
    for (unsigned i = 0; i < VN_FLOW_SLOTS; i++) {
        fq->entry[i].used = false;
        fq->entry[i].slots = 0;
        memset(&fq->entry[i].key, 0, sizeof(fq->entry[i].key));
    }
    fq->tracked = 0;
}

/* ------------------------------------------------------------------ *
 * Counters                                                            *
 * ------------------------------------------------------------------ */

void vn_stats_init(VNStats *s) { if (s) memset(s, 0, sizeof(*s)); }

size_t vn_stats_count(void) { return sizeof(VNStats) / sizeof(uint64_t); }

void vn_stats_export(const VNStats *s, uint64_t *out, size_t max) {
    size_t n = sizeof(VNStats) / sizeof(uint64_t);
    if (!s || !out) return;
    if (max < n) n = max;
    memcpy(out, s, n * sizeof(uint64_t));
}

#endif /* A64_VIRTIO_NET_OFFLOAD_C */
