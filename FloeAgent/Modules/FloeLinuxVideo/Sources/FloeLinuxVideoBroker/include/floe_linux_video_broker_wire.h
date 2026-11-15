/* SPDX-License-Identifier: MPL-2.0
 *
 * floe_linux_video_broker_wire.h — the typed native-codec broker wire
 * contract, shared byte-for-byte by the in-App server and the Linux guest
 * client (FloeAgent/LinuxGuest/acceleration/video/floe_codec.c).
 *
 * This header is deliberately separate from floe_linux_video.h: the frozen
 * C ABI 1 host interface is unchanged. No Apple symbol, object address,
 * host path or file descriptor crosses this wire.
 *
 * Framing: every message starts with one fixed request/reply header in the
 * host byte order of both sides (little-endian on arm64 Darwin/Linux).
 * Exactly one request is outstanding per client; the server replies once.
 * All lengths are bounded by the capabilities reported in LIST/HELLO and the
 * server's configured packet/frame limits. Session IDs are opaque server
 * tokens, never pointers.
 *
 * Data plane:
 *   DECODE: SUBMIT_PACKET(coded access unit) -> DEQUEUE packet/frame/EOS
 *   ENCODE: SUBMIT_FRAME(raw NV12/P010)       -> DEQUEUE packet/EOS
 *
 * The broker never opens a client-supplied path. Clients read/write their
 * own files; only bytes and numeric parameters are sent here.
 */
#ifndef FLOE_LINUX_VIDEO_BROKER_WIRE_H
#define FLOE_LINUX_VIDEO_BROKER_WIRE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FLVB_WIRE_MAGIC   0x42564c46u /* "FLVB" little-endian */
#define FLVB_WIRE_VERSION 1u

/* Handshake, client -> server, 24 bytes. */
typedef struct {
    uint32_t magic;     /* FLVB_WIRE_MAGIC */
    uint32_t version;   /* FLVB_WIRE_VERSION */
    uint64_t token;     /* per-machine token from the V4L2 QUERYCAP bus_info */
    uint32_t flags;     /* reserved, must be 0 */
    uint32_t reserved;  /* must be 0 */
} flvb_hello;

/* Handshake reply, 16 bytes. */
typedef struct {
    uint32_t magic;
    uint32_t version;
    int32_t  status;    /* 0 = accepted; -1 = refused (bad token/version/busy) */
    uint32_t max_packet_bytes; /* 0 is never sent; bounded server limit */
} flvb_hello_reply;

/* Request opcodes. Numbers are wire constants, never C enum ABI. */
#define FLVB_OP_LIST        0x10u
#define FLVB_OP_CREATE      0x11u
#define FLVB_OP_DESTROY     0x12u
#define FLVB_OP_SUBMIT_PACKET 0x13u
#define FLVB_OP_SUBMIT_FRAME  0x14u
#define FLVB_OP_DEQUEUE     0x15u
#define FLVB_OP_FLUSH       0x16u
#define FLVB_OP_CANCEL      0x17u

/* Request header, 56 bytes, naturally aligned. `length` is the number of
 * payload bytes immediately following this header. */
typedef struct {
    uint32_t magic;
    uint32_t op;
    uint32_t flags;      /* op-specific small flags (keyframe, drain, ...) */
    uint32_t reserved;   /* must be 0 */
    uint64_t session;    /* server token; 0 for LIST/CREATE */
    uint64_t pts_ns;
    uint64_t dts_ns;
    uint64_t duration_ns;
    uint32_t length;     /* payload bytes */
    uint32_t aux;        /* timeout_ms (DEQUEUE) / plane hint / reserved */
} flvb_request;

/* Reply header, 96 bytes, naturally aligned. `length` payload bytes follow. */
typedef struct {
    uint32_t magic;
    uint32_t op;
    int32_t  status;     /* FLV_OK/FLV_AGAIN/... (wire values equal ABI 1) */
    uint32_t kind;       /* 1 packet, 2 frame, 3 format, 4 EOS, 5 error */
    uint32_t flags;      /* FLVDataFlags */
    uint32_t hardware_used; /* 1 only when the producing session was hardware */
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;
    uint32_t plane_count;
    uint64_t session;
    int64_t  pts_ns;
    int64_t  dts_ns;
    int64_t  duration_ns;
    uint64_t tag;
    uint32_t length;
    uint32_t reserved;
} flvb_reply;

/* CREATE payload, 56 bytes: 10 u32 fields then one u64 and two u32 fields,
 * followed by exactly codec_config_bytes bytes. */
typedef struct {
    uint32_t codec;          /* FLVCodec 1..11 */
    uint32_t direction;      /* FLV_ENCODE=1 / FLV_DECODE=2 */
    uint32_t pixel_format;   /* FLVPixelFormat */
    uint32_t width;
    uint32_t height;
    uint32_t frame_rate_num;
    uint32_t frame_rate_den;
    uint32_t bitstream_format; /* FLVBitstreamFormat */
    uint32_t profile;
    uint32_t flags;          /* FLV_REQUIRE_HARDWARE/REALTIME/LOW_LATENCY */
    uint64_t bitrate;
    uint32_t codec_config_bytes;
    uint32_t reserved;       /* must be 0 */
} flvb_create_request;

/* LIST reply: u32 native_software_enabled, u32 count, then count records. */
typedef struct {
    uint32_t codec;
    uint32_t direction;
    uint32_t flags;
    uint32_t pixel_format_mask;
    uint32_t max_width;
    uint32_t max_height;
    int32_t  probe_status;
    uint32_t reserved;
} flvb_capability;

/* DEQUEUE payload (after a successful header) uses the reply metadata and
 * the concatenated planes in canonical order with no row padding:
 *   NV12:  Y (width*height) then interleaved UV (width*height/2)
 *   P010:  Y (width*height*2) then interleaved UV (width*height)
 * Coded packet payloads are the exact raw coded bytes. */

#ifdef __cplusplus
}
#endif
#endif /* FLOE_LINUX_VIDEO_BROKER_WIRE_H */
