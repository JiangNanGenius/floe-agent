// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * External declarations only (no logic) for the TRUSTED-HOST draft
 * probe/discovery seam. Loads the same libfloe_jni the other bridge loaders
 * pin (JVM loadLibrary is idempotent per class loader).
 *
 * This is NOT a bridge command and NOT reachable from the model/tool wire.
 * The provider editor freezes the EXACT closed save candidate from its RAM
 * draft plus the bounded ephemeral key typed in that same session, and
 * submits it with its own live `rt:v1:` editor route handle. Native validates
 * the route against the accepted Root epoch + live provider editor
 * incarnation, maps the candidate through the ORIGINAL draft builder, and
 * dispatches through the ORIGINAL provider adapter under the SAME transport
 * admission gate as the saved probe. Nothing is persisted: no provider row,
 * no model row, no vault intent, no credential-store write.
 *
 * Envelope returned by [pollDraftProbe]:
 *   "P"            still running
 *   "S" + <json>   settled payload (exact ConfigProbeOutcome object, or a
 *                  typed {status:"failed",errorCode,reason}/cancelled object)
 *   "R" + <int>    typed refusal (retired route / invalid handle / oversized)
 */
object ProviderDraftProbeNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Freeze + dispatch one draft probe. Returns the opaque `dp:v1:` handle
     * or null when the native seam refused before any dispatch (retired
     * route, invalid candidate, saturation).
     */
    external fun submitDraftProbe(
        candidate: ByteArray,
        secret: ByteArray?,
        routeToken: String,
    ): String?

    /** Non-blocking poll; see the envelope contract above. */
    external fun pollDraftProbe(handle: String, routeToken: String): String?

    /** Owner cancel; the real adapter work is cancelled natively. */
    external fun cancelDraftProbe(handle: String, routeToken: String): Int
}
