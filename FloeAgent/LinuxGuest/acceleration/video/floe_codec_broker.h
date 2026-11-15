/* SPDX-License-Identifier: MPL-2.0 */
/* Guest-side typed native-codec broker client. POSIX only; no Apple headers. */
#ifndef FLOE_CODEC_BROKER_H
#define FLOE_CODEC_BROKER_H

#include <stddef.h>
#include <stdint.h>
#include "floe_linux_video_broker_wire.h"

#define FLOE_CODEC_MAX_CAPS 22

typedef struct {
    int fd;
    uint64_t token;
    char host[64];
    uint16_t port;
    uint64_t max_packet_bytes;
} floe_codec_broker;

typedef struct {
    uint32_t codec, direction, flags, pixel_format_mask;
    uint32_t max_width, max_height;
    int32_t probe_status;
} floe_codec_capability;

/* Discover "floe:v1:<port>:<token>" from a V4L2 QUERYCAP bus_info. The scan
 * path may be a specific device or NULL to scan /dev/video0..31. Returns 0 on
 * success. */
int floe_codec_discover_endpoint(const char *device, char *host, size_t host_cap,
                                 uint16_t *port, uint64_t *token);

/* Parse "host:port:token" or "port:token" (host defaults to 10.0.2.2). */
int floe_codec_parse_endpoint(const char *text, char *host, size_t host_cap,
                              uint16_t *port, uint64_t *token);

int floe_codec_broker_open(floe_codec_broker *client, const char *host, uint16_t port,
                           uint64_t token);
void floe_codec_broker_close(floe_codec_broker *client);

int floe_codec_broker_list(floe_codec_broker *client,
                           floe_codec_capability *caps, size_t capacity,
                           size_t *count_out, uint32_t *native_software_enabled);

int floe_codec_broker_create(floe_codec_broker *client, uint32_t codec, uint32_t direction,
                             uint32_t pixel_format, uint32_t width, uint32_t height,
                             uint32_t bitstream_format, uint32_t flags, uint64_t bitrate,
                             const uint8_t *config, size_t config_bytes,
                             uint64_t *session_out);

int floe_codec_broker_destroy(floe_codec_broker *client, uint64_t session);
int floe_codec_broker_submit_packet(floe_codec_broker *client, uint64_t session,
                                    const uint8_t *data, size_t bytes,
                                    int64_t pts_ns, int64_t dts_ns, int64_t duration_ns,
                                    uint32_t flags);
int floe_codec_broker_submit_frame(floe_codec_broker *client, uint64_t session,
                                   const uint8_t *data, size_t bytes,
                                   int64_t pts_ns, int64_t duration_ns, uint32_t flags);
/* Waits up to timeout_ms for one output. On a successful output the reply is
 * filled and *payload_out is malloc'd by the caller's free() when length > 0. */
int floe_codec_broker_dequeue(floe_codec_broker *client, uint64_t session,
                              flvb_reply *reply, uint8_t **payload_out,
                              uint32_t timeout_ms);
int floe_codec_broker_flush(floe_codec_broker *client, uint64_t session, int drain);
int floe_codec_broker_cancel(floe_codec_broker *client, uint64_t session);

#endif /* FLOE_CODEC_BROKER_H */
