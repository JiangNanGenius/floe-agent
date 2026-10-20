// SPDX-License-Identifier: MPL-2.0
package com.floe.android.credentials

/**
 * Secret-free failure surface for [AndroidKeystoreCredentialStore].
 *
 * Messages are stable codes, never credential values, raw references or file
 * paths. Causes are retained for diagnostics but must not be rendered as user
 * copy without review.
 */
sealed class CredentialStoreException(
    val code: String,
    cause: Throwable? = null,
) : Exception(code, cause) {
    /** The reference is empty, too long or outside the opaque reference alphabet. */
    class InvalidReference : CredentialStoreException("invalid_reference")

    /** The namespace is empty, too long or outside the namespace alphabet. */
    class InvalidNamespace : CredentialStoreException("invalid_namespace")

    /** The secret is larger than [CredentialLimits.MAX_SECRET_BYTES]. */
    class InvalidValue : CredentialStoreException("invalid_value")

    /** The envelope header or length is invalid; no authentication was attempted. */
    class CorruptRecord(cause: Throwable? = null) : CredentialStoreException("corrupt_record", cause)

    /** AES-GCM authentication failed (tampering, cross-reference swap or wrong key). */
    class AuthenticationFailed(cause: Throwable? = null) : CredentialStoreException("authentication_failed", cause)

    /** The per-reference key is absent, permanently invalidated or unrecoverable. */
    class KeyUnavailable(cause: Throwable? = null) : CredentialStoreException("key_unavailable", cause)

    /** AndroidKeyStore/provider operation failed; retry may be possible. */
    class KeyStoreFailure(cause: Throwable? = null) : CredentialStoreException("keystore_failure", cause)

    /** Local record I/O failed; the previous committed record is retained. */
    class StorageFailure(cause: Throwable? = null) : CredentialStoreException("storage_failure", cause)

    /** Delete did not fully remove the record and/or its key. */
    class DeleteFailed(cause: Throwable? = null) : CredentialStoreException("delete_failed", cause)
}
