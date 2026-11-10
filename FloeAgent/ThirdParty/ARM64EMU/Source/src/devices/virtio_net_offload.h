/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre (virtio-net device; pinned upstream 55c8128cb02d) */
/* Copyright 2026 Floe contributors (NIC offload candidate) */
/* virtio-net offload helpers.
 *
 * Scope: everything a virtio-net *device* needs in order to stop making the
 * guest do per-packet software work, without changing what the network backend
 * sees. The backend interface is untouched: TX still hands over ordinary,
 * fully formed Ethernet frames and RX still accepts ordinary Ethernet frames.
 *
 * Provided here
 *   - a bounds-checked Ethernet/IPv4/IPv6/TCP/UDP/ICMP frame parser that never
 *     trusts a length the peer supplied without checking it against the frame;
 *   - an independent RFC 1071 ones-complement checksum implementation with
 *     IPv4/IPv6 pseudo-header seeding (deliberately not reusing the backend's
 *     un_l4_cksum(), so a device-side bug can never be cancelled out by the
 *     same bug in the reference path);
 *   - TX partial-checksum completion (VIRTIO_NET_F_CSUM);
 *   - TX TCP segmentation for TCPV4/TCPV6 (VIRTIO_NET_F_HOST_TSO4/TSO6);
 *   - RX transport-checksum verdicts used for VIRTIO_NET_HDR_F_DATA_VALID
 *     (VIRTIO_NET_F_GUEST_CSUM);
 *   - bounded RX TCP coalescing into one GSO super-frame
 *     (VIRTIO_NET_F_GUEST_TSO4/TSO6, the guest's GRO_HW path);
 *   - per-flow fair admission for the device RX ring so one bulk flow cannot
 *     starve another when the ring is under pressure.
 *
 * Hard rules this file exists to enforce
 *   1. Nothing is offloaded unless the matching feature bit is present in the
 *      *negotiated* set. Un-negotiated traffic keeps the exact legacy path.
 *   2. A frame is never dropped to make a counter look good. Bad transport
 *      checksums are still delivered (the Linux stack must be able to report
 *      them); we simply refuse to claim DATA_VALID for them.
 *   3. VIRTIO_NET_HDR_F_DATA_VALID / F_NEEDS_CSUM are only ever written after
 *      this file actually verified or actually computed the value.
 *   4. Every length, offset and count comes from the frame or from an explicit
 *      cap, never from a guest-supplied hint that is not independently
 *      re-derived (hdr_len is a hint per the virtio spec and is ignored as an
 *      input; it is only ever written as an output).
 *
 * Provenance / licensing
 *   Self-contained implementation. No third-party source was copied. The
 *   normative references used are public specifications and interface
 *   documentation only:
 *     - RFC 1071, "Computing the Internet Checksum" (ones-complement sum,
 *       odd trailing byte, incremental folding);
 *     - RFC 791 / RFC 8200 / RFC 9293 / RFC 768 / RFC 4443 (header layouts,
 *       pseudo-headers, IPv6 extension-header chain);
 *     - OASIS Virtual I/O Device (VIRTIO) 1.2, section 5.1 "Network Device"
 *       (feature bits, struct virtio_net_hdr_v1, NEEDS_CSUM/DATA_VALID and
 *       GSO semantics);
 *     - Linux Documentation/networking/checksum-offloads.rst and
 *       segmentation-offloads.rst, plus include/linux/virtio_net.h, read as
 *       the *driver-side acceptance contract* (what a real guest will and will
 *       not accept). No GPL code was copied into this file.
 *   This file therefore carries no additional license obligation beyond the
 *   Apache-2.0 header already used by Source/src/.
 */
#ifndef A64_VIRTIO_NET_OFFLOAD_H
#define A64_VIRTIO_NET_OFFLOAD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ------------------------------------------------------------------ *
 * Feature bits (VIRTIO 1.2 section 5.1.3)                             *
 * ------------------------------------------------------------------ */
#define VN_F_CSUM            (1ULL << 0)   /* device completes a partial TX csum */
#define VN_F_GUEST_CSUM      (1ULL << 1)   /* driver accepts DATA_VALID/NEEDS_CSUM */
#define VN_F_MAC             (1ULL << 5)
#define VN_F_GUEST_TSO4      (1ULL << 7)   /* driver accepts TCPV4 GSO super-frames */
#define VN_F_GUEST_TSO6      (1ULL << 8)   /* driver accepts TCPV6 GSO super-frames */
#define VN_F_GUEST_ECN       (1ULL << 9)   /* not advertised by this candidate */
#define VN_F_HOST_TSO4       (1ULL << 11)  /* device segments TCPV4 GSO */
#define VN_F_HOST_TSO6       (1ULL << 12)  /* device segments TCPV6 GSO */
#define VN_F_HOST_ECN        (1ULL << 13)  /* not advertised by this candidate */
#define VN_F_STATUS          (1ULL << 16)
#define VN_F_VERSION_1       (1ULL << 32)

/* What this implementation can actually honour. The device advertises exactly
 * these on top of its pre-existing MAC/STATUS/VERSION_1 set, and only acts on
 * the subset the driver wrote back. HOST_ECN / GUEST_ECN / UFO / USO /
 * MRG_RXBUF / MTU / HASH_REPORT are deliberately absent: advertising a bit we
 * cannot fully service is worse than not accelerating that case. */
#define VN_OFFLOAD_TX_FEATURES (VN_F_CSUM | VN_F_HOST_TSO4 | VN_F_HOST_TSO6)
#define VN_OFFLOAD_RX_FEATURES (VN_F_GUEST_CSUM | VN_F_GUEST_TSO4 | VN_F_GUEST_TSO6)
#define VN_OFFLOAD_FEATURES \
    (VN_OFFLOAD_TX_FEATURES | VN_OFFLOAD_RX_FEATURES)

/* ------------------------------------------------------------------ *
 * struct virtio_net_hdr_v1 (12 bytes: VERSION_1 is negotiated)        *
 * ------------------------------------------------------------------ */
#define VN_HDR_LEN 12u

#define VN_HDR_F_NEEDS_CSUM 0x01u
#define VN_HDR_F_DATA_VALID 0x02u
/* Bits this device never writes and treats as a driver violation on RX of a
 * TX buffer: RSC_INFO(4) needs VIRTIO_NET_F_RSC_EXT, UDP_TUNNEL_CSUM(8) needs
 * the tunnel features. Neither is advertised. */
#define VN_HDR_F_KNOWN      (VN_HDR_F_NEEDS_CSUM | VN_HDR_F_DATA_VALID)

#define VN_GSO_NONE     0u
#define VN_GSO_TCPV4    1u
#define VN_GSO_UDP      3u   /* UFO: not implemented, never advertised */
#define VN_GSO_TCPV6    4u
#define VN_GSO_UDP_L4   5u   /* USO: not implemented, never advertised */
#define VN_GSO_ECN      0x80u

/* Ethernet / IP protocol numbers used below. */
#define VN_ETH_P_IP     0x0800u
#define VN_ETH_P_IPV6   0x86DDu
#define VN_ETH_P_ARP    0x0806u
#define VN_ETH_P_VLAN   0x8100u
#define VN_ETH_P_QINQ   0x88A8u

#define VN_PROTO_ICMP    1u
#define VN_PROTO_TCP     6u
#define VN_PROTO_UDP    17u
#define VN_PROTO_ICMPV6 58u

#define VN_ETH_HLEN     14u
#define VN_IPV4_HLEN_MIN 20u
#define VN_IPV6_HLEN    40u
#define VN_TCP_HLEN_MIN 20u
#define VN_UDP_HLEN      8u
#define VN_TCP_CSUM_OFF 16u   /* offsetof(struct tcphdr, check) */
#define VN_UDP_CSUM_OFF  6u   /* offsetof(struct udphdr, check)  */

#define VN_TCP_FIN 0x01u
#define VN_TCP_SYN 0x02u
#define VN_TCP_RST 0x04u
#define VN_TCP_PSH 0x08u
#define VN_TCP_ACK 0x10u
#define VN_TCP_URG 0x20u
#define VN_TCP_ECE 0x40u
#define VN_TCP_CWR 0x80u

/* IPv4 ECN mask inside the TOS byte (RFC 3168); IPv6 carries it in the low two
 * bits of the traffic class, i.e. the same bit positions after our byte swap. */
#define VN_INET_ECN_MASK 0x03u

/* ------------------------------------------------------------------ *
 * Bounds                                                              *
 * ------------------------------------------------------------------ */

/* A non-GSO Ethernet frame the legacy ring has always accepted. */
#define VN_MAX_ETH_FRAME 1518u

/* Largest Ethernet frame a GSO super-packet can describe, derived from the
 * 16-bit IP length fields rather than guessed:
 *   IPv6: 14 (eth) + 40 (fixed) + 60 (max TCP header) + 65535 (payload_length)
 *   IPv4: 14 (eth) + 60 (max IHL) + 65535 (total_length, includes the header)
 * The IPv6 shape is the larger one. */
#define VN_MAX_GSO_FRAME (VN_ETH_HLEN + VN_IPV6_HLEN + 65535u)
#define VN_MAX_TCP_HLEN  60u

/* Segment payload is bounded by the 16-bit IP length as well. */
#define VN_MAX_GSO_PAYLOAD 65535u

/* RX coalescing caps. max_payload keeps one super-frame inside the 16-bit IP
 * length; max_segments bounds the work done for a single guest buffer so one
 * poll can never be held hostage by a huge backlog. */
#define VN_RX_COALESCE_MAX_SEGMENTS 45u
#define VN_RX_COALESCE_MAX_PAYLOAD  65535u

/* Frames delivered to the guest per net_flush_rx() invocation. Bounds the
 * owner-visible stall when the backend has queued a large backlog (a 16 MiB
 * download must not become one uninterruptible pass). */
#define VN_RX_BATCH_MAX_FRAMES 64u

/* Output frames produced per TX drain. A single QueueNotify can carry a whole
 * ring of GSO super-packets; without this budget one notify could expand into
 * thousands of backend calls. The device continues the remainder from its
 * poll, so nothing is stranded. */
#define VN_TX_SEGMENT_BUDGET 1024u

/* Minimum transport payload for a guest TX frame to be treated as bulk data
 * for completion pacing (see the deferred TX completion logic in
 * virtio_net.c). Frames at or above this size have their used-ring entries
 * held back in a bounded window instead of being published inside the same
 * drain that consumed them. Everything below it - ACKs, SYNs, DNS, shell
 * traffic, small HTTP responses - completes in the same poll drain without
 * joining the bulk completion window. */
#define VN_TX_DEFER_MIN_PAYLOAD 512u

/* Bulk TX completions outstanding (descriptors consumed and delivered to the
 * backend, used entries not yet published) before the oldest are published.
 * The window is a count, never a time: it holds roughly three quarters of the
 * ring, so from the guest's point of view a bulk flow always has most of the
 * ring occupied. That is what turns the device's real consumption rate into
 * socket-visible backpressure inside the guest: the transmit queue stops, the
 * qdisc and then the sending socket's buffer fill, and the application's
 * write() finally returns EAGAIN - which is the only thing that reliably
 * returns a single-threaded event loop (Node, Python, any servers embedded in
 * the guest) to its other connections while a large response streams. Data
 * itself is never held back: segments reach the backend as soon as they are
 * consumed, so throughput stays backend-bound, and the window slides forward
 * on bulk work. Control-only ticks publish at least one old completion, so
 * continuous small traffic cannot strand a bulk tail; an idle tick drains
 * every held completion. */
#define VN_TX_COMPLETION_HOLD 192u

/* ------------------------------------------------------------------ *
 * Frame parsing                                                       *
 * ------------------------------------------------------------------ */

typedef enum {
    VN_FRAME_OTHER = 0,   /* ARP, unknown ethertype, non-IP: never offloaded */
    VN_FRAME_IPV4  = 4,
    VN_FRAME_IPV6  = 6
} VNFrameFamily;

typedef struct {
    VNFrameFamily family;
    uint16_t l3_off;        /* start of the IP header (== Ethernet header len) */
    uint16_t l3_len;        /* IPv4: IHL*4 incl. options. IPv6: 40 + walked
                             * extension headers, i.e. l4_off - l3_off. */
    uint16_t l4_off;        /* start of the transport header */
    uint16_t l4_hdr_len;    /* TCP: doff*4; UDP: 8; ICMP/ICMPv6: 8; else 0 */
    uint8_t  proto;         /* VN_PROTO_*; 0 when the L4 is not one we know */
    uint16_t csum_off;      /* absolute offset of the L4 checksum field,
                             * 0xFFFF when the L4 has no such field */
    uint16_t payload_off;   /* l4_off + l4_hdr_len */
    uint32_t payload_len;   /* bytes after the transport header */
    uint32_t l4_wire_len;   /* length the pseudo-header must carry:
                             * everything from l4_off to the end of the frame */
    bool     fragmented;    /* IPv4: MF set or a non-zero fragment offset */
    bool     has_options;   /* IPv4 IHL > 5, or an IPv6 extension-header chain */
    /* Source/destination addresses as pointers into the frame itself, so no
     * copy is needed and no endianness decision is baked in here. */
    const uint8_t *saddr;   /* 4 bytes for IPv4, 16 for IPv6, else NULL */
    const uint8_t *daddr;
    uint16_t sport;         /* host order; 0 when there is no port */
    uint16_t dport;
    /* Fields the RX coalescer must see stay identical across merged segments. */
    uint8_t  tos;           /* IPv4 TOS, or the IPv6 traffic-class byte */
    uint8_t  ttl;           /* IPv4 TTL, or the IPv6 hop limit */
    uint32_t flow_label;    /* IPv6 only */
    uint16_t ip_id;         /* IPv4 only */
    bool     dont_fragment; /* IPv4 only */
} VNFrameInfo;

typedef enum {
    VN_PARSE_OK = 0,
    VN_PARSE_SHORT,        /* a header claimed more bytes than the frame holds */
    VN_PARSE_UNSUPPORTED   /* VLAN tag, bad version/IHL, jumbogram, extension
                            * chain too deep or ending somewhere unexpected */
} VNParseStatus;

/* Parse an Ethernet frame. Always initialises *out; on VN_FRAME_OTHER the
 * caller must treat the frame as opaque and pass it through untouched.
 * Never reads outside [f, f+len). */
VNParseStatus vn_frame_parse(const uint8_t *f, uint32_t len, VNFrameInfo *out);

/* True when the frame carries bulk data whose admission should be subject to
 * the per-flow fair share (TCP/UDP). ARP, ICMP and ND are control traffic and
 * bypass the cap so address resolution and error reporting cannot be starved
 * by a download. */
bool vn_frame_is_bulk(const VNFrameInfo *info);

/* ------------------------------------------------------------------ *
 * RFC 1071 ones-complement checksum                                   *
 * ------------------------------------------------------------------ */

/* Add n bytes to a running unfolded accumulator. Words are read big-endian, as
 * on the wire; a trailing odd byte contributes as the high byte of a word with
 * a zero low byte (RFC 1071 section 3). The accumulator is a plain u32 and
 * cannot overflow for any n this device accepts: it is reduced internally
 * every 65534 bytes.
 *
 * COMPOSITION CONSTRAINT (RFC 1071 section 4). Successive calls only add up to
 * one whole-region sum when every chunk after the first starts at an EVEN
 * offset from the start of the checksummed region. At an odd boundary the
 * 16-bit word alignment flips and the partial sum would have to be byte-swapped
 * before continuing. Every caller in this file splits only on even offsets, so
 * no parity argument is needed:
 *   - the transport checksum field offsets are 16 (TCP), 6 (UDP) and 2 (ICMP);
 *   - transport header lengths are multiples of 4 (TCP) or exactly 8;
 *   - IPv4/IPv6 addresses are 4 and 16 bytes.
 * NICOffloadTests.c asserts both halves of this statement: composition holds
 * at even boundaries and demonstrably does not hold at an odd one. */
uint32_t vn_csum_add(uint32_t acc, const uint8_t *p, uint32_t n);

/* Fold and complement: the Internet checksum of an accumulated sum. */
uint16_t vn_csum_fold(uint32_t acc);

/* Convenience: the Internet checksum of a region. */
uint16_t vn_csum_region(const uint8_t *p, uint32_t n);

/* Folded pseudo-header sums, returned in the form that belongs in a checksum
 * field used as a partial-checksum seed (i.e. uncomplemented). */
uint16_t vn_pseudo4(const uint8_t saddr[4], const uint8_t daddr[4],
                    uint8_t proto, uint32_t l4len);
uint16_t vn_pseudo6(const uint8_t saddr[16], const uint8_t daddr[16],
                    uint8_t proto, uint32_t l4len);

/* ------------------------------------------------------------------ *
 * struct virtio_net_hdr_v1, host order                                *
 * ------------------------------------------------------------------ */
typedef struct {
    uint8_t  flags;
    uint8_t  gso_type;
    uint16_t hdr_len;      /* hint only on input; ignored as an input */
    uint16_t gso_size;
    uint16_t csum_start;
    uint16_t csum_offset;
    uint16_t num_buffers;
} VNNetHdrFields;

void vn_hdr_read(const uint8_t *p, VNNetHdrFields *out);
/* Write a header for a frame delivered to the guest. num_buffers is always 1:
 * this device does not negotiate VIRTIO_NET_F_MRG_RXBUF. */
void vn_hdr_write(uint8_t *p, const VNNetHdrFields *in);
/* The legacy RX behaviour: a zeroed header with num_buffers = 1. */
void vn_hdr_write_plain(uint8_t *p);

/* ------------------------------------------------------------------ *
 * TX: partial checksum completion (VIRTIO_NET_F_CSUM)                 *
 * ------------------------------------------------------------------ */

typedef enum {
    VN_TX_CSUM_NOT_REQUESTED = 0, /* no NEEDS_CSUM flag: nothing to do */
    VN_TX_CSUM_COMPLETED,
    VN_TX_CSUM_MALFORMED          /* offsets out of range, or unknown flag bits */
} VNTxCsumStatus;

/* Complete a partial checksum in place.
 *
 * Contract (Linux Documentation/networking/checksum-offloads.rst): the device
 * computes the 16-bit ones-complement sum from csum_start to the end of the
 * packet and stores the result at csum_start + csum_offset. Because
 * csum_offset cannot be negative, the previous content of the checksum field
 * is necessarily part of that sum - which is exactly how the driver hands over
 * its pseudo-header correction. This implementation therefore sums the region
 * *including* the seed word and complements the fold. It does not special-case
 * the field, does not zero it first, and does not assume which pseudo-header
 * the driver used; both are covered by the same arithmetic.
 *
 * f points at the first byte after the virtio_net_hdr and len is that frame's
 * length. Returns VN_TX_CSUM_MALFORMED without touching the frame when the
 * offsets do not fit, so the caller can count a driver violation instead of
 * writing outside the buffer. */
VNTxCsumStatus vn_tx_complete_csum(uint8_t *f, uint32_t len, const VNNetHdrFields *hdr);

/* ------------------------------------------------------------------ *
 * TX: TCP segmentation (VIRTIO_NET_F_HOST_TSO4 / TSO6)                *
 * ------------------------------------------------------------------ */

/* Receives one produced Ethernet frame, without any virtio_net_hdr. Returning
 * false stops segmentation immediately (the caller reports VN_SEG_STOPPED and
 * must not treat the super-packet as delivered). */
typedef bool (*vn_emit_fn)(void *opaque, const uint8_t *frame, uint32_t len);

typedef enum {
    VN_SEG_NOT_GSO = 0,   /* gso_type NONE: the caller passes the frame through */
    VN_SEG_OK,            /* every segment was emitted */
    VN_SEG_UNSUPPORTED,   /* a gso_type/ECN combination we do not advertise */
    VN_SEG_MALFORMED,     /* header/length/gso_size inconsistent with the frame */
    VN_SEG_STOPPED,       /* the emit callback refused; some segments went out */
    VN_SEG_BUDGET         /* the per-drain segment budget ran out */
} VNSegStatus;

typedef struct {
    uint32_t frames;      /* segments emitted */
    uint64_t bytes;       /* bytes emitted */
} VNSegReport;

/* Caller-owned segmentation context.
 *
 * max_out_frame is the link ceiling for produced frames; gso_size is clamped
 * down to (max_out_frame - header length) so a super-packet can never be
 * turned into a frame the backend has to drop. scratch/scratch_cap is the
 * build buffer, at least max_out_frame bytes; nothing is allocated here.
 * budget bounds how many frames this call may emit - and a super-packet is
 * never split across calls, because the guest has already been told the whole
 * thing was consumed. */
typedef struct {
    uint32_t max_out_frame;
    uint32_t budget;
    uint8_t *scratch;
    uint32_t scratch_cap;
} VNSegCtx;

/* Segment a TX super-packet.
 *
 * f/len describe the Ethernet frame that follows the virtio_net_hdr; hdr is
 * that header in host order; negotiated is the driver's accepted feature set.
 * Each emitted frame is a complete, independently valid Ethernet frame: its IP
 * length, IP ID, IP header checksum, TCP sequence number and TCP checksum are
 * all recomputed for that segment. Nothing is copied out unmodified except the
 * Ethernet header and the transport header's own fields.
 *
 * The transport checksum is recomputed from the segment's own bytes. A
 * driver-supplied partial seed is therefore never trusted to be right, and a
 * super-packet whose driver computed a whole-packet checksum is still segmented
 * into correctly checksummed frames. csum_start/csum_offset are validated when
 * NEEDS_CSUM is set (an out-of-range pair is a driver violation, not a hint).
 *
 * VN_SEG_BUDGET is returned with report->frames == 0 when the whole
 * super-packet cannot be emitted within ctx->budget. */
VNSegStatus vn_tx_segment(const uint8_t *f, uint32_t len,
                          const VNNetHdrFields *hdr, uint64_t negotiated,
                          const VNSegCtx *ctx,
                          vn_emit_fn emit, void *opaque,
                          VNSegReport *report);

/* ------------------------------------------------------------------ *
 * RX: transport checksum verdict (VIRTIO_NET_F_GUEST_CSUM)            *
 * ------------------------------------------------------------------ */

typedef enum {
    VN_RX_CSUM_UNKNOWN = 0, /* cannot be judged here: leave flags = 0 so the
                             * guest verifies it the way it always did */
    VN_RX_CSUM_VALID,       /* verified: DATA_VALID may be written */
    VN_RX_CSUM_INVALID      /* verified wrong: still deliver, never DATA_VALID */
} VNRxCsumVerdict;

/* Verify the transport checksum of a received frame.
 *
 * Returns UNKNOWN rather than guessing whenever the frame is not one this
 * device can judge: non-IP, a non-initial IPv4 fragment, an L4 it does not
 * implement, an IPv4 UDP datagram whose checksum field is zero (the sender
 * disabled it, so there is nothing to confirm) or a frame too short to contain
 * the field.
 *
 * A wrong checksum is reported, never acted on: the frame must still reach the
 * guest so its stack can count it. */
VNRxCsumVerdict vn_rx_verify(const uint8_t *f, uint32_t len,
                             const VNFrameInfo *info);

/* ------------------------------------------------------------------ *
 * RX: bounded TCP coalescing into a GSO super-frame                   *
 * ------------------------------------------------------------------ */

typedef enum {
    VN_COAL_OK = 0,
    VN_COAL_NOT_NEGOTIATED,  /* the GUEST_CSUM/GUEST_TSO bit for this family */
    VN_COAL_NOT_IP,          /* ARP, ND, non-IP: boundaries are always kept */
    VN_COAL_NOT_TCP,         /* ICMP, UDP: never coalesced */
    VN_COAL_FRAGMENTED,
    VN_COAL_CSUM_UNVERIFIED, /* we could not confirm it, so we may not merge */
    VN_COAL_FLAGS_BOUNDARY,  /* SYN, FIN, RST or PSH: half-close and push
                              * boundaries must stay visible to the guest */
    VN_COAL_DIFFERENT_FLOW,
    VN_COAL_HEADER_MISMATCH, /* TCP header bytes, window, ack, TOS, TTL, flow
                              * label or the IPv6 extension chain differ */
    VN_COAL_SEQ_DISCONTINUITY,
    VN_COAL_EMPTY_PAYLOAD,
    VN_COAL_SIZE_MISMATCH,   /* gso_size must describe every merged segment */
    VN_COAL_TOO_MANY_SEGMENTS,
    VN_COAL_TOO_LARGE,
    VN_COAL_MALFORMED
} VNCoalReason;

typedef struct {
    /* Snapshot of the first member; everything else is compared against it. */
    VNFrameInfo info;
    uint8_t  ip_version;    /* 4 or 6 */
    uint8_t  gso_type;      /* VN_GSO_TCPV4 / VN_GSO_TCPV6 */
    uint16_t l2_len;
    uint16_t l3_len;
    uint16_t tcp_hdr_len;
    uint16_t prefix_len;    /* l2_len + l3_len + tcp_hdr_len: replicated verbatim */
    uint16_t gso_size;      /* payload length of every merged segment */
    uint32_t seq_next;      /* seq the next member must carry */
    uint32_t total_payload;
    uint16_t count;
    /* Compared byte-for-byte or field-for-field on every append. */
    uint32_t ack;
    uint16_t window;
    uint8_t  tcp_flags;
    uint16_t sport, dport;
    uint8_t  saddr[16], daddr[16];
    uint8_t  addr_len;      /* 4 or 16 */
    uint8_t  tcp_hdr[VN_MAX_TCP_HLEN];  /* first member's transport header */
} VNCoalesce;

/* Parsed view of one candidate member. Filled by vn_coalesce_begin() and
 * vn_coalesce_append(); exposed so a test can assert on the exact boundary
 * that rejected a merge. */
typedef struct {
    VNFrameInfo   info;
    uint32_t      seq, ack;
    uint16_t      window;
    uint8_t       flags;
    uint8_t       hdr_len;
} VNTcpView;

/* caps bound one aggregate. max_payload must leave room for the replicated
 * prefix inside the 16-bit IP length field. */
typedef struct {
    uint32_t max_payload;
    uint16_t max_segments;
} VNCaps;

/* Examine f and, when it is eligible to root an aggregate, fill *c and *view.
 * The frame's transport checksum is verified here: a member is only ever
 * merged once this device has confirmed it, which is what makes the resulting
 * NEEDS_CSUM seed an honest statement. */
VNCoalReason vn_coalesce_begin(const uint8_t *f, uint32_t len, uint64_t negotiated,
                               VNCoalesce *c, VNTcpView *view);

/* Decide whether f may extend *c, and commit it when it may. Pure with respect
 * to f; only *c changes. member_payload is set to the bytes this member adds. */
VNCoalReason vn_coalesce_append(VNCoalesce *c, const uint8_t *f, uint32_t len,
                                const VNCaps *caps, uint32_t *member_payload);

typedef struct {
    const uint8_t *bytes;      /* the member's Ethernet frame, no virtio hdr */
    uint32_t       len;        /* total bytes available at bytes */
    uint32_t       payload_off;/* where this member's TCP payload starts */
    uint32_t       payload_len;/* IP-declared payload length, padding excluded */
} VNFrameRef;

/* Materialise the aggregate.
 *
 * dst receives VN_HDR_LEN bytes of virtio_net_hdr followed by the super-frame:
 * the first member's Ethernet + IP + TCP headers, then every member's payload
 * concatenated. cap is the size of dst and must already reflect the space the
 * guest actually posted.
 *
 * The header written is gso_type TCPV4/TCPV6, gso_size = the common segment
 * payload, hdr_len = prefix_len, and flags = NEEDS_CSUM with csum_start at the
 * TCP header and csum_offset = 16. The TCP checksum field is seeded with the
 * folded pseudo-header of the *super-frame* (protocol, addresses and the total
 * transport length), which is exactly the value the guest's segmentation path
 * adjusts by the per-segment length delta. DATA_VALID is not used for a
 * super-frame: one checksum cannot describe several segments, and claiming it
 * would be a false statement to the guest.
 *
 * Returns the total number of bytes written, or 0 when the aggregate does not
 * fit in cap or has fewer than two members (a single member is delivered by the
 * ordinary path instead). */
uint32_t vn_coalesce_emit(const VNCoalesce *c, const VNFrameRef *members,
                          uint16_t count, uint8_t *dst, uint32_t cap);

/* ------------------------------------------------------------------ *
 * Per-flow fair admission for the device RX ring                      *
 * ------------------------------------------------------------------ */

typedef struct {
    uint8_t  ip_version;   /* 0 = not an IP flow */
    uint8_t  proto;
    uint16_t sport, dport; /* host order */
    uint8_t  addr_len;     /* 4 or 16 */
    uint8_t  saddr[16], daddr[16];
} VNFlowKey;

/* Number of concurrently tracked flows. Small and fixed: this is a fairness
 * approximation for a ring of a few dozen slots, not a scheduler. */
#define VN_FLOW_SLOTS 16

typedef struct {
    VNFlowKey key;
    uint16_t  slots;
    bool      used;
} VNFairEntry;

typedef struct {
    VNFairEntry entry[VN_FLOW_SLOTS];
    uint16_t    tracked;
    uint64_t    admits;
    uint64_t    refusals;         /* refused by the per-flow share */
    uint64_t    table_full;       /* untracked flow: plain FIFO admission */
    uint64_t    control_bypass;   /* ARP/ICMP/ND admitted without the cap */
} VNFairness;

bool vn_flow_key(const uint8_t *f, uint32_t len, const VNFrameInfo *info,
                 VNFlowKey *out);
bool vn_flow_key_eq(const VNFlowKey *a, const VNFlowKey *b);

void vn_fairness_init(VNFairness *fq);
/* May this frame take one more ring slot?
 * ring_size/ring_used describe the device ring; bulk selects whether the
 * per-flow share applies. The share is ring_size divided by the number of
 * flows that currently hold data, with a floor of one slot, so an idle ring
 * behaves exactly like the legacy FIFO and a contended ring converges towards
 * an equal split. */
bool vn_fairness_admit(VNFairness *fq, const VNFlowKey *key, bool bulk,
                       uint16_t ring_size, uint16_t ring_used);
/* Give one slot back when the frame leaves the ring. */
void vn_fairness_release(VNFairness *fq, const VNFlowKey *key);
/* Drop all accounting (device reset); the ring itself is emptied by the caller. */
void vn_fairness_reset(VNFairness *fq);

/* ------------------------------------------------------------------ *
 * Counters                                                            *
 * ------------------------------------------------------------------ */

typedef struct {
    /* TX */
    uint64_t tx_frames;            /* super-packets accepted from the guest */
    uint64_t tx_passthrough;       /* forwarded as one ordinary frame */
    uint64_t tx_csum_completed;
    /* A GSO super-packet whose partial checksum was deliberately NOT completed:
     * the segmenter recomputes every segment's transport checksum from that
     * segment's own bytes, so completing the whole 64 KiB packet first would be
     * a full redundant checksum walk per super-packet. Counted so the saving is
     * visible and so a fallback that forgets to complete is detectable. */
    uint64_t tx_csum_deferred;
    uint64_t tx_segmented;         /* super-packets that were segmented */
    uint64_t tx_segments;          /* frames handed to the backend */
    uint64_t tx_seg_bytes;
    uint64_t tx_reject_malformed;
    uint64_t tx_reject_unsupported;
    uint64_t tx_reject_unnegotiated;
    uint64_t tx_reject_oversized;  /* descriptor chain exceeded the gather cap */
    uint64_t tx_budget_exhausted;
    /* RX */
    uint64_t rx_frames;            /* frames accepted into the ring */
    uint64_t rx_csum_valid;
    uint64_t rx_csum_invalid;
    uint64_t rx_csum_unknown;
    uint64_t rx_data_valid;        /* delivered with DATA_VALID set */
    uint64_t rx_aggregates;        /* super-frames delivered */
    uint64_t rx_aggregate_members; /* original frames those super-frames carried */
    uint64_t rx_delivered;         /* used-ring entries published to the guest */
    uint64_t rx_ring_full;         /* backend refused: ring had no slot */
    uint64_t rx_fair_refused;      /* backend refused: per-flow share reached */
    uint64_t rx_oversized;
    uint64_t rx_batch_capped;      /* a poll stopped early on the frame budget */
    uint64_t rx_truncated_buffer;  /* guest buffer smaller than the frame */
    /* Shared */
    uint64_t desc_index_violations;/* a descriptor index outside the ring */
} VNStats;

void vn_stats_init(VNStats *s);
/* Copy into caller-owned storage; any pointer may be NULL. Used by the
 * diagnostics accessor so the counters stay readable without exposing the
 * struct layout through the public C ABI. */
void vn_stats_export(const VNStats *s, uint64_t *out, size_t max);
size_t vn_stats_count(void);

#endif /* A64_VIRTIO_NET_OFFLOAD_H */
