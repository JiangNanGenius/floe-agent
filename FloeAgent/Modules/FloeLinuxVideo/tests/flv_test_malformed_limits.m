/* SPDX-License-Identifier: MPL-2.0 */
/* Malformed input, validation, finite limits and backpressure. */
#import "flv_test_util.h"
#include <unistd.h>

static int make_host_expect_invalid(FLVHostConfig *cfg) {
    FLVHost *h = NULL;
    int rc = flv_host_create(cfg, &h);
    if (rc == FLV_OK) flv_host_destroy(h);
    return rc != FLV_OK ? 0 : 1;
}

int main(void) {
    FLVTestNotifyState ns;
    memset(&ns, 0, sizeof(ns));

    /* Host creation validation. */
    FLVHostConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.abi_version = 999;
    cfg.max_sessions = 2; cfg.max_inflight_per_session = 2;
    cfg.max_packet_bytes = 1 << 20; cfg.max_frame_bytes = 1 << 20; cfg.max_owned_bytes = 1 << 20;
    cfg.notify = flv_test_notify;
    FLV_TEST_CHECK(make_host_expect_invalid(&cfg) == 0);
    cfg.abi_version = FLV_ABI_VERSION;
    cfg.notify = NULL;
    FLV_TEST_CHECK(make_host_expect_invalid(&cfg) == 0);
    cfg.notify = flv_test_notify;
    cfg.max_sessions = 0;
    FLV_TEST_CHECK(make_host_expect_invalid(&cfg) == 0);
    cfg.max_sessions = 2;

    FLVHost *host = NULL;
    FLV_TEST_CHECK_STATUS(flv_host_create(&cfg, &host), FLV_OK);

    /* Session creation validation. */
    FLVSessionConfig sc;
    memset(&sc, 0, sizeof(sc));
    sc.flags = FLV_REQUIRE_HARDWARE;
    sc.abi_version = 999;
    sc.codec = FLV_H264; sc.direction = FLV_ENCODE; sc.pixel_format = FLV_NV12;
    sc.width = 640; sc.height = 360; sc.frame_rate_num = 30; sc.frame_rate_den = 1;
    sc.bitstream_format = FLV_ANNEX_B;
    FLVSession *s = NULL;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_INVALID);
    sc.abi_version = FLV_ABI_VERSION;

    sc.codec = 0;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_UNSUPPORTED);
    sc.codec = 42;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_UNSUPPORTED);
    sc.codec = FLV_H264;

    sc.direction = 0;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_INVALID);
    sc.direction = FLV_ENCODE;

    sc.pixel_format = FLV_BGRA;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_UNSUPPORTED);
    sc.pixel_format = 99;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_UNSUPPORTED);
    sc.pixel_format = FLV_NV12;

    sc.width = 0; sc.height = 360;   /* encode: zero dims invalid */
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_INVALID);
    sc.width = 640; sc.height = 361; /* odd height invalid for 4:2:0 */
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_INVALID);
    sc.height = 360;

    sc.frame_rate_den = 0;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_INVALID);
    sc.frame_rate_den = 1;

    sc.bitstream_format = 99;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_INVALID);
    sc.bitstream_format = FLV_RAW_CODED_FRAME; /* invalid for H264 encode */
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_INVALID);
    sc.bitstream_format = FLV_ANNEX_B;

    sc.width = 16384; sc.height = 16384; /* beyond structural bound */
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_LIMIT);
    sc.width = 640; sc.height = 360;

    /* VP8: no path at all. */
    sc.codec = FLV_VP8; sc.direction = FLV_DECODE;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_UNSUPPORTED);
    sc.codec = FLV_H264; sc.direction = FLV_ENCODE;

    /* H264 length-prefixed decode without avcC must fail clearly. */
    sc.direction = FLV_DECODE; sc.bitstream_format = FLV_LENGTH_PREFIXED;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_INVALID);
    /* garbage avcC must fail clearly */
    uint8_t garbage[16]; memset(garbage, 0xAA, sizeof(garbage));
    sc.codec_config = garbage; sc.codec_config_bytes = sizeof(garbage);
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_CORRUPT);
    sc.codec_config = NULL; sc.codec_config_bytes = 0;
    sc.direction = FLV_ENCODE; sc.bitstream_format = FLV_ANNEX_B;

    /* Session budget: max_sessions = 2 on this host. */
    FLVSession *s1 = NULL, *s2 = NULL, *s3 = NULL;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s1), FLV_OK);
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s2), FLV_OK);
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s3), FLV_LIMIT);
    FLV_TEST_CHECK(s1 && s2 && !s3);
    flv_session_close(s1);
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s1), FLV_OK);

    /* Backpressure + stride validation on a live encoder. */
    const uint32_t w = 640, h = 360;
    const size_t frame_bytes = (size_t)w * h * 3 / 2;
    uint8_t *nv12 = malloc(frame_bytes);
    memset(nv12, 0, frame_bytes);
    FLVFrame fr;
    flv_test_frame_from_nv12(nv12, w, h, 0, 33333333, 1, 1, &fr);
    /* bad stride */
    fr.plane_strides[0] = w - 1;
    FLV_TEST_CHECK_STATUS(flv_session_submit_frame(s2, &fr), FLV_INVALID);
    /* plane beyond end */
    fr.plane_strides[0] = w;
    fr.plane_offsets[1] = (uint64_t)w * h * 2;
    FLV_TEST_CHECK_STATUS(flv_session_submit_frame(s2, &fr), FLV_INVALID);
    fr.plane_offsets[1] = (uint64_t)w * h;
    /* zero-byte frame */
    fr.bytes = 0;
    FLV_TEST_CHECK_STATUS(flv_session_submit_frame(s2, &fr), FLV_INVALID);
    fr.bytes = frame_bytes;

    /* Fill inflight (max_inflight_per_session = 2) and require FLV_AGAIN.
     * The encoder callback drains on VT's thread, so whether the third
     * immediate submit sees a full window is timing-dependent BY DESIGN —
     * an OK there is legal (the callback simply completed first). Retry the
     * fill until AGAIN is observed (near-certain within a few rounds); the
     * assertion itself is never relaxed, and the bounded invariant is
     * checked from host stats every round. */
    int saw_again = 0;
    for (int round = 0; round < 32 && !saw_again; round++) {
        flv_test_frame_from_nv12(nv12, w, h, 0, 33333333, 1, 1, &fr);
        FLV_TEST_CHECK_STATUS(flv_session_submit_frame(s2, &fr), FLV_OK);
        flv_test_frame_from_nv12(nv12, w, h, 33333333, 33333333, 2, 0, &fr);
        FLV_TEST_CHECK_STATUS(flv_session_submit_frame(s2, &fr), FLV_OK);
        flv_test_frame_from_nv12(nv12, w, h, 66666666, 33333333, 3, 0, &fr);
        int rc3 = flv_session_submit_frame(s2, &fr);
        FLV_TEST_CHECK(rc3 == FLV_OK || rc3 == FLV_AGAIN);
        if (rc3 == FLV_AGAIN) { saw_again = 1; }
        FLVStats st;
        FLV_TEST_CHECK_STATUS(flv_host_get_stats(host, &st), FLV_OK);
        FLV_TEST_CHECK(st.inflight <= 2); /* bound holds regardless of timing */
        /* Drain whatever completed. Only coded packets carry the
         * hardware_used flag; ERROR outputs must fail the round. */
        FLVOutput out;
        while (flv_session_dequeue(s2, &out) == FLV_OK) {
            FLV_TEST_CHECK(out.kind != FLV_OUTPUT_ERROR);
            if (out.kind == FLV_OUTPUT_PACKET) FLV_TEST_CHECK(out.hardware_used == 1);
            flv_session_release_output(s2, &out);
        }
        /* Ensure the window is empty before the next fill. */
        for (int i = 0; i < 200; i++) {
            FLVStats st2;
            FLV_TEST_CHECK_STATUS(flv_host_get_stats(host, &st2), FLV_OK);
            if (st2.inflight == 0) break;
            while (flv_session_dequeue(s2, &out) == FLV_OK) flv_session_release_output(s2, &out);
            usleep(2000);
        }
    }
    FLV_TEST_CHECK(saw_again); /* strict: backpressure must be observable */

    /* Drain until a coded packet appears, then input is accepted again. */
    int got_output = 0;
    for (int i = 0; i < 400 && !got_output; i++) {
        FLVOutput out;
        if (flv_session_dequeue(s2, &out) == FLV_OK) {
            FLV_TEST_CHECK(out.kind != FLV_OUTPUT_ERROR);
            if (out.kind == FLV_OUTPUT_PACKET) {
                FLV_TEST_CHECK(out.hardware_used == 1); /* REQUIRE_HARDWARE */
                got_output = 1;
            }
            flv_session_release_output(s2, &out);
        } else {
            usleep(5000);
        }
    }
    FLV_TEST_CHECK(got_output);
    fr.pts_ns = 66666666; fr.tag = 3;
    FLV_TEST_CHECK_STATUS(flv_session_submit_frame(s2, &fr), FLV_OK);

    /* Packet path validation on a decoder (no config needed for Annex B).
     * Free s1's slot first: the host budget is 2 sessions and the budget
     * enforcement itself was verified above. */
    flv_session_close(s1);
    s1 = NULL;
    FLVSessionConfig dc = sc;
    dc.direction = FLV_DECODE;
    FLVSession *dec = NULL;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &dc, &dec), FLV_OK);
    FLVPacket pkt;
    memset(&pkt, 0, sizeof(pkt));
    uint8_t tiny[8] = {0, 0, 0, 1, 0x65, 0x11, 0x22, 0x33};
    pkt.data = tiny; pkt.bytes = sizeof(tiny);
    int rc = flv_session_submit_packet(dec, &pkt);
    FLV_TEST_CHECK(rc == FLV_OK || rc == FLV_CORRUPT || rc == FLV_INTERNAL);
    /* oversized packet */
    FLVHostConfig cfg2 = cfg;
    cfg2.max_packet_bytes = 4;
    FLVHost *host2 = NULL;
    FLV_TEST_CHECK_STATUS(flv_host_create(&cfg2, &host2), FLV_OK);
    FLVSession *dec2 = NULL;
    FLV_TEST_CHECK_STATUS(flv_session_create(host2, &dc, &dec2), FLV_OK);
    pkt.bytes = 1024;
    FLV_TEST_CHECK_STATUS(flv_session_submit_packet(dec2, &pkt), FLV_LIMIT);
    flv_session_close(dec2);
    flv_host_destroy(host2);

    /* Stats sanity: sessions counted, completed > 0. */
    FLVStats stats;
    FLV_TEST_CHECK_STATUS(flv_host_get_stats(host, &stats), FLV_OK);
    FLV_TEST_CHECK(stats.sessions == 2);
    FLV_TEST_CHECK(stats.submitted >= 3 && stats.completed >= 1);

    flv_session_close(dec);
    flv_session_close(s1);
    flv_session_close(s2);
    flv_host_destroy(host);
    free(nv12);

    printf("{\"test\": \"malformed_limits\", \"status\": \"passed\"}\n");
    return 0;
}
