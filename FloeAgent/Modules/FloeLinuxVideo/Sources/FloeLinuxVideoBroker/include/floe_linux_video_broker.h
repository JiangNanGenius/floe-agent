/* SPDX-License-Identifier: MPL-2.0
 *
 * floe_linux_video_broker.h — additive app-owned typed native-codec broker.
 *
 * This API is separate from, and does not modify, the frozen host C ABI
 * floe_linux_video.h (ABI 1). It exposes a bounded loopback TCP service that
 * carries typed codec requests for Linux consumers that have no standard
 * stateful V4L2 mapping (AV1 decode, ProRes 422/4444, and an explicit
 * generic path for every other host-supported codec).
 *
 * Lifetime: the owner creates one broker per machine, before platform build,
 * and destroys it after all virtio-media nodes have been destroyed. The
 * broker owns its own FLVHost and its own server thread. The guest reaches
 * the listener through libslirp's existing 10.0.2.2 host-loopback alias; the
 * listener binds 127.0.0.1 only. No NAT rule, host file share or shell
 * execution is added.
 */
#ifndef FLOE_LINUX_VIDEO_BROKER_H
#define FLOE_LINUX_VIDEO_BROKER_H

#include <stddef.h>
#include <stdint.h>

#include "floe_linux_video.h"
#include "floe_linux_video_broker_wire.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FLVB_ABI_VERSION 1u

typedef struct FLVBroker FLVBroker;

typedef struct {
    uint32_t abi_version;          /* FLVB_ABI_VERSION */
    uint32_t max_sessions;         /* 1..8; 0 = 4 */
    uint32_t max_inflight;         /* per session, 1..16; 0 = 8 */
    uint32_t reserved;             /* must be 0 */
    uint64_t max_packet_bytes;     /* 0 = 16 MiB; bounded to 256 MiB */
    uint64_t max_frame_bytes;      /* 0 = 64 MiB; bounded to 512 MiB */
    uint64_t max_owned_bytes;      /* 0 = 128 MiB; bounded to 512 MiB */
    uint16_t port;                 /* 0 = ephemeral loopback port */
    uint16_t reserved_port;
    const char *access_token;      /* optional NUL-terminated lowercase hex;
                                    * NULL/empty generates a 64-bit token */
} FLVBrokerConfig;

typedef struct {
    uint32_t abi_version;
    uint32_t nodes;                /* 1 when the broker runs */
    uint32_t sessions;
    uint32_t inflight;
    uint32_t queued_outputs;
    uint32_t native_software_enabled;
    uint64_t host_owned_bytes;
    uint64_t host_peak_bytes;
    uint64_t submitted;
    uint64_t hardware_outputs;
    uint64_t native_software_outputs;
    uint64_t errors;
    uint32_t native_software_formats;
    uint32_t native_software_mask; /* bit (codec-1)*2 + (direction-1) */
    uint32_t accepted_clients;
    uint64_t cancelled;
    uint64_t reserved[4];
} FLVBrokerStats;

/* Creates the listener and starts the single-client service. `port_out` is
 * the actual loopback port (needed for the V4L2 bus_info discovered by the
 * guest client). The token is always generated or validated as 16 hex chars;
 * `token_out` receives the 64-bit value. Either out pointer may be NULL. */
int flvb_create(const FLVBrokerConfig *config, uint16_t *port_out,
                uint64_t *token_out, FLVBroker **broker_out);

/* Joins the server thread, closes any live client/session, then releases the
 * host. Safe for NULL. No callback can run after it returns. */
void flvb_destroy(FLVBroker *broker);

/* Snapshot; safe from the coordinator while the server thread runs. */
int flvb_get_stats(FLVBroker *broker, FLVBrokerStats *stats);

/* Backend policy (hardware-only vs allow proven native software). Applies to
 * sessions created afterwards; an existing live session keeps its negotiated
 * backend. Returns FLV_OK, FLV_INVALID, or FLV_AGAIN when any session exists
 * (the caller must retry between file sessions). */
int flvb_set_native_software(FLVBroker *broker, uint32_t enabled);

/* Whether a session is currently live. Used by the engine to reject a policy
 * change before touching either the V4L2 nodes or this broker. */
int flvb_has_live_session(FLVBroker *broker, uint32_t *has_live);

/* Test/qualification helper: format the guest-visible endpoint string
 * "floe:v1:<port>:<16 hex>" into a 32-byte buffer (including NUL). */
int flvb_format_endpoint(uint16_t port, uint64_t token, char out[32]);

#ifdef __cplusplus
}
#endif
#endif /* FLOE_LINUX_VIDEO_BROKER_H */
