/* SPDX-License-Identifier: MPL-2.0 */
/* Cancellation fencing, late-callback safety, output ownership and drain
 * behavior. Uses a real H.264 Annex-B clip when available; otherwise a
 * synthetic parameter-set-only stream still exercises the state machine. */
#import "flv_test_util.h"
#include <unistd.h>

static int decode_file_cancel_test(const char *clip_path, FLVHost *host) {
    size_t clip_bytes = 0;
    uint8_t *clip = clip_path ? flv_test_load_file(clip_path, &clip_bytes) : NULL;
    FLVSessionConfig sc;
    memset(&sc, 0, sizeof(sc));
    sc.abi_version = FLV_ABI_VERSION;
    sc.codec = FLV_H264;
    sc.direction = FLV_DECODE;
    sc.pixel_format = FLV_NV12;
    sc.width = 0; sc.height = 0; /* Annex-B: dims from in-band SPS */
    sc.frame_rate_num = 30; sc.frame_rate_den = 1;
    sc.bitstream_format = FLV_ANNEX_B;
    sc.flags = FLV_REQUIRE_HARDWARE;
    sc.session_tag = 0xCA0C1E11u;
    FLVSession *s = NULL;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_OK);

    uint32_t outputs_before = 0, saw_format = 0, saw_frame = 0;
    if (clip) {
        /* Feed real access units (AUD-grouped; a bare SPS/PPS NAL is
         * metadata, not a frame). Feed a bounded prefix, then cancel
         * mid-stream. */
        const uint8_t **aus = NULL; size_t *sizes = NULL; size_t count = 0;
        flv_test_split_annexb_aus(clip, clip_bytes, FLV_H264, &aus, &sizes, &count);
        uint64_t tag = 1;
        size_t submitted = 0;
        for (size_t ai = 0; ai < count && submitted < 60; ai++) {
            FLVPacket pkt;
            memset(&pkt, 0, sizeof(pkt));
            pkt.data = aus[ai];
            pkt.bytes = sizes[ai];
            pkt.pts_ns = (int64_t)submitted * 33333333;
            pkt.tag = tag++;
            int rc = flv_session_submit_packet(s, &pkt);
            for (int retry = 0; rc == FLV_AGAIN && retry < 2000; retry++) {
                /* drain a little to make room */
                FLVOutput out;
                while (flv_session_dequeue(s, &out) == FLV_OK) {
                    if (out.kind == FLV_OUTPUT_FORMAT) saw_format = 1;
                    if (out.kind == FLV_OUTPUT_FRAME) { saw_frame = 1; outputs_before++; }
                    flv_session_release_output(s, &out);
                }
                usleep(1000);
                rc = flv_session_submit_packet(s, &pkt);
            }
            if (rc != FLV_OK) { fprintf(stderr, "submit rc=%d at %zu\n", rc, submitted); free(aus); free(sizes); return 1; }
            submitted++;
            /* After a few frames land, cancel mid-stream. */
            if (submitted == 20) {
                /* let some callbacks land */
                usleep(30000);
                flv_session_cancel(s);
                break;
            }
        }
        free(aus); free(sizes);
        free(clip);
        FLV_TEST_CHECK(submitted == 20);
    } else {
        /* Synthetic SPS/PPS/IDR-ish access units to exercise fencing. */
        static const uint8_t sps[] = {0,0,0,1,0x67,0x42,0x00,0x1f,0x8c,0x8d,0x40,0x50,0x1e,0xd0,0x0f,0x12,0x26,0xa0};
        static const uint8_t pps[] = {0,0,0,1,0x68,0xce,0x3c,0x80};
        static const uint8_t idr[] = {0,0,0,1,0x65,0x88,0x84,0x00,0x33,0xff};
        const uint8_t *parts[3] = {sps, pps, idr};
        size_t sizes[3] = {sizeof(sps), sizeof(pps), sizeof(idr)};
        for (int i = 0; i < 3; i++) {
            FLVPacket pkt;
            memset(&pkt, 0, sizeof(pkt));
            pkt.data = parts[i]; pkt.bytes = sizes[i];
            pkt.tag = (uint64_t)i + 1;
            int rc = flv_session_submit_packet(s, &pkt);
            if (rc != FLV_OK && rc != FLV_CORRUPT && rc != FLV_INTERNAL) {
                fprintf(stderr, "synthetic submit rc=%d\n", rc);
                return 1;
            }
        }
        flv_session_cancel(s);
    }

    /* Post-cancel: submits fail, outputs stop, drain is clean. */
    FLVPacket pkt;
    memset(&pkt, 0, sizeof(pkt));
    uint8_t junk[8] = {0, 0, 0, 1, 0x65, 1, 2, 3};
    pkt.data = junk; pkt.bytes = sizeof(junk);
    FLV_TEST_CHECK_STATUS(flv_session_submit_packet(s, &pkt), FLV_CANCELLED);

    usleep(50000); /* allow any fenced callbacks to land */
    FLVOutput out;
    uint32_t total_after = 0;
    while (flv_session_dequeue(s, &out) == FLV_OK) {
        if (out.kind == FLV_OUTPUT_FRAME) total_after++;
        flv_session_release_output(s, &out);
    }
    /* No new frames may appear after cancel beyond those already delivered. */
    usleep(50000);
    uint32_t late_frames = 0;
    while (flv_session_dequeue(s, &out) == FLV_OK) {
        if (out.kind == FLV_OUTPUT_FRAME) { total_after++; late_frames++; }
        flv_session_release_output(s, &out);
    }
    FLV_TEST_CHECK(late_frames == 0);
    (void)outputs_before;
    printf("  \"cancel_outputs_after\": %u, \"saw_format\": %u, \"saw_frame\": %u,\n",
           total_after, saw_format, saw_frame);
    flv_session_close(s);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc != 2) { fprintf(stderr, "usage: %s <real-30frame-h264-annexb>\n", argv[0]); return 2; }
    const char *clip = argc > 1 ? argv[1] : NULL;
    FLVTestNotifyState ns;
    memset(&ns, 0, sizeof(ns));
    FLVHost *host = NULL;
    FLV_TEST_CHECK_STATUS(flv_test_make_host(&host, 4, 8, &ns), FLV_OK);

    printf("{\n  \"test\": \"cancel_ownership\",\n");
    fprintf(stderr, "phase:cancel_prefix\n");
    FLV_TEST_CHECK(decode_file_cancel_test(clip, host) == 0);

    /* EOS/drain: submit a real stream with EOS flag and expect an EOS output. */
    fprintf(stderr, "phase:drain_30_frames\n");
    FLVSessionConfig sc;
    memset(&sc, 0, sizeof(sc));
    sc.abi_version = FLV_ABI_VERSION;
    sc.codec = FLV_H264; sc.direction = FLV_DECODE; sc.pixel_format = FLV_NV12;
    sc.width = 0; sc.height = 0; sc.frame_rate_num = 30; sc.frame_rate_den = 1;
    sc.bitstream_format = FLV_ANNEX_B; sc.flags = FLV_REQUIRE_HARDWARE;
    FLVSession *s = NULL;
    FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &s), FLV_OK);
    FLV_TEST_CHECK(clip != NULL);
    size_t bytes = 0;
    uint8_t *data = flv_test_load_file(clip, &bytes);
    FLV_TEST_CHECK(data != NULL);
    const uint8_t **parts = NULL; size_t *sizes = NULL; size_t count = 0;
    flv_test_split_annexb_aus(data, bytes, FLV_H264, &parts, &sizes, &count);
    FLV_TEST_CHECK(count == 30);
    int saw_eos = 0;
    uint32_t frames_seen = 0, hardware_seen = 0;
    for (size_t i = 0; i < count; i++) {
        FLVPacket pkt;
        memset(&pkt, 0, sizeof(pkt));
        pkt.data = parts[i]; pkt.bytes = sizes[i];
        pkt.tag = (uint64_t)i + 1;
        pkt.pts_ns = (int64_t)i * 33333333;
        int rc = flv_session_submit_packet(s, &pkt);
        for (int retry = 0; rc == FLV_AGAIN && retry < 2000; retry++) {
            FLVOutput out;
            while (flv_session_dequeue(s, &out) == FLV_OK) {
                FLV_TEST_CHECK(out.kind != FLV_OUTPUT_ERROR && out.kind != FLV_OUTPUT_EOS);
                if (out.kind == FLV_OUTPUT_FRAME) { frames_seen++; hardware_seen += out.hardware_used != 0; }
                flv_session_release_output(s, &out);
            }
            usleep(1000);
            rc = flv_session_submit_packet(s, &pkt);
        }
        FLV_TEST_CHECK_STATUS(rc, FLV_OK);
    }
    free(parts); free(sizes); free(data);
    FLV_TEST_CHECK_STATUS(flv_session_flush(s, 1), FLV_OK);
    for (int i = 0; i < 600 && !saw_eos; i++) {
        FLVOutput out;
        if (flv_session_dequeue(s, &out) == FLV_OK) {
            FLV_TEST_CHECK(out.kind != FLV_OUTPUT_ERROR);
            if (out.kind == FLV_OUTPUT_FRAME) { frames_seen++; hardware_seen += out.hardware_used != 0; }
            if (out.kind == FLV_OUTPUT_EOS) { FLV_TEST_CHECK(frames_seen == 30); saw_eos = 1; }
            flv_session_release_output(s, &out);
        } else usleep(5000);
    }
    FLV_TEST_CHECK(saw_eos);
    FLV_TEST_CHECK(frames_seen == 30 && hardware_seen == 30);
    __weak id weak_closed_session = (__bridge id)s;
    flv_session_close(s);
    s = NULL; /* close released this raw handle; never call through it again */
    FLV_TEST_CHECK(weak_closed_session == nil);

    /* Make cancelled-work accounting deterministic. The prefix above may
     * already be completed when cancel arrives; sleeping is not proof that
     * it cancelled any work. Here a real decoded frame is deliberately left
     * queued, then close must discard it and release all owned bytes. */
    fprintf(stderr, "phase:discard_queued_frame\n");
    {
        FLVSession *queued = NULL;
        FLV_TEST_CHECK_STATUS(flv_session_create(host, &sc, &queued), FLV_OK);
        size_t clip_bytes = 0;
        uint8_t *coded = flv_test_load_file(clip, &clip_bytes);
        FLV_TEST_CHECK(coded != NULL);
        const uint8_t **units = NULL; size_t *lengths = NULL; size_t unit_count = 0;
        flv_test_split_annexb_aus(coded, clip_bytes, FLV_H264, &units, &lengths, &unit_count);
        FLV_TEST_CHECK(unit_count == 30);
        FLVPacket first = {0};
        first.data = units[0]; first.bytes = lengths[0]; first.tag = 1;
        FLV_TEST_CHECK_STATUS(flv_session_submit_packet(queued, &first), FLV_OK);
        FLV_TEST_CHECK_STATUS(flv_session_flush(queued, 1), FLV_OK);
        FLVStats before;
        FLV_TEST_CHECK_STATUS(flv_host_get_stats(host, &before), FLV_OK);
        FLV_TEST_CHECK(before.queued_outputs > 0 && before.owned_bytes > 0);
        flv_session_cancel(queued);
        flv_session_close(queued);
        queued = NULL;
        FLVStats after;
        FLV_TEST_CHECK_STATUS(flv_host_get_stats(host, &after), FLV_OK);
        FLV_TEST_CHECK(after.sessions == 0 && after.inflight == 0 && after.queued_outputs == 0 && after.owned_bytes == 0);
        FLV_TEST_CHECK(after.cancelled > before.cancelled);
        free(units); free(lengths); free(coded);
    }

    /* Host destroy with a live session: the frozen ABI promises host
     * destroy closes all remaining sessions. There must be no crash, no
     * dangling callback and no leak of the host object (a strong
     * host<->session cycle previously pinned both forever). */
    {
        fprintf(stderr, "phase:host_destroy_live_session\n");
        FLVHost *host2 = NULL;
        FLV_TEST_CHECK_STATUS(flv_test_make_host(&host2, 4, 4, &ns), FLV_OK);
        FLVSessionConfig sc2;
        memset(&sc2, 0, sizeof(sc2));
        sc2.abi_version = FLV_ABI_VERSION;
        sc2.codec = FLV_H264; sc2.direction = FLV_ENCODE; sc2.pixel_format = FLV_NV12;
        sc2.width = 320; sc2.height = 180; sc2.frame_rate_num = 30; sc2.frame_rate_den = 1;
        sc2.bitstream_format = FLV_ANNEX_B; sc2.flags = FLV_REQUIRE_HARDWARE;
        FLVSession *live = NULL;
        FLV_TEST_CHECK_STATUS(flv_session_create(host2, &sc2, &live), FLV_OK);
        FLV_TEST_CHECK(live != NULL);
        __weak id weak_live_session = (__bridge id)live;
        __weak id weak_host = (__bridge id)host2;
        /* Leave the session live (never closed) and destroy the host. */
        flv_host_destroy(host2);
        live = NULL; host2 = NULL;
        FLV_TEST_CHECK(weak_live_session == nil && weak_host == nil);
        usleep(20000); /* a late callback must find a fully fenced session */
        /* A fresh host still works afterwards (no global corruption). */
        FLVHost *host3 = NULL;
        FLV_TEST_CHECK_STATUS(flv_test_make_host(&host3, 2, 2, &ns), FLV_OK);
        FLVSession *live3 = NULL;
        FLV_TEST_CHECK_STATUS(flv_session_create(host3, &sc2, &live3), FLV_OK);
        FLVStats st3;
        FLV_TEST_CHECK_STATUS(flv_host_get_stats(host3, &st3), FLV_OK);
        FLV_TEST_CHECK(st3.sessions == 1);
        flv_session_close(live3);
        flv_host_destroy(host3);
    }

    /* C-caller ownership check: repeated create/close from a plain C main
     * (no outer autoreleasepool) must stay stable; an @autoreleasepool
     * mistake at the ABI boundary would typically over-release and crash
     * within these cycles. */
    {
        fprintf(stderr, "phase:repeat_create_close\n");
        FLVHost *host4 = NULL;
        FLV_TEST_CHECK_STATUS(flv_test_make_host(&host4, 2, 2, &ns), FLV_OK);
        FLVSessionConfig sc4;
        memset(&sc4, 0, sizeof(sc4));
        sc4.abi_version = FLV_ABI_VERSION;
        sc4.codec = FLV_H264; sc4.direction = FLV_ENCODE; sc4.pixel_format = FLV_NV12;
        sc4.width = 320; sc4.height = 180; sc4.frame_rate_num = 30; sc4.frame_rate_den = 1;
        sc4.bitstream_format = FLV_ANNEX_B; sc4.flags = FLV_REQUIRE_HARDWARE;
        for (int i = 0; i < 32; i++) {
            FLVSession *cs = NULL;
            FLV_TEST_CHECK_STATUS(flv_session_create(host4, &sc4, &cs), FLV_OK);
            __weak id weak_session = (__bridge id)cs;
            flv_session_close(cs);
            cs = NULL;
            FLV_TEST_CHECK(weak_session == nil);
        }
        FLVStats st4;
        FLV_TEST_CHECK_STATUS(flv_host_get_stats(host4, &st4), FLV_OK);
        FLV_TEST_CHECK(st4.sessions == 0);
        flv_host_destroy(host4);
    }

    /* Host stats: cancelled counters advanced. */
    FLVStats stats;
    FLV_TEST_CHECK_STATUS(flv_host_get_stats(host, &stats), FLV_OK);
    FLV_TEST_CHECK(stats.cancelled > 0);
    FLV_TEST_CHECK(stats.sessions == 0 && stats.inflight == 0 && stats.queued_outputs == 0 && stats.owned_bytes == 0);

    printf("  \"eos_frames\": %u, \"eos_hardware_frames\": %u,\n", frames_seen, hardware_seen);
    printf("  \"final_stats\": {\"sessions\": %u, \"inflight\": %u, \"queued_outputs\": %u, \"owned_bytes\": %llu, \"cancelled\": %llu},\n",
           stats.sessions, stats.inflight, stats.queued_outputs,
           (unsigned long long)stats.owned_bytes, (unsigned long long)stats.cancelled);
    flv_host_destroy(host);
    printf("  \"status\": \"passed\"\n}\n");
    return 0;
}
