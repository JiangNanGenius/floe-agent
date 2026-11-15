/* SPDX-License-Identifier: MPL-2.0 */
/* Test helpers shared by the component tests. */
#ifndef FLV_TEST_UTIL_H
#define FLV_TEST_UTIL_H

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#include <stdatomic.h>
#include "floe_linux_video.h"

typedef struct {
    _Atomic uint32_t output_ready;
    _Atomic uint32_t input_ready;
    _Atomic uint32_t error_events;
    _Atomic uint32_t total_calls;
} FLVTestNotifyState;

void flv_test_notify(void *opaque, uint64_t session_tag, uint32_t events);

int flv_test_make_host(FLVHost **host_out, uint32_t max_sessions,
                       uint32_t max_inflight, FLVTestNotifyState *notify_state);

uint8_t *flv_test_load_file(const char *path, size_t *out_bytes);
int flv_test_sha256(const uint8_t *data, size_t bytes, char hex_out[65]);

/* Drain all currently queued outputs, releasing each. Returns count drained. */
uint32_t flv_test_drain(FLVSession *s, FLVOutput *last);

/* Pack NV12 planes from a tight buffer into an FLVFrame. */
void flv_test_frame_from_nv12(const uint8_t *nv12, uint32_t w, uint32_t h,
                              int64_t pts_ns, int64_t duration_ns, uint64_t tag,
                              int keyframe, FLVFrame *frame_out);

/* Split an Annex-B stream into real access units. A new access unit starts
 * at every AUD NAL (H.264 type 9 / HEVC type 35, as inserted by
 * tests/gen_fixtures.sh); all NALs before the first AUD belong to AU 0
 * (that is where in-band SPS/PPS land). Individual NALs are NOT access
 * units: a bare SPS or PPS is metadata, not a frame. Returns 0 on success
 * and hands back malloc'd arrays the caller must free. */
int flv_test_split_annexb_aus(const uint8_t *data, size_t bytes, uint32_t codec,
                              const uint8_t ***aus_out, size_t **sizes_out, size_t *count_out);

/* Return 1 when the NAL starting at nal (nal[0..2] = start code) is an
 * access-unit delimiter for the given codec. */
int flv_test_nal_is_aud(uint32_t codec, const uint8_t *nal, size_t bytes_available);

#define FLV_TEST_CHECK(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        return 1; \
    } \
} while (0)

#define FLV_TEST_CHECK_STATUS(expr, want) do { \
    int rc_ = (expr); \
    if (rc_ != (want)) { \
        fprintf(stderr, "FAIL %s:%d: %s -> %d, want %d\n", __FILE__, __LINE__, #expr, rc_, (want)); \
        return 1; \
    } \
} while (0)

#endif /* FLV_TEST_UTIL_H */
