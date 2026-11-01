// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Typed refusal of the privileged design-authority ingress. Only the numeric
 * status survives; the owner token, confirmation token and any user content
 * never enter the message.
 */
class DesignAuthorityNativeException(val status: Int) :
    IllegalStateException("design_authority_status_$status")

/**
 * Privileged trusted-host ingress for design RESTRUCTURE preservation
 * confirmations.
 *
 * This is NOT a V3 command, tool or permission. The App calls [prepare] only
 * from the explicit preservation-confirmation action with its live accepted
 * Root epoch + full process owner token; native validates the owner proof and
 * the live target, returns display data + an opaque token, and mints the
 * existing single-use approval grant only through [confirm]. The design
 * service burns that grant immediately before freeze/propose/adopt.
 *
 * The owner token stays inside this JNI call: it is never written to the wire
 * envelope, UI saved state or logs.
 */
object DesignAuthorityNative {
    init { System.loadLibrary("floe_jni") }

    /** Returns the bounded display JSON, or null on a non-throwing refusal. */
    external fun prepare(
        ownerEpoch: Long,
        ownerToken: String,
        requestJson: String,
    ): String?

    /** Mints the existing single-use grant for the exact prepared request. */
    external fun confirm(ownerEpoch: Long, ownerToken: String, token: String): Int

    /** Exact-token revoke (user cancel / superseded sheet). */
    external fun revoke(ownerEpoch: Long, ownerToken: String, token: String): Int

    /** RootStop cleanup for this exact epoch. */
    external fun retire(ownerEpoch: Long, ownerToken: String): Int
}
