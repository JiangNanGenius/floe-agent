/* SPDX-License-Identifier: MPL-2.0 */
/* Layer A: the production offload helpers against the independent oracle.
 *
 * These call the real functions from Source/src/devices/virtio_net_offload.c
 * (folded into virtio_net.c, which this host includes) and check every result
 * against OffloadOracle.h. No stubs, no fakes: the same code the device runs.
 */
#ifndef FLOE_NIC_OFFLOAD_UNIT_TESTS_H
#define FLOE_NIC_OFFLOAD_UNIT_TESTS_H

/* Capturing sink for segmentation. */
#define SEG_SINK_MAX 64
typedef struct {
    uint8_t  buf[SEG_SINK_MAX][1600];
    uint32_t len[SEG_SINK_MAX];
    uint32_t n;
    uint32_t refuse_at;      /* refuse once n reaches this */
} SegSink;

static bool seg_emit(void *opaque, const uint8_t *frame, uint32_t len) {
    SegSink *s = opaque;
    if (s->n >= s->refuse_at) return false;
    if (s->n >= SEG_SINK_MAX || len > sizeof(s->buf[0])) return false;
    memcpy(s->buf[s->n], frame, len);
    s->len[s->n] = len;
    s->n++;
    return true;
}

static void seg_sink_reset(SegSink *s, uint32_t refuse_at) {
    s->n = 0;
    s->refuse_at = refuse_at;
}

static void test_checksum_core(void) {
    static const uint8_t odd[9] = {0x01,0x02,0x03,0x04,0x05,0x06,0x07,0xf0,0x0f};
    static const uint8_t even[8] = {0xff,0xff,0x00,0x01,0xaa,0x55,0x10,0xf0};
    static uint8_t big[70000];
    static uint8_t pat[70000];

    CASE("checksum-core/rfc1071-agreement");
    /* Every prefix length of both an odd- and an even-sized region. */
    for (uint32_t n = 0; n <= sizeof(odd); n++)
        CHECK(vn_csum_region(odd, n) == ref_csum(odd, n));
    for (uint32_t n = 0; n <= sizeof(even); n++)
        CHECK(vn_csum_region(even, n) == ref_csum(even, n));
    /* Odd trailing byte contributes as the high byte of a padded word. */
    CHECK(vn_csum_region(odd, 9) == ref_csum(odd, 9));
    CHECK(vn_csum_region(odd, 9) != vn_csum_region(odd, 8));
    /* Cross the internal chunk boundary (65534 bytes) and force carries. */
    memset(big, 0xff, sizeof(big));
    for (uint32_t n = 65528; n <= 65540; n++)
        CHECK(vn_csum_region(big, n) == ref_csum(big, n));
    CHECK(vn_csum_region(big, (uint32_t)sizeof(big)) ==
          ref_csum(big, sizeof(big)));
    /* All-0xffff pairs sum to zero, so the complement is zero too. */
    CHECK(vn_csum_region(big, 2) == 0x0000u);
    /* Incremental accumulation must equal one-shot accumulation, provided
     * every chunk after the first starts at an even offset (RFC 1071 s4). A
     * non-uniform pattern is required here: an all-0xff region is symmetric and
     * would hide an odd-boundary regression. */
    for (uint32_t i = 0; i < sizeof(pat); i++) pat[i] = (uint8_t)(i * 31 + 7);
    {
        uint32_t a = vn_csum_add(0, pat, 1000);
        a = vn_csum_add(a, pat + 1000, 2000);
        a = vn_csum_add(a, pat + 3000, 1000);
        CHECK(vn_csum_fold(a) == ref_csum(pat, 4000));
    }
    /* And the constraint is real, not decorative: resuming at an odd offset
     * does not reconcile. Every split point inside virtio_net_offload.c is even
     * (csum offsets 16/6/2, transport header lengths multiples of 4, addresses
     * 4 and 16 bytes), which is what makes the no-parity signature safe. */
    {
        uint32_t b = vn_csum_add(0, pat, 1001);
        b = vn_csum_add(b, pat + 1001, 2999);
        CHECK(vn_csum_fold(b) != ref_csum(pat, 4000));
    }
    /* A pre-seeded accumulator folds identically to the reference seed. */
    {
        const uint8_t s4[4] = {10,0,2,15}, d4[4] = {10,0,2,2};
        CHECK(vn_pseudo4(s4, d4, 6, 40) == ref_seed4(IP_GUEST, IP_HOST, 6, 40));
        CHECK(vn_pseudo4(s4, d4, 17, 1500) == ref_seed4(IP_GUEST, IP_HOST, 17, 1500));
        CHECK(vn_pseudo6(IP6_LOCAL_A, IP6_LOCAL_B, 6, 1460) ==
              ref_seed6(IP6_LOCAL_A, IP6_LOCAL_B, 6, 1460));
        CHECK(vn_pseudo6(IP6_LOCAL_A, IP6_LOCAL_B, 58, 8) ==
              ref_seed6(IP6_LOCAL_A, IP6_LOCAL_B, 58, 8));
    }
    DONE();
}

static void test_frame_parse(void) {
    static TestFrame f;
    VNFrameInfo i;
    static uint8_t payload[100];

    memset(payload, 0x5a, sizeof(payload));

    CASE("parse/ipv4-tcp");
    mk_tcp4(&f, IP_GUEST, IP_HOST, 4000, 80, 1000, 2000, 0x10, 65535, 1, 0, 64,
            payload, 100);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.family == VN_FRAME_IPV4);
    CHECK(i.l3_off == 14 && i.l3_len == 20 && i.l4_off == 34);
    CHECK(i.l4_hdr_len == 20 && i.proto == VN_PROTO_TCP);
    CHECK(i.csum_off == 50 && i.payload_off == 54 && i.payload_len == 100);
    CHECK(i.l4_wire_len == 120);
    CHECK(!i.fragmented && !i.has_options);
    CHECK(i.sport == 4000 && i.dport == 80);
    CHECK(i.ip_id == 1 && i.dont_fragment && i.ttl == 64);
    CHECK(vn_frame_is_bulk(&i));
    DONE();

    CASE("parse/ipv6-tcp");
    mk_tcp6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 4001, 443, 1, 2, 0x10, 65535, 0x20,
            0x12345, payload, 100);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.family == VN_FRAME_IPV6);
    CHECK(i.l3_off == 14 && i.l3_len == 40 && i.l4_off == 54);
    CHECK(i.proto == VN_PROTO_TCP && i.csum_off == 70);
    CHECK(i.payload_len == 100 && i.l4_wire_len == 120);
    CHECK(i.flow_label == 0x12345 && i.ttl == 64 && i.tos == 0x20);
    CHECK(!i.has_options);
    DONE();

    CASE("parse/arp-is-opaque-and-not-bulk");
    mk_arp_request(&f);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.family == VN_FRAME_OTHER && i.proto == 0);
    CHECK(!vn_frame_is_bulk(&i));
    DONE();

    CASE("parse/icmp-is-not-bulk");
    mk_icmp4_echo(&f, IP_HOST, IP_GUEST);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.proto == VN_PROTO_ICMP && i.csum_off == 36 && i.l4_hdr_len == 8);
    CHECK(!vn_frame_is_bulk(&i));
    DONE();

    CASE("parse/udp-is-bulk");
    mk_udp4(&f, IP_HOST, IP_GUEST, 53, 5353, payload, 50);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.proto == VN_PROTO_UDP && i.l4_hdr_len == 8 && i.csum_off == 40);
    CHECK(i.sport == 53 && i.dport == 5353);
    CHECK(vn_frame_is_bulk(&i));
    DONE();

    CASE("parse/ipv4-fragment-is-flagged");
    eth_build(f.buf, MAC_HOST, MAC_GUEST, 0x0800);
    ipv4_build(f.buf + 14, IP_HOST, IP_GUEST, 6, 100, 0, 64, 3, false, 0x0010);
    memset(f.buf + 34, 0, 100);
    f.len = 134;
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.fragmented);
    /* More-fragments with a zero offset is still a fragment. */
    ipv4_build(f.buf + 14, IP_HOST, IP_GUEST, 6, 100, 0, 64, 3, false, 0x2000);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.fragmented);
    /* A DF-only packet is not a fragment. */
    ipv4_build(f.buf + 14, IP_HOST, IP_GUEST, 6, 100, 0, 64, 3, true, 0);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(!i.fragmented && i.dont_fragment);
    DONE();

    CASE("parse/truncated-headers-refused");
    mk_tcp4(&f, IP_GUEST, IP_HOST, 1, 2, 0, 0, 0x10, 0, 0, 0, 64, payload, 100);
    for (uint32_t n = 0; n < 14; n++)
        CHECK(vn_frame_parse(f.buf, n, &i) == VN_PARSE_SHORT);
    for (uint32_t n = 14; n < 34; n++)
        CHECK(vn_frame_parse(f.buf, n, &i) == VN_PARSE_SHORT);
    for (uint32_t n = 34; n < 54; n++) {
        VNParseStatus st = vn_frame_parse(f.buf, n, &i);
        CHECK(st == VN_PARSE_SHORT || st == VN_PARSE_UNSUPPORTED || i.proto == 0);
    }
    /* total_length shorter than the header, and longer than the frame */
    put_be16(f.buf + 16, 10);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_SHORT);
    put_be16(f.buf + 16, 60000);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_SHORT);
    DONE();

    CASE("parse/vlan-bad-version-and-bad-ihl-refused");
    mk_tcp4(&f, IP_GUEST, IP_HOST, 1, 2, 0, 0, 0x10, 0, 0, 0, 64, payload, 20);
    put_be16(f.buf + 12, 0x8100);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_UNSUPPORTED);
    put_be16(f.buf + 12, 0x88A8);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_UNSUPPORTED);
    put_be16(f.buf + 12, 0x0800);
    f.buf[14] = 0x55;                            /* version 5 */
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_UNSUPPORTED);
    f.buf[14] = 0x44;                            /* IHL 4 < 5 */
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_UNSUPPORTED);
    /* IHL 15 claims a 60-byte IP header. A frame too short for it must be
     * refused outright rather than parsed. */
    f.buf[14] = 0x4F;
    CHECK(vn_frame_parse(f.buf, 40, &i) == VN_PARSE_SHORT);
    /* At the full length the header is self-consistent (total_length 60 ==
     * IHL 60) but leaves no room for a transport header. The frame must then
     * degrade to "unknown L4" and never be offloaded, which is the safety
     * property that actually matters. */
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.l3_len == 60 && i.proto == 0 && i.l4_hdr_len == 0);
    CHECK(!vn_frame_is_bulk(&i));
    CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_UNKNOWN);
    DONE();

    CASE("parse/ipv6-jumbogram-and-version-refused");
    mk_tcp6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 1, 2, 0, 0, 0x10, 0, 0, 0, payload, 20);
    put_be16(f.buf + 18, 0);                     /* payload_length 0 */
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_UNSUPPORTED);
    mk_tcp6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 1, 2, 0, 0, 0x10, 0, 0, 0, payload, 20);
    f.buf[14] = (uint8_t)((f.buf[14] & 0x0f) | 0x50);   /* version 5 */
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_UNSUPPORTED);
    DONE();

    CASE("parse/ipv6-extension-chain-walked");
    {
        uint8_t tmp[200];
        eth_build(tmp, MAC_HOST, MAC_GUEST, 0x86DD);
        ipv6_build(tmp + 14, IP6_LOCAL_A, IP6_LOCAL_B, 0, 8 + 20 + 20, 0, 64, 0);
        tmp[54] = 6; tmp[55] = 0;                /* Hop-by-Hop, 8 bytes, -> TCP */
        memset(tmp + 56, 0, 6);
        tcp_build(tmp + 62, 1, 2, 0, 0, 0x10, 0);
        memcpy(tmp + 82, payload, 20);
        memcpy(f.buf, tmp, 102);
        f.len = 102;
        put_be16(f.buf + 78, ref_tcp6(IP6_LOCAL_A, IP6_LOCAL_B, f.buf + 62, 40));
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(i.family == VN_FRAME_IPV6 && i.has_options);
        CHECK(i.l3_len == 48 && i.l4_off == 62 && i.proto == VN_PROTO_TCP);
        CHECK(i.payload_len == 20 && i.csum_off == 78);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
        /* An over-long extension header must be refused, not walked off the end. */
        tmp[55] = 200;
        memcpy(f.buf, tmp, 102);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_SHORT);
        /* A Fragment header makes the transport header unjudgeable. */
        tmp[55] = 0;
        ipv6_build(tmp + 14, IP6_LOCAL_A, IP6_LOCAL_B, 44, 8 + 20 + 20, 0, 64, 0);
        tmp[54] = 6; tmp[55] = 0;
        memcpy(f.buf, tmp, 102);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(i.family == VN_FRAME_IPV6 && i.fragmented && i.proto == 0);
    }
    DONE();

    CASE("parse/ipv4-options-marked");
    {
        uint8_t tmp[200];
        eth_build(tmp, MAC_HOST, MAC_GUEST, 0x0800);
        memset(tmp + 14, 0, 24);
        tmp[14] = 0x46;                          /* IHL 6 -> 24 bytes */
        tmp[15] = 0;
        put_be16(tmp + 16, 24 + 20 + 20);
        put_be16(tmp + 18, 5);
        tmp[22] = 64; tmp[23] = 6;
        put_be32(tmp + 26, IP_HOST);
        put_be32(tmp + 30, IP_GUEST);
        put_be16(tmp + 24, ref_csum(tmp + 14, 24));
        tcp_build(tmp + 38, 1, 2, 0, 0, 0x10, 0);
        memcpy(tmp + 58, payload, 20);
        memcpy(f.buf, tmp, 78);
        f.len = 78;
        put_be16(f.buf + 54, ref_tcp4(IP_HOST, IP_GUEST, f.buf + 38, 40));
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(i.l3_len == 24 && i.l4_off == 38 && i.has_options);
        CHECK(i.payload_len == 20);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
    }
    DONE();
}

static void test_tx_partial_csum(void) {
    static TestFrame f;
    VNNetHdrFields h;
    static uint8_t payload[1500];
    uint32_t len;

    for (uint32_t i = 0; i < sizeof(payload); i++)
        payload[i] = (uint8_t)(i * 7 + 1);

    CASE("tx-csum/tcpv4-equals-reference");
    for (uint32_t n = 1; n <= 64; n++) {
        mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 0x1000, 42, 0, payload, n);
        memset(&h, 0, sizeof(h));
        h.flags = VN_HDR_F_NEEDS_CSUM; h.csum_start = 34; h.csum_offset = 16;
        len = f.len;
        CHECK(vn_tx_complete_csum(f.buf, len, &h) == VN_TX_CSUM_COMPLETED);
        CHECK(get_be16(f.buf + 50) == ref_tcp4(IP_GUEST, IP_HOST, f.buf + 34, 20 + n));
        /* And the RX verifier agrees the completed frame is valid. */
        {
            VNFrameInfo i;
            CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
            CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
        }
    }
    /* A large, odd-length payload crossing the internal chunk boundary. */
    mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 0x1000, 42, 0, payload, 1401);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM; h.csum_start = 34; h.csum_offset = 16;
    CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_COMPLETED);
    CHECK(get_be16(f.buf + 50) == ref_tcp4(IP_GUEST, IP_HOST, f.buf + 34, 20 + 1401));
    DONE();

    CASE("tx-csum/udpv4-equals-reference");
    for (uint32_t n = 1; n <= 33; n++) {
        mk_udp4(&f, IP_GUEST, IP_HOST, 5000, 53, payload, n);
        put_be16(f.buf + 40, ref_seed4(IP_GUEST, IP_HOST, 17, 8 + n));
        memset(&h, 0, sizeof(h));
        h.flags = VN_HDR_F_NEEDS_CSUM; h.csum_start = 34; h.csum_offset = 6;
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_COMPLETED);
        CHECK(get_be16(f.buf + 40) == ref_udp4(IP_GUEST, IP_HOST, f.buf + 34, 8 + n));
    }
    DONE();

    CASE("tx-csum/tcpv6-equals-reference");
    for (uint32_t n = 1; n <= 33; n++) {
        mk_gso6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 4000, 443, 7, 0, 0, payload, n);
        put_be16(f.buf + 70, ref_seed6(IP6_LOCAL_A, IP6_LOCAL_B, 6, 20 + n));
        memset(&h, 0, sizeof(h));
        h.flags = VN_HDR_F_NEEDS_CSUM; h.csum_start = 54; h.csum_offset = 16;
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_COMPLETED);
        CHECK(get_be16(f.buf + 70) ==
              ref_tcp6(IP6_LOCAL_A, IP6_LOCAL_B, f.buf + 54, 20 + n));
        {
            VNFrameInfo i;
            CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
            CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
        }
    }
    DONE();

    CASE("tx-csum/no-flag-is-a-no-op");
    mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, 100);
    {
        uint16_t before = get_be16(f.buf + 50);
        memset(&h, 0, sizeof(h));
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_NOT_REQUESTED);
        CHECK(get_be16(f.buf + 50) == before);
    }
    DONE();

    CASE("tx-csum/out-of-range-offsets-refused-without-writing");
    mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, 100);
    {
        uint16_t before = get_be16(f.buf + 50);
        memset(&h, 0, sizeof(h));
        h.flags = VN_HDR_F_NEEDS_CSUM;
        h.csum_start = 60000; h.csum_offset = 16;
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_MALFORMED);
        h.csum_start = 34; h.csum_offset = 60000;
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_MALFORMED);
        h.csum_start = 0xffff; h.csum_offset = 0xffff;   /* u16 wrap attempt */
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_MALFORMED);
        h.csum_start = (uint16_t)f.len; h.csum_offset = 0;
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_MALFORMED);
        h.csum_start = (uint16_t)(f.len - 1); h.csum_offset = 0;
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_MALFORMED);
        CHECK(get_be16(f.buf + 50) == before);           /* untouched */
    }
    DONE();

    CASE("tx-csum/zero-fold-becomes-ffff-for-udp-only");
    {
        uint8_t p[8];
        /* Constructed, not searched: solve for the trailing payload word that
         * makes the correct checksum exactly 0x0000, so the RFC 768
         * substitution is exercised deterministically. */
        uint64_t a;
        uint16_t adj;

        /* --- IPv4 UDP: a zero checksum must be transmitted as 0xFFFF --- */
        memset(p, 0, sizeof(p));
        p[0] = 1; p[1] = 2; p[2] = 3; p[3] = 4; p[4] = 5; p[5] = 6;
        mk_udp4(&f, IP_GUEST, IP_HOST, 5000, 53, p, 8);
        a = ref_ph4(0, IP_GUEST, IP_HOST, 17, 16);
        a = ref_acc(a, f.buf + 34, 6);      /* sport, dport, length */
        a = ref_acc(a, f.buf + 42, 6);      /* payload bytes 0..5 */
        adj = ref_mod65535(-(int64_t)ref_fold_raw(a));
        put_be16(p + 6, adj);
        mk_udp4(&f, IP_GUEST, IP_HOST, 5000, 53, p, 8);
        CHECK(ref_udp4(IP_GUEST, IP_HOST, f.buf + 34, 16) == 0);
        put_be16(f.buf + 40, ref_seed4(IP_GUEST, IP_HOST, 17, 16));
        memset(&h, 0, sizeof(h));
        h.flags = VN_HDR_F_NEEDS_CSUM; h.csum_start = 34; h.csum_offset = 6;
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_COMPLETED);
        CHECK(get_be16(f.buf + 40) == 0xFFFFu);
        /* A receiver must still accept it: zero would read as "no checksum". */
        {
            VNFrameInfo vi;
            CHECK(vn_frame_parse(f.buf, f.len, &vi) == VN_PARSE_OK);
            CHECK(vi.proto == VN_PROTO_UDP);
            CHECK(vn_rx_verify(f.buf, f.len, &vi) == VN_RX_CSUM_VALID);
        }

        /* --- IPv6 UDP: RFC 8200 makes the checksum mandatory and forbids a
         * transmitted zero, so a computed zero must be sent as 0xFFFF too -
         * the same substitution, for a different reason. --- */
        memset(p, 0, sizeof(p));
        p[0] = 9; p[1] = 8; p[2] = 7; p[3] = 6; p[4] = 5; p[5] = 4;
        {
            uint8_t o[200];
            eth_build(o, MAC_GUEST, MAC_HOST, 0x86DD);
            ipv6_build(o + 14, IP6_LOCAL_A, IP6_LOCAL_B, 17, 16, 0, 64, 0);
            udp_build(o + 54, 5000, 53, 8);
            memcpy(o + 62, p, 8);
            memcpy(f.buf, o, 70); f.len = 70;
            a = ref_ph6(0, IP6_LOCAL_A, IP6_LOCAL_B, 17, 16);
            a = ref_acc(a, f.buf + 54, 6);
            a = ref_acc(a, f.buf + 62, 6);
            adj = ref_mod65535(-(int64_t)ref_fold_raw(a));
            put_be16(p + 6, adj);
            memcpy(f.buf + 62, p, 8);
            put_be16(f.buf + 60, 0);
            CHECK(ref_udp6(IP6_LOCAL_A, IP6_LOCAL_B, f.buf + 54, 16) == 0);
            put_be16(f.buf + 60, ref_seed6(IP6_LOCAL_A, IP6_LOCAL_B, 17, 16));
            memset(&h, 0, sizeof(h));
            h.flags = VN_HDR_F_NEEDS_CSUM; h.csum_start = 54; h.csum_offset = 6;
            CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_COMPLETED);
            CHECK(get_be16(f.buf + 60) == 0xFFFFu);
            {
                VNFrameInfo vi;
                CHECK(vn_frame_parse(f.buf, f.len, &vi) == VN_PARSE_OK);
                CHECK(vi.family == VN_FRAME_IPV6 && vi.proto == VN_PROTO_UDP);
                CHECK(vn_rx_verify(f.buf, f.len, &vi) == VN_RX_CSUM_VALID);
            }
        }

        /* --- IPv4 TCP: no such rule, a zero fold must stay zero --- */
        memset(p, 0, sizeof(p));
        p[0] = 0x11; p[1] = 0x22; p[2] = 0x33; p[3] = 0x44;
        p[4] = 0x55; p[5] = 0x66;
        mk_tcp4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 0, 0x10, 1000, 1, 0, 64,
                p, 8);
        a = ref_ph4(0, IP_GUEST, IP_HOST, 6, 28);
        a = ref_acc(a, f.buf + 34, 16);     /* TCP header, csum field excluded */
        a = ref_acc(a, f.buf + 54, 6);      /* payload bytes 0..5 */
        adj = ref_mod65535(-(int64_t)ref_fold_raw(a));
        put_be16(p + 6, adj);
        mk_tcp4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 0, 0x10, 1000, 1, 0, 64,
                p, 8);
        CHECK(ref_tcp4(IP_GUEST, IP_HOST, f.buf + 34, 28) == 0);
        put_be16(f.buf + 50, ref_seed4(IP_GUEST, IP_HOST, 6, 28));
        memset(&h, 0, sizeof(h));
        h.flags = VN_HDR_F_NEEDS_CSUM; h.csum_start = 34; h.csum_offset = 16;
        CHECK(vn_tx_complete_csum(f.buf, f.len, &h) == VN_TX_CSUM_COMPLETED);
        CHECK(get_be16(f.buf + 50) == 0);
        printf("  zero-fold: udp4->0xFFFF, udp6->0xFFFF, tcp4->0x0000\n");
    }
    DONE();
}

static void verify_segments_v4(SegSink *sink, const TestFrame *orig,
                               const uint8_t *payload, uint32_t plen,
                               uint32_t seg_payload, uint32_t base_seq,
                               uint16_t base_id, bool expect_ecn) {
    uint32_t at = 0;
    for (uint32_t i = 0; i < sink->n; i++) {
        const uint8_t *s = sink->buf[i];
        uint32_t sl = sink->len[i];
        uint32_t pl = (plen - at > seg_payload) ? seg_payload : plen - at;
        uint8_t tmp[1600];
        VNFrameInfo si;

        CHECK(sl == 54 + pl);
        CHECK(vn_frame_parse(s, sl, &si) == VN_PARSE_OK);
        CHECK(si.family == VN_FRAME_IPV4 && si.proto == VN_PROTO_TCP);
        CHECK(memcmp(s, orig->buf, 14) == 0);              /* Ethernet header */
        CHECK(get_be16(s + 16) == 20 + 20 + pl);           /* total length */
        CHECK(get_be16(s + 18) == (uint16_t)(base_id + i)); /* ID advances */
        CHECK(ref_csum(s + 14, 20) == 0);                  /* header checksum */
        CHECK(get_be32(s + 38) == base_seq + at);          /* sequence */
        CHECK(s[47] == 0x10);                              /* flags */
        CHECK(get_be16(s + 48) == 65535);                  /* window */
        CHECK((s[15] & VN_INET_ECN_MASK) == (expect_ecn ? (orig->buf[15] & VN_INET_ECN_MASK) : 0));
        CHECK(memcmp(s + 54, payload + at, pl) == 0);      /* payload bytes */
        memcpy(tmp, s + 34, 20 + pl);
        put_be16(tmp + 16, 0);
        CHECK(get_be16(s + 50) == ref_tcp4(IP_GUEST, IP_HOST, tmp, 20 + pl));
        CHECK(vn_rx_verify(s, sl, &si) == VN_RX_CSUM_VALID);
        at += pl;
    }
    CHECK(at == plen);
}

static void test_tx_segment_v4(void) {
    static TestFrame f;
    static SegSink sink;
    VNNetHdrFields h;
    VNSegCtx ctx;
    VNSegReport rep;
    uint8_t segbuf[1600];
    /* 45 segments of 1400 bytes is the largest super-packet exercised below. */
    static uint8_t payload[45 * 1400];
    uint32_t plen, flen;

    for (uint32_t i = 0; i < sizeof(payload); i++)
        payload[i] = (uint8_t)(i * 31 + 7);

    ctx.max_out_frame = 1518;
    ctx.scratch = segbuf;
    ctx.scratch_cap = sizeof(segbuf);

    CASE("tx-tso4/45-segments-match-reference");
    plen = 45 * 1400;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 0x00001000u, 0x1234, 0,
                    payload, plen), f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16; h.hdr_len = 54;
    ctx.budget = VN_TX_SEGMENT_BUDGET;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(rep.frames == 45 && sink.n == 45);
    CHECK(rep.bytes == 45 * (54 + 1400));
    verify_segments_v4(&sink, &f, payload, plen, 1400, 0x00001000u, 0x1234, false);
    DONE();

    CASE("tx-tso4/uneven-tail-segment");
    plen = 3 * 1400 + 137;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 500, 9, 0, payload, plen),
            f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(sink.n == 4);
    CHECK(sink.len[3] == 54 + 137);
    CHECK(get_be32(sink.buf[3] + 38) == 500 + 3 * 1400);
    verify_segments_v4(&sink, &f, payload, plen, 1400, 500, 9, false);
    DONE();

    CASE("tx-tso4/one-byte-and-single-segment-cases");
    plen = 1;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, plen),
            f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(sink.n == 1 && sink.len[0] == flen);
    /* A one-segment super-packet is not a byte-for-byte copy: the input carries
     * the partial-checksum seed in the TCP checksum field, and the device must
     * replace it with the completed checksum. Everything else is untouched. */
    CHECK(memcmp(sink.buf[0], f.buf, 50) == 0);
    CHECK(memcmp(sink.buf[0] + 52, f.buf + 52, flen - 52) == 0);
    {
        uint8_t tmp[1600];
        memcpy(tmp, sink.buf[0] + 34, 20 + 1);
        put_be16(tmp + 16, 0);
        CHECK(get_be16(sink.buf[0] + 50) == ref_tcp4(IP_GUEST, IP_HOST, tmp, 21));
        CHECK(get_be16(f.buf + 50) != get_be16(sink.buf[0] + 50));
    }
    CHECK(ref_csum(sink.buf[0] + 14, 20) == 0);   /* IPv4 header still valid */
    /* gso_size larger than the payload still yields exactly one segment */
    plen = 900;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, plen),
            f.len);
    h.gso_size = 1400;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(sink.n == 1);
    verify_segments_v4(&sink, &f, payload, plen, 1400, 1, 1, false);
    DONE();

    CASE("tx-tso4/clamped-to-link-mtu");
    plen = 2 * 4000;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, plen),
            f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 8000;   /* above the link ceiling */
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    /* 8000 payload bytes at the clamped 1464 = 5 full segments plus a 680 byte
     * tail. Nothing may exceed the link ceiling. */
    CHECK(sink.n == 6);
    for (uint32_t i = 0; i < 5; i++) CHECK(sink.len[i] == 54 + 1464);
    CHECK(sink.len[5] == 54 + (8000 - 5 * 1464));
    CHECK(sink.len[5] == 54 + 680);
    for (uint32_t i = 0; i < sink.n; i++) CHECK(sink.len[i] <= 1518);
    verify_segments_v4(&sink, &f, payload, plen, 1464, 1, 1, false);
    DONE();

    CASE("tx-tso4/sequence-number-wraparound");
    plen = 3 * 1400;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 0xFFFFFF00u, 7, 0,
                    payload, plen), f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(sink.n == 3);
    CHECK(get_be32(sink.buf[0] + 38) == 0xFFFFFF00u);
    CHECK(get_be32(sink.buf[1] + 38) == 0xFFFFFF00u + 1400u);
    CHECK(get_be32(sink.buf[2] + 38) == 0xFFFFFF00u + 2800u);   /* wrapped */
    verify_segments_v4(&sink, &f, payload, plen, 1400, 0xFFFFFF00u, 7, false);
    DONE();

    CASE("tx-tso4/ip-id-wraparound");
    plen = 3 * 1400;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 0xFFFE, 0, payload, plen),
            f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(get_be16(sink.buf[0] + 18) == 0xFFFEu);
    CHECK(get_be16(sink.buf[1] + 18) == 0xFFFFu);
    CHECK(get_be16(sink.buf[2] + 18) == 0x0000u);
    for (uint32_t i = 0; i < sink.n; i++) CHECK(ref_csum(sink.buf[i] + 14, 20) == 0);
    DONE();

    CASE("tx-tso4/ecn-cleared-without-host-ecn-preserved-with-it");
    plen = 2 * 1400;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0x03 /* CE */,
                    payload, plen), f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4 | VN_GSO_ECN; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(sink.n == 2);
    for (uint32_t i = 0; i < sink.n; i++) {
        CHECK((sink.buf[i][15] & VN_INET_ECN_MASK) == 0);
        CHECK((sink.buf[i][15] & 0xFCu) == 0);      /* DSCP preserved */
        CHECK(ref_csum(sink.buf[i] + 14, 20) == 0);
    }
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h,
                        VN_F_CSUM | VN_F_HOST_TSO4 | VN_F_HOST_ECN, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    for (uint32_t i = 0; i < sink.n; i++)
        CHECK((sink.buf[i][15] & VN_INET_ECN_MASK) == 0x03);
    DONE();

    CASE("tx-tso4/without-needs-csum-still-segments-correctly");
    plen = 2 * 1400;
    mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 77, 5, 0, payload, plen);
    put_be16(f.buf + 50, ref_tcp4(IP_GUEST, IP_HOST, f.buf + 34, 20 + plen));
    flen = f.len;
    memset(&h, 0, sizeof(h));
    h.flags = 0;                     /* driver computed a whole-packet checksum */
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(sink.n == 2);
    verify_segments_v4(&sink, &f, payload, plen, 1400, 77, 5, false);
    DONE();

    CASE("tx-tso4/budget-refuses-atomically-and-stop-is-honoured");
    plen = 45 * 1400;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, plen),
            f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    ctx.budget = 10;
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_BUDGET);
    CHECK(rep.frames == 0 && sink.n == 0);      /* nothing half-sent */
    ctx.budget = 45;
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(sink.n == 45);
    seg_sink_reset(&sink, 3);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_STOPPED);
    CHECK(rep.frames == 3 && sink.n == 3);
    ctx.budget = VN_TX_SEGMENT_BUDGET;
    DONE();

    CASE("tx-tso4/malformed-and-unsupported-refused");
    plen = 2 * 1400;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, plen),
            f.len);
    seg_sink_reset(&sink, UINT32_MAX);
    memset(&h, 0, sizeof(h));
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 0;              /* zero MSS */
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_MALFORMED);
    CHECK(sink.n == 0);
    h.gso_size = 1400; h.flags = VN_HDR_F_NEEDS_CSUM;
    h.csum_start = 60000; h.csum_offset = 16;               /* out of range */
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_MALFORMED);
    h.csum_start = 34; h.csum_offset = 60000;
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_MALFORMED);
    h.csum_start = 34; h.csum_offset = 16;
    /* Feature not negotiated -> must refuse rather than segment. */
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_UNSUPPORTED);
    CHECK(vn_tx_segment(f.buf, flen, &h, 0, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_UNSUPPORTED);
    /* TSO6 not negotiated: refused as unsupported before the frame is even
     * parsed, because the device must not act on a feature it did not offer. */
    h.gso_type = VN_GSO_TCPV6;
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_UNSUPPORTED);
    /* TSO6 negotiated but the frame is IPv4: the requested segmentation is
     * supported, the header contradicts the packet, so this is malformed rather
     * than unsupported. The distinction matters because the device counts the
     * two differently. */
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO6, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_MALFORMED);
    h.gso_type = VN_GSO_TCPV4;
    /* UFO and USO are not implemented and must never be accepted. */
    h.gso_type = VN_GSO_UDP;
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_OFFLOAD_TX_FEATURES, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_UNSUPPORTED);
    h.gso_type = VN_GSO_UDP_L4;
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_OFFLOAD_TX_FEATURES, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_UNSUPPORTED);
    /* gso_type NONE must be reported so the caller passes the frame through. */
    h.gso_type = VN_GSO_NONE;
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_OFFLOAD_TX_FEATURES, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_NOT_GSO);
    CHECK(sink.n == 0);
    DONE();

    CASE("tx-tso4/truncated-super-packet-refused-not-segmented");
    plen = 2 * 1400;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, plen),
            f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    /* A descriptor gather that stopped short looks exactly like this: the IP
     * header still claims the full length. Segmenting it would emit payload
     * bytes that were never transferred. */
    CHECK(vn_tx_segment(f.buf, flen - 1400, &h, VN_F_CSUM | VN_F_HOST_TSO4,
                        &ctx, seg_emit, &sink, &rep) == VN_SEG_MALFORMED);
    CHECK(sink.n == 0);
    /* A zero-payload super-packet is not segmentable either. */
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, 0),
            f.len);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_MALFORMED);
    DONE();

    CASE("tx-tso4/prefix-too-large-for-output-ceiling-refused");
    plen = 2 * 1400;
    flen = (mk_gso4(&f, IP_GUEST, IP_HOST, 4000, 80, 1, 1, 0, payload, plen),
            f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;
    h.csum_start = 34; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    ctx.max_out_frame = 54;                     /* no room for any payload */
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_MALFORMED);
    CHECK(sink.n == 0);
    ctx.max_out_frame = 1518;
    DONE();
}

static void test_tx_segment_v6(void) {
    static TestFrame f;
    static SegSink sink;
    VNNetHdrFields h;
    VNSegCtx ctx;
    VNSegReport rep;
    uint8_t segbuf[1600];
    static uint8_t payload[6000];
    uint32_t plen, flen;

    for (uint32_t i = 0; i < sizeof(payload); i++)
        payload[i] = (uint8_t)(i ^ 0xa5);

    ctx.max_out_frame = 1518; ctx.budget = VN_TX_SEGMENT_BUDGET;
    ctx.scratch = segbuf; ctx.scratch_cap = sizeof(segbuf);

    CASE("tx-tso6/segments-match-reference");
    plen = 3 * 1400 + 33;
    flen = (mk_gso6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 4000, 443, 0x2000,
                    0x20 /* ECT(0) */, 0, payload, plen), f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV6; h.gso_size = 1400;
    h.csum_start = 54; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO6, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    CHECK(sink.n == 4);
    {
        uint32_t at = 0;
        for (uint32_t i = 0; i < sink.n; i++) {
            const uint8_t *s = sink.buf[i];
            uint32_t sl = sink.len[i];
            uint32_t pl = (plen - at > 1400) ? 1400 : plen - at;
            uint8_t tmp[1600];
            VNFrameInfo si;

            CHECK(sl == 74 + pl);
            CHECK(vn_frame_parse(s, sl, &si) == VN_PARSE_OK);
            CHECK(si.family == VN_FRAME_IPV6 && si.proto == VN_PROTO_TCP);
            CHECK(memcmp(s, f.buf, 14) == 0);
            CHECK(get_be16(s + 18) == 20 + pl);          /* payload_length */
            CHECK(s[14 + 7] == 64);                      /* hop limit */
            /* traffic class preserved except the ECN bits, flow label intact */
            CHECK((uint8_t)((s[14] & 0x0f) << 4 | (s[15] >> 4)) ==
                  (uint8_t)(0x20 & ~0x03));
            CHECK((get_be32(s + 14) & 0x000fffffu) == 0);
            CHECK(get_be32(s + 58) == 0x2000 + at);      /* sequence */
            CHECK(memcmp(s + 74, payload + at, pl) == 0);
            memcpy(tmp, s + 54, 20 + pl);
            put_be16(tmp + 16, 0);
            CHECK(get_be16(s + 70) ==
                  ref_tcp6(IP6_LOCAL_A, IP6_LOCAL_B, tmp, 20 + pl));
            CHECK(vn_rx_verify(s, sl, &si) == VN_RX_CSUM_VALID);
            at += pl;
        }
        CHECK(at == plen);
    }
    DONE();

    CASE("tx-tso6/ecn-bits-in-traffic-class-cleared");
    plen = 2 * 1400;
    flen = (mk_gso6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 4000, 443, 1, 0x23, 0,
                    payload, plen), f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV6 | VN_GSO_ECN; h.gso_size = 1400;
    h.csum_start = 54; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO6, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_OK);
    for (uint32_t i = 0; i < sink.n; i++) {
        uint8_t tc = (uint8_t)((sink.buf[i][14] & 0x0f) << 4 |
                               (sink.buf[i][15] >> 4));
        CHECK((tc & 0x03) == 0);          /* ECN cleared */
        CHECK((tc & 0xFC) == (0x23 & 0xFC));   /* DSCP preserved */
        CHECK((sink.buf[i][15] & 0x0f) == 0);  /* flow label high nibble intact */
    }
    DONE();

    CASE("tx-tso6/wrong-family-gso-type-refused");
    flen = (mk_gso6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 4000, 443, 1, 0, 0,
                    payload, 2800), f.len);
    memset(&h, 0, sizeof(h));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV4; h.gso_size = 1400;   /* lies about the family */
    h.csum_start = 54; h.csum_offset = 16;
    seg_sink_reset(&sink, UINT32_MAX);
    CHECK(vn_tx_segment(f.buf, flen, &h, VN_F_CSUM | VN_F_HOST_TSO4, &ctx,
                        seg_emit, &sink, &rep) == VN_SEG_MALFORMED);
    CHECK(sink.n == 0);
    DONE();
}

static void test_rx_verify(void) {
    static TestFrame f;
    VNFrameInfo i;
    static uint8_t payload[600];

    for (uint32_t k = 0; k < sizeof(payload); k++) payload[k] = (uint8_t)(k * 3);

    CASE("rx-csum/valid-and-invalid-tcp-udp-icmp-v4-v6");
    /* Odd lengths exercise the trailing-byte rule on every protocol. */
    for (uint32_t n = 1; n <= 41; n++) {
        mk_tcp4(&f, IP_HOST, IP_GUEST, 80, 4000, 1, 2, 0x10, 1000, 0, 0, 64,
                payload, n);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
        corrupt_at(&f, 50);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_INVALID);

        mk_udp4(&f, IP_HOST, IP_GUEST, 53, 4000, payload, n);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
        corrupt_at(&f, 40);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_INVALID);

        mk_tcp6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 443, 4000, 1, 2, 0x10, 1000, 0,
                0, payload, n);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
        corrupt_at(&f, 70);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_INVALID);
    }
    /* IPv6 UDP: the pseudo-header is mandatory, unlike IPv4 UDP. */
    {
        uint8_t o[200];
        eth_build(o, MAC_HOST, MAC_GUEST, 0x86DD);
        ipv6_build(o + 14, IP6_LOCAL_A, IP6_LOCAL_B, 17, 8 + 64, 0, 64, 0);
        udp_build(o + 54, 5353, 53, 64);
        memcpy(o + 62, payload, 64);
        memcpy(f.buf, o, 126); f.len = 126;
        put_be16(f.buf + 60, ref_udp6(IP6_LOCAL_A, IP6_LOCAL_B, f.buf + 54, 72));
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(i.family == VN_FRAME_IPV6 && i.proto == VN_PROTO_UDP);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
        corrupt_at(&f, 60);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_INVALID);
        /* A zero UDP checksum is illegal in IPv6 and must not be called valid. */
        put_be16(f.buf + 60, 0);
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_INVALID);
    }
    /* ICMPv4 has no pseudo-header; ICMPv6 does. Both must be judged correctly. */
    mk_icmp4_echo(&f, IP_HOST, IP_GUEST);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
    corrupt_at(&f, 36);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_INVALID);
    mk_icmp6_echo(&f, IP6_LOCAL_A, IP6_LOCAL_B, payload, 16);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.proto == VN_PROTO_ICMPV6);
    CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
    corrupt_at(&f, 56);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_INVALID);
    DONE();

    CASE("rx-csum/unknown-cases-are-never-claimed-valid");
    /* IPv4 UDP with a zero checksum means "none": nothing to confirm. */
    mk_udp4(&f, IP_HOST, IP_GUEST, 53, 4000, payload, 100);
    put_be16(f.buf + 40, 0);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_UNKNOWN);
    /* ARP has no transport checksum at all. */
    mk_arp_request(&f);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_UNKNOWN);
    /* A non-initial IPv4 fragment: no transport header present. */
    eth_build(f.buf, MAC_HOST, MAC_GUEST, 0x0800);
    ipv4_build(f.buf + 14, IP_HOST, IP_GUEST, 6, 100, 0, 64, 3, false, 0x0020);
    memset(f.buf + 34, 0, 100);
    f.len = 134;
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(i.fragmented);
    CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_UNKNOWN);
    /* Ethernet padding beyond the IP length must not be folded in. */
    mk_tcp4(&f, IP_HOST, IP_GUEST, 80, 4000, 1, 2, 0x10, 1000, 0, 0, 64,
            payload, 1);
    {
        uint32_t real = f.len;
        memset(f.buf + real, 0xAB, 20);
        f.len = real + 20;
        CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
        CHECK(vn_rx_verify(f.buf, f.len, &i) == VN_RX_CSUM_VALID);
    }
    DONE();
}

static void test_coalesce_rules(void) {
    static TestFrame a, b, c;
    VNCoalesce co;
    VNTcpView view;
    VNCaps caps;
    static uint8_t payload[1400];
    uint64_t full = VN_F_GUEST_CSUM | VN_F_GUEST_TSO4 | VN_F_GUEST_TSO6;
    uint32_t added;

    for (uint32_t k = 0; k < sizeof(payload); k++) payload[k] = (uint8_t)(k + 1);
    caps.max_payload = VN_RX_COALESCE_MAX_PAYLOAD;
    caps.max_segments = VN_RX_COALESCE_MAX_SEGMENTS;

    CASE("coalesce/happy-path-and-independent-super-frame-check");
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 1000, 2000, 0x10, 65535, 1, 0, 64,
            payload, 1400);
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2400, 2000, 0x10, 65535, 2, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_OK);
    CHECK(co.gso_type == VN_GSO_TCPV4 && co.gso_size == 1400 && co.count == 1);
    CHECK(co.prefix_len == 54 && co.ip_version == 4);
    CHECK(view.seq == 1000 && view.ack == 2000 && view.flags == 0x10);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) == VN_COAL_OK);
    CHECK(added == 1400 && co.count == 2 && co.total_payload == 2800);
    {
        VNFrameRef mem[2];
        static uint8_t dst[70000];
        static uint8_t expect[2800];
        uint32_t n;
        mem[0].bytes = a.buf; mem[0].len = a.len;
        mem[0].payload_off = co.prefix_len; mem[0].payload_len = 1400;
        mem[1].bytes = b.buf; mem[1].len = b.len;
        mem[1].payload_off = co.prefix_len; mem[1].payload_len = 1400;
        n = vn_coalesce_emit(&co, mem, 2, dst, sizeof(dst));
        CHECK(n == VN_HDR_LEN + co.prefix_len + 2800);
        memcpy(expect, payload, 1400);
        memcpy(expect + 1400, payload, 1400);
        verify_super_frame(dst, dst + VN_HDR_LEN, n - VN_HDR_LEN, 2,
                           expect, 2800, 1000);
        /* A single member is never emitted as a super-frame. */
        CHECK(vn_coalesce_emit(&co, mem, 1, dst, sizeof(dst)) == 0);
        /* A destination one byte too small must be refused, not truncated. */
        CHECK(vn_coalesce_emit(&co, mem, 2, dst, n - 1) == 0);
        /* A member count that disagrees with the aggregate is refused. */
        CHECK(vn_coalesce_emit(&co, mem, 3, dst, sizeof(dst)) == 0);
    }
    DONE();

    CASE("coalesce/every-protocol-boundary-is-preserved");
    {
        struct { const char *name; uint8_t flags; } cases[] = {
            {"syn", 0x12}, {"fin", 0x11}, {"rst", 0x14}, {"psh", 0x18},
            {"urg", 0x30}, {"ece", 0x50}, {"cwr", 0x90}, {"no-ack", 0x00},
        };
        for (unsigned k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
            mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 1000, 2000, 0x10, 65535,
                    1, 0, 64, payload, 1400);
            mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2400, 2000, cases[k].flags,
                    65535, 2, 0, 64, payload, 1400);
            CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_OK);
            CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
                  VN_COAL_FLAGS_BOUNDARY);
            /* The boundary frame may not root an aggregate either. */
            CHECK(vn_coalesce_begin(b.buf, b.len, full, &co, &view) ==
                  VN_COAL_FLAGS_BOUNDARY);
        }
    }
    DONE();

    CASE("coalesce/rejects-un-negotiated-features");
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 1, 2, 0x10, 65535, 1, 0, 64,
            payload, 100);
    CHECK(vn_coalesce_begin(a.buf, a.len, 0, &co, &view) == VN_COAL_NOT_NEGOTIATED);
    CHECK(vn_coalesce_begin(a.buf, a.len, VN_F_GUEST_TSO4, &co, &view) ==
          VN_COAL_NOT_NEGOTIATED);                       /* no GUEST_CSUM */
    CHECK(vn_coalesce_begin(a.buf, a.len, VN_F_GUEST_CSUM, &co, &view) ==
          VN_COAL_NOT_NEGOTIATED);                       /* no GUEST_TSO4 */
    CHECK(vn_coalesce_begin(a.buf, a.len, VN_F_GUEST_CSUM | VN_F_GUEST_TSO6,
                            &co, &view) == VN_COAL_NOT_NEGOTIATED);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_OK);
    DONE();

    CASE("coalesce/rejects-non-ip-and-non-tcp");
    mk_arp_request(&a);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_NOT_IP);
    mk_icmp4_echo(&a, IP_HOST, IP_GUEST);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_NOT_TCP);
    mk_icmp6_echo(&a, IP6_LOCAL_A, IP6_LOCAL_B, payload, 16);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_NOT_TCP);
    mk_udp4(&a, IP_HOST, IP_GUEST, 53, 4000, payload, 100);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_NOT_TCP);
    /* An IPv6 aggregate must not absorb an IPv4 frame. */
    mk_tcp6(&b, IP6_LOCAL_A, IP6_LOCAL_B, 80, 4000, 101, 2, 0x10, 65535, 0, 0,
            payload, 100);
    CHECK(vn_coalesce_begin(b.buf, b.len, full, &co, &view) == VN_COAL_OK);
    CHECK(co.gso_type == VN_GSO_TCPV6);
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 201, 2, 0x10, 65535, 1, 0, 64,
            payload, 100);
    CHECK(vn_coalesce_append(&co, a.buf, a.len, &caps, &added) ==
          VN_COAL_DIFFERENT_FLOW);
    DONE();

    CASE("coalesce/rejects-bad-checksum-fragment-and-empty-payload");
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 1, 2, 0x10, 65535, 1, 0, 64,
            payload, 100);
    corrupt_at(&a, 50);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) ==
          VN_COAL_CSUM_UNVERIFIED);
    /* A fragmented TCP frame has no trustworthy transport header. */
    eth_build(a.buf, MAC_HOST, MAC_GUEST, 0x0800);
    ipv4_build(a.buf + 14, IP_HOST, IP_GUEST, 6, 120, 0, 64, 3, false, 0x0010);
    tcp_build(a.buf + 34, 80, 4000, 1, 2, 0x10, 65535);
    memcpy(a.buf + 54, payload, 100);
    a.len = 154;
    put_be16(a.buf + 50, ref_tcp4(IP_HOST, IP_GUEST, a.buf + 34, 120));
    CHECK(vn_frame_parse(a.buf, a.len, &view.info) == VN_PARSE_OK);
    CHECK(view.info.fragmented);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) ==
          VN_COAL_FRAGMENTED);
    /* A pure ACK carries no payload to merge. */
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 1, 2, 0x10, 65535, 1, 0, 64,
            NULL, 0);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) ==
          VN_COAL_EMPTY_PAYLOAD);
    DONE();

    CASE("coalesce/rejects-flow-header-seq-and-size-changes");
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 1000, 2000, 0x10, 65535, 1, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_OK);
    /* different source port */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 81, 4000, 2400, 2000, 0x10, 65535, 2, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_DIFFERENT_FLOW);
    /* different source address */
    mk_tcp4(&b, 0x0A000203u, IP_GUEST, 80, 4000, 2400, 2000, 0x10, 65535, 2, 0,
            64, payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_DIFFERENT_FLOW);
    /* different acknowledgment number */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2400, 2001, 0x10, 65535, 2, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_HEADER_MISMATCH);
    /* different window */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2400, 2000, 0x10, 30000, 2, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_HEADER_MISMATCH);
    /* different TOS */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2400, 2000, 0x10, 65535, 2, 0x08,
            64, payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_HEADER_MISMATCH);
    /* different TTL */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2400, 2000, 0x10, 65535, 2, 0, 63,
            payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_HEADER_MISMATCH);
    /* sequence gap forward */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2401, 2000, 0x10, 65535, 2, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_SEQ_DISCONTINUITY);
    /* retransmit: sequence behind */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 1000, 2000, 0x10, 65535, 2, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_SEQ_DISCONTINUITY);
    /* different payload size */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2400, 2000, 0x10, 65535, 2, 0, 64,
            payload, 1399);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
          VN_COAL_SIZE_MISMATCH);
    /* a correct continuation still appends */
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 2400, 2000, 0x10, 65535, 2, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) == VN_COAL_OK);
    CHECK(co.count == 2);
    DONE();

    CASE("coalesce/rejects-ip-options-and-ipv6-extension-headers");
    {
        uint8_t tmp[200];
        /* IPv4 with a 4-byte option: prefix would not replicate cleanly. */
        eth_build(tmp, MAC_HOST, MAC_GUEST, 0x0800);
        memset(tmp + 14, 0, 24);
        tmp[14] = 0x46; tmp[15] = 0;
        put_be16(tmp + 16, 24 + 20 + 100);
        put_be16(tmp + 18, 1);
        tmp[22] = 64; tmp[23] = 6;
        put_be32(tmp + 26, IP_HOST); put_be32(tmp + 30, IP_GUEST);
        put_be16(tmp + 24, ref_csum(tmp + 14, 24));
        tcp_build(tmp + 38, 80, 4000, 1, 2, 0x10, 65535);
        memcpy(tmp + 58, payload, 100);
        memcpy(a.buf, tmp, 158); a.len = 158;
        put_be16(a.buf + 54, ref_tcp4(IP_HOST, IP_GUEST, a.buf + 38, 120));
        CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) ==
              VN_COAL_HEADER_MISMATCH);
        /* IPv6 with a Hop-by-Hop extension header. */
        eth_build(tmp, MAC_HOST, MAC_GUEST, 0x86DD);
        ipv6_build(tmp + 14, IP6_LOCAL_A, IP6_LOCAL_B, 0, 8 + 20 + 100, 0, 64, 0);
        tmp[54] = 6; tmp[55] = 0; memset(tmp + 56, 0, 6);
        tcp_build(tmp + 62, 80, 4000, 1, 2, 0x10, 65535);
        memcpy(tmp + 82, payload, 100);
        memcpy(b.buf, tmp, 182); b.len = 182;
        put_be16(b.buf + 78, ref_tcp6(IP6_LOCAL_A, IP6_LOCAL_B, b.buf + 62, 120));
        CHECK(vn_coalesce_begin(b.buf, b.len, full, &co, &view) ==
              VN_COAL_HEADER_MISMATCH);
    }
    DONE();

    CASE("coalesce/respects-segment-and-byte-caps");
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 0, 0, 0x10, 65535, 1, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_OK);
    {
        VNCaps small = { VN_RX_COALESCE_MAX_PAYLOAD, 2 };
        mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 1400, 0, 0x10, 65535, 2, 0, 64,
                payload, 1400);
        CHECK(vn_coalesce_append(&co, b.buf, b.len, &small, &added) == VN_COAL_OK);
        mk_tcp4(&c, IP_HOST, IP_GUEST, 80, 4000, 2800, 0, 0x10, 65535, 3, 0, 64,
                payload, 1400);
        CHECK(vn_coalesce_append(&co, c.buf, c.len, &small, &added) ==
              VN_COAL_TOO_MANY_SEGMENTS);
        CHECK(co.count == 2);
    }
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 0, 0, 0x10, 65535, 1, 0, 64,
            payload, 1400);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_OK);
    {
        VNCaps tight = { 2000, VN_RX_COALESCE_MAX_SEGMENTS };
        mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 1400, 0, 0x10, 65535, 2, 0, 64,
                payload, 1400);
        CHECK(vn_coalesce_append(&co, b.buf, b.len, &tight, &added) ==
              VN_COAL_TOO_LARGE);
        CHECK(co.count == 1);
    }
    DONE();

    CASE("coalesce/ipv6-super-frame-verified");
    {
        static uint8_t dst[70000];
        static uint8_t expect[4200];
        VNFrameRef mem[3];
        TestFrame t[3];
        uint32_t n;
        for (int k = 0; k < 3; k++)
            mk_tcp6(&t[k], IP6_LOCAL_A, IP6_LOCAL_B, 443, 5000,
                    5000 + (uint32_t)k * 1400, 900, 0x10, 65535, 0, 0xabcde,
                    payload, 1400);
        CHECK(vn_coalesce_begin(t[0].buf, t[0].len, full, &co, &view) == VN_COAL_OK);
        for (int k = 1; k < 3; k++)
            CHECK(vn_coalesce_append(&co, t[k].buf, t[k].len, &caps, &added) ==
                  VN_COAL_OK);
        CHECK(co.count == 3 && co.gso_type == VN_GSO_TCPV6);
        CHECK(co.prefix_len == 74);
        for (int k = 0; k < 3; k++) {
            mem[k].bytes = t[k].buf; mem[k].len = t[k].len;
            mem[k].payload_off = co.prefix_len; mem[k].payload_len = 1400;
        }
        n = vn_coalesce_emit(&co, mem, 3, dst, sizeof(dst));
        CHECK(n == VN_HDR_LEN + 74 + 4200);
        memcpy(expect, payload, 1400);
        memcpy(expect + 1400, payload, 1400);
        memcpy(expect + 2800, payload, 1400);
        verify_super_frame(dst, dst + VN_HDR_LEN, n - VN_HDR_LEN, 3,
                           expect, 4200, 5000);
    }
    DONE();

    CASE("coalesce/sequence-wraparound-across-members");
    mk_tcp4(&a, IP_HOST, IP_GUEST, 80, 4000, 0xFFFFFFF0u, 0, 0x10, 65535, 1, 0,
            64, payload, 1400);
    CHECK(vn_coalesce_begin(a.buf, a.len, full, &co, &view) == VN_COAL_OK);
    CHECK(co.seq_next == 0xFFFFFFF0u + 1400u);
    mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 0xFFFFFFF0u + 1400u, 0, 0x10,
            65535, 2, 0, 64, payload, 1400);
    CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) == VN_COAL_OK);
    CHECK(co.count == 2 && co.total_payload == 2800);
    DONE();

    CASE("coalesce/45-member-aggregate-verified");
    {
        static uint8_t dst[70000];
        static uint8_t expect[45 * 1400];
        static TestFrame t[45];
        VNFrameRef mem[45];
        uint32_t n;
        for (int k = 0; k < 45; k++) {
            mk_tcp4(&t[k], IP_HOST, IP_GUEST, 80, 4000,
                    (uint32_t)k * 1400u, 7, 0x10, 65535, (uint16_t)k, 0, 64,
                    payload, 1400);
            memcpy(expect + (size_t)k * 1400, payload, 1400);
        }
        CHECK(vn_coalesce_begin(t[0].buf, t[0].len, full, &co, &view) == VN_COAL_OK);
        for (int k = 1; k < 45; k++)
            CHECK(vn_coalesce_append(&co, t[k].buf, t[k].len, &caps, &added) ==
                  VN_COAL_OK);
        CHECK(co.count == 45 && co.total_payload == 45u * 1400u);
        for (int k = 0; k < 45; k++) {
            mem[k].bytes = t[k].buf; mem[k].len = t[k].len;
            mem[k].payload_off = co.prefix_len; mem[k].payload_len = 1400;
        }
        n = vn_coalesce_emit(&co, mem, 45, dst, sizeof(dst));
        CHECK(n == VN_HDR_LEN + 54 + 45u * 1400u);
        CHECK(n <= VN_HDR_LEN + VN_MAX_GSO_FRAME);
        verify_super_frame(dst, dst + VN_HDR_LEN, n - VN_HDR_LEN, 45,
                           expect, 45u * 1400u, 0);
        /* The 46th member must be refused by the segment cap. */
        mk_tcp4(&b, IP_HOST, IP_GUEST, 80, 4000, 45u * 1400u, 7, 0x10, 65535,
                99, 0, 64, payload, 1400);
        CHECK(vn_coalesce_append(&co, b.buf, b.len, &caps, &added) ==
              VN_COAL_TOO_MANY_SEGMENTS);
    }
    DONE();
}

static void test_fairness(void) {
    VNFairness fq;
    VNFlowKey A, B, arp;
    const uint16_t ring = RX_RING_USABLE;

    memset(&A, 0, sizeof(A)); memset(&B, 0, sizeof(B)); memset(&arp, 0, sizeof(arp));
    A.ip_version = 4; A.proto = 6; A.addr_len = 4;
    A.sport = 1; A.dport = 2; A.saddr[3] = 1; A.daddr[3] = 2;
    B.ip_version = 4; B.proto = 6; B.addr_len = 4;
    B.sport = 3; B.dport = 4; B.saddr[3] = 3; B.daddr[3] = 4;

    CASE("fairness/single-flow-keeps-the-whole-ring");
    vn_fairness_init(&fq);
    for (uint16_t i = 0; i < ring; i++)
        CHECK(vn_fairness_admit(&fq, &A, true, ring, i));
    CHECK(!vn_fairness_admit(&fq, &A, true, ring, ring));   /* ring itself full */
    CHECK(fq.refusals == 0);       /* never refused while it was alone */
    CHECK(fq.admits == ring);
    DONE();

    CASE("fairness/two-flows-split-the-ring");
    vn_fairness_init(&fq);
    {
        uint16_t used = 0, a_ok = 0, b_ok = 0;
        /* Perfectly interleaved admission: the ring fills with a near-even
         * split and nobody is ever refused, because neither flow overreaches. */
        for (int round = 0; round < 400 && used < ring; round++) {
            if (vn_fairness_admit(&fq, &A, true, ring, used)) { a_ok++; used++; }
            if (used >= ring) break;
            if (vn_fairness_admit(&fq, &B, true, ring, used)) { b_ok++; used++; }
        }
        CHECK(used == ring);
        CHECK(a_ok <= (uint16_t)((ring + 1) / 2));
        CHECK(b_ok <= (uint16_t)((ring + 1) / 2));
        CHECK(a_ok + b_ok == ring);
        printf("  two-flow interleaved split: A=%u B=%u ring=%u\n",
               a_ok, b_ok, (unsigned)ring);
    }
    /* Now the case that actually needs the cap: one flow holds data and the
     * other runs flat out. Without a per-flow share the greedy flow would take
     * every remaining slot and starve the first one. */
    vn_fairness_init(&fq);
    {
        uint16_t used = 0, a_ok = 0;
        for (uint16_t i = 0; i < 8; i++)
            CHECK(vn_fairness_admit(&fq, &B, true, ring, i));
        used = 8;
        while (used < ring && vn_fairness_admit(&fq, &A, true, ring, used)) {
            a_ok++; used++;
        }
        CHECK(fq.refusals > 0);                  /* the cap engaged */
        CHECK(a_ok <= (uint16_t)((ring + 1) / 2));   /* held to its share */
        CHECK(a_ok < ring - 8);                  /* did not take all that was left */
        CHECK(used < ring);                      /* B's remaining share is reserved */
        printf("  two-flow greedy: B held 8, A took %u, refused %llu, %u slots "
               "left for B\n", a_ok, (unsigned long long)fq.refusals,
               (unsigned)(ring - used));
    }
    DONE();

    CASE("fairness/release-lets-a-flow-back-in");
    vn_fairness_init(&fq);
    for (uint16_t i = 0; i < 32; i++)
        CHECK(vn_fairness_admit(&fq, &A, true, ring, i));
    for (uint16_t i = 0; i < 31; i++)
        CHECK(vn_fairness_admit(&fq, &B, true, ring, (uint16_t)(32 + i)));
    CHECK(!vn_fairness_admit(&fq, &A, true, ring, ring - 1));
    vn_fairness_release(&fq, &A);
    CHECK(vn_fairness_admit(&fq, &A, true, ring, ring - 1));
    for (uint16_t i = 0; i < 80; i++) {
        vn_fairness_release(&fq, &A);
        vn_fairness_release(&fq, &B);
    }
    CHECK(fq.tracked == 0);
    /* Releasing an unknown key must be harmless. */
    vn_fairness_release(&fq, &arp);
    DONE();

    CASE("fairness/control-traffic-bypasses-the-cap");
    vn_fairness_init(&fq);
    {
        uint16_t used = 0;
        /* A single flow must never be capped - that would be a throughput
         * regression against the legacy FIFO for the common case. */
        for (uint16_t i = 0; i < ring - 1; i++)
            CHECK(vn_fairness_admit(&fq, &A, true, ring, i));
        CHECK(fq.refusals == 0);
        CHECK(vn_fairness_admit(&fq, &A, true, ring, ring - 1));
        CHECK(!vn_fairness_admit(&fq, &A, true, ring, ring));  /* ring itself full */

        /* Now create real contention: B holds data, A runs to its cap. */
        vn_fairness_init(&fq);
        for (uint16_t i = 0; i < 8; i++)
            CHECK(vn_fairness_admit(&fq, &B, true, ring, i));
        used = 8;
        while (used < ring && vn_fairness_admit(&fq, &A, true, ring, used)) used++;
        CHECK(!vn_fairness_admit(&fq, &A, true, ring, used));   /* A is capped */
        CHECK(fq.refusals > 0);
        CHECK(used < ring);                       /* room is left, A just cannot have it */

        /* ARP is not an IP flow: it bypasses the per-flow cap entirely, so
         * address resolution can never be starved by a download. */
        CHECK(arp.ip_version == 0);
        CHECK(vn_fairness_admit(&fq, &arp, false, ring, used));
        CHECK(fq.control_bypass > 0);

        /* The cap is per flow, not global: B is still below its share and gets
         * in even though A was just refused. */
        CHECK(vn_fairness_admit(&fq, &B, true, ring, (uint16_t)(used + 1)));
        printf("  control bypass: A capped at %u of %u, ARP admitted, B still "
               "admitted\n", (unsigned)used, (unsigned)ring);
    }
    DONE();

    CASE("fairness/many-flows-and-table-overflow");
    vn_fairness_init(&fq);
    {
        VNFlowKey keys[VN_FLOW_SLOTS + 4];
        uint16_t used = 0;
        for (unsigned k = 0; k < VN_FLOW_SLOTS + 4; k++) {
            memset(&keys[k], 0, sizeof(keys[k]));
            keys[k].ip_version = 4; keys[k].proto = 6; keys[k].addr_len = 4;
            keys[k].sport = (uint16_t)(1000 + k); keys[k].dport = 80;
            keys[k].saddr[3] = (uint8_t)(k + 1); keys[k].daddr[3] = 2;
        }
        while (used < ring) {
            bool progress = false;
            for (unsigned k = 0; k < VN_FLOW_SLOTS + 4 && used < ring; k++) {
                if (vn_fairness_admit(&fq, &keys[k], true, ring, used)) {
                    used++; progress = true;
                }
            }
            if (!progress) break;
        }
        CHECK(used == ring);
        for (unsigned s = 0; s < VN_FLOW_SLOTS; s++)
            if (fq.entry[s].used)
                CHECK(fq.entry[s].slots <= (uint16_t)((ring + 2) / 3));
        /* Flows beyond the table fall back to plain FIFO admission, counted. */
        CHECK(fq.table_full > 0);
        printf("  many-flow: tracked=%u table_full=%llu refusals=%llu\n",
               (unsigned)fq.tracked, (unsigned long long)fq.table_full,
               (unsigned long long)fq.refusals);
    }
    DONE();
}

static void test_flow_key_and_stats(void) {
    static TestFrame f;
    VNFrameInfo i;
    VNFlowKey k1, k2;
    static uint8_t payload[20];
    VNStats s;
    uint64_t flat[64];

    CASE("flow-key/separates-flows-and-ignores-non-ip");
    memset(payload, 0x11, sizeof(payload));
    mk_tcp4(&f, IP_HOST, IP_GUEST, 80, 4000, 1, 2, 0x10, 100, 1, 0, 64,
            payload, 20);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_flow_key(f.buf, f.len, &i, &k1));
    CHECK(k1.ip_version == 4 && k1.proto == 6);
    CHECK(k1.sport == 80 && k1.dport == 4000 && k1.addr_len == 4);
    mk_tcp4(&f, IP_HOST, IP_GUEST, 80, 4001, 1, 2, 0x10, 100, 1, 0, 64,
            payload, 20);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_flow_key(f.buf, f.len, &i, &k2));
    CHECK(!vn_flow_key_eq(&k1, &k2));
    /* seq, ack, window, id and tos are not part of flow identity. */
    mk_tcp4(&f, IP_HOST, IP_GUEST, 80, 4000, 999, 888, 0x10, 777, 9, 0x10, 33,
            payload, 20);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_flow_key(f.buf, f.len, &i, &k2));
    CHECK(vn_flow_key_eq(&k1, &k2));
    /* IPv6 keys use 16-byte addresses. */
    mk_tcp6(&f, IP6_LOCAL_A, IP6_LOCAL_B, 443, 5000, 1, 2, 0x10, 100, 0, 0,
            payload, 20);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(vn_flow_key(f.buf, f.len, &i, &k2));
    CHECK(k2.ip_version == 6 && k2.addr_len == 16);
    CHECK(!vn_flow_key_eq(&k1, &k2));
    /* ARP is not an IP flow. */
    mk_arp_request(&f);
    CHECK(vn_frame_parse(f.buf, f.len, &i) == VN_PARSE_OK);
    CHECK(!vn_flow_key(f.buf, f.len, &i, &k2));
    CHECK(!vn_flow_key_eq(&k1, NULL));
    DONE();

    CASE("stats/layout-is-flat-uint64-and-exportable");
    vn_stats_init(&s);
    CHECK(vn_stats_count() == sizeof(VNStats) / sizeof(uint64_t));
    CHECK(vn_stats_count() <= sizeof(flat) / sizeof(flat[0]));
    s.tx_segmented = 7; s.rx_aggregates = 9;
    memset(flat, 0, sizeof(flat));
    vn_stats_export(&s, flat, vn_stats_count());
    /* Indices derived from the layout rather than hardcoded, so inserting a
     * counter cannot silently make this assert the wrong field. */
    CHECK(flat[offsetof(VNStats, tx_segmented) / sizeof(uint64_t)] == 7);
    CHECK(flat[offsetof(VNStats, rx_aggregates) / sizeof(uint64_t)] == 9);
    CHECK(flat[offsetof(VNStats, tx_csum_deferred) / sizeof(uint64_t)] == 0);
    CHECK(flat[offsetof(VNStats, tx_csum_completed) / sizeof(uint64_t)] == 0);
    vn_stats_export(&s, flat, 2); /* a short buffer must not overrun */
    CHECK(flat[0] == 0 && flat[1] == 0);
    vn_stats_export(NULL, flat, 4);
    vn_stats_export(&s, NULL, 4);
    DONE();
}

static void test_header_codec(void) {
    uint8_t raw[VN_HDR_LEN];
    VNNetHdrFields h, out;

    CASE("hdr/little-endian-round-trip-and-num-buffers-forced-to-one");
    memset(raw, 0xA5, sizeof(raw));
    h.flags = VN_HDR_F_NEEDS_CSUM;
    h.gso_type = VN_GSO_TCPV6;
    h.hdr_len = 0x1234; h.gso_size = 0x5678;
    h.csum_start = 0x9abc; h.csum_offset = 0xdef0;
    h.num_buffers = 0xbeef;                 /* must be ignored on write */
    vn_hdr_write(raw, &h);
    CHECK(raw[0] == VN_HDR_F_NEEDS_CSUM && raw[1] == VN_GSO_TCPV6);
    CHECK(raw[2] == 0x34 && raw[3] == 0x12);
    CHECK(raw[4] == 0x78 && raw[5] == 0x56);
    CHECK(raw[6] == 0xbc && raw[7] == 0x9a);
    CHECK(raw[8] == 0xf0 && raw[9] == 0xde);
    CHECK(raw[10] == 1 && raw[11] == 0);
    vn_hdr_read(raw, &out);
    CHECK(out.flags == h.flags && out.gso_type == h.gso_type);
    CHECK(out.hdr_len == h.hdr_len && out.gso_size == h.gso_size);
    CHECK(out.csum_start == h.csum_start && out.csum_offset == h.csum_offset);
    CHECK(out.num_buffers == 1);
    /* The legacy RX header shape must be a zeroed header with num_buffers 1. */
    memset(raw, 0xA5, sizeof(raw));
    vn_hdr_write_plain(raw);
    vn_hdr_read(raw, &out);
    CHECK(out.flags == 0 && out.gso_type == VN_GSO_NONE);
    CHECK(out.hdr_len == 0 && out.gso_size == 0);
    CHECK(out.csum_start == 0 && out.csum_offset == 0);
    CHECK(out.num_buffers == 1);
    CHECK(raw[10] == 1 && raw[11] == 0);
    DONE();
}

#endif /* FLOE_NIC_OFFLOAD_UNIT_TESTS_H */
