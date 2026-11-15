/* SPDX-License-Identifier: MPL-2.0 */
/* Guest-side standard V4L2 single-planar M2M client (stock UAPI only). */
#ifndef FLOE_CODEC_V4L2_H
#define FLOE_CODEC_V4L2_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
    const uint8_t *data;
    size_t bytes;
} floe_au;

typedef struct {
    char path[64];
    char card[64];
    char bus[64];
    int m2m;
    uint32_t decode_formats; /* bit N for FLVCodec N */
    uint32_t encode_formats;
} floe_v4l2_device_info;

int floe_codec_v4l2_scan(floe_v4l2_device_info *devices, size_t capacity, size_t *count_out);
int floe_codec_v4l2_find(const char *explicit_path, int decoder, unsigned codec,
                         floe_v4l2_device_info *out);

/* codec_fourcc is the V4L2 pixelformat (H264/HEVC/...); width/height may be
 * 0 for Annex-B H264/HEVC input. Returns 0 on success. */
int floe_codec_v4l2_decode(const char *device, uint32_t codec_fourcc,
                           const floe_au *aus, size_t au_count,
                           uint32_t width, uint32_t height,
                           FILE *output, uint32_t limit, uint64_t *frames_out,
                           uint64_t *bytes_out);
int floe_codec_v4l2_encode(const char *device, uint32_t codec_fourcc,
                           FILE *input, uint32_t width, uint32_t height,
                           uint64_t frame_bytes, uint32_t limit, FILE *output,
                           uint64_t *chunks_out, uint64_t *bytes_out);

#endif /* FLOE_CODEC_V4L2_H */
