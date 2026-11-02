// Thin product adapter. xatlas algorithm and its qualified archives remain unchanged.
// SPDX-License-Identifier: MPL-2.0
#ifndef FLOE_XATLAS_H
#define FLOE_XATLAS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FXACancel FXACancel;
FXACancel *fxa_cancel_create(void);
void fxa_cancel_request(FXACancel *cancel);
void fxa_cancel_destroy(FXACancel *cancel);
// Status: 0 success, 1 invalid input, 2 cancelled, 3 rejected by
// xatlas, 4 unsupported multi-atlas/incomplete result, 5 bad result, 6 allocation,
// 7 another native atlas operation is active, 8 cooperative deadline. Output is usable ONLY on 0.
// Packed xyz/normals, whole triangle indices and one group per input triangle.
// Output UVs are packed uv pairs, ONE PER INPUT INDEX, in original face order.
int32_t fxa_unwrap(const float *positions, const float *normals, uint32_t vertexCount,
                   const uint32_t *indices, uint32_t indexCount,
                   const uint32_t *faceGroups, uint32_t resolution, uint32_t padding,
                   double wallClockLimitSeconds, FXACancel *cancel, float *cornerUVs, uint32_t *faceCharts,
                   uint32_t *actualWidth, uint32_t *actualHeight);
// Repack an edited set with existing per-face island ids; all inputs are
// per-corner, with implicit 0..cornerCount-1 indices. No 3D geometry is modified.
int32_t fxa_pack(const float *cornerUVs, uint32_t cornerCount,
                 const uint32_t *faceCharts, uint32_t resolution, uint32_t padding,
                 double wallClockLimitSeconds, FXACancel *cancel, float *packedUVs, uint32_t *packedCharts,
                 uint32_t *actualWidth, uint32_t *actualHeight);
#ifdef __cplusplus
}
#endif
#endif
