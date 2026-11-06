#ifndef TURNINGNATIVE_H
#define TURNINGNATIVE_H

/*
 * TurningNative — native single-spindle turning planner C ABI.
 *
 * Prototype for the local manufacturing predevelopment (2026-11-04).
 * Geometry engine: vendored LibLathe C++ core
 * (github.com/dubstar-04/LibLathe @ 4bac3400813f40a15e0bf22e12998453e337d96e,
 *  GPL-2.0, see Vendor/liblathe/LICENSE). face/rough/profile operations are a
 * mechanical C++ port of LibLathe's liblathe/op/{face,rough,profile}.py.
 *
 * Request/response JSON: see Local/Private/multi-axis-manufacturing-predev-20261104/CONTRACT.md
 * (formatVersion 1, millimetres, profile pairs are [radius, z]).
 *
 * All functions are plain C; no exceptions cross this boundary. Returned
 * strings are freshly allocated with malloc and must be released with
 * fm_turn_free. No callbacks are invoked after the synchronous call returns.
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Progress/cancellation callback. Return nonzero to request cancellation.
 * `fraction` is a best-effort 0..1 progress hint; `phase` is a short
 * ASCII phase name (never NULL). */
typedef int32_t (*FMProgress)(void *context, double fraction, const char *phase);

/* Plans turning cut paths (face, external roughing, profile finishing).
 * Returns a newly allocated UTF-8 JSON object:
 *   success: {"ok":true,"backend":"...","paths":[{"kind":"face|rough|profile",
 *             "points":[[radius,z],...],"feedMMPerMinute":f}],"warnings":[...]}
 *   failure: {"ok":false,"error":"..."}  (cancellation => error "cancelled")
 * Returns NULL only on allocation failure.
 *
 * Optional top-level "turningSetup" (formatVersion 1) selects the native
 * operations (faceEnabled/roughEnabled/profileEnabled), clearance, per-axis
 * feeds (horizontal/verticalFeedMMPerMinute), lead angles, allowGrooving and
 * the real 2D insert (insertShape C/D/S/V/R/T, insertEdgeLengthMM,
 * insertRotationDegrees). When present, paths carry per-axis directional
 * feeds (split where the feed changes) and the result includes a
 * "setupReceipt" with the applied setup, the exact tool outline used for
 * defeature and the backend string. When absent the legacy scalar
 * turning.feedMMPerMinute applies to every path and no receipt is emitted.
 * See Local/Private/multi-axis-manufacturing-predev-20261104/r4/CONTRACT.md
 * and r4/turning/API.md for the exact schema and validation ranges. */
char *fm_turn_plan(const char *request_json, FMProgress callback, void *context);

/* Frees a string returned by fm_turn_plan. NULL is a no-op. */
void fm_turn_free(char *json);

#ifdef __cplusplus
}
#endif

#endif /* TURNINGNATIVE_H */
