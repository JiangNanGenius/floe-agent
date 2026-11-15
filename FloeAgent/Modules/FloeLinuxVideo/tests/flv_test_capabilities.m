/* SPDX-License-Identifier: MPL-2.0 */
/* Capability truthfulness test: all 22 slots must exist, no entry may claim
 * hardware without a real probe, and the native software flag (8) must never
 * coexist with hardware flags (1|4) nor satisfy hardware filtering. */
#import "flv_test_util.h"
#import "FLVCodecRegistry.h" /* FLV_CAP_NATIVE_SOFTWARE_PROBED (internal) */

int main(void) {
    FLVTestNotifyState ns;
    memset(&ns, 0, sizeof(ns));
    FLVHost *host = NULL;
    FLV_TEST_CHECK_STATUS(flv_test_make_host(&host, 2, 2, &ns), FLV_OK);

    size_t required = 0;
    FLV_TEST_CHECK_STATUS(flv_host_query_capabilities(host, NULL, 0, &required), FLV_OK);
    FLV_TEST_CHECK(required == 22);

    FLVCapability caps[22];
    memset(caps, 0, sizeof(caps));
    FLV_TEST_CHECK_STATUS(flv_host_query_capabilities(host, caps, 22, &required), FLV_OK);
    FLV_TEST_CHECK(required == 22);

    uint32_t seen[12][2];
    memset(seen, 0, sizeof(seen));
    for (size_t i = 0; i < 22; i++) {
        const FLVCapability *c = &caps[i];
        FLV_TEST_CHECK(c->codec >= FLV_H264 && c->codec <= FLV_VP8);
        FLV_TEST_CHECK(c->direction == FLV_ENCODE || c->direction == FLV_DECODE);
        seen[c->codec][c->direction - 1]++;
        FLV_TEST_CHECK(c->reserved == 0);
        if (c->flags & FLV_CAP_HW_REPORTED) {
            FLV_TEST_CHECK(c->flags & FLV_CAP_IMPLEMENTED);
            FLV_TEST_CHECK(c->flags & FLV_CAP_SESSION_PROBED);
        }
        if (c->flags & FLV_CAP_SESSION_PROBED) {
            FLV_TEST_CHECK(c->flags & FLV_CAP_IMPLEMENTED);
            FLV_TEST_CHECK(c->probe_status == FLV_OK);
            FLV_TEST_CHECK(c->max_width > 0 && c->max_height > 0);
            FLV_TEST_CHECK(c->pixel_format_mask != 0);
        } else if (!(c->flags & FLV_CAP_NATIVE_SOFTWARE_PROBED)) {
            FLV_TEST_CHECK(c->max_width == 0 && c->max_height == 0);
        }
        /* Native software flag (8): never with hardware flags 1|4 (old
         * hardware-only callers filter 1|4 and must keep strict behavior),
         * always with IMPLEMENTED, and only after a real successful probe
         * with measured dimensions. */
        if (c->flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) {
            FLV_TEST_CHECK((c->flags & (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED)) == 0);
            FLV_TEST_CHECK(c->flags & FLV_CAP_IMPLEMENTED);
            FLV_TEST_CHECK(c->probe_status == FLV_OK);
            FLV_TEST_CHECK(c->max_width > 0 && c->max_height > 0);
            FLV_TEST_CHECK(c->pixel_format_mask != 0);
        }
        /* pixel mask may only contain NV12 (bit1) / P010 (bit2) today */
        FLV_TEST_CHECK((c->pixel_format_mask & ~(0x2u | 0x4u)) == 0);
    }
    for (uint32_t codec = FLV_H264; codec <= FLV_VP8; codec++)
        FLV_TEST_CHECK(seen[codec][0] == 1 && seen[codec][1] == 1);

    /* VP8 has no public VT path: must never claim anything. */
    const FLVCapability *vp8enc = NULL, *vp8dec = NULL;
    for (size_t i = 0; i < 22; i++) {
        if (caps[i].codec == FLV_VP8 && caps[i].direction == FLV_ENCODE) vp8enc = &caps[i];
        if (caps[i].codec == FLV_VP8 && caps[i].direction == FLV_DECODE) vp8dec = &caps[i];
    }
    FLV_TEST_CHECK(vp8enc && vp8dec);
    FLV_TEST_CHECK(vp8enc->flags == 0 && vp8dec->flags == 0);

    printf("{\n  \"test\": \"capabilities\",\n  \"status\": \"passed\",\n  \"slots\": %zu,\n  \"entries\": [\n", required);
    for (size_t i = 0; i < 22; i++) {
        printf("    {\"codec\": %u, \"direction\": %u, \"flags\": %u, \"pixel_mask\": %u, \"max\": [%u, %u], \"probe_status\": %d}%s\n",
               caps[i].codec, caps[i].direction, caps[i].flags, caps[i].pixel_format_mask,
               caps[i].max_width, caps[i].max_height, caps[i].probe_status,
               i + 1 < 22 ? "," : "");
    }
    printf("  ]\n}\n");
    flv_host_destroy(host);
    return 0;
}
