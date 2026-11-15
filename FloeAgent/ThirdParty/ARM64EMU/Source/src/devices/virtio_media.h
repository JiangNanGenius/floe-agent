/* SPDX-License-Identifier: Apache-2.0 */
#ifndef FLOE_VIRTIO_MEDIA_H
#define FLOE_VIRTIO_MEDIA_H
#include "../types.h"
struct Machine;
struct GIC;
struct VirtIOMedia;
#define FLOE_VIDEO_DECODER_SLOT 28
#define FLOE_VIDEO_ENCODER_SLOT 29
/* Disjoint from RAM, flash, PCI and the GPU's [64,68) GiB aperture. */
#define FLOE_VIDEO_DECODER_BASE UINT64_C(0x1200000000)
#define FLOE_VIDEO_ENCODER_BASE UINT64_C(0x1300000000)
#define FLOE_VIDEO_APERTURE_BYTES UINT64_C(268435456)
typedef struct VirtIOMediaOptions {
    uint32_t direction;           /* FLV_ENCODE / FLV_DECODE */
    uint32_t max_sessions;        /* 1..4, 0 = 4 */
    uint64_t host_owned_limit;    /* 0 = 128 MiB per device */
    int wake_fd;
    uint16_t broker_port;         /* 0 = no typed broker endpoint advertised */
    uint64_t broker_token;        /* guest-visible discovery token (not a host secret) */
} VirtIOMediaOptions;
typedef struct VirtIOMediaStats {
    uint32_t nodes,sessions,inflight,queued_outputs;
    uint64_t owned_mmap_bytes,host_owned_bytes,host_peak_bytes;
    uint64_t submitted,hardware_outputs,errors;
    uint64_t native_software_outputs;
    uint32_t native_software_enabled,native_software_formats;
    uint32_t native_software_mask; /* bit (codec-1)*2 + (direction-1) */
} VirtIOMediaStats;
struct VirtIOMedia *virtio_media_create(struct Machine *,struct GIC *,int,
                                      const VirtIOMediaOptions *);
void virtio_media_destroy(struct VirtIOMedia *);
void virtio_media_reset(struct VirtIOMedia *);
/* Independent of the optional graphics device. Coordinator-only service;
 * codec callbacks only mark atomic readiness and wake the owner's pipe. */
bool virtio_media_has_work(struct Machine *);
void virtio_media_service(struct Machine *);
void virtio_media_get_stats(struct Machine *,VirtIOMediaStats *);
/* Atomic policy transition between client sessions; existing open handles
 * keep their negotiated backend. Coordinator only. Returns EBUSY if active. */
int virtio_media_set_native_software(struct Machine *,bool);
#endif
