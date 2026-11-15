/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FloeLinuxVideoHost — in-process host backend for the Floe Linux video
 * driver, backed by public Apple VideoToolbox / CoreMedia / CoreVideo.
 *
 * This library is the host side of the fixed C ABI declared in
 * floe_linux_video.h (ABI 1). It never exposes host function pointers or
 * native object addresses to a guest; a guest only sees the bounded
 * virtio-media / V4L2 device surface built on top of this API by the
 * emulator integration.
 *
 * Design notes:
 *  - Sessions are asynchronous. All VT callbacks only enqueue owned output
 *    and raise the host notify hook; they never re-enter this API.
 *  - Every submitted input is copied into host-owned memory before VT sees
 *    it. No guest pointer is retained after a submit call returns.
 *  - Outputs are host-owned until flv_session_release_output. The release
 *    token is an opaque host allocation and is never guest-visible.
 *  - Cancellation fences late callbacks with a generation counter; close
 *    invalidates the VT session (which joins pending callbacks) and then
 *    frees only what this session owned.
 *  - Capability records are truthful: a codec/direction is only advertised
 *    with FLV_CAP_HW_REPORTED / FLV_CAP_SESSION_PROBED after a real
 *    hardware-required session probe on the actual machine.
 */
#ifndef FLV_INTERNAL_H
#define FLV_INTERNAL_H

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <pthread.h>

#include "floe_linux_video.h"

#define FLV_ARRAY_COUNT(a) (sizeof(a) / sizeof((a)[0]))

/* Development-time diagnostics only; never prints media payloads. */
#define FLVLogF(...) do { \
    fprintf(stderr, "[FloeLinuxVideo] " __VA_ARGS__); fputc('\n', stderr); \
} while (0)

/* Hard structural bounds; configured limits sit below these. */
#define FLV_STRUCT_MAX_DIMENSION 8192u
#define FLV_STRUCT_MAX_PACKET_BYTES (256ull * 1024ull * 1024ull)
#define FLV_STRUCT_MAX_FRAME_BYTES (512ull * 1024ull * 1024ull)
#define FLV_MAX_QUEUED_OUTPUTS 256u

static inline uint32_t flv_pixel_format_bit(uint32_t pf) {
    return (pf > 0 && pf < 32) ? (1u << pf) : 0u;
}

/* Pixel format geometry. Returns FLV_OK and fills plane layout. */
int flv_pixel_layout(uint32_t pixel_format, uint32_t width, uint32_t height,
                     uint32_t *plane_count,
                     uint64_t *plane_bytes, uint32_t *min_strides, uint32_t *plane_rows);

/* Rejects zero dimensions and byte-size overflow. */
int flv_validate_dimensions(uint32_t width, uint32_t height);

/* Safe unsigned saturating accounting helpers. */
static inline uint64_t flv_sat_add(uint64_t a, uint64_t b) {
    uint64_t r = a + b;
    return (r < a) ? UINT64_MAX : r;
}

#endif /* FLV_INTERNAL_H */
