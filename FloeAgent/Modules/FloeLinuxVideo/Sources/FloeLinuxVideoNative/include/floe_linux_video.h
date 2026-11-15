/* SPDX-License-Identifier: MPL-2.0 */
#ifndef FLOE_LINUX_VIDEO_H
#define FLOE_LINUX_VIDEO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* In-process host interface. Never forward function pointers or native object
 * addresses to a guest. The guest sees only the fixed virtio-media/V4L2 UAPI. */
#define FLV_ABI_VERSION 1u
#define FLV_MAX_PLANES 4u
typedef struct FLVHost FLVHost;
typedef struct FLVSession FLVSession;

enum FLVStatus { FLV_OK=0, FLV_AGAIN=1, FLV_INVALID=-1, FLV_UNSUPPORTED=-2,
    FLV_LIMIT=-3, FLV_CANCELLED=-4, FLV_INTERNAL=-5, FLV_CLOSED=-6, FLV_CORRUPT=-7 };
enum FLVCodec { FLV_H264=1, FLV_HEVC=2, FLV_VP9=3, FLV_AV1=4, FLV_MJPEG=5,
    FLV_MPEG2=6, FLV_MPEG4=7, FLV_PRORES422=8, FLV_PRORES4444=9, FLV_H263=10, FLV_VP8=11 };
enum FLVDirection { FLV_ENCODE=1, FLV_DECODE=2 };
enum FLVPixelFormat { FLV_NV12=1, FLV_P010=2, FLV_BGRA=3, FLV_YUYV=4, FLV_UYVY=5 };
enum FLVBitstreamFormat { FLV_ANNEX_B=1, FLV_LENGTH_PREFIXED=2, FLV_RAW_CODED_FRAME=3 };
enum FLVCapabilityFlags { FLV_CAP_HW_REPORTED=1u, FLV_CAP_IMPLEMENTED=2u,
    FLV_CAP_SESSION_PROBED=4u,
    /* Additive (2026-11-12): a real native software
     * encode/decode was proven on this machine while no hardware path was.
     * This includes a public VideoToolbox software session or, for MJPEG, the
     * bounded public ImageIO JPEG fallback (still never hardware).
     * Never combined with HW_REPORTED/SESSION_PROBED, never satisfies
     * FLV_REQUIRE_HARDWARE, never counted as hardware use. Consumers that
     * filter flags 1|4 for hardware selection keep strict behavior because
     * this bit is outside that mask. */
    FLV_CAP_NATIVE_SOFTWARE_PROBED=8u };
enum FLVSessionFlags { FLV_REQUIRE_HARDWARE=1u, FLV_REALTIME=2u, FLV_LOW_LATENCY=4u,
    /* Additive (2026-11-12): the caller explicitly allows a proven native
     * software path for this session. It never satisfies REQUIRE_HARDWARE and
     * never changes hardware_used. Today only MJPEG uses it (public ImageIO
     * fallback); every other codec keeps its VideoToolbox path. A caller that
     * sets neither this nor REQUIRE_HARDWARE keeps the historical behavior:
     * VideoToolbox may choose software, but no ImageIO substitute is used. */
    FLV_ALLOW_NATIVE_SOFTWARE=8u };
enum FLVDataFlags { FLV_KEYFRAME=1u, FLV_END_OF_STREAM=2u, FLV_DISCONTINUITY=4u };
enum FLVOutputKind { FLV_OUTPUT_PACKET=1, FLV_OUTPUT_FRAME=2, FLV_OUTPUT_FORMAT=3,
    FLV_OUTPUT_EOS=4, FLV_OUTPUT_ERROR=5 };
enum FLVEvent { FLV_EVENT_OUTPUT_READY=1u, FLV_EVENT_INPUT_READY=2u, FLV_EVENT_ERROR=4u };

typedef struct FLVCapability {
    uint32_t codec, direction, flags, pixel_format_mask;
    /* Zero means unknown, never an invented device limit. Pixel format bit N
     * corresponds to FLVPixelFormat N. Driver advertisement must intersect
     * IMPLEMENTED, hardware-reported/probed, and Linux format mappings. */
    uint32_t max_width, max_height;
    int32_t probe_status;
    uint32_t reserved;
} FLVCapability;

/* May be invoked on a codec thread. Must only enqueue/wake the owning machine;
 * must not enter this API reentrantly. No notification follows session_close. */
typedef void (*FLVNotify)(void *opaque, uint64_t session_tag, uint32_t events);
typedef struct FLVHostConfig {
    uint32_t abi_version, max_sessions, max_inflight_per_session, reserved;
    uint64_t max_packet_bytes, max_frame_bytes, max_owned_bytes;
    FLVNotify notify;
    void *notify_opaque;
} FLVHostConfig;

typedef struct FLVSessionConfig {
    uint32_t abi_version, codec, direction, pixel_format;
    uint32_t width, height, frame_rate_num, frame_rate_den;
    uint64_t bitrate, session_tag;
    uint32_t flags, bitstream_format, profile, reserved;
    /* Copied during creation. Codec configuration record when needed (avcC,
     * hvcC, vpcC, av1C). Annex B H264/HEVC may instead configure from in-band
     * parameter sets. Invalid/missing required configuration must fail clearly. */
    const uint8_t *codec_config;
    size_t codec_config_bytes;
} FLVSessionConfig;

typedef struct FLVPacket {
    const uint8_t *data;
    size_t bytes;
    int64_t pts_ns, dts_ns, duration_ns;
    uint64_t tag;
    uint32_t flags, reserved;
} FLVPacket;

typedef struct FLVFrame {
    const uint8_t *data;
    size_t bytes;
    uint32_t width, height, pixel_format, plane_count;
    uint64_t plane_offsets[FLV_MAX_PLANES];
    uint64_t plane_bytes[FLV_MAX_PLANES];
    uint32_t plane_strides[FLV_MAX_PLANES];
    int64_t pts_ns, duration_ns;
    uint64_t tag;
    uint32_t flags, reserved;
} FLVFrame;

typedef struct FLVOutput {
    uint32_t kind, flags;
    int32_t status;
    uint32_t hardware_used;
    uint64_t tag;
    int64_t pts_ns, dts_ns, duration_ns;
    const uint8_t *data;
    size_t bytes;
    uint32_t width, height, pixel_format, plane_count;
    uint64_t plane_offsets[FLV_MAX_PLANES];
    uint64_t plane_bytes[FLV_MAX_PLANES];
    uint32_t plane_strides[FLV_MAX_PLANES];
    /* Owned host token; never expose to guest. Release before session_close.
     * Output data remains valid until release. No caller-owned guest pointer
     * may be retained after a submit function returns. */
    void *release_token;
} FLVOutput;

typedef struct FLVStats {
    uint32_t sessions, inflight, queued_outputs, reserved;
    uint64_t owned_bytes, peak_owned_bytes, submitted, completed, cancelled;
} FLVStats;

int flv_host_create(const FLVHostConfig *config, FLVHost **host_out);
/* Returns required entry count, including unsupported known codecs as flags=0.
 * Capacity=0 permits a count query. Unknown/unsupported must never be advertised
 * as hardware merely because a software VideoToolbox session could be created. */
int flv_host_query_capabilities(FLVHost *host, FLVCapability *entries,
                                size_t capacity, size_t *required_count);
int flv_host_get_stats(FLVHost *host, FLVStats *stats);
void flv_host_destroy(FLVHost *host);
int flv_session_create(FLVHost *host, const FLVSessionConfig *config, FLVSession **session_out);
/* Bounded, copies input into owned buffers. FLV_AGAIN means backpressure and no
 * input ownership transfer. REQUIRE_HARDWARE sessions fail on software fallback. */
int flv_session_submit_packet(FLVSession *session, const FLVPacket *packet);
int flv_session_submit_frame(FLVSession *session, const FLVFrame *frame);
int flv_session_dequeue(FLVSession *session, FLVOutput *output);
void flv_session_release_output(FLVSession *session, FLVOutput *output);
/* Drain queues an EOS after earlier output; discard drops queued work.
 * Cancellation fences late callbacks. close invalidates and joins callbacks
 * before releasing the session. Host destroy closes all remaining sessions. */
int flv_session_flush(FLVSession *session, int drain);
void flv_session_cancel(FLVSession *session);
void flv_session_close(FLVSession *session);
#ifdef __cplusplus
}
#endif
#endif
