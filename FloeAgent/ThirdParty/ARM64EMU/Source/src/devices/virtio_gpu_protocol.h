/* SPDX-License-Identifier: BSD-3-Clause */
/* virtio-gpu protocol constants and wire structures, reimplemented from the
 * OASIS Virtio Specification v1.3 (virtio-gpu device, section 5.7) and
 * cross-checked against the Linux UAPI header include/uapi/linux/virtio_gpu.h
 * (BSD-3-Clause, Red Hat / Dave Airlie / Gerd Hoffmann). No GPL sources used.
 *
 * This is a fresh implementation for the Floe ARM64EMU virtio-gpu transport
 * candidate. Structures are little-endian wire format; the device core uses
 * the le{16,32,64} load/store helpers in virtio_gpu.c. */
#ifndef A64_VIRTIO_GPU_PROTOCOL_H
#define A64_VIRTIO_GPU_PROTOCOL_H

#include "../types.h"

/* ---- feature bits (device-specific bits 0..4, transport bit 32) ---- */
#define VIRTIO_GPU_F_VIRGL          0u   /* 3D commands + ctx lifecycle      */
#define VIRTIO_GPU_F_EDID           1u   /* VIRTIO_GPU_CMD_GET_EDID          */
#define VIRTIO_GPU_F_RESOURCE_UUID  2u   /* (not advertised by transport v1) */
#define VIRTIO_GPU_F_RESOURCE_BLOB  3u   /* blob resources + host-visible shm */
#define VIRTIO_GPU_F_CONTEXT_INIT   4u   /* ctx create with capset id + rings */

#define VIRTIO_F_VERSION_1          (1ULL << 32)

/* ---- shared memory region ids ---- */
#define VIRTIO_GPU_SHM_ID_UNDEFINED   0
#define VIRTIO_GPU_SHM_ID_HOST_VISIBLE 1

/* ---- control command types ---- */
enum virtio_gpu_ctrl_type {
    VIRTIO_GPU_UNDEFINED = 0,
    /* 2d commands */
    VIRTIO_GPU_CMD_GET_DISPLAY_INFO = 0x0100,
    VIRTIO_GPU_CMD_RESOURCE_CREATE_2D,
    VIRTIO_GPU_CMD_RESOURCE_UNREF,
    VIRTIO_GPU_CMD_SET_SCANOUT,
    VIRTIO_GPU_CMD_RESOURCE_FLUSH,
    VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D,
    VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING,
    VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING,
    VIRTIO_GPU_CMD_GET_CAPSET_INFO,
    VIRTIO_GPU_CMD_GET_CAPSET,
    VIRTIO_GPU_CMD_GET_EDID,
    VIRTIO_GPU_CMD_RESOURCE_ASSIGN_UUID,
    VIRTIO_GPU_CMD_RESOURCE_CREATE_BLOB,
    VIRTIO_GPU_CMD_SET_SCANOUT_BLOB,
    /* 3d commands */
    VIRTIO_GPU_CMD_CTX_CREATE = 0x0200,
    VIRTIO_GPU_CMD_CTX_DESTROY,
    VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE,
    VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE,
    VIRTIO_GPU_CMD_RESOURCE_CREATE_3D,
    VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D,
    VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D,
    VIRTIO_GPU_CMD_SUBMIT_3D,
    VIRTIO_GPU_CMD_RESOURCE_MAP_BLOB,
    VIRTIO_GPU_CMD_RESOURCE_UNMAP_BLOB,
    /* cursor commands */
    VIRTIO_GPU_CMD_UPDATE_CURSOR = 0x0300,
    VIRTIO_GPU_CMD_MOVE_CURSOR,
    /* success responses */
    VIRTIO_GPU_RESP_OK_NODATA = 0x1100,
    VIRTIO_GPU_RESP_OK_DISPLAY_INFO,
    VIRTIO_GPU_RESP_OK_CAPSET_INFO,
    VIRTIO_GPU_RESP_OK_CAPSET,
    VIRTIO_GPU_RESP_OK_EDID,
    VIRTIO_GPU_RESP_OK_RESOURCE_UUID,
    VIRTIO_GPU_RESP_OK_MAP_INFO,
    /* error responses */
    VIRTIO_GPU_RESP_ERR_UNSPEC = 0x1200,
    VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY,
    VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID,
    VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID,
    VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID,
    VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER,
};

/* ---- ctrl hdr flags ---- */
#define VIRTIO_GPU_FLAG_FENCE       (1u << 0)
#define VIRTIO_GPU_FLAG_INFO_RING_IDX (1u << 1)

struct virtio_gpu_ctrl_hdr {
    u32 type;
    u32 flags;
    u64 fence_id;
    u32 ctx_id;
    u8  ring_idx;
    u8  padding[3];
};

/* ---- cursor ---- */
struct virtio_gpu_cursor_pos { u32 scanout_id, x, y, padding; };
struct virtio_gpu_update_cursor {
    struct virtio_gpu_ctrl_hdr hdr;
    struct virtio_gpu_cursor_pos pos;
    u32 resource_id, hot_x, hot_y, padding;
};

/* ---- 2d ---- */
struct virtio_gpu_rect { u32 x, y, width, height; };
struct virtio_gpu_resource_unref { struct virtio_gpu_ctrl_hdr hdr; u32 resource_id, padding; };
struct virtio_gpu_resource_create_2d {
    struct virtio_gpu_ctrl_hdr hdr;
    u32 resource_id, format, width, height;
};
struct virtio_gpu_set_scanout {
    struct virtio_gpu_ctrl_hdr hdr;
    struct virtio_gpu_rect r;
    u32 scanout_id, resource_id;
};
struct virtio_gpu_resource_flush { struct virtio_gpu_ctrl_hdr hdr; struct virtio_gpu_rect r; u32 resource_id, padding; };
struct virtio_gpu_transfer_to_host_2d {
    struct virtio_gpu_ctrl_hdr hdr;
    struct virtio_gpu_rect r;
    u64 offset;
    u32 resource_id, padding;
};
struct virtio_gpu_mem_entry { u64 addr; u32 length, padding; };
struct virtio_gpu_resource_attach_backing {
    struct virtio_gpu_ctrl_hdr hdr;
    u32 resource_id, nr_entries;
};
struct virtio_gpu_resource_detach_backing { struct virtio_gpu_ctrl_hdr hdr; u32 resource_id, padding; };

#define VIRTIO_GPU_MAX_SCANOUTS 16
struct virtio_gpu_resp_display_info {
    struct virtio_gpu_ctrl_hdr hdr;
    struct { struct virtio_gpu_rect r; u32 enabled, flags; } pmodes[VIRTIO_GPU_MAX_SCANOUTS];
};

/* ---- 3d ---- */
struct virtio_gpu_box { u32 x, y, z, w, h, d; };
struct virtio_gpu_transfer_host_3d {
    struct virtio_gpu_ctrl_hdr hdr;
    struct virtio_gpu_box box;
    u64 offset;
    u32 resource_id, level, stride, layer_stride;
};
#define VIRTIO_GPU_RESOURCE_FLAG_Y_0_TOP (1u << 0)
struct virtio_gpu_resource_create_3d {
    struct virtio_gpu_ctrl_hdr hdr;
    u32 resource_id, target, format, bind, width, height, depth;
    u32 array_size, last_level, nr_samples, flags, padding;
};
#define VIRTIO_GPU_CONTEXT_INIT_CAPSET_ID_MASK 0x000000ff
struct virtio_gpu_ctx_create {
    struct virtio_gpu_ctrl_hdr hdr;
    u32 nlen, context_init;
    char debug_name[64];
};
struct virtio_gpu_ctx_destroy { struct virtio_gpu_ctrl_hdr hdr; };
struct virtio_gpu_ctx_resource { struct virtio_gpu_ctrl_hdr hdr; u32 resource_id, padding; };
struct virtio_gpu_cmd_submit { struct virtio_gpu_ctrl_hdr hdr; u32 size, padding; };

/* ---- capsets ---- */
#define VIRTIO_GPU_CAPSET_VIRGL  1
#define VIRTIO_GPU_CAPSET_VIRGL2 2
/* 3 reserved for gfxstream */
#define VIRTIO_GPU_CAPSET_VENUS  4
#define VIRTIO_GPU_CAPSET_DRM    6

struct virtio_gpu_get_capset_info { struct virtio_gpu_ctrl_hdr hdr; u32 capset_index, padding; };
struct virtio_gpu_resp_capset_info {
    struct virtio_gpu_ctrl_hdr hdr;
    u32 capset_id, capset_max_version, capset_max_size, padding;
};
struct virtio_gpu_get_capset { struct virtio_gpu_ctrl_hdr hdr; u32 capset_id, capset_version; };
struct virtio_gpu_resp_capset { struct virtio_gpu_ctrl_hdr hdr; u8 capset_data[]; };

/* ---- EDID ---- */
struct virtio_gpu_cmd_get_edid { struct virtio_gpu_ctrl_hdr hdr; u32 scanout, padding; };
struct virtio_gpu_resp_edid { struct virtio_gpu_ctrl_hdr hdr; u32 size, padding; u8 edid[1024]; };

/* ---- config space (at MMIO 0x100) ---- */
#define VIRTIO_GPU_EVENT_DISPLAY (1u << 0)
struct virtio_gpu_config { u32 events_read, events_clear, num_scanouts, num_capsets; };

/* ---- blob ---- */
struct virtio_gpu_resource_assign_uuid { struct virtio_gpu_ctrl_hdr hdr; u32 resource_id, padding; };
struct virtio_gpu_resp_resource_uuid { struct virtio_gpu_ctrl_hdr hdr; u8 uuid[16]; };

#define VIRTIO_GPU_BLOB_MEM_GUEST        0x0001
#define VIRTIO_GPU_BLOB_MEM_HOST3D       0x0002
#define VIRTIO_GPU_BLOB_MEM_HOST3D_GUEST 0x0003
#define VIRTIO_GPU_BLOB_FLAG_USE_MAPPABLE     0x0001
#define VIRTIO_GPU_BLOB_FLAG_USE_SHAREABLE    0x0002
#define VIRTIO_GPU_BLOB_FLAG_USE_CROSS_DEVICE 0x0004
struct virtio_gpu_resource_create_blob {
    struct virtio_gpu_ctrl_hdr hdr;
    u32 resource_id, blob_mem, blob_flags, nr_entries;
    u64 blob_id, size;
    /* nr_entries * sizeof(struct virtio_gpu_mem_entry) follow inline */
};
struct virtio_gpu_set_scanout_blob {
    struct virtio_gpu_ctrl_hdr hdr;
    struct virtio_gpu_rect r;
    u32 scanout_id, resource_id, width, height, format, padding;
    u32 strides[4], offsets[4];
};
struct virtio_gpu_resource_map_blob { struct virtio_gpu_ctrl_hdr hdr; u32 resource_id, padding; u64 offset; };
struct virtio_gpu_resp_map_info {
    struct virtio_gpu_ctrl_hdr hdr;
    u32 map_info, padding;   /* VIRTIO_GPU_MAP_CACHE_* */
};
struct virtio_gpu_resource_unmap_blob { struct virtio_gpu_ctrl_hdr hdr; u32 resource_id, padding; };

#define VIRTIO_GPU_MAP_CACHE_MASK     0x0f
#define VIRTIO_GPU_MAP_CACHE_NONE     0x00
#define VIRTIO_GPU_MAP_CACHE_CACHED   0x01
#define VIRTIO_GPU_MAP_CACHE_UNCACHED 0x02
#define VIRTIO_GPU_MAP_CACHE_WC       0x03

/* 2D formats we accept for scanout/2D resources (subset of virtio_gpu_formats) */
#define VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM 1
#define VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM 2
#define VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM 3
#define VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM 4
#define VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM 67
#define VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM 68
#define VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM 121
#define VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM 134

/* Venus context_init parameter ids (documented for the host backend; values
 * from the virtio-gpu spec and Mesa) */
#define VIRTIO_GPU_CONTEXT_PARAM_CAPSET_ID        0x0001
#define VIRTIO_GPU_CONTEXT_PARAM_NUM_RINGS        0x0002
#define VIRTIO_GPU_CONTEXT_PARAM_POLL_RINGS_MASK  0x0003

/* virglrenderer venus capset wire struct (MIT virglrenderer src/venus_hw.h @
 * pinned b6c4d36e1240). The HOST backend fills this from its own renderer
 * instance; the transport copies the bytes verbatim. */
struct virgl_renderer_capset_venus {
    u32 wire_format_version;
    u32 vk_xml_version;
    u32 vk_ext_command_serialization_spec_version;
    u32 vk_mesa_venus_protocol_spec_version;
    u32 supports_blob_id_0;
    u32 vk_extension_mask1[32];
    u32 allow_vk_wait_syncs;
    u32 supports_multiple_timelines;
    u32 use_guest_vram;
};

#endif /* A64_VIRTIO_GPU_PROTOCOL_H */
