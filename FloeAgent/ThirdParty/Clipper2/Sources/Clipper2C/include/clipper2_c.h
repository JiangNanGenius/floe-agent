/*
 * Thin C ABI for the pinned Clipper2 library.
 *
 * SPDX-License-Identifier: BSL-1.0
 *
 * Coordinates are integer values supplied by the caller. The caller owns the
 * coordinate space (for example 1/1024 of a canvas pixel) and is responsible
 * for keeping the quantization error inside its own documented tolerance.
 * This header does not expose C++ types and does not own document/model state.
 */

#ifndef FLOE_CLIPPER2_C_H
#define FLOE_CLIPPER2_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum FloeClipperOperation {
    FLOE_CLIPPER_INTERSECTION = 0,
    FLOE_CLIPPER_UNION = 1,
    FLOE_CLIPPER_DIFFERENCE = 2,
    FLOE_CLIPPER_XOR = 3
} FloeClipperOperation;

typedef enum FloeClipperFillRule {
    FLOE_CLIPPER_FILL_EVEN_ODD = 0,
    FLOE_CLIPPER_FILL_NON_ZERO = 1,
    FLOE_CLIPPER_FILL_POSITIVE = 2,
    FLOE_CLIPPER_FILL_NEGATIVE = 3
} FloeClipperFillRule;

typedef enum FloeClipperJoinType {
    FLOE_CLIPPER_JOIN_SQUARE = 0,
    FLOE_CLIPPER_JOIN_BEVEL = 1,
    FLOE_CLIPPER_JOIN_ROUND = 2,
    FLOE_CLIPPER_JOIN_MITER = 3
} FloeClipperJoinType;

typedef enum FloeClipperEndType {
    FLOE_CLIPPER_END_POLYGON = 0,
    FLOE_CLIPPER_END_JOINED = 1,
    FLOE_CLIPPER_END_BUTT = 2,
    FLOE_CLIPPER_END_SQUARE = 3,
    FLOE_CLIPPER_END_ROUND = 4
} FloeClipperEndType;

/*
 * Owned result. `coords` contains `coord_count` int64 values, i.e. 2 values per
 * point. `offsets` contains `path_count + 1` indexes into point units: path i
 * occupies coords[2*offsets[i] ..< 2*offsets[i+1]]. Release with
 * floe_clipper_result_free. On error, coord_count and path_count are zero and
 * error_message is a heap-allocated NUL-terminated UTF-8 string (or NULL).
 */
typedef struct FloeClipperResult {
    int64_t *coords;
    size_t coord_count;
    size_t *offsets;
    size_t path_count;
    int32_t error_code;
    char *error_message;
} FloeClipperResult;

/*
 * Boolean operation.
 *
 * subject_coords/clip_coords: flat x,y pairs.
 * subject_offsets/clip_offsets: path_count+1 indexes; the first must be 0 and
 * the last must equal coord_count/2. Empty paths are allowed.
 */
FloeClipperResult floe_clipper_boolean(
    int32_t operation,
    int32_t fill_rule,
    const int64_t *subject_coords,
    size_t subject_coord_count,
    const size_t *subject_offsets,
    size_t subject_path_count,
    const int64_t *clip_coords,
    size_t clip_coord_count,
    const size_t *clip_offsets,
    size_t clip_path_count);

/*
 * Polygon offset. `delta`, `miter_limit` and `arc_tolerance` are expressed in
 * the same integer coordinate units as the input. `arc_tolerance` is the
 * caller's explicit maximum chord error for round joins/arcs.
 */
FloeClipperResult floe_clipper_offset(
    const int64_t *coords,
    size_t coord_count,
    const size_t *offsets,
    size_t path_count,
    double delta,
    int32_t join_type,
    int32_t end_type,
    double miter_limit,
    double arc_tolerance);

/* Releases all allocations in a result and zeroes it. Safe on a zeroed value. */
void floe_clipper_result_free(FloeClipperResult *result);

/* Pinned upstream version string, owned by the library (do not free). */
const char *floe_clipper_version(void);

#ifdef __cplusplus
}
#endif

#endif /* FLOE_CLIPPER2_C_H */
