/* SPDX-License-Identifier: MPL-2.0 */
/*
 * GENERATED FILE — do not edit by hand.
 *
 * One-frame coded probe samples used by the capability probe to verify the
 * decode data plane with real bitstreams (no containers). Each entry was
 * produced by an encoder at development time; see
 * tests/gen_probe_samples/gen_probe_samples.sh for the exact commands.
 *
 * Codecs without an entry are reported unprobed by the capability query,
 * which is the honest result when no verified sample ships with the build.
 */
#ifndef FLV_PROBE_SAMPLES_H
#define FLV_PROBE_SAMPLES_H

#include <stddef.h>
#include <stdint.h>

/* The probe table uses the FLV codec/pixel-format enums. */
#include "floe_linux_video.h"

typedef struct {
    uint32_t codec;            /* FLV codec enum */
    uint32_t pixel_format;     /* expected output pixel format (FLVPixelFormat) */
    uint32_t width, height;
    const uint8_t *config;     /* codec configuration record (avcC/hvcC/vpcC/av1C), may be NULL */
    size_t config_bytes;
    const uint8_t *frame;      /* one complete coded frame/access unit */
    size_t frame_bytes;
    const char *generator;     /* encoder + version that produced it */
} FLVProbeSample;

extern const FLVProbeSample flv_probe_samples[];
extern const size_t flv_probe_samples_count;

#endif /* FLV_PROBE_SAMPLES_H */
