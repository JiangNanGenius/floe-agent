// SPDX-License-Identifier: MPL-2.0
// Floe's bounded C facade; geometry is supplied by Apache-2.0 Manifold 3.5.4.
#ifndef FLOE_MANIFOLD_H
#define FLOE_MANIFOLD_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FloeManifoldContext FloeManifoldContext;
typedef struct FloeManifoldResult FloeManifoldResult;
FloeManifoldContext *floe_manifold_context_create(void);
void floe_manifold_context_cancel(FloeManifoldContext *context);
void floe_manifold_context_destroy(FloeManifoldContext *context);
// xyz buffers are tightly packed float triples. Only byte-identical seam
// positions are welded; this route never repairs holes or changes tolerance.
// operation: 0 union, 1 subtract, 2 intersect. A null tool validates the source.
FloeManifoldResult *floe_manifold_boolean(FloeManifoldContext *context,
    const float *sourceXYZ, size_t sourceVertexCount,
    const uint32_t *sourceTriangles, size_t sourceIndexCount,
    const float *toolXYZ, size_t toolVertexCount,
    const uint32_t *toolTriangles, size_t toolIndexCount, int operation);
// 0 success; 1 malformed; 2 non-manifold; 3 cancelled; 4 empty; 5 budget; 6 kernel.
int floe_manifold_result_status(const FloeManifoldResult *result);
const char *floe_manifold_result_message(const FloeManifoldResult *result);
size_t floe_manifold_result_vertex_count(const FloeManifoldResult *result);
size_t floe_manifold_result_index_count(const FloeManifoldResult *result);
const float *floe_manifold_result_xyz(const FloeManifoldResult *result);
const uint32_t *floe_manifold_result_indices(const FloeManifoldResult *result);
double floe_manifold_result_volume(const FloeManifoldResult *result);
void floe_manifold_result_destroy(FloeManifoldResult *result);
#ifdef __cplusplus
}
#endif
#endif
