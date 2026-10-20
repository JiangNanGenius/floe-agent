// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Typed staging rejection raised by the RB-7 attachment JNI adapter. Only
 * the numeric contract status is retained — storage roots, receipts, URIs,
 * display names and file bytes NEVER enter the message.
 *
 * Status space (owned by `AttachmentStagingStatus` in Swift; additive to
 * the frozen runtime-owner -2xx space, mirroring how that space is itself
 * additive to the gateway -1xx space):
 *   0 ok, -105 shape, -106 buffer too small,
 *   -301 notInstalled, -302 generationFenced, -303 routeUnknown,
 *   -304 routeTemporary, -305 ingressUnknown, -306 stateConflict,
 *   -307 sizeExceeded, -308 aggregateExceeded, -309 diskFull,
 *   -310 saturated, -311 writeFailed, -312 readFailed, -313 handleUnknown,
 *   -314 grantMissing, -315 digestMismatch, -316 partial, -399 internal.
 */
class AttachmentStagingNativeException(val status: Int) :
    IllegalStateException("staging_status_$status")

/**
 * External declarations only (no logic) for the RB-7 staging byte channel.
 * The class initializer is the ONE place this seam loads libfloe_jni (the
 * same library object the gateway and runtime-owner loaders already pin;
 * JVM loadLibrary is idempotent per class loader). Production callers touch
 * this object only from the staging platform service's worker coroutine —
 * never from a property initializer or Application main.
 *
 * The frozen SwiftCore.kt, SecretGatewayNative.kt and RuntimeCoreNative.kt
 * stay byte-identical.
 *
 * Byte direction (the ONLY two binary channels in this lane):
 *  - `stagingWrite` pushes one bounded chunk (<= 64 KiB) of the REAL source
 *    stream into the trusted native ingress file. No whole-file buffering,
 *    no base64, no JSON.
 *  - `stagingRead` / `attachmentRead` pull bounded preview pages back into
 *    a caller-provided ByteArray. Return semantics: >=0 = bytes actually
 *    copied into the buffer (0 = clean EOF), <0 = typed
 *    [AttachmentStagingStatus] code, never a silent wrong answer.
 */
object AttachmentStagingNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Register one compose route with the trusted native host.
     * [conversationId] = null for the new-conversation composer (a valid
     * host route exists before any run; no fabricated conversation).
     * Temporary sessions must be refused by the CALLING platform layer
     * BEFORE reaching this seam; the native side double-refuses (-304).
     * Returns the opaque route receipt (`route:v1:<32hex>`).
     */
    external fun stagingRouteOpen(
        conversationId: String?,
        incarnation: Long,
        draftRevision: Long,
        isTemporary: Boolean,
    ): String

    /** Invalidate one route: aborts that route's live ingresses only.
     * Normal staged bytes survive until explicit discard/consumption. */
    external fun stagingRouteClose(routeReceipt: String)

    /**
     * Open one bounded staging ingress under [routeReceipt].
     * [reusingStagingId] supports the retry contract ("same attachment id,
     * host re-derives bytes"); pass null for a fresh import.
     * Returns "<ingressReceipt> <stagingId>" — two space-separated ASCII
     * tokens validated in C before crossing (never a raw path).
     */
    external fun stagingBegin(routeReceipt: String, reusingStagingId: String?): String

    /** One bounded chunk of the actual source stream. Throws typed
     * [AttachmentStagingNativeException] on refusal (size/aggregate/free
     * space/cancel/write failure/saturation). */
    external fun stagingWrite(ingressReceipt: String, data: ByteArray, offset: Int, length: Int)

    /** EOF: flush+fsync the temp, clamp the untrusted hints, mark the
     * session ready for the `attachment.stage` publish command. */
    external fun stagingEnd(
        ingressReceipt: String,
        displayNameHint: String?,
        mimeTypeHint: String?,
    )

    /** Fast host abort of a live ingress (bytes removed; never touches a
     * published or leased file). */
    external fun stagingAbort(ingressReceipt: String)

    /** Authoritative in-process progress "bytes finished cancelled"
     * (ASCII decimal tokens; the UI renders its own fraction). */
    external fun stagingProgress(ingressReceipt: String): String

    /** Bounded preview read of a STAGED file. Returns copied bytes
     * (>=0, 0=EOF) or a negative typed status. */
    external fun stagingRead(handle: String, offset: Long, buffer: ByteArray): Int

    /** Bounded preview read of a COMMITTED attachment. Requires the live
     * read grant that the `attachment.read` command mints after the
     * original-row ownership verification settles; absent/stale grant is
     * -314 (fail closed), never an unverified read. */
    external fun attachmentRead(
        attachmentId: String,
        conversationId: String,
        offset: Long,
        buffer: ByteArray,
    ): Int

    /** Lock-only bounded counters JSON (installed/epoch/counts; no paths,
     * names or URIs). Null only when the Swift side cannot serialize;
     * callers treat null as unknown, never as ready. */
    external fun stagingStatus(): String?
}
