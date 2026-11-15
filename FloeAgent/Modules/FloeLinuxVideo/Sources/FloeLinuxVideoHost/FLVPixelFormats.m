/* SPDX-License-Identifier: MPL-2.0 */
#import "FLVInternal.h"

int flv_validate_dimensions(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return FLV_INVALID;
    if (width > FLV_STRUCT_MAX_DIMENSION || height > FLV_STRUCT_MAX_DIMENSION) return FLV_LIMIT;
    /* Paranoia overflow guard for downstream stride math. */
    if ((uint64_t)width * (uint64_t)height > (1ull << 40)) return FLV_LIMIT;
    return FLV_OK;
}

int flv_pixel_layout(uint32_t pixel_format, uint32_t width, uint32_t height,
                     uint32_t *plane_count,
                     uint64_t *plane_bytes, uint32_t *min_strides, uint32_t *plane_rows) {
    int rc = flv_validate_dimensions(width, height);
    if (rc != FLV_OK) return rc;
    uint64_t w = width, h = height;
    switch (pixel_format) {
        case FLV_NV12:
            *plane_count = 2;
            plane_bytes[0] = w * h;
            plane_bytes[1] = (w * h) / 2; /* exact for even; odd sizes invalid for 4:2:0 */
            if ((width & 1u) || (height & 1u)) return FLV_INVALID;
            min_strides[0] = width;
            min_strides[1] = width;
            plane_rows[0] = height;
            plane_rows[1] = height / 2;
            return FLV_OK;
        case FLV_P010:
            *plane_count = 2;
            plane_bytes[0] = w * h * 2;
            plane_bytes[1] = w * h; /* 2 bytes per UV pair */
            if ((width & 1u) || (height & 1u)) return FLV_INVALID;
            min_strides[0] = width * 2;
            min_strides[1] = width * 2;
            plane_rows[0] = height;
            plane_rows[1] = height / 2;
            return FLV_OK;
        case FLV_BGRA:
            *plane_count = 1;
            plane_bytes[0] = w * h * 4;
            min_strides[0] = width * 4;
            plane_rows[0] = height;
            return FLV_OK;
        case FLV_YUYV:
        case FLV_UYVY:
            *plane_count = 1;
            plane_bytes[0] = w * h * 2;
            min_strides[0] = width * 2;
            plane_rows[0] = height;
            return FLV_OK;
        default:
            return FLV_UNSUPPORTED;
    }
}
