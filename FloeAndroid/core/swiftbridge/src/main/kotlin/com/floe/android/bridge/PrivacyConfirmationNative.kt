// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Typed refusal of the privileged privacy-confirmation ingress. Only the
 * numeric status survives; the owner token, preview digest, capability and
 * any user data never enter the message.
 */
class PrivacyConfirmationNativeException(val status: Int) :
    IllegalStateException("privacy_confirmation_status_$status")

/**
 * Privileged trusted-host confirmation ingress for the two destructive
 * privacy commands (privacy.history.clear / privacy.modelConfiguration.clear).
 *
 * This is NOT a V3 command, tool or permission. The App calls [issue] ONLY
 * from the explicit user confirmation action, passing its live accepted Root
 * epoch + full process owner token; the native side re-validates the full
 * owner proof and mints an opaque `pc:v1:` capability bound to the exact
 * root, epoch, operation, action, preview digest and command correlation
 * ([invocationID]). The command path consumes it exactly once.
 *
 * The owner token stays inside this JNI call: it is never written to the
 * wire envelope, UI saved state or logs.
 */
object PrivacyConfirmationNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Returns the opaque one-operation capability, or null only when the
     * native side refused without a typed status (defensive). A typed
     * refusal throws [PrivacyConfirmationNativeException].
     */
    external fun issue(
        ownerEpoch: Long,
        ownerToken: String,
        operation: String,
        previewDigest: String,
        invocationID: String,
        action: String,
    ): String?

    /** Exact-token revoke; returns 0 or a typed refusal status. */
    external fun revoke(ownerEpoch: Long, ownerToken: String, token: String): Int

    /** RootStop cleanup for this exact epoch; returns 0 or a refusal status. */
    external fun retire(ownerEpoch: Long, ownerToken: String): Int
}
