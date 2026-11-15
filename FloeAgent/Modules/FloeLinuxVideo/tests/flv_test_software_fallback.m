/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Native software codec fallback — focused qualification (source-stage
 * prepared; runtime execution is the primary's later native stage).
 *
 * Covers, with REAL coded data (never self-consistency or mocked hardware):
 *  1. Capability invariants: FLV_CAP_NATIVE_SOFTWARE_PROBED (8) never
 *     coexists with hardware flags 1|4 and never claims hardware.
 *  2. vpcC record layout: the 12-byte VideoToolbox record built by
 *     flv_vpcc_build (pinned bytes), with explicit unknowns — dimensions
 *     must NOT appear in the record.
 *  3. Strict REQUIRE_HARDWARE rejection: a software-only codec/direction
 *     (flag 8, no flags 1|4) must fail session creation with
 *     FLV_UNSUPPORTED under FLV_REQUIRE_HARDWARE and must never increment a
 *     hardware-used result; the same config without the flag must create a
 *     working session whose outputs report hardware_used == 0.
 *  4. Real software decode of the shipped probe frame for a software-only
 *     decode codec; cancellation fences late work; close releases resources
 *     (host stats return to zero owned bytes).
 *  5. Sanity: a hardware-proven codec (H.264 decode when flagged 1|4) still
 *     creates a REQUIRE_HARDWARE session successfully (strictness must not
 *     break the hardware path).
 *
 * The test discovers software-only codecs from the capability query, so it
 * adapts to the machine it runs on. When the machine has no software-only
 * codec, the session checks report "skipped" truthfully (exit 0).
 *
 * Usage: flv_test_software_fallback
 */
#import "flv_test_util.h"
#import "FLVBitstream.h"
#import "FLVCodecRegistry.h" /* FLV_CAP_NATIVE_SOFTWARE_PROBED, probe samples */
#import "FLVProbeSamples.h"
#include <unistd.h>

static const FLVProbeSample *find_sample(uint32_t codec) {
    for (size_t i = 0; i < flv_probe_samples_count; i++)
        if (flv_probe_samples[i].codec == codec) return &flv_probe_samples[i];
    return NULL;
}

/* Drain until a frame output appears or the deadline (2.5 s) passes.
 * Counts every dequeued output by kind; returns the frame count. */
static uint32_t drain_count_frames(FLVSession *s, uint32_t *hw_frames_out,
                                   uint32_t *errors_out) {
    uint32_t frames = 0, hw = 0, errors = 0;
    for (int i = 0; i < 500; i++) {
        FLVOutput o;
        while (flv_session_dequeue(s, &o) == FLV_OK) {
            if (o.kind == FLV_OUTPUT_FRAME) { frames++; hw += o.hardware_used; }
            if (o.kind == FLV_OUTPUT_ERROR) errors++;
            flv_session_release_output(s, &o);
        }
        if (frames || errors) break;
        usleep(5000);
    }
    if (hw_frames_out) *hw_frames_out = hw;
    if (errors_out) *errors_out = errors;
    return frames;
}

static int test_vpcc_layout(void) {
    uint8_t buf[16];
    size_t n = 0;
    /* profile 0, level 0 (Undefined), 8-bit, 4:2:0, limited range,
     * colour unspecified (2,2,2): the exact verified probe-fixture shape. */
    FLV_TEST_CHECK_STATUS(flv_vpcc_build(0, 0, 8, 1, 0, 2, 2, 2,
                                         buf, sizeof(buf), &n), FLV_OK);
    FLV_TEST_CHECK(n == 12);
    static const uint8_t expect[12] = {
        0x01, 0x00, 0x00, 0x00, /* version 1, flags */
        0x00,                   /* profile */
        0x00,                   /* level Undefined */
        0x82,                   /* (8 << 4) | (1 << 1) | 0 */
        0x02, 0x02, 0x02,       /* colour unspecified */
        0x00, 0x00              /* initialization size */
    };
    FLV_TEST_CHECK(memcmp(buf, expect, 12) == 0);
    /* Level and colour parameters are honored, not invented. */
    FLV_TEST_CHECK_STATUS(flv_vpcc_build(2, 40, 10, 1, 1, 1, 13, 9,
                                         buf, sizeof(buf), &n), FLV_OK);
    FLV_TEST_CHECK(n == 12 && buf[4] == 2 && buf[5] == 40);
    FLV_TEST_CHECK(buf[6] == ((10 << 4) | (1 << 1) | 1));
    FLV_TEST_CHECK(buf[7] == 1 && buf[8] == 13 && buf[9] == 9);
    /* Too-small buffers fail closed; dimensions never appear in the record. */
    FLV_TEST_CHECK_STATUS(flv_vpcc_build(0, 0, 8, 1, 0, 2, 2, 2,
                                         buf, 11, &n), FLV_LIMIT);
    /* 320x180 (the probe fixture dims) must not be encodable anywhere:
     * the record contains no width/height fields at all. */
    FLV_TEST_CHECK_STATUS(flv_vpcc_build(0, 0, 8, 1, 0, 2, 2, 2,
                                         buf, sizeof(buf), &n), FLV_OK);
    const uint8_t wlo = (uint8_t)((320 - 1) & 0xFF), whi = (uint8_t)(((320 - 1) >> 8) & 0xFF);
    int dims_leaked = 0;
    for (size_t i = 0; i + 1 < n; i++)
        if (buf[i] == wlo && buf[i + 1] == whi) dims_leaked = 1;
    const uint8_t hlo = (uint8_t)((180 - 1) & 0xFF), hhi = (uint8_t)(((180 - 1) >> 8) & 0xFF);
    for (size_t i = 0; i + 1 < n; i++)
        if (buf[i] == hlo && buf[i + 1] == hhi) dims_leaked = 1;
    (void)hhi;
    FLV_TEST_CHECK(!dims_leaked);
    return 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (test_vpcc_layout() != 0) return 1;

    FLVTestNotifyState ns;
    memset(&ns, 0, sizeof(ns));
    FLVHost *host = NULL;
    FLV_TEST_CHECK_STATUS(flv_test_make_host(&host, 4, 4, &ns), FLV_OK);

    size_t required = 0;
    FLV_TEST_CHECK_STATUS(flv_host_query_capabilities(host, NULL, 0, &required), FLV_OK);
    FLV_TEST_CHECK(required == 22);
    FLVCapability caps[22];
    memset(caps, 0, sizeof(caps));
    FLV_TEST_CHECK_STATUS(flv_host_query_capabilities(host, caps, 22, &required), FLV_OK);

    /* ---- 1. flag invariants across all slots ---- */
    uint32_t sw_decode_codec = 0, sw_encode_codec = 0;
    int h264_hw_decode = 0;
    for (size_t i = 0; i < 22; i++) {
        const FLVCapability *c = &caps[i];
        if (c->flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) {
            FLV_TEST_CHECK((c->flags & (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED)) == 0);
            FLV_TEST_CHECK(c->flags & FLV_CAP_IMPLEMENTED);
            FLV_TEST_CHECK(c->probe_status == FLV_OK);
            if (c->direction == FLV_DECODE && !sw_decode_codec &&
                !(c->flags & FLV_CAP_HW_REPORTED)) {
                /* Only codecs with a shipped real probe sample are usable
                 * for the session checks below. */
                if (find_sample(c->codec)) sw_decode_codec = c->codec;
            }
            if (c->direction == FLV_ENCODE && !sw_encode_codec)
                sw_encode_codec = c->codec;
        }
        if (c->codec == FLV_H264 && c->direction == FLV_DECODE &&
            (c->flags & (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED)))
            h264_hw_decode = 1;
    }

    printf("{\n  \"test\": \"software_fallback\",\n  \"results\": {\n");

    /* ---- 3+4. strict rejection + real software session ---- */
    const char *sw_verdict = "skipped";
    if (sw_decode_codec) {
        const FLVProbeSample *sample = find_sample(sw_decode_codec);
        FLV_TEST_CHECK(sample != NULL);

        /* REQUIRE_HARDWARE must never be satisfied by software. */
        FLVSessionConfig sc;
        memset(&sc, 0, sizeof(sc));
        sc.abi_version = FLV_ABI_VERSION;
        sc.codec = sw_decode_codec; sc.direction = FLV_DECODE;
        sc.pixel_format = FLV_NV12;
        sc.width = sample->width; sc.height = sample->height;
        sc.frame_rate_num = 30; sc.frame_rate_den = 1;
        sc.bitstream_format = FLV_RAW_CODED_FRAME;
        sc.flags = FLV_REQUIRE_HARDWARE;
        sc.codec_config = sample->config; sc.codec_config_bytes = sample->config_bytes;
        FLVSession *s = NULL;
        FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_UNSUPPORTED);
        FLV_TEST_CHECK(s == NULL);

        /* Same config without REQUIRE_HARDWARE: native software session. */
        sc.flags = 0;
        FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_OK);
        FLV_TEST_CHECK(s != NULL);
        FLVPacket pkt;
        memset(&pkt, 0, sizeof(pkt));
        pkt.data = sample->frame; pkt.bytes = sample->frame_bytes;
        pkt.pts_ns = 0; pkt.tag = 1;
        int src = flv_session_submit_packet(s, &pkt);
        if (src == FLV_AGAIN) { flv_test_drain(s, NULL); src = flv_session_submit_packet(s, &pkt); }
        FLV_TEST_CHECK_STATUS(src, FLV_OK);
        pkt.bytes = 0; pkt.flags = FLV_END_OF_STREAM;
        FLV_TEST_CHECK_STATUS(flv_session_submit_packet(s, &pkt), FLV_OK);
        uint32_t hw_frames = 0, errors = 0;
        uint32_t frames = drain_count_frames(s, &hw_frames, &errors);
        /* The frame must decode through software and never report hardware. */
        FLV_TEST_CHECK(errors == 0);
        FLV_TEST_CHECK(frames >= 1);
        FLV_TEST_CHECK(hw_frames == 0);

        /* Cancellation fences late work; further submits fail closed. */
        flv_session_cancel(s);
        FLVPacket p2;
        memset(&p2, 0, sizeof(p2));
        p2.data = sample->frame; p2.bytes = sample->frame_bytes; p2.tag = 7;
        FLV_TEST_CHECK_STATUS(flv_session_submit_packet(s, &p2), FLV_CANCELLED);
        FLV_TEST_CHECK_STATUS(flv_session_flush(s, 1), FLV_CANCELLED);
        flv_session_close(s);
        flv_session_close(s); /* double close is a documented no-op */

        FLVStats stats;
        FLV_TEST_CHECK_STATUS(flv_host_get_stats(host, &stats), FLV_OK);
        FLV_TEST_CHECK(stats.sessions == 0);
        FLV_TEST_CHECK(stats.owned_bytes == 0);
        FLV_TEST_CHECK(stats.cancelled >= 1);
        sw_verdict = "passed";
    }
    printf("    \"software_decode_session\": {\"status\": \"%s\", \"codec\": %u},\n",
           sw_verdict, sw_decode_codec);

    /* ---- software encode candidate (created without REQUIRE_HARDWARE) ---- */
    const char *sw_enc_verdict = "skipped";
    if (sw_encode_codec) {
        const FLVCapability *cap = NULL;
        for (size_t i = 0; i < 22; i++)
            if (caps[i].codec == sw_encode_codec && caps[i].direction == FLV_ENCODE) cap = &caps[i];
        FLV_TEST_CHECK(cap != NULL);
        /* Measured software probe dims: at least the 640x360 probe size. */
        uint32_t w = cap->max_width >= 640 ? 640 : cap->max_width;
        uint32_t h = cap->max_height >= 360 ? 360 : cap->max_height;
        if (w == 0 || h == 0) { w = 640; h = 360; }
        FLVSessionConfig sc;
        memset(&sc, 0, sizeof(sc));
        sc.abi_version = FLV_ABI_VERSION;
        sc.codec = sw_encode_codec; sc.direction = FLV_ENCODE;
        sc.pixel_format = FLV_NV12;
        sc.width = w; sc.height = h;
        sc.frame_rate_num = 30; sc.frame_rate_den = 1;
        sc.bitstream_format = FLV_RAW_CODED_FRAME;
        sc.bitrate = 1000000;
        /* Strict rejection on the encode direction too. */
        sc.flags = FLV_REQUIRE_HARDWARE;
        FLVSession *s = NULL;
        FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_UNSUPPORTED);
        FLV_TEST_CHECK(s == NULL);
        /* Software session: one real frame must encode with hw_used == 0. */
        sc.flags = 0;
        FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_OK);
        size_t fb = (size_t)w * h * 3 / 2;
        uint8_t *nv12 = malloc(fb);
        FLV_TEST_CHECK(nv12 != NULL);
        for (size_t i = 0; i < fb; i++) nv12[i] = (uint8_t)(i * 2654435761u >> 24);
        FLVFrame fr;
        flv_test_frame_from_nv12(nv12, w, h, 0, 33333333, 1, 1, &fr);
        fr.flags |= FLV_END_OF_STREAM;
        int src2 = flv_session_submit_frame(s, &fr);
        if (src2 == FLV_AGAIN) { flv_test_drain(s, NULL); src2 = flv_session_submit_frame(s, &fr); }
        FLV_TEST_CHECK_STATUS(src2, FLV_OK);
        uint32_t hw_packets = 0, errors2 = 0;
        FLVOutput o;
        uint32_t packets = 0;
        for (int i = 0; i < 500 && !packets && !errors2; i++) {
            while (flv_session_dequeue(s, &o) == FLV_OK) {
                if (o.kind == FLV_OUTPUT_PACKET) { packets++; hw_packets += o.hardware_used; }
                if (o.kind == FLV_OUTPUT_ERROR) errors2++;
                flv_session_release_output(s, &o);
            }
            usleep(5000);
        }
        flv_session_close(s);
        free(nv12);
        FLV_TEST_CHECK(errors2 == 0);
        FLV_TEST_CHECK(packets >= 1);
        FLV_TEST_CHECK(hw_packets == 0);
        sw_enc_verdict = "passed";
    }
    printf("    \"software_encode_session\": {\"status\": \"%s\", \"codec\": %u},\n",
           sw_enc_verdict, sw_encode_codec);

    /* ---- 5. hardware sanity: strictness must not break the hardware path ---- */
    const char *hw_verdict = "skipped";
    if (h264_hw_decode) {
        FLVSessionConfig sc;
        memset(&sc, 0, sizeof(sc));
        sc.abi_version = FLV_ABI_VERSION;
        sc.codec = FLV_H264; sc.direction = FLV_DECODE;
        sc.pixel_format = FLV_NV12;
        sc.width = 640; sc.height = 360;
        sc.frame_rate_num = 30; sc.frame_rate_den = 1;
        sc.bitstream_format = FLV_ANNEX_B;
        sc.flags = FLV_REQUIRE_HARDWARE;
        FLVSession *s = NULL;
        FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_OK);
        FLV_TEST_CHECK(s != NULL);
        flv_session_close(s);
        hw_verdict = "passed";
    }
    printf("    \"hardware_require_sanity\": {\"status\": \"%s\"},\n", hw_verdict);

    flv_host_destroy(host);
    printf("    \"note\": \"session checks skip truthfully when this machine has no software-only codec\"\n  },\n  \"status\": \"passed\"\n}\n");
    return 0;
}
