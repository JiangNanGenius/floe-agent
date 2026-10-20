// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials.debug

/**
 * Secret-free failures for the debug-only sealed QA enrollment protocol.
 * These types are compiled into debug variants only.
 */
sealed class DebugEnrollmentException(
    val code: String,
    cause: Throwable? = null,
) : Exception(code, cause) {
    /** Descriptor, session id, state file or protocol fields are malformed. */
    class InvalidSession(cause: Throwable? = null) : DebugEnrollmentException("invalid_session", cause)

    /** No state exists: never created, already imported, cancelled or cleaned. */
    class SessionUnknown : DebugEnrollmentException("session_unknown")

    /** The one-shot session passed its expiry without a successful import. */
    class SessionExpired : DebugEnrollmentException("session_expired")

    /** The state was created for a different application package. */
    class SessionPackageMismatch : DebugEnrollmentException("session_package_mismatch")

    /** The session private key is missing or unusable. */
    class SessionKeyUnavailable(cause: Throwable? = null) :
        DebugEnrollmentException("session_key_unavailable", cause)

    /** Session lifetime is outside the debug helper's allowed range. */
    class InvalidTtl : DebugEnrollmentException("invalid_ttl")

    /** The plaintext payload exceeds the credential store bound. */
    class InvalidPayload : DebugEnrollmentException("invalid_payload")

    /** Host-side sealing failed before producing an envelope. */
    class SealFailed(cause: Throwable? = null) : DebugEnrollmentException("seal_failed", cause)

    /** Sealed envelope structure, RSA unwrap or AES-GCM authentication failed. */
    class SealedEnvelopeRejected(cause: Throwable? = null) :
        DebugEnrollmentException("sealed_envelope_rejected", cause)

    /** Session key creation or state persistence failed. */
    class SessionCreationFailed(cause: Throwable? = null) :
        DebugEnrollmentException("session_creation_failed", cause)

    /** Imported credential exists, but session key/state cleanup failed. */
    class SessionCleanupFailed(cause: Throwable? = null) :
        DebugEnrollmentException("session_cleanup_failed", cause)

    /**
     * The durable one-shot consumption marker exists. The envelope was already
     * used, possibly with an uncertain credential-write outcome; reissue a new
     * session instead of retrying this one.
     */
    class SessionConsumed : DebugEnrollmentException("session_consumed")

    /** The durable consumption marker could not be read or written safely. */
    class SessionConsumptionFailed(cause: Throwable? = null) :
        DebugEnrollmentException("session_consumption_failed", cause)

    /** Another import currently owns this session; cancel must not race it. */
    class SessionBusy : DebugEnrollmentException("session_busy")
}
