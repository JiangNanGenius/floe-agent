/*
 * FloeMachiningNative.h — frozen C ABI for the Floe native machining core.
 *
 * Contract: Local/Private/multi-axis-manufacturing-predev-20261104/CONTRACT.md
 * Module:   FloeMachiningNative (same C module name for ios-arm64,
 *           ios-arm64-simulator and macos-arm64 slices).
 *
 * All boundary values are millimetres; A/C fields are explicit degrees.
 * Functions return a newly allocated UTF-8 JSON object (never an exception or
 * panic across the C boundary). The caller releases it with fm_core_free.
 * The progress callback may return nonzero to request cancellation; no
 * callbacks are made after the synchronous call returns.
 */
#ifndef FLOE_MACHINING_NATIVE_H
#define FLOE_MACHINING_NATIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns nonzero to request cancellation. `fraction` is 0..1. */
typedef int32_t (*FMProgress)(void *context, double fraction, const char *phase);
typedef FMProgress FMProgressCallback;

/*
 * Core turn/mill removal request (JSON v1, see CONTRACT.md).
 * R5: accepts optional top-level initialStockState (remaining-stock
 * continuation; never resets stock) and exports top-level stockState on every
 * success. Returns a JSON object; on any failure the object is exactly
 * {"ok":false,"error":"..."} and never carries success fields.
 */
char *fm_core_execute(const char *request_json, FMProgress callback, void *context);

/*
 * A/C trunnion joint sampling request:
 * {"formatVersion":1,"start":[x,y,z,aDeg,cDeg],"end":[...],"toolLengthMM":10,"steps":40}
 * Returns {"ok":true,"poses":[{"tipMM":[x,y,z],"axis":[i,j,k],"joints":[x,y,z,a,c]}],
 *          "warnings":[...],"backend":"..."} or {"ok":false,"error":"..."}.
 * Start/end are physical gauge joints [X,Y,Z,A,C]; the tool tip is toolLengthMM
 * below the gauge point along machine Z (fixed spindle). Physical C travel is
 * preserved exactly (never wrapped to a shortest arc).
 */
char *fm_core_ac(const char *request_json, FMProgress callback, void *context);

/*
 * R5 generalized machine-axis-chain/body collision query (separate ABI; the
 * exact request/result JSON schema lives in
 * r5/evidence/native-worker/API_SCHEMA.json):
 *  * chain: serial parent-ID axes (linear/revolute, explicit pivot/frame,
 *    units, closed travel limits, unwrapped multi-turn windows) under an
 *    optional rigid baseFrame; forward kinematics only, no IK.
 *  * bodies: identified solids (box/cylinder/capsule/bounded triangle mesh)
 *    attached to axis frames (optional resourceID echoed back); fixtures are
 *    static world bodies.
 *  * motion (single) or motions (synchronized, common t) plus held
 *    jointPositions for non-moved axes; endpoints must lie inside declared
 *    travel (explicit reachability failure otherwise, never clipped/wrapped).
 *  * allowedContactPairs lists PERMITTED intentional contacts (excluded from
 *    evaluation and reported back); queryPairs optionally restricts which
 *    pairs are checked (default: every pair minus allowed ones).
 *  * budget: maxSamples (displacement-adaptive sampling, explicit cannot-cover
 *    failure), maxCollisionQueries (actual Parry calls only), clearanceMM,
 *    sampleSpacingMM, maxRotationDegPerSample.
 * Returns {"ok":true, "motions", "jointPositions", "samplesPlanned",
 *          "poses":[{"t","jointValues","axes","bodies"}], "fixtures",
 *          "excludedPairs", "pairs":[{"a","b","state"
 *          (intersecting|clearance|clear|incomplete|uncertain), ...}],
 *          "parryCalls", "warnings", ...}
 * or {"ok":false,"error":"..."}. Discrete sampled poses only; continuous
 * sweep between samples is not certified. Query errors never become clear.
 */
char *fm_machine_query(const char *request_json, FMProgress callback, void *context);

/* Releases a JSON string returned by fm_core_execute / fm_core_ac. */
void fm_core_free(char *json);

#ifdef __cplusplus
}
#endif

#endif /* FLOE_MACHINING_NATIVE_H */
