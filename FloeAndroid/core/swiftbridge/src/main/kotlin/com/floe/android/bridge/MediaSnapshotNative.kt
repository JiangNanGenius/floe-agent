// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Trusted App transport for the G09-R2 native render-snapshot lease
 * (job-b72b2978320e484e). Declarations only — NO business logic here.
 *
 * The frozen `floe.creative/6` action list has no snapshot action, so the App
 * host reaches the native lease authority through this narrow host-only ABI.
 * It is NOT a bridge version, NOT a model tool and NOT a second project store:
 * Swift validates the request against the SAME bound accepted root/epoch and
 * writes the immutable snapshot. The App must never construct a lease by value.
 *
 * Both calls are blocking host calls executed on the creative IO dispatcher
 * (never on the UI thread, never inside `exchangeLocked`).
 *
 * Status space: 0 ok; -101 unknown/mismatched lease; -102 generation fenced;
 * -105 invalid shape/token; -106 buffer too small; -107 oversize request;
 * -108 descriptor invalid.
 */
object MediaSnapshotNative {
    init { System.loadLibrary("floe_jni") }

    /** Request JSON = exact `G09R2RenderSnapshotRequestDTO` object keys:
     * `{context:{projectID,sessionToken,storage:{kind,workspaceID?},origin?},
     *   expectedRevision, expectedTimelineDigest}`.
     * Reply = native-issued lease object or `{ok:false,error,...}`. */
    external fun acquire(epoch: Long, request: ByteArray): ByteArray?

    /** Exact lease object JSON; idempotent, removes only the owned snapshot. */
    external fun release(epoch: Long, lease: ByteArray): Int
}
